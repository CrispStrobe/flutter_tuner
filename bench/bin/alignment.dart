// Where in the analysis window does the estimate actually belong?
//
// A cent-error figure is only honest if the reference instant is the right
// one. YIN's difference function at a 4096-sample window only ever looks at
// the first half of it, so its estimate is weighted towards the beginning of
// the window; the instantaneous-frequency refinement reads the *last* couple
// of thousand samples instead. Comparing both against the same assumed centre
// would flatter one and punish the other.
//
// So: sweep the assumed reference instant across the window and report the
// median absolute error at each offset. The minimum is where that estimator's
// answer really lives; the depth of the minimum is its precision.
//
//   dart run bin/alignment.dart [files]

import 'dart:io';
import 'dart:typed_data';

import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/narrowband.dart';
import 'package:tuner_bench/refine.dart';
import 'package:tuner_bench/wav.dart';
import 'package:tuner_bench/yin.dart';

const data = '/mnt/storage/tuner-bench/datasets';

void main(List<String> args) {
  final count = args.isEmpty ? 12 : int.parse(args[0]);
  final wavs = Directory('$data/audio')
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('_solo_mic.wav'))
      .toList()
    ..sort();
  final chosen = [
    for (int i = 0; i < wavs.length && i < count * 15; i += 15) wavs[i]
  ].take(count).toList();

  const offsets = [0, 512, 1024, 1536, 2048, 2560, 3072, 3584, 4095];
  final plain = {for (final o in offsets) o: CentHistogram()};
  final refined = {for (final o in offsets) o: CentHistogram()};
  final goertzel = {for (final o in offsets) o: CentHistogram()};
  const hop = 1024;
  int frames = 0;

  for (final wavPath in chosen) {
    final base = wavPath.split('/').last.replaceAll('_mic.wav', '');
    final truth = readJams('$data/annotation/$base.jams');
    final wav = readWav(wavPath);
    final rate = wav.sampleRate.toDouble();
    final yin =
        RefYin(sampleRate: rate, bufferSize: pitchWindowSize, useFft: true);
    final tolerance = truth.hop / 2;

    for (int start = 0;
        start + pitchWindowSize <= wav.samples.length;
        start += hop) {
      final block =
          Float64List.sublistView(wav.samples, start, start + pitchWindowSize);
      yin.cmndf(block);
      final r = yin.resultFromCmndf(0.20);
      if (!r.pitched || r.probability <= 0.9) continue;
      final ifr =
          refineByInstantaneousFrequency(block, r.pitch, rate).frequency;
      final gz = refineByGoertzel(block, r.pitch, rate, harmonics: 8);
      frames++;
      for (final o in offsets) {
        final t = (start + o) / rate;
        final active = truth.activeAt(t, tolerance);
        if (active.length != 1) continue;
        final ref = active.first.frequency;
        final e1 = cents(r.pitch, ref);
        if (e1.abs() <= 50) plain[o]!.add(e1);
        final e2 = cents(ifr, ref);
        if (e2.abs() <= 50) refined[o]!.add(e2);
        final e3 = cents(gz, ref);
        if (e3.abs() <= 50) goertzel[o]!.add(e3);
      }
    }
  }

  stdout.writeln('${chosen.length} files, $frames pitched frames, '
      'window $pitchWindowSize, hop $hop');
  stdout.writeln('');
  stdout.writeln('reference instant      YIN |err| p50   p90  |  '
      'YIN+IF |err| p50   p90  |  YIN+goertzel-h8 p50   p90');
  for (final o in offsets) {
    final p = plain[o]!, q = refined[o]!, g = goertzel[o]!;
    stdout.writeln('  +$o samples '
                '(${(1000 * o / 44100).toStringAsFixed(1)} ms)'
            .padRight(12) +
        '${p.absPercentile(0.5).toStringAsFixed(2).padLeft(10)}'
            '${p.absPercentile(0.9).toStringAsFixed(2).padLeft(7)}  |  '
            '${q.absPercentile(0.5).toStringAsFixed(2).padLeft(10)}'
            '${q.absPercentile(0.9).toStringAsFixed(2).padLeft(7)}  |  '
            '${g.absPercentile(0.5).toStringAsFixed(2).padLeft(16)}'
            '${g.absPercentile(0.9).toStringAsFixed(2).padLeft(7)}');
  }
}
