// After a pluck, how long until the tuner says the right thing?
//
//   dart run bin/notes.dart --subset solo --jobs 3 --hop 512
//
// The frame-level metrics in REPORT.md answer "what fraction of frames are
// right", which is not what anyone experiences. This one answers "how long
// does the needle take, and does it stay". Times are measured from the pluck
// to the moment a reading could be *displayed* — the end of its analysis
// window — so the window's own 93 ms is charged to the latency, as it is to
// the user.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/note_latency.dart';

String ms(double seconds) =>
    seconds.isNaN ? '   —' : (seconds * 1000).toStringAsFixed(0).padLeft(4);

Future<void> main(List<String> argv) async {
  String data = '/mnt/storage/tuner-bench/datasets';
  String subset = 'solo';
  int limit = 0, jobs = 3, hop = 512, window = pitchWindowSize;
  String? out;
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
      case '--window':
        window = int.parse(argv[++i]);
      case '--out':
        out = argv[++i];
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
  stdout.writeln('window  : $window samples, hop $hop '
      '(${(1000 * hop / 44100).toStringAsFixed(1)} ms between readings, '
      '${(1000 * window / 44100).toStringAsFixed(0)} ms of window)');
  stdout.writeln('');

  final aggregate = <String, LatencyStats>{};
  final queue = List.of(pairs);
  int done = 0;
  final sw = Stopwatch()..start();

  await Future.wait(List.generate(jobs, (_) async {
    while (queue.isNotEmpty) {
      final p = queue.removeAt(0);
      final encoded = await Isolate.run(() {
        final stats = measureAllPipelines(
          wavPath: p.wav,
          jamsPath: p.jams,
          window: window,
          hop: hop,
        );
        return jsonEncode(
            {for (final e in stats.entries) e.key: e.value.toJson()});
      });
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      for (final e in decoded.entries) {
        aggregate
            .putIfAbsent(e.key, () => LatencyStats(e.key))
            .merge(LatencyStats.fromJson(e.value as Map<String, dynamic>));
      }
      done++;
      stdout.write('\r  $done/${pairs.length}  ${sw.elapsed.inSeconds}s   ');
    }
  }));
  stdout.writeln('\n');

  stdout.writeln('                         first reading   first correct '
      '     settled      never    never   correct  stale');
  stdout.writeln('pipeline                 p50   p90       p50   p90     '
      '  p50   p90     correct  settles  share   before');
  for (final s in aggregate.values) {
    stdout.writeln([
      s.name.padRight(24),
      ms(LatencyStats.percentile(s.firstReading, 0.5)),
      ms(LatencyStats.percentile(s.firstReading, 0.9)),
      '    ',
      ms(LatencyStats.percentile(s.firstCorrect, 0.5)),
      ms(LatencyStats.percentile(s.firstCorrect, 0.9)),
      '    ',
      ms(LatencyStats.percentile(s.settled, 0.5)),
      ms(LatencyStats.percentile(s.settled, 0.9)),
      '   ',
      '${(100 * s.neverCorrect / s.notes).toStringAsFixed(1)}%'.padLeft(6),
      '${(100 * s.neverSettled / s.notes).toStringAsFixed(1)}%'.padLeft(7),
      '${(100 * LatencyStats.percentile(s.correctShares, 0.5)).toStringAsFixed(0)}%'
          .padLeft(6),
      '${(100 * LatencyStats.percentile(s.staleShares, 0.9)).toStringAsFixed(0)}%'
          .padLeft(6),
    ].join(' '));
  }

  final any = aggregate.values.first;
  stdout.writeln('');
  stdout.writeln('${any.notes} isolated notes '
      '(at least 300 ms long, no other string sounding across the pluck). '
      'Times in ms from the pluck.');
  stdout.writeln('"settled" is the last wrong reading before the note ended; '
      '"stale before" is the p90 share of');
  stdout.writeln('pre-settling readings that were within 50 cents of the '
      'PREVIOUS note — the needle still showing');
  stdout.writeln('what you played last.');

  if (out != null) {
    final f = File(out);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({
      'files': pairs.length,
      'subset': subset,
      'window': window,
      'hop': hop,
      'pipelines': {
        for (final e in aggregate.entries) e.key: e.value.toJson()
      },
    }));
    stdout.writeln('\nwrote $out');
  }
}
