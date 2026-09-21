// lib/core/audio/crisp_dsp/resample.dart
//
// Linear-interpolation resampling — the per-note pitcher for sampled tracker
// instruments (classic MOD/tracker behaviour: playing a sample faster raises
// its pitch and shortens it). Also the grain resampler used by the granular
// pitch shifter. Pure Dart, Float64.

import 'dart:math';
import 'dart:typed_data';

/// Resamples [src] by [ratio] using linear interpolation. [ratio] is a playback
/// speed multiplier: `2.0` plays twice as fast (one octave up, half as long),
/// `0.5` half as fast (one octave down, twice as long). For a tracker note,
/// `ratio = targetFreq / baseFreq`. Returns a new buffer of length
/// `src.length / ratio`.
Float64List resampleLinear(Float64List src, double ratio) {
  if (ratio <= 0 || src.isEmpty) return Float64List(0);
  final outLen = (src.length / ratio).floor();
  final out = Float64List(outLen);
  for (var i = 0; i < outLen; i++) {
    final srcIndex = i * ratio;
    final f = srcIndex.floor();
    final c = min(f + 1, src.length - 1);
    final frac = srcIndex - f;
    out[i] = src[f] * (1 - frac) + src[c] * frac;
  }
  return out;
}

/// Resamples [src] by [ratio] using **4-point cubic (Catmull-Rom) interpolation**
/// — same semantics as [resampleLinear] (ratio = playback-speed multiplier,
/// output length `src.length / ratio`) but smoother: the C1-continuous cubic fits
/// the two samples on each side, so a pitched sample has far less interpolation
/// hiss than the piecewise-linear version. This is the pitcher for sampled
/// instruments (a borrowed module sample, the recorded voice). Endpoints clamp
/// the neighbour taps to the sample bounds.
Float64List resampleCubic(Float64List src, double ratio) {
  if (ratio <= 0 || src.isEmpty) return Float64List(0);
  final n = src.length;
  if (n == 1) return Float64List.fromList([src[0]]);
  final outLen = (n / ratio).floor();
  final out = Float64List(outLen);
  for (var i = 0; i < outLen; i++) {
    final srcIndex = i * ratio;
    final f = srcIndex.floor();
    final t = srcIndex - f;
    final p0 = src[max(f - 1, 0)];
    final p1 = src[f];
    final p2 = src[min(f + 1, n - 1)];
    final p3 = src[min(f + 2, n - 1)];
    // Catmull-Rom: 0.5·(2p1 + (-p0+p2)t + (2p0-5p1+4p2-p3)t² + (-p0+3p1-3p2+p3)t³)
    final t2 = t * t;
    final t3 = t2 * t;
    out[i] = 0.5 *
        (2 * p1 +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
  }
  return out;
}

/// Cubic (Catmull-Rom) read of [src] at fractional position [pos], with the
/// neighbour taps clamped to the sample bounds. Shared by the glide resampler.
double _cubicAt(Float64List src, double pos) {
  final n = src.length;
  final f = pos.floor();
  final t = pos - f;
  final p0 = src[max(f - 1, 0)];
  final p1 = src[f.clamp(0, n - 1)];
  final p2 = src[min(f + 1, n - 1)];
  final p3 = src[min(f + 2, n - 1)];
  final t2 = t * t;
  final t3 = t2 * t;
  return 0.5 *
      (2 * p1 +
          (-p0 + p2) * t +
          (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
          (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
}

/// Resamples [src] with a playback ratio that GLIDES linearly from [ratioStart]
/// to [ratioEnd] over the first [glideSamples] output samples, then holds at
/// [ratioEnd] — a pitch envelope (scoop/fall). Produces up to [outLen] samples,
/// stopping early if the read position runs off the end of [src]. Cubic-
/// interpolated, same semantics as [resampleCubic] when ratioStart == ratioEnd.
Float64List resampleGlide(
  Float64List src, {
  required double ratioStart,
  required double ratioEnd,
  required int glideSamples,
  required int outLen,
}) {
  if (src.isEmpty || outLen <= 0 || ratioStart <= 0 || ratioEnd <= 0) {
    return Float64List(0);
  }
  if (src.length == 1) return Float64List.fromList([src[0]]);
  final out = Float64List(outLen);
  var pos = 0.0;
  var produced = 0;
  for (var i = 0; i < outLen; i++) {
    if (pos >= src.length - 1) break;
    final ratio = (glideSamples > 0 && i < glideSamples)
        ? ratioStart + (ratioEnd - ratioStart) * (i / glideSamples)
        : ratioEnd;
    out[i] = _cubicAt(src, pos);
    pos += ratio;
    produced = i + 1;
  }
  return produced == outLen ? out : Float64List.sublistView(out, 0, produced);
}

// ---------------------------------------------------------------------------
// Band-limited rate conversion — A6.
//
// Everything above is an INTERPOLATOR: given a fractional read position, guess
// the value between two samples. That is the right tool for pitching a tracker
// sample, and the wrong one for changing the sample RATE, because it says
// nothing about the frequencies the new rate cannot represent. Downsample
// 44.1 kHz to 22.05 kHz with cubic interpolation and every partial above
// 11 kHz folds back into the audible band as an alias — a cymbal becomes a
// descending whistle, and no later processing can remove it, because by then
// the alias and the music occupy the same frequencies.
//
// The fix is the classic one: convolve with a band-limited kernel whose cutoff
// is the LOWER of the two Nyquist limits, so the content that cannot survive is
// removed BEFORE it can fold. Implemented from the published theory of
// band-limited interpolation (a windowed sinc evaluated at the fractional
// output positions), not from any existing implementation.

/// How much filter to spend on a rate conversion.
///
/// The tiers differ only in how many sinc lobes each output sample sees, which
/// buys stopband depth and transition sharpness at a linear cost in time. They
/// are named for the decision rather than the tap count because the tap count
/// also depends on the ratio.
enum ResampleQuality {
  /// 8 lobes a side. Audibly clean for gentle ratios; the cheapest tier worth
  /// having over plain interpolation.
  fast,

  /// 16 lobes a side. The default — inaudible aliasing for ordinary export
  /// ratios at a cost nobody notices on a bounce.
  good,

  /// 32 lobes a side. For archival downsampling, where the extra stopband
  /// depth matters more than the wait.
  best,
}

int _lobesFor(ResampleQuality q) => switch (q) {
      ResampleQuality.fast => 8,
      ResampleQuality.good => 16,
      ResampleQuality.best => 32,
    };

/// Convert [src] from [fromRate] to [toRate] with proper anti-aliasing.
///
/// Output length is `src.length * toRate / fromRate`, rounded down. The kernel's
/// cutoff is the lower of the two Nyquist limits, which is what makes a
/// DOWNsample alias-free; upsampling needs no extra filtering (there is nothing
/// above the source Nyquist to fold) but goes through the same path so the two
/// directions cannot drift apart.
///
/// Equal rates return the input untouched rather than running a unity filter
/// over it — a no-op that costs a rounding error is still not a no-op.
Float64List resampleHq(
  Float64List src, {
  required double fromRate,
  required double toRate,
  ResampleQuality quality = ResampleQuality.good,
}) {
  if (src.isEmpty || fromRate <= 0 || toRate <= 0) return Float64List(0);
  if (fromRate == toRate) return src;

  // Source samples consumed per output sample. >1 is a downsample.
  final step = fromRate / toRate;
  final outLen = (src.length / step).floor();
  if (outLen <= 0) return Float64List(0);

  // Cutoff as a fraction of the SOURCE Nyquist. Downsampling pulls it down to
  // the destination's Nyquist — this single line is the whole anti-aliasing
  // story. Upsampling leaves it at 1: there is nothing above the source Nyquist
  // to remove, and lowering it would just dull the result.
  final cutoff = step > 1 ? 1 / step : 1.0;

  // The window has to widen as the cutoff narrows, or the transition band
  // widens with it and the filter stops being sharp exactly when it matters.
  final lobes = _lobesFor(quality);
  final halfWidth = lobes / cutoff;

  final out = Float64List(outLen);
  final n = src.length;
  for (var i = 0; i < outLen; i++) {
    final centre = i * step;
    final first = (centre - halfWidth).ceil();
    final last = (centre + halfWidth).floor();
    var acc = 0.0;
    var norm = 0.0;
    for (var k = first; k <= last; k++) {
      final x = centre - k;
      // Windowed sinc. The Blackman window is the same choice the FIR designer
      // makes, and for the same reason: ~−74 dB stopband is what makes the
      // removed content inaudible rather than merely quiet.
      final w = 0.42 +
          0.5 * cos(pi * x / halfWidth) +
          0.08 * cos(2 * pi * x / halfWidth);
      final arg = pi * cutoff * x;
      final s = x == 0 ? cutoff : sin(arg) / (pi * x);
      final tap = s * w;
      norm += tap;
      // Reading past either end clamps rather than wrapping or zeroing: zeros
      // would put a click at both edges of every converted file.
      acc += tap * src[k.clamp(0, n - 1)];
    }
    // Normalising per output sample keeps the gain exactly unity even where the
    // kernel is truncated by the ends of the buffer, which is where an
    // un-normalised version fades out.
    out[i] = norm.abs() > 1e-12 ? acc / norm : acc;
  }
  return out;
}

/// Rate conversion with the anti-aliasing deliberately turned OFF — the raw
/// up/downsample.
///
/// This is not a cheaper [resampleHq]; it is a different, audible effect, and
/// the only honest reason to offer it is that the aliasing IS the point: it is
/// how early samplers sounded, and folding a bright source down to 8 kHz is a
/// recognisable lo-fi voice. Named so nobody reaches for it expecting quality.
Float64List resampleRaw(
  Float64List src, {
  required double fromRate,
  required double toRate,
}) {
  if (src.isEmpty || fromRate <= 0 || toRate <= 0) return Float64List(0);
  if (fromRate == toRate) return src;
  return resampleCubic(src, fromRate / toRate);
}
