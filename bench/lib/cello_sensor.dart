/// MUSERC's sensor track, turned into a pitch reference.
///
/// The corpus ships more than audio: each take has a 752 Hz CSV carrying the
/// finger position on the fingerboard, three accelerometer axes, and a
/// low-rate copy of the audio. Earlier sections did not use it, and for the
/// steady takes that was defensible — the filename gives the note. For the
/// **vibrato** takes it is not: the filename gives one number for a pitch
/// that is moving several times a second, so without the sensor there is no
/// reference for *when* it moved, and therefore no way to ask the question
/// §9.1 asks of guitar — how far behind is the reading?
///
/// Turning position into hertz needs a physical model, and the useful one is
/// simple. For a string of sounding length `L` stopped at distance `x` from
/// the nut, `f = f_open · L / (L − x)`, so
///
///     1/f = 1/f_open − x / (f_open · L)
///
/// — **1/f is linear in finger position**. That makes the calibration a
/// straight line fit over the steady takes, whose pitch is known from the
/// label, with no free parameters beyond the two coefficients.
///
/// Measured, the model holds structurally and imprecisely: R² = 0.974 on both
/// sensors, with a residual of 6–12 cents at the median and up to 47 in the
/// tail. So this is a **contour** reference, good for timing and for the
/// shape of a vibrato, and *not* good enough to score anyone's intonation in
/// cents. Every use of it below is a timing use.
///
/// The two sensors are two strings: `FretPosition1` carries the takes
/// labelled 59–61 and `FretPosition2` those labelled 50–53, so they are
/// calibrated separately.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'cello.dart';

/// A straight line `1/f = intercept + slope · x` for one sensor.
class SensorCalibration {
  final double intercept;
  final double slope;
  final int takes;
  final double rSquared;

  /// Median absolute residual, in cents — the honest precision of this
  /// reference.
  final double residualCents;

  const SensorCalibration(this.intercept, this.slope, this.takes,
      this.rSquared, this.residualCents);

  /// Hertz for a raw sensor reading, or null where the model does not apply.
  double? frequencyFor(double position) {
    final inverse = intercept + slope * position;
    if (inverse <= 0) return null;
    final f = 1 / inverse;
    return (f > 30 && f < 2000) ? f : null;
  }
}

/// One take's sensor track, with times rebased onto the audio's clock.
class SensorTrack {
  /// Seconds from the start of the WAV.
  final List<double> times;
  final List<double> position;

  /// Which column the position came from: 1 or 2.
  final int sensor;

  /// The shift applied to align the sensor stream to the audio, in seconds.
  /// Reported rather than hidden: it is the measurement's own error bar.
  final double alignment;

  const SensorTrack(this.times, this.position, this.sensor, this.alignment);

  bool get isEmpty => times.isEmpty;
}

/// Find the shift that best lines the CSV's own audio column up with the WAV.
///
/// The CSV's `Time` column runs on the session clock — one take's starts at
/// 140.45 s — so it has to be rebased before it means anything, and rebasing
/// on the first timestamp alone leaves 10-30 ms of residual. That is small,
/// and the effect being measured here is about 20 ms, so it is not small
/// enough. The CSV carries a low-rate copy of the audio, which makes the
/// residual measurable per take instead of assumed away.
double _alignmentSeconds(
    List<double> csvAudio, Float64List samples, double audioRate,
    double sensorRate) {
  final step = (audioRate / sensorRate).round();
  if (step < 1 || csvAudio.length < 32) return 0;
  final wavEnvelope = <double>[];
  for (int i = 0; i + step <= samples.length; i += step) {
    double sum = 0;
    for (int j = i; j < i + step; j++) {
      sum += samples[j].abs();
    }
    wavEnvelope.add(sum / step);
  }
  final n = math.min(wavEnvelope.length, csvAudio.length);
  if (n < 32) return 0;

  double meanA = 0, meanB = 0;
  for (int i = 0; i < n; i++) {
    meanA += wavEnvelope[i];
    meanB += csvAudio[i].abs();
  }
  meanA /= n;
  meanB /= n;

  final maxLag = math.min(n ~/ 4, (0.2 * sensorRate).round());
  double best = -double.infinity;
  int bestLag = 0;
  for (int lag = -maxLag; lag <= maxLag; lag++) {
    double sum = 0;
    int count = 0;
    for (int i = 0; i < n; i++) {
      final j = i + lag;
      if (j < 0 || j >= n) continue;
      sum += (wavEnvelope[i] - meanA) * (csvAudio[j].abs() - meanB);
      count++;
    }
    if (count < n ~/ 2) continue;
    final score = sum / count;
    if (score > best) {
      best = score;
      bestLag = lag;
    }
  }
  return bestLag / sensorRate;
}

/// Read the CSV beside a take's WAV, choosing whichever sensor is live and
/// putting its timestamps on the audio's clock.
SensorTrack readSensor(String wavPath, {Float64List? samples, double? rate}) {
  final file = File(wavPath.replaceAll('.wav', '.csv'));
  if (!file.existsSync()) return const SensorTrack([], [], 0, 0);

  final lines = file.readAsLinesSync();
  if (lines.length < 2) return const SensorTrack([], [], 0, 0);
  final header = lines.first.split(',');
  final timeAt = header.indexOf('Time');
  final firstAt = header.indexOf('FretPosition1');
  final secondAt = header.indexOf('FretPosition2');
  if (timeAt < 0 || firstAt < 0 || secondAt < 0) {
    return const SensorTrack([], [], 0, 0);
  }

  final audioAt = header.indexOf('Audio');
  final times = <double>[];
  final first = <double>[];
  final second = <double>[];
  final audio = <double>[];
  for (int i = 1; i < lines.length; i++) {
    final parts = lines[i].split(',');
    if (parts.length <= secondAt) continue;
    final t = double.tryParse(parts[timeAt]);
    final a = double.tryParse(parts[firstAt]);
    final b = double.tryParse(parts[secondAt]);
    if (t == null || a == null || b == null) continue;
    times.add(t);
    first.add(a);
    second.add(b);
    if (audioAt >= 0 && parts.length > audioAt) {
      audio.add(double.tryParse(parts[audioAt]) ?? 0);
    }
  }
  if (times.isEmpty) return const SensorTrack([], [], 0, 0);

  // The Time column is the session's clock, not the take's.
  final origin = times.first;
  for (int i = 0; i < times.length; i++) {
    times[i] -= origin;
  }
  double alignment = 0;
  if (samples != null && rate != null && audio.length == times.length) {
    final span = times.last - times.first;
    if (span > 0) {
      alignment = _alignmentSeconds(
          audio, samples, rate, (times.length - 1) / span);
      for (int i = 0; i < times.length; i++) {
        times[i] -= alignment;
      }
    }
  }

  int liveFirst = 0, liveSecond = 0;
  for (int i = 0; i < first.length; i++) {
    if (first[i] > 0) liveFirst++;
    if (second[i] > 0) liveSecond++;
  }
  if (liveFirst < times.length ~/ 2 && liveSecond < times.length ~/ 2) {
    return const SensorTrack([], [], 0, 0);
  }
  return liveFirst >= liveSecond
      ? SensorTrack(times, first, 1, alignment)
      : SensorTrack(times, second, 2, alignment);
}

/// Fit both sensors from the steady takes, whose pitch the label gives.
///
/// Takes labelled 53 are excluded: their audio is E3, some 90 cents from the
/// F3 the label claims (REPORT.md §11), so including them would bend the line
/// to fit a mislabelling.
Map<int, SensorCalibration> calibrate(List<CelloTake> takes) {
  final byS = <int, List<({double x, double f})>>{1: [], 2: []};
  for (final take in takes) {
    if (!take.steady || !take.hasReliableNominal || take.midi == 53) continue;
    // Calibration needs only the steady median position, so it does not need
    // the alignment — and reading the WAV for every take to get one would
    // triple the cost of fitting a straight line.
    final track = readSensor(take.path);
    if (track.isEmpty) continue;
    final live = track.position.where((p) => p > 0).toList()..sort();
    if (live.length < track.position.length ~/ 2) continue;
    byS[track.sensor]!
        .add((x: live[live.length ~/ 2], f: take.nominal));
  }

  final out = <int, SensorCalibration>{};
  for (final entry in byS.entries) {
    final points = entry.value;
    if (points.length < 3) continue;
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (final p in points) {
      final y = 1 / p.f;
      sx += p.x;
      sy += y;
      sxx += p.x * p.x;
      sxy += p.x * y;
    }
    final n = points.length.toDouble();
    final denom = n * sxx - sx * sx;
    if (denom == 0) continue;
    final slope = (n * sxy - sx * sy) / denom;
    final intercept = (sy - slope * sx) / n;

    double ssRes = 0, ssTot = 0;
    final mean = sy / n;
    final residuals = <double>[];
    for (final p in points) {
      final y = 1 / p.f;
      final predicted = intercept + slope * p.x;
      ssRes += (y - predicted) * (y - predicted);
      ssTot += (y - mean) * (y - mean);
      if (predicted > 0) {
        residuals.add((1200 * math.log(1 / predicted / p.f) / math.ln2).abs());
      }
    }
    residuals.sort();
    out[entry.key] = SensorCalibration(
      intercept,
      slope,
      points.length,
      ssTot == 0 ? 0 : 1 - ssRes / ssTot,
      residuals.isEmpty ? double.nan : residuals[residuals.length ~/ 2],
    );
  }
  return out;
}

/// The reference pitch contour for a take, sampled at [times].
///
/// Returns NaN where the sensor says nothing.
List<double> referenceContour(
    SensorTrack track, SensorCalibration calibration, List<double> times) {
  final out = List<double>.filled(times.length, double.nan);
  if (track.isEmpty) return out;
  int cursor = 0;
  for (int i = 0; i < times.length; i++) {
    final t = times[i];
    while (cursor + 1 < track.times.length && track.times[cursor + 1] < t) {
      cursor++;
    }
    final position = track.position[cursor];
    if (position <= 0) continue;
    final f = calibration.frequencyFor(position);
    if (f != null) out[i] = f;
  }
  return out;
}
