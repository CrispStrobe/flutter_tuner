/// What the partials are doing, with **no Flutter dependency at all**.
///
/// The detector answers one question — what is the period — and throws the
/// rest of the spectrum away. A guitar string is not a sine: it carries a
/// dozen partials, they are not exactly harmonic, and what they do is
/// directly useful to a tuner:
///
///   * **which partial the detector locked onto.** An octave error is not a
///     random number; it is the detector reporting partial 2 as if it were
///     partial 1, or half the period as the whole. Measuring the partials
///     independently says which happened, and lets the reading be sanity
///     checked against the spectrum rather than against the last five frames.
///   * **inharmonicity.** A real string is stiff, so
///     `f_n = n·f0·√(1 + B·n²)`. B is measurable from the partials, and it is
///     the gateway to stretch tuning — an octave on a stiff string is wider
///     than 2:1, which is why pianos are tuned stretched and why a guitar's
///     12th-fret harmonic never quite agrees with the fretted note.
///   * **timbre**, in the plain sense of which partials are loud. A note
///     plucked near the bridge, a harmonic, and a muted string are different
///     shapes, and the detector sees all three as "a pitch".
///
/// Everything here reads a spectrum the app is already computing for the
/// display, so the incremental cost is the peak search.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// One measured partial.
class Partial {
  /// Harmonic number it was matched to: 1 is the fundamental.
  final int order;

  /// Measured frequency in Hz, refined from the phase advance between two
  /// sub-frames rather than read off the bin grid.
  final double frequency;

  /// Linear magnitude, in whatever units the input samples were.
  final double magnitude;

  /// How far this partial sits from `order * f0`, in cents. Positive means
  /// sharp, which is what stiffness does.
  final double centsFromHarmonic;

  const Partial(
      this.order, this.frequency, this.magnitude, this.centsFromHarmonic);
}

/// What a frame's partials say about it.
class HarmonicProfile {
  /// The partials that were found, in order.
  final List<Partial> partials;

  /// Fundamental implied by the partials, fitted with the stiffness term
  /// when there were enough of them. May differ from the detector's answer;
  /// that difference is the interesting part.
  final double fittedF0;

  /// Stiffness coefficient B from `f_n = n·f0·√(1+B·n²)`, or null when too
  /// few partials were measurable to fit it. Around 1e-4 for a steel guitar
  /// string; an order of magnitude more on a piano's short bass strings.
  final double? inharmonicity;

  /// Which partial of [fittedF0] the detector's own estimate corresponds to.
  ///
  /// 1 means the detector and the spectrum agree. 2 means the detector is an
  /// octave high — it locked onto the second partial. 0.5 means it is an
  /// octave low, having found twice the period. Null when the detector's
  /// answer is not a simple ratio of the fitted fundamental at all, which is
  /// its own kind of warning.
  final double? detectorPartial;

  /// Sum of the measured partials' magnitudes, as a crude loudness.
  final double energy;

  /// Fraction of that energy in the fundamental. Low means a thin, bridge-y
  /// or harmonic-heavy sound — and a detector working harder than it looks.
  final double fundamentalShare;

  const HarmonicProfile({
    required this.partials,
    required this.fittedF0,
    required this.inharmonicity,
    required this.detectorPartial,
    required this.energy,
    required this.fundamentalShare,
  });

  static const empty = HarmonicProfile(
    partials: [],
    fittedF0: 0,
    inharmonicity: null,
    detectorPartial: null,
    energy: 0,
    fundamentalShare: 0,
  );

  bool get isEmpty => partials.isEmpty;

  /// True when the detector is reporting a partial other than the first —
  /// an octave error, or worse.
  bool get detectorOnWrongPartial =>
      detectorPartial != null && (detectorPartial! - 1).abs() > 0.02;

  /// How far a stiff string's own octave is stretched, in cents, at [order]
  /// octaves up. Zero when there is no usable stiffness estimate.
  ///
  /// This is the number stretch tuning is about: on a string with
  /// inharmonicity B, the partial that *sounds* like the octave sits above
  /// 2·f0, so tuning the octave to an exact 2:1 leaves it beating.
  double octaveStretchCents([int order = 1]) {
    final b = inharmonicity;
    if (b == null) return 0;
    final n = math.pow(2, order).toDouble();
    return 1200 * math.log(math.sqrt(1 + b * n * n) / math.sqrt(1 + b)) /
        math.ln2;
  }
}

/// Measures the partials around [coarseF0] in [buffer].
///
/// Takes two Hann-windowed sub-frames of [subSize] samples, [hop] apart, from
/// the end of the buffer, and reads each partial's frequency from how far its
/// phase advanced between them — the phase-vocoder estimator, which resolves
/// far finer than the bin spacing.
///
/// The detector's answer is a starting point, not an assumption: before the
/// partials are fitted, the spectrum is asked whether there is a *lower*
/// fundamental the detector skipped (an octave error upwards), or whether the
/// partial the detector named is missing entirely while its double is strong
/// (an octave error downwards). That is what makes [HarmonicProfile]
/// .detectorPartial mean anything.
///
/// Returns [HarmonicProfile.empty] when nothing usable is there.
HarmonicProfile analyseHarmonics(
  List<double> buffer,
  double coarseF0,
  double sampleRate, {
  int subSize = 2048,
  int hop = 256,
  int maxPartials = 12,

  /// A partial must be at least this loud, relative to the loudest partial
  /// found, to be believed. Without it the search happily "finds" partial 9
  /// of an 8-partial string in the skirt of partial 8.
  double relativeFloor = 0.01,
}) {
  if (coarseF0 <= 0 || buffer.length < subSize + hop) {
    return HarmonicProfile.empty;
  }

  final start2 = buffer.length - subSize;
  final start1 = start2 - hop;
  final window = Float64List(subSize);
  for (int i = 0; i < subSize; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / subSize);
  }

  final fft = FFT(subSize);
  Float64x2List spectrumAt(int start) {
    final frame = Float64List(subSize);
    for (int i = 0; i < subSize; i++) {
      frame[i] = buffer[start + i] * window[i];
    }
    return fft.realFft(frame);
  }

  final s1 = spectrumAt(start1);
  final s2 = spectrumAt(start2);
  final bins = subSize ~/ 2;
  final binWidth = sampleRate / subSize;

  double magnitudeAt(Float64x2List s, int k) =>
      math.sqrt(s[k].x * s[k].x + s[k].y * s[k].y);

  /// The peak nearest [target], with its phase-derived frequency, or null.
  ({double frequency, double magnitude})? peakNear(double target) {
    if (target <= 0 || target > sampleRate * 0.45) return null;
    final centre = (target / binWidth).round();
    if (centre < 2 || centre >= bins - 2) return null;
    final span = math.max(2, (0.04 * centre).round());
    int peak = centre;
    double peakMag = -1;
    for (int k = math.max(1, centre - span);
        k <= math.min(bins - 2, centre + span);
        k++) {
      final m = magnitudeAt(s2, k);
      if (m > peakMag) {
        peakMag = m;
        peak = k;
      }
    }
    if (peakMag <= 0) return null;
    // A peak, not the shoulder of a louder neighbour.
    if (peakMag < magnitudeAt(s2, peak - 1) ||
        peakMag < magnitudeAt(s2, peak + 1)) {
      return null;
    }

    final phase1 = math.atan2(s1[peak].y, s1[peak].x);
    final phase2 = math.atan2(s2[peak].y, s2[peak].x);
    final omega = 2 * math.pi * peak / subSize;
    double residual = (phase2 - phase1) - omega * hop;
    residual -= 2 * math.pi * (residual / (2 * math.pi)).round();
    final f = sampleRate * (peak / subSize + residual / (2 * math.pi * hop));
    if (f <= 0) return null;
    // Refuse to match a partial to the wrong harmonic number: the tolerance
    // is a fraction of the *spacing*, which is what a wrong match crosses.
    if ((f - target).abs() > 0.025 * target + binWidth) return null;
    return (frequency: f, magnitude: peakMag);
  }

  // --- 1. Which fundamental are we actually looking at? -------------------
  //
  // Take the detector's answer, then ask the spectrum two questions it
  // cannot answer for itself.
  double base = coarseF0;
  double detectorRatio = 1.0;

  final atCoarse = peakNear(coarseF0);
  final atDouble = peakNear(coarseF0 * 2);

  // (a) The detector found twice the period — it is an octave (or a twelfth)
  //     low, and the partial it named is not really there.
  if (atDouble != null &&
      (atCoarse == null || atCoarse.magnitude < 0.05 * atDouble.magnitude)) {
    base = coarseF0 * 2;
    detectorRatio = 0.5;
  } else if (atCoarse != null) {
    // (b) The detector locked onto partial 2 or 3: there is a strong peak an
    //     octave or a twelfth *below* it, with the partials to match.
    for (final divisor in const [2.0, 3.0]) {
      final candidate = coarseF0 / divisor;
      final sub = peakNear(candidate);
      if (sub == null || sub.magnitude < 0.05 * atCoarse.magnitude) continue;
      // Require the intervening partials too, or a room resonance below the
      // note would be read as its fundamental.
      bool supported = true;
      for (int n = 2; n < divisor.round(); n++) {
        final between = peakNear(candidate * n);
        if (between == null || between.magnitude < 0.02 * atCoarse.magnitude) {
          supported = false;
          break;
        }
      }
      if (!supported) continue;
      base = candidate;
      detectorRatio = divisor;
      break;
    }
  }

  // --- 2. The partials of that fundamental --------------------------------
  final found = <Partial>[];
  double loudest = 0;
  for (int n = 1; n <= maxPartials; n++) {
    final guess = base * n;
    if (guess > sampleRate * 0.45) break;
    final peak = peakNear(guess);
    if (peak == null) continue;
    if (loudest > 0 && peak.magnitude < relativeFloor * loudest) continue;
    if (peak.magnitude > loudest) loudest = peak.magnitude;
    found.add(Partial(n, peak.frequency, peak.magnitude,
        1200 * math.log(peak.frequency / guess) / math.ln2));
  }
  // A late partial can only be trusted relative to the loudest one, which is
  // not known until the sweep is over.
  found.removeWhere((p) => p.magnitude < relativeFloor * loudest);
  if (found.isEmpty) return HarmonicProfile.empty;

  // --- 3. Fit f0, and the stiffness if there is enough to fit it ----------
  double num = 0, den = 0, energy = 0;
  for (final p in found) {
    num += p.magnitude * p.order * p.frequency;
    den += p.magnitude * p.order * p.order;
    energy += p.magnitude;
  }
  double f0 = den > 0 ? num / den : base;
  double? b;

  if (found.length >= 4) {
    // With stiffness, (f_n/n)² = f0² + f0²B·n²: a straight line in n².
    double sw = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (final p in found) {
      final x = (p.order * p.order).toDouble();
      final y = math.pow(p.frequency / p.order, 2).toDouble();
      final w = p.magnitude;
      sw += w;
      sx += w * x;
      sy += w * y;
      sxx += w * x * x;
      sxy += w * x * y;
    }
    final denom = sw * sxx - sx * sx;
    if (denom != 0) {
      final slope = (sw * sxy - sx * sy) / denom;
      final intercept = (sy * sxx - sx * sxy) / denom;
      if (intercept > 0) {
        final fitted = math.sqrt(intercept);
        final coefficient = slope / intercept;
        // How well does that model actually describe these partials? A noisy
        // frame will happily produce a line through nonsense, so the fit has
        // to earn its place: every partial within 15 cents of where the model
        // says it is.
        double worst = 0;
        for (final p in found) {
          final model = fitted *
              p.order *
              math.sqrt(1 + coefficient * p.order * p.order);
          final cents = (1200 * math.log(p.frequency / model) / math.ln2).abs();
          if (cents > worst) worst = cents;
        }
        // A guitar's B is ~1e-5 to 1e-4, a piano bass string's up to ~1e-2.
        if (coefficient.isFinite &&
            coefficient >= 0 &&
            coefficient < 1e-2 &&
            worst < 15 &&
            (fitted - base).abs() < 0.06 * base) {
          f0 = fitted;
          b = coefficient;
        }
      }
    }
  }

  // --- 4. Which partial of that is the detector reporting? ----------------
  double? detectorPartial;
  if (f0 > 0) {
    final ratio = coarseF0 / f0;
    for (final candidate in const [0.25, 1 / 3, 0.5, 1.0, 2.0, 3.0, 4.0]) {
      if ((1200 * math.log(ratio / candidate) / math.ln2).abs() < 35) {
        detectorPartial = candidate;
        break;
      }
    }
    detectorPartial ??= detectorRatio;
  }

  final fundamental = found.firstWhere((p) => p.order == 1,
      orElse: () => const Partial(0, 0, 0, 0));

  return HarmonicProfile(
    partials: List.unmodifiable(found),
    fittedF0: f0,
    inharmonicity: b,
    detectorPartial: detectorPartial,
    energy: energy,
    fundamentalShare: energy > 0 ? fundamental.magnitude / energy : 0,
  );
}
