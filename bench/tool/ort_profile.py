#!/usr/bin/env python3
"""Where does a transcription model's time go under native onnxruntime?

    python3 tool/ort_profile.py <model.onnx> [--threads 4] [--shape 1,256,192]

§36 rests on this. Knowing that a model spends 72% of its time in MatMul is
not enough to decide anything: what matters is whether those MatMuls carry a
*weight* matrix, because that is the difference between a model ggml can
shrink and one it cannot. So the per-op table is only half the output — the
other half reads each MatMul's operand shapes back out of ORT's own profile
and says how many of them have a batch dimension on both sides, which is the
signature of attention (Q·Kᵀ, P·V) rather than a dense layer.

Shapes come from the profile rather than from `onnx.shape_inference`, which
gives up on these graphs: the dynamic batch dimension defeats it and fixing
the dimension does not rescue the intermediates.
"""
import argparse
import collections
import json

import numpy as np
import onnx
import onnxruntime as ort


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--shape", default="",
                    help="comma-separated input shape; inferred when omitted")
    ap.add_argument("--runs", type=int, default=3)
    a = ap.parse_args()

    so = ort.SessionOptions()
    so.intra_op_num_threads = a.threads
    so.inter_op_num_threads = 1
    so.enable_profiling = True
    s = ort.InferenceSession(a.model, so, providers=["CPUExecutionProvider"])

    inp = s.get_inputs()[0]
    if a.shape:
        shape = [int(v) for v in a.shape.split(",")]
    else:
        # A symbolic dimension is a sequence length; 1 is wrong for timing, so
        # pick something long enough to be representative rather than a stub.
        shape = [d if isinstance(d, int) else (1 if i == 0 else 512)
                 for i, d in enumerate(inp.shape)]
    print(f"{inp.name} {inp.shape} -> {shape}, {a.threads} thread(s)")

    # Log-mel input: centred well below zero, because a model fed zeros can
    # take a different path through its own gates than one fed a spectrum.
    x = (np.random.randn(*shape).astype(np.float32) - 5.0)
    outs = [o.name for o in s.get_outputs()]
    s.run(outs, {inp.name: x})                       # warm
    for _ in range(a.runs):
        s.run(outs, {inp.name: x})
    events = json.load(open(s.end_profiling()))

    # ORT reports only the ACTIVATION operand's shape when the other operand
    # is an initializer, so a weight GEMM arrives with one shape where
    # attention arrives with two. That is the signal — but the missing shape
    # has to come from somewhere, so read the weights out of the model and
    # match them to nodes by name. Getting this wrong is not academic: the
    # first version of this script counted the one-shape nodes as
    # unmeasurable and concluded hFT was 100% attention, which is backwards.
    model = onnx.load(a.model, load_external_data=False)
    init = {i.name: list(i.dims) for i in model.graph.initializer}
    weight_of = {}
    for n in model.graph.node:
        if n.op_type not in ("MatMul", "FusedMatMul"):
            continue
        for name in n.input:
            if name in init:
                weight_of[n.name] = init[name]

    # The warm-up run is inside the profile too, so the number of passes is
    # counted rather than assumed: dividing by --runs overstated every
    # per-pass figure by a third the first time this was written.
    node_hits = collections.Counter(
        e["name"] for e in events
        if e.get("cat") == "Node" and e["name"].endswith("_kernel_time"))
    passes = max(node_hits.values()) if node_hits else 1

    by_op = collections.Counter()
    matmuls = collections.Counter()
    mm_flops = collections.Counter()
    mm_time = collections.Counter()
    total = 0
    for e in events:
        if e.get("cat") != "Node" or not e["name"].endswith("_kernel_time"):
            continue
        args = e["args"]
        op = args.get("op_name", "?")
        by_op[op] += e["dur"]
        total += e["dur"]
        if op not in ("MatMul", "FusedMatMul"):
            continue
        shapes = args.get("input_type_shape") or []
        if not shapes:
            continue
        dims = [[int(v) for v in list(t.values())[0]] for t in shapes]
        if len(dims) >= 2:
            A, B = dims[0], dims[1]
        else:
            node = e["name"][:-len("_kernel_time")]
            B = weight_of.get(node)
            if B is None:
                continue
            A = dims[0]
        batch = int(np.prod(A[:-2])) if len(A) > 2 else 1
        flops = 2 * batch * A[-2] * A[-1] * B[-1]
        # Both operands batched => neither is a stored weight => attention.
        kind = "attention" if len(B) > 2 else "weights"
        key = f"{A} x {B}  [{kind}]"
        matmuls[key] += 1
        mm_flops[key] += flops
        mm_time[key] += e["dur"]

    runs = passes
    print(f"{passes} profiled passes (warm-up included)")
    print(f"\ntotal kernel time {total / runs / 1e3:.0f} ms per pass\n")
    print(f"{'op':<22}{'ms/pass':>10}{'share':>8}{'nodes':>7}")
    for op, dur in by_op.most_common(14):
        print(f"{op:<22}{dur / runs / 1e3:>10.1f}{100 * dur / total:>7.1f}%"
              f"{sum(1 for e in events if e.get('cat') == 'Node' and e['name'].endswith('_kernel_time') and e['args'].get('op_name') == op) // passes:>7}")

    if not mm_flops:
        return
    gf = sum(mm_flops.values()) / runs / 1e9
    ms = sum(mm_time.values()) / runs / 1e3
    att = sum(v for k, v in mm_flops.items() if "[attention]" in k)
    print(f"\nMatMul: {gf:.2f} GFLOP per pass in {ms:.0f} ms "
          f"= {gf * 1e3 / ms:.0f} GFLOP/s effective")
    w = sum(mm_flops.values()) - att
    print(f"of which activation x activation (unquantisable): "
          f"{100 * att / max(sum(mm_flops.values()), 1):.1f}%, "
          f"weight GEMM: {w / passes / 1e9:.2f} GFLOP\n")
    print(f"{'operand shapes':<52}{'n':>4}{'GFLOP':>8}{'ms':>8}{'GFLOP/s':>9}")
    for k, f in mm_flops.most_common(10):
        print(f"{k:<52}{matmuls[k] // runs:>4}{f / runs / 1e9:>8.2f}"
              f"{mm_time[k] / runs / 1e3:>8.1f}{f / mm_time[k] * 1e6 / 1e9:>9.1f}")


if __name__ == "__main__":
    main()
