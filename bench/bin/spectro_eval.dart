// Score hFT-Transformer and Onsets & Frames on MusicNet's test split.
//
//   python3 tool/spectro_activations.py --model hft --out /mnt/storage/…/acts
//   python3 tool/spectro_activations.py --model oaf --out /mnt/storage/…/acts
//   dart run bin/spectro_eval.dart --acts /mnt/storage/…/acts [--limit N]
//
// The two models §31 exported and never ran. Their head activations are
// cached by the Python tool above — native ORT, which §32.5 showed agrees
// with PyTorch on the transcription itself — and everything that follows is
// this repository's own: the decoders ported from each model's inference
// code (`lib/hft.dart`, `lib/oaf.dart`) and `lib/note_metrics.dart`, which
// §32.3 checked against `mir_eval` itself.
//
// `bin/spectro_timing.dart` runs the same graphs in the pure-Dart runtime and
// `tool/spectro_compare.py` diffs the two, so this split costs nothing in
// trust; it costs only the hours the pure-Dart runtime would take over 24.7
// minutes of audio.
//
// Reported per piece as well as in aggregate, because §29.2 found that an
// aggregate mixing solo piano with string trios describes neither — and
// these are piano models being asked about both.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tuner_bench/hft.dart';
import 'package:tuner_bench/musicnet.dart';
import 'package:tuner_bench/note_metrics.dart';
import 'package:tuner_bench/oaf.dart';

/// One model's head activations for one piece, as written by
/// `tool/spectro_activations.py`.
class Activations {
  final List<String> heads;
  final int frames;
  final int notes;
  final Map<String, List<Float32List>> data;
  Activations(this.heads, this.frames, this.notes, this.data);

  static Activations read(String binPath) {
    final meta = jsonDecode(
        File(binPath.replaceAll('.bin', '.json')).readAsStringSync());
    final heads = (meta['heads'] as List).cast<String>();
    final bytes = File(binPath).readAsBytesSync();
    final bd = ByteData.sublistView(bytes);
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'SPAC') {
      throw StateError('$binPath is not an activation cache');
    }
    final frames = bd.getUint32(8, Endian.little);
    final notes = bd.getUint32(12, Endian.little);
    final nHeads = bd.getUint32(16, Endian.little);
    if (nHeads != heads.length) {
      throw StateError('$binPath: $nHeads heads, sidecar names ${heads.length}');
    }
    final floats = Float32List.sublistView(bytes, 20);
    final data = <String, List<Float32List>>{};
    for (int h = 0; h < nHeads; h++) {
      final rows = <Float32List>[];
      for (int t = 0; t < frames; t++) {
        final off = h * frames * notes + t * notes;
        rows.add(Float32List.sublistView(floats, off, off + notes));
      }
      data[heads[h]] = rows;
    }
    return Activations(heads, frames, notes, data);
  }
}

/// [ignoreZero] is hFT's own `mode_velocity: 'ignore_zero'`, which drops any
/// note whose velocity head reads zero at the onset frame. It turns out to
/// be the thing that decides how many notes hFT emits — see the sweep.
List<Note> _hftNotes(Activations a,
    {double onset = 0.5,
    double offset = 0.5,
    double mpe = 0.5,
    bool ignoreZero = true}) {
  final vel = [
    for (final r in a.data['velocity']!)
      Int32List.fromList(
          [for (final v in r) ignoreZero ? v.round() : 1])
  ];
  return hftNotes(
      HftFrames(a.data['onset']!, a.data['offset']!, a.data['mpe']!, vel),
      thredOnset: onset, thredOffset: offset, thredMpe: mpe);
}

List<Note> _oafNotes(Activations a,
        {double onset = 0.5, double frame = 0.5}) =>
    oafNotes(OafFrames(a.data['onset']!, a.data['frame']!),
        onsetThreshold: onset, frameThreshold: frame);

void main(List<String> argv) {
  var data = '/mnt/storage/tuner-bench/datasets/musicnet';
  var acts = '/mnt/storage/tuner-bench/acts';
  var limit = 0;
  var sweep = false;
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--data':
        data = argv[++i];
      case '--acts':
        acts = argv[++i];
      case '--limit':
        limit = int.parse(argv[++i]);
      case '--sweep':
        sweep = true;
    }
  }

  final pieces = findMusicNetTest(data);
  if (pieces.isEmpty) {
    stderr.writeln('no MusicNet test split under $data');
    exit(2);
  }
  final chosen = pieces.take(limit == 0 ? pieces.length : limit).toList();

  final engines = <String>[];
  for (final m in ['hft', 'oaf']) {
    if (Directory('$acts/$m').existsSync()) {
      engines.add(m);
    } else {
      stdout.writeln('$m: no activation cache under $acts/$m — '
          'run tool/spectro_activations.py --model $m');
    }
  }
  if (engines.isEmpty) exit(2);

  final noOffset = {for (final e in engines) e: NoteScore()};
  final withOffset = {for (final e in engines) e: NoteScore()};
  final perPiece = <String, Map<String, NoteScore>>{
    for (final e in engines) e: {}
  };
  // MIDI program 1 is piano. Both of these are PIANO transcribers, so the
  // aggregate over a corpus that is half strings and winds is the wrong
  // number to compare against a piano result — §29.2's point, and §32.4's
  // when Kong emitted 9 notes for 551 violin references and was right to.
  final pianoOnly = {for (final e in engines) e: NoteScore()};
  final other = {for (final e in engines) e: NoteScore()};

  int refNotes = 0;

  for (final piece in chosen) {
    refNotes += piece.notes.length;



    for (final e in engines) {
      final path = '$acts/$e/${piece.id}.bin';
      if (!File(path).existsSync()) {
        stdout.writeln('${piece.id}: no $e activations, skipped');
        continue;
      }
      final a = Activations.read(path);
      final est = e == 'hft' ? _hftNotes(a) : _oafNotes(a);
      final s = scoreNotes(piece.notes, est);
      noOffset[e]!.merge(s);
      withOffset[e]!
          .merge(scoreNotes(piece.notes, est, withOffset: true));
      perPiece[e]![piece.id] = s;
      final isPiano = piece.instruments.every((i) => i == 1);
      (isPiano ? pianoOnly : other)[e]!.merge(s);
    }
  }

  // An engine whose cache is empty or partial is dropped rather than
  // printed as a row of zeros: a zero that means "not measured" is exactly
  // the shape of number this report has been burned by (§20.2a, §30.1).
  final scoredEngines =
      engines.where((e) => perPiece[e]!.isNotEmpty).toList();
  for (final e in engines) {
    if (!scoredEngines.contains(e)) {
      stdout.writeln('$e: nothing scored — no activations present');
    } else if (perPiece[e]!.length < chosen.length) {
      stdout.writeln('$e: ${perPiece[e]!.length} of ${chosen.length} pieces '
          'have activations — the rows below are that subset, not the split');
    }
  }
  engines
    ..clear()
    ..addAll(scoredEngines);
  if (engines.isEmpty) exit(2);

  stdout.writeln('\n${chosen.length} MusicNet test pieces, '
      '$refNotes reference notes\n');
  stdout.writeln('Onset + pitch (the standard note-level number):\n');
  stdout.writeln('| engine | precision | recall | F1 | onset err p50 | '
      'pitch err p50 |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- |');
  for (final e in engines) {
    final s = noOffset[e]!;
    stdout.writeln('| $e | ${(100 * s.precision).toStringAsFixed(1)}% | '
        '${(100 * s.recall).toStringAsFixed(1)}% | '
        '**${(100 * s.f1).toStringAsFixed(1)}%** | '
        '${NoteScore.medianAbs(s.onsetErrorsMs).toStringAsFixed(1)} ms | '
        '${NoteScore.medianAbs(s.pitchErrorsCents).toStringAsFixed(1)} c |');
  }
  stdout.writeln('\nSplit by what the model was trained on:\n');
  stdout.writeln('| engine | material | precision | recall | F1 |');
  stdout.writeln('| --- | --- | --- | --- | --- |');
  for (final e in engines) {
    for (final row in [('solo piano', pianoOnly[e]!), ('everything else', other[e]!)]) {
      stdout.writeln('| $e | ${row.$1} | '
          '${(100 * row.$2.precision).toStringAsFixed(1)}% | '
          '${(100 * row.$2.recall).toStringAsFixed(1)}% | '
          '**${(100 * row.$2.f1).toStringAsFixed(1)}%** |');
    }
  }

  stdout.writeln('\nOnset + pitch + offset:\n');
  stdout.writeln('| engine | precision | recall | F1 |');
  stdout.writeln('| --- | --- | --- | --- |');
  for (final e in engines) {
    final s = withOffset[e]!;
    stdout.writeln('| $e | ${(100 * s.precision).toStringAsFixed(1)}% | '
        '${(100 * s.recall).toStringAsFixed(1)}% | '
        '${(100 * s.f1).toStringAsFixed(1)}% |');
  }

  // §29.2's request, answered: these are PIANO models, and the split
  // between solo piano and everything else is the result, not the noise.
  stdout.writeln('\nPer piece — a piano model on non-piano material is not '
      'failing, it is declining:\n');
  stdout.write('| piece | instruments | ref notes |');
  for (final e in engines) {
    stdout.write(' $e F1 | $e onset p50 |');
  }
  stdout.writeln('');
  stdout.write('| --- | --- | --- |');
  for (final _ in engines) {
    stdout.write(' --- | --- |');
  }
  stdout.writeln('');
  for (final piece in chosen) {
    stdout.write('| ${piece.id} | '
        '${(piece.instruments.toList()..sort()).join("/")} | '
        '${piece.notes.length} |');
    for (final e in engines) {
      final s = perPiece[e]![piece.id];
      if (s == null) {
        stdout.write(' — | — |');
        continue;
      }
      stdout.write(' ${(100 * s.f1).toStringAsFixed(1)}% | '
          '${NoteScore.medianAbs(s.onsetErrorsMs).toStringAsFixed(1)} ms |');
    }
    stdout.writeln('');
  }

  if (!sweep) return;
  // §29.3 swept Basic Pitch's decoder and found the shipped defaults already
  // at the F1 optimum. The same question, asked of these two.
  stdout.writeln('\nThreshold sweep:\n');
  stdout.writeln('| engine | onset | frame/mpe | precision | recall | F1 |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- |');
  for (final e in engines) {
    for (final t in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7]) {
      final s = NoteScore();
      for (final piece in chosen) {
        final path = '$acts/$e/${piece.id}.bin';
        if (!File(path).existsSync()) continue;
        final a = Activations.read(path);
        final est = e == 'hft'
            ? _hftNotes(a, onset: t, mpe: t)
            : _oafNotes(a, onset: t, frame: t);
        s.merge(scoreNotes(piece.notes, est));
      }
      stdout.writeln('| $e | $t | $t | '
          '${(100 * s.precision).toStringAsFixed(1)}% | '
          '${(100 * s.recall).toStringAsFixed(1)}% | '
          '${(100 * s.f1).toStringAsFixed(1)}% |');
    }
  }

  if (!engines.contains('hft')) return;
  // hFT's onset threshold turns out to be inert: the velocity head zeroes
  // the weak candidates independently, so `ignore_zero` removes exactly the
  // notes a lower threshold would have added. Without it the threshold bites
  // again — which is the only way to see that the lever exists at all.
  stdout.writeln('\nhFT without `mode_velocity: ignore_zero` — the gate that '
      'makes the row above flat:\n');
  stdout.writeln('| onset/mpe | precision | recall | F1 |');
  stdout.writeln('| --- | --- | --- | --- |');
  for (final t in [0.2, 0.3, 0.5, 0.7]) {
    final s = NoteScore();
    for (final piece in chosen) {
      final path = '$acts/hft/${piece.id}.bin';
      if (!File(path).existsSync()) continue;
      final a = Activations.read(path);
      s.merge(scoreNotes(piece.notes,
          _hftNotes(a, onset: t, mpe: t, ignoreZero: false)));
    }
    stdout.writeln('| $t | ${(100 * s.precision).toStringAsFixed(1)}% | '
        '${(100 * s.recall).toStringAsFixed(1)}% | '
        '${(100 * s.f1).toStringAsFixed(1)}% |');
  }
}
