/// The pitch detectors themselves, with **no Flutter dependency at all**.
///
/// Until now the app called `pitch_detector_dart` directly from `main.dart`
/// and there was exactly one way to find a pitch. Two things changed that:
///
///   * measuring the package (see `bench/REPORT.md` §3.3) showed its textbook
///     O(N²) difference function costs 210–240% of one audio callback's
///     budget at a 4096-sample window — more time than the audio it is
///     analysing takes to arrive. The identical calculation by FFT costs
///     7–8%. That is not a tuning parameter, it is the difference between
///     keeping up and not;
///   * once the detector is a seam rather than a call, alternatives can be
///     offered and, more to the point, *measured against each other on the
///     same audio* rather than argued about.
///
/// [YinEngine] is the default and reproduces the shipped package exactly:
/// same window convention, same threshold, same first-dip-below-threshold
/// rule, same parabolic interpolation, same `probability`. `test/` asserts
/// that frame by frame against `pitch_detector_dart` itself, which is kept as
/// a dev dependency purely so that assertion can exist.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'fft_real.dart';

/// One frame's answer from a detector.
class PitchEstimate {
  /// Hz, or -1 when nothing periodic was found.
  final double frequency;

  /// How periodic the frame was, in [0, 1]. For YIN this is
  /// `1 - aperiodicity` at the chosen lag; the app's gate wants > 0.9.
  final double probability;

  final bool pitched;

  const PitchEstimate(this.frequency, this.probability, this.pitched);

  static const unpitched = PitchEstimate(-1, 0, false);
}

/// Which detector the app is using.
///
/// The names are persisted in settings, so do not rename them.
enum DetectorKind {
  /// YIN, as the app has always used it, but with the difference function
  /// computed by FFT. Identical answers, a fraction of the arithmetic.
  yin,

  /// McLeod's normalised square difference function. Answers on far more
  /// frames than YIN — and wrongly on more of them too. Offered because on
  /// a quiet instrument with a weak signal its willingness to commit is
  /// sometimes what you want.
  mpm,
}

/// Anything that can turn a window of audio into a pitch.
abstract class PitchEngine {
  const PitchEngine();

  DetectorKind get kind;

  /// The analysis window this engine was built for, in samples.
  int get windowSize;

  /// Lowest frequency this engine can represent at all, given its window.
  double get detectionFloor;

  /// Analyse one window. Must not retain [window].
  PitchEstimate analyse(List<double> window);

  factory PitchEngine.of(
    DetectorKind kind, {
    required double sampleRate,
    required int windowSize,
  }) =>
      switch (kind) {
        DetectorKind.yin =>
          YinEngine(sampleRate: sampleRate, windowSize: windowSize),
        DetectorKind.mpm =>
          MpmEngine(sampleRate: sampleRate, windowSize: windowSize),
      };
}

/// The lag-domain machinery both detectors share.
///
/// YIN's difference function and MPM's NSDF are the same two sums — the
/// energy of each half-lapped segment, and their correlation — combined
/// differently. Both are computed here once, by FFT.
class _LagDomain {
  final int windowSize;
  final int halfSize;
  final Float64List squares; // prefix sums of x²
  final Float64List correlation; // r(tau) for tau in [0, halfSize)
  final FftAutocorrelation _autocorrelation;

  _LagDomain(int windowSize)
      : windowSize = windowSize,
        halfSize = windowSize ~/ 2,
        squares = Float64List(windowSize + 1),
        correlation = Float64List(windowSize ~/ 2),
        _autocorrelation = FftAutocorrelation(
          headLength: windowSize ~/ 2,
          wholeLength: windowSize,
          lags: windowSize ~/ 2,
        );

  /// r(tau) = Σ_{i<W} x[i]·x[i+tau], by FFT.
  ///
  /// Reversing the first half turns correlation into convolution, so one
  /// forward transform of each side and one inverse gives every lag at once:
  /// O(N log N) where the double loop is O(N²).
  ///
  /// The transform is `fft_real.dart` rather than `fftea` for one measured
  /// reason: `fftea` returns a `Float64x2List`, dart2js has no SIMD, and in a
  /// browser that makes a single 8192-point transform cost 15.6 ms against
  /// 0.38 ms natively. See the table in `fft_real.dart`.
  void compute(List<double> window) {
    squares[0] = 0;
    for (int i = 0; i < windowSize; i++) {
      squares[i + 1] = squares[i] + window[i] * window[i];
    }
    _autocorrelation.compute(window, correlation);
  }

  /// Σ x[i]² over the first half — the head segment's energy.
  double get headEnergy => squares[halfSize];

  /// Σ x[i+tau]² over the lagged segment.
  double tailEnergy(int tau) => squares[halfSize + tau] - squares[tau];
}

/// YIN (de Cheveigné & Kawahara 2002), with the difference function by FFT.
///
/// The window convention is the package's and therefore the app's: the
/// difference function reads the first half of the window and searches lags
/// up to that half, so the lowest representable frequency is
/// `2 * sampleRate / windowSize` — 21.5 Hz at 4096 samples, below the bottom
/// of a piano.
class YinEngine extends PitchEngine {
  final double sampleRate;
  @override
  final int windowSize;
  final int halfSize;

  /// The aperiodicity below which a dip is accepted as the period.
  ///
  /// 0.20, which is the package's default and which the package's own comment
  /// calls too loose. Measured over GuitarSet it is at the *minimum* of the
  /// octave-error curve: the rate rises both as the threshold is tightened
  /// (1.95% at 0.20, 2.22% at 0.10) and as it is loosened (2.81% at 0.40).
  /// Tightening it makes the first dip — the true period's — stop qualifying,
  /// and the search runs on to a deeper dip at twice the period. See
  /// `bench/REPORT.md` §3.1 before changing this.
  final double threshold;

  /// Use the textbook O(N²) double loop instead of the FFT. Only the
  /// equivalence test wants this; it is ~10× slower for identical output.
  final bool naiveDifference;

  final Float64List _yin;
  final _LagDomain _lags;

  YinEngine({
    required this.sampleRate,
    required this.windowSize,
    this.threshold = 0.20,
    this.naiveDifference = false,
  })  : halfSize = windowSize ~/ 2,
        _yin = Float64List(windowSize ~/ 2),
        _lags = _LagDomain(windowSize);

  @override
  DetectorKind get kind => DetectorKind.yin;

  @override
  double get detectionFloor => 2 * sampleRate / windowSize;

  @override
  PitchEstimate analyse(List<double> window) {
    _difference(window);
    _cumulativeMeanNormalise();

    // Step 4: the first dip below the threshold, walked down to its local
    // minimum. Biased towards short lags, which is what keeps it off the
    // sub-octave.
    int tau;
    for (tau = 2; tau < halfSize; tau++) {
      if (_yin[tau] < threshold) {
        while (tau + 1 < halfSize && _yin[tau + 1] < _yin[tau]) {
          tau++;
        }
        break;
      }
    }
    if (tau >= halfSize || _yin[tau] >= threshold) {
      return PitchEstimate.unpitched;
    }

    final betterTau = _parabolicInterpolation(tau);
    if (betterTau <= 0) return PitchEstimate.unpitched;
    return PitchEstimate(sampleRate / betterTau, 1 - _yin[tau], true);
  }

  void _difference(List<double> window) {
    if (naiveDifference) {
      for (int tau = 1; tau < halfSize; tau++) {
        double sum = 0;
        for (int i = 0; i < halfSize; i++) {
          final delta = window[i] - window[i + tau];
          sum += delta * delta;
        }
        _yin[tau] = sum;
      }
      _yin[0] = 0;
      return;
    }
    // d(tau) = Σ(x[i] - x[i+tau])² = Σx[i]² + Σx[i+tau]² - 2·r(tau)
    _lags.compute(window);
    _yin[0] = 0;
    final head = _lags.headEnergy;
    for (int tau = 1; tau < halfSize; tau++) {
      final d = head + _lags.tailEnergy(tau) - 2 * _lags.correlation[tau];
      _yin[tau] = d > 0 ? d : 0;
    }
  }

  void _cumulativeMeanNormalise() {
    _yin[0] = 1;
    double runningSum = 0;
    for (int tau = 1; tau < halfSize; tau++) {
      runningSum += _yin[tau];
      _yin[tau] = runningSum == 0 ? 1 : _yin[tau] * tau / runningSum;
    }
  }

  /// Step 5, including the sign fix the package carries.
  double _parabolicInterpolation(int tauEstimate) {
    final int x0 = tauEstimate < 1 ? tauEstimate : tauEstimate - 1;
    final int x2 = tauEstimate + 1 < halfSize ? tauEstimate + 1 : tauEstimate;
    if (x0 == tauEstimate) {
      return _yin[tauEstimate] <= _yin[x2]
          ? tauEstimate.toDouble()
          : x2.toDouble();
    }
    if (x2 == tauEstimate) {
      return _yin[tauEstimate] <= _yin[x0]
          ? tauEstimate.toDouble()
          : x0.toDouble();
    }
    final s0 = _yin[x0], s1 = _yin[tauEstimate], s2 = _yin[x2];
    final denom = 2 * (2 * s1 - s2 - s0);
    if (denom == 0) return tauEstimate.toDouble();
    return tauEstimate + (s2 - s0) / denom;
  }
}

/// McLeod's MPM: the normalised square difference function.
///
/// Where YIN normalises by a running mean and takes the first dip below a
/// threshold, MPM normalises by the energy of the two segments and takes the
/// first *peak* that clears a fixed fraction of the highest one. That rule is
/// symmetric where YIN's is one-sided, which is supposed to make it robust to
/// octave errors in both directions.
///
/// Measured over GuitarSet it answers on 96% of frames against YIN's 86% and
/// is more accurate per reference frame — at the price of a 57% voicing
/// false-alarm rate against YIN's 34%, and twice the gross-error rate. For a
/// tuner that trade is usually the wrong way round, which is why this is the
/// alternative and not the default.
class MpmEngine extends PitchEngine {
  final double sampleRate;
  @override
  final int windowSize;
  final int halfSize;

  /// Fraction of the highest NSDF peak a peak must reach to be taken.
  final double cutoff;

  /// Reject the frame when even the best peak is this unclear.
  final double clarityFloor;

  final Float64List _nsdf;
  final _LagDomain _lags;

  MpmEngine({
    required this.sampleRate,
    required this.windowSize,
    this.cutoff = 0.9,
    this.clarityFloor = 0.5,
  })  : halfSize = windowSize ~/ 2,
        _nsdf = Float64List(windowSize ~/ 2),
        _lags = _LagDomain(windowSize);

  @override
  DetectorKind get kind => DetectorKind.mpm;

  @override
  double get detectionFloor => 2 * sampleRate / windowSize;

  @override
  PitchEstimate analyse(List<double> window) {
    _lags.compute(window);
    final head = _lags.headEnergy;
    for (int tau = 0; tau < halfSize; tau++) {
      final m = head + _lags.tailEnergy(tau);
      _nsdf[tau] = m > 0 ? 2 * _lags.correlation[tau] / m : 0;
    }

    // One maximum per positive stretch, skipping the lobe around tau = 0.
    int tau = 1;
    while (tau < halfSize - 1 && _nsdf[tau] > 0) {
      tau++;
    }
    int chosen = -1;
    double highest = 0;
    final peaks = <int>[];
    while (tau < halfSize - 1) {
      if (_nsdf[tau] > 0 && _nsdf[tau - 1] <= 0) {
        int best = tau;
        while (tau < halfSize - 1 && _nsdf[tau] > 0) {
          if (_nsdf[tau] > _nsdf[best]) best = tau;
          tau++;
        }
        peaks.add(best);
        if (_nsdf[best] > highest) highest = _nsdf[best];
      } else {
        tau++;
      }
    }
    if (peaks.isEmpty || highest < clarityFloor) return PitchEstimate.unpitched;

    final limit = cutoff * highest;
    for (final p in peaks) {
      if (_nsdf[p] >= limit) {
        chosen = p;
        break;
      }
    }
    if (chosen < 0) return PitchEstimate.unpitched;

    final period = _parabolic(chosen);
    if (period <= 0) return PitchEstimate.unpitched;
    return PitchEstimate(
        sampleRate / period, _nsdf[chosen].clamp(0.0, 1.0), true);
  }

  double _parabolic(int i) {
    if (i <= 0 || i >= _nsdf.length - 1) return i.toDouble();
    final denom = _nsdf[i - 1] - 2 * _nsdf[i] + _nsdf[i + 1];
    if (denom == 0) return i.toDouble();
    final shift = 0.5 * (_nsdf[i - 1] - _nsdf[i + 1]) / denom;
    return i + (shift.abs() < 1 ? shift : 0);
  }
}

/// Cents between two frequencies, for callers that do not want the whole of
/// `tuner_core.dart`.
double centsBetween(double a, double b) =>
    (a <= 0 || b <= 0) ? 0 : 1200 * math.log(a / b) / math.ln2;
