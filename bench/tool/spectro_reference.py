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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", default="/mnt/storage/tuner-bench/datasets/"
                                     "musicnet/musicnet/test_data/2191.wav")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--hft", default="/mnt/storage/tuner-bench/onnx/hft_transformer.onnx")
    ap.add_argument("--oaf", default="/mnt/storage/tuner-bench/onnx/onsets_and_frames.onnx")
    ap.add_argument("--dump", default="")
    a = ap.parse_args()

    audio, sr = sf.read(a.wav, always_2d=True)
    audio = audio[:int(a.seconds * sr), 0]
    secs = len(audio) / sr
    t0 = time.time()
    mono = resample(audio, sr, 16000)
    print(f"{secs:.1f} s of {a.wav.split('/')[-1]}, "
          f"resample {time.time() - t0:.2f} s, ORT {a.threads} thread(s)")

    # librosa's first transform pays an import/JIT cost that is not a
    # property of the front end — 157 s on one run here, under a second
    # every time after. Warm it before anything is timed.
    mel(mono[:16000], 16000, 2048, 256, 32, 0, 8000, 2.0, "constant")

    so = ort.SessionOptions()
    so.intra_op_num_threads = a.threads
    so.inter_op_num_threads = 1
    dump = {}

    # --- hFT -------------------------------------------------------------
    t0 = time.time()
    feat = np.log(mel(mono, 16000, 2048, 256, 256, 0, 8000, 2.0, "constant") + 1e-8)
    mel_hft = time.time() - t0
    F = feat.shape[0]
    minv = math.log(1e-8)
    len_s = int(np.ceil(F / 128) * 128) - F
    padded = np.concatenate([
        np.full((32, 256), minv, np.float32),
        feat.astype(np.float32),
        np.full((len_s + 32, 256), minv, np.float32)])
    s = ort.InferenceSession(a.hft, so, providers=["CPUExecutionProvider"])
    warm = padded[0:192].T[None, :, :].astype(np.float32)
    s.run(["onset_B"], {"spec": warm})
    t0 = time.time()
    windows = 0
    first = None
    for i in range(0, F, 128):
        x = padded[i:i + 192].T[None, :, :].astype(np.float32)
        out = s.run(["onset_B", "offset_B", "mpe_B"], {"spec": x})
        if first is None:
            first = out
        windows += 1
    t_hft = time.time() - t0
    print(f"hFT: mel {mel_hft:.2f} s ({mel_hft/secs:.3f}x), "
          f"{windows} windows in {t_hft:.2f} s = {t_hft/secs:.3f}x real time, "
          f"{1000*t_hft/windows:.0f} ms/window")
    dump["hft_window"] = [padded[i:i + 192].T.tolist() for i in (0, 128)]
    dump["hft_frames"] = F
    dump["hft_first_window"] = {
        "onset_B": sigmoid(first[0][0]).tolist(),
        "mpe_B": sigmoid(first[2][0]).tolist(),
    }

    # --- Onsets & Frames -------------------------------------------------
    t0 = time.time()
    m2 = np.log(np.maximum(
        mel(mono[:-1], 16000, 2048, 512, 229, 30, 8000, 1.0, "reflect"), 1e-5))
    mel_oaf = time.time() - t0
    s2 = ort.InferenceSession(a.oaf, so, providers=["CPUExecutionProvider"])
    t0 = time.time()
    o = s2.run(["onset", "velocity"], {"mel": m2[None, :, :].astype(np.float32)})
    t_oaf = time.time() - t0
    print(f"O&F: mel {mel_oaf:.2f} s ({mel_oaf/secs:.3f}x), "
          f"{m2.shape[0]} frames in {t_oaf:.2f} s = {t_oaf/secs:.3f}x real time")
    dump["oaf_mel"] = m2[:8].tolist()
    dump["oaf_frames"] = m2.shape[0]
    dump["oaf_head"] = {
        "onset": sigmoid(o[0][0][:8]).tolist(),
        "frame": sigmoid(o[1][0][:8]).tolist(),
    }

    if a.dump:
        json.dump(dump, open(a.dump, "w"))
        print("dumped", a.dump)


if __name__ == "__main__":
    main()
