/// One file in, one set of scored pipeline variants out.
///
/// Every YIN variant reads the *same* cumulative mean normalised difference
/// function, computed once per frame. That is what makes a twenty-way sweep
/// affordable: the difference function is essentially the whole cost of YIN,
/// and the threshold, the tau rule and step 6 are all decisions taken after
/// it exists.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'app/tuner_core.dart';
import 'jams.dart';
import 'metrics.dart';
import 'mpm.dart';
import 'pyin.dart';
import 'refine.dart';
import 'wav.dart';
import 'yin.dart';

/// What to do to a raw YIN estimate after the fact.
enum Refinement2 { none, instantaneousFrequency, instantaneousFrequencyStiff }

/// One pipeline under test.
class Variant {
  final String name;
  final double threshold;
  final TauSelection selection;
  final bool bestLocal;

  /// The app's `result.probability > 0.9` gate, i.e. reject the frame unless
  /// the CMNDF at the chosen tau is below 0.1.
  final bool probabilityGate;

  /// The app's five-frame running median over accepted pitches.
  final bool median;

  final Refinement2 refine;

  /// Non-YIN detectors.
  final bool isMpm;
  final bool isPyin;
  final double mpmCutoff;

  const Variant(
    this.name, {
    this.threshold = 0.20,
    this.selection = TauSelection.firstDipBelowThreshold,
    this.bestLocal = false,
    this.probabilityGate = false,
    this.median = false,
    this.refine = Refinement2.none,
    this.isMpm = false,
    this.isPyin = false,
    this.mpmCutoff = 0.9,
  });
}

/// The pipelines the report compares.
///
/// `app` is the one in the App Store: YIN at threshold 0.20, the
/// `probability > 0.9` gate from `main.dart`, then `MedianFilter(size: 5)`.
/// Everything else changes exactly one thing at a time from there, or is a
/// different detector entirely.
const List<Variant> defaultVariants = [
  // --- the shipped pipeline, and each of its pieces removed ---
  Variant('app', probabilityGate: true, median: true),
  Variant('app-no-gate', median: true),
  Variant('app-no-median', probabilityGate: true),
  Variant('yin-raw-0.20'),

  // --- threshold sweep, raw YIN with no gate and no median ---
  Variant('yin-raw-0.05', threshold: 0.05),
  Variant('yin-raw-0.10', threshold: 0.10),
  Variant('yin-raw-0.15', threshold: 0.15),
  Variant('yin-raw-0.30', threshold: 0.30),
  Variant('yin-raw-0.40', threshold: 0.40),

  // --- threshold sweep with the app's gate and median in place ---
  Variant('app-thr-0.10', threshold: 0.10, probabilityGate: true, median: true),
  Variant('app-thr-0.15', threshold: 0.15, probabilityGate: true, median: true),

  // --- step 6 of the YIN paper, the package's TODO ---
  Variant('yin-raw-0.20+step6', bestLocal: true),
  Variant('yin-raw-0.15+step6', threshold: 0.15, bestLocal: true),
  Variant('app+step6', bestLocal: true, probabilityGate: true, median: true),
  Variant('app-thr-0.15+step6',
      threshold: 0.15, bestLocal: true, probabilityGate: true, median: true),

  // --- picking the global minimum instead of the first dip ---
  Variant('yin-raw-0.20+globalmin', selection: TauSelection.globalMinimum),
  Variant('app+globalmin',
      selection: TauSelection.globalMinimum,
      probabilityGate: true,
      median: true),

  // --- other detectors ---
  Variant('mpm', isMpm: true),
  Variant('mpm+median', isMpm: true, median: true),
  Variant('pyin', isPyin: true),

  // --- precision refinements on top ---
  Variant('app+if',
      probabilityGate: true,
      median: true,
      refine: Refinement2.instantaneousFrequency),
  Variant('app+if-stiff',
      probabilityGate: true,
      median: true,
      refine: Refinement2.instantaneousFrequencyStiff),
  Variant('app-thr-0.15+step6+if',
      threshold: 0.15,
      bestLocal: true,
      probabilityGate: true,
      median: true,
      refine: Refinement2.instantaneousFrequency),
];

class FileResult {
  final String file;
  final Map<String, MethodStats> stats;

  /// Inharmonicity coefficients measured on confidently-detected frames,
  /// summarised per file: median B and how many frames supported it.
  final double? medianB;
  final int bFrames;
  const FileResult(this.file, this.stats, this.medianB, this.bFrames);
}

/// Score every variant on one (wav, jams) pair.
FileResult evaluateFile({
  required String wavPath,
  required String jamsPath,
  int window = pitchWindowSize,
  int hop = 1024,
  List<Variant> variants = defaultVariants,
}) {
  final wav = readWav(wavPath);
  final truth = readJams(jamsPath);
  final rate = wav.sampleRate.toDouble();
  final tolerance = truth.hop / 2;

  final yin = RefYin(sampleRate: rate, bufferSize: window, useFft: true);
  final mpm = Mpm(sampleRate: rate, bufferSize: window);
  final pyin = PyinTracker(sampleRate: rate, bufferSize: window);

  // Ground truth, per frame.
  final refMono = <double>[]; // reference f0, or 0 when not monophonic
  final refActive = <List<double>>[]; // every string sounding
  // Detections, per variant, per frame (0 = nothing reported).
  final detected = {for (final v in variants) v.name: <double>[]};
  final medians = {
    for (final v in variants)
      if (v.median) v.name: MedianFilter()
  };
  final pyinFrames = <PyinFrame>[];
  final bValues = <double>[];

  for (int start = 0; start + window <= wav.samples.length; start += hop) {
    final block = Float64List.sublistView(wav.samples, start, start + window);
    final centre = (start + window / 2) / rate;
    final active = truth.activeAt(centre, tolerance);
    refActive.add([for (final a in active) a.frequency]);
    refMono.add(active.length == 1 ? active.first.frequency : 0);

    yin.cmndf(block);
    pyinFrames.add(pyin.observe(yin));

    YinResult? mpmResult;

    for (final v in variants) {
      double value;
      if (v.isPyin) {
        value = 0; // decoded after the loop
      } else {
        final YinResult r;
        if (v.isMpm) {
          mpmResult ??= mpm.getPitch(block);
          r = mpmResult;
        } else {
          r = yin.resultFromCmndf(v.threshold,
              selection: v.selection, bestLocal: v.bestLocal);
        }
        if (!r.pitched || (v.probabilityGate && r.probability <= 0.9)) {
          value = 0;
        } else {
          value = r.pitch;
          if (v.refine != Refinement2.none) {
            final refined = refineByInstantaneousFrequency(
              block,
              value,
              rate,
              fitInharmonicity:
                  v.refine == Refinement2.instantaneousFrequencyStiff,
            );
            value = refined.frequency;
          }
          if (v.median) value = medians[v.name]!.add(value);
        }
      }
      detected[v.name]!.add(value);
    }

    // Inharmonicity, measured wherever the frame is confidently pitched.
    final confident = yin.resultFromCmndf(0.15);
    if (confident.pitched && confident.probability > 0.9) {
      final r = refineByInstantaneousFrequency(block, confident.pitch, rate,
          fitInharmonicity: true);
      if (r.inharmonicity != null) bValues.add(r.inharmonicity!);
    }
  }

  // pYIN decodes the whole file at once.
  for (final v in variants) {
    if (!v.isPyin) continue;
    final path = pyin.snapToCandidates(pyinFrames, pyin.decode(pyinFrames));
    final out = detected[v.name]!;
    for (int i = 0; i < out.length && i < path.length; i++) {
      out[i] = path[i];
    }
  }

  // Which frames are a held note? The median spans five frames, so require
  // the reference to have been monophonic and within ±20 cents across that
  // span before calling the frame steady.
  const span = 5;
  final steady = List<bool>.filled(refMono.length, false);
  for (int i = 0; i < refMono.length; i++) {
    if (refMono[i] <= 0 || i < span - 1) continue;
    bool ok = true;
    for (int k = i - span + 1; k <= i; k++) {
      if (refMono[k] <= 0 || cents(refMono[k], refMono[i]).abs() > 20) {
        ok = false;
        break;
      }
    }
    steady[i] = ok;
  }

  // Score.
  final stats = {for (final v in variants) v.name: MethodStats(v.name)};
  for (final v in variants) {
    final s = stats[v.name]!;
    final d = detected[v.name]!;
    for (int i = 0; i < refMono.length; i++) {
      final value = d[i];
      final active = refActive[i];

      // Voicing, over every frame.
      if (active.isEmpty) {
        s.refUnvoiced++;
        if (value > 0) s.refUnvoicedReported++;
      } else {
        s.refVoiced++;
        if (value > 0) s.refVoicedReported++;
      }

      if (active.length == 1) {
        s.scoreMono(value > 0 ? value : null, refMono[i], steady: steady[i]);
        // Jitter: consecutive frames, both reported, reference steady.
        if (i > 0 &&
            value > 0 &&
            d[i - 1] > 0 &&
            refActive[i - 1].length == 1 &&
            cents(refMono[i], refMono[i - 1]).abs() < 5 &&
            cents(value, refMono[i]).abs() <= 50 &&
            cents(d[i - 1], refMono[i - 1]).abs() <= 50) {
          s.jitter.add(cents(value, d[i - 1]) - cents(refMono[i], refMono[i - 1]));
        }
      } else if (active.length > 1) {
        s.polyFrames++;
        if (value > 0) {
          s.polyReported++;
          for (final f in active) {
            if (cents(value, f).abs() <= 50) {
              s.polyMatchedAnyString++;
              break;
            }
          }
        }
      }
    }
  }

  double? medianB;
  if (bValues.length >= 10) {
    bValues.sort();
    medianB = bValues[bValues.length ~/ 2];
  }
  return FileResult(
      wavPath.split('/').last, stats, medianB, bValues.length);
}

/// Frames per second of audio at this window and hop, for the report.
double framesPerSecond(int hop, double rate) => rate / hop;

/// Convenience for the report: cents between two frequencies.
double centsOf(double a, double b) => 1200 * math.log(a / b) / math.ln2;
