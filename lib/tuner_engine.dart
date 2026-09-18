import 'dart:async';
import 'dart:math' as math;
import 'package:collection/collection.dart';
import 'package:fftea/fftea.dart';
import 'package:flutter/foundation.dart';

import 'detectors.dart';
import 'temperament.dart';
import 'tuner_core.dart';
// Also imported under a prefix: the class below deliberately re-exposes
// several of the core's top-level functions as static members of the same
// name, and an unprefixed call inside the class body would resolve to the
// static member itself and recurse forever.
import 'tuner_core.dart' as core;
import 'tunings.dart';

export 'detectors.dart'
    show DetectorKind, PitchEngine, PitchEstimate, YinEngine, MpmEngine;
export 'temperament.dart';
export 'tuner_core.dart'
    show
        NoteDetectionResult,
        TuningStatus,
        PitchTable,
        PitchSmoother,
        RollingWindow,
        pitchWindowSize;
export 'tunings.dart';

/// The app's tuner state.
///
/// All of the mathematics lives in `tuner_core.dart`, which has no Flutter
/// dependency whatsoever — this class adds the mutable state and the
/// `ChangeNotifier` the UI listens to, and nothing else. That split is what
/// lets `tool/tuner_probe.dart` run the very same detection code against real
/// audio from a terminal.
class TunerEngine extends ChangeNotifier {
  double _a4Frequency;
  Instrument _selectedInstrument;
  String _tuningId;
  List<String> _customStrings;
  TemperamentTable _temperament;
  late PitchTable _pitchTable;
  Map<String, double> _standardPitches = {};

  /// Whether [_customStrings] holds a tuning the user actually chose, as
  /// opposed to the placeholder the engine starts with. Selecting the custom
  /// tuning seeds it from what is on screen, but only the first time —
  /// otherwise restoring a saved custom tuning at launch would immediately
  /// overwrite it with the standard one, because the tuning id is applied
  /// after the strings are.
  bool _hasCustomTuning = false;

  final QueueList<double> _pitchHistory;
  final int _historySize;

  /// Immutable snapshot of [_pitchHistory], rebuilt only when the history
  /// actually changes. Painters read this every frame, so allocating a fresh
  /// copy per `build()` would churn the heap at display rate.
  List<double> _pitchHistorySnapshot = const [];

  List<double> _fftMagnitudes = [];

  static const int fftSize = 2048;
  final FFT _fft = FFT(fftSize);

  // Pre-computed Hann window coefficients
  late final Float64List _hannWindow;

  /// Scratch buffer for the windowed samples handed to the FFT. Reused across
  /// calls — [computeFFT] runs at display rate on the audio callback path.
  final Float64List _windowScratch = Float64List(fftSize);

  final PitchSmoother _smoother = PitchSmoother();

  DetectorKind _detectorKind = DetectorKind.yin;

  NoteDetectionResult? _lastResult;

  /// Set while a coalesced notification is already queued. A single audio
  /// callback updates the pitch reading *and* the spectrum, and each used to
  /// call [notifyListeners] separately — two full rebuilds per frame for one
  /// block of audio. Merging them into one microtask halves the UI work on
  /// the hot path.
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// Lowest note the tuner will report: A0, the bottom of a piano.
  static const int minMidi = core.minMidi;

  /// Highest note the tuner will report: C8, the top of a piano.
  static const int maxMidi = core.maxMidi;

  /// Semitone offsets from A4 for every note in range, keyed by name.
  ///
  /// The pre-2.2 implementation carried this as a hand-written table that
  /// stopped at C6 (~1046 Hz), so anything above it — routine on a violin or
  /// mandolin E string — was reported as a wildly out-of-tune C6.
  static final Map<String, int> noteOffsets = Map.unmodifiable({
    for (int midi = core.minMidi; midi <= core.maxMidi; midi++)
      core.noteNameForMidi(midi): midi - 69,
  });

  TunerEngine({
    double a4Frequency = 440.0,
    Instrument instrument = Instrument.guitar,
    String? tuningId,
    Temperament temperament = Temperament.equal,
    int temperamentRoot = 0,
    int historySize = 100,
  })  : _a4Frequency = a4Frequency,
        _selectedInstrument = instrument,
        _tuningId = tuningId ?? tuningsFor(instrument).first.id,
        _customStrings = List<String>.from(tuningsFor(instrument).first.strings),
        _temperament = TemperamentTable(temperament, root: temperamentRoot),
        _historySize = historySize,
        _pitchHistory = QueueList<double>(historySize) {
    _hannWindow = Float64List(fftSize);
    for (int i = 0; i < fftSize; i++) {
      _hannWindow[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (fftSize - 1)));
    }
    for (int i = 0; i < historySize; i++) {
      _pitchHistory.add(0);
    }
    _pitchHistorySnapshot = List<double>.unmodifiable(_pitchHistory);
    _rebuildPitchTable();
  }

  // -- Getters --

  double get a4Frequency => _a4Frequency;
  Instrument get selectedInstrument => _selectedInstrument;
  Map<String, double> get standardPitches => Map.unmodifiable(_standardPitches);
  List<double> get pitchHistory => _pitchHistorySnapshot;
  List<double> get fftMagnitudes => _fftMagnitudes;
  NoteDetectionResult? get lastResult => _lastResult;

  /// The table the detection actually consults.
  PitchTable get pitchTable => _pitchTable;

  /// The id of the selected tuning — [customTuningId] when the user has one
  /// of their own.
  String get tuningId => _tuningId;

  /// The user's editable tuning, independent of the selected instrument.
  List<String> get customStrings => List.unmodifiable(_customStrings);

  TemperamentTable get temperamentTable => _temperament;
  Temperament get temperament => _temperament.temperament;
  int get temperamentRoot => _temperament.root;

  /// Open-string notes of the tuning in force, lowest string first.
  List<String> get currentTuningStrings => _tuningId == customTuningId
      ? List.unmodifiable(_customStrings)
      : tuningFor(_selectedInstrument, _tuningId).strings;

  // -- Setters --

  set a4Frequency(double value) {
    if (value == _a4Frequency) return;
    _a4Frequency = value;
    _rebuildPitchTable();
    notifyListeners();
  }

  set selectedInstrument(Instrument value) {
    if (value == _selectedInstrument) return;
    _selectedInstrument = value;
    // A tuning id is only meaningful for the instrument that defines it —
    // "dropD" exists for guitar and bass but not for viola. Fall back to the
    // new instrument's standard tuning rather than showing it no strings.
    if (_tuningId != customTuningId &&
        !tuningsFor(value).any((t) => t.id == _tuningId)) {
      _tuningId = tuningsFor(value).first.id;
    }
    notifyListeners();
  }

  set tuningId(String value) {
    if (value == _tuningId) return;
    // Entering custom mode for the first time seeds the editable tuning from
    // whatever was on screen, so the user adjusts rather than starts blank.
    if (value == customTuningId && !_hasCustomTuning) {
      _customStrings = List<String>.from(currentTuningStrings);
      _hasCustomTuning = true;
    }
    _tuningId = value;
    notifyListeners();
  }

  set customStrings(List<String> value) {
    if (value.isEmpty) return;
    _customStrings = List<String>.from(value);
    _hasCustomTuning = true;
    notifyListeners();
  }

  set temperament(Temperament value) {
    if (value == _temperament.temperament) return;
    _temperament = TemperamentTable(value, root: _temperament.root);
    _rebuildPitchTable();
    notifyListeners();
  }

  set temperamentRoot(int value) {
    final root = value % 12;
    if (root == _temperament.root) return;
    _temperament = TemperamentTable(_temperament.temperament, root: root);
    _rebuildPitchTable();
    notifyListeners();
  }

  // -- Static forwarders, so callers need only this library --

  static String noteNameForMidi(int midi) => core.noteNameForMidi(midi);
  static int? midiForNoteName(String name) => core.midiForNoteName(name);
  static String stripOctave(String note) => core.stripOctave(note);
  static double computeCents(double detected, double target) =>
      core.computeCents(detected, target);

  // -- Core logic --

  void _rebuildPitchTable() {
    _pitchTable =
        PitchTable(a4Frequency: _a4Frequency, temperament: _temperament);
    _standardPitches = _pitchTable.allPitches();
  }

  /// The sounding frequency of a MIDI note under the current concert pitch
  /// and temperament.
  double frequencyForMidi(int midi) => _pitchTable.frequencyForMidi(midi);

  /// How far the given note sits from equal temperament, in cents. Zero in
  /// equal temperament; this is what the temperament readout shows.
  double centsOffsetForNote(String note) {
    final midi = midiForNoteName(note);
    if (midi == null) return 0;
    return _temperament.centsForPitchClass(midi % 12);
  }

  /// Find the closest note to a detected pitch, and record it.
  NoteDetectionResult detectNote(double detectedPitch) {
    final result = _pitchTable.nearestNote(detectedPitch);
    if (result.isEmpty) return result;

    // Update pitch history — bounded by the configured size, not a literal,
    // or a non-default historySize would grow without limit.
    if (_pitchHistory.length >= _historySize) _pitchHistory.removeFirst();
    _pitchHistory.add(result.cents.clamp(-50, 50));
    _pitchHistorySnapshot = List<double>.unmodifiable(_pitchHistory);

    _lastResult = result;
    _scheduleNotify();
    return result;
  }

  /// Which detector analyses the audio.
  ///
  /// YIN is the default and what every number in `bench/REPORT.md` describes.
  /// MPM answers on more frames and is wrong on more of them; it is offered
  /// because on a weak signal its willingness to commit is sometimes what a
  /// player wants. Changing this clears the smoothing window: the two
  /// detectors disagree by more than the median should ever average across.
  DetectorKind get detectorKind => _detectorKind;
  set detectorKind(DetectorKind value) {
    if (_detectorKind == value) return;
    _detectorKind = value;
    _smoother.clear();
    notifyListeners();
  }

  /// Apply the median filter to smooth an already-accepted pitch.
  double smoothPitch(double rawPitch) => _smoother.smooth(rawPitch);

  /// Push one detector frame through the app's gate and smoothing.
  ///
  /// Returns the pitch to display, or null when the frame is not periodic
  /// enough to believe — in which case the smoothing window is cleared, so
  /// that nothing from before the gap is averaged with what comes after it.
  double? acceptFrame({
    required bool pitched,
    required double probability,
    required double pitch,
  }) =>
      _smoother.accept(
          pitched: pitched, probability: probability, pitch: pitch);

  /// Convert raw PCM16 bytes to float samples.
  Float64List pcmToFloat(Uint8List data) => core.pcmToFloat(data);

  /// Run FFT with Hann windowing and return magnitudes for the musically
  /// useful range — the first quarter of the bins, i.e. up to ~5.5 kHz at a
  /// 44.1 kHz sample rate. Everything above that is noise for a tuner.
  List<double> computeFFT(Float64List samples) {
    if (samples.length < fftSize) return [];

    for (int i = 0; i < fftSize; i++) {
      _windowScratch[i] = samples[i] * _hannWindow[i];
    }

    final fftResult = _fft.realFft(_windowScratch);
    final magnitudes = fftResult.discardConjugates().magnitudes();

    // Copy out only the bins we display, in one pass — `.toList()` followed by
    // `.sublist()` allocated the full spectrum then threw 3/4 of it away.
    final int usefulBins = magnitudes.length ~/ 4;
    final trimmed = List<double>.filled(usefulBins, 0.0);
    for (int i = 0; i < usefulBins; i++) {
      trimmed[i] = magnitudes[i];
    }

    _fftMagnitudes = trimmed;
    _scheduleNotify();
    return _fftMagnitudes;
  }

  /// Coalesce the notifications raised by one block of audio into one.
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Compute frequency for a given note name.
  double? getFrequencyForNote(String note) =>
      _standardPitches[note] ?? _pitchTable.frequencyForNote(note);

  void reset() {
    _lastResult = null;
    _fftMagnitudes = [];
    _smoother.clear();
    for (int i = 0; i < _pitchHistory.length; i++) {
      _pitchHistory[i] = 0;
    }
    _pitchHistorySnapshot = List<double>.unmodifiable(_pitchHistory);
    notifyListeners();
  }
}
