import 'dart:async';
import 'dart:typed_data';

/// Describes an available audio input device.
class AudioInputDevice {
  final String id;
  final String label;

  const AudioInputDevice({required this.id, required this.label});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioInputDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => label;
}

/// Shared interface for platform-specific audio capture services.
///
/// Mobile and web implementations must implement this interface via
/// conditional imports in `audio_service.dart`.
abstract class AudioService {
  Future<void> init();
  Future<bool> hasPermission();

  /// List available audio input devices (microphones).
  /// Returns empty list if enumeration is not supported.
  Future<List<AudioInputDevice>> listInputDevices();

  /// Start listening for audio data.
  /// If [deviceId] is provided, use that specific input device.
  Future<void> startListening(Function(Uint8List) onData, {String? deviceId});

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
