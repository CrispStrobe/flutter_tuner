// lib/core/audio/transcription/rmvpe_mel.dart
//
// Mel-spectrogram front-end for RMVPE — reproduces the RVC MelSpectrogram the
// RMVPE ONNX was trained/exported with: `log(clamp(mel_basis · |STFT|, 1e-5))`,
// STFT n_fft=1024, hop=160, Hann window, centered (reflect pad), 128 HTK-mel
// bins (fmin 30, fmax 8000) at 16 kHz.
//
// The mel filterbank + Hann window ship as a compact asset (from librosa,
// exact); the STFT uses the app's radix-2 FFT.
//
// WEB-SAFE: pure Dart (the app FFT + `dart:typed_data`); the filterbank arrives
// as bytes (the native store downloads it). No dart:io.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'chroma_analysis.dart' show fft;

const int rmvpeSampleRate = 16000;
const int rmvpeHop = 160; // 10 ms
const double _clamp = 1e-5;

/// The RMVPE mel filterbank (`[nMels × nFreq]`) + Hann window, parsed from the
/// `rmvpe-mel.bin` asset.
class RmvpeMel {
  RmvpeMel({
    required this.nMels,
    required this.nFft,
    required this.nFreq,
    required this.hop,
    required this.melBasis,
    required this.hann,
  });

  final int nMels; // 128
  final int nFft; // 1024
  final int nFreq; // 513
  final int hop; // 160
  final Float32List melBasis; // [nMels * nFreq] row-major
  final Float32List hann; // [nFft]

  /// Parse the little-endian asset:
  /// `int32[4]{nMels,nFft,nFreq,hop} · float32[nMels·nFreq]melBasis · float32[nFft]hann`.
  factory RmvpeMel.fromBytes(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    var p = 0;
    int i32() {
      final v = d.getInt32(p, Endian.little);
      p += 4;
      return v;
    }

    final nMels = i32();
    final nFft = i32();
    final nFreq = i32();
    final hop = i32();
    final melBasis = Float32List(nMels * nFreq);
    for (var j = 0; j < melBasis.length; j++) {
      melBasis[j] = d.getFloat32(p, Endian.little);
      p += 4;
    }
    final hann = Float32List(nFft);
    for (var j = 0; j < nFft; j++) {
      hann[j] = d.getFloat32(p, Endian.little);
      p += 4;
    }
    return RmvpeMel(
      nMels: nMels,
      nFft: nFft,
      nFreq: nFreq,
      hop: hop,
      melBasis: melBasis,
      hann: hann,
    );
  }
}

/// Compute the RMVPE log-mel for [audio16k] (mono, 16 kHz). Returns
/// `(logMel, nFrames)` where logMel is row-major `[nMels × nFrames]` (mel-major,
/// matching the model input `[1, nMels, nFrames]`).
(Float32List, int) rmvpeLogMel(RmvpeMel mb, Float64List audio16k) {
  final nFft = mb.nFft, hop = mb.hop, nMels = mb.nMels, nFreq = mb.nFreq;
  final half = nFft ~/ 2;
  final len = audio16k.length;
  // Center like torch.stft(center=True, pad_mode='reflect').
  final padded = Float64List(len + nFft);
  padded.setRange(half, half + len, audio16k);
  int refl(int i) {
    // numpy/torch 'reflect': mirror without repeating the boundary.
    if (len <= 1) return 0;
    var j = i;
    while (j < 0 || j >= len) {
      if (j < 0) j = -j;
      if (j >= len) j = 2 * (len - 1) - j;
    }
    return j;
  }

  for (var i = 0; i < half; i++) {
    padded[i] = audio16k[refl(i - half)]; // left reflect (i-half < 0)
    padded[half + len + i] = audio16k[refl(len + i)]; // right reflect
  }

  final nFrames = 1 + len ~/ hop;
  final logMel = Float32List(nMels * nFrames);
  final re = Float64List(nFft), im = Float64List(nFft);
  for (var t = 0; t < nFrames; t++) {
    final start = t * hop;
    for (var i = 0; i < nFft; i++) {
      re[i] = padded[start + i] * mb.hann[i]; // window
      im[i] = 0.0;
    }
    fft(re, im); // in-place radix-2, unscaled
    // magnitude of the first nFreq bins
    final mag = Float64List(nFreq);
    for (var f = 0; f < nFreq; f++) {
      mag[f] = math.sqrt(re[f] * re[f] + im[f] * im[f]);
    }
    for (var m = 0; m < nMels; m++) {
      final mo = m * nFreq;
      var acc = 0.0;
      for (var f = 0; f < nFreq; f++) {
        acc += mb.melBasis[mo + f] * mag[f];
      }
      logMel[m * nFrames + t] = math.log(acc < _clamp ? _clamp : acc);
    }
  }
  return (logMel, nFrames);
}
