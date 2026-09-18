/// McLeod's MPM (the normalised square difference function), as a comparison
/// point for YIN.
///
/// NSDF is YIN's difference function normalised by the energy of the two
/// segments rather than by a running mean, and the period is picked from the
/// *maxima* between positive zero crossings, taking the first maximum that
/// clears a fixed fraction of the largest. That "first one that is nearly as
/// good as the best" rule is what is supposed to make it robust to octave
/// errors in both directions, where YIN's threshold is one-sided.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

import 'yin.dart' show YinResult;

class Mpm {
  final double sampleRate;
  final int bufferSize;
  final int halfSize;

  /// Fraction of the highest NSDF peak a peak must reach to be accepted;
  /// McLeod suggests 0.8–0.9.
  final double cutoff;

  /// Reject the frame when even the best peak is this unclear.
  final double clarityFloor;

  FFT? _fft;
  int _fftSize = 0;

  Mpm({
    required this.sampleRate,
    required this.bufferSize,
    this.cutoff = 0.9,
    this.clarityFloor = 0.5,
  }) : halfSize = bufferSize ~/ 2;

  YinResult getPitch(List<double> buffer) {
    final nsdf = _nsdf(buffer);

    // Peaks between positive zero crossings, one per crossing interval.
    final peaks = <int>[];
    int tau = 1;
    while (tau < halfSize - 1 && nsdf[tau] > 0) {
      tau++; // skip the initial lobe around tau = 0
    }
    while (tau < halfSize - 1) {
      if (nsdf[tau] > 0 && nsdf[tau - 1] <= 0) {
        // Entering a positive stretch; take its maximum.
        int best = tau;
        while (tau < halfSize - 1 && nsdf[tau] > 0) {
          if (nsdf[tau] > nsdf[best]) best = tau;
          tau++;
        }
        peaks.add(best);
      } else {
        tau++;
      }
    }
    if (peaks.isEmpty) return YinResult.unpitched;

    double highest = 0;
    for (final p in peaks) {
      if (nsdf[p] > highest) highest = nsdf[p];
    }
    if (highest < clarityFloor) return YinResult.unpitched;

    final limit = cutoff * highest;
    int chosen = peaks.first;
    for (final p in peaks) {
      if (nsdf[p] >= limit) {
        chosen = p;
        break;
      }
    }

    final period = _parabolic(nsdf, chosen);
    if (period <= 0) return YinResult.unpitched;
    return YinResult(sampleRate / period, nsdf[chosen].clamp(0.0, 1.0), true);
  }

  Float64List _nsdf(List<double> buffer) {
    final w = halfSize;
    int n = 1;
    while (n < 2 * bufferSize) {
      n <<= 1;
    }
    if (_fft == null || _fftSize != n) {
      _fft = FFT(n);
      _fftSize = n;
    }
    final fft = _fft!;

    final squares = Float64List(bufferSize + 1);
    for (int i = 0; i < bufferSize; i++) {
      squares[i + 1] = squares[i] + buffer[i] * buffer[i];
    }

    final a = Float64List(n);
    final b = Float64List(n);
    for (int i = 0; i < w; i++) {
      a[w - 1 - i] = buffer[i];
    }
    for (int i = 0; i < bufferSize; i++) {
      b[i] = buffer[i];
    }
    final fa = fft.realFft(a);
    fa.complexMultiply(fft.realFft(b));
    final conv = fft.realInverseFft(fa);

    final out = Float64List(w);
    for (int tau = 0; tau < w; tau++) {
      final r = conv[w - 1 + tau];
      final m = squares[w] + (squares[w + tau] - squares[tau]);
      out[tau] = m > 0 ? 2 * r / m : 0;
    }
    return out;
  }

  double _parabolic(Float64List f, int i) {
    if (i <= 0 || i >= f.length - 1) return i.toDouble();
    final denom = f[i - 1] - 2 * f[i] + f[i + 1];
    if (denom == 0) return i.toDouble();
    final shift = 0.5 * (f[i - 1] - f[i + 1]) / denom;
    return i + (shift.abs() < 1 ? shift : 0);
  }
}

/// Convenience for reporting: cents between two frequencies.
double centsBetween(double a, double b) =>
    (a <= 0 || b <= 0) ? 0 : 1200 * math.log(a / b) / math.ln2;
