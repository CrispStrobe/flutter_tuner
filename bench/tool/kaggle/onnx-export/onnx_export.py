"""Export music-transcription models to ONNX, for the pure-Dart runtime.

REPORT.md S29 found what limits note-level transcription here: the notes are
detected (75% at a wide tolerance) but onsets on sustained instruments land
39-70 ms late, straddling the 50 ms tolerance. Piano is the one family that
does NOT lag (-12 ms), and it is 40% of MusicNet - so a model with a
dedicated high-resolution onset head is the concrete lever.

This kernel covers models published only as PyTorch checkpoints, exported to
ONNX so `onnx_runtime_dart` can run them on every platform the app ships to,
with no native library.

That route is viable only if the runtime already has the ops. This script does
not assume it: SUPPORTED_OPS below is transcribed from the dispatch table in
`onnx_runtime_dart/lib/src/onnx_graph.dart`, and every exported graph is
diffed against it, node by node, with the missing ops printed loudly.

Three things are checked per model, because an export that is not checked is
worth nothing:
  1. it exports at all,
  2. onnxruntime reproduces the PyTorch outputs (max abs diff per output),
  3. it still reproduces them at a DIFFERENT input length than the one the
     graph was traced at - which is the only real test that `dynamic_axes`
     did what it claims.

Why Kaggle: exporting needs torch and each model's own code, neither of which
belongs on the shared VPS this project develops on.

Gotchas this script is written around, from kaggle-usage.md:
  * a CPU worker may have NO internet even with enable_internet set, so the
    script probes for it in the first seconds and says so loudly rather than
    failing obscurely twenty minutes in;
  * only `code_file` is uploaded, so there are no local imports;
  * re-pushing destroys the previous log, so everything worth keeping is
    printed as it happens rather than summarised at the end.
"""

import json
import os
import shutil
import subprocess
import sys
import time
import traceback

SCRIPT_VERSION = "v4"
OUT = "/kaggle/working"
WORK = "/kaggle/working"

# ---------------------------------------------------------------------------
# The onnx_runtime_dart dispatch table, transcribed from the `case '...'`
# labels in lib/src/onnx_graph.dart. Internal fusion pseudo-ops (leading
# underscore) are excluded: an exporter will never emit them.
# ---------------------------------------------------------------------------
SUPPORTED_OPS = set("""
Abs Add And ArgMax ArgMin Atan AveragePool BatchNormalization Cast Ceil Clip
Concat Constant ConstantOfShape Conv ConvInteger ConvTranspose Cos CumSum
DequantizeLinear Div Dropout DynamicQuantizeLinear Einsum Elu Equal Erf Exp
Expand Flatten Floor Gather GatherElements GatherND Gelu Gemm GlobalAveragePool
GlobalMaxPool Greater GreaterOrEqual GridSample GroupNormalization
GroupQueryAttention GRU HardSigmoid HardSwish Identity If InstanceNormalization
IsInf IsNaN LayerNormalization LeakyRelu Less LessOrEqual Log LogSoftmax Loop
LSTM MatMul MatMulInteger MatMulNBits Max MaxPool Min Mod Mul MultiHeadAttention
Neg NonMaxSuppression NonZero Not Or Pad Pow PRelu QLinearConv QLinearMatMul
QuantizeLinear RandomNormal RandomNormalLike RandomUniform Range Reciprocal
ReduceL2 ReduceMax ReduceMean ReduceMin ReduceProd ReduceSum ReduceSumSquare
Relu Reshape Resize RNN RoiAlign RotaryEmbedding Round Scan ScatterND Shape
Sigmoid Sign SimplifiedLayerNormalization Sin Size
SkipSimplifiedLayerNormalization Slice Softmax Softplus Split Sqrt Squeeze STFT
Sub Tanh Tile TopK Transpose Trilu Unsqueeze Upsample Where
""".split())

RESULTS = []


def log(*a):
    print(*a, flush=True)


def banner(s):
    log("\n" + "=" * 72)
    log(s)
    log("=" * 72)


def sh(cmd, check=False, timeout=1800):
    log(f"$ {cmd}")
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                       timeout=timeout)
    out = (r.stdout or "") + (r.stderr or "")
    tail = out.strip().splitlines()
    for line in tail[-40:]:
        log("  | " + line)
    if check and r.returncode != 0:
        raise RuntimeError(f"command failed rc={r.returncode}: {cmd}")
    return r.returncode, out


def pip(pkgs):
    return sh(f"{sys.executable} -m pip install -q --no-input {pkgs}")


# ---------------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------------

def environment_report():
    banner(f"ENVIRONMENT  (script {SCRIPT_VERSION})")
    log("python", sys.version.replace("\n", " "))
    try:
        import torch
        log("torch", torch.__version__, "cuda", torch.cuda.is_available())
    except Exception:
        log("torch NOT importable")
        traceback.print_exc()
    for mod in ("onnx", "onnxruntime", "numpy", "librosa"):
        try:
            m = __import__(mod)
            log(f"{mod} {getattr(m, '__version__', '?')}")
        except Exception:
            log(f"{mod} not installed")
    sh("df -h /kaggle/working | tail -1")
    sh("free -g | head -2")
    log("supported ops in dispatch table:", len(SUPPORTED_OPS))


def internet_probe():
    """Loud, early, cheap. A CPU worker may have no internet even with
    enable_internet set (kaggle-usage.md gotcha #3); every model here needs a
    download, so finding out now beats finding out later."""
    banner("INTERNET PROBE")
    import urllib.request
    ok = False
    for url in ("https://pypi.org/simple/", "https://zenodo.org",
                "https://huggingface.co", "https://github.com"):
        try:
            t = time.time()
            urllib.request.urlopen(url, timeout=20)
            log(f"  OK   {url}  ({time.time()-t:.1f}s)")
            ok = True
        except Exception as e:
            log(f"  FAIL {url}  {type(e).__name__}: {e}")
    if not ok:
        log("\n!!! NO INTERNET ON THIS WORKER !!!")
        log("!!! Every target here needs a download. Re-push with "
            "enable_gpu=true to draw a worker that has it. !!!")
    return ok


# ---------------------------------------------------------------------------
# op survey + numerical verification
# ---------------------------------------------------------------------------

def survey_ops(path, label):
    import onnx
    m = onnx.load(path, load_external_data=False)

    ops = {}

    def walk(graph):
        for n in graph.node:
            ops[n.op_type] = ops.get(n.op_type, 0) + 1
            for attr in n.attribute:
                if attr.HasField("g"):
                    walk(attr.g)
                for g in attr.graphs:
                    walk(g)

    walk(m.graph)
    distinct = sorted(ops)
    missing = sorted(o for o in distinct if o not in SUPPORTED_OPS)

    opsets = {i.domain or "ai.onnx": i.version for i in m.opset_import}
    total = sum(ops.values())
    log(f"\n--- ops in {label} ---")
    log(f"  nodes={total}  distinct={len(distinct)}  opsets={opsets}")
    log("  ops: " + " ".join(f"{o}x{ops[o]}" for o in distinct))
    if missing:
        log(f"  !! MISSING FROM onnx_runtime_dart ({len(missing)}): "
            + " ".join(missing))
    else:
        log("  ** all ops present in onnx_runtime_dart dispatch table **")

    # Pad with mode=reflect/edge is a common trap: the op exists but the mode
    # may not. Flag every non-constant Pad mode we emit.
    pad_modes = set()
    for n in m.graph.node:
        if n.op_type == "Pad":
            for a in n.attribute:
                if a.name == "mode":
                    pad_modes.add(a.s.decode())
    if pad_modes:
        log(f"  note: Pad modes used = {sorted(pad_modes)} "
            "(verify onnx_runtime_dart supports non-constant modes)")

    non_default_domains = [d for d in opsets if d not in ("", "ai.onnx")]
    if non_default_domains:
        log(f"  note: non-default opset domains present: {non_default_domains}")

    return {"nodes": total, "distinct": distinct, "missing": missing,
            "opsets": opsets, "pad_modes": sorted(pad_modes)}


def torch_outputs_to_list(y):
    import torch
    if isinstance(y, dict):
        return [(k, y[k]) for k in sorted(y)]
    if isinstance(y, (list, tuple)):
        return [(f"out{i}", v) for i, v in enumerate(y)]
    return [("out0", y)]


def verify(path, model, inputs, input_names, label):
    """inputs: dict name -> torch tensor. Returns list of (name, maxabsdiff)."""
    import numpy as np
    import torch
    import onnxruntime as ort

    so = ort.SessionOptions()
    so.log_severity_level = 3
    sess = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
    feed = {k: v.detach().cpu().numpy() for k, v in inputs.items()}
    got = sess.run(None, feed)
    with torch.no_grad():
        ref = torch_outputs_to_list(model(*[inputs[n] for n in input_names]))

    log(f"\n--- numeric check: {label} ---")
    if len(got) != len(ref):
        log(f"  !! output count mismatch: onnx={len(got)} torch={len(ref)}")
    diffs = []
    for i, (name, t) in enumerate(ref):
        if i >= len(got):
            break
        a = t.detach().cpu().numpy()
        b = got[i]
        if a.shape != b.shape:
            log(f"  {name}: SHAPE MISMATCH torch={a.shape} onnx={b.shape}")
            diffs.append((name, float("nan")))
            continue
        d = float(np.max(np.abs(a.astype("float64") - b.astype("float64"))))
        log(f"  {name}: shape={a.shape} max_abs_diff={d:.3e}")
        diffs.append((name, d))
    worst = max((d for _, d in diffs if d == d), default=float("nan"))
    log(f"  worst max_abs_diff = {worst:.3e}")
    return diffs, worst


def finish(name, path, model, sample_inputs, alt_inputs, input_names, notes=""):
    """Common tail: size, op survey, numeric check at traced and at a
    different length."""
    size = os.path.getsize(path)
    log(f"\nwrote {path}  {size/1e6:.1f} MB")
    ops = survey_ops(path, os.path.basename(path))
    rec = {"model": name, "file": os.path.basename(path),
           "size_mb": round(size / 1e6, 1), "ops": ops, "notes": notes}
    try:
        _, worst = verify(path, model, sample_inputs, input_names,
                          f"{name} @ traced length")
        rec["max_abs_diff_traced"] = worst
    except Exception:
        log("  verification FAILED")
        traceback.print_exc()
        rec["max_abs_diff_traced"] = None
    if alt_inputs is not None:
        try:
            _, worst = verify(path, model, alt_inputs, input_names,
                              f"{name} @ DIFFERENT length (dynamic axis test)")
            rec["max_abs_diff_dynamic"] = worst
        except Exception:
            log("  dynamic-length verification FAILED "
                "(dynamic_axes did not take)")
            traceback.print_exc()
            rec["max_abs_diff_dynamic"] = None
    RESULTS.append(rec)
    log(f"\nRESULT {json.dumps({k: v for k, v in rec.items() if k != 'ops'})}")


def export(model, args, path, input_names, output_names, dynamic_axes,
           opset=17):
    """torch.onnx.export across torch versions. Newer torch defaults to the
    dynamo exporter, which handles these models much less reliably; force the
    TorchScript path and fall back only if that argument is unknown."""
    import torch
    kw = dict(input_names=input_names, output_names=output_names,
              dynamic_axes=dynamic_axes, opset_version=opset,
              do_constant_folding=True)
    try:
        torch.onnx.export(model, args, path, dynamo=False, **kw)
    except TypeError:
        torch.onnx.export(model, args, path, **kw)
    return path


class TupleWrap:
    pass


def make_tuple_wrapper(model, keys):
    """Kong's models return dicts; torch.onnx.export is far happier with a
    module that returns a fixed-order tuple, and a fixed order is also what
    the Dart side will index by."""
    import torch

    class W(torch.nn.Module):
        def __init__(self, m, ks):
            super().__init__()
            self.m = m
            self.ks = ks

        def forward(self, x):
            y = self.m(x)
            return tuple(y[k] for k in self.ks)

    w = W(model, keys)
    w.eval()
    return w


# ---------------------------------------------------------------------------
# 1. Kong / ByteDance high-resolution piano transcription
# ---------------------------------------------------------------------------

def export_kong():
    """CNN + biGRU with a regressed, continuous onset time rather than a
    frame pick - exactly the quantity that costs us 39-70 ms on sustained
    attacks in S29."""
    import torch
    pip("piano_transcription_inference")
    import piano_transcription_inference as pti
    from piano_transcription_inference import PianoTranscription

    log("piano_transcription_inference at", os.path.dirname(pti.__file__))
    log("sample_rate", pti.sample_rate)

    t = PianoTranscription(device="cpu")
    net = t.model
    net.eval()
    log("model class:", type(net).__name__)
    n_params = sum(p.numel() for p in net.parameters())
    log(f"params: {n_params/1e6:.2f} M")

    sr = pti.sample_rate
    dummy = torch.zeros(1, sr * 10)  # Kong's own segment length
    with torch.no_grad():
        y = net(dummy)
    keys = sorted(y) if isinstance(y, dict) else None
    log("forward returned:", type(y).__name__,
        keys if keys else f"{len(y)} items")
    if keys:
        for k in keys:
            log(f"   {k}: {tuple(y[k].shape)}")
        wrapped = make_tuple_wrapper(net, keys)
        out_names = keys
    else:
        wrapped = net
        out_names = [f"out{i}" for i in range(len(y))]

    path = f"{OUT}/kong_piano_transcription.onnx"
    export(wrapped, (dummy,), path, ["audio"], out_names,
           {"audio": {1: "samples"}, **{k: {1: "frames"} for k in out_names}})

    alt = torch.zeros(1, sr * 6)
    # A non-trivial signal: zeros can hide bugs that only bite on real input.
    torch.manual_seed(0)
    sig = torch.randn(1, sr * 10) * 0.05
    alt_sig = torch.randn(1, sr * 6) * 0.05
    finish("kong_piano_transcription", path, wrapped,
           {"audio": sig}, {"audio": alt_sig}, ["audio"],
           notes=f"{n_params/1e6:.2f}M params; sr={sr}; "
                 "logmel computed inside the graph (torchlibrosa Conv1d STFT)")


# ---------------------------------------------------------------------------
# 2. Magenta Onsets & Frames
# ---------------------------------------------------------------------------

def export_onsets_and_frames():
    """CNN + biLSTM, the classic piano baseline.

    Magenta's own release is TensorFlow. The PyTorch line is jongwook's port;
    ddPn08's `onsets-and-frames` is a re-translation of the same Magenta model
    with a module that imports nothing but torch, and - decisively - with
    trained weights published on HuggingFace. So the architecture comes from
    the repo and the weights from HF, and this is a real model rather than a
    shape-only export.

    One trap has to be worked around. The repo's BiLSTM.forward has a separate
    EVAL path that walks the sequence in 512-frame chunks with in-place writes
    into a preallocated buffer. Tracing that bakes the chunk boundaries and the
    sequence length into the graph - the opposite of a dynamic time axis. It is
    mathematically the same as running the LSTM over the whole sequence (the
    state carries across chunks in both directions), so the export runs the
    plain full-sequence path, and the numeric check afterwards is made against
    the UNPATCHED chunked forward, which is what proves the substitution is
    honest rather than merely convenient.
    """
    import torch
    repo = f"{WORK}/oaf"
    if not os.path.isdir(repo):
        sh("git clone --depth 1 "
           "https://github.com/ddPn08/onsets-and-frames.git " + repo, check=True)
    sys.path.insert(0, repo)
    from modules.models import OnsetsAndFrames, BiLSTM

    model = OnsetsAndFrames(229, 88, 48)
    weights = "random-init"
    try:
        pip("huggingface_hub")
        from huggingface_hub import hf_hub_download
        f = hf_hub_download("ddPn08/onsets-and-frames", "note/01/model.pt")
        obj = torch.load(f, map_location="cpu", weights_only=False)
        sd = obj.get("state_dict", obj) if isinstance(obj, dict) else obj
        if not isinstance(sd, dict):
            model = sd
        else:
            sd = {k[6:] if k.startswith("model.") else k: v for k, v in sd.items()}
            missing, unexpected = model.load_state_dict(sd, strict=False)
            log(f"  load_state_dict: {len(missing)} missing, "
                f"{len(unexpected)} unexpected")
            if missing:
                log("  missing:", list(missing)[:10])
            if unexpected:
                log("  unexpected:", list(unexpected)[:10])
            if len(missing) > 4:
                raise RuntimeError("checkpoint does not match this architecture")
        weights = "ddPn08/onsets-and-frames note/01/model.pt"
    except Exception:
        log("  checkpoint fetch/load failed; exporting RANDOM weights "
            "(op survey still valid, numbers are not)")
        traceback.print_exc()
    log("weights:", weights)
    model.eval()
    n_params = sum(p.numel() for p in model.parameters())
    log(f"params: {n_params/1e6:.2f} M")

    torch.manual_seed(0)
    mel = torch.rand(1, 640, 229) * -5.0   # log-mel-ish range
    alt = torch.rand(1, 137, 229) * -5.0

    original_forward = BiLSTM.forward

    def flat_forward(self, x):
        return self.rnn(x)[0]

    BiLSTM.forward = flat_forward
    with torch.no_grad():
        y = model(mel)
    log("forward returned", len(y), "tensors:", [tuple(t.shape) for t in y])
    names = ["onset", "offset", "frame", "velocity"][:len(y)]
    path = f"{OUT}/onsets_and_frames.onnx"
    export(model, (mel,), path, ["mel"], names,
           {"mel": {1: "frames"}, **{n: {1: "frames"} for n in names}})
    BiLSTM.forward = original_forward   # verify against the shipped eval path

    finish("onsets_and_frames", path, model, {"mel": mel}, {"mel": alt},
           ["mel"],
           notes=f"{n_params/1e6:.2f}M params; weights = {weights}; "
                 "input is a 229-bin log-mel at hop 512 / sr 16000, NOT raw "
                 "audio - the front end must be reimplemented in Dart. "
                 "Numeric check is ONNX (full-sequence LSTM) vs torch's "
                 "chunked eval path.")


# ---------------------------------------------------------------------------
# 3. hFT-Transformer
# ---------------------------------------------------------------------------

def export_hft():
    """Hierarchical frequency-time transformer, current piano SOTA.

    Sony's original (sony/hFT-Transformer) ships code but its checkpoints are
    behind a manual download. ddPn08/hft-transformers-rewrite is the same model
    with Lightning checkpoints on HuggingFace (ddPn08/hft-transformer-rewrite),
    so that is the pair used here.

    Note the repo name: `hft-transformerS-rewrite`, plural. The singular spelt
    URL 404s, and a 404 clone surfaces as `could not read Username for
    https://github.com`, which reads exactly like a network failure and is not
    one.

    hFT is a FIXED-WINDOW model by construction - the encoder's positional
    embeddings are sized to margin_b + num_frame + margin_f = 192 frames - so
    there is no dynamic time axis to ask for here, and a whole piece is
    transcribed by striding this window. That is a property of the model, not
    a shortcoming of the export.
    """
    import torch
    repo = f"{WORK}/hft"
    if not os.path.isdir(repo):
        sh("git clone --depth 1 "
           "https://github.com/ddPn08/hft-transformers-rewrite.git " + repo,
           check=True)
    pip("pydantic")
    sys.path.insert(0, repo)
    from modules.transcriber import Transcriber, TranscriberConfig

    pip("huggingface_hub")
    from huggingface_hub import hf_hub_download, list_repo_files
    files = list_repo_files("ddPn08/hft-transformer-rewrite")
    log("checkpoint files:", files)
    ckpts = sorted(f for f in files if f.endswith(".ckpt"))
    if not ckpts:
        raise RuntimeError("no .ckpt in ddPn08/hft-transformer-rewrite")
    # highest epoch = most trained
    pick = max(ckpts, key=lambda f: int(f.split("epoch=")[1].split("-")[0]))
    log("using", pick)
    f = hf_hub_download("ddPn08/hft-transformer-rewrite", pick)
    log("ckpt size", os.path.getsize(f) / 1e6, "MB")
    obj = torch.load(f, map_location="cpu", weights_only=False)
    log("ckpt top-level keys:", list(obj)[:20] if isinstance(obj, dict) else type(obj))
    if isinstance(obj, dict) and "hyper_parameters" in obj:
        log("hyper_parameters:", json.dumps(obj["hyper_parameters"], default=str)[:3000])
    sd = obj["state_dict"] if isinstance(obj, dict) and "state_dict" in obj else obj
    sd = {k[6:] if k.startswith("model.") else k: v for k, v in sd.items()}
    log("state_dict: %d tensors" % len(sd))
    for k in list(sd)[:60]:
        log(f"   {k}: {tuple(sd[k].shape)}")

    # Derive what can be derived; the rest are the paper's published values.
    cfg = dict(n_frame=128, n_bin=256, cnn_channel=4, cnn_kernel=5,
               hid_dim=256, n_margin=32, n_layers=3, n_heads=4, pf_dim=512,
               dropout=0.1, n_velocity=128, n_note=88)
    for k, v in sd.items():
        if k.endswith("encoder.conv.weight") or k.endswith("cnn.weight"):
            cfg["cnn_channel"], _, _, cfg["cnn_kernel"] = (
                v.shape[0], v.shape[1], v.shape[2], v.shape[-1])
            log(f"derived cnn_channel={cfg['cnn_channel']} "
                f"cnn_kernel={cfg['cnn_kernel']} from {k} {tuple(v.shape)}")
    for k, v in sd.items():
        if "pos_embedding" in k or "positional" in k:
            log(f"positional {k}: {tuple(v.shape)}")
    log("config guess:", cfg)

    model = Transcriber(TranscriberConfig(**cfg))
    missing, unexpected = model.load_state_dict(sd, strict=False)
    log(f"load_state_dict: {len(missing)} missing, {len(unexpected)} unexpected")
    if missing:
        log("  missing:", list(missing)[:20])
    if unexpected:
        log("  unexpected:", list(unexpected)[:20])
    if missing or unexpected:
        raise RuntimeError(
            "hyperparameter guess does not match the checkpoint. The shapes "
            "printed above say exactly which dimension is wrong; fix cfg and "
            "re-push rather than exporting a half-loaded model.")
    model.eval()
    n_params = sum(p.numel() for p in model.parameters())
    log(f"params: {n_params/1e6:.2f} M")

    n_in = cfg["n_margin"] * 2 + cfg["n_frame"]
    torch.manual_seed(0)
    spec = torch.randn(1, cfg["n_bin"], n_in)
    with torch.no_grad():
        y = model(spec)
    log("forward returned", len(y), "tensors:", [tuple(t.shape) for t in y])
    names = ["onset_A", "offset_A", "onpedal_A", "offpedal_A", "mpe_A",
             "mpe_pedal_A", "velocity_A", "enc_vector",
             "onset_B", "offset_B", "onpedal_B", "offpedal_B", "mpe_B",
             "mpe_pedal_B", "velocity_B"][:len(y)]
    path = f"{OUT}/hft_transformer.onnx"
    # batch is the only free axis; the time window is architectural.
    export(model, (spec,), path, ["spec"], names,
           {"spec": {0: "batch"}, **{n: {0: "batch"} for n in names}})
    alt = torch.randn(3, cfg["n_bin"], n_in)
    finish("hft_transformer", path, model, {"spec": spec}, {"spec": alt},
           ["spec"],
           notes=f"{n_params/1e6:.2f}M params; ckpt {pick}; input is a "
                 f"256-bin log-mel window of exactly {n_in} frames "
                 f"({cfg['n_margin']}+{cfg['n_frame']}+{cfg['n_margin']}) at "
                 "hop 256 / sr 16000; FIXED time window by construction, "
                 "dynamic axis is batch. Outputs are LOGITS (apply sigmoid).")


# ---------------------------------------------------------------------------
# 4. YourMT3
# ---------------------------------------------------------------------------

def export_yourmt3():
    """Multi-instrument, the natural MT3 successor.

    Surveyed rather than assumed. The blocker is structural, not a bug: the
    decoder is autoregressive T5, so a single ONNX graph cannot express
    inference. A usable artifact is two graphs - encoder, and one decoder step
    taking and returning a KV cache - plus a greedy loop written in Dart. This
    function establishes whether the ENCODER alone exports, which is the
    expensive half and the half that decides whether the rest is worth doing.
    """
    repo = f"{WORK}/ymt3"
    if not os.path.isdir(repo):
        sh("git clone --depth 1 https://github.com/mimbres/YourMT3.git " + repo,
           check=True)
    sh(f"du -sh {repo}")
    sh(f"cat {repo}/requirements.txt 2>/dev/null | head -60")
    sh(f"find {repo} -name 'requirements*.txt' -o -name 'setup.py' "
       f"-o -name 'pyproject.toml' | head")
    sh(f"ls {repo}")
    raise RuntimeError(
        "YourMT3 not exported. Two reasons, both structural rather than "
        "incidental: (a) the decoder is autoregressive T5, so inference is a "
        "loop and not a graph - the honest artifact is encoder.onnx plus "
        "decoder_step.onnx with KV cache in/out plus a Dart-side greedy "
        "search; (b) its dependency set (nnAudio, einops, transformers, "
        "pytorch-lightning, mirdata) and its 1000+ token vocabulary mean the "
        "Dart side needs a tokenizer and an event decoder as well as a "
        "runtime. That is a project. The listing above is the scoping "
        "evidence, and this is recorded as SCOPED OUT, not as a failure.")


# ---------------------------------------------------------------------------
# 5. bonus: does int8 dynamic quantisation survive?
# ---------------------------------------------------------------------------

def quantize_kong():
    """154 MB is a lot to ship or download. Dynamic int8 quantisation emits
    QuantizeLinear / DequantizeLinear / MatMulInteger / ConvInteger, and all
    four ARE in the Dart dispatch table - so the size question is answerable
    here rather than deferred. What matters is whether the accuracy survives:
    a GRU acoustic model is not obviously robust to this."""
    import torch
    src = f"{OUT}/kong_piano_transcription.onnx"
    if not os.path.exists(src):
        raise RuntimeError("Kong export missing; nothing to quantise")
    pip("onnxruntime")
    from onnxruntime.quantization import quantize_dynamic, QuantType
    dst = f"{OUT}/kong_piano_transcription.int8.onnx"
    quantize_dynamic(src, dst, weight_type=QuantType.QInt8)
    size = os.path.getsize(dst)
    log(f"int8: {size/1e6:.1f} MB "
        f"(vs {os.path.getsize(src)/1e6:.1f} MB float32)")
    ops = survey_ops(dst, "kong_piano_transcription.int8.onnx")

    # Accuracy against the FLOAT ONNX, which is the thing it replaces.
    import numpy as np
    import onnxruntime as ort
    torch.manual_seed(1)
    sig = (torch.randn(1, 16000 * 10) * 0.05).numpy()
    so = ort.SessionOptions()
    so.log_severity_level = 3
    a = ort.InferenceSession(src, so, providers=["CPUExecutionProvider"]).run(
        None, {"audio": sig})
    b = ort.InferenceSession(dst, so, providers=["CPUExecutionProvider"]).run(
        None, {"audio": sig})
    log("\n--- int8 vs float32 ONNX ---")
    worst = 0.0
    for i, (x, y) in enumerate(zip(a, b)):
        d = float(np.max(np.abs(x.astype("float64") - y.astype("float64"))))
        log(f"  out{i}: max_abs_diff={d:.3e}")
        worst = max(worst, d)
    log(f"  worst = {worst:.3e}")
    RESULTS.append({"model": "kong_piano_transcription_int8",
                    "file": os.path.basename(dst),
                    "size_mb": round(size / 1e6, 1), "ops": ops,
                    "max_abs_diff_traced": worst,
                    "max_abs_diff_dynamic": None,
                    "notes": "dynamic int8 weights; diff is against the "
                             "float32 ONNX, not against torch. Sigmoid "
                             "outputs are in [0,1], so read the diff as an "
                             "absolute probability error."})


# ---------------------------------------------------------------------------

def main():
    environment_report()
    have_net = internet_probe()
    if not have_net:
        log("\nABORTING EARLY - nothing here can run without internet.")
        json.dump({"error": "no internet on worker"},
                  open(f"{OUT}/results.json", "w"), indent=2)
        return

    pip("onnx onnxruntime")

    targets = [
        ("1. Kong / ByteDance piano transcription", export_kong),
        ("2. Magenta Onsets & Frames (PyTorch port)", export_onsets_and_frames),
        ("3. hFT-Transformer", export_hft),
        ("4. YourMT3", export_yourmt3),
        ("5. Kong int8 quantisation", quantize_kong),
    ]
    failures = []
    for name, fn in targets:
        banner(name)
        t0 = time.time()
        try:
            fn()
            log(f"\n[{name}] OK in {time.time()-t0:.0f}s")
        except Exception as e:
            log(f"\n[{name}] FAILED after {time.time()-t0:.0f}s")
            traceback.print_exc()
            failures.append({"model": name, "error": f"{type(e).__name__}: {e}"})

    banner("SUMMARY")
    for r in RESULTS:
        log(f"\n{r['model']}  {r['size_mb']} MB")
        log(f"  traced-length max_abs_diff : {r.get('max_abs_diff_traced')}")
        log(f"  dynamic-length max_abs_diff: {r.get('max_abs_diff_dynamic')}")
        log(f"  distinct ops ({len(r['ops']['distinct'])}): "
            + " ".join(r["ops"]["distinct"]))
        miss = r["ops"]["missing"]
        log(f"  UNSUPPORTED BY onnx_runtime_dart: "
            + (" ".join(miss) if miss else "NONE"))
        log(f"  notes: {r['notes']}")
    for f in failures:
        log(f"\nFAILED {f['model']}: {f['error']}")

    json.dump({"script_version": SCRIPT_VERSION, "results": RESULTS,
               "failures": failures},
              open(f"{OUT}/results.json", "w"), indent=2)

    # Keep the working dir to just the artifacts we want back.
    for d in ("oaf", "hft", "ymt3"):
        shutil.rmtree(f"{WORK}/{d}", ignore_errors=True)
    for p in ("oaf.pt",):
        if os.path.exists(f"{WORK}/{p}"):
            os.remove(f"{WORK}/{p}")
    sh(f"ls -la {OUT}")


if __name__ == "__main__":
    main()
