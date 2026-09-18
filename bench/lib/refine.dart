/// Precision refinements on top of a coarse f0.
///
/// A tuner is not really a pitch *detector* — by the time the user is looking
/// at the needle the note is already known. What it needs is the last tenth of
/// a cent, and YIN's parabolic interpolation over an integer lag grid is a
/// blunt instrument for that: at 330 Hz the lag is 134 samples, so one sample
/// of lag is 13 cents, and the parabola has to find the rest.
///
/// Two cheap refinements, both of which need only FFTs the app is already in
/// a position to compute:
///
///   * **instantaneous frequency** from the phase advance of a partial
///     between two sub-frames — the phase-vocoder estimator;
///   * **harmonic least squares**, fitting all the measured partials at once,
///     optionally with a stiffness term, which also falls out as an
///     inharmonicity coefficient B.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

class Refinement {
  /// Refined f0 in Hz, or the input if nothing could be fitted.
  final double frequency;

  /// Inharmonicity coefficient B from f_n = n·f0·√(1+B·n²), or null when
  /// too few partials were measurable to fit it.
  final double? inharmonicity;

  /// How many partials the fit actually used.
  final int partials;
  const Refinement(this.frequency, this.inharmonicity, this.partials);
}

/// Refine [coarseF0] using the instantaneous frequency of its partials.
///
/// Takes two Hann-windowed sub-frames of [subSize] samples, [hop] apart, from
/// the end of [buffer] (the most recent audio — a tuner should answer about
/// now, not about 90 ms ago), and reads each partial's frequency from how far
/// its phase moved between them.
Refinement refineByInstantaneousFrequency(
  List<double> buffer,
  double coarseF0,
  double sampleRate, {
  int subSize = 2048,
  int hop = 256,
  int maxPartials = 8,
  bool fitInharmonicity = true,
}) {
  if (coarseF0 <= 0 || buffer.length < subSize + hop) {
    return Refinement(coarseF0, null, 0);
  }

  final start2 = buffer.length - subSize;
  final start1 = start2 - hop;

  final window = Float64List(subSize);
  for (int i = 0; i < subSize; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / subSize);
  }

  final fft = FFT(subSize);
  Float64x2List spectrum(int start) {
    final frame = Float64List(subSize);
    for (int i = 0; i < subSize; i++) {
      frame[i] = buffer[start + i] * window[i];
    }
    return fft.realFft(frame);
  }

  final s1 = spectrum(start1);
  final s2 = spectrum(start2);
  final bins = subSize ~/ 2;

  // (frequency, weight) per partial that is clearly present.
  final freqs = <double>[];
  final weights = <double>[];
  final orders = <int>[];

  for (int n = 1; n <= maxPartials; n++) {
    final target = coarseF0 * n;
    if (target > sampleRate * 0.45) break;
    final centre = (target * subSize / sampleRate).round();
    if (centre < 2 || centre >= bins - 2) break;

    // The partial may sit a bin or two off the harmonic guess, especially on
    // a stiff string; search a small neighbourhood for the local peak.
    final span = math.max(2, (0.03 * centre).round());
    int peak = centre;
    double peakMag = -1;
    for (int k = math.max(1, centre - span);
        k <= math.min(bins - 2, centre + span);
        k++) {
      final m = s2[k].x * s2[k].x + s2[k].y * s2[k].y;
      if (m > peakMag) {
        peakMag = m;
        peak = k;
      }
    }
    // Require a real peak, not a shoulder of noise.
    final neighbourFloor = math.min(
      s2[peak - 1].x * s2[peak - 1].x + s2[peak - 1].y * s2[peak - 1].y,
      s2[peak + 1].x * s2[peak + 1].x + s2[peak + 1].y * s2[peak + 1].y,
    );
    if (peakMag <= 0 || peakMag < neighbourFloor) continue;

    final phase1 = math.atan2(s1[peak].y, s1[peak].x);
    final phase2 = math.atan2(s2[peak].y, s2[peak].x);
    final omega = 2 * math.pi * peak / subSize;
    double residual = (phase2 - phase1) - omega * hop;
    residual = residual - 2 * math.pi * (residual / (2 * math.pi)).round();
    final f = sampleRate * (peak / subSize + residual / (2 * math.pi * hop));
    if (f <= 0) continue;
    // Guard against locking onto a neighbouring partial.
    if ((f - target).abs() > 0.06 * target + sampleRate / subSize) continue;

    freqs.add(f);
    weights.add(math.sqrt(peakMag));
    orders.add(n);
  }

  if (freqs.isEmpty) return Refinement(coarseF0, null, 0);

  // Weighted least squares for f_n = n·f0 (no stiffness): minimise
  // Σ w (f_n - n f0)² → f0 = Σ w n f_n / Σ w n².
  double num = 0, den = 0;
  for (int i = 0; i < freqs.length; i++) {
    num += weights[i] * orders[i] * freqs[i];
    den += weights[i] * orders[i] * orders[i];
  }
  final plainF0 = den > 0 ? num / den : coarseF0;

  if (!fitInharmonicity || freqs.length < 4) {
    return Refinement(plainF0, null, freqs.length);
  }

  // With stiffness, f_n = n·f0·√(1+B n²), so (f_n/n)² = f0² + f0²B·n²: a
  // straight line in n². Weighted linear regression gives both.
  double sw = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (int i = 0; i < freqs.length; i++) {
    final x = (orders[i] * orders[i]).toDouble();
    final y = math.pow(freqs[i] / orders[i], 2).toDouble();
    final w = weights[i];
    sw += w;
    sx += w * x;
    sy += w * y;
    sxx += w * x * x;
    sxy += w * x * y;
  }
  final denom = sw * sxx - sx * sx;
  if (denom == 0) return Refinement(plainF0, null, freqs.length);
  final slope = (sw * sxy - sx * sy) / denom;
  final intercept = (sy * sxx - sx * sxy) / denom;
  if (intercept <= 0) return Refinement(plainF0, null, freqs.length);
  final f0 = math.sqrt(intercept);
  final b = slope / intercept;
  // A guitar's B is ~1e-5–1e-4; anything wilder is a bad fit, not a stiff
  // string, and the plain fit is the safer answer.
  if (!b.isFinite ||
      b < 0 ||
      b > 1e-2 ||
      (f0 - coarseF0).abs() > 0.06 * coarseF0) {
    return Refinement(plainF0, null, freqs.length);
  }
  return Refinement(f0, b, freqs.length);
}
