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
    const head = 2048, whole = 4096; // the sizes the detector actually uses
    final signal = Float64List(whole);
    for (int i = 0; i < whole; i++) {
      signal[i] = rng.nextDouble() * 2 - 1;
    }

    final out = Float64List(head);
    FftAutocorrelation(headLength: head, wholeLength: whole, lags: head)
        .compute(signal, out);

    for (final tau in [0, 1, 7, 100, 1023, head - 1]) {
      double expected = 0;
      for (int i = 0; i < head; i++) {
        expected += signal[i] * signal[i + tau];
      }
      expect(out[tau], closeTo(expected, 1e-9 * head), reason: 'lag $tau');
    }
  });

  // The real-input path is the one the app actually uses: `RealSpectrum` and
  // `FftAutocorrelation` both call `realForward`. It has to agree with the
  // complex transform it replaced to floating point, in *both* components —
  // `harmonics.dart` reads the phase of a bin in two frames a hop apart, so a
  // result that is right up to a sign is a broken result there.
  test('realForward matches the zero-padded complex transform, bin for bin',
      () {
    final rng = math.Random(31337);
    for (final size in [2, 4, 8, 64, 256, 2048, 4096, 8192]) {
      final fft = RealFft(size);
      final signal = Float64List(size);
      for (int i = 0; i < size; i++) {
        signal[i] = rng.nextDouble() * 2 - 1;
      }

      final reference = fft.newBuffer();
      for (int i = 0; i < size; i++) {
        reference[i * 2] = signal[i];
        reference[i * 2 + 1] = 0;
      }
      fft.transform(reference);

      final got = fft.newBuffer();
      fft.realForward(signal, got);

      double worstComponent = 0, worstPhase = 0;
      for (int k = 0; k < size; k++) {
        final rr = reference[k * 2], ri = reference[k * 2 + 1];
        final gr = got[k * 2], gi = got[k * 2 + 1];
        worstComponent = math.max(worstComponent, (gr - rr).abs());
        worstComponent = math.max(worstComponent, (gi - ri).abs());
        // Phase, separately: a magnitude-only check would pass a conjugated
        // spectrum, which is exactly the bug this path could have.
        if (math.sqrt(rr * rr + ri * ri) > 1e-6) {
          var d = math.atan2(ri, rr) - math.atan2(gi, gr);
          d -= 2 * math.pi * (d / (2 * math.pi)).round();
          worstPhase = math.max(worstPhase, d.abs());
        }
      }
      expect(worstComponent, lessThan(1e-9),
          reason: 'size $size: components differ by $worstComponent');
      expect(worstPhase, lessThan(1e-9),
          reason: 'size $size: phases differ by $worstPhase rad');
    }
  });

  test('realForward leaves the conjugate mirror in the upper half', () {
    const size = 512;
    final rng = math.Random(4);
    final fft = RealFft(size);
    final signal = Float64List(size);
    for (int i = 0; i < size; i++) {
      signal[i] = rng.nextDouble() * 2 - 1;
    }
    final out = fft.newBuffer();
    fft.realForward(signal, out);

    expect(out[1], closeTo(0, 1e-12), reason: 'DC bin must be real');
    expect(out[size ~/ 2 * 2 + 1], closeTo(0, 1e-12),
        reason: 'Nyquist bin must be real');
    for (final k in [1, 2, 37, size ~/ 2 - 1]) {
      expect(out[(size - k) * 2], closeTo(out[k * 2], 1e-12));
      expect(out[(size - k) * 2 + 1], closeTo(-out[k * 2 + 1], 1e-12));
    }
  });

  test('realInverse undoes realForward, up to the factor of size', () {
    final rng = math.Random(99);
    for (final size in [2, 8, 1024, 4096]) {
      final fft = RealFft(size);
      final original = Float64List(size);
      for (int i = 0; i < size; i++) {
        original[i] = rng.nextDouble() * 2 - 1;
      }
      final spectrum = fft.newBuffer();
      fft.realForward(original, spectrum);
      final back = Float64List(size);
      fft.realInverse(spectrum, back);
      for (int i = 0; i < size; i++) {
        expect(back[i] / size, closeTo(original[i], 1e-9),
            reason: 'size $size, sample $i');
      }
    }
  });

  test('a non-power-of-two size is refused rather than silently wrong', () {
    expect(() => RealFft(1000), throwsArgumentError);
    expect(() => RealFft(0), throwsArgumentError);
  });
}
