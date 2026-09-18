#!/usr/bin/env python3
"""Evaluate Spotify's Basic Pitch against the same corpus, the same way.

This is an *offline evaluator*, deliberately in Python and deliberately not
part of the app: the question it answers is whether a neural transcriber is
worth building a native (or pure-Dart) inference path for at all. If the
answer is yes, the porting work is justified; if not, nothing was ported.

It mirrors `bin/bench.dart`: the same GuitarSet annotations, the same
monophonic-frame definition, the same 50-cent correctness rule, the same
octave/gross split, so the numbers can sit next to YIN's in REPORT.md without
an asterisk.

Three questions:

  1. **Accuracy.** Is it better than YIN at naming the note, and can it say
     anything useful about cents? Its contour head is 3 bins per semitone —
     33 cents — so the answer depends entirely on interpolation.
  2. **Cost.** Milliseconds per 2-second window on a CPU, which sets the
     update rate a sliding-window implementation could sustain.
  3. **Latency — the one that decides "almost realtime".** The model is not
     causal: every frame it emits sits inside a 2-second window and has been
     computed with audio from *after* it. So accuracy is measured as a
     function of how much right-context a frame had. A frame at the very end
     of the window has none, and that is the frame a realtime tuner would
     have to display.

  python3 tool/basic_pitch_eval.py --model /path/nmp.onnx --limit 30
"""

import argparse
import glob
import json
import os
import time
import wave

import numpy as np
import onnxruntime as ort
from scipy.signal import resample_poly

# The ONNX graph's fixed geometry.
MODEL_SAMPLE_RATE = 22050
WINDOW_SAMPLES = 43844
N_FRAMES = 172
FRAME_HOP = 256  # samples at 22050 Hz -> 11.61 ms
CONTOUR_BINS = 264
BINS_PER_SEMITONE = 3
BASE_FREQUENCY = 27.5  # A0, bin 0


def bin_to_frequency(bins):
    return BASE_FREQUENCY * 2 ** (np.asarray(bins) / (12.0 * BINS_PER_SEMITONE))


def read_wav_mono(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2, path
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
    data = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    channels = 1
    with wave.open(path, "rb") as w:
        channels = w.getnchannels()
    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)
    return data, rate


def load_truth(jams_path):
    """Per-string pitch contours: list of (times, freqs) arrays."""
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


def active_at(strings, t, tol):
    """Frequencies of every string sounding at time t."""
    out = []
    for times, freqs in strings:
        if len(times) == 0:
            continue
        i = np.searchsorted(times, t)
        for j in (i - 1, i):
            if 0 <= j < len(times) and abs(times[j] - t) <= tol:
                out.append(freqs[j])
                break
    return out


def cents(a, b):
    return 1200 * np.log2(a / b)


def frame_pitch(contour_row, threshold):
    """One frame of the contour head -> (frequency, confidence).

    The head is a posteriogram on a 33-cent grid, which is far too coarse for
    a tuner on its own; a parabolic interpolation in log-frequency across the
    peak is the fairest way to ask what it really thinks.
    """
    peak = int(np.argmax(contour_row))
    confidence = float(contour_row[peak])
    if confidence < threshold:
        return 0.0, confidence
    if 0 < peak < CONTOUR_BINS - 1:
        a, b, c = (
            float(contour_row[peak - 1]),
            float(contour_row[peak]),
            float(contour_row[peak + 1]),
        )
        denom = a - 2 * b + c
        shift = 0.5 * (a - c) / denom if denom != 0 else 0.0
        if abs(shift) > 1:
            shift = 0.0
    else:
        shift = 0.0
    return float(bin_to_frequency(peak + shift)), confidence


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="/tmp/claude-1000/nmp.onnx")
    ap.add_argument("--data", default="/mnt/storage/tuner-bench/datasets")
    ap.add_argument("--subset", default="solo")
    ap.add_argument("--limit", type=int, default=30)
    ap.add_argument("--threshold", type=float, default=0.3)
    ap.add_argument("--offset-sweep", action="store_true",
                    help="sweep the frame-time alignment and report the best")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    session = ort.InferenceSession(
        args.model, providers=["CPUExecutionProvider"]
    )
    input_name = session.get_inputs()[0].name
    # Outputs come back as (note, onset, contour) by shape, not by name.
    out_names = [o.name for o in session.get_outputs()]
    contour_index = [i for i, o in enumerate(session.get_outputs())
                     if o.shape[-1] == CONTOUR_BINS][0]

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
    print(f"files      : {len(pairs)} ({args.subset})")
    print(f"model      : {args.model} ({os.path.getsize(args.model)/1024:.0f} KB)")

    # Accumulators, mirroring MethodStats in the Dart harness.
    mono = correct = octave = gross = reported = 0
    errors = []
    voiced = voiced_reported = unvoiced = unvoiced_reported = 0
    # Accuracy by how much audio followed the frame inside its window.
    context_buckets = {}  # bucket -> [total, correct]
    infer_ms = []
    offsets = [0, 64, 128, 192, 256, 384, 512] if args.offset_sweep else [128]
    offset_hits = {o: [0, 0] for o in offsets}

    for n, (wav, jams) in enumerate(pairs, 1):
        audio, rate = read_wav_mono(wav)
        if rate != MODEL_SAMPLE_RATE:
            audio = resample_poly(audio, MODEL_SAMPLE_RATE, rate)
        strings = load_truth(jams)
        tol = 256 / 44100 / 2

        for start in range(0, len(audio) - WINDOW_SAMPLES + 1, WINDOW_SAMPLES):
            block = audio[start : start + WINDOW_SAMPLES].astype(np.float32)
            t0 = time.perf_counter()
            outputs = session.run(out_names, {input_name: block[None, :, None]})
            infer_ms.append((time.perf_counter() - t0) * 1000)
            contour = outputs[contour_index][0]  # (172, 264)

            for i in range(N_FRAMES):
                f_hat, confidence = frame_pitch(contour[i], args.threshold)
                for off in offsets:
                    t = (start + i * FRAME_HOP + off) / MODEL_SAMPLE_RATE
                    act = active_at(strings, t, tol)
                    if len(act) != 1:
                        continue
                    offset_hits[off][0] += 1
                    if f_hat > 0 and abs(cents(f_hat, act[0])) <= 50:
                        offset_hits[off][1] += 1

                # Scoring proper, at the chosen alignment.
                t = (start + i * FRAME_HOP + offsets[0] if len(offsets) == 1
                     else start + i * FRAME_HOP + 128) / MODEL_SAMPLE_RATE
                act = active_at(strings, t, tol)
                if len(act) == 0:
                    unvoiced += 1
                    if f_hat > 0:
                        unvoiced_reported += 1
                    continue
                voiced += 1
                if f_hat > 0:
                    voiced_reported += 1
                if len(act) != 1:
                    continue

                mono += 1
                if f_hat <= 0:
                    continue
                reported += 1
                err = cents(f_hat, act[0])
                right_context_ms = (N_FRAMES - 1 - i) * FRAME_HOP / MODEL_SAMPLE_RATE * 1000
                bucket = min(int(right_context_ms // 100) * 100, 1900)
                slot = context_buckets.setdefault(bucket, [0, 0])
                slot[0] += 1
                if abs(err) <= 50:
                    correct += 1
                    errors.append(err)
                    slot[1] += 1
                else:
                    octaves = err / 1200
                    if abs(octaves - round(octaves)) * 1200 <= 50 and round(octaves) != 0:
                        octave += 1
                    else:
                        gross += 1
        print(f"\r  {n}/{len(pairs)}", end="", flush=True)
    print()

    errors = np.abs(np.asarray(errors))
    pct = lambda x: 100 * x

    print()
    print(f"monophonic frames : {mono}")
    print(f"RPA               : {pct(correct/max(1,mono)):.2f}%")
    print(f"reported          : {pct(reported/max(1,mono)):.2f}%")
    print(f"octave errors     : {pct(octave/max(1,reported)):.2f}% of reported")
    print(f"gross errors      : {pct(gross/max(1,reported)):.2f}% of reported")
    if len(errors):
        print(f"|err| p50/p90/p99 : {np.percentile(errors,50):.2f} / "
              f"{np.percentile(errors,90):.2f} / {np.percentile(errors,99):.2f} cents")
        print(f"frames beyond 5c  : {pct((errors>5).mean()):.2f}%")
    print(f"voicing recall    : {pct(voiced_reported/max(1,voiced)):.2f}%")
    print(f"voicing false alarm: {pct(unvoiced_reported/max(1,unvoiced)):.2f}%")

    print()
    print(f"inference         : {np.median(infer_ms):.1f} ms per "
          f"{WINDOW_SAMPLES/MODEL_SAMPLE_RATE:.2f} s window "
          f"({np.median(infer_ms)/(WINDOW_SAMPLES/MODEL_SAMPLE_RATE*1000)*100:.1f}% of real time)")

    if args.offset_sweep:
        print()
        print("frame-time alignment sweep (fraction correct):")
        for off, (total, hit) in sorted(offset_hits.items()):
            if total:
                print(f"  +{off:4d} samples ({off/MODEL_SAMPLE_RATE*1000:5.1f} ms): "
                      f"{pct(hit/total):.2f}%")

    print()
    print("accuracy by right-context — how much audio followed the frame")
    print("inside its window. A realtime tuner only ever has the last frame:")
    for bucket in sorted(context_buckets):
        total, hit = context_buckets[bucket]
        if total < 50:
            continue
        print(f"  {bucket:4d}-{bucket+99:4d} ms after the frame: "
              f"{pct(hit/total):6.2f}%  ({total} frames)")

    if args.out:
        with open(args.out, "w") as f:
            json.dump(
                {
                    "files": len(pairs),
                    "mono": mono,
                    "correct": correct,
                    "reported": reported,
                    "octave": octave,
                    "gross": gross,
                    "voiced": voiced,
                    "voiced_reported": voiced_reported,
                    "unvoiced": unvoiced,
                    "unvoiced_reported": unvoiced_reported,
                    "median_infer_ms": float(np.median(infer_ms)),
                    "context_buckets": context_buckets,
                    "err_p50": float(np.percentile(errors, 50)) if len(errors) else None,
                    "err_p90": float(np.percentile(errors, 90)) if len(errors) else None,
                    "err_p99": float(np.percentile(errors, 99)) if len(errors) else None,
                },
                f,
            )
        print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
