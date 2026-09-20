// Does onnx_runtime_dart's isolate pool help Basic Pitch?
//
//   dart run bin/dart_parallel.dart [--onnx …] [--reps N]
//
// §17.3 measured the pure-Dart path at 0.78 GMAC/s against 484.4 MMAC per
// window, so most of the machine is unused. The package already ships a
// GemmPool: `parallelize(workers:, poolConv:)` partitions work across
// isolates and `runAsync` executes on them.
//
// Its own doc comment predicts this will not help here — "conv messages
// carry the whole input activation to every worker, and for CNN workloads
// measured so far that copying costs more than the banded compute saves" —
// and Basic Pitch is all Conv with no top-level MatMul, which is the case
// `parallelize` partitions without `poolConv`. That prediction is worth a
// number rather than a nod: if it holds, the Dart path's headroom is in the
// kernel, not in the core count, and that is the finding.
//
// Outputs are compared element-for-element, because a fast wrong answer is
// the failure mode that matters (bench/REPORT.md §17 cites the project rule:
// a speedup is a lie until the work is proven).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';
import 'package:onnx_runtime_dart/onnx_runtime_dart_io.dart';
import 'package:tuner_bench/app/transcription.dart';

const _noteHead = 'StatefulPartitionedCall:1';
const _onsetHead = 'StatefulPartitionedCall:2';
const _input = 'serving_default_input_2:0';

/// 484.4 MMAC per window, counted from the layer shapes in REPORT.md §17.3.
const double _mmacPerWindow = 484.4;

double median(List<double> v) {
  final s = List<double>.of(v)..sort();
  return s[s.length ~/ 2];
}

Float32List _signal() {
  // Deterministic and broadband, so every arm does identical work and no arm
  // can win by hitting a cheaper input.
  final x = Float32List(BasicPitchGeometry.windowSamples);
  final rnd = math.Random(20260919);
  double phase = 0;
  for (int i = 0; i < x.length; i++) {
    phase += 2 * math.pi * 196.0 / BasicPitchGeometry.sampleRate;
    x[i] = 0.5 * math.sin(phase) + 0.05 * (rnd.nextDouble() - 0.5);
  }
  return x;
}

void _report(String label, List<double> ms) {
  final m = median(ms);
  stdout.writeln('  ${label.padRight(28)} ${m.toStringAsFixed(0)} ms  '
      '(${(_mmacPerWindow / m).toStringAsFixed(2)} GMAC/s)');
}

/// Element-for-element, not a tolerance: the arms run the same kernels in the
/// same order, so anything but equality is a bug rather than drift.
int _mismatches(Float32List a, Float32List b) {
  if (a.length != b.length) return -1;
  int n = 0;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) n++;
  }
  return n;
}

Future<void> main(List<String> argv) async {
  var onnxPath = '../assets/models/basic_pitch.onnx';
  var reps = 5;
  // One arm per process. Dart's JIT optimises hot code across the whole
  // isolate, so running every arm in one process warms the kernels for
  // whichever arm goes second and penalises the one that goes first — which
  // is exactly the harness asymmetry this project's own rules call out. The
  // driver below runs each arm cold, in its own process.
  String? only;
  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--onnx':
        onnxPath = argv[++i];
      case '--reps':
        reps = int.parse(argv[++i]);
      case '--only':
        only = argv[++i];
    }
  }

  final x = _signal();
  Map<String, Tensor> inputs() =>
      {_input: Tensor.float(x, [1, x.length, 1])};

  stdout.writeln('Basic Pitch, ${_mmacPerWindow.toStringAsFixed(1)} MMAC per '
      '2 s window, median of $reps after one warm-up\n');

  // ── baseline: what the app does today ────────────────────────────────
  Float32List? reference;
  if (only == null || only == 'base') {
  final base = loadOnnxModel(onnxPath);
  base.run(inputs(), const [_noteHead, _onsetHead]); // warm
  final baseMs = <double>[];
  for (int r = 0; r < reps; r++) {
    final sw = Stopwatch()..start();
    final out = base.run(inputs(), const [_noteHead, _onsetHead]);
    sw.stop();
    baseMs.add(sw.elapsedMicroseconds / 1000);
    reference = Float32List.fromList(out[_noteHead]!.asFloatList());
  }
  _report('run() single isolate', baseMs);
  if (only == 'base') {
    stdout.writeln('\n  cores visible: ${Platform.numberOfProcessors}');
    return;
  }
  }
  // Only the pooled arms need a reference, and with --only they cannot share
  // one with the baseline process; equality is checked in the all-arms run.


  // ── runAsync with NO pool ────────────────────────────────────────────
  //
  // §19 recorded an unexplained 6–17%: `parallelize(N)` without `poolConv`
  // measured faster than `run()` on four machines, while the graph has zero
  // MatMul for it to partition. Either `runAsync` differs from `run` in more
  // than pooling, or the number was an artefact. This arm separates the two
  // — same async node loop, no workers spawned at all.
  if (only == null || only == 'runAsync no pool') {
    final m = loadOnnxModel(onnxPath);
    await m.runAsync(inputs(), const [_noteHead, _onsetHead]); // warm
    final ms = <double>[];
    Float32List last = Float32List(0);
    for (int r = 0; r < reps; r++) {
      final sw = Stopwatch()..start();
      final out = await m.runAsync(inputs(), const [_noteHead, _onsetHead]);
      sw.stop();
      ms.add(sw.elapsedMicroseconds / 1000);
      last = Float32List.fromList(out[_noteHead]!.asFloatList());
    }
    _report('runAsync, no pool', ms);
    final ref = reference;
    if (ref != null && _mismatches(ref, last) != 0) {
      stdout.writeln('    !! differs from run()');
    }
    if (only != null) {
      stdout.writeln('\n  cores visible: ${Platform.numberOfProcessors}');
      return;
    }
  }

  // ── the pool, with and without conv fan-out ──────────────────────────
  for (final workers in const [2, 4]) {
    for (final poolConv in const [false, true]) {
      final label = 'parallelize($workers'
          '${poolConv ? ", poolConv" : ""})';
      if (only != null && only != label) continue;
      final model = loadOnnxModel(onnxPath);
      try {
        await model.parallelize(workers: workers, poolConv: poolConv);
      } catch (e) {
        stdout.writeln('  ${label.padRight(28)} unavailable: $e');
        continue;
      }
      try {
        await model.runAsync(inputs(), const [_noteHead, _onsetHead]); // warm
        final ms = <double>[];
        Float32List last = Float32List(0);
        for (int r = 0; r < reps; r++) {
          final sw = Stopwatch()..start();
          final out =
              await model.runAsync(inputs(), const [_noteHead, _onsetHead]);
          sw.stop();
          ms.add(sw.elapsedMicroseconds / 1000);
          last = Float32List.fromList(out[_noteHead]!.asFloatList());
        }
        _report(label, ms);
        final ref = reference;
        final bad = ref == null ? 0 : _mismatches(ref, last);
        if (bad != 0) {
          stdout.writeln('    !! $bad element(s) differ from the baseline '
              '— a faster wrong answer is not a win');
        }
      } finally {
        model.dispose();
      }
    }
  }

  stdout.writeln('\n  cores visible: ${Platform.numberOfProcessors}');
}
