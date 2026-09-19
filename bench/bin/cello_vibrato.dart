// How far behind the cellist's vibrato is the reading?
//
//   dart run bin/cello_vibrato.dart --data .../MUSERC/SA
//
// §9.1 asks this of guitar bends using GuitarSet's annotated contours. The
// cello corpus has no annotated contour — but it has a finger-position sensor
// at 752 Hz, and lib/cello_sensor.dart turns that into one. The reference is
// good for timing and not for cents (6-12 cents of calibration residual), so
// only timing is asked of it.
//
// Also measured here, because a bowed attack is nothing like a plucked one:
// how long after the bow starts before the reading is right and stays right.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tuner_bench/app/detectors.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/cello.dart';
import 'package:tuner_bench/cello_sensor.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/note_latency.dart' show NotePipeline, Smoothing;
import 'package:tuner_bench/wav.dart';

const pipelines = [
  NotePipeline('before (legacy median)', DetectorKind.yin, Smoothing.legacyMedian),
  NotePipeline('after (PitchSmoother)', DetectorKind.yin, Smoothing.pitchSmoother),
  NotePipeline('no median at all', DetectorKind.yin, Smoothing.gateOnly),
  NotePipeline('MPM + PitchSmoother', DetectorKind.mpm, Smoothing.pitchSmoother),
];

double percentile(List<double> v, double p) {
  if (v.isEmpty) return double.nan;
  final s = List<double>.of(v)..sort();
  return s[(p * (s.length - 1)).round()];
}

/// Where the bow starts, from the audio's own energy.
///
/// MUSERC has no onset annotation and does not need one: each take is a
/// single note preceded by silence, so the first sustained rise above the
/// noise floor is the attack.
double detectOnset(Float64List samples, double rate) {
  const window = 512;
  double floor = double.infinity;
  final energies = <double>[];
  for (int i = 0; i + window <= samples.length; i += window) {
    double sum = 0;
    for (int j = i; j < i + window; j++) {
      sum += samples[j] * samples[j];
    }
    final rms = math.sqrt(sum / window);
    energies.add(rms);
    if (rms < floor) floor = rms;
  }
  if (energies.isEmpty) return 0;
  final sorted = List<double>.of(energies)..sort();
  final loud = sorted[(0.9 * (sorted.length - 1)).round()];
  final threshold = math.max(floor * 4, loud * 0.1);
  for (int i = 0; i < energies.length; i++) {
    if (energies[i] >= threshold) return i * window / rate;
  }
  return 0;
}

void main(List<String> argv) {
  String data = '/mnt/storage/tuner-bench/datasets/muserc/MUSERC/SA';
  int window = pitchWindowSize, hop = 512;
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--data':
        data = argv[++i];
      case '--window':
        window = int.parse(argv[++i]);
      case '--hop':
        hop = int.parse(argv[++i]);
      default:
        stderr.writeln('unknown option ${argv[i]}');
        exit(2);
    }
  }

  final takes = findTakes(data);
  final calibrations = calibrate(takes);
  stdout.writeln('takes       : ${takes.length}');
  for (final entry in calibrations.entries) {
    final c = entry.value;
    stdout.writeln('sensor ${entry.key}    : fitted on ${c.takes} steady takes, '
        'R² ${c.rSquared.toStringAsFixed(3)}, '
        'residual ${c.residualCents.toStringAsFixed(1)} cents — a contour '
        'reference, not a cent-accurate one');
  }
  stdout.writeln('');

  // --- vibrato tracking lag -------------------------------------------
  stdout.writeln('VIBRATO TAKES — lag behind the sensor contour');
  stdout.writeln('pipeline                 lag p10   p50   p90    segments');
  final alignments = <double>[];
  for (final pipeline in pipelines) {
    final lags = <double>[];
    for (final take in takes.where((t) => !t.steady)) {
      final wav = readWav(take.path);
      final rate = wav.sampleRate.toDouble();
      final track =
          readSensor(take.path, samples: wav.samples, rate: rate);
      final calibration = calibrations[track.sensor];
      if (track.isEmpty || calibration == null) continue;
      alignments.add(track.alignment);
      final engine = PitchEngine.of(pipeline.detector,
          sampleRate: rate, windowSize: window);
      final smoother = PitchSmoother();
      final legacy = MedianFilter();

      final times = <double>[];
      final detected = <double>[];
      for (int start = 0; start + window <= wav.samples.length; start += hop) {
        final block =
            Float64List.sublistView(wav.samples, start, start + window);
        final estimate = engine.analyse(block);
        double value = 0;
        switch (pipeline.smoothing) {
          case Smoothing.pitchSmoother:
            value = smoother.accept(
                    pitched: estimate.pitched,
                    probability: estimate.probability,
                    pitch: estimate.frequency) ??
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
        // YIN's answer describes the start of its window (REPORT.md §1).
        times.add(start / rate);
        detected.add(value);
      }

      final reference = referenceContour(track, calibration, times);
      // Fit the shift that best aligns the two contours, in cents about each
      // one's own median so the calibration's offset cannot matter.
      final usable = <int>[];
      for (int i = 0; i < times.length; i++) {
        if (detected[i] > 0 && !reference[i].isNaN) usable.add(i);
      }
      if (usable.length < 40) continue;
      final refMedian = <double>[for (final i in usable) reference[i]]..sort();
      final detMedian = <double>[for (final i in usable) detected[i]]..sort();
      final rm = refMedian[refMedian.length ~/ 2];
      final dm = detMedian[detMedian.length ~/ 2];

      // Only a take whose reference actually moves carries timing
      // information; a flat contour fits every lag equally.
      double lo = double.infinity, hi = -double.infinity;
      for (final i in usable) {
        final c = cents(reference[i], rm);
        lo = math.min(lo, c);
        hi = math.max(hi, c);
      }
      if (hi - lo < 20) continue;

      // Vibrato is periodic, so a lag of 0 and a lag of one whole cycle fit
      // equally well — the same aliasing that made §9.1 exclude vibrato from
      // the guitar measurement. A cellist's vibrato runs about 5 Hz, so the
      // search is held inside a half-cycle, where the fit has one answer.
      final maxLag = (0.06 * rate / hop).round();
      double bestRms = double.infinity;
      int bestLag = 0;
      for (int lag = -maxLag; lag <= maxLag; lag++) {
        double sum = 0;
        int n = 0;
        for (final i in usable) {
          final j = i + lag;
          if (j < 0 || j >= detected.length || detected[j] <= 0) continue;
          final d = cents(detected[j], dm) - cents(reference[i], rm);
          if (d.abs() > 200) continue;
          sum += d * d;
          n++;
        }
        if (n < 20) continue;
        final rms = math.sqrt(sum / n);
        if (rms < bestRms) {
          bestRms = rms;
          bestLag = lag;
        }
      }
      if (bestRms.isFinite) lags.add(bestLag * hop / rate);
    }

    stdout.writeln([
      pipeline.name.padRight(24),
      '${(1000 * percentile(lags, 0.1)).toStringAsFixed(0)} ms'.padLeft(8),
      '${(1000 * percentile(lags, 0.5)).toStringAsFixed(0)} ms'.padLeft(7),
      '${(1000 * percentile(lags, 0.9)).toStringAsFixed(0)} ms'.padLeft(7),
      lags.length.toString().padLeft(9),
    ].join(' '));
  }

  if (alignments.isNotEmpty) {
    stdout.writeln('sensor/audio alignment applied per take: median '
        '${(1000 * percentile(alignments, 0.5)).toStringAsFixed(0)} ms, '
        'p10 ${(1000 * percentile(alignments, 0.1)).toStringAsFixed(0)} ms, '
        'p90 ${(1000 * percentile(alignments, 0.9)).toStringAsFixed(0)} ms');
  }

  // --- reaction to a bowed attack --------------------------------------
  stdout.writeln('');
  stdout.writeln('BOWED ATTACK — from the bow starting to a correct, settled '
      'reading');
  stdout.writeln('pipeline                 first reading  first correct  '
      'settled   notes');
  for (final pipeline in pipelines) {
    final firstReading = <double>[], firstCorrect = <double>[],
        settled = <double>[];
    for (final take in takes) {
      if (!take.hasReliableNominal) continue;
      final wav = readWav(take.path);
      final rate = wav.sampleRate.toDouble();
      final onset = detectOnset(wav.samples, rate);
      final engine = PitchEngine.of(pipeline.detector,
          sampleRate: rate, windowSize: window);
      final smoother = PitchSmoother();
      final legacy = MedianFilter();

      double? seen, correct, lastWrong;
      for (int start = 0; start + window <= wav.samples.length; start += hop) {
        final block =
            Float64List.sublistView(wav.samples, start, start + window);
        final estimate = engine.analyse(block);
        double value = 0;
        switch (pipeline.smoothing) {
          case Smoothing.pitchSmoother:
            value = smoother.accept(
                    pitched: estimate.pitched,
                    probability: estimate.probability,
                    pitch: estimate.frequency) ??
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
        // Displayed when its last sample has arrived, as §9 times it.
        final at = (start + window) / rate;
        if (at < onset) continue;
        final since = at - onset;
        if (since > 2.0) break;
        if (value <= 0) continue;
        seen ??= since;
        if (cents(value, take.nominal).abs() <= 50) {
          correct ??= since;
        } else {
          lastWrong = since;
        }
      }
      if (seen != null) firstReading.add(seen);
      if (correct != null) {
        firstCorrect.add(correct);
        settled.add(lastWrong ?? 0);
      }
    }
    stdout.writeln([
      pipeline.name.padRight(24),
      '${(1000 * percentile(firstReading, 0.5)).toStringAsFixed(0)} ms'.padLeft(13),
      '${(1000 * percentile(firstCorrect, 0.5)).toStringAsFixed(0)} ms'.padLeft(14),
      '${(1000 * percentile(settled, 0.5)).toStringAsFixed(0)} ms'.padLeft(9),
      firstCorrect.length.toString().padLeft(7),
    ].join(' '));
  }
}
