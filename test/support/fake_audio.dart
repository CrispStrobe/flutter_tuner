import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_tuner/audio_service_stub.dart';

/// A microphone that plays a synthesised plucked-string tone.
///
/// Stands in for the platform recorder so tests — and the store-screenshot
/// renderer — can push audio through the app's real detection pipeline and
/// see exactly what a player would see, with no device.
class FakeAudioService implements AudioService {
  /// The frequency being "played", in Hz. May be changed while listening.
  double frequency;

  static const int sampleRate = 44100;
  static const int chunkSize = 2048;

  Timer? _timer;
  int _sampleIndex = 0;
  final _random = math.Random(11);

  FakeAudioService({this.frequency = 110.0});

  @override
  Future<void> init() async {}

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<List<AudioInputDevice>> listInputDevices() async => const [];

  @override
  Future<void> startListening(Function(Uint8List) onData,
      {String? deviceId}) async {
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: (1000 * chunkSize / sampleRate).round()),
      (_) => onData(_nextChunk()),
    );
  }

  Uint8List _nextChunk() {
    const harmonics = [1.0, 0.55, 0.32, 0.2, 0.13, 0.08];
    final bytes = ByteData(chunkSize * 2);
    for (int i = 0; i < chunkSize; i++) {
      final t = _sampleIndex++ / sampleRate;
      double sample = 0;
      for (int h = 0; h < harmonics.length; h++) {
        final partial = frequency * (h + 1);
        if (partial > sampleRate / 2) break;
        sample += harmonics[h] * math.sin(2 * math.pi * partial * t);
      }
      sample = sample * 0.35 + (_random.nextDouble() - 0.5) * 0.003;
      final value = (sample.clamp(-1.0, 1.0) * 32767).round();
      bytes.setInt16(i * 2, value, Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  @override
  Future<void> stopListening() async {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
  }
}

/// A tone generator that makes no sound.
class SilentToneGenerator implements ToneGeneratorService {
  @override
  Future<void> init() async {}
  @override
  void playNote(double frequency) {}
  @override
  void stopNote() {}
  @override
  void dispose() {}
}
