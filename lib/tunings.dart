/// Instruments and their tunings.
///
/// A tuner that only knows standard tuning is useless to most of the people
/// who reach for one: guitarists in particular spend much of their time in
/// drop and open tunings, and the fixed six-string E-A-D-G-B-E list this app
/// started with covered none of them.
library;

enum Instrument {
  guitar,
  guitar7,
  bass,
  bass5,
  ukulele,
  banjo,
  mandolin,
  violin,
  viola,
  cello,
  doubleBass,
}

/// A named set of open-string pitches.
class Tuning {
  /// Stable identifier — persisted in preferences and used to look up the
  /// display name, so it must not change once shipped.
  final String id;

  /// Open strings, lowest first, as scientific pitch names ("E2", "F#3").
  final List<String> strings;

  const Tuning(this.id, this.strings);

  @override
  bool operator ==(Object other) => other is Tuning && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The id of the user-editable tuning. It is offered for every instrument and
/// is seeded from whatever tuning was selected when the user first picks it.
const String customTuningId = 'custom';

/// Every instrument's tunings, standard first.
///
/// Sources are the conventional tunings as played; where an instrument has a
/// genuinely reentrant standard (the ukulele's high G) that is preserved
/// rather than "corrected" into ascending order.
const Map<Instrument, List<Tuning>> instrumentTunings = {
  Instrument.guitar: [
    Tuning('standard', ['E2', 'A2', 'D3', 'G3', 'B3', 'E4']),
    Tuning('dropD', ['D2', 'A2', 'D3', 'G3', 'B3', 'E4']),
    Tuning('dropC', ['C2', 'G2', 'C3', 'F3', 'A3', 'D4']),
    Tuning('halfStepDown', ['D#2', 'G#2', 'C#3', 'F#3', 'A#3', 'D#4']),
    Tuning('wholeStepDown', ['D2', 'G2', 'C3', 'F3', 'A3', 'D4']),
    Tuning('dadgad', ['D2', 'A2', 'D3', 'G3', 'A3', 'D4']),
    Tuning('openG', ['D2', 'G2', 'D3', 'G3', 'B3', 'D4']),
    Tuning('openD', ['D2', 'A2', 'D3', 'F#3', 'A3', 'D4']),
    Tuning('openE', ['E2', 'B2', 'E3', 'G#3', 'B3', 'E4']),
    Tuning('openC', ['C2', 'G2', 'C3', 'G3', 'C4', 'E4']),
  ],
  Instrument.guitar7: [
    Tuning('standard', ['B1', 'E2', 'A2', 'D3', 'G3', 'B3', 'E4']),
    Tuning('dropA', ['A1', 'E2', 'A2', 'D3', 'G3', 'B3', 'E4']),
  ],
  Instrument.bass: [
    Tuning('standard', ['E1', 'A1', 'D2', 'G2']),
    Tuning('dropD', ['D1', 'A1', 'D2', 'G2']),
    Tuning('halfStepDown', ['D#1', 'G#1', 'C#2', 'F#2']),
    Tuning('wholeStepDown', ['D1', 'G1', 'C2', 'F2']),
  ],
  Instrument.bass5: [
    Tuning('standard', ['B0', 'E1', 'A1', 'D2', 'G2']),
    Tuning('tenor', ['E1', 'A1', 'D2', 'G2', 'C3']),
  ],
  Instrument.ukulele: [
    // Standard soprano/concert/tenor tuning is reentrant: the G is *above*
    // the C, not below it.
    Tuning('standard', ['G4', 'C4', 'E4', 'A4']),
    Tuning('lowG', ['G3', 'C4', 'E4', 'A4']),
    Tuning('baritone', ['D3', 'G3', 'B3', 'E4']),
    Tuning('dTuning', ['A4', 'D4', 'F#4', 'B4']),
  ],
  Instrument.banjo: [
    // Five-string banjo: the short fifth string is the high drone, listed
    // first as it is strung.
    Tuning('openG', ['G4', 'D3', 'G3', 'B3', 'D4']),
    Tuning('doubleC', ['G4', 'C3', 'G3', 'C4', 'D4']),
    Tuning('dropC', ['G4', 'C3', 'G3', 'B3', 'D4']),
    Tuning('tenor', ['C3', 'G3', 'D4', 'A4']),
  ],
  Instrument.mandolin: [
    Tuning('standard', ['G3', 'D4', 'A4', 'E5']),
    Tuning('octave', ['G2', 'D3', 'A3', 'E4']),
  ],
  Instrument.violin: [
    Tuning('standard', ['G3', 'D4', 'A4', 'E5']),
    Tuning('crossAEAE', ['A3', 'E4', 'A4', 'E5']),
  ],
  Instrument.viola: [
    Tuning('standard', ['C3', 'G3', 'D4', 'A4']),
  ],
  Instrument.cello: [
    Tuning('standard', ['C2', 'G2', 'D3', 'A3']),
    Tuning('solo', ['D2', 'A2', 'E3', 'B3']),
  ],
  Instrument.doubleBass: [
    Tuning('standard', ['E1', 'A1', 'D2', 'G2']),
    Tuning('solo', ['F#1', 'B1', 'E2', 'A2']),
  ],
};

/// The tunings offered for [instrument], standard first.
List<Tuning> tuningsFor(Instrument instrument) =>
    instrumentTunings[instrument]!;

/// The tuning with [id] for [instrument], or its standard tuning if there is
/// no such id — a saved preference must never be able to leave the app with
/// no tuning at all.
Tuning tuningFor(Instrument instrument, String id) {
  final tunings = tuningsFor(instrument);
  for (final tuning in tunings) {
    if (tuning.id == id) return tuning;
  }
  return tunings.first;
}

/// How many strings a custom tuning may have.
const int minCustomStrings = 2;
const int maxCustomStrings = 12;
