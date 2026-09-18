/// Just enough JAMS to read GuitarSet's ground truth.
///
/// Each file carries **six** `pitch_contour` annotations, one per guitar
/// string, with columnar data: `time[]`, `duration[]`, `value[]`,
/// `confidence[]`, where each value is
/// `{voiced: bool, index: int, frequency: double}`. Unvoiced instants are
/// simply absent from the list rather than present with `voiced: false`, so
/// "is this string sounding at time t" is a question about whether a sample
/// exists near t, not about a flag.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// One string's pitch contour: times (seconds) and frequencies (Hz), sorted.
class StringContour {
  final int string; // 0 = low E as annotated (GuitarSet order), 5 = high e
  final List<double> times;
  final List<double> frequencies;
  const StringContour(this.string, this.times, this.frequencies);
}

/// One note event: a pluck, and what it sounded until it stopped.
///
/// GuitarSet's `note_midi` annotations are row-major where `pitch_contour` is
/// columnar, and the value is a *fractional* MIDI number — the note's mean
/// pitch, so a bend or a slide averages into it.
class NoteEvent {
  final int string;
  final double onset;
  final double duration;
  final double midi;
  const NoteEvent(this.string, this.onset, this.duration, this.midi);

  double get offset => onset + duration;

  /// Equal-tempered frequency at A440.
  double get frequency => 440 * math.pow(2, (midi - 69) / 12).toDouble();

  bool soundsAt(double t) => t >= onset && t <= offset;
}

class JamsTruth {
  final String title;
  final double duration;
  final List<StringContour> strings;

  /// Every note on every string, in onset order.
  final List<NoteEvent> notes;
  const JamsTruth(this.title, this.duration, this.strings, this.notes);

  /// The annotation hop, inferred from the median spacing inside a contour.
  double get hop {
    for (final s in strings) {
      if (s.times.length > 20) {
        final gaps = <double>[];
        for (int i = 1; i < s.times.length && gaps.length < 200; i++) {
          final g = s.times[i] - s.times[i - 1];
          if (g > 0) gaps.add(g);
        }
        gaps.sort();
        if (gaps.isNotEmpty) return gaps[gaps.length ~/ 2];
      }
    }
    return 256 / 44100;
  }

  /// Every string sounding at [t], within [tolerance] seconds, as
  /// (string, frequency) pairs.
  List<({int string, double frequency})> activeAt(double t, double tolerance) {
    final out = <({int string, double frequency})>[];
    for (final s in strings) {
      final i = _nearest(s.times, t);
      if (i < 0) continue;
      if ((s.times[i] - t).abs() <= tolerance) {
        out.add((string: s.string, frequency: s.frequencies[i]));
      }
    }
    return out;
  }

  static int _nearest(List<double> xs, double t) {
    if (xs.isEmpty) return -1;
    int lo = 0, hi = xs.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (xs[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // lo is the first index >= t; the nearest is lo or lo-1.
    if (lo > 0 && (t - xs[lo - 1]).abs() <= (xs[lo] - t).abs()) return lo - 1;
    return lo;
  }
}

JamsTruth readJams(String path) {
  final root =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final meta = root['file_metadata'] as Map<String, dynamic>;
  final strings = <StringContour>[];
  final notes = <NoteEvent>[];
  int n = 0;
  int noteString = 0;
  for (final a in (root['annotations'] as List)) {
    final ann = a as Map<String, dynamic>;
    if (ann['namespace'] == 'note_midi') {
      for (final e in (ann['data'] as List)) {
        final row = e as Map<String, dynamic>;
        notes.add(NoteEvent(
          noteString,
          (row['time'] as num).toDouble(),
          (row['duration'] as num).toDouble(),
          (row['value'] as num).toDouble(),
        ));
      }
      noteString++;
      continue;
    }
    if (ann['namespace'] != 'pitch_contour') continue;
    final data = ann['data'] as Map<String, dynamic>;
    final times = <double>[];
    final freqs = <double>[];
    final ts = data['time'] as List;
    final vs = data['value'] as List;
    for (int i = 0; i < ts.length; i++) {
      final v = vs[i] as Map<String, dynamic>;
      if (v['voiced'] != true) continue;
      final f = (v['frequency'] as num).toDouble();
      if (f <= 0) continue;
      times.add((ts[i] as num).toDouble());
      freqs.add(f);
    }
    // The six annotations arrive in string order; keep that as the index.
    strings.add(StringContour(n, times, freqs));
    n++;
  }
  notes.sort((a, b) => a.onset.compareTo(b.onset));
  return JamsTruth(
    (meta['title'] ?? '') as String,
    (meta['duration'] as num).toDouble(),
    strings,
    notes,
  );
}
