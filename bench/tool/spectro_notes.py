#!/usr/bin/env python3
"""hFT-Transformer and Onsets & Frames on MusicNet's test split, scored by
`mir_eval` itself.

    python3 tool/spectro_notes.py [--data <musicnet root>] [--limit N]
                                  [--sweep] [--out results.json]

This is a SECOND opinion on §35.3, not a replacement for it. §35.3's numbers
came from `tool/spectro_activations.py` (native ORT) feeding
`bin/spectro_eval.dart`, whose decoders (`lib/hft.dart`, `lib/oaf.dart`) and
metric (`lib/note_metrics.dart`) are this repository's own. Everything below
the model is re-implemented here independently — the decoders in numpy, the
metric from `mir_eval.transcription` — so a disagreement localises to the
decoder or the metric rather than to the model, and an agreement is evidence
that neither port drifted.

The two traps §35.2 found are carried over rather than rediscovered:

  * **O&F's ONNX output names are shifted by one.** `torch.onnx.export` was
    handed four `output_names` for a five-output forward, so the tensor named
    `frame` is the pre-combination activation and the one named `velocity` is
    the real frame head. `--oaf-frame-output frame` reproduces the wrong
    reading, which is the evidence for the claim.
  * **hFT's decoder runs `mode_velocity='ignore_zero'`**, dropping any note
    whose velocity head reads zero at the onset frame. That gate, not the
    onset threshold, is what decides how many notes hFT emits.

Both heads emit LOGITS, not probabilities; the sigmoid is applied here.
"""
import argparse
import csv
import json
import math
import os
import time

import numpy as np

from spectro_reference import mel, resample, sigmoid

# MusicNet label times are SAMPLE INDICES at this rate, not seconds. Scaling
# by anything else still produces a plausible-looking table, which is why it
# is a named constant in `lib/musicnet.dart` too rather than an inline 44100.
MUSICNET_RATE = 44100

HFT_HOP = 256
HFT_SR = 16000
HFT_HOP_SEC = HFT_HOP / HFT_SR
HFT_PITCH_MIN = 21
OAF_HOP = 512
OAF_SR = 16000
OAF_PITCH_MIN = 21


# --------------------------------------------------------------------------
# corpus
# --------------------------------------------------------------------------

def read_labels(path):
    """`test_labels/<id>.csv` -> (notes, instrument set).

    Columns: start_time,end_time,instrument,note,start_beat,end_beat,note_value
    """
    notes, instruments = [], set()
    with open(path) as f:
        for row in csv.DictReader(f):
            start = int(row["start_time"])
            end = int(row["end_time"])
            instruments.add(int(row["instrument"]))
            notes.append((start / MUSICNET_RATE, end / MUSICNET_RATE,
                          float(row["note"])))
    notes.sort()
    return notes, instruments


def find_test(root):
    audio_dir = os.path.join(root, "musicnet", "test_data")
    label_dir = os.path.join(root, "musicnet", "test_labels")
    out = []
    for name in sorted(os.listdir(audio_dir)):
        if not name.endswith(".wav"):
            continue
        pid = name[:-4]
        labels = os.path.join(label_dir, pid + ".csv")
        if not os.path.exists(labels):
            continue
        notes, instruments = read_labels(labels)
        out.append((pid, os.path.join(audio_dir, name), notes, instruments))
    return out


# --------------------------------------------------------------------------
# the models
# --------------------------------------------------------------------------

def hft_activations(sess, mono):
    """Stitched sigmoid'd head activations, `infer.py`'s window arithmetic.

    margin_b = margin_f = 32 frames of log(1e-8) padding, the tail padded to a
    multiple of num_frame = 128; the window is 192 frames and the model
    answers for the middle 128. Output frame i of window w is feature frame
    w*128+i, whose time is (w*128+i)*256/16000 s — `torch.stft(center=True)`
    centres frame i on sample i*hop, so there is no drift to correct (§30.1).
    """
    feat = np.log(mel(mono, HFT_SR, 2048, HFT_HOP, 256, 0, 8000, 2.0,
                      "constant") + 1e-8)
    frames = feat.shape[0]
    minv = math.log(1e-8)
    len_s = int(np.ceil(frames / 128) * 128) - frames
    padded = np.concatenate([
        np.full((32, 256), minv, np.float32),
        feat.astype(np.float32),
        np.full((len_s + 32, 256), minv, np.float32)])
    total = frames + len_s
    out = {h: np.zeros((total, 88), np.float32)
           for h in ("onset", "offset", "mpe", "velocity")}
    t0 = time.time()
    for i in range(0, frames, 128):
        x = padded[i:i + 192].T[None, :, :].astype(np.float32)
        on, off, mp, vel = sess.run(
            ["onset_B", "offset_B", "mpe_B", "velocity_B"], {"spec": x})
        n = min(128, total - i)
        out["onset"][i:i + n] = sigmoid(on[0][:n])
        out["offset"][i:i + n] = sigmoid(off[0][:n])
        out["mpe"][i:i + n] = sigmoid(mp[0][:n])
        # velocity is [1, 128, 88, 128] logits; argmax over the last axis is
        # what `infer.py` decodes, and zero is what `ignore_zero` drops.
        out["velocity"][i:i + n] = vel[0][:n].argmax(-1).astype(np.float32)
    return out, time.time() - t0


def oaf_activations(sess, mono, frame_output="velocity"):
    m = np.log(np.maximum(
        mel(mono[:-1], OAF_SR, 2048, OAF_HOP, 229, 30, 8000, 1.0, "reflect"),
        1e-5))
    t0 = time.time()
    on, fr = sess.run(["onset", frame_output],
                      {"mel": m[None, :, :].astype(np.float32)})
    return {"onset": sigmoid(on[0]), "frame": sigmoid(fr[0])}, time.time() - t0


# --------------------------------------------------------------------------
# the decoders, ported from each model's own inference code
# --------------------------------------------------------------------------

def detect_event(data, idx, threshold):
    """`preprocess/midi.py: detect_event`.

    A frame is an event when it is at or above the threshold and is a local
    maximum in the WEAK sense — scanning outward in each direction, the first
    strictly different neighbour is smaller. The time is then refined between
    the neighbours, which is where hFT gets onset resolution finer than its
    16 ms frame.
    """
    col = data[:, idx]
    n = len(col)
    out = []
    for i in np.flatnonzero(col >= threshold):
        v = col[i]
        left = True
        for ii in range(i - 1, -1, -1):
            if v > col[ii]:
                break
            if v < col[ii]:
                left = False
                break
        if not left:
            continue
        right = True
        for ii in range(i + 1, n):
            if v > col[ii]:
                break
            if v < col[ii]:
                right = False
                break
        if not right:
            continue
        if i == 0 or i == n - 1:
            t = i * HFT_HOP_SEC
        else:
            l, r = col[i - 1], col[i + 1]
            if l == r:
                t = i * HFT_HOP_SEC
            elif l > r:
                t = i * HFT_HOP_SEC - HFT_HOP_SEC * 0.5 * (l - r) / (v - r)
            else:
                t = i * HFT_HOP_SEC + HFT_HOP_SEC * 0.5 * (r - l) / (v - l)
        out.append((int(i), float(t)))
    return out


def process_label(pitch, onsets, offsets, mpe, thred_mpe, velocity):
    """`preprocess/midi.py: process_label`, `mode_offset='shorter'`."""
    out = []
    n_mpe = mpe.shape[0]
    for k, (loc_onset, time_onset) in enumerate(onsets):
        if k + 1 < len(onsets):
            loc_next, time_next = onsets[k + 1]
        else:
            loc_next = n_mpe
            time_next = (loc_next - 1) * HFT_HOP_SEC
        loc_offset, time_offset, flag_offset = loc_onset + 1, 0.0, False
        for loc, t in offsets:
            if loc_onset < loc:
                loc_offset, time_offset, flag_offset = loc, t, True
                break
        if loc_offset > loc_next:
            loc_offset, time_offset = loc_next, time_next
        loc_mpe, time_mpe, flag_mpe = loc_onset + 1, 0.0, False
        for ii in range(loc_onset + 1, min(loc_next, n_mpe)):
            if mpe[ii, pitch] < thred_mpe:
                loc_mpe, flag_mpe = ii, True
                time_mpe = loc_mpe * HFT_HOP_SEC
                break
        if not flag_offset and not flag_mpe:
            offset_value = time_next
        elif flag_offset and not flag_mpe:
            offset_value = time_offset
        elif not flag_offset and flag_mpe:
            offset_value = time_mpe
        else:
            offset_value = time_offset if loc_offset <= loc_mpe else time_mpe
        # `mode_velocity='ignore_zero'`: a note whose velocity head reads zero
        # at the onset frame is dropped. §35.4 measured this as a better
        # precision filter than the onset threshold.
        if velocity is not None and velocity[loc_onset, pitch] <= 0:
            continue
        out.append((time_onset, offset_value, float(pitch + HFT_PITCH_MIN)))
    return out


def hft_notes(acts, onset=0.5, offset=0.5, mpe=0.5, ignore_zero=True):
    """`preprocess/midi.py: convert_label_to_note`, notes only."""
    velocity = np.rint(acts["velocity"]).astype(np.int32) if ignore_zero else None
    notes = []
    for pitch in range(88):
        on = detect_event(acts["onset"], pitch, onset)
        if not on:
            continue
        off = detect_event(acts["offset"], pitch, offset)
        for note in process_label(pitch, on, off, acts["mpe"], mpe, velocity):
            # "a re-onset of the same pitch ends the previous note" — the
            # two-notes-back comparison in the original.
            if notes and notes[-1][2] == note[2] and note[0] < notes[-1][1]:
                prev = notes.pop()
                notes.append((prev[0], note[0], prev[2]))
            notes.append(note)
    notes.sort(key=lambda n: n[0])
    return notes


def oaf_notes(acts, onset_threshold=0.5, frame_threshold=0.5):
    """`modules/decoding.py: extract_notes`, with `infer.py`'s time scaling."""
    on = acts["onset"] > onset_threshold
    fr = acts["frame"] > frame_threshold
    n = on.shape[0]
    scale = OAF_HOP / OAF_SR
    out = []
    for p in range(88):
        col_on, col_fr = on[:, p], fr[:, p]
        starts = np.flatnonzero(col_on & ~np.concatenate([[False], col_on[:-1]]))
        for t in starts:
            o = t
            while o < n and (col_on[o] or col_fr[o]):
                o += 1
            if o > t:
                out.append((t * scale, o * scale, float(p + OAF_PITCH_MIN)))
    out.sort(key=lambda x: x[0])
    return out


# --------------------------------------------------------------------------
# scoring — mir_eval itself, not a port of it
# --------------------------------------------------------------------------

def to_arrays(notes):
    if not notes:
        return np.zeros((0, 2)), np.zeros(0)
    a = np.array([[n[0], n[1]] for n in notes], dtype=float)
    # mir_eval rejects zero-length intervals; a note whose decoded offset
    # lands on its onset is widened by one frame rather than dropped, which
    # is what both repos' MIDI writers do in effect.
    bad = a[:, 1] <= a[:, 0]
    a[bad, 1] = a[bad, 0] + 1e-3
    return a, np.array([440.0 * 2 ** ((n[2] - 69) / 12) for n in notes])


class Tally:
    """Accumulates counts across pieces so the aggregate is note-weighted,
    the way `lib/note_metrics.dart` aggregates and unlike a mean of per-piece
    F1s, which would weight a 551-note violin piece like a 2004-note trio."""

    def __init__(self):
        self.matched = self.estimated = self.reference = 0
        self.onset_err = []
        self.pitch_err = []

    def add(self, ref, est, with_offset):
        import mir_eval
        ri, rp = to_arrays(ref)
        ei, ep = to_arrays(est)
        self.reference += len(ref)
        self.estimated += len(est)
        if len(ref) == 0 or len(est) == 0:
            return
        kw = dict(onset_tolerance=0.05, pitch_tolerance=50.0)
        if not with_offset:
            kw["offset_ratio"] = None
        match = mir_eval.transcription.match_notes(ri, rp, ei, ep, **kw)
        self.matched += len(match)
        for r, e in match:
            self.onset_err.append(1000.0 * (ei[e][0] - ri[r][0]))
            self.pitch_err.append(1200.0 * math.log2(ep[e] / rp[r]))

    @property
    def precision(self):
        return self.matched / self.estimated if self.estimated else 0.0

    @property
    def recall(self):
        return self.matched / self.reference if self.reference else 0.0

    @property
    def f1(self):
        p, r = self.precision, self.recall
        return 2 * p * r / (p + r) if p + r else 0.0

    def med(self, which):
        v = self.onset_err if which == "onset" else self.pitch_err
        return float(np.median(np.abs(v))) if v else float("nan")


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="/mnt/storage/tuner-bench/datasets/musicnet")
    ap.add_argument("--models", default="/mnt/storage/tuner-bench/onnx")
    ap.add_argument("--hft", default="")
    ap.add_argument("--oaf", default="")
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--sweep", action="store_true")
    ap.add_argument("--oaf-frame-output", default="velocity")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    import onnxruntime as ort
    import soundfile as sf

    hft_path = a.hft or os.path.join(a.models, "hft_transformer.pruned.onnx")
    oaf_path = a.oaf or os.path.join(a.models, "onsets_and_frames.onnx")
    so = ort.SessionOptions()
    so.intra_op_num_threads = a.threads
    so.inter_op_num_threads = 1
    sessions = {
        "hft": ort.InferenceSession(hft_path, so, providers=["CPUExecutionProvider"]),
        "oaf": ort.InferenceSession(oaf_path, so, providers=["CPUExecutionProvider"]),
    }

    pieces = find_test(a.data)
    if a.limit:
        pieces = pieces[:a.limit]
    if not pieces:
        raise SystemExit(f"no MusicNet test split under {a.data}")

    engines = ["hft", "oaf"]
    no_offset = {e: Tally() for e in engines}
    with_offset = {e: Tally() for e in engines}
    piano = {e: Tally() for e in engines}
    other = {e: Tally() for e in engines}
    per_piece = {e: {} for e in engines}
    cached = {}
    ref_notes = 0
    audio_s = 0.0
    infer_s = {e: 0.0 for e in engines}

    for pid, path, notes, instruments in pieces:
        ref_notes += len(notes)
        audio, sr = sf.read(path, always_2d=True)
        audio = audio[:, 0]
        audio_s += len(audio) / sr
        mono = resample(audio, sr, 16000)
        is_piano = instruments == {1}
        for e in engines:
            if e == "hft":
                acts, dt = hft_activations(sessions[e], mono)
                est = hft_notes(acts)
            else:
                acts, dt = oaf_activations(sessions[e], mono, a.oaf_frame_output)
                est = oaf_notes(acts)
            infer_s[e] += dt
            cached[(e, pid)] = acts
            t = Tally()
            t.add(notes, est, False)
            no_offset[e].add(notes, est, False)
            with_offset[e].add(notes, est, True)
            (piano if is_piano else other)[e].add(notes, est, False)
            per_piece[e][pid] = t
            print(f"{pid} {e}: {len(notes)} ref, {len(est)} est, "
                  f"F1 {100 * t.f1:.1f}%, ORT {dt:.1f} s", flush=True)

    print(f"\n{len(pieces)} MusicNet test pieces, {ref_notes} reference notes, "
          f"{audio_s / 60:.1f} min of audio\n")
    print("Onset + pitch (the standard note-level number), mir_eval:\n")
    print("| engine | precision | recall | F1 | onset err p50 | pitch err p50 |")
    print("| --- | --- | --- | --- | --- | --- |")
    for e in engines:
        t = no_offset[e]
        print(f"| {e} | {100 * t.precision:.1f}% | {100 * t.recall:.1f}% | "
              f"**{100 * t.f1:.1f}%** | {t.med('onset'):.1f} ms | "
              f"{t.med('pitch'):.1f} c |")

    print("\nSplit by what the model was trained on:\n")
    print("| engine | material | precision | recall | F1 |")
    print("| --- | --- | --- | --- | --- |")
    for e in engines:
        for label, t in (("solo piano", piano[e]), ("everything else", other[e])):
            print(f"| {e} | {label} | {100 * t.precision:.1f}% | "
                  f"{100 * t.recall:.1f}% | **{100 * t.f1:.1f}%** |")

    print("\nOnset + pitch + offset:\n")
    print("| engine | precision | recall | F1 |")
    print("| --- | --- | --- | --- |")
    for e in engines:
        t = with_offset[e]
        print(f"| {e} | {100 * t.precision:.1f}% | {100 * t.recall:.1f}% | "
              f"{100 * t.f1:.1f}% |")

    print("\nPer piece:\n")
    print("| piece | instruments | ref notes | " +
          " | ".join(f"{e} F1 | {e} onset p50" for e in engines) + " |")
    print("| --- | --- | --- |" + " --- | --- |" * len(engines))
    for pid, _, notes, instruments in pieces:
        cells = []
        for e in engines:
            t = per_piece[e][pid]
            cells.append(f"{100 * t.f1:.1f}% | {t.med('onset'):.1f} ms")
        print(f"| {pid} | {'/'.join(str(i) for i in sorted(instruments))} | "
              f"{len(notes)} | " + " | ".join(cells) + " |")

    print("\nNative ORT cost over the split, "
          f"{a.threads} intra-op thread(s):\n")
    for e in engines:
        print(f"  {e}: {infer_s[e]:.0f} s for {audio_s:.0f} s of audio = "
              f"{infer_s[e] / audio_s:.3f}x real time")

    result = {
        "pieces": len(pieces), "ref_notes": ref_notes, "audio_s": audio_s,
        "threads": a.threads,
        "engines": {e: {
            "precision": no_offset[e].precision,
            "recall": no_offset[e].recall,
            "f1": no_offset[e].f1,
            "f1_with_offset": with_offset[e].f1,
            "piano_f1": piano[e].f1,
            "other_f1": other[e].f1,
            "onset_p50_ms": no_offset[e].med("onset"),
            "pitch_p50_cents": no_offset[e].med("pitch"),
            "ort_seconds": infer_s[e],
            "per_piece": {p: per_piece[e][p].f1 for p in per_piece[e]},
        } for e in engines},
    }

    if a.sweep:
        # §35.4: O&F's threshold behaves the way a threshold should; hFT's is
        # inert, because `ignore_zero` removes exactly the candidates a lower
        # threshold admits. Both halves are re-derived here from the cached
        # activations, so the sweep costs no further inference.
        print("\nThreshold sweep:\n")
        print("| engine | threshold | precision | recall | F1 |")
        print("| --- | --- | --- | --- | --- |")
        sweep = {}
        for e in engines:
            for th in (0.2, 0.3, 0.5, 0.7):
                t = Tally()
                for pid, _, notes, _ in pieces:
                    acts = cached[(e, pid)]
                    est = (hft_notes(acts, onset=th, mpe=th) if e == "hft"
                           else oaf_notes(acts, onset_threshold=th,
                                          frame_threshold=th))
                    t.add(notes, est, False)
                sweep[f"{e}@{th}"] = t.f1
                print(f"| {e} | {th} | {100 * t.precision:.1f}% | "
                      f"{100 * t.recall:.1f}% | {100 * t.f1:.1f}% |")
        print("\nhFT without `mode_velocity: ignore_zero` — the gate that "
              "makes the row above flat:\n")
        print("| onset/mpe | precision | recall | F1 |")
        print("| --- | --- | --- | --- |")
        for th in (0.2, 0.3, 0.5, 0.7):
            t = Tally()
            for pid, _, notes, _ in pieces:
                est = hft_notes(cached[("hft", pid)], onset=th, mpe=th,
                                ignore_zero=False)
                t.add(notes, est, False)
            sweep[f"hft-nogate@{th}"] = t.f1
            print(f"| {th} | {100 * t.precision:.1f}% | "
                  f"{100 * t.recall:.1f}% | {100 * t.f1:.1f}% |")
        result["sweep"] = sweep

    if a.out:
        json.dump(result, open(a.out, "w"), indent=1)
        print("\nwrote", a.out)


if __name__ == "__main__":
    main()
