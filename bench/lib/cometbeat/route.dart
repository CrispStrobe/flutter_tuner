// lib/core/audio/transcription/route.dart
//
// N1 — the auto-router. One entry point that looks at the audio and dispatches
// to the right transcriber: the pure-Dart MONOPHONIC chain (pYIN → tuning →
// note-HMM → octave cleanup) for a clean solo line or voice, or the NEURAL
// polyphonic engine (Basic Pitch) for chords, dense/plucked textures, and
// inharmonic percussion. The two are complementary — see the corpus study in
// docs/PLAN.md — so the app can just say "transcribe" and get the best engine.
//
// This file stays pure Dart / web-safe: it NEVER imports the neural engine
// (basic_pitch pulls dart:io). The caller injects a [NeuralTranscriber] when one
// is available (native + model downloaded); on web, or with no model, the router
// falls back to the monophonic chain automatically.
//
// The probe is a single principled metric — MONOPHONIC HARMONICITY: for the
// voiced frames, what fraction of spectral energy sits on the harmonic series of
// the lowest strong partial. A lone harmonic tone/voice scores high (its
// overtones ARE integer multiples of its f0); a chord scores low (the other
// notes fall between the root's harmonics); inharmonic bells/noise score low
// (their partials aren't integer multiples). One number separates "monophonic &
// tonal" from "everything the neural net is better at."

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'chroma_analysis.dart' show fft;
import 'contracts.dart';
import 'note_hmm.dart';
import 'pyin.dart';
import 'tuning.dart';

/// Which engine the router chose (or was forced to).
enum TranscriptionEngine { monophonic, neural }

/// A read on the input: [voicedFraction] (how much is pitched at all),
/// [harmonicity] (0..1, the monophonic-harmonicity metric above), and the
/// resulting [preferNeural] recommendation.
typedef InputProbe = ({
  double voicedFraction,
  double harmonicity,
  bool preferNeural,
});

/// A monophonic F0 estimator producing the shared [PitchTrack] — the seam that
/// lets a better pitch model (CREPE / RMVPE / FCPE, via ORT / FFI / ggml) replace
/// the built-in pure-Dart pYIN without touching the router or the note segmenter.
/// Returns `FutureOr` so a synchronous pYIN and an async neural model share it.
/// The default is [pyinF0]; inject via `transcribeAuto(f0: ...)`.
typedef F0Estimator = FutureOr<PitchTrack> Function(
  Float64List mono,
  int sampleRate,
);

/// A polyphonic transcriber (e.g. Basic Pitch) injected by the caller. Kept as a
/// function so this pure-Dart file never depends on the native ONNX engine.
typedef NeuralTranscriber = Future<List<NoteEvent>> Function(
  Float64List mono,
  int sampleRate,
);

const int _probeWindow = 2048;
const int _harmonics = 8; // harmonics counted toward the harmonic energy
const double _tol = 0.03; // ±3% frequency tolerance around each harmonic

/// Probe [mono] and decide whether the neural engine is the better fit.
///
/// [harmonicityThreshold]: below this the input is treated as polyphonic /
/// inharmonic → prefer neural. [minVoiced]: an input with almost nothing pitched
/// (percussive/noisy) also prefers neural.
InputProbe probeInput(
  Float64List mono, {
  int sampleRate = 44100,
  double harmonicityThreshold = 0.55,
  double minVoiced = 0.1,
}) {
  final track = pyinF0(mono, sampleRate: sampleRate);
  var voiced = 0;
  for (final f in track) {
    if (f.voicedProb >= 0.5 && f.f0Hz > 0) voiced++;
  }
  final voicedFraction = track.isEmpty ? 0.0 : voiced / track.length;

  final harmonicity = _meanHarmonicity(mono, sampleRate);
  final preferNeural =
      harmonicity < harmonicityThreshold || voicedFraction < minVoiced;
  return (
    voicedFraction: voicedFraction,
    harmonicity: harmonicity,
    preferNeural: preferNeural,
  );
}

/// Mean, over evenly-spaced non-silent windows, of the fraction of spectral
/// energy lying on the harmonic series of the window's lowest strong partial.
double _meanHarmonicity(Float64List mono, int sampleRate) {
  final n = mono.length;
  if (n < _probeWindow) return 1.0; // too short to judge — treat as simple
  const probes = 16;
  final step = max(1, (n - _probeWindow) ~/ probes);
  final window = Float64List(_probeWindow);
  for (var i = 0; i < _probeWindow; i++) {
    window[i] = 0.5 - 0.5 * cos(2 * pi * i / (_probeWindow - 1)); // Hann
  }
  final re = Float64List(_probeWindow);
  final im = Float64List(_probeWindow);
  final binHz = sampleRate / _probeWindow;

  var sum = 0.0;
  var count = 0;
  for (var start = 0; start + _probeWindow <= n; start += step) {
    var energy = 0.0;
    for (var i = 0; i < _probeWindow; i++) {
      final v = mono[start + i];
      energy += v * v;
    }
    if (sqrt(energy / _probeWindow) < 1e-3) continue; // silent window

    for (var i = 0; i < _probeWindow; i++) {
      re[i] = mono[start + i] * window[i];
      im[i] = 0;
    }
    fft(re, im);
    const half = _probeWindow ~/ 2;
    final mag = Float64List(half + 1);
    var total = 0.0, maxMag = 0.0;
    for (var k = 0; k <= half; k++) {
      final m = sqrt(re[k] * re[k] + im[k] * im[k]);
      mag[k] = m;
      total += m * m;
      if (m > maxMag) maxMag = m;
    }
    if (total <= 0 || maxMag <= 0) continue;

    // Lowest strong partial (≥30% of the peak, above 50 Hz) = the fundamental.
    final f0bin = _lowestStrongPeak(mag, binHz, 0.30 * maxMag);
    if (f0bin <= 0) continue;
    final f0 = f0bin * binHz;

    var harmonic = 0.0;
    for (var h = 1; h <= _harmonics; h++) {
      final centre = h * f0 / binHz;
      final lo = (centre * (1 - _tol)).floor();
      final hi = (centre * (1 + _tol)).ceil();
      for (var k = max(1, lo); k <= min(half, hi); k++) {
        harmonic += mag[k] * mag[k];
      }
    }
    sum += (harmonic / total).clamp(0.0, 1.0);
    count++;
  }
  return count == 0 ? 1.0 : sum / count;
}

/// The bin index of the lowest local maximum above [thresh] and 50 Hz.
int _lowestStrongPeak(Float64List mag, double binHz, double thresh) {
  final start = max(2, (50 / binHz).ceil());
  for (var k = start; k < mag.length - 1; k++) {
    if (mag[k] >= thresh && mag[k] >= mag[k - 1] && mag[k] >= mag[k + 1]) {
      return k;
    }
  }
  return -1;
}

/// The monophonic chain as one call: F0 ([f0] or the default pure-Dart pYIN) →
/// auto-tuning → note-HMM → octave-artifact cleanup → NoteEvents. Web-safe when
/// [f0] is null (the default).
Future<List<NoteEvent>> transcribeMonophonic(
  Float64List mono, {
  int sampleRate = 44100,
  double a4 = 440,
  F0Estimator? f0,
}) async {
  final track = f0 == null
      ? pyinF0(mono, sampleRate: sampleRate)
      : await f0(mono, sampleRate);
  final ref = tunedReference(track, a4: a4);
  final notes = segmentNotes(track, a4: ref);
  return removeOctaveArtifacts(notes);
}

/// The result of a routed transcription: the [notes] and which [engine] produced
/// them (plus the [probe] that decided).
typedef RoutedTranscription = ({
  List<NoteEvent> notes,
  TranscriptionEngine engine,
  InputProbe probe,
});

/// Transcribe [mono], automatically choosing the engine.
///
/// If the probe prefers neural AND a [neural] transcriber is supplied, use it;
/// otherwise use the monophonic chain. Pass [forceEngine] to override the probe
/// (e.g. a user toggle), and [f0] to swap in a better monophonic pitch model
/// (CREPE/RMVPE); the default pYIN keeps this web-safe. With no [neural] the
/// router always falls back to monophonic.
Future<RoutedTranscription> transcribeAuto(
  Float64List mono, {
  int sampleRate = 44100,
  double a4 = 440,
  NeuralTranscriber? neural,
  F0Estimator? f0,
  TranscriptionEngine? forceEngine,
}) async {
  final probe = probeInput(mono, sampleRate: sampleRate);
  final wantNeural = forceEngine == TranscriptionEngine.neural ||
      (forceEngine == null && probe.preferNeural);
  if (wantNeural && neural != null) {
    return (
      notes: await neural(mono, sampleRate),
      engine: TranscriptionEngine.neural,
      probe: probe,
    );
  }
  return (
    notes: await transcribeMonophonic(
      mono,
      sampleRate: sampleRate,
      a4: a4,
      f0: f0,
    ),
    engine: TranscriptionEngine.monophonic,
    probe: probe,
  );
}
