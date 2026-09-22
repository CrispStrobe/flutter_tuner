// lib/core/audio/transcription/fcpe.dart
//
// FCPE — Fast Context-based Pitch Estimation (Lynx-Net, MIT), the FAST neural
// F0. A depthwise-separable-conv + GLU model on a mel spectrogram → 360-bin
// pitch latent. Runs on `onnx_runtime_dart` at ~1.6× real time (vs CREPE/RMVPE
// ~0.3×), so it's the recommended default for full-song monophonic pitch.
//
// Pipeline: resample→16 kHz → log-mel (see `fcpe_mel.dart`, validated vs
// torchfcpe) → model → FCPE `local_argmax` decode (weighted average of the
// cent_table over a 9-bin window around the peak, edge-clamped; unvoiced when
// peak ≤ threshold) → [PitchTrack].
//
// WEB-SAFE: takes a preloaded [OnnxModel] + [FcpeAssets]; the ~43 MB model
// download (dart:io) lives in the native `fcpe_model_store.dart`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'resample.dart';
import 'contracts.dart';
import 'f0_viterbi.dart';
import 'fcpe_mel.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';

const int _nBins = 360;
const String _inName = 'mel';
const String _outName = 'salience';

/// Neural monophonic F0 with FCPE. Resamples [mono] to 16 kHz, computes the
/// log-mel, runs the [model], and decodes each frame to F0 + voicing →
/// [PitchTrack]. [threshold] gates a frame unvoiced (`f0Hz == 0`) when the peak
/// latent is below it. Pure / synchronous / web-safe.
PitchTrack fcpeF0(
  Float64List mono, {
  required OnnxModel model,
  required FcpeAssets assets,
  int sampleRate = 44100,
  double threshold = 0.006,
  bool viterbi = false,
}) {
  final p = _prep(mono, assets, sampleRate);
  if (p == null) return const [];
  final out = model.run(
    {
      _inName: Tensor.float(p.mel, [1, p.nFrames, assets.nMels]),
    },
    const [_outName],
  )[_outName]!;
  return _decode(
    out.f ?? out.asFloatList(),
    p.nFrames,
    assets,
    threshold,
    viterbi: viterbi,
  );
}

/// Isolate-pool variant of [fcpeF0] (`runAsync`) — FCPE is ~77% Conv, so a
/// [OnnxModel.parallelize]d model runs faster; output stays bitwise identical.
Future<PitchTrack> fcpeF0Async(
  Float64List mono, {
  required OnnxModel model,
  required FcpeAssets assets,
  int sampleRate = 44100,
  double threshold = 0.006,
  bool viterbi = false,
}) async {
  final p = _prep(mono, assets, sampleRate);
  if (p == null) return const [];
  final out = await model.runAsync(
    {
      _inName: Tensor.float(p.mel, [1, p.nFrames, assets.nMels]),
    },
    const [_outName],
  );
  final sal = out[_outName]!.f ?? out[_outName]!.asFloatList();
  return _decode(sal, p.nFrames, assets, threshold, viterbi: viterbi);
}

({Float32List mel, int nFrames})? _prep(
  Float64List mono,
  FcpeAssets assets,
  int sampleRate,
) {
  final audio = sampleRate == fcpeSampleRate
      ? mono
      : resampleLinear(mono, sampleRate / fcpeSampleRate);
  if (audio.isEmpty) return null;
  final (mel, nFrames) = fcpeLogMel(assets, audio);
  return (mel: mel, nFrames: nFrames);
}

/// FCPE `latent2cents_local_decoder`: per frame, argmax over 360, then the
/// weighted average of `cent_table` over `[argmax-4, argmax+5)` (indices
/// edge-CLAMPED to `[0,360)`, weighted by the raw latent). Unvoiced (F0 0) when
/// the peak ≤ [threshold]. Voicing = peak.
PitchTrack _decode(
  Float32List sal,
  int nFrames,
  FcpeAssets a,
  double threshold, {
  bool viterbi = false,
}) {
  // [viterbi]: the global optimal bin path (torchcrepe/librosa) then the same
  // local average around each path bin — smooths octave flips / spikes.
  final path = viterbi ? viterbiPitchPath(sal, nFrames, _nBins) : null;
  final track = <PitchFrame>[];
  for (var t = 0; t < nFrames; t++) {
    final base = t * _nBins;
    var argmax = 0;
    var peak = sal[base];
    for (var b = 1; b < _nBins; b++) {
      final v = sal[base + b];
      if (v > peak) {
        peak = v;
        argmax = b;
      }
    }
    final center = path != null ? path[t] : argmax;
    var hz = 0.0;
    if (peak > threshold) {
      var num = 0.0, den = 0.0;
      for (var k = 0; k < 9; k++) {
        var idx = center - 4 + k;
        if (idx < 0) idx = 0;
        if (idx >= _nBins) idx = _nBins - 1;
        final w = sal[base + idx];
        num += a.centTable[idx] * w;
        den += w;
      }
      final cents = den != 0 ? num / den : 0.0;
      hz = 10.0 * math.pow(2.0, cents / 1200.0);
    }
    track.add(
      (
        timeMs: t * a.hop / fcpeSampleRate * 1000.0,
        f0Hz: hz,
        voicedProb: peak.isFinite ? peak : 0.0,
      ),
    );
  }
  return track;
}
