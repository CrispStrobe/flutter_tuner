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
    from spectro_reference import mel
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
    from spectro_reference import resample

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


def main():
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


if __name__ == "__main__":
    main()
