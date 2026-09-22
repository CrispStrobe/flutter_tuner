// CometBeat's pitch engines, against this report's corpora and rules.
//
//   dart run bin/cometbeat.dart --corpus guitar --data <dir> [--limit N]
//                                [--models <dir>] [--engines a,b]
//   dart run bin/cometbeat.dart --corpus cello  --data <dir> [--limit N]
//
// §25 compared the two projects' CrispASR *integration*. This compares their
// detectors. CometBeat ships engines this app does not — WORLD DIO (a
// model-free F0 estimator built for speech) and its own pYIN — and its whole
// transcription tree is Flutter-free, so they can be run here directly
// (tool/sync_cometbeat.sh copies them; CI checks the copies are current).
//
// The model-free engines run unconditionally. RMVPE and FCPE — CometBeat's
// two neural F0 estimators — need an ONNX on disk, so they join the table
// only when `--models <dir>` holds them and are SKIPPED WITH A PRINTED
// REASON otherwise, never silently dropped. They are scored through exactly
// the same code path as `cb-pyin`, on the same reference frames, so the rows
// are comparable line for line.
//
// Same rules as every other table here: the frame is scored at the instant
// the estimator's answer describes, correct within 50 cents, octave errors
// separated from gross ones.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/cello.dart';
import 'package:tuner_bench/cometbeat/contracts.dart';
import 'package:tuner_bench/cometbeat/dio.dart';
import 'package:tuner_bench/cometbeat/fcpe.dart';
import 'package:tuner_bench/cometbeat/fcpe_mel.dart';
import 'package:tuner_bench/cometbeat/note_hmm.dart';
import 'package:tuner_bench/cometbeat/pyin.dart';
import 'package:tuner_bench/cometbeat/rmvpe.dart';
import 'package:tuner_bench/cometbeat/rmvpe_mel.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/wav.dart';

/// The engines, and how one file's audio becomes one track per engine.
///
/// Deliberately NOT a list of independent `(mono, sr) -> track` closures,
/// which is how this was first written: the three pYIN arms differ only in
/// what happens *after* the estimator, so independent closures ran `pyinF0`
/// three times per file. On a 20-second guitar recording that is 54 seconds
/// of work to produce 18 seconds' worth of answer, and it is why the first
/// full run timed out after three files.
const modelFreeEngines = <String>[
  'cb-dio',
  'cb-dio-norefine',
  'cb-pyin',
  'cb-pyin+hmm',
  'cb-pyin+hmm-mask',
];

/// The engines this run scores: the model-free set, plus whichever neural
/// models [loadNeural] actually found, minus anything `--engines` excluded.
final engineNames = <String>[...modelFreeEngines];

/// `--engines a,b` restricts the run. The default (empty) is everything.
///
/// It exists because the neural arms cost two orders of magnitude more than
/// the model-free ones: without it, measuring RMVPE's throughput means also
/// paying for pYIN and DIO on every file, and the timing column then reports
/// a number dominated by contention between them rather than the model.
final engineFilter = <String>{};

bool _wanted(String name) => engineFilter.isEmpty || engineFilter.contains(name);

/// A loaded neural estimator: the ONNX plus its mel asset, resolved ONCE for
/// the whole run — 361 MB and 25 seconds of parse for RMVPE is not a cost any
/// per-file loop should pay, and the timing column would then be reporting it
/// rather than the model's inference.
class _Neural {
  _Neural.rmvpe(this.model, RmvpeMel mel) : rmvpeMel = mel, fcpeAssets = null;
  _Neural.fcpe(this.model, FcpeAssets a) : fcpeAssets = a, rmvpeMel = null;
  final OnnxModel model;
  final RmvpeMel? rmvpeMel;
  final FcpeAssets? fcpeAssets;
}

_Neural? _rmvpe;
_Neural? _fcpe;

/// Resolve both ONNX bundles from [dir]. A missing model is reported and its
/// engine left out of the table — never a crash, and never a silent omission
/// that would let a short table pass for a complete one.
void loadNeural(String dir) {
  for (final spec in const [
    ('cb-rmvpe', 'rmvpe.onnx', 'rmvpe_mel.bin'),
    ('cb-fcpe', 'fcpe.onnx', 'fcpe_mel.bin'),
  ]) {
    final (name, onnx, asset) = spec;
    if (!_wanted(name)) continue; // `--engines` excluded it; don't pay 361 MB.
    final m = File('$dir/$onnx'), a = File('$dir/$asset');
    if (!m.existsSync() || !a.existsSync()) {
      final missing = [
        if (!m.existsSync()) m.path,
        if (!a.existsSync()) a.path,
      ].join(', ');
      stdout.writeln('skipping $name: missing $missing');
      continue;
    }
    final sw = Stopwatch()..start();
    final model = loadOnnxModel(m.path);
    if (name == 'cb-rmvpe') {
      _rmvpe = _Neural.rmvpe(model, RmvpeMel.fromBytes(a.readAsBytesSync()));
    } else {
      _fcpe = _Neural.fcpe(model, FcpeAssets.fromBytes(a.readAsBytesSync()));
    }
    sw.stop();
    engineNames.add(name);
    stdout.writeln('loaded $name from ${m.path} '
        '(${(m.lengthSync() / 1e6).toStringAsFixed(0)} MB, '
        '${sw.elapsedMilliseconds} ms)');
  }
}

/// How a frame's voiced/unvoiced decision is read, per engine.
///
/// pYIN and DIO emit a genuine voicing PROBABILITY, so 0.5 means something and
/// every other table in this report uses it. RMVPE and FCPE do not: their
/// `voicedProb` is the RAW peak salience of the 360-bin lattice, and the
/// voicing decision has already been taken inside the estimator against its
/// own documented threshold (RMVPE 0.03, FCPE 0.006) — an unvoiced frame comes
/// back with `f0Hz == 0`. Re-gating those at 0.5 would impose a second
/// threshold the model never had and would zero out most of FCPE, whose peak
/// latents live near 1e-2. So each engine is asked in the terms it answers in.
bool _isVoiced(String engine, PitchFrame f) =>
    engine == 'cb-rmvpe' || engine == 'cb-fcpe'
        ? f.f0Hz > 0
        : f.voicedProb >= 0.5;

Map<String, PitchTrack> runAllEngines(Float64List mono, int sr,
    Map<String, double> millis) {
  final out = <String, PitchTrack>{};
  void timed(String name, PitchTrack Function() f) {
    if (!_wanted(name)) return;
    final sw = Stopwatch()..start();
    out[name] = f();
    sw.stop();
    millis[name] = (millis[name] ?? 0) + sw.elapsedMicroseconds / 1000;
  }

  timed('cb-dio', () => dioF0(mono, sr));
  timed('cb-dio-norefine', () => dioF0(mono, sr, refine: false));
  timed('cb-pyin', () => pyinF0(mono, sampleRate: sr));
  // The two HMM arms reuse the track above; their cost is the HMM, which is
  // what the timing column should say.
  // The HMM arms are a post-process on the pYIN track, so `--engines` may ask
  // for one without asking for pYIN itself — in which case the estimator still
  // has to run, and its cost belongs to pYIN's row, not to the HMM's.
  final raw = out['cb-pyin'] ??
      (_wanted('cb-pyin+hmm') || _wanted('cb-pyin+hmm-mask')
          ? pyinF0(mono, sampleRate: sr)
          : const <PitchFrame>[]);
  timed('cb-pyin+hmm', () => _applyHmm(raw, keepOriginalHz: false));
  timed('cb-pyin+hmm-mask', () => _applyHmm(raw, keepOriginalHz: true));
  // Neural arms, at each model's own default threshold and per-frame argmax
  // decode (no Viterbi) — the shipped default, so the row describes what
  // CometBeat would actually hand a caller.
  final r = _rmvpe;
  if (r != null) {
    timed('cb-rmvpe',
        () => rmvpeF0(mono, model: r.model, mel: r.rmvpeMel!, sampleRate: sr));
  }
  final f = _fcpe;
  if (f != null) {
    timed('cb-fcpe',
        () => fcpeF0(mono, model: f.model, assets: f.fcpeAssets!,
            sampleRate: sr));
  }
  return out;
}

/// CometBeat's shipped monophonic pipeline is not the estimator alone:
/// `route.dart` runs `segmentNotes` — an HMM over the pitch lattice — after
/// it. Scoring the raw estimator measures a component, not the product, and
/// the false-alarm column is where that shows: unvoiced frames the HMM would
/// discard are counted against the estimator.
///
/// Two ways of putting the HMM back, because they answer different
/// questions:
///
///  * **`+hmm`** is the shipped pipeline, and its notes carry an `int midi`
///    — semitone-quantised. That is right for a transcriber and disqualifying
///    for a tuner, and the cent column below says so numerically.
///  * **`+hmm-mask`** uses the HMM only for the voiced/unvoiced decision and
///    keeps the estimator's own frequency inside a note. That is the shape a
///    tuner would want: pYIN's weakness against this app is voicing (§24.1),
///    not pitch, and this separates the two.
PitchTrack _applyHmm(PitchTrack track, {required bool keepOriginalHz}) {
  final notes = segmentNotes(track);
  if (notes.isEmpty) {
    return [for (final f in track) (timeMs: f.timeMs, f0Hz: 0.0, voicedProb: 0.0)];
  }
  final out = <PitchFrame>[];
  int n = 0;
  for (final f in track) {
    while (n < notes.length && notes[n].offMs < f.timeMs) {
      n++;
    }
    final covered =
        n < notes.length && f.timeMs >= notes[n].onMs && f.timeMs <= notes[n].offMs;
    if (!covered) {
      out.add((timeMs: f.timeMs, f0Hz: 0.0, voicedProb: 0.0));
      continue;
    }
    final hz = keepOriginalHz && f.f0Hz > 0
        ? f.f0Hz
        : 440 * math.pow(2, (notes[n].midi - 69) / 12).toDouble();
    out.add((timeMs: f.timeMs, f0Hz: hz, voicedProb: 1.0));
  }
  return out;
}



/// Nearest frame of a track to [t] seconds, or null when the track has
/// nothing within half a hop — the engines pick their own frame rates, so
/// the comparison has to meet each one where it lands rather than assume a
/// shared grid.
double? _at(String engine, PitchTrack track, double t, double toleranceMs) {
  if (track.isEmpty) return null;
  final ms = t * 1000;
  double best = double.infinity;
  double? f0;
  for (final f in track) {
    final d = (f.timeMs - ms).abs();
    if (d < best) {
      best = d;
      f0 = _isVoiced(engine, f) ? f.f0Hz : 0;
    }
  }
  if (best > toleranceMs) return null;
  return f0;
}

void _row(String name, MethodStats s, {String? extra}) {
  stdout.writeln('| $name | '
      '${(100 * s.rawPitchAccuracy).toStringAsFixed(2)} | '
      '${(100 * s.accuracyWhenReporting).toStringAsFixed(2)} | '
      '${(100 * s.octaveRate).toStringAsFixed(2)} | '
      '${(100 * s.grossRate).toStringAsFixed(2)} | '
      '${s.fine.absPercentile(0.5).toStringAsFixed(2)} | '
      '${(100 * s.voicingRecall).toStringAsFixed(2)} | '
      '${(100 * s.voicingFalseAlarm).toStringAsFixed(2)} |${extra ?? ""}');
}

void main(List<String> argv) {
  var corpus = 'guitar';
  var data = '/mnt/storage/tuner-bench/datasets';
  var limit = 0;
  var subset = 0;
  var models = '/mnt/storage/tuner-bench/onnx/cometbeat';
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--corpus':
        corpus = argv[++i];
      case '--data':
        data = argv[++i];
      case '--models':
        models = argv[++i];
      case '--engines':
        engineFilter.addAll(argv[++i].split(','));
      case '--limit':
        limit = int.parse(argv[++i]);
      // A second table over the first N files of the same run. §35.6 had to
      // report the neural arms on a 40-file prefix and could not say whether
      // the prefix was representative, because the full-corpus rows came
      // from a DIFFERENT run. Accumulating both from one pass answers that
      // for free: the subset table and the full table see identical audio,
      // identical models and identical code.
      case '--subset':
        subset = int.parse(argv[++i]);
    }
  }

  loadNeural(models);
  engineNames.removeWhere((e) => !_wanted(e));

  final stats = {for (final e in engineNames) e: MethodStats(e)};
  final subsetStats = {for (final e in engineNames) e: MethodStats(e)};
  final millis = <String, double>{};
  var scored = 0;
  final wall = Stopwatch()..start();

  /// Which tables this file's frames count towards: always the full one,
  /// and the prefix one while we are still inside `--subset`.
  List<Map<String, MethodStats>> targets(int index) =>
      subset > 0 && index < subset ? [stats, subsetStats] : [stats];

  if (corpus == 'guitar') {
    final files = Directory('$data/audio')
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.contains('_solo') && p.endsWith('_mic.wav'))
        .toList()
      ..sort();
    final chosen = files.take(limit == 0 ? files.length : limit).toList();
    for (int index = 0; index < chosen.length; index++) {
      final path = chosen[index];
      final jamsPath = '$data/annotation/'
          '${path.split("/").last.replaceAll("_mic.wav", "")}.jams';
      if (!File(jamsPath).existsSync()) continue;
      final truth = readJams(jamsPath);
      final wav = readWav(path);
      final rate = wav.sampleRate;
      final secs = wav.samples.length / rate;
      final tracks = runAllEngines(wav.samples, rate, millis);
      scored++;
      for (final name in engineNames) {
        final track = tracks[name]!;
        // Walk the reference grid, not the engine's: every table in this
        // report scores the same reference frames.
        for (double t = 0; t < truth.duration; t += truth.hop) {
          final active = truth.activeAt(t, truth.hop);
          final got = _at(name, track, t, 25) ?? 0;
          // Voicing over EVERY frame, mono accuracy over the monophonic
          // ones — the same split lib/evaluate.dart uses, so VR and FA mean
          // here what they mean in §13 rather than coming out as zero.
          for (final table in targets(index)) {
            final st = table[name]!;
            if (active.isEmpty) {
              st.refUnvoiced++;
              if (got > 0) st.refUnvoicedReported++;
            } else {
              st.refVoiced++;
              if (got > 0) st.refVoicedReported++;
            }
            if (active.length == 1) {
              st.scoreMono(got > 0 ? got : null, active.first.frequency);
            }
          }
        }
      }
      // One line per file, not a dot. §35.6's runs were killed by the OOM
      // killer partway through and the only record of how far they had got
      // was a row of dots; the peak RSS is printed because for RMVPE it is
      // the finding, not the diagnostics. `ProcessInfo.maxRss` is a
      // high-water mark for the whole process, so it only ever rises — it
      // says what the longest file so far cost, not what this one did.
      stdout.writeln('[${index + 1}/${chosen.length}] '
          '${path.split("/").last} ${secs.toStringAsFixed(1)} s  '
          'elapsed ${(wall.elapsedMilliseconds / 1000).toStringAsFixed(0)} s  '
          'maxRss ${(ProcessInfo.maxRss / 1e9).toStringAsFixed(2)} GB');
    }
    stdout.writeln('\n${chosen.length} solo files, GuitarSet\n');
  } else {
    // The audio sits at <data>/muserc/MUSERC/SA — the same path bin/cello.dart
    // uses. Accept either the corpus root or that directory directly, so the
    // two tools can be pointed at the same --data.
    final celloDir = Directory('$data/muserc/MUSERC/SA').existsSync()
        ? '$data/muserc/MUSERC/SA'
        : data;
    final takes = findTakes(celloDir)
        .where((t) => t.hasReliableNominal)
        .toList();
    final chosen = takes.take(limit == 0 ? takes.length : limit).toList();
    for (int index = 0; index < chosen.length; index++) {
      final take = chosen[index];
      final wav = readWav(take.path);
      final rate = wav.sampleRate;
      final secs = wav.samples.length / rate;
      final tracks = runAllEngines(wav.samples, rate, millis);
      scored++;
      for (final name in engineNames) {
        // MUSERC is one sustained note per take, so the nominal is the
        // reference for every frame the engine produces.
        final track = tracks[name]!;
        for (final f in track) {
          final got = _isVoiced(name, f) ? f.f0Hz : 0.0;
          // A MUSERC take is one sustained note throughout, so every frame
          // is a voiced reference frame — there is no unvoiced span to
          // build a false-alarm rate from, and the column is left empty
          // rather than filled with a meaningless zero.
          for (final table in targets(index)) {
            final st = table[name]!;
            st.refVoiced++;
            if (got > 0) st.refVoicedReported++;
            st.scoreMono(got > 0 ? got : null, take.nominal,
                steady: take.steady);
          }
        }
      }
      stdout.writeln('[${index + 1}/${chosen.length}] '
          '${take.path.split("/").last} ${secs.toStringAsFixed(1)} s  '
          'elapsed ${(wall.elapsedMilliseconds / 1000).toStringAsFixed(0)} s  '
          'maxRss ${(ProcessInfo.maxRss / 1e9).toStringAsFixed(2)} GB');
    }
    stdout.writeln('\n${chosen.length} cello takes, MUSERC '
        '(tune takes excluded — §11.1)\n');
  }

  stdout.writeln('| engine | RPA% | rep% | oct% | gross% | |err| p50 | VR% | FA% |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final name in engineNames) {
    _row(name, stats[name]!);
  }
  if (subset > 0 && subset < scored) {
    stdout.writeln('\nThe same run, restricted to the first $subset files — '
        'the prefix §35.6 had to report, from identical audio and identical '
        'models, so the two tables ARE comparable line for line:\n');
    stdout.writeln(
        '| engine | RPA% | rep% | oct% | gross% | |err| p50 | VR% | FA% |');
    stdout.writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
    for (final name in engineNames) {
      _row(name, subsetStats[name]!);
    }
  }

  stdout.writeln('');
  stdout.writeln('peak RSS for the whole run: '
      '${(ProcessInfo.maxRss / 1e9).toStringAsFixed(2)} GB');
  for (final name in engineNames) {
    final total = millis[name];
    if (total == null || scored == 0) continue;
    stdout.writeln('$name: ${(total / scored).toStringAsFixed(0)} ms '
        'per file (mean over $scored)');
  }
}
