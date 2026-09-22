// A log-mel front end, in Dart, matching `torchaudio.transforms.MelSpectrogram`.
//
// Two of the exported ONNX graphs (§31) take a spectrogram rather than raw
// audio, which is the whole reason they had never been scored: Kong's graph
// carries its own torchlibrosa STFT inside, and Basic Pitch takes samples, so
// until now nothing here needed a mel. hFT-Transformer and Onsets & Frames
// both do, and both were trained on `torchaudio`'s, so this reproduces that
// one rather than librosa's defaults — the two differ in ways (periodic
// window, `slaney` filter normalisation, `htk` mel scale) that are each
// individually small and together are not.
//
// Validated against `librosa` on real audio by `test/mel_test.dart`'s
// companion (`tool/mel_reference.py`); a front-end mismatch is invisible in
// the output of a model — it simply scores worse — which is exactly the kind
// of error §12.1 warns about.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// How the signal is padded before the first and after the last full frame.
///
/// `torch.stft(center: true)` pads `nFft ~/ 2` on each side. hFT's dataset
/// config asks for `constant`, Onsets & Frames takes torchaudio's default
/// `reflect`; they are not interchangeable at the edges of a piece.
enum MelPad { reflect, constant }

/// Hertz to mel, the HTK formula — `torchaudio`'s default `mel_scale`.
double _hzToMel(double hz) => 2595.0 * (math.log(1.0 + hz / 700.0) / math.ln10);

double _melToHz(double mel) => 700.0 * (math.pow(10.0, mel / 2595.0) - 1.0);

/// A triangular mel filterbank, `norm: 'slaney'`, `mel_scale: 'htk'`.
///
/// Returned as `[nMels][nFreqs]`, the shape the projection wants.
List<Float64List> melFilterbank({
  required int sampleRate,
  required int nFft,
  required int nMels,
  required double fMin,
  required double fMax,
}) {
  final nFreqs = nFft ~/ 2 + 1;
  final allFreqs = Float64List(nFreqs);
  for (int i = 0; i < nFreqs; i++) {
    allFreqs[i] = i * sampleRate / nFft;
  }
  final mMin = _hzToMel(fMin);
  final mMax = _hzToMel(fMax);
  final fPts = Float64List(nMels + 2);
  for (int i = 0; i < nMels + 2; i++) {
    fPts[i] = _melToHz(mMin + (mMax - mMin) * i / (nMels + 1));
  }
  final fb = [for (int m = 0; m < nMels; m++) Float64List(nFreqs)];
  for (int m = 0; m < nMels; m++) {
    final lower = fPts[m], centre = fPts[m + 1], upper = fPts[m + 2];
    final downDiff = centre - lower;
    final upDiff = upper - centre;
    // `slaney` normalisation: each filter is scaled to unit *area* rather
    // than unit peak, which is a factor of two to three across the band.
    final enorm = 2.0 / (upper - lower);
    for (int k = 0; k < nFreqs; k++) {
      final f = allFreqs[k];
      final down = (f - lower) / downDiff;
      final up = (upper - f) / upDiff;
      final v = math.min(down, up);
      fb[m][k] = v > 0 ? v * enorm : 0.0;
    }
  }
  return fb;
}

/// `torchaudio.transforms.MelSpectrogram`, frame-major.
///
/// [compute] returns `[frames][nMels]` — the transpose of torchaudio's own
/// layout, because every consumer here wants a frame at a time.
class MelSpectrogram {
  final int sampleRate;
  final int nFft;
  final int winLength;
  final int hopLength;
  final int nMels;
  final double power;
  final MelPad pad;

  final Float64List _window;
  final List<Float64List> _fb;
  final FFT _fft;

  MelSpectrogram({
    required this.sampleRate,
    required this.nFft,
    required this.winLength,
    required this.hopLength,
    required this.nMels,
    double fMin = 0.0,
    double? fMax,
    this.power = 2.0,
    this.pad = MelPad.reflect,
  })  : _window = Float64List(winLength),
        _fb = melFilterbank(
          sampleRate: sampleRate,
          nFft: nFft,
          nMels: nMels,
          fMin: fMin,
          fMax: fMax ?? sampleRate / 2,
        ),
        _fft = FFT(nFft) {
    // `torch.hann_window` is PERIODIC by default (divide by N, not N-1).
    for (int i = 0; i < winLength; i++) {
      _window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / winLength);
    }
  }

  /// Number of frames `torch.stft(center: true)` produces for [length]
  /// samples: `1 + length ~/ hop`.
  int frameCount(int length) => 1 + length ~/ hopLength;

  List<Float64List> compute(Float64List audio) {
    final half = nFft ~/ 2;
    final padded = Float64List(audio.length + 2 * half);
    for (int i = 0; i < audio.length; i++) {
      padded[half + i] = audio[i];
    }
    if (pad == MelPad.reflect) {
      for (int i = 0; i < half; i++) {
        // `reflect` excludes the edge sample itself, as numpy and torch do.
        padded[half - 1 - i] = audio[math.min(i + 1, audio.length - 1)];
        padded[half + audio.length + i] =
            audio[math.max(audio.length - 2 - i, 0)];
      }
    }
    final frames = frameCount(audio.length);
    final nFreqs = nFft ~/ 2 + 1;
    final out = <Float64List>[];
    final buf = Float64List(nFft);
    final mag = Float64List(nFreqs);
    for (int f = 0; f < frames; f++) {
      final start = f * hopLength;
      for (int i = 0; i < nFft; i++) {
        buf[i] = 0;
      }
      // winLength <= nFft, centred in the FFT buffer as torch does it.
      final off = (nFft - winLength) ~/ 2;
      for (int i = 0; i < winLength; i++) {
        final j = start + i;
        buf[off + i] = j < padded.length ? padded[j] * _window[i] : 0.0;
      }
      final spec = _fft.realFft(buf);
      for (int k = 0; k < nFreqs; k++) {
        final c = spec[k];
        final m = math.sqrt(c.x * c.x + c.y * c.y);
        mag[k] = power == 1.0 ? m : (power == 2.0 ? m * m : math.pow(m, power).toDouble());
      }
      final row = Float64List(nMels);
      for (int m = 0; m < nMels; m++) {
        final filt = _fb[m];
        double s = 0;
        for (int k = 0; k < nFreqs; k++) {
          s += filt[k] * mag[k];
        }
        row[m] = s;
      }
      out.add(row);
    }
    return out;
  }
}

/// `torchaudio.functional.resample`, the Kaiser-free `sinc_interp_hann` form.
///
/// The linear interpolation `bin/transcribe_eval.dart` uses for Basic Pitch
/// has no anti-aliasing filter at all. At 44.1 kHz into 22.05 kHz that is
/// survivable; into 16 kHz it folds everything above 8 kHz back into the mel
/// band these two models read, so it is worth the forty lines.
class SincResampler {
  final int origFreq;
  final int newFreq;
  final int width;
  final List<Float64List> _kernels;

  factory SincResampler(int from, int to, {int filterWidth = 6}) {
    int g = _gcd(from, to);
    final o = from ~/ g, n = to ~/ g;
    const rolloff = 0.99;
    final baseFreq = math.min(o, n) * rolloff;
    final width = (filterWidth * o / baseFreq).ceil();
    final kernels = <Float64List>[];
    for (int i = 0; i < n; i++) {
      final k = Float64List(2 * width + o);
      for (int j = 0; j < k.length; j++) {
        final idx = (j - width) / o;
        var t = (-i / n + idx) * baseFreq;
        t = t.clamp(-filterWidth.toDouble(), filterWidth.toDouble());
        final w = math.pow(math.cos(t * math.pi / filterWidth / 2), 2).toDouble();
        t *= math.pi;
        final s = t == 0 ? 1.0 : math.sin(t) / t;
        k[j] = s * w * baseFreq / o;
      }
      kernels.add(k);
    }
    return SincResampler._(o, n, width, kernels);
  }

  SincResampler._(this.origFreq, this.newFreq, this.width, this._kernels);

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  Float64List apply(Float64List input) {
    final outLen = (input.length * newFreq / origFreq).ceil();
    final out = Float64List(outLen);
    final klen = 2 * width + origFreq;
    for (int m = 0; m < outLen; m++) {
      final block = m ~/ newFreq;
      final phase = m % newFreq;
      final k = _kernels[phase];
      final base = block * origFreq - width;
      double s = 0;
      int jStart = 0;
      if (base < 0) jStart = -base;
      int jEnd = klen;
      if (base + jEnd > input.length) jEnd = input.length - base;
      for (int j = jStart; j < jEnd; j++) {
        s += k[j] * input[base + j];
      }
      out[m] = s;
    }
    return out;
  }
}

/// Resample [audio] from [from] Hz to [to] Hz, or hand it back unchanged.
Float64List resampleTo(Float64List audio, int from, int to) =>
    from == to ? audio : SincResampler(from, to).apply(audio);
