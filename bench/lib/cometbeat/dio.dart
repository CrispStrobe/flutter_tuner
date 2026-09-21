// lib/core/audio/transcription/dio.dart
//
// WORLD **DIO** F0 estimation (Distributed Inline-filter Operation) + the
// **StoneMask** refinement — a robust classical DSP pitch tracker, faithfully
// ported from mmorise/World (BSD) and verified against `pyworld.dio`/`stonemask`.
// A model-free, web-safe F0 method complementing the neural stack (pYIN/CREPE/
// RMVPE/FCPE). Fits the `F0Estimator` seam via `dioF0`.
//
// Uses the app's radix-2 `fft` (power-of-two only — DIO's fft_size is already a
// power of two). Assumes WORLD's default `speed=1` (no decimation), the pyworld
// default.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'chroma_analysis.dart' show fft;
import 'resample.dart';
import 'contracts.dart';
import 'route.dart'
    show F0Estimator;

const double _kCutOff = 50.0;
const double _kLog2 = 0.69314718055994529;
const double _kSafeGuard = 0.000000000001;
const double _kMaximumValue = 100000.0;

int _round(double x) => x > 0 ? (x + 0.5).toInt() : (x - 0.5).toInt();

int _suitableFftSize(int sample) =>
    math.pow(2.0, (math.log(sample) / _kLog2).toInt() + 1).toInt();

int samplesForDio(int fs, int xLength, double framePeriod) =>
    (1000.0 * xLength / fs / framePeriod).toInt() + 1;

/// Nuttall window of length [n] (WORLD's coefficients).
Float64List _nuttall(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    final t = i / (n - 1.0);
    w[i] = 0.355768 -
        0.487396 * math.cos(2.0 * math.pi * t) +
        0.144232 * math.cos(4.0 * math.pi * t) -
        0.012604 * math.cos(6.0 * math.pi * t);
  }
  return w;
}

/// WORLD's `histc` — the bin index (1-based) for each edge in [xi] over the
/// first [xLen] entries of [x] (arrays are over-allocated; [xLen] is logical).
void _histc(
  Float64List x,
  int xLen,
  Float64List xi,
  int xiLen,
  Int32List index,
) {
  var count = 1;
  var i = 0;
  for (; i < xiLen; ++i) {
    index[i] = 1;
    if (xi[i] >= x[0]) break;
  }
  for (; i < xiLen; ++i) {
    if (xi[i] < x[count]) {
      index[i] = count;
    } else {
      index[i--] = count++;
    }
    if (count == xLen) break;
  }
  count--;
  for (i++; i < xiLen; ++i) {
    index[i] = count;
  }
}

/// WORLD's `interp1` — linear interpolation of (x,y) at points [xi].
void _interp1(
  Float64List x,
  Float64List y,
  int xLen,
  Float64List xi,
  int xiLen,
  Float64List yi,
) {
  if (xLen < 2) {
    for (var i = 0; i < xiLen; ++i) {
      yi[i] = 0.0;
    }
    return;
  }
  final h = Float64List(xLen - 1);
  for (var i = 0; i < xLen - 1; ++i) {
    h[i] = x[i + 1] - x[i];
  }
  final k = Int32List(xiLen);
  _histc(x, xLen, xi, xiLen, k);
  for (var i = 0; i < xiLen; ++i) {
    final s = (xi[i] - x[k[i] - 1]) / h[k[i] - 1];
    yi[i] = y[k[i] - 1] + s * (y[k[i]] - y[k[i] - 1]);
  }
}

/// In-place forward radix-2 FFT (delegates to the app FFT).
void _fft(Float64List re, Float64List im) => fft(re, im);

/// Real inverse FFT: real part of ifft(re+i·im), length N (power of two).
Float64List _ifftReal(Float64List re, Float64List im, int n) {
  final r = Float64List(n), ii = Float64List(n);
  for (var i = 0; i < n; i++) {
    r[i] = re[i];
    ii[i] = -im[i];
  }
  fft(r, ii);
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r[i] / n;
  }
  return out;
}

Float64List _designLowCutFilter(int nn, int fftSize) {
  final f = Float64List(fftSize);
  for (var i = 1; i <= nn; ++i) {
    f[i - 1] = 0.5 - 0.5 * math.cos(i * 2.0 * math.pi / (nn + 1));
  }
  var sum = 0.0;
  for (var i = 0; i < nn; ++i) {
    sum += f[i];
  }
  for (var i = 0; i < nn; ++i) {
    f[i] = -f[i] / sum;
  }
  final half = (nn - 1) ~/ 2;
  for (var i = 0; i < half; ++i) {
    f[fftSize - half + i] = f[i];
  }
  for (var i = 0; i < nn; ++i) {
    f[i] = f[i + half];
  }
  f[0] += 1.0;
  return f;
}

/// The DC-removed, low-cut-filtered spectrum used for all bands.
(Float64List, Float64List) _spectrumForEstimation(
  Float64List x,
  int xLength,
  double actualFs,
  int fftSize,
) {
  final yr = Float64List(fftSize), yi = Float64List(fftSize);
  var mean = 0.0;
  for (var i = 0; i < xLength; ++i) {
    mean += x[i];
  }
  mean /= xLength;
  for (var i = 0; i < xLength; ++i) {
    yr[i] = x[i] - mean;
  }
  _fft(yr, yi); // y_spectrum

  final cutoff = _round(actualFs / _kCutOff);
  final filt = _designLowCutFilter(cutoff * 2 + 1, fftSize);
  final fr = Float64List.fromList(filt), fi = Float64List(fftSize);
  _fft(fr, fi); // filter_spectrum

  final sr = Float64List(fftSize), si = Float64List(fftSize);
  for (var i = 0; i <= fftSize ~/ 2; ++i) {
    sr[i] = yr[i] * fr[i] - yi[i] * fi[i];
    si[i] = yr[i] * fi[i] + yi[i] * fr[i];
  }
  return (sr, si);
}

/// The band-pass-filtered signal for one band (Nuttall LP + delay comp).
Float64List _filteredSignal(
  int halfAverageLength,
  int fftSize,
  Float64List specR,
  Float64List specI,
  int yLength,
) {
  final lpf = Float64List(fftSize);
  final nut = _nuttall(halfAverageLength * 4);
  for (var i = 0; i < halfAverageLength * 4; ++i) {
    lpf[i] = nut[i];
  }
  final lr = lpf, li = Float64List(fftSize);
  _fft(lr, li); // low_pass_filter_spectrum

  final cr = Float64List(fftSize), ci = Float64List(fftSize);
  for (var i = 0; i <= fftSize ~/ 2; ++i) {
    cr[i] = specR[i] * lr[i] - specI[i] * li[i];
    ci[i] = specR[i] * li[i] + specI[i] * lr[i];
    if (i >= 1) {
      cr[fftSize - i] = cr[i];
      ci[fftSize - i] = ci[i];
    }
  }
  final sig = _ifftReal(cr, ci, fftSize);
  final indexBias = halfAverageLength * 2;
  final out = Float64List(yLength);
  for (var i = 0; i < yLength; ++i) {
    out[i] = sig[i + indexBias];
  }
  return out;
}

/// ZeroCrossingEngine — negative-going zero crossings → interval Hz + locations.
/// Returns the count; fills [locations]/[intervals].
int _zeroCrossing(
  Float64List sig,
  int yLength,
  double fs,
  Float64List locations,
  Float64List intervals,
) {
  final edges = <int>[];
  for (var i = 0; i < yLength - 1; ++i) {
    if (0.0 < sig[i] && sig[i + 1] <= 0.0) edges.add(i + 1);
  }
  if (edges.length < 2) return 0;
  final fine = Float64List(edges.length);
  for (var i = 0; i < edges.length; ++i) {
    final e = edges[i];
    fine[i] = e - sig[e - 1] / (sig[e] - sig[e - 1]);
  }
  for (var i = 0; i < edges.length - 1; ++i) {
    intervals[i] = fs / (fine[i + 1] - fine[i]);
    locations[i] = (fine[i] + fine[i + 1]) / 2.0 / fs;
  }
  return edges.length - 1;
}

class _ZeroCrossings {
  _ZeroCrossings(int max)
      : negLoc = Float64List(max),
        negInt = Float64List(max),
        posLoc = Float64List(max),
        posInt = Float64List(max),
        peakLoc = Float64List(max),
        peakInt = Float64List(max),
        dipLoc = Float64List(max),
        dipInt = Float64List(max);
  final Float64List negLoc, negInt, posLoc, posInt, peakLoc, peakInt, dipLoc;
  final Float64List dipInt;
  int nNeg = 0, nPos = 0, nPeak = 0, nDip = 0;
}

_ZeroCrossings _fourZeroCrossings(Float64List sig, int yLength, double fs) {
  final z = _ZeroCrossings(yLength);
  z.nNeg = _zeroCrossing(sig, yLength, fs, z.negLoc, z.negInt);
  for (var i = 0; i < yLength; ++i) {
    sig[i] = -sig[i];
  }
  z.nPos = _zeroCrossing(sig, yLength, fs, z.posLoc, z.posInt);
  for (var i = 0; i < yLength - 1; ++i) {
    sig[i] = sig[i] - sig[i + 1];
  }
  z.nPeak = _zeroCrossing(sig, yLength - 1, fs, z.peakLoc, z.peakInt);
  for (var i = 0; i < yLength - 1; ++i) {
    sig[i] = -sig[i];
  }
  z.nDip = _zeroCrossing(sig, yLength - 1, fs, z.dipLoc, z.dipInt);
  return z;
}

int _checkEvent(int x) => x > 0 ? 1 : 0;

void _f0CandidateContour(
  _ZeroCrossings z,
  double boundaryF0,
  double f0Floor,
  double f0Ceil,
  Float64List tPos,
  int f0Length,
  Float64List f0Candidate,
  Float64List f0Score,
) {
  if (0 ==
      _checkEvent(z.nNeg - 2) *
          _checkEvent(z.nPos - 2) *
          _checkEvent(z.nPeak - 2) *
          _checkEvent(z.nDip - 2)) {
    for (var i = 0; i < f0Length; ++i) {
      f0Score[i] = _kMaximumValue;
      f0Candidate[i] = 0.0;
    }
    return;
  }
  final s = List.generate(4, (_) => Float64List(f0Length));
  _interp1(z.negLoc, z.negInt, z.nNeg, tPos, f0Length, s[0]);
  _interp1(z.posLoc, z.posInt, z.nPos, tPos, f0Length, s[1]);
  _interp1(z.peakLoc, z.peakInt, z.nPeak, tPos, f0Length, s[2]);
  _interp1(z.dipLoc, z.dipInt, z.nDip, tPos, f0Length, s[3]);

  for (var i = 0; i < f0Length; ++i) {
    final cand = (s[0][i] + s[1][i] + s[2][i] + s[3][i]) / 4.0;
    f0Candidate[i] = cand;
    var v = 0.0;
    for (var j = 0; j < 4; ++j) {
      v += (s[j][i] - cand) * (s[j][i] - cand);
    }
    f0Score[i] = math.sqrt(v / 3.0);
    if (cand > boundaryF0 ||
        cand < boundaryF0 / 2.0 ||
        cand > f0Ceil ||
        cand < f0Floor) {
      f0Candidate[i] = 0.0;
      f0Score[i] = _kMaximumValue;
    }
  }
}

// ---- FixF0Contour (the 4 postprocessing steps) ----

double _selectBestF0(
  double currentF0,
  double pastF0,
  List<Float64List> candidates,
  int numCands,
  int idx,
  double allowedRange,
) {
  final ref = (currentF0 * 3.0 - pastF0) / 2.0;
  var minErr = (ref - candidates[0][idx]).abs();
  var best = candidates[0][idx];
  for (var i = 1; i < numCands; ++i) {
    final err = (ref - candidates[i][idx]).abs();
    if (err < minErr) {
      minErr = err;
      best = candidates[i][idx];
    }
  }
  if ((1.0 - best / ref).abs() > allowedRange) return 0.0;
  return best;
}

Float64List _fixF0Contour(
  double framePeriod,
  int numCands,
  List<Float64List> candidates,
  Float64List bestContour,
  int f0Length,
  double f0Floor,
  double allowedRange,
) {
  final out = Float64List(f0Length);
  final vrm = (0.5 + 1000.0 / framePeriod / f0Floor).toInt() * 2 + 1;
  if (f0Length <= vrm) return out;

  // FixStep1
  final base = Float64List(f0Length);
  for (var i = vrm; i < f0Length - vrm; ++i) {
    base[i] = bestContour[i];
  }
  final step1 = Float64List(f0Length);
  for (var i = vrm; i < f0Length; ++i) {
    step1[i] =
        (base[i] - base[i - 1]).abs() / (_kSafeGuard + base[i]) < allowedRange
            ? base[i]
            : 0.0;
  }

  // FixStep2
  final step2 = Float64List.fromList(step1);
  final center = (vrm - 1) ~/ 2;
  for (var i = center; i < f0Length - center; ++i) {
    for (var j = -center; j <= center; ++j) {
      if (step1[i + j] == 0) {
        step2[i] = 0.0;
        break;
      }
    }
  }

  // voiced sections
  final posIdx = <int>[], negIdx = <int>[];
  for (var i = 1; i < f0Length; ++i) {
    if (step2[i] == 0 && step2[i - 1] != 0) {
      negIdx.add(i - 1);
    } else if (step2[i - 1] == 0 && step2[i] != 0) {
      posIdx.add(i);
    }
  }

  // FixStep3 (backward→forward)
  final step3 = Float64List.fromList(step2);
  for (var i = 0; i < negIdx.length; ++i) {
    final limit = i == negIdx.length - 1 ? f0Length - 1 : negIdx[i + 1];
    for (var j = negIdx[i]; j < limit; ++j) {
      step3[j + 1] = _selectBestF0(
        step3[j],
        step3[j - 1],
        candidates,
        numCands,
        j + 1,
        allowedRange,
      );
      if (step3[j + 1] == 0) break;
    }
  }

  // FixStep4 (forward→backward)
  for (var i = 0; i < f0Length; ++i) {
    out[i] = step3[i];
  }
  for (var i = posIdx.length - 1; i >= 0; --i) {
    final limit = i == 0 ? 1 : posIdx[i - 1];
    for (var j = posIdx[i]; j > limit; --j) {
      out[j - 1] = _selectBestF0(
        out[j],
        out[j + 1],
        candidates,
        numCands,
        j - 1,
        allowedRange,
      );
      if (out[j - 1] == 0) break;
    }
  }
  return out;
}

/// Raw DIO F0 contour (Hz per frame, 0 = unvoiced) + temporal positions (s).
(Float64List f0, Float64List tPos) dioContour(
  Float64List x, {
  int fs = 16000,
  double framePeriod = 5.0,
  double f0Floor = 71.0,
  double f0Ceil = 800.0,
  double channelsInOctave = 2.0,
  double allowedRange = 0.1,
}) {
  final xLength = x.length;
  final numberOfBands =
      1 + (math.log(f0Ceil / f0Floor) / _kLog2 * channelsInOctave).toInt();
  final boundary = Float64List(numberOfBands);
  for (var i = 0; i < numberOfBands; ++i) {
    boundary[i] = f0Floor * math.pow(2.0, (i + 1) / channelsInOctave);
  }

  const decimationRatio = 1;
  final yLength = 1 + xLength ~/ decimationRatio;
  final actualFs = fs.toDouble();
  final fftSize = _suitableFftSize(
    yLength +
        _round(actualFs / _kCutOff) * 2 +
        1 +
        4 * (1.0 + actualFs / boundary[0] / 2.0).toInt(),
  );

  final (specR, specI) = _spectrumForEstimation(x, xLength, actualFs, fftSize);

  final f0Length = samplesForDio(fs, xLength, framePeriod);
  final tPos = Float64List(f0Length);
  for (var i = 0; i < f0Length; ++i) {
    tPos[i] = i * framePeriod / 1000.0;
  }

  final candidates = List.generate(numberOfBands, (_) => Float64List(f0Length));
  final scores = List.generate(numberOfBands, (_) => Float64List(f0Length));
  final cand = Float64List(f0Length), score = Float64List(f0Length);
  for (var b = 0; b < numberOfBands; ++b) {
    final sig = _filteredSignal(
      _round(actualFs / boundary[b] / 2.0),
      fftSize,
      specR,
      specI,
      yLength,
    );
    final z = _fourZeroCrossings(sig, yLength, actualFs);
    _f0CandidateContour(
      z,
      boundary[b],
      f0Floor,
      f0Ceil,
      tPos,
      f0Length,
      cand,
      score,
    );
    for (var j = 0; j < f0Length; ++j) {
      scores[b][j] = score[j] / (cand[j] + _kSafeGuard);
      candidates[b][j] = cand[j];
    }
  }

  // best contour
  final best = Float64List(f0Length);
  for (var i = 0; i < f0Length; ++i) {
    var tmp = scores[0][i];
    best[i] = candidates[0][i];
    for (var b = 1; b < numberOfBands; ++b) {
      if (tmp > scores[b][i]) {
        tmp = scores[b][i];
        best[i] = candidates[b][i];
      }
    }
  }

  final f0 = _fixF0Contour(
    framePeriod,
    numberOfBands,
    candidates,
    best,
    f0Length,
    f0Floor,
    allowedRange,
  );
  return (f0, tPos);
}

/// DIO as a [PitchTrack] (the `F0Estimator` seam). Resamples to 16 kHz.
PitchTrack dioF0(
  Float64List mono,
  int sampleRate, {
  double framePeriod = 5.0,
  double f0Floor = 71.0,
  double f0Ceil = 800.0,
  bool refine = true,
}) {
  const targetFs = 16000;
  final x = sampleRate == targetFs
      ? mono
      : resampleLinear(mono, sampleRate / targetFs);
  if (x.length < targetFs ~/ 20) return const [];
  final (f0Raw, tPos) = dioContour(
    x,
    framePeriod: framePeriod,
    f0Floor: f0Floor,
    f0Ceil: f0Ceil,
  );
  final f0 = refine ? stoneMask(x, targetFs, tPos, f0Raw) : f0Raw;
  return [
    for (var i = 0; i < f0.length; ++i)
      (
        timeMs: tPos[i] * 1000.0,
        f0Hz: f0[i],
        voicedProb: f0[i] > 0 ? 1.0 : 0.0
      ),
  ];
}

// ---- StoneMask: instantaneous-frequency F0 refinement of the DIO output ----

const double _kFloorF0StoneMask = 40.0;

double _fixF0(
  Float64List power,
  Float64List numeratorI,
  int fftSize,
  int fs,
  double initialF0,
  int numHarmonics,
) {
  final amp = Float64List(numHarmonics);
  final ifreq = Float64List(numHarmonics);
  for (var i = 0; i < numHarmonics; ++i) {
    final index =
        math.min(_round(initialF0 * fftSize / fs * (i + 1)), fftSize ~/ 2);
    ifreq[i] = power[index] == 0.0
        ? 0.0
        : index * fs / fftSize +
            numeratorI[index] / power[index] * fs / 2.0 / math.pi;
    amp[i] = math.sqrt(power[index]);
  }
  var num = 0.0, den = 0.0;
  for (var i = 0; i < numHarmonics; ++i) {
    num += amp[i] * ifreq[i];
    den += amp[i] * (i + 1);
  }
  return num / (den + _kSafeGuard);
}

double _tentativeF0(
  Float64List power,
  Float64List numeratorI,
  int fftSize,
  int fs,
  double initialF0,
) {
  final t = _fixF0(power, numeratorI, fftSize, fs, initialF0, 2);
  if (t <= 0.0 || t > initialF0 * 2) return 0.0;
  return _fixF0(power, numeratorI, fftSize, fs, t, 6);
}

double _meanF0(
  Float64List x,
  int fs,
  double currentPosition,
  double initialF0,
  int fftSize,
  double windowLengthInTime,
  Float64List baseTime,
  int btLen,
) {
  final indexRaw = Int32List(btLen);
  for (var i = 0; i < btLen; ++i) {
    indexRaw[i] = _round((currentPosition + baseTime[i]) * fs);
  }
  final mainWin = Float64List(btLen), diffWin = Float64List(btLen);
  for (var i = 0; i < btLen; ++i) {
    final tmp = (indexRaw[i] - 1.0) / fs - currentPosition;
    mainWin[i] = 0.42 +
        0.5 * math.cos(2.0 * math.pi * tmp / windowLengthInTime) +
        0.08 * math.cos(4.0 * math.pi * tmp / windowLengthInTime);
  }
  diffWin[0] = -mainWin[1] / 2.0;
  for (var i = 1; i < btLen - 1; ++i) {
    diffWin[i] = -(mainWin[i + 1] - mainWin[i - 1]) / 2.0;
  }
  diffWin[btLen - 1] = mainWin[btLen - 2] / 2.0;

  final xLen = x.length;
  final idx = Int32List(btLen);
  for (var i = 0; i < btLen; ++i) {
    idx[i] = math.max(0, math.min(xLen - 1, indexRaw[i] - 1));
  }
  (Float64List, Float64List) spec(Float64List win) {
    final wr = Float64List(fftSize), wi = Float64List(fftSize);
    for (var i = 0; i < btLen; ++i) {
      wr[i] = x[idx[i]] * win[i];
    }
    _fft(wr, wi);
    return (wr, wi);
  }

  final (mr, mi) = spec(mainWin);
  final (dr, di) = spec(diffWin);
  final half = fftSize ~/ 2;
  final power = Float64List(half + 1), numeratorI = Float64List(half + 1);
  for (var j = 0; j <= half; ++j) {
    numeratorI[j] = mr[j] * di[j] - mi[j] * dr[j];
    power[j] = mr[j] * mr[j] + mi[j] * mi[j];
  }
  return _tentativeF0(power, numeratorI, fftSize, fs, initialF0);
}

double _refinedF0(
  Float64List x,
  int fs,
  double currentPosition,
  double initialF0,
) {
  if (initialF0 <= _kFloorF0StoneMask || initialF0 > fs / 12.0) return 0.0;
  final halfWindowLength = (1.5 * fs / initialF0 + 1.0).toInt();
  final windowLengthInTime = (2.0 * halfWindowLength + 1.0) / fs;
  final btLen = halfWindowLength * 2 + 1;
  final baseTime = Float64List(btLen);
  for (var i = 0; i < btLen; ++i) {
    baseTime[i] = (-halfWindowLength + i) / fs;
  }
  final fftSize = math
      .pow(2.0, 2.0 + (math.log(halfWindowLength * 2.0 + 1.0) / _kLog2).toInt())
      .toInt();
  var mean = _meanF0(
    x,
    fs,
    currentPosition,
    initialF0,
    fftSize,
    windowLengthInTime,
    baseTime,
    btLen,
  );
  if ((mean - initialF0).abs() > initialF0 * 0.2) mean = initialF0;
  return mean;
}

/// StoneMask — refine a DIO [f0] contour via instantaneous frequency.
Float64List stoneMask(Float64List x, int fs, Float64List tPos, Float64List f0) {
  final out = Float64List(f0.length);
  for (var i = 0; i < f0.length; ++i) {
    out[i] = _refinedF0(x, fs, tPos[i], f0[i]);
  }
  return out;
}

/// DIO+StoneMask as an [F0Estimator] (route.dart seam).
F0Estimator dioEstimator({bool refine = true}) =>
    (mono, sampleRate) => dioF0(mono, sampleRate, refine: refine);
