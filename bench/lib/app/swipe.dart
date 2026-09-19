/// SWIPE′ — the Sawtooth Waveform Inspired Pitch Estimator (Camacho 2007).
///
/// Offered as a detector option, with its measurements attached so the choice
/// is an informed one. Over the full 180-file corpus (bench/REPORT.md §4.5)
/// it answers on **100%** of frames where YIN answers on 75%, and collects a
/// slightly higher raw pitch accuracy for it — 74.5% against 71.9%. It pays
/// with a false-alarm rate of 100%: it never rejects anything, so the needle
/// moves in a silent room. And on what a tuner is actually for it loses
/// badly — twice YIN's median cent error (7.15 against 3.00) and eight times
/// the gross-error rate.
///
/// Cost is not the objection it was once thought to be: 1.20 ms a frame
/// against YIN's 1.02, measured in the same process on the same frames.
///
/// It is here because it fails differently — spectral rather than lag-domain
/// — and because on an awkward signal a different failure mode is
/// occasionally what you want.
///
/// YIN and MPM both work in the lag domain: they ask how well the waveform
/// resembles itself a period later. SWIPE′ works in the spectral domain and
/// asks a different question — how well does the square-root magnitude
/// spectrum match a cosine kernel placed at the *prime* harmonics of a
/// candidate pitch? Using only primes (1, 2, 3, 5, 7, …) is the prime in
/// SWIPE′, and the reason it was reported to resist octave errors: a kernel
/// at twice the true pitch cannot borrow support from the harmonics it
/// shares, because the shared ones are the even numbers it has dropped.
///
/// It is much more expensive than YIN, and the reason is structural rather
/// than an implementation detail: every candidate pitch wants its own window
/// length (about eight periods), so a proper implementation transforms the
/// signal at several window sizes and interpolates between them. That is
/// several FFTs per frame against YIN's one.
///
/// This is a faithful-in-shape implementation: log-spaced candidates,
/// per-candidate optimal window size with interpolation between the two
/// bracketing power-of-two sizes, square-root spectra, prime-harmonic cosine
/// kernels normalised to unit norm. It is not Camacho's MATLAB, and the
/// numbers here should be read as "SWIPE′-like", not as a reproduction of the
/// paper's.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

import 'detectors.dart';

/// The harmonic numbers the kernel is built from: 1 and the primes.
const List<int> _primeHarmonics = [1, 2, 3, 5, 7, 11, 13, 17, 19, 23];

class SwipeEngine extends PitchEngine {
  final double sampleRate;

  /// Candidate range and resolution. The paper uses 1/96 of an octave; 1/48
  /// is used here, with parabolic interpolation on the strength curve to
  /// recover the rest, because the cost is linear in the candidate count.
  final double minF0;
  final double maxF0;
  final int binsPerOctave;

  /// Pitch strength below which the frame is called unpitched. The paper's
  /// default is 0.2 for speech; it is swept in `bin/swipe.dart` rather than
  /// assumed. Note that the useful range depends on [localNormalisation]:
  /// normalising locally puts almost every frame above 0.75, so the threshold
  /// stops discriminating at all.
  final double strengthThreshold;

  /// Normalise the spectrum over the kernel's own support rather than over
  /// the whole band.
  ///
  /// Both were measured (REPORT.md §12). Neither is clearly better: the local
  /// norm cuts gross errors from 35.2% to 28.4% and halves the median cent
  /// error, while *tripling* octave errors, 1.4% to 4.3%. Both are far worse
  /// than YIN on this corpus, which is the actual finding.
  final bool localNormalisation;

  late final List<double> _candidates;
  final Map<int, FFT> _ffts = {};

  @override
  final int windowSize;

  @override
  DetectorKind get kind => DetectorKind.swipe;

  @override
  double get detectionFloor => minF0;

  SwipeEngine({
    required this.sampleRate,
    required this.windowSize,
    this.minF0 = 40.0,
    this.maxF0 = 1600.0,
    this.binsPerOctave = 48,
    this.strengthThreshold = 0.2,
    this.localNormalisation = true,
  }) {
    final octaves = math.log(maxF0 / minF0) / math.ln2;
    final count = (octaves * binsPerOctave).ceil() + 1;
    _candidates = List<double>.generate(
        count, (i) => minF0 * math.pow(2, i / binsPerOctave).toDouble());
  }

  List<double> get candidates => List.unmodifiable(_candidates);

  /// Square-root magnitude spectrum of the last [size] samples, Hann
  /// windowed. Square root because SWIPE′ matches amplitude, not power —
  /// which is what stops one loud partial from deciding the answer.
  Float64List _sqrtSpectrum(List<double> buffer, int size) {
    final fft = _ffts.putIfAbsent(size, () => FFT(size));
    final frame = Float64List(size);
    final from = buffer.length - size;
    for (int i = 0; i < size; i++) {
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / size);
      frame[i] = (from + i >= 0 ? buffer[from + i] : 0) * w;
    }
    final spectrum = fft.realFft(frame);
    final bins = size ~/ 2;
    final out = Float64List(bins);
    for (int k = 0; k < bins; k++) {
      final re = spectrum[k].x, im = spectrum[k].y;
      out[k] = math.sqrt(math.sqrt(re * re + im * im));
    }
    return out;
  }

  /// Pitch strength of one candidate against one spectrum.
  ///
  /// The kernel is a half-cosine lobe around each prime harmonic, weighted by
  /// 1/sqrt(n) as in the paper, and both kernel and spectrum are normalised,
  /// so the result is a cosine similarity in [-1, 1].
  double _strength(Float64List spectrum, int fftSize, double f0) {
    final binHz = sampleRate / fftSize;
    double dot = 0, kernelNorm = 0, spectrumNorm = 0;

    for (final n in _primeHarmonics) {
      final centre = f0 * n;
      if (centre > sampleRate * 0.45) break;
      final weight = 1 / math.sqrt(n.toDouble());
      // The lobe spans ±f0/2 around the harmonic: wide enough to catch the
      // partial wherever it actually sits, narrow enough not to reach its
      // neighbours.
      final halfWidth = f0 / 2;
      final firstBin = ((centre - halfWidth) / binHz).ceil();
      final lastBin = ((centre + halfWidth) / binHz).floor();
      for (int k = math.max(1, firstBin);
          k <= math.min(spectrum.length - 1, lastBin);
          k++) {
        final offset = (k * binHz - centre) / halfWidth; // in [-1, 1]
        final lobe = weight * math.cos(offset * math.pi / 2);
        dot += lobe * spectrum[k];
        kernelNorm += lobe * lobe;
        if (localNormalisation) {
          spectrumNorm += spectrum[k] * spectrum[k];
        }
      }
    }
    if (kernelNorm <= 0) return 0;
    if (!localNormalisation) {
      for (int k = 1; k < spectrum.length; k++) {
        spectrumNorm += spectrum[k] * spectrum[k];
      }
    }
    if (spectrumNorm <= 0) return 0;
    return dot / (math.sqrt(kernelNorm) * math.sqrt(spectrumNorm));
  }

  /// Estimate the pitch of the audio in [buffer].
  ///
  /// Each candidate is scored at the two power-of-two window sizes that
  /// bracket its ideal (eight periods), and the two scores are blended by how
  /// close each size is — the paper's interpolation, which is what keeps the
  /// strength curve smooth across the size boundaries.
  @override
  PitchEstimate analyse(List<double> buffer) {
    // Which window sizes are needed at all?
    final sizes = <int>{};
    final idealSize = <double>[];
    for (final f0 in _candidates) {
      final ideal = 8 * sampleRate / f0;
      idealSize.add(ideal);
      int lower = 1;
      while (lower * 2 <= ideal) {
        lower *= 2;
      }
      final upper = lower * 2;
      if (lower >= 64 && lower <= buffer.length) sizes.add(lower);
      if (upper >= 64 && upper <= buffer.length) sizes.add(upper);
    }
    if (sizes.isEmpty) return PitchEstimate.unpitched;

    final spectra = <int, Float64List>{
      for (final size in sizes) size: _sqrtSpectrum(buffer, size)
    };

    double bestStrength = -1;
    int bestIndex = -1;
    final strengths = Float64List(_candidates.length);
    for (int i = 0; i < _candidates.length; i++) {
      final f0 = _candidates[i];
      final ideal = idealSize[i];
      int lower = 1;
      while (lower * 2 <= ideal) {
        lower *= 2;
      }
      final upper = lower * 2;
      double total = 0, weightSum = 0;
      for (final size in [lower, upper]) {
        final spectrum = spectra[size];
        if (spectrum == null) continue;
        // Weight by closeness in log size, as the paper interpolates.
        final distance = (math.log(size / ideal) / math.ln2).abs();
        final weight = math.max(0.0, 1 - distance);
        if (weight <= 0) continue;
        total += weight * _strength(spectrum, size, f0);
        weightSum += weight;
      }
      final value = weightSum > 0 ? total / weightSum : 0.0;
      strengths[i] = value;
      if (value > bestStrength) {
        bestStrength = value;
        bestIndex = i;
      }
    }

    if (bestIndex < 0 || bestStrength < strengthThreshold) {
      return PitchEstimate.unpitched;
    }

    // Parabolic interpolation on the strength curve, in log-frequency.
    double refined = bestIndex.toDouble();
    if (bestIndex > 0 && bestIndex < _candidates.length - 1) {
      final a = strengths[bestIndex - 1];
      final b = strengths[bestIndex];
      final c = strengths[bestIndex + 1];
      final denom = a - 2 * b + c;
      if (denom != 0) {
        final shift = 0.5 * (a - c) / denom;
        if (shift.abs() <= 1) refined = bestIndex + shift;
      }
    }
    final frequency =
        minF0 * math.pow(2, refined / binsPerOctave).toDouble();
    return PitchEstimate(frequency, bestStrength.clamp(0.0, 1.0), true);
  }


}
