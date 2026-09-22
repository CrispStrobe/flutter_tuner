// Is there *any* PLL setting that works inside a tuner's frame?
//
//   dart run bin/pll_sweep.dart
//
// §4.6 rejects the phase-locked loop, and a rejection is only worth
// anything if the thing was given a fair run. A loop has two knobs that
// matter here — how fast it is allowed to follow, and how much of the block
// is thrown away while it acquires — and they pull against each other inside
// a 93 ms window. This sweeps both against the same synthetic plucks
// bin/precision.dart uses.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/narrowband.dart';
import 'package:tuner_bench/yin.dart';

const int rate = 44100;
void main() {
  for (final bw in [4.0, 15.0, 40.0, 100.0, 250.0]) {
    for (final settle in [0.4, 0.75]) {
      final h = CentHistogram();
      final yin = RefYin(sampleRate: rate * 1.0, bufferSize: pitchWindowSize, useFft: true);
      final rng = math.Random(11);
      for (final base in [82.41, 110.0, 146.83, 196.0, 246.94, 329.63]) {
        for (final d in [-33.0, -12.0, -3.0, 0.0, 3.0, 12.0, 33.0]) {
          final f0 = base * math.pow(2, d / 1200).toDouble();
          final sig = pluck(f0, pitchWindowSize * 4, rng, noise: 0.002);
          for (int s = 0; s + pitchWindowSize <= sig.length; s += pitchWindowSize) {
            final block = Float64List.sublistView(sig, s, s + pitchWindowSize);
            yin.cmndf(block);
            final r = yin.resultFromCmndf(0.15);
            if (!r.pitched) continue;
            h.add(cents(refineByPll(block, r.pitch, rate * 1.0,
                loopBandwidthHz: bw, settleFraction: settle), f0));
          }
        }
      }
      stdout.writeln('bw=${bw.toStringAsFixed(0)} settle=$settle  '
          'bias ${h.mean.toStringAsFixed(2)}  p50 ${h.absPercentile(0.5).toStringAsFixed(2)}  '
          'p90 ${h.absPercentile(0.9).toStringAsFixed(2)}');
    }
  }
}

Float64List pluck(double f0, int samples, math.Random rng,
    {double decay = 1.2, double b = 0.0, double noise = 0.002}) {
  const harmonics = [1.0, 0.55, 0.32, 0.20, 0.13, 0.08, 0.05, 0.03];
  final out = Float64List(samples);
  final phases = [
    for (int i = 0; i < harmonics.length; i++) rng.nextDouble() * 2 * math.pi
  ];
  for (int i = 0; i < samples; i++) {
    final t = i / rate;
    double s = 0;
    for (int h = 0; h < harmonics.length; h++) {
      final n = h + 1;
      final partial = f0 * n * math.sqrt(1 + b * n * n);
      if (partial > rate / 2) break;
      s += harmonics[h] * math.exp(-t * (decay + 0.6 * h)) *
          math.sin(2 * math.pi * partial * t + phases[h]);
    }
    out[i] = s * 0.4 + (rng.nextDouble() - 0.5) * noise;
  }
  return out;
}
