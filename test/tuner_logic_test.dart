import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/tuner_engine.dart';

void main() {
  group('Instrument enum', () {
    test('has all expected instruments', () {
      for (final expected in [
        Instrument.guitar,
        Instrument.guitar7,
        Instrument.bass,
        Instrument.bass5,
        Instrument.ukulele,
        Instrument.banjo,
        Instrument.mandolin,
        Instrument.violin,
        Instrument.viola,
        Instrument.cello,
        Instrument.doubleBass,
      ]) {
        expect(Instrument.values, contains(expected));
      }
    });
  });

  group('TunerEngine construction', () {
    test('defaults to A4 = 440 Hz', () {
      final engine = TunerEngine();
      expect(engine.a4Frequency, 440.0);
    });

    test('defaults to guitar', () {
      final engine = TunerEngine();
      expect(engine.selectedInstrument, Instrument.guitar);
    });

    test('accepts custom A4 frequency', () {
      final engine = TunerEngine(a4Frequency: 432.0);
      expect(engine.a4Frequency, 432.0);
    });

    test('pitch history is initialized to zeros', () {
      final engine = TunerEngine(historySize: 50);
      expect(engine.pitchHistory.length, 50);
      expect(engine.pitchHistory.every((v) => v == 0), isTrue);
    });

    test('lastResult is null initially', () {
      final engine = TunerEngine();
      expect(engine.lastResult, isNull);
    });

    test('fftMagnitudes is empty initially', () {
      final engine = TunerEngine();
      expect(engine.fftMagnitudes, isEmpty);
    });
  });

  group('Instrument tunings', () {
    Tuning standardOf(Instrument instrument) =>
        tuningFor(instrument, 'standard');

    test('guitar standard is EADGBE', () {
      expect(standardOf(Instrument.guitar).strings,
          ['E2', 'A2', 'D3', 'G3', 'B3', 'E4']);
    });

    test('violin standard is GDAE', () {
      expect(standardOf(Instrument.violin).strings, ['G3', 'D4', 'A4', 'E5']);
    });

    test('cello standard is CGDA', () {
      expect(standardOf(Instrument.cello).strings, ['C2', 'G2', 'D3', 'A3']);
    });

    test('bass standard is EADG', () {
      expect(standardOf(Instrument.bass).strings, ['E1', 'A1', 'D2', 'G2']);
    });

    test('ukulele standard is reentrant GCEA', () {
      expect(standardOf(Instrument.ukulele).strings, ['G4', 'C4', 'E4', 'A4']);
    });

    test('mandolin standard is GDAE', () {
      expect(standardOf(Instrument.mandolin).strings, ['G3', 'D4', 'A4', 'E5']);
    });

    test('drop D lowers only the sixth string', () {
      final standard = standardOf(Instrument.guitar).strings;
      final dropD = tuningFor(Instrument.guitar, 'dropD').strings;
      expect(dropD.first, 'D2');
      expect(dropD.sublist(1), standard.sublist(1));
    });

    test('DADGAD is D A D G A D', () {
      expect(tuningFor(Instrument.guitar, 'dadgad').strings,
          ['D2', 'A2', 'D3', 'G3', 'A3', 'D4']);
    });

    test('half step down is every string one semitone below standard', () {
      final standard = standardOf(Instrument.guitar).strings;
      final lowered = tuningFor(Instrument.guitar, 'halfStepDown').strings;
      expect(lowered.length, standard.length);
      for (int i = 0; i < standard.length; i++) {
        expect(TunerEngine.midiForNoteName(lowered[i]),
            TunerEngine.midiForNoteName(standard[i])! - 1,
            reason: 'string ${i + 1}');
      }
    });

    test('every instrument has at least one tuning, standard first', () {
      for (final instrument in Instrument.values) {
        final tunings = tuningsFor(instrument);
        expect(tunings, isNotEmpty, reason: instrument.name);
        // The banjo's conventional home tuning is open G, not "standard".
        expect(tunings.first.id, anyOf('standard', 'openG'),
            reason: instrument.name);
      }
    });

    test('tuning ids are unique within an instrument', () {
      for (final instrument in Instrument.values) {
        final ids = tuningsFor(instrument).map((t) => t.id).toList();
        expect(ids.toSet().length, ids.length, reason: instrument.name);
      }
    });

    test('no tuning uses the reserved custom id', () {
      for (final instrument in Instrument.values) {
        for (final tuning in tuningsFor(instrument)) {
          expect(tuning.id, isNot(customTuningId), reason: instrument.name);
        }
      }
    });

    test('every string of every tuning is a note the engine can resolve', () {
      for (final instrument in Instrument.values) {
        for (final tuning in tuningsFor(instrument)) {
          for (final note in tuning.strings) {
            final midi = TunerEngine.midiForNoteName(note);
            expect(midi, isNotNull,
                reason: '$note (${instrument.name}/${tuning.id})');
            expect(midi, inInclusiveRange(
                TunerEngine.minMidi, TunerEngine.maxMidi),
                reason: '$note (${instrument.name}/${tuning.id})');
            expect(TunerEngine.noteOffsets.containsKey(note), isTrue,
                reason: '$note (${instrument.name}/${tuning.id})');
          }
        }
      }
    });

    test('unknown tuning id falls back to the instrument standard', () {
      expect(tuningFor(Instrument.viola, 'dadgad').id, 'standard');
    });
  });

  group('currentTuningStrings', () {
    test('returns guitar strings by default', () {
      final engine = TunerEngine();
      expect(engine.currentTuningStrings, ['E2', 'A2', 'D3', 'G3', 'B3', 'E4']);
    });

    test('returns correct strings after instrument change', () {
      final engine = TunerEngine();
      engine.selectedInstrument = Instrument.violin;
      expect(engine.currentTuningStrings, ['G3', 'D4', 'A4', 'E5']);
    });
  });

  group('Standard pitch calculation', () {
    test('A4 is 440 Hz at default tuning', () {
      final engine = TunerEngine();
      expect(engine.standardPitches['A4'], closeTo(440.0, 0.01));
    });

    test('A3 is 220 Hz', () {
      final engine = TunerEngine();
      expect(engine.standardPitches['A3'], closeTo(220.0, 0.01));
    });

    test('A5 is 880 Hz', () {
      final engine = TunerEngine();
      expect(engine.standardPitches['A5'], closeTo(880.0, 0.01));
    });

    test('E2 (guitar low E) is ~82.41 Hz', () {
      final engine = TunerEngine();
      expect(engine.standardPitches['E2'], closeTo(82.41, 0.01));
    });

    test('C4 (middle C) is ~261.63 Hz', () {
      final engine = TunerEngine();
      expect(engine.standardPitches['C4'], closeTo(261.63, 0.01));
    });

    test('pitches recalculate when A4 changes', () {
      final engine = TunerEngine();
      engine.a4Frequency = 432.0;
      expect(engine.standardPitches['A4'], closeTo(432.0, 0.01));
      expect(engine.standardPitches['A3'], closeTo(216.0, 0.01));
    });

    test('getFrequencyForNote returns correct value', () {
      final engine = TunerEngine();
      expect(engine.getFrequencyForNote('A4'), closeTo(440.0, 0.01));
    });

    test('getFrequencyForNote returns null for unknown note', () {
      final engine = TunerEngine();
      expect(engine.getFrequencyForNote('Z9'), isNull);
    });
  });

  group('TunerEngine.computeCents', () {
    test('exact pitch gives 0 cents', () {
      expect(TunerEngine.computeCents(440.0, 440.0), closeTo(0.0, 0.001));
    });

    test('one semitone sharp gives +100 cents', () {
      final sharp = 440.0 * math.pow(2, 1 / 12.0);
      expect(TunerEngine.computeCents(sharp, 440.0), closeTo(100.0, 0.01));
    });

    test('one semitone flat gives -100 cents', () {
      final flat = 440.0 * math.pow(2, -1 / 12.0);
      expect(TunerEngine.computeCents(flat, 440.0), closeTo(-100.0, 0.01));
    });

    test('octave up gives +1200 cents', () {
      expect(TunerEngine.computeCents(880.0, 440.0), closeTo(1200.0, 0.01));
    });

    test('+5 Hz from 440 gives ~19.56 cents', () {
      expect(TunerEngine.computeCents(445.0, 440.0), closeTo(19.56, 0.1));
    });

    test('-5 Hz from 440 gives ~-19.78 cents', () {
      expect(TunerEngine.computeCents(435.0, 440.0), closeTo(-19.78, 0.1));
    });

    test('returns 0 for zero target', () {
      expect(TunerEngine.computeCents(440.0, 0.0), 0.0);
    });

    test('returns 0 for zero detected', () {
      expect(TunerEngine.computeCents(0.0, 440.0), 0.0);
    });
  });

  group('detectNote', () {
    late TunerEngine engine;

    setUp(() {
      engine = TunerEngine();
    });

    test('detects A4 at 440 Hz as in tune', () {
      final result = engine.detectNote(440.0);
      expect(result.note, 'A4');
      expect(result.status, TuningStatus.inTune);
      expect(result.cents, closeTo(0.0, 0.1));
    });

    test('detects A4 slightly sharp', () {
      final result = engine.detectNote(445.0);
      expect(result.note, 'A4');
      expect(result.status, TuningStatus.sharp);
      expect(result.cents, greaterThan(5));
    });

    test('detects A4 slightly flat', () {
      final result = engine.detectNote(435.0);
      expect(result.note, 'A4');
      expect(result.status, TuningStatus.flat);
      expect(result.cents, lessThan(-5));
    });

    test('detects E2 for guitar low E', () {
      final result = engine.detectNote(82.41);
      expect(result.note, 'E2');
      expect(result.status, TuningStatus.inTune);
    });

    test('returns empty for zero pitch', () {
      final result = engine.detectNote(0.0);
      expect(result.isEmpty, isTrue);
      expect(result.status, TuningStatus.idle);
    });

    test('returns empty for negative pitch', () {
      final result = engine.detectNote(-100.0);
      expect(result.isEmpty, isTrue);
    });

    test('updates lastResult', () {
      engine.detectNote(440.0);
      expect(engine.lastResult, isNotNull);
      expect(engine.lastResult!.note, 'A4');
    });

    test('updates pitch history', () {
      // Detect a note that is NOT exactly in tune so the cents value is non-zero
      engine.detectNote(445.0); // ~19.56 cents sharp
      final history = engine.pitchHistory;
      // The last entry should be the clamped cents value, not zero
      expect(history.last, isNot(0.0));
    });

    test('history stays bounded by the configured historySize', () {
      // Regression: the bound was hardcoded to 100, so any engine built with a
      // different historySize grew without limit on every detection.
      final small = TunerEngine(historySize: 10);
      for (int i = 0; i < 200; i++) {
        small.detectNote(440.0 + i % 7);
      }
      expect(small.pitchHistory.length, 10);
    });

    test('history stays bounded at the default size too', () {
      final defaultEngine = TunerEngine();
      for (int i = 0; i < 250; i++) {
        defaultEngine.detectNote(440.0 + i % 7);
      }
      expect(defaultEngine.pitchHistory.length, 100);
    });
  });

  group('NoteDetectionResult', () {
    test('displayNote strips octave number', () {
      const result = NoteDetectionResult(
        note: 'A#4',
        pitch: 466.16,
        cents: 0,
        targetFrequency: 466.16,
        status: TuningStatus.inTune,
      );
      expect(result.displayNote, 'A#');
    });


    test('isEmpty is true for empty result', () {
      expect(NoteDetectionResult.empty().isEmpty, isTrue);
    });

    test('isEmpty is false for real result', () {
      const result = NoteDetectionResult(
        note: 'A4', pitch: 440, cents: 0, targetFrequency: 440,
        status: TuningStatus.inTune,
      );
      expect(result.isEmpty, isFalse);
    });
  });

  group('smoothPitch (median filter)', () {
    test('returns raw pitch when buffer has fewer than 3 samples', () {
      final engine = TunerEngine();
      expect(engine.smoothPitch(440.0), 440.0);
      expect(engine.smoothPitch(445.0), 445.0);
    });

    test('returns median of buffer', () {
      final engine = TunerEngine();
      engine.smoothPitch(440.0);
      engine.smoothPitch(445.0);
      final result = engine.smoothPitch(442.0);
      // Sorted: [440, 442, 445], median = 442
      expect(result, 442.0);
    });

    test('filters out spike values', () {
      final engine = TunerEngine();
      engine.smoothPitch(440.0);
      engine.smoothPitch(440.0);
      engine.smoothPitch(440.0);
      engine.smoothPitch(440.0);
      // Spike
      final result = engine.smoothPitch(900.0);
      // Buffer: [440, 440, 440, 440, 900], sorted median = 440
      expect(result, 440.0);
    });
  });

  group('pcmToFloat', () {
    test('converts silence (zeros) correctly', () {
      final engine = TunerEngine();
      final pcm = Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0]);
      final result = engine.pcmToFloat(pcm);
      expect(result.length, 4);
      expect(result.every((v) => v == 0.0), isTrue);
    });

    test('converts max positive sample correctly', () {
      final engine = TunerEngine();
      // Max positive 16-bit sample = 32767 = 0xFF7F (little-endian: 0xFF, 0x7F)
      final pcm = Uint8List.fromList([0xFF, 0x7F]);
      final result = engine.pcmToFloat(pcm);
      expect(result.length, 1);
      expect(result[0], closeTo(1.0, 0.001));
    });

    test('converts negative sample correctly', () {
      final engine = TunerEngine();
      // -1 in 16-bit signed = 0xFFFF (little-endian: 0xFF, 0xFF)
      final pcm = Uint8List.fromList([0xFF, 0xFF]);
      final result = engine.pcmToFloat(pcm);
      expect(result.length, 1);
      expect(result[0], closeTo(-1 / 32768.0, 0.001));
    });

    test('empty input returns empty output', () {
      final engine = TunerEngine();
      final result = engine.pcmToFloat(Uint8List(0));
      expect(result.length, 0);
    });
  });

  group('computeFFT', () {
    test('returns empty for too-short input', () {
      final engine = TunerEngine();
      final result = engine.computeFFT(Float64List(100));
      expect(result, isEmpty);
    });

    test('returns non-empty for valid input', () {
      final engine = TunerEngine();
      // Generate a simple sine wave
      final samples = Float64List(TunerEngine.fftSize);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = math.sin(2 * math.pi * 440 * i / 44100.0);
      }
      final result = engine.computeFFT(samples);
      expect(result, isNotEmpty);
      expect(result.any((v) => v > 0), isTrue);
    });

    test('peak is near expected bin for 440Hz sine', () {
      final engine = TunerEngine();
      final samples = Float64List(TunerEngine.fftSize);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = math.sin(2 * math.pi * 440 * i / 44100.0);
      }
      final result = engine.computeFFT(samples);

      // Expected bin for 440Hz: bin = 440 * fftSize / sampleRate = 440 * 2048 / 44100 ≈ 20.4
      int peakBin = 0;
      double peakVal = 0;
      for (int i = 0; i < result.length; i++) {
        if (result[i] > peakVal) {
          peakVal = result[i];
          peakBin = i;
        }
      }
      expect(peakBin, closeTo(20, 2));
    });

    test('updates fftMagnitudes property', () {
      final engine = TunerEngine();
      expect(engine.fftMagnitudes, isEmpty);
      final samples = Float64List(TunerEngine.fftSize);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = math.sin(2 * math.pi * 440 * i / 44100.0);
      }
      engine.computeFFT(samples);
      expect(engine.fftMagnitudes, isNotEmpty);
    });
  });

  group('stripOctave', () {
    test('strips single digit', () {
      expect(TunerEngine.stripOctave('A4'), 'A');
    });

    test('strips from sharp note', () {
      expect(TunerEngine.stripOctave('C#3'), 'C#');
    });

    test('handles note without octave', () {
      expect(TunerEngine.stripOctave('G'), 'G');
    });
  });

  group('reset', () {
    test('clears lastResult', () {
      final engine = TunerEngine();
      engine.detectNote(440.0);
      expect(engine.lastResult, isNotNull);
      engine.reset();
      expect(engine.lastResult, isNull);
    });

    test('clears fftMagnitudes', () {
      final engine = TunerEngine();
      final samples = Float64List(TunerEngine.fftSize);
      engine.computeFFT(samples);
      engine.reset();
      expect(engine.fftMagnitudes, isEmpty);
    });

    test('zeros out pitch history', () {
      final engine = TunerEngine(historySize: 10);
      engine.detectNote(440.0);
      engine.reset();
      expect(engine.pitchHistory.every((v) => v == 0), isTrue);
    });
  });

  group('Note offset map completeness', () {
    test('A4 offset is 0', () {
      expect(TunerEngine.noteOffsets['A4'], 0);
    });

    test('offsets are consecutive', () {
      final sorted = TunerEngine.noteOffsets.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (int i = 1; i < sorted.length; i++) {
        expect(sorted[i].value - sorted[i - 1].value, 1,
            reason: '${sorted[i].key} should be 1 semitone after ${sorted[i - 1].key}');
      }
    });

    test('contains all 12 chromatic notes per octave (1-5)', () {
      final noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
      for (int octave = 1; octave <= 5; octave++) {
        for (final name in noteNames) {
          expect(TunerEngine.noteOffsets.containsKey('$name$octave'), isTrue,
              reason: '$name$octave should be in noteOffsets');
        }
      }
    });
  });
}
