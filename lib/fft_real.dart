/// A radix-2 FFT over one interleaved `Float64List`, with **no Flutter and no
/// `Float64x2`**.
///
/// The app already depends on `fftea`, which is faster than this on a native
/// VM and is still what the spectrum display uses. This exists for one
/// measured reason: `fftea` hands back a `Float64x2List`, and **dart2js has
/// no SIMD**, so in a browser every complex element becomes a JavaScript
/// object. Measured on this project's own detector, same machine, same code:
///
/// | | native Dart | dart2js |
/// | --- | --- | --- |
/// | one 8192-point `fftea` real FFT | 0.38 ms | **15.56 ms** |
/// | YIN with the FFT difference function | 1.33 ms | 49.78 ms |
/// | YIN with the textbook O(N²) loop | 8.29 ms | 16.40 ms |
///
/// A factor of 41 on the transform, and — the part that matters — the FFT
/// difference function that is 6× *faster* than the double loop natively is
/// 3× *slower* than it in a browser. The optimisation inverts across the
/// platforms this app ships on, which is not something you can reason your
/// way to.
///
/// Storing the complex array as `[re0, im0, re1, im1, …]` in a plain
/// `Float64List` keeps it a single `Float64Array` in JavaScript, with no
/// per-element allocation.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// An in-place iterative radix-2 FFT for a fixed power-of-two size.
///
/// Twiddle factors and the bit-reversal permutation are precomputed once, so
/// a repeated transform of the same size — which is exactly what a tuner does
/// — costs only the butterflies.
class RealFft {
  /// Transform length in complex points.
  final int size;

  final Float64List _cos;
  final Float64List _sin;
  final Int32List _reversed;

  RealFft(this.size)
      : _cos = Float64List(size ~/ 2),
        _sin = Float64List(size ~/ 2),
        _reversed = Int32List(size) {
    if (size < 2 || (size & (size - 1)) != 0) {
      throw ArgumentError.value(size, 'size', 'must be a power of two');
    }
    for (int i = 0; i < size ~/ 2; i++) {
      final angle = -2 * math.pi * i / size;
      _cos[i] = math.cos(angle);
      _sin[i] = math.sin(angle);
    }
    int bits = 0;
    while ((1 << bits) < size) {
      bits++;
    }
    for (int i = 0; i < size; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _reversed[i] = r;
    }
  }

  /// A buffer of the right length for [transform]: interleaved re/im.
  Float64List newBuffer() => Float64List(size * 2);

  /// In-place complex FFT of [data], interleaved as `[re, im, re, im, …]`.
  ///
  /// [inverse] computes the unnormalised inverse; divide by [size] yourself
  /// if you need the scaling, which the autocorrelation below folds in.
  void transform(Float64List data, {bool inverse = false}) {
    // Bit-reversal permutation.
    for (int i = 0; i < size; i++) {
      final j = _reversed[i];
      if (j > i) {
        final ir = i * 2, jr = j * 2;
        final tr = data[ir], ti = data[ir + 1];
        data[ir] = data[jr];
        data[ir + 1] = data[jr + 1];
        data[jr] = tr;
        data[jr + 1] = ti;
      }
    }

    for (int span = 1; span < size; span <<= 1) {
      final step = size ~/ (span * 2);
      for (int start = 0; start < size; start += span * 2) {
        int twiddle = 0;
        for (int k = start; k < start + span; k++) {
          final wr = _cos[twiddle];
          final wi = inverse ? -_sin[twiddle] : _sin[twiddle];
          twiddle += step;

          final a = k * 2;
          final b = (k + span) * 2;
          final br = data[b], bi = data[b + 1];
          final tr = br * wr - bi * wi;
          final ti = br * wi + bi * wr;
          data[b] = data[a] - tr;
          data[b + 1] = data[a + 1] - ti;
          data[a] = data[a] + tr;
          data[a + 1] = data[a + 1] + ti;
        }
      }
    }
  }
}

/// Autocorrelation `r(tau) = Σ_i x[i]·x[i+tau]` for `tau` in `[0, lags)`,
/// by FFT, with no `Float64x2` anywhere.
///
/// [head] is the segment correlated against [whole]; YIN correlates the first
/// half of its window against all of it.
class FftAutocorrelation {
  final int headLength;
  final int wholeLength;
  final int lags;
  final RealFft _fft;
  final Float64List _a;
  final Float64List _b;

  FftAutocorrelation({
    required this.headLength,
    required this.wholeLength,
    required this.lags,
  })  : _fft = RealFft(_sizeFor(headLength + wholeLength)),
        _a = Float64List(_sizeFor(headLength + wholeLength) * 2),
        _b = Float64List(_sizeFor(headLength + wholeLength) * 2);

  static int _sizeFor(int n) {
    int p = 1;
    while (p < n) {
      p <<= 1;
    }
    return p;
  }

  /// Fills [out] with `r(0 … lags-1)`.
  void compute(List<double> window, Float64List out) {
    final n = _fft.size;
    for (int i = 0; i < n * 2; i++) {
      _a[i] = 0;
      _b[i] = 0;
    }
    // Reversing the head turns correlation into convolution.
    for (int i = 0; i < headLength; i++) {
      _a[(headLength - 1 - i) * 2] = window[i];
    }
    for (int i = 0; i < wholeLength; i++) {
      _b[i * 2] = window[i];
    }

    _fft.transform(_a);
    _fft.transform(_b);

    // Pointwise complex multiply, in place into _a.
    for (int i = 0; i < n; i++) {
      final ar = _a[i * 2], ai = _a[i * 2 + 1];
      final br = _b[i * 2], bi = _b[i * 2 + 1];
      _a[i * 2] = ar * br - ai * bi;
      _a[i * 2 + 1] = ar * bi + ai * br;
    }

    _fft.transform(_a, inverse: true);

    final scale = 1.0 / n;
    for (int tau = 0; tau < lags; tau++) {
      out[tau] = _a[(headLength - 1 + tau) * 2] * scale;
    }
  }
}

/// Magnitude spectrum of a real signal, for the display.
///
/// Same reason as [FftAutocorrelation]: the spectrum is recomputed at display
/// rate on the audio path, and doing it through a `Float64x2List` costs a
/// browser 15 ms a frame.
class RealSpectrum {
  final int size;
  final RealFft _fft;
  final Float64List _buffer;

  RealSpectrum(this.size)
      : _fft = RealFft(size),
        _buffer = Float64List(size * 2);

  /// Magnitudes of the first `size / 2` bins of [windowed], which the caller
  /// has already windowed. Writes into [out], which must hold at least
  /// [bins] entries.
  void magnitudes(Float64List windowed, Float64List out, int bins) {
    for (int i = 0; i < size; i++) {
      _buffer[i * 2] = windowed[i];
      _buffer[i * 2 + 1] = 0;
    }
    _fft.transform(_buffer);
    final limit = bins < size ~/ 2 ? bins : size ~/ 2;
    for (int i = 0; i < limit; i++) {
      final re = _buffer[i * 2], im = _buffer[i * 2 + 1];
      out[i] = math.sqrt(re * re + im * im);
    }
  }
}
