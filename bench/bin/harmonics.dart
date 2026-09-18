// What the partials say, measured across the corpus.
//
//   dart run bin/harmonics.dart --subset solo --jobs 3 --limit 60
//
// Three questions, none of which the detector can answer for itself:
//
//   1. How inharmonic is a real guitar string, measured rather than assumed?
//      B is what stretch tuning is about, and the app now measures it.
//   2. How many partials are actually there to measure, on real recorded
//      audio rather than on a synthesiser?
//   3. **Can the spectrum catch the detector's octave errors?**
//      `HarmonicProfile.detectorPartial` says which partial the detector
//      locked onto. Ground truth says whether it was octave-wrong. Putting
//      those side by side gives a precision/recall for using the partials as
//      an octave guard in the app — which is the only reason to believe it is
//      worth shipping.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tuner_bench/app/detectors.dart';
import 'package:tuner_bench/app/harmonics.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/wav.dart';

class Tally {
  int frames = 0; // pitched frames examined
  int withProfile = 0; // frames where partials were measurable
  int withB = 0; // frames where the stiffness fit held up
  final List<double> bValues = [];
  final List<int> partialCounts = [];
  final List<double> fundamentalShares = [];

  // Octave guard: truth (was the detector octave-wrong?) vs the spectrum's
  // verdict (detectorPartial != 1).
  int truePositive = 0; // octave-wrong, and flagged
  int falseNegative = 0; // octave-wrong, not flagged
  int falsePositive = 0; // correct, but flagged
  int trueNegative = 0; // correct, and not flagged
  int monoFrames = 0;

  Map<String, dynamic> toJson() => {
        'frames': frames,
        'withProfile': withProfile,
        'withB': withB,
        'bValues': bValues,
        'partialCounts': partialCounts,
        'fundamentalShares': fundamentalShares,
        'truePositive': truePositive,
        'falseNegative': falseNegative,
        'falsePositive': falsePositive,
        'trueNegative': trueNegative,
        'monoFrames': monoFrames,
      };

  void mergeJson(Map<String, dynamic> j) {
    frames += j['frames'] as int;
    withProfile += j['withProfile'] as int;
    withB += j['withB'] as int;
    bValues.addAll((j['bValues'] as List).map((v) => (v as num).toDouble()));
    partialCounts
        .addAll((j['partialCounts'] as List).map((v) => (v as num).toInt()));
    fundamentalShares.addAll(
        (j['fundamentalShares'] as List).map((v) => (v as num).toDouble()));
    truePositive += j['truePositive'] as int;
    falseNegative += j['falseNegative'] as int;
    falsePositive += j['falsePositive'] as int;
    trueNegative += j['trueNegative'] as int;
    monoFrames += j['monoFrames'] as int;
  }
}

Map<String, dynamic> analyseFile(String wavPath, String jamsPath, int hop) {
  final wav = readWav(wavPath);
  final truth = readJams(jamsPath);
  final rate = wav.sampleRate.toDouble();
  final tolerance = truth.hop / 2;
  final engine = YinEngine(sampleRate: rate, windowSize: pitchWindowSize);
  final smoother = PitchSmoother();
  final tally = Tally();

  for (int start = 0;
      start + pitchWindowSize <= wav.samples.length;
      start += hop) {
    final block =
        Float64List.sublistView(wav.samples, start, start + pitchWindowSize);
    final estimate = engine.analyse(block);
    final pitch = smoother.accept(
      pitched: estimate.pitched,
      probability: estimate.probability,
      pitch: estimate.frequency,
    );
    if (pitch == null) continue;
    tally.frames++;

    final profile = analyseHarmonics(block, pitch, rate);
    if (profile.isEmpty) continue;
    tally.withProfile++;
    tally.partialCounts.add(profile.partials.length);
    tally.fundamentalShares.add(profile.fundamentalShare);
    if (profile.inharmonicity != null) {
      tally.withB++;
      tally.bValues.add(profile.inharmonicity!);
    }

    // The octave guard, scored against the annotation. YIN's answer describes
    // the start of its window (bench/REPORT.md §1), so that is where the
    // reference is read.
    final active = truth.activeAt(start / rate, tolerance);
    if (active.length != 1) continue;
    tally.monoFrames++;
    final err = cents(pitch, active.first.frequency);
    final octaves = err / 1200;
    final wrongOctave = err.abs() > 50 &&
        (octaves - octaves.roundToDouble()).abs() * 1200 <= 50 &&
        octaves.round() != 0;
    final flagged = profile.detectorOnWrongPartial;
    if (wrongOctave && flagged) {
      tally.truePositive++;
    } else if (wrongOctave && !flagged) {
      tally.falseNegative++;
    } else if (!wrongOctave && flagged && err.abs() <= 50) {
      tally.falsePositive++;
    } else if (!wrongOctave && !flagged && err.abs() <= 50) {
      tally.trueNegative++;
    }
  }
  return tally.toJson();
}

double percentile(List<double> sorted, double p) =>
    sorted.isEmpty ? double.nan : sorted[(p * (sorted.length - 1)).round()];

Future<void> main(List<String> argv) async {
  String data = '/mnt/storage/tuner-bench/datasets';
  String subset = 'solo';
  int limit = 0, jobs = 3, hop = 1024;
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--data':
        data = argv[++i];
      case '--subset':
        subset = argv[++i];
      case '--limit':
        limit = int.parse(argv[++i]);
      case '--jobs':
        jobs = int.parse(argv[++i]);
      case '--hop':
        hop = int.parse(argv[++i]);
      default:
        stderr.writeln('unknown option ${argv[i]}');
        exit(2);
    }
  }

  final wavs = Directory('$data/audio')
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.wav'))
      .toList()
    ..sort();
  final pairs = <({String wav, String jams})>[];
  for (final wav in wavs) {
    final base = wav.split('/').last.replaceAll('_mic.wav', '');
    if (!base.endsWith('_$subset')) continue;
    final jams = '$data/annotation/$base.jams';
    if (File(jams).existsSync()) pairs.add((wav: wav, jams: jams));
  }
  if (limit > 0 && pairs.length > limit) pairs.removeRange(limit, pairs.length);

  stdout.writeln('files   : ${pairs.length} ($subset)');
  final total = Tally();
  final queue = List.of(pairs);
  int done = 0;
  final sw = Stopwatch()..start();

  await Future.wait(List.generate(jobs, (_) async {
    while (queue.isNotEmpty) {
      final p = queue.removeAt(0);
      final encoded = await Isolate.run(
          () => jsonEncode(analyseFile(p.wav, p.jams, hop)));
      total.mergeJson(jsonDecode(encoded) as Map<String, dynamic>);
      done++;
      stdout.write('\r  $done/${pairs.length}  ${sw.elapsed.inSeconds}s   ');
    }
  }));
  stdout.writeln('\n');

  final bs = total.bValues..sort();
  final shares = total.fundamentalShares..sort();
  final counts = total.partialCounts..sort();

  stdout.writeln('pitched frames        : ${total.frames}');
  stdout.writeln('partials measurable   : ${total.withProfile} '
      '(${(100 * total.withProfile / math.max(1, total.frames)).toStringAsFixed(1)}%)');
  if (counts.isNotEmpty) {
    stdout.writeln('partials per frame    : '
        'p10 ${counts[(counts.length * 0.1).round()]}  '
        'median ${counts[counts.length ~/ 2]}  '
        'p90 ${counts[(counts.length * 0.9).round()]}');
  }
  if (shares.isNotEmpty) {
    stdout.writeln('energy in fundamental : '
        'p10 ${percentile(shares, 0.1).toStringAsFixed(2)}  '
        'median ${percentile(shares, 0.5).toStringAsFixed(2)}  '
        'p90 ${percentile(shares, 0.9).toStringAsFixed(2)}');
  }
  stdout.writeln('stiffness fitted      : ${total.withB} frames '
      '(${(100 * total.withB / math.max(1, total.withProfile)).toStringAsFixed(1)}% '
      'of those with partials)');
  if (bs.isNotEmpty) {
    stdout.writeln('inharmonicity B       : '
        'p10 ${percentile(bs, 0.1).toStringAsExponential(2)}  '
        'median ${percentile(bs, 0.5).toStringAsExponential(2)}  '
        'p90 ${percentile(bs, 0.9).toStringAsExponential(2)}');
    final median = percentile(bs, 0.5);
    final stretch = 1200 *
        math.log(math.sqrt(1 + median * 4) / math.sqrt(1 + median)) /
        math.ln2;
    stdout.writeln('  → octave stretch at the median B: '
        '${stretch.toStringAsFixed(2)} cents');
  }

  stdout.writeln('');
  stdout.writeln('Using the partials as an octave guard, against the '
      'annotation (${total.monoFrames} monophonic frames):');
  final tp = total.truePositive, fn = total.falseNegative;
  final fp = total.falsePositive, tn = total.trueNegative;
  stdout.writeln('  octave-wrong frames caught : $tp of ${tp + fn}'
      '${tp + fn == 0 ? "" : " (${(100 * tp / (tp + fn)).toStringAsFixed(1)}% recall)"}');
  stdout.writeln('  correct frames wrongly flagged: $fp of ${fp + tn}'
      '${fp + tn == 0 ? "" : " (${(100 * fp / (fp + tn)).toStringAsFixed(2)}%)"}');
  if (tp + fp > 0) {
    stdout.writeln('  precision of the flag       : '
        '${(100 * tp / (tp + fp)).toStringAsFixed(1)}%');
  }
}
