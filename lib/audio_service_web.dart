// ignore_for_file: avoid_web_libraries_in_flutter, non_constant_identifier_names

import 'dart:async';
import 'dart:typed_data';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'audio_service_stub.dart' as stub;

@JS('AudioContext')
@staticInterop
class AudioContext {
  external factory AudioContext();
}

extension AudioContextExtension on AudioContext {
  external AnalyserNode createAnalyser();
  external MediaStreamAudioSourceNode createMediaStreamSource(web.MediaStream stream);
  external ScriptProcessorNode createScriptProcessor(int bufferSize, int numberOfInputChannels, int numberOfOutputChannels);
  external OscillatorNode createOscillator();
  external GainNode createGain();
  external AudioDestinationNode get destination;
  external JSPromise close();
  external AudioWorklet get audioWorklet;
}

@JS()
@staticInterop
class AudioWorklet {}

extension AudioWorkletExtension on AudioWorklet {
  external JSPromise addModule(String moduleURL);
}

@JS('AudioWorkletNode')
@staticInterop
class AudioWorkletNode {
  external factory AudioWorkletNode(AudioContext context, String name);
}

extension AudioWorkletNodeExtension on AudioWorkletNode {
  external MessagePort get port;
  external void connect(JSObject destination);
  external void disconnect();
}

@JS()
@staticInterop
class MessagePort {}

extension MessagePortExtension on MessagePort {
  external set onmessage(JSFunction? handler);
}

@JS()
@staticInterop
class MessageEvent {}

extension MessageEventExtension on MessageEvent {
  external JSObject get data;
}

@JS()
@staticInterop
class AnalyserNode {}

extension AnalyserNodeExtension on AnalyserNode {
  external set fftSize(int value);
  external void connect(JSObject destination);
  external void disconnect();
}

@JS()
@staticInterop
class MediaStreamAudioSourceNode {}

extension MediaStreamAudioSourceNodeExtension on MediaStreamAudioSourceNode {
  external void connect(JSObject destination);
  external void disconnect();
}

@JS()
@staticInterop
class ScriptProcessorNode {}

extension ScriptProcessorNodeExtension on ScriptProcessorNode {
  external set onaudioprocess(JSFunction? handler);
  external void connect(JSObject destination);
  external void disconnect();
}

@JS()
@staticInterop
class AudioProcessingEvent {}

extension AudioProcessingEventExtension on AudioProcessingEvent {
  external AudioBuffer get inputBuffer;
}

@JS()
@staticInterop
class AudioBuffer {}

extension AudioBufferExtension on AudioBuffer {
  external JSFloat32Array getChannelData(int channel);
}

@JS()
@staticInterop
class OscillatorNode {}

extension OscillatorNodeExtension on OscillatorNode {
  external set type(String value);
  external AudioParam get frequency;
  external void connect(JSObject destination);
  external void disconnect();
  external void start();
  external void stop();
}

@JS()
@staticInterop
class GainNode {}

extension GainNodeExtension on GainNode {
  external AudioParam get gain;
  external void connect(JSObject destination);
  external void disconnect();
}

@JS()
@staticInterop
class AudioParam {}

extension AudioParamExtension on AudioParam {
  external set value(num val);
}

@JS()
@staticInterop
class AudioDestinationNode {}

class AudioService implements stub.AudioService {
  web.MediaStream? _stream;
  AudioContext? _audioContext;
  MediaStreamAudioSourceNode? _microphone;
  AudioWorkletNode? _workletNode;
  ScriptProcessorNode? _scriptProcessor;
  AnalyserNode? _analyser;
  Function(Uint8List)? _onData;

  @override
  Future<void> init() async {}

  @override
  Future<bool> hasPermission() async {
    try {
      final constraints = web.MediaStreamConstraints(audio: true.toJS);
      final mediaDevices = web.window.navigator.mediaDevices;
      _stream = await mediaDevices.getUserMedia(constraints).toDart;

      if (_stream != null) {
        final tracks = _stream!.getTracks().toDart;
        for (var track in tracks) {
          track.stop();
        }
        _stream = null;
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<void> startListening(Function(Uint8List) onData) async {
    _onData = onData;

    try {
      final constraints = web.MediaStreamConstraints(audio: true.toJS);
      final mediaDevices = web.window.navigator.mediaDevices;
      _stream = await mediaDevices.getUserMedia(constraints).toDart;

      _audioContext = AudioContext();

      _microphone = _audioContext!.createMediaStreamSource(_stream!);

      // Try AudioWorkletNode first (modern, low-latency)
      if (await _tryStartWorklet()) {
        return;
      }

      // Fallback to deprecated ScriptProcessorNode
      _startScriptProcessor();
    } catch (e) {
      // Failed to start web audio
    }
  }

  /// Attempt to set up AudioWorkletNode. Returns true on success.
  Future<bool> _tryStartWorklet() async {
    try {
      final worklet = _audioContext!.audioWorklet;
      await worklet.addModule('pcm_processor.js').toDart;

      _workletNode = AudioWorkletNode(_audioContext!, 'pcm-processor');

      _workletNode!.port.onmessage = ((JSObject event) {
        try {
          final msgEvent = event as MessageEvent;
          final jsData = msgEvent.data;
          // The worklet posts a Uint8Array — read it via JSUint8Array interop
          final jsTyped = jsData as JSUint8Array;
          final bytes = jsTyped.toDart;
          _onData?.call(bytes);
        } catch (_) {
          // Worklet message processing error
        }
      }).toJS;

      _microphone!.connect(_workletNode! as JSObject);
      // Connect to destination to keep the audio graph alive
      _workletNode!.connect(_audioContext!.destination as JSObject);

      return true;
    } catch (_) {
      // AudioWorklet not supported, will fall back to ScriptProcessorNode
      return false;
    }
  }

  /// Legacy fallback using deprecated ScriptProcessorNode.
  void _startScriptProcessor() {
    _analyser = _audioContext!.createAnalyser();
    _analyser!.fftSize = 2048;

    _microphone!.connect(_analyser! as JSObject);

    _scriptProcessor = _audioContext!.createScriptProcessor(4096, 1, 1);

    _scriptProcessor!.onaudioprocess = ((JSObject event) {
      try {
        final audioEvent = event as AudioProcessingEvent;
        final inputBuffer = audioEvent.inputBuffer;
        final float32 = inputBuffer.getChannelData(0).toDart;

        final bytes = <int>[];
        for (int i = 0; i < float32.length; i++) {
          final int16 = (float32[i] * 32767).clamp(-32768, 32767).toInt();
          bytes.add(int16 & 0xFF);
          bytes.add((int16 >> 8) & 0xFF);
        }

        _onData?.call(Uint8List.fromList(bytes));
      } catch (e) {
        // Audio process callback error
      }
    }).toJS;

    _analyser!.connect(_scriptProcessor! as JSObject);
    _scriptProcessor!.connect(_audioContext!.destination as JSObject);
  }

  @override
  Future<void> stopListening() async {
    try {
      if (_workletNode != null) {
        _workletNode!.disconnect();
        _workletNode = null;
      }

      if (_scriptProcessor != null) {
        _scriptProcessor!.disconnect();
        _scriptProcessor = null;
      }

      if (_analyser != null) {
        _analyser!.disconnect();
        _analyser = null;
      }

      if (_microphone != null) {
        _microphone!.disconnect();
        _microphone = null;
      }

      if (_stream != null) {
        final tracks = _stream!.getTracks().toDart;
        for (var track in tracks) {
          track.stop();
        }
        _stream = null;
      }

      if (_audioContext != null) {
        await _audioContext!.close().toDart;
        _audioContext = null;
      }
    } catch (e) {
      // Failed to stop web audio
    }
  }

  @override
  void dispose() {
    stopListening();
  }

  static AudioService create() => AudioService();
}

class ToneGeneratorService implements stub.ToneGeneratorService {
  AudioContext? _audioContext;
  OscillatorNode? _oscillator;
  GainNode? _gainNode;
  bool _isPlaying = false;

  @override
  Future<void> init() async {
    try {
      _audioContext = AudioContext();
    } catch (e) {
      // Failed to initialize tone generator
    }
  }

  @override
  void playNote(double frequency) {
    if (_audioContext == null) return;

    try {
      if (_isPlaying) {
        stopNote();
      }

      _oscillator = _audioContext!.createOscillator();
      _oscillator!.type = 'sine';
      _oscillator!.frequency.value = frequency;

      _gainNode = _audioContext!.createGain();
      _gainNode!.gain.value = 0.3;

      _oscillator!.connect(_gainNode! as JSObject);
      _gainNode!.connect(_audioContext!.destination as JSObject);

      _oscillator!.start();
      _isPlaying = true;
    } catch (_) {
      // Failed to play tone
    }
  }

  @override
  void stopNote() {
    if (_oscillator != null && _isPlaying) {
      try {
        _oscillator!.stop();
        _oscillator!.disconnect();
        _oscillator = null;
      } catch (_) {
        // Failed to stop tone
      }
    }
    _isPlaying = false;
  }

  @override
  void dispose() {
    stopNote();
    if (_audioContext != null) {
      try {
        _audioContext!.close();
      } catch (_) {
        // AudioContext close may fail if already closed
      }
      _audioContext = null;
    }
  }

  static ToneGeneratorService create() => ToneGeneratorService();
}
