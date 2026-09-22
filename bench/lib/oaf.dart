// Onsets & Frames, end to end in Dart.
//
// 26.49 M parameters, 106 MB of ONNX, the classic piano baseline. §31 dropped
// it as "a baseline, not a candidate" on size, and §32 then measured it at
// **11x faster than real time on one thread** under native ONNX Runtime,
// which is an unusually good mobile profile. Neither statement was ever an
// accuracy number, because the graph takes a 229-bin log-mel and nothing here
// could make one. `mel.dart` can now.
//
// Faithful to `ddPn08/onsets-and-frames`'s `infer.py`:
//
//   * mel: 16 kHz, n_fft = win = 2048, hop = 512, 229 mels, f_min 30,
//     f_max 8000, `slaney` norm, **power 1.0** (magnitude, not energy),
//     then log(clamp(mel, 1e-5)). The last audio sample is dropped, which
//     is what makes the frame count come out at (len-1)//512 + 1.
//   * frame i is centred on sample i*512, so its time is i*512/16000 s.
//     One window, one clock, no drift (§30.1).
//
// TWO TRAPS, both found by reading the graph rather than by trusting a name.
//
// 1. **The output names are shifted by one.** `torch.onnx.export` was given
//    four `output_names` for a forward that returns five tensors, so the
//    names slid: `onset` is onset_pred and `offset` is offset_pred, but
//    `frame` is the *pre-combination* activation, `velocity` is the real
//    frame prediction out of the combined stack, and the unnamed fifth
//    output `679` is the velocity. Verified structurally: `velocity` is the
//    only graph output that has `onset`, `offset` and `frame` among its
//    ancestors, which is exactly `combined_stack(cat([onset, offset,
//    activation]))`. This is §12.1's failure mode — an unlabelled output
//    does not announce that it has been misread — and decoding the
//    activation head instead of the frame head would have looked like a
//    mediocre model rather than like a bug.
//
// 2. **The heads emit logits, not probabilities.** Every stack ends in
//    `nn.Linear` with no sigmoid, and the repo's own `infer.py` then
//    thresholds at 0.5 as though they were probabilities — which is really a
//    sigmoid threshold of 0.62. This applies the sigmoid and thresholds at
//    0.5; `--oaf-logit-threshold` reproduces the repo's behaviour for
//    comparison.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';

import 'mel.dart';
import 'note_metrics.dart' show Note;

class OafGeometry {
  static const int sampleRate = 16000;
  static const int hop = 512;
  static const int nFft = 2048;
  static const int nMels = 229;
  static const double fMin = 30;
  static const double fMax = 8000;
  static const int minMidi = 21;
  static const int numNotes = 88;

  /// See trap 1 above: these are the graph output names, not their meanings.
  static const String onsetOut = 'onset';
  static const String activationOut = 'frame';
  static const String frameOut = 'velocity';
  static const String velocityOut = '679';
}

double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

class OafFrames {
  final List<Float32List> onset;
  final List<Float32List> frame;
  OafFrames(this.onset, this.frame);
}

/// One forward pass over the whole piece — the LSTM axis is dynamic, so the
/// chunking `infer.py` does for memory is not needed here, and §32 measured
/// the LSTM as the sequential part that does not parallelise anyway.
OafFrames oafForward(OnnxModel model, Float64List audio, int sampleRate) {
  var mono = resampleTo(audio, sampleRate, OafGeometry.sampleRate);
  // `x[:, :-1]` in the repo's forward.
  mono = Float64List.sublistView(mono, 0, math.max(0, mono.length - 1));
  final melT = MelSpectrogram(
    sampleRate: OafGeometry.sampleRate,
    nFft: OafGeometry.nFft,
    winLength: OafGeometry.nFft,
    hopLength: OafGeometry.hop,
    nMels: OafGeometry.nMels,
    fMin: OafGeometry.fMin,
    fMax: OafGeometry.fMax,
    power: 1.0,
    pad: MelPad.reflect,
  );
  final mel = melT.compute(mono);
  final frames = mel.length;
  final flat = Float32List(frames * OafGeometry.nMels);
  for (int t = 0; t < frames; t++) {
    final row = mel[t];
    for (int m = 0; m < OafGeometry.nMels; m++) {
      flat[t * OafGeometry.nMels + m] = math.log(math.max(row[m], 1e-5));
    }
  }
  final out = model.run(
    {'mel': Tensor.float(flat, [1, frames, OafGeometry.nMels])},
    const [OafGeometry.onsetOut, OafGeometry.frameOut],
  );
  final on = out[OafGeometry.onsetOut]!.asFloatList();
  final fr = out[OafGeometry.frameOut]!.asFloatList();
  final onset = <Float32List>[];
  final frame = <Float32List>[];
  for (int t = 0; t < frames; t++) {
    final a = Float32List(OafGeometry.numNotes);
    final b = Float32List(OafGeometry.numNotes);
    for (int p = 0; p < OafGeometry.numNotes; p++) {
      final k = t * OafGeometry.numNotes + p;
      a[p] = _sigmoid(on[k]);
      b[p] = _sigmoid(fr[k]);
    }
    onset.add(a);
    frame.add(b);
  }
  return OafFrames(onset, frame);
}

/// `modules/decoding.py: extract_notes`, with the sample-rate scaling
/// `infer.py` applies afterwards.
List<Note> oafNotes(OafFrames h,
    {double onsetThreshold = 0.5, double frameThreshold = 0.5}) {
  final n = h.onset.length;
  final out = <Note>[];
  const scaleMs = 1000.0 * OafGeometry.hop / OafGeometry.sampleRate;
  for (int p = 0; p < OafGeometry.numNotes; p++) {
    for (int t = 0; t < n; t++) {
      final on = h.onset[t][p] > onsetThreshold;
      final prev = t == 0 ? false : h.onset[t - 1][p] > onsetThreshold;
      if (!on || prev) continue;
      int offset = t;
      while (offset < n &&
          (h.onset[offset][p] > onsetThreshold ||
              h.frame[offset][p] > frameThreshold)) {
        offset++;
      }
      if (offset > t) {
        out.add((
          onsetMs: t * scaleMs,
          offsetMs: offset * scaleMs,
          midi: (p + OafGeometry.minMidi).toDouble(),
        ));
      }
    }
  }
  out.sort((a, b) => a.onsetMs.compareTo(b.onsetMs));
  return out;
}
