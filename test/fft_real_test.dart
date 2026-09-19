import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/fft_real.dart';

/// `lib/fft_real.dart` exists because `fftea`'s `Float64x2List` is catastrophic
/// under dart2js (no SIMD — 15.6 ms for one 8192-point transform against
/// 0.38 ms natively). It is only worth having if it computes the same thing,
/// so this checks it against `fftea` directly.
void main() {
  test('RealFft matches fftea for random real input', () {
    final rng = math.Random(2026);
    for (final size in [64, 256, 2048, 8192]) {
      final signal = Float64List(size);
      for (int i = 0; i < size; i++) {
        signal[i] = rng.nextDouble() * 2 - 1;
      }

      final reference = FFT(size).realFft(signal);

      final fft = RealFft(size);
      final buffer = fft.newBuffer();
      for (int i = 0; i < size; i++) {
        buffer[i * 2] = signal[i];
        buffer[i * 2 + 1] = 0;
      }
      fft.transform(buffer);

      double worst = 0;
      for (int i = 0; i < size; i++) {
        worst = math.max(worst, (buffer[i * 2] - reference[i].x).abs());
        worst = math.max(worst, (buffer[i * 2 + 1] - reference[i].y).abs());
      }
      expect(worst, lessThan(1e-8), reason: 'size $size differs by $worst');
    }
  });

  test('the inverse transform round-trips', () {
    final rng = math.Random(7);
    const size = 1024;
    final fft = RealFft(size);
    final buffer = fft.newBuffer();
    final original = Float64List(size);
    for (int i = 0; i < size; i++) {
      original[i] = rng.nextDouble() * 2 - 1;
      buffer[i * 2] = original[i];
    }
    fft.transform(buffer);
    fft.transform(buffer, inverse: true);
    for (int i = 0; i < size; i++) {
      expect(buffer[i * 2] / size, closeTo(original[i], 1e-9));
    }
  });

  test('autocorrelation equals the direct sum', () {
    final rng = math.Random(11);
    const head = 512, whole = 1024;
    final signal = Float64List(whole);
    for (int i = 0; i < whole; i++) {
      signal[i] = rng.nextDouble() * 2 - 1;
    }

    final out = Float64List(head);
    FftAutocorrelation(headLength: head, wholeLength: whole, lags: head)
        .compute(signal, out);

    for (final tau in [0, 1, 7, 100, 511]) {
      double expected = 0;
      for (int i = 0; i < head; i++) {
        expected += signal[i] * signal[i + tau];
      }
      expect(out[tau], closeTo(expected, 1e-8), reason: 'lag $tau');
    }
  });

  test('a non-power-of-two size is refused rather than silently wrong', () {
    expect(() => RealFft(1000), throwsArgumentError);
    expect(() => RealFft(0), throwsArgumentError);
  });
}
