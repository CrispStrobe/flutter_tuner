// How far behind the pitch is the reading, while the pitch is moving?
//
//   dart run bin/tracking.dart --subset solo --jobs 3 --hop 512
//
// §9 times the tuner's cold start — pluck to correct reading. This times the
// other half: a bend or a slide moves the pitch continuously, and the needle
// follows it at some remove. That remove is what a player feels as
// sluggishness while turning a peg, and no frame-level metric shows it: a
// pipeline that is uniformly late scores a perfect RPA.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/tracking.dart';

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
      '(${(1000 * hop / 44100).toStringAsFixed(1)} ms per frame)');
  stdout.writeln('');

  final aggregate = <String, TrackingStats>{};
  final queue = List.of(pairs);
  int done = 0;
  final sw = Stopwatch()..start();

  await Future.wait(List.generate(jobs, (_) async {
    while (queue.isNotEmpty) {
      final p = queue.removeAt(0);
      final encoded = await Isolate.run(() {
        final stats = measureTrackingAll(
            wavPath: p.wav, jamsPath: p.jams, window: window, hop: hop);
        return jsonEncode(
            {for (final e in stats.entries) e.key: e.value.toJson()});
      });
      for (final e in (jsonDecode(encoded) as Map<String, dynamic>).entries) {
        aggregate
            .putIfAbsent(e.key, () => TrackingStats(e.key))
            .merge(TrackingStats.fromJson(e.value as Map<String, dynamic>));
      }
      done++;
      stdout.write('\r  $done/${pairs.length}  ${sw.elapsed.inSeconds}s   ');
    }
  }));
  stdout.writeln('\n');

  String ms(double v) => v.isNaN ? '  —' : (v * 1000).toStringAsFixed(0).padLeft(4);
  String c(double v) => v.isNaN ? '  —' : v.toStringAsFixed(2).padLeft(5);

  stdout.writeln('pipeline                 tracking lag (ms)      '
      'RMS error (cents)');
  stdout.writeln('                         p10   p50   p90        '
      'at best lag   unshifted');
  for (final s in aggregate.values) {
    stdout.writeln([
      s.name.padRight(24),
      ms(TrackingStats.percentile(s.lags, 0.1)),
      ms(TrackingStats.percentile(s.lags, 0.5)),
      ms(TrackingStats.percentile(s.lags, 0.9)),
      '      ',
      c(TrackingStats.percentile(s.rmsBest, 0.5)),
      '       ',
      c(TrackingStats.percentile(s.rmsZero, 0.5)),
    ].join(' '));
  }

  final any = aggregate.values.first;
  stdout.writeln('');
  stdout.writeln('${any.segments} moving segments (at least 40 cents of '
      'reference movement, so the lag is identifiable at all —');
  stdout.writeln('a held note fits every lag equally well). Positive lag '
      'means the reading trails the string.');

  if (out != null) {
    final f = File(out);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({
      'files': pairs.length,
      'hop': hop,
      'window': window,
      'pipelines': {for (final e in aggregate.entries) e.key: e.value.toJson()},
    }));
    stdout.writeln('\nwrote $out');
  }
}
