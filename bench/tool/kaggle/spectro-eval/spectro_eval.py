#!/usr/bin/env python3
"""CrispTuner: the four models §35 could not finish measuring, on Kaggle.

Generated from bench/tool/{spectro_reference,spectro_notes,onnx_timing}.py by
bench/tool/kaggle/build_spectro_kernel.py — do not edit here; the local
copies are the ones that get reviewed.

Two jobs, on a worker that is not shared with anyone:

1. **Reproduce §35.3.** hFT-Transformer and Onsets & Frames over MusicNet's
   ten-piece test split, native ORT, with the decoders re-implemented in
   numpy and the metric taken from `mir_eval` itself. §35.3's numbers came
   through `lib/hft.dart`, `lib/oaf.dart` and `lib/note_metrics.dart`; if the
   two agree, neither port has drifted, and if they disagree the difference
   is below the model rather than in it.

2. **Cost, properly measured.** Native-ORT wall time as a multiple of real
   time at 1, 2 and 4 intra-op threads, and peak RSS, for all four models —
   one process per (model, thread count), so the memory figure belongs to a
   model rather than to a run.

MusicNet is Zenodo 5120004. **Its label times are sample indices at 44100 Hz,
not seconds**, which has already cost this project one wrong table; the
constant is named in `spectro_notes.py` rather than inlined. The archive is
one 11 GB tarball of which the test split is ~205 MB, so it is streamed and
the stream is abandoned once the twenty members needed are out.
"""

import os
import subprocess
import sys
import tarfile
import urllib.request

WORK = "/kaggle/working"
DATA = os.path.join(WORK, "datasets", "musicnet")
MUSICNET = "https://zenodo.org/records/5120004/files/musicnet.tar.gz?download=1"

# `onnx_timing` runs one child process per (model, thread count) by
# re-executing this same file with `--only`. The child must not re-run the
# install or the download, and this is the flag that says so.
CHILD = "--only" in sys.argv


def models_dir():
    """Where `dataset_sources` mounted the ONNX bundle.

    Kaggle has used two layouts for this; both are checked rather than
    guessed at, because the failure mode of guessing is a kernel that runs
    for ten minutes and then cannot find a model.
    """
    for p in ("/kaggle/input/crisptuner-onnx",
              "/kaggle/input/datasets/chr1s4/crisptuner-onnx"):
        if os.path.isdir(p):
            return p
    raise SystemExit("crisptuner-onnx is not attached; see gotcha #13 — a "
                     "private dataset can only be used by kernels pushed "
                     "from the account that owns it")


def sh(cmd):
    print(f"$ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=True)


def require_internet():
    """Fail loudly and early rather than hanging.

    Kaggle CPU workers get no internet even with `enable_internet: "true"`,
    and a GPU worker can lose it too. The corpus needs it and there is no
    degraded mode worth attempting.
    """
    try:
        urllib.request.urlopen("https://zenodo.org", timeout=30).close()
    except Exception as exc:  # noqa: BLE001 - any failure means the same thing
        raise SystemExit(f"no internet on this worker ({exc}); re-run")


def install():
    sh(f"{sys.executable} -m pip install -q mir_eval librosa soundfile "
       f"onnxruntime")


def fetch_musicnet():
    """The test split only: 10 wavs and 10 label CSVs out of an 11 GB tar.

    `tarfile` in stream mode cannot seek, so the archive is read in order and
    dropped on the floor member by member until the twenty wanted are out —
    at which point the stream is abandoned. How much of the 11 GB that costs
    depends on where the members sit, and the kernel prints it rather than
    claiming a figure.
    """
    want_audio = os.path.join(DATA, "musicnet", "test_data")
    want_labels = os.path.join(DATA, "musicnet", "test_labels")
    if os.path.isdir(want_audio) and len(os.listdir(want_audio)) >= 10:
        return
    os.makedirs(DATA, exist_ok=True)
    print("streaming MusicNet (11 GB tar, keeping the ~205 MB test split)",
          flush=True)
    got = 0
    seen = 0
    with urllib.request.urlopen(MUSICNET) as r:
        with tarfile.open(fileobj=r, mode="r|gz") as t:
            for m in t:
                seen += 1
                if not m.isfile():
                    continue
                if ("/test_data/" in m.name and m.name.endswith(".wav")) or \
                   ("/test_labels/" in m.name and m.name.endswith(".csv")):
                    t.extract(m, DATA)
                    got += 1
                    print(f"  {m.name} ({m.size / 1e6:.1f} MB)", flush=True)
                    if got >= 20:
                        break
    print(f"extracted {got} members after reading {seen} tar entries",
          flush=True)
    print(f"audio: {len(os.listdir(want_audio))}, "
          f"labels: {len(os.listdir(want_labels))}", flush=True)


if not CHILD:
    require_internet()
    install()
    fetch_musicnet()

# Everything below is bench/tool/spectro_reference.py, spectro_notes.py and
# onnx_timing.py, verbatim but for the renamed entry points.
# ---------------------------------------------------------------------------

#!/usr/bin/env python3
"""hFT and Onsets & Frames under NATIVE onnxruntime, on real audio.

    python3 tool/spectro_reference.py --wav <musicnet wav> [--seconds 30]
                                      [--dump /tmp/ref.json]

Two jobs.

1. **Timing.** §32.5 put native ORT at 96x cheaper than the pure-Dart runtime
   for Kong. `bin/spectro_timing.dart` measures the Dart side for these two;
   this is the other end of the same comparison, on the same clip.

2. **A cross-check of the Dart pipeline.** `lib/mel.dart` was checked against
   librosa on a synthetic signal and `lib/hft.dart` / `lib/oaf.dart` wire it
   to `onnx_runtime_dart`. This runs the same audio through librosa + native
   ORT and dumps the activations, so `bin/spectro_dump.dart`'s output can be
   diffed against it. A front-end or wiring error does not raise — it just
   scores worse — so the check is the point.

The resampler is torchaudio's `sinc_interp_hann` written out in numpy, the
same algorithm `lib/mel.dart` implements, because librosa's resampler is a
different filter and a 0.1% difference at the top of the band is not what is
being tested here.
"""
import argparse
import json
import math
import time

import numpy as np
import librosa
import soundfile as sf
import onnxruntime as ort


def resample(x, orig, new, width=6):
    g = math.gcd(orig, new)
    o, n = orig // g, new // g
    base = min(o, n) * 0.99
    w = math.ceil(width * o / base)
    idx = (np.arange(-w, w + o)) / o
    i = np.arange(n)[:, None]
    t = np.clip((-i / n + idx[None, :]) * base, -width, width)
    win = np.cos(t * np.pi / width / 2) ** 2
    tp = t * np.pi
    kern = np.where(tp == 0, 1.0, np.sin(np.where(tp == 0, 1.0, tp)) / np.where(tp == 0, 1.0, tp))
    kern = kern * win * base / o
    out_len = math.ceil(len(x) * n / o)
    blocks = out_len // n + 1
    klen = 2 * w + o
    pad = np.concatenate([np.zeros(w), x, np.zeros(blocks * o + klen)])
    # One matrix multiply rather than a Python loop over output samples:
    # rows are the input blocks, columns the kernel taps.
    win = np.lib.stride_tricks.as_strided(
        pad, shape=(blocks, klen), strides=(pad.strides[0] * o, pad.strides[0]))
    return (win @ kern.T).reshape(-1)[:out_len]


def mel(x, sr, n_fft, hop, n_mels, fmin, fmax, power, pad_mode):
    S = np.abs(librosa.stft(x, n_fft=n_fft, hop_length=hop, win_length=n_fft,
                            window="hann", center=True, pad_mode=pad_mode)) ** power
    fb = librosa.filters.mel(sr=sr, n_fft=n_fft, n_mels=n_mels, fmin=fmin,
                             fmax=fmax, htk=True, norm="slaney")
    return (fb @ S).T


def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


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

# (spectro_reference is inlined above)

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

def main_notes():
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


#!/usr/bin/env python3
"""What the four models cost under NATIVE ONNX Runtime, per thread count.

    python3 tool/onnx_timing.py [--wav <file>] [--seconds 30]
                                [--threads 1,2,4] [--out timing.json]

§35 quoted throughput for these models from the pure-Dart runtime, where the
figure is dominated by that runtime's lack of buffer reuse, and from a VPS
under load, where it is dominated by the neighbours. This measures the other
end: native ORT, one model per process, with `intra_op` swept so the table
says whether a thread actually buys anything.

**One process per (model, thread count).** The obvious shape — load all four
graphs in one process and print `VmHWM` at the end — gives a single number
that belongs to no model, and §35's own rule is that a figure which cannot be
attributed is not a measurement. Each child reports its RSS twice: once after
building the input and before the session exists (the front end and the
interpreter), and once at the end. The difference is the model's share, which
is the number a phone would care about.

All four are fed a REAL front end computed from real audio, not noise:
throughput does not depend on the values, but a wrong-shaped input silently
measures a different graph, and RMVPE's input is `[1, 128, frames]` while
FCPE's is `[1, frames, 128]`.
"""
import argparse
import json
import math
import os
import subprocess
import sys
import time

import numpy as np

MODELS = ("hft", "oaf", "rmvpe", "fcpe")


def peak_rss_mb():
    """VmHWM — the kernel's own high-water mark, not a sampled maximum."""
    try:
        for line in open("/proc/self/status"):
            if line.startswith("VmHWM:"):
                return float(line.split()[1]) / 1024.0
    except OSError:
        pass
    return float("nan")


def read_mel_asset(path):
    """CometBeat's `<model>_mel.bin`: little-endian
    `int32[4]{nMels,nFft,nFreq,hop}`, `float32[nMels*nFreq]` mel basis,
    `float32[nFft]` Hann window. The basis ships as an asset precisely so the
    front end is not re-derived, and re-deriving it here would measure a
    different front end from the one CometBeat runs."""
    raw = open(path, "rb").read()
    n_mels, n_fft, n_freq, hop = np.frombuffer(raw, "<i4", count=4)
    off = 16
    basis = np.frombuffer(raw, "<f4", count=int(n_mels) * int(n_freq),
                          offset=off).reshape(int(n_mels), int(n_freq))
    off += 4 * int(n_mels) * int(n_freq)
    hann = np.frombuffer(raw, "<f4", count=int(n_fft), offset=off)
    return int(n_mels), int(n_fft), int(n_freq), int(hop), basis, hann


def cometbeat_logmel(audio16k, asset):
    """`rmvpe_mel.dart` / `fcpe_mel.dart`: log(clamp(basis @ |STFT|, 1e-5)),
    centred with reflect padding. Returns `[nMels, frames]`."""
    n_mels, n_fft, n_freq, hop, basis, hann = asset
    pad = np.pad(audio16k, n_fft // 2, mode="reflect")
    frames = 1 + len(audio16k) // hop
    idx = np.arange(n_fft)[None, :] + hop * np.arange(frames)[:, None]
    spec = np.abs(np.fft.rfft(pad[idx] * hann, axis=1))[:, :n_freq]
    return np.log(np.maximum(basis @ spec.T, 1e-5)).astype(np.float32)


def build_feed(name, mono, cb_dir):
    """The input tensor(s) one model is actually given, and how many calls a
    clip costs it. hFT's window is a fixed 192 frames advancing 128, so its
    per-clip cost is `windows` invocations; the other three take the whole
    clip in one forward."""
    if name == "hft":
        feat = np.log(mel(mono, 16000, 2048, 256, 256, 0, 8000, 2.0,
                          "constant") + 1e-8)
        f = feat.shape[0]
        minv = math.log(1e-8)
        len_s = int(np.ceil(f / 128) * 128) - f
        padded = np.concatenate([
            np.full((32, 256), minv, np.float32), feat.astype(np.float32),
            np.full((len_s + 32, 256), minv, np.float32)])
        return ({"spec": padded[0:192].T[None, :, :].astype(np.float32)},
                len(range(0, f, 128)))
    if name == "oaf":
        m = np.log(np.maximum(
            mel(mono[:-1], 16000, 2048, 512, 229, 30, 8000, 1.0, "reflect"),
            1e-5))
        return {"mel": m[None, :, :].astype(np.float32)}, 1
    lm = cometbeat_logmel(mono, read_mel_asset(
        os.path.join(cb_dir, f"{name}_mel.bin")))
    if name == "rmvpe":
        # The U-Net strides by 32; the frame axis is padded up to a multiple
        # of it, exactly as `rmvpe.dart` does before the call. This is NOT
        # chunking — it is one forward over the whole clip, which is the
        # thing §35.6 could not run on the VPS.
        pf = int(np.ceil(lm.shape[1] / 32) * 32)
        x = np.zeros((1, lm.shape[0], pf), np.float32)
        x[0, :, :lm.shape[1]] = lm
        return {"input": x}, 1
    return {"mel": lm.T[None, :, :].astype(np.float32)}, 1


def child(a):
    """One model, one thread count, one process. Prints a single JSON line."""
    import onnxruntime as ort
    import soundfile as sf

    audio, sr = sf.read(a.wav, always_2d=True)
    audio = audio[:int(a.seconds * sr), 0]
    secs = len(audio) / sr
    mono = resample(audio, sr, 16000)
    feed, calls = build_feed(a.only, mono, a.cometbeat)
    rss_before = peak_rss_mb()

    so = ort.SessionOptions()
    so.intra_op_num_threads = a.threads
    so.inter_op_num_threads = 1
    sess = ort.InferenceSession(a.model_path, so,
                                providers=["CPUExecutionProvider"])
    # One warm-up: ORT's first call pays for arena growth and thread-pool
    # creation, which is a property of the first call rather than of the model.
    sess.run(None, feed)
    times = []
    for _ in range(a.runs):
        t0 = time.time()
        sess.run(None, feed)
        times.append(time.time() - t0)
    per_call = float(np.median(times))
    print("RESULT " + json.dumps({
        "model": a.only, "threads": a.threads, "seconds": secs,
        "calls": calls, "per_call_s": per_call,
        "clip_s": per_call * calls, "xrt": per_call * calls / secs,
        "rss_before_mb": rss_before, "rss_peak_mb": peak_rss_mb(),
    }), flush=True)


def main_timing():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", default="/mnt/storage/tuner-bench/datasets/"
                                     "musicnet/musicnet/test_data/2191.wav")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--threads", default="1,2,4")
    ap.add_argument("--models", default="/mnt/storage/tuner-bench/onnx")
    ap.add_argument("--cometbeat", default="")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--out", default="")
    ap.add_argument("--only", default="", choices=("",) + MODELS)
    ap.add_argument("--model-path", default="")
    a = ap.parse_args()
    a.cometbeat = a.cometbeat or os.path.join(a.models, "cometbeat")

    if a.only:
        a.threads = int(a.threads)
        return child(a)

    paths = {
        "hft": os.path.join(a.models, "hft_transformer.pruned.onnx"),
        "oaf": os.path.join(a.models, "onsets_and_frames.onnx"),
        "rmvpe": os.path.join(a.cometbeat, "rmvpe.onnx"),
        "fcpe": os.path.join(a.cometbeat, "fcpe.onnx"),
    }
    rows = {}
    for name in MODELS:
        # A model whose file is absent is reported and dropped, never printed
        # as a row of zeros — §35's own rule about what a missing measurement
        # should look like.
        if not os.path.exists(paths[name]):
            print(f"skipping {name}: no {paths[name]}", flush=True)
            continue
        rows[name] = {}
        for nt in [int(t) for t in a.threads.split(",")]:
            cmd = [sys.executable, os.path.abspath(__file__),
                   "--only", name, "--model-path", paths[name],
                   "--wav", a.wav, "--seconds", str(a.seconds),
                   "--threads", str(nt), "--runs", str(a.runs),
                   "--models", a.models, "--cometbeat", a.cometbeat]
            p = subprocess.run(cmd, capture_output=True, text=True,
                               cwd=os.path.dirname(os.path.abspath(__file__)))
            line = [l for l in p.stdout.splitlines() if l.startswith("RESULT ")]
            if not line:
                # A child that died — RMVPE's un-chunked forward is exactly
                # the thing that gets OOM-killed — is recorded as a failure
                # with its reason, not omitted.
                tail = (p.stderr.strip().splitlines() or ["no output"])[-1]
                rows[name][nt] = {"failed": tail, "returncode": p.returncode}
                print(f"{name:6s} {nt} thread(s): FAILED rc={p.returncode} "
                      f"{tail}", flush=True)
                continue
            r = json.loads(line[-1][7:])
            rows[name][nt] = r
            print(f"{name:6s} {nt} thread(s): {r['clip_s']:.3f} s for "
                  f"{r['seconds']:.1f} s of audio = {r['xrt']:.3f}x real time"
                  + (f" ({r['calls']} windows)" if r["calls"] > 1 else "")
                  + f", RSS {r['rss_before_mb']:.0f} -> "
                    f"{r['rss_peak_mb']:.0f} MB", flush=True)

    print("\n| model | 1 thread | 2 threads | 4 threads | peak RSS (1 thread) "
          "| model's share |")
    print("| --- | --- | --- | --- | --- | --- |")
    for name, per in rows.items():
        cells = []
        for nt in (1, 2, 4):
            r = per.get(nt)
            cells.append("—" if not r or "failed" in r else f"{r['xrt']:.3f}x")
        one = per.get(1)
        if one and "failed" not in one:
            mem = (f"{one['rss_peak_mb']:.0f} MB",
                   f"{one['rss_peak_mb'] - one['rss_before_mb']:.0f} MB")
        else:
            mem = ("—", "—")
        print(f"| {name} | " + " | ".join(cells) + f" | {mem[0]} | {mem[1]} |")

    if a.out:
        json.dump({"wav": os.path.basename(a.wav), "seconds": a.seconds,
                   "rows": rows}, open(a.out, "w"), indent=1)
        print("wrote", a.out)


# ---------------------------------------------------------------------------
# The kernel's own entry point.
# ---------------------------------------------------------------------------

MODELS = models_dir()

if CHILD:
    # A timing child: one model, one thread count, its own address space.
    sys.exit(main_timing())

print("\n=== MusicNet test split, hFT and O&F, mir_eval ===\n", flush=True)
sys.argv = [
    "spectro_notes",
    "--data", DATA,
    "--models", MODELS,
    "--threads", "2",
    "--sweep",
    "--out", os.path.join(WORK, "spectro_notes.json"),
]
main_notes()

print("\n=== native ORT cost: four models, 1/2/4 threads, peak RSS ===\n",
      flush=True)
sys.argv = [
    "onnx_timing",
    "--wav", os.path.join(DATA, "musicnet", "test_data", "2191.wav"),
    "--seconds", "30",
    "--threads", "1,2,4",
    "--models", MODELS,
    "--cometbeat", MODELS,
    "--out", os.path.join(WORK, "onnx_timing.json"),
]
main_timing()
