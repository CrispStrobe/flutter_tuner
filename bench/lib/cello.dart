/// The cello experiment: a bowed instrument, and vibrato.
///
/// Everything else in this report is guitar, and §12 has been saying so as a
/// limitation for as long as there have been results. Two things about a
/// cello are genuinely different from a plucked string, and both matter to a
/// tuner:
///
///   * **it is bowed**, so the note does not decay — the signal is sustained
///     and steady rather than a transient that fades, which should suit a
///     period-based detector better than a pluck does;
///   * **vibrato is the norm, not an ornament.** A cellist holding a note is
///     moving it, several times a second, by tens of cents. Every smoothing
///     decision in `PitchSmoother` was measured on a corpus where that was
///     rare.
///
/// The corpus is MUSERC (Zenodo 1560651, CC BY 4.0): 132 recordings of one
/// pro and one amateur cellist, 48 kHz, seven notes between D3 and C♯4, in
/// steady "tune" takes, "novib" takes at three dynamics, and vibrato takes.
/// The nominal note is in the filename.
///
/// What can and cannot be measured from that is worth stating plainly. The
/// dataset's own ground truth is a finger-position sensor, which gives the
/// *shape* of the pitch but needs a physical calibration to become hertz, so
/// it is not used here. What the filename gives is the note the player was
/// aiming at — enough to ask whether the tuner names the right note, and
/// whether it ever jumps an octave. And what needs no reference at all is
/// the question a player actually cares about: **how still does the needle
/// sit on a steady note, and does it follow vibrato or flatten it?**
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'app/detectors.dart';
import 'app/tuner_core.dart';
import 'metrics.dart';
import 'note_latency.dart' show NotePipeline, Smoothing;
import 'wav.dart';

/// One MUSERC recording, as described by its filename.
class CelloTake {
  final String path;
  final String player; // pro | amateur
  final int midi; // the note the cellist was aiming at
  final String dynamic; // tune | f | m | p
  final bool vibrato;

  const CelloTake(
      this.path, this.player, this.midi, this.dynamic, this.vibrato);

  /// Equal-tempered frequency of the nominal note at A440.
  double get nominal => 440 * math.pow(2, (midi - 69) / 12).toDouble();

  /// Steady takes: what a tuner is normally pointed at.
  bool get steady => !vibrato;

  /// Whether the filename's note describes what the take actually contains.
  ///
  /// It does not, for the `tune` takes, and assuming otherwise cost a set of
  /// published numbers. They are the cellist *tuning the instrument*:
  /// `pro_60_tune_1` is labelled 60 and holds a 220 Hz open A;
  /// `pro_53_tune_2` is labelled 53 and holds a 97 Hz open G. For every other
  /// take the label is a genuine MIDI note — `amateur_60_p_novib` measures
  /// 261.0 Hz against its 261.63 nominal — so only these are excluded, and
  /// only from the metrics that need a reference. Stillness and jitter need
  /// none, so they keep every take.
  bool get hasReliableNominal => dynamic != 'tune';

  String get label => '$player $midi $dynamic${vibrato ? " vib" : ""}';
}

/// Parse `pro_60_tune_1.wav`, `amateur_50_f_vib_1.wav`, `pro_51_m_novib.wav`.
CelloTake? parseTake(String path) {
  final name = path.split('/').last.replaceAll('.wav', '');
  final parts = name.split('_');
  if (parts.length < 3) return null;
  final player = parts[0];
  final midi = int.tryParse(parts[1]);
  if (midi == null) return null;
  final third = parts[2];
  if (third == 'tune') return CelloTake(path, player, midi, 'tune', false);
  final vibrato = parts.length > 3 && parts[3].startsWith('vib');
  return CelloTake(path, player, midi, third, vibrato);
}

List<CelloTake> findTakes(String directory) {
  final out = <CelloTake>[];
  for (final entry in Directory(directory).listSync()) {
    if (entry is! File || !entry.path.endsWith('.wav')) continue;
    final take = parseTake(entry.path);
    if (take != null) out.add(take);
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

class CelloOutcome {
  final CelloTake take;

  /// Frames the pipeline reported anything on, out of those analysed.
  final int frames;
  final int reported;

  /// Frames whose nearest equal-tempered note is the one in the filename.
  final int namedCorrectly;

  /// Frames the nominal-referenced metrics were computed over — zero for a
  /// `tune` take, whose filename does not describe its contents.
  final int nominalFrames;

  /// Frames an octave (or more) away from the nominal note.
  final int octaveAway;

  /// Median reported pitch, in cents relative to the nominal note. This is
  /// the cellist's own intonation as much as the tuner's error, which is why
  /// it is reported rather than scored.
  final double medianOffsetCents;

  /// Spread of the reading around that median, in cents — the needle's
  /// stillness, and the one figure here that needs no reference at all.
  final double spreadP90;

  /// Frame-to-frame change in the reading, in cents.
  final double jitterP90;

  /// Peak-to-peak excursion of the reading over the take, in cents. On a
  /// vibrato take this is the vibrato the pipeline managed to follow.
  final double excursion;

  const CelloOutcome({
    required this.take,
    required this.frames,
    required this.reported,
    required this.namedCorrectly,
    required this.nominalFrames,
    required this.octaveAway,
    required this.medianOffsetCents,
    required this.spreadP90,
    required this.jitterP90,
    required this.excursion,
  });
}

/// Run one pipeline over one cello take.
///
/// The first [skipSeconds] are discarded: a bow attack is not what a tuner is
/// being asked about, and §9 has already measured what happens during one.
CelloOutcome measureTake(
  CelloTake take,
  NotePipeline pipeline, {
  int window = pitchWindowSize,
  int hop = 512,
  double skipSeconds = 0.3,
}) {
  final wav = readWav(take.path);
  final rate = wav.sampleRate.toDouble();
  final engine = PitchEngine.of(pipeline.detector,
      sampleRate: rate, windowSize: window);
  final smoother = PitchSmoother();
  final legacy = MedianFilter();

  final pitches = <double>[];
  int frames = 0, reported = 0, named = 0, octaveAway = 0, nominalFrames = 0;
  final skipSamples = (skipSeconds * rate).round();

  for (int start = 0; start + window <= wav.samples.length; start += hop) {
    final block = Float64List.sublistView(wav.samples, start, start + window);
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
    if (start < skipSamples) continue;
    frames++;
    if (value <= 0) continue;
    reported++;
    pitches.add(value);

    if (!take.hasReliableNominal) continue;
    nominalFrames++;
    final error = cents(value, take.nominal);
    if (error.abs() <= 50) {
      named++;
    } else {
      final octaves = error / 1200;
      if ((octaves - octaves.roundToDouble()).abs() * 1200 <= 50 &&
          octaves.round() != 0) {
        octaveAway++;
      }
    }
  }

  if (pitches.isEmpty) {
    return CelloOutcome(
      take: take,
      frames: frames,
      reported: 0,
      namedCorrectly: 0,
      nominalFrames: 0,
      octaveAway: 0,
      medianOffsetCents: double.nan,
      spreadP90: double.nan,
      jitterP90: double.nan,
      excursion: double.nan,
    );
  }

  final sorted = List<double>.of(pitches)..sort();
  final median = sorted[sorted.length ~/ 2];

  // Everything below is measured against the take's *own* median, so the
  // cellist's intonation cancels out and what is left is the instrument's
  // and the pipeline's.
  final deviations = <double>[];
  for (final p in pitches) {
    final d = cents(p, median).abs();
    if (d < 600) deviations.add(d); // an octave error is not "spread"
  }
  deviations.sort();

  final jumps = <double>[];
  for (int i = 1; i < pitches.length; i++) {
    final d = cents(pitches[i], pitches[i - 1]).abs();
    if (d < 600) jumps.add(d);
  }
  jumps.sort();

  double percentile(List<double> values, double p) =>
      values.isEmpty ? double.nan : values[(p * (values.length - 1)).round()];

  double lowest = double.infinity, highest = -double.infinity;
  for (final p in pitches) {
    final c = cents(p, median);
    if (c.abs() > 600) continue;
    lowest = math.min(lowest, c);
    highest = math.max(highest, c);
  }

  return CelloOutcome(
    take: take,
    frames: frames,
    reported: reported,
    namedCorrectly: named,
    octaveAway: octaveAway,
    nominalFrames: nominalFrames,
    medianOffsetCents:
        take.hasReliableNominal ? cents(median, take.nominal) : double.nan,
    spreadP90: percentile(deviations, 0.9),
    jitterP90: percentile(jumps, 0.9),
    excursion: highest - lowest,
  );
}
