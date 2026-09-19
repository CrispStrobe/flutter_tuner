import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/transcription.dart';
import 'package:flutter_tuner/transcription_service.dart';

/// The decoding rules of the transcription mode, which is where the judgement
/// is and therefore where the mistakes are. The model itself is exercised by
/// `bench/tool/kaggle/polyphonic-eval`, against chords with ground truth.
void main() {
  group('Halfband decimator', () {
    test('halves the sample count and keeps a low tone intact', () {
      const rate = 44100.0;
      final input = Float64List(4096);
      for (int i = 0; i < input.length; i++) {
        input[i] = math.sin(2 * math.pi * 220 * i / rate);
      }
      final out = Halfband().process(input);
      expect(out.length, input.length ~/ 2);

      // A 220 Hz tone is far below the new Nyquist, so it must survive with
      // its amplitude — the filter is there for what is above 11 kHz.
      double peak = 0;
      for (int i = out.length ~/ 4; i < out.length; i++) {
        peak = math.max(peak, out[i].abs());
      }
      expect(peak, greaterThan(0.8));
    });

    test('rejects content above the new Nyquist instead of folding it down',
        () {
      const rate = 44100.0;
      final input = Float64List(4096);
      for (int i = 0; i < input.length; i++) {
        // 16 kHz: above 22.05/2, so decimating without filtering would alias
        // it back to ~6 kHz and the model would see a tone that is not there.
        input[i] = math.sin(2 * math.pi * 16000 * i / rate);
      }
      final out = Halfband().process(input);
      double peak = 0;
      for (int i = out.length ~/ 2; i < out.length; i++) {
        peak = math.max(peak, out[i].abs());
      }
      expect(peak, lessThan(0.2), reason: 'aliased through at $peak');
    });

    test('is continuous across block boundaries', () {
      const rate = 44100.0;
      final whole = Float64List(2048);
      for (int i = 0; i < whole.length; i++) {
        whole[i] = math.sin(2 * math.pi * 440 * i / rate);
      }
      final inOneGo = Halfband().process(whole);

      final streamed = Halfband();
      final first = streamed.process(Float64List.sublistView(whole, 0, 1024));
      final second = streamed.process(Float64List.sublistView(whole, 1024));

      for (int i = 0; i < first.length; i++) {
        expect(first[i], closeTo(inOneGo[i], 1e-12));
      }
      for (int i = 0; i < second.length; i++) {
        expect(second[i], closeTo(inOneGo[first.length + i], 1e-12),
            reason: 'discontinuity at the block boundary, sample $i');
      }
    });
  });

  group('BasicPitchDecoder', () {
    const frames = BasicPitchGeometry.frames;
    const bins = BasicPitchGeometry.noteBins;

    Float64List heads({Map<int, double> active = const {}}) {
      final out = Float64List(frames * bins);
      for (final entry in active.entries) {
        for (int f = 0; f < frames; f++) {
          out[f * bins + entry.key] = entry.value;
        }
      }
      return out;
    }

    test('reports the notes above the threshold, strongest first', () {
      // Bin 19 is MIDI 40 (E2); bin 28 is MIDI 49 (C#3).
      final note = heads(active: {19: 0.9, 28: 0.6, 30: 0.1});
      final onset = heads();
      final decoded = const BasicPitchDecoder().decode(note, onset);

      expect(decoded.map((n) => n.midi), [40, 49]);
      expect(decoded.first.strength, closeTo(0.9, 1e-9));
      expect(decoded.first.name, 'E2');
    });

    test('a note only just below the threshold is not reported', () {
      final decoded = const BasicPitchDecoder(noteThreshold: 0.5)
          .decode(heads(active: {19: 0.49}), heads());
      expect(decoded, isEmpty);
    });

    test('reads the end of the window, not the start', () {
      // The model is effectively causal (REPORT.md §10.1) and a live display
      // wants the newest frames; a note that stopped early must not linger.
      final note = Float64List(frames * bins);
      for (int f = 0; f < frames - 40; f++) {
        note[f * bins + 19] = 0.95; // loud, but over by the end
      }
      for (int f = frames - 8; f < frames; f++) {
        note[f * bins + 28] = 0.8; // sounding now
      }
      final decoded = const BasicPitchDecoder().decode(note, heads());
      expect(decoded.map((n) => n.midi), [49]);
    });

    test('carries the onset strength through, for new-note indication', () {
      final onset = Float64List(frames * bins);
      onset[(frames - 3) * bins + 19] = 0.77;
      final decoded =
          const BasicPitchDecoder().decode(heads(active: {19: 0.9}), onset);
      expect(decoded.single.onset, closeTo(0.77, 1e-9));
    });

    test('names and frequencies line up with MIDI', () {
      final decoded =
          const BasicPitchDecoder().decode(heads(active: {48: 0.9}), heads());
      // Bin 48 = MIDI 69 = A4 = 440 Hz.
      expect(decoded.single.midi, 69);
      expect(decoded.single.name, 'A4');
      expect(decoded.single.nominalFrequency, closeTo(440.0, 1e-9));
    });
  });

  test('the note and onset heads are not interchangeable', () {
    // Guarding a mistake that has already been made once: the ONNX export
    // names neither head, the order is not the obvious one, and scoring the
    // onset head as notes looks like a plausible-but-poor model rather than
    // like a bug.
    expect(kNoteHead, 'StatefulPartitionedCall:1');
    expect(kOnsetHead, 'StatefulPartitionedCall:2');
    expect(kNoteHead, isNot(kOnsetHead));
  });
}
