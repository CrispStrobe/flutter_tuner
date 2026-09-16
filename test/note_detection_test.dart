import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/tuner_engine.dart';

void main() {
  lowEndTests();
  group('note naming', () {
    test('MIDI 69 is A4', () {
      expect(TunerEngine.noteNameForMidi(69), 'A4');
      expect(TunerEngine.midiForNoteName('A4'), 69);
    });

    test('round-trips across the whole range', () {
      for (int midi = TunerEngine.minMidi; midi <= TunerEngine.maxMidi; midi++) {
        final name = TunerEngine.noteNameForMidi(midi);
        expect(TunerEngine.midiForNoteName(name), midi, reason: name);
      }
    });

    test('accepts flat spellings', () {
      expect(TunerEngine.midiForNoteName('Eb3'),
          TunerEngine.midiForNoteName('D#3'));
      expect(TunerEngine.midiForNoteName('Bb2'),
          TunerEngine.midiForNoteName('A#2'));
    });

    test('rejects nonsense rather than guessing', () {
      for (final bad in ['', 'H4', 'X', '4', 'A', 'A#', 'Ab#3', 'A4x']) {
        expect(TunerEngine.midiForNoteName(bad), isNull, reason: bad);
      }
    });

    test('stripOctave removes the octave and nothing else', () {
      expect(TunerEngine.stripOctave('A4'), 'A');
      expect(TunerEngine.stripOctave('C#10'), 'C#');
      expect(TunerEngine.stripOctave('E-1'), 'E');
    });
  });

  group('detection range', () {
    // The old hand-written note table stopped at C6 (~1046 Hz), so everything
    // above it was reported as a badly out-of-tune C6 — on an instrument the
    // app advertises, in ordinary playing positions.
    test('resolves notes above the old C6 ceiling', () {
      final engine = TunerEngine();
      for (final name in ['E6', 'A6', 'B6', 'C7', 'E7', 'C8']) {
        final frequency = engine.getFrequencyForNote(name)!;
        final result = engine.detectNote(frequency);
        expect(result.note, name, reason: '$name at $frequency Hz');
        expect(result.cents.abs(), lessThan(0.01), reason: name);
      }
    });

    test('a violin high E is not mistaken for a wildly flat C6', () {
      final engine = TunerEngine();
      // E6, two octaves above the open E string's E4... the E an octave above
      // the top open string, routine in third position and up.
      final result = engine.detectNote(1318.51);
      expect(result.note, 'E6');
      expect(result.status, TuningStatus.inTune);
    });

    test('resolves the bottom of the range', () {
      final engine = TunerEngine();
      for (final name in ['A0', 'B0', 'C1', 'E1']) {
        final frequency = engine.getFrequencyForNote(name)!;
        expect(engine.detectNote(frequency).note, name);
      }
    });

    test('every note in range round-trips through detection', () {
      final engine = TunerEngine();
      for (int midi = TunerEngine.minMidi; midi <= TunerEngine.maxMidi; midi++) {
        final name = TunerEngine.noteNameForMidi(midi);
        final result = engine.detectNote(engine.frequencyForMidi(midi));
        expect(result.note, name, reason: name);
        expect(result.cents.abs(), lessThan(1e-6), reason: name);
      }
    });

    test('pitches beyond the range clamp instead of crashing', () {
      final engine = TunerEngine();
      expect(engine.detectNote(20000).note, 'C8');
      expect(engine.detectNote(1.0).note, 'A0');
    });

    test('rejects non-positive and non-finite input', () {
      final engine = TunerEngine();
      for (final bad in [0.0, -440.0, double.nan, double.infinity]) {
        expect(engine.detectNote(bad).isEmpty, isTrue, reason: '$bad');
      }
    });
  });

  group('semitone boundary', () {
    // Pitch is logarithmic: the boundary between two semitones is their
    // geometric mean (where the reading is ±50 cents), not the arithmetic
    // mean the old linear nearest-frequency scan effectively used. Between
    // A4 and A#4 the two differ by about 0.19 Hz, and every pitch in that
    // band was attributed to the lower note.
    final engine = TunerEngine();
    const a4 = 440.0;
    final aSharp4 = 440.0 * math.pow(2, 1 / 12.0);
    final geometric = math.sqrt(a4 * aSharp4);
    final arithmetic = (a4 + aSharp4) / 2;

    test('the two means really do differ here', () {
      expect(geometric, closeTo(452.893, 0.001));
      expect(arithmetic, closeTo(453.082, 0.001));
      expect(arithmetic, greaterThan(geometric));
    });

    test('the geometric mean reads exactly ±50 cents', () {
      final result = engine.detectNote(geometric);
      expect(result.cents.abs(), closeTo(50.0, 1e-6));
    });

    test('a pitch in the disputed band belongs to the upper note', () {
      final between = (geometric + arithmetic) / 2;
      final result = engine.detectNote(between);
      expect(result.note, 'A#4',
          reason: '$between Hz is closer to A#4 in cents, which is what a '
              'tuner means by closer');
      expect(result.cents.abs(), lessThan(50));
    });

    test('just below the geometric mean still belongs to the lower note', () {
      final result = engine.detectNote(geometric - 0.05);
      expect(result.note, 'A4');
    });

    test('never reports more than 50 cents of error', () {
      final engine = TunerEngine();
      // Sweep the range finely; any pitch should land within half a semitone
      // of some note, or the nearest-note search is wrong somewhere.
      for (double f = 30; f < 4000; f *= 1.0013) {
        final result = engine.detectNote(f);
        expect(result.cents.abs(), lessThanOrEqualTo(50.0 + 1e-9),
            reason: '$f Hz reported ${result.cents} cents from ${result.note}');
      }
    });

    test('matches an exhaustive search, in every temperament', () {
      // The three-candidate window is an optimisation over scanning every
      // note. It is only valid if it picks the same note a full scan would —
      // and an unequal temperament is where it would break first, because
      // the targets no longer sit on a 100-cent grid.
      for (final t in Temperament.values) {
        final engine = TunerEngine(temperament: t);
        for (double f = 28; f < 4300; f *= 1.0017) {
          final result = engine.detectNote(f);

          String? exhaustiveNote;
          double exhaustiveCents = double.infinity;
          for (int midi = TunerEngine.minMidi;
              midi <= TunerEngine.maxMidi;
              midi++) {
            final cents =
                TunerEngine.computeCents(f, engine.frequencyForMidi(midi));
            if (cents.abs() < exhaustiveCents.abs()) {
              exhaustiveCents = cents;
              exhaustiveNote = TunerEngine.noteNameForMidi(midi);
            }
          }

          expect(result.note, exhaustiveNote,
              reason: '${t.name} at $f Hz');
          expect(result.cents, closeTo(exhaustiveCents, 1e-9),
              reason: '${t.name} at $f Hz');
        }
      }
    });

    test('error never exceeds half the widest semitone of the temperament',
        () {
      // In equal temperament that is 50 cents. Unequal temperaments have
      // semitones of different sizes — quarter-comma meantone's diatonic
      // semitone is 117.1 cents — so the bound there is genuinely wider, and
      // asserting a flat 50 would be asserting the wrong thing.
      for (final t in Temperament.values) {
        final engine = TunerEngine(temperament: t);
        final table = TemperamentTable(t);
        final positions = [
          for (int pc = 0; pc < 12; pc++) 100.0 * pc + table.centsForPitchClass(pc),
        ];
        positions.add(1200 + positions.first);
        double widest = 0;
        for (int i = 0; i < 12; i++) {
          widest = math.max(widest, positions[i + 1] - positions[i]);
        }

        for (double f = 30; f < 4000; f *= 1.0013) {
          expect(engine.detectNote(f).cents.abs(),
              lessThanOrEqualTo(widest / 2 + 1e-6),
              reason: '${t.name} at $f Hz (widest semitone $widest cents)');
        }
      }
    });
  });

  group('concert pitch', () {
    test('A4 follows the slider', () {
      final engine = TunerEngine(a4Frequency: 432.0);
      expect(engine.getFrequencyForNote('A4'), closeTo(432.0, 1e-9));
      expect(engine.getFrequencyForNote('A3'), closeTo(216.0, 1e-9));
      expect(engine.detectNote(432.0).note, 'A4');
      expect(engine.detectNote(432.0).cents, closeTo(0, 1e-9));
    });

    test('a 415 Hz baroque pitch puts 440 Hz past A entirely', () {
      final engine = TunerEngine(a4Frequency: 415.0);
      final result = engine.detectNote(440.0);
      // 440 against A = 415 is 101.3 cents — over a semitone, so the nearest
      // note really is A#, not a very sharp A.
      expect(1200 * math.log(440 / 415) / math.ln2, closeTo(101.27, 0.01));
      expect(result.note, 'A#4');
      expect(result.cents, closeTo(1.27, 0.01));
    });

    test('a modern A reads slightly sharp against a 435 Hz orchestra', () {
      final engine = TunerEngine(a4Frequency: 435.0);
      final result = engine.detectNote(440.0);
      expect(result.note, 'A4');
      expect(result.cents, closeTo(19.78, 0.01));
      expect(result.status, TuningStatus.sharp);
    });
  });
}

/// Regression tests for the low end.
///
/// These encode the bug the headless probe (`tool/tuner_probe.dart`) found:
/// with a 2048-sample YIN window the detector cannot represent anything below
/// 43.07 Hz, so a bass guitar's open low E read as an F and a five-string's
/// low B produced no reading at all.
void lowEndTests() {
  group('analysis window', () {
    test('the window reaches below the lowest note any tuning asks for', () {
      const sampleRate = 44100.0;
      // YIN searches lags up to bufferSize / 2.
      const floor = 2 * sampleRate / pitchWindowSize;

      int lowest = TunerEngine.maxMidi;
      String lowestNote = '';
      for (final instrument in Instrument.values) {
        for (final tuning in tuningsFor(instrument)) {
          for (final note in tuning.strings) {
            final midi = TunerEngine.midiForNoteName(note)!;
            if (midi < lowest) {
              lowest = midi;
              lowestNote = note;
            }
          }
        }
      }

      final engine = TunerEngine();
      final lowestFrequency = engine.frequencyForMidi(lowest);
      expect(floor, lessThan(lowestFrequency),
          reason: 'the lowest string the app offers is $lowestNote at '
              '${lowestFrequency.toStringAsFixed(2)} Hz, but YIN bottoms out '
              'at ${floor.toStringAsFixed(2)} Hz with a $pitchWindowSize '
              'sample window');
    });

    test('the old 2048-sample window would not have been enough', () {
      // Documents why the window was widened, so nobody narrows it again to
      // save latency without noticing what it costs.
      const oldFloor = 2 * 44100.0 / 2048;
      final engine = TunerEngine();
      expect(oldFloor, greaterThan(engine.getFrequencyForNote('E1')!));
      expect(2 * 44100.0 / pitchWindowSize,
          lessThan(engine.getFrequencyForNote('B0')!));
    });
  });

  group('RollingWindow', () {
    test('accumulates across chunks smaller than the window', () {
      final window = RollingWindow(8);
      for (int i = 0; i < 4; i++) {
        window.add(Float64List.fromList([i * 2.0, i * 2.0 + 1]));
      }
      expect(window.isFull, isTrue);
      expect(window.lastN(8), [0, 1, 2, 3, 4, 5, 6, 7]);
    });

    test('reports not-full until it genuinely has a full window', () {
      final window = RollingWindow(4);
      window.add(Float64List.fromList([1, 2, 3]));
      expect(window.isFull, isFalse);
      expect(window.available, 3);
      expect(window.lastN(4), isEmpty);
      window.add(Float64List.fromList([4]));
      expect(window.isFull, isTrue);
      expect(window.lastN(4), [1, 2, 3, 4]);
    });

    test('keeps the newest samples once it wraps', () {
      final window = RollingWindow(4);
      window.add(Float64List.fromList([1, 2, 3, 4, 5, 6]));
      expect(window.lastN(4), [3, 4, 5, 6]);
      window.add(Float64List.fromList([7]));
      expect(window.lastN(4), [4, 5, 6, 7]);
    });

    test('a chunk larger than the window keeps only its tail', () {
      final window = RollingWindow(3);
      window.add(Float64List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9]));
      expect(window.lastN(3), [7, 8, 9]);
    });

    test('lastN can take a sub-window, as the FFT does', () {
      final window = RollingWindow(8);
      window.add(Float64List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      expect(window.lastN(3), [6, 7, 8]);
    });

    test('clear empties it', () {
      final window = RollingWindow(4);
      window.add(Float64List.fromList([1, 2, 3, 4]));
      window.clear();
      expect(window.isFull, isFalse);
      expect(window.available, 0);
    });
  });
}
