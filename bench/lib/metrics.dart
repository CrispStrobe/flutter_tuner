/// Standard MIR pitch metrics, plus the ones a tuner actually lives on.
library;

import 'dart:convert';
import 'dart:math' as math;

double cents(double detected, double reference) =>
    (detected <= 0 || reference <= 0)
        ? double.nan
        : 1200 * math.log(detected / reference) / math.ln2;

/// A fixed-bin histogram of signed cent errors, so percentiles and tails can
/// be aggregated across 360 files without keeping every frame in memory.
///
/// 0.05-cent bins across ±100 cents; anything wider lands in the overflow
/// counters, which is fine because it is already a gross error by then.
class CentHistogram {
  static const double span = 100.0;
  static const double binWidth = 0.05;
  static const int bins = 4000; // 2 * span / binWidth

  final List<int> counts;
  int below = 0;
  int above = 0;

  CentHistogram() : counts = List<int>.filled(bins, 0);
  CentHistogram.fromCounts(this.counts, this.below, this.above);

  void add(double c) {
    if (c.isNaN) return;
    if (c < -span) {
      below++;
      return;
    }
    if (c >= span) {
      above++;
      return;
    }
    counts[((c + span) / binWidth).floor().clamp(0, bins - 1)]++;
  }

  int get total => counts.fold<int>(0, (a, b) => a + b) + below + above;

  void merge(CentHistogram other) {
    for (int i = 0; i < bins; i++) {
      counts[i] += other.counts[i];
    }
    below += other.below;
    above += other.above;
  }

  double _valueOf(int bin) => -span + (bin + 0.5) * binWidth;

  /// Percentile of the signed error.
  double percentile(double p) {
    final n = total;
    if (n == 0) return double.nan;
    final target = p * n;
    double seen = below.toDouble();
    if (seen >= target) return -span;
    for (int i = 0; i < bins; i++) {
      seen += counts[i];
      if (seen >= target) return _valueOf(i);
    }
    return span;
  }

  /// Percentile of the *absolute* error — the tail that matters to a tuner.
  double absPercentile(double p) {
    final n = total;
    if (n == 0) return double.nan;
    final target = p * n;
    // Bins half+d and half-1-d hold the same magnitude, (d + 0.5) bins wide.
    double seen = 0;
    final half = bins ~/ 2;
    for (int d = 0; d < half; d++) {
      seen += counts[half + d] + counts[half - 1 - d];
      if (seen >= target) return (d + 1) * binWidth;
    }
    return span;
  }

  double get mean {
    double sum = 0;
    int n = 0;
    for (int i = 0; i < bins; i++) {
      sum += _valueOf(i) * counts[i];
      n += counts[i];
    }
    return n == 0 ? double.nan : sum / n;
  }

  double get median => percentile(0.5);

  /// Fraction of errors whose magnitude exceeds [c] cents.
  double fractionBeyond(double c) {
    final n = total;
    if (n == 0) return double.nan;
    int beyond = below + above;
    for (int i = 0; i < bins; i++) {
      if (_valueOf(i).abs() > c) beyond += counts[i];
    }
    return beyond / n;
  }

  Map<String, dynamic> toJson() =>
      {'counts': counts, 'below': below, 'above': above};

  static CentHistogram fromJson(Map<String, dynamic> j) =>
      CentHistogram.fromCounts(
        (j['counts'] as List).cast<int>().toList(),
        j['below'] as int,
        j['above'] as int,
      );
}

/// Everything one pipeline variant scored, accumulated.
class MethodStats {
  final String name;

  // --- monophonic reference frames (exactly one string sounding) ---
  int monoFrames = 0; // reference frames considered
  int reported = 0; // frames where the method returned a pitch
  int correct = 0; // |error| <= 50 cents
  int octave = 0; // within 50 cents of a whole number of octaves off
  int gross = 0; // wrong by more than 50 cents, not an octave

  /// Signed cent error on the frames that were correct to within 50 cents.
  final CentHistogram fine = CentHistogram();

  /// Frame-to-frame change in the reported pitch, over consecutive frames
  /// where the reference itself barely moved.
  ///
  /// This is the needle wobble the user watches, and unlike the cent error it
  /// does not depend on how precise GuitarSet's own reference is — only on
  /// how steady it says the note was.
  final CentHistogram jitter = CentHistogram();

  // --- the subset a tuner actually serves: a note being held ---
  //
  // A frame is "steady" when the reference has been monophonic and within
  // ±20 cents of its current value for the whole of the preceding median
  // span. Transition frames are real, and counted above; but a player
  // watching a needle is holding the note, and a pipeline can look bad on
  // frame-level RPA purely for lagging through attacks.
  int steadyFrames = 0;
  int steadyReported = 0;
  int steadyCorrect = 0;
  int steadyOctave = 0;
  int steadyGross = 0;
  final CentHistogram fineSteady = CentHistogram();

  // --- voicing, over every frame including polyphonic ones ---
  int refVoiced = 0;
  int refVoicedReported = 0;
  int refUnvoiced = 0;
  int refUnvoicedReported = 0;

  // --- polyphonic frames, scored leniently: did we name *a* string? ---
  int polyFrames = 0;
  int polyReported = 0;
  int polyMatchedAnyString = 0;

  MethodStats(this.name);

  double get rawPitchAccuracy => monoFrames == 0 ? 0 : correct / monoFrames;
  double get steadyAccuracy =>
      steadyFrames == 0 ? 0 : steadyCorrect / steadyFrames;
  double get steadyOctaveRate =>
      steadyReported == 0 ? 0 : steadyOctave / steadyReported;
  double get steadyGrossRate =>
      steadyReported == 0 ? 0 : steadyGross / steadyReported;
  double get accuracyWhenReporting => reported == 0 ? 0 : correct / reported;
  double get octaveRate => reported == 0 ? 0 : octave / reported;
  double get grossRate => reported == 0 ? 0 : gross / reported;
  double get voicingRecall => refVoiced == 0 ? 0 : refVoicedReported / refVoiced;
  double get voicingFalseAlarm =>
      refUnvoiced == 0 ? 0 : refUnvoicedReported / refUnvoiced;

  void merge(MethodStats o) {
    monoFrames += o.monoFrames;
    reported += o.reported;
    correct += o.correct;
    octave += o.octave;
    gross += o.gross;
    fine.merge(o.fine);
    fineSteady.merge(o.fineSteady);
    jitter.merge(o.jitter);
    steadyFrames += o.steadyFrames;
    steadyReported += o.steadyReported;
    steadyCorrect += o.steadyCorrect;
    steadyOctave += o.steadyOctave;
    steadyGross += o.steadyGross;
    refVoiced += o.refVoiced;
    refVoicedReported += o.refVoicedReported;
    refUnvoiced += o.refUnvoiced;
    refUnvoicedReported += o.refUnvoicedReported;
    polyFrames += o.polyFrames;
    polyReported += o.polyReported;
    polyMatchedAnyString += o.polyMatchedAnyString;
  }

  /// Score one monophonic reference frame.
  void scoreMono(double? detected, double reference, {bool steady = false}) {
    monoFrames++;
    if (steady) steadyFrames++;
    if (detected == null || detected <= 0) return;
    reported++;
    if (steady) steadyReported++;
    final err = cents(detected, reference);
    if (err.abs() <= 50) {
      correct++;
      fine.add(err);
      if (steady) {
        steadyCorrect++;
        fineSteady.add(err);
      }
      return;
    }
    final octaves = err / 1200;
    if ((octaves - octaves.roundToDouble()).abs() * 1200 <= 50 &&
        octaves.round() != 0) {
      octave++;
      if (steady) steadyOctave++;
    } else {
      gross++;
      if (steady) steadyGross++;
    }
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'monoFrames': monoFrames,
        'reported': reported,
        'correct': correct,
        'octave': octave,
        'gross': gross,
        'fine': fine.toJson(),
        'fineSteady': fineSteady.toJson(),
        'jitter': jitter.toJson(),
        'steadyFrames': steadyFrames,
        'steadyReported': steadyReported,
        'steadyCorrect': steadyCorrect,
        'steadyOctave': steadyOctave,
        'steadyGross': steadyGross,
        'refVoiced': refVoiced,
        'refVoicedReported': refVoicedReported,
        'refUnvoiced': refUnvoiced,
        'refUnvoicedReported': refUnvoicedReported,
        'polyFrames': polyFrames,
        'polyReported': polyReported,
        'polyMatchedAnyString': polyMatchedAnyString,
      };

  static MethodStats fromJson(Map<String, dynamic> j) {
    final s = MethodStats(j['name'] as String);
    s.monoFrames = j['monoFrames'] as int;
    s.reported = j['reported'] as int;
    s.correct = j['correct'] as int;
    s.octave = j['octave'] as int;
    s.gross = j['gross'] as int;
    s.fine.merge(CentHistogram.fromJson(j['fine'] as Map<String, dynamic>));
    s.fineSteady
        .merge(CentHistogram.fromJson(j['fineSteady'] as Map<String, dynamic>));
    s.jitter
        .merge(CentHistogram.fromJson(j['jitter'] as Map<String, dynamic>));
    s.steadyFrames = j['steadyFrames'] as int;
    s.steadyReported = j['steadyReported'] as int;
    s.steadyCorrect = j['steadyCorrect'] as int;
    s.steadyOctave = j['steadyOctave'] as int;
    s.steadyGross = j['steadyGross'] as int;
    s.refVoiced = j['refVoiced'] as int;
    s.refVoicedReported = j['refVoicedReported'] as int;
    s.refUnvoiced = j['refUnvoiced'] as int;
    s.refUnvoicedReported = j['refUnvoicedReported'] as int;
    s.polyFrames = j['polyFrames'] as int;
    s.polyReported = j['polyReported'] as int;
    s.polyMatchedAnyString = j['polyMatchedAnyString'] as int;
    return s;
  }

  static String encodeAll(Map<String, MethodStats> stats) =>
      jsonEncode({for (final e in stats.entries) e.key: e.value.toJson()});

  static Map<String, MethodStats> decodeAll(String s) {
    final m = jsonDecode(s) as Map<String, dynamic>;
    return {
      for (final e in m.entries)
        e.key: MethodStats.fromJson(e.value as Map<String, dynamic>),
    };
  }
}
