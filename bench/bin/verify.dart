// Does the benchmark's YIN agree with the one the app actually ships?
//
// Everything downstream rests on RefYin being the package frame for frame at
// its defaults, so that differences later can be attributed to the parameter
// that was changed rather than to a reimplementation. This walks real audio
// and compares, then times the naive and FFT difference functions.
//
//   dart run bin/verify.dart <wav> [frames]

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/wav.dart';
import 'package:tuner_bench/yin.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run bin/verify.dart <wav> [frames]');
    exit(2);
  }
  final wav = readWav(args[0]);
  final maxFrames = args.length > 1 ? int.parse(args[1]) : 200;
  final rate = wav.sampleRate.toDouble();
  const hop = 1024;

  final package =
      PitchDetector(audioSampleRate: rate, bufferSize: pitchWindowSize);
  final naive = RefYin(sampleRate: rate, bufferSize: pitchWindowSize);
  final fast =
      RefYin(sampleRate: rate, bufferSize: pitchWindowSize, useFft: true);

  int compared = 0, mismatched = 0;
  double worstCents = 0;
  final frames = <Float64List>[];
  for (int start = 0;
      start + pitchWindowSize <= wav.samples.length &&
          frames.length < maxFrames;
      start += hop) {
    frames.add(
        Float64List.sublistView(wav.samples, start, start + pitchWindowSize));
  }

  for (final block in frames) {
    final a = await package.getPitchFromFloatBuffer(block);
    final b = naive.getPitch(block);
    final c = fast.getPitch(block);
    compared++;
    bool bad = a.pitched != b.pitched || a.pitched != c.pitched;
    if (a.pitched) {
      for (final got in [b.pitch, c.pitch]) {
        final cents = (1200 * math.log(got / a.pitch) / math.ln2).abs();
        if (cents > worstCents) worstCents = cents;
        if (cents > 0.01) bad = true;
      }
    }
    if (bad) mismatched++;
  }

  stdout.writeln('frames compared : $compared');
  stdout.writeln('mismatches      : $mismatched');
  stdout.writeln(
      'worst deviation : ${worstCents.toStringAsExponential(2)} cents');

  // Timing, on the same frames, warmed up.
  double time(void Function(Float64List) f, int reps) {
    for (final b in frames.take(5)) {
      f(b);
    }
    final sw = Stopwatch()..start();
    int n = 0;
    for (int r = 0; r < reps; r++) {
      for (final b in frames) {
        f(b);
        n++;
      }
    }
    sw.stop();
    return sw.elapsedMicroseconds / 1000.0 / n;
  }

  final naiveMs = time((b) => naive.getPitch(b), 1);
  final fftMs = time((b) => fast.getPitch(b), 3);
  final pkgSw = Stopwatch()..start();
  for (final b in frames) {
    await package.getPitchFromFloatBuffer(b);
  }
  pkgSw.stop();

  stdout.writeln('');
  stdout.writeln(
      'package (naive) : ${(pkgSw.elapsedMicroseconds / 1000 / frames.length).toStringAsFixed(3)} ms/frame');
  stdout.writeln('RefYin naive    : ${naiveMs.toStringAsFixed(3)} ms/frame');
  stdout.writeln('RefYin FFT      : ${fftMs.toStringAsFixed(3)} ms/frame');
  stdout.writeln('speed-up        : ${(naiveMs / fftMs).toStringAsFixed(1)}x');
  exit(mismatched == 0 ? 0 : 1);
}
