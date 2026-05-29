import 'dart:async';
import 'dart:typed_data';

/// Shared interface for platform-specific audio capture services.
///
/// Mobile and web implementations must implement this interface via
/// conditional imports in `audio_service.dart`.
abstract class AudioService {
  Future<void> init();
  Future<bool> hasPermission();
  Future<void> startListening(Function(Uint8List) onData);
  Future<void> stopListening();
  void dispose();

  static AudioService create() {
    throw UnsupportedError('Cannot create AudioService on this platform');
  }
}

/// Shared interface for platform-specific tone generation services.
abstract class ToneGeneratorService {
  Future<void> init();
  void playNote(double frequency);
  void stopNote();
  void dispose();

  static ToneGeneratorService create() {
    throw UnsupportedError('Cannot create ToneGeneratorService on this platform');
  }
}