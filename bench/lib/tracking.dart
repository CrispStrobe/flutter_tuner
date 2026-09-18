/// How far behind is the needle when the pitch is *moving*?
///
/// §9 measures the delay from a pluck to a correct reading. That is the
/// tuner's cold start. The other half of the experience is what happens while
/// you turn the peg: the pitch slides, and the needle follows it at some
/// remove. A player reads that lag as sluggishness, and it is invisible to
/// every frame-level metric in this report — a pipeline that is uniformly
/// 60 ms late scores a perfect RPA.
///
/// GuitarSet contains no peg-turning, but it contains the same signal in a
/// musical form: bends, slides and vibrato, where the annotated pitch moves
/// smoothly within a single sounding string. Measuring how far the detected
/// contour has to be shifted in time to best match the annotated one gives
/// the tracking lag directly.
///
/// The measurement only means something where the reference actually moves.
/// A held note carries no timing information at all — any lag fits a flat
/// line equally well — so segments are required to have real pitch movement
/// before they are counted, and that requirement is what makes the number
/// honest.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'app/detectors.dart';
import 'app/tuner_core.dart';
import 'jams.dart';
import 'metrics.dart';
import 'note_latency.dart' show NotePipeline, Smoothing;
import 'wav.dart';

class TrackingResult {
  /// Best-fitting lag in seconds, positive meaning the detector is *behind*
  /// the reference.
  final double lag;

  /// RMS cent error at that lag.
  final double rmsAtBestLag;

  /// RMS cent error with no shift at all — the difference between the two is
  /// what the lag is costing.
  final double rmsAtZeroLag;

  /// How far the reference moved across the segment, peak to peak, in cents.
  final double movement;

  final int frames;
  const TrackingResult(this.lag, this.rmsAtBestLag, this.rmsAtZeroLag,
      this.movement, this.frames);
}

class TrackingStats {
  final String name;
  final List<double> lags = [];
  final List<double> rmsBest = [];
  final List<double> rmsZero = [];
  int segments = 0;

  TrackingStats(this.name);

  void add(TrackingResult r) {
    segments++;
    // Each list is summarised on its own, so a segment that could not
    // produce one of these contributes to the others rather than being
    // dropped — and JSON cannot carry a NaN in any case.
    if (r.lag.isFinite) lags.add(r.lag);
    if (r.rmsAtBestLag.isFinite) rmsBest.add(r.rmsAtBestLag);
    if (r.rmsAtZeroLag.isFinite) rmsZero.add(r.rmsAtZeroLag);
  }

  void merge(TrackingStats o) {
    segments += o.segments;
    lags.addAll(o.lags);
    rmsBest.addAll(o.rmsBest);
    rmsZero.addAll(o.rmsZero);
  }

  static double percentile(List<double> values, double p) {
    if (values.isEmpty) return double.nan;
    final sorted = List<double>.of(values)..sort();
    return sorted[(p * (sorted.length - 1)).round()];
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'segments': segments,
        'lags': lags,
        'rmsBest': rmsBest,
        'rmsZero': rmsZero,
      };

  static TrackingStats fromJson(Map<String, dynamic> j) {
    final s = TrackingStats(j['name'] as String);
    s.segments = j['segments'] as int;
    List<double> doubles(String k) =>
        (j[k] as List).map((v) => (v as num).toDouble()).toList();
    s.lags.addAll(doubles('lags'));
    s.rmsBest.addAll(doubles('rmsBest'));
    s.rmsZero.addAll(doubles('rmsZero'));
    return s;
  }
}

/// Measure tracking lag for one pipeline over one file.
///
/// [minMovement] is the peak-to-peak movement, in cents, a segment must show
/// before its lag is believed.
List<TrackingResult> measureTracking({
  required Float64List samples,
  required double sampleRate,
  required JamsTruth truth,
  required NotePipeline pipeline,
  int window = pitchWindowSize,
  int hop = 512,
  int maxLagFrames = 16,
  int minFrames = 16,
  double minMovement = 40,
}) {
  final engine = PitchEngine.of(pipeline.detector,
      sampleRate: sampleRate, windowSize: window);
  final smoother = PitchSmoother();
  final legacy = MedianFilter();
  final tolerance = truth.hop / 2;

  // One pass, in time order, collecting (reference, detected) pairs.
  final refCents = <double>[];
  final detCents = <double>[];
  final valid = <bool>[];
  const anchor = 200.0; // an arbitrary fixed pitch; only differences matter

  for (int start = 0; start + window <= samples.length; start += hop) {
    final block = Float64List.sublistView(samples, start, start + window);
    final estimate = engine.analyse(block);
    double value = 0;
    switch (pipeline.smoothing) {
      case Smoothing.pitchSmoother:
        value = smoother.accept(
              pitched: estimate.pitched,
              probability: estimate.probability,
              pitch: estimate.frequency,
            ) ??
            0;
      case Smoothing.legacyMedian:
        if (estimate.pitched &&
            estimate.probability > PitchSmoother.minProbability) {
          value = legacy.add(estimate.frequency);
        }
      case Smoothing.gateOnly:
        if (estimate.pitched &&
            estimate.probability > PitchSmoother.minProbability) {
          value = estimate.frequency;
        }
    }

    // YIN's answer describes the start of its window (REPORT.md §1), so the
    // reference is read there. Any constant offset would show up as a
    // constant lag, which is exactly what is being measured — so this choice
    // has to be the same one the rest of the report makes.
    // Segments are defined by the *reference*, not by what this pipeline
    // happened to report. Otherwise each pipeline would be measured on its
    // own private set of segments and the comparison would be meaningless —
    // the one that reports least would get the easiest material.
    final active = truth.activeAt(start / sampleRate, tolerance);
    valid.add(active.length == 1);
    refCents.add(active.length == 1 ? cents(active.first.frequency, anchor) : 0);
    detCents.add(value > 0 ? cents(value, anchor) : double.nan);
  }

  final out = <TrackingResult>[];
  int i = 0;
  while (i < valid.length) {
    if (!valid[i]) {
      i++;
      continue;
    }
    int j = i;
    while (j < valid.length && valid[j]) {
      j++;
    }
    if (j - i >= minFrames) {
      // The detected series is read with the segment's own lag window either
      // side, so a lagging pipeline is not cut off at the segment boundary.
      final from = math.max(0, i - maxLagFrames);
      final to = math.min(detCents.length, j + maxLagFrames);
      final result = _fitLag(
        refCents.sublist(i, j),
        detCents.sublist(from, to),
        i - from,
        maxLagFrames,
        minMovement,
        hop / sampleRate,
      );
      if (result != null) out.add(result);
    }
    i = j;
  }
  return out;
}

/// Shift the detected series against the reference and find the shift that
/// fits best.
TrackingResult? _fitLag(List<double> reference, List<double> detected,
    int detectedOffset, int maxLag, double minMovement, double frameSeconds) {
  // Only the moving part of the reference carries timing information, and
  // only *monotonic* movement carries it unambiguously. Vibrato is movement
  // too, but it is periodic: a 5 Hz wobble fits a lag of 0 ms and 200 ms
  // equally well, so including it would widen the distribution with values
  // that are aliases rather than measurements. A bend or a slide has one
  // answer.
  double netChange = (reference.last - reference.first).abs();
  double totalVariation = 0;
  for (int k = 1; k < reference.length; k++) {
    totalVariation += (reference[k] - reference[k - 1]).abs();
  }
  if (netChange < minMovement) return null;
  if (totalVariation > 0 && netChange < 0.5 * totalVariation) return null;
  final movement = netChange;

  double rmsFor(int lag) {
    // detected[k + lag] against reference[k]: a positive lag means the
    // detector said it later than the reference did.
    double sum = 0;
    int n = 0;
    for (int k = 0; k < reference.length; k++) {
      final index = k + lag + detectedOffset;
      if (index < 0 || index >= detected.length) continue;
      final value = detected[index];
      if (value.isNaN) continue; // the pipeline said nothing on this frame
      final d = value - reference[k];
      // A gross error would dominate the fit; this is a timing measurement,
      // not an accuracy one, so octave jumps are excluded rather than
      // allowed to choose the lag.
      if (d.abs() > 200) continue;
      sum += d * d;
      n++;
    }
    return n < 8 ? double.infinity : math.sqrt(sum / n);
  }

  double bestRms = double.infinity;
  int bestLag = 0;
  for (int lag = -maxLag; lag <= maxLag; lag++) {
    final rms = rmsFor(lag);
    if (rms < bestRms) {
      bestRms = rms;
      bestLag = lag;
    }
  }
  if (!bestRms.isFinite) return null;

  // Parabolic interpolation between whole frames, so the answer is not
  // quantised to the hop.
  final before = rmsFor(bestLag - 1);
  final after = rmsFor(bestLag + 1);
  double refined = bestLag.toDouble();
  if (before.isFinite && after.isFinite) {
    final denom = before - 2 * bestRms + after;
    if (denom > 0) {
      final shift = 0.5 * (before - after) / denom;
      if (shift.abs() <= 1) refined = bestLag + shift;
    }
  }

  final zero = rmsFor(0);
  return TrackingResult(refined * frameSeconds, bestRms,
      zero.isFinite ? zero : double.nan, movement, reference.length);
}

/// Every pipeline, one file.
Map<String, TrackingStats> measureTrackingAll({
  required String wavPath,
  required String jamsPath,
  int window = pitchWindowSize,
  int hop = 512,
  List<NotePipeline> pipelines = defaultPipelines,
}) {
  final wav = readWav(wavPath);
  final truth = readJams(jamsPath);
  final out = <String, TrackingStats>{};
  for (final p in pipelines) {
    final stats = TrackingStats(p.name);
    for (final r in measureTracking(
      samples: wav.samples,
      sampleRate: wav.sampleRate.toDouble(),
      truth: truth,
      pipeline: p,
      window: window,
      hop: hop,
    )) {
      stats.add(r);
    }
    out[p.name] = stats;
  }
  return out;
}

const List<NotePipeline> defaultPipelines = [
  NotePipeline('before (legacy median)', DetectorKind.yin, Smoothing.legacyMedian),
  NotePipeline('after (PitchSmoother)', DetectorKind.yin, Smoothing.pitchSmoother),
  NotePipeline('no median at all', DetectorKind.yin, Smoothing.gateOnly),
  NotePipeline('MPM + PitchSmoother', DetectorKind.mpm, Smoothing.pitchSmoother),
];
