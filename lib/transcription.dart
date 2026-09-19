/// Polyphonic note transcription, with **no Flutter dependency at all**.
///
/// The tuner's detector answers one question — what single note is this — and
/// `bench/REPORT.md` spends most of its length establishing that it answers
/// it well. It cannot answer a different one: *which notes*, plural. YIN and
/// MPM are monophonic by construction; on GuitarSet's chordal recordings the
/// shipped pipeline names some sounding string 21% of the time it says
/// anything at all (§6), which is not a defect to fix but the shape of the
/// algorithm.
///
/// This is the other capability, and it is deliberately a separate mode
/// rather than another detector. Spotify's Basic Pitch (Gfeller et al.,
/// ICASSP 2022) is a 35.7k-parameter CNN that emits three heads over ~11.6 ms
/// frames: a 264-bin pitch contour, an 88-bin note activation, and an 88-bin
/// onset activation. Measured against GuitarSet by the same rules as
/// everything else (§10):
///
///   * it names notes *better* than YIN — 86% raw pitch accuracy against 72%,
///     with a third of the octave errors;
///   * it cannot measure cents at all — a median error of 27 cents, against
///     YIN's 2.45, because the contour head is a posteriogram on a 33-cent
///     grid. **So the tuner's needle keeps using YIN.** This mode is for
///     naming notes, not for tuning them.
///   * it is effectively causal: frames with 0–99 ms of audio after them
///     score 92.85%, against 94.02% for frames with 1.5 s of padding, so a
///     sliding window can display its newest frame rather than waiting out
///     the model's 2-second input.
///
/// Native platforms only. The inference is pure Dart (`onnx_runtime_dart`),
/// which is what keeps this off the FFI path — but the same measurement that
/// made `fft_real.dart` necessary rules a browser out here: dart2js runs this
/// kind of numeric code tens of times slower, and a 2-second window already
/// costs ~500 ms on a native core.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'tuner_core.dart' show noteNameForMidi;

/// The model's fixed geometry, from the ONNX graph's own shapes.
class BasicPitchGeometry {
  /// The graph's input length, in samples at [sampleRate].
  static const int windowSamples = 43844;

  /// The model wants 22.05 kHz; the app captures at 44.1.
  static const int sampleRate = 22050;

  /// Output frames per window, and the hop between them.
  static const int frames = 172;
  static const int frameHop = 256;

  /// The note and onset heads cover the 88 keys of a piano, MIDI 21 (A0) to
  /// 108 (C8).
  static const int noteBins = 88;
  static const int lowestMidi = 21;

  static const int contourBins = 264;

  static double frameSeconds(int frame) => frame * frameHop / sampleRate;
}

/// One note the model believes is sounding.
class TranscribedNote {
  final int midi;

  /// Mean note-head activation over the frames considered, in [0, 1].
  final double strength;

  /// Peak onset activation — high means the note *started* in this window,
  /// which is what distinguishes a new note from one still ringing.
  final double onset;

  const TranscribedNote(this.midi, this.strength, this.onset);

  String get name => noteNameForMidi(midi);

  /// Equal-tempered frequency at A440, for display next to the tuner's own
  /// reading. Deliberately not offered as a tuning target: the model's pitch
  /// resolution is 33 cents (see the library comment).
  double get nominalFrequency =>
      440 * math.pow(2, (midi - 69) / 12).toDouble();
}

/// What one inference produced.
class TranscriptionResult {
  /// Notes sounding at the end of the window, strongest first.
  final List<TranscribedNote> notes;

  /// How long the inference took. Worth surfacing: on a slow device this is
  /// the whole story of whether the mode is usable.
  final Duration elapsed;

  const TranscriptionResult(this.notes, this.elapsed);

  static const empty = TranscriptionResult(<TranscribedNote>[], Duration.zero);

  bool get isEmpty => notes.isEmpty;
}

/// Decimates 44.1 kHz to the 22.05 kHz the model expects.
///
/// Dropping every other sample without filtering would fold everything above
/// 11 kHz back down into the band the model reads. A modest windowed-sinc
/// low-pass first is cheap and keeps that out.
class Halfband {
  final Float64List _taps;
  final Float64List _history;
  int _historyIndex = 0;

  Halfband({int taps = 31})
      : _taps = Float64List(taps),
        _history = Float64List(taps) {
    // Windowed sinc at a quarter of the sample rate, Hamming-windowed.
    final centre = (taps - 1) / 2.0;
    double sum = 0;
    for (int i = 0; i < taps; i++) {
      final x = i - centre;
      final sinc = x == 0 ? 0.5 : math.sin(math.pi * x * 0.5) / (math.pi * x);
      final window =
          0.54 - 0.46 * math.cos(2 * math.pi * i / (taps - 1));
      _taps[i] = sinc * window;
      sum += _taps[i];
    }
    for (int i = 0; i < taps; i++) {
      _taps[i] /= sum; // unity gain at DC
    }
  }

  /// Filter and decimate by two. Keeps filter state across calls so a
  /// streamed signal has no discontinuity at block boundaries.
  Float64List process(List<double> input) {
    final out = Float64List(input.length ~/ 2);
    int written = 0;
    for (int i = 0; i < input.length; i++) {
      _history[_historyIndex] = input[i];
      _historyIndex = (_historyIndex + 1) % _history.length;
      if (i.isOdd && written < out.length) {
        double acc = 0;
        int h = _historyIndex;
        for (int t = 0; t < _taps.length; t++) {
          acc += _taps[t] * _history[h];
          h = (h + 1) % _history.length;
        }
        out[written++] = acc;
      }
    }
    return written == out.length ? out : Float64List.sublistView(out, 0, written);
  }

  void reset() {
    for (int i = 0; i < _history.length; i++) {
      _history[i] = 0;
    }
    _historyIndex = 0;
  }
}

/// Turns the model's three output heads into notes.
///
/// Kept separate from inference so it can be tested without a model: the
/// decoding rules are where the judgement is, and they are the part most
/// likely to be wrong.
class BasicPitchDecoder {
  /// Note-head activation a note must reach to be reported.
  ///
  /// Measured on GuitarSet's chordal recordings, 128,558 reference frames
  /// (bench/REPORT.md §12):
  ///
  /// | threshold | precision | recall | F1 |
  /// | --- | --- | --- | --- |
  /// | 0.3 | 81.3% | 80.1% | **80.7%** |
  /// | 0.4 | 86.7% | 72.0% | 78.7% |
  /// | 0.5 | 90.3% | 61.3% | 73.0% |
  /// | 0.7 | 95.0% | 27.7% | 42.9% |
  ///
  /// 0.3 maximises F1, but a display is not an F1 score: a note shown that
  /// is not being played is a worse error than one missed, because the
  /// player can see what they are holding. 0.4 keeps 87% precision for a
  /// tenth of the recall — that is the trade taken here, and it is a
  /// one-line change if you disagree.
  final double noteThreshold;

  /// Activation a note already sounding must stay above to *keep* sounding.
  ///
  /// A single threshold treats every frame independently, so a note whose
  /// activation dips for two frames is reported as having stopped and
  /// started. Real notes do not do that; the activation does. This is the
  /// standard Schmitt-trigger answer — a high bar to start, a lower one to
  /// continue — and it is why §17 found CrispASR recalling eight points more
  /// notes for the same model: it emits segmented note *events*, and an
  /// event spans the dip.
  ///
  /// Defaults to [noteThreshold], which is exactly the old behaviour.
  /// `null` is not accepted: the equality is the point, so that turning
  /// hysteresis off is a value rather than a code path.
  final double sustainThreshold;

  /// Onset activation above which a note is called newly struck.
  final double onsetThreshold;

  /// How many frames at the end of the window to read. The model is
  /// effectively causal (§10.1), so the newest frames are as good as any —
  /// averaging a handful of them steadies the display without adding lag
  /// worth noticing: 8 frames is 93 ms.
  final int tailFrames;

  /// The default, named so a second backend can describe the same instant.
  /// `CrispAsrBackend` keeps only note events still sounding in this many
  /// frames at the end of its window, so switching runtimes does not shift
  /// when a note appears.
  static const int defaultTailFrames = 8;

  const BasicPitchDecoder({
    this.noteThreshold = 0.4,
    double? sustainThreshold,
    this.onsetThreshold = 0.5,
    this.tailFrames = defaultTailFrames,
  }) : sustainThreshold = sustainThreshold ?? noteThreshold;

  /// Decode a whole window frame by frame, with hysteresis across frames.
  ///
  /// Returns one set of MIDI numbers per frame. This is the *sequence*
  /// decode — it sees a note's history, which [decode] cannot, because
  /// [decode] answers "what is sounding now" from a tail average and has no
  /// past to consult.
  ///
  /// [carry] is the set sounding at the end of the previous window, so a
  /// streamed sequence of windows decodes as one signal rather than as
  /// independent fragments. Pass null at the start.
  List<Set<int>> decodeFrames(Float64List note,
      {int frames = BasicPitchGeometry.frames, Set<int>? carry}) {
    const bins = BasicPitchGeometry.noteBins;
    final out = <Set<int>>[];
    final sounding = <int>{...?carry};
    for (int f = 0; f < frames; f++) {
      for (int b = 0; b < bins; b++) {
        final midi = BasicPitchGeometry.lowestMidi + b;
        final a = note[f * bins + b];
        if (sounding.contains(midi)) {
          if (a < sustainThreshold) sounding.remove(midi);
        } else if (a >= noteThreshold) {
          sounding.add(midi);
        }
      }
      out.add(Set<int>.of(sounding));
    }
    return out;
  }

  /// [note] and [onset] are `frames × 88`, row-major.
  List<TranscribedNote> decode(Float64List note, Float64List onset,
      {int frames = BasicPitchGeometry.frames}) {
    const bins = BasicPitchGeometry.noteBins;
    final from = math.max(0, frames - tailFrames);
    final count = frames - from;
    if (count <= 0) return const [];

    final found = <TranscribedNote>[];
    for (int b = 0; b < bins; b++) {
      double sum = 0;
      double peakOnset = 0;
      for (int f = from; f < frames; f++) {
        sum += note[f * bins + b];
        final o = onset[f * bins + b];
        if (o > peakOnset) peakOnset = o;
      }
      final strength = sum / count;
      if (strength >= noteThreshold) {
        found.add(TranscribedNote(
            BasicPitchGeometry.lowestMidi + b, strength, peakOnset));
      }
    }
    found.sort((a, b) => b.strength.compareTo(a.strength));
    return found;
  }
}
