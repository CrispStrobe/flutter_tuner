/// pYIN with a streaming note model on top: the detector `bench/REPORT.md`
/// §39 measured, as an engine the app can run one window at a time.
///
/// Three stages, each causal — nothing here waits for audio that has not
/// arrived:
///
///  1. **pYIN** (Mauch & Dixon 2014, in the simplified form the bench
///     measured): every dip of YIN's difference function is a candidate,
///     weighted by how many thresholds of a Beta(2, 18) prior would have
///     picked it, and an HMM over a 10-cent pitch grid with voiced and
///     unvoiced copies chooses the path. Decoded greedily: each frame takes
///     the best state given everything so far (§24: lag 0).
///  2. **A note-state HMM** over pYIN's path, one state per MIDI note plus
///     silence. It shows a frame only once the note it belongs to has
///     lasted [PyinNoteEngine.minFrames] frames, which is what removes
///     pYIN's short false alarms, and it splits brief excursions off a held
///     note (§39.1–§39.4).
///  3. **YIN's octave**: when YIN itself is confident (the app's own gate,
///     probability above 0.9) and pYIN's reading sits one or two octaves
///     away, the reading moves into YIN's octave (§39.9).
///
/// Measured on GuitarSet through the app's whole pipeline (refinement, gate
/// and median after this engine, exactly as for YIN; §39.10): held-note
/// accuracy 89.2% against YIN's 80.8% on solo takes, the same overall
/// accuracy and false alarms, 2.20 cents median error against 2.05, the
/// first correct reading about 30 ms later. Between strummed chords it
/// reports more often when nothing is annotated (17.8% against 14.1%), so
/// it is offered as an option, not the default.
///
/// The note model here is the production subset of the bench's
/// `note_state_hmm.dart`: the research knobs that measured as useless
/// (§39.8) are left out.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'detectors.dart';

class PyinNoteEngine extends PitchEngine {
  final double sampleRate;
  @override
  final int windowSize;

  /// Frames a note must last before any of it is shown. 2 is the operating
  /// point §39.4 chose: each extra frame costs one hop (23 ms) of response.
  final int minFrames;

  final YinEngine _yin;
  final _GreedyPyin _pyin;
  final _NoteStates _notes;

  PyinNoteEngine({
    required this.sampleRate,
    required this.windowSize,
    this.minFrames = 2,
  })  : _yin = YinEngine(sampleRate: sampleRate, windowSize: windowSize),
        _pyin = _GreedyPyin(),
        _notes = _NoteStates(minFrames: minFrames);

  @override
  DetectorKind get kind => DetectorKind.pyinNote;

  @override
  double get detectionFloor =>
      math.max(2 * sampleRate / windowSize, _GreedyPyin.minF0);

  /// The app's gate: YIN's answer is believed above this periodicity.
  static const double _yinConfident = 0.9;

  @override
  PitchEstimate analyse(List<double> window) {
    // One difference function serves both YIN's own answer and pYIN's
    // candidates.
    final yin = _yin.analyse(window);
    final f0 = _pyin.step(_candidates());
    final shown = _notes.push(f0);
    if (!shown) return PitchEstimate.unpitched;

    var f = f0;
    if (yin.pitched && yin.probability > _yinConfident) {
      final k = _octavesApart(f, yin.frequency);
      if (k != 0) f /= math.pow(2, k);
    }
    return PitchEstimate(f, 1.0, true);
  }

  /// Every local minimum of the last CMNDF, as (frequency, aperiodicity).
  List<({double frequency, double aperiodicity})> _candidates() {
    final d = _yin.cmndf;
    final half = _yin.halfSize;
    final out = <({double frequency, double aperiodicity})>[];
    for (int tau = 2; tau < half - 1; tau++) {
      if (d[tau] < d[tau - 1] && d[tau] <= d[tau + 1] && d[tau] < 1.0) {
        final period = _yin.interpolatedPeriod(tau);
        if (period > 0) {
          out.add((frequency: sampleRate / period, aperiodicity: d[tau]));
        }
      }
    }
    return out;
  }

  /// Whole octaves (±1, ±2) by which [f] sits above [ref], to within a
  /// semitone; 0 when they are not octave-related.
  static int _octavesApart(double f, double ref) {
    final c = centsBetween(f, ref);
    for (final k in const [1, -1, 2, -2]) {
      if ((c - 1200 * k).abs() <= 100) return k;
    }
    return 0;
  }
}

/// pYIN's candidate weighting and pitch HMM, decoded greedily one frame at
/// a time. The arithmetic is the bench's `pyin.dart` (`observe`, `decode`
/// with lag 0, `snapToCandidates`), restructured as a stream.
class _GreedyPyin {
  static const double minF0 = 30.0;
  static const double maxF0 = 1200.0;
  static const double binCents = 10.0;
  static const double noTrustFloor = 0.01;
  static const double transitionCents = 60.0;
  static const double switchProbability = 0.01;

  late final int bins =
      (1200 * math.log(maxF0 / minF0) / math.ln2 / binCents).ceil() + 1;
  late final int _states = 2 * bins; // [0, bins) voiced, then unvoiced
  late final int _neighbourhood = (3 * transitionCents / binCents).ceil();
  late final Float64List _logW = Float64List.fromList([
    for (int d = 0; d <= _neighbourhood; d++)
      math.log(math.max(1e-9, 1 - d * binCents / (3 * transitionCents)))
  ]);
  final double _logStay = math.log(1 - switchProbability);
  final double _logSwitch = math.log(switchProbability);
  late final double _logBins = math.log(bins);

  /// 20 thresholds with a Beta(2, 18) prior, mean 0.1.
  static final List<double> _thresholds =
      List.generate(20, (i) => (i + 1) * 0.025);
  static final List<double> _priors = () {
    double beta(double x) =>
        math.pow(x, 1).toDouble() * math.pow(1 - x, 17).toDouble();
    final raw = _thresholds.map(beta).toList();
    final total = raw.reduce((a, b) => a + b);
    return raw.map((p) => p / total).toList();
  }();

  late final Float64List _previous = Float64List(_states);
  late final Float64List _current = Float64List(_states);
  late final Float64List _emission = Float64List(_states);
  bool _started = false;

  int _binOf(double f) =>
      (1200 * math.log(f / minF0) / math.ln2 / binCents).round();
  double _freqOf(int bin) =>
      minF0 * math.pow(2, bin * binCents / 1200).toDouble();

  /// One frame in; the decoded frequency out, or 0 when unvoiced.
  double step(List<({double frequency, double aperiodicity})> candidates) {
    // Observation: which candidate each threshold would have picked.
    final freqs = <double>[];
    final probs = <double>[];
    if (candidates.isNotEmpty) {
      for (int i = 0; i < _thresholds.length; i++) {
        final s = _thresholds[i];
        int chosen = -1;
        for (int c = 0; c < candidates.length; c++) {
          if (candidates[c].aperiodicity < s) {
            chosen = c;
            break;
          }
        }
        if (chosen < 0) continue; // this vote stays with "unvoiced"
        final f = candidates[chosen].frequency;
        if (f < minF0 || f > maxF0) continue;
        final mass = _priors[i] *
            (1 - candidates[chosen].aperiodicity).clamp(0.0, 1.0);
        final at = freqs.indexWhere((x) => (x - f).abs() < 1e-9);
        if (at >= 0) {
          probs[at] += mass;
        } else {
          freqs.add(f);
          probs.add(mass);
        }
      }
    }

    // Emission.
    final e = _emission..fillRange(0, _states, 0.0);
    double claimed = 0;
    for (int i = 0; i < freqs.length; i++) {
      final b = _binOf(freqs[i]);
      if (b < 0 || b >= bins) continue;
      e[b] += probs[i];
      claimed += probs[i];
    }
    final unvoiced = math.max(noTrustFloor, 1 - claimed) / bins;
    for (int b = bins; b < _states; b++) {
      e[b] = unvoiced;
    }
    for (int i = 0; i < _states; i++) {
      e[i] = math.log(e[i] + 1e-12);
    }

    // Forward step.
    final prev = _previous, cur = _current;
    if (!_started) {
      final init = math.log(_states);
      for (int i = 0; i < _states; i++) {
        cur[i] = e[i] - init;
      }
      _started = true;
    } else {
      double bestVoiced = double.negativeInfinity;
      double bestUnvoiced = double.negativeInfinity;
      for (int i = 0; i < bins; i++) {
        if (prev[i] > bestVoiced) bestVoiced = prev[i];
        if (prev[bins + i] > bestUnvoiced) bestUnvoiced = prev[bins + i];
      }
      final stay = bestUnvoiced + _logStay;
      final drop = bestVoiced + _logSwitch;
      final toUnvoiced = stay >= drop ? stay : drop;
      final fromUnvoiced = bestUnvoiced + _logSwitch - _logBins;
      for (int b = 0; b < bins; b++) {
        double best = fromUnvoiced;
        final lo = math.max(0, b - _neighbourhood);
        final hi = math.min(bins - 1, b + _neighbourhood);
        for (int p = lo; p <= hi; p++) {
          final score = prev[p] + _logStay + _logW[(b - p).abs()];
          if (score > best) best = score;
        }
        cur[b] = best + e[b];
        cur[bins + b] = toUnvoiced + e[bins + b];
      }
    }

    // Greedy decision, and renormalise so an endless stream stays finite.
    int arg = 0;
    for (int i = 1; i < _states; i++) {
      if (cur[i] > cur[arg]) arg = i;
    }
    final top = cur[arg];
    for (int i = 0; i < _states; i++) {
      prev[i] = cur[i] - top;
    }
    if (arg >= bins) return 0;

    // The grid is 10 cents; snap back onto the nearest real candidate,
    // which carries YIN's sub-sample precision.
    final f = _freqOf(arg);
    double best = f;
    double bestCents = binCents;
    for (final c in freqs) {
      final d = (1200 * math.log(c / f) / math.ln2).abs();
      if (d < bestCents) {
        bestCents = d;
        best = c;
      }
    }
    return best;
  }
}

/// The note-state HMM, greedy (no lookahead), with the causal minimum-run
/// rule. States: one per MIDI note over [minMidi, maxMidi], plus silence.
class _NoteStates {
  final int minFrames;
  static const double switchCost = 1.8;
  static const double boundaryCost = 0.6;
  static const int minMidi = 28; // E1
  static const int maxMidi = 100; // E7
  static const int _k = maxMidi - minMidi + 1;
  static const int _silence = _k;

  Float64List _cost = Float64List(_k + 1);
  Float64List _next = Float64List(_k + 1);
  bool _started = false;
  int _held = _silence; // state of the previous frame
  int _run = 0; // frames the held state has lasted

  _NoteStates({required this.minFrames});

  double _emit(int i, double frameCents, bool voiced) {
    if (!voiced) return 3.0;
    final c = (frameCents - 100.0 * (minMidi + i - 69)).abs();
    return math.min(c / 50.0, 5.0);
  }

  /// Push one frame of pYIN's path (0 = unvoiced); returns whether to show
  /// it.
  bool push(double f0) {
    final voiced = f0 > 0;
    final fc = voiced ? 1200 * math.log(f0 / 440) / math.ln2 : 0.0;
    final prev = _cost, cur = _next;
    if (!_started) {
      for (int i = 0; i < _k; i++) {
        cur[i] = _emit(i, fc, voiced);
      }
      cur[_silence] = voiced ? 1.0 : 0.0;
      _started = true;
    } else {
      double g1 = double.infinity, g2 = double.infinity;
      int a1 = -1;
      for (int i = 0; i < _k; i++) {
        final c = prev[i];
        if (c < g1) {
          g2 = g1;
          g1 = c;
          a1 = i;
        } else if (c < g2) {
          g2 = c;
        }
      }
      final fromSilence = prev[_silence] + boundaryCost;
      for (int i = 0; i < _k; i++) {
        var best = prev[i];
        if (fromSilence < best) best = fromSilence;
        final other = (i == a1 ? g2 : g1) + switchCost;
        if (other < best) best = other;
        cur[i] = best + _emit(i, fc, voiced);
      }
      final toSilence = math.min(prev[_silence], g1 + boundaryCost);
      cur[_silence] = toSilence + (voiced ? 1.0 : 0.0);
    }

    int arg = 0;
    for (int s = 1; s <= _k; s++) {
      if (cur[s] < cur[arg]) arg = s;
    }
    final lo = cur[arg];
    for (int s = 0; s <= _k; s++) {
      cur[s] -= lo;
    }
    _cost = cur;
    _next = prev;

    _run = arg == _held ? _run + 1 : 1;
    _held = arg;
    return arg != _silence && _run >= minFrames;
  }
}
