// lib/core/audio/transcription/f0_viterbi.dart
//
// Viterbi path-smoothing over a per-frame pitch-bin activation lattice — the
// torchcrepe / librosa decode, shared by the neural F0 estimators (CREPE, RMVPE,
// FCPE all emit a 360-bin activation). Instead of decoding each frame
// independently (argmax + local average), this finds the globally optimal bin
// path, penalising large frame-to-frame jumps — so octave flips and single-frame
// spikes are smoothed away.
//
// Matches `torchcrepe.decode.viterbi`: observations are the per-frame softmax of
// the activations, and the transition is torchcrepe's triangular window
// `max(width-|i-j|, 0)` row-normalised (default width 12 → ±11 bins). The path
// is bit-identical to `librosa.sequence.viterbi`. The bin→F0 conversion is left
// to the caller (each model has its own cents mapping / local average).
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Per-frame log-softmax of the `bins` activations at frame [t] (row-major
/// `[frames × bins]`), numerically stable.
void _logSoftmaxFrame(List<double> act, int t, int bins, Float64List out) {
  final base = t * bins;
  var m = double.negativeInfinity;
  for (var b = 0; b < bins; b++) {
    final v = act[base + b];
    if (v > m) m = v;
  }
  var sum = 0.0;
  for (var b = 0; b < bins; b++) {
    sum += math.exp(act[base + b] - m);
  }
  final lse = m + math.log(sum);
  for (var b = 0; b < bins; b++) {
    out[b] = act[base + b] - lse;
  }
}

/// Viterbi decode over the activation lattice [act] (row-major `[frames×bins]`,
/// raw activations — softmaxed per frame here). Returns the optimal bin path
/// (one bin per frame). Transition = torchcrepe's `max(width-|i-j|,0)`
/// row-normalised triangular window. Uniform initial distribution, exactly as
/// `librosa.sequence.viterbi`.
Int32List viterbiPitchPath(
  List<double> act,
  int frames,
  int bins, {
  int width = 12,
}) {
  if (frames <= 0) return Int32List(0);
  if (frames == 1) {
    // Single frame → argmax of the observation (first max, like numpy).
    var best = double.negativeInfinity, arg = 0;
    for (var b = 0; b < bins; b++) {
      if (act[b] > best) {
        best = act[b];
        arg = b;
      }
    }
    return Int32List(1)..[0] = arg;
  }

  // Per-source-state transition normaliser: sum of max(width-|i-j|,0) over j.
  final rowSum = Float64List(bins);
  for (var p = 0; p < bins; p++) {
    var s = 0.0;
    for (var d = -(width - 1); d <= width - 1; d++) {
      final j = p + d;
      if (j < 0 || j >= bins) continue;
      s += (width - d.abs()).toDouble();
    }
    rowSum[p] = s;
  }

  final logInit = -math.log(bins.toDouble());
  final t1 = Float64List(bins), t1prev = Float64List(bins);
  final ls = Float64List(bins);
  final back = List.generate(frames, (_) => Int32List(bins), growable: false);

  _logSoftmaxFrame(act, 0, bins, ls);
  for (var s = 0; s < bins; s++) {
    t1prev[s] = logInit + ls[s];
  }

  for (var t = 1; t < frames; t++) {
    _logSoftmaxFrame(act, t, bins, ls);
    for (var cur = 0; cur < bins; cur++) {
      final lo = math.max(0, cur - (width - 1));
      final hi = math.min(bins - 1, cur + (width - 1));
      var best = double.negativeInfinity, arg = cur;
      for (var prev = lo; prev <= hi; prev++) {
        // transition[prev][cur] = max(width-|prev-cur|,0) / rowSum[prev]
        final w = (width - (prev - cur).abs()).toDouble();
        final v = t1prev[prev] + math.log(w / rowSum[prev]);
        if (v > best) {
          best = v;
          arg = prev;
        }
      }
      t1[cur] = best + ls[cur];
      back[t][cur] = arg;
    }
    for (var s = 0; s < bins; s++) {
      t1prev[s] = t1[s];
    }
  }

  // Backtrack from the best final state (first max, like numpy argmax).
  var s = 0;
  var bestEnd = double.negativeInfinity;
  for (var b = 0; b < bins; b++) {
    if (t1prev[b] > bestEnd) {
      bestEnd = t1prev[b];
      s = b;
    }
  }
  final path = Int32List(frames);
  path[frames - 1] = s;
  for (var t = frames - 1; t > 0; t--) {
    s = back[t][s];
    path[t - 1] = s;
  }
  return path;
}
