#!/usr/bin/env python3
"""Diff the pure-Dart pipeline against librosa + native onnxruntime.

    dart run bin/spectro_timing.dart --seconds 30 --dump /tmp/dart.json
    python3 tool/spectro_reference.py --seconds 30 --dump /tmp/ref.json
    python3 tool/spectro_compare.py /tmp/dart.json /tmp/ref.json

Both sides read the same audio, resample it with the same algorithm, build
their mel with implementations checked against each other
(`tool/mel_reference.py`), and run the same ONNX graph in two different
runtimes. What is left to disagree is the wiring — output names, window
arithmetic, the transpose into the model — and that is exactly what a wrong
number here would be made of.
"""
import json
import sys

import numpy as np


def main(dart_path, ref_path):
    d = json.load(open(dart_path))
    r = json.load(open(ref_path))
    ok = True
    # The inputs first: if these disagree nothing downstream means anything.
    for key in ("hft_window", "oaf_mel"):
        if key not in d or key not in r:
            print(f"{key}: missing on one side, skipped")
            continue
        a = np.array(d[key], dtype=np.float64)
        b = np.array(r[key], dtype=np.float64)
        if a.shape != b.shape:
            print(f"{key}: FAIL shape {a.shape} vs {b.shape}")
            ok = False
            continue
        worst = np.abs(a - b).max()
        print(f"{key}: {a.shape} max abs diff {worst:.3e}")
        if worst > 1e-3:
            ok = False
            print("  FAIL: the model is not being fed the same thing")
    for k in ("hft_frames", "oaf_frames"):
        if k in d and k in r and d[k] != r[k]:
            print(f"{k}: FAIL {d[k]} vs {r[k]}")
            ok = False

    for section, keys in (("hft_first_window", ("onset_B", "mpe_B")),
                          ("oaf_head", ("onset", "frame"))):
        if section not in d or section not in r:
            print(f"{section}: missing on one side, skipped")
            continue
        for k in keys:
            a = np.array(d[section][k], dtype=np.float64)
            b = np.array(r[section][k], dtype=np.float64)
            n = min(a.shape[0], b.shape[0])
            a, b = a[:n], b[:n]
            worst = np.abs(a - b).max()
            print(f"{section}.{k}: {a.shape} max abs diff {worst:.3e}  "
                  f"(peak activation dart {a.max():.4f} / ort {b.max():.4f})")
            if worst > 2e-3:
                ok = False
                print("  FAIL: the two pipelines do not agree")
    print("OK" if ok else "MISMATCH")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
