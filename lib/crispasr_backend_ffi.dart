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
/// `crispasr_session_piano` serves all five alike — the parameter is still
/// named `pcm_16k` after the first of them — so supporting another model is
/// a *choice of model*, not another code path.
///
/// Measured on MusicNet's test split, note-level F1 by
/// `mir_eval.transcription`'s rules (`bench/REPORT.md` §32, §36.4, §37):
///
/// | model | F1 | solo piano F1 | cost per second of audio | download |
/// | --- | --- | --- | --- | --- |
/// | `basic-pitch` | 44.2% | — | 0.08× | 110 KB |
/// | `piano-transcription` | 47.7% | **71.2%** | 7.77× | 77 MB |
/// | `mt3` | **76.5%** | — | 0.26× | 96 MB |
/// | `onsets-and-frames` | 49.6% | 69.0% | 0.44× | **30.8 MiB** |
/// | `hft-transformer` | 52.2% | **70.7%** | 2.14× | **4.5 MiB** |
///
/// Onset error p50, where it was measured: 21.4 ms for basic-pitch, 19.1 ms
/// for piano-transcription, 16.8 ms for MT3.
///
/// Which to reach for:
///
///   * **MT3 for real music.** 76.5% F1, the only multi-instrument model
///     here, and still a quarter of real time. It finds three quarters of
///     the notes where Basic Pitch finds under half.
///   * **Onsets & Frames for piano.** 69.0% solo-piano F1 for 30.8 MiB and
///     0.44× real time — CrispASR's recommended piano arm, and the balance
///     of the five.
///   * **hFT-Transformer when size matters most.** The best solo-piano score
///     here, 70.7%, out of 4.5 MiB of q4_0 weights — the most accuracy per
///     megabyte of the five. On a physical M1 it runs at 0.30× real time on
///     Metal and 0.76× on the CPU at this app's two threads (CrispASR
///     `PIANO_METAL_AB.md` §8); **on a phone or tablet it is not known**.
///     See [realTimeFactor] for what the 2.14× is and is not evidence of.
///   * **Basic Pitch for comparing runtimes**, which is what it is here for:
///     it is the same model the pure-Dart path runs.
///
/// Kong's piano-transcription is stronger *on piano* than its aggregate
/// suggests and correctly declines on instruments it was not trained for —
/// 9 notes emitted for 551 references on solo violin.
///
/// Every cost above is CPU seconds per audio second on **four shared vCPUs
/// of a contended Linux VPS**, CPU only. None of it has been measured on a
/// phone, a tablet or a Mac; nothing in this project has. Treat the column
/// as a ranking, not as a latency budget — and see [realTimeFactor].
enum CrispAsrModel {
  /// 110 KB. The same model the pure-Dart path runs, so it is what to pick
  /// when the question is about the *runtime* rather than the model.
  basicPitch('basic-pitch', 22050, downloadMiB: 0.11, realTimeFactor: 0.08),

  /// 77 MB. Kong / ByteDance high-resolution piano transcription: 71.2% F1
  /// on solo piano, and 7.77× real time — the most expensive of the five.
  pianoTranscription('piano-transcription', 16000,
      downloadMiB: 77, realTimeFactor: 7.77),

  /// 96 MB, 46.9M parameters. Multi-instrument, and the best score in this
  /// benchmark by a wide margin: 76.5% F1 at 0.26× real time. For real
  /// music rather than for piano alone.
  mt3('mt3', 16000, downloadMiB: 96, realTimeFactor: 0.26),

  /// 30.8 MiB at q8_0 (Hawthorne et al. 2018). 49.6% F1 overall, **69.0% on
  /// solo piano**, 0.44× real time — CrispASR's recommended piano arm, and
  /// the one that balances the three. q8_0 is F1-identical to fp32 on every
  /// column (`bench/REPORT.md` §36.4).
  onsetsAndFrames('onsets-and-frames', 16000,
      downloadMiB: 30.8, realTimeFactor: 0.44),

  /// 4.5 MiB at q4_0 (Toyama et al., ISMIR 2023). The best solo-piano score
  /// measured here, **70.7%** (52.2% overall), out of less weight than a
  /// photograph: the most accuracy per megabyte of the five. Its cost is set
  /// by its sequence length rather than its parameter count (§36.2). On a
  /// physical M1 that is 0.30× real time on Metal and 0.76× on two CPU
  /// threads; on a phone or tablet it is **not known** — see
  /// [realTimeFactor].
  hftTransformer('hft-transformer', 16000,
      downloadMiB: 4.5, realTimeFactor: 2.14);

  /// The name CrispASR's registry and `CrispasrSession.open` both use.
  final String id;

  /// The rate the model expects. Queried from the session at startup anyway
  /// — this is only the default for sizing the capture window.
  final int nativeRate;

  /// How much the GGUF weighs, in MiB. It is a **download**: CrispASR
  /// fetches it from HuggingFace into its own cache the first time the model
  /// is selected, and nothing here is bundled with the app.
  final double downloadMiB;

  /// CPU seconds per second of audio on **four shared vCPUs of a contended
  /// Linux VPS, CPU only** (`bench/REPORT.md` §36.4, §37).
  ///
  /// Read this as a ranking of the five against each other, not as a
  /// prediction of what any of them costs on a user's device. Two reasons,
  /// both concrete:
  ///
  ///   * the machine. Skylake-SP vCPUs shared with other tenants, measured
  ///     under load average 3–20. The only other measurements are on Apple
  ///     Silicon Macs (CrispASR `PIANO_METAL_AB.md` §4, §8); nothing has
  ///     run on a phone or a tablet.
  ///   * the build. When these were measured, `onsets_and_frames.cpp` and
  ///     `hft_transformer.cpp` were CPU-only. CrispASR has since wired both
  ///     through `crispasr_init_gpu_backend()`, and a session opens with
  ///     `use_gpu` on, so a Metal-built libcrispasr that contains that
  ///     change runs them on the GPU with no change here. On a physical M1
  ///     that made hFT 2.4–4.4× faster than two CPU threads and O&F about
  ///     1.45× (CrispASR `PIANO_METAL_AB.md` §8), so a CPU figure is a
  ///     floor on Apple Silicon, not a property of the model.
  ///
  /// So no UI string should be derived from this by arithmetic. What the
  /// picker says about a model's speed is written per model, in one place,
  /// in `lib/main.dart`, and is to be updated when a measurement on real
  /// target hardware lands rather than inferred from this number.
  final double realTimeFactor;

  const CrispAsrModel(this.id, this.nativeRate,
      {required this.downloadMiB, required this.realTimeFactor});

  String get displayName => switch (this) {
        CrispAsrModel.basicPitch => 'Basic Pitch',
        CrispAsrModel.pianoTranscription => 'Piano transcription',
        CrispAsrModel.mt3 => 'MT3 (multi-instrument)',
        CrispAsrModel.onsetsAndFrames => 'Onsets & Frames (piano)',
        CrispAsrModel.hftTransformer => 'hFT-Transformer (piano)',
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

/// Which model the CrispASR backend should run, by registry id:
/// `basic-pitch`, `piano-transcription`, `mt3`, `onsets-and-frames` or
/// `hft-transformer`. Unset or unrecognised means basic-pitch, the smallest.
///
/// This variable and [kBackendEnv] together **override the setting the user
/// picked in the app** — that precedence is deliberate and is how CI and
/// `bench/` select a backend without touching stored preferences. See
/// `lib/main.dart`, where it is applied.
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
    'onsets_and_frames' || 'oaf' => CrispAsrModel.onsetsAndFrames,
    'hft_transformer' || 'hft' => CrispAsrModel.hftTransformer,
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
      // pianoNotesWithPrograms rather than pianoNotes: MT3's whole advantage
      // is that it says WHICH instrument played each note, and until crispasr
      // 0.8.35 that was discarded at the C ABI. Against an older library, or
      // a model that identifies no instrument, every program is -1 — the call
      // degrades rather than needing a capability probe.
      final events = session!.pianoNotesWithPrograms(pcm);
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
          program: e.program,
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
