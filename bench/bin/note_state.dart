// §27.3's next experiment: a bounded-lag note-state HMM over pYIN, against
// the tuner as it ships — accuracy, false alarms and response time together.
//
//   dart run bin/note_state.dart --data <guitarset> --subset solo --jobs 4
//
// Frame metrics are `evaluate.dart`'s, unchanged. Response time is measured
// on the same per-frame readings, on isolated plucks (`isolatedNotes`), with
// a reading shown at the moment it could be: the end of its analysis window
// plus the variant's decoding lag. The offline arm has no such moment — it
// needs the end of the recording — so its times are printed as if it had
// none, and marked: they are a bound, not a result.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:tuner_bench/app/detectors.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/error_attribution.dart';
import 'package:tuner_bench/evaluate.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/note_latency.dart';

/// Variant, and the frames of lookahead it needs before showing a frame
/// (null = needs the whole recording).
final List<(Variant, int?)> arms = [
  (Variant('engine-yin (ships)',
      appEngine: DetectorKind.yin, coreSmoother: true), 0),
  (Variant('pyin-lag0', isPyin: true, pyinLag: 0), 0),
  (Variant('pyin-lag0+hmm offline', isPyin: true, pyinLag: 0, hmmMask: true),
      null),
  // Response time turns out to be set by minFrames, not by the lag: a run
  // must be known to reach minFrames before it is shown, whether those
  // frames are waited for as lag or withheld. So the sweep is over
  // minFrames, each at lag 0 (rule fully causal) and at lag minFrames - 1
  // (the rule sees exactly what the offline one does).
  for (final m in [5, 4, 3, 2]) ...[
    (Variant('nhmm min$m lag0',
        isPyin: true, pyinLag: 0, noteLag: 0, noteMinFrames: m), 0),
    (Variant('nhmm min$m lag${m - 1}',
        isPyin: true, pyinLag: 0, noteLag: m - 1, noteMinFrames: m), m - 1),
  ],
  (Variant('nhmm min5 lag2',
      isPyin: true, pyinLag: 0, noteLag: 2, noteMinFrames: 5), 2),
  // No run rule at all: the note HMM's own decision, greedy.
  (Variant('nhmm min1 lag0',
      isPyin: true, pyinLag: 0, noteLag: 0, noteMinFrames: 1), 0),
  // §39.8: octave guards on the chosen operating point (min2, lag 0).
  // A penalty on direct octave jumps; a gate that drops or folds readings
  // an octave from the held note; and a cheaper octave-off emission so the
  // model can hold a note through a slip for the fold to act on.
  for (final (label, jump, emission, gate) in const [
    ('oct2', 2.0, null, NoteGate.none),
    ('oct5', 5.0, null, NoteGate.none),
    ('agree', 0.0, null, NoteGate.agree),
    ('fold', 0.0, null, NoteGate.fold),
    ('hold0.8 fold', 0.0, 0.8, NoteGate.fold),
    ('hold0.8 oct2 fold', 2.0, 0.8, NoteGate.fold),
    ('hold0.5 oct2 fold', 2.0, 0.5, NoteGate.fold),
  ])
    (Variant('nhmm min2 lag0 $label',
        isPyin: true, pyinLag: 0, noteLag: 0, noteMinFrames: 2,
        noteOctaveJump: jump, noteOctaveEmission: emission, noteGate: gate),
        0),
  // §39.9: borrow YIN's octave, per frame or once per note.
  (Variant('nhmm min2 lag0 yin-frame', isPyin: true, pyinLag: 0, noteLag: 0,
      noteMinFrames: 2, noteYinOctave: YinOctave.frame), 0),
  (Variant('nhmm min2 lag0 yin-run', isPyin: true, pyinLag: 0, noteLag: 0,
      noteMinFrames: 2, noteYinOctave: YinOctave.run), 0),
  (Variant('nhmm min3 lag0 yin-run', isPyin: true, pyinLag: 0, noteLag: 0,
      noteMinFrames: 3, noteYinOctave: YinOctave.run), 0),
  // The app's own engine (lib/pyin_note.dart). Unsmoothed it must match
  // `nhmm min2 lag0 yin-frame`, the pipeline it was ported from; smoothed
  // it is what the app shows, through the same PitchSmoother engine-yin uses.
  (Variant('engine-pyin-note raw', appEngine: DetectorKind.pyinNote), 0),
  (Variant('engine-pyin-note',
      appEngine: DetectorKind.pyinNote, coreSmoother: true), 0),
  // The release pipeline: refinement, then gate and median, as main.dart
  // runs it. engine-yin + refine is the app as it ships today.
  (Variant('release yin', appEngine: DetectorKind.yin,
      appRefine: true, coreSmoother: true), 0),
  (Variant('release pyin-note', appEngine: DetectorKind.pyinNote,
      appRefine: true, coreSmoother: true), 0),
  // The same without the median, in case this detector should skip it.
  (Variant('release pyin-note no median', appEngine: DetectorKind.pyinNote,
      appRefine: true), 0),
];

class Timing {
  int notes = 0, neverCorrect = 0;
  final List<double> firstCorrect = [];
  final List<double> firstReading = [];
  void merge(Timing o) {
    notes += o.notes;
    neverCorrect += o.neverCorrect;
    firstCorrect.addAll(o.firstCorrect);
    firstReading.addAll(o.firstReading);
  }

  Map<String, dynamic> toJson() => {
        'notes': notes,
        'neverCorrect': neverCorrect,
        'firstCorrect': firstCorrect,
        'firstReading': firstReading,
      };
  static Timing fromJson(Map<String, dynamic> j) => Timing()
    ..notes = j['notes'] as int
    ..neverCorrect = j['neverCorrect'] as int
    ..firstCorrect.addAll(
        (j['firstCorrect'] as List).map((v) => (v as num).toDouble()))
    ..firstReading.addAll(
        (j['firstReading'] as List).map((v) => (v as num).toDouble()));
}

Map<String, Timing> timeNotes(Map<String, List<double>> tracks, JamsTruth truth,
    {required int hop, required int window, required double rate}) {
  final notes = isolatedNotes(truth);
  final out = <String, Timing>{};
  for (final (v, lag) in arms) {
    final track = tracks[v.name]!;
    final delay = (lag ?? 0) * hop;
    final t = Timing();
    for (final note in notes) {
      t.notes++;
      double? first, firstOk;
      for (int i = 0; i < track.length; i++) {
        final shown = (i * hop + window + delay) / rate;
        if (shown < note.onset) continue;
        if (shown > note.offset) break;
        final p = track[i];
        if (p <= 0) continue;
        first ??= shown - note.onset;
        if (cents(p, note.frequency).abs() <= 50) {
          firstOk = shown - note.onset;
          break;
        }
      }
      if (first != null) t.firstReading.add(first);
      if (firstOk == null) {
        t.neverCorrect++;
      } else {
        t.firstCorrect.add(firstOk);
      }
    }
    out[v.name] = t;
  }
  return out;
}

Future<void> main(List<String> argv) async {
  var data = '/mnt/storage/tuner-bench/datasets';
  var subset = 'solo';
  var limit = 0, jobs = 4, hop = 1024;
  String? out;
  Set<String>? only;
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--only':
        only = argv[++i].split(',').map((s) => s.trim()).toSet();
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
      case '--out':
        out = argv[++i];
      default:
        stderr.writeln('unknown option ${argv[i]}');
        exit(2);
    }
  }
  const window = pitchWindowSize;
  if (only != null) {
    final unknown = only.difference({for (final (v, _) in arms) v.name});
    if (unknown.isNotEmpty) {
      stderr.writeln('unknown arm(s): ${unknown.join(', ')}');
      exit(2);
    }
    arms.retainWhere((a) => only!.contains(a.$1.name));
  }

  final pairs = <({String wav, String jams})>[];
  final wavs = Directory('$data/audio')
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.wav'))
      .toList()
    ..sort();
  for (final wav in wavs) {
    final base = wav.split('/').last.replaceAll('_mic.wav', '');
    if (subset != 'all' && !base.endsWith('_$subset')) continue;
    final jams = '$data/annotation/$base.jams';
    if (File(jams).existsSync()) pairs.add((wav: wav, jams: jams));
  }
  if (limit > 0 && pairs.length > limit) pairs.removeRange(limit, pairs.length);
  stdout.writeln('files: ${pairs.length} ($subset), window/hop $window/$hop '
      '(${(1000 * hop / 44100).toStringAsFixed(1)} ms a frame)');

  final stats = <String, MethodStats>{};
  final timing = <String, Timing>{};
  final attribution = <String, ErrorAttribution>{};
  final sw = Stopwatch()..start();
  var done = 0;
  final queue = List.of(pairs);

  Future<void> runOne(({String wav, String jams}) p) async {
    final encoded = await Isolate.run(() {
      final r = evaluateFile(
        wavPath: p.wav,
        jamsPath: p.jams,
        window: window,
        hop: hop,
        variants: [for (final (v, _) in arms) v],
        keepTracks: true,
      );
      final truth = readJams(p.jams);
      final t = timeNotes(r.tracks!, truth,
          hop: hop, window: window, rate: 44100);
      final attr = [
        for (final (v, _) in arms)
          attributeErrors(v.name, r.tracks![v.name]!, truth,
                  hop: hop, window: window, rate: 44100)
              .toJson()
      ];
      return jsonEncode({
        'attr': attr,
        'stats': jsonDecode(MethodStats.encodeAll(r.stats)),
        'timing': {for (final e in t.entries) e.key: e.value.toJson()},
      });
    });
    final d = jsonDecode(encoded) as Map<String, dynamic>;
    for (final e
        in MethodStats.decodeAll(jsonEncode(d['stats'])).entries) {
      stats.putIfAbsent(e.key, () => MethodStats(e.key)).merge(e.value);
    }
    for (final e in (d['timing'] as Map<String, dynamic>).entries) {
      timing
          .putIfAbsent(e.key, Timing.new)
          .merge(Timing.fromJson(e.value as Map<String, dynamic>));
    }
    for (final j in d['attr'] as List) {
      final a = ErrorAttribution.fromJson(j as Map<String, dynamic>);
      attribution.putIfAbsent(a.name, () => ErrorAttribution(a.name)).merge(a);
    }
    done++;
    stdout.write('\r  $done/${pairs.length} ${sw.elapsed.inSeconds}s   ');
  }

  await Future.wait(List.generate(jobs, (_) async {
    while (queue.isNotEmpty) {
      await runOne(queue.removeAt(0));
    }
  }));
  stdout.writeln('\n');

  String pct(double v) => (100 * v).toStringAsFixed(2);
  String ms(List<double> xs, double p) {
    if (xs.isEmpty) return '—';
    final s = List.of(xs)..sort();
    return (1000 * s[(p * (s.length - 1)).round()]).toStringAsFixed(0);
  }

  stdout.writeln('| variant | lag ms | RPA% | oct% | gross% | held RPA% '
      '| \\|err\\| p50 | VR% | FA% | first correct p50 / p90 ms '
      '| never correct |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- | --- | --- | --- '
      '| --- | --- |');
  for (final (v, lag) in arms) {
    final s = stats[v.name]!;
    final t = timing[v.name]!;
    final lagMs =
        lag == null ? 'offline' : (1000 * lag * hop / 44100).toStringAsFixed(0);
    final mark = lag == null ? ' †' : '';
    stdout.writeln('| ${v.name} | $lagMs | ${pct(s.rawPitchAccuracy)} '
        '| ${pct(s.octaveRate)} | ${pct(s.grossRate)} '
        '| ${pct(s.steadyAccuracy)} '
        '| ${s.fineSteady.absPercentile(0.5).toStringAsFixed(2)} '
        '| ${pct(s.voicingRecall)} | ${pct(s.voicingFalseAlarm)} '
        '| ${ms(t.firstCorrect, 0.5)} / ${ms(t.firstCorrect, 0.9)}$mark '
        '| ${t.neverCorrect}/${t.notes} |');
  }
  stdout.writeln('\n† needs the whole recording; times are a bound, not a '
      'response.');
  stdout.writeln('');
  stdout.writeln('Where the errors come from (% of silent frames for false '
      'alarms, % of monophonic frames for wrong pitch):');
  stdout.writeln('');
  stdout.writeln('| variant | FA% | tail | onset | other '
      '| wrong% | octave | other string | other |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final (v, _) in arms) {
    final a = attribution[v.name]!;
    String of(int n, int d) => d == 0 ? '—' : pct(n / d);
    stdout.writeln('| ${v.name} | ${of(a.falseAlarms, a.refUnvoiced)} '
        '| ${of(a.faTail, a.refUnvoiced)} | ${of(a.faOnset, a.refUnvoiced)} '
        '| ${of(a.faOther, a.refUnvoiced)} '
        '| ${of(a.wrong, a.monoFrames)} | ${of(a.wrongOctave, a.monoFrames)} '
        '| ${of(a.wrongOtherString, a.monoFrames)} '
        '| ${of(a.wrongOther, a.monoFrames)} |');
  }
  stdout.writeln('');
  stdout.writeln('elapsed ${sw.elapsed.inSeconds}s');

  if (out != null) {
    File(out).writeAsStringSync(jsonEncode({
      'files': pairs.length,
      'subset': subset,
      'hop': hop,
      'stats': jsonDecode(MethodStats.encodeAll(stats)),
      'timing': {for (final e in timing.entries) e.key: e.value.toJson()},
      'attribution': {
        for (final e in attribution.entries) e.key: e.value.toJson()
      },
    }));
  }
}
