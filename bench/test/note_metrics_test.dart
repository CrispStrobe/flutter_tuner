import 'package:test/test.dart';
import 'package:tuner_bench/note_metrics.dart';

void main() {
  Note n(double on, double off, double midi) =>
      (onsetMs: on, offsetMs: off, midi: midi);

  test('an exact transcription scores 1.0', () {
    final ref = [n(0, 500, 60), n(500, 1000, 62)];
    final s = scoreNotes(ref, List.of(ref));
    expect(s.f1, 1.0);
  });

  test('a note off by more than the onset tolerance does not match', () {
    final s = scoreNotes([n(0, 500, 60)], [n(60, 560, 60)]);
    expect(s.matched, 0);
  });

  test('a note off by more than the pitch tolerance does not match', () {
    final s = scoreNotes([n(0, 500, 60)], [n(0, 500, 60.6)]);
    expect(s.matched, 0, reason: '60 cents is beyond the 50-cent tolerance');
  });

  test('matching is one-to-one', () {
    // Two estimates inside one reference's tolerance may claim it only once.
    final s = scoreNotes([n(0, 500, 60)], [n(-10, 490, 60), n(10, 510, 60)]);
    expect(s.matched, 1);
    expect(s.precision, 0.5);
    expect(s.recall, 1.0);
  });

  test('greedy would undercount here; maximum matching does not', () {
    // e0 is admissible for BOTH references; e1 only for r1. A greedy pass
    // that hands e0 to r0 first leaves r1 with e1 — fine — but a greedy pass
    // ordered the other way gives e0 to r1 and strands r0. Maximum matching
    // finds 2 regardless of order, which is the whole reason for it.
    final ref = [n(0, 100, 60), n(40, 140, 60)];
    final est = [n(20, 120, 60), n(45, 145, 60)];
    final s = scoreNotes(ref, est);
    expect(s.matched, 2);
  });

  test('offsets are only judged when asked', () {
    final ref = [n(0, 1000, 60)];
    final est = [n(0, 200, 60)]; // same onset, badly wrong offset
    expect(scoreNotes(ref, est).matched, 1);
    expect(scoreNotes(ref, est, withOffset: true).matched, 0);
  });

  test('the offset tolerance scales with note length', () {
    // 20% of 1000 ms is 200 ms, so a 150 ms offset error passes; the same
    // error against a short note does not.
    expect(scoreNotes([n(0, 1000, 60)], [n(0, 1150, 60)], withOffset: true)
        .matched, 1);
    expect(scoreNotes([n(0, 100, 60)], [n(0, 250, 60)], withOffset: true)
        .matched, 0);
  });

  test('empty inputs do not divide by zero', () {
    expect(scoreNotes([], []).f1, 0);
    expect(scoreNotes([n(0, 1, 60)], []).recall, 0);
    expect(scoreNotes([], [n(0, 1, 60)]).precision, 0);
  });
}
