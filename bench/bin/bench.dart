// The benchmark: every pipeline variant against GuitarSet, file by file.
//
//   dart run bin/bench.dart --data /mnt/storage/tuner-bench/datasets \
//       --subset solo --jobs 4 --out results/solo.json
//
// GuitarSet's audio and annotations are CC BY 4.0 and stay outside the repo;
// only the numbers come back.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:tuner_bench/evaluate.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/app/tuner_core.dart';

class Args {
  String data = '/mnt/storage/tuner-bench/datasets';
  String subset = 'solo'; // solo | comp | all
  int limit = 0;
  int hop = 1024;
  int window = pitchWindowSize;
  int jobs = 4;
  String? out;
}

Args parse(List<String> argv) {
  final a = Args();
  for (int i = 0; i < argv.length; i++) {
    String next() => argv[++i];
    switch (argv[i]) {
      case '--data':
        a.data = next();
      case '--subset':
        a.subset = next();
      case '--limit':
        a.limit = int.parse(next());
      case '--hop':
        a.hop = int.parse(next());
      case '--window':
        a.window = int.parse(next());
      case '--jobs':
        a.jobs = int.parse(next());
      case '--out':
        a.out = next();
      default:
        stderr.writeln('unknown option ${argv[i]}');
        exit(2);
    }
  }
  return a;
}

Future<void> main(List<String> argv) async {
  final args = parse(argv);
  final audioDir = Directory('${args.data}/audio');
  final annDir = Directory('${args.data}/annotation');

  final pairs = <({String wav, String jams})>[];
  final wavs = audioDir
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.wav'))
      .toList()
    ..sort();
  for (final wav in wavs) {
    final base = wav.split('/').last.replaceAll('_mic.wav', '');
    if (args.subset != 'all' && !base.endsWith('_${args.subset}')) continue;
    final jams = '${annDir.path}/$base.jams';
    if (!File(jams).existsSync()) {
      stderr.writeln('no annotation for $base, skipping');
      continue;
    }
    pairs.add((wav: wav, jams: jams));
  }
  if (args.limit > 0 && pairs.length > args.limit) {
    pairs.removeRange(args.limit, pairs.length);
  }

  stdout.writeln('files       : ${pairs.length} (${args.subset})');
  stdout.writeln('window/hop  : ${args.window} / ${args.hop} samples '
      '(${(44100 / args.hop).toStringAsFixed(1)} frames/s)');
  stdout.writeln('variants    : ${defaultVariants.length}');
  stdout.writeln('');

  final aggregate = <String, MethodStats>{};
  final perFileB = <String, double>{};
  final sw = Stopwatch()..start();
  int done = 0;

  Future<void> runOne(({String wav, String jams}) p) async {
    final window = args.window;
    final hop = args.hop;
    final encoded = await Isolate.run(() {
      final r = evaluateFile(
        wavPath: p.wav,
        jamsPath: p.jams,
        window: window,
        hop: hop,
      );
      return jsonEncode({
        'file': r.file,
        'stats': jsonDecode(MethodStats.encodeAll(r.stats)),
        'medianB': r.medianB,
        'bFrames': r.bFrames,
      });
    });
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    final stats =
        MethodStats.decodeAll(jsonEncode(decoded['stats']));
    for (final e in stats.entries) {
      aggregate.putIfAbsent(e.key, () => MethodStats(e.key)).merge(e.value);
    }
    if (decoded['medianB'] != null) {
      perFileB[decoded['file'] as String] = (decoded['medianB'] as num).toDouble();
    }
    done++;
    stdout.write('\r  ${done.toString().padLeft(4)}/${pairs.length} '
        '${(sw.elapsed.inSeconds)}s  ${decoded['file']}'.padRight(78));
  }

  // A small pool: the work is CPU-bound, so one isolate per core.
  final queue = List.of(pairs);
  final workers = List.generate(args.jobs, (_) async {
    while (queue.isNotEmpty) {
      await runOne(queue.removeAt(0));
    }
  });
  await Future.wait(workers);
  sw.stop();
  stdout.writeln('\n');

  printTable(aggregate);

  if (perFileB.isNotEmpty) {
    final bs = perFileB.values.toList()..sort();
    stdout.writeln('');
    stdout.writeln('inharmonicity B (per-file medians, ${bs.length} files): '
        'p10 ${bs[bs.length ~/ 10].toStringAsExponential(2)}  '
        'median ${bs[bs.length ~/ 2].toStringAsExponential(2)}  '
        'p90 ${bs[(bs.length * 9) ~/ 10].toStringAsExponential(2)}');
  }

  if (args.out != null) {
    final f = File(args.out!);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({
      'files': pairs.length,
      'subset': args.subset,
      'window': args.window,
      'hop': args.hop,
      'elapsedSeconds': sw.elapsed.inSeconds,
      'stats': jsonDecode(MethodStats.encodeAll(aggregate)),
      'inharmonicity': perFileB,
    }));
    stdout.writeln('\nwrote ${args.out}');
  }
}

String pct(double v) => (100 * v).toStringAsFixed(2);

void printTable(Map<String, MethodStats> stats) {
  stdout.writeln('all monophonic frames                       | '
      'held-note frames only                        | voicing');
  stdout.writeln('variant                  RPA%  rep%  oct% gross% | '
      'RPA%  oct% gross%  |err|p50   p90    p99  >5c% | jit90  VR%   FA%');
  for (final s in stats.values) {
    final reportRate = s.monoFrames == 0 ? 0.0 : s.reported / s.monoFrames;
    stdout.writeln([
      s.name.padRight(22),
      pct(s.rawPitchAccuracy).padLeft(5),
      pct(reportRate).padLeft(5),
      pct(s.octaveRate).padLeft(5),
      pct(s.grossRate).padLeft(6),
      '|',
      pct(s.steadyAccuracy).padLeft(5),
      pct(s.steadyOctaveRate).padLeft(5),
      pct(s.steadyGrossRate).padLeft(6),
      s.fineSteady.absPercentile(0.5).toStringAsFixed(2).padLeft(8),
      s.fineSteady.absPercentile(0.9).toStringAsFixed(2).padLeft(6),
      s.fineSteady.absPercentile(0.99).toStringAsFixed(2).padLeft(6),
      pct(s.fineSteady.fractionBeyond(5)).padLeft(5),
      '|',
      s.jitter.absPercentile(0.9).toStringAsFixed(2).padLeft(5),
      pct(s.voicingRecall).padLeft(5),
      pct(s.voicingFalseAlarm).padLeft(5),
    ].join(' '));
  }
  stdout.writeln('');
  final any = stats.values.first;
  stdout.writeln('frames: ${any.monoFrames} monophonic '
      '(${any.steadyFrames} of them held notes), ${any.polyFrames} '
      'polyphonic, ${any.refUnvoiced} silent');
  final poly = stats.values
      .where((s) => s.polyReported > 0)
      .map((s) =>
          '${s.name} ${pct(s.polyMatchedAnyString / s.polyReported)}%')
      .take(3)
      .join(', ');
  stdout.writeln('on polyphonic frames, "named some sounding string": $poly');
}
