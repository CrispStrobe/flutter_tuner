import 'dart:io';
import 'dart:typed_data';
import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/cometbeat/basic_pitch.dart' as cb;
import 'package:tuner_bench/musicnet.dart';
import 'package:tuner_bench/note_metrics.dart';
import 'package:tuner_bench/wav.dart';

const int fpw = 142;
const int drift = 142 * 256 - 36164;
double fix(double ms) => ms - 1000 * (ms * 22050 / 1000 / 256 ~/ fpw) * drift / 22050;

void main() {
  final model = loadOnnxModel('../assets/models/basic_pitch.onnx');
  final pieces = findMusicNetTest('/mnt/storage/tuner-bench/datasets/musicnet').take(4).toList();
  final audio = {for (final p in pieces) p.id: readWav(p.audioPath).samples};

  // The model runs ONCE per window per piece; every decoder config replays
  // from this cache. Without it each config costs a full inference pass and
  // the sweep does not finish.
  final cache = <String, List<({Float32List notes, Float32List onsets})>>{};
  cb.BasicPitchWindowRunner runnerFor(String id) {
    final list = cache.putIfAbsent(id, () => []);
    var i = 0;
    return (window) {
      if (i < list.length) return list[i++];
      final out = model.run(
        {'serving_default_input_2:0': Tensor.float(window, [1, window.length, 1])},
        const ['StatefulPartitionedCall:1', 'StatefulPartitionedCall:2'],
      );
      final r = (
        notes: out['StatefulPartitionedCall:1']!.f ??
            Float32List.fromList(out['StatefulPartitionedCall:1']!.asFloatList()),
        onsets: out['StatefulPartitionedCall:2']!.f ??
            Float32List.fromList(out['StatefulPartitionedCall:2']!.asFloatList()),
      );
      list.add(r);
      i++;
      return r;
    };
  }

  stdout.writeln('| onset | frame | minLen | melodia | P | R | F1 |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- | --- |');
  for (final cfg in [
    (0.5, 0.3, 11, false),
    (0.5, 0.3, 11, true),
    (0.3, 0.3, 11, true),
    (0.2, 0.2, 11, true),
    (0.2, 0.2, 5, true),
    (0.1, 0.15, 5, true),
    (0.3, 0.2, 5, false),
  ]) {
    final t = NoteScore();
    for (final p in pieces) {
      final notes = cb.basicPitchTranscribeWithRunner(audio[p.id]!,
          run: runnerFor(p.id),
          onsetThreshold: cfg.$1,
          frameThreshold: cfg.$2,
          minNoteLenFrames: cfg.$3,
          melodiaTrick: cfg.$4);
      t.merge(scoreNotes(p.notes, [
        for (final n in notes)
          (onsetMs: fix(n.onMs), offsetMs: fix(n.offMs), midi: n.midi.toDouble())
      ]));
    }
    stdout.writeln('| ${cfg.$1} | ${cfg.$2} | ${cfg.$3} | ${cfg.$4} | '
        '${(100 * t.precision).toStringAsFixed(1)}% | '
        '${(100 * t.recall).toStringAsFixed(1)}% | '
        '${(100 * t.f1).toStringAsFixed(1)}% |');
  }
}
