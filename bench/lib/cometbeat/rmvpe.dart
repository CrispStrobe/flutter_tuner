// lib/core/audio/transcription/rmvpe.dart
//
// RMVPE — robust neural monophonic F0 (MIT, RVC/lj1995 export) behind the
// `PitchTrack` contract. A heavier, more noise/vocal-robust alternative to
// CREPE. The model is a pure conv U-Net: 128-mel spectrogram → 360-bin pitch
// salience (the same representation CREPE emits). Runs on `onnx_runtime_dart`.
//
// Pipeline: resample→16 kHz → log-mel (see `rmvpe_mel.dart`, validated vs the
// RVC MelSpectrogram) → pad frames to a multiple of 32 (the U-Net's stride) →
// model → crop → RMVPE `to_local_average_cents` decode → [PitchTrack].
//
// WEB-SAFE: takes a preloaded [OnnxModel] + [RmvpeMel] bytes; model/asset
// download (dart:io, ~361 MB) lives in the native `rmvpe_model_store.dart`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'resample.dart';
import 'contracts.dart';
import 'f0_viterbi.dart';
import 'rmvpe_mel.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';

const int _nBins = 360;
const double _centsBase = 1997.3794084376191; // == CREPE (20 cents/bin)
const String _inName = 'input';
const String _outName = 'output';

/// Neural monophonic F0 with RMVPE. Resamples [mono] to 16 kHz, computes the
/// log-mel, runs the [model], and decodes each frame to F0 + voicing → a
/// [PitchTrack]. [thred] gates a frame unvoiced (`f0Hz == 0`) when the peak
/// salience is below it (RMVPE default 0.03). Pure / synchronous / web-safe.
PitchTrack rmvpeF0(
  Float64List mono, {
  required OnnxModel model,
  required RmvpeMel mel,
  int sampleRate = 44100,
  double thred = 0.03,
  bool viterbi = false,
}) =>
    rmvpeF0WithRunner(
      mono,
      mel: mel,
      sampleRate: sampleRate,
      thred: thred,
      viterbi: viterbi,
      run: (input, nMels, pf) {
        final out = model.run(
          {
            _inName: Tensor.float(input, [1, nMels, pf]),
          },
          const [_outName],
        )[_outName]!;
        return out.f ?? out.asFloatList();
      },
    );

/// Runs the U-Net on a `[1, nMels, pf]` log-mel input and returns the flat
/// `[1·pf·360]` salience. The ONLY model-runtime coupling in the RMVPE chain —
/// supply a runner backed by `onnx_runtime_dart` (the default via [rmvpeF0]) OR
/// native ORT (the `onnxFfi` backend); the identical mel/pad/decode runs either
/// way. Mirrors CREPE's `CrepeActivationRunner`.
typedef RmvpeSalienceRunner = Float32List Function(
  Float32List input,
  int nMels,
  int pf,
);

/// [rmvpeF0] with the model runtime abstracted behind [run] — same mel,
/// frame-padding, and `to_local_average_cents` decode, only the inference call
/// differs (so pure-Dart and native-ORT stay bit-for-bit identical apart from
/// the backend).
PitchTrack rmvpeF0WithRunner(
  Float64List mono, {
  required RmvpeMel mel,
  required RmvpeSalienceRunner run,
  int sampleRate = 44100,
  double thred = 0.03,
  bool viterbi = false,
}) {
  final p = _prepMel(mono, mel, sampleRate);
  if (p == null) return const [];
  final sal = run(p.input, mel.nMels, p.pf);
  return _decodeSalience(sal, p.nFrames, mel, thred, viterbi: viterbi);
}

/// Isolate-pool variant of [rmvpeF0]: identical mel / pad / decode, but
/// inference goes through [OnnxModel.runAsync] so a [OnnxModel.parallelize]d
/// model runs its Conv on the worker pool. RMVPE is ~80% Conv, so this is the
/// speed lever (~1.7× measured); output stays bitwise identical. Selected by the
/// store's env-gated `estimator()`.
Future<PitchTrack> rmvpeF0Async(
  Float64List mono, {
  required OnnxModel model,
  required RmvpeMel mel,
  int sampleRate = 44100,
  double thred = 0.03,
  bool viterbi = false,
}) async {
  final p = _prepMel(mono, mel, sampleRate);
  if (p == null) return const [];
  final out = await model.runAsync(
    {
      _inName: Tensor.float(p.input, [1, mel.nMels, p.pf]),
    },
    const [_outName],
  );
  final sal = out[_outName]!.f ?? out[_outName]!.asFloatList();
  return _decodeSalience(sal, p.nFrames, mel, thred, viterbi: viterbi);
}

/// Resample→16 kHz, log-mel, and frame-pad to a multiple of 32 (the U-Net
/// downsamples by 2^5). Returns the model input `[1, nMels, pf]` flattened plus
/// the true `nFrames`; null when the audio is empty.
({Float32List input, int nFrames, int pf})? _prepMel(
  Float64List mono,
  RmvpeMel mel,
  int sampleRate,
) {
  final audio = sampleRate == rmvpeSampleRate
      ? mono
      : resampleLinear(mono, sampleRate / rmvpeSampleRate);
  if (audio.isEmpty) return null;
  final (logMel, nFrames) = rmvpeLogMel(mel, audio);
  final nMels = mel.nMels;
  final nPad = 32 * ((nFrames - 1) ~/ 32 + 1) - nFrames;
  final pf = nFrames + nPad;
  final input = Float32List(nMels * pf); // frame-padded with 0 (log-mel space)
  for (var m = 0; m < nMels; m++) {
    input.setRange(m * pf, m * pf + nFrames, logMel, m * nFrames);
  }
  return (input: input, nFrames: nFrames, pf: pf);
}

/// Decode a `[1, pf, 360]` salience matrix's first [nFrames] rows to a track.
PitchTrack _decodeSalience(
  Float32List sal,
  int nFrames,
  RmvpeMel mel,
  double thred, {
  bool viterbi = false,
}) {
  // [viterbi]: global optimal bin path (torchcrepe/librosa) then the same local
  // average around each path bin — smooths octave flips the per-frame argmax
  // would follow.
  final path = viterbi ? viterbiPitchPath(sal, nFrames, _nBins) : null;
  final track = <PitchFrame>[];
  for (var t = 0; t < nFrames; t++) {
    final (hz, voiced) = path != null
        ? _decodeAtCenter(sal, t * _nBins, path[t], thred)
        : _decodeFrame(sal, t * _nBins, thred);
    track.add(
      (
        timeMs: t * mel.hop / rmvpeSampleRate * 1000.0,
        f0Hz: hz,
        voicedProb: voiced,
      ),
    );
  }
  return track;
}

/// Decode one 360-bin salience row (at [base]) to (F0 Hz, voicing) — RMVPE's
/// `to_local_average_cents`: weighted average of bin-centre cents over
/// `[argmax-4, argmax+5)` (out-of-range bins contribute 0), weighted by the RAW
/// salience (no sigmoid, unlike CREPE). Unvoiced (F0 0) when peak ≤ [thred].
/// Voicing = peak salience.
(double, double) _decodeFrame(Float32List sal, int base, double thred) {
  var argmax = 0;
  var peak = sal[base];
  for (var b = 1; b < _nBins; b++) {
    final v = sal[base + b];
    if (v > peak) {
      peak = v;
      argmax = b;
    }
  }
  return _decodeAtCenter(sal, base, argmax, thred);
}

/// The local weighted-average decode of one salience row, centred on [center]
/// (the argmax, or the Viterbi path bin). Voicing = peak salience; unvoiced when
/// peak ≤ [thred].
(double, double) _decodeAtCenter(
  Float32List sal,
  int base,
  int center,
  double thred,
) {
  var peak = sal[base];
  for (var b = 1; b < _nBins; b++) {
    if (sal[base + b] > peak) peak = sal[base + b];
  }
  if (peak <= thred) return (0.0, peak < 0 ? 0.0 : peak);
  final lo = math.max(0, center - 4), hi = math.min(_nBins, center + 5);
  var num = 0.0, den = 0.0;
  for (var b = lo; b < hi; b++) {
    final w = sal[base + b];
    num += w * (20 * b + _centsBase);
    den += w;
  }
  final cents = den > 0 ? num / den : 0.0;
  final hz = 10.0 * math.pow(2.0, cents / 1200.0);
  return (hz, peak);
}

/// Decode a full salience matrix `[nFrames × 360]` to `(f0Hz, voicing)` pairs —
/// exposed so the decoder can be tested against an RMVPE reference without the
/// model.
List<(double, double)> decodeRmvpeSalience(
  Float32List salience,
  int nFrames, {
  double thred = 0.03,
}) =>
    [
      for (var t = 0; t < nFrames; t++)
        _decodeFrame(salience, t * _nBins, thred),
    ];
