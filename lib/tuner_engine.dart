import 'dart:math' as math;
import 'package:collection/collection.dart';
import 'package:fftea/fftea.dart';
import 'package:flutter/foundation.dart';

/// Pure-Dart tuner engine — no Flutter dependency beyond ChangeNotifier.
/// Handles pitch detection math, note matching, cents calculation,
/// FFT processing, and pitch history tracking.
///
/// Widgets can listen via [ListenableBuilder] instead of calling setState.
class TunerEngine extends ChangeNotifier {
  double _a4Frequency;
  Instrument _selectedInstrument;
  Map<String, double> _standardPitches = {};

  final QueueList<double> _pitchHistory;
  List<double> _fftMagnitudes = [];

  static const int fftSize = 2048;
  final FFT _fft = FFT(fftSize);

  // Pre-computed Hann window coefficients
  late final Float64List _hannWindow;

  // Median filter buffer for pitch smoothing
  final QueueList<double> _pitchBuffer = QueueList<double>();
  static const int _medianFilterSize = 5;

  // Last detection result
  NoteDetectionResult? _lastResult;

  static const Map<Instrument, List<String>> instrumentTunings = {
    Instrument.guitar: ['E2', 'A2', 'D3', 'G3', 'B3', 'E4'],
    Instrument.cello: ['C2', 'G2', 'D3', 'A3'],
    Instrument.bass: ['E1', 'A1', 'D2', 'G2'],
    Instrument.violin: ['G3', 'D4', 'A4', 'E5'],
    Instrument.ukulele: ['G4', 'C4', 'E4', 'A4'],
    Instrument.mandolin: ['G3', 'D4', 'A4', 'E5'],
  };

  static const Map<String, int> noteOffsets = {
    'A0': -48, 'A#0': -47, 'B0': -46, 'C1': -45, 'C#1': -44, 'D1': -43,
    'D#1': -42, 'E1': -41, 'F1': -40, 'F#1': -39, 'G1': -38, 'G#1': -37,
    'A1': -36, 'A#1': -35, 'B1': -34, 'C2': -33, 'C#2': -32, 'D2': -31,
    'D#2': -30, 'E2': -29, 'F2': -28, 'F#2': -27, 'G2': -26, 'G#2': -25,
    'A2': -24, 'A#2': -23, 'B2': -22, 'C3': -21, 'C#3': -20, 'D3': -19,
    'D#3': -18, 'E3': -17, 'F3': -16, 'F#3': -15, 'G3': -14, 'G#3': -13,
    'A3': -12, 'A#3': -11, 'B3': -10, 'C4': -9, 'C#4': -8, 'D4': -7,
    'D#4': -6, 'E4': -5, 'F4': -4, 'F#4': -3, 'G4': -2, 'G#4': -1, 'A4': 0,
    'A#4': 1, 'B4': 2, 'C5': 3, 'C#5': 4, 'D5': 5, 'D#5': 6, 'E5': 7,
    'F5': 8, 'F#5': 9, 'G5': 10, 'G#5': 11, 'A5': 12, 'A#5': 13, 'B5': 14,
    'C6': 15,
  };

  TunerEngine({
    double a4Frequency = 440.0,
    Instrument instrument = Instrument.guitar,
    int historySize = 100,
  })  : _a4Frequency = a4Frequency,
        _selectedInstrument = instrument,
        _pitchHistory = QueueList<double>(historySize) {
    // Pre-compute Hann window
    _hannWindow = Float64List(fftSize);
    for (int i = 0; i < fftSize; i++) {
      _hannWindow[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (fftSize - 1)));
    }
    // Fill pitch history with zeros
    for (int i = 0; i < historySize; i++) {
      _pitchHistory.add(0);
    }
    _recalculatePitches();
  }

  // -- Getters --

  double get a4Frequency => _a4Frequency;
  Instrument get selectedInstrument => _selectedInstrument;
  Map<String, double> get standardPitches => Map.unmodifiable(_standardPitches);
  List<double> get pitchHistory => _pitchHistory.toList();
  List<double> get fftMagnitudes => _fftMagnitudes;
  NoteDetectionResult? get lastResult => _lastResult;
  List<String> get currentTuningStrings =>
      instrumentTunings[_selectedInstrument]!;

  // -- Setters --

  set a4Frequency(double value) {
    if (value == _a4Frequency) return;
    _a4Frequency = value;
    _recalculatePitches();
    notifyListeners();
  }

  set selectedInstrument(Instrument value) {
    if (value == _selectedInstrument) return;
    _selectedInstrument = value;
    notifyListeners();
  }

  // -- Core logic --

  void _recalculatePitches() {
    _standardPitches = {
      for (final entry in noteOffsets.entries)
        entry.key: _a4Frequency * math.pow(2, entry.value / 12.0),
    };
  }

  /// Find the closest note to a detected pitch frequency.
  NoteDetectionResult detectNote(double detectedPitch) {
    if (detectedPitch <= 0) {
      return NoteDetectionResult.empty();
    }

    String closestNote = '';
    double minDifference = double.infinity;
    double targetFrequency = 0;

    for (final entry in _standardPitches.entries) {
      final difference = (detectedPitch - entry.value).abs();
      if (difference < minDifference) {
        minDifference = difference;
        closestNote = entry.key;
        targetFrequency = entry.value;
      }
    }

    final cents = computeCents(detectedPitch, targetFrequency);

    // Update pitch history
    if (_pitchHistory.length >= 100) _pitchHistory.removeFirst();
    _pitchHistory.add(cents.clamp(-50, 50));

    final status = _classifyTuning(cents);

    _lastResult = NoteDetectionResult(
      note: closestNote,
      pitch: detectedPitch,
      cents: cents,
      targetFrequency: targetFrequency,
      status: status,
    );
    notifyListeners();
    return _lastResult!;
  }

  /// Apply median filter to smooth raw pitch values.
  double smoothPitch(double rawPitch) {
    _pitchBuffer.add(rawPitch);
    if (_pitchBuffer.length > _medianFilterSize) {
      _pitchBuffer.removeFirst();
    }
    if (_pitchBuffer.length < 3) return rawPitch;

    final sorted = _pitchBuffer.toList()..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// Convert raw PCM16 bytes to float samples.
  Float64List pcmToFloat(Uint8List data) {
    final sampleCount = data.length ~/ 2;
    final floatData = Float64List(sampleCount);
    for (int i = 0; i < sampleCount; i++) {
      final int byteIndex = i * 2;
      final int sample = data[byteIndex] | (data[byteIndex + 1] << 8);
      final int signedSample = sample > 32767 ? sample - 65536 : sample;
      floatData[i] = signedSample / 32768.0;
    }
    return floatData;
  }

  /// Run FFT with Hann windowing and return magnitudes (first 1/8 of bins — musically useful range).
  List<double> computeFFT(Float64List samples) {
    if (samples.length < fftSize) return [];

    final windowed = List<double>.filled(fftSize, 0.0);
    for (int i = 0; i < fftSize; i++) {
      windowed[i] = samples[i] * _hannWindow[i];
    }

    final fftResult = _fft.realFft(windowed);
    final magnitudes = fftResult.discardConjugates().magnitudes().toList();

    // Only keep the first 1/8 of bins — up to ~2.7 kHz at 44100 sample rate
    final usefulBins = magnitudes.length ~/ 4;
    _fftMagnitudes = magnitudes.sublist(0, usefulBins);
    notifyListeners();
    return _fftMagnitudes;
  }

  /// Compute cents difference between detected and target frequency.
  static double computeCents(double detected, double target) {
    if (target <= 0 || detected <= 0) return 0;
    return 1200 * (math.log(detected / target) / math.log(2));
  }

  /// Compute frequency for a given note name.
  double? getFrequencyForNote(String note) => _standardPitches[note];

  /// Strip octave number from a note name (e.g., "E4" -> "E").
  static String stripOctave(String note) {
    return note.replaceAll(RegExp(r'[0-9]'), '');
  }

  TuningStatus _classifyTuning(double cents) {
    if (cents.abs() < 5) return TuningStatus.inTune;
    if (cents > 5) return TuningStatus.sharp;
    return TuningStatus.flat;
  }

  void reset() {
    _lastResult = null;
    _fftMagnitudes = [];
    _pitchBuffer.clear();
    for (int i = 0; i < _pitchHistory.length; i++) {
      _pitchHistory[i] = 0;
    }
    notifyListeners();
  }
}

enum Instrument { guitar, cello, bass, violin, ukulele, mandolin }

enum TuningStatus { inTune, sharp, flat, idle }

class NoteDetectionResult {
  final String note;
  final double pitch;
  final double cents;
  final double targetFrequency;
  final TuningStatus status;

  const NoteDetectionResult({
    required this.note,
    required this.pitch,
    required this.cents,
    required this.targetFrequency,
    required this.status,
  });

  factory NoteDetectionResult.empty() => const NoteDetectionResult(
        note: '',
        pitch: 0,
        cents: 0,
        targetFrequency: 0,
        status: TuningStatus.idle,
      );

  bool get isEmpty => note.isEmpty;

  String get displayNote => TunerEngine.stripOctave(note);

  String get statusText {
    switch (status) {
      case TuningStatus.inTune:
        return 'In Tune ✓';
      case TuningStatus.sharp:
        return 'Too Sharp ↑';
      case TuningStatus.flat:
        return 'Too Flat ↓';
      case TuningStatus.idle:
        return '';
    }
  }
}

extension StringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}
