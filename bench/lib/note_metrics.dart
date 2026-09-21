/// Note-level transcription metrics, the way MIR actually scores a
/// transcriber.
///
/// Every table in this report so far has been **frame-level**: is this 11.6
/// ms slice's pitch right. That answers "does it hear the note" and not "does
/// it transcribe" — a system can be excellent frame by frame and still split
/// one note into nine, or merge nine into one, and frame accuracy will not
/// notice. §12 and §18 have that limitation and this module is the fix.
///
/// The rules are `mir_eval.transcription`'s, which is what published numbers
/// use:
///
///   * a reference note matches an estimate when the **onsets** are within
///     [onsetToleranceMs] (50 ms by convention), and the **pitches** within
///     [pitchToleranceCents] (50 cents);
///   * optionally the **offsets** must also agree, within the larger of
///     [offsetToleranceMs] and [offsetToleranceRatio] of the reference note's
///     duration — offsets are much less reliable than onsets, both in
///     annotations and in models, which is why the headline number in the
///     literature is the onset-only one;
///   * each reference note matches **at most one** estimate and vice versa.
///
/// That last rule is why this does a real maximum bipartite matching rather
/// than a greedy pass. Greedy-by-onset is the obvious shortcut and it
/// *undercounts*: a reference note can be claimed by an estimate that a later
/// reference needed, leaving both unmatched where a different assignment
/// would have paired them. Hopcroft–Karp-style augmenting paths give the same
/// maximum as mir_eval.
library;

import 'dart:math' as math;

/// One note, from an annotation or a transcriber.
typedef Note = ({double onsetMs, double offsetMs, double midi});

/// The outcome of scoring one set of estimates against one reference.
class NoteScore {
  int matched = 0;
  int estimated = 0;
  int reference = 0;

  /// Signed onset error of matched pairs, in ms, and pitch error in cents —
  /// kept because "it found the note" and "it found the note *on time*" are
  /// different questions and only the second says whether a transcription is
  /// usable as notation.
  final List<double> onsetErrorsMs = [];
  final List<double> pitchErrorsCents = [];

  double get precision => estimated == 0 ? 0 : matched / estimated;
  double get recall => reference == 0 ? 0 : matched / reference;
  double get f1 => precision + recall == 0
      ? 0
      : 2 * precision * recall / (precision + recall);

  void merge(NoteScore o) {
    matched += o.matched;
    estimated += o.estimated;
    reference += o.reference;
    onsetErrorsMs.addAll(o.onsetErrorsMs);
    pitchErrorsCents.addAll(o.pitchErrorsCents);
  }

  static double median(List<double> v) {
    if (v.isEmpty) return double.nan;
    final s = List<double>.of(v)..sort();
    return s[s.length ~/ 2];
  }

  static double medianAbs(List<double> v) =>
      median(v.map((x) => x.abs()).toList());
}

/// Score [estimate] against [reference].
///
/// [withOffset] adds the offset condition; leave it false for the number that
/// is comparable with published note-level F1.
NoteScore scoreNotes(
  List<Note> reference,
  List<Note> estimate, {
  double onsetToleranceMs = 50,
  double pitchToleranceCents = 50,
  bool withOffset = false,
  double offsetToleranceMs = 50,
  double offsetToleranceRatio = 0.2,
}) {
  final score = NoteScore()
    ..reference = reference.length
    ..estimated = estimate.length;
  if (reference.isEmpty || estimate.isEmpty) return score;

  // Admissible pairs. MIDI numbers are compared in cents so that a reference
  // given as a fractional MIDI (a bend, a slide) is treated the same way the
  // rest of this report treats pitch.
  final candidates = List<List<int>>.generate(reference.length, (_) => []);
  for (int r = 0; r < reference.length; r++) {
    final ref = reference[r];
    final refDur = ref.offsetMs - ref.onsetMs;
    final offTol =
        math.max(offsetToleranceMs, offsetToleranceRatio * refDur);
    for (int e = 0; e < estimate.length; e++) {
      final est = estimate[e];
      if ((est.onsetMs - ref.onsetMs).abs() > onsetToleranceMs) continue;
      if ((100 * (est.midi - ref.midi)).abs() > pitchToleranceCents) continue;
      if (withOffset && (est.offsetMs - ref.offsetMs).abs() > offTol) continue;
      candidates[r].add(e);
    }
  }

  // Maximum bipartite matching, Kuhn's algorithm with augmenting paths.
  final matchOfEstimate = List<int>.filled(estimate.length, -1);
  bool tryAssign(int r, List<bool> seen) {
    for (final e in candidates[r]) {
      if (seen[e]) continue;
      seen[e] = true;
      if (matchOfEstimate[e] == -1 || tryAssign(matchOfEstimate[e], seen)) {
        matchOfEstimate[e] = r;
        return true;
      }
    }
    return false;
  }

  for (int r = 0; r < reference.length; r++) {
    if (candidates[r].isEmpty) continue;
    tryAssign(r, List<bool>.filled(estimate.length, false));
  }

  for (int e = 0; e < estimate.length; e++) {
    final r = matchOfEstimate[e];
    if (r == -1) continue;
    score.matched++;
    score.onsetErrorsMs.add(estimate[e].onsetMs - reference[r].onsetMs);
    score.pitchErrorsCents.add(100 * (estimate[e].midi - reference[r].midi));
  }
  return score;
}

/// Frequency in Hz to fractional MIDI, for estimators that report Hz.
double midiOfHz(double hz) => 69 + 12 * (math.log(hz / 440) / math.ln2);
