/// The FFI half of [CrispAsrBackend]'s conditional export. See
/// `crispasr_backend.dart` for the measurements and for why this is not the
/// default.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';

import 'transcription.dart';
import 'transcription_backend.dart';

/// Basic Pitch through CrispASR's ggml runtime.
///
/// Availability is a *runtime* question here, unlike [TranscriptionService]
/// where it is a platform one: the `crispasr` package does not bundle
/// `libcrispasr`, so whether this backend can run depends on whether a host
/// has one installed. [isAvailable] answers that by looking, and the mode
/// list should hide the backend when it says no rather than offering a
/// choice that throws.
class CrispAsrBackend implements TranscriptionBackend {
  /// Explicit path to `libcrispasr`, or null to let the package resolve the
  /// platform's default name (`libcrispasr.so`, `libcrispasr.dylib`, …).
  final String? libraryPath;

  /// Path to `basic-pitch-f16.gguf` (or f32). Unlike the ONNX model, which
  /// ships as a 225 KB asset, this is not bundled — the GGUF is CrispASR's
  /// own artefact and lives wherever the host put it.
  final String? modelPath;

  CrispAsrBackend({this.libraryPath, this.modelPath});

  /// Configure from the environment, or null when it is not configured.
  ///
  /// Neither half of this backend ships with the app — the GGUF is CrispASR's
  /// artefact and the native library is a separate install — so there is no
  /// sensible default path to guess. Two environment variables are the seam:
  ///
  /// ```
  /// CRISPTUNER_BASIC_PITCH_GGUF=/path/to/basic-pitch-f16.gguf
  /// CRISPTUNER_CRISPASR_LIB=/path/to/libcrispasr.so   # optional
  /// ```
  ///
  /// If this ever becomes a shipped choice rather than a developer one, the
  /// paths move into settings and this method is what they replace.
  static CrispAsrBackend? fromEnvironment() {
    final model = Platform.environment['CRISPTUNER_BASIC_PITCH_GGUF'];
    if (model == null || model.isEmpty) return null;
    final lib = Platform.environment['CRISPTUNER_CRISPASR_LIB'];
    final backend = CrispAsrBackend(
        modelPath: model, libraryPath: lib?.isEmpty ?? true ? null : lib);
    return backend.isAvailable ? backend : null;
  }

  @override
  String get id => 'basic-pitch-crispasr';

  @override
  String get displayName => 'Basic Pitch (CrispASR/ggml)';

  /// True only when both halves are actually present: the native library and
  /// the GGUF. Opening is deferred to [start]; this is the cheap check the
  /// settings list can call.
  @override
  bool get isAvailable {
    final model = modelPath;
    if (model == null || !File(model).existsSync()) return false;
    final lib = libraryPath;
    if (lib != null) return File(lib).existsSync();
    // No explicit path: the loader will search the platform's library path,
    // which cannot be answered without trying to open it.
    return true;
  }

  /// 22050 Hz — the same rate as the ONNX arm, and confirmed at [start] by
  /// asking the session rather than assuming. CrispASR serves Basic Pitch
  /// through its *piano* (note-event) arm, whose C parameter is still named
  /// `pcm_16k` after piano-transcription; the name is a fossil and the query
  /// is the truth.
  @override
  int get inputSampleRate => BasicPitchGeometry.sampleRate;

  @override
  int get windowSamples => BasicPitchGeometry.windowSamples;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Completer<TranscriptionResult>? _pending;
  bool _starting = false;

  @override
  bool get isRunning => _toWorker != null;

  @override
  Future<void> start() async {
    if (_toWorker != null || _starting) return;
    final model = modelPath;
    if (model == null || !File(model).existsSync()) {
      throw UnsupportedError(
          'CrispASR backend needs a basic-pitch GGUF; none at $model');
    }
    _starting = true;
    try {
      final ready = Completer<Object>();
      _fromWorker = ReceivePort();
      _fromWorker!.listen((message) {
        if (message is SendPort) {
          if (!ready.isCompleted) ready.complete(message);
        } else if (message is TranscriptionResult) {
          _pending?.complete(message);
          _pending = null;
        } else if (message is _WorkerError) {
          if (!ready.isCompleted) {
            ready.complete(message);
          } else {
            _pending?.completeError(StateError(message.message));
            _pending = null;
          }
        }
      });

      _isolate = await Isolate.spawn(
        _workerMain,
        _WorkerStart(_fromWorker!.sendPort, model, libraryPath),
        debugName: 'crispasr-basic-pitch',
      );
      final answer = await ready.future;
      if (answer is _WorkerError) {
        await stop();
        throw StateError(answer.message);
      }
      _toWorker = answer as SendPort;
    } finally {
      _starting = false;
    }
  }

  @override
  Future<TranscriptionResult>? transcribe(Float64List window) {
    final port = _toWorker;
    if (port == null || _pending != null) return null;
    final completer = Completer<TranscriptionResult>();
    _pending = completer;
    port.send(Float64List.fromList(window));
    return completer.future;
  }

  @override
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
  final String modelPath;
  final String? libraryPath;
  const _WorkerStart(this.reply, this.modelPath, this.libraryPath);
}

class _WorkerError {
  final String message;
  const _WorkerError(this.message);
}

/// How much of the end of the window counts as "now".
///
/// The same span the ONNX decoder averages over — 8 frames of 256 samples at
/// 22050 Hz, 93 ms — so the two backends describe the same instant and a user
/// switching between them sees the same notes appear at the same time.
const double _tailSeconds =
    BasicPitchDecoder.defaultTailFrames * BasicPitchGeometry.frameHop /
        BasicPitchGeometry.sampleRate;

void _workerMain(_WorkerStart start) {
  final inbox = ReceivePort();
  CrispasrSession? session;
  int rate = BasicPitchGeometry.sampleRate;

  try {
    session = CrispasrSession.open(start.modelPath,
        libPath: start.libraryPath, backend: 'basic-pitch', nThreads: 2);
    // Ask, do not assume: a future GGUF at another rate would otherwise be
    // fed audio at the wrong speed and transpose every note silently.
    final wanted = session.pianoSampleRate;
    if (wanted > 0) rate = wanted;
    if (rate != BasicPitchGeometry.sampleRate) {
      throw StateError('model wants $rate Hz, but the capture path decimates '
          'to ${BasicPitchGeometry.sampleRate}');
    }
  } catch (e) {
    start.reply.send(_WorkerError('$e'));
    inbox.close();
    return;
  }

  start.reply.send(inbox.sendPort);

  inbox.listen((message) {
    if (message == null) {
      session?.close();
      inbox.close();
      return;
    }
    if (message is! Float64List) return;
    final stopwatch = Stopwatch()..start();
    try {
      final pcm = Float32List(message.length);
      for (int i = 0; i < pcm.length; i++) {
        pcm[i] = message[i];
      }
      final events = session!.pianoNotes(pcm);
      final windowMs = 1000.0 * pcm.length / rate;
      final from = windowMs - _tailSeconds * 1000;

      // Note *events*, not per-frame activations: keep the ones still
      // sounding at the end of the window, which is what the ONNX decoder's
      // tail average approximates.
      final notes = <TranscribedNote>[];
      for (final e in events) {
        if (e.offMs < from || e.onMs > windowMs) continue;
        // `velocity` is the model's loudness estimate, not a confidence —
        // the CrispASR docs say so explicitly. Mapping it into `strength`
        // is a deliberate choice: the field exists to sort the display, and
        // louder-first is the right order for that. Nothing thresholds it.
        notes.add(TranscribedNote(
          e.midi,
          (e.velocity / 127).clamp(0.0, 1.0),
          e.onMs >= from ? 1.0 : 0.0,
        ));
      }
      notes.sort((a, b) => b.strength.compareTo(a.strength));
      stopwatch.stop();
      start.reply.send(TranscriptionResult(notes, stopwatch.elapsed));
    } catch (e) {
      start.reply.send(_WorkerError('$e'));
    }
  });
}
