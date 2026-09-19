#!/usr/bin/env python3
"""The neural pitch models on a cello — the instrument none of them saw.

Everything in REPORT.md §10 was measured on guitar. CREPE, PESTO and FCNF0++
are trained overwhelmingly on speech, singing and (for CREPE) a corpus that
is mostly voice and plucked instruments; a bowed string with heavy vibrato in
a low register is the case where a learned model has most room to disappoint,
and until now nothing had checked.

MUSERC (Zenodo 1560651, CC BY 4.0): 132 recordings of one professional and
one amateur cellist, 48 kHz, seven notes from D3 to C#4, in steady 'tune'
takes, 'novib' takes at three dynamics, and vibrato takes.

What the corpus supports is narrower than GuitarSet's, and the scoring
follows bench/lib/cello.dart so the numbers sit beside YIN's:

  * the note the cellist aimed at is in the filename, so note-naming and
    octave errors are scoreable;
  * the cellist was tuned to roughly A=432 (REPORT.md §11), so a fixed A440
    reference would score a third of a semitone of error that is the
    instrument's tuning rather than anyone's mistake. Each take's own median
    reading is therefore the reference for spread, and the offset is
    reported rather than scored;
  * needle stillness needs no reference at all, and on a steady bowed note it
    is the figure a player actually sees.
"""

import glob
import json
import os
import re
import subprocess
import sys
import urllib.request
import zipfile

import numpy as np

WORK = "/kaggle/working"
DATA = os.path.join(WORK, "muserc")
SA = os.path.join(DATA, "MUSERC", "SA")


def sh(cmd):
    print(f"$ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=True)


def require_internet():
    try:
        urllib.request.urlopen("https://zenodo.org", timeout=20).close()
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"no internet on this worker ({exc})")


def fetch():
    if os.path.isdir(SA) and len(os.listdir(SA)) > 100:
        return
    os.makedirs(DATA, exist_ok=True)
    target = os.path.join(DATA, "MUSERC.zip")
    print("fetching MUSERC (1.4 GB)", flush=True)
    urllib.request.urlretrieve(
        "https://zenodo.org/records/1560651/files/MUSERC.zip?download=1", target)
    with zipfile.ZipFile(target) as z:
        # Only the SA/ folder: audio and sensor CSVs, 72 MB of the 1.4 GB.
        for name in z.namelist():
            if name.startswith("MUSERC/SA/") and not name.startswith("__MACOSX"):
                z.extract(name, DATA)
    os.remove(target)
    print(f"takes: {len(os.listdir(SA))}", flush=True)


def read_wav_mono(path):
    import wave
    with wave.open(path, "rb") as w:
        rate, channels = w.getframerate(), w.getnchannels()
        frames = w.readframes(w.getnframes())
    data = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)
    return data, rate


def parse_take(path):
    """pro_60_tune_1.wav, amateur_50_f_vib_1.wav, pro_51_m_novib.wav."""
    name = os.path.basename(path).replace(".wav", "")
    parts = name.split("_")
    if len(parts) < 3 or not parts[1].isdigit():
        return None
    midi = int(parts[1])
    if parts[2] == "tune":
        return dict(player=parts[0], midi=midi, dynamic="tune", vibrato=False)
    vib = len(parts) > 3 and parts[3].startswith("vib")
    return dict(player=parts[0], midi=midi, dynamic=parts[2], vibrato=vib)


def cents(a, b):
    return 1200 * np.log2(a / b)


def main():
    require_internet()
    sh(f"{sys.executable} -m pip install -q torchcrepe pesto-pitch penn")
    fetch()

    import torch
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False
    device = "cpu"
    if torch.cuda.is_available():
        major, minor = torch.cuda.get_device_capability()
        if major * 10 + minor >= 70:
            device = "cuda"
    print(f"device: {device}", flush=True)

    import torchcrepe
    import pesto
    import penn
    from scipy.signal import resample_poly
    from math import gcd

    def run_crepe(audio, rate, capacity):
        x = torch.from_numpy(audio)[None]
        pitch, periodicity = torchcrepe.predict(
            x, rate, hop_length=int(rate * 0.01), fmin=50.0, fmax=2006.0,
            model=capacity, decoder=torchcrepe.decode.weighted_argmax,
            return_periodicity=True, batch_size=512, device=device)
        return (pitch[0].cpu().numpy().astype(np.float64),
                periodicity[0].cpu().numpy().astype(np.float64))

    def run_pesto(audio, rate):
        x = torch.from_numpy(audio.astype(np.float32)).to(device)
        _, pitch, conf, _ = pesto.predict(x, rate, step_size=10.0,
                                          convert_to_freq=True)
        return (pitch.cpu().numpy().astype(np.float64),
                conf.cpu().numpy().astype(np.float64))

    def run_penn(audio, rate):
        x = torch.from_numpy(audio.astype(np.float32))[None]
        pitch, periodicity = penn.from_audio(
            x, rate, hopsize=0.01, fmin=50.0, fmax=2006.0, checkpoint=None,
            batch_size=512, gpu=0 if device == "cuda" else None)
        return (pitch[0].cpu().numpy().astype(np.float64),
                periodicity[0].cpu().numpy().astype(np.float64))

    models = {
        "crepe-tiny": (16000, lambda a, r: run_crepe(a, r, "tiny")),
        "crepe-full": (16000, lambda a, r: run_crepe(a, r, "full")),
        "pesto": (44100, run_pesto),
        "fcnf0++": (penn.SAMPLE_RATE, run_penn),
    }
    confidences = [0.1, 0.25, 0.5, 0.75]

    takes = []
    for wav in sorted(glob.glob(os.path.join(SA, "*.wav"))):
        t = parse_take(wav)
        if t:
            t["path"] = wav
            takes.append(t)
    # The `tune` takes are the cellist tuning the instrument, not the note in
    # the filename: pro_60_tune_1 is labelled 60 and holds a 220 Hz open A.
    # Scoring them against the label cost a published set of numbers once
    # already (REPORT.md §11), so they are excluded here from the outset.
    steady = [t for t in takes
              if not t["vibrato"] and t["dynamic"] != "tune"]
    print(f"takes: {len(takes)} ({len(steady)} steady, tuning takes excluded)",
          flush=True)

    results = {}
    for name, (model_rate, run) in models.items():
        per_threshold = {c: dict(frames=0, reported=0, named=0, octave=0,
                                 spread=[], offset=[], named_per_take=[],
                                 octave_per_take=[]) for c in confidences}
        failed = None
        try:
            for n, take in enumerate(steady, 1):
                audio, rate = read_wav_mono(take["path"])
                if rate != model_rate:
                    g = gcd(int(model_rate), int(rate))
                    audio = resample_poly(audio, model_rate // g, rate // g)
                f0, conf = run(audio.astype(np.float32), model_rate)

                # Skip the bow attack, as bin/cello.dart does.
                skip = int(0.3 / 0.01)
                f0, conf = f0[skip:], conf[skip:]
                nominal = 440 * 2 ** ((take["midi"] - 69) / 12)

                for c in confidences:
                    said = (conf >= c) & (f0 > 0)
                    slot = per_threshold[c]
                    slot["frames"] += len(f0)
                    slot["reported"] += int(said.sum())
                    if not said.any():
                        continue
                    err = cents(f0[said], nominal)
                    named = int((np.abs(err) <= 50).sum())
                    octaves = err / 1200
                    octave = int((
                        (np.abs(err) > 50)
                        & (np.abs(octaves - np.round(octaves)) * 1200 <= 50)
                        & (np.round(octaves) != 0)).sum())
                    slot["named"] += named
                    slot["octave"] += octave
                    slot["named_per_take"].append(named / int(said.sum()))
                    slot["octave_per_take"].append(octave / int(said.sum()))
                    # Reference-free: spread around this take's own median.
                    median = np.median(f0[said])
                    dev = np.abs(cents(f0[said], median))
                    dev = dev[dev < 600]
                    if dev.size:
                        slot["spread"].append(float(np.percentile(dev, 90)))
                    slot["offset"].append(float(cents(median, nominal)))
                print(f"\r  {name}: {n}/{len(steady)}", end="", flush=True)
            print()
        except Exception as exc:  # noqa: BLE001
            failed = f"{type(exc).__name__}: {exc}"
            print(f"\n{name} FAILED — {failed}", flush=True)
            continue

        # Median over takes, not a pooled ratio over frames: bin/cello.dart
        # reports the median take, and a comparison of two different
        # aggregations is not a comparison. One awful take swings a pooled
        # ratio and moves a median hardly at all, which is the behaviour
        # wanted when a corpus has known label problems in it.
        results[name] = {str(c): {
            "reported_pct": 100 * v["reported"] / max(1, v["frames"]),
            "named_pct": 100 * float(np.median(v["named_per_take"]))
            if v["named_per_take"] else 0.0,
            "octave_pct": 100 * float(np.median(v["octave_per_take"]))
            if v["octave_per_take"] else 0.0,
            "spread_p90": float(np.median(v["spread"])) if v["spread"] else None,
            "offset": float(np.median(v["offset"])) if v["offset"] else None,
        } for c, v in per_threshold.items()}

    print()
    print("STEADY CELLO TAKES — bow attack excluded, tuning takes excluded, "
          "median over takes.")
    print("YIN for comparison: named 100.0%, octave 0.0%, "
          "reported 99.7%, spread p90 5.48 c, offset -3.6 c")
    print(f"{'model':14s} {'conf':6s} {'rep%':>7s} {'named%':>8s} "
          f"{'oct%':>7s} {'spread p90':>11s} {'offset':>9s}")
    for name, rows in results.items():
        for c, r in rows.items():
            spread = f"{r['spread_p90']:.2f}" if r["spread_p90"] else "  —"
            offset = f"{r['offset']:.1f}c" if r["offset"] is not None else "  —"
            print(f"{name:14s} {c:6s} {r['reported_pct']:6.2f}% "
                  f"{r['named_pct']:7.2f}% {r['octave_pct']:6.2f}% "
                  f"{spread:>11s} {offset:>9s}")

    with open(os.path.join(WORK, "cello_neural.json"), "w") as f:
        json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()
