// What each detector costs per frame, on real audio.
//
//   dart run bin/timing.dart <wav> [frames]
//
// The number that matters is not the absolute millisecond count — this is a
// VPS core, not a phone — but the ratio, and whether a frame fits inside the
// interval between audio callbacks. The app analyses a 4096-sample window on
// *every* callback, so if a callback arrives every 23 ms and a frame costs 35,
// the detector is the bottleneck and frames queue up behind it.

import 'dart:io';
import 'dart:typed_data';

import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/mpm.dart';
import 'package:tuner_bench/pyin.dart';
import 'package:tuner_bench/refine.dart';
import 'package:tuner_bench/wav.dart';
import 'package:tuner_bench/yin.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run bin/timing.dart <wav> [frames]');
    exit(2);
  }
  final wav = readWav(args[0]);
  final want = args.length > 1 ? int.parse(args[1]) : 300;
  final rate = wav.sampleRate.toDouble();
  const hop = 1024;
  const window = pitchWindowSize;

  final frames = <Float64List>[];
  for (int start = 0;
      start + window <= wav.samples.length && frames.length < want;
      start += hop) {
    frames.add(Float64List.sublistView(wav.samples, start, start + window));
  }

  final package = PitchDetector(audioSampleRate: rate, bufferSize: window);
  final naive = RefYin(sampleRate: rate, bufferSize: window);
  final fast = RefYin(sampleRate: rate, bufferSize: window, useFft: true);
  final mpm = Mpm(sampleRate: rate, bufferSize: window);
  final pyin = PyinTracker(sampleRate: rate, bufferSize: window);

  double measure(void Function(Float64List) f, {int reps = 1}) {
    for (final b in frames.take(10)) {
      f(b);
    }
    final sw = Stopwatch()..start();
    for (int r = 0; r < reps; r++) {
      for (final b in frames) {
        f(b);
      }
    }
    sw.stop();
    return sw.elapsedMicroseconds / 1000.0 / (frames.length * reps);
  }

  final rows = <({String name, double ms})>[];

  // The package is async, so time it on its own.
  for (final b in frames.take(10)) {
    await package.getPitchFromFloatBuffer(b);
  }
  final pkg = Stopwatch()..start();
  for (final b in frames) {
    await package.getPitchFromFloatBuffer(b);
  }
  pkg.stop();
  rows.add((
    name: 'pitch_detector_dart 0.0.7 (shipped)',
    ms: pkg.elapsedMicroseconds / 1000.0 / frames.length
  ));

  rows.add((
    name: 'YIN, naive difference (Float64List)',
    ms: measure((b) => naive.getPitch(b))
  ));
  rows.add((
    name: 'YIN, FFT difference',
    ms: measure((b) => fast.getPitch(b), reps: 5)
  ));
  rows.add(
      (name: 'MPM / NSDF (FFT)', ms: measure((b) => mpm.getPitch(b), reps: 5)));
  rows.add((
    name: 'instantaneous-frequency refinement alone',
    ms: measure((b) => refineByInstantaneousFrequency(b, 196.0, rate), reps: 5)
  ));
  rows.add((
    name: 'pYIN front end (FFT YIN + candidate set)',
    ms: measure((b) {
      fast.cmndf(b);
      pyin.observe(fast);
    }, reps: 5)
  ));

  // pYIN's Viterbi is per file, not per frame; report it amortised.
  final observations = [
    for (final b in frames)
      () {
        fast.cmndf(b);
        return pyin.observe(fast);
      }()
  ];
  final viterbi = Stopwatch()..start();
  pyin.decode(observations);
  viterbi.stop();

  stdout.writeln('frames      : ${frames.length} of $window samples '
      '(${(1000 * hop / rate).toStringAsFixed(1)} ms apart at hop $hop)');
  stdout.writeln('budget      : ${(1000 * hop / rate).toStringAsFixed(1)} ms '
      'per frame to keep up in real time');
  stdout.writeln('');
  for (final r in rows) {
    stdout.writeln('${r.name.padRight(42)} '
        '${r.ms.toStringAsFixed(3).padLeft(8)} ms  '
        '${(100 * r.ms * rate / hop / 1000).toStringAsFixed(1)}% of budget');
  }
  stdout.writeln('');
  stdout.writeln('pYIN Viterbi over ${frames.length} frames: '
      '${(viterbi.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms total, '
      '${(viterbi.elapsedMicroseconds / 1000 / frames.length).toStringAsFixed(3)}'
      ' ms/frame amortised (and it cannot run until the file is over — '
      'online use needs a bounded lag instead)');
}
