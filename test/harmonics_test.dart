import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/harmonics.dart';
import 'package:flutter_tuner/tuner_core.dart';

/// Partial measurement, against signals whose partials are known exactly.
void main() {
  const rate = 44100.0;

  /// A string with [b] stiffness and the given partial amplitudes.
  Float64List string(
    double f0, {
    double b = 0,
    List<double> amplitudes = const [1.0, 0.6, 0.4, 0.28, 0.2, 0.14, 0.1, 0.07],
    int samples = pitchWindowSize,
    double noise = 0,
  }) {
    final rng = math.Random(5);
    final out = Float64List(samples);
    for (int i = 0; i < samples; i++) {
      final t = i / rate;
      double s = 0;
      for (int h = 0; h < amplitudes.length; h++) {
        final n = h + 1;
        final partial = f0 * n * math.sqrt(1 + b * n * n);
        if (partial > rate / 2) break;
        s += amplitudes[h] * math.sin(2 * math.pi * partial * t);
      }
      out[i] = s * 0.3 + (rng.nextDouble() - 0.5) * noise;
    }
    return out;
  }

  test('finds the partials of a harmonic string', () {
    final profile = analyseHarmonics(string(146.83), 146.83, rate);
    expect(profile.isEmpty, isFalse);
    expect(profile.partials.length, greaterThanOrEqualTo(6));
    for (final p in profile.partials) {
      expect((p.frequency - 146.83 * p.order).abs(), lessThan(0.5),
          reason: 'partial ${p.order} at ${p.frequency}');
      expect(p.centsFromHarmonic.abs(), lessThan(10));
    }
    expect((profile.fittedF0 - 146.83).abs(), lessThan(0.05));
    expect(profile.detectorPartial, 1.0);
    expect(profile.detectorOnWrongPartial, isFalse);
  });

  test('recovers the stiffness of an inharmonic string', () {
    const f0 = 110.0;
    const b = 3e-4;
    final profile = analyseHarmonics(string(f0, b: b), f0, rate);
    expect(profile.inharmonicity, isNotNull);
    expect(profile.inharmonicity!, closeTo(b, b * 0.3));
    expect((profile.fittedF0 - f0).abs(), lessThan(0.2));
    // Higher partials of a stiff string are measurably sharp: partial 8 of a
    // B = 3e-4 string sits ~16 cents above 8·f0.
    final eighth =
        profile.partials.where((p) => p.order == 8).firstOrNull;
    if (eighth != null) expect(eighth.centsFromHarmonic, greaterThan(5));
    // And its octave is stretched, which is the point of measuring B at all.
    expect(profile.octaveStretchCents(), greaterThan(0.5));
  });

  test('says which partial the detector locked onto', () {
    final signal = string(82.41);
    // The classic octave error: the detector reports twice the frequency.
    final high = analyseHarmonics(signal, 164.82, rate);
    expect(high.detectorPartial, 2.0);
    expect(high.detectorOnWrongPartial, isTrue);

    // And the other direction: half the frequency, twice the period.
    final low = analyseHarmonics(signal, 41.2, rate);
    expect(low.detectorPartial, 0.5);
    expect(low.detectorOnWrongPartial, isTrue);
  });

  test('reports how much of the sound is in the fundamental', () {
    // A note plucked near the bridge: almost nothing in the fundamental.
    final bridgey = analyseHarmonics(
      string(196.0, amplitudes: const [0.08, 1.0, 0.9, 0.7, 0.5, 0.3]),
      196.0,
      rate,
    );
    expect(bridgey.fundamentalShare, lessThan(0.15));

    final round = analyseHarmonics(
      string(196.0, amplitudes: const [1.0, 0.3, 0.15, 0.08]),
      196.0,
      rate,
    );
    expect(round.fundamentalShare, greaterThan(0.5));
  });

  test('returns nothing rather than nonsense for silence and noise', () {
    expect(analyseHarmonics(Float64List(pitchWindowSize), 220.0, rate).isEmpty,
        isTrue);
    final rng = math.Random(1);
    final noise = Float64List.fromList(
        [for (int i = 0; i < pitchWindowSize; i++) rng.nextDouble() - 0.5]);
    final profile = analyseHarmonics(noise, 220.0, rate);
    // Noise may throw up a peak or two; what it must not do is claim a
    // confident stiffness fit over a full harmonic series.
    expect(profile.partials.length < 6 || profile.inharmonicity == null, isTrue);
  });

  test('an empty buffer is handled, not thrown at', () {
    expect(analyseHarmonics(const [], 220.0, rate).isEmpty, isTrue);
    expect(analyseHarmonics(Float64List(100), 220.0, rate).isEmpty, isTrue);
    expect(analyseHarmonics(Float64List(pitchWindowSize), 0, rate).isEmpty,
        isTrue);
  });
}
