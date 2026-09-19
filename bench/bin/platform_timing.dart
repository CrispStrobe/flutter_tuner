// What the detectors and the transcription model cost on *this* machine.
//
//   dart run bin/platform_timing.dart
//
// No corpus: the point is the machine, not the audio, so the signal is
// synthesised and every platform measures the identical work. Run it on a CI
// runner to get a number for hardware nobody here owns — the Apple Silicon
// figures in REPORT.md §15 come from a macos-latest runner, not from an
// estimate.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/app/detectors.dart';
import 'package:tuner_bench/app/swipe.dart';
import 'package:tuner_bench/app/tuner_core.dart';

Float64List pluck(double f0, int n, {double rate = 44100}) {
  const harmonics = [1.0, 0.55, 0.32, 0.2, 0.13, 0.08];
  final rng = math.Random(3);
  final out = Float64List(n);
  for (int i = 0; i < n; i++) {
    final t = i / rate;
    double s = 0;
    for (int h = 0; h < harmonics.length; h++) {
      s += harmonics[h] *
          math.exp(-t * (1.2 + 0.5 * h)) *
          math.sin(2 * math.pi * f0 * (h + 1) * t);
    }
    out[i] = s * 0.4 + (rng.nextDouble() - 0.5) * 0.002;
  }
  return out;
}

/// Minimum of several runs: the minimum is the least contaminated by whatever
/// else the machine is doing, which on a shared runner is the whole problem.
double timeMin(void Function() f, {int warmup = 10, int reps = 40, int rounds = 5}) {
  for (int i = 0; i < warmup; i++) {
    f();
  }
  double best = double.infinity;
  for (int r = 0; r < rounds; r++) {
    final sw = Stopwatch()..start();
    for (int i = 0; i < reps; i++) {
      f();
    }
    sw.stop();
    final ms = sw.elapsedMicroseconds / 1000 / reps;
    if (ms < best) best = ms;
  }
  return best;
}

void main(List<String> args) {
  stdout.writeln('platform    : ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}');
  stdout.writeln('cores       : ${Platform.numberOfProcessors}');
  stdout.writeln('dart        : ${Platform.version.split(" ").first}');
  stdout.writeln('');

  final block = pluck(146.83, pitchWindowSize);
  final budget = 1000 * 1024 / 44100; // one 1024-sample analysis hop, in ms

  stdout.writeln('detector (4096-sample window, one analysis):');
  for (final entry in <(String, PitchEngine)>[
    ('YIN', YinEngine(sampleRate: 44100, windowSize: pitchWindowSize)),
    ('MPM', MpmEngine(sampleRate: 44100, windowSize: pitchWindowSize)),
    ("SWIPE'", SwipeEngine(sampleRate: 44100, windowSize: pitchWindowSize)),
  ]) {
    final ms = timeMin(() => entry.$2.analyse(block));
    stdout.writeln('  ${entry.$1.padRight(8)} ${ms.toStringAsFixed(3)} ms'
        '   ${(100 * ms / budget).toStringAsFixed(1)}% of a 23 ms hop');
  }

  final modelPath = args.isNotEmpty ? args.first : '../assets/models/basic_pitch.onnx';
  if (!File(modelPath).existsSync()) {
    stdout.writeln('\n(no model at $modelPath; skipping transcription)');
    return;
  }

  stdout.writeln('');
  stdout.writeln('transcription (Basic Pitch, one 2 s window):');
  final model = loadOnnxModel(modelPath);
  final input = Float32List(43844);
  final source = pluck(196.0, 43844, rate: 22050);
  for (int i = 0; i < input.length; i++) {
    input[i] = source[i];
  }
  final tensor = Tensor.float(input, [1, input.length, 1]);
  final ms = timeMin(
    () => model.run({'serving_default_input_2:0': tensor},
        const ['StatefulPartitionedCall:1']),
    warmup: 2,
    reps: 3,
    rounds: 3,
  );
  stdout.writeln('  pure Dart ${ms.toStringAsFixed(0)} ms'
      '   ${(100 * ms / 2000).toStringAsFixed(1)}% of real time'
      '   (native ONNX Runtime on a VPS core: 174-270 ms)');
}
