/// The tuner's mathematics, with **no Flutter dependency at all**.
///
/// `TunerEngine` wraps this in a `ChangeNotifier` for the UI, but everything
/// that decides what note you are playing lives here, in plain Dart. That is
/// what lets `tool/tuner_probe.dart` push real audio through the exact code
/// the app runs, from a terminal, with no device and no simulator.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'temperament.dart';

/// Lowest note the tuner will report: A0, the bottom of a piano.
const int minMidi = 21;

/// Highest note the tuner will report: C8, the top of a piano.
const int maxMidi = 108;

const List<String> _noteNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
];

/// Scientific pitch name for a MIDI note number — 69 is "A4".
String noteNameForMidi(int midi) =>
    '${_noteNames[midi % 12]}${(midi ~/ 12) - 1}';

/// MIDI note number for a scientific pitch name, or null if unparseable.
/// Accepts both sharps and flats ("D#3" and "Eb3").
int? midiForNoteName(String name) {
  final match = RegExp(r'^([A-Ga-g])([#b]?)(-?\d+)$').firstMatch(name.trim());
  if (match == null) return null;
  const naturals = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
  final semitone = naturals[match.group(1)!.toUpperCase()]!;
  final accidental = switch (match.group(2)) { '#' => 1, 'b' => -1, _ => 0 };
  final octave = int.parse(match.group(3)!);
  return (octave + 1) * 12 + semitone + accidental;
}

/// Strip the octave number from a note name ("E4" -> "E").
String stripOctave(String note) => note.replaceAll(RegExp(r'-?[0-9]+$'), '');

/// Cents between a detected pitch and a target.
double computeCents(double detected, double target) {
  if (target <= 0 || detected <= 0) return 0;
  return 1200 * (math.log(detected / target) / math.ln2);
}

/// Convert raw little-endian PCM16 bytes to float samples in [-1, 1].
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

/// Running median over the last [size] pitch estimates.
///
/// YIN occasionally reports an octave error or a spurious value on a single
/// frame; a median discards those without lagging the way a mean does.
class MedianFilter {
  final int size;
  final List<double> _window = [];
  late final Float64List _scratch;

  MedianFilter({this.size = 5}) {
    _scratch = Float64List(size);
  }

  double add(double value) {
    _window.add(value);
    if (_window.length > size) _window.removeAt(0);
    if (_window.length < 3) return value;

    // Insertion sort into a reusable buffer — the window is tiny and this
    // runs on every audio callback, so allocating a fresh list would churn.
    final int n = _window.length;
    for (int i = 0; i < n; i++) {
      final double v = _window[i];
      int j = i - 1;
      while (j >= 0 && _scratch[j] > v) {
        _scratch[j + 1] = _scratch[j];
        j--;
      }
      _scratch[j + 1] = v;
    }
    return _scratch[n ~/ 2];
  }

  void clear() => _window.clear();
}

/// The YIN window the app analyses, in samples.
///
/// YIN searches lags up to `bufferSize / 2`, so the lowest frequency it can
/// represent at all is `2 * sampleRate / bufferSize`. At the 2048 samples this
/// app used until 2.2 that floor is **43.07 Hz** — above the open low E of a
/// bass guitar (41.20 Hz), which was therefore reported as an F, and well
/// above the low B of a five-string (30.87 Hz), which produced no reading at
/// all. 4096 samples puts the floor at 21.5 Hz, below the bottom of a piano.
const int pitchWindowSize = 4096;

/// A fixed-size rolling window of the most recent samples.
///
/// Platforms hand over audio in whatever chunk size they please, and the app
/// used to simply discard any callback carrying fewer samples than it wanted —
/// so on a device with a small chunk size the tuner did nothing whatsoever.
/// Accumulating here decouples the analysis window from the delivery size.
class RollingWindow {
  final int size;
  final Float64List _buffer;
  int _count = 0;
  int _head = 0;

  RollingWindow(this.size) : _buffer = Float64List(size);

  void add(List<double> samples) {
    // Only the newest [size] samples can survive, so skip any excess rather
    // than writing it and immediately overwriting it.
    final int from = samples.length > size ? samples.length - size : 0;
    for (int i = from; i < samples.length; i++) {
      _buffer[_head] = samples[i];
      _head = (_head + 1) % size;
      if (_count < size) _count++;
    }
  }

  /// How many samples are buffered, up to [size].
  int get available => _count;

  bool get isFull => _count >= size;

  /// The most recent [n] samples, oldest first; empty if there are not yet
  /// that many.
  Float64List lastN(int n) {
    if (n > _count || n <= 0) return Float64List(0);
    final out = Float64List(n);
    int start = (_head - n) % size;
    if (start < 0) start += size;
    for (int i = 0; i < n; i++) {
      out[i] = _buffer[(start + i) % size];
    }
    return out;
  }

  void clear() {
    _count = 0;
    _head = 0;
  }
}

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

  String get displayNote => stripOctave(note);
}

/// Maps frequencies to notes under a given concert pitch and temperament.
class PitchTable {
  final double a4Frequency;
  final TemperamentTable temperament;

  const PitchTable({
    this.a4Frequency = 440.0,
    required this.temperament,
  });

  /// The sounding frequency of a MIDI note.
  double frequencyForMidi(int midi) {
    final cents = temperament.centsForPitchClass(midi % 12);
    return a4Frequency *
        math.pow(2, (midi - 69) / 12.0) *
        math.pow(2, cents / 1200.0);
  }

  /// Frequency for a note name, or null if it cannot be parsed.
  double? frequencyForNote(String note) {
    final midi = midiForNoteName(note);
    return midi == null ? null : frequencyForMidi(midi);
  }

  /// The note closest to [detectedPitch].
  ///
  /// Pitch is logarithmic, so the note is found from the log position rather
  /// than by scanning for the smallest *linear* frequency difference. A linear
  /// scan is both O(number of notes) per audio frame and subtly wrong: the
  /// boundary between two semitones is their geometric mean, not their
  /// arithmetic one.
  ///
  /// The three candidates around the equal-tempered guess are then compared
  /// against the *tempered* targets, which can sit tens of cents off equal.
  NoteDetectionResult nearestNote(double detectedPitch) {
    if (detectedPitch <= 0 ||
        detectedPitch.isNaN ||
        detectedPitch.isInfinite) {
      return NoteDetectionResult.empty();
    }

    final double position =
        69 + 12 * (math.log(detectedPitch / a4Frequency) / math.ln2);
    if (position.isNaN || position.isInfinite) {
      return NoteDetectionResult.empty();
    }
    final int guess = position.round().clamp(minMidi, maxMidi);

    int bestMidi = guess;
    double bestCents = double.infinity;
    double bestTarget = 0;
    for (int midi = guess - 1; midi <= guess + 1; midi++) {
      if (midi < minMidi || midi > maxMidi) continue;
      final target = frequencyForMidi(midi);
      final cents = computeCents(detectedPitch, target);
      if (cents.abs() < bestCents.abs()) {
        bestCents = cents;
        bestMidi = midi;
        bestTarget = target;
      }
    }

    return NoteDetectionResult(
      note: noteNameForMidi(bestMidi),
      pitch: detectedPitch,
      cents: bestCents,
      targetFrequency: bestTarget,
      status: classifyTuning(bestCents),
    );
  }

  /// Every note in range, keyed by name.
  Map<String, double> allPitches() => {
        for (int midi = minMidi; midi <= maxMidi; midi++)
          noteNameForMidi(midi): frequencyForMidi(midi),
      };
}

/// In tune within 5 cents, else sharp or flat.
TuningStatus classifyTuning(double cents) {
  if (cents.abs() < 5) return TuningStatus.inTune;
  if (cents > 5) return TuningStatus.sharp;
  return TuningStatus.flat;
}
