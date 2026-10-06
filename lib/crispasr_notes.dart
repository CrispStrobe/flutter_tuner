/// What both CrispASR backends — native over FFI, browser over WebAssembly —
/// do to the audio on the way in and to the note events on the way out.
///
/// Kept in one place because the two runtimes must describe the same
/// instant: if one resampled differently or kept a different tail, the same
/// chord would show different notes depending on where the app ran, for no
/// reason a user could see.
library;

import 'dart:typed_data';

import 'transcription.dart';

/// One note event as CrispASR reports it: `crispasr_session_piano_notes`
/// over FFI, `sessionPianoNotes` in the browser.
class NoteEvent {
  final double onMs;
  final double offMs;
  final int midi;

  /// The model's loudness estimate, 0–127 — not a confidence. The CrispASR
  /// docs say so explicitly. It sorts the display and nothing thresholds it.
  final int velocity;

  /// General MIDI program, or -1 when the model names no instrument (every
  /// model but MT3, and MT3 against a library older than 0.8.35).
  final int program;

  const NoteEvent(this.onMs, this.offMs, this.midi, this.velocity,
      [this.program = -1]);
}

/// The same span the ONNX decoder averages — 8 frames of 256 samples at
/// 22050 Hz, 93 ms — so every backend describes the same instant.
const double noteTailSeconds =
    BasicPitchDecoder.defaultTailFrames * BasicPitchGeometry.frameHop /
        BasicPitchGeometry.sampleRate;

/// The capture path always delivers 22.05 kHz. basic-pitch wants that; the
/// other four models want 16 kHz, so they are resampled here rather than
/// forcing a second decimation chain onto the audio thread. Linear is
/// adequate downsampling a band-limited signal by 0.73.
Float32List toModelRate(Float64List window, int rate) {
  if (rate == BasicPitchGeometry.sampleRate) {
    final pcm = Float32List(window.length);
    for (int i = 0; i < pcm.length; i++) {
      pcm[i] = window[i];
    }
    return pcm;
  }
  final ratio = BasicPitchGeometry.sampleRate / rate;
  final pcm = Float32List((window.length / ratio).floor());
  for (int i = 0; i < pcm.length; i++) {
    final x = i * ratio;
    final j = x.floor();
    final t = x - j;
    final a = window[j];
    final b = j + 1 < window.length ? window[j + 1] : a;
    pcm[i] = a + (b - a) * t;
  }
  return pcm;
}

/// The notes still sounding in the last [noteTailSeconds] of a window that
/// lasted [windowMs], loudest first.
List<TranscribedNote> notesInTail(Iterable<NoteEvent> events, double windowMs) {
  final from = windowMs - noteTailSeconds * 1000;
  final notes = <TranscribedNote>[];
  for (final e in events) {
    if (e.offMs < from || e.onMs > windowMs) continue;
    notes.add(TranscribedNote(
      e.midi,
      (e.velocity / 127).clamp(0.0, 1.0),
      e.onMs >= from ? 1.0 : 0.0,
      program: e.program,
    ));
  }
  notes.sort((a, b) => b.strength.compareTo(a.strength));
  return notes;
}
