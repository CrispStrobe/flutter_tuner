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

import 'crispasr_model.dart';
import 'crispasr_notes.dart';
import 'transcription.dart';
import 'transcription_backend.dart';

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

/// Which model the CrispASR backend should run, by registry id:
/// `basic-pitch`, `piano-transcription`, `mt3`, `onsets-and-frames` or
/// `hft-transformer`. Unset or unrecognised means basic-pitch, the smallest.
///
/// This variable and [kBackendEnv] together **override the setting the user
/// picked in the app** — that precedence is deliberate and is how CI and
/// `bench/` select a backend without touching stored preferences. See
/// `lib/main.dart`, where it is applied.
const String kModelNameEnv = 'CRISPTUNER_CRISPASR_MODEL';

/// Where libcrispasr might be, in the order worth trying.
///
/// The bundled locations come first because they are the only entries that
/// describe a *shipped* app rather than a developer's shell, and each is an
/// absolute path: what `dlopen` does with a bare name differs per platform,
/// and on Linux it does not consult the executable's `$ORIGIN/lib` RUNPATH
/// at all when the call comes from the Flutter engine rather than from the
/// executable. Where each one comes from:
///
///   * iOS, macOS — `crispasr.framework`, embedded from CrispASR's release
///     xcframework by the `crispasr` pod (`ios/`, `macos/`
///     `crispasr.podspec`). macOS also keeps the older loose-dylib layout
///     CometBeat ships, for a developer build that copied one in.
///   * Linux — `bundle/lib/libcrispasr.so`, installed by
///     `linux/CMakeLists.txt`.
///   * Windows — `crispasr.dll` next to the executable, installed by
///     `windows/CMakeLists.txt`.
///   * Android — `libcrispasr.so` from `jniLibs/`. The bare name is right
///     there: the app's linker namespace already searches its own native
///     library directory, and there is no absolute path to give.
String crispAsrLibPath() {
  final override = Platform.environment[kLibEnv];
  if (override != null && override.isNotEmpty) return override;

  for (final candidate in _bundledLibCandidates()) {
    if (File(candidate).existsSync()) return candidate;
  }

  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    final drop = '$home/.cache/crispasr/libcrispasr.$suffix';
    if (File(drop).existsSync()) return drop;
  }

  return CrispASR.defaultLibName();
}

List<String> _bundledLibCandidates() {
  final String exeDir;
  try {
    exeDir = File(Platform.resolvedExecutable).parent.path;
  } catch (_) {
    return const []; // resolvedExecutable can throw in odd hosts.
  }
  final sep = Platform.pathSeparator;
  if (Platform.isIOS) {
    // Runner.app/Runner → Runner.app/Frameworks/
    return ['$exeDir/Frameworks/crispasr.framework/crispasr'];
  }
  if (Platform.isMacOS) {
    // Contents/MacOS/CrispTuner → Contents/Frameworks/
    final frameworks = '${File(exeDir).parent.path}/Frameworks';
    return [
      '$frameworks/crispasr.framework/crispasr',
      '$frameworks/libcrispasr.dylib',
    ];
  }
  if (Platform.isLinux) return ['$exeDir/lib/libcrispasr.so'];
  if (Platform.isWindows) return ['$exeDir${sep}crispasr.dll'];
  return const [];
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

  /// Whether the native library loads, exports the note ABI this file
  /// calls, and knows about [model]. Cached: the answer cannot change within
  /// a run, and a settings list may ask repeatedly.
  ///
  /// Does not require the model to be present — that is [start]'s job, and
  /// making it a precondition here is what made the old version unreachable.
  @override
  bool get isAvailable => _available ??= _probe();

  bool _probe() {
    try {
      final lib = DynamicLibrary.open(libraryPath ?? crispAsrLibPath());
      // A libcrispasr older than 0.8.35 loads fine and then fails on the
      // first window; asking for the symbol up front turns that into "not
      // available" instead.
      if (!lib.providesSymbol('crispasr_session_piano_note_programs')) {
        return false;
      }
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
    // 0 is the sentinel for "this backend has no piano arm" (§17.2) — it is
    // a capability probe that never throws, so an unchecked read turns a
    // wrong model into a silent per-window failure later instead of a clear
    // one now. An earlier version of this file threw when the rate did not
    // match; generalising to three models dropped that check, and this is it
    // restored in the form the three models actually need.
    final wanted = session.pianoSampleRate;
    if (wanted <= 0) {
      throw StateError('${start.backend} reports no piano arm in this '
          'libcrispasr build (pianoSampleRate == 0)');
    }
    rate = wanted;
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
      final pcm = toModelRate(message, rate);
      // pianoNotesWithPrograms rather than pianoNotes: MT3's whole advantage
      // is that it says WHICH instrument played each note, and until crispasr
      // 0.8.35 that was discarded at the C ABI. Against an older library, or
      // a model that identifies no instrument, every program is -1 — the call
      // degrades rather than needing a capability probe.
      final events = session!.pianoNotesWithPrograms(pcm);
      final notes = notesInTail(
          [
            for (final e in events)
              NoteEvent(e.onMs, e.offMs, e.midi, e.velocity, e.program)
          ],
          1000.0 * pcm.length / rate);
      stopwatch.stop();
      start.reply.send(TranscriptionResult(notes, stopwatch.elapsed));
    } catch (e) {
      start.reply.send(_WorkerError('$e'));
    }
  });
}
