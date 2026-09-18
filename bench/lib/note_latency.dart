/// The experiment the frame-level numbers cannot express: after a pluck, how
/// long until the tuner says the right thing and keeps saying it?
///
/// Raw pitch accuracy counts frames, and a frame is not what anyone
/// experiences. A player plucks a string and watches the needle: what they
/// notice is the delay before it means anything, and whether it wanders back
/// off once it has arrived. Two pipelines with the same RPA can feel
/// completely different — a lagging median scores well on a held note and
/// still shows the *previous* note for a quarter of a second after the pluck.
///
/// So: take GuitarSet's `note_midi` onsets, run the whole pipeline in time
/// order, and time each reading from the pluck that produced it.
///
/// A reading is timed at the moment it could be *displayed*, which is when
/// the last sample of its window has arrived — `(start + window) / rate`.
/// That is deliberately the pessimistic convention: it charges the analysis
/// window to the latency, because the user is charged for it too.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'app/detectors.dart';
import 'app/tuner_core.dart';
import 'jams.dart';
import 'metrics.dart';
import 'wav.dart';

/// How the gate and the median are managed, so the shipped behaviour can be
/// compared against what it replaced.
enum Smoothing {
  /// The gate, and a five-frame median that is never cleared — CrispTuner
  /// before the fix in REPORT.md §2.1.
  legacyMedian,

  /// The gate and the median as they ship now: `PitchSmoother`, which clears
  /// the window whenever a frame is rejected.
  pitchSmoother,

  /// The gate alone, for attribution.
  gateOnly,
}

class NotePipeline {
  final String name;
  final DetectorKind detector;
  final Smoothing smoothing;
  const NotePipeline(this.name, this.detector, this.smoothing);
}

const List<NotePipeline> defaultPipelines = [
  NotePipeline('before (legacy median)', DetectorKind.yin, Smoothing.legacyMedian),
  NotePipeline('after (PitchSmoother)', DetectorKind.yin, Smoothing.pitchSmoother),
  NotePipeline('no median at all', DetectorKind.yin, Smoothing.gateOnly),
  NotePipeline('MPM + PitchSmoother', DetectorKind.mpm, Smoothing.pitchSmoother),
];

/// What happened on one note.
class NoteOutcome {
  /// Seconds from the pluck to the first reading of any kind, or null if the
  /// pipeline said nothing at all while the note sounded.
  final double? firstReading;

  /// Seconds from the pluck to the first *correct* reading (within 50 cents).
  final double? firstCorrect;

  /// Seconds from the pluck to the last reading that was wrong — i.e. the
  /// point after which everything until the note ended was right. Null when
  /// the note never settled.
  final double? settled;

  /// Fraction of the readings during the note that were correct.
  final double correctShare;

  /// Fraction of the readings before settling that were within 50 cents of
  /// the *previous* note instead. This is staleness, measured: the needle
  /// still showing what you played before.
  final double staleShare;

  const NoteOutcome({
    required this.firstReading,
    required this.firstCorrect,
    required this.settled,
    required this.correctShare,
    required this.staleShare,
  });
}

/// Aggregated over many notes.
class LatencyStats {
  final String name;
  int notes = 0;
  int neverRead = 0;
  int neverCorrect = 0;
  int neverSettled = 0;
  final List<double> firstReading = [];
  final List<double> firstCorrect = [];
  final List<double> settled = [];
  final List<double> correctShares = [];
  final List<double> staleShares = [];

  LatencyStats(this.name);

  void add(NoteOutcome o) {
    notes++;
    if (o.firstReading == null) {
      neverRead++;
    } else {
      firstReading.add(o.firstReading!);
    }
    if (o.firstCorrect == null) {
      neverCorrect++;
    } else {
      firstCorrect.add(o.firstCorrect!);
    }
    if (o.settled == null) {
      neverSettled++;
    } else {
      settled.add(o.settled!);
    }
    correctShares.add(o.correctShare);
    staleShares.add(o.staleShare);
  }

  void merge(LatencyStats o) {
    notes += o.notes;
    neverRead += o.neverRead;
    neverCorrect += o.neverCorrect;
    neverSettled += o.neverSettled;
    firstReading.addAll(o.firstReading);
    firstCorrect.addAll(o.firstCorrect);
    settled.addAll(o.settled);
    correctShares.addAll(o.correctShares);
    staleShares.addAll(o.staleShares);
  }

  static double percentile(List<double> values, double p) {
    if (values.isEmpty) return double.nan;
    final sorted = List<double>.of(values)..sort();
    return sorted[(p * (sorted.length - 1)).round()];
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'notes': notes,
        'neverRead': neverRead,
        'neverCorrect': neverCorrect,
        'neverSettled': neverSettled,
        'firstReading': firstReading,
        'firstCorrect': firstCorrect,
        'settled': settled,
        'correctShares': correctShares,
        'staleShares': staleShares,
      };

  static LatencyStats fromJson(Map<String, dynamic> j) {
    final s = LatencyStats(j['name'] as String);
    s.notes = j['notes'] as int;
    s.neverRead = j['neverRead'] as int;
    s.neverCorrect = j['neverCorrect'] as int;
    s.neverSettled = j['neverSettled'] as int;
    List<double> doubles(String key) =>
        (j[key] as List).map((v) => (v as num).toDouble()).toList();
    s.firstReading.addAll(doubles('firstReading'));
    s.firstCorrect.addAll(doubles('firstCorrect'));
    s.settled.addAll(doubles('settled'));
    s.correctShares.addAll(doubles('correctShares'));
    s.staleShares.addAll(doubles('staleShares'));
    return s;
  }
}

/// One reading, with the time it could have been shown.
class _Reading {
  final double time;
  final double pitch; // 0 when the pipeline reported nothing
  const _Reading(this.time, this.pitch);
}

/// Notes a tuner is actually being asked about: long enough to read, and not
/// overlapped by another string.
///
/// Guitar playing is full of notes that ring into each other; a tuner is used
/// on one string at a time. Measuring settling time across a chord voicing
/// would be measuring the wrong thing, so those notes are excluded and
/// counted.
List<NoteEvent> isolatedNotes(
  JamsTruth truth, {
  double minDuration = 0.3,
  double guard = 0.05,
}) {
  final out = <NoteEvent>[];
  for (final note in truth.notes) {
    if (note.duration < minDuration) continue;
    final from = note.onset - guard;
    final to = math.min(note.offset, note.onset + 0.6);
    bool clean = true;
    for (final other in truth.notes) {
      if (identical(other, note)) continue;
      if (other.offset < from || other.onset > to) continue;
      clean = false;
      break;
    }
    if (clean) out.add(note);
  }
  return out;
}

/// Run one pipeline over one file and time every isolated note.
List<NoteOutcome> measureFile({
  required Float64List samples,
  required double sampleRate,
  required JamsTruth truth,
  required NotePipeline pipeline,
  int window = pitchWindowSize,
  int hop = 512,

  /// A note counts as settled only if there is at least this much of it left
  /// after the last wrong reading — otherwise "settled" could mean "ended".
  double minSettledSpan = 0.15,
}) {
  final engine = PitchEngine.of(pipeline.detector,
      sampleRate: sampleRate, windowSize: window);
  final smoother = PitchSmoother();
  final legacy = MedianFilter();

  final readings = <_Reading>[];
  for (int start = 0; start + window <= samples.length; start += hop) {
    final block = Float64List.sublistView(samples, start, start + window);
    final estimate = engine.analyse(block);
    double value = 0;
    switch (pipeline.smoothing) {
      case Smoothing.pitchSmoother:
        value = smoother.accept(
              pitched: estimate.pitched,
              probability: estimate.probability,
              pitch: estimate.frequency,
            ) ??
            0;
      case Smoothing.legacyMedian:
        if (estimate.pitched &&
            estimate.probability > PitchSmoother.minProbability) {
          value = legacy.add(estimate.frequency);
        }
      case Smoothing.gateOnly:
        if (estimate.pitched &&
            estimate.probability > PitchSmoother.minProbability) {
          value = estimate.frequency;
        }
    }
    // The reading can only be shown once its last sample has arrived.
    readings.add(_Reading((start + window) / sampleRate, value));
  }

  final notes = isolatedNotes(truth);
  final outcomes = <NoteOutcome>[];
  for (final note in notes) {
    // What was sounding before this pluck, for the staleness measure.
    NoteEvent? previous;
    for (final other in truth.notes) {
      if (other.offset <= note.onset &&
          (previous == null || other.offset > previous.offset)) {
        previous = other;
      }
    }

    final reference = note.frequency;
    double? firstReading, firstCorrect, lastWrong;
    int total = 0, correct = 0, staleBefore = 0, beforeSettled = 0;
    double lastReadingTime = note.onset;

    for (final r in readings) {
      if (r.time < note.onset) continue;
      if (r.time > note.offset) break;
      total++;
      lastReadingTime = r.time;
      final isCorrect =
          r.pitch > 0 && cents(r.pitch, reference).abs() <= 50;
      if (r.pitch > 0) firstReading ??= r.time - note.onset;
      if (isCorrect) {
        correct++;
        firstCorrect ??= r.time - note.onset;
      } else {
        lastWrong = r.time - note.onset;
      }
    }

    // Settling: the moment after the last wrong reading, provided enough of
    // the note is left for that to mean anything.
    double? settled;
    if (total > 0 && correct > 0) {
      final candidate = lastWrong == null ? 0.0 : lastWrong;
      final remaining = (note.offset - note.onset) - candidate;
      if (remaining >= minSettledSpan) settled = candidate;
    }

    // Staleness, over the readings before settling.
    if (previous != null && settled != null) {
      final previousReference = previous.frequency;
      final differs = cents(previousReference, reference).abs() > 50;
      if (differs) {
        for (final r in readings) {
          if (r.time < note.onset) continue;
          if (r.time - note.onset >= settled) break;
          beforeSettled++;
          if (r.pitch > 0 &&
              cents(r.pitch, previousReference).abs() <= 50) {
            staleBefore++;
          }
        }
      }
    }

    outcomes.add(NoteOutcome(
      firstReading: firstReading,
      firstCorrect: firstCorrect,
      settled: settled,
      correctShare: total == 0 ? 0 : correct / total,
      staleShare: beforeSettled == 0 ? 0 : staleBefore / beforeSettled,
    ));
    // Silence the unused-variable warning while keeping the intent visible.
    assert(lastReadingTime >= note.onset);
  }
  return outcomes;
}

/// Everything, for one file.
Map<String, LatencyStats> measureAllPipelines({
  required String wavPath,
  required String jamsPath,
  int window = pitchWindowSize,
  int hop = 512,
  List<NotePipeline> pipelines = defaultPipelines,
}) {
  final wav = readWav(wavPath);
  final truth = readJams(jamsPath);
  final out = <String, LatencyStats>{};
  for (final p in pipelines) {
    final stats = LatencyStats(p.name);
    for (final outcome in measureFile(
      samples: wav.samples,
      sampleRate: wav.sampleRate.toDouble(),
      truth: truth,
      pipeline: p,
      window: window,
      hop: hop,
    )) {
      stats.add(outcome);
    }
    out[p.name] = stats;
  }
  return out;
}
