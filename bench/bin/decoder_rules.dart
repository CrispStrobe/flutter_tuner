// The two decoding rules Spotify's decoder has and this app's did not.
//
//   dart run bin/decoder_rules.dart --data <corpus> [--limit N]
//
// §18 bought five points of F1 from one `if`, and said the remaining
// headroom was likelier to be in decoding than in kernels. Spotify's
// note_creation.py applies rules this repo never ported:
//
//   * minimum_note_length_ms = 127.7 (~11 frames) — drop notes too short to
//     be real. Theirs is a post-filter over a segmented signal; a live
//     display cannot see the future, so `minNoteFrames` is the causal form,
//     a debounce on the start, and it costs exactly that much latency.
//   * infer_onsets — gate note creation on the onset head. This app computed
//     that head on every window and used it only to mark notes as newly
//     struck.
//
// Same 11.6 ms grid, same note_midi truth, same rules as §12, §17 and §18,
// so every number here is comparable to the tables already published.

import 'dart:io';
import 'dart:typed_data';

import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/app/transcription.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/wav.dart';

const _noteHead = 'StatefulPartitionedCall:1';
const _onsetHead = 'StatefulPartitionedCall:2';
const _scoreHop =
    BasicPitchGeometry.frameHop / BasicPitchGeometry.sampleRate;

/// (minNoteFrames, requireOnset, onsetThreshold). The first row is what §18
/// shipped, so every other row is a delta against a published number.
const _settings = <(int, bool, double)>[
  (0, false, 0.5),
  (2, false, 0.5),
  (4, false, 0.5),
  (6, false, 0.5),
  (11, false, 0.5),
  (0, true, 0.5),
  (0, true, 0.3),
  (0, true, 0.2),
  (2, true, 0.3),
  (4, true, 0.3),
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
  double get f1 => precision + recall == 0
      ? 0
      : 2 * precision * recall / (precision + recall);
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

  final files = Directory('$data/audio')
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('_comp_mic.wav'))
      .toList()
    ..sort();
  final chosen = files.take(limit == 0 ? files.length : limit).toList();
  if (chosen.isEmpty) {
    stderr.writeln('no _comp_mic.wav under $data/audio');
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
    // Every setting carries its own sounding set between windows: these are
    // stateful rules and a stream is what they run on.
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
        const [_noteHead, _onsetHead],
      );
      final note = Float64List.fromList(out[_noteHead]!.asFloatList());
      final onset = Float64List.fromList(out[_onsetHead]!.asFloatList());
      final frameBase = (start / BasicPitchGeometry.frameHop).round();

      for (final s in _settings) {
        final decoder = BasicPitchDecoder(
            minNoteFrames: s.$1, requireOnset: s.$2, onsetThreshold: s.$3);
        final seq =
            decoder.decodeFrames(note, carry: carry[s], onset: onset);
        for (int f = 0; f < seq.length; f++) {
          tallies[s]!.add(seq[f], truthFrames[frameBase + f] ?? const <int>{});
        }
        carry[s] = seq.last;
      }
    }
    stdout.write('.');
  }
  stdout.writeln('\n${chosen.length} chordal files, '
      '${_scoreHop * 1000 ~/ 1} ms frames, thresholds 0.5/0.25 throughout\n');
  stdout.writeln('| min length | onset gate | precision | recall | F1 |');
  stdout.writeln('| --- | --- | --- | --- | --- |');
  for (final s in _settings) {
    final t = tallies[s]!;
    final ships = s.$1 == 0 && !s.$2 ? '  <- ships today' : '';
    stdout.writeln('| ${s.$1} frames | ${s.$2 ? ">= ${s.$3}" : "none"} | '
        '${t.precision.toStringAsFixed(1)}% | '
        '${t.recall.toStringAsFixed(1)}% | '
        '${t.f1.toStringAsFixed(1)}% |$ships');
  }
  stdout.writeln('\nfor reference, §18 shipped 87.8% / 77.8% / 82.5% '
      'on all 180 files');
}
