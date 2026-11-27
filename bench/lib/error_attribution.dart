/// Where a pipeline's errors come from, by what the annotation says was
/// happening around the frame.
///
/// §39.5 found the streaming note HMM worse than the shipped tuner on
/// GuitarSet's comp takes — more false alarms and octave errors — and
/// offered a cause without measuring it: pYIN committing to one of several
/// sounding strings. This measures it. Every error frame is put in exactly
/// one class:
///
/// False alarms (no string annotated as sounding, something reported):
///  * **tail** — the reported pitch matches (±50 cents, or an octave) a note
///    that ended within [tailWindow] before the frame: a string still ringing
///    after its annotation stopped.
///  * **onset** — the analysis window reaches the next annotated onset (the
///    frame time is the window *start*, and the window is 93 ms long).
///  * **other**.
///
/// Wrong pitch on a monophonic frame (one string annotated, > 50 cents off):
///  * **octave** — an octave of the sounding note.
///  * **otherString** — matches a *different* note sounding within
///    [tailWindow] of the frame: the tracker followed another string.
///  * **other**.
library;

import 'jams.dart';
import 'metrics.dart';

class ErrorAttribution {
  final String name;
  int refUnvoiced = 0, monoFrames = 0;
  int faTail = 0, faOnset = 0, faOther = 0;
  int wrongOctave = 0, wrongOtherString = 0, wrongOther = 0;

  ErrorAttribution(this.name);

  int get falseAlarms => faTail + faOnset + faOther;
  int get wrong => wrongOctave + wrongOtherString + wrongOther;

  void merge(ErrorAttribution o) {
    refUnvoiced += o.refUnvoiced;
    monoFrames += o.monoFrames;
    faTail += o.faTail;
    faOnset += o.faOnset;
    faOther += o.faOther;
    wrongOctave += o.wrongOctave;
    wrongOtherString += o.wrongOtherString;
    wrongOther += o.wrongOther;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'refUnvoiced': refUnvoiced,
        'monoFrames': monoFrames,
        'faTail': faTail,
        'faOnset': faOnset,
        'faOther': faOther,
        'wrongOctave': wrongOctave,
        'wrongOtherString': wrongOtherString,
        'wrongOther': wrongOther,
      };

  static ErrorAttribution fromJson(Map<String, dynamic> j) =>
      ErrorAttribution(j['name'] as String)
        ..refUnvoiced = j['refUnvoiced'] as int
        ..monoFrames = j['monoFrames'] as int
        ..faTail = j['faTail'] as int
        ..faOnset = j['faOnset'] as int
        ..faOther = j['faOther'] as int
        ..wrongOctave = j['wrongOctave'] as int
        ..wrongOtherString = j['wrongOtherString'] as int
        ..wrongOther = j['wrongOther'] as int;
}

/// True when [p] is within 50 cents of [f] or of an octave of it.
bool matchesOrOctave(double p, double f) {
  final c = cents(p, f);
  for (final k in const [-2400.0, -1200.0, 0.0, 1200.0, 2400.0]) {
    if ((c - k).abs() <= 50) return true;
  }
  return false;
}

/// Attribute one track's errors. [track] has one reading per frame (0 =
/// nothing shown); frame `i` starts at `i * hop / rate` and is scored as
/// `evaluateFile` scores a variant with reference offset 0.
ErrorAttribution attributeErrors(
  String name,
  List<double> track,
  JamsTruth truth, {
  required int hop,
  required int window,
  required double rate,
  double tailWindow = 0.3,
}) {
  final a = ErrorAttribution(name);
  final tolerance = truth.hop / 2;
  final windowSeconds = window / rate;
  for (int i = 0; i < track.length; i++) {
    final t = i * hop / rate;
    final active = truth.activeAt(t, tolerance);
    final p = track[i];
    if (active.isEmpty) {
      a.refUnvoiced++;
      if (p <= 0) continue;
      var tail = false, onset = false;
      for (final n in truth.notes) {
        if (n.offset <= t && t - n.offset <= tailWindow &&
            matchesOrOctave(p, n.frequency)) {
          tail = true;
        }
        if (n.onset > t && n.onset <= t + windowSeconds) onset = true;
      }
      if (tail) {
        a.faTail++;
      } else if (onset) {
        a.faOnset++;
      } else {
        a.faOther++;
      }
    } else if (active.length == 1) {
      a.monoFrames++;
      if (p <= 0) continue;
      final ref = active.first.frequency;
      final c = cents(p, ref);
      if (c.abs() <= 50) continue;
      if (matchesOrOctave(p, ref)) {
        a.wrongOctave++;
        continue;
      }
      var other = false;
      for (final n in truth.notes) {
        if (n.onset > t + windowSeconds || n.offset < t - tailWindow) continue;
        if (n.string == active.first.string &&
            cents(n.frequency, ref).abs() <= 50) {
          continue; // the sounding note itself
        }
        if (matchesOrOctave(p, n.frequency)) {
          other = true;
          break;
        }
      }
      if (other) {
        a.wrongOtherString++;
      } else {
        a.wrongOther++;
      }
    }
  }
  return a;
}
