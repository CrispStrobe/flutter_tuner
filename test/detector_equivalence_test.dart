import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pitch_detector_dart/pitch_detector.dart';

import 'package:flutter_tuner/detectors.dart';
import 'package:flutter_tuner/tuner_core.dart';

/// The app used to call `pitch_detector_dart`; `lib/detectors.dart` now
/// carries YIN itself, so that the difference function can be computed by FFT
/// instead of the package's O(N²) double loop — measured at 210–240% of one
/// audio callback's budget, against 7–8% (bench/REPORT.md §3.3).
///
/// That is only defensible if the answers are the same answers. This is the
/// assertion that says so, and it is why the package is still a dev
/// dependency: it is the reference, frame by frame, on signals chosen to be
/// awkward rather than flattering.
void main() {
  const rate = 44100.0;

  /// A plucked string: falling harmonics, a decay, noise, random phase.
  Float64List pluck(
    double f0,
    math.Random rng, {
    int samples = pitchWindowSize,
    double noise = 0.01,
    double decay = 1.2,
    double b = 0,
  }) {
    const harmonics = [1.0, 0.55, 0.32, 0.20, 0.13, 0.08, 0.05, 0.03];
    final phases = [
      for (int i = 0; i < harmonics.length; i++) rng.nextDouble() * 2 * math.pi
    ];
    final out = Float64List(samples);
    for (int i = 0; i < samples; i++) {
      final t = i / rate;
      double s = 0;
      for (int h = 0; h < harmonics.length; h++) {
        final n = h + 1;
        final partial = f0 * n * math.sqrt(1 + b * n * n);
        if (partial > rate / 2) break;
        s += harmonics[h] *
            math.exp(-t * (decay + 0.6 * h)) *
            math.sin(2 * math.pi * partial * t + phases[h]);
      }
      out[i] = s * 0.4 + (rng.nextDouble() - 0.5) * noise;
    }
    return out;
  }

  test('YinEngine matches pitch_detector_dart frame for frame', () async {
    final package =
        PitchDetector(audioSampleRate: rate, bufferSize: pitchWindowSize);
    final engine =
        YinEngine(sampleRate: rate, windowSize: pitchWindowSize);
    final rng = math.Random(20260918);

    // Every open string of a guitar and a bass, detuned, decaying, noisy,
    // plus stiff strings and two cases that should be rejected outright.
    final cases = <Float64List>[
      for (final f0 in [
        30.87, 41.20, 55.0, 82.41, 110.0, 146.83, 196.0, 246.94, 329.63, 440.0,
        659.26, 880.0,
      ])
        for (final detune in [-40.0, 0.0, 27.0])
          pluck(f0 * math.pow(2, detune / 1200).toDouble(), rng),
      // Stiff strings: the partials are sharp, so the dips move.
      pluck(82.41, rng, b: 5e-4),
      pluck(146.83, rng, b: 2e-4),
      // Fast decay — by the end of the window there is almost nothing left.
      pluck(196.0, rng, decay: 12.0),
      // Noise alone, and silence: both should be rejected, identically.
      Float64List.fromList(
          [for (int i = 0; i < pitchWindowSize; i++) rng.nextDouble() - 0.5]),
      Float64List(pitchWindowSize),
    ];

    int pitchedFrames = 0;
    double worstCents = 0;
    for (final block in cases) {
      final expected = await package.getPitchFromFloatBuffer(block);
      final got = engine.analyse(block);

      expect(got.pitched, expected.pitched,
          reason: 'voicing decision differs');
      if (!expected.pitched) continue;
      pitchedFrames++;

      final cents = centsBetween(got.frequency, expected.pitch).abs();
      if (cents > worstCents) worstCents = cents;
      expect(cents, lessThan(1e-6), reason: 'pitch differs by $cents cents');
      expect(got.probability, closeTo(expected.probability, 1e-12));
    }

    expect(pitchedFrames, greaterThan(20),
        reason: 'the corpus of test signals should mostly be pitched');
    expect(worstCents, lessThan(1e-6));
  });

  test('the FFT difference function equals the textbook double loop',
      () async {
    final rng = math.Random(7);
    final fast = YinEngine(sampleRate: rate, windowSize: pitchWindowSize);
    final naive = YinEngine(
        sampleRate: rate, windowSize: pitchWindowSize, naiveDifference: true);
    for (final f0 in [55.0, 98.0, 220.0, 523.25]) {
      final block = pluck(f0, rng);
      final a = fast.analyse(block);
      final b = naive.analyse(block);
      expect(a.pitched, b.pitched);
      expect(centsBetween(a.frequency, b.frequency).abs(), lessThan(1e-6));
    }
  });

  test('MPM finds the same notes as YIN on clean plucks', () {
    final rng = math.Random(3);
    final yin = YinEngine(sampleRate: rate, windowSize: pitchWindowSize);
    final mpm = MpmEngine(sampleRate: rate, windowSize: pitchWindowSize);
    for (final f0 in [82.41, 110.0, 196.0, 329.63]) {
      final block = pluck(f0, rng, noise: 0.002);
      final a = yin.analyse(block);
      final b = mpm.analyse(block);
      expect(a.pitched, isTrue);
      expect(b.pitched, isTrue);
      expect(centsBetween(a.frequency, f0).abs(), lessThan(5));
      expect(centsBetween(b.frequency, f0).abs(), lessThan(5));
    }
  });

  test('both engines report the window\'s detection floor', () {
    final yin = YinEngine(sampleRate: rate, windowSize: pitchWindowSize);
    final mpm = MpmEngine(sampleRate: rate, windowSize: pitchWindowSize);
    // 4096 samples at 44.1 kHz: 21.53 Hz, below the bottom of a piano.
    expect(yin.detectionFloor, closeTo(21.53, 0.01));
    expect(mpm.detectionFloor, closeTo(21.53, 0.01));
    // The 2048 the app used until 2.2 could not represent a bass low E.
    expect(YinEngine(sampleRate: rate, windowSize: 2048).detectionFloor,
        greaterThan(41.20));
  });
}
