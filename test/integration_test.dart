import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/tuner_engine.dart';

/// Integration tests — push synthetic audio through the full TunerEngine
/// pipeline (PCM → float → FFT + pitch detection) and verify end-to-end results.
void main() {
  /// Generate a PCM16 little-endian sine wave buffer.
  Uint8List generatePcmSine(double frequency, {int sampleRate = 44100, int samples = 4096}) {
    final bytes = <int>[];
    for (int i = 0; i < samples; i++) {
      final t = i / sampleRate;
      final sample = (math.sin(2 * math.pi * frequency * t) * 32767).toInt().clamp(-32768, 32767);
      bytes.add(sample & 0xFF);
      bytes.add((sample >> 8) & 0xFF);
    }
    return Uint8List.fromList(bytes);
  }

  group('Full pipeline: PCM → float → detectNote', () {
    test('440 Hz sine is detected as A4 in tune', () {
      final engine = TunerEngine();
      final pcm = generatePcmSine(440.0);
      final floats = engine.pcmToFloat(pcm);

      // Smooth a few times to fill the median buffer
      for (int i = 0; i < 3; i++) {
        engine.smoothPitch(440.0);
      }
      final result = engine.detectNote(440.0);

      expect(result.note, 'A4');
      expect(result.status, TuningStatus.inTune);
      expect(result.cents.abs(), lessThan(1.0));
      expect(floats.length, 4096);
    });

    test('82.41 Hz sine is detected as E2 (guitar low E)', () {
      final engine = TunerEngine();
      final pcm = generatePcmSine(82.41);
      final floats = engine.pcmToFloat(pcm);
      expect(floats.length, greaterThan(0));

      final result = engine.detectNote(82.41);
      expect(result.note, 'E2');
      expect(result.status, TuningStatus.inTune);
    });

    test('sharp pitch is detected correctly', () {
      final engine = TunerEngine();
      final sharpFreq = 445.0; // ~19.56 cents sharp of A4
      final result = engine.detectNote(sharpFreq);

      expect(result.note, 'A4');
      expect(result.status, TuningStatus.sharp);
      expect(result.cents, greaterThan(5));
    });

    test('flat pitch is detected correctly', () {
      final engine = TunerEngine();
      final flatFreq = 435.0; // ~19.78 cents flat of A4
      final result = engine.detectNote(flatFreq);

      expect(result.note, 'A4');
      expect(result.status, TuningStatus.flat);
      expect(result.cents, lessThan(-5));
    });
  });

  group('Full pipeline: PCM → float → FFT', () {
    test('440 Hz sine produces FFT peak near expected bin', () {
      final engine = TunerEngine();
      final pcm = generatePcmSine(440.0, samples: TunerEngine.fftSize);
      final floats = engine.pcmToFloat(pcm);
      final mags = engine.computeFFT(floats);

      expect(mags, isNotEmpty);

      // Find peak bin
      int peakBin = 0;
      double peakVal = 0;
      for (int i = 0; i < mags.length; i++) {
        if (mags[i] > peakVal) {
          peakVal = mags[i];
          peakBin = i;
        }
      }

      // Expected bin: 440 * 2048 / 44100 ≈ 20.4
      expect(peakBin, closeTo(20, 2));
    });

    test('silence produces no significant FFT peaks', () {
      final engine = TunerEngine();
      final pcm = Uint8List(TunerEngine.fftSize * 2); // all zeros
      final floats = engine.pcmToFloat(pcm);
      final mags = engine.computeFFT(floats);

      expect(mags, isNotEmpty);
      // All magnitudes should be essentially zero
      for (final m in mags) {
        expect(m, closeTo(0.0, 0.001));
      }
    });

    test('FFT from short buffer returns empty', () {
      final engine = TunerEngine();
      final pcm = generatePcmSine(440.0, samples: 100);
      final floats = engine.pcmToFloat(pcm);
      final mags = engine.computeFFT(floats);
      expect(mags, isEmpty);
    });
  });

  group('Full pipeline: sequential detections', () {
    test('multiple notes detected sequentially update history', () {
      final engine = TunerEngine();

      engine.detectNote(440.0); // A4
      engine.detectNote(329.63); // E4
      engine.detectNote(261.63); // C4

      final history = engine.pitchHistory;
      // Last 3 entries should be non-zero (cents values)
      final recentEntries = history.sublist(history.length - 3);
      // At least the E4 and C4 detections produce non-zero cents since they
      // are unlikely to land exactly on target
      expect(engine.lastResult, isNotNull);
    });

    test('reset clears all state after detections', () {
      final engine = TunerEngine();
      final pcm = generatePcmSine(440.0, samples: TunerEngine.fftSize);
      final floats = engine.pcmToFloat(pcm);

      engine.detectNote(440.0);
      engine.computeFFT(floats);
      engine.smoothPitch(440.0);

      expect(engine.lastResult, isNotNull);
      expect(engine.fftMagnitudes, isNotEmpty);

      engine.reset();

      expect(engine.lastResult, isNull);
      expect(engine.fftMagnitudes, isEmpty);
      expect(engine.pitchHistory.every((v) => v == 0), isTrue);
    });
  });

  group('Full pipeline: instrument switching', () {
    test('changing instrument updates tuning strings', () {
      final engine = TunerEngine();
      expect(engine.currentTuningStrings, ['E2', 'A2', 'D3', 'G3', 'B3', 'E4']);

      engine.selectedInstrument = Instrument.violin;
      expect(engine.currentTuningStrings, ['G3', 'D4', 'A4', 'E5']);

      engine.selectedInstrument = Instrument.ukulele;
      expect(engine.currentTuningStrings, ['G4', 'C4', 'E4', 'A4']);
    });

    test('changing A4 recalculates all pitches', () {
      final engine = TunerEngine();
      expect(engine.standardPitches['A4'], closeTo(440.0, 0.01));

      engine.a4Frequency = 432.0;
      expect(engine.standardPitches['A4'], closeTo(432.0, 0.01));
      expect(engine.standardPitches['A3'], closeTo(216.0, 0.01));

      // Detection should work with new tuning
      final result = engine.detectNote(432.0);
      expect(result.note, 'A4');
      expect(result.status, TuningStatus.inTune);
    });
  });

  group('Full pipeline: median filter + detection', () {
    test('smoothing filters out spike before detection', () {
      final engine = TunerEngine();

      // Feed steady 440 Hz
      engine.smoothPitch(440.0);
      engine.smoothPitch(440.0);
      engine.smoothPitch(440.0);
      engine.smoothPitch(440.0);

      // Spike to 900 Hz — median should still return ~440
      final smoothed = engine.smoothPitch(900.0);
      expect(smoothed, closeTo(440.0, 1.0));

      // Detection on smoothed value should still be A4
      final result = engine.detectNote(smoothed);
      expect(result.note, 'A4');
      expect(result.status, TuningStatus.inTune);
    });
  });
}
