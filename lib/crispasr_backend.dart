/// A second transcription runtime: CrispASR's ggml, over FFI on native
/// platforms and as WebAssembly in the browser — and with it four models
/// the pure-Dart path cannot run.
///
/// `transcription_backend.dart` predicted what this would cost and what it
/// would buy; `bench/bin/runtime_compare.dart` measured both on GuitarSet's
/// chordal recordings, 8 files, one thread each so the comparison is of
/// runtimes and not of core counts (`bench/REPORT.md` §17):
///
/// | | precision | recall | F1 | per 2 s window |
/// | --- | --- | --- | --- | --- |
/// | pure Dart (ONNX) | 88.2% | 67.2% | 76.2% | 624 ms |
/// | CrispASR (ggml) | 84.4% | 75.6% | **79.7%** | **345 ms** |
///
/// The two agree about *what is playing* almost exactly — over those files
/// they name the same set of pitches, 100% on five of eight and never below
/// 83% — so this is one model, faithfully run twice. ggml is 1.8× faster and
/// trades 3.8 points of precision for 8.4 of recall, because it emits
/// segmented note events rather than per-frame activations and a note event
/// bridges the frames where activation dips below threshold.
///
/// **It is still not the default**, and the reason is unchanged: §18 ported
/// the decoder advantage into pure Dart, and the built-in path needs neither
/// a native library nor a download. What CrispASR adds is the *other four
/// models* — MT3 above all — and those are a choice the user makes in
/// settings, with the download size in front of them.
///
/// How the library reaches each platform (`tool/crispasr/`, and the release
/// workflows that call it):
///
///   * iOS and macOS embed `crispasr.framework` from CrispASR's release
///     xcframework, through a local CocoaPods pod.
///   * Android, Linux and Windows build `libcrispasr` from the same pinned
///     CrispASR release, because its release archives carry no shared
///     library for desktop and a 4 KB-aligned one for Android, which Google
///     Play no longer accepts.
///   * The web build compiles CrispASR to single-threaded WebAssembly with
///     one added binding, `sessionPianoNotes`
///     (`tool/crispasr/wasm-piano-notes.patch`), and runs it in a worker.
///
/// A build made without that step — a plain `flutter run` — still works:
/// the backend reports itself unavailable and the picker says so.
///
/// Selection by environment variable
/// (`CRISPTUNER_TRANSCRIPTION_BACKEND=crispasr`) still overrides the
/// setting; that is how CI and `bench/` pick a backend without touching
/// stored preferences.
library;

export 'crispasr_model.dart';
export 'crispasr_backend_web.dart'
    if (dart.library.ffi) 'crispasr_backend_ffi.dart';
