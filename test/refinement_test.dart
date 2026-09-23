import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/tuner_engine.dart';

/// The period refinement, run through the same synthesised plucked strings
/// `tuning_coverage_test.dart` uses, and asked the two questions the
/// benchmark asked of it on real audio (`bench/REPORT.md` §38):
///
///   * does the reading stay right — same note, still inside a cent — once
///     the extra step has moved it, and
///   * does it decline where the original declines?
///
/// It is a synthetic signal, so the margins here are much wider than a room:
/// §38.2 measures the gain on a clean tone as small and the gain on a noisy
/// one as a 40% cut in the tail. This test is a guard against the wiring
/// breaking, not a re-measurement — the measurement lives in `bench/`.
void main() {
  const rate = 44100.0;

  /// A plucked-string tone: harmonics falling away, a little noise.
  Float64List pluck(double frequency,
      {int samples = pitchWindowSize, double noise = 0.003, int seed = 4}) {
    const harmonics = [1.0, 0.55, 0.32, 0.2, 0.13, 0.08];
    final out = Float64List(samples);
    final random = math.Random(seed);
    for (int i = 0; i < samples; i++) {
      final t = i / rate;
      double sample = 0;
      for (int h = 0; h < harmonics.length; h++) {
        final partial = frequency * (h + 1);
        if (partial > rate / 2) break;
        sample += harmonics[h] * math.sin(2 * math.pi * partial * t);
      }
      out[i] = sample * 0.35 + (random.nextDouble() - 0.5) * noise;
    }
    return out;
  }

  double cents(double a, double b) => 1200 * math.log(a / b) / math.ln2;

  final detector = YinEngine(sampleRate: rate, windowSize: pitchWindowSize);

  // Two open strings at each end of a guitar's range, plus an orchestral A.
  const targets = <double>[82.41, 146.83, 196.00, 329.63, 440.0];

  test('every string stays within a cent of the truth after refinement', () {
    for (final target in targets) {
      for (final noise in const [0.003, 0.05]) {
        final window = pluck(target, noise: noise);
        final raw = detector.analyse(window);
        expect(raw.pitched, isTrue, reason: '$target Hz was not detected');

        final refined =
            refineByOverlapCorrelation(window, raw.frequency, rate);
        final before = cents(raw.frequency, target).abs();
        final after = cents(refined, target).abs();

        // The refinement moves the period by at most ±1%, so it can never
        // turn a correct reading into a different note.
        expect(after, lessThan(50),
            reason: '$target Hz at noise $noise: $after cents off');
        // And it stays inside a cent of the truth. Deliberately not "never
        // worse than `before`": on a synthetic tone YIN's own parabolic
        // interpolation already lands within 0.01 cents (§4.3), and the
        // re-scan is measured here moving it by up to 0.2 — which is why
        // §38 trusts the corpus and not the synthesiser, and why the
        // benchmark, not this test, is where the gain is claimed.
        expect(after, lessThan(1.0),
            reason: '$target Hz at noise $noise: '
                '$before cents became $after cents');
      }
    }
  });

  test('declines rather than guessing when it cannot help', () {
    final window = pluck(196.0);
    // Nothing to refine.
    expect(refineByOverlapCorrelation(window, 0, rate), 0);
    expect(refineByOverlapCorrelation(window, -1, rate), -1);
    expect(refineByOverlapCorrelation(const [], 196.0, rate), 196.0);
    expect(refineByOverlapCorrelation(window, double.nan, rate).isNaN, isTrue);
    // A period longer than half the window has no overlap worth scanning.
    final tooLow = rate / (window.length * 0.75);
    expect(refineByOverlapCorrelation(window, tooLow, rate), tooLow);
    // Silence has no correlation peak at all; the input comes back.
    expect(
        refineByOverlapCorrelation(Float64List(pitchWindowSize), 196.0, rate),
        196.0);
  });

  test('a refined frame is still the same note', () {
    final engine = TunerEngine();
    for (final note in ['E2', 'A2', 'D3', 'G3', 'B3', 'E4']) {
      final target = engine.getFrequencyForNote(note)!;
      final window = pluck(target);
      final raw = detector.analyse(window);
      final refined = engine.refinePitch(window, raw.frequency, rate);
      expect(engine.detectNote(refined).note, note,
          reason: '$note (${target.toStringAsFixed(2)} Hz) '
              'became ${engine.detectNote(refined).note}');
    }
  });

  test('the engine setting is on by default and can be turned off', () {
    final engine = TunerEngine();
    expect(engine.pitchRefinement, isTrue);

    final window = pluck(196.0, noise: 0.05);
    final raw = detector.analyse(window);
    expect(engine.refinePitch(window, raw.frequency, rate),
        refineByOverlapCorrelation(window, raw.frequency, rate));

    engine.pitchRefinement = false;
    expect(engine.refinePitch(window, raw.frequency, rate), raw.frequency);
  });
}
