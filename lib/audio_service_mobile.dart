import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:record/record.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'audio_service_stub.dart' as stub;
export 'audio_service_stub.dart' show AudioInputDevice;

class AudioService implements stub.AudioService {
  final _audioRecorder = AudioRecorder();
  StreamSubscription? _audioSubscription;

  @override
  Future<void> init() async {}

  @override
  Future<bool> hasPermission() async {
    return await _audioRecorder.hasPermission();
  }

  @override
  Future<List<stub.AudioInputDevice>> listInputDevices() async {
    try {
      final devices = await _audioRecorder.listInputDevices();
      return devices
          .map((d) => stub.AudioInputDevice(id: d.id, label: d.label))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> startListening(Function(Uint8List) onData, {String? deviceId}) async {
    InputDevice? device;
    if (deviceId != null) {
      final devices = await _audioRecorder.listInputDevices();
      final match = devices.where((d) => d.id == deviceId);
      if (match.isNotEmpty) device = match.first;
    }

    final stream = await _audioRecorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
        device: device,
      ),
    );
    _audioSubscription = stream.listen(onData);
  }

  @override
  Future<void> stopListening() async {
    await _audioSubscription?.cancel();
    await _audioRecorder.stop();
  }

  @override
  void dispose() {
    _audioSubscription?.cancel();
    _audioRecorder.dispose();
  }

  static AudioService create() => AudioService();
}

class ToneGeneratorService implements stub.ToneGeneratorService {
  static const int _sampleRate = 44100;
  static const int _amplitude = 16000;
  static const int _framesPerFeed = 2000;

  bool _isInitialized = false;
  bool _isPlaying = false;

  /// The exact frequency requested, in Hz. Must NOT be quantised to a MIDI
  /// note: the user can retune A4 anywhere in 415–465 Hz, and rounding to the
  /// nearest equal-tempered semitone would silently play the 440 Hz-based
  /// pitch instead of the calibrated one.
  double _frequency = 0.0;
  double _phase = 0.0;

  /// Reused across feed callbacks, which fire continuously while a tone sounds.
  final Int16List _feedBuffer = Int16List(_framesPerFeed);

  @override
  Future<void> init() async {
    if (_isInitialized) return;
    try {
      await FlutterPcmSound.setup(sampleRate: _sampleRate, channelCount: 1);
      await FlutterPcmSound.setFeedThreshold(4000);
      _isInitialized = true;
    } catch (_) {
      // Audio output unavailable on this device — reference tones stay silent
      // but pitch detection is unaffected, so this is not fatal.
    }
  }

  @override
  void playNote(double frequency) {
    if (!_isInitialized || frequency <= 0) return;
    _frequency = frequency;
    _phase = 0.0;
    if (!_isPlaying) {
      _isPlaying = true;
      FlutterPcmSound.setFeedCallback(_onFeed);
      _onFeed(0);
    }
  }

  void _onFeed(int remainingFrames) {
    if (!_isPlaying || _frequency <= 0) return;
    _fillSineWave();
    // Fire-and-forget: the plugin calls back for more when it drains. A failed
    // feed just means silence, so swallow it rather than raising an unhandled
    // async error from an audio callback.
    FlutterPcmSound.feed(PcmArrayInt16(bytes: _feedBuffer.buffer.asByteData()))
        .catchError((_) {});
  }

  /// Fill [_feedBuffer] with a phase-continuous sine at [_frequency].
  void _fillSineWave() {
    final double phaseStep = 2 * math.pi * _frequency / _sampleRate;
    for (int i = 0; i < _framesPerFeed; i++) {
      _feedBuffer[i] = (_amplitude * math.sin(_phase)).toInt();
      _phase += phaseStep;
      if (_phase > 2 * math.pi) _phase -= 2 * math.pi;
    }
  }

  @override
  void stopNote() {
    _isPlaying = false;
    _frequency = 0.0;
    _phase = 0.0;
  }

  @override
  void dispose() {
    stopNote();
    FlutterPcmSound.release();
  }

  static ToneGeneratorService create() => ToneGeneratorService();
}
