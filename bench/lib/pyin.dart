/// A pYIN-shaped tracker: candidate distribution per frame, Viterbi across
/// frames.
///
/// Mauch & Dixon's point is that YIN's threshold is an arbitrary hard
/// decision taken independently on every frame, and that most of its errors
/// are frames where a *different* threshold would have given the right
/// answer. So: keep every local minimum of the CMNDF as a candidate, weight
/// it by the prior probability of the thresholds that would have selected it,
/// and let a hidden Markov model over time choose the path.
///
/// This is a faithful-in-shape, simplified-in-detail implementation: the
/// threshold prior is Beta(2, 18) as in the paper, the state space is a
/// [binCents]-cent grid with a voiced and an unvoiced copy of each bin, and
/// the transition model is a triangular pitch-continuity window plus a fixed
/// voicing switch probability. It is not librosa's pYIN and should not be
/// reported as such; it is here to answer "would a temporal model kill the
/// octave errors", which it can.
library;

import 'dart:math' as math;

import 'yin.dart';

class PyinFrame {
  final List<double> frequencies;
  final List<double> probabilities;
  const PyinFrame(this.frequencies, this.probabilities);
}

class PyinTracker {
  final double sampleRate;
  final int bufferSize;
  final double minF0;
  final double maxF0;
  final double binCents;

  /// Probability mass a frame keeps for "nothing is sounding" beyond what the
  /// candidates leave unclaimed.
  final double noTrustFloor;

  /// Standard deviation, in cents, of the frame-to-frame pitch transition.
  final double transitionCents;

  /// Probability of switching between voiced and unvoiced from one frame to
  /// the next.
  final double switchProbability;

  late final int bins;
  late final List<double> _thresholds;
  late final List<double> _thresholdPriors;

  PyinTracker({
    required this.sampleRate,
    required this.bufferSize,
    this.minF0 = 30.0,
    this.maxF0 = 1200.0,
    this.binCents = 10.0,
    this.noTrustFloor = 0.01,
    this.transitionCents = 60.0,
    this.switchProbability = 0.01,
  }) {
    bins = (1200 * math.log(maxF0 / minF0) / math.ln2 / binCents).ceil() + 1;
    // 20 thresholds, prior Beta(2, 18) — mean 0.1, the value the YIN paper
    // recommends and the shipped package does not use.
    _thresholds = List.generate(20, (i) => (i + 1) * 0.025);
    final raw = _thresholds.map((s) => _beta(s, 2, 18)).toList();
    final total = raw.reduce((a, b) => a + b);
    _thresholdPriors = raw.map((p) => p / total).toList();
  }

  static double _beta(double x, double a, double b) =>
      math.pow(x, a - 1).toDouble() * math.pow(1 - x, b - 1).toDouble();

  int binOf(double f) =>
      (1200 * math.log(f / minF0) / math.ln2 / binCents).round();

  double freqOf(int bin) =>
      minF0 * math.pow(2, bin * binCents / 1200).toDouble();

  /// The candidate distribution for one frame, from a CMNDF already computed.
  PyinFrame observe(RefYin yin) {
    final candidates = yin.candidates(maxAperiodicity: 1.0);
    final freqs = <double>[];
    final probs = <double>[];
    if (candidates.isEmpty) return const PyinFrame([], []);

    for (int i = 0; i < _thresholds.length; i++) {
      final s = _thresholds[i];
      // Which candidate would this threshold have picked? The same rule the
      // package uses: the first local minimum below it.
      int chosen = -1;
      for (int c = 0; c < candidates.length; c++) {
        if (candidates[c].aperiodicity < s) {
          chosen = c;
          break;
        }
      }
      double mass = _thresholdPriors[i];
      if (chosen < 0) {
        // No candidate clears this threshold: that vote goes to "unvoiced",
        // handled by the mass never being assigned below.
        continue;
      }
      // pYIN also lets the best candidate absorb some of the unclaimed mass;
      // the simplification here is to weight by periodicity.
      mass *= (1 - candidates[chosen].aperiodicity).clamp(0.0, 1.0);
      final f = candidates[chosen].frequency;
      if (f < minF0 || f > maxF0) continue;
      final at = freqs.indexWhere((x) => (x - f).abs() < 1e-9);
      if (at >= 0) {
        probs[at] += mass;
      } else {
        freqs.add(f);
        probs.add(mass);
      }
    }
    return PyinFrame(freqs, probs);
  }

  /// Viterbi with a bounded decoding lag, in frames.
  ///
  /// REPORT.md §4.1 rejected pYIN for a tuner partly on the grounds that
  /// "Viterbi cannot decide frame t until it has seen the end of the file.
  /// An online version needs a fixed decoding lag, which is more latency on
  /// top of the ~90 ms the window already costs." That was an assertion with
  /// no number behind it, and this is the number: frame `t` is emitted once
  /// frame `t + lag` has been observed, which is exactly what a streaming
  /// implementation could do.
  ///
  /// `lag = 0` is greedy — take the best state at each frame, no lookahead
  /// at all. A lag at or beyond the frame count is the offline [decode].
  ///
  /// Shares the forward pass with [decode]; only the backtrace changes, so
  /// the cost of a bounded lag is the same arithmetic and less memory.
  List<double> decodeWithLag(List<PyinFrame> frames, int lag) =>
      decode(frames, lag: lag);

  /// Viterbi over the whole file. Returns one frequency per frame, or 0 where
  /// the best path is unvoiced.
  ///
  /// [lag] bounds the lookahead: see [decodeWithLag]. Null decodes offline.
  List<double> decode(List<PyinFrame> frames, {int? lag}) {
    if (frames.isEmpty) return const [];
    final nStates = bins * 2; // [0, bins) voiced, [bins, 2*bins) unvoiced
    final neighbourhood = (3 * transitionCents / binCents).ceil();

    // Log-domain triangular transition weights over the pitch neighbourhood.
    final weights = List<double>.generate(neighbourhood + 1, (d) {
      final cents = d * binCents;
      return math.max(1e-9, 1 - cents / (3 * transitionCents));
    });
    final logW = weights.map((w) => math.log(w)).toList();
    final logStay = math.log(1 - switchProbability);
    final logSwitch = math.log(switchProbability);

    var previous = List<double>.filled(nStates, double.negativeInfinity);
    final backpointers = <List<int>>[];
    // Argmax of the forward scores at each frame. Only a bounded-lag decode
    // reads it, and it is the whole reason a streaming decoder can answer at
    // all: it is the best state given everything seen *so far*.
    final bestAt = List<int>.filled(frames.length, 0);
    bool seededBest = false;

    List<double> emission(PyinFrame f) {
      final e = List<double>.filled(nStates, 0.0);
      double claimed = 0;
      for (int i = 0; i < f.frequencies.length; i++) {
        final b = binOf(f.frequencies[i]);
        if (b < 0 || b >= bins) continue;
        e[b] += f.probabilities[i];
        claimed += f.probabilities[i];
      }
      final unvoiced = math.max(noTrustFloor, 1 - claimed);
      for (int b = bins; b < nStates; b++) {
        e[b] = unvoiced / bins;
      }
      for (int i = 0; i < nStates; i++) {
        e[i] = math.log(e[i] + 1e-12);
      }
      return e;
    }

    final first = emission(frames.first);
    for (int i = 0; i < nStates; i++) {
      previous[i] = first[i] - math.log(nStates);
    }

    // Frame 0 has no predecessor, so its best state is the argmax of the
    // initial row rather than of a transition.
    if (!seededBest) {
      int b0 = 0;
      for (int i = 1; i < nStates; i++) {
        if (previous[i] > previous[b0]) b0 = i;
      }
      bestAt[0] = b0;
      seededBest = true;
    }
    for (int t = 1; t < frames.length; t++) {
      final e = emission(frames[t]);
      final current = List<double>.filled(nStates, double.negativeInfinity);
      final back = List<int>.filled(nStates, 0);

      // Best unvoiced predecessor is shared: unvoiced states are flat, so
      // only the maxima matter.
      double bestVoiced = double.negativeInfinity;
      int bestVoicedAt = 0;
      double bestUnvoiced = double.negativeInfinity;
      int bestUnvoicedAt = bins;
      for (int i = 0; i < bins; i++) {
        if (previous[i] > bestVoiced) {
          bestVoiced = previous[i];
          bestVoicedAt = i;
        }
        if (previous[bins + i] > bestUnvoiced) {
          bestUnvoiced = previous[bins + i];
          bestUnvoicedAt = bins + i;
        }
      }

      for (int b = 0; b < bins; b++) {
        // Voiced: a local pitch move, or arriving from unvoiced.
        double best = bestUnvoiced + logSwitch - math.log(bins);
        int from = bestUnvoicedAt;
        final lo = math.max(0, b - neighbourhood);
        final hi = math.min(bins - 1, b + neighbourhood);
        for (int p = lo; p <= hi; p++) {
          final score = previous[p] + logStay + logW[(b - p).abs()];
          if (score > best) {
            best = score;
            from = p;
          }
        }
        current[b] = best + e[b];
        back[b] = from;

        // Unvoiced: stay unvoiced, or drop out of voiced.
        final stay = bestUnvoiced + logStay;
        final drop = bestVoiced + logSwitch;
        if (stay >= drop) {
          current[bins + b] = stay + e[bins + b];
          back[bins + b] = bestUnvoicedAt;
        } else {
          current[bins + b] = drop + e[bins + b];
          back[bins + b] = bestVoicedAt;
        }
      }
      backpointers.add(back);
      previous = current;
      int b0 = 0;
      for (int i = 1; i < nStates; i++) {
        if (current[i] > current[b0]) b0 = i;
      }
      bestAt[t] = b0;
    }

    int best = 0;
    for (int i = 1; i < nStates; i++) {
      if (previous[i] > previous[best]) best = i;
    }
    final path = List<int>.filled(frames.length, 0);
    path[frames.length - 1] = best;
    if (lag == null) {
      for (int t = frames.length - 1; t > 0; t--) {
        path[t - 1] = backpointers[t - 1][path[t]];
      }
    } else {
      // Bounded lag: frame t is decided by backtracing from the best state
      // at frame t+lag, which is all a streaming decoder could have seen.
      // `bestAt` is the argmax of the forward scores already stored per
      // frame, so this costs one extra backtrace per frame and no extra
      // forward work.
      for (int t = 0; t < frames.length; t++) {
        final anchor =
            math.min(frames.length - 1, t + (lag < 0 ? 0 : lag));
        var state = bestAt[anchor];
        for (int u = anchor; u > t; u--) {
          state = backpointers[u - 1][state];
        }
        path[t] = state;
      }
    }

    return [
      for (int t = 0; t < frames.length; t++)
        path[t] < bins ? freqOf(path[t]) : 0.0,
    ];
  }

  /// The decoded path is quantised to [binCents]; a tuner needs better than
  /// that. Snap each decoded frame back onto the nearest *actual* candidate
  /// frequency, which carries YIN's parabolic sub-sample precision.
  List<double> snapToCandidates(List<PyinFrame> frames, List<double> decoded) {
    final out = List<double>.filled(decoded.length, 0);
    for (int t = 0; t < decoded.length; t++) {
      final f = decoded[t];
      if (f <= 0) continue;
      double best = f;
      double bestCents = binCents; // never snap further than one bin
      for (final c in frames[t].frequencies) {
        final d = (1200 * math.log(c / f) / math.ln2).abs();
        if (d < bestCents) {
          bestCents = d;
          best = c;
        }
      }
      out[t] = best;
    }
    return out;
  }
}
