import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tuner_bench/app/detectors.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/note_latency.dart' show NotePipeline, Smoothing;
import 'package:tuner_bench/tracking.dart';

/// The tracking-lag harness, checked against a glide whose timing this test
/// controls.
///
/// The measurement is a fit, and a fit will always return *something*; the
/// only way to know it returns the right thing is to hand it a signal whose
/// answer is already known.
void main() {
  const rate = 44100.0;

  /// A string sliding smoothly from [from] to [to] over [seconds].
  ({Float64List samples, JamsTruth truth}) glide({
    double from = 110.0,
    double to = 138.6, // four semitones up
    double seconds = 2.0,
    double lead = 0.3,
  }) {
    const harmonics = [1.0, 0.5, 0.3, 0.18];
    final total = lead + seconds + 0.3;
    final samples = Float64List((total * rate).round());
    final start = (lead * rate).round();
    final count = (seconds * rate).round();

    // Integrate the instantaneous frequency so the phase stays continuous.
    double phase = 0;
    final times = <double>[];
    final freqs = <double>[];
    for (int i = 0; i < count && start + i < samples.length; i++) {
      final u = i / count;
      final f = from * math.pow(to / from, u).toDouble();
      phase += 2 * math.pi * f / rate;
      double s = 0;
      for (int h = 0; h < harmonics.length; h++) {
        s += harmonics[h] * math.sin(phase * (h + 1));
      }
      samples[start + i] = s * 0.4;
      if (i % 256 == 0) {
        times.add((start + i) / rate);
        freqs.add(f);
      }
    }
    final truth = JamsTruth('glide', total, [StringContour(0, times, freqs)],
        [NoteEvent(0, lead, seconds, 45)]);
    return (samples: samples, truth: truth);
  }

  test('a glide with no smoothing is tracked with little lag', () {
    final signal = glide();
    final results = measureTracking(
      samples: signal.samples,
      sampleRate: rate,
      truth: signal.truth,
      pipeline:
          const NotePipeline('x', DetectorKind.yin, Smoothing.gateOnly),
      hop: 512,
    );
    expect(results, isNotEmpty);
    final lag = results.first.lag;
    // YIN's answer is timed at the start of its window, which is the
    // convention the whole report uses, so an unsmoothed pipeline should sit
    // near zero. Anything beyond ±30 ms would mean the harness — or that
    // convention — is wrong.
    expect(lag.abs(), lessThan(0.03), reason: 'lag was ${lag * 1000} ms');
    expect(results.first.rmsAtBestLag, lessThan(15));
  });

  test('the median filter shows up as extra lag, of about the size it must be',
      () {
    final signal = glide();
    double lagOf(Smoothing smoothing) => measureTracking(
          samples: signal.samples,
          sampleRate: rate,
          truth: signal.truth,
          pipeline: NotePipeline('x', DetectorKind.yin, smoothing),
          hop: 512,
        ).first.lag;

    final none = lagOf(Smoothing.gateOnly);
    final smoothed = lagOf(Smoothing.pitchSmoother);
    // A five-frame median is two frames behind; at a 512-sample hop that is
    // 23 ms, so the difference should be in that region rather than zero or
    // a tenth of a second.
    final extra = smoothed - none;
    expect(extra, greaterThan(0.008), reason: 'extra lag ${extra * 1000} ms');
    expect(extra, lessThan(0.045), reason: 'extra lag ${extra * 1000} ms');
  });

  test('a held note is refused rather than fitted', () {
    // Constant pitch: no movement, so no lag is identifiable and the harness
    // must decline instead of returning a number that means nothing.
    final steady = glide(from: 110.0, to: 110.0);
    final results = measureTracking(
      samples: steady.samples,
      sampleRate: rate,
      truth: steady.truth,
      pipeline:
          const NotePipeline('x', DetectorKind.yin, Smoothing.gateOnly),
      hop: 512,
    );
    expect(results, isEmpty);
  });
}
