import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_tuner/detectors.dart';
import 'package:flutter_tuner/pyin_note.dart';
import 'package:flutter_tuner/tuner_core.dart';

/// The pYIN + note-model detector (bench/REPORT.md §39). Its accuracy is
/// measured on GuitarSet by `bench/bin/note_state.dart`; these pin the
/// behaviour that measurement depends on.
void main() {
  const rate = 44100.0;
  const hop = 1024;

  /// A continuous tone with decaying harmonics, long enough to slide a
  /// window along it.
  Float64List tone(double f0, int samples, {double noise = 0.005}) {
    final rng = math.Random(3);
    const harmonics = [1.0, 0.55, 0.32, 0.20, 0.13, 0.08];
    final out = Float64List(samples);
    for (int i = 0; i < samples; i++) {
      final t = i / rate;
      double s = 0;
      for (int h = 0; h < harmonics.length; h++) {
        s += harmonics[h] * math.sin(2 * math.pi * f0 * (h + 1) * t);
      }
      out[i] = s * 0.3 + (rng.nextDouble() - 0.5) * noise;
    }
    return out;
  }

  /// Run [engine] over [signal] at the app's hop; one estimate per frame.
  List<PitchEstimate> run(PitchEngine engine, Float64List signal) => [
        for (int start = 0;
            start + pitchWindowSize <= signal.length;
            start += hop)
          engine.analyse(
              Float64List.sublistView(signal, start, start + pitchWindowSize))
      ];

  PyinNoteEngine engine() =>
      PyinNoteEngine(sampleRate: rate, windowSize: pitchWindowSize);

  test('a held note is withheld for one frame, then read to YIN precision',
      () {
    for (final f0 in [82.41, 196.0, 440.0, 987.77]) {
      final frames = run(engine(), tone(f0, pitchWindowSize + 10 * hop));
      expect(frames.first.pitched, isFalse,
          reason: 'a note must last two frames before it is shown');
      for (final r in frames.skip(1)) {
        expect(r.pitched, isTrue, reason: '$f0 Hz dropped a frame');
        expect(centsBetween(r.frequency, f0).abs(), lessThan(2),
            reason: '$f0 Hz read as ${r.frequency}');
      }
    }
  });

  test('silence and faint noise are never shown', () {
    final rng = math.Random(9);
    final noise = Float64List.fromList([
      for (int i = 0; i < pitchWindowSize + 20 * hop; i++)
        (rng.nextDouble() - 0.5) * 0.002
    ]);
    expect(run(engine(), noise).where((r) => r.pitched), isEmpty);
    expect(
        run(engine(), Float64List(pitchWindowSize + 5 * hop))
            .where((r) => r.pitched),
        isEmpty);
  });

  test('it is the pyinNote kind, and the factory builds it', () {
    final e = PitchEngine.of(DetectorKind.pyinNote,
        sampleRate: rate, windowSize: pitchWindowSize);
    expect(e, isA<PyinNoteEngine>());
    expect(e.kind, DetectorKind.pyinNote);
    // pYIN's grid starts at 30 Hz, above the 4096 window's 21.5 Hz floor.
    expect(e.detectionFloor, 30.0);
  });

  test('costs a small fraction of the 23 ms frame budget', () {
    final e = engine();
    final signal = tone(146.83, pitchWindowSize + 200 * hop);
    run(e, Float64List.sublistView(signal, 0, pitchWindowSize + 20 * hop));
    final sw = Stopwatch()..start();
    final frames = run(e, signal);
    final perFrameMs = sw.elapsedMicroseconds / 1000 / frames.length;
    // Generous: a shared CI box, not a benchmark. The measured figure goes
    // in REPORT.md, not here.
    expect(perFrameMs, lessThan(10),
        reason: '${perFrameMs.toStringAsFixed(2)} ms a frame');
  });
}
