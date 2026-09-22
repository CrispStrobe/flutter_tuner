// hFT-Transformer, end to end in Dart.
//
// The model is 5.52 M parameters, 22 MB of ONNX, and piano SOTA. §31 exported
// and verified it against PyTorch but never ran it on audio, for one reason:
// its input is not audio. It takes a 256-bin log-mel window of exactly 192
// frames, so the work is the front end (`mel.dart`) and the window
// arithmetic, not the runtime.
//
// Faithful to `ddPn08/hft-transformers-rewrite`'s `infer.py` and
// `preprocess/midi.py`, which is the checkpoint's own inference code:
//
//   * feature = log(melspec + 1e-8), 256 mels, n_fft 2048, hop 256, 16 kHz,
//     `constant` padding, `slaney` norm — `dataset.json`'s `feature` block.
//   * margin_b = margin_f = 32 frames of `min_value = log(1e-8)` before and
//     after, the tail padded up to a multiple of num_frame = 128.
//   * the window advances 128 frames and the model answers for those 128,
//     the 2x32 margin being context only. **There is no clock drift here**:
//     output frame i of window w is feature frame w*128+i, whose time is
//     (w*128+i) * 256/16000 s, because `torch.stft(center: true)` centres
//     frame i on sample i*hop. That is the arithmetic §30.1 says to check
//     before believing a number, and it is why this file states it.
//   * the outputs are LOGITS; sigmoid is applied here, as `infer.py` does.
//
// One deliberate departure. `infer.py` decodes the A head and the B head and
// concatenates both note lists, which emits every note twice. hFT's two heads
// are the two stages of the same prediction; the paper's result is the second
// (B). This transcribes from B, and `--hft-head A` exists to check that.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnx_runtime_dart/onnx_runtime_dart.dart';

import 'mel.dart';
import 'note_metrics.dart' show Note;

class HftGeometry {
  static const int sampleRate = 16000;
  static const int hop = 256;
  static const int nFft = 2048;
  static const int nBins = 256;
  static const int marginB = 32;
  static const int marginF = 32;
  static const int numFrame = 128;
  static const int window = marginB + numFrame + marginF; // 192
  static const int numNotes = 88;
  static const int pitchMin = 21;
  static const double logOffset = 1e-8;
  static double get minValue => math.log(logOffset);
  static double get hopSec => hop / sampleRate;
}

double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

/// A detected local maximum: which frame, and the sub-frame time.
typedef _Detection = ({int loc, double time});

/// `preprocess/midi.py: detect_event`.
///
/// A frame is an event when its value is at or above the threshold and is a
/// local maximum in the weak sense — scanning outward in both directions,
/// the first strictly different neighbour is smaller. The time is refined
/// between the neighbours, which is where hFT gets onset resolution finer
/// than its 16 ms frame.
List<_Detection> _detectEvent(
    List<Float32List> data, int idx, double threshold) {
  final out = <_Detection>[];
  final n = data.length;
  for (int i = 0; i < n; i++) {
    final v = data[i][idx];
    if (v < threshold) continue;
    bool leftFlag = true;
    for (int ii = i - 1; ii >= 0; ii--) {
      if (v > data[ii][idx]) {
        leftFlag = true;
        break;
      } else if (v < data[ii][idx]) {
        leftFlag = false;
        break;
      }
    }
    bool rightFlag = true;
    for (int ii = i + 1; ii < n; ii++) {
      if (v > data[ii][idx]) {
        rightFlag = true;
        break;
      } else if (v < data[ii][idx]) {
        rightFlag = false;
        break;
      }
    }
    if (!leftFlag || !rightFlag) continue;
    final hopSec = HftGeometry.hopSec;
    double time;
    if (i == 0 || i == n - 1) {
      time = i * hopSec;
    } else {
      final l = data[i - 1][idx], r = data[i + 1][idx];
      if (l == r) {
        time = i * hopSec;
      } else if (l > r) {
        time = i * hopSec - hopSec * 0.5 * (l - r) / (v - r);
      } else {
        time = i * hopSec + hopSec * 0.5 * (r - l) / (v - l);
      }
    }
    out.add((loc: i, time: time));
  }
  return out;
}

/// `preprocess/midi.py: process_label`, `mode_offset: 'shorter'`.
List<Note> _processLabel(
  int pitch,
  List<_Detection> onsets,
  List<_Detection> offsets,
  List<Float32List> mpe,
  double thredMpe,
  List<Int32List>? velocity,
) {
  final out = <Note>[];
  final hopSec = HftGeometry.hopSec;
  for (int idxOn = 0; idxOn < onsets.length; idxOn++) {
    final locOnset = onsets[idxOn].loc;
    final timeOnset = onsets[idxOn].time;
    int locNext;
    double timeNext;
    if (idxOn + 1 < onsets.length) {
      locNext = onsets[idxOn + 1].loc;
      timeNext = onsets[idxOn + 1].time;
    } else {
      locNext = mpe.length;
      timeNext = (locNext - 1) * hopSec;
    }
    int locOffset = locOnset + 1;
    double timeOffset = 0;
    bool flagOffset = false;
    for (final d in offsets) {
      if (locOnset < d.loc) {
        locOffset = d.loc;
        timeOffset = d.time;
        flagOffset = true;
        break;
      }
    }
    if (locOffset > locNext) {
      locOffset = locNext;
      timeOffset = timeNext;
    }
    int locMpe = locOnset + 1;
    double timeMpe = 0;
    bool flagMpe = false;
    for (int ii = locOnset + 1; ii < locNext; ii++) {
      if (mpe[ii][pitch] < thredMpe) {
        locMpe = ii;
        flagMpe = true;
        timeMpe = locMpe * hopSec;
        break;
      }
    }
    final velocityValue =
        velocity == null ? 0 : velocity[locOnset][pitch];
    double offsetValue;
    if (!flagOffset && !flagMpe) {
      offsetValue = timeNext;
    } else if (flagOffset && !flagMpe) {
      offsetValue = timeOffset;
    } else if (!flagOffset && flagMpe) {
      offsetValue = timeMpe;
    } else {
      offsetValue = locOffset <= locMpe ? timeOffset : timeMpe;
    }
    // `mode_velocity: 'ignore_zero'` — a note whose velocity head says zero
    // is dropped.
    if (velocity != null && velocityValue <= 0) continue;
    out.add((
      onsetMs: timeOnset * 1000,
      offsetMs: offsetValue * 1000,
      midi: (pitch + HftGeometry.pitchMin).toDouble(),
    ));
  }
  return out;
}

/// The frame-wise head outputs of one head set (A or B), stitched over the
/// whole piece.
class HftFrames {
  final List<Float32List> onset;
  final List<Float32List> offset;
  final List<Float32List> mpe;
  final List<Int32List> velocity;
  HftFrames(this.onset, this.offset, this.mpe, this.velocity);
}

/// The padded log-mel feature the model actually sees: `margin_b` rows of
/// `min_value`, the piece, then enough `min_value` rows to reach a multiple
/// of `num_frame` plus `margin_f`.
///
/// Exposed on its own because it is the half of this pipeline that can be
/// checked without running the model — `tool/spectro_compare.py` diffs it
/// against the same construction in numpy, which catches a wrong transpose,
/// a wrong pad or an off-by-one window before any activation is believed.
({List<Float32List> padded, int frames, int lenS}) hftFeature(
    Float64List audio, int sampleRate) {
  final mono = resampleTo(audio, sampleRate, HftGeometry.sampleRate);
  final melT = MelSpectrogram(
    sampleRate: HftGeometry.sampleRate,
    nFft: HftGeometry.nFft,
    winLength: HftGeometry.nFft,
    hopLength: HftGeometry.hop,
    nMels: HftGeometry.nBins,
    fMin: 0,
    fMax: HftGeometry.sampleRate / 2,
    power: 2.0,
    pad: MelPad.constant,
  );
  final mel = melT.compute(mono);
  final f = mel.length;
  final feature = <Float32List>[];
  for (final row in mel) {
    final r = Float32List(HftGeometry.nBins);
    for (int i = 0; i < HftGeometry.nBins; i++) {
      r[i] = math.log(row[i] + HftGeometry.logOffset);
    }
    feature.add(r);
  }
  final lenS =
      ((f / HftGeometry.numFrame).ceil() * HftGeometry.numFrame) - f;
  final minRow = Float32List(HftGeometry.nBins)
    ..fillRange(0, HftGeometry.nBins, HftGeometry.minValue);
  return (
    padded: <Float32List>[
      for (int i = 0; i < HftGeometry.marginB; i++) minRow,
      ...feature,
      for (int i = 0; i < lenS + HftGeometry.marginF; i++) minRow,
    ],
    frames: f,
    lenS: lenS,
  );
}

/// Run the model over [audio] (any sample rate) and return the stitched
/// head activations for both head sets.
///
/// [onWindow] is called once per model invocation, which is what the
/// throughput measurement counts.
({HftFrames a, HftFrames b}) hftForward(
  OnnxModel model,
  Float64List audio,
  int sampleRate, {
  void Function(int windows)? onWindow,
}) {
  final feat = hftFeature(audio, sampleRate);
  final padded = feat.padded;
  final f = feat.frames;
  final total = f + feat.lenS;
  HftFrames blank() => HftFrames(
        [for (int i = 0; i < total; i++) Float32List(HftGeometry.numNotes)],
        [for (int i = 0; i < total; i++) Float32List(HftGeometry.numNotes)],
        [for (int i = 0; i < total; i++) Float32List(HftGeometry.numNotes)],
        [for (int i = 0; i < total; i++) Int32List(HftGeometry.numNotes)],
      );
  final a = blank(), b = blank();

  const names = [
    'onset_A', 'offset_A', 'mpe_A', 'velocity_A',
    'onset_B', 'offset_B', 'mpe_B', 'velocity_B',
  ];
  final input = Float32List(HftGeometry.nBins * HftGeometry.window);
  int windows = 0;
  for (int i = 0; i < f; i += HftGeometry.numFrame) {
    // `feature_with_margin[i : i + 192].T` — bin-major, 256 x 192.
    for (int bin = 0; bin < HftGeometry.nBins; bin++) {
      final base = bin * HftGeometry.window;
      for (int t = 0; t < HftGeometry.window; t++) {
        input[base + t] = padded[i + t][bin];
      }
    }
    final out = model.run(
      {'spec': Tensor.float(input, [1, HftGeometry.nBins, HftGeometry.window])},
      names,
    );
    void take(HftFrames dst, String suffix) {
      final on = out['onset_$suffix']!.asFloatList();
      final off = out['offset_$suffix']!.asFloatList();
      final mp = out['mpe_$suffix']!.asFloatList();
      final vel = out['velocity_$suffix']!.asFloatList();
      for (int t = 0; t < HftGeometry.numFrame; t++) {
        final row = i + t;
        if (row >= total) break;
        for (int p = 0; p < HftGeometry.numNotes; p++) {
          final k = t * HftGeometry.numNotes + p;
          dst.onset[row][p] = _sigmoid(on[k]);
          dst.offset[row][p] = _sigmoid(off[k]);
          dst.mpe[row][p] = _sigmoid(mp[k]);
          // velocity is [1, 128, 88, 128] logits; argmax over the last axis.
          final vbase = (t * HftGeometry.numNotes + p) * 128;
          int best = 0;
          double bestV = vel[vbase];
          for (int v = 1; v < 128; v++) {
            if (vel[vbase + v] > bestV) {
              bestV = vel[vbase + v];
              best = v;
            }
          }
          dst.velocity[row][p] = best;
        }
      }
    }
    take(a, 'A');
    take(b, 'B');
    windows++;
    onWindow?.call(windows);
  }
  return (a: a, b: b);
}

/// `preprocess/midi.py: convert_label_to_note`, notes only.
List<Note> hftNotes(
  HftFrames h, {
  double thredOnset = 0.5,
  double thredOffset = 0.5,
  double thredMpe = 0.5,
}) {
  final notes = <Note>[];
  for (int pitch = 0; pitch < HftGeometry.numNotes; pitch++) {
    final on = _detectEvent(h.onset, pitch, thredOnset);
    if (on.isEmpty) continue;
    final off = _detectEvent(h.offset, pitch, thredOffset);
    final made =
        _processLabel(pitch, on, off, h.mpe, thredMpe, h.velocity);
    for (final n in made) {
      // "a re-onset of the same pitch ends the previous note" — the
      // two-notes-back comparison in the original.
      if (notes.length >= 1 &&
          notes.last.midi == n.midi &&
          n.onsetMs < notes.last.offsetMs) {
        final prev = notes.removeLast();
        notes.add((
          onsetMs: prev.onsetMs,
          offsetMs: n.onsetMs,
          midi: prev.midi
        ));
      }
      notes.add(n);
    }
  }
  notes.sort((x, y) => x.onsetMs.compareTo(y.onsetMs));
  return notes;
}
