import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class AudioService {
  final _audioRecorder = AudioRecorder();
  StreamSubscription? _audioSubscription;

  Future<void> init() async {}

  Future<bool> hasPermission() async {
    return await _audioRecorder.hasPermission();
  }

  Future<void> startListening(Function(Uint8List) onData) async {
    final stream = await _audioRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
      ),
    );
    _audioSubscription = stream.listen(onData);
  }

  Future<void> stopListening() async {
    await _audioSubscription?.cancel();
    await _audioRecorder.stop();
  }

  void dispose() {
    _audioSubscription?.cancel();
    _audioRecorder.dispose();
  }

  static AudioService create() => AudioService();
}

class ToneGeneratorService {
  bool _isInitialized = false;
  bool _isPlaying = false;
  int _currentNote = -1;
  double _phase = 0.0;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      await FlutterPcmSound.setup(sampleRate: 44100, channelCount: 1);
      await FlutterPcmSound.setFeedThreshold(4000);
      _isInitialized = true;
    } catch (e) {
      print('Error initializing tone generator: $e');
    }
  }

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

  void stopNote() {
    _isPlaying = false;
    _currentNote = -1;
    _phase = 0.0;
  }

  void dispose() {
    stopNote();
    FlutterPcmSound.release();
  }

  static ToneGeneratorService create() => ToneGeneratorService();
}