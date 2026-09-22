// What the two spectrogram models cost in the PURE-DART runtime.
//
//   dart run bin/spectro_timing.dart [--seconds 30] [--wav <path>]
//
// §31.1 measured Kong at ~96x real time in `onnx_runtime_dart` and inverted
// its own conclusion on the strength of it: compatibility is solved,
// throughput is the whole question. §31.2 then named hFT-Transformer as the
// one model that might need neither a native runtime nor a ggml one — 5.52 M
// parameters against Kong's 42.95 M — and put its cost at "near ~19x real
// time" by arithmetic rather than by measurement.
//
// This measures it. The number decides whether a strong transcriber can ship
// on all six platforms, web included, with no native library.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/app/transcription.dart';
import 'package:tuner_bench/hft.dart';
import 'package:tuner_bench/mel.dart';
import 'package:tuner_bench/oaf.dart';
import 'package:tuner_bench/wav.dart';

void main(List<String> argv) {
  var seconds = 30.0;
  var wavPath =
      '/mnt/storage/tuner-bench/datasets/musicnet/musicnet/test_data/2191.wav';
  var hftPath = '/mnt/storage/tuner-bench/onnx/hft_transformer.pruned.onnx';
  var oafPath = '/mnt/storage/tuner-bench/onnx/onsets_and_frames.onnx';
  var dump = '';
  var bpPath = '../assets/models/basic_pitch.onnx';
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--seconds':
        seconds = double.parse(argv[++i]);
      case '--wav':
        wavPath = argv[++i];
      case '--hft-onnx':
        hftPath = argv[++i];
      case '--oaf-onnx':
        oafPath = argv[++i];
      case '--dump':
        dump = argv[++i];
      case '--basic-pitch':
        bpPath = argv[++i];
    }
  }

  final dumped = <String, dynamic>{};
  final wav = readWav(wavPath);
  final n = (seconds * wav.sampleRate).round();
  final clip = Float64List.sublistView(
      wav.samples, 0, n < wav.samples.length ? n : wav.samples.length);
  final audioSeconds = clip.length / wav.sampleRate;
  stdout.writeln('${audioSeconds.toStringAsFixed(1)} s of '
      '${wavPath.split("/").last}, one isolate, pure Dart\n');

  // The front end is measured separately, because it is the part that would
  // also have to exist on a native path and the part §31.2 called hFT's
  // "real work".
  for (final m in [
    (
      'hft log-mel (256 bins, hop 256)',
      MelSpectrogram(
          sampleRate: 16000,
          nFft: 2048,
          winLength: 2048,
          hopLength: 256,
          nMels: 256,
          power: 2.0,
          pad: MelPad.constant)
    ),
    (
      'oaf log-mel (229 bins, hop 512)',
      MelSpectrogram(
          sampleRate: 16000,
          nFft: 2048,
          winLength: 2048,
          hopLength: 512,
          nMels: 229,
          fMin: 30,
          fMax: 8000,
          power: 1.0,
          pad: MelPad.reflect)
    ),
  ]) {
    final sw = Stopwatch()..start();
    final mono = resampleTo(clip, wav.sampleRate, 16000);
    final rs = sw.elapsedMicroseconds / 1e6;
    m.$2.compute(mono);
    sw.stop();
    final t = sw.elapsedMicroseconds / 1e6;
    stdout.writeln('${m.$1}: ${t.toStringAsFixed(2)} s '
        '(${(t / audioSeconds).toStringAsFixed(4)}x real time, of which '
        'resample ${(rs / audioSeconds).toStringAsFixed(4)}x)');
  }

  if (File(hftPath).existsSync()) {
    final model = loadOnnxModel(hftPath);
    final sw = Stopwatch()..start();
    int windows = 0;
    final f = hftForward(model, clip, wav.sampleRate,
        onWindow: (w) => windows = w);
    sw.stop();
    if (dump.isNotEmpty) {
      // The first 128 stitched rows ARE the first window's answer, so
      // dumping them checks the window arithmetic as well as the tensors.
      dumped['hft_first_window'] = {
        'onset_B': [for (final r in f.b.onset.take(128)) r.toList()],
        'mpe_B': [for (final r in f.b.mpe.take(128)) r.toList()],
      };
    }
    final t = sw.elapsedMicroseconds / 1e6;
    stdout.writeln('\nhFT-Transformer, $windows windows of 192 frames: '
        '${t.toStringAsFixed(1)} s = '
        '**${(t / audioSeconds).toStringAsFixed(1)}x real time**, '
        '${(1000 * t / windows).toStringAsFixed(0)} ms per window '
        '(each window answers for 2.048 s of audio)');
  } else {
    stdout.writeln('\nhFT: model not found at $hftPath');
  }

  if (File(oafPath).existsSync()) {
    final model = loadOnnxModel(oafPath);
    final sw = Stopwatch()..start();
    final f = oafForward(model, clip, wav.sampleRate);
    sw.stop();
    if (dump.isNotEmpty) {
      dumped['oaf_head'] = {
        'onset': [for (final r in f.onset.take(8)) r.toList()],
        'frame': [for (final r in f.frame.take(8)) r.toList()],
      };
    }
    final t = sw.elapsedMicroseconds / 1e6;
    stdout.writeln('Onsets & Frames, one pass: ${t.toStringAsFixed(1)} s = '
        '**${(t / audioSeconds).toStringAsFixed(1)}x real time**');
  } else {
    stdout.writeln('oaf: model not found at $oafPath');
  }

  // A co-measured baseline, because this box is shared and its load moves.
  // §30 measured Basic Pitch through the same runtime at **0.12x real
  // time**; running it here, in the same process and the same minute, turns
  // the absolute numbers above into a ratio that survives the load average.
  if (File(bpPath).existsSync()) {
    final model = loadOnnxModel(bpPath);
    final audio = resampleTo(
        clip, wav.sampleRate, BasicPitchGeometry.sampleRate);
    final sw = Stopwatch()..start();
    int windows = 0;
    for (int start = 0;
        start + BasicPitchGeometry.windowSamples <= audio.length;
        start += BasicPitchGeometry.windowSamples) {
      final input = Float32List(BasicPitchGeometry.windowSamples);
      for (int i = 0; i < input.length; i++) {
        input[i] = audio[start + i];
      }
      model.run(
        {'serving_default_input_2:0': Tensor.float(input, [1, input.length, 1])},
        const ['StatefulPartitionedCall:1', 'StatefulPartitionedCall:2'],
      );
      windows++;
    }
    sw.stop();
    final t = sw.elapsedMicroseconds / 1e6;
    stdout.writeln('\nBasic Pitch (the shipped model), $windows windows: '
        '${t.toStringAsFixed(1)} s = '
        '${(t / audioSeconds).toStringAsFixed(3)}x real time '
        '— §30 measured 0.12x on a quiet machine, so divide the rows '
        'above by ${((t / audioSeconds) / 0.12).toStringAsFixed(1)} to read '
        'them at that load');
  } else {
    stdout.writeln('\nbasic pitch: not found at $bpPath — no co-measured '
        'baseline, so the absolute numbers above carry this box\'s load');
  }

  if (dump.isNotEmpty) {
    File(dump).writeAsStringSync(jsonEncode(dumped));
    stdout.writeln('dumped $dump');
  }
}
