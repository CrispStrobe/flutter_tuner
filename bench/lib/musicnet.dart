/// MusicNet (Zenodo 5120004, CC BY 4.0) — real classical recordings with
/// note-level labels.
///
/// The corpus this report needed and did not have. GuitarSet answers "does it
/// hear the pitch" on one instrument; MusicNet asks whether a transcriber can
/// turn a *recording of music* into notes — piano, strings and winds, solo
/// through orchestral, played by people in rooms.
///
/// Only the standard **test split** is used: ten recordings, which is what
/// published note-level numbers are quoted on. The archive is a single 11 GB
/// tarball of which the test split is ~205 MB, so it is streamed and only
/// those members extracted.
///
/// Licence, as for every corpus here: local evaluation only. Never commit
/// audio or labels.
library;

import 'dart:io';

import 'note_metrics.dart';

/// Label times are sample indices at this rate, NOT seconds. Getting that
/// wrong scales every onset by 44100 and still produces a plausible-looking
/// table, so it is stated here rather than left to be inferred.
const int kMusicNetRate = 44100;

class MusicNetPiece {
  final String id;
  final String audioPath;
  final List<Note> notes;

  /// MIDI program numbers present — how "solo piano" is told from "string
  /// quartet" without a separate metadata file.
  final Set<int> instruments;

  const MusicNetPiece(this.id, this.audioPath, this.notes, this.instruments);

  double get durationMs => notes.isEmpty
      ? 0
      : notes.map((n) => n.offsetMs).reduce((a, b) => a > b ? a : b);
}

/// Parse one `test_labels/<id>.csv`:
/// `start_time,end_time,instrument,note,start_beat,end_beat,note_value`.
({List<Note> notes, Set<int> instruments}) readMusicNetLabels(String path) {
  final notes = <Note>[];
  final instruments = <int>{};
  final lines = File(path).readAsLinesSync();
  for (int i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final f = line.split(',');
    if (f.length < 4) continue;
    final start = int.tryParse(f[0]);
    final end = int.tryParse(f[1]);
    final instrument = int.tryParse(f[2]);
    final midi = int.tryParse(f[3]);
    if (start == null || end == null || midi == null) continue;
    if (instrument != null) instruments.add(instrument);
    notes.add((
      onsetMs: 1000 * start / kMusicNetRate,
      offsetMs: 1000 * end / kMusicNetRate,
      midi: midi.toDouble(),
    ));
  }
  notes.sort((a, b) => a.onsetMs.compareTo(b.onsetMs));
  return (notes: notes, instruments: instruments);
}

/// Every piece of the test split under [root] — the directory holding
/// `musicnet/test_data` and `musicnet/test_labels`.
List<MusicNetPiece> findMusicNetTest(String root) {
  final audioDir = Directory('$root/musicnet/test_data');
  final labelDir = Directory('$root/musicnet/test_labels');
  if (!audioDir.existsSync() || !labelDir.existsSync()) return const [];
  final out = <MusicNetPiece>[];
  for (final f in audioDir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.wav')) continue;
    final id = f.path.split('/').last.replaceAll('.wav', '');
    final labels = File('${labelDir.path}/$id.csv');
    if (!labels.existsSync()) continue;
    final parsed = readMusicNetLabels(labels.path);
    out.add(MusicNetPiece(id, f.path, parsed.notes, parsed.instruments));
  }
  out.sort((a, b) => a.id.compareTo(b.id));
  return out;
}
