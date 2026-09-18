#!/usr/bin/env python3
"""CrispTuner: neural pitch estimators against GuitarSet, on Kaggle.

Generated from bench/tool/neural_eval.py by bench/tool/kaggle/build_kernel.py —
do not edit here; the local copy is the one that gets reviewed.

It runs off-box for a plain reason: the evaluation is CPU-bound for tens of
minutes per model, and the VPS this project is developed on is shared. Nothing
here strictly needs a GPU, but Kaggle only gives a worker internet when one
is attached (gotcha #3), and a GPU turns CREPE-full from hours into minutes —
so the quota spent is small and the run is reliable.

The corpus is fetched from Zenodo inside the kernel rather than mirrored as a
Kaggle dataset, so nothing redistributes GuitarSet.
"""

import os
import subprocess
import sys
import zipfile
import urllib.request

WORK = "/kaggle/working"
DATA = os.path.join(WORK, "datasets")


def sh(cmd):
    print(f"$ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=True)


def fetch_guitarset():
    """GuitarSet (Zenodo 3371780, CC BY 4.0): annotations + mono-mic audio."""
    audio_dir = os.path.join(DATA, "audio")
    ann_dir = os.path.join(DATA, "annotation")
    if os.path.isdir(audio_dir) and len(os.listdir(audio_dir)) > 100:
        return
    os.makedirs(DATA, exist_ok=True)
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
    print(f"audio: {len(os.listdir(audio_dir))} files, "
          f"annotations: {len(os.listdir(ann_dir))}", flush=True)


def install():
    # Kaggle pre-installs torch; only the small wrappers are needed, and
    # re-installing torch wastes minutes and risks a version conflict.
    # Kaggle pre-installs torch and tensorflow; only the small wrappers are
    # needed. tensorflow_hub/kagglehub are for SPICE, the one model here that
    # is not a torch model.
    sh(f"{sys.executable} -m pip install -q torchcrepe pesto-pitch penn "
       f"tensorflow_hub kagglehub")


def require_internet():
    """Fail loudly and early rather than hanging.

    Kaggle CPU workers get no internet even with `enable_internet: "true"`,
    and a GPU worker can lose it too. Everything here — the pip installs, the
    model weights, the corpus — needs it, so there is no degraded mode worth
    attempting.
    """
    try:
        urllib.request.urlopen("https://zenodo.org", timeout=20).close()
    except Exception as exc:  # noqa: BLE001 - any failure means the same thing
        raise SystemExit(
            f"no internet on this worker ({exc}); re-run until a connected "
            "GPU worker is drawn, or deliver the corpus via dataset_sources"
        )


require_internet()
install()
fetch_guitarset()

# Everything below is bench/tool/neural_eval.py, verbatim.
# ---------------------------------------------------------------------------

import argparse
import glob
import json
import os
import time

import numpy as np

SEARCH_OFFSETS_MS = [-40, -20, -10, 0, 10, 20, 40]


_DEVICE = None


def torch_device():
    """CUDA when there is a *usable* one, else CPU.

    Two traps, both from /mnt/volume1/kaggle-usage.md. Kaggle hands out P100s
    almost exclusively (gotcha #21), and its preinstalled torch has dropped
    sm_60, so a P100 draw kills a torch kernel outright with "no kernel image
    is available for execution on the device" (#23). The guide's advice there
    is to exit and re-push until a better GPU appears.

    This kernel does not need to do that, because it does not actually need a
    GPU — it needs a worker with *internet*, which on Kaggle only comes
    attached to one. So an unusable GPU degrades to CPU and the run still
    finishes, slower, instead of burning a draw.

    Note what the device does to the cost column: a GPU timing is not
    comparable to YIN's 1.6 ms/frame on a CPU core, and REPORT.md says so
    rather than quietly putting them in one table.
    """
    global _DEVICE
    if _DEVICE is not None:
        return _DEVICE
    import torch
    _DEVICE = "cpu"
    if torch.cuda.is_available():
        major, minor = torch.cuda.get_device_capability()
        capability = major * 10 + minor
        name = torch.cuda.get_device_name(0)
        if capability >= 70:
            _DEVICE = "cuda"
        else:
            print(f"GPU is {name} (sm_{capability}); this torch build needs "
                  f"sm_70+, so running on CPU instead", flush=True)
    return _DEVICE


# ---------------------------------------------------------------- corpus ---

def read_wav_mono(path):
    import wave
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2, path
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
        data = ann["data"]
        times, freqs = [], []
        for t, v in zip(data["time"], data["value"]):
            if not v.get("voiced"):
                continue
            f = float(v["frequency"])
            if f > 0:
                times.append(t)
                freqs.append(f)
        strings.append((np.asarray(times), np.asarray(freqs)))
    return strings


def reference_series(strings, times, tol):
    """For each query time: (n_active, frequency_if_exactly_one)."""
    counts = np.zeros(len(times), dtype=np.int16)
    freqs = np.zeros(len(times), dtype=np.float64)
    for string_times, string_freqs in strings:
        if len(string_times) == 0:
            continue
        idx = np.searchsorted(string_times, times)
        for j, (i, t) in enumerate(zip(idx, times)):
            for cand in (i - 1, i):
                if 0 <= cand < len(string_times) and abs(string_times[cand] - t) <= tol:
                    counts[j] += 1
                    freqs[j] = string_freqs[cand]
                    break
    return counts, freqs


# ---------------------------------------------------------------- models ---

class Model:
    """Returns (times, frequencies, confidences) for a mono signal."""
    name = "?"
    sample_rate = 16000
    # The audio a single frame's answer depends on, in ms — the structural
    # latency floor, the same quantity §9 charges YIN's 93 ms window for.
    receptive_field_ms = None

    def run(self, audio, rate):
        raise NotImplementedError


class TorchCrepe(Model):
    def __init__(self, capacity="tiny", hop_ms=10.0, decoder="weighted_argmax"):
        import torchcrepe
        self.torchcrepe = torchcrepe
        self.capacity = capacity
        self.decoder_name = decoder
        self.name = f"crepe-{capacity}" + (
            "" if decoder == "weighted_argmax" else f"-{decoder}")
        self.sample_rate = torchcrepe.SAMPLE_RATE
        self.hop = int(self.sample_rate * hop_ms / 1000)
        # 1024 samples at 16 kHz.
        self.receptive_field_ms = 1000 * torchcrepe.WINDOW_SIZE / self.sample_rate

    def run(self, audio, rate):
        import torch
        tensor = torch.from_numpy(audio)[None]
        # Two standard decoders, and the choice is not cosmetic.
        # `weighted_argmax` reads cents out of CREPE's 20-cent bins by a local
        # weighted average and decides each frame alone. `viterbi` adds a
        # temporal model — the same idea pYIN adds to YIN (§4.1) — which
        # should show up where octave errors do, so it is measured rather
        # than assumed.
        pitch, periodicity = self.torchcrepe.predict(
            tensor,
            self.sample_rate,
            hop_length=self.hop,
            fmin=50.0,
            fmax=2006.0,
            model=self.capacity,
            decoder=getattr(self.torchcrepe.decode, self.decoder_name),
            return_periodicity=True,
            batch_size=512,
            device=torch_device(),
        )
        # .cpu() before .numpy(): on a CUDA device the bare call raises
        # "can't convert cuda:0 device type tensor to numpy", which is exactly
        # how the first Kaggle run died after 60 files of crepe-tiny.
        f0 = pitch[0].cpu().numpy().astype(np.float64)
        conf = periodicity[0].cpu().numpy().astype(np.float64)
        times = np.arange(len(f0)) * self.hop / self.sample_rate
        return times, f0, conf


class Pesto(Model):
    def __init__(self, step_ms=10.0, model_name="mir-1k_g7"):
        import pesto
        self.pesto = pesto
        self.step_ms = step_ms
        self.model_name = model_name
        # The package ships two checkpoints; the default is the g7 one.
        self.name = "pesto" if model_name == "mir-1k_g7" else f"pesto-{model_name}"
        self.sample_rate = 44100
        # PESTO is single-frame by design: one CQT frame in, one pitch out.
        # Its CQT's lowest filters set the receptive field; ~64 ms is the
        # figure its authors quote for the equivalent window.
        self.receptive_field_ms = 64.0

    def run(self, audio, rate):
        import torch
        x = torch.from_numpy(audio.astype(np.float32)).to(torch_device())
        timesteps, pitch, confidence, _ = self.pesto.predict(
            x, rate, step_size=self.step_ms, model_name=self.model_name,
            convert_to_freq=True
        )
        return (
            timesteps.cpu().numpy().astype(np.float64) / 1000.0,
            pitch.cpu().numpy().astype(np.float64),
            confidence.cpu().numpy().astype(np.float64),
        )


class Penn(Model):
    """FCNF0++ (Morrison et al. 2023), via the `penn` package."""

    name = "fcnf0++"

    def __init__(self):
        import penn
        self.penn = penn
        self.sample_rate = penn.SAMPLE_RATE
        self.receptive_field_ms = 1000 * 1024 / penn.SAMPLE_RATE

    def run(self, audio, rate):
        import torch
        x = torch.from_numpy(audio.astype(np.float32))[None]
        pitch, periodicity = self.penn.from_audio(
            x,
            self.sample_rate,
            hopsize=0.01,
            fmin=50.0,
            fmax=2006.0,
            checkpoint=None,
            batch_size=512,
            gpu=0 if torch_device() == "cuda" else None,
        )
        f0 = pitch[0].cpu().numpy().astype(np.float64)
        conf = periodicity[0].cpu().numpy().astype(np.float64)
        times = np.arange(len(f0)) * 0.01
        return times, f0, conf


class Spice(Model):
    """Google's SPICE (Gfeller et al. 2020), via TensorFlow Hub.

    The outlier of this comparison in two ways. It is self-supervised and
    predicts *relative* pitch, so its output is in arbitrary units that need
    the published affine calibration to become hertz — which means a
    systematic offset in that calibration would look exactly like a tuning
    error, and this report cares about a couple of cents. And it needs
    TensorFlow, which is why it only runs on Kaggle: installing TF next to
    torch on the VPS to measure one more model was not a good trade.
    """

    name = "spice"
    sample_rate = 16000

    # Published calibration from the SPICE model card.
    PT_OFFSET = 25.58
    PT_SLOPE = 63.07
    FMIN = 10.0
    BINS_PER_OCTAVE = 12.0

    def __init__(self):
        import tensorflow_hub as hub
        self.model = None
        for source in (
            lambda: __import__("kagglehub").model_download(
                "google/spice/tensorFlow2/spice"),
            lambda: "https://tfhub.dev/google/spice/2",
        ):
            try:
                self.model = hub.load(source())
                break
            except Exception as exc:  # noqa: BLE001
                print(f"spice: {exc}", flush=True)
        if self.model is None:
            raise SystemExit("could not load SPICE from kagglehub or tfhub")
        # ~32 ms between frames; the model's own context is longer, and it is
        # reported here as the frame spacing rather than guessed at.
        self.hop = 512
        self.receptive_field_ms = 1000 * 1024 / self.sample_rate

    def run(self, audio, rate):
        import numpy as np
        out = self.model.signatures["serving_default"](
            __import__("tensorflow").constant(audio, dtype="float32")
        )
        pitch = out["pitch"].numpy().astype(np.float64)
        uncertainty = out["uncertainty"].numpy().astype(np.float64)
        cqt_bin = pitch * self.PT_SLOPE + self.PT_OFFSET
        f0 = self.FMIN * 2.0 ** (cqt_bin / self.BINS_PER_OCTAVE)
        times = np.arange(len(f0)) * self.hop / self.sample_rate
        return times, f0, 1.0 - uncertainty


def build(name):
    if name.startswith("crepe-"):
        parts = name.split("-")
        capacity = parts[1]
        decoder = "-".join(parts[2:]) or "weighted_argmax"
        return TorchCrepe(capacity=capacity, decoder=decoder)
    if name.startswith("pesto"):
        _, _, variant = name.partition("-")
        return Pesto(model_name=variant or "mir-1k_g7")
    if name in ("penn", "fcnf0++"):
        return Penn()
    if name == "spice":
        return Spice()
    raise SystemExit(f"unknown model {name}")


# --------------------------------------------------------------- scoring ---

def cents(a, b):
    return 1200 * np.log2(a / b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="crepe-tiny,pesto")
    ap.add_argument("--data", default=DATA)
    ap.add_argument("--subset", default="solo")
    ap.add_argument("--limit", type=int, default=20)
    # One fixed confidence threshold is not a fair comparison: each model's
    # confidence is on its own scale, and SWIPE' already demonstrated how
    # badly that can mislead (REPORT.md §4.5 — a scale mismatch rejected
    # every frame). The model output is cached, so sweeping costs nothing.
    ap.add_argument("--confidence", default="0.1,0.25,0.5,0.75,0.9")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    wavs = sorted(glob.glob(os.path.join(args.data, "audio", "*.wav")))
    pairs = []
    for wav in wavs:
        base = os.path.basename(wav).replace("_mic.wav", "")
        if not base.endswith("_" + args.subset):
            continue
        jams = os.path.join(args.data, "annotation", base + ".jams")
        if os.path.exists(jams):
            pairs.append((wav, jams))
    pairs = pairs[: args.limit] if args.limit else pairs

    print(f"files  : {len(pairs)} ({args.subset})")
    print(f"models : {args.models}")
    print(f"device : {torch_device()}")
    print()

    summary = {}
    for model_name in args.models.split(","):
        model = build(model_name.strip())
        mono = correct = octave = gross = reported = 0
        voiced = voiced_reported = unvoiced = unvoiced_reported = 0
        errors = []
        seconds_audio = 0.0
        seconds_compute = 0.0
        offset_hits = {o: [0, 0] for o in SEARCH_OFFSETS_MS}

        # Run each model over each file exactly once; the alignment sweep
        # and the scoring both read the cached output. (Running it twice, as
        # a first version did, doubled the cost of the slowest models for
        # nothing.)
        thresholds = [float(t) for t in str(args.confidence).split(",")]
        cached = []
        for n, (wav, jams) in enumerate(pairs, 1):
            audio, rate = read_wav_mono(wav)
            if rate != model.sample_rate:
                from scipy.signal import resample_poly
                from math import gcd
                g = gcd(int(model.sample_rate), int(rate))
                audio_m = resample_poly(audio, model.sample_rate // g, rate // g)
            else:
                audio_m = audio
            seconds_audio += len(audio_m) / model.sample_rate

            t0 = time.perf_counter()
            times, f0, conf = model.run(audio_m.astype(np.float32), model.sample_rate)
            seconds_compute += time.perf_counter() - t0
            cached.append((load_truth(jams), times, f0, conf))
            print(f"\r  {model.name}: {n}/{len(pairs)}", end="", flush=True)
        print()

        tol = 256 / 44100 / 2
        for strings, times, f0, conf in cached:
            for off in SEARCH_OFFSETS_MS:
                counts, refs = reference_series(strings, times + off / 1000.0, tol)
                sel = counts == 1
                if not sel.any():
                    continue
                ok = sel & (conf >= thresholds[0]) & (f0 > 0)
                offset_hits[off][0] += int(sel.sum())
                if ok.any():
                    err = np.abs(cents(f0[ok], refs[ok]))
                    offset_hits[off][1] += int((err <= 50).sum())

        best_offset = max(
            offset_hits, key=lambda o: offset_hits[o][1] / max(1, offset_hits[o][0])
        )

        per_threshold = {}
        for threshold in thresholds:
            mono = correct = octave = gross = reported = 0
            voiced = voiced_reported = unvoiced = unvoiced_reported = 0
            errors = []
            for strings, times, f0, conf in cached:
                counts, refs = reference_series(
                    strings, times + best_offset / 1000.0, tol
                )
                said = (conf >= threshold) & (f0 > 0)
                voiced += int((counts >= 1).sum())
                voiced_reported += int(((counts >= 1) & said).sum())
                unvoiced += int((counts == 0).sum())
                unvoiced_reported += int(((counts == 0) & said).sum())

                sel = counts == 1
                mono += int(sel.sum())
                use = sel & said
                reported += int(use.sum())
                if use.any():
                    err = cents(f0[use], refs[use])
                    good = np.abs(err) <= 50
                    correct += int(good.sum())
                    errors.extend(np.abs(err[good]).tolist())
                    bad = err[~good]
                    if bad.size:
                        octaves = bad / 1200
                        is_octave = (
                            np.abs(octaves - np.round(octaves)) * 1200 <= 50
                        ) & (np.round(octaves) != 0)
                        octave += int(is_octave.sum())
                        gross += int((~is_octave).sum())

            per_threshold[threshold] = dict(
                mono=mono, correct=correct, reported=reported, octave=octave,
                gross=gross, voiced=voiced, voiced_reported=voiced_reported,
                unvoiced=unvoiced, unvoiced_reported=unvoiced_reported,
                errors=np.asarray(errors),
            )

        # Report every threshold; pick none as canonical, because which one is
        # right depends on what the tuner would rather do when unsure.
        for threshold, r in per_threshold.items():
            e = r["errors"]
            print(
                f"{model.name:12s} @{threshold:<5} "
                f"RPA {100*r['correct']/max(1,r['mono']):5.2f}%  "
                f"rep {100*r['reported']/max(1,r['mono']):5.2f}%  "
                f"oct {100*r['octave']/max(1,r['reported']):4.2f}%  "
                f"gross {100*r['gross']/max(1,r['reported']):5.2f}%  "
                f"|err| p50 {np.percentile(e,50) if e.size else float('nan'):5.2f}  "
                f"p90 {np.percentile(e,90) if e.size else float('nan'):6.2f}  "
                f">5c {100*(e>5).mean() if e.size else float('nan'):5.2f}%  "
                f"VR {100*r['voiced_reported']/max(1,r['voiced']):5.1f}%  "
                f"FA {100*r['unvoiced_reported']/max(1,r['unvoiced']):5.1f}%",
                flush=True,
            )

        best = per_threshold[thresholds[0]]
        mono, correct, reported = best["mono"], best["correct"], best["reported"]
        octave, gross = best["octave"], best["gross"]
        voiced, voiced_reported = best["voiced"], best["voiced_reported"]
        unvoiced, unvoiced_reported = best["unvoiced"], best["unvoiced_reported"]
        errors = best["errors"]
        row = {
            "model": model.name,
            "mono": mono,
            "rpa": 100 * correct / max(1, mono),
            "reported": 100 * reported / max(1, mono),
            "octave": 100 * octave / max(1, reported),
            "gross": 100 * gross / max(1, reported),
            "p50": float(np.percentile(errors, 50)) if errors.size else None,
            "p90": float(np.percentile(errors, 90)) if errors.size else None,
            "p99": float(np.percentile(errors, 99)) if errors.size else None,
            "beyond5": 100 * float((errors > 5).mean()) if errors.size else None,
            "vr": 100 * voiced_reported / max(1, voiced),
            "fa": 100 * unvoiced_reported / max(1, unvoiced),
            "realtime": 100 * seconds_compute / max(1e-9, seconds_audio),
            "offset_ms": best_offset,
            "receptive_ms": model.receptive_field_ms,
            "by_threshold": {
                str(t): {
                    k: (v.tolist() if hasattr(v, "tolist") else v)
                    for k, v in r.items()
                    if k != "errors"
                }
                | {
                    "p50": float(np.percentile(r["errors"], 50))
                    if r["errors"].size
                    else None
                }
                for t, r in per_threshold.items()
            },
        }
        summary[model.name] = row
        print(
            f"{row['model']:12s} RPA {row['rpa']:5.2f}%  rep {row['reported']:5.2f}%  "
            f"oct {row['octave']:4.2f}%  gross {row['gross']:5.2f}%  "
            f"|err| p50 {row['p50']:5.2f}  p90 {row['p90']:6.2f}  "
            f">5c {row['beyond5']:5.2f}%  VR {row['vr']:5.1f}%  FA {row['fa']:5.1f}%  "
            f"{row['realtime']:6.1f}% of real time  (align {best_offset:+d} ms, "
            f"window {row['receptive_ms']:.0f} ms)"
        )

    if args.out:
        with open(args.out, "w") as f:
            json.dump(summary, f, indent=1)
        print(f"\nwrote {args.out}")


if __name__ == "__main__":
    sys.argv = [
        "neural_eval",
        "--models", os.environ.get("MODELS", "crepe-tiny,crepe-tiny-viterbi,crepe-full,crepe-full-viterbi,pesto,pesto-mir-1k,fcnf0++,spice"),
        "--limit", os.environ.get("LIMIT", "60"),
        "--out", os.path.join(WORK, "neural.json"),
    ]
    main()
