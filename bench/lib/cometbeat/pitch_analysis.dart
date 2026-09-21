// lib/core/audio/pitch_analysis.dart
//
// Pure-Dart monophonic pitch detection — the input-side twin of synth.dart.
// No plugins, no assets, works on every platform, and is fully unit-testable
// against synth.dart's own tones (see test/pitch_analysis_test.dart).
//
// The algorithm is the McLeod Pitch Method (MPM): a normalized square-
// difference function (NSDF) with parabolic peak refinement. MPM is what
// instrument tuners use for a single sustained tone — it gives sub-cent
// precision, resolves low notes (cello C2 ≈ 65 Hz) that a raw FFT cannot at a
// reasonable window size, and rarely makes the octave errors that FFT peak-
// picking does. It is monophonic by design; chords/polyphony are a later phase
// (a chromagram over this same capture layer) and deliberately out of scope.
//
// References: McLeod & Wyvill, "A Smarter Way to Find Pitch" (ICMC 2005).

import 'dart:math';
import 'dart:typed_data';

/// A4 tuning reference in Hz. Configurable so the cello corner (or an early-
/// music mode) can retune to 415, 442, etc. without touching the detector.
const double kDefaultA4 = 440.0;

const _noteNames = <String>[
  'C',
  'C#',
  'D',
  'D#',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'A#',
  'B',
];

/// One frame's analysis result.
///
/// [frequency] ≤ 0 means "no confident pitch this frame" (silence, noise, or
/// clarity below the detector's threshold). Everything else is only meaningful
/// when [hasPitch] is true.
class PitchReading {
  const PitchReading({
    required this.frequency,
    required this.clarity,
    required this.a4,
    this.rms = 0,
    this.zcr = 0,
  });

  /// Detected fundamental in Hz, or ≤ 0 when nothing was found.
  final double frequency;

  /// NSDF peak height, 0..1 — how periodic the frame was. High for a clean
  /// sustained tone, low for noise/consonants/silence. Doubles as a confidence.
  final double clarity;

  /// The tuning reference this reading was scored against.
  final double a4;

  /// The window's DC-removed RMS level (0..~1). Carried on every frame —
  /// including no-pitch ones — so percussive/onset consumers (the Loop
  /// Mixer's beatbox capture) can see energy where MPM sees no period.
  final double rms;

  /// Zero-crossing rate as the fraction of adjacent sample pairs that change
  /// sign (0..1). A crude brightness measure: a bass thump sits near 0, a
  /// hissy "ts" near 0.5+. Only meaningful when [rms] is non-negligible.
  final double zcr;

  /// A silent/no-pitch reading.
  factory PitchReading.silent({
    double a4 = kDefaultA4,
    double rms = 0,
    double zcr = 0,
  }) =>
      PitchReading(frequency: 0, clarity: 0, a4: a4, rms: rms, zcr: zcr);

  bool get hasPitch => frequency > 0;

  /// Fractional MIDI number (69.5 = a quarter-tone above A4).
  double get midi =>
      hasPitch ? 69.0 + 12.0 * (log(frequency / a4) / ln2) : double.nan;

  /// The MIDI number of the nearest equal-tempered note.
  int get nearestMidi => hasPitch ? midi.round() : -1;

  /// Signed deviation from the nearest note, in cents (−50..+50).
  /// Negative = flat, positive = sharp. This is the intonation meter — the
  /// whole point for a fretless instrument like the cello, or for singing.
  double get cents => hasPitch ? (midi - nearestMidi) * 100.0 : double.nan;

  /// e.g. "A4", "C#3". Empty when there is no pitch.
  String get noteName {
    if (!hasPitch) return '';
    final m = nearestMidi;
    return '${_noteNames[m % 12]}${(m ~/ 12) - 1}';
  }

  @override
  String toString() => hasPitch
      ? '$noteName ${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(0)}¢ '
          '(${frequency.toStringAsFixed(1)} Hz, clarity ${clarity.toStringAsFixed(2)})'
      : 'PitchReading.silent';
}

/// Monophonic pitch detector. Stateless across frames — feed it a window of
/// mono float samples and it returns one [PitchReading]. The owning service is
/// responsible for buffering the mic stream into windows of [windowSize].
class PitchDetector {
  PitchDetector({
    this.sampleRate = 44100,
    this.a4 = kDefaultA4,
    this.clarityThreshold = 0.7,
    this.minFrequency = 55.0, // A1 — below the cello's low C, with headroom.
    this.maxFrequency = 2000.0, // above a soprano's top / violin high work.
  });

  final int sampleRate;
  final double a4;

  /// Reject readings whose NSDF peak is below this. Higher = stricter (fewer
  /// false notes from breath/bow noise); lower = catches quieter/vibrato tones.
  final double clarityThreshold;

  final double minFrequency;
  final double maxFrequency;

  /// The window MPM wants: enough samples for ~2–3 periods of the lowest note.
  /// At 44.1 kHz that is 2048 (≈46 ms, min detectable ≈ 43 Hz).
  int get windowSize {
    // Need lag up to sampleRate / minFrequency; window must be ~2× that.
    final needed = (2 * sampleRate / minFrequency).ceil();
    var n = 1024;
    while (n < needed) {
      n <<= 1;
    }
    return n;
  }

  /// Analyse one window of mono samples in [-1, 1]. Samples shorter than a
  /// couple of periods will simply return silent.
  PitchReading analyze(Float64List samples) {
    final n = samples.length;
    final maxLag = min(n ~/ 2, (sampleRate / minFrequency).ceil());
    final minLag = max(2, (sampleRate / maxFrequency).floor());
    if (maxLag <= minLag) return PitchReading.silent(a4: a4);

    // Remove DC offset so it does not bias the NSDF.
    var mean = 0.0;
    for (var i = 0; i < n; i++) {
      mean += samples[i];
    }
    mean /= n;

    // Bail on near-silence: RMS gate avoids "detecting" a pitch in room noise.
    // The same pass counts sign changes — the zero-crossing rate rides along
    // on every reading as a cheap brightness measure (see PitchReading.zcr).
    var energy = 0.0;
    var crossings = 0;
    var prev = samples[0] - mean;
    for (var i = 0; i < n; i++) {
      final v = samples[i] - mean;
      energy += v * v;
      if ((v < 0) != (prev < 0)) crossings++;
      prev = v;
    }
    final rms = sqrt(energy / n);
    final zcr = crossings / n;
    // A bad plugin frame (NaN/Inf samples) makes rms non-finite; `NaN < 1e-3`
    // is false, so without this guard the reading would leak a NaN/Inf rms into
    // downstream onset detection. Treat a non-finite frame as clean silence.
    if (!rms.isFinite) return PitchReading.silent(a4: a4);
    if (rms < 1e-3) return PitchReading.silent(a4: a4, rms: rms, zcr: zcr);

    // Normalized square difference function (NSDF), lags 0..maxLag.
    final nsdf = Float64List(maxLag + 1);
    for (var tau = 0; tau <= maxLag; tau++) {
      var acf = 0.0; // autocorrelation at this lag
      var m = 0.0; // summed square magnitude (the normalizer)
      for (var i = 0; i < n - tau; i++) {
        final a = samples[i] - mean;
        final b = samples[i + tau] - mean;
        acf += a * b;
        m += a * a + b * b;
      }
      nsdf[tau] = m > 0 ? 2.0 * acf / m : 0.0;
    }

    // Key maxima: the highest NSDF point in each stretch between successive
    // positively-sloped zero crossings, starting after the first one (so we
    // skip the tau=0 self-correlation peak).
    //
    // NB: scan from tau=1, NOT from minLag. For a tone of period T the upward
    // zero crossing that opens the fundamental's segment sits near 3T/4, which
    // for short periods falls BELOW minLag. Starting at minLag lands mid-segment
    // (prev and cur both already positive), so no crossing is seen, the peak at
    // T is skipped entirely and the first one found is at 2T — reporting the
    // pitch an octave low, at full clarity. minLag still bounds the *result*
    // via the frequency range check below.
    final peakLags = <int>[];
    var pos = false; // are we currently past the first positive zero crossing?
    var maxLagInSegment = -1;
    var maxValInSegment = -double.infinity;
    for (var tau = 1; tau <= maxLag; tau++) {
      final prev = nsdf[tau - 1];
      final cur = nsdf[tau];
      if (!pos) {
        // Wait for an upward zero crossing to begin the first segment.
        if (prev <= 0 && cur > 0) {
          pos = true;
          maxLagInSegment = tau;
          maxValInSegment = cur;
        }
        continue;
      }
      if (cur > 0) {
        if (cur > maxValInSegment) {
          maxValInSegment = cur;
          maxLagInSegment = tau;
        }
      } else {
        // Downward zero crossing: close the segment, record its maximum.
        if (maxLagInSegment >= 0) peakLags.add(maxLagInSegment);
        pos = false;
        maxLagInSegment = -1;
        maxValInSegment = -double.infinity;
      }
    }
    if (pos && maxLagInSegment >= 0) peakLags.add(maxLagInSegment);
    if (peakLags.isEmpty) {
      return PitchReading.silent(a4: a4, rms: rms, zcr: zcr);
    }

    // The MPM choice: the FIRST key maximum that clears k × (global max).
    // Taking the first (not the tallest) is what avoids octave-too-low errors.
    var globalMax = -double.infinity;
    for (final lag in peakLags) {
      if (nsdf[lag] > globalMax) globalMax = nsdf[lag];
    }
    const k = 0.9;
    final threshold = k * globalMax;
    var chosenLag = peakLags.first;
    for (final lag in peakLags) {
      if (nsdf[lag] >= threshold) {
        chosenLag = lag;
        break;
      }
    }

    // Parabolic interpolation around the chosen integer lag for sub-sample
    // (sub-cent) precision.
    final (refinedLag, peakVal) = _parabolicPeak(nsdf, chosenLag);
    if (peakVal < clarityThreshold) {
      return PitchReading.silent(a4: a4, rms: rms, zcr: zcr);
    }

    final freq = sampleRate / refinedLag;
    // `!freq.isFinite` is defensive (a zero/NaN refined lag would otherwise
    // slip past the range check, since NaN comparisons are false).
    if (!freq.isFinite || freq < minFrequency || freq > maxFrequency) {
      return PitchReading.silent(a4: a4, rms: rms, zcr: zcr);
    }
    return PitchReading(
      frequency: freq,
      clarity: peakVal.clamp(0.0, 1.0),
      a4: a4,
      rms: rms,
      zcr: zcr,
    );
  }

  /// Fit a parabola through (lag-1, lag, lag+1) and return the vertex
  /// (interpolated lag, interpolated peak value).
  (double, double) _parabolicPeak(Float64List nsdf, int lag) {
    if (lag <= 0 || lag >= nsdf.length - 1) {
      return (lag.toDouble(), nsdf[lag]);
    }
    final y0 = nsdf[lag - 1];
    final y1 = nsdf[lag];
    final y2 = nsdf[lag + 1];
    final denom = y0 - 2 * y1 + y2;
    if (denom == 0) return (lag.toDouble(), y1);
    final delta = 0.5 * (y0 - y2) / denom;
    final refined = lag + delta.clamp(-1.0, 1.0);
    final peak = y1 - 0.25 * (y0 - y2) * delta;
    return (refined, peak);
  }
}

/// Convert interleaved-free mono PCM16 little-endian bytes to normalized
/// float samples in [-1, 1]. The mic stream from `record` arrives as PCM16;
/// this is the single conversion point.
Float64List pcm16ToFloat(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final out = Float64List(n);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < n; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
