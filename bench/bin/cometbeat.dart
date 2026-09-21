// CometBeat's pitch engines, against this report's corpora and rules.
//
//   dart run bin/cometbeat.dart --corpus guitar --data <dir> [--limit N]
//   dart run bin/cometbeat.dart --corpus cello  --data <dir> [--limit N]
//
// §25 compared the two projects' CrispASR *integration*. This compares their
// detectors. CometBeat ships engines this app does not — WORLD DIO (a
// model-free F0 estimator built for speech) and its own pYIN — and its whole
// transcription tree is Flutter-free, so they can be run here directly
// (tool/sync_cometbeat.sh copies them; CI checks the copies are current).
//
// Only the model-free engines are included. CREPE, RMVPE and FCPE would each
// need their GGUF or ONNX resolved and would measure a model rather than
// CometBeat, and §13 already has numbers for crepe.
//
// Same rules as every other table here: the frame is scored at the instant
// the estimator's answer describes, correct within 50 cents, octave errors
// separated from gross ones.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tuner_bench/cello.dart';
import 'package:tuner_bench/cometbeat/contracts.dart';
import 'package:tuner_bench/cometbeat/dio.dart';
import 'package:tuner_bench/cometbeat/note_hmm.dart';
import 'package:tuner_bench/cometbeat/pyin.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/wav.dart';

typedef Engine = ({String name, PitchTrack Function(Float64List, int) run});

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

final _engines = <Engine>[
  (
    name: 'cb-dio',
    run: (mono, sr) => dioF0(mono, sr),
  ),
  (
    name: 'cb-dio-norefine',
    run: (mono, sr) => dioF0(mono, sr, refine: false),
  ),
  (
    name: 'cb-pyin',
    run: (mono, sr) => pyinF0(mono, sampleRate: sr),
  ),
  (
    name: 'cb-pyin+hmm',
    run: (mono, sr) =>
        _applyHmm(pyinF0(mono, sampleRate: sr), keepOriginalHz: false),
  ),
  (
    name: 'cb-pyin+hmm-mask',
    run: (mono, sr) =>
        _applyHmm(pyinF0(mono, sampleRate: sr), keepOriginalHz: true),
  ),
];

/// Nearest frame of a track to [t] seconds, or null when the track has
/// nothing within half a hop — the engines pick their own frame rates, so
/// the comparison has to meet each one where it lands rather than assume a
/// shared grid.
double? _at(PitchTrack track, double t, double toleranceMs) {
  if (track.isEmpty) return null;
  final ms = t * 1000;
  double best = double.infinity;
  double? f0;
  for (final f in track) {
    final d = (f.timeMs - ms).abs();
    if (d < best) {
      best = d;
      f0 = f.voicedProb >= 0.5 ? f.f0Hz : 0;
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
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--corpus':
        corpus = argv[++i];
      case '--data':
        data = argv[++i];
      case '--limit':
        limit = int.parse(argv[++i]);
    }
  }

  final stats = {for (final e in _engines) e.name: MethodStats(e.name)};
  final timings = {for (final e in _engines) e.name: <double>[]};

  if (corpus == 'guitar') {
    final files = Directory('$data/audio')
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.contains('_solo') && p.endsWith('_mic.wav'))
        .toList()
      ..sort();
    final chosen = files.take(limit == 0 ? files.length : limit).toList();
    for (final path in chosen) {
      final jamsPath = '$data/annotation/'
          '${path.split("/").last.replaceAll("_mic.wav", "")}.jams';
      if (!File(jamsPath).existsSync()) continue;
      final truth = readJams(jamsPath);
      final wav = readWav(path);
      final rate = wav.sampleRate;
      for (final e in _engines) {
        final sw = Stopwatch()..start();
        final track = e.run(wav.samples, rate);
        sw.stop();
        timings[e.name]!.add(sw.elapsedMicroseconds / 1000);
        // Walk the reference grid, not the engine's: every table in this
        // report scores the same reference frames.
        for (double t = 0; t < truth.duration; t += truth.hop) {
          final active = truth.activeAt(t, truth.hop);
          final got = _at(track, t, 25) ?? 0;
          // Voicing over EVERY frame, mono accuracy over the monophonic
          // ones — the same split lib/evaluate.dart uses, so VR and FA mean
          // here what they mean in §13 rather than coming out as zero.
          final st = stats[e.name]!;
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
      stdout.write('.');
    }
    stdout.writeln('\n\n${chosen.length} solo files, GuitarSet\n');
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
    for (final take in chosen) {
      final wav = readWav(take.path);
      final rate = wav.sampleRate;
      for (final e in _engines) {
        final sw = Stopwatch()..start();
        final track = e.run(wav.samples, rate);
        sw.stop();
        timings[e.name]!.add(sw.elapsedMicroseconds / 1000);
        // MUSERC is one sustained note per take, so the nominal is the
        // reference for every frame the engine produces.
        final st = stats[e.name]!;
        for (final f in track) {
          final got = f.voicedProb >= 0.5 ? f.f0Hz : 0.0;
          // A MUSERC take is one sustained note throughout, so every frame
          // is a voiced reference frame — there is no unvoiced span to
          // build a false-alarm rate from, and the column is left empty
          // rather than filled with a meaningless zero.
          st.refVoiced++;
          if (got > 0) st.refVoicedReported++;
          st.scoreMono(got > 0 ? got : null, take.nominal,
              steady: take.steady);
        }
      }
      stdout.write('.');
    }
    stdout.writeln('\n\n${chosen.length} cello takes, MUSERC '
        '(tune takes excluded — §11.1)\n');
  }

  stdout.writeln('| engine | RPA% | rep% | oct% | gross% | |err| p50 | VR% | FA% |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final e in _engines) {
    _row(e.name, stats[e.name]!);
  }
  stdout.writeln('');
  for (final e in _engines) {
    final t = timings[e.name]!;
    if (t.isEmpty) continue;
    final s = List<double>.of(t)..sort();
    stdout.writeln('${e.name}: ${s[s.length ~/ 2].toStringAsFixed(0)} ms '
        'per file (median of ${s.length})');
  }
}
