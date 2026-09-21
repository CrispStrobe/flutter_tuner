// lib/core/audio/transcription/contracts.dart
//
// Shared data contracts for the automatic-transcription pipeline (S1–S5; design
// in docs/TRANSCRIPTION_SCOPING.md, build plan in docs/PLAN.md). THREE workers
// build in parallel and code against ONLY these types, so the pitch chain
// (pYIN), the rhythm chain, and the neural (Basic Pitch) transcriber stay
// independent and compose:
//
//   S1 F0        → PitchTrack        (Worker 1 · pyin.dart)
//   S2 segment   → List<NoteEvent>   (Worker 1 · note_hmm.dart)
//   S4 rhythm    → RhythmGrid        (Worker 2 · rhythm.dart)
//   S4 quantise  → List<GriddedNote> (Worker 2 · rhythm.dart)
//   Track B      → List<NoteEvent>   (Worker 3 · basic_pitch.dart, ONNX)
//   S5 notation  → crisp_notation Score (integration · transcribe.dart)
//
// Pure data, Flutter-free. This file is the SEAM — treat it as frozen once the
// workers start; a change here needs a heads-up on the PLAN.md board.

/// S1 output — one estimate per analysis frame. [voicedProb] in 0..1 (a
/// probabilistic voiced/unvoiced decision, unlike the old hard RMS gate).
typedef PitchFrame = ({double timeMs, double f0Hz, double voicedProb});

/// The per-frame pitch track (S1). Empty for a too-short / silent signal.
typedef PitchTrack = List<PitchFrame>;

/// A transcribed note — the UNIVERSAL contract between every transcriber
/// (monophonic pYIN note-HMM AND polyphonic Basic Pitch) and the notation
/// stage. [midi] 0..127; [onMs]/[offMs] = note on/off in ms (offMs > onMs);
/// [confidence] 0..1.
typedef NoteEvent = ({int midi, double onMs, double offMs, double confidence});

/// S4 output — the rhythmic analysis: estimated [bpm], the beat onsets
/// ([beatMs], strictly increasing) and the detected note onsets ([onsetMs]).
typedef RhythmGrid = ({double bpm, List<double> beatMs, List<double> onsetMs});

/// A [note] placed on the beat grid (S4 quantise output): its metric position
/// ([startBeat]) and length ([beats]) in beats — what S5 turns into a duration.
typedef GriddedNote = ({NoteEvent note, double startBeat, double beats});

/// Convenience: a note's duration in ms.
double noteDurationMs(NoteEvent n) => n.offMs - n.onMs;
