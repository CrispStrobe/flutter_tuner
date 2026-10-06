/// The browser half of [CrispAsrBackend]'s conditional export: the same five
/// models, run by CrispASR's WebAssembly build in a worker.
///
/// `package:crispasr` imports `dart:ffi` unconditionally, so it cannot be
/// reached from a web entry point; this file talks to
/// `web/crispasr/worker.js` instead, which loads `libwhisper.wasm` and calls
/// the `sessionPianoNotes` binding — the WebAssembly face of the same
/// `crispasr_session_piano*` C ABI the FFI half uses. Audio goes in and
/// note events come out in the same shapes, through the same helpers
/// (`crispasr_notes.dart`), so the two runtimes describe the same instant.
///
/// A worker, not the page: the build is single-threaded (no
/// SharedArrayBuffer, so no COOP/COEP headers to impose on the whole site),
/// and an inference run on the page's own thread would freeze the needle
/// for as long as it took.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'crispasr_model.dart';
import 'crispasr_notes.dart';
import 'transcription.dart';
import 'transcription_backend.dart';

/// Names kept identical to the FFI half so callers and tests compile
/// against either without conditionals of their own.
const String kCrispAsrBackendName = 'basic-pitch';
const String kModelNameEnv = 'CRISPTUNER_CRISPASR_MODEL';
const String kBackendEnv = 'CRISPTUNER_TRANSCRIPTION_BACKEND';
const String kLibEnv = 'CRISPTUNER_CRISPASR_LIB';
const String kModelEnv = 'CRISPTUNER_BASIC_PITCH_GGUF';

/// Whether this web build ships the WebAssembly engine. Set by the build
/// (`--dart-define=CRISPTUNER_CRISPASR_WASM=true`) only when
/// `tool/crispasr/build_wasm.sh` put `libwhisper.wasm` under
/// `web/crispasr/`, so a build without it says the models are unavailable
/// rather than offering them and failing to start.
const bool kCrispAsrWasmBundled =
    bool.fromEnvironment('CRISPTUNER_CRISPASR_WASM');

class CrispAsrBackend implements TranscriptionBackend {
  /// The model's cache key — its pinned URL, as `ModelStore.location`
  /// returns it. Null means "look it up": the worker finds it by
  /// [model]'s URL either way.
  final String? modelPath;

  final CrispAsrModel model;

  CrispAsrBackend(
      {String? libraryPath,
      this.modelPath,
      bool allowDownload = true,
      this.model = CrispAsrModel.basicPitch});

  /// Always null: there is no environment in a browser, and an unavailable
  /// backend is a fall-through, not an error.
  static CrispAsrBackend? fromEnvironment() => null;

  @override
  String get id => '${model.id}-crispasr';

  @override
  String get displayName => '${model.displayName} (CrispASR/WebAssembly)';

  @override
  bool get isAvailable => kCrispAsrWasmBundled;

  @override
  int get inputSampleRate => BasicPitchGeometry.sampleRate;

  @override
  int get windowSamples => BasicPitchGeometry.windowSamples;

  web.Worker? _worker;
  int _rate = 0;
  int _nextId = 0;
  Completer<Object?>? _opening;
  final Map<int, (Completer<TranscriptionResult>, double)> _inFlight = {};
  Completer<TranscriptionResult>? _pending;

  @override
  bool get isRunning => _rate > 0;

  @override
  Future<void> start() async {
    if (_rate > 0 || _opening != null) return;
    if (!isAvailable) {
      throw StateError('this build does not include CrispASR WebAssembly');
    }
    final opening = _opening = Completer<Object?>();
    final worker = _worker = web.Worker('crispasr/worker.js'.toJS);
    worker.onmessage = ((web.MessageEvent event) => _onMessage(event)).toJS;
    worker.onerror = ((web.Event event) {
      final message = event is web.ErrorEvent ? event.message : 'worker failed';
      _fail(message);
    }).toJS;
    worker.postMessage({
      'type': 'open',
      'url': modelPath ?? model.file.url.toString(),
      'name': model.file.name,
      'backend': model.id,
    }.jsify());
    try {
      final answer = await opening.future;
      _rate = (answer as num).toInt();
    } catch (_) {
      await stop();
      rethrow;
    } finally {
      _opening = null;
    }
  }

  void _onMessage(web.MessageEvent event) {
    final data = (event.data as JSObject?).dartify() as Map?;
    if (data == null) return;
    switch (data['type']) {
      case 'opened':
        _opening?.complete(data['rate']);
      case 'result':
        final entry = _inFlight.remove((data['id'] as num).toInt());
        if (entry == null) return;
        final (completer, windowMs) = entry;
        final events = [
          for (final e in (data['notes'] as List? ?? const []))
            NoteEvent(
              (e['onMs'] as num).toDouble(),
              (e['offMs'] as num).toDouble(),
              (e['midi'] as num).toInt(),
              (e['velocity'] as num).toInt(),
              (e['program'] as num? ?? -1).toInt(),
            ),
        ];
        _pending = null;
        completer.complete(TranscriptionResult(
          notesInTail(events, windowMs),
          Duration(microseconds: ((data['ms'] as num) * 1000).round()),
        ));
      case 'error':
        _fail('${data['message']}', id: (data['id'] as num?)?.toInt());
    }
  }

  void _fail(String message, {int? id}) {
    final error = StateError(message);
    final opening = _opening;
    if (opening != null && !opening.isCompleted) {
      opening.completeError(error);
      return;
    }
    final failed = id == null
        ? _inFlight.values.toList()
        : [if (_inFlight[id] case final entry?) entry];
    if (id == null) {
      _inFlight.clear();
    } else {
      _inFlight.remove(id);
    }
    _pending = null;
    for (final (completer, _) in failed) {
      completer.completeError(error);
    }
  }

  @override
  Future<TranscriptionResult>? transcribe(Float64List window) {
    final worker = _worker;
    if (worker == null || _rate <= 0 || _pending != null) return null;
    final pcm = toModelRate(window, _rate);
    final id = _nextId++;
    final completer = Completer<TranscriptionResult>();
    _pending = completer;
    _inFlight[id] = (completer, 1000.0 * pcm.length / _rate);
    final message = JSObject()
      ..setProperty('type'.toJS, 'transcribe'.toJS)
      ..setProperty('id'.toJS, id.toJS)
      ..setProperty('pcm'.toJS, pcm.toJS);
    // Copied, not transferred: two seconds of audio is ~170 KB, and under
    // dart2wasm `toJS` has already made the copy a transfer would avoid.
    worker.postMessage(message);
    return completer.future;
  }

  @override
  Future<void> stop() async {
    final worker = _worker;
    _worker = null;
    _rate = 0;
    if (worker != null) {
      worker.postMessage({'type': 'close'}.jsify());
      worker.terminate();
    }
    // Dropped, not failed — as the FFI half does. A failed window reads to
    // the caller as "the mode broke", and stopping is not that.
    _inFlight.clear();
    _pending = null;
    final opening = _opening;
    if (opening != null && !opening.isCompleted) {
      opening.completeError(StateError('stopped'));
    }
  }
}
