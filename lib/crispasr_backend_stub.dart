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
const String kModelNameEnv = 'CRISPTUNER_CRISPASR_MODEL';

/// Mirrors the FFI half so callers and tests compile against either.
enum CrispAsrModel {
  basicPitch('basic-pitch', 22050),
  pianoTranscription('piano-transcription', 16000),
  mt3('mt3', 16000);

  final String id;
  final int nativeRate;
  const CrispAsrModel(this.id, this.nativeRate);

  String get displayName => switch (this) {
        CrispAsrModel.basicPitch => 'Basic Pitch',
        CrispAsrModel.pianoTranscription => 'Piano transcription',
        CrispAsrModel.mt3 => 'MT3 (multi-instrument)',
      };
}

CrispAsrModel crispAsrModelFromName(String? name) {
  final n = (name ?? '').trim().toLowerCase();
  for (final m in CrispAsrModel.values) {
    if (m.id == n) return m;
  }
  return switch (n) {
    'piano' || 'kong' => CrispAsrModel.pianoTranscription,
    'mt3' => CrispAsrModel.mt3,
    _ => CrispAsrModel.basicPitch,
  };
}
const String kBackendEnv = 'CRISPTUNER_TRANSCRIPTION_BACKEND';
const String kLibEnv = 'CRISPTUNER_CRISPASR_LIB';
const String kModelEnv = 'CRISPTUNER_BASIC_PITCH_GGUF';

class CrispAsrBackend implements TranscriptionBackend {
  CrispAsrBackend(
      {String? libraryPath,
      String? modelPath,
      bool allowDownload = true,
      CrispAsrModel model = CrispAsrModel.basicPitch});

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
