/// The seam a second transcription runtime would slot into.
///
/// There is one backend today — Basic Pitch through `onnx_runtime_dart`, pure
/// Dart, no FFI — and the measurements say that is enough: 324 ms for a
/// two-second window on Apple Silicon (`bench/REPORT.md` §14), against a mode
/// that updates twice a second. Speed is not the open question.
///
/// The interface exists anyway, because the *choice* is live. CrisperWeaver,
/// the sibling project, runs its transcription through CrispASR's ggml
/// runtime over FFI, and does it behind exactly this shape: a
/// `TranscriptionEngine` interface, an `EngineType` enum carrying the
/// user-facing name, and a factory that returns different engines per
/// platform. That structure is why adding a cloud engine there did not touch
/// its UI.
///
/// The reason this app does *not* use CrispASR today is not quality, it is
/// packaging. From the `crispasr` package's own README: it "is pure Dart FFI
/// and does not bundle the native library. Install `libcrispasr` separately
/// or ship it with your app." For CrisperWeaver that is the product — 43 ASR
/// backends and 48 TTS engines. For a tuner it would mean shipping a native
/// library to five platforms, and losing the web build entirely, in order to
/// run one 225 KB model that already runs fast enough in Dart.
///
/// If that changes — MT3 is 96 MB and 46.9M parameters, and would need real
/// speed — a `CrispAsrBackend` implements this interface and nothing above it
/// moves.
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
