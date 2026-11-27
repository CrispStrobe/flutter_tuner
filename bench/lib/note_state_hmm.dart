/// A note-state voicing decision that runs in a stream: §27.3's next piece
/// of work.
///
/// §27 found that pYIN, masked by CometBeat's note HMM (`segmentNotes`),
/// beats the shipped tuner on held notes (88.21% against 80.80%). §27.3 then
/// tried to make that streamable by shrinking the HMM to two states, voiced
/// and unvoiced, and lost the whole gain — because the note states are what
/// let the model use pitch *continuity* to decide voicing.
///
/// Reading `segmentNotes` again against how §27 feeds it says more than
/// that. The mask hands the HMM pYIN's *decoded path* with binary voicing,
/// and keeps pYIN's frequency only inside a decoded note. So the HMM can
/// only ever **remove** frames, and it removes them in two ways:
///
///  1. **Note runs shorter than `minFrames` (5) are dropped.** A two- or
///     three-frame burst of pitch in a silence is a false alarm, and this is
///     what kills it.
///  2. **Brief excursions are split off a note.** A frame an octave away
///     costs more to explain as the held note than to leave and come back,
///     so it becomes a short run of its own and rule 1 drops it.
///
/// Neither of those needs the whole track. Both need *note identity* — which
/// is the part §27.3 threw away — and rule 1 needs to know how long a run
/// will be, which is exactly the lookahead question.
///
/// This class is that model, streamed:
///
///  * the same state space and costs as `segmentNotes` (one state per MIDI
///    note over a fixed range, plus silence; stay free, note↔silence
///    [boundaryCost], note→note [switchCost]), but with a fixed range, since
///    a stream cannot scan the track for its pitch range first;
///  * a forward pass that keeps the last `lag + 1` frames of backpointers,
///    and decides frame `t` by backtracing from the best state at `t + lag`
///    — §24's trick, now on the structure that earns the result;
///  * rule 1 made causal: a frame is reported only when the run it belongs
///    to is already known to reach [minFrames] — counting frames already
///    committed behind it and the tentative path ahead of it, up to the lag.
///    At `lag >= minFrames - 1` that sees as far as the offline rule needs;
///    below it, the first frames of every note are withheld instead, and
///    that is a response-time cost the benchmark charges.
///
/// Written for this repository against `segmentNotes`' documented model, not
/// copied from it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// The decision for one frame.
class NoteStateDecision {
  /// Index of the frame this decides (the frame pushed `lag` pushes ago).
  final int frame;

  /// MIDI note the model holds at this frame, or null for silence.
  final int? midi;

  /// Whether to show this frame's pitch. False on silence, and on a note
  /// run not yet confirmed to reach `minFrames`.
  final bool voiced;

  const NoteStateDecision(this.frame, this.midi, this.voiced);
}

class StreamingNoteHmm {
  /// Frames of lookahead before a frame is decided. 0 is greedy.
  final int lag;

  /// A note run must be known to reach this many frames to be reported.
  /// `segmentNotes` uses 5; 1 disables the rule.
  final int minFrames;

  /// Penalty to change note between frames.
  final double switchCost;

  /// Penalty to enter or leave silence.
  final double boundaryCost;

  /// Extra penalty, on top of [switchCost], for moving straight to a note
  /// one or two octaves from the held one. §39.7 found octave errors the
  /// largest measured part of the comp losses; an octave slip is far more
  /// often the tracker locking a partial than the player leaping an octave
  /// with no gap. 0 keeps the plain model, bit for bit.
  final double octaveJumpCost;

  /// When set, a frame one or two octaves from a note costs this (plus its
  /// residual cents) to explain as that note, rather than the capped 5.0.
  /// That lets the model *hold* a note through an octave slip instead of
  /// leaving it, so a gate can fold the reading back. Null keeps the plain
  /// emission.
  final double? octaveEmission;

  /// Fixed MIDI range of the note states.
  final int minMidi;
  final int maxMidi;

  final double a4;

  /// When a run is interrupted for at most this many frames — by another
  /// note or by silence — and then resumes on the same note, count it as the
  /// same run for [minFrames]. (Greedy decoding usually routes a one-frame
  /// octave blip through silence rather than through the other note.)
  ///
  /// Offline this never matters: both halves of a note split by a one-frame
  /// excursion are usually long enough on their own. In a stream they are
  /// not *yet* known to be, so without this every excursion would withhold
  /// the next `minFrames - 1` frames of a note that was already confirmed.
  /// 0 reproduces the plain rule.
  final int resumeGap;

  final int _k; // note states 0.._k-1; silence is _k
  late final int _states = _k + 1;
  late Float64List _cost = Float64List(_states);
  late final List<Int32List> _back; // ring buffer, lag + 1 deep
  late final Int32List _bestAt; // argmin state per ring slot
  int _t = 0; // frames pushed so far

  /// Committed states, newest last, kept just long enough for the run count.
  final List<int> _committed = [];

  StreamingNoteHmm({
    this.lag = 4,
    this.minFrames = 5,
    this.switchCost = 1.8,
    this.boundaryCost = 0.6,
    this.minMidi = 28, // E1: below a bass guitar's low E
    this.maxMidi = 100, // E7: above anything a guitar tuner is asked about
    this.a4 = 440,
    this.resumeGap = 0,
    this.octaveJumpCost = 0,
    this.octaveEmission,
  })  : assert(lag >= 0),
        assert(minFrames >= 1),
        _k = maxMidi - minMidi + 1 {
    _back = List.generate(lag + 1, (_) => Int32List(_states));
    _bestAt = Int32List(lag + 1);
  }

  int get _silence => _k;

  /// [frameCents] is the frame's pitch in cents relative to MIDI 69, taken
  /// once per frame so the per-state cost is a subtraction.
  double _emitNote(int i, double frameCents, bool voiced) {
    if (!voiced) return 3.0; // a note state on an unvoiced frame is costly
    final c = (frameCents - 100.0 * (minMidi + i - 69)).abs();
    final plain = math.min(c / 50.0, 5.0);
    final oe = octaveEmission;
    if (oe == null || c <= 600) return plain;
    // Distance to the nearest octave of this note, one or two away.
    final r = math.min((c - 1200).abs(), (c - 2400).abs());
    return r <= 50 ? math.min(plain, oe + r / 50.0) : plain;
  }

  /// Push the next frame's pitch track value. [voiced] is the tracker's own
  /// decision; [f0Hz] is ignored when it is false.
  ///
  /// Returns the decision for frame `t - lag`, or null while the first
  /// `lag` frames are still being buffered.
  NoteStateDecision? push(double f0Hz, {required bool voiced}) {
    voiced = voiced && f0Hz > 0;
    final fc = voiced ? 1200 * math.log(f0Hz / a4) / math.ln2 : 0.0;
    final prev = _cost;
    final cur = Float64List(_states);
    final slot = _t % (lag + 1);
    final back = _back[slot];

    if (_t == 0) {
      // Every state starts free, as offline.
      for (int i = 0; i < _k; i++) {
        cur[i] = _emitNote(i, fc, voiced);
        back[i] = i;
      }
      cur[_silence] = voiced ? 1.0 : 0.0;
      back[_silence] = _silence;
    } else {
      // Best and second-best note in the previous frame, so each state's
      // best "from another note" source is O(1).
      double g1 = double.infinity, g2 = double.infinity;
      int a1 = -1, a2 = -1;
      for (int i = 0; i < _k; i++) {
        final c = prev[i];
        if (c < g1) {
          g2 = g1;
          a2 = a1;
          g1 = c;
          a1 = i;
        } else if (c < g2) {
          g2 = c;
          a2 = i;
        }
      }
      final fromSilence = prev[_silence] + boundaryCost;
      // The five cheapest notes, cheapest first (only for the octave rule).
      final top = Int32List(5)..fillRange(0, 5, -1);
      if (octaveJumpCost != 0) {
        for (int j = 0; j < _k; j++) {
          final c = prev[j];
          int pos = 5;
          while (pos > 0 && (top[pos - 1] < 0 || prev[top[pos - 1]] > c)) {
            pos--;
          }
          if (pos >= 5) continue;
          for (int m = 4; m > pos; m--) {
            top[m] = top[m - 1];
          }
          top[pos] = j;
        }
      }
      for (int i = 0; i < _k; i++) {
        var best = prev[i];
        var from = i;
        if (fromSilence < best) {
          best = fromSilence;
          from = _silence;
        }
        if (octaveJumpCost == 0) {
          final other = i == a1 ? g2 : g1;
          final otherArg = i == a1 ? a2 : a1;
          if (other + switchCost < best) {
            best = other + switchCost;
            from = otherArg;
          }
        } else {
          // Best source that is neither this note nor an octave of it:
          // at most four are excluded, so the five cheapest always hold one.
          for (final j in top) {
            if (j < 0) break;
            final d = (j - i).abs();
            if (d == 0 || d == 12 || d == 24) continue;
            if (prev[j] + switchCost < best) {
              best = prev[j] + switchCost;
              from = j;
            }
            break;
          }
          for (final d in const [-24, -12, 12, 24]) {
            final j = i + d;
            if (j < 0 || j >= _k) continue;
            final c = prev[j] + switchCost + octaveJumpCost;
            if (c < best) {
              best = c;
              from = j;
            }
          }
        }
        cur[i] = best + _emitNote(i, fc, voiced);
        back[i] = from;
      }
      var best = prev[_silence];
      var from = _silence;
      if (g1 + boundaryCost < best) {
        best = g1 + boundaryCost;
        from = a1;
      }
      cur[_silence] = best + (voiced ? 1.0 : 0.0);
      back[_silence] = from;
    }

    // Keep the numbers bounded on an endless stream; argmin is unaffected.
    var lo = cur[0];
    var arg = 0;
    for (int s = 1; s < _states; s++) {
      if (cur[s] < lo) {
        lo = cur[s];
        arg = s;
      }
    }
    for (int s = 0; s < _states; s++) {
      cur[s] -= lo;
    }
    _cost = cur;
    _bestAt[slot] = arg;
    _t++;

    if (_t <= lag) return null;
    return _decide(_t - 1 - lag, _t - 1);
  }

  /// Decide the frames still buffered once the stream ends, with whatever
  /// lookahead is left. Only a finite recording has an end; a live tuner
  /// never calls this.
  List<NoteStateDecision> flush() {
    final out = <NoteStateDecision>[];
    final last = _t - 1;
    for (int f = math.max(0, _t - lag); f <= last; f++) {
      out.add(_decide(f, last));
    }
    return out;
  }

  /// Decide [frame] by backtracing from the best state at [anchor].
  NoteStateDecision _decide(int frame, int anchor) {
    // Tentative path from anchor back to frame: ahead[d] is frame + d.
    final ahead = List<int>.filled(anchor - frame + 1, 0);
    var s = _bestAt[anchor % (lag + 1)];
    for (int u = anchor; u > frame; u--) {
      ahead[u - frame] = s;
      s = _back[u % (lag + 1)][s];
    }
    ahead[0] = s;

    _committed.add(s);
    final keep = minFrames + resumeGap + 1;
    if (_committed.length > keep) {
      _committed.removeRange(0, _committed.length - keep);
    }

    if (s == _silence) return NoteStateDecision(frame, null, false);

    // Run length known so far: this frame, the committed frames behind it,
    // the tentative frames ahead of it.
    var run = 1;
    var gap = 0;
    for (int i = _committed.length - 2; i >= 0 && run < minFrames; i--) {
      final c = _committed[i];
      if (c == s) {
        run++;
        gap = 0;
      } else if (gap < resumeGap) {
        gap++; // a short excursion or dropout; look past it
      } else {
        break;
      }
    }
    for (int d = 1; d < ahead.length && run < minFrames; d++) {
      if (ahead[d] != s) break;
      run++;
    }
    return NoteStateDecision(frame, minMidi + s, run >= minFrames);
  }
}
