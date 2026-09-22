#!/usr/bin/env python3
"""Cut hFT-Transformer's ONNX graph down to the outputs a transcriber needs.

    python3 tool/prune_hft.py --in hft_transformer.onnx --out hft_transformer.pruned.onnx

The export kept all fifteen of the model's forward outputs, which is right for
verifying an export and wrong for running one. Two of them dominate:

  * `enc_vector`, [1, 128, 4, 88, 256] — 11.5 M floats, an internal encoder
    state that no decoder here reads;
  * the pedal heads, which MusicNet does not annotate.

§31's Dart run of this graph was abandoned when its RSS passed 1.4 GB, and
the note there named these outputs as the likely cause. Keeping only
`onset_B`, `offset_B`, `mpe_B` and `velocity_B` — what
`convert_label_to_note` actually consumes — lets `onnx.utils.extract_model`
drop every node that fed the rest, and turns the question of whether hFT can
run in the pure-Dart runtime into one that can be answered rather than
guessed at.

This is not a trick to make a number look better: it is what shipping the
model would do, and the A-head arm needs its own pruning if it is ever
wanted.
"""
import argparse
import os

import onnx

KEEP = ["onset_B", "offset_B", "mpe_B", "velocity_B"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src",
                    default="/mnt/storage/tuner-bench/onnx/hft_transformer.onnx")
    ap.add_argument("--out", dest="dst",
                    default="/mnt/storage/tuner-bench/onnx/hft_transformer.pruned.onnx")
    ap.add_argument("--keep", default=",".join(KEEP))
    a = ap.parse_args()
    keep = [s for s in a.keep.split(",") if s]

    m = onnx.load(a.src)
    before = [o.name for o in m.graph.output]
    print("outputs before:", before)
    missing = [k for k in keep if k not in before]
    if missing:
        raise SystemExit(f"not graph outputs: {missing}")
    onnx.utils.extract_model(a.src, a.dst, ["spec"], keep)
    p = onnx.load(a.dst)
    print("outputs after:", [o.name for o in p.graph.output])
    print(f"nodes {len(m.graph.node)} -> {len(p.graph.node)}, "
          f"size {os.path.getsize(a.src)/1e6:.1f} MB -> "
          f"{os.path.getsize(a.dst)/1e6:.1f} MB")


if __name__ == "__main__":
    main()
