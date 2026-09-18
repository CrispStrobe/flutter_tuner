/// YIN, and the pieces of it the shipped package leaves out.
///
/// `pitch_detector_dart` 0.0.7 is a port of TarsosDSP's `Yin`, which is itself
/// a port of aubio's. Three things in it are worth measuring rather than
/// arguing about:
///
///   * its `defaultThreshold` is 0.20, while its own comment says the paper's
///     value "should be around 0.10~0.15";
///   * step 6 of the paper (best local estimate) is a `TODO`;
///   * the difference function is the textbook O(N²) double loop.
///
/// [RefYin] reproduces the package exactly at its defaults — `bin/verify.dart`
/// asserts that frame by frame on real audio — and then lets each of those
/// three be varied independently, so the effect of each can be attributed.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// How the tau of the period is chosen from the cumulative mean normalised
/// difference function.
enum TauSelection {
  /// aubio/TarsosDSP, and therefore the shipped app: the *first* dip below
  /// the threshold, walked down to its local minimum. Cheap, and biased
  /// towards short lags — i.e. towards the octave above.
  firstDipBelowThreshold,

  /// The global minimum of the CMNDF, accepted if it falls below the
  /// threshold. Biased the other way, towards long lags.
  globalMinimum,
}

class PitchCandidate {
  final double tau;
  final double frequency;

  /// The CMNDF value at the chosen tau — the YIN paper's "aperiodicity".
  final double aperiodicity;
  const PitchCandidate(this.tau, this.frequency, this.aperiodicity);
}

class YinResult {
  final double pitch; // Hz, or -1
  final double probability; // 1 - aperiodicity, or 0
  final bool pitched;
  const YinResult(this.pitch, this.probability, this.pitched);
  static const unpitched = YinResult(-1, 0, false);
}

/// A YIN whose every step is a parameter.
///
/// [bufferSize] is the analysis window handed in; as in the package, the
/// difference function uses the first half of it and searches lags up to that
/// half, so the lowest representable frequency is `2 * sampleRate /
/// bufferSize`.
class RefYin {
  final double sampleRate;
  final int bufferSize;
  final int halfSize;
  final double threshold;
  final TauSelection selection;

  /// Step 6 of the YIN paper, approximated within the frame: rather than
  /// accepting the first dip, take the lowest CMNDF minimum within ±20% of
  /// it. The paper re-estimates over a *longer* window than the frame; we
  /// have only the frame, so this is the in-frame version of the same idea.
  final bool bestLocalEstimate;

  /// Compute the difference function by FFT (O(N log N)) instead of the
  /// package's double loop (O(N²)). Numerically equivalent to ~1e-9.
  final bool useFft;

  final Float64List _yin;
  final Float64List _prefixSquares;
  FFT? _fft;
  Float64List? _fftIn;

  RefYin({
    required this.sampleRate,
    required this.bufferSize,
    this.threshold = 0.20,
    this.selection = TauSelection.firstDipBelowThreshold,
    this.bestLocalEstimate = false,
    this.useFft = false,
  })  : halfSize = bufferSize ~/ 2,
        _yin = Float64List(bufferSize ~/ 2),
        _prefixSquares = Float64List(bufferSize + 1);

  /// The CMNDF for this frame. Exposed because every threshold shares it:
  /// sweeping thresholds costs one difference function, not one per value.
  Float64List cmndf(List<double> buffer) {
    if (useFft) {
      _differenceFft(buffer);
    } else {
      _differenceNaive(buffer);
    }
    _cumulativeMeanNormalise();
    return _yin;
  }

  YinResult getPitch(List<double> buffer) {
    cmndf(buffer);
    return resultFromCmndf(threshold);
  }

  /// Read a pitch out of the CMNDF already computed by [cmndf].
  ///
  /// The threshold and the two decision rules can be overridden per call:
  /// sweeping them costs nothing once the difference function exists, which
  /// is the whole reason this is separate from [getPitch].
  YinResult resultFromCmndf(double thr,
      {TauSelection? selection, bool? bestLocal}) {
    final tau = _selectTau(thr, selection ?? this.selection);
    if (tau < 0) return YinResult.unpitched;
    final refined =
        (bestLocal ?? bestLocalEstimate) ? _bestLocalEstimate(tau) : tau;
    final betterTau = _parabolicInterpolation(refined);
    if (betterTau <= 0) return YinResult.unpitched;
    return YinResult(sampleRate / betterTau, 1 - _yin[refined], true);
  }

  /// Every local minimum of the CMNDF below [maxAperiodicity], as pYIN needs
  /// them: one difference function, a whole candidate distribution.
  List<PitchCandidate> candidates({double maxAperiodicity = 0.9}) {
    final out = <PitchCandidate>[];
    for (int tau = 2; tau < halfSize - 1; tau++) {
      if (_yin[tau] < _yin[tau - 1] &&
          _yin[tau] <= _yin[tau + 1] &&
          _yin[tau] < maxAperiodicity) {
        final better = _parabolicInterpolation(tau);
        if (better > 0) {
          out.add(PitchCandidate(better, sampleRate / better, _yin[tau]));
        }
      }
    }
    return out;
  }

  int _selectTau(double thr, TauSelection selection) {
    switch (selection) {
      case TauSelection.firstDipBelowThreshold:
        // Exactly the package's loop, threshold made a parameter.
        int tau;
        for (tau = 2; tau < halfSize; tau++) {
          if (_yin[tau] < thr) {
            while (tau + 1 < halfSize && _yin[tau + 1] < _yin[tau]) {
              tau++;
            }
            break;
          }
        }
        if (tau == halfSize || _yin[tau] >= thr) return -1;
        return tau;
      case TauSelection.globalMinimum:
        int best = -1;
        double bestValue = double.infinity;
        for (int tau = 2; tau < halfSize; tau++) {
          if (_yin[tau] < bestValue) {
            bestValue = _yin[tau];
            best = tau;
          }
        }
        return (best >= 0 && bestValue < thr) ? best : -1;
    }
  }

  /// The lowest CMNDF minimum within ±20% of [tau0].
  ///
  /// The point is octave errors: when the first dip below the threshold sits
  /// at half the true period, the true period's deeper dip is usually within
  /// this window, and taking the deeper one corrects the frame.
  int _bestLocalEstimate(int tau0) {
    final lo = math.max(2, (tau0 * 0.8).floor());
    final hi = math.min(halfSize - 1, (tau0 * 1.2).ceil());
    int best = tau0;
    for (int tau = lo; tau <= hi; tau++) {
      if (_yin[tau] < _yin[best]) best = tau;
    }
    return best;
  }

  /// Step 2, as the package writes it: ~N²/4 multiply-adds a frame.
  void _differenceNaive(List<double> buffer) {
    for (int tau = 0; tau < halfSize; tau++) {
      _yin[tau] = 0;
    }
    for (int tau = 1; tau < halfSize; tau++) {
      double sum = 0;
      for (int i = 0; i < halfSize; i++) {
        final delta = buffer[i] - buffer[i + tau];
        sum += delta * delta;
      }
      _yin[tau] = sum;
    }
  }

  /// Step 2 by FFT.
  ///
  /// d(tau) = Σ(x[i] - x[i+tau])² expands to
  ///   Σx[i]² + Σx[i+tau]² - 2·r(tau)
  /// The two power terms are prefix sums; the autocorrelation r(tau) is one
  /// forward and one inverse transform. Zero-padded past 3·W/2 so the
  /// circular correlation cannot wrap onto the lags we read.
  void _differenceFft(List<double> buffer) {
    final w = halfSize;
    int n = 1;
    while (n < 2 * bufferSize) {
      n <<= 1;
    }
    if (_fft == null || _fftIn!.length != n) {
      _fft = FFT(n);
      _fftIn = Float64List(n);
    }
    final fft = _fft!;

    _prefixSquares[0] = 0;
    for (int i = 0; i < bufferSize; i++) {
      _prefixSquares[i + 1] = _prefixSquares[i] + buffer[i] * buffer[i];
    }

    // r(tau) = Σ_{i<W} x[i]·x[i+tau]: correlate the head against the whole
    // buffer. Reversing the head turns correlation into convolution.
    final a = Float64List(n);
    final b = Float64List(n);
    for (int i = 0; i < w; i++) {
      a[w - 1 - i] = buffer[i];
    }
    for (int i = 0; i < bufferSize; i++) {
      b[i] = buffer[i];
    }
    final fa = fft.realFft(a);
    final fb = fft.realFft(b);
    fa.complexMultiply(fb);
    final conv = fft.realInverseFft(fa);

    _yin[0] = 0;
    for (int tau = 1; tau < w; tau++) {
      final head = _prefixSquares[w];
      final tail = _prefixSquares[w + tau] - _prefixSquares[tau];
      final r = conv[w - 1 + tau];
      final d = head + tail - 2 * r;
      _yin[tau] = d > 0 ? d : 0;
    }
  }

  void _cumulativeMeanNormalise() {
    _yin[0] = 1;
    double runningSum = 0;
    for (int tau = 1; tau < halfSize; tau++) {
      runningSum += _yin[tau];
      if (runningSum == 0) {
        _yin[tau] = 1;
      } else {
        _yin[tau] *= tau / runningSum;
      }
    }
  }

  /// Step 5, verbatim from the package (including its fixed sign).
  double _parabolicInterpolation(final int tauEstimate) {
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
