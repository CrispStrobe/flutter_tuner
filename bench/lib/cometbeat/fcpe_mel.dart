// lib/core/audio/transcription/fcpe_mel.dart
//
// Mel front-end + cent table for FCPE — reproduces torchfcpe's MelModule:
// pad by (win−hop)/2 reflect (center=False), STFT n_fft=1024, hop=160, Hann,
// magnitude `sqrt(re²+im²+1e-9)`, 128 SLANEY-mel bins (fmin 0, fmax 8000) at
// 16 kHz, then `log(clamp(mel, 1e-5))`. Output is frame-major `[T × nMels]`
// (FCPE feeds the model `[1, T, nMels]`, unlike RMVPE's `[1, nMels, T]`).
//
// The slaney mel filterbank, Hann window, and the 360-bin `cent_table`
// (linspace of f0_min→f0_max cents) ship as a compact asset.
//
// WEB-SAFE: pure Dart (the app FFT + typed_data); the asset arrives as bytes.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'chroma_analysis.dart' show fft;

const int fcpeSampleRate = 16000;
const int fcpeHop = 160;
const double _clamp = 1e-5;

/// FCPE's mel filterbank (`[nMels × nFreq]`), Hann window, and 360-bin
/// `centTable`, parsed from the `fcpe_mel.bin` asset.
class FcpeAssets {
  FcpeAssets({
    required this.nMels,
    required this.nFft,
    required this.nFreq,
    required this.hop,
    required this.melBasis,
    required this.hann,
    required this.centTable,
  });

  final int nMels; // 128
  final int nFft; // 1024
  final int nFreq; // 513
  final int hop; // 160
  final Float32List melBasis; // [nMels * nFreq]
  final Float32List hann; // [nFft]
  final Float32List centTable; // [360] — bin → cents

  /// Parse: `int32[4]{nMels,nFft,nFreq,hop} · float32[nMels·nFreq]melBasis ·`
  /// `float32[nFft]hann · float32[360]centTable`.
  factory FcpeAssets.fromBytes(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    var p = 0;
    int i32() {
      final v = d.getInt32(p, Endian.little);
      p += 4;
      return v;
    }

    double f32() {
      final v = d.getFloat32(p, Endian.little);
      p += 4;
      return v;
    }

    final nMels = i32(), nFft = i32(), nFreq = i32(), hop = i32();
    final melBasis = Float32List(nMels * nFreq);
    for (var j = 0; j < melBasis.length; j++) {
      melBasis[j] = f32();
    }
    final hann = Float32List(nFft);
    for (var j = 0; j < nFft; j++) {
      hann[j] = f32();
    }
    final centTable = Float32List(360);
    for (var j = 0; j < 360; j++) {
      centTable[j] = f32();
    }
    return FcpeAssets(
      nMels: nMels,
      nFft: nFft,
      nFreq: nFreq,
      hop: hop,
      melBasis: melBasis,
      hann: hann,
      centTable: centTable,
    );
  }
}

/// Compute FCPE's log-mel for [audio16k] (mono, 16 kHz). Returns
/// `(logMel, nFrames)` where logMel is row-major `[nFrames × nMels]`
/// (frame-major, matching the model input `[1, nFrames, nMels]`).
(Float32List, int) fcpeLogMel(FcpeAssets a, Float64List audio16k) {
  final nFft = a.nFft, hop = a.hop, nMels = a.nMels, nFreq = a.nFreq;
  final len = audio16k.length;
  // torchfcpe pad: (win−hop)/2 each side, reflect, then STFT center=False.
  final padL = (nFft - hop) ~/ 2;
  final padR = (nFft - hop + 1) ~/ 2;
  final plen = len + padL + padR;
  final padded = Float64List(plen);
  padded.setRange(padL, padL + len, audio16k);
  int refl(int i) {
    if (len <= 1) return 0;
    var j = i;
    while (j < 0 || j >= len) {
      if (j < 0) j = -j;
      if (j >= len) j = 2 * (len - 1) - j;
    }
    return j;
  }

  for (var i = 0; i < padL; i++) {
    padded[i] = audio16k[refl(i - padL)];
  }
  for (var i = 0; i < padR; i++) {
    padded[padL + len + i] = audio16k[refl(len + i)];
  }

  final nFrames = 1 + (plen - nFft) ~/ hop;
  final logMel = Float32List(nFrames * nMels);
  final re = Float64List(nFft), im = Float64List(nFft);
  for (var t = 0; t < nFrames; t++) {
    final start = t * hop;
    for (var i = 0; i < nFft; i++) {
      re[i] = padded[start + i] * a.hann[i];
      im[i] = 0.0;
    }
    fft(re, im);
    final mag = Float64List(nFreq);
    for (var f = 0; f < nFreq; f++) {
      mag[f] = math.sqrt(re[f] * re[f] + im[f] * im[f] + 1e-9);
    }
    final base = t * nMels; // frame-major
    for (var m = 0; m < nMels; m++) {
      final mo = m * nFreq;
      var acc = 0.0;
      for (var f = 0; f < nFreq; f++) {
        acc += a.melBasis[mo + f] * mag[f];
      }
      logMel[base + m] = math.log(acc < _clamp ? _clamp : acc);
    }
  }
  return (logMel, nFrames);
}
