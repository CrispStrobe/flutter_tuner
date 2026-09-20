// Does a sustain threshold buy back what §17 found the ggml decoder winning?
//
//   dart run bin/hysteresis.dart --data <corpus> [--limit N] [--onnx …]
//
// §17 measured the same Basic Pitch model through two runtimes and found
// CrispASR recalling 8.4 points more notes for 3.8 points less precision.
// The cause was not ggml: it was that CrispASR returns segmented note
// *events*, which span the frames where an activation dips, while this
// repository thresholded every frame independently.
//
// If that reading is right, a sustain threshold on the pure-Dart path should
// recover most of the recall without any of the packaging cost — and if it is
// wrong, this prints that instead. Same 11.6 ms grid, same note_midi truth,
// same rules as §12 and §17.

import 'dart:io';
import 'dart:typed_data';

import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/app/transcription.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/wav.dart';

const _noteHead = 'StatefulPartitionedCall:1';
const _scoreHop =
    BasicPitchGeometry.frameHop / BasicPitchGeometry.sampleRate;

/// (start, sustain) pairs. The first is the shipped behaviour — sustain equal
/// to start is no hysteresis at all — so every other row is a delta against
/// a number this report already published.
const _settings = <(double, double)>[
  (0.4, 0.4),
  (0.4, 0.3),
  (0.4, 0.25),
  (0.4, 0.2),
  (0.4, 0.15),
  (0.5, 0.25),
  (0.5, 0.2),
  (0.3, 0.3),
];

class Tally {
  int tp = 0, fp = 0, fn = 0;
  void add(Set<int> est, Set<int> truth) {
    for (final p in est) {
      if (truth.contains(p)) {
        tp++;
      } else {
        fp++;
      }
    }
    for (final p in truth) {
      if (!est.contains(p)) fn++;
    }
  }

  double get precision => tp + fp == 0 ? 0 : 100 * tp / (tp + fp);
  double get recall => tp + fn == 0 ? 0 : 100 * tp / (tp + fn);
  double get f1 =>
      precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall);
}

Float64List resampleLinear(Float64List input, double from, double to) {
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

void main(List<String> argv) {
  var data = '/mnt/storage/tuner-bench/datasets';
  var onnxPath = '../assets/models/basic_pitch.onnx';
  var limit = 8;
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--data':
        data = argv[++i];
      case '--onnx':
        onnxPath = argv[++i];
      case '--limit':
        limit = int.parse(argv[++i]);
    }
  }

  final audioDir = Directory('$data/audio');
  final files = audioDir
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('_comp_mic.wav'))
      .toList()
    ..sort();
  final chosen = files.take(limit == 0 ? files.length : limit).toList();
  if (chosen.isEmpty) {
    stderr.writeln('no _comp_mic.wav under $audioDir');
    exit(2);
  }

  final model = loadOnnxModel(onnxPath);
  final tallies = {for (final s in _settings) s: Tally()};

  for (final path in chosen) {
    final jamsPath = '$data/annotation/'
        '${path.split("/").last.replaceAll("_mic.wav", "")}.jams';
    if (!File(jamsPath).existsSync()) continue;
    final truth = readJams(jamsPath);
    final truthFrames = <int, Set<int>>{};
    for (final n in truth.notes) {
      final from = (n.onset / _scoreHop).floor();
      final to = (n.offset / _scoreHop).ceil();
      for (int f = from; f < to; f++) {
        (truthFrames[f] ??= <int>{}).add(n.midi.round());
      }
    }

    final wav = readWav(path);
    final audio = resampleLinear(wav.samples, wav.sampleRate.toDouble(),
        BasicPitchGeometry.sampleRate.toDouble());

    // Hysteresis is stateful across windows, so each setting carries its own
    // sounding set between them — decoding a stream, not a pile of clips.
    final carry = {for (final s in _settings) s: <int>{}};

    for (int start = 0;
        start + BasicPitchGeometry.windowSamples <= audio.length;
        start += BasicPitchGeometry.windowSamples) {
      final input = Float32List(BasicPitchGeometry.windowSamples);
      for (int i = 0; i < input.length; i++) {
        input[i] = audio[start + i];
      }
      final out = model.run(
        {'serving_default_input_2:0': Tensor.float(input, [1, input.length, 1])},
        const [_noteHead],
      );
      final note = Float64List.fromList(out[_noteHead]!.asFloatList());
      final frameBase = (start / BasicPitchGeometry.frameHop).round();

      for (final s in _settings) {
        final decoder =
            BasicPitchDecoder(noteThreshold: s.$1, sustainThreshold: s.$2);
        final seq = decoder.decodeFrames(note, carry: carry[s]);
        for (int f = 0; f < seq.length; f++) {
          tallies[s]!.add(seq[f], truthFrames[frameBase + f] ?? const <int>{});
        }
        carry[s] = seq.last;
      }
    }
    stdout.write('.');
  }
  stdout.writeln('');
  stdout.writeln('${chosen.length} chordal files, '
      '${_scoreHop * 1000 ~/ 1} ms frames\n');
  stdout.writeln('| start | sustain | precision | recall | F1 |');
  stdout.writeln('| --- | --- | --- | --- | --- |');
  for (final s in _settings) {
    final t = tallies[s]!;
    final ships = s.$1 == 0.4 && s.$2 == 0.4 ? '  <- ships today' : '';
    stdout.writeln('| ${s.$1} | ${s.$2} | '
        '${t.precision.toStringAsFixed(1)}% | '
        '${t.recall.toStringAsFixed(1)}% | '
        '${t.f1.toStringAsFixed(1)}% |$ships');
  }
  stdout.writeln('');
  stdout.writeln('for reference, §17 on these files: '
      'CrispASR/ggml 84.4% / 75.6% / 79.7%');
}
