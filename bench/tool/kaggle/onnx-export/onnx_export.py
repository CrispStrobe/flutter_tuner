"""Export piano transcribers to ONNX, for the pure-Dart runtime.

REPORT.md §29 found what limits note-level transcription here: the notes are
detected (75% at a wide tolerance) but onsets on sustained instruments land
39-70 ms late, straddling the 50 ms tolerance. Piano is the one family that
does NOT lag (-12 ms), and it is 40% of MusicNet — so a model with a
dedicated high-resolution onset head is the concrete lever.

Two of those are reachable through CrispASR's GGUF registry and are measured
separately. This kernel covers the other route: models published only as
PyTorch checkpoints, exported to ONNX so `onnx_runtime_dart` can run them on
every platform the app ships to, with no native library.

That route is viable because the runtime already has the ops. Checked
against its dispatch table: Conv, ConvTranspose, GRU, LSTM,
BatchNormalization, Sigmoid, Relu, MatMul, Gemm, LayerNormalization,
Softmax, Einsum, Erf, Trilu, CumSum, TopK, ScatterND, Range, GatherND,
Expand, Tile - 128 ops in total. Kong's piano-transcription is CNN+biGRU and
Onsets & Frames is CNN+biLSTM, so neither needs a kernel that does not
exist.

Why Kaggle: exporting needs torch and the model's own code, neither of which
belongs on the shared VPS this project develops on.

Gotchas this script is written around, from ../kaggle-usage.md:
  * a CPU worker may have NO internet even with enable_internet set, so every
    download is wrapped and the script reports what it could not fetch
    instead of dying;
  * only `code_file` is uploaded, so there are no local imports;
  * re-pushing destroys the previous log, so everything worth keeping is
    printed as it happens rather than summarised at the end.
"""

import os
import sys
import traceback

OUT = "/kaggle/working"


def log(*a):
    print(*a, flush=True)


def try_export(name, fn):
    log(f"\n=== {name} ===")
    try:
        fn()
    except Exception:
        log(f"FAILED: {name}")
        traceback.print_exc()


def export_kong():
    """ByteDance / Kong high-resolution piano transcription (CNN + biGRU).

    The model whose onset head §29 says is the missing piece: it regresses a
    continuous onset time rather than picking a frame, which is exactly the
    quantity that costs us 39-70 ms on sustained attacks.
    """
    import torch
    os.system(f"{sys.executable} -m pip install -q piano_transcription_inference")
    from piano_transcription_inference import PianoTranscription
    from piano_transcription_inference.models import Regress_onset_offset_frame_velocity_CRNN

    model = Regress_onset_offset_frame_velocity_CRNN(
        frames_per_second=100, classes_num=88)
    ckpt = PianoTranscription(device="cpu").checkpoint_path
    state = torch.load(ckpt, map_location="cpu")
    model.load_state_dict(state["model"])
    model.eval()

    # One second of audio at 16 kHz. The exported graph takes a dynamic time
    # axis so a whole piece can be fed in one call.
    dummy = torch.zeros(1, 16000)
    path = f"{OUT}/kong_piano_transcription.onnx"
    torch.onnx.export(
        model, dummy, path,
        input_names=["audio"],
        output_names=["reg_onset", "reg_offset", "frame", "velocity"],
        dynamic_axes={"audio": {1: "samples"}},
        opset_version=17,
    )
    log("wrote", path, os.path.getsize(path) // 1024, "KB")


def export_onsets_and_frames():
    """Magenta Onsets & Frames (CNN + biLSTM), the classic piano baseline."""
    import torch
    os.system(f"{sys.executable} -m pip install -q onsets-and-frames")
    from onsets_and_frames import OnsetsAndFrames

    model = OnsetsAndFrames(229, 88, 48)
    model.eval()
    dummy = torch.zeros(1, 100, 229)  # mel frames
    path = f"{OUT}/onsets_and_frames.onnx"
    torch.onnx.export(
        model, dummy, path,
        input_names=["mel"],
        output_names=["onset", "offset", "frame", "velocity"],
        dynamic_axes={"mel": {1: "frames"}},
        opset_version=17,
    )
    log("wrote", path, os.path.getsize(path) // 1024, "KB")


def report_ops():
    """List every op the exported graphs use.

    The point of the whole exercise: an op the Dart runtime does not
    implement is the difference between 'import it' and 'write a kernel', and
    finding that out here costs nothing while finding it out later costs a
    debugging session.
    """
    try:
        import onnx
    except Exception:
        log("onnx not importable; skipping op report")
        return
    for f in sorted(os.listdir(OUT)):
        if not f.endswith(".onnx"):
            continue
        try:
            m = onnx.load(f"{OUT}/{f}")
            ops = sorted({n.op_type for n in m.graph.node})
            log(f"\n{f}: {len(m.graph.node)} nodes, {len(ops)} distinct ops")
            log("  ", " ".join(ops))
        except Exception:
            log(f"  could not inspect {f}")
            traceback.print_exc()


if __name__ == "__main__":
    log("python", sys.version)
    try_export("Kong piano-transcription", export_kong)
    try_export("Onsets & Frames", export_onsets_and_frames)
    report_ops()
    log("\nartifacts:", [f for f in os.listdir(OUT) if f.endswith('.onnx')])
