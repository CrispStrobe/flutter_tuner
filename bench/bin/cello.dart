// A bowed instrument, and vibrato — the corpus this report has been missing.
//
//   dart run bin/cello.dart --data /mnt/storage/tuner-bench/datasets/muserc/MUSERC/SA
//
// See lib/cello.dart for what MUSERC can and cannot answer. In short: the
// note the cellist was aiming at is known from the filename, so note-naming
// and octave errors are scoreable; the needle's stillness and its ability to
// follow vibrato need no reference at all.

import 'dart:io';

import 'package:tuner_bench/app/detectors.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/cello.dart';
import 'package:tuner_bench/note_latency.dart' show NotePipeline, Smoothing;

const pipelines = [
  NotePipeline('before (legacy median)', DetectorKind.yin, Smoothing.legacyMedian),
  NotePipeline('after (PitchSmoother)', DetectorKind.yin, Smoothing.pitchSmoother),
  NotePipeline('no median at all', DetectorKind.yin, Smoothing.gateOnly),
  NotePipeline('MPM + PitchSmoother', DetectorKind.mpm, Smoothing.pitchSmoother),
];

double median(List<double> values) {
  if (values.isEmpty) return double.nan;
  final sorted = List<double>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

double percentile(List<double> values, double p) {
  if (values.isEmpty) return double.nan;
  final sorted = List<double>.of(values)..sort();
  return sorted[(p * (sorted.length - 1)).round()];
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
  if (takes.isEmpty) {
    stderr.writeln('no MUSERC takes found in $data');
    exit(1);
  }
  final steady = takes.where((t) => t.steady).toList();
  final vibrato = takes.where((t) => !t.steady).toList();
  stdout.writeln('takes   : ${takes.length} '
      '(${steady.length} steady, ${vibrato.length} vibrato)');
  final notes = (takes.map((t) => t.midi).toSet().toList()..sort());
  stdout.writeln('notes   : ${notes.map(noteNameForMidi).join(", ")}');
  stdout.writeln('window  : $window samples, hop $hop');
  stdout.writeln('');

  String pct(double v) => (100 * v).toStringAsFixed(1).padLeft(5);
  String c(double v) => v.isNaN ? '   —' : v.toStringAsFixed(2).padLeft(6);

  stdout.writeln('STEADY TAKES (bow attack excluded)');
  stdout.writeln('pipeline                 named%  oct%   rep%   '
      'spread p90  jitter p90   player offset');
  for (final pipeline in pipelines) {
    final named = <double>[], octave = <double>[], rep = <double>[];
    final spread = <double>[], jitter = <double>[], offset = <double>[];
    for (final take in steady) {
      final o = measureTake(take, pipeline, window: window, hop: hop);
      if (o.reported == 0) {
        rep.add(0);
        continue;
      }
      named.add(o.namedCorrectly / o.reported);
      octave.add(o.octaveAway / o.reported);
      rep.add(o.reported / o.frames);
      if (!o.spreadP90.isNaN) spread.add(o.spreadP90);
      if (!o.jitterP90.isNaN) jitter.add(o.jitterP90);
      if (!o.medianOffsetCents.isNaN) offset.add(o.medianOffsetCents);
    }
    stdout.writeln([
      pipeline.name.padRight(24),
      pct(median(named)),
      pct(median(octave)),
      pct(median(rep)),
      c(median(spread)),
      '    ',
      c(median(jitter)),
      '    ',
      '${median(offset).toStringAsFixed(1)} cents'.padLeft(12),
    ].join(' '));
  }

  stdout.writeln('');
  stdout.writeln('VIBRATO TAKES — how much of the cellist\'s vibrato survives');
  stdout.writeln('pipeline                 excursion p50   p90    named%  rep%');
  for (final pipeline in pipelines) {
    final excursion = <double>[], named = <double>[], rep = <double>[];
    for (final take in vibrato) {
      final o = measureTake(take, pipeline, window: window, hop: hop);
      if (o.reported == 0) continue;
      if (!o.excursion.isNaN) excursion.add(o.excursion);
      named.add(o.namedCorrectly / o.reported);
      rep.add(o.reported / o.frames);
    }
    stdout.writeln([
      pipeline.name.padRight(24),
      c(percentile(excursion, 0.5)),
      c(percentile(excursion, 0.9)),
      '  ',
      pct(median(named)),
      pct(median(rep)),
    ].join(' '));
  }

  stdout.writeln('');
  stdout.writeln('Per-note, with the shipped pipeline (steady takes):');
  stdout.writeln('note   nominal Hz   takes  named%  spread p90  offset');
  for (final midi in notes) {
    final forNote = steady.where((t) => t.midi == midi).toList();
    if (forNote.isEmpty) continue;
    final named = <double>[], spread = <double>[], offset = <double>[];
    for (final take in forNote) {
      final o = measureTake(take, pipelines[1], window: window, hop: hop);
      if (o.reported == 0) continue;
      named.add(o.namedCorrectly / o.reported);
      if (!o.spreadP90.isNaN) spread.add(o.spreadP90);
      if (!o.medianOffsetCents.isNaN) offset.add(o.medianOffsetCents);
    }
    stdout.writeln([
      noteNameForMidi(midi).padRight(6),
      forNote.first.nominal.toStringAsFixed(2).padLeft(10),
      forNote.length.toString().padLeft(6),
      pct(median(named)),
      c(median(spread)),
      '  ',
      '${median(offset).toStringAsFixed(1)}c'.padLeft(8),
    ].join(' '));
  }
}
