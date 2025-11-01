import 'dart:async';
import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_util' as js_util;
import 'package:web/web.dart' as web;

@JS('AudioContext')
external JSObject get _AudioContextConstructor;

@JS()
@staticInterop
class AudioContext {}

extension AudioContextExtension on AudioContext {
  external AnalyserNode createAnalyser();
  external MediaStreamAudioSourceNode createMediaStreamSource(web.MediaStream stream);
  external ScriptProcessorNode createScriptProcessor(int bufferSize, int numberOfInputChannels, int numberOfOutputChannels);
  external OscillatorNode createOscillator();
  external GainNode createGain();
  external AudioDestinationNode get destination;
  external JSPromise close();
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
  external JSObject getChannelData(int channel);
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

class AudioService {
  web.MediaStream? _stream;
  AudioContext? _audioContext;
  AnalyserNode? _analyser;
  MediaStreamAudioSourceNode? _microphone;
  ScriptProcessorNode? _scriptProcessor;
  Function(Uint8List)? _onData;

  Future<void> init() async {}

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
      print('Microphone permission error: $e');
      return false;
    }
  }

  Future<void> startListening(Function(Uint8List) onData) async {
    _onData = onData;
    
    try {
      final constraints = web.MediaStreamConstraints(audio: true.toJS);
      final mediaDevices = web.window.navigator.mediaDevices;
      _stream = await mediaDevices.getUserMedia(constraints).toDart;
      
      // Use js_util.callConstructor to properly create AudioContext
      _audioContext = js_util.callConstructor(_AudioContextConstructor, []) as AudioContext;
      
      _analyser = _audioContext!.createAnalyser();
      _analyser!.fftSize = 2048;
      
      _microphone = _audioContext!.createMediaStreamSource(_stream!);
      _microphone!.connect(_analyser! as JSObject);
      
      _scriptProcessor = _audioContext!.createScriptProcessor(4096, 1, 1);
      
      _scriptProcessor!.onaudioprocess = ((JSObject event) {
        try {
          final audioEvent = event as AudioProcessingEvent;
          final inputBuffer = audioEvent.inputBuffer;
          final channelDataJS = inputBuffer.getChannelData(0);
          
          // Convert JSObject to Float32List using js_util
          final length = js_util.getProperty(channelDataJS, 'length') as int;
          
          final bytes = <int>[];
          for (int i = 0; i < length; i++) {
            final sample = js_util.getProperty(channelDataJS, i) as double;
            final int16 = (sample * 32767).clamp(-32768, 32767).toInt();
            bytes.add(int16 & 0xFF);
            bytes.add((int16 >> 8) & 0xFF);
          }
          
          _onData?.call(Uint8List.fromList(bytes));
        } catch (e) {
          print('Error in audio process callback: $e');
        }
      }.toJS);
      
      _analyser!.connect(_scriptProcessor! as JSObject);
      _scriptProcessor!.connect(_audioContext!.destination as JSObject);
      
      print('Web audio started successfully');
      
    } catch (e) {
      print('Error starting web audio: $e');
    }
  }

  Future<void> stopListening() async {
    try {
      if (_scriptProcessor != null) {
        _scriptProcessor!.disconnect();
        _scriptProcessor = null;
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
      print('Error stopping web audio: $e');
    }
  }

  void dispose() {
    stopListening();
  }

  static AudioService create() => AudioService();
}

class ToneGeneratorService {
  AudioContext? _audioContext;
  OscillatorNode? _oscillator;
  GainNode? _gainNode;
  bool _isPlaying = false;

  Future<void> init() async {
    try {
      // Use js_util.callConstructor to properly create AudioContext
      _audioContext = js_util.callConstructor(_AudioContextConstructor, []) as AudioContext;
      print('Web tone generator initialized successfully');
    } catch (e) {
      print('Error initializing web tone generator: $e');
    }
  }

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
      
      print('Playing tone at ${frequency}Hz');
    } catch (e) {
      print('Error playing web tone: $e');
    }
  }

  void stopNote() {
    if (_oscillator != null && _isPlaying) {
      try {
        _oscillator!.stop();
        _oscillator!.disconnect();
        _oscillator = null;
      } catch (e) {
        print('Error stopping web tone: $e');
      }
    }
    _isPlaying = false;
  }

  void dispose() {
    stopNote();
    if (_audioContext != null) {
      try {
        _audioContext!.close();
      } catch (e) {}
      _audioContext = null;
    }
  }

  static ToneGeneratorService create() => ToneGeneratorService();
}