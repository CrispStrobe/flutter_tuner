/// Period refinement, with **no Flutter dependency at all** — like
/// `tuner_core.dart`, `detectors.dart` and the rest of the core, so that
/// `bench/` and `tool/tuner_probe.dart` can run exactly what the app runs.
///
/// The one step here is ported from
/// [`w1ne/stringtune`](https://github.com/w1ne/stringtune) (MIT), a web tuner
/// whose pitch core is Rust compiled to WASM around the `pitch-detection`
/// crate. It does not trust its own detector's period; after the detector has
/// chosen a candidate it re-scans the lag neighbourhood itself, and
/// `tuner-core/src/lib.rs` says why:
///
/// > The dependency's finite-window autocorrelation peak is biased toward
/// > shorter periods, most visibly on bass notes. Keep its candidate/clarity
/// > selection, then refine only the nearby period using correctly normalized
/// > overlapping sample pairs. This avoids a fixed cents offset that would
/// > depend on phase.
///
/// That claim was measured rather than believed. On GuitarSet's 180 solo
/// files, held-note frames, the shipped pipeline with this one step added and
/// **nothing else changed** (`bench/REPORT.md` §38.1):
///
/// | | RPA% | oct% | gross% | \|err\| p50 | p90 | p99 | >5c% | jitter p90 |
/// | --- | --- | --- | --- | --- | --- | --- | --- | --- |
/// | app, as it ships | 80.86 | 0.44 | 0.91 | 2.45 | 7.70 | 16.25 | 22.18 | 3.65 |
/// | app + this step | 80.86 | 0.44 | 0.91 | **2.05** | **6.45** | **14.80** | **16.68** | **2.85** |
///
/// Raw pitch accuracy, the octave rate, the gross-error rate, voicing recall
/// and voicing false alarm are identical *to the digit* — which is the
/// internal check that this does what it claims, since it moves a frequency
/// and touches no voicing decision. What moves is the tail, and the needle
/// jitter a player actually sees, by about a fifth. It costs 0.548 ms per
/// frame, 2.4% of the frame budget, and is the first refinement in that
/// report that improves the tuner without a trade — which is why it is on by
/// default. The credit is theirs; the measurement is ours.
///
/// None of those numbers came from a phone: the benchmark is a desktop
/// `dart run` over recorded audio, and nothing in this project has been
/// measured on a device.
library;

import 'dart:math' as math;

/// Re-scan the lag neighbourhood around [coarseF0] and return a better
/// estimate of the same period, in Hz.
///
/// Over lags within ±1% of the candidate period it recomputes
///
///     r(lag) = 2 Σ x[i]·x[i+lag] / Σ (x[i]² + x[i+lag]²),  i over 0..N-lag
///
/// — a correlation normalised over the *full overlap*, whose length shrinks
/// as the lag grows, rather than over a fixed window — and puts a parabola
/// through the best lag and its two neighbours.
///
/// Two details are deliberately preserved from the original because they are
/// judgement calls rather than incidental:
///
///   * the search radius is ±1% of the period but **at least two lags**, so
///     that a short period still gets a neighbourhood to look at;
///   * a maximum landing on either **edge** of that window returns [coarseF0]
///     unchanged rather than guessing. A boundary maximum means the candidate
///     needed a wider search, and inventing a fundamental there would be
///     worse than declining.
///
/// Returns [coarseF0] untouched for a frame it cannot improve: a non-positive
/// or non-finite candidate, an empty window, or a period longer than half the
/// window.
double refineByOverlapCorrelation(
    List<double> signal, double coarseF0, double sampleRate) {
  if (coarseF0 <= 0 || signal.isEmpty) return coarseF0;
  final period = sampleRate / coarseF0;
  if (!period.isFinite || period < 2 || period > signal.length / 2) {
    return coarseF0;
  }

  double correlation(int lag) {
    double cross = 0, energy = 0;
    for (int i = 0; i < signal.length - lag; i++) {
      final a = signal[i], b = signal[i + lag];
      cross += a * b;
      energy += a * a + b * b;
    }
    return energy > 0 ? 2 * cross / energy : 0;
  }

  final centre = period.round();
  final radius = math.max(2, (period * 0.01).ceil());
  final start = math.max(1, centre - radius);
  final end = math.min(centre + radius, signal.length ~/ 2);
  if (start >= end) return coarseF0;

  int best = centre;
  double peak = double.negativeInfinity;
  for (int lag = start; lag <= end; lag++) {
    final v = correlation(lag);
    if (v > peak) {
      peak = v;
      best = lag;
    }
  }
  if (best == start || best == end) return coarseF0;

  final left = correlation(best - 1), right = correlation(best + 1);
  final curvature = left - 2 * peak + right;
  final offset = curvature.abs() > 1e-300
      ? (0.5 * (left - right) / curvature).clamp(-0.5, 0.5)
      : 0.0;
  return sampleRate / (best + offset);
}
