#!/usr/bin/env python3
"""Basic Pitch on *chords* — the measurement the transcription mode rests on.

Every neural number in bench/REPORT.md §10 came from GuitarSet's `_solo`
files. That is single-line playing, and it is the wrong material for judging
a polyphonic transcriber: it measures how well Basic Pitch does a job YIN
already does. The question a transcription mode actually raises is whether it
can name *several notes at once*, which is precisely what the `_comp`
recordings contain and what nothing in this repository had tested.

So: the same corpus, the chordal half, scored with the metric that applies to
sets rather than to single values — per-frame precision, recall and F1 over
the set of sounding notes, micro-averaged. The monophonic detector is scored
on the same frames as a baseline: it can only ever name one note, so its
recall is bounded by 1/|notes sounding|, and seeing that bound is the point.

Runs on Kaggle (see /mnt/volume1/kaggle-usage.md): a GPU worker for the
internet, not for the arithmetic.
"""

import glob
import json
import os
import subprocess
import sys
import urllib.request
import zipfile

import numpy as np

WORK = "/kaggle/working"
DATA = os.path.join(WORK, "datasets")
MODEL = os.path.join(WORK, "nmp.onnx")

MODEL_SAMPLE_RATE = 22050
WINDOW_SAMPLES = 43844
N_FRAMES = 172
FRAME_HOP = 256
NOTE_BINS = 88
LOWEST_MIDI = 21


def sh(cmd):
    print(f"$ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=True)


def require_internet():
    try:
        urllib.request.urlopen("https://zenodo.org", timeout=20).close()
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"no internet on this worker ({exc})")


def fetch():
    os.makedirs(DATA, exist_ok=True)
    audio_dir, ann_dir = os.path.join(DATA, "audio"), os.path.join(DATA, "annotation")
    if not (os.path.isdir(audio_dir) and len(os.listdir(audio_dir)) > 100):
        for name, url in [
            ("annotation.zip",
             "https://zenodo.org/records/3371780/files/annotation.zip?download=1"),
            ("audio_mono-mic.zip",
             "https://zenodo.org/records/3371780/files/audio_mono-mic.zip?download=1"),
        ]:
            target = os.path.join(DATA, name)
            print(f"fetching {name}", flush=True)
            urllib.request.urlretrieve(url, target)
            out = ann_dir if "annotation" in name else audio_dir
            os.makedirs(out, exist_ok=True)
            with zipfile.ZipFile(target) as z:
                z.extractall(out)
            os.remove(target)
    if not os.path.exists(MODEL):
        urllib.request.urlretrieve(
            "https://github.com/spotify/basic-pitch/raw/main/basic_pitch/"
            "saved_models/icassp_2022/nmp.onnx", MODEL)
    print("corpus and model ready", flush=True)


def read_wav_mono(path):
    import wave
    with wave.open(path, "rb") as w:
        rate, channels = w.getframerate(), w.getnchannels()
        frames = w.readframes(w.getnframes())
    data = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)
    return data, rate


def load_truth(jams_path):
    with open(jams_path) as f:
        doc = json.load(f)
    strings = []
    for ann in doc["annotations"]:
        if ann["namespace"] != "pitch_contour":
            continue
        d = ann["data"]
        times, freqs = [], []
        for t, v in zip(d["time"], d["value"]):
            if v.get("voiced") and float(v["frequency"]) > 0:
                times.append(t)
                freqs.append(float(v["frequency"]))
        strings.append((np.asarray(times), np.asarray(freqs)))
    return strings


def active_midi(strings, t, tol):
    """The set of MIDI notes sounding at t, rounded to the nearest semitone."""
    out = set()
    for times, freqs in strings:
        if len(times) == 0:
            continue
        i = np.searchsorted(times, t)
        for j in (i - 1, i):
            if 0 <= j < len(times) and abs(times[j] - t) <= tol:
                out.add(int(round(69 + 12 * np.log2(freqs[j] / 440.0))))
                break
    return out


def main():
    require_internet()
    sh(f"{sys.executable} -m pip install -q onnxruntime")
    fetch()
    import onnxruntime as ort
    from scipy.signal import resample_poly

    subset = os.environ.get("SUBSET", "comp")
    limit = int(os.environ.get("LIMIT", "60"))
    threshold = float(os.environ.get("THRESHOLD", "0.5"))

    session = ort.InferenceSession(MODEL, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    outs = session.get_outputs()
    names = [o.name for o in outs]

    # Two of the three heads are 88 wide — note and onset — and the ONNX
    # export does not name them. Assuming the order cost a whole evaluation:
    # the first version of this file scored the ONSET head as if it were
    # notes, which gave a recall of 21% and nearly killed the feature. Onsets
    # fire for a few frames at a note's start; note activations are sustained
    # for its duration, so the two are trivially separable by how long their
    # activations run. Identify them, and print the decision so it is
    # auditable rather than assumed.
    probe = session.run(names, {input_name: np.zeros((1, WINDOW_SAMPLES, 1),
                                                     dtype=np.float32)})
    wide = [i for i, o in enumerate(outs) if o.shape[-1] == NOTE_BINS]

    # Use real audio for the probe: silence tells us nothing about duration.
    probe_wav = sorted(glob.glob(os.path.join(DATA, "audio", "*_comp_mic.wav")))[0]
    probe_audio, probe_rate = read_wav_mono(probe_wav)
    probe_audio = resample_poly(probe_audio, MODEL_SAMPLE_RATE, probe_rate)
    probe = session.run(
        names,
        {input_name: probe_audio[:WINDOW_SAMPLES].astype(np.float32)[None, :, None]},
    )
    runs = {}
    for i in wide:
        active = probe[i][0] >= 0.3
        per_bin = active.sum(axis=0)
        runs[i] = per_bin[per_bin > 0].mean() if (per_bin > 0).any() else 0
    note_idx = max(runs, key=runs.get)
    onset_idx = min(runs, key=runs.get)
    print(f"note head  = {names[note_idx]} (mean activation run "
          f"{runs[note_idx]:.1f} frames)")
    print(f"onset head = {names[onset_idx]} (mean activation run "
          f"{runs[onset_idx]:.1f} frames)")

    pairs = []
    for wav in sorted(glob.glob(os.path.join(DATA, "audio", "*.wav"))):
        base = os.path.basename(wav).replace("_mic.wav", "")
        if not base.endswith("_" + subset):
            continue
        jams = os.path.join(DATA, "annotation", base + ".jams")
        if os.path.exists(jams):
            pairs.append((wav, jams))
    pairs = pairs[:limit] if limit else pairs
    print(f"files: {len(pairs)} ({subset}), note threshold {threshold}")

    thresholds = [0.3, 0.4, 0.5, 0.6, 0.7]
    stats = {t: dict(tp=0, fp=0, fn=0, frames=0) for t in thresholds}
    # How polyphonic is the material, and what can one note possibly score?
    poly_histogram = {}
    mono_tp = mono_fn = 0

    tol = 256 / 44100 / 2
    for n, (wav, jams) in enumerate(pairs, 1):
        audio, rate = read_wav_mono(wav)
        if rate != MODEL_SAMPLE_RATE:
            audio = resample_poly(audio, MODEL_SAMPLE_RATE, rate)
        strings = load_truth(jams)

        for start in range(0, len(audio) - WINDOW_SAMPLES + 1, WINDOW_SAMPLES):
            block = audio[start:start + WINDOW_SAMPLES].astype(np.float32)
            out = session.run(names, {input_name: block[None, :, None]})
            note = out[note_idx][0]  # (172, 88)

            for f in range(N_FRAMES):
                t = (start + f * FRAME_HOP) / MODEL_SAMPLE_RATE
                truth = active_midi(strings, t, tol)
                if not truth:
                    continue
                poly_histogram[len(truth)] = poly_histogram.get(len(truth), 0) + 1

                # A monophonic detector's ceiling on this frame: one right note.
                mono_tp += 1
                mono_fn += len(truth) - 1

                for th in thresholds:
                    predicted = {
                        LOWEST_MIDI + b for b in range(NOTE_BINS)
                        if note[f, b] >= th
                    }
                    s = stats[th]
                    s["frames"] += 1
                    s["tp"] += len(truth & predicted)
                    s["fp"] += len(predicted - truth)
                    s["fn"] += len(truth - predicted)
        print(f"\r  {n}/{len(pairs)}", end="", flush=True)
    print()

    print()
    print("polyphony of the reference frames:")
    for k in sorted(poly_histogram):
        share = 100 * poly_histogram[k] / max(1, sum(poly_histogram.values()))
        print(f"  {k} note(s) sounding: {poly_histogram[k]:7d} frames ({share:5.1f}%)")

    print()
    print("Basic Pitch, note head, per-frame multi-pitch:")
    print("thresh   precision  recall     F1")
    best = None
    for th in thresholds:
        s = stats[th]
        p = s["tp"] / max(1, s["tp"] + s["fp"])
        r = s["tp"] / max(1, s["tp"] + s["fn"])
        f1 = 0 if p + r == 0 else 2 * p * r / (p + r)
        print(f"  {th:<6} {100*p:8.2f}%  {100*r:7.2f}%  {100*f1:6.2f}%")
        if best is None or f1 > best[1]:
            best = (th, f1)

    mono_recall = mono_tp / max(1, mono_tp + mono_fn)
    print()
    print(f"A perfect *monophonic* detector's ceiling on the same frames: "
          f"recall {100*mono_recall:.2f}% (it can name one note of "
          f"{(mono_tp + mono_fn) / max(1, mono_tp):.2f} sounding on average)")
    print(f"Basic Pitch's best F1 here: {100*best[1]:.2f}% at threshold {best[0]}")

    with open(os.path.join(WORK, "polyphonic.json"), "w") as f:
        json.dump({
            "subset": subset, "files": len(pairs),
            "polyphony": poly_histogram,
            "mono_recall_ceiling": mono_recall,
            "stats": {str(k): v for k, v in stats.items()},
        }, f, indent=1)


if __name__ == "__main__":
    main()
