// Does the inharmonicity estimate recover a B it was given?
//
//   dart run bin/inharmonicity.dart
//
// `harmonics.dart` has estimated B — the stiffness coefficient in
// `f_n = n·f0·sqrt(1 + B·n²)` — since it was written, and nothing has ever
// used it. The brief called it "potentially the most valuable feature here …
// the gateway to stretch tuning", so before wiring it into a tuner it is
// worth knowing whether the number is right.
//
// GuitarSet cannot answer that: it annotates pitch, not stiffness. A
// synthesised stiff string can, because B is an input. That is a weaker test
// than the corpus — this report's own caution is that a synthetic tone is a
// far easier signal than a plucked string — so it establishes only that the
// estimator is not broken, never that it works on a real recording. §21 says
// so plainly.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tuner_bench/app/harmonics.dart';

const _rate = 44100.0;

/// A stiff string: partial n sits at `n·f0·sqrt(1 + B·n²)`, decaying with
/// order so the spectrum looks like something a pickup would see.
Float64List stiffString(double f0, double b,
    {int partials = 12, int length = 8192}) {
  final x = Float64List(length);
  for (int n = 1; n <= partials; n++) {
    final f = n * f0 * math.sqrt(1 + b * n * n);
    if (f >= _rate / 2) break;
    final amp = 1.0 / (n * n * 0.35 + 1);
    final phase = 0.7 * n; // fixed, so runs are reproducible
    for (int i = 0; i < length; i++) {
      x[i] += amp * math.sin(2 * math.pi * f * i / _rate + phase);
    }
  }
  return x;
}

void main() {
  stdout.writeln('| f0 | B given | B found | error | octave stretch |');
  stdout.writeln('| --- | --- | --- | --- | --- |');

  // Bs spanning a wound bass string (~1e-4) to a plain treble string
  // (~1e-5), plus 0 for a perfectly flexible one.
  const cases = <(double, double)>[
    (82.41, 0.0),
    (82.41, 2.0e-4),
    (110.0, 1.0e-4),
    (146.83, 5.0e-5),
    (196.0, 3.0e-5),
    (246.94, 1.5e-5),
    (329.63, 1.0e-5),
  ];

  int ok = 0;
  for (final (f0, b) in cases) {
    final buffer = stiffString(f0, b);
    final profile = analyseHarmonics(buffer, f0, _rate);
    final found = profile.inharmonicity;
    final stretch = profile.octaveStretchCents();
    if (found == null) {
      stdout.writeln('| $f0 | $b | (none) | — | — |');
      continue;
    }
    final err = b == 0 ? found.abs() : (found - b).abs() / b;
    if (b == 0 ? found.abs() < 5e-6 : err < 0.25) ok++;
    stdout.writeln('| ${f0.toStringAsFixed(2)} | '
        '${b.toStringAsExponential(1)} | '
        '${found.toStringAsExponential(1)} | '
        '${b == 0 ? found.toStringAsExponential(1) : "${(err * 100).toStringAsFixed(0)}%"} | '
        '${stretch.toStringAsFixed(2)} cents |');
  }
  stdout.writeln('\n$ok of ${cases.length} within tolerance '
      '(25% relative, or |B| < 5e-6 when B is zero)');
}
