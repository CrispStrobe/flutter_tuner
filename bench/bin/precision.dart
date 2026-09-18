// How precise can each estimator possibly be?
//
// GuitarSet's reference is itself an algorithm's output (pYIN on a hexaphonic
// pickup), so it cannot settle arguments at the tenth-of-a-cent level — which
// is exactly the level a tuner cares about. Synthetic tones can: the true f0
// is known exactly.
//
// This is the complement to bin/bench.dart, not a substitute for it. A
// synthetic tone is a far easier signal than a plucked string in a room, so
// these numbers are a *floor* on the error, never a prediction of it.
//
//   dart run bin/precision.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tuner_bench/app/tuner_core.dart';
import 'package:tuner_bench/metrics.dart';
import 'package:tuner_bench/mpm.dart';
import 'package:tuner_bench/refine.dart';
import 'package:tuner_bench/yin.dart';

const int rate = 44100;

/// A plucked string: falling harmonics, exponential decay, a little noise,
/// and optionally the stiffness that makes a real string's partials sharp.
Float64List pluck(double f0, int samples, math.Random rng,
    {double decay = 1.2, double b = 0.0, double noise = 0.002}) {
  const harmonics = [1.0, 0.55, 0.32, 0.20, 0.13, 0.08, 0.05, 0.03];
  final out = Float64List(samples);
  // A random phase per partial, or every run measures the same lucky frame.
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
      s += harmonics[h] *
          math.exp(-t * (decay + 0.6 * h)) *
          math.sin(2 * math.pi * partial * t + phases[h]);
    }
    out[i] = s * 0.4 + (rng.nextDouble() - 0.5) * noise;
  }
  return out;
}

class Case {
  final String name;
  final double b;
  final double noise;
  const Case(this.name, this.b, this.noise);
}

void main(List<String> args) {
  const cases = [
    Case('harmonic, quiet', 0.0, 0.002),
    Case('harmonic, noisy', 0.0, 0.05),
    Case('stiff string (B=1e-4)', 1e-4, 0.002),
  ];

  // The open strings of a guitar, each tested at a spread of detunings a
  // player would actually be looking at.
  const openStrings = [82.41, 110.0, 146.83, 196.0, 246.94, 329.63];
  const detunings = [-33.0, -12.0, -3.0, 0.0, 3.0, 12.0, 33.0];

  for (final c in cases) {
    final yin = RefYin(
        sampleRate: rate * 1.0, bufferSize: pitchWindowSize, useFft: true);
    final mpm = Mpm(sampleRate: rate * 1.0, bufferSize: pitchWindowSize);
    final results = <String, CentHistogram>{
      'yin (parabolic only)': CentHistogram(),
      'yin + step6': CentHistogram(),
      'mpm': CentHistogram(),
      'yin + instantaneous frequency': CentHistogram(),
      'yin + IF, stiffness fitted': CentHistogram(),
    };
    final rng = math.Random(11);
    int frames = 0;

    for (final base in openStrings) {
      for (final detune in detunings) {
        final f0 = base * math.pow(2, detune / 1200).toDouble();
        // Several frames per tone, at different points in the decay.
        final signal =
            pluck(f0, pitchWindowSize * 4, rng, b: c.b, noise: c.noise);
        for (int start = 0;
            start + pitchWindowSize <= signal.length;
            start += pitchWindowSize) {
          final block =
              Float64List.sublistView(signal, start, start + pitchWindowSize);
          frames++;
          yin.cmndf(block);
          final plain = yin.resultFromCmndf(0.15);
          final step6 = yin.resultFromCmndf(0.15, bestLocal: true);
          final m = mpm.getPitch(block);
          if (plain.pitched) {
            results['yin (parabolic only)']!.add(cents(plain.pitch, f0));
            final r1 = refineByInstantaneousFrequency(
                block, plain.pitch, rate * 1.0,
                fitInharmonicity: false);
            results['yin + instantaneous frequency']!
                .add(cents(r1.frequency, f0));
            final r2 = refineByInstantaneousFrequency(
                block, plain.pitch, rate * 1.0,
                fitInharmonicity: true);
            results['yin + IF, stiffness fitted']!.add(cents(r2.frequency, f0));
          }
          if (step6.pitched) {
            results['yin + step6']!.add(cents(step6.pitch, f0));
          }
          if (m.pitched) results['mpm']!.add(cents(m.pitch, f0));
        }
      }
    }

    stdout.writeln('${c.name}  ($frames frames, '
        'noise ${c.noise}, B ${c.b})');
    stdout.writeln('  estimator                        '
        'bias    |err| p50   p90    p99');
    for (final e in results.entries) {
      final h = e.value;
      stdout.writeln('  ${e.key.padRight(32)}'
          '${h.mean.toStringAsFixed(2).padLeft(6)}  '
          '${h.absPercentile(0.5).toStringAsFixed(2).padLeft(8)}'
          '${h.absPercentile(0.9).toStringAsFixed(2).padLeft(7)}'
          '${h.absPercentile(0.99).toStringAsFixed(2).padLeft(7)}');
    }
    stdout.writeln('');
  }

  stdout.writeln('A note on the stiff case: the true f0 of a stiff string is '
      'the fitted f0, not the first partial —');
  stdout.writeln('the first partial sits at f0·sqrt(1+B), which is '
      '${(600 * math.log(1 + 1e-4) / math.ln2).toStringAsFixed(2)} cents '
      'sharp at B=1e-4.');
}
