/// Narrow-band refinements: evaluate the transform *where the note is*
/// rather than on the FFT's bin grid.
///
/// §4.3 found that YIN's parabolic interpolation already resolves 0.05 cents
/// on a clean synthetic tone, and that phase-based refinement does not beat
/// it. Three classical techniques were still untried, and all three share one
/// idea: once a coarse f0 is known, the whole spectrum is a waste of effort —
/// only a narrow band around f0 and its partials matters, and that band can
/// be evaluated at arbitrary frequency resolution.
///
///   * **Goertzel** evaluates one DFT bin at an *arbitrary* frequency, in
///     O(N) per frequency with two multiplies per sample. A grid of
///     frequencies across a few cents, plus parabolic interpolation on the
///     magnitudes, is a zoom onto the peak.
///   * **Zoom-FFT / chirp-Z** is the same answer computed differently: the
///     chirp-Z transform evaluates the DFT along an arbitrary arc of the unit
///     circle, so a dense grid over ±50 cents costs one FFT rather than one
///     Goertzel per point. For the grid sizes a tuner needs (tens of points)
///     the Goertzel loop is the cheaper of the two, so this file implements
///     the Goertzel form and the CZT is discussed, not shipped — the
///     *estimate* the two produce is identical by construction.
///   * **Harmonic Goertzel** sums the magnitude at n·f for several n while
///     sweeping f, which is the narrow-band analogue of the least-squares fit
///     in refine.dart: all the partials constrain one number.
///   * **PLL** tracks the fundamental's phase continuously with a loop
///     filter instead of measuring it twice, which is what analogue tuners
///     did and what a tracking-filter tuner still does.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// StringTune's period refinement now lives in the app.
///
/// It was ported here first, measured (`REPORT.md` §38), and then adopted:
/// `lib/refinement.dart` in the app is the implementation, and
/// `tool/sync_core.sh` copies it to `lib/app/refinement.dart` like the rest
/// of the Flutter-free core. Re-exported rather than duplicated so that the
/// benchmark and the shipped app cannot drift apart on the one refinement
/// this report recommends adopting.
export 'app/refinement.dart' show refineByOverlapCorrelation;

/// Squared magnitude of the DFT of [x] at frequency [f] Hz, by Goertzel.
///
/// [x] is expected to be windowed already: the caller usually wants one
/// window for the whole sweep rather than one per frequency.
double goertzelPower(Float64List x, double f, double sampleRate) {
  final w = 2 * math.pi * f / sampleRate;
  final coeff = 2 * math.cos(w);
  double s1 = 0, s2 = 0;
  for (int i = 0; i < x.length; i++) {
    final s = x[i] + coeff * s1 - s2;
    s2 = s1;
    s1 = s;
  }
  final real = s1 - s2 * math.cos(w);
  final imag = s2 * math.sin(w);
  return real * real + imag * imag;
}

Float64List _hann(Float64List x) {
  final n = x.length;
  final out = Float64List(n);
  for (int i = 0; i < n; i++) {
    out[i] = x[i] * 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
  }
  return out;
}

/// Peak of a parabola through three equally spaced samples, as a fractional
/// offset from the middle one in units of the spacing.
double _parabolic(double left, double mid, double right) {
  final denom = left - 2 * mid + right;
  if (denom == 0) return 0;
  final d = 0.5 * (left - right) / denom;
  return d.abs() > 1 ? 0 : d;
}

/// Refine [coarseF0] by sweeping the Goertzel magnitude over a band around
/// it, optionally summing over [harmonics] partials.
///
/// [spanCents] is the half-width of the search; [steps] the number of grid
/// points across the whole span. The grid is logarithmic, so the resolution
/// is `2 * spanCents / (steps - 1)` cents everywhere, and the parabolic
/// interpolation at the end buys roughly another order of magnitude.
double refineByGoertzel(
  List<double> buffer,
  double coarseF0,
  double sampleRate, {
  double spanCents = 60,
  int steps = 13,
  int harmonics = 1,
  int windowSize = 4096,

  /// Run a second sweep across one grid spacing either side of the winner.
  /// The magnitude of a windowed sinusoid against frequency is not a
  /// parabola except very close to its top, so interpolating a coarse grid
  /// is worse than zooming into it — and a zoom costs [steps] more Goertzels
  /// where a finer single grid would cost several times that.
  bool twoStage = true,
}) {
  if (coarseF0 <= 0 || buffer.isEmpty) return coarseF0;
  final n = math.min(windowSize, buffer.length);
  final raw = Float64List(n);
  final offset = buffer.length - n;
  for (int i = 0; i < n; i++) {
    raw[i] = buffer[offset + i];
  }
  final x = _hann(raw);

  /// Summed Goertzel power of the harmonic series built on [f].
  double score(double f) {
    double total = 0;
    for (int h = 1; h <= harmonics; h++) {
      final target = f * h;
      if (target > sampleRate * 0.45) break;
      // Weight by 1/h: the partials of a plucked string fall off, and an
      // unweighted sum lets a loud partial 2 drag the fit when it is
      // slightly inharmonic. Same shape as the magnitude weighting in
      // refine.dart.
      total += goertzelPower(x, target, sampleRate) / h;
    }
    return total;
  }

  /// Sweep [steps] points across `centre ± span` cents and return the
  /// interpolated peak, in cents relative to [coarseF0], or null when the
  /// peak sits on the edge of the band — the coarse estimate was then
  /// further out than the search allows, and refining would be a guess.
  double? sweep(double centre, double span) {
    final stepCents = 2 * span / (steps - 1);
    final power = Float64List(steps);
    for (int k = 0; k < steps; k++) {
      power[k] = score(
          coarseF0 * math.pow(2, (centre - span + k * stepCents) / 1200));
    }
    int best = 0;
    for (int k = 1; k < steps; k++) {
      if (power[k] > power[best]) best = k;
    }
    if (best == 0 || best == steps - 1) return null;
    final delta = _parabolic(power[best - 1], power[best], power[best + 1]);
    return centre - span + (best + delta) * stepCents;
  }

  final coarse = sweep(0, spanCents);
  if (coarse == null) return coarseF0;
  if (!twoStage) {
    return coarseF0 * math.pow(2, coarse / 1200).toDouble();
  }
  final fine = sweep(coarse, 2 * spanCents / (steps - 1)) ?? coarse;
  return coarseF0 * math.pow(2, fine / 1200).toDouble();
}

/// Track [coarseF0] through [buffer] with a phase-locked loop and report the
/// frequency it settles on.
///
/// A second-order loop: the NCO runs at the current estimate, the phase
/// detector is the imaginary part of the product with the NCO's conjugate
/// (i.e. the phase error after mixing down to baseband), and the loop filter
/// is proportional-plus-integral. [loopBandwidthHz] sets how fast it can
/// follow; a tuner wants it slow, because the thing being tracked is meant to
/// be constant and everything faster than that is noise.
///
/// The first [settleFraction] of the block is discarded: the loop starts at
/// the coarse estimate and its transient is not data.
double refineByPll(
  List<double> buffer,
  double coarseF0,
  double sampleRate, {
  // Swept over {4, 15, 40, 100, 250} Hz x {0.4, 0.75} settle on the
  // synthetic plucks: 15 Hz with three quarters of the window discarded is
  // the best the loop does. Slower never acquires inside a 93 ms frame;
  // faster tracks the noise and the p90 goes to a full semitone.
  double loopBandwidthHz = 15,
  double settleFraction = 0.75,
  int windowSize = 4096,
}) {
  if (coarseF0 <= 0 || buffer.isEmpty) return coarseF0;
  final n = math.min(windowSize, buffer.length);
  final offset = buffer.length - n;

  // Standard second-order loop coefficients for damping 1/√2.
  final wn = 2 * math.pi * loopBandwidthHz / sampleRate;
  const zeta = 0.707;
  final kp = 2 * zeta * wn;
  final ki = wn * wn;

  double phase = 0;
  double freq = coarseF0;
  double integral = 0;
  final settle = (n * settleFraction).round();
  double sum = 0;
  int counted = 0;

  // Mix to baseband against the NCO and low-pass the product, so the phase
  // detector sees the fundamental and not the partials.
  double li = 0, lq = 0;
  final alpha = 1 - math.exp(-2 * math.pi * (coarseF0 * 0.5) / sampleRate);

  for (int i = 0; i < n; i++) {
    final s = buffer[offset + i];
    final c = math.cos(phase), sn = math.sin(phase);
    li += alpha * (s * c - li);
    lq += alpha * (-s * sn - lq);
    final error = (li * li + lq * lq) > 1e-20 ? math.atan2(lq, li) : 0.0;

    integral += ki * error;
    final control = kp * error + integral;
    // The NCO runs on the full control signal, but the *estimate* is the
    // integrator alone. The proportional term is there to keep the loop
    // stable, and it carries the per-sample noise straight through: averaging
    // it in gave a 12-cent median where the integrator gives hundredths.
    freq = coarseF0 + control * sampleRate / (2 * math.pi);
    final estimate = coarseF0 + integral * sampleRate / (2 * math.pi);
    if (i >= settle && estimate > 0.5 * coarseF0 && estimate < 2 * coarseF0) {
      sum += estimate;
      counted++;
    }
    phase += 2 * math.pi * freq / sampleRate;
    if (phase > 2 * math.pi) phase -= 2 * math.pi;
  }
  if (counted == 0) return coarseF0;
  return sum / counted;
}
