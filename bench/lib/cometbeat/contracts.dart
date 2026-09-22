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
//
// CHANGED ONCE, 2026-09-22: `NoteEvent` grew a `program` field (the General
// MIDI instrument) after the board entry that proposed it. The rule held — the
// heads-up came first, and the widening is compiler-checked at every one of the
// ~20 construction sites rather than defaulted, so no producer can silently
// claim an instrument it never identified. See `NoteEvent` for the sentinel.

/// S1 output — one estimate per analysis frame. [voicedProb] in 0..1 (a
/// probabilistic voiced/unvoiced decision, unlike the old hard RMS gate).
typedef PitchFrame = ({double timeMs, double f0Hz, double voicedProb});

/// The per-frame pitch track (S1). Empty for a too-short / silent signal.
typedef PitchTrack = List<PitchFrame>;

/// A transcribed note — the UNIVERSAL contract between every transcriber
/// (monophonic pYIN note-HMM AND polyphonic Basic Pitch) and the notation
/// stage. [midi] 0..127; [onMs]/[offMs] = note on/off in ms (offMs > onMs);
/// [confidence] 0..1; [program] the instrument that played it.
///
/// **[program] — the General MIDI instrument, widened into this record on
/// 2026-09-22** (the PLAN.md board entry that proposed it is the heads-up this
/// file's header asks for). MT3 is multi-instrument — that is what earns it its
/// score — and until this field existed a wind trio arrived flattened into one
/// undifferentiated part. Dart records have no width subtyping, so a
/// five-field record is *not* assignable to a four-field one: a superset type
/// could not have flowed through the existing consumers, and a parallel array
/// of programs would have been one `sort` away from silently mislabelling every
/// note. Widening the record is the only shape the compiler checks for us, and
/// it cost every producer one line.
///
/// The values: [gmProgramUnknown] (**-1**) = no instrument identified,
/// **0..127** = a General MIDI program, [gmProgramPercussion] (**128**) = GM
/// channel 10 (drum keys, not pitches). Unknown is deliberately NOT 0, which is
/// *Acoustic Grand Piano* and would be indistinguishable from a real answer.
/// Every producer that is not MT3 — pYIN's note-HMM, Basic Pitch, Kong's
/// piano-transcription, CREPE — reports -1, because none of them identifies an
/// instrument; a piano transcriber emitting 0 would be asserting something it
/// never computed.
typedef NoteEvent = ({
  int midi,
  double onMs,
  double offMs,
  double confidence,
  int program,
});

/// [NoteEvent.program] for "no instrument identified" — see [NoteEvent].
const int gmProgramUnknown = -1;

/// [NoteEvent.program] for GM percussion (channel 10) — see [NoteEvent].
const int gmProgramPercussion = 128;

/// Whether [program] names an instrument at all (a GM program or percussion).
bool hasInstrument(int program) =>
    program >= 0 && program <= gmProgramPercussion;

/// S4 output — the rhythmic analysis: estimated [bpm], the beat onsets
/// ([beatMs], strictly increasing) and the detected note onsets ([onsetMs]).
typedef RhythmGrid = ({double bpm, List<double> beatMs, List<double> onsetMs});

/// A [note] placed on the beat grid (S4 quantise output): its metric position
/// ([startBeat]) and length ([beats]) in beats — what S5 turns into a duration.
typedef GriddedNote = ({NoteEvent note, double startBeat, double beats});

/// Convenience: a note's duration in ms.
double noteDurationMs(NoteEvent n) => n.offMs - n.onMs;
