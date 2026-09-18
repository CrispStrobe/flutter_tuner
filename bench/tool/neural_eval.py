#!/usr/bin/env python3
"""Every neural pitch estimator worth testing, scored the way YIN was.

`basic_pitch_eval.py` answered one model. This answers the rest of the list,
and unlike Basic Pitch these are *direct* competitors: CREPE, PESTO and
FCNF0++ are monophonic frame-level f0 estimators, exactly the job
`lib/detectors.dart` does.

The rules are the ones `bin/bench.dart` uses, so the numbers can sit beside
YIN's without an asterisk: GuitarSet's own annotations, a frame counted only
when exactly one string is sounding, correct within 50 cents, octave errors
separated from gross ones, and the reference instant swept rather than
assumed (each model is scored at whichever alignment flatters it most, which
is the only fair way to compare estimators with different frame conventions).

The question is not "which is the best pitch tracker" — the literature has
answered that, and it is not YIN. The question is narrower and this report
has asked it throughout: **can any of them tell you the cents?** A tuner
needs ±1 cent on a held note. A classifier over 20-cent bins has to earn
that back through interpolation, and whether it does is measurable.

  python3 tool/neural_eval.py --models crepe-tiny,crepe-full,pesto,penn --limit 20

Requires torch, torchcrepe, pesto-pitch, penn, librosa, scipy.
"""

import argparse
import glob
import json
import os
import time

import numpy as np

SEARCH_OFFSETS_MS = [-40, -20, -10, 0, 10, 20, 40]


def torch_device():
    """CUDA when there is one — on Kaggle there is, and CREPE-full on a CPU
    is the difference between minutes and hours.

    Note what this does to the cost column: timings on a GPU are not
    comparable to YIN's 1.6 ms/frame on a CPU core, and REPORT.md says so
    rather than quietly putting them in the same table.
    """
    import torch
    return "cuda" if torch.cuda.is_available() else "cpu"


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
    def __init__(self, capacity="tiny", hop_ms=10.0):
        import torchcrepe
        self.torchcrepe = torchcrepe
        self.capacity = capacity
        self.name = f"crepe-{capacity}"
        self.sample_rate = torchcrepe.SAMPLE_RATE
        self.hop = int(self.sample_rate * hop_ms / 1000)
        # 1024 samples at 16 kHz.
        self.receptive_field_ms = 1000 * torchcrepe.WINDOW_SIZE / self.sample_rate

    def run(self, audio, rate):
        import torch
        tensor = torch.from_numpy(audio)[None]
        # `decoder=argmax` plus torchcrepe's own weighted average is the
        # standard way to read cents out of CREPE's 20-cent bins; Viterbi
        # would add a temporal model this comparison is not about.
        pitch, periodicity = self.torchcrepe.predict(
            tensor,
            self.sample_rate,
            hop_length=self.hop,
            fmin=50.0,
            fmax=2006.0,
            model=self.capacity,
            decoder=self.torchcrepe.decode.weighted_argmax,
            return_periodicity=True,
            batch_size=512,
            device=torch_device(),
        )
        f0 = pitch[0].numpy().astype(np.float64)
        conf = periodicity[0].numpy().astype(np.float64)
        times = np.arange(len(f0)) * self.hop / self.sample_rate
        return times, f0, conf


class Pesto(Model):
    name = "pesto"

    def __init__(self, step_ms=10.0):
        import pesto
        self.pesto = pesto
        self.step_ms = step_ms
        self.sample_rate = 44100
        # PESTO is single-frame by design: one CQT frame in, one pitch out.
        # Its CQT's lowest filters set the receptive field; ~64 ms is the
        # figure its authors quote for the equivalent window.
        self.receptive_field_ms = 64.0

    def run(self, audio, rate):
        import torch
        x = torch.from_numpy(audio.astype(np.float32)).to(torch_device())
        timesteps, pitch, confidence, _ = self.pesto.predict(
            x, rate, step_size=self.step_ms, convert_to_freq=True
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
        f0 = pitch[0].numpy().astype(np.float64)
        conf = periodicity[0].numpy().astype(np.float64)
        times = np.arange(len(f0)) * 0.01
        return times, f0, conf


def build(name):
    if name.startswith("crepe-"):
        return TorchCrepe(capacity=name.split("-", 1)[1])
    if name == "pesto":
        return Pesto()
    if name in ("penn", "fcnf0++"):
        return Penn()
    raise SystemExit(f"unknown model {name}")


# --------------------------------------------------------------- scoring ---

def cents(a, b):
    return 1200 * np.log2(a / b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="crepe-tiny,pesto")
    ap.add_argument("--data", default="/mnt/storage/tuner-bench/datasets")
    ap.add_argument("--subset", default="solo")
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--confidence", type=float, default=0.5)
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
                ok = sel & (conf >= args.confidence) & (f0 > 0)
                offset_hits[off][0] += int(sel.sum())
                if ok.any():
                    err = np.abs(cents(f0[ok], refs[ok]))
                    offset_hits[off][1] += int((err <= 50).sum())

        best_offset = max(
            offset_hits, key=lambda o: offset_hits[o][1] / max(1, offset_hits[o][0])
        )

        for strings, times, f0, conf in cached:
            counts, refs = reference_series(
                strings, times + best_offset / 1000.0, tol
            )
            said = (conf >= args.confidence) & (f0 > 0)
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
                    is_octave = (np.abs(octaves - np.round(octaves)) * 1200 <= 50) & (
                        np.round(octaves) != 0
                    )
                    octave += int(is_octave.sum())
                    gross += int((~is_octave).sum())

        errors = np.asarray(errors)
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
    main()
