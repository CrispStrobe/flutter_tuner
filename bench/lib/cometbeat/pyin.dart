// lib/core/audio/transcription/pyin.dart
//
// S1 of the transcription pipeline (docs/PLAN.md § "Automatic Music
// Transcription"): per-frame fundamental frequency (F0) via a clean-room YIN /
// probabilistic-YIN estimator. Emits the shared PitchTrack contract.
//
// Clean-room from the papers — de Cheveigné & Kawahara "YIN, a fundamental
// frequency estimator" (JASA 2002) and Mauch & Dixon "pYIN" (ICASSP 2014) — NOT
// copied from any GPL implementation. YIN's cumulative-mean-normalised
// difference function + the FIRST-dip-below-threshold rule is what makes this
// far more octave-error-robust than the shipped MPM autocorrelation detector.
//
// This slice ships the YIN F0 core with a probabilistic voicing measure
// (voicedProb from the dip depth, RMS-gated). The full pYIN candidate-lattice
// Viterbi smoothing is a follow-up refinement inside S2 (note_hmm.dart), which
// already runs a Viterbi over note states.

import 'dart:math';
import 'dart:typed_data';

import 'contracts.dart';

/// Estimate F0 over [mono] (float PCM in [-1, 1]) at [sampleRate].
///
/// A frame of [windowSize] samples slides by [hopMs] milliseconds; each yields a
/// [PitchFrame] timestamped at the frame CENTRE. [minHz]/[maxHz] bound the
/// search (defaults cover A1..~C6, i.e. a low cello to a high voice). A frame
/// whose best YIN dip is shallower than the voicing derived from [threshold], or
/// that is near-silent, is emitted unvoiced (`f0Hz == 0`, low `voicedProb`).
PitchTrack pyinF0(
  Float64List mono, {
  int sampleRate = 44100,
  double minHz = 55,
  double maxHz = 1000,
  int windowSize = 2048,
  double hopMs = 10,
  double threshold = 0.15,
}) {
  final n = mono.length;
  final w = windowSize;
  final hop = max(1, (hopMs * sampleRate / 1000).round());
  if (n < w) return const [];

  final maxLag = min(w ~/ 2, (sampleRate / minHz).ceil());
  final minLag = max(2, (sampleRate / maxHz).floor());
  final track = <PitchFrame>[];
  if (maxLag <= minLag) return track;

  final diff = Float64List(maxLag + 1);
  for (var start = 0; start + w <= n; start += hop) {
    final timeMs = (start + w / 2) / sampleRate * 1000;

    // RMS voicing gate (a silent window has no pitch).
    var energy = 0.0;
    for (var i = 0; i < w; i++) {
      final v = mono[start + i];
      energy += v * v;
    }
    final rms = sqrt(energy / w);
    if (!rms.isFinite || rms < 1e-3) {
      track.add((timeMs: timeMs, f0Hz: 0, voicedProb: 0));
      continue;
    }

    // YIN difference function d(τ) = Σ (x[i] − x[i+τ])².
    for (var tau = 1; tau <= maxLag; tau++) {
      var sum = 0.0;
      final lim = w - tau;
      for (var i = 0; i < lim; i++) {
        final delta = mono[start + i] - mono[start + i + tau];
        sum += delta * delta;
      }
      diff[tau] = sum;
    }
    // Cumulative mean normalised difference d'(τ).
    diff[0] = 1;
    var running = 0.0;
    for (var tau = 1; tau <= maxLag; tau++) {
      running += diff[tau];
      diff[tau] = running == 0 ? 1 : diff[tau] * tau / running;
    }

    // The FIRST local minimum below [threshold] within the pitch range (taking
    // the first, not the deepest, is what avoids octave-too-LOW errors); else
    // the global minimum in range as a low-confidence fallback.
    var tau = -1;
    for (var t = minLag; t <= maxLag; t++) {
      if (diff[t] < threshold) {
        // Descend to the local minimum of this dip.
        while (t + 1 <= maxLag && diff[t + 1] < diff[t]) {
          t++;
        }
        tau = t;
        break;
      }
    }
    if (tau < 0) {
      var best = minLag;
      for (var t = minLag; t <= maxLag; t++) {
        if (diff[t] < diff[best]) best = t;
      }
      tau = best;
    }

    // Parabolic interpolation for a sub-sample period.
    final refined = _parabolicMin(diff, tau, maxLag);
    final f0 = sampleRate / refined;

    // voicedProb: dip depth (1 − d'), only trusted for an in-range pitch.
    final clarity = (1 - diff[tau]).clamp(0.0, 1.0);
    final inRange = f0 >= minHz && f0 <= maxHz;
    track.add(
      (
        timeMs: timeMs,
        f0Hz: inRange ? f0 : 0,
        voicedProb: inRange ? clarity : 0,
      ),
    );
  }
  return track;
}

/// Parabola through (τ−1, τ, τ+1) of the difference function → the sub-sample
/// lag of the minimum. Falls back to the integer lag at the edges.
double _parabolicMin(Float64List d, int tau, int maxLag) {
  if (tau <= 1 || tau >= maxLag) return tau.toDouble();
  final a = d[tau - 1], b = d[tau], c = d[tau + 1];
  final denom = a - 2 * b + c;
  if (denom == 0) return tau.toDouble();
  final delta = 0.5 * (a - c) / denom;
  return tau + delta.clamp(-1.0, 1.0);
}

/// Cents between two frequencies (for tests / tuning): 1200·log2(f/ref).
double centsBetween(double f, double ref) => 1200 * (log(f / ref) / ln2);
