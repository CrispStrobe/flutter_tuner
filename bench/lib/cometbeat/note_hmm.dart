// lib/core/audio/transcription/note_hmm.dart
//
// S2 of the transcription pipeline: segment an S1 PitchTrack into discrete
// NoteEvents with a note-state Viterbi (a clean-room take on the pYIN note HMM /
// "Tony", Mauch et al. — NOT copied from the GPL Tony/Vamp code). This is the
// step that turns a wobbly sung/played F0 curve into notes: the model prefers to
// STAY on a note (a per-frame "switch cost"), so vibrato and brief pitch
// excursions are absorbed into one stable note instead of splitting it.
//
// States: one per MIDI note in the track's range, plus a SILENCE state.
// Emission cost of a note = how far (in cents) the frame's F0 sits from that
// note (∞-ish when the frame is unvoiced); of silence = the frame's voicing.
// Transitions: stay (free), note↔silence (boundaryCost), note→other-note
// (switchCost). Efficient: the best "from another note" source per frame is the
// global-min note cost, so each frame is O(#states), not O(#states²).

import 'dart:math';
import 'dart:typed_data';

import 'contracts.dart';

double _midiToHz(int midi, double a4) =>
    a4 * pow(2, (midi - 69) / 12).toDouble();
double _cents(double f, double ref) => 1200 * (log(f / ref) / ln2);

/// Segment [track] into notes. [voicedThreshold] gates a frame as pitched;
/// [switchCost] is the penalty to change note between frames (higher ⇒ more
/// vibrato/wobble absorbed, but real fast notes need it not too high);
/// [boundaryCost] gates note↔silence; a decoded note shorter than [minFrames]
/// windows is dropped as a glitch. [a4] is the reference tuning (see S3).
List<NoteEvent> segmentNotes(
  PitchTrack track, {
  double voicedThreshold = 0.5,
  double switchCost = 1.8,
  double boundaryCost = 0.6,
  int minFrames = 5,
  double a4 = 440,
}) {
  if (track.length < 2) return const [];

  // Voiced nearest-MIDI per frame, and the pitch range to model.
  int nearest(double hz) => (69 + 12 * (log(hz / a4) / ln2)).round();
  var lo = 1 << 30, hi = -(1 << 30);
  var anyVoiced = false;
  for (final f in track) {
    if (f.voicedProb >= voicedThreshold && f.f0Hz > 0) {
      anyVoiced = true;
      final m = nearest(f.f0Hz);
      if (m < lo) lo = m;
      if (m > hi) hi = m;
    }
  }
  if (!anyVoiced) return const [];
  final minMidi = lo - 2, maxMidi = hi + 2;
  final k = maxMidi - minMidi + 1; // note states 0..k-1
  final silence = k; // + one silence state
  final states = k + 1;

  final t0 = track.length;
  final back = List<Int32List>.generate(t0, (_) => Int32List(states));
  var prev = Float64List(states); // init 0 everywhere

  for (var t = 0; t < t0; t++) {
    final frame = track[t];
    final voiced = frame.voicedProb >= voicedThreshold && frame.f0Hz > 0;

    // Best "from another note" source = global-min note cost in prev
    // (with the second-min for the case where the min IS this note).
    var gmin = double.infinity, gmin2 = double.infinity, gArg = -1;
    for (var i = 0; i < k; i++) {
      final c = prev[i];
      if (c < gmin) {
        gmin2 = gmin;
        gmin = c;
        gArg = i;
      } else if (c < gmin2) {
        gmin2 = c;
      }
    }

    final cur = Float64List(states);
    // Note states.
    for (var i = 0; i < k; i++) {
      final midi = minMidi + i;
      final emit = voiced
          ? min(_cents(frame.f0Hz, _midiToHz(midi, a4)).abs() / 50.0, 5.0)
          : 3.0; // a voiced-note state on an unvoiced frame is costly
      // best predecessor: stay | from silence | from another note
      var bestCost = prev[i]; // stay (transition 0)
      var bestFrom = i;
      final fromSil = prev[silence] + boundaryCost;
      if (fromSil < bestCost) {
        bestCost = fromSil;
        bestFrom = silence;
      }
      final otherMin = (i == gArg) ? gmin2 : gmin;
      final fromOther = otherMin + switchCost;
      if (fromOther < bestCost) {
        bestCost = fromOther;
        bestFrom = (i == gArg) ? -2 : gArg; // -2 = "the second-best note"
      }
      cur[i] = bestCost + emit;
      back[t][i] = bestFrom;
    }
    // Silence state.
    {
      final emit = voiced ? frame.voicedProb : 0.0;
      var bestCost = prev[silence]; // stay
      var bestFrom = silence;
      final fromNote = gmin + boundaryCost;
      if (fromNote < bestCost) {
        bestCost = fromNote;
        bestFrom = gArg;
      }
      cur[silence] = bestCost + emit;
      back[t][silence] = bestFrom;
    }
    // Resolve the "-2 = second-best note" marker now that we know gArg's rank.
    for (var i = 0; i < k; i++) {
      if (back[t][i] == -2) {
        // second-best note overall — find it (rare path, O(k)).
        var s = -1;
        var sc = double.infinity;
        for (var j = 0; j < k; j++) {
          if (j == gArg) continue;
          if (prev[j] < sc) {
            sc = prev[j];
            s = j;
          }
        }
        back[t][i] = s;
      }
    }
    prev = cur;
  }

  // Terminate at the min-cost final state, backtrace the state path.
  var end = 0;
  for (var s = 1; s < states; s++) {
    if (prev[s] < prev[end]) end = s;
  }
  final path = Int32List(t0);
  var s = end;
  for (var t = t0 - 1; t >= 0; t--) {
    path[t] = s;
    s = back[t][s];
    if (s < 0) s = silence; // safety
  }

  // Runs of the same NOTE state → NoteEvents (drop < minFrames).
  final hopMs = track[1].timeMs - track[0].timeMs;
  final notes = <NoteEvent>[];
  var runStart = 0;
  for (var t = 1; t <= t0; t++) {
    if (t == t0 || path[t] != path[runStart]) {
      final st = path[runStart];
      final len = t - runStart;
      if (st != silence && len >= minFrames) {
        var conf = 0.0;
        for (var u = runStart; u < t; u++) {
          conf += track[u].voicedProb;
        }
        notes.add(
          (
            midi: minMidi + st,
            onMs: track[runStart].timeMs,
            offMs: track[t - 1].timeMs + hopMs,
            confidence: (conf / len).clamp(0.0, 1.0),
            // pYIN tracks one f0; it has no notion of timbre or instrument.
            program: gmProgramUnknown,
          ),
        );
      }
      runStart = t;
    }
  }
  return notes;
}

/// Drop subharmonic octave-error notes from a transcription.
///
/// On real recordings pYIN occasionally locks a sub-octave for a moment — during
/// a plucked note's decay, a bowed/breath transition, or a sung slide — and the
/// note-HMM emits a SHORT note an octave (or two) below the line. It's not a real
/// melodic leap: a genuine octave dip and instant return, briefer than the notes
/// around it, essentially never happens in a melody. So a short note sitting
/// ≥[octaveDrop] semitones below BOTH its neighbours (or its one neighbour at an
/// edge) is removed. This measurably cleans up real-audio output (pizzicato,
/// low-register, sung takes) while being a no-op on clean input — the octave
/// condition is what discriminates, the [maxMs] gate is a safety belt against
/// nuking a real low note in a wide-range melody.
List<NoteEvent> removeOctaveArtifacts(
  List<NoteEvent> notes, {
  int octaveDrop = 11,
  double maxMs = 150,
}) {
  if (notes.length < 2) return notes;
  final out = <NoteEvent>[];
  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    if (n.offMs - n.onMs <= maxMs) {
      final prev = i > 0 ? notes[i - 1] : null;
      final next = i < notes.length - 1 ? notes[i + 1] : null;
      final belowPrev = prev == null || prev.midi - n.midi >= octaveDrop;
      final belowNext = next == null || next.midi - n.midi >= octaveDrop;
      if (belowPrev && belowNext) continue; // a subharmonic blip — drop it
    }
    out.add(n);
  }
  return out;
}
