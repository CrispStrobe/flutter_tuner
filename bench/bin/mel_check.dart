// Prove the Dart log-mel front end is the one these models were trained on.
//
//   dart run bin/mel_check.dart > /tmp/dart_mel.json
//   python3 tool/mel_reference.py /tmp/dart_mel.json
//
// A front-end mismatch does not announce itself: the model still runs, still
// emits plausible activations, and simply scores worse. §12.1 is this
// report's cautionary tale about exactly that, so the two front ends
// (hFT's and Onsets & Frames') are checked against `librosa` on a signal both
// sides generate from the same recipe, rather than trusted.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tuner_bench/hft.dart';
import 'package:tuner_bench/mel.dart';
import 'package:tuner_bench/oaf.dart';
import 'package:tuner_bench/wav.dart';

/// A deterministic test signal the Python side reproduces exactly: two
/// partials plus a 32-bit LCG noise floor, so the comparison covers both
/// tonal peaks and the low-level bins where a log takes small differences
/// and makes them large.
Float64List signal(int n, int sampleRate) {
  final x = Float64List(n);
  int seed = 12345;
  for (int i = 0; i < n; i++) {
    seed = (1103515245 * seed + 12345) & 0x7fffffff;
    final noise = (seed / 0x7fffffff) * 2 - 1;
    x[i] = 0.6 * math.sin(2 * math.pi * 440 * i / sampleRate) +
        0.25 * math.sin(2 * math.pi * 1234.5 * i / sampleRate) +
        0.01 * noise;
  }
  return x;
}

void main(List<String> argv) {
  // With `--wav`, dump what the models are actually fed on REAL audio: the
  // first two 192-frame hFT windows (which exercise the resampler, the
  // margin padding and the bin-major transpose) and the first O&F mel rows.
  // `tool/spectro_reference.py --dump` builds the same in numpy and
  // `tool/spectro_compare.py` diffs them, so a wrong transpose or an
  // off-by-one window is caught before any activation is believed.
  String? wavPath;
  double seconds = 20;
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--wav':
        wavPath = argv[++i];
      case '--seconds':
        seconds = double.parse(argv[++i]);
    }
  }
  if (wavPath != null) {
    final wav = readWav(wavPath);
    final n = (seconds * wav.sampleRate).round();
    final clip = Float64List.sublistView(
        wav.samples, 0, n < wav.samples.length ? n : wav.samples.length);
    final feat = hftFeature(clip, wav.sampleRate);
    final windows = <List<List<double>>>[];
    for (final w in [0, 1]) {
      final start = w * HftGeometry.numFrame;
      windows.add([
        for (int bin = 0; bin < HftGeometry.nBins; bin++)
          [
            for (int t = 0; t < HftGeometry.window; t++)
              feat.padded[start + t][bin]
          ]
      ]);
    }
    final oafMel = MelSpectrogram(
      sampleRate: OafGeometry.sampleRate,
      nFft: OafGeometry.nFft,
      winLength: OafGeometry.nFft,
      hopLength: OafGeometry.hop,
      nMels: OafGeometry.nMels,
      fMin: OafGeometry.fMin,
      fMax: OafGeometry.fMax,
      power: 1.0,
      pad: MelPad.reflect,
    ).compute(Float64List.sublistView(
        resampleTo(clip, wav.sampleRate, OafGeometry.sampleRate),
        0,
        resampleTo(clip, wav.sampleRate, OafGeometry.sampleRate).length - 1));
    stdout.writeln(jsonEncode({
      'hft_window': windows,
      'hft_frames': feat.frames,
      'oaf_mel': [
        for (final r in oafMel.take(8))
          [for (final v in r) math.log(math.max(v, 1e-5))]
      ],
      'oaf_frames': oafMel.length,
    }));
    return;
  }
  const sr = 16000;
  final x = signal(sr * 2, sr);

  final hft = MelSpectrogram(
    sampleRate: sr,
    nFft: 2048,
    winLength: 2048,
    hopLength: 256,
    nMels: 256,
    fMin: 0,
    fMax: 8000,
    power: 2.0,
    pad: MelPad.constant,
  ).compute(x);

  final oaf = MelSpectrogram(
    sampleRate: sr,
    nFft: 2048,
    winLength: 2048,
    hopLength: 512,
    nMels: 229,
    fMin: 30,
    fMax: 8000,
    power: 1.0,
    pad: MelPad.reflect,
  ).compute(x);

  // The resampler, checked the way a resampler should be: a pure tone in,
  // and how much of what comes out is not that tone.
  final at441 = Float64List(44100);
  for (int i = 0; i < at441.length; i++) {
    at441[i] = math.sin(2 * math.pi * 1000 * i / 44100);
  }
  final at16 = resampleTo(at441, 44100, 16000);

  stdout.writeln(jsonEncode({
    'hft': [for (final r in hft.take(8)) r.toList()],
    'oaf': [for (final r in oaf.take(8)) r.toList()],
    'hft_frames': hft.length,
    'oaf_frames': oaf.length,
    'resampled_1k': at16.sublist(2000, 2400).toList(),
  }));
}
