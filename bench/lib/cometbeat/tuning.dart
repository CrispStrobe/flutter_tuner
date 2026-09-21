// lib/core/audio/transcription/tuning.dart
//
// S3 of the transcription pipeline: estimate the recording's global tuning
// offset in cents, so the note-HMM (S2) quantises to the scale the performer
// ACTUALLY sang, not to a rigid A=440 grid.
//
// Why this matters (proven on real audio, see bin/listen.dart --transcribe): a
// human singer rarely lands on equal-tempered A440. If their tonic sits, say,
// 40 cents below our grid, every note rounds toward the wrong chromatic
// neighbour and the transcription smears (C reads as B, D as C#, …). Shifting
// the reference by the estimated offset first makes the SAME notes snap to one
// consistent diatonic scale.
//
// Method (clean-room, no external code): each voiced frame's F0 has a "pitch
// residual" — how far, in cents, it sits from the nearest equal-tempered note.
// A consistent global mistuning shows up as those residuals clustering around a
// single non-zero value. We take the (voicing-weighted) CIRCULAR mean of the
// residuals on the ±50-cent circle — circular because +49 c and −49 c are 2 c
// apart, not 98. That is robust to vibrato and to the odd octave glitch, and
// needs no key detection.

import 'dart:math';

import 'contracts.dart';

/// Estimate the global tuning offset of [track] in cents relative to [a4]
/// (positive ⇒ the performance is sharp of the A440 grid). Returns 0 when there
/// is nothing voiced to measure. The result is the number you'd add to every
/// note's reference — e.g. feed `a4 * 2^(cents/1200)` to [segmentNotes].
double estimateTuningCents(
  PitchTrack track, {
  double a4 = 440,
  double voicedThreshold = 0.5,
}) {
  // Sum unit vectors at angle = residual mapped onto a full circle. The residual
  // lives in [-50, +50) cents; map that half-open ±50 range onto [-pi, pi) so
  // the wrap-around at the semitone boundary is handled correctly.
  var sx = 0.0, sy = 0.0;
  for (final f in track) {
    if (f.voicedProb < voicedThreshold || f.f0Hz <= 0 || !f.f0Hz.isFinite) {
      continue;
    }
    final semis =
        12 * (log(f.f0Hz / a4) / ln2); // real-valued semitones from A4
    final residual = semis - semis.roundToDouble(); // in [-0.5, +0.5] semitones
    final angle = residual * 2 * pi; // a 100-cent interval → a 2π circle
    sx += f.voicedProb * cos(angle);
    sy += f.voicedProb * sin(angle);
  }
  if (sx == 0 && sy == 0) return 0;
  final meanAngle = atan2(sy, sx); // [-pi, pi]
  final cents = meanAngle / (2 * pi) * 100; // back to [-50, +50]
  return cents;
}

/// The A4 reference that cancels [track]'s tuning offset: notes sung this many
/// cents off A440 will, against this reference, sit ON the equal-tempered grid.
/// Pass the result as `a4:` to [segmentNotes] to auto-correct a mistuned take.
double tunedReference(PitchTrack track, {double a4 = 440}) =>
    a4 * pow(2, estimateTuningCents(track, a4: a4) / 1200);
