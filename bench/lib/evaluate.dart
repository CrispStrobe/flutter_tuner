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

import 'app/harmonics.dart';
import 'app/detectors.dart';
import 'app/tuner_core.dart';
import 'jams.dart';
import 'metrics.dart';
import 'mpm.dart';
import 'narrowband.dart';
import 'cometbeat/contracts.dart' as cb;
import 'cometbeat/note_hmm.dart' as cb;
import 'pyin.dart';
import 'refine.dart';
import 'voicing_hmm.dart';
import 'wav.dart';
import 'yin.dart';

/// What to do to a raw YIN estimate after the fact.
enum Refinement2 {
  none,
  instantaneousFrequency,
  instantaneousFrequencyStiff,

  /// The app's own `analyseHarmonics`: partial frequencies read off the
  /// interpolated spectrum rather than from phase advance, then the same
  /// magnitude-weighted least-squares fit with a stiffness term.
  spectralHarmonicLsq,

  /// Goertzel sweep across a narrow band around the coarse estimate: the
  /// DFT evaluated where the note actually is, rather than on the bin grid.
  goertzel,

  /// The same sweep, summing the magnitude at eight partials at once.
  goertzelHarmonic,

  /// StringTune's re-scan of the lag neighbourhood with a full-overlap
  /// normalised correlation. See `refineByOverlapCorrelation`.
  overlapCorrelation,
}

/// How the app's running median is managed.
///
/// The app's `MedianFilter` is a window over the last five *accepted* pitches,
/// with no notion of time: if four frames in five are rejected, the median is
/// still averaging over pitches from half a second ago. And nothing resets it
/// when the player moves to a different note, so every note change is
/// smeared across the next few frames.
enum MedianPolicy {
  /// No median at all.
  none,

  /// Exactly what ships: five accepted pitches, never reset.
  app,

  /// Clear the window whenever a frame is rejected, so it can only ever
  /// contain consecutive frames.
  resetOnGap,

  /// Clear it on a gap, and also whenever the raw pitch jumps by more than
  /// a semitone — i.e. when the player has plainly changed note.
  resetOnGapOrJump,
}

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
  final MedianPolicy medianPolicy;

  final Refinement2 refine;

  /// Use one of the app's own detectors from `lib/detectors.dart`, rather
  /// than the benchmark's instrumented YIN. Implies [coreSmoother]: this is
  /// the whole shipped path, end to end.
  final DetectorKind? appEngine;

  /// Run the gate and the median through the app's own [PitchSmoother]
  /// rather than reproducing them here — so what is scored is the shipped
  /// class, not a benchmark's idea of it.
  final bool coreSmoother;

  /// Non-YIN detectors.
  final bool isMpm;
  final bool isPyin;

  /// Decoding lag in frames for a pYIN variant: frame t is decided once
  /// frame t+lag has been seen, which is what a streaming decoder could do.
  /// Null means the offline decode that §4.1 measured.
  final int? pyinLag;

  /// Mask the decoded track's voicing with CometBeat's note-HMM, keeping
  /// pYIN's own frequency inside a note.
  ///
  /// §24.1 left pYIN's one disqualifying weakness as voicing: 39.5% false
  /// alarm against the shipped pipeline's 17.1%. §24.2 then showed this
  /// app's threshold gate cannot fix it, because pYIN already HAS a voicing
  /// model and the gate is a cruder version of the same decision.
  ///
  /// An HMM is a different mechanism — temporal rather than per-frame — and
  /// §26.1 showed CometBeat's halves pYIN's gross errors on cello. What it
  /// must not do is decide the *pitch*: `segmentNotes` returns `int midi`,
  /// and a reading quantised to the semitone has thrown away the deviation
  /// a tuner exists to show. So the notes are used as a voicing mask only.
  final bool hmmMask;

  /// Mask voicing with this repo's own streaming two-state HMM
  /// (`voicing_hmm.dart`), at the given lookahead in frames.
  ///
  /// §27.2 named the blocker: the offline note-HMM cannot run in a tuner.
  /// This is the same idea at a size a tuner can afford — two states instead
  /// of one per MIDI note, because the mask discards the note identity
  /// anyway (§27.1), and a bounded lag instead of the whole track.
  final int? voicingLag;

  /// Cost model for [voicingLag], swept because the defaults were a guess.
  final double? voicingSwitch;
  final double? voicingEvidence;
  final double mpmCutoff;

  /// Where in the analysis window this estimator's answer belongs, in
  /// samples from the start of the window.
  ///
  /// YIN's difference function only ever looks at the first half of the
  /// window, so its answer describes the *beginning* of it; the
  /// instantaneous-frequency refinement reads the last couple of thousand
  /// samples instead, so its answer describes the end. Scoring both against
  /// the same instant would flatter one and punish the other, so each is
  /// compared against the reference where it actually lives. The values here
  /// come from `bin/alignment.dart`, which sweeps the offset and finds the
  /// minimum.
  final int referenceOffset;

  const Variant(
    this.name, {
    this.threshold = 0.20,
    this.selection = TauSelection.firstDipBelowThreshold,
    this.bestLocal = false,
    this.probabilityGate = false,
    this.medianPolicy = MedianPolicy.none,
    this.coreSmoother = false,
    this.appEngine,
    this.refine = Refinement2.none,
    this.isMpm = false,
    this.isPyin = false,
    this.pyinLag,
    this.hmmMask = false,
    this.voicingLag,
    this.voicingSwitch,
    this.voicingEvidence,
    this.mpmCutoff = 0.9,
    this.referenceOffset = 0,
  });

  bool get median => medianPolicy != MedianPolicy.none;
}

/// The pipelines the report compares.
///
/// `app` is the one in the App Store: YIN at threshold 0.20, the
/// `probability > 0.9` gate from `main.dart`, then `MedianFilter(size: 5)`.
/// Everything else changes exactly one thing at a time from there, or is a
/// different detector entirely.
const List<Variant> defaultVariants = [
  // --- the shipped pipeline, and each of its pieces removed ---
  Variant('app', probabilityGate: true, medianPolicy: MedianPolicy.app),
  Variant('app-no-gate', medianPolicy: MedianPolicy.app),
  Variant('app-no-median', probabilityGate: true),
  Variant('yin-raw-0.20'),

  // --- threshold sweep, raw YIN with no gate and no median ---
  Variant('yin-raw-0.05', threshold: 0.05),
  Variant('yin-raw-0.10', threshold: 0.10),
  Variant('yin-raw-0.15', threshold: 0.15),
  Variant('yin-raw-0.30', threshold: 0.30),
  Variant('yin-raw-0.40', threshold: 0.40),

  // --- threshold sweep with the app's gate and median in place ---
  Variant('app-thr-0.10',
      threshold: 0.10, probabilityGate: true, medianPolicy: MedianPolicy.app),
  Variant('app-thr-0.15',
      threshold: 0.15, probabilityGate: true, medianPolicy: MedianPolicy.app),

  // --- step 6 of the YIN paper, the package's TODO ---
  Variant('yin-raw-0.20+step6', bestLocal: true),
  Variant('yin-raw-0.15+step6', threshold: 0.15, bestLocal: true),
  Variant('app+step6',
      bestLocal: true, probabilityGate: true, medianPolicy: MedianPolicy.app),
  Variant('app-thr-0.15+step6',
      threshold: 0.15,
      bestLocal: true,
      probabilityGate: true,
      medianPolicy: MedianPolicy.app),

  // --- picking the global minimum instead of the first dip ---
  Variant('yin-raw-0.20+globalmin', selection: TauSelection.globalMinimum),
  Variant('app+globalmin',
      selection: TauSelection.globalMinimum,
      probabilityGate: true,
      medianPolicy: MedianPolicy.app),

  // --- other detectors ---
  Variant('mpm', isMpm: true),
  Variant('mpm+median', isMpm: true, medianPolicy: MedianPolicy.app),

  // --- the shipped path, end to end, through the app's own classes ---
  Variant('app-fixed', coreSmoother: true),
  Variant('engine-yin', appEngine: DetectorKind.yin, coreSmoother: true),
  Variant('engine-mpm', appEngine: DetectorKind.mpm, coreSmoother: true),

  // --- the median, made time-aware (modelled here, for attribution) ---
  Variant('app+median-gapreset',
      probabilityGate: true, medianPolicy: MedianPolicy.resetOnGap),
  Variant('app+median-jumpreset',
      probabilityGate: true, medianPolicy: MedianPolicy.resetOnGapOrJump),
  Variant('pyin', isPyin: true),
  // §4.1 rejected pYIN partly because "Viterbi cannot decide frame t until
  // it has seen the end of the file". True offline; these ask what a bounded
  // lookahead costs. At a 1024-sample hop a frame is 23.2 ms.
  Variant('pyin-lag0', isPyin: true, pyinLag: 0),
  Variant('pyin-lag1', isPyin: true, pyinLag: 1),
  Variant('pyin-lag2', isPyin: true, pyinLag: 2),
  Variant('pyin-lag4', isPyin: true, pyinLag: 4),
  Variant('pyin-lag8', isPyin: true, pyinLag: 8),
  Variant('pyin-lag16', isPyin: true, pyinLag: 16),
  // §24's open question: pYIN's weakness against the shipped pipeline is
  // that it answers far more often and is wrong more often when it does.
  // The app's own gate-and-median is what fixes exactly that. These put the
  // two together — the smoother is causal (a 5-frame median), so applying it
  // to a bounded-lag path is faithful rather than a cheat.
  // The experiment §24.2 left open, with the mechanism that section said was
  // missing. Lag 0 is included because §24.1 found greedy decoding is a
  // different operating point rather than a worse one — the best held-note
  // accuracy in the report.
  Variant('pyin-lag0+hmm', isPyin: true, pyinLag: 0, hmmMask: true),
  // The streaming replacement for the arm above. If these match, §27 has a
  // path to shipping; if they do not, the note structure was doing work the
  // voicing states cannot.
  Variant('pyin-lag0+vhmm0', isPyin: true, pyinLag: 0, voicingLag: 0),
  Variant('pyin-lag0+vhmm2', isPyin: true, pyinLag: 0, voicingLag: 2),
  Variant('pyin-lag0+vhmm5', isPyin: true, pyinLag: 0, voicingLag: 5),
  // The defaults above (switch 1.2, evidence 4.0) were a starting point, not
  // a measurement. A weaker switch cost and weaker evidence should both make
  // the model hold a note through a dip rather than cutting it.
  Variant('vhmm-s0.4-e2', isPyin: true, pyinLag: 0, voicingLag: 2,
      voicingSwitch: 0.4, voicingEvidence: 2.0),
  Variant('vhmm-s0.4-e1', isPyin: true, pyinLag: 0, voicingLag: 2,
      voicingSwitch: 0.4, voicingEvidence: 1.0),
  Variant('vhmm-s2.5-e2', isPyin: true, pyinLag: 0, voicingLag: 2,
      voicingSwitch: 2.5, voicingEvidence: 2.0),
  Variant('vhmm-s5-e1', isPyin: true, pyinLag: 0, voicingLag: 2,
      voicingSwitch: 5.0, voicingEvidence: 1.0),
  Variant('vhmm-s5-e0.5', isPyin: true, pyinLag: 0, voicingLag: 2,
      voicingSwitch: 5.0, voicingEvidence: 0.5),
  Variant('pyin-lag2+hmm', isPyin: true, pyinLag: 2, hmmMask: true),
  Variant('pyin-lag0+smoother', isPyin: true, pyinLag: 0, coreSmoother: true),
  Variant('pyin-lag2+smoother', isPyin: true, pyinLag: 2, coreSmoother: true),

  // --- precision refinements on top ---
  Variant('app+if',
      probabilityGate: true,
      medianPolicy: MedianPolicy.app,
      refine: Refinement2.instantaneousFrequency,
      referenceOffset: 2560),
  Variant('app+if-stiff',
      probabilityGate: true,
      medianPolicy: MedianPolicy.app,
      refine: Refinement2.instantaneousFrequencyStiff,
      referenceOffset: 2560),
  Variant('app-thr-0.15+step6+if',
      threshold: 0.15,
      bestLocal: true,
      probabilityGate: true,
      medianPolicy: MedianPolicy.app,
      refine: Refinement2.instantaneousFrequency,
      referenceOffset: 2560),
  // Same least-squares fit, but over spectral peaks instead of phase
  // advance — this is the app's shipped `analyseHarmonics`, and it reads
  // the end of the window like the phase arms do.
  Variant('app+harmonic-lsq',
      probabilityGate: true,
      medianPolicy: MedianPolicy.app,
      refine: Refinement2.spectralHarmonicLsq,
      referenceOffset: 2560),
  // The Goertzel sweep reads the whole window, so the instant it describes
  // is the window's centre rather than its start.
  Variant('app+goertzel',
      probabilityGate: true,
      medianPolicy: MedianPolicy.app,
      refine: Refinement2.goertzel,
      referenceOffset: 2048),
  // StringTune rescans the whole lag neighbourhood, so its answer describes
  // the same instant YIN's does — the window start, not the end.
  Variant('app+stringtune',
      probabilityGate: true,
      medianPolicy: MedianPolicy.app,
      refine: Refinement2.overlapCorrelation),
  Variant('mpm+stringtune',
      isMpm: true,
      probabilityGate: true,
      medianPolicy: MedianPolicy.app,
      refine: Refinement2.overlapCorrelation),
  Variant('app+goertzel-h8',
      probabilityGate: true,
      medianPolicy: MedianPolicy.app,
      refine: Refinement2.goertzelHarmonic,
      referenceOffset: 2048),
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

  // Ground truth, per frame, once per distinct reference offset in use.
  final offsets = {for (final v in variants) v.referenceOffset}.toList()
    ..sort();
  final refMono = {for (final o in offsets) o: <double>[]};
  final refActive = {for (final o in offsets) o: <List<double>>[]};
  // Detections, per variant, per frame (0 = nothing reported).
  final detected = {for (final v in variants) v.name: <double>[]};
  final medians = {
    for (final v in variants)
      if (v.median) v.name: MedianFilter()
  };
  final lastRaw = <String, double>{};
  final smoothers = {
    for (final v in variants)
      if (v.coreSmoother) v.name: PitchSmoother()
  };
  final engines = {
    for (final v in variants)
      if (v.appEngine != null)
        v.name: PitchEngine.of(v.appEngine!,
            sampleRate: rate, windowSize: window)
  };
  final pyinFrames = <PyinFrame>[];
  final bValues = <double>[];

  for (int start = 0; start + window <= wav.samples.length; start += hop) {
    final block = Float64List.sublistView(wav.samples, start, start + window);
    for (final o in offsets) {
      final active = truth.activeAt((start + o) / rate, tolerance);
      refActive[o]!.add([for (final a in active) a.frequency]);
      refMono[o]!.add(active.length == 1 ? active.first.frequency : 0);
    }

    yin.cmndf(block);
    pyinFrames.add(pyin.observe(yin));

    YinResult? mpmResult;

    for (final v in variants) {
      double value;
      if (v.appEngine != null) {
        // The app's detector and the app's smoother, with nothing of the
        // benchmark's own in between.
        final e = engines[v.name]!.analyse(block);
        final smoothed = smoothers[v.name]!.accept(
          pitched: e.pitched,
          probability: e.probability,
          pitch: e.frequency,
        );
        detected[v.name]!.add(smoothed ?? 0);
        continue;
      }
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
        if (v.coreSmoother) {
          // The app's own class decides everything from here.
          final smoothed = smoothers[v.name]!.accept(
            pitched: r.pitched,
            probability: r.probability,
            pitch: r.pitch,
          );
          detected[v.name]!.add(smoothed ?? 0);
          continue;
        }
        if (!r.pitched || (v.probabilityGate && r.probability <= 0.9)) {
          value = 0;
        } else {
          value = r.pitch;
          if (v.refine == Refinement2.overlapCorrelation) {
            value = refineByOverlapCorrelation(block, value, rate);
          } else if (v.refine == Refinement2.goertzel) {
            value = refineByGoertzel(block, value, rate);
          } else if (v.refine == Refinement2.goertzelHarmonic) {
            value = refineByGoertzel(block, value, rate, harmonics: 8);
          } else if (v.refine == Refinement2.spectralHarmonicLsq) {
            final profile = analyseHarmonics(block, value, rate);
            if (profile.fittedF0 > 0) value = profile.fittedF0;
          } else if (v.refine != Refinement2.none) {
            final refined = refineByInstantaneousFrequency(
              block,
              value,
              rate,
              fitInharmonicity:
                  v.refine == Refinement2.instantaneousFrequencyStiff,
            );
            value = refined.frequency;
          }
          if (v.median) {
            final policy = v.medianPolicy;
            if (policy != MedianPolicy.app) {
              // A gap since the previous frame, or a note change, means the
              // window holds nothing worth averaging with.
              final previous = lastRaw[v.name];
              final gap =
                  detected[v.name]!.isNotEmpty && detected[v.name]!.last <= 0;
              final jump = policy == MedianPolicy.resetOnGapOrJump &&
                  previous != null &&
                  cents(value, previous).abs() > 100;
              if (gap || jump) medians[v.name]!.clear();
            }
            lastRaw[v.name] = value;
            value = medians[v.name]!.add(value);
          }
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
    var path = pyin.snapToCandidates(
        pyinFrames, pyin.decode(pyinFrames, lag: v.pyinLag));
    if (v.hmmMask) path = _hmmVoicingMask(path, hop, rate);
    if (v.voicingLag != null) {
      // pYIN's own claimed probability mass per frame is the emission: the
      // mass it did not assign to any candidate IS its estimate of being
      // unvoiced, so no new signal has to be invented.
      final evidence = [
        for (final f in pyinFrames)
          f.probabilities.fold<double>(0, (a, b) => a + b).clamp(0.0, 1.0)
      ];
      final voiced = VoicingHmm(
        lag: v.voicingLag!,
        switchCost: v.voicingSwitch ?? 1.2,
        evidenceWeight: v.voicingEvidence ?? 4.0,
      ).decide(evidence);
      for (int i = 0; i < path.length && i < voiced.length; i++) {
        if (!voiced[i]) path[i] = 0;
      }
    }
    final out = detected[v.name]!;
    final smoother = smoothers[v.name];
    for (int i = 0; i < out.length && i < path.length; i++) {
      if (smoother == null) {
        out[i] = path[i];
        continue;
      }
      // pYIN reports a frequency or nothing; the smoother wants the
      // detector's own triple. A decoded frame IS the tracker's considered
      // answer, so it is handed over as pitched with full confidence — the
      // gate then contributes only its median and its voiced/unvoiced
      // discipline, which is the part being tested.
      out[i] = smoother.accept(
            pitched: path[i] > 0,
            probability: path[i] > 0 ? 1.0 : 0.0,
            pitch: path[i],
          ) ??
          0;
    }
  }

  // Which frames are a held note? The median spans five frames, so require
  // the reference to have been monophonic and within ±20 cents across that
  // span before calling the frame steady.
  const span = 5;
  final steadyByOffset = <int, List<bool>>{};
  for (final o in offsets) {
    final ref = refMono[o]!;
    final steady = List<bool>.filled(ref.length, false);
    for (int i = 0; i < ref.length; i++) {
      if (ref[i] <= 0 || i < span - 1) continue;
      bool ok = true;
      for (int k = i - span + 1; k <= i; k++) {
        if (ref[k] <= 0 || cents(ref[k], ref[i]).abs() > 20) {
          ok = false;
          break;
        }
      }
      steady[i] = ok;
    }
    steadyByOffset[o] = steady;
  }

  // Score.
  final stats = {for (final v in variants) v.name: MethodStats(v.name)};
  for (final v in variants) {
    final s = stats[v.name]!;
    final d = detected[v.name]!;
    final mono = refMono[v.referenceOffset]!;
    final actives = refActive[v.referenceOffset]!;
    final steady = steadyByOffset[v.referenceOffset]!;
    for (int i = 0; i < mono.length; i++) {
      final value = d[i];
      final active = actives[i];

      // Voicing, over every frame.
      if (active.isEmpty) {
        s.refUnvoiced++;
        if (value > 0) s.refUnvoicedReported++;
      } else {
        s.refVoiced++;
        if (value > 0) s.refVoicedReported++;
      }

      if (active.length == 1) {
        s.scoreMono(value > 0 ? value : null, mono[i], steady: steady[i]);
        // Jitter: consecutive frames, both reported, reference steady.
        if (i > 0 &&
            value > 0 &&
            d[i - 1] > 0 &&
            actives[i - 1].length == 1 &&
            cents(mono[i], mono[i - 1]).abs() < 5 &&
            cents(value, mono[i]).abs() <= 50 &&
            cents(d[i - 1], mono[i - 1]).abs() <= 50) {
          s.jitter.add(cents(value, d[i - 1]) - cents(mono[i], mono[i - 1]));
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
  return FileResult(wavPath.split('/').last, stats, medianB, bValues.length);
}

/// Frames per second of audio at this window and hop, for the report.
double framesPerSecond(int hop, double rate) => rate / hop;

/// Convenience for the report: cents between two frequencies.
double centsOf(double a, double b) => 1200 * math.log(a / b) / math.ln2;


/// Keep pYIN's frequency where CometBeat's note-HMM says a note is sounding,
/// and report nothing where it does not.
///
/// The HMM's own `int midi` is deliberately discarded — see [Variant.hmmMask].
/// This asks one question and one only: is pYIN's *voicing* the fixable part
/// of its disadvantage.
List<double> _hmmVoicingMask(List<double> path, int hop, double rate) {
  final track = <cb.PitchFrame>[
    for (int i = 0; i < path.length; i++)
      (
        timeMs: 1000 * i * hop / rate,
        f0Hz: path[i],
        voicedProb: path[i] > 0 ? 1.0 : 0.0,
      )
  ];
  final notes = cb.segmentNotes(track);
  final out = List<double>.filled(path.length, 0);
  if (notes.isEmpty) return out;
  int n = 0;
  for (int i = 0; i < path.length; i++) {
    final t = 1000 * i * hop / rate;
    while (n < notes.length && notes[n].offMs < t) {
      n++;
    }
    if (n >= notes.length) break;
    if (t >= notes[n].onMs && t <= notes[n].offMs) out[i] = path[i];
  }
  return out;
}
