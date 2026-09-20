// Two runtimes, one model, the same audio: ggml against pure Dart.
//
//   dart run bin/runtime_compare.dart <wav> [--lib …] [--gguf …] [--onnx …]
//
// The app runs Basic Pitch through onnx_runtime_dart — pure Dart, no FFI, no
// native library on any of six platforms. CrispASR runs the same model
// through ggml over FFI, which is what the sibling project CrisperWeaver
// uses. The question this answers is what the FFI path would buy, since what
// it costs is already known: libcrispasr shipped to five platforms and no web
// build at all.
//
// The two are not the same shape of answer, and that is half the finding.
// The ONNX path returns the raw note head — 172 frames x 88 pitches of
// activation — and this repository's decoder turns the newest frames into
// "what is sounding now". CrispASR returns segmented note *events* with
// onsets, offsets and velocities. One is a live display; the other is a
// transcription.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/app/transcription.dart';
import 'package:tuner_bench/jams.dart';
import 'package:tuner_bench/wav.dart';

const _noteHead = 'StatefulPartitionedCall:1';
const _onsetHead = 'StatefulPartitionedCall:2';

/// Resample to whatever rate each runtime asks for. Both arms here end up at
/// 22.05 kHz — Basic Pitch's native rate on either runtime — but the ggml
/// side queries rather than assumes, because the C parameter is still named
/// `pcm_16k` after piano-transcription and only the query is honest.
Float64List resampleLinear(Float64List input, double from, double to) {
  if ((from - to).abs() < 1) return input;
  final ratio = from / to;
  final out = Float64List((input.length / ratio).floor());
  for (int i = 0; i < out.length; i++) {
    final x = i * ratio;
    final j = x.floor();
    final t = x - j;
    final a = input[j];
    final b = j + 1 < input.length ? input[j + 1] : a;
    out[i] = a + (b - a) * t;
  }
  return out;
}

/// Frame-level multi-pitch score, the same rules as REPORT.md §12: a
/// reference frame every [_scoreHop] seconds, a pitch counted present if any
/// note covers that frame, and precision/recall/F1 over the set of (frame,
/// pitch) pairs. Octave errors are not excused; nothing is collapsed.
///
/// The point of scoring both arms this way rather than only comparing them to
/// each other is that agreement is not accuracy. Two runtimes of one model
/// can agree perfectly and both be wrong, and the pitches they disagree on
/// are exactly the ones where a ground truth decides which is right.
const double _scoreHop = BasicPitchGeometry.frameHop / BasicPitchGeometry.sampleRate;

typedef Score = ({int tp, int fp, int fn});

Score scoreFrames(Set<int> Function(int frame) estimate,
    Set<int> Function(int frame) truth, int frames) {
  int tp = 0, fp = 0, fn = 0;
  for (int f = 0; f < frames; f++) {
    final e = estimate(f);
    final t = truth(f);
    for (final p in e) {
      if (t.contains(p)) {
        tp++;
      } else {
        fp++;
      }
    }
    for (final p in t) {
      if (!e.contains(p)) fn++;
    }
  }
  return (tp: tp, fp: fp, fn: fn);
}

String formatScore(String label, Score s) {
  final p = s.tp + s.fp == 0 ? 0.0 : 100 * s.tp / (s.tp + s.fp);
  final r = s.tp + s.fn == 0 ? 0.0 : 100 * s.tp / (s.tp + s.fn);
  final f1 = p + r == 0 ? 0.0 : 2 * p * r / (p + r);
  return '  $label  precision ${p.toStringAsFixed(1)}%  '
      'recall ${r.toStringAsFixed(1)}%  F1 ${f1.toStringAsFixed(1)}%';
}

/// GuitarSet's annotation for a `…_mic.wav`, if it is where the corpus puts
/// it. Returns null rather than failing: the runtime comparison is still
/// worth running on audio with no ground truth.
String? jamsFor(String wavPath) {
  final base = wavPath.split('/').last
      .replaceAll(RegExp(r'_(mic|mix|hex.*)\.wav$'), '')
      .replaceAll('.wav', '');
  final dir = wavPath.substring(0, wavPath.lastIndexOf('/'));
  for (final candidate in [
    '${dir.substring(0, dir.lastIndexOf("/"))}/annotation/$base.jams',
    '$dir/$base.jams',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

double median(List<double> v) {
  if (v.isEmpty) return double.nan;
  final s = List<double>.of(v)..sort();
  return s[s.length ~/ 2];
}

void main(List<String> argv) {
  String? wavPath;
  var libPath = '/mnt/volume1/CrispASR/build/src/libcrispasr.so.0.8.33';
  var ggufPath = '/mnt/storage/tuner-bench/models/basic-pitch-f32.gguf';
  var onnxPath = '../assets/models/basic_pitch.onnx';
  var threads = 4;
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--lib':
        libPath = argv[++i];
      case '--gguf':
        ggufPath = argv[++i];
      case '--onnx':
        onnxPath = argv[++i];
      case '--threads':
        threads = int.parse(argv[++i]);
      default:
        wavPath ??= argv[i];
    }
  }
  if (wavPath == null) {
    stderr.writeln('usage: dart run bin/runtime_compare.dart <wav>');
    exit(2);
  }

  final wav = readWav(wavPath);
  final rate = wav.sampleRate.toDouble();
  stdout.writeln('audio   : $wavPath '
      '(${rate.toStringAsFixed(0)} Hz, '
      '${(wav.samples.length / rate).toStringAsFixed(2)} s)');

  // ---------------- pure Dart, ONNX ----------------
  stdout.writeln('');
  stdout.writeln('pure Dart (onnx_runtime_dart), ${File(onnxPath).lengthSync() ~/ 1024} KB model');
  final model = loadOnnxModel(onnxPath);
  final forOnnx = resampleLinear(
      wav.samples, rate, BasicPitchGeometry.sampleRate.toDouble());
  // `stateless`, not the shipped default. §18 changed BasicPitchDecoder's
  // defaults to 0.5/0.25 with hysteresis, and this harness scores the ONNX
  // arm frame-by-frame with no hysteresis at all — so the live default's
  // start threshold alone would score 0.5 flat, which is neither what ships
  // nor what §17 published. Pinning the old pair keeps §17's table
  // reproducible; §18's table is the one that describes the app.
  const decoder = BasicPitchDecoder.stateless;

  final onnxNotes = <int>{};
  final onnxFrames = <int, Set<int>>{};
  final onnxTimings = <double>[];
  int onnxWindows = 0;
  for (int start = 0;
      start + BasicPitchGeometry.windowSamples <= forOnnx.length;
      start += BasicPitchGeometry.windowSamples) {
    final input = Float32List(BasicPitchGeometry.windowSamples);
    for (int i = 0; i < input.length; i++) {
      input[i] = forOnnx[start + i];
    }
    final sw = Stopwatch()..start();
    final out = model.run(
      {'serving_default_input_2:0': Tensor.float(input, [1, input.length, 1])},
      const [_noteHead, _onsetHead],
    );
    sw.stop();
    onnxTimings.add(sw.elapsedMicroseconds / 1000);

    // Every frame of the window, so the comparison is against CrispASR's
    // whole-buffer note list rather than against one live display frame.
    final note = Float64List.fromList(out[_noteHead]!.asFloatList());
    const bins = BasicPitchGeometry.noteBins;
    final frameBase = (start / BasicPitchGeometry.frameHop).round();
    for (int f = 0; f < BasicPitchGeometry.frames; f++) {
      for (int b = 0; b < bins; b++) {
        if (note[f * bins + b] >= decoder.noteThreshold) {
          final midi = BasicPitchGeometry.lowestMidi + b;
          onnxNotes.add(midi);
          (onnxFrames[frameBase + f] ??= <int>{}).add(midi);
        }
      }
    }
    onnxWindows++;
  }
  stdout.writeln('  ${onnxTimings.length} window(s), '
      '${median(onnxTimings).toStringAsFixed(0)} ms each (median)');
  stdout.writeln('  notes seen: ${(onnxNotes.toList()..sort()).join(", ")}');

  // ---------------- ggml, CrispASR over FFI ----------------
  stdout.writeln('');
  stdout.writeln('CrispASR (ggml over FFI), '
      '${File(ggufPath).lengthSync() ~/ 1024} KB model, '
      '$threads thread(s)');
  if (!File(libPath).existsSync()) {
    stdout.writeln('  libcrispasr not found at $libPath — this is the '
        'packaging cost, in one line.');
    return;
  }

  final CrispasrSession session;
  try {
    session = CrispasrSession.open(ggufPath,
        libPath: libPath, backend: 'basic-pitch', nThreads: threads);
  } catch (e) {
    stdout.writeln('  could not open a basic-pitch session: $e');
    return;
  }

  try {
    // `pianoSampleRate`, not `pitchSampleRate`: CrispASR's basic-pitch arm
    // hangs off crispasr_session_piano (the note-event API), while the pitch
    // arm is CREPE's monophonic F0 track. Asking the wrong one returns 0
    // rather than throwing — it is a capability probe — which is exactly how
    // this was wrong for a whole run.
    var wanted = session.pianoSampleRate;
    if (wanted <= 0) {
      wanted = BasicPitchGeometry.sampleRate;
      stdout.writeln('  backend reported no rate; assuming $wanted Hz');
    } else {
      stdout.writeln('  backend wants $wanted Hz');
    }
    final forGgml = resampleLinear(wav.samples, rate, wanted.toDouble());
    final pcm = Float32List(forGgml.length);
    for (int i = 0; i < pcm.length; i++) {
      pcm[i] = forGgml[i];
    }

    // Warm once: the first call pays for lazy graph setup on either runtime.
    session.pianoNotes(Float32List.sublistView(pcm, 0, math.min(pcm.length, wanted)));

    final sw = Stopwatch()..start();
    final notes = session.pianoNotes(pcm);
    sw.stop();
    final seconds = forGgml.length / wanted;
    final perWindow = sw.elapsedMilliseconds * 2.0 / seconds;
    stdout.writeln('  whole buffer (${seconds.toStringAsFixed(2)} s) in '
        '${sw.elapsedMilliseconds} ms '
        '=> ${perWindow.toStringAsFixed(0)} ms per 2 s window');
    final midi = (notes.map((n) => n.midi).toSet().toList()..sort());
    stdout.writeln('  note events: ${notes.length}, '
        'distinct pitches: ${midi.join(", ")}');
    if (notes.isNotEmpty) {
      final first = notes.reduce((a, b) => a.onMs <= b.onMs ? a : b);
      stdout.writeln('  earliest event: midi ${first.midi} at '
          '${first.onMs.toStringAsFixed(0)} ms, '
          'velocity ${first.velocity}');
    }

    final ggmlFrames = <int, Set<int>>{};
    for (final n in notes) {
      final from = (n.onMs / 1000 / _scoreHop).floor();
      final to = (n.offMs / 1000 / _scoreHop).ceil();
      for (int f = from; f < to; f++) {
        (ggmlFrames[f] ??= <int>{}).add(n.midi);
      }
    }

    // ---------------- against ground truth ----------------
    final jamsPath = jamsFor(wavPath);
    if (jamsPath != null) {
      final truth = readJams(jamsPath);
      final truthFrames = <int, Set<int>>{};
      for (final n in truth.notes) {
        final from = (n.onset / _scoreHop).floor();
        final to = (n.offset / _scoreHop).ceil();
        for (int f = from; f < to; f++) {
          (truthFrames[f] ??= <int>{}).add(n.midi.round());
        }
      }
      // Only the span the ONNX arm actually ran over, so both are judged on
      // the same audio.
      final limit = (onnxWindows *
              BasicPitchGeometry.windowSamples /
              BasicPitchGeometry.frameHop)
          .floor();
      Set<int> t(int f) => truthFrames[f] ?? const <int>{};
      stdout.writeln('');
      stdout.writeln('against ${jamsPath.split("/").last} '
          '($limit frames of ${_scoreHop * 1000 ~/ 1} ms):');
      stdout.writeln(formatScore('pure Dart',
          scoreFrames((f) => onnxFrames[f] ?? const <int>{}, t, limit)));
      stdout.writeln(formatScore('CrispASR ',
          scoreFrames((f) => ggmlFrames[f] ?? const <int>{}, t, limit)));
    }

    // ---------------- agreement ----------------
    stdout.writeln('');
    final shared = onnxNotes.intersection(midi.toSet());
    final union = {...onnxNotes, ...midi};
    stdout.writeln('agreement: ${shared.length}/${union.length} pitches in '
        'common (${(100 * shared.length / math.max(1, union.length)).toStringAsFixed(0)}%)');
    final onlyOnnx = (onnxNotes.difference(midi.toSet()).toList()..sort());
    final onlyGgml = (midi.toSet().difference(onnxNotes).toList()..sort());
    if (onlyOnnx.isNotEmpty) stdout.writeln('  only pure Dart: ${onlyOnnx.join(", ")}');
    if (onlyGgml.isNotEmpty) stdout.writeln('  only CrispASR : ${onlyGgml.join(", ")}');
  } finally {
    session.close();
  }
}
