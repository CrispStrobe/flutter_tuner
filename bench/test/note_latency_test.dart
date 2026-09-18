import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tuner_bench/app/detectors.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/note_latency.dart';

/// The note-latency harness, checked against a signal whose plucks happen at
/// times this test chose.
///
/// A latency measurement that is quietly wrong is worse than no measurement,
/// and nothing in the corpus can catch that: GuitarSet's onsets are only as
/// good as GuitarSet, and a bug that shifted every time by a window would
/// look perfectly plausible.
void main() {
  const rate = 44100.0;

  double midiOf(double frequency) =>
      69 + 12 * math.log(frequency / 440) / math.ln2;

  /// Silence, then note A, then a short gap, then note B.
  ({Float64List samples, JamsTruth truth}) twoPlucks({
    double first = 110.0,
    double second = 164.81,
    double lead = 0.5,
    double noteLength = 1.2,
    double gap = 0.08,
  }) {
    const harmonics = [1.0, 0.55, 0.32, 0.2, 0.13, 0.08];
    final rng = math.Random(9);
    final total = lead + noteLength + gap + noteLength + 0.2;
    final samples = Float64List((total * rate).round());

    void pluck(double onset, double frequency, double length) {
      final start = (onset * rate).round();
      final count = (length * rate).round();
      for (int i = 0; i < count && start + i < samples.length; i++) {
        final t = i / rate;
        double s = 0;
        for (int h = 0; h < harmonics.length; h++) {
          final partial = frequency * (h + 1);
          if (partial > rate / 2) break;
          s += harmonics[h] *
              math.exp(-t * (1.1 + 0.5 * h)) *
              math.sin(2 * math.pi * partial * t);
        }
        samples[start + i] = s * 0.4 + (rng.nextDouble() - 0.5) * 0.002;
      }
    }

    pluck(lead, first, noteLength);
    final secondOnset = lead + noteLength + gap;
    pluck(secondOnset, second, noteLength);

    final truth = JamsTruth('synthetic', total, const [], [
      NoteEvent(0, lead, noteLength, midiOf(first)),
      NoteEvent(1, secondOnset, noteLength, midiOf(second)),
    ]);
    return (samples: samples, truth: truth);
  }

  test('both plucks count as isolated notes', () {
    final signal = twoPlucks();
    final notes = isolatedNotes(signal.truth);
    expect(notes.length, 2);
  });

  test('a note plucked while another is ringing is disqualified', () {
    final signal = twoPlucks();
    // Same audio, but the annotation says the first note was still sounding
    // when the second was plucked.
    final overlapping =
        JamsTruth('overlapping', signal.truth.duration, const [], [
      NoteEvent(0, 0.5, 1.4, signal.truth.notes.first.midi),
      NoteEvent(1, 1.78, 1.2, signal.truth.notes.last.midi),
    ]);
    final kept = isolatedNotes(overlapping);
    // The second note is thrown out — something else was sounding across its
    // pluck. The first is kept: nothing overlaps *its* pluck or the 600 ms
    // after it, which is all this measurement looks at.
    expect(kept.length, 1);
    expect(kept.single.onset, 0.5);
  });

  test('the first correct reading cannot arrive before the window has filled',
      () {
    final signal = twoPlucks();
    final outcomes = measureFile(
      samples: signal.samples,
      sampleRate: rate,
      truth: signal.truth,
      pipeline: const NotePipeline(
          'test', DetectorKind.yin, Smoothing.pitchSmoother),
      hop: 512,
    );
    expect(outcomes.length, 2);
    // A 4096-sample window is 92.9 ms, but the floor is not the whole window:
    // a window that *straddles* the pluck can already be right, because YIN
    // needs only a few periods of the new note inside the half it reads. What
    // must never happen is a reading that is correct about a note before
    // enough of that note exists to have produced it — a quarter of a window
    // is a conservative line, and a harness bug that timed readings from the
    // window's start instead of its end would cross it immediately.
    const quarterWindow = pitchWindowSize / 4 / rate;
    for (final o in outcomes) {
      expect(o.firstCorrect, isNotNull);
      expect(o.firstCorrect!, greaterThanOrEqualTo(quarterWindow));
      expect(o.firstCorrect!, lessThan(0.30),
          reason: 'a clean pluck should not take this long');
    }
  });

  test('the legacy median is slower onto the second note, and shows the '
      'first one while it lags', () {
    final signal = twoPlucks();
    List<NoteOutcome> run(Smoothing smoothing) => measureFile(
          samples: signal.samples,
          sampleRate: rate,
          truth: signal.truth,
          pipeline: NotePipeline('test', DetectorKind.yin, smoothing),
          hop: 512,
        );

    final legacy = run(Smoothing.legacyMedian);
    final fixed = run(Smoothing.pitchSmoother);

    // The first note is the same for both: there is nothing stale to carry.
    expect(legacy.first.firstCorrect, closeTo(fixed.first.firstCorrect!, 1e-9));

    // The second is where the never-cleared window costs time, and what it
    // shows in the meantime is the previous note.
    expect(legacy.last.firstCorrect!,
        greaterThan(fixed.last.firstCorrect! + 0.01));
    expect(legacy.last.staleShare, greaterThan(0));
    expect(fixed.last.staleShare, 0);
  });

  test('a pipeline that never reports is recorded, not crashed on', () {
    final silence = Float64List((3 * rate).round());
    final truth = JamsTruth('silence', 3, const [], [
      NoteEvent(0, 0.5, 1.2, 45),
    ]);
    final outcomes = measureFile(
      samples: silence,
      sampleRate: rate,
      truth: truth,
      pipeline: const NotePipeline(
          'test', DetectorKind.yin, Smoothing.pitchSmoother),
      hop: 512,
    );
    expect(outcomes.single.firstReading, isNull);
    expect(outcomes.single.firstCorrect, isNull);
    expect(outcomes.single.settled, isNull);
    expect(outcomes.single.correctShare, 0);
  });

  test('LatencyStats aggregates and survives JSON', () {
    final stats = LatencyStats('x')
      ..add(const NoteOutcome(
          firstReading: 0.1,
          firstCorrect: 0.12,
          settled: 0.2,
          correctShare: 0.9,
          staleShare: 0.1))
      ..add(const NoteOutcome(
          firstReading: null,
          firstCorrect: null,
          settled: null,
          correctShare: 0,
          staleShare: 0));
    expect(stats.notes, 2);
    expect(stats.neverRead, 1);
    expect(stats.neverSettled, 1);
    expect(LatencyStats.percentile(stats.firstCorrect, 0.5), 0.12);

    final back = LatencyStats.fromJson(stats.toJson());
    expect(back.notes, 2);
    expect(back.neverCorrect, 1);
    expect(back.firstReading, stats.firstReading);
  });
}
