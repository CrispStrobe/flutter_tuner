/// Minimal WAV reader, lifted from `tool/tuner_probe.dart` so the benchmark
/// stays a standalone package.
///
/// 16-bit integer PCM covers every corpus here except MusicNet, which is
/// **32-bit IEEE float** (`audioFormat` 3) — so that is supported too, along
/// with 24- and 32-bit integer PCM. Anything else still throws rather than
/// guessing: a WAV read with the wrong sample width produces noise that
/// looks like audio, and every number downstream would be plausible and
/// wrong.
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
  // 1 = integer PCM, 3 = IEEE float. 0xFFFE is WAVE_FORMAT_EXTENSIBLE, whose
  // real format lives in the extension's SubFormat GUID; its first two bytes
  // carry the same 1-or-3, which is all that is needed here.
  int format = 1;
  int offset = 12;
  Float64List? samples;

  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;

    if (id == 'fmt ') {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE && size >= 26) {
        format = data.getUint16(body + 24, Endian.little);
      }
    } else if (id == 'data') {
      final bytesPerSample = bits ~/ 8;
      if (bytesPerSample == 0 ||
          !((format == 1 && (bits == 16 || bits == 24 || bits == 32)) ||
              (format == 3 && (bits == 32 || bits == 64)))) {
        throw FormatException(
            'unsupported WAV: format $format, $bits-bit (16/24/32-bit PCM '
            'and 32/64-bit float are handled)');
      }
      final frames = size ~/ (bytesPerSample * channels);
      samples = Float64List(frames);
      for (int f = 0; f < frames; f++) {
        double sum = 0;
        for (int c = 0; c < channels; c++) {
          final at = body + (f * channels + c) * bytesPerSample;
          switch ((format, bits)) {
            case (1, 16):
              sum += data.getInt16(at, Endian.little) / 32768.0;
            case (1, 24):
              // Little-endian 24-bit two's complement, sign-extended by
              // hand: there is no getInt24.
              final lo = data.getUint8(at);
              final mid = data.getUint8(at + 1);
              final hi = data.getInt8(at + 2);
              sum += ((hi << 16) | (mid << 8) | lo) / 8388608.0;
            case (1, 32):
              sum += data.getInt32(at, Endian.little) / 2147483648.0;
            case (3, 32):
              sum += data.getFloat32(at, Endian.little);
            case (3, 64):
              sum += data.getFloat64(at, Endian.little);
          }
        }
        samples[f] = sum / channels;
      }
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }

  if (samples == null) throw FormatException('No data chunk in $path');
  return (samples: samples, sampleRate: sampleRate);
}
