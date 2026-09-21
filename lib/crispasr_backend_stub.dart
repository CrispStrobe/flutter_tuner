/// The web half of [CrispAsrBackend]'s conditional export.
///
/// `package:crispasr` imports `dart:ffi` unconditionally, so importing it
/// anywhere reachable from a web entry point fails the build. This file is
/// what the web compilation unit sees instead: the same class, permanently
/// unavailable.
library;

import 'dart:typed_data';

import 'transcription.dart';
import 'transcription_backend.dart';

/// Names kept identical to the FFI half so callers and tests compile
/// against either without conditionals of their own.
const String kCrispAsrBackendName = 'basic-pitch';
const String kBackendEnv = 'CRISPTUNER_TRANSCRIPTION_BACKEND';
const String kLibEnv = 'CRISPTUNER_CRISPASR_LIB';
const String kModelEnv = 'CRISPTUNER_BASIC_PITCH_GGUF';

class CrispAsrBackend implements TranscriptionBackend {
  CrispAsrBackend(
      {String? libraryPath, String? modelPath, bool allowDownload = true});

  /// Always null here: there is no FFI to open a library with, and this
  /// returns null rather than throwing for the same reason the FFI half
  /// does — an unavailable backend is a fall-through, not an error.
  static CrispAsrBackend? fromEnvironment() => null;

  @override
  String get id => 'basic-pitch-crispasr';

  @override
  String get displayName => 'Basic Pitch (CrispASR/ggml)';

  /// Never, on the web: there is no FFI to open a native library with.
  @override
  bool get isAvailable => false;

  @override
  int get inputSampleRate => BasicPitchGeometry.sampleRate;

  @override
  int get windowSamples => BasicPitchGeometry.windowSamples;

  @override
  bool get isRunning => false;

  @override
  Future<void> start() async =>
      throw UnsupportedError('CrispASR needs dart:ffi; not available on web');

  @override
  Future<void> stop() async {}

  @override
  Future<TranscriptionResult>? transcribe(Float64List window) => null;
}
