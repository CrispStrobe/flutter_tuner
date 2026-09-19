/// Runs Basic Pitch off the UI thread, and says plainly where it cannot run.
///
/// Inference costs roughly half a second per two-second window on a native
/// core (`bench/REPORT.md` §10.1), which is fine for a transcription display
/// updating once or twice a second and completely unacceptable on the thread
/// drawing the needle. So it lives in an isolate, loaded once and fed
/// windows.
///
/// On the web there are no isolates for this kind of work, and the numeric
/// cost is tens of times higher under dart2js besides (the measurement behind
/// `fft_real.dart`). Rather than ship a mode that freezes a browser tab,
/// [TranscriptionService.isSupported] is false there and the UI says so.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';

import 'transcription.dart';

/// Where the model ships.
const String kBasicPitchAsset = 'assets/models/basic_pitch.onnx';

/// The graph's output names.
///
/// `StatefulPartitionedCall:1` is the **note** head and `:2` is the **onset**
/// head — not the other way round, which is the order the names suggest and
/// the order this code had at first. Established by measurement rather than
/// by reading: on real audio the note head's activations run for a mean of 59
/// frames and the onset head's for 11.5, because one marks a note's duration
/// and the other marks its beginning. `bench/tool/kaggle/polyphonic-eval`
/// re-derives this at runtime and prints its decision; the app hard-codes the
/// answer and `test/transcription_test.dart` guards it.
const String kNoteHead = 'StatefulPartitionedCall:1';
const String kOnsetHead = 'StatefulPartitionedCall:2';
const String kContourHead = 'StatefulPartitionedCall:0';

class TranscriptionService {
  /// Whether this platform can run the mode at all.
  ///
  /// Not a capability check on the device — a statement about the platform.
  /// See the library comment: dart2js makes this numeric work tens of times
  /// slower, and there is no isolate to hide it in.
  static bool get isSupported => !kIsWeb;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Completer<TranscriptionResult>? _pending;
  bool _starting = false;

  bool get isRunning => _toWorker != null;

  /// Load the model and start the worker. Safe to call twice.
  Future<void> start() async {
    if (_toWorker != null || _starting) return;
    if (!isSupported) {
      throw UnsupportedError(
          'transcription needs an isolate and native numeric speed; '
          'see TranscriptionService.isSupported');
    }
    _starting = true;
    try {
      final model = await rootBundle.load(kBasicPitchAsset);
      final bytes = model.buffer.asUint8List(
          model.offsetInBytes, model.lengthInBytes);

      final ready = Completer<SendPort>();
      _fromWorker = ReceivePort();
      _fromWorker!.listen((message) {
        if (message is SendPort) {
          ready.complete(message);
        } else if (message is TranscriptionResult) {
          _pending?.complete(message);
          _pending = null;
        } else if (message is _WorkerError) {
          _pending?.completeError(StateError(message.message));
          _pending = null;
        }
      });

      _isolate = await Isolate.spawn(
        _workerMain,
        _WorkerStart(_fromWorker!.sendPort, bytes),
        debugName: 'basic-pitch',
      );
      _toWorker = await ready.future;
    } finally {
      _starting = false;
    }
  }

  /// Transcribe one window of **22.05 kHz** audio, exactly
  /// [BasicPitchGeometry.windowSamples] long.
  ///
  /// Returns null if an inference is already in flight: this mode is
  /// deliberately drop-latest rather than queueing, because a queue of stale
  /// windows is the thing that makes a slow device feel broken.
  Future<TranscriptionResult>? transcribe(Float64List window) {
    final port = _toWorker;
    if (port == null || _pending != null) return null;
    final completer = Completer<TranscriptionResult>();
    _pending = completer;
    port.send(Float64List.fromList(window));
    return completer.future;
  }

  Future<void> stop() async {
    _toWorker?.send(null);
    _toWorker = null;
    _fromWorker?.close();
    _fromWorker = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _pending = null;
  }
}

class _WorkerStart {
  final SendPort reply;
  final Uint8List model;
  const _WorkerStart(this.reply, this.model);
}

class _WorkerError {
  final String message;
  const _WorkerError(this.message);
}

/// The isolate body: load the model once, then answer windows.
void _workerMain(_WorkerStart start) {
  final inbox = ReceivePort();
  start.reply.send(inbox.sendPort);

  OnnxModel? model;
  const decoder = BasicPitchDecoder();

  inbox.listen((message) {
    if (message == null) {
      inbox.close();
      return;
    }
    if (message is! Float64List) return;
    final stopwatch = Stopwatch()..start();
    try {
      model ??= OnnxModel.fromBytes(start.model);

      final input = Float32List(BasicPitchGeometry.windowSamples);
      final n = message.length < input.length ? message.length : input.length;
      for (int i = 0; i < n; i++) {
        input[i] = message[i];
      }

      // Two heads are 88 wide — note and onset — and the ONNX export names
      // neither. Getting the order wrong is silent and expensive: assuming it
      // cost a whole corpus evaluation, which scored the onset head as if it
      // were notes and reported a recall of 21%. Onsets fire for a few frames
      // at a note's start; note activations are sustained for its duration,
      // so the two are separable by how long their activations run, and
      // [_identifyHeads] does that once against real audio.
      final outputs = model!.run(
        {
          'serving_default_input_2:0':
              Tensor.float(input, [1, input.length, 1]),
        },
        const [kNoteHead, kOnsetHead],
      );

      final note = outputs[kNoteHead]!.asFloatList();
      final onset = outputs[kOnsetHead]!.asFloatList();
      final notes = decoder.decode(
        Float64List.fromList(note),
        Float64List.fromList(onset),
      );
      stopwatch.stop();
      start.reply.send(TranscriptionResult(notes, stopwatch.elapsed));
    } catch (e) {
      start.reply.send(_WorkerError('$e'));
    }
  });
}
