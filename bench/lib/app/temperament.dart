import 'dart:math' as math;

/// Historical temperaments.
///
/// Each temperament is defined here the way it is actually *specified* in the
/// theory — as the sizes of the twelve fifths around the circle — and the cent
/// deviations are derived from that. Published tables of "cents above C" for
/// these temperaments disagree with each other in the last decimal (and
/// sometimes in which note is taken as zero), so deriving them from the fifths
/// is both self-documenting and the only version that can be checked against a
/// textbook.
enum Temperament {
  equal,
  pythagorean,
  quarterCommaMeantone,
  werckmeisterIII,
  kirnbergerIII,
  vallotti,
}

/// A just (pure) perfect fifth, 3:2, in cents — 701.955.
final double pureFifthCents = 1200 * math.log(1.5) / math.ln2;

/// The Pythagorean comma: twelve pure fifths minus seven octaves — 23.460.
final double pythagoreanComma = 12 * pureFifthCents - 8400;

/// The syntonic comma: four pure fifths minus two octaves and a pure 5:4
/// major third — 21.506.
final double syntonicComma =
    4 * pureFifthCents - 2400 - 1200 * math.log(1.25) / math.ln2;

/// Semitone offsets of the circle of fifths, walking up from the root:
/// root, +7, +2, +9, +4, +11, +6, +1, +8, +3, +10, +5, back to the root.
///
/// With the root at C that reads C G D A E B F♯ C♯ G♯ E♭ B♭ F — so index 8 is
/// the G♯–E♭ fifth, which is where the classical wolf sits.
const List<int> _circleOfFifths = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5];

/// The size, in cents, of each of the twelve fifths of [t], in circle order.
///
/// The twelve always sum to exactly seven octaves (8400 cents); whichever
/// fifth is left to absorb the remainder is the wolf.
List<double> fifthSizes(Temperament t) {
  final double pure = pureFifthCents;
  switch (t) {
    case Temperament.equal:
      return List<double>.filled(12, 700.0);

    // Eleven pure fifths; G♯–E♭ absorbs the Pythagorean comma (678.495).
    case Temperament.pythagorean:
      final f = List<double>.filled(12, pure);
      f[8] = 8400 - 11 * pure;
      return f;

    // Eleven fifths narrowed by a quarter of the syntonic comma, which makes
    // every major third in the chain pure; G♯–E♭ takes the rest (737.637).
    case Temperament.quarterCommaMeantone:
      final narrowed = pure - syntonicComma / 4;
      final f = List<double>.filled(12, narrowed);
      f[8] = 8400 - 11 * narrowed;
      return f;

    // Werckmeister III (1691): C–G, G–D, D–A and B–F♯ each narrowed by a
    // quarter of the Pythagorean comma, the other eight pure.
    case Temperament.werckmeisterIII:
      final narrowed = pure - pythagoreanComma / 4;
      final f = List<double>.filled(12, pure);
      for (final i in const [0, 1, 2, 5]) {
        f[i] = narrowed;
      }
      return f;

    // Kirnberger III (1779): C–G, G–D, D–A and A–E narrowed by a quarter of
    // the syntonic comma (a pure C–E third), F♯–C♯ left to absorb the schisma.
    case Temperament.kirnbergerIII:
      final narrowed = pure - syntonicComma / 4;
      final f = List<double>.filled(12, pure);
      for (final i in const [0, 1, 2, 3]) {
        f[i] = narrowed;
      }
      f[6] = 8400 - (4 * narrowed + 7 * pure);
      return f;

    // Vallotti (c. 1780): the six fifths F–C–G–D–A–E–B each narrowed by a
    // sixth of the Pythagorean comma, the other six pure. F–C is the fifth
    // that closes the circle, hence index 11.
    case Temperament.vallotti:
      final narrowed = pure - pythagoreanComma / 6;
      final f = List<double>.filled(12, pure);
      for (final i in const [0, 1, 2, 3, 4, 11]) {
        f[i] = narrowed;
      }
      return f;
  }
}

/// Cent deviations from equal temperament for each pitch class, with the
/// temperament built on C. Index 0 is C, 9 is A.
List<double> _deviationsFromEqual(Temperament t) {
  final fifths = fifthSizes(t);
  final result = List<double>.filled(12, 0);
  double cumulative = 0;
  for (int i = 0; i < 12; i++) {
    final pitchClass = _circleOfFifths[i];
    double reduced = cumulative % 1200;
    if (reduced < 0) reduced += 1200;
    double deviation = reduced - pitchClass * 100.0;
    // Fold into (-600, 600] — octave reduction can land a note a whole
    // octave away from the equal-tempered pitch class it belongs to.
    while (deviation > 600) {
      deviation -= 1200;
    }
    while (deviation <= -600) {
      deviation += 1200;
    }
    result[pitchClass] = deviation;
    cumulative += fifths[i];
  }
  return result;
}

/// A temperament in a particular key, ready to tune against.
///
/// The pattern of deviations is rotated so it is built on [root], then shifted
/// so that **A is always exactly zero**. That second step is what makes the
/// concert-pitch slider mean what it says: set it to 415 Hz and the A really
/// sounds at 415 Hz, in every temperament and every key, with the other eleven
/// notes bending around it.
class TemperamentTable {
  final Temperament temperament;

  /// Pitch class the temperament is built on — 0 is C, 9 is A.
  final int root;

  final List<double> _cents;

  TemperamentTable(this.temperament, {this.root = 0})
      : _cents = _anchorOnA(_deviationsFromEqual(temperament), root);

  static List<double> _anchorOnA(List<double> base, int root) {
    final rotated = List<double>.generate(
      12,
      (pitchClass) => base[(pitchClass - root + 12) % 12],
    );
    final aOffset = rotated[9];
    return List<double>.unmodifiable(
      rotated.map((cents) => cents - aOffset),
    );
  }

  /// How far pitch class [pitchClass] (0 = C) sits from its equal-tempered
  /// position, in cents.
  double centsForPitchClass(int pitchClass) => _cents[pitchClass % 12];

  /// The full twelve deviations, C first.
  List<double> get cents => _cents;

  /// True when every note matches equal temperament, i.e. nothing to show.
  bool get isEqual => temperament == Temperament.equal;

  @override
  bool operator ==(Object other) =>
      other is TemperamentTable &&
      other.temperament == temperament &&
      other.root == root;

  @override
  int get hashCode => Object.hash(temperament, root);
}
