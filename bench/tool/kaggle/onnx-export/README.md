# Exporting music transcribers to ONNX for `onnx_runtime_dart`

Kernel: `chr1s4/crisptuner-transcriber-onnx-export` (script `onnx_export.py`,
metadata `kernel-metadata.json`). Run on a Kaggle **CPU** worker; no GPU quota
was spent. End-to-end wall time ~4 minutes.

## Why

[`REPORT.md` §29](../../../REPORT.md) established what limits note-level
transcription here: the notes are *detected* — 75% at a wide tolerance — but
onsets on sustained instruments land 39–70 ms late, straddling the standard
50 ms tolerance. Piano is the one family that does **not** lag (−12 ms). So a
model with a dedicated high-resolution onset head is the concrete lever, and
none of the candidates publishes ONNX. Hence an export job.

`onnx_runtime_dart` is pure Dart with no FFI, so a model that imports cleanly
runs on every platform the app ships to — web and WebAssembly included — with
no native library and no per-platform build.

## The headline

**All three piano models exported, all of them verified numerically, and not
one of them uses an op `onnx_runtime_dart` lacks.** The Dart route is real.

| Model | ONNX | Params | Max abs diff vs PyTorch | Distinct ops | Missing ops |
|---|---:|---:|---:|---:|---|
| Kong / ByteDance high-res piano | **154.2 MB** | 42.95 M | **7.7e-07** | 26 | **none** |
| Onsets & Frames (PyTorch) | **106.0 MB** | 26.49 M | **7.0e-05** | 15 | **none** |
| hFT-Transformer | **22.3 MB** | 5.52 M | **1.3e-05** | 20 | **none** |
| Kong, dynamic int8 | 119.0 MB | — | 1.2e-01 *(vs float ONNX)* | 28 | **none** |

Every diff is at or near float32 round-off for a graph of this depth. The
O&F figure (7e-05) is the largest and is not an export defect — see below.

A second, stronger check: each graph was re-run at an input length **different
from the one it was traced at**, and the diff held (Kong 7.2e-07 at 6 s having
been traced at 10 s; O&F 1.7e-05 at 137 frames having been traced at 640).
That is the only real test that `dynamic_axes` did what it claims, rather than
baking the traced length into the graph.

## Per model

### 1. Kong / ByteDance high-resolution piano transcription — the one that matters

`piano_transcription_inference` on pip; checkpoint
`note_F1=0.9677_pedal_F1=0.9186.pth` pulled from Zenodo by the package itself.
The loaded object is `Note_pedal`, which wraps both the note CRNN and the pedal
CRNN, so the export covers **seven** heads at once:

```
frame_output, reg_offset_output, reg_onset_output, velocity_output,
pedal_frame_output, reg_pedal_offset_output, reg_pedal_onset_output
```

`reg_onset_output` is the reason for the whole exercise: a *continuous*
regressed onset time rather than a frame pick, which is precisely the quantity
costing us 39–70 ms in §29.

Ops (26): `Add AveragePool BatchNormalization Cast Clip Concat Constant
ConstantOfShape Conv Div GRU Gather Identity Log MatMul Mul Pad Pow Relu
Reshape Shape Sigmoid Slice Sub Transpose Unsqueeze`.

Two details worth knowing before wiring this up:

- **The log-mel front end is inside the graph.** torchlibrosa implements the
  STFT as a `Conv1d`, so the exported model takes **raw audio at 16 kHz** and
  needs no Dart-side feature extraction. This is a real advantage over the
  other two, both of which take a spectrogram and would need their front ends
  reimplemented in Dart and matched bit-for-bit.
- **One `Pad` node uses `mode=reflect`** (the STFT centring).
  `onnx_runtime_dart`'s `opPad` implements `constant`/`reflect`/`edge`
  (`lib/src/onnx_ops.dart:2764`), so this is covered — but it is the kind of
  thing that is an op-table hit and a runtime miss, which is why the kernel
  reports Pad modes separately.

Input `audio` is `[batch, samples]` with `samples` dynamic; outputs are
`[batch, frames, 88]` (or `[batch, frames, 1]` for the pedal heads) at
100 frames/s.

### 2. Onsets & Frames

Magenta's own release is TensorFlow. The PyTorch line is jongwook's port;
**ddPn08/onsets-and-frames** is a re-translation of the same Magenta model
whose model module imports nothing but `torch` and — decisively — which has
**trained weights on HuggingFace** (`ddPn08/onsets-and-frames`,
`note/01/model.pt`). `load_state_dict` matched with 0 missing and 0
unexpected, so these are real weights, not a shape-only export.

One trap had to be worked around, and it is worth recording because it would
silently ruin the export. The repo's `BiLSTM.forward` has a separate **eval**
path that walks the sequence in 512-frame chunks with in-place writes into a
preallocated buffer. Tracing that bakes the chunk boundaries *and the sequence
length* into the graph — the exact opposite of a dynamic time axis. It is
mathematically identical to running the LSTM over the whole sequence (state
carries across chunks in both directions), so the export monkeypatches the
plain full-sequence path, **and then restores the original before verifying**.
The 7e-05 diff in the table is therefore ONNX-full-sequence against
torch-chunked — it measures the substitution as well as the export, which is
why it is larger than the other two and why it is still small enough to accept.

Ops (15): `Add Concat Constant ConstantOfShape Conv Gather LSTM MatMul MaxPool
Relu Reshape Shape Slice Transpose Unsqueeze`.

Input is a **229-bin log-mel** (`sr` 16 kHz, hop 512, `fmin` 30), not audio —
a Dart-side front end is required, and any mismatch in mel filterbank
normalisation will cost accuracy silently.

### 3. hFT-Transformer — much the most interesting size/quality point

Sony's original (`sony/hFT-Transformer`) ships code but keeps its checkpoints
behind a manual download. **`ddPn08/hft-transformers-rewrite`** is the same
model with Lightning checkpoints on HF (`ddPn08/hft-transformer-rewrite`), so
that is the pair used.

> Note the repo name: `hft-transformer**s**-rewrite`, **plural**. The singular
> spelling given in the task brief 404s — and a 404 clone surfaces as
> `could not read Username for 'https://github.com'`, which reads exactly like
> a network failure and is not one. That cost one run.

The hyperparameters are not in the checkpoint, but the paper's published values
(`hid_dim=256, n_layers=3, n_heads=4, pf_dim=512, cnn_channel=4, cnn_kernel=5,
n_frame=128, n_margin=32, n_bin=256`) load with **0 missing, 0 unexpected**.

**22.3 MB for current piano SOTA** — seven times smaller than Kong. If it holds
up on our corpus that is the model to ship, and it is small enough to bundle
rather than download.

Ops (20): `Add Cast Concat Constant ConstantOfShape Conv Div Expand Gather
LayerNormalization MatMul Mul Relu Reshape Shape Slice Softmax Tile Transpose
Unsqueeze`. Note the attention is plain `MatMul`+`Softmax`+`LayerNormalization`
— no fused custom op, no `com.microsoft` domain, nothing exotic.

Two caveats:

- **It is a fixed-window model by construction.** The input is exactly
  `32 + 128 + 32 = 192` frames of a 256-bin log-mel at hop 256; positional
  embeddings are sized to that. There is no time axis to make dynamic. The
  free axis is **batch**, which is what the export uses, and a whole piece is
  transcribed by striding the window. That is a property of the model, not a
  limitation of the export — and batching the strides is arguably better for a
  Dart runtime than one long sequence.
- **Outputs are logits.** Fifteen of them (A and B branches × onset / offset /
  onpedal / offpedal / mpe / mpe_pedal / velocity, plus the encoder vector).
  Apply sigmoid on the Dart side. Two of the fifteen are large
  (`[b,128,88,128]` velocity logits, `[b,128,4,88,256]` encoder vector) — if
  you do not need them, prune them from the graph outputs and the run gets
  materially cheaper.

### 4. YourMT3 — not exported, and the brief's pointer is wrong

**`github.com/mimbres/YourMT3` contains no code.** It clones to 240 KB:
`LICENSE` and `README.md`, nothing else. The actual implementation lives in the
HF Space of the same name. That alone should change the priority.

Beyond the pointer, the blocker is structural rather than incidental:

1. The decoder is **autoregressive T5**, so inference is a loop, not a graph.
   The honest artifact is *two* graphs — `encoder.onnx`, and
   `decoder_step.onnx` taking and returning a KV cache — plus a greedy search
   written in Dart. `onnx_runtime_dart` can host that (it already has
   `lastTokenLogits` and KV-cache-shaped inputs in its API), but it is a
   project, not an export.
2. The Dart side would additionally need a tokenizer and a MIDI-event decoder
   for a 1000+ token vocabulary.

Recorded as **scoped out**, not as a failure. Do the piano models first;
revisit this only if multi-instrument becomes the requirement.

### 5. Bonus: dynamic int8 on Kong — not worth it as it stands

154 MB is a lot to ship or download, so the kernel also tries
`quantize_dynamic`. All four ops it introduces (`QuantizeLinear`,
`DequantizeLinear`, `MatMulInteger`, `ConvInteger`, plus
`DynamicQuantizeLinear`) are in the dispatch table, so this is *runnable* — but
the numbers say don't:

- **154.2 MB → 119.0 MB.** Only 23%, because `quantize_dynamic` leaves the
  `GRU` weights alone, and the biGRU is most of this model.
- **Worst output error 1.2e-01** against the float ONNX. These outputs are
  sigmoid probabilities in [0,1], so that is a 12-percentage-point absolute
  error on the frame head — far too much for onset regression, where the whole
  point is sub-frame precision.

A worthwhile size reduction for Kong would have to quantize the GRU, which
`quantize_dynamic` will not do. Better levers: **ship hFT-Transformer at
22.3 MB instead**, or prune the pedal heads out of Kong's graph if pedal is not
wanted.

## What the op survey actually proves, and what it doesn't

The survey walks every node including subgraphs, counts op types, and diffs
against the 123 public ops in `onnx_runtime_dart`'s dispatch table
(`lib/src/onnx_graph.dart`; the 8 leading-underscore entries are internal
fusion pseudo-ops no exporter emits, and are excluded). Zero misses across all
four graphs.

Be clear about the limit of that claim. "The op type is dispatched" is not
"the op is correct for these attributes". Three specific risks remain, in
descending order:

1. **Bidirectional `GRU`/`LSTM` over a dynamic sequence.** Both Kong and O&F
   depend on it. The dispatch table documents forward/reverse/bidirectional
   support, but the torch exporter emits a warning about variable-length
   bidirectional RNNs with batch > 1, and the exports here were traced at
   batch 1. **Keep batch at 1.**
2. **`Pad` with `mode=reflect`** on Kong's STFT centring — implemented, but
   exercise it.
3. **Numeric agreement between onnxruntime and `onnx_runtime_dart`.** The
   diffs in the table are torch-vs-onnxruntime. A second comparison against
   the Dart runtime is the remaining verification, and the smoke harness for
   it is described below.

## Reproducing

```bash
export KAGGLE_API_TOKEN=<chr1s4 token>      # see /mnt/volume1/kaggle-usage.md
python -m kaggle kernels push -p bench/tool/kaggle/onnx-export
python -m kaggle kernels status chr1s4/crisptuner-transcriber-onnx-export
```

Artifacts land in `/kaggle/working` and come back through
`KaggleApi().kernels_output(...)`. **The `.onnx` files are deliberately not
committed** — 400 MB of derived weights do not belong in this repo, and the
checkpoints they derive from carry their own licences.

Kernel-side notes, all of them from `/mnt/volume1/kaggle-usage.md`:

- Only `code_file` is uploaded, so the script has **no local imports** — the
  supported-op list is transcribed into the script rather than read from the
  Dart package. **If `onnx_runtime_dart`'s dispatch table changes, update
  `SUPPORTED_OPS` in `onnx_export.py`**, or the survey silently reports
  against a stale table. Regenerate it with:
  ```bash
  grep -oP "(?<=case ')[A-Za-z][A-Za-z0-9_]*(?=')" \
    ../../../../onnx_runtime_dart/lib/src/onnx_graph.dart | sort -u
  ```
- Re-pushing destroys the previous run's log, so the script prints everything
  as it happens and each failure is caught per-model rather than aborting the
  run.
- **Gotcha #3 in the usage guide is too strong.** It says CPU workers get no
  internet even with `enable_internet`. This CPU worker reached pypi, Zenodo,
  HuggingFace and GitHub in well under a second each, on both runs. The script
  probes all four in its first seconds and says so loudly either way, so a bad
  draw costs one minute rather than a session — but "CPU means no internet" is
  not a reliable rule in either direction.
- **Gotcha #16 bit on the first push:** the kernel slug comes from the
  *title*, not the `id`. `crisptuner-onnx-export` in the metadata silently
  became `crisptuner-transcriber-onnx-export`. The metadata now matches.

## Dart-side smoke test (local, not on Kaggle)

```bash
mkdir -p /tmp/onnxsmoke && cd /tmp/onnxsmoke   # any scratch dir
# pubspec.yaml with a path dependency on onnx_runtime_dart, then:
dart run bin/smoke.dart <model.onnx> <input_name> <dim> [<dim>...]
```

`bin/smoke.dart` loads the file with `OnnxModel.fromBytes`, feeds one
deterministic tensor, and prints load time, run time and every output's shape.
Graph **parsing** is fast — hFT's 22 MB loads in 1.6 s. Execution of these
graphs at realistic sizes is slow in pure Dart (§19 measured the runtime at
0.78 GMAC/s), which is a throughput question rather than a correctness one and
is the natural follow-on measurement: Kong is ~60 convolutions over 1001
frames × 229 mel bins per 10-second segment.

## Recommendation

1. **hFT-Transformer first.** 22.3 MB, 5.52 M params, current piano SOTA,
   clean op set, fixed 192-frame window that batches naturally. The front end
   (256-bin log-mel, hop 256, `sr` 16 kHz, `norm="slaney"`) has to be written
   in Dart and matched carefully — that is the real work, not the runtime.
2. **Kong as the accuracy reference and the fallback.** It is the only one of
   the three that takes **raw audio**, front end included, which removes an
   entire class of Dart-side mismatch bugs. 154 MB means downloading rather
   than bundling, and its regressed onset head is the thing §29 actually
   asked for.
3. **Onsets & Frames as the baseline**, not as a shipping candidate — 106 MB
   for the oldest architecture of the three is not a trade anyone would take.
4. **Skip YourMT3** unless multi-instrument becomes a requirement, and note
   that the GitHub repo named for it is empty.
5. **Skip int8** at the current tooling; measure the runtime cost first and
   quantize only if throughput, not size, turns out to be the binding
   constraint.
