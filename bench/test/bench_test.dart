import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/mpm.dart';
import 'package:tuner_bench/refine.dart';
import 'package:tuner_bench/yin.dart';

Float64List tone(double f0, {int n = pitchWindowSize, double rate = 44100}) {
  const harmonics = [1.0, 0.5, 0.3, 0.18, 0.1];
  final out = Float64List(n);
  for (int i = 0; i < n; i++) {
    final t = i / rate;
    double s = 0;
    for (int h = 0; h < harmonics.length; h++) {
      s += harmonics[h] * math.sin(2 * math.pi * f0 * (h + 1) * t);
    }
    out[i] = s * 0.3;
  }
  return out;
}

void main() {
  group('CentHistogram', () {
    test('percentiles land where the mass is', () {
      final h = CentHistogram();
      for (int i = 0; i < 100; i++) {
        h.add(i / 10.0); // 0.0 … 9.9 cents
      }
      expect(h.total, 100);
      expect(h.median, closeTo(5.0, 0.2));
      expect(h.absPercentile(0.9), closeTo(9.0, 0.3));
      expect(h.fractionBeyond(5), closeTo(0.49, 0.02));
    });

    test('absolute percentiles are symmetric', () {
      final h = CentHistogram();
      for (int i = 1; i <= 50; i++) {
        h.add(i.toDouble());
        h.add(-i.toDouble());
      }
      // Bin centres sit half a bin off zero, so the mean lands there, not on it.
      expect(h.mean, closeTo(0, CentHistogram.binWidth));
      expect(h.absPercentile(0.5), closeTo(25, 1.5));
    });

    test('survives a round trip through JSON', () {
      final h = CentHistogram()
        ..add(1.0)
        ..add(-300.0)
        ..add(300.0);
      final back = CentHistogram.fromJson(h.toJson());
      expect(back.total, 3);
      expect(back.below, 1);
      expect(back.above, 1);
    });
  });

  group('RefYin', () {
    test('the FFT difference function matches the naive one', () {
      final block = tone(146.83);
      final naive = RefYin(sampleRate: 44100, bufferSize: pitchWindowSize);
      final fast = RefYin(
          sampleRate: 44100, bufferSize: pitchWindowSize, useFft: true);
      final a = Float64List.fromList(naive.cmndf(block));
      final b = fast.cmndf(block);
      double worst = 0;
      for (int i = 1; i < a.length; i++) {
        final d = (a[i] - b[i]).abs();
        if (d > worst) worst = d;
      }
      expect(worst, lessThan(1e-9));
      expect(naive.getPitch(block).pitch,
          closeTo(fast.getPitch(block).pitch, 1e-9));
    });

    test('finds an open D string', () {
      final yin = RefYin(
          sampleRate: 44100, bufferSize: pitchWindowSize, useFft: true);
      final r = yin.getPitch(tone(146.83));
      expect(r.pitched, isTrue);
      expect(cents(r.pitch, 146.83).abs(), lessThan(1.0));
    });

    test('offers several candidates for pYIN to choose between', () {
      final yin = RefYin(
          sampleRate: 44100, bufferSize: pitchWindowSize, useFft: true);
      yin.cmndf(tone(196.0));
      final candidates = yin.candidates();
      expect(candidates.length, greaterThan(1));
      // The true period must be among them.
      expect(
        candidates.any((c) => cents(c.frequency, 196.0).abs() < 5),
        isTrue,
      );
    });
  });

  test('MPM finds the same note as YIN', () {
    final mpm = Mpm(sampleRate: 44100, bufferSize: pitchWindowSize);
    final r = mpm.getPitch(tone(110.0));
    expect(r.pitched, isTrue);
    expect(cents(r.pitch, 110.0).abs(), lessThan(1.0));
  });

  test('the stiffness fit recovers B from an inharmonic string', () {
    const f0 = 110.0;
    const b = 2e-4;
    const harmonics = [1.0, 0.6, 0.4, 0.25, 0.15, 0.1];
    final out = Float64List(pitchWindowSize);
    for (int i = 0; i < out.length; i++) {
      final t = i / 44100;
      double s = 0;
      for (int h = 0; h < harmonics.length; h++) {
        final n = h + 1;
        s += harmonics[h] *
            math.sin(2 * math.pi * f0 * n * math.sqrt(1 + b * n * n) * t);
      }
      out[i] = s * 0.3;
    }
    final r = refineByInstantaneousFrequency(out, f0, 44100);
    expect(r.inharmonicity, isNotNull);
    expect(r.inharmonicity!, closeTo(b, b * 0.25));
    expect(cents(r.frequency, f0).abs(), lessThan(1.0));
  });
}
