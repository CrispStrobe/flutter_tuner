import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:tuner_bench/cometbeat/note_hmm.dart';
import 'package:tuner_bench/note_state_hmm.dart';

double midiHz(num m) => 440 * math.pow(2, (m - 69) / 12).toDouble();

/// Run the stream to the end and collect one voiced flag per frame.
List<bool> stream(List<double> track, StreamingNoteHmm hmm) {
  final out = List<bool>.filled(track.length, false);
  final seen = <int>{};
  for (final f in track) {
    final d = hmm.push(f, voiced: f > 0);
    if (d != null) {
      out[d.frame] = d.voiced;
      seen.add(d.frame);
    }
  }
  for (final d in hmm.flush()) {
    out[d.frame] = d.voiced;
    seen.add(d.frame);
  }
  expect(seen.length, track.length, reason: 'every frame decided once');
  return out;
}

void main() {
  test('a short burst in silence is dropped; a held note is kept', () {
    final track = [
      ...List.filled(10, 0.0),
      midiHz(64), midiHz(64), // two-frame false alarm
      ...List.filled(10, 0.0),
      ...List.filled(30, midiHz(45) * 1.004), // A2, 7 cents sharp
      ...List.filled(10, 0.0),
    ];
    final v = stream(track, StreamingNoteHmm(lag: 4));
    expect(v.sublist(10, 12), everyElement(isFalse));
    expect(v.sublist(22, 52), everyElement(isTrue),
        reason: 'lag >= minFrames - 1 sees the whole onset');

    // Greedy: the onset is withheld until the run is confirmed.
    final g = stream(track, StreamingNoteHmm(lag: 0));
    expect(g.sublist(10, 12), everyElement(isFalse));
    expect(g.sublist(22, 26), everyElement(isFalse));
    expect(g.sublist(26, 52), everyElement(isTrue));
  });

  test('an octave blip is cut out of a held note, the rest is kept', () {
    final track = [
      ...List.filled(20, midiHz(52)),
      midiHz(40), // one frame an octave down
      ...List.filled(20, midiHz(52)),
    ];
    final v = stream(track, StreamingNoteHmm(lag: 4));
    expect(v[20], isFalse);
    expect([...v.sublist(0, 20), ...v.sublist(21)], everyElement(isTrue));

    // Greedy without resume: the note is re-confirmed after the blip.
    final g = stream(track, StreamingNoteHmm(lag: 0));
    expect(g.sublist(21, 25), everyElement(isFalse));
    // With resume, it carries on.
    final r = stream(track, StreamingNoteHmm(lag: 0, resumeGap: 2));
    expect(r[20], isFalse);
    expect(r.sublist(21), everyElement(isTrue));
  });

  test('at full lookahead it agrees with segmentNotes on note membership', () {
    final rng = math.Random(7);
    final track = <double>[];
    for (int seg = 0; seg < 60; seg++) {
      final len = 1 + rng.nextInt(25);
      final silent = rng.nextDouble() < 0.3;
      final note = 40 + rng.nextInt(24);
      for (int i = 0; i < len; i++) {
        if (silent || rng.nextDouble() < 0.05) {
          track.add(0);
        } else {
          final wobble = (rng.nextDouble() - 0.5) * 0.6; // ±30 cents
          final octave = rng.nextDouble() < 0.04 ? 0.5 : 1.0;
          track.add(midiHz(note + wobble) * octave);
        }
      }
    }
    const hopMs = 10.0;
    final notes = segmentNotes([
      for (int i = 0; i < track.length; i++)
        (timeMs: i * hopMs, f0Hz: track[i], voicedProb: track[i] > 0 ? 1.0 : 0.0)
    ]);
    final offline = List<bool>.filled(track.length, false);
    for (final n in notes) {
      for (int i = (n.onMs / hopMs).round(); i < (n.offMs / hopMs).round(); i++) {
        offline[i] = true;
      }
    }
    final streamed =
        stream(track, StreamingNoteHmm(lag: track.length));
    var agree = 0;
    for (int i = 0; i < track.length; i++) {
      if (offline[i] == streamed[i]) agree++;
    }
    expect(agree / track.length, greaterThan(0.99),
        reason: '$agree of ${track.length} frames agree');
  });
}
