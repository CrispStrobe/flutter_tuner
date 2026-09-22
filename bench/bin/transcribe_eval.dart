// How well do the transcribers actually transcribe?
//
//   dart run bin/transcribe_eval.dart [--data <musicnet root>] [--limit N]
//                                     [--engines onnx,bp,piano,mt3]
//
// Every other table in this report is FRAME-level: is this 11.6 ms slice's
// pitch right. That is not the same question as "can it turn a recording
// into notes" — a system can be excellent frame by frame and still split one
// note into nine. §12 and §18 have that limitation; this closes it.
//
// MusicNet's standard test split: ten real classical recordings, 13,589
// annotated notes, solo piano through string and wind trios. Scored by
// mir_eval.transcription's rules (lib/note_metrics.dart): onset within
// 50 ms and pitch within 50 cents, one-to-one, with the offset condition
// reported separately because offsets are far less reliable than onsets in
// both annotations and models.
//
// Four transcribers, which is every one this project can reach:
//   onnx   Basic Pitch through onnx_runtime_dart — what the app ships
//   bp     Basic Pitch through CrispASR's ggml (the same model, §17)
//   piano  Kong's piano-transcription through CrispASR (77 MB)
//   mt3    MT3 through CrispASR (96 MB, 46.9M parameters)
//   hft    hFT-Transformer through onnx_runtime_dart (22 MB, 5.52M params)
//   oaf    Onsets & Frames through onnx_runtime_dart (106 MB, 26.49M params)
//
// The last two are the ONNX exports of §31, which had been verified against
// PyTorch and never run on audio, because their input is a spectrogram and
// nothing here could build one. `lib/mel.dart` can; `lib/hft.dart` and
// `lib/oaf.dart` are their window arithmetic and their own decoders.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/app/transcription.dart';
import 'package:tuner_bench/cometbeat/basic_pitch.dart' as cb;
import 'package:tuner_bench/hft.dart';
import 'package:tuner_bench/oaf.dart';
import 'package:tuner_bench/musicnet.dart';
import 'package:tuner_bench/note_metrics.dart';
import 'package:tuner_bench/wav.dart';

const _noteHead = 'StatefulPartitionedCall:1';
const _onsetHead = 'StatefulPartitionedCall:2';

String _libPath() {
  final ov = Platform.environment['CRISPTUNER_CRISPASR_LIB'];
  if (ov != null && ov.isNotEmpty) return ov;
  final home = Platform.environment['HOME'];
  if (home != null) {
    final drop = '$home/.cache/crispasr/libcrispasr.so';
    if (File(drop).existsSync()) return drop;
  }
  return CrispASR.defaultLibName();
}

Float64List _resample(Float64List input, double from, double to) {
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

/// Turn the pure-Dart frame decode into note events.
///
/// The app's decoder answers "what is sounding now" and never had to say
/// where a note began or ended — that is exactly the capability a
/// frame-level metric cannot see the absence of. A run of consecutive frames
/// in which a pitch is sounding IS a note; this is the simplest segmenter
/// that turns one into the other, and it is deliberately simple so the
/// number below is attributable to the model rather than to a clever
/// post-process.
List<Note> _notesFromFrames(List<Set<int>> frames, List<double> timesMs,
    {double minMs = 0}) {
  final open = <int, int>{}; // midi -> first frame index
  final out = <Note>[];
  for (int f = 0; f < frames.length; f++) {
    final now = frames[f];
    for (final midi in now) {
      open.putIfAbsent(midi, () => f);
    }
    for (final midi in open.keys.toList()) {
      if (now.contains(midi)) continue;
      final start = open.remove(midi)!;
      final onMs = timesMs[start];
      final offMs = timesMs[f];
      if (offMs - onMs >= minMs) {
        out.add((onsetMs: onMs, offsetMs: offMs, midi: midi.toDouble()));
      }
    }
  }
  open.forEach((midi, start) {
    out.add((
      onsetMs: timesMs[start],
      offsetMs: timesMs.last,
      midi: midi.toDouble()
    ));
  });
  out.sort((a, b) => a.onsetMs.compareTo(b.onsetMs));
  return out;
}

List<Note> _runOnnx(OnnxModel model, Float64List audio44k) {
  final audio = _resample(
      audio44k, 44100, BasicPitchGeometry.sampleRate.toDouble());
  const decoder = BasicPitchDecoder();
  final frames = <Set<int>>[];
  // Absolute time of every frame, computed from its WINDOW START rather than
  // from a running frame index. 172 frames of 256 samples span 44032
  // samples while the window advances 43844, so an index-based clock gains
  // 8.53 ms per window — 836 ms over a three-minute piece, against a 50 ms
  // onset tolerance. That single line was most of an 8% F1.
  final timesMs = <double>[];
  Set<int> carry = <int>{};
  for (int start = 0;
      start + BasicPitchGeometry.windowSamples <= audio.length;
      start += BasicPitchGeometry.windowSamples) {
    final input = Float32List(BasicPitchGeometry.windowSamples);
    for (int i = 0; i < input.length; i++) {
      input[i] = audio[start + i];
    }
    final out = model.run(
      {'serving_default_input_2:0': Tensor.float(input, [1, input.length, 1])},
      const [_noteHead, _onsetHead],
    );
    final note = Float64List.fromList(out[_noteHead]!.asFloatList());
    final onset = Float64List.fromList(out[_onsetHead]!.asFloatList());
    frames.addAll(decoder.decodeFrames(note, carry: carry, onset: onset));
    for (int f = 0; f < BasicPitchGeometry.frames; f++) {
      timesMs.add(1000 *
          (start + f * BasicPitchGeometry.frameHop) /
          BasicPitchGeometry.sampleRate);
    }
    carry = frames.last;
  }
  return _notesFromFrames(frames, timesMs);
}

/// The SAME ONNX model, decoded by CometBeat's faithful port of Spotify's
/// `note_creation.py` — onset peak-picking by `argrelmax`, a minimum note
/// length, `inferOnsets`, overlapping windows with the seams trimmed.
///
/// This arm exists to separate two questions that the first version of this
/// tool conflated. "How well does Basic Pitch transcribe" is about the
/// model; "how well does a run of consecutive above-threshold frames
/// approximate a note" is about the decoder — and §22 already established
/// that this repository's decoder answers a different question on purpose
/// (what is sounding *now*, for a live display). Scoring the app's decoder
/// on a transcription benchmark measures the mismatch, not the model.
/// Its reported times carry the same clock drift this tool had, and the
/// correction is applied here rather than in the copied source so
/// `tool/sync_cometbeat.sh --check` keeps verifying the copy is faithful.
///
/// The stitched grid keeps 142 frames per window (172 minus 15 trimmed from
/// each side) while the window advances 36,164 samples — and 142 x 256 =
/// 36,352. So a frame's time gains 188 samples for every window it is past,
/// 8.53 ms each, exactly the arithmetic that cost this tool five times its
/// score. Measured: 11.1% F1 as-is, **47.8% corrected**.
const int _cbFramesPerWindow = 142;
const int _cbDriftSamples = 142 * 256 - 36164; // 188

double _cbCorrect(double ms) {
  final frame = ms * BasicPitchGeometry.sampleRate / 1000 / 256;
  final window = frame ~/ _cbFramesPerWindow;
  return ms -
      1000 * window * _cbDriftSamples / BasicPitchGeometry.sampleRate;
}

List<Note> _runCometBeat(OnnxModel model, Float64List audio44k) => [
      for (final n in cb.basicPitchTranscribe(audio44k, model: model))
        (
          onsetMs: _cbCorrect(n.onMs),
          offsetMs: _cbCorrect(n.offMs),
          midi: n.midi.toDouble()
        )
    ];

/// hFT over a whole piece: stride the fixed 192-frame window, then its own
/// `convert_label_to_note`. The B head is the second of the two stages and
/// is what the paper reports; `infer.py` concatenates A and B, which emits
/// every note twice.
List<Note> _runHft(OnnxModel model, Float64List audio, int rate, String head) {
  final f = hftForward(model, audio, rate);
  return hftNotes(head == 'A' ? f.a : f.b);
}

/// Onsets & Frames over a whole piece, one forward pass — its time axis is
/// dynamic, so the chunking its `infer.py` does for GPU memory is not
/// needed.
List<Note> _runOaf(OnnxModel model, Float64List audio, int rate) =>
    oafNotes(oafForward(model, audio, rate));

List<Note> _runCrispasr(CrispasrSession s, Float64List audio44k, int rate) {
  final audio = _resample(audio44k, 44100, rate.toDouble());
  final pcm = Float32List(audio.length);
  for (int i = 0; i < pcm.length; i++) {
    pcm[i] = audio[i];
  }
  return [
    for (final n in s.pianoNotes(pcm))
      (onsetMs: n.onMs, offsetMs: n.offMs, midi: n.midi.toDouble())
  ];
}

void main(List<String> argv) async {
  var data = '/mnt/storage/tuner-bench/datasets/musicnet';
  var onnxPath = '../assets/models/basic_pitch.onnx';
  var limit = 0;
  var want = 'onnx,cbdec,bp,piano,mt3';
  var hftPath = '/mnt/storage/tuner-bench/onnx/hft_transformer.pruned.onnx';
  var oafPath = '/mnt/storage/tuner-bench/onnx/onsets_and_frames.onnx';
  var hftHead = 'B';
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--data':
        data = argv[++i];
      case '--onnx':
        onnxPath = argv[++i];
      case '--limit':
        limit = int.parse(argv[++i]);
      case '--engines':
        want = argv[++i];
      case '--hft-onnx':
        hftPath = argv[++i];
      case '--oaf-onnx':
        oafPath = argv[++i];
      case '--hft-head':
        hftHead = argv[++i];
    }
  }
  final wanted = want.split(',').map((s) => s.trim()).toSet();

  final pieces = findMusicNetTest(data);
  if (pieces.isEmpty) {
    stderr.writeln('no MusicNet test split under $data');
    exit(2);
  }
  final chosen = pieces.take(limit == 0 ? pieces.length : limit).toList();

  // Open what is available; a missing model is a skipped row, never a crash.
  OnnxModel? onnx;
  if (wanted.contains('onnx') || wanted.contains('cbdec')) {
    onnx = loadOnnxModel(onnxPath);
  }

  // The two spectrogram models. A missing file is a skipped row with a
  // reason printed, never a crash and never a silent omission (§30.1).
  OnnxModel? hft;
  if (wanted.contains('hft')) {
    if (File(hftPath).existsSync()) {
      hft = loadOnnxModel(hftPath);
      stdout.writeln('hft: ready (22 MB, head $hftHead)');
    } else {
      stdout.writeln('hft: model not found at $hftPath');
    }
  }
  OnnxModel? oaf;
  if (wanted.contains('oaf')) {
    if (File(oafPath).existsSync()) {
      oaf = loadOnnxModel(oafPath);
      stdout.writeln('oaf: ready (106 MB)');
    } else {
      stdout.writeln('oaf: model not found at $oafPath');
    }
  }

  final sessions = <String, CrispasrSession>{};
  final rates = <String, int>{};
  const backends = {'bp': 'basic-pitch', 'piano': 'piano-transcription',
    'mt3': 'mt3'};
  for (final e in backends.entries) {
    if (!wanted.contains(e.key)) continue;
    try {
      final lib = DynamicLibrary.open(_libPath());
      final entry = registryLookup(e.value, lib: lib);
      if (entry == null) {
        stdout.writeln('${e.key}: not registered in this libcrispasr');
        continue;
      }
      final dir = cacheDir(lib: lib);
      var model = dir == null ? null : '$dir/${entry.filename}';
      if (model == null || !File(model).existsSync()) {
        stdout.writeln('${e.key}: fetching ${entry.filename} '
            '(${entry.approxSize}) …');
        model = cacheEnsureFile(entry.filename, entry.url, quiet: true,
            lib: lib);
      }
      if (model == null) {
        stdout.writeln('${e.key}: model unavailable');
        continue;
      }
      final s = CrispasrSession.open(model,
          libPath: _libPath(), backend: e.value, nThreads: 2);
      sessions[e.key] = s;
      rates[e.key] = s.pianoSampleRate > 0
          ? s.pianoSampleRate
          : BasicPitchGeometry.sampleRate;
      stdout.writeln('${e.key}: ready (${rates[e.key]} Hz)');
    } catch (err) {
      stdout.writeln('${e.key}: unavailable — $err');
    }
  }

  final engines = <String>[
    if (onnx != null && wanted.contains('onnx')) 'onnx',
    if (onnx != null && wanted.contains('cbdec')) 'cbdec',
    if (hft != null) 'hft',
    if (oaf != null) 'oaf',
    ...sessions.keys,
  ];
  final noOffset = {for (final e in engines) e: NoteScore()};
  final withOffset = {for (final e in engines) e: NoteScore()};
  final seconds = {for (final e in engines) e: 0.0};
  double audioSeconds = 0;

  for (final piece in chosen) {
    final wav = readWav(piece.audioPath);
    audioSeconds += wav.samples.length / wav.sampleRate;
    stdout.write('\n${piece.id} (${piece.notes.length} notes, '
        'instruments ${(piece.instruments.toList()..sort()).join("/")}) ');
    for (final e in engines) {
      final sw = Stopwatch()..start();
      List<Note> est;
      try {
        est = switch (e) {
          'onnx' => _runOnnx(onnx!, wav.samples),
          'cbdec' => _runCometBeat(onnx!, wav.samples),
          'hft' => _runHft(hft!, wav.samples, wav.sampleRate, hftHead),
          'oaf' => _runOaf(oaf!, wav.samples, wav.sampleRate),
          _ => _runCrispasr(sessions[e]!, wav.samples, rates[e]!),
        };
      } catch (err) {
        stdout.write('[$e failed] ');
        continue;
      }
      sw.stop();
      seconds[e] = seconds[e]! + sw.elapsedMicroseconds / 1e6;
      noOffset[e]!.merge(scoreNotes(piece.notes, est));
      withOffset[e]!.merge(scoreNotes(piece.notes, est, withOffset: true));
      stdout.write('$e:${est.length} ');
    }
  }

  stdout.writeln('\n\n${chosen.length} MusicNet test pieces, '
      '${(audioSeconds / 60).toStringAsFixed(1)} min of audio, '
      '${chosen.fold<int>(0, (a, p) => a + p.notes.length)} reference notes\n');
  stdout.writeln('Onset + pitch (the standard note-level number):\n');
  stdout.writeln('| engine | precision | recall | F1 | onset err p50 | '
      'pitch err p50 | xRT |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- | --- |');
  for (final e in engines) {
    final s = noOffset[e]!;
    stdout.writeln('| $e | ${(100 * s.precision).toStringAsFixed(1)}% | '
        '${(100 * s.recall).toStringAsFixed(1)}% | '
        '**${(100 * s.f1).toStringAsFixed(1)}%** | '
        '${NoteScore.medianAbs(s.onsetErrorsMs).toStringAsFixed(1)} ms | '
        '${NoteScore.medianAbs(s.pitchErrorsCents).toStringAsFixed(1)} c | '
        '${(seconds[e]! / audioSeconds).toStringAsFixed(2)} |');
  }
  stdout.writeln('\nOnset + pitch + offset:\n');
  stdout.writeln('| engine | precision | recall | F1 |');
  stdout.writeln('| --- | --- | --- | --- |');
  for (final e in engines) {
    final s = withOffset[e]!;
    stdout.writeln('| $e | ${(100 * s.precision).toStringAsFixed(1)}% | '
        '${(100 * s.recall).toStringAsFixed(1)}% | '
        '${(100 * s.f1).toStringAsFixed(1)}% |');
  }
  for (final s in sessions.values) {
    s.close();
  }
}
