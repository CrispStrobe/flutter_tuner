// SWIPE' against YIN, on the same frames, by the same rules.
//
//   dart run bin/swipe.dart --limit 20 --jobs 2 --hop 1024
//
// The brief asked for SWIPE' as a comparison point and this is it. It is run
// on a subset rather than the whole corpus for one reason, which is itself
// part of the answer: it costs tens of milliseconds a frame where YIN costs
// 1.6, so a full-corpus run would take hours.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:tuner_bench/app/detectors.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/swipe.dart';
import 'package:tuner_bench/wav.dart';

Map<String, dynamic> evaluate(String wavPath, String jamsPath, int hop,
    List<double> swipeThresholds) {
  final wav = readWav(wavPath);
  final truth = readJams(jamsPath);
  final rate = wav.sampleRate.toDouble();
  final tolerance = truth.hop / 2;
  final yin = YinEngine(sampleRate: rate, windowSize: pitchWindowSize);
  // The estimator never rejects; the thresholds are applied afterwards, so
  // one pass measures the whole sweep — the same trick the YIN threshold
  // sweep uses in evaluate.dart.
  final swipe = SwipeEstimator(sampleRate: rate, strengthThreshold: -1);
  final swipeGlobal = SwipeEstimator(
      sampleRate: rate, strengthThreshold: -1, localNormalisation: false);
  final globalSmoother = PitchSmoother();
  final yinSmoother = PitchSmoother();
  final swipeSmoothers = {
    for (final t in swipeThresholds) t: PitchSmoother()
  };

  final stats = {
    'yin': MethodStats('yin'),
    for (final t in swipeThresholds)
      'swipe@$t': MethodStats('swipe@$t'),
    'swipe-global-norm': MethodStats('swipe-global-norm'),
  };
  int frames = 0;
  int yinMicros = 0, swipeMicros = 0;
  final sw = Stopwatch();

  for (int start = 0;
      start + pitchWindowSize <= wav.samples.length;
      start += hop) {
    final block =
        Float64List.sublistView(wav.samples, start, start + pitchWindowSize);
    frames++;

    sw.reset();
    sw.start();
    final y = yin.analyse(block);
    sw.stop();
    yinMicros += sw.elapsedMicroseconds;

    sw.reset();
    sw.start();
    final s = swipe.analyse(block);
    sw.stop();
    swipeMicros += sw.elapsedMicroseconds;
    final g = swipeGlobal.analyse(block);

    final yv = yinSmoother.accept(
        pitched: y.pitched, probability: y.probability, pitch: y.frequency);
    // SWIPE' has no aperiodicity, and its pitch strength is on a different
    // scale entirely — around 0.77 on a clean plucked string, where YIN's
    // periodicity is above 0.95. Passing that through the app's
    // `probability > 0.9` gate rejects every frame, which is what a first
    // run of this file did. So the estimator's own strength threshold makes
    // the voicing decision (swept by --threshold), and the smoother is told
    // the frame passed.
    final active = truth.activeAt(start / rate, tolerance);
    final entries = <(String, double?)>[('yin', yv)];
    for (final t in swipeThresholds) {
      final passes = s.pitched && s.probability >= t;
      entries.add((
        'swipe@$t',
        swipeSmoothers[t]!.accept(
            pitched: passes, probability: passes ? 1.0 : 0.0,
            pitch: s.frequency)
      ));
    }
    entries.add((
      'swipe-global-norm',
      globalSmoother.accept(
          pitched: g.pitched && g.probability >= 0.2,
          probability: 1.0,
          pitch: g.frequency)
    ));
    for (final entry in entries) {
      final st = stats[entry.$1]!;
      final value = entry.$2;
      if (active.isEmpty) {
        st.refUnvoiced++;
        if (value != null) st.refUnvoicedReported++;
      } else {
        st.refVoiced++;
        if (value != null) st.refVoicedReported++;
      }
      if (active.length == 1) {
        st.scoreMono(value, active.first.frequency);
      }
    }
  }

  return {
    'stats': jsonDecode(MethodStats.encodeAll(stats)),
    'frames': frames,
    'yinMicros': yinMicros,
    'swipeMicros': swipeMicros,
  };
}

Future<void> main(List<String> argv) async {
  String data = '/mnt/storage/tuner-bench/datasets';
  int limit = 20, jobs = 2, hop = 1024;
  var thresholds = <double>[0.2, 0.5, 0.6, 0.65, 0.7, 0.75];
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--data':
        data = argv[++i];
      case '--limit':
        limit = int.parse(argv[++i]);
      case '--jobs':
        jobs = int.parse(argv[++i]);
      case '--hop':
        hop = int.parse(argv[++i]);
      case '--thresholds':
        thresholds =
            argv[++i].split(',').map(double.parse).toList();
      default:
        stderr.writeln('unknown option ${argv[i]}');
        exit(2);
    }
  }

  final wavs = Directory('$data/audio')
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('_solo_mic.wav'))
      .toList()
    ..sort();
  final pairs = <({String wav, String jams})>[];
  for (final wav in wavs) {
    final base = wav.split('/').last.replaceAll('_mic.wav', '');
    final jams = '$data/annotation/$base.jams';
    if (File(jams).existsSync()) pairs.add((wav: wav, jams: jams));
  }
  if (pairs.length > limit) pairs.removeRange(limit, pairs.length);

  stdout.writeln('files     : ${pairs.length} (solo)');
  stdout.writeln('hop       : $hop samples, SWIPE\' thresholds $thresholds');

  final aggregate = <String, MethodStats>{};
  int totalFrames = 0, yinMicros = 0, swipeMicros = 0;
  final queue = List.of(pairs);
  int done = 0;
  final sw = Stopwatch()..start();

  await Future.wait(List.generate(jobs, (_) async {
    while (queue.isNotEmpty) {
      final p = queue.removeAt(0);
      final encoded = await Isolate.run(
          () => jsonEncode(evaluate(p.wav, p.jams, hop, thresholds)));
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final stats = MethodStats.decodeAll(jsonEncode(decoded['stats']));
      for (final e in stats.entries) {
        aggregate.putIfAbsent(e.key, () => MethodStats(e.key)).merge(e.value);
      }
      totalFrames += decoded['frames'] as int;
      yinMicros += decoded['yinMicros'] as int;
      swipeMicros += decoded['swipeMicros'] as int;
      done++;
      stdout.write('\r  $done/${pairs.length}  ${sw.elapsed.inSeconds}s   ');
    }
  }));
  stdout.writeln('\n');

  String pct(double v) => (100 * v).toStringAsFixed(2);
  stdout.writeln('estimator  RPA%   rep%   oct%  gross%  |err| p50   p90'
      '    p99   >5c%   VR%    FA%     ms/frame');
  for (final s in aggregate.values) {
    final reportRate = s.monoFrames == 0 ? 0.0 : s.reported / s.monoFrames;
    final micros = s.name == 'yin' ? yinMicros : swipeMicros;
    stdout.writeln([
      s.name.padRight(9),
      pct(s.rawPitchAccuracy).padLeft(6),
      pct(reportRate).padLeft(6),
      pct(s.octaveRate).padLeft(6),
      pct(s.grossRate).padLeft(6),
      s.fine.absPercentile(0.5).toStringAsFixed(2).padLeft(10),
      s.fine.absPercentile(0.9).toStringAsFixed(2).padLeft(6),
      s.fine.absPercentile(0.99).toStringAsFixed(2).padLeft(6),
      pct(s.fine.fractionBeyond(5)).padLeft(6),
      pct(s.voicingRecall).padLeft(6),
      pct(s.voicingFalseAlarm).padLeft(6),
      (micros / 1000 / totalFrames).toStringAsFixed(2).padLeft(12),
    ].join(' '));
  }
  stdout.writeln('');
  stdout.writeln('$totalFrames frames; both estimators ran on every one of '
      'them, through the same PitchSmoother.');
}
