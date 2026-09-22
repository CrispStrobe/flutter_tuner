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
///
/// Everything this file computes is the transform of a **real** signal, so
/// [RealFft.realForward] and [RealFft.realInverse] do it the real way: N real
/// samples read as N/2 complex points, one half-length complex transform, one
/// O(N) untangle. The name used to be a promise the file did not keep — it
/// zero-filled the imaginary parts and ran the full complex transform, which
/// spends half its arithmetic on zeros. Measured per call, median of three
/// processes on one arm each (see `bench/bin/fft_real_timing.dart`):
///
/// | | native, complex | native, real | dart2js, complex | dart2js, real |
/// | --- | --- | --- | --- | --- |
/// | spectrum, N = 4096 | 0.284 ms | 0.179 ms | 0.923 ms | 0.433 ms |
/// | YIN autocorrelation, N = 8192 | 2.455 ms | 1.125 ms | 5.423 ms | 3.780 ms |
///
/// Roughly 1.6× on both — the browser gains at least as much as the native
/// VM, which is the platform this file was written for. The VPS the numbers
/// came from is shared and was at load ~11 on four cores, so read the ratios
/// and not the absolutes; `bench-platforms.yml` runs the same arms on Apple
/// Silicon, x86-64 Linux and Windows.
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

  // --- The real-input path -------------------------------------------
  //
  // Feeding `transform` a real signal with the imaginary parts zeroed does
  // the full complex job on half a buffer of zeros. The standard remedy is
  // to read the N real samples as N/2 *complex* points — even samples into
  // the real parts, odd into the imaginary — run the half-length complex
  // transform, and untangle the two interleaved spectra afterwards with one
  // O(N) pass. The untangle needs the same twiddle table the top butterfly
  // stage of a full-length transform would have used, which `_cos`/`_sin`
  // already are, so it costs no extra memory.
  //
  //   E[k] = (Z[k] + conj(Z[M-k])) / 2          (the even samples)
  //   O[k] = -i (Z[k] - conj(Z[M-k])) / 2       (the odd samples)
  //   X[k] = E[k] + W_N^k O[k],  X[N-k] = conj(X[k])

  RealFft? _half;
  Float64List? _halfBuffer;

  RealFft get _halfFft => _half ??= RealFft(size >> 1);
  Float64List get _halfBuf => _halfBuffer ??= Float64List(size);

  /// Forward FFT of [input], `size` **real** samples, into [out], which must
  /// hold `size * 2` doubles and receives the full interleaved complex
  /// spectrum `[re0, im0, re1, im1, …]` — bin for bin, sign for sign, what
  /// [transform] produces from the same signal with zeroed imaginary parts.
  ///
  /// The upper half is the conjugate mirror of the lower, as it must be for
  /// a real signal; it is written out rather than left to the caller so that
  /// this is a drop-in for the complex path. [input] is not modified.
  void realForward(Float64List input, Float64List out) {
    final m = size >> 1;
    if (m < 2) {
      // N = 2: the transform is a single butterfly.
      final a = input[0], b = input[1];
      out[0] = a + b;
      out[1] = 0;
      out[2] = a - b;
      out[3] = 0;
      return;
    }

    final buf = _halfBuf;
    // x[2j] -> Re z[j], x[2j+1] -> Im z[j] is exactly the interleaved layout
    // `input` already has, so the pack is a copy.
    buf.setRange(0, size, input);
    _halfFft.transform(buf);

    // k = 0 and k = M are their own conjugate partners, and Z[M] = Z[0].
    final z0r = buf[0], z0i = buf[1];
    out[0] = z0r + z0i;
    out[1] = 0;
    out[m * 2] = z0r - z0i;
    out[m * 2 + 1] = 0;

    for (int k = 1; k < m; k++) {
      final j = m - k;
      final zr1 = buf[k * 2], zi1 = buf[k * 2 + 1];
      final zr2 = buf[j * 2], zi2 = buf[j * 2 + 1];

      final er = 0.5 * (zr1 + zr2);
      final ei = 0.5 * (zi1 - zi2);
      final or_ = 0.5 * (zi1 + zi2);
      final oi = -0.5 * (zr1 - zr2);

      final wr = _cos[k], wi = _sin[k];
      final xr = er + (or_ * wr - oi * wi);
      final xi = ei + (or_ * wi + oi * wr);

      out[k * 2] = xr;
      out[k * 2 + 1] = xi;
      out[(size - k) * 2] = xr;
      out[(size - k) * 2 + 1] = -xi;
    }
  }

  /// The inverse of [realForward], **unnormalised**: given a conjugate-
  /// symmetric [spectrum] (only bins `0 … size/2` are read), writes `size`
  /// real samples into [out], each `size` times too large — the same scaling
  /// convention [transform] uses with `inverse: true`, so a caller that
  /// divides by `size` can swap one for the other.
  ///
  /// Only useful when the spectrum really is conjugate-symmetric. It is not
  /// checked; an asymmetric input silently yields the inverse of its
  /// symmetric part.
  void realInverse(Float64List spectrum, Float64List out) {
    final m = size >> 1;
    if (m < 2) {
      final a = spectrum[0], b = spectrum[2];
      out[0] = a + b;
      out[1] = a - b;
      return;
    }

    // Undo the untangle: E[k] = (X[k] + conj(X[M-k])) / 2, and
    // W^k O[k] = (X[k] - conj(X[M-k])) / 2, so Z[k] = E[k] + i O[k].
    final buf = _halfBuf;
    for (int k = 0; k < m; k++) {
      final j = m - k; // X[k + M] = conj(X[M - k]); at k = 0 that is X[M].
      final xr1 = spectrum[k * 2], xi1 = spectrum[k * 2 + 1];
      final xr2 = spectrum[j * 2], xi2 = -spectrum[j * 2 + 1];

      // E and d each carry a factor of 1/2 in the algebra above. Both are
      // dropped, which scales z — and so the output — by 2; that is what
      // turns the half transform's leftover factor of N/2 into the N this
      // method's doc comment promises, and it saves four multiplies a bin.
      final er = xr1 + xr2;
      final ei = xi1 + xi2;
      final dr = xr1 - xr2;
      final di = xi1 - xi2;
      // O[k] = conj(W_N^k) * d
      final wr = _cos[k], wi = -_sin[k];
      final or_ = dr * wr - di * wi;
      final oi = dr * wi + di * wr;

      // Z[k] = E[k] + i O[k]
      buf[k * 2] = er - oi;
      buf[k * 2 + 1] = ei + or_;
    }

    _halfFft.transform(buf, inverse: true);

    // z[j] = (x[2j], x[2j+1]) — the unpack is again a copy.
    out.setRange(0, size, buf);
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
  final Float64List _x;
  final Float64List _y;
  final Float64List _a;
  final Float64List _b;

  FftAutocorrelation({
    required this.headLength,
    required this.wholeLength,
    required this.lags,
  })  : _fft = RealFft(_sizeFor(headLength + wholeLength)),
        _x = Float64List(_sizeFor(headLength + wholeLength)),
        _y = Float64List(_sizeFor(headLength + wholeLength)),
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
  ///
  /// Both operands are real and their product is therefore conjugate
  /// symmetric, so all three transforms take the real-input path: two
  /// [RealFft.realForward] calls and one [RealFft.realInverse], each a
  /// half-length complex transform plus an O(N) untangle. The pointwise
  /// multiply only has to touch bins `0 … N/2`, since that is all the
  /// inverse reads.
  void compute(List<double> window, Float64List out) {
    final n = _fft.size;
    for (int i = 0; i < n; i++) {
      _x[i] = 0;
      _y[i] = 0;
    }
    // Reversing the head turns correlation into convolution.
    for (int i = 0; i < headLength; i++) {
      _x[headLength - 1 - i] = window[i];
    }
    for (int i = 0; i < wholeLength; i++) {
      _y[i] = window[i];
    }

    _fft.realForward(_x, _a);
    _fft.realForward(_y, _b);

    // Pointwise complex multiply, in place into _a. Bins above N/2 are the
    // conjugate mirror and realInverse never looks at them.
    for (int i = 0; i <= n ~/ 2; i++) {
      final ar = _a[i * 2], ai = _a[i * 2 + 1];
      final br = _b[i * 2], bi = _b[i * 2 + 1];
      _a[i * 2] = ar * br - ai * bi;
      _a[i * 2 + 1] = ar * bi + ai * br;
    }

    _fft.realInverse(_a, _x);

    final scale = 1.0 / n;
    for (int tau = 0; tau < lags; tau++) {
      out[tau] = _x[headLength - 1 + tau] * scale;
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

  /// The interleaved complex spectrum of the most recent [magnitudes] or
  /// [transform] call: `[re0, im0, re1, im1, …]`, `size` bins long.
  ///
  /// Exposed because magnitude alone is not enough for everything that reads
  /// a spectrum. `harmonics.dart` needs the phase of one bin in two frames a
  /// hop apart to recover a partial's instantaneous frequency, which is the
  /// cheap precision refinement the brief asked for — the FFT is already
  /// computed, so the phase costs nothing to keep.
  ///
  /// Valid until the next call; do not retain.
  Float64List get complex => _buffer;

  /// Transform [windowed] without extracting magnitudes, leaving the result
  /// in [complex].
  void transform(Float64List windowed) {
    _fft.realForward(windowed, _buffer);
  }

  /// Magnitudes of the first `size / 2` bins of [windowed], which the caller
  /// has already windowed. Writes into [out], which must hold at least
  /// [bins] entries.
  void magnitudes(Float64List windowed, Float64List out, int bins) {
    _fft.realForward(windowed, _buffer);
    final limit = bins < size ~/ 2 ? bins : size ~/ 2;
    for (int i = 0; i < limit; i++) {
      final re = _buffer[i * 2], im = _buffer[i * 2 + 1];
      out[i] = math.sqrt(re * re + im * im);
    }
  }
}
