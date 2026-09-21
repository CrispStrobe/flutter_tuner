// Smoke test: load each exported .onnx in the pure-Dart runtime and run one
// forward pass. The Kaggle kernel proved every op type is in the dispatch
// table; this proves the runtime actually parses and executes the graph,
// which is a different claim.
import 'dart:io';
import 'dart:typed_data';
import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';

void main(List<String> args) {
  final path = args[0];
  final inputName = args[1];
  final shape = args.sublist(2).map(int.parse).toList();
  final n = shape.reduce((a, b) => a * b);
  final sw = Stopwatch()..start();
  final onnx = OnnxModel.fromBytes(File(path).readAsBytesSync());
  print('loaded in ${sw.elapsedMilliseconds} ms');
  final data = Float32List(n);
  for (var i = 0; i < n; i++) {
    data[i] = ((i * 2654435761) % 2000) / 1000.0 - 1.0;
  }
  final x = Tensor.float(data, shape);
  sw.reset();
  final out = onnx.run({inputName: x}, onnx.outputNames);
  print('ran in ${sw.elapsedMilliseconds} ms');
  out.forEach((k, v) {
    final f = v.asFloatList();
    print('  $k shape=${v.shape} first=${f.take(3).toList()}');
  });
}
