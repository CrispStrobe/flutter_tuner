/// The five note-transcription models CrispASR can run, and where each one's
/// weights come from.
///
/// One enum for every platform. It used to be declared twice — once in each
/// half of `crispasr_backend.dart`'s conditional export — with a comment
/// asking that the two be kept in step by hand. Nothing here needs `dart:ffi`
/// or `dart:io`, so there is no reason for a second copy.
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
///     megabyte of the five. **Its speed on the devices this app ships to
///     is not known**; see [realTimeFactor] for what the 2.14× is and is
///     not evidence of.
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
library;

enum CrispAsrModel {
  /// 110 KB. The same model the pure-Dart path runs, so it is what to pick
  /// when the question is about the *runtime* rather than the model.
  basicPitch('basic-pitch', 22050,
      downloadMiB: 0.11,
      realTimeFactor: 0.08,
      file: ModelFile(
        repo: 'cstr/basic-pitch-GGUF',
        revision: '49d4c2ef90d56b3fc4ab764cfbcd0b9f77a3cfbf',
        name: 'basic-pitch-f16.gguf',
        bytes: 112160,
        sha256:
            '1bbef6c713af2c78ba0d0126ad4f6095421f20ae3e145f394b2131ff50b54cad',
      )),

  /// 77 MB. Kong / ByteDance high-resolution piano transcription: 71.2% F1
  /// on solo piano, and 7.77× real time — the most expensive of the five.
  pianoTranscription('piano-transcription', 16000,
      downloadMiB: 77,
      realTimeFactor: 7.77,
      file: ModelFile(
        repo: 'cstr/piano-transcription-GGUF',
        revision: '363db710d741c992a1232626101e25f6e8dfcb26',
        name: 'piano-transcription-f16.gguf',
        bytes: 77277792,
        sha256:
            '31f13dcd1b753cd5eebfac0ebc831e9b834dbb0e4d5b463a5291be481ce71fd9',
      )),

  /// 96 MB, 46.9M parameters. Multi-instrument, and the best score in this
  /// benchmark by a wide margin: 76.5% F1 at 0.26× real time. For real
  /// music rather than for piano alone.
  mt3('mt3', 16000,
      downloadMiB: 96,
      realTimeFactor: 0.26,
      file: ModelFile(
        repo: 'cstr/mt3-GGUF',
        revision: '4299d5f308dc7cababf86823f3e1afa0cbdafb91',
        name: 'mt3-f16.gguf',
        bytes: 96044864,
        sha256:
            '6d632edd4a21458ff22507a1651772f6cf7a2cabe8e7e236c1b0eac981556831',
      )),

  /// 30.8 MiB at q8_0 (Hawthorne et al. 2018). 49.6% F1 overall, **69.0% on
  /// solo piano**, 0.44× real time — CrispASR's recommended piano arm, and
  /// the one that balances the three. q8_0 is F1-identical to fp32 on every
  /// column (`bench/REPORT.md` §36.4).
  onsetsAndFrames('onsets-and-frames', 16000,
      downloadMiB: 30.8,
      realTimeFactor: 0.44,
      file: ModelFile(
        repo: 'cstr/onsets-and-frames-GGUF',
        revision: 'e19fdd5dab82f473624d0aaa0808ae80d2891261',
        name: 'onsets-and-frames-q8_0.gguf',
        bytes: 32244960,
        sha256:
            '8159b67a9280d4eacd50782b1784b450d36a8e3480f1ce1e10efacb6863929af',
      )),

  /// 4.5 MiB at q4_0 (Toyama et al., ISMIR 2023). The best solo-piano score
  /// measured here, **70.7%** (52.2% overall), out of less weight than a
  /// photograph: the most accuracy per megabyte of the five. Its cost is set
  /// by its sequence length rather than its parameter count (§36.2), and
  /// what that costs on a phone or a Mac is **not known** — see
  /// [realTimeFactor].
  hftTransformer('hft-transformer', 16000,
      downloadMiB: 4.5,
      realTimeFactor: 2.14,
      file: ModelFile(
        repo: 'cstr/hft-transformer-GGUF',
        revision: '17d72a2429f10579d590ae66b7db4985886c89be',
        name: 'hft-transformer-q4_0.gguf',
        bytes: 4681056,
        sha256:
            'c72a56b9ceaca3091b04ca48bb52e882bf2f44a8ce603bc9cb64224e0c987dc3',
      ));

  /// The name CrispASR's registry and `CrispasrSession.open` both use.
  final String id;

  /// The rate the model expects. Queried from the session at startup anyway
  /// — this is only the default for sizing the capture window.
  final int nativeRate;

  /// How much the GGUF weighs, in MiB, as shown in the picker. [file] has
  /// the exact byte count the download is checked against.
  final double downloadMiB;

  /// CPU seconds per second of audio on **four shared vCPUs of a contended
  /// Linux VPS, CPU only** (`bench/REPORT.md` §36.4, §37).
  ///
  /// Read this as a ranking of the five against each other, not as a
  /// prediction of what any of them costs on a user's device. Two reasons,
  /// both concrete:
  ///
  ///   * the machine. Skylake-SP vCPUs shared with other tenants, measured
  ///     under load average 3–20. Nothing in this project has run on a
  ///     phone, a tablet or a Mac.
  ///   * the build. `onsets_and_frames.cpp` and `hft_transformer.cpp` both
  ///     call `core_cpu_backend::init()` unconditionally and never read
  ///     their `use_gpu` parameter, so these two arms are CPU-only today
  ///     where CrispASR's other backends go through
  ///     `crispasr_init_gpu_backend()` (CUDA > Metal > Vulkan > CPU). hFT is
  ///     83.5% dense weight GEMM (§36.2) — exactly the arithmetic a GPU
  ///     backend exists for — so its number here is a floor on a path that
  ///     is being changed, not a property of the model.
  ///
  /// So no UI string should be derived from this by arithmetic. What the
  /// picker says about a model's speed is written per model, in one place,
  /// in `lib/main.dart`, and is to be updated when a measurement on real
  /// target hardware lands rather than inferred from this number.
  final double realTimeFactor;

  /// Where the weights are downloaded from, and how the download is checked.
  final ModelFile file;

  const CrispAsrModel(this.id, this.nativeRate,
      {required this.downloadMiB,
      required this.realTimeFactor,
      required this.file});

  String get displayName => switch (this) {
        CrispAsrModel.basicPitch => 'Basic Pitch',
        CrispAsrModel.pianoTranscription => 'Piano transcription',
        CrispAsrModel.mt3 => 'MT3 (multi-instrument)',
        CrispAsrModel.onsetsAndFrames => 'Onsets & Frames (piano)',
        CrispAsrModel.hftTransformer => 'hFT-Transformer (piano)',
      };
}

/// One GGUF on Hugging Face, pinned to a commit.
///
/// The file names match CrispASR's own registry (`crispasr_model_registry.cpp`
/// at v0.8.41), so a model cached by the CrispASR CLI and one downloaded by
/// this app are the same file. The URL is **not** taken from that registry
/// at run time, for two reasons: the web build has no FFI to ask it through,
/// and the registry points at `main`, so the bytes behind it can change
/// without the app changing. Pinning the revision and checking the SHA-256
/// (which is what Hugging Face reports as the LFS ETag) means a re-upload
/// upstream is a clear download failure here rather than a different model.
class ModelFile {
  final String repo;
  final String revision;
  final String name;
  final int bytes;
  final String sha256;

  const ModelFile({
    required this.repo,
    required this.revision,
    required this.name,
    required this.bytes,
    required this.sha256,
  });

  Uri get url =>
      Uri.parse('https://huggingface.co/$repo/resolve/$revision/$name');
}

/// Parse a model name, tolerantly. An unknown name falls back rather than
/// throwing: it usually comes from an environment variable, and a typo
/// should not take the transcription mode down with it.
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
