import 'dart:async';
import 'dart:typed_data';

abstract class AudioService {
  Future<void> init();
  Future<bool> hasPermission();
  Future<void> startListening(Function(Uint8List) onData);
  Future<void> stopListening();
  void dispose();
  
  static AudioService create() {
    throw UnsupportedError('Cannot create AudioService');
  }
}

abstract class ToneGeneratorService {
  Future<void> init();
  void playNote(double frequency);
  void stopNote();
  void dispose();
  
  static ToneGeneratorService create() {
    throw UnsupportedError('Cannot create ToneGeneratorService');
  }
}