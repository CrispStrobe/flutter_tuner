// How well do the transcribers actually transcribe?
//
//   dart run bin/transcribe_eval.dart [--data <musicnet root>] [--limit N]
//                                     [--engines onnx,bp,piano,mt3]
//
// Every other table in this report is FRAME-level: is this 11.6 ms slice's
// pitch right. That is not the same question as "can it turn a recording
// into notes" — a system can be excellent frame by frame and still split one
// note into nine. §12 and §18 have that limitation; this closes it.
//
// MusicNet's standard test split: ten real classical recordings, 13,589
// annotated notes, solo piano through string and wind trios. Scored by
// mir_eval.transcription's rules (lib/note_metrics.dart): onset within
// 50 ms and pitch within 50 cents, one-to-one, with the offset condition
// reported separately because offsets are far less reliable than onsets in
// both annotations and models.
//
// Four transcribers, which is every one this project can reach:
//   onnx   Basic Pitch through onnx_runtime_dart — what the app ships
//   bp     Basic Pitch through CrispASR's ggml (the same model, §17)
//   piano  Kong's piano-transcription through CrispASR (77 MB)
//   mt3    MT3 through CrispASR (96 MB, 46.9M parameters)

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/app/transcription.dart';
import 'package:tuner_bench/musicnet.dart';
import 'package:tuner_bench/note_metrics.dart';
import 'package:tuner_bench/wav.dart';

const _noteHead = 'StatefulPartitionedCall:1';
const _onsetHead = 'StatefulPartitionedCall:2';

String _libPath() {
  final ov = Platform.environment['CRISPTUNER_CRISPASR_LIB'];
  if (ov != null && ov.isNotEmpty) return ov;
  final home = Platform.environment['HOME'];
  if (home != null) {
    final drop = '$home/.cache/crispasr/libcrispasr.so';
    if (File(drop).existsSync()) return drop;
  }
  return CrispASR.defaultLibName();
}

Float64List _resample(Float64List input, double from, double to) {
  if ((from - to).abs() < 1) return input;
  final ratio = from / to;
  final out = Float64List((input.length / ratio).floor());
  for (int i = 0; i < out.length; i++) {
    final x = i * ratio;
    final j = x.floor();
    final t = x - j;
    final a = input[j];
    final b = j + 1 < input.length ? input[j + 1] : a;
    out[i] = a + (b - a) * t;
  }
  return out;
}

/// Turn the pure-Dart frame decode into note events.
///
/// The app's decoder answers "what is sounding now" and never had to say
/// where a note began or ended — that is exactly the capability a
/// frame-level metric cannot see the absence of. A run of consecutive frames
/// in which a pitch is sounding IS a note; this is the simplest segmenter
/// that turns one into the other, and it is deliberately simple so the
/// number below is attributable to the model rather than to a clever
/// post-process.
List<Note> _notesFromFrames(List<Set<int>> frames, double frameMs,
    {double minMs = 0}) {
  final open = <int, int>{}; // midi -> first frame index
  final out = <Note>[];
  for (int f = 0; f < frames.length; f++) {
    final now = frames[f];
    for (final midi in now) {
      open.putIfAbsent(midi, () => f);
    }
    for (final midi in open.keys.toList()) {
      if (now.contains(midi)) continue;
      final start = open.remove(midi)!;
      final onMs = start * frameMs;
      final offMs = f * frameMs;
      if (offMs - onMs >= minMs) {
        out.add((onsetMs: onMs, offsetMs: offMs, midi: midi.toDouble()));
      }
    }
  }
  open.forEach((midi, start) {
    out.add((
      onsetMs: start * frameMs,
      offsetMs: frames.length * frameMs,
      midi: midi.toDouble()
    ));
  });
  out.sort((a, b) => a.onsetMs.compareTo(b.onsetMs));
  return out;
}

List<Note> _runOnnx(OnnxModel model, Float64List audio44k) {
  final audio = _resample(
      audio44k, 44100, BasicPitchGeometry.sampleRate.toDouble());
  const decoder = BasicPitchDecoder();
  final frames = <Set<int>>[];
  Set<int> carry = <int>{};
  for (int start = 0;
      start + BasicPitchGeometry.windowSamples <= audio.length;
      start += BasicPitchGeometry.windowSamples) {
    final input = Float32List(BasicPitchGeometry.windowSamples);
    for (int i = 0; i < input.length; i++) {
      input[i] = audio[start + i];
    }
    final out = model.run(
      {'serving_default_input_2:0': Tensor.float(input, [1, input.length, 1])},
      const [_noteHead, _onsetHead],
    );
    final note = Float64List.fromList(out[_noteHead]!.asFloatList());
    final onset = Float64List.fromList(out[_onsetHead]!.asFloatList());
    frames.addAll(decoder.decodeFrames(note, carry: carry, onset: onset));
    carry = frames.last;
  }
  const frameMs =
      1000 * BasicPitchGeometry.frameHop / BasicPitchGeometry.sampleRate;
  return _notesFromFrames(frames, frameMs);
}

List<Note> _runCrispasr(CrispasrSession s, Float64List audio44k, int rate) {
  final audio = _resample(audio44k, 44100, rate.toDouble());
  final pcm = Float32List(audio.length);
  for (int i = 0; i < pcm.length; i++) {
    pcm[i] = audio[i];
  }
  return [
    for (final n in s.pianoNotes(pcm))
      (onsetMs: n.onMs, offsetMs: n.offMs, midi: n.midi.toDouble())
  ];
}

void main(List<String> argv) async {
  var data = '/mnt/storage/tuner-bench/datasets/musicnet';
  var onnxPath = '../assets/models/basic_pitch.onnx';
  var limit = 0;
  var want = 'onnx,bp,piano,mt3';
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--data':
        data = argv[++i];
      case '--onnx':
        onnxPath = argv[++i];
      case '--limit':
        limit = int.parse(argv[++i]);
      case '--engines':
        want = argv[++i];
    }
  }
  final wanted = want.split(',').map((s) => s.trim()).toSet();

  final pieces = findMusicNetTest(data);
  if (pieces.isEmpty) {
    stderr.writeln('no MusicNet test split under $data');
    exit(2);
  }
  final chosen = pieces.take(limit == 0 ? pieces.length : limit).toList();

  // Open what is available; a missing model is a skipped row, never a crash.
  OnnxModel? onnx;
  if (wanted.contains('onnx')) onnx = loadOnnxModel(onnxPath);

  final sessions = <String, CrispasrSession>{};
  final rates = <String, int>{};
  const backends = {'bp': 'basic-pitch', 'piano': 'piano-transcription',
    'mt3': 'mt3'};
  for (final e in backends.entries) {
    if (!wanted.contains(e.key)) continue;
    try {
      final lib = DynamicLibrary.open(_libPath());
      final entry = registryLookup(e.value, lib: lib);
      if (entry == null) {
        stdout.writeln('${e.key}: not registered in this libcrispasr');
        continue;
      }
      final dir = cacheDir(lib: lib);
      var model = dir == null ? null : '$dir/${entry.filename}';
      if (model == null || !File(model).existsSync()) {
        stdout.writeln('${e.key}: fetching ${entry.filename} '
            '(${entry.approxSize}) …');
        model = cacheEnsureFile(entry.filename, entry.url, quiet: true,
            lib: lib);
      }
      if (model == null) {
        stdout.writeln('${e.key}: model unavailable');
        continue;
      }
      final s = CrispasrSession.open(model,
          libPath: _libPath(), backend: e.value, nThreads: 2);
      sessions[e.key] = s;
      rates[e.key] = s.pianoSampleRate > 0
          ? s.pianoSampleRate
          : BasicPitchGeometry.sampleRate;
      stdout.writeln('${e.key}: ready (${rates[e.key]} Hz)');
    } catch (err) {
      stdout.writeln('${e.key}: unavailable — $err');
    }
  }

  final engines = <String>[
    if (onnx != null) 'onnx',
    ...sessions.keys,
  ];
  final noOffset = {for (final e in engines) e: NoteScore()};
  final withOffset = {for (final e in engines) e: NoteScore()};
  final seconds = {for (final e in engines) e: 0.0};
  double audioSeconds = 0;

  for (final piece in chosen) {
    final wav = readWav(piece.audioPath);
    audioSeconds += wav.samples.length / wav.sampleRate;
    stdout.write('\n${piece.id} (${piece.notes.length} notes, '
        'instruments ${(piece.instruments.toList()..sort()).join("/")}) ');
    for (final e in engines) {
      final sw = Stopwatch()..start();
      List<Note> est;
      try {
        est = e == 'onnx'
            ? _runOnnx(onnx!, wav.samples)
            : _runCrispasr(sessions[e]!, wav.samples, rates[e]!);
      } catch (err) {
        stdout.write('[$e failed] ');
        continue;
      }
      sw.stop();
      seconds[e] = seconds[e]! + sw.elapsedMicroseconds / 1e6;
      noOffset[e]!.merge(scoreNotes(piece.notes, est));
      withOffset[e]!.merge(scoreNotes(piece.notes, est, withOffset: true));
      stdout.write('$e:${est.length} ');
    }
  }

  stdout.writeln('\n\n${chosen.length} MusicNet test pieces, '
      '${(audioSeconds / 60).toStringAsFixed(1)} min of audio, '
      '${chosen.fold<int>(0, (a, p) => a + p.notes.length)} reference notes\n');
  stdout.writeln('Onset + pitch (the standard note-level number):\n');
  stdout.writeln('| engine | precision | recall | F1 | onset err p50 | '
      'pitch err p50 | xRT |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- | --- |');
  for (final e in engines) {
    final s = noOffset[e]!;
    stdout.writeln('| $e | ${(100 * s.precision).toStringAsFixed(1)}% | '
        '${(100 * s.recall).toStringAsFixed(1)}% | '
        '**${(100 * s.f1).toStringAsFixed(1)}%** | '
        '${NoteScore.medianAbs(s.onsetErrorsMs).toStringAsFixed(1)} ms | '
        '${NoteScore.medianAbs(s.pitchErrorsCents).toStringAsFixed(1)} c | '
        '${(seconds[e]! / audioSeconds).toStringAsFixed(2)} |');
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
  for (final s in sessions.values) {
    s.close();
  }
}
