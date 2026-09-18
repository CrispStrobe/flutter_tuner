// Headless probe for CrispTuner's detection pipeline.
//
// Runs the *same* code the app runs — YIN pitch detection, the median filter,
// and the tempered nearest-note search from `lib/tuner_core.dart` — against a
// WAV file or a synthesised tone, from a terminal. No device, no simulator,
// no microphone.
//
//   dart run tool/tuner_probe.dart --note E2
//   dart run tool/tuner_probe.dart --tone 445.3 --a4 440
//   dart run tool/tuner_probe.dart --wav /tmp/guitar.wav
//   dart run tool/tuner_probe.dart --note C#4 --temperament quarterCommaMeantone
//
// It works only because the maths has no Flutter dependency; if someone moves
// it back behind `ChangeNotifier`, this stops running and that is the point.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pitch_detector_dart/pitch_detector.dart';

import 'package:flutter_tuner/temperament.dart';
import 'package:flutter_tuner/tuner_core.dart';

/// YIN searches lags up to bufferSize/2, so the lowest frequency it can
/// represent is 2*sampleRate/bufferSize — 43.07 Hz at 2048 samples, which is
/// above the open low E of a bass (41.20 Hz).
const int kDefaultBuffer = 4096;

const List<String> pitchClassNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
];

class Options {
  String? wav;
  double? tone;
  String? note;
  double a4 = 440.0;
  Temperament temperament = Temperament.equal;
  int root = 0;
  double seconds = 1.5;
  double detune = 0.0;
  bool pluck = true;
  bool quiet = false;
  int buffer = kDefaultBuffer;
}

void usage() {
  stdout.writeln('''
CrispTuner headless probe

  --wav <path>          analyse a 16-bit PCM WAV file
  --tone <hz>           synthesise this frequency
  --note <name>         synthesise this note (E2, C#4, …) at the current
                        concert pitch and temperament
  --detune <cents>      offset a synthesised note by this many cents
  --seconds <s>         length of synthesised audio (default 1.5)
  --pure                synthesise a bare sine instead of a plucked string
  --a4 <hz>             concert pitch (default 440)
  --temperament <name>  equal | pythagorean | quarterCommaMeantone |
                        werckmeisterIII | kirnbergerIII | vallotti
  --key <note>          temperament root, e.g. C or F (default C)
  --buffer <n>          YIN window in samples (default $kDefaultBuffer;
                        the detection floor is 2*rate/n Hz)
  --quiet               summary only
''');
}

Options parseArgs(List<String> args) {
  final o = Options();
  for (int i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) {
        stderr.writeln('Missing value for ${args[i]}');
        exit(2);
      }
      return args[++i];
    }

    switch (args[i]) {
      case '--wav':
        o.wav = next();
      case '--tone':
        o.tone = double.parse(next());
      case '--note':
        o.note = next();
      case '--detune':
        o.detune = double.parse(next());
      case '--seconds':
        o.seconds = double.parse(next());
      case '--pure':
        o.pluck = false;
      case '--a4':
        o.a4 = double.parse(next());
      case '--quiet':
        o.quiet = true;
      case '--buffer':
        o.buffer = int.parse(next());
      case '--temperament':
        final name = next();
        o.temperament = Temperament.values.firstWhere(
          (t) => t.name.toLowerCase() == name.toLowerCase(),
          orElse: () {
            stderr.writeln('Unknown temperament "$name"');
            exit(2);
          },
        );
      case '--key':
        final midi = midiForNoteName('${next()}4');
        if (midi == null) {
          stderr.writeln('Unknown key');
          exit(2);
        }
        o.root = midi % 12;
      case '-h':
      case '--help':
        usage();
        exit(0);
      default:
        stderr.writeln('Unknown option ${args[i]}');
        usage();
        exit(2);
    }
  }
  return o;
}

/// Minimal 16-bit PCM WAV reader. Returns interleaved samples mixed to mono.
({Float64List samples, int sampleRate}) readWav(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 12 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw FormatException('$path is not a RIFF/WAVE file');
  }

  int channels = 1, sampleRate = 44100, bits = 16;
  int offset = 12;
  Float64List? samples;

  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;

    if (id == 'fmt ') {
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (bits != 16) {
        throw FormatException('Only 16-bit PCM is supported, got $bits-bit');
      }
      final frames = size ~/ (2 * channels);
      samples = Float64List(frames);
      for (int f = 0; f < frames; f++) {
        double sum = 0;
        for (int c = 0; c < channels; c++) {
          sum += data.getInt16(body + (f * channels + c) * 2, Endian.little) /
              32768.0;
        }
        samples[f] = sum / channels;
      }
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }

  if (samples == null) throw FormatException('No data chunk in $path');
  return (samples: samples, sampleRate: sampleRate);
}

/// A plucked-string-ish tone: harmonics with falling amplitude, an exponential
/// decay, a touch of vibrato and a little noise. Closer to what the microphone
/// actually hears than a bare sine, and therefore a fairer test of YIN.
Float64List synthesise(double frequency, double seconds, bool pluck,
    {int sampleRate = 44100}) {
  final n = (seconds * sampleRate).round();
  final out = Float64List(n);
  final random = math.Random(7);

  if (!pluck) {
    for (int i = 0; i < n; i++) {
      out[i] = 0.6 * math.sin(2 * math.pi * frequency * i / sampleRate);
    }
    return out;
  }

  const harmonics = [1.0, 0.55, 0.32, 0.20, 0.13, 0.08, 0.05, 0.03];
  for (int i = 0; i < n; i++) {
    final t = i / sampleRate;
    // Slight vibrato, as a real player would produce.
    final vibrato = 1 + 0.0009 * math.sin(2 * math.pi * 5.2 * t);
    double sample = 0;
    for (int h = 0; h < harmonics.length; h++) {
      final partial = frequency * (h + 1) * vibrato;
      if (partial > sampleRate / 2) break;
      // Higher partials die away faster, as on a real string.
      final decay = math.exp(-t * (1.6 + 0.9 * h));
      sample += harmonics[h] * decay * math.sin(2 * math.pi * partial * t);
    }
    sample += (random.nextDouble() - 0.5) * 0.004;
    out[i] = sample * 0.5;
  }
  return out;
}

String meter(double cents) {
  const width = 21;
  const centre = width ~/ 2;
  final position =
      (centre + (cents.clamp(-50.0, 50.0) / 50.0) * centre).round();
  final cells = List<String>.filled(width, '·');
  cells[centre] = '|';
  cells[position.clamp(0, width - 1)] = cents.abs() < 5 ? '#' : 'o';
  return cells.join();
}

Future<int> run(List<String> args) async {
  final o = parseArgs(args);
  final table = PitchTable(
    a4Frequency: o.a4,
    temperament: TemperamentTable(o.temperament, root: o.root),
  );

  Float64List samples;
  int sampleRate = 44100;
  String source;
  double? expected;

  if (o.wav != null) {
    final wav = readWav(o.wav!);
    samples = wav.samples;
    sampleRate = wav.sampleRate;
    source = '${o.wav} ($sampleRate Hz, '
        '${(samples.length / sampleRate).toStringAsFixed(2)} s)';
  } else {
    double frequency;
    if (o.note != null) {
      final f = table.frequencyForNote(o.note!);
      if (f == null) {
        stderr.writeln('Unknown note "${o.note}"');
        return 2;
      }
      frequency = f;
    } else if (o.tone != null) {
      frequency = o.tone!;
    } else {
      usage();
      return 2;
    }
    frequency *= math.pow(2, o.detune / 1200.0);
    expected = frequency;
    samples = synthesise(frequency, o.seconds, o.pluck);
    source = '${o.pluck ? "plucked" : "sine"} '
        '${frequency.toStringAsFixed(3)} Hz'
        '${o.detune == 0 ? "" : " (${o.detune > 0 ? "+" : ""}${o.detune}¢)"}';
  }

  stdout.writeln('source      : $source');
  stdout.writeln('concert A4  : ${o.a4.toStringAsFixed(1)} Hz');
  stdout.writeln('temperament : ${o.temperament.name}'
      '${o.temperament == Temperament.equal ? "" : " in ${pitchClassNames[o.root]}"}');
  if (o.note != null) {
    stdout.writeln('target      : ${o.note} = '
        '${table.frequencyForNote(o.note!)!.toStringAsFixed(3)} Hz');
  }
  stdout.writeln('');

  final PitchDetector detector =
      PitchDetector(audioSampleRate: sampleRate * 1.0, bufferSize: o.buffer);
  stdout.writeln('yin window  : ${o.buffer} samples '
      '(floor ${(2 * sampleRate / o.buffer).toStringAsFixed(1)} Hz)');
  final smoother = PitchSmoother();

  final detections = <NoteDetectionResult>[];
  int frames = 0, unpitched = 0;

  if (!o.quiet) {
    stdout.writeln('    time      Hz    note   cents  meter');
  }

  for (int start = 0; start + o.buffer <= samples.length; start += o.buffer) {
    frames++;
    final block = Float64List.sublistView(samples, start, start + o.buffer);
    final raw = await detector.getPitchFromFloatBuffer(block);
    // Exactly the app's path: the gate and median from PitchSmoother, then
    // the tempered nearest note.
    final smoothed = smoother.accept(
      pitched: raw.pitched,
      probability: raw.probability,
      pitch: raw.pitch,
    );
    if (smoothed == null) {
      unpitched++;
      continue;
    }
    final result = table.nearestNote(smoothed);
    detections.add(result);

    if (!o.quiet) {
      final t = start / sampleRate;
      stdout.writeln('  ${t.toStringAsFixed(3)}s '
          '${result.pitch.toStringAsFixed(2).padLeft(8)} '
          '${result.note.padLeft(6)} '
          '${result.cents.toStringAsFixed(1).padLeft(7)}  '
          '${meter(result.cents)}');
    }
  }

  stdout.writeln('');
  if (detections.isEmpty) {
    stdout.writeln('No pitched frames out of $frames — nothing to report.');
    return 1;
  }

  final notes = <String, int>{};
  for (final d in detections) {
    notes[d.note] = (notes[d.note] ?? 0) + 1;
  }
  final winner =
      notes.entries.reduce((a, b) => a.value >= b.value ? a : b);
  final agreeing =
      detections.where((d) => d.note == winner.key).toList();
  final cents = agreeing.map((d) => d.cents).toList()..sort();
  final medianCents = cents[cents.length ~/ 2];
  final meanHz =
      agreeing.map((d) => d.pitch).reduce((a, b) => a + b) / agreeing.length;
  final spread = cents.last - cents.first;

  stdout.writeln('frames      : $frames '
      '(${detections.length} pitched, $unpitched rejected)');
  stdout.writeln('note        : ${winner.key} '
      '(${winner.value}/${detections.length} frames agree)');
  stdout.writeln('mean pitch  : ${meanHz.toStringAsFixed(3)} Hz');
  stdout.writeln('median error: ${medianCents.toStringAsFixed(2)} cents '
      '(${classifyTuning(medianCents).name})');
  stdout.writeln('spread      : ${spread.toStringAsFixed(2)} cents');
  if (expected != null) {
    final error = computeCents(meanHz, expected);
    stdout.writeln('vs input    : ${error.toStringAsFixed(2)} cents');
  }
  return 0;
}

Future<void> main(List<String> args) async {
  exitCode = await run(args);
}
