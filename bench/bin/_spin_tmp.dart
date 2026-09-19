import 'dart:typed_data';
import 'package:crispasr/crispasr.dart';
void main() {
  final s = CrispasrSession.open(
      '/mnt/storage/tuner-bench/models/basic-pitch-f32.gguf',
      libPath: '/mnt/volume1/CrispASR/build/src/libcrispasr.so.0.8.33',
      backend: 'basic-pitch', nThreads: 1);
  final pcm = Float32List(43844);
  for (int i = 0; i < pcm.length; i++) {
    pcm[i] = 0.3 * (i % 97) / 97 - 0.15;
  }
  for (int k = 0; k < 400; k++) {
    s.pianoNotes(pcm);
  }
  s.close();
}
