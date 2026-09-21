/// The FFI half of [CrispAsrBackend]'s conditional export. See
/// `crispasr_backend.dart` for the measurements and for why this is not the
/// default.
///
/// Rewritten after reading how CometBeat — the sibling project, same owner,
/// same `crispasr` package — wires the same runtime (`bench/REPORT.md` §25).
/// Three things came from that comparison:
///
///   * the GGUF is resolved through **CrispASR's own registry and cache**
///     rather than an environment variable pointing at a file the user had
///     to find. §17.1 called the old arrangement "unavailable unless
///     configured"; the honest description was a backend nobody could
///     reach.
///   * the native library is looked for where a **shipped app** would
///     actually put it, not only where a developer exports it.
///   * **nothing throws to say "not here"** — every unavailable path returns
///     null, so the caller falls through to pure Dart instead of catching.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';

import 'transcription.dart';
import 'transcription_backend.dart';

/// The note-event models CrispASR can run, all through one C entry point.
///
/// `crispasr_session_piano` serves basic-pitch, piano-transcription and MT3
/// alike — the parameter is still named `pcm_16k` after the first of them —
/// so supporting all three is a *choice of model*, not three code paths.
///
/// Measured on MusicNet's test split, note-level F1 by
/// `mir_eval.transcription`'s rules (`bench/REPORT.md` §32):
///
/// | model | F1 | onset err p50 | cost per second of audio | size |
/// | --- | --- | --- | --- | --- |
/// | `basic-pitch` | 44.2% | 21.4 ms | 0.08× | 110 KB |
/// | `piano-transcription` | 47.7% (**71.2% on solo piano**) | 19.1 ms | 7.77× | 77 MB |
/// | `mt3` | **76.5%** | **16.8 ms** | 0.26× | 96 MB |
///
/// MT3 is the one to reach for on real music: it finds three quarters of the
/// notes where Basic Pitch finds under half, it is the only multi-instrument
/// model of the three, and it still runs at a quarter of real time. Kong's
/// piano-transcription is stronger *on piano* than its aggregate suggests
/// and correctly declines on instruments it was not trained for — 9 notes
/// emitted for 551 references on solo violin.
enum CrispAsrModel {
  /// 110 KB. The same model the pure-Dart path runs, for comparing runtimes.
  basicPitch('basic-pitch', 22050),

  /// 77 MB. Kong / ByteDance high-resolution piano transcription.
  pianoTranscription('piano-transcription', 16000),

  /// 96 MB, 46.9M parameters. Multi-instrument, and the best score in this
  /// benchmark by a wide margin.
  mt3('mt3', 16000);

  /// The name CrispASR's registry and `CrispasrSession.open` both use.
  final String id;

  /// The rate the model expects. Queried from the session at startup anyway
  /// — this is only the default for sizing the capture window.
  final int nativeRate;

  const CrispAsrModel(this.id, this.nativeRate);

  String get displayName => switch (this) {
        CrispAsrModel.basicPitch => 'Basic Pitch',
        CrispAsrModel.pianoTranscription => 'Piano transcription',
        CrispAsrModel.mt3 => 'MT3 (multi-instrument)',
      };
}

/// Kept for callers that predate [CrispAsrModel].
const String kCrispAsrBackendName = 'basic-pitch';

/// Opt in with `CRISPTUNER_TRANSCRIPTION_BACKEND=crispasr`.
///
/// Deliberately a *choice*, not a capability probe. Once the model downloads
/// itself this backend is available on any machine with libcrispasr, and
/// §18.2 is the reason that must not make it the default: its speed
/// advantage is real, its accuracy advantage turned out to be its decoder,
/// and that decoder now ships in pure Dart. Availability decides whether the
/// option can be offered; it must not decide that it is taken.
const String kBackendEnv = 'CRISPTUNER_TRANSCRIPTION_BACKEND';

/// Overrides, for development. Neither is needed any more.
const String kLibEnv = 'CRISPTUNER_CRISPASR_LIB';
const String kModelEnv = 'CRISPTUNER_BASIC_PITCH_GGUF';

/// Which model the CrispASR backend should run: `basic-pitch`,
/// `piano-transcription` or `mt3`. Unset or unrecognised means basic-pitch,
/// the one that needs no download.
const String kModelNameEnv = 'CRISPTUNER_CRISPASR_MODEL';

/// Parse [kModelNameEnv], tolerantly. An unknown name falls back rather than
/// throwing: this reads an environment variable, and a typo should not take
/// the transcription mode down with it.
CrispAsrModel crispAsrModelFromName(String? name) {
  final n = (name ?? '').trim().toLowerCase();
  for (final m in CrispAsrModel.values) {
    if (m.id == n) return m;
  }
  return switch (n) {
    'piano' || 'kong' => CrispAsrModel.pianoTranscription,
    'mt3' => CrispAsrModel.mt3,
    _ => CrispAsrModel.basicPitch,
  };
}

/// Where libcrispasr might be, in the order worth trying.
///
/// The `Frameworks/` case is the one that matters and the one the previous
/// version lacked: it is where a built macOS app keeps its dylibs, so it is
/// the only entry here that describes a shipped app rather than a developer's
/// shell. Taken from CometBeat, which ships this way.
String crispAsrLibPath() {
  final override = Platform.environment[kLibEnv];
  if (override != null && override.isNotEmpty) return override;

  if (Platform.isMacOS) {
    try {
      final macos = File(Platform.resolvedExecutable).parent; // Contents/MacOS
      final bundled = '${macos.parent.path}/Frameworks/libcrispasr.dylib';
      if (File(bundled).existsSync()) return bundled;
    } catch (_) {
      // Fall through: resolvedExecutable can throw in odd hosts.
    }
  }

  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    final drop = '$home/.cache/crispasr/libcrispasr.$suffix';
    if (File(drop).existsSync()) return drop;
  }

  return CrispASR.defaultLibName();
}

/// Basic Pitch through CrispASR's ggml runtime.
class CrispAsrBackend implements TranscriptionBackend {
  /// Explicit library path, or null to use [crispAsrLibPath].
  final String? libraryPath;

  /// Explicit GGUF path, or null to resolve it through CrispASR's registry.
  final String? modelPath;

  /// Whether the model may be fetched if it is not already cached. The
  /// download happens on the worker isolate, never on the UI thread.
  final bool allowDownload;

  /// Which model to run. Defaults to the smallest, because it is the one
  /// that needs no download.
  final CrispAsrModel model;

  CrispAsrBackend(
      {this.libraryPath,
      this.modelPath,
      this.allowDownload = true,
      this.model = CrispAsrModel.basicPitch});

  /// The backend when the user has opted in, or **null** — never a throw.
  static CrispAsrBackend? fromEnvironment() {
    final env = Platform.environment;
    final chosen = (env[kBackendEnv] ?? '').toLowerCase();
    final model = env[kModelEnv];
    // An explicit model path is itself an opt-in, so the old arrangement
    // keeps working for anyone already using it.
    if (chosen != 'crispasr' && (model == null || model.isEmpty)) return null;
    final backend = CrispAsrBackend(
      libraryPath: _nullIfEmpty(env[kLibEnv]),
      modelPath: _nullIfEmpty(model),
      model: crispAsrModelFromName(env[kModelNameEnv]),
    );
    return backend.isAvailable ? backend : null;
  }

  static String? _nullIfEmpty(String? s) =>
      (s == null || s.isEmpty) ? null : s;

  @override
  String get id => '${model.id}-crispasr';

  @override
  String get displayName => '${model.displayName} (CrispASR/ggml)';

  bool? _available;

  /// Whether the native library loads *and* this build of it knows about
  /// basic-pitch. Cached: the answer cannot change within a run, and a
  /// settings list may ask repeatedly.
  ///
  /// Does not require the model to be present — that is [start]'s job, and
  /// making it a precondition here is what made the old version unreachable.
  @override
  bool get isAvailable => _available ??= _probe();

  bool _probe() {
    try {
      final lib = DynamicLibrary.open(libraryPath ?? crispAsrLibPath());
      if (modelPath != null) return File(modelPath!).existsSync();
      return registryLookup(model.id, lib: lib) != null;
    } catch (_) {
      return false;
    }
  }

  /// The capture path decimates to 22.05 kHz for every model; a model that
  /// wants 16 kHz is resampled on the worker isolate rather than forcing a
  /// second decimation chain into the audio thread.
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
        _WorkerStart(_fromWorker!.sendPort, libraryPath ?? crispAsrLibPath(),
            modelPath, allowDownload, model.id),
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
  final String libPath;
  final String? modelPath;
  final bool allowDownload;
  final String backend;
  const _WorkerStart(this.reply, this.libPath, this.modelPath,
      this.allowDownload, this.backend);
}

class _WorkerError {
  final String message;
  const _WorkerError(this.message);
}

/// The same span the ONNX decoder averages — 8 frames of 256 samples at
/// 22050 Hz, 93 ms — so both backends describe the same instant.
const double _tailSeconds =
    BasicPitchDecoder.defaultTailFrames * BasicPitchGeometry.frameHop /
        BasicPitchGeometry.sampleRate;

/// Find the GGUF: an explicit path, else CrispASR's cache, else download it
/// if allowed. Returns null rather than throwing, at every step.
///
/// Runs on the worker isolate because the download is blocking network I/O
/// and the model is only ~110 KB but the principle is the point.
String? _resolveModel(DynamicLibrary lib, String? explicit,
    bool allowDownload, String backend) {
  if (explicit != null && explicit.isNotEmpty) {
    return File(explicit).existsSync() ? explicit : null;
  }
  final entry = registryLookup(backend, lib: lib);
  if (entry == null) return null; // this build has no basic-pitch registered
  final dir = cacheDir(lib: lib);
  if (dir != null) {
    final cached = File('$dir/${entry.filename}');
    if (cached.existsSync() && cached.lengthSync() > 0) return cached.path;
  }
  if (!allowDownload) return null;
  return cacheEnsureFile(entry.filename, entry.url, quiet: true, lib: lib);
}

void _workerMain(_WorkerStart start) {
  final inbox = ReceivePort();
  CrispasrSession? session;
  int rate = BasicPitchGeometry.sampleRate;

  try {
    final lib = DynamicLibrary.open(start.libPath);
    final model = _resolveModel(
        lib, start.modelPath, start.allowDownload, start.backend);
    if (model == null) {
      start.reply.send(_WorkerError(
          'no ${start.backend} GGUF: not cached and not downloadable'));
      inbox.close();
      return;
    }
    session = CrispasrSession.open(model,
        libPath: start.libPath, backend: start.backend, nThreads: 2);
    // Ask, do not assume: a future GGUF at another rate would otherwise be
    // fed audio at the wrong speed and transpose every note silently.
    final wanted = session.pianoSampleRate;
    if (wanted > 0) rate = wanted;
  } catch (e) {
    session?.close();
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
      // The capture path always delivers 22.05 kHz. basic-pitch wants that;
      // piano-transcription and MT3 want 16 kHz, so they are resampled here
      // rather than forcing a second decimation chain onto the audio thread.
      // Linear is adequate downsampling a band-limited signal by 0.73.
      final Float32List pcm;
      if (rate == BasicPitchGeometry.sampleRate) {
        pcm = Float32List(message.length);
        for (int i = 0; i < pcm.length; i++) {
          pcm[i] = message[i];
        }
      } else {
        final ratio = BasicPitchGeometry.sampleRate / rate;
        pcm = Float32List((message.length / ratio).floor());
        for (int i = 0; i < pcm.length; i++) {
          final x = i * ratio;
          final j = x.floor();
          final t = x - j;
          final a = message[j];
          final b = j + 1 < message.length ? message[j + 1] : a;
          pcm[i] = a + (b - a) * t;
        }
      }
      final events = session!.pianoNotes(pcm);
      final windowMs = 1000.0 * pcm.length / rate;
      final from = windowMs - _tailSeconds * 1000;

      final notes = <TranscribedNote>[];
      for (final e in events) {
        if (e.offMs < from || e.onMs > windowMs) continue;
        // `velocity` is the model's loudness estimate, not a confidence —
        // the CrispASR docs say so explicitly. It sorts the display and
        // nothing thresholds it.
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
