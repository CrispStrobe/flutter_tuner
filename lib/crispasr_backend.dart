/// A second transcription runtime: the same Basic Pitch model through
/// CrispASR's ggml, over FFI.
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
/// **It is still not the default, and on most installs it will not be
/// available at all.** The `crispasr` package is pure Dart FFI and does not
/// bundle the native library: shipping this means a ~23 MB `libcrispasr` on
/// five platforms and no web build, to speed up a mode that already runs in
/// 324 ms on Apple Silicon and updates twice a second. So the backend loads
/// the library if the host happens to have one and reports
/// [isAvailable] false if not — which is the honest state for a tuner, and
/// leaves the door open for MT3 (96 MB, 46.9M parameters), where the speed
/// would actually decide whether the mode runs.
library;

export 'crispasr_backend_stub.dart'
    if (dart.library.ffi) 'crispasr_backend_ffi.dart';
