import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:record/record.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'audio_service_stub.dart' as stub;

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
  bool _isInitialized = false;
  bool _isPlaying = false;
  int _currentNote = -1;
  double _phase = 0.0;

  @override
  Future<void> init() async {
    if (_isInitialized) return;
    try {
      await FlutterPcmSound.setup(sampleRate: 44100, channelCount: 1);
      await FlutterPcmSound.setFeedThreshold(4000);
      _isInitialized = true;
    } catch (e) {
      // Failed to initialize tone generator
    }
  }

  @override
  void playNote(double frequency) {
    if (!_isInitialized) return;
    _currentNote = (69 + 12 * (math.log(frequency / 440.0) / math.log(2))).round();
    _phase = 0.0;
    if (!_isPlaying) {
      _isPlaying = true;
      FlutterPcmSound.setFeedCallback(_onFeed);
      _startFeeding();
    }
  }

  void _startFeeding() => _onFeed(0);

  void _onFeed(int remainingFrames) async {
    if (!_isPlaying || _currentNote < 0) return;
    final frequency = 440.0 * math.pow(2, (_currentNote - 69) / 12.0);
    final samples = _generateSineWave(frequency, 2000);
    await FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
  }

  List<int> _generateSineWave(double frequency, int numSamples) {
    final samples = <int>[];
    const sampleRate = 44100;
    const amplitude = 16000;
    for (int i = 0; i < numSamples; i++) {
      final value = (amplitude * math.sin(_phase)).toInt();
      samples.add(value);
      _phase += 2 * math.pi * frequency / sampleRate;
      if (_phase > 2 * math.pi) _phase -= 2 * math.pi;
    }
    return samples;
  }

  @override
  void stopNote() {
    _isPlaying = false;
    _currentNote = -1;
    _phase = 0.0;
  }

  @override
  void dispose() {
    stopNote();
    FlutterPcmSound.release();
  }

  static ToneGeneratorService create() => ToneGeneratorService();
}
