// What the real-input FFT is worth, measured rather than counted.
//
// Feeding a complex FFT a real signal with zeroed imaginary parts spends half
// its arithmetic on zeros. `RealFft.realForward` packs the N real samples as
// N/2 complex points, runs the half-length transform and untangles the result
// in one O(N) pass. This times the two against each other.
//
// Measurement discipline, learned the hard way in REPORT.md §19.1 and §23:
//
//   * ONE ARM PER PROCESS (`--only`). Running arms in one process lets Dart's
//     JIT warm the later ones and overstates the win.
//   * The caller runs a throwaway process first and loops reps OUTER, arms
//     INNER, so no arm permanently owns the cold-cache slot.
//   * Each process discards a warm-up round and reports the MEDIAN of the
//     rest, plus the minimum.
//
// Usage: dart run bin/fft_real_timing.dart --only "spectrum real 4096"
//        dart run bin/fft_real_timing.dart --list
import 'dart:math' as math;
import 'dart:typed_data';

import '../lib/app/fft_real.dart';

/// Rounds per measured pass, chosen so a pass is a few hundred ms.
const int rounds = 300;

/// Measured passes; the first is discarded.
const int passes = 7;

typedef Arm = void Function();

/// The pre-change `RealSpectrum.transform`: zero-fill the imaginary parts and
/// run the full complex transform. Kept here, not in `lib/`, so the shipped
/// file carries only one implementation.
Arm complexSpectrum(int size) {
  final fft = RealFft(size);
  final buf = fft.newBuffer();
  final signal = _signal(size);
  return () {
    for (int i = 0; i < size; i++) {
      buf[i * 2] = signal[i];
      buf[i * 2 + 1] = 0;
    }
    fft.transform(buf);
  };
}

Arm realSpectrum(int size) {
  final fft = RealFft(size);
  final buf = fft.newBuffer();
  final signal = _signal(size);
  return () => fft.realForward(signal, buf);
}

/// The pre-change `FftAutocorrelation.compute`, rebuilt on the public complex
/// API: two full forward transforms, a full-length pointwise multiply and one
/// full inverse.
Arm complexAutocorrelation(int head, int whole) {
  int n = 1;
  while (n < head + whole) {
    n <<= 1;
  }
  final fft = RealFft(n);
  final a = Float64List(n * 2), b = Float64List(n * 2);
  final window = _signal(whole);
  final out = Float64List(head);
  return () {
    for (int i = 0; i < n * 2; i++) {
      a[i] = 0;
      b[i] = 0;
    }
    for (int i = 0; i < head; i++) {
      a[(head - 1 - i) * 2] = window[i];
    }
    for (int i = 0; i < whole; i++) {
      b[i * 2] = window[i];
    }
    fft.transform(a);
    fft.transform(b);
    for (int i = 0; i < n; i++) {
      final ar = a[i * 2], ai = a[i * 2 + 1];
      final br = b[i * 2], bi = b[i * 2 + 1];
      a[i * 2] = ar * br - ai * bi;
      a[i * 2 + 1] = ar * bi + ai * br;
    }
    fft.transform(a, inverse: true);
    final scale = 1.0 / n;
    for (int tau = 0; tau < head; tau++) {
      out[tau] = a[(head - 1 + tau) * 2] * scale;
    }
  };
}

Arm realAutocorrelation(int head, int whole) {
  final ac =
      FftAutocorrelation(headLength: head, wholeLength: whole, lags: head);
  final window = _signal(whole);
  final out = Float64List(head);
  return () => ac.compute(window, out);
}

Float64List _signal(int n) {
  final rng = math.Random(20260922);
  final x = Float64List(n);
  for (int i = 0; i < n; i++) {
    // A plucked-string-ish sum of partials plus noise: the transform does not
    // care, but a constant or a pure sine can be optimised differently.
    final t = i / 44100.0;
    x[i] = math.sin(2 * math.pi * 196 * t) +
        0.5 * math.sin(2 * math.pi * 392 * t) +
        0.25 * math.sin(2 * math.pi * 588 * t) +
        0.02 * (rng.nextDouble() * 2 - 1);
  }
  return x;
}

final Map<String, Arm Function()> arms = {
  // The detector's own sizes: the spectrum display and harmonics use 2048 and
  // 4096; YIN's autocorrelation over a 4096 window pads to 8192.
  'spectrum complex 2048': () => complexSpectrum(2048),
  'spectrum real 2048': () => realSpectrum(2048),
  'spectrum complex 4096': () => complexSpectrum(4096),
  'spectrum real 4096': () => realSpectrum(4096),
  'spectrum complex 8192': () => complexSpectrum(8192),
  'spectrum real 8192': () => realSpectrum(8192),
  'autocorr complex 2048/4096': () => complexAutocorrelation(2048, 4096),
  'autocorr real 2048/4096': () => realAutocorrelation(2048, 4096),
};

void main(List<String> args) {
  if (args.contains('--list')) {
    arms.keys.forEach(print);
    return;
  }
  final i = args.indexOf('--only');
  // dart2js does not hand `main` the command line, so the arm can also be
  // fixed at compile time: `dart compile js -Darm="spectrum real 4096"`.
  // One arm per compiled program is one arm per process, which is the point.
  const compiled = String.fromEnvironment('arm');
  final only = i >= 0 && i + 1 < args.length
      ? args[i + 1]
      : (compiled.isEmpty ? null : compiled);
  final selected =
      only == null ? arms.keys.toList() : arms.keys.where((k) => k == only);
  if (selected.isEmpty) {
    stderrLine('no arm named "$only"; --list shows them');
    return;
  }
  if (only == null) {
    stderrLine('WARNING: all arms in one process. The JIT warms later arms '
        '(REPORT.md §19.1); use --only for a number worth quoting.');
  }
  for (final name in selected) {
    final arm = arms[name]!();
    final ms = <double>[];
    for (int p = 0; p < passes; p++) {
      final sw = Stopwatch()..start();
      for (int r = 0; r < rounds; r++) {
        arm();
      }
      sw.stop();
      ms.add(sw.elapsedMicroseconds / 1000.0 / rounds);
    }
    ms.removeAt(0); // the warm-up pass
    ms.sort();
    final median = ms[ms.length ~/ 2];
    print('${name.padRight(28)} ${median.toStringAsFixed(4)} ms/call  '
        '(min ${ms.first.toStringAsFixed(4)}, n=${ms.length} passes '
        'of $rounds)');
  }
}

void stderrLine(String s) => print('# $s');
