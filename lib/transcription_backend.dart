/// The seam the transcription runtimes slot into.
///
/// The default is Basic Pitch through `onnx_runtime_dart` — pure Dart, no
/// FFI — and for that one model the measurements say it is enough: 324 ms
/// for a two-second window on Apple Silicon (`bench/REPORT.md` §14),
/// against a mode that updates twice a second.
///
/// The interface exists because the *choice* is live. CrisperWeaver,
/// the sibling project, runs its transcription through CrispASR's ggml
/// runtime over FFI, and does it behind exactly this shape: a
/// `TranscriptionEngine` interface, an `EngineType` enum carrying the
/// user-facing name, and a factory that returns different engines per
/// platform. That structure is why adding a cloud engine there did not touch
/// its UI.
///
/// The same shape serves here. `CrispAsrBackend` (`crispasr_backend.dart`)
/// implements this interface for the four models the pure-Dart path cannot
/// run — MT3 above all — over FFI on native platforms and as WebAssembly in
/// the browser, and nothing above the interface had to move. The built-in
/// path stays the default: it needs no native library and no download.
library;

import 'dart:typed_data';

import 'transcription.dart';

/// What a transcription runtime has to provide.
abstract class TranscriptionBackend {
  /// Stable identifier, persisted in settings if this ever becomes a choice.
  String get id;

  /// Name for the settings list.
  String get displayName;

  /// Whether this backend can run here at all — a statement about the
  /// platform and the build, not a probe of the device.
  bool get isAvailable;

  /// Sample rate the backend wants its audio in.
  int get inputSampleRate;

  /// How many samples one analysis takes.
  int get windowSamples;

  bool get isRunning;

  /// Load whatever the backend needs. Safe to call twice.
  Future<void> start();

  Future<void> stop();

  /// Analyse one window, or null if the backend is busy or not started.
  ///
  /// Returning null rather than queueing is deliberate and belongs in the
  /// interface rather than in one implementation: a queue of stale windows is
  /// what makes a slow device feel broken, and any backend added later should
  /// drop rather than accumulate.
  Future<TranscriptionResult>? transcribe(Float64List window);
}
