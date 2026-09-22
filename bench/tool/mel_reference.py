#!/usr/bin/env python3
"""Check bin/mel_check.dart's log-mel against librosa, and the resampler
against a clean tone.

    dart run bin/mel_check.dart > /tmp/dart_mel.json
    python3 tool/mel_reference.py /tmp/dart_mel.json

`torchaudio.transforms.MelSpectrogram` is what both models were trained with
and is not installed on this box; librosa reproduces it exactly given three
settings that are NOT its defaults — a periodic Hann window (it uses one),
`htk=True` mel scale (librosa defaults to Slaney's), and `norm='slaney'`
filter normalisation. Getting any one of them wrong is a silent few-percent
error that a model turns into a worse score rather than into an exception.
"""
import json
import sys

import numpy as np
import librosa


def signal(n, sr):
    x = np.empty(n)
    seed = 12345
    for i in range(n):
        seed = (1103515245 * seed + 12345) & 0x7FFFFFFF
        noise = (seed / 0x7FFFFFFF) * 2 - 1
        x[i] = (0.6 * np.sin(2 * np.pi * 440 * i / sr)
                + 0.25 * np.sin(2 * np.pi * 1234.5 * i / sr)
                + 0.01 * noise)
    return x


def mel(x, sr, n_fft, hop, n_mels, fmin, fmax, power, pad_mode):
    S = np.abs(librosa.stft(x, n_fft=n_fft, hop_length=hop, win_length=n_fft,
                            window="hann", center=True, pad_mode=pad_mode))
    S = S ** power
    fb = librosa.filters.mel(sr=sr, n_fft=n_fft, n_mels=n_mels, fmin=fmin,
                             fmax=fmax, htk=True, norm="slaney")
    return (fb @ S).T


def main(path):
    d = json.load(open(path))
    sr = 16000
    x = signal(sr * 2, sr)

    ok = True
    for name, cfg in (
        ("hft", dict(n_fft=2048, hop=256, n_mels=256, fmin=0, fmax=8000,
                     power=2.0, pad_mode="constant")),
        ("oaf", dict(n_fft=2048, hop=512, n_mels=229, fmin=30, fmax=8000,
                     power=1.0, pad_mode="reflect")),
    ):
        ref = mel(x, sr, **cfg)
        got = np.array(d[name])
        n = got.shape[0]
        assert d[f"{name}_frames"] == ref.shape[0], (
            f"{name}: frame count {d[f'{name}_frames']} != {ref.shape[0]}")
        a, b = got, ref[:n]
        # Compare in the log domain, which is what the model actually sees.
        offset = 1e-8 if name == "hft" else 1e-5
        la = np.log(np.maximum(a, 0) + offset)
        lb = np.log(np.maximum(b, 0) + offset)
        worst = np.abs(la - lb).max()
        rel = np.abs(a - b).max() / max(b.max(), 1e-12)
        print(f"{name}: {n} frames x {a.shape[1]} mels  "
              f"max |dlog| {worst:.3e}  max rel {rel:.3e}")
        if worst > 1e-3:
            ok = False
            print(f"  FAIL: {name} front end does not match librosa")

    y = np.array(d["resampled_1k"])
    t = np.arange(len(y))
    ref = np.sin(2 * np.pi * 1000 * (t + 2000) / 16000)
    # Fit amplitude/phase rather than assuming the resampler is zero-delay.
    A = np.stack([np.sin(2 * np.pi * 1000 * (t + 2000) / 16000),
                  np.cos(2 * np.pi * 1000 * (t + 2000) / 16000)], 1)
    c, *_ = np.linalg.lstsq(A, y, rcond=None)
    resid = y - A @ c
    snr = 10 * np.log10(np.sum((A @ c) ** 2) / max(np.sum(resid ** 2), 1e-30))
    print(f"resampler 44.1k->16k on a 1 kHz tone: gain "
          f"{np.hypot(*c):.4f}, SNR {snr:.1f} dB")
    if snr < 60:
        ok = False
        print("  FAIL: resampler is not clean")
    print("OK" if ok else "MISMATCH")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/dart_mel.json"))
