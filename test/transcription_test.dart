import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/crispasr_backend.dart';
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

  group('BasicPitchDecoder.decodeFrames', () {
    // 3 frames x 88 bins, one bin (MIDI 60 = bin 39) dipping in the middle.
    Float64List activations(List<double> perFrame) {
      const bins = BasicPitchGeometry.noteBins;
      final out = Float64List(perFrame.length * bins);
      for (int f = 0; f < perFrame.length; f++) {
        out[f * bins + (60 - BasicPitchGeometry.lowestMidi)] = perFrame[f];
      }
      return out;
    }

    test('without hysteresis a dip stops the note', () {
      // BasicPitchDecoder.stateless is how this shipped before §18: one
      // threshold, every frame judged alone.
      final seq = BasicPitchDecoder.stateless
          .decodeFrames(activations([0.9, 0.25, 0.9]), frames: 3);
      expect(seq.map((s) => s.contains(60)).toList(), [true, false, true]);
    });

    test('a sustain threshold spans the dip', () {
      final seq =
          const BasicPitchDecoder(noteThreshold: 0.4, sustainThreshold: 0.2)
              .decodeFrames(activations([0.9, 0.25, 0.9]), frames: 3);
      expect(seq.map((s) => s.contains(60)).toList(), [true, true, true]);
    });

    test('a dip below the sustain threshold still ends the note', () {
      final seq =
          const BasicPitchDecoder(noteThreshold: 0.4, sustainThreshold: 0.2)
              .decodeFrames(activations([0.9, 0.1, 0.9]), frames: 3);
      expect(seq.map((s) => s.contains(60)).toList(), [true, false, true]);
    });

    test('a note below the start threshold never starts, however long', () {
      // Hysteresis must not lower the bar for *starting* — otherwise it
      // would buy recall by inventing notes rather than by sustaining them.
      final seq =
          const BasicPitchDecoder(noteThreshold: 0.4, sustainThreshold: 0.2)
              .decodeFrames(activations([0.3, 0.35, 0.3]), frames: 3);
      expect(seq.every((s) => s.isEmpty), isTrue);
    });

    test('carry continues a note across a window boundary', () {
      final seq =
          const BasicPitchDecoder(noteThreshold: 0.4, sustainThreshold: 0.2)
              .decodeFrames(activations([0.25]), frames: 1, carry: {60});
      expect(seq.single, contains(60));
    });

    test('the defaults are the measured pair, not a single threshold', () {
      // 0.5/0.25 was chosen in bench/REPORT.md §18 because it is strictly
      // better than the old 0.4/0.4 on BOTH precision and recall over all
      // 180 chordal files. If someone collapses these back to one value,
      // that is a regression rather than a simplification.
      const d = BasicPitchDecoder();
      expect(d.noteThreshold, 0.5);
      expect(d.sustainThreshold, 0.25);
      expect(d.sustainThreshold, lessThan(d.noteThreshold),
          reason: 'a Schmitt trigger needs the bars to differ');
      expect(BasicPitchDecoder.stateless.sustainThreshold,
          BasicPitchDecoder.stateless.noteThreshold);
    });
  });

  group('LiveNoteTracker', () {
    Float64List heads(List<double> perFrame) {
      const bins = BasicPitchGeometry.noteBins;
      final out = Float64List(perFrame.length * bins);
      for (int f = 0; f < perFrame.length; f++) {
        out[f * bins + (60 - BasicPitchGeometry.lowestMidi)] = perFrame[f];
      }
      return out;
    }

    test('a note dipping across a window boundary stays one note', () {
      final tracker = LiveNoteTracker();
      final zeros = Float64List(4 * BasicPitchGeometry.noteBins);
      // Window one ends with the note sounding strongly.
      tracker.track(heads([0.9, 0.9, 0.9, 0.9]), zeros, frames: 4);
      // Window two is entirely in the dip — above sustain, below start.
      final notes =
          tracker.track(heads([0.3, 0.3, 0.3, 0.3]), zeros, frames: 4);
      expect(notes.map((n) => n.midi), contains(60),
          reason: 'the carry set is what makes this survive the boundary');
    });

    test('reset forgets a held note', () {
      final tracker = LiveNoteTracker();
      final zeros = Float64List(4 * BasicPitchGeometry.noteBins);
      tracker.track(heads([0.9, 0.9, 0.9, 0.9]), zeros, frames: 4);
      tracker.reset();
      final notes =
          tracker.track(heads([0.3, 0.3, 0.3, 0.3]), zeros, frames: 4);
      expect(notes, isEmpty);
    });

    test('a note sounding in a minority of the tail is not reported', () {
      // Hysteresis makes one frame decisive; the majority rule is what stops
      // that turning into a flickering display.
      final tracker = LiveNoteTracker();
      final zeros = Float64List(4 * BasicPitchGeometry.noteBins);
      final notes =
          tracker.track(heads([0.0, 0.0, 0.0, 0.9]), zeros, frames: 4);
      expect(notes, isEmpty);
    });
  });

  group('poolWorkersFor', () {
    test('never returns one — one worker is worse than none', () {
      // A single worker pays the per-conv message copy and gains no
      // parallelism, so it is strictly worse than not pooling at all.
      for (int cores = 1; cores <= 64; cores++) {
        expect(poolWorkersFor(cores), greaterThanOrEqualTo(2),
            reason: 'cores=$cores');
      }
    });

    test('caps at four, where the CI measurements stopped improving', () {
      expect(poolWorkersFor(4), 4);
      expect(poolWorkersFor(8), 4);
      expect(poolWorkersFor(64), 4);
    });

    test('a small machine still pools', () {
      expect(poolWorkersFor(1), 2);
      expect(poolWorkersFor(2), 2);
      expect(poolWorkersFor(3), 3);
    });
  });

  group('TranscriptionPacing', () {
    const pacing = TranscriptionPacing();

    test('backs off only after the answer repeats', () {
      expect(pacing.hopFor(0), pacing.activeHop);
      expect(pacing.hopFor(2), pacing.activeHop);
      expect(pacing.hopFor(3), pacing.idleHop);
      expect(pacing.hopFor(99), pacing.idleHop);
    });

    test('the backoff is bounded, because looking is the only way to know', () {
      // A newly played note waits at most idleHop before anything looks for
      // it. Two seconds is a deliberate ceiling, not an accident of tuning.
      expect(pacing.idleHop,
          lessThanOrEqualTo(BasicPitchGeometry.sampleRate * 2));
      expect(pacing.idleHop, greaterThan(pacing.activeHop));
    });

    test('silence is skipped and a quiet note is not', () {
      final silence = List<double>.filled(4096, 0.0);
      expect(pacing.isSilent(silence), isTrue);

      // -46 dBFS: quiet, but a real string.
      final quiet = List<double>.generate(
          4096, (i) => 0.005 * math.sin(2 * math.pi * 196 * i / 22050));
      expect(pacing.isSilent(quiet), isFalse,
          reason: 'the silence gate must not swallow softly played notes');
    });

    test('an empty window counts as silence rather than throwing', () {
      expect(pacing.isSilent(const <double>[]), isTrue);
    });

    test('sameNotes compares the answer, not the activations', () {
      const a = [TranscribedNote(60, 0.9, 0.1), TranscribedNote(64, 0.8, 0.0)];
      const b = [TranscribedNote(60, 0.5, 0.9), TranscribedNote(64, 0.4, 0.2)];
      const c = [TranscribedNote(60, 0.9, 0.1), TranscribedNote(67, 0.8, 0.0)];
      expect(TranscriptionPacing.sameNotes(a, b), isTrue,
          reason: 'strengths move every frame; the notes did not change');
      expect(TranscriptionPacing.sameNotes(a, c), isFalse);
      expect(TranscriptionPacing.sameNotes(a, const []), isFalse);
    });
  });

  // --- the second runtime ------------------------------------------------
  //
  // CrispASR's ggml arm is measured in bench/REPORT.md §17 and implemented
  // behind a conditional export, so what a test can assert here is the
  // contract rather than the inference: that an unconfigured backend is
  // honestly unavailable, and that the two runtimes describe the same
  // instant.
  group('CrispAsrBackend', () {
    test('reports itself unavailable when nothing is configured', () {
      expect(CrispAsrBackend.fromEnvironment(), isNull,
          reason: 'no CRISPTUNER_BASIC_PITCH_GGUF in a test run');
      expect(CrispAsrBackend(modelPath: '/nonexistent/basic-pitch.gguf')
          .isAvailable, isFalse);
    });

    test('agrees with the ONNX backend on geometry', () {
      final ggml = CrispAsrBackend();
      final onnx = TranscriptionService();
      expect(ggml.inputSampleRate, onnx.inputSampleRate);
      expect(ggml.windowSamples, onnx.windowSamples);
      expect(ggml.id, isNot(onnx.id));
    });

    test('shares the tail length that defines "now"', () {
      // The ggml backend keeps events sounding in the last
      // defaultTailFrames worth of audio; the ONNX decoder averages the same
      // frames. If these drift apart, one backend shows notes earlier than
      // the other for no reason a user could understand.
      expect(const BasicPitchDecoder().tailFrames,
          BasicPitchDecoder.defaultTailFrames);
    });
  });
}
