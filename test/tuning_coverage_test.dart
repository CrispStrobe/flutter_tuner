import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:flutter_tuner/tuner_engine.dart';

/// Every open string of every tuning the app offers, played through the real
/// detector.
///
/// The other tests check that the catalogue's notes parse and sit in range.
/// This one asks the harder question: if a player actually sounds this string,
/// does CrispTuner name it correctly? That is the promise the app makes, and
/// nothing verified it end to end — which is how a 2048-sample window shipped
/// for a year reporting a bass low E as an F.
void main() {
  /// A plucked-string tone: harmonics falling away, a little noise. A bare
  /// sine would be an easier test than reality.
  Float64List pluck(double frequency, {int samples = pitchWindowSize}) {
    const harmonics = [1.0, 0.55, 0.32, 0.2, 0.13, 0.08];
    final out = Float64List(samples);
    final random = math.Random(4);
    for (int i = 0; i < samples; i++) {
      final t = i / 44100.0;
      double sample = 0;
      for (int h = 0; h < harmonics.length; h++) {
        final partial = frequency * (h + 1);
        if (partial > 22050) break;
        sample += harmonics[h] * math.sin(2 * math.pi * partial * t);
      }
      out[i] = sample * 0.35 + (random.nextDouble() - 0.5) * 0.003;
    }
    return out;
  }

  final detector = PitchDetector(
      audioSampleRate: 44100, bufferSize: pitchWindowSize);

  test('every open string of every tuning is detected as itself', () async {
    final engine = TunerEngine();
    final failures = <String>[];
    int checked = 0;

    for (final instrument in Instrument.values) {
      for (final tuning in tuningsFor(instrument)) {
        for (final note in tuning.strings) {
          final target = engine.getFrequencyForNote(note)!;
          final result = await detector.getPitchFromFloatBuffer(pluck(target));
          final where = '${instrument.name}/${tuning.id} $note '
              '(${target.toStringAsFixed(2)} Hz)';
          checked++;

          if (!result.pitched) {
            failures.add('$where: not detected at all');
            continue;
          }
          final detected = engine.detectNote(result.pitch);
          if (detected.note != note) {
            failures.add('$where: heard as ${detected.note}');
          } else if (detected.cents.abs() > 10) {
            failures.add('$where: ${detected.cents.toStringAsFixed(1)} cents off');
          }
        }
      }
    }

    expect(checked, greaterThan(100), reason: 'the catalogue should be large');
    expect(failures, isEmpty,
        reason: '${failures.length} of $checked strings failed:\n'
            '  ${failures.join('\n  ')}');
  });

  test('every string is detected under an unequal temperament too', () async {
    // Meantone moves targets by up to ~27 cents; the detector must follow.
    final engine = TunerEngine(temperament: Temperament.quarterCommaMeantone);
    final failures = <String>[];
    for (final instrument in Instrument.values) {
      for (final tuning in tuningsFor(instrument)) {
        for (final note in tuning.strings) {
          final target = engine.getFrequencyForNote(note)!;
          final result = await detector.getPitchFromFloatBuffer(pluck(target));
          if (!result.pitched) {
            failures.add('${instrument.name}/${tuning.id} $note: not detected');
            continue;
          }
          final detected = engine.detectNote(result.pitch);
          if (detected.note != note) {
            failures.add('${instrument.name}/${tuning.id} $note: '
                'heard as ${detected.note}');
          }
        }
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n  '));
  });

  test('the lowest and highest strings in the catalogue are both reachable',
      () async {
    final engine = TunerEngine();
    int lowest = TunerEngine.maxMidi, highest = TunerEngine.minMidi;
    String lowNote = '', highNote = '';
    for (final instrument in Instrument.values) {
      for (final tuning in tuningsFor(instrument)) {
        for (final note in tuning.strings) {
          final midi = TunerEngine.midiForNoteName(note)!;
          if (midi < lowest) { lowest = midi; lowNote = note; }
          if (midi > highest) { highest = midi; highNote = note; }
        }
      }
    }
    for (final note in [lowNote, highNote]) {
      final result = await detector
          .getPitchFromFloatBuffer(pluck(engine.getFrequencyForNote(note)!));
      expect(result.pitched, isTrue, reason: '$note was not detected');
      expect(engine.detectNote(result.pitch).note, note);
    }
    // ignore: avoid_print
    print('catalogue spans $lowNote to $highNote');
  });
}
