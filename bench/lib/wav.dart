/// Minimal 16-bit PCM WAV reader, lifted from `tool/tuner_probe.dart` so the
/// benchmark stays a standalone package.
library;

import 'dart:io';
import 'dart:typed_data';

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
