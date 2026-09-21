/// A two-state voicing decision with bounded lookahead.
///
/// §27 found the change that would actually improve this tuner: pYIN, with
/// its voicing cleaned up by a temporal model rather than a per-frame gate,
/// beats the shipped pipeline on held-note accuracy (88.21% against 80.80%)
/// and on cents (2.00 against 2.45), with the false-alarm gap closed from 22
/// points to 2.
///
/// §27.2 then named what stood in the way: the model that achieved it,
/// CometBeat's `segmentNotes`, is a Viterbi over the **whole track**. It is
/// offline, exactly as pYIN's own decode was before §24 gave it a bounded
/// lag, and a tuner cannot wait for the end of a performance to decide
/// whether the current frame is a note.
///
/// This is the streaming form, and it is deliberately **smaller** than what
/// it replaces. `segmentNotes` runs one state per MIDI note in the track's
/// range in order to decide *which* note — and §27.1 established that its
/// answer to that question must be thrown away, because `int midi`
/// quantises to the semitone and discards the deviation a tuner exists to
/// show. Only its voiced/unvoiced decision survives the mask. So this models
/// exactly that: two states, and the pitch is pYIN's throughout.
///
/// The structure is §24's, reused: a forward pass that keeps backpointers,
/// and a decision for frame `t` taken from the best state at `t + lag`.
/// `lag = 0` is greedy.
library;

import 'dart:math' as math;

/// Cost model, in log-domain units. Defaults are the starting point the
/// sweep in `bin/voicing.dart` explores rather than tuned constants.
class VoicingHmm {
  /// Penalty for changing between voiced and unvoiced. Higher means longer,
  /// steadier runs — the same job `switchCost` does in a note HMM, which is
  /// what absorbs vibrato and brief excursions instead of splitting them.
  final double switchCost;

  /// How strongly a frame's own evidence argues for its state. pYIN gives a
  /// probability mass over candidates; the mass it did *not* claim is its
  /// own estimate of being unvoiced, which is the natural emission here and
  /// costs nothing extra to compute.
  final double evidenceWeight;

  /// Frames of lookahead. 0 is greedy; the whole point of the class is that
  /// this is bounded and small.
  final int lag;

  const VoicingHmm({
    this.switchCost = 1.2,
    this.evidenceWeight = 4.0,
    this.lag = 2,
  });

  /// Decide voicing for each frame.
  ///
  /// [voicedEvidence] is one value per frame in 0..1 — pYIN's claimed
  /// probability mass. Returns one bool per frame.
  List<bool> decide(List<double> voicedEvidence) {
    final n = voicedEvidence.length;
    if (n == 0) return const [];

    // Two states: 0 unvoiced, 1 voiced.
    final back = List<List<int>>.generate(n, (_) => [0, 0], growable: false);
    final bestAt = List<int>.filled(n, 0);
    var prev = <double>[0, 0];

    double emit(int state, int t) {
      final p = voicedEvidence[t].clamp(0.0, 1.0);
      // Log-odds of the frame's own evidence, scaled. No probability is ever
      // taken as 0 or 1: a single confident frame must not be able to
      // override the transition prior outright, which is the failure mode
      // that makes a temporal model behave like a per-frame gate.
      final q = 0.02 + 0.96 * p;
      return state == 1
          ? -evidenceWeight * math.log(q)
          : -evidenceWeight * math.log(1 - q);
    }

    prev = [emit(0, 0), emit(1, 0)];
    bestAt[0] = prev[1] < prev[0] ? 1 : 0;

    for (int t = 1; t < n; t++) {
      final cur = <double>[0, 0];
      for (int s = 0; s < 2; s++) {
        final stay = prev[s];
        final switched = prev[1 - s] + switchCost;
        if (stay <= switched) {
          cur[s] = stay + emit(s, t);
          back[t][s] = s;
        } else {
          cur[s] = switched + emit(s, t);
          back[t][s] = 1 - s;
        }
      }
      prev = cur;
      bestAt[t] = cur[1] < cur[0] ? 1 : 0;
    }

    // Bounded-lag backtrace: frame t is decided from the best state at
    // t + lag, which is all a streaming decoder could have seen.
    final out = List<bool>.filled(n, false);
    for (int t = 0; t < n; t++) {
      final anchor = math.min(n - 1, t + (lag < 0 ? 0 : lag));
      var state = bestAt[anchor];
      for (int u = anchor; u > t; u--) {
        state = back[u][state];
      }
      out[t] = state == 1;
    }
    return out;
  }
}
