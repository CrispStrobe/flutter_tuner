#!/usr/bin/env python3
"""Run hFT / Onsets & Frames under native ONNX Runtime and cache the head
activations, so the DECODER and the METRIC stay in this repository.

    python3 tool/spectro_activations.py --model hft --out <dir> [--limit N]
    python3 tool/spectro_activations.py --model oaf --out <dir>
    dart run bin/spectro_eval.dart --acts <dir>

Why the split. Both graphs run in the pure-Dart runtime — `bin/spectro_timing.dart`
measures exactly that, and it is the number §31.2 asked for — but running the
whole 24.7-minute test split through it takes hours on a shared box, and
§32.5 already established that native ORT and PyTorch agree on the
transcription itself (5,451 of 5,451 notes). So the model runs where it is
fast; the note decoding (`lib/hft.dart`, `lib/oaf.dart`) and the scoring
(`lib/note_metrics.dart`, validated against mir_eval) stay in Dart, where the
rest of this report's numbers are made. `bin/spectro_timing.dart --dump` plus
`tool/spectro_compare.py` check that the two runtimes agree on the
activations before any of this is believed.

Format, little-endian: magic 'SPAC', uint32 version, uint32 frames,
uint32 notes, uint32 heads, then heads x frames x notes float32, with the
head order recorded in a sidecar `<id>.json`.
"""
import argparse
import json
import math
import os
import struct
import time

import numpy as np
import soundfile as sf
import onnxruntime as ort

from spectro_reference import mel, resample, sigmoid

HFT_HEADS = ["onset", "offset", "mpe", "velocity"]
OAF_HEADS = ["onset", "frame"]


def write_acts(path, heads, arrays):
    frames, notes = arrays[0].shape
    with open(path, "wb") as f:
        f.write(b"SPAC")
        f.write(struct.pack("<IIII", 1, frames, notes, len(arrays)))
        for a in arrays:
            f.write(np.ascontiguousarray(a, dtype="<f4").tobytes())
    json.dump({"heads": heads, "frames": frames, "notes": notes},
              open(path.replace(".bin", ".json"), "w"))


def run_hft(sess, mono, secs):
    feat = np.log(mel(mono, 16000, 2048, 256, 256, 0, 8000, 2.0, "constant") + 1e-8)
    F = feat.shape[0]
    minv = math.log(1e-8)
    len_s = int(np.ceil(F / 128) * 128) - F
    padded = np.concatenate([
        np.full((32, 256), minv, np.float32),
        feat.astype(np.float32),
        np.full((len_s + 32, 256), minv, np.float32)])
    total = F + len_s
    out = {h: np.zeros((total, 88), np.float32) for h in HFT_HEADS}
    t0 = time.time()
    for i in range(0, F, 128):
        x = padded[i:i + 192].T[None, :, :].astype(np.float32)
        on, off, mp, vel = sess.run(
            ["onset_B", "offset_B", "mpe_B", "velocity_B"], {"spec": x})
        n = min(128, total - i)
        out["onset"][i:i + n] = sigmoid(on[0][:n])
        out["offset"][i:i + n] = sigmoid(off[0][:n])
        out["mpe"][i:i + n] = sigmoid(mp[0][:n])
        out["velocity"][i:i + n] = vel[0][:n].argmax(-1).astype(np.float32)
    dt = time.time() - t0
    return HFT_HEADS, [out[h] for h in HFT_HEADS], dt


def run_oaf(sess, mono, secs):
    m = np.log(np.maximum(
        mel(mono[:-1], 16000, 2048, 512, 229, 30, 8000, 1.0, "reflect"), 1e-5))
    t0 = time.time()
    # Trap: `torch.onnx.export` was given four output names for five
    # outputs, so they slid by one. `velocity` IS the combined frame head.
    on, fr = sess.run(["onset", "velocity"],
                      {"mel": m[None, :, :].astype(np.float32)})
    dt = time.time() - t0
    return OAF_HEADS, [sigmoid(on[0]), sigmoid(fr[0])], dt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=["hft", "oaf"], required=True)
    ap.add_argument("--data", default="/mnt/storage/tuner-bench/datasets/musicnet")
    ap.add_argument("--onnx", default="")
    ap.add_argument("--out", default="/mnt/storage/tuner-bench/acts")
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()

    onnx = a.onnx or (
        "/mnt/storage/tuner-bench/onnx/hft_transformer.onnx" if a.model == "hft"
        else "/mnt/storage/tuner-bench/onnx/onsets_and_frames.onnx")
    so = ort.SessionOptions()
    so.intra_op_num_threads = a.threads
    so.inter_op_num_threads = 1
    sess = ort.InferenceSession(onnx, so, providers=["CPUExecutionProvider"])

    audio_dir = os.path.join(a.data, "musicnet", "test_data")
    ids = sorted(f[:-4] for f in os.listdir(audio_dir) if f.endswith(".wav"))
    if a.limit:
        ids = ids[:a.limit]
    outdir = os.path.join(a.out, a.model)
    os.makedirs(outdir, exist_ok=True)
    total_audio = total_infer = 0.0
    for pid in ids:
        audio, sr = sf.read(os.path.join(audio_dir, pid + ".wav"), always_2d=True)
        audio = audio[:, 0]
        secs = len(audio) / sr
        mono = resample(audio, sr, 16000)
        heads, arrays, dt = (run_hft if a.model == "hft" else run_oaf)(sess, mono, secs)
        write_acts(os.path.join(outdir, pid + ".bin"), heads, arrays)
        total_audio += secs
        total_infer += dt
        print(f"{pid}: {secs:.0f} s audio, {arrays[0].shape[0]} frames, "
              f"inference {dt:.1f} s ({dt/secs:.3f}x real time)", flush=True)
    print(f"\n{a.model}: {total_audio/60:.1f} min of audio, "
          f"{total_infer:.0f} s of ORT on {a.threads} thread(s) = "
          f"{total_infer/total_audio:.3f}x real time")


if __name__ == "__main__":
    main()
