// lib/core/audio/chroma_analysis.dart
//
// Phase 2 of automatic play-along: *fuzzy* chord recognition. Where
// pitch_analysis.dart answers "which single note?" (monophonic, exact), this
// answers "what chord did that sound like?" — deliberately approximate. It runs
// over the SAME mic capture layer (MicrophonePitchService), just a second
// analysis path on each window.
//
// The method is a **chromagram + template match**, not note-by-note
// transcription (which is research-grade and unreliable on guitar/piano decay):
//  1. FFT the windowed signal → magnitude spectrum.
//  2. Fold every bin onto its pitch class (C..B) → a 12-bin chroma vector.
//  3. Cosine-match that chroma against binary chord templates (maj, min, 7, …)
//     for all 12 roots, and return the best few as fuzzy candidates.
//
// Pure Dart, no plugins/assets — unit-tested against synth.dart chords in
// test/chroma_analysis_test.dart.

import 'dart:math';
import 'dart:typed_data';

import 'pitch_analysis.dart' show kDefaultA4;

const _pcNames = <String>[
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

/// In-place iterative radix-2 Cooley–Tukey FFT. [re]/[im] must be the same
/// length and a power of two. Transforms in place.
void fft(Float64List re, Float64List im) {
  final n = re.length;
  assert(im.length == n);
  assert(n & (n - 1) == 0, 'FFT length must be a power of two');
  if (n <= 1) return;

  // Bit-reversal permutation.
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; (j & bit) != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }

  // Danielson–Lanczos butterflies.
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * pi / len;
    final wLenRe = cos(ang);
    final wLenIm = sin(ang);
    for (var i = 0; i < n; i += len) {
      var wRe = 1.0;
      var wIm = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final uRe = re[i + k];
        final uIm = im[i + k];
        final vRe = re[i + k + len ~/ 2] * wRe - im[i + k + len ~/ 2] * wIm;
        final vIm = re[i + k + len ~/ 2] * wIm + im[i + k + len ~/ 2] * wRe;
        re[i + k] = uRe + vRe;
        im[i + k] = uIm + vIm;
        re[i + k + len ~/ 2] = uRe - vRe;
        im[i + k + len ~/ 2] = uIm - vIm;
        final nWRe = wRe * wLenRe - wIm * wLenIm;
        wIm = wRe * wLenIm + wIm * wLenRe;
        wRe = nWRe;
      }
    }
  }
}

/// A chord shape as semitone offsets from the root, with the suffix used to
/// name it (e.g. C + [0,3,7] + 'm' → "Cm").
class ChordTemplate {
  const ChordTemplate(this.suffix, this.intervals);
  final String suffix;
  final List<int> intervals;
}

/// The vocabulary we try to match. Ordered roughly most→least common so ties
/// break toward the simpler/likelier chord.
const kChordTemplates = <ChordTemplate>[
  ChordTemplate('', [0, 4, 7]), // major
  ChordTemplate('m', [0, 3, 7]), // minor
  ChordTemplate('7', [0, 4, 7, 10]), // dominant 7
  ChordTemplate('m7', [0, 3, 7, 10]), // minor 7
  ChordTemplate('maj7', [0, 4, 7, 11]), // major 7
  ChordTemplate('sus4', [0, 5, 7]), // suspended 4
  ChordTemplate('dim', [0, 3, 6]), // diminished
  ChordTemplate('aug', [0, 4, 8]), // augmented
];

/// One fuzzy chord guess.
class ChordCandidate {
  const ChordCandidate({
    required this.rootPc,
    required this.suffix,
    required this.score,
  });

  /// Root pitch class, 0 = C … 11 = B.
  final int rootPc;
  final String suffix;

  /// Cosine similarity to the template, 0..1. Higher = better fit.
  final double score;

  /// e.g. "C", "Am", "G7".
  String get name => '${_pcNames[rootPc]}$suffix';

  @override
  String toString() => '$name (${(score * 100).toStringAsFixed(0)}%)';
}

/// The result of analysing one window for chords.
class ChordReading {
  const ChordReading({
    this.bassPc,
    required this.candidates,
    required this.chroma,
    required this.energy,
  });

  /// Best guesses, strongest first (may be empty on silence).
  final List<ChordCandidate> candidates;

  /// The 12-bin normalized pitch-class profile (for visualisation).
  final List<double> chroma;

  /// The pitch class of the lowest sounding note (0 = C), or null when the bass
  /// register is empty or ambiguous.
  ///
  /// This is information a chromagram STRUCTURALLY cannot carry — chroma folds
  /// away the octave, so `C` and `C/E` are the same 12 numbers, and `C6` and
  /// `Am7` are literally the same four pitch classes. The bass is what tells
  /// them apart, and it is found by harmonic summation rather than by folding
  /// the low band (see [ChordDetector.bassPitchClass] for why that does not
  /// work).
  final int? bassPc;

  /// Absolute level in the analysed band: the summed pitch-class magnitude per
  /// input sample. An absolute measure (NOT read off the peak-normalized
  /// chroma), so it actually tracks loudness and can serve as a silence gate.
  final double energy;

  factory ChordReading.silent() =>
      ChordReading(candidates: const [], chroma: List.filled(12, 0), energy: 0);

  bool get hasChord => candidates.isNotEmpty;
  ChordCandidate? get best => candidates.isEmpty ? null : candidates.first;

  @override
  String toString() =>
      hasChord ? candidates.take(3).join(', ') : 'ChordReading.silent';
}

/// Computes a chromagram and matches chord templates. Stateless per window; the
/// capture service feeds it the same windows it feeds [PitchDetector].
class ChordDetector {
  ChordDetector({
    this.sampleRate = 44100,
    this.a4 = kDefaultA4,
    this.minFrequency = 65.0, // ~C2: cover a guitar/piano's chord register.
    this.maxFrequency = 2000.0,
    this.energyGate = 1e-4,
    this.scoreThreshold = 0.6,
    this.maxCandidates = 3,
    this.templates = kChordTemplates,
    this.bassMinMidi = 28,
    this.bassMaxMidi = 64,
    this.bassHarmonics = 6,
    this.bassFundamentalFloor = 0.12,
    this.bassHarmonicSupport = 0.05,
    this.bassTieEpsilon = 0.02,
  });

  /// The register searched for the bass note: E1 (28) to E4 (64) by default.
  /// The ceiling is above a "bass" register on purpose — an INVERSION puts the
  /// lowest sounding note in the middle of the chord, and that note is still the
  /// bass for naming purposes.
  final int bassMinMidi;
  final int bassMaxMidi;

  /// How many harmonics to sum when scoring a candidate bass note.
  final int bassHarmonics;

  /// A candidate bass note must show at least this fraction of the bass band's
  /// peak magnitude AT ITS OWN FUNDAMENTAL. See [_bassPcFrom] — without this
  /// test, harmonic summation alone is too ambiguous to be useful.
  final double bassFundamentalFloor;

  /// A candidate must also carry harmonic support of at least this fraction of
  /// its own fundamental, which is what separates a real low note from leakage.
  final double bassHarmonicSupport;

  /// How close two cosine scores must be before the bass is allowed to decide
  /// between them. Small on purpose — the bass breaks TIES, it does not override
  /// the harmony.
  final double bassTieEpsilon;

  /// The chord vocabulary to match against. Defaults to [kChordTemplates], so
  /// every existing caller is unaffected.
  ///
  /// Injectable because extending this vocabulary has to be MEASURED, not argued
  /// about — more templates is not automatically better, since a denser template
  /// has more ones and partially matches more things. `tool/
  /// chord_template_ab.dart` A/Bs a candidate set against the shipped one; the
  /// first thing it measured was a **−19pp regression** from the obvious
  /// extension, which is why nothing here changes without a number.
  final List<ChordTemplate> templates;

  final int sampleRate;
  final double a4;
  final double minFrequency;
  final double maxFrequency;

  /// Below this absolute band level ([ChordReading.energy]), treat the window as
  /// silence and report no chord.
  final double energyGate;

  /// Best-candidate cosine below this → report no chord (too ambiguous).
  final double scoreThreshold;

  final int maxCandidates;

  /// The window this detector wants: larger than the pitch detector's, for the
  /// finer FFT frequency resolution chord matching needs (≈10 Hz at 44.1 kHz).
  int get windowSize => 4096;

  /// Pre-computed L2-normalized template vectors, one per (root, template).
  late final List<({int rootPc, String suffix, List<double> vec})> _templates =
      _buildTemplates();

  List<({int rootPc, String suffix, List<double> vec})> _buildTemplates() {
    final out = <({int rootPc, String suffix, List<double> vec})>[];
    for (var root = 0; root < 12; root++) {
      for (final t in templates) {
        final v = List<double>.filled(12, 0);
        for (final iv in t.intervals) {
          v[(root + iv) % 12] = 1.0;
        }
        _l2Normalize(v);
        out.add((rootPc: root, suffix: t.suffix, vec: v));
      }
    }
    return out;
  }

  /// Analyse one window of mono samples in [-1, 1].
  ChordReading analyze(Float64List samples) {
    // A window shorter than 2 samples can't be Hann-windowed or FFT-binned
    // (the bin clamp would be `clamp(1, 0)`), and a bad/empty mic frame must
    // never crash the chord listener — treat it as silence.
    if (samples.length < 2) return ChordReading.silent();
    // Gate on the ABSOLUTE band level, which means measuring it *before* peak
    // normalization: `chromagram` scales its output so the loudest bin is 1, so
    // any sum over it is scale-invariant (always ≈1..12 for any non-zero input).
    // Gating on that can only ever catch bit-exact silence — inaudible noise
    // sails through and is emitted as a confident chord.
    final (mags, fftN) = _magnitudes(samples);
    final raw = _foldChroma(mags, fftN);
    var sum = 0.0;
    for (final v in raw) {
      sum += v;
    }
    // Per input sample, so the gate is window-size independent and stays
    // comparable to the signal's amplitude.
    final energy = sum / samples.length;
    if (energy < energyGate) return ChordReading.silent();

    final chroma = List<double>.of(raw);
    _peakNormalize(chroma);

    final bassPc = _bassPcFrom(mags, fftN);
    final scored = matchChroma(chroma, bassPc: bassPc);
    if (scored.isEmpty || scored.first.score < scoreThreshold) {
      return ChordReading(
        candidates: const [],
        chroma: chroma,
        energy: energy,
        bassPc: _bassPcFrom(mags, fftN),
      );
    }
    return ChordReading(
      candidates: scored.take(maxCandidates).toList(),
      chroma: chroma,
      energy: energy,
      bassPc: bassPc,
    );
  }

  /// Score every (root, template) against [chroma] and return the candidates in
  /// a fully deterministic order, optionally letting [bassPc] break a near-tie.
  ///
  /// Public and separate from [analyze] so a smoother can match an AVERAGED
  /// chroma without duplicating the ordering rules — the two must agree, or a
  /// smoothed reading would be ranked by different logic than an unsmoothed one.
  List<ChordCandidate> matchChroma(List<double> chroma, {int? bassPc}) {
    final norm = List<double>.of(chroma);
    _l2Normalize(norm);

    final scored = <ChordCandidate>[];
    for (final t in _templates) {
      var dot = 0.0;
      for (var i = 0; i < 12; i++) {
        dot += norm[i] * t.vec[i];
      }
      scored.add(
        ChordCandidate(rootPc: t.rootPc, suffix: t.suffix, score: dot),
      );
    }
    // 🔴 A DETERMINISTIC ORDER, not just a score order. Dart's `List.sort` is
    // NOT stable, so two candidates with equal cosine could come back in either
    // order — and the moment the vocabulary contains a true collision (`C6` and
    // `Am7` are the same four pitch classes) that makes the reported chord name
    // arbitrary between runs. The secondary keys are a documented PRIOR, applied
    // only when the acoustic evidence is exhausted: prefer the SIMPLER chord
    // (fewer tones — which is also how the cosine already behaves on
    // subset/superset), then the lower root, then the name.
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byTones = _toneCount(a.suffix).compareTo(_toneCount(b.suffix));
      if (byTones != 0) return byTones;
      final byRoot = a.rootPc.compareTo(b.rootPc);
      if (byRoot != 0) return byRoot;
      return a.suffix.compareTo(b.suffix);
    });

    // Then let the BASS break a near-tie, because that is real evidence rather
    // than a prior. Two chords with identical pitch-class sets differ only in
    // which note is lowest, so this is the one thing that can separate them —
    // and it is applied ONLY within a near-tie, never as a general preference:
    // a first-inversion C major has E in the bass and is still a C chord.
    if (bassPc != null && scored.length > 1) {
      final best = scored.first.score;
      for (var i = 1; i < scored.length; i++) {
        if (best - scored[i].score > bassTieEpsilon) break;
        if (scored[i].rootPc == bassPc && scored.first.rootPc != bassPc) {
          final promoted = scored.removeAt(i);
          scored.insert(0, promoted);
          break;
        }
      }
    }

    return scored;
  }

  /// The pitch class of the lowest sounding note, or null when the bass register
  /// is empty or the reading is ambiguous.
  ///
  /// 🔴 **Why this is NOT a second chromagram over the low band.** At 44.1 kHz a
  /// 4096-point FFT has 10.77 Hz bins, while a semitone at C3 spans 7.8 Hz, at
  /// E2 4.9 Hz and at A1 3.3 Hz. **Below roughly G3 the transform physically
  /// cannot separate adjacent semitones**, so folding the low band into 12 bins
  /// measures leakage, not the bass — the fundamental smears across two or more
  /// pitch classes and the answer is noise wearing a confident hat.
  ///
  /// So instead each candidate bass note is scored by HARMONIC SUMMATION: the
  /// magnitude at its fundamental plus its first [bassHarmonics] partials,
  /// weighted 1/h. The partials land in the well-resolved region above 200 Hz,
  /// which is exactly where the fundamental's information is missing.
  ///
  /// ⚠️ Sub-octave confusion is harmless HERE and that is worth knowing: a note
  /// an octave down shares every partial, so it can score well — but it has the
  /// SAME PITCH CLASS, which is all a slash chord needs. A fifth-below error
  /// would change the answer, which is what the 1/h weighting and [bassMargin]
  /// guard against.
  int? bassPitchClass(Float64List samples) {
    if (samples.length < 2) return null;
    final (mags, n) = _magnitudes(samples);
    return _bassPcFrom(mags, n);
  }

  /// How many tones a template's suffix names — the tie-break's simplicity key.
  int _toneCount(String suffix) {
    for (final t in templates) {
      if (t.suffix == suffix) return t.intervals.length;
    }
    return 3;
  }

  double _midiHz(int midi) => a4 * pow(2.0, (midi - 69) / 12.0);

  int? _bassPcFrom(List<double> mags, int n) {
    final half = mags.length - 1;
    final loBin =
        (_midiHz(bassMinMidi) * n / sampleRate).floor().clamp(1, half);
    final hiBin = (_midiHz(bassMaxMidi) * n / sampleRate).ceil().clamp(1, half);
    if (hiBin <= loBin) return null;

    var bandPeak = 0.0;
    for (var b = loBin; b <= hiBin; b++) {
      if (mags[b] > bandPeak) bandPeak = mags[b];
    }
    if (bandPeak <= 0) return null;

    // 🔴 FIND PEAKS, DO NOT SCAN SEMITONES. Scanning candidate notes and testing
    // each one's neighbourhood lets a candidate steal the peak belonging to the
    // note a semitone above it, which is exactly the systematic "reports the
    // note just below" error measured at 65% wrong.
    //
    // The key realisation: the resolution limit applies to SEPARATING two close
    // partials, not to LOCATING an isolated one. A bass fundamental has nothing
    // within a semitone of it, so parabolic interpolation over the peak and its
    // two neighbours recovers its frequency far more precisely than the bin
    // width — the standard sub-bin estimator. That is what makes this tractable
    // at a window we can afford.
    for (var b = loBin + 1; b < hiBin; b++) {
      final m = mags[b];
      if (m < bandPeak * bassFundamentalFloor) continue;
      if (m <= mags[b - 1] || m < mags[b + 1]) continue; // not a local maximum

      // Parabolic interpolation on the log magnitude → sub-bin peak position.
      final a = mags[b - 1], c = mags[b + 1];
      final denom = a - 2 * m + c;
      final delta = denom == 0 ? 0.0 : 0.5 * (a - c) / denom;
      final freq = (b + delta.clamp(-0.5, 0.5)) * sampleRate / n;
      if (freq <= 0) continue;

      // Harmonic support: a real note brings partials. Leakage does not.
      var support = 0.0;
      for (var h = 2; h <= bassHarmonics; h++) {
        final hb = (freq * h * n / sampleRate).round();
        if (hb < 1 || hb > half) break;
        support += mags[hb] / h;
      }
      if (support < m * bassHarmonicSupport) continue;

      final midi = 69.0 + 12.0 * (log(freq / a4) / ln2);
      return (midi.round() % 12 + 12) % 12;
    }
    return null;
  }

  /// The 12-bin pitch-class energy profile of [samples], normalized so its max
  /// is 1 (0 for silence). Public for tests and visualisation.
  List<double> chromagram(Float64List samples) {
    if (samples.length < 2) return List<double>.filled(12, 0);
    final chroma = _rawChroma(samples);
    _peakNormalize(chroma);
    return chroma;
  }

  /// The un-normalized 12-bin pitch-class magnitude profile — the absolute
  /// spectral level, which the silence gate needs (see [analyze]).
  List<double> _rawChroma(Float64List samples) {
    final (mags, n) = _magnitudes(samples);
    return _foldChroma(mags, n);
  }

  /// One FFT → the magnitude spectrum, shared by the chroma fold and the bass
  /// finder so adding the bass costs no extra transform.
  (List<double>, int) _magnitudes(Float64List samples) {
    final n = _pow2AtLeast(samples.length);
    final re = Float64List(n);
    final im = Float64List(n);
    // Hann window to cut spectral leakage; zero-pad up to the FFT size.
    final m = samples.length;
    for (var i = 0; i < m; i++) {
      final w = 0.5 - 0.5 * cos(2 * pi * i / (m - 1));
      re[i] = samples[i] * w;
    }
    fft(re, im);
    final half = n ~/ 2;
    final mags = List<double>.filled(half + 1, 0);
    for (var bin = 0; bin <= half; bin++) {
      final mag = sqrt(re[bin] * re[bin] + im[bin] * im[bin]);
      // A NaN/Inf sample (bad mic frame) yields a non-finite magnitude; drop it
      // so everything downstream — the energy gate, the cosine scores, the bass
      // finder — stays finite instead of leaking NaN.
      mags[bin] = mag.isFinite ? mag : 0.0;
    }
    return (mags, n);
  }

  List<double> _foldChroma(List<double> mags, int n) {
    final chroma = List<double>.filled(12, 0);
    final loBin = (minFrequency * n / sampleRate).floor().clamp(1, n ~/ 2);
    final hiBin = (maxFrequency * n / sampleRate).ceil().clamp(1, n ~/ 2);
    for (var bin = loBin; bin <= hiBin; bin++) {
      final freq = bin * sampleRate / n;
      final mag = mags[bin];
      final midi = 69.0 + 12.0 * (log(freq / a4) / ln2);
      final pc = (midi.round() % 12 + 12) % 12;
      chroma[pc] += mag;
    }
    return chroma;
  }

  /// Scale [v] so its largest entry is 1 (a no-op on an all-zero profile).
  static void _peakNormalize(List<double> v) {
    var peak = 0.0;
    for (final x in v) {
      if (x > peak) peak = x;
    }
    if (peak > 0) {
      for (var i = 0; i < v.length; i++) {
        v[i] /= peak;
      }
    }
  }

  static void _l2Normalize(List<double> v) {
    var sumSq = 0.0;
    for (final x in v) {
      sumSq += x * x;
    }
    final norm = sqrt(sumSq);
    if (norm > 0) {
      for (var i = 0; i < v.length; i++) {
        v[i] /= norm;
      }
    }
  }

  static int _pow2AtLeast(int x) {
    var n = 1;
    while (n < x) {
      n <<= 1;
    }
    return n;
  }
}

/// How a [ChordSmoother] combines the frames it holds.
enum ChordSmoothing {
  /// Average the chroma vectors, then match once. Cheap and stable.
  meanChroma,

  /// Per-bin median of the chroma vectors, then match once. Rejects a single
  /// odd frame (a re-strum, a passing note) rather than averaging it in.
  medianChroma,

  /// Match every frame, then take a plurality vote on the winning label. The
  /// weakest of the three — it throws away how *close* each frame's decision
  /// was — and it is here because it is what a naive implementation does, so
  /// the others have something to beat.
  labelVote,
}

/// Smooths a per-frame [ChordDetector] over time.
///
/// 🔴 **This is the single largest measured win in the non-neural chord path,
/// and nothing in the app did it before.** Measured on GuitarSet (real
/// guitarists, real microphone), combining nine frames of one sustained chord
/// took exact accuracy from **12.9% to 24.3%** — and the diagnostic that
/// explains it is that those nine frames produced **eight different answers**.
/// A per-frame chord detector is far less stable than its confidence suggests.
///
/// Smoothing the CHROMA beats voting on labels because it keeps the continuous
/// evidence: a frame that was nearly right contributes its near-rightness
/// instead of being reduced to one discarded guess. This is also why BTC feeds
/// its transformer 108 frames of context rather than classifying single frames.
///
/// Stateful by nature, which is why it is a separate class — [ChordDetector]
/// documents itself as stateless per window and stays that way. Feed it frames
/// with [add]; call [reset] at a discontinuity (a new take, a seek).
class ChordSmoother {
  ChordSmoother(
    this.detector, {
    this.frames = 9,
    this.mode = ChordSmoothing.medianChroma,
  }) : assert(frames > 0, 'need at least one frame');

  final ChordDetector detector;

  /// How many recent frames to combine. Nine at the detector's window is roughly
  /// a second of context — long enough to outvote a re-strum, short enough that
  /// a real chord change is not smeared across the boundary.
  final int frames;

  final ChordSmoothing mode;

  final List<ChordReading> _history = [];

  /// Drop all history — call at a seek or a new recording, or the last take's
  /// chords bleed into the next one's first second.
  void reset() => _history.clear();

  /// Feed one analysed frame and get the smoothed reading back.
  ChordReading add(ChordReading reading) {
    _history.add(reading);
    if (_history.length > frames) _history.removeAt(0);

    final sounding = _history.where((r) => r.energy > 0).toList();
    if (sounding.isEmpty) return ChordReading.silent();

    // The bass is categorical, so it votes rather than averages.
    final bass = _voteBass(sounding);

    if (mode == ChordSmoothing.labelVote) {
      final ballot = <String, int>{};
      for (final r in sounding) {
        if (!r.hasChord) continue;
        final c = r.candidates.first;
        ballot['${c.rootPc}|${c.suffix}'] =
            (ballot['${c.rootPc}|${c.suffix}'] ?? 0) + 1;
      }
      if (ballot.isEmpty) return ChordReading.silent();
      // Deterministic: most votes, then the lexically first key.
      final winner = ballot.entries.reduce((a, b) {
        if (b.value != a.value) return b.value > a.value ? b : a;
        return a.key.compareTo(b.key) <= 0 ? a : b;
      }).key;
      final parts = winner.split('|');
      return ChordReading(
        candidates: [
          ChordCandidate(
            rootPc: int.parse(parts[0]),
            suffix: parts[1],
            score: ballot[winner]! / sounding.length,
          ),
        ],
        chroma: sounding.last.chroma,
        energy: sounding.last.energy,
        bassPc: bass,
      );
    }

    final combined = List<double>.filled(12, 0);
    for (var bin = 0; bin < 12; bin++) {
      final values = [for (final r in sounding) r.chroma[bin]]..sort();
      combined[bin] = mode == ChordSmoothing.medianChroma
          ? values[values.length ~/ 2]
          : values.reduce((a, b) => a + b) / values.length;
    }

    final scored = detector.matchChroma(combined, bassPc: bass);
    final energy =
        sounding.map((r) => r.energy).reduce((a, b) => a + b) / sounding.length;
    if (scored.isEmpty || scored.first.score < detector.scoreThreshold) {
      return ChordReading(
        candidates: const [],
        chroma: combined,
        energy: energy,
        bassPc: bass,
      );
    }
    return ChordReading(
      candidates: scored.take(detector.maxCandidates).toList(),
      chroma: combined,
      energy: energy,
      bassPc: bass,
    );
  }

  static int? _voteBass(List<ChordReading> readings) {
    final ballot = <int, int>{};
    for (final r in readings) {
      final b = r.bassPc;
      if (b != null) ballot[b] = (ballot[b] ?? 0) + 1;
    }
    if (ballot.isEmpty) return null;
    return ballot.entries.reduce((a, b) {
      if (b.value != a.value) return b.value > a.value ? b : a;
      return a.key <= b.key ? a : b; // deterministic
    }).key;
  }
}
