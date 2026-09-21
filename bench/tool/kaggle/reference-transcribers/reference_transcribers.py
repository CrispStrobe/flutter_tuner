#!/usr/bin/env python3
"""Reference transcribers vs MusicNet's test split, scored by `mir_eval`.

`bench/REPORT.md` §30 reports **44.0% note-level F1** for Spotify Basic Pitch
on MusicNet's test split, produced by a pure-Dart port of Spotify's
`note_creation.py` decoding a pure-Dart ONNX run of the same model. Getting
there took fixing two clock bugs that had the same pipeline at 8.0%, which is
exactly the history that makes 44.0% untrustworthy on its own: it could be
"the model on this corpus", or it could be a third bug of the same family.

A port cannot validate itself. The only thing that settles it is the
**official implementation, on the same audio, with the same metric** — which
is what this kernel is. Three things come out of it:

1.  Reference note-level F1, per piece and aggregate, with and without the
    offset condition. If the reference lands near 44%, §30 is a model result.
    If it lands near 70%, our port still has a defect.
2.  Whether the per-instrument onset lag of §29.2 reproduces — piano at
    −12 ms, bowed and blown instruments at +39…+70 ms, straddling the 50 ms
    tolerance. That finding drives the whole "what would actually improve it"
    section, and it has only ever been measured through our own decoder.
3.  A free audit of `bench/lib/note_metrics.dart`, which re-implements
    `mir_eval.transcription`'s matching rules by hand. The same matcher is
    re-implemented here in Python, run on the *same* reference/estimate
    arrays as `mir_eval`, and any disagreement is printed.

Corpus: MusicNet (Zenodo 5120004, CC BY 4.0). Ten test recordings, 13,589
annotated notes. The archive is one 11 GB gzip stream, so the ~205 MB of
`test_data/` and `test_labels/` **cannot be seeked to** — the stream is read
until both directories are complete, then abandoned.

Operational notes (see /mnt/volume1/kaggle-usage.md):

  * Only `code_file` is uploaded, so this file has no local imports.
  * A worker can land without internet even with `enable_internet` set. That
    is fatal here, so it is checked in the first seconds and the run exits
    with a loud marker rather than burning the session.
  * Re-pushing destroys the previous run's log, so everything prints as it
    goes and every partial result is written to /kaggle/working as JSON.
  * Each model runs as a **child process** of this same script, so one
    model segfaulting or OOMing does not take the run with it, and each
    model's `pip install` cannot break the model that already ran. Scoring
    happens immediately after each child, before the next install.
"""

import json
import os
import subprocess
import sys
import time
import urllib.request

SCRIPT_VERSION = "reference-transcribers v5"

WORK = "/kaggle/working"
DATA = os.path.join(WORK, "musicnet")
AUDIO_DIR = os.path.join(DATA, "test_data")
LABEL_DIR = os.path.join(DATA, "test_labels")

ZENODO_RECORD = "5120004"
MUSICNET_RATE = 44100  # label times are SAMPLE INDICES at this rate, not seconds

ONSET_TOL_S = 0.050
PITCH_TOL_CENTS = 50.0
OFFSET_RATIO = 0.2
OFFSET_MIN_TOL_S = 0.050

# A deliberately wide tolerance, used only to measure the onset *lag*. At the
# strict 50 ms the error distribution is truncated at ±50 ms by construction,
# so a median computed there cannot show a +70 ms bias even when one exists.
WIDE_ONSET_TOL_S = 0.500

# MusicNet's `instrument` column is a General MIDI program number.
GM = {
    1: "piano", 7: "harpsichord", 41: "violin", 42: "viola", 43: "cello",
    44: "contrabass", 61: "horn", 69: "oboe", 71: "bassoon", 72: "clarinet",
    74: "flute",
}


def log(*a):
    print(*a, flush=True)


def sh(cmd, check=True, timeout=None):
    log(f"$ {cmd}")
    return subprocess.run(cmd, shell=True, check=check, timeout=timeout)


# ---------------------------------------------------------------------------
# corpus
# ---------------------------------------------------------------------------

def require_internet():
    for host in ("https://zenodo.org", "https://pypi.org"):
        try:
            urllib.request.urlopen(host, timeout=30).close()
        except Exception as exc:  # noqa: BLE001
            log(f"NO_INTERNET_RETRY_WITH_GPU  ({host}: {exc})")
            log("A Kaggle CPU worker frequently has no egress even with "
                "enable_internet set. Re-push with enable_gpu=true.")
            raise SystemExit(0)
    log("internet ok")


class _Counting:
    """Wrap the HTTP stream so 11 GB of download is visible in the log."""

    def __init__(self, fh, total):
        self.fh, self.total, self.n, self.t0, self.last = fh, total, 0, time.time(), 0

    def read(self, size=-1):
        b = self.fh.read(size)
        self.n += len(b)
        if self.n - self.last > 256 * 1024 * 1024:
            self.last = self.n
            mb, el = self.n / 1e6, time.time() - self.t0
            log(f"  ... {mb:8.0f} MB / {self.total/1e6:.0f} MB  "
                f"({mb/max(el,1):.1f} MB/s, {el/60:.1f} min)")
        return b


def fetch_musicnet():
    import tarfile

    if (os.path.isdir(AUDIO_DIR) and len(os.listdir(AUDIO_DIR)) >= 10
            and os.path.isdir(LABEL_DIR) and len(os.listdir(LABEL_DIR)) >= 10):
        log("musicnet test split already present")
        return

    meta = json.load(urllib.request.urlopen(
        f"https://zenodo.org/api/records/{ZENODO_RECORD}", timeout=60))
    log(f"zenodo record {ZENODO_RECORD}: {meta['metadata']['title']}")
    entry = None
    for f in meta["files"]:
        log(f"  file {f['key']}  {f['size']/1e9:.2f} GB")
        if f["key"] == "musicnet.tar.gz":
            entry = f
    if entry is None:
        raise SystemExit("musicnet.tar.gz not found in the Zenodo record")
    url = entry.get("links", {}).get("self") or (
        f"https://zenodo.org/records/{ZENODO_RECORD}/files/musicnet.tar.gz?download=1")

    os.makedirs(DATA, exist_ok=True)
    log(f"streaming {url}")
    log("(gzip stream: the test members cannot be seeked to, so the archive "
        "is read from the start until both test directories are complete)")

    wav = csv = 0
    t0 = time.time()
    resp = urllib.request.urlopen(url, timeout=120)
    with tarfile.open(fileobj=_Counting(resp, entry["size"]), mode="r|gz") as tf:
        for member in tf:
            name = member.name
            if not member.isfile():
                continue
            if "/test_data/" in name and name.endswith(".wav"):
                out, wav = AUDIO_DIR, wav + 1
            elif "/test_labels/" in name and name.endswith(".csv"):
                out, csv = LABEL_DIR, csv + 1
            else:
                continue
            os.makedirs(out, exist_ok=True)
            src = tf.extractfile(member)
            with open(os.path.join(out, os.path.basename(name)), "wb") as fh:
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    fh.write(chunk)
            log(f"  extracted {os.path.basename(name)} "
                f"({member.size/1e6:.1f} MB)  [wav {wav}, csv {csv}]")
            if wav >= 10 and csv >= 10:
                log("both test directories complete — abandoning the stream")
                break
    resp.close()
    log(f"corpus ready in {(time.time()-t0)/60:.1f} min")


def read_labels(path):
    """`start_time,end_time,instrument,note,start_beat,end_beat,note_value`.

    The times are **sample indices at 44100 Hz**. Treating them as seconds
    scales every onset by 44100 and still produces a plausible-looking table,
    which is the shape of bug this whole kernel exists to rule out.
    """
    notes, instruments = [], set()
    with open(path) as fh:
        lines = fh.read().splitlines()
    for line in lines[1:]:
        f = line.strip().split(",")
        if len(f) < 4:
            continue
        try:
            start, end, instrument, midi = (int(f[0]), int(f[1]),
                                            int(f[2]), int(f[3]))
        except ValueError:
            continue
        instruments.add(instrument)
        notes.append((start / MUSICNET_RATE, end / MUSICNET_RATE, float(midi)))
    notes.sort()
    return notes, sorted(instruments)


def _wav_seconds(path):
    import wave
    with wave.open(path, "rb") as w:
        return w.getnframes() / w.getframerate()


def load_pieces():
    pieces = []
    for f in sorted(os.listdir(AUDIO_DIR)):
        if not f.endswith(".wav"):
            continue
        pid = f[:-4]
        lab = os.path.join(LABEL_DIR, pid + ".csv")
        if not os.path.exists(lab):
            continue
        notes, instruments = read_labels(lab)
        pieces.append({
            "id": pid,
            "audio": os.path.join(AUDIO_DIR, f),
            "audio_sec": _wav_seconds(os.path.join(AUDIO_DIR, f)),
            "notes": notes,
            "instruments": instruments,
            "instrument_names": [GM.get(i, f"program{i}") for i in instruments],
        })
    return pieces


# ---------------------------------------------------------------------------
# the model children
# ---------------------------------------------------------------------------

def run_basic_pitch(pieces, out_path):
    """Spotify Basic Pitch, official code. The direct comparison to §30.

    The model is pinned to the packaged **`nmp.onnx`**, not left to
    `basic_pitch.__init__`'s try-import chain. Two reasons, and the second is
    the important one:

      * that chain prefers TensorFlow whenever it imports, and the whole
        point of installing this package `--no-deps` is to avoid dragging
        Kaggle's TensorFlow down to the `<2.15.1` the wheel pins;
      * `nmp.onnx` is *the same file* our Dart pipeline runs. Pinning it
        means any gap that shows up is decoding, not two different exports
        of the weights — which is precisely the question §30 leaves open.
    """
    import basic_pitch
    from basic_pitch.inference import predict

    pkg = os.path.dirname(basic_pitch.__file__)
    MODEL = None
    for cand in (os.path.join(pkg, "saved_models", "icassp_2022", "nmp.onnx"),):
        if os.path.exists(cand):
            MODEL = cand
    if MODEL is None:
        try:
            from basic_pitch import ICASSP_2022_MODEL_PATH as MODEL
            log("nmp.onnx not found in the wheel; falling back to the "
                "package's own default model path")
        except Exception as exc:  # noqa: BLE001
            raise SystemExit(f"no basic-pitch model available: {exc}")
    log(f"basic-pitch {getattr(basic_pitch, '__version__', '?')} "
        f"model: {MODEL}")

    log(f"onnxruntime threads: default, os.cpu_count()={os.cpu_count()}")
    preds, timing = {}, {}
    for i, p in enumerate(pieces, 1):
        t0 = time.time()
        _, _, events = predict(p["audio"], model_or_model_path=MODEL)
        wall = time.time() - t0
        # (start_s, end_s, pitch_midi, amplitude, pitch_bends)
        preds[p["id"]] = [[float(e[0]), float(e[1]), float(e[2])]
                          for e in events]
        timing[p["id"]] = {"audio_sec": p["audio_sec"], "infer_sec": wall}
        log(f"  [{i}/{len(pieces)}] {p['id']}: {len(events)} notes "
            f"(ref {len(p['notes'])})  {p['audio_sec']:.0f}s audio in "
            f"{wall:.0f}s  =>  {wall/p['audio_sec']:.3f}x real time")
        json.dump(preds, open(out_path, "w"))
        json.dump(timing, open(out_path.replace("preds_", "timing_"), "w"))


def run_kong(pieces, out_path):
    """ByteDance / Kong high-resolution piano transcription. Piano only."""
    import torch

    # Two things the package does that a Kaggle worker will not tolerate.
    #
    # 1. It fetches its 165 MB checkpoint with `os.system("wget ...")` and
    #    does not check the result, so a worker without wget gets a silent
    #    zero-byte file and a confusing `torch.load` failure. Fetch it here
    #    instead, visibly.
    # 2. `torch.load` defaults to `weights_only=True` from torch 2.6, and
    #    this checkpoint predates that by years. The file is the published
    #    Zenodo artefact, so loading it fully is the intended behaviour, but
    #    it has to be asked for.
    ckpt_dir = os.path.expanduser("~/piano_transcription_inference_data")
    ckpt = os.path.join(ckpt_dir, "note_F1=0.9677_pedal_F1=0.9186.pth")
    if not os.path.exists(ckpt) or os.path.getsize(ckpt) < 1.6e8:
        os.makedirs(ckpt_dir, exist_ok=True)
        url = ("https://zenodo.org/record/4034264/files/"
               "CRNN_note_F1%3D0.9677_pedal_F1%3D0.9186.pth?download=1")
        log(f"fetching Kong checkpoint (~165 MB) from {url}")
        urllib.request.urlretrieve(url, ckpt)
        log(f"  {os.path.getsize(ckpt)/1e6:.1f} MB")

    _torch_load = torch.load

    def _load(*a, **kw):
        kw.setdefault("weights_only", False)
        return _torch_load(*a, **kw)

    torch.load = _load

    # 3. Its own `load_audio` calls `librosa.core.audio.util.buf_to_float`,
    #    a path librosa's lazy loader no longer exposes
    #    (`AttributeError: No librosa.core attribute audio`). `librosa.load`
    #    does the same job — mono, resampled to the model's 16 kHz — so call
    #    that directly rather than pinning librosa backwards.
    import librosa
    from piano_transcription_inference import PianoTranscription, sample_rate

    device = "cpu"
    if torch.cuda.is_available():
        cap = torch.cuda.get_device_capability()
        # Kaggle's preinstalled torch has dropped sm_60; a P100 draw would die
        # with "no kernel image is available" *after* loading the model.
        if cap[0] * 10 + cap[1] >= 70:
            device = "cuda"
        else:
            log(f"  GPU is sm_{cap[0]}{cap[1]}, unsupported by this torch — CPU")
    log(f"kong device: {device}")

    log(f"torch threads {torch.get_num_threads()}, "
        f"os.cpu_count()={os.cpu_count()}")
    tr = PianoTranscription(device=device, checkpoint_path=ckpt)
    preds, timing = {}, {}
    for i, p in enumerate(pieces, 1):
        audio, _ = librosa.load(p["audio"], sr=sample_rate, mono=True)
        t0 = time.time()
        out = tr.transcribe(audio, None)
        wall = time.time() - t0
        ev = out["est_note_events"]
        preds[p["id"]] = [[float(e["onset_time"]), float(e["offset_time"]),
                           float(e["midi_note"])] for e in ev]
        timing[p["id"]] = {"audio_sec": p["audio_sec"], "infer_sec": wall}
        log(f"  [{i}/{len(pieces)}] {p['id']}: {len(ev)} notes "
            f"(ref {len(p['notes'])})  {p['audio_sec']:.0f}s audio in "
            f"{wall:.0f}s  =>  {wall/p['audio_sec']:.2f}x real time")
        json.dump(preds, open(out_path, "w"))
        json.dump(timing, open(out_path.replace("preds_", "timing_"), "w"))


# ---------------------------------------------------------------------------
# the same weights under native ONNX Runtime
# ---------------------------------------------------------------------------
#
# The Dart runtime measures ~96x real time for Kong — 96 seconds of CPU per
# second of audio — so that path cannot ship these models whatever their
# accuracy. Native ONNX Runtime is the runtime that could. Nobody has
# measured what it costs, and that number, not op compatibility, decides
# whether a native-ORT backend is worth building.
#
# Kong is the one of the three exports that can be scored rather than only
# timed: its graph takes **raw 16 kHz audio**, with the log-mel front end
# (torchlibrosa's Conv1d STFT) inside the graph, and its outputs are named
# exactly as the PyTorch model's dict keys. So the official segmentation and
# the official `RegressionPostProcessor` can be reused verbatim and only the
# forward pass swapped. Anything that differs is then the runtime.
#
# Onsets & Frames and HFT Transformer take *features*, not audio — a 229-bin
# log-mel at hop 512 and a 256-bin log-mel in fixed 192-frame windows. Their
# front ends and note decoders would have to be reimplemented, and an
# unverified reimplementation is exactly the failure mode this kernel exists
# to rule out. They are therefore **timed and not scored**, which is the
# half of the question that actually decides the backend.

ONNX_MOUNTS = (
    "/kaggle/input/crisptuner-transcriber-onnx",
    "/kaggle/input/datasets/chr1s4/crisptuner-transcriber-onnx",
)

# Kong transcribes piano. On the six pieces with no piano in them its output
# is not a transcription of anything, so the arms that exist to compare
# runtimes run on the four pieces that contain piano.
KONG_PIECES = ("1759", "2303", "2556", "2628")

KONG_SEGMENT_SAMPLES = 16000 * 10


def find_onnx(name):
    for d in ONNX_MOUNTS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    return None


def _enframe(x, segment_samples):
    """Verbatim from `PianoTranscription.enframe` — 50% overlapping 10 s
    segments. Copied rather than called so the ORT arm needs no torch."""
    assert x.shape[1] % segment_samples == 0
    batch, pointer = [], 0
    while pointer + segment_samples <= x.shape[1]:
        batch.append(x[:, pointer:pointer + segment_samples])
        pointer += segment_samples // 2
    import numpy as np
    return np.concatenate(batch, axis=0)


def _deframe(x):
    """Verbatim from `PianoTranscription.deframe` — drops the extra frame
    each segment gains from `center=True`, then keeps each segment's middle
    half."""
    import numpy as np
    if x.shape[0] == 1:
        return x[0]
    x = x[:, 0:-1, :]
    (n, seg, _) = x.shape
    assert seg % 4 == 0
    y = [x[0, 0:int(seg * 0.75)]]
    for i in range(1, n - 1):
        y.append(x[i, int(seg * 0.25):int(seg * 0.75)])
    y.append(x[-1, int(seg * 0.25):])
    return np.concatenate(y, axis=0)


def _ort_session(path, threads):
    import onnxruntime as ort
    so = ort.SessionOptions()
    if threads:
        so.intra_op_num_threads = threads
        so.inter_op_num_threads = 1
    return ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])


def _run_kong_onnx(pieces, out_path, model_file):
    import librosa
    import numpy as np
    from piano_transcription_inference import config
    from piano_transcription_inference.utilities import RegressionPostProcessor

    path = find_onnx(model_file)
    if path is None:
        raise SystemExit(f"{model_file} not found in {ONNX_MOUNTS}")
    threads = int(os.environ.get("ORT_THREADS", "0"))
    sess = _ort_session(path, threads)
    names = [o.name for o in sess.get_outputs()]
    inp = sess.get_inputs()[0].name
    log(f"{model_file}: {os.path.getsize(path)/1e6:.0f} MB, "
        f"intra_op_num_threads={threads or 'default'}, "
        f"os.cpu_count()={os.cpu_count()}, outputs={names}")

    preds, timing = {}, {}
    for i, p in enumerate(pieces, 1):
        audio, _ = librosa.load(p["audio"], sr=16000, mono=True)
        audio_sec = len(audio) / 16000
        audio = audio[None, :]
        n = audio.shape[1]
        pad = int(np.ceil(n / KONG_SEGMENT_SAMPLES)) * KONG_SEGMENT_SAMPLES - n
        audio = np.concatenate((audio, np.zeros((1, pad))), axis=1)
        segments = _enframe(audio, KONG_SEGMENT_SAMPLES).astype(np.float32)

        t0 = time.time()
        acc = {k: [] for k in names}
        for s in range(segments.shape[0]):
            out = sess.run(names, {inp: segments[s:s + 1]})
            for k, v in zip(names, out):
                acc[k].append(v)
        infer = time.time() - t0

        od = {k: _deframe(np.concatenate(v, axis=0))[0:n]
              for k, v in acc.items()}
        post = RegressionPostProcessor(
            config.frames_per_second, classes_num=config.classes_num,
            onset_threshold=0.3, offset_threshold=0.3, frame_threshold=0.1,
            pedal_offset_threshold=0.2)
        ev, _pedal = post.output_dict_to_midi_events(od)
        preds[p["id"]] = [[float(e["onset_time"]), float(e["offset_time"]),
                           float(e["midi_note"])] for e in ev]
        timing[p["id"]] = {"audio_sec": audio_sec, "infer_sec": infer,
                           "segments": int(segments.shape[0])}
        log(f"  [{i}/{len(pieces)}] {p['id']}: {len(ev)} notes "
            f"(ref {len(p['notes'])})  {audio_sec:.0f}s audio in "
            f"{infer:.0f}s  =>  {infer/audio_sec:.2f}x real time")
        json.dump(preds, open(out_path, "w"))
        json.dump(timing, open(out_path.replace("preds_", "timing_"), "w"))


def run_kong_onnx(pieces, out_path):
    _run_kong_onnx(pieces, out_path, "kong_piano_transcription.onnx")


def run_kong_onnx_int8(pieces, out_path):
    _run_kong_onnx(pieces, out_path, "kong_piano_transcription.int8.onnx")


def bench_onnx_throughput(_pieces, out_path):
    """Time the two exports whose front ends are not reimplemented here.

    Accuracy for these would need their log-mel parameters and their note
    decoders ported and verified; throughput does not, and throughput is the
    number the backend decision turns on. Random input of the documented
    shape costs the same arithmetic as real input.
    """
    import numpy as np

    # (file, input name, shape, seconds of audio that shape represents)
    #   O&F: 229-bin log-mel at hop 512 / 16 kHz -> 31.25 frames per second.
    #   HFT: 192-frame window at hop 256 / 16 kHz, of which only the middle
    #        128 frames are emitted, so a window advances 128*256/16000 s.
    cases = [
        ("onsets_and_frames.onnx", (1, 1000, 229), 1000 * 512 / 16000),
        ("hft_transformer.onnx", (1, 256, 192), 128 * 256 / 16000),
    ]
    out = {}
    for fname, shape, audio_sec in cases:
        path = find_onnx(fname)
        if path is None:
            log(f"  {fname}: not mounted, skipped")
            continue
        for threads in (1, 0):
            try:
                sess = _ort_session(path, threads)
                inp = sess.get_inputs()[0].name
                names = [o.name for o in sess.get_outputs()]
                x = np.random.randn(*shape).astype(np.float32)
                sess.run(names, {inp: x})  # warm up
                reps = 5
                t0 = time.time()
                for _ in range(reps):
                    sess.run(names, {inp: x})
                per = (time.time() - t0) / reps
                label = f"{threads or os.cpu_count()} thread(s)"
                log(f"  {fname:28} {label:14} {1000*per:8.1f} ms per "
                    f"{audio_sec:.2f} s of audio  =>  "
                    f"{per/audio_sec:6.3f}x real time")
                out.setdefault(fname, {})[str(threads)] = {
                    "sec_per_window": per, "audio_sec": audio_sec,
                    "x_real_time": per / audio_sec,
                    "threads": threads or os.cpu_count()}
            except Exception as exc:  # noqa: BLE001
                log(f"  {fname} at {threads} threads failed: {exc}")
    json.dump(out, open(out_path, "w"), indent=1)


MODELS = {"basic_pitch": run_basic_pitch, "kong": run_kong,
          "kong_onnx": run_kong_onnx, "kong_onnx_int8": run_kong_onnx_int8,
          "onnx_throughput": bench_onnx_throughput}


# ---------------------------------------------------------------------------
# scoring
# ---------------------------------------------------------------------------

def _arrays(notes):
    import numpy as np
    if not notes:
        return np.zeros((0, 2)), np.zeros(0), []
    iv = np.array([[n[0], n[1]] for n in notes], dtype=float)
    # mir_eval rejects non-positive durations; a handful of MusicNet labels
    # and of model outputs are degenerate. Widen rather than drop, so the
    # note counts stay comparable with our Dart run.
    bad = iv[:, 1] <= iv[:, 0]
    iv[bad, 1] = iv[bad, 0] + 1e-3
    hz = np.array([440.0 * 2.0 ** ((n[2] - 69) / 12.0) for n in notes])
    # The cleaned tuples go to our matcher too: an audit that feeds the two
    # implementations different intervals measures the cleaning, not the rule.
    clean = [(float(iv[i, 0]), float(iv[i, 1]), float(notes[i][2]))
             for i in range(len(notes))]
    return iv, hz, clean


def dart_match(ref, est, onset_tol, pitch_tol_cents, with_offset,
               round_decimals=None):
    """`bench/lib/note_metrics.dart`, re-implemented line for line.

    Kuhn's augmenting-path maximum bipartite matching over the admissible
    pairs, exactly as the Dart does. Run on the same inputs as mir_eval so
    that a disagreement is a fact about one of the two implementations and
    not about the data.

    [round_decimals] mirrors `mir_eval`'s `N_DECIMALS`: it rounds the onset
    and offset distances before the comparison, so a distance that is 50 ms
    plus a float ulp still counts as a hit. The Dart does not do this, and a
    randomised cross-check found that to be the **only** thing the two
    disagree about — so the audit reports both, and a disagreement that
    survives the rounding is a real defect while one that does not is a
    boundary tie.
    """
    import bisect
    sys.setrecursionlimit(100000)

    # The Dart compares every pair; here the estimates are sorted by onset and
    # only the window within the onset tolerance is visited, which is the same
    # admissibility set at a fraction of the cost.
    order = sorted(range(len(est)), key=lambda e: est[e][0])
    onsets = [est[e][0] for e in order]

    cand = []
    for rn in ref:
        dur = rn[1] - rn[0]
        off_tol = max(OFFSET_MIN_TOL_S, OFFSET_RATIO * dur)
        slack = 0.0 if round_decimals is None else 0.5 * 10 ** -round_decimals
        lo = bisect.bisect_left(onsets, rn[0] - onset_tol - slack)
        hi = bisect.bisect_right(onsets, rn[0] + onset_tol + slack)
        row = []
        for k in range(lo, hi):
            e = order[k]
            en = est[e]
            d = abs(en[0] - rn[0])
            if round_decimals is not None:
                d = round(d, round_decimals)
            if d > onset_tol:
                continue
            # The Dart compares MIDI numbers directly — `100 * (est.midi -
            # ref.midi)` — which is the same cents as mir_eval's
            # `1200*log2(f_est/f_ref)` only because both sides are exact MIDI
            # here. Mirror the Dart, not mir_eval, or this stops being an
            # audit of the Dart.
            if abs(100.0 * (en[2] - rn[2])) > pitch_tol_cents:
                continue
            if with_offset:
                d2 = abs(en[1] - rn[1])
                if round_decimals is not None:
                    d2 = round(d2, round_decimals)
                if d2 > off_tol:
                    continue
            row.append(e)
        cand.append(row)

    match_of_est = [-1] * len(est)

    def assign(r, seen):
        for e in cand[r]:
            if seen[e]:
                continue
            seen[e] = True
            if match_of_est[e] == -1 or assign(match_of_est[e], seen):
                match_of_est[e] = r
                return True
        return False

    for r in range(len(ref)):
        if cand[r]:
            assign(r, [False] * len(est))
    return [(match_of_est[e], e) for e in range(len(est)) if match_of_est[e] >= 0]


def score_piece(piece, est_notes):
    import numpy as np
    import mir_eval

    ref_iv, ref_hz, ref_clean = _arrays(piece["notes"])
    est_iv, est_hz, est_clean = _arrays([tuple(n) for n in est_notes])
    row = {"id": piece["id"], "instruments": piece["instrument_names"],
           "ref_notes": len(piece["notes"]), "est_notes": len(est_notes)}
    if len(ref_iv) == 0 or len(est_iv) == 0:
        row.update(p=0.0, r=0.0, f1=0.0, p_off=0.0, r_off=0.0, f1_off=0.0)
        return row

    p, r, f1, _ = mir_eval.transcription.precision_recall_f1_overlap(
        ref_iv, ref_hz, est_iv, est_hz, onset_tolerance=ONSET_TOL_S,
        pitch_tolerance=PITCH_TOL_CENTS, offset_ratio=None)
    po, ro, fo, _ = mir_eval.transcription.precision_recall_f1_overlap(
        ref_iv, ref_hz, est_iv, est_hz, onset_tolerance=ONSET_TOL_S,
        pitch_tolerance=PITCH_TOL_CENTS, offset_ratio=OFFSET_RATIO,
        offset_min_tolerance=OFFSET_MIN_TOL_S)
    row.update(p=float(p), r=float(r), f1=float(f1),
               p_off=float(po), r_off=float(ro), f1_off=float(fo))

    strict = mir_eval.transcription.match_notes(
        ref_iv, ref_hz, est_iv, est_hz, onset_tolerance=ONSET_TOL_S,
        pitch_tolerance=PITCH_TOL_CENTS, offset_ratio=None)
    row["matched"] = len(strict)
    if strict:
        err = np.array([est_iv[e, 0] - ref_iv[r_, 0] for r_, e in strict])
        row["onset_err_ms_p50_strict"] = float(np.median(err) * 1000)

    # The lag, measured where it is measurable.
    wide = mir_eval.transcription.match_notes(
        ref_iv, ref_hz, est_iv, est_hz, onset_tolerance=WIDE_ONSET_TOL_S,
        pitch_tolerance=PITCH_TOL_CENTS, offset_ratio=None)
    row["matched_wide"] = len(wide)
    if wide:
        err = np.array([est_iv[e, 0] - ref_iv[r_, 0] for r_, e in wide])
        row["onset_err_ms_p50_wide"] = float(np.median(err) * 1000)
        row["onset_err_ms_mean_wide"] = float(np.mean(err) * 1000)
        cents = np.array([1200 * np.log2(est_hz[e] / ref_hz[r_])
                          for r_, e in wide])
        row["pitch_err_cents_p50"] = float(np.median(cents))

    # The audit of our hand-rolled matcher, on identical inputs.
    ours = dart_match(ref_clean, est_clean,
                      ONSET_TOL_S, PITCH_TOL_CENTS, False)
    row["matched_dart_rules"] = len(ours)
    ours_off = dart_match(ref_clean, est_clean,
                          ONSET_TOL_S, PITCH_TOL_CENTS, True)
    strict_off = mir_eval.transcription.match_notes(
        ref_iv, ref_hz, est_iv, est_hz, onset_tolerance=ONSET_TOL_S,
        pitch_tolerance=PITCH_TOL_CENTS, offset_ratio=OFFSET_RATIO,
        offset_min_tolerance=OFFSET_MIN_TOL_S)
    row["matched_off"] = len(strict_off)
    row["matched_off_dart_rules"] = len(ours_off)
    row["matched_dart_rounded"] = len(dart_match(
        ref_clean, est_clean,
        ONSET_TOL_S, PITCH_TOL_CENTS, False, round_decimals=4))
    row["matched_off_dart_rounded"] = len(dart_match(
        ref_clean, est_clean,
        ONSET_TOL_S, PITCH_TOL_CENTS, True, round_decimals=4))
    return row


def aggregate(rows, key_matched="matched", key_est="est_notes"):
    m = sum(r.get(key_matched, 0) for r in rows)
    e = sum(r[key_est] for r in rows)
    g = sum(r["ref_notes"] for r in rows)
    p = m / e if e else 0.0
    r_ = m / g if g else 0.0
    return p, r_, (0.0 if p + r_ == 0 else 2 * p * r_ / (p + r_)), m, e, g


def report(model, rows):
    log("")
    log(f"===== {model} =====")
    log(f"{'piece':6} {'instruments':34} {'ref':>6} {'est':>6} "
        f"{'P':>7} {'R':>7} {'F1':>7} | {'F1+off':>7} | "
        f"{'onset p50 (wide)':>17} {'cents':>7}")
    for r in rows:
        inst = ",".join(r["instruments"])[:34]
        log(f"{r['id']:6} {inst:34} {r['ref_notes']:6d} {r['est_notes']:6d} "
            f"{100*r['p']:6.1f}% {100*r['r']:6.1f}% {100*r['f1']:6.1f}% | "
            f"{100*r['f1_off']:6.1f}% | "
            f"{r.get('onset_err_ms_p50_wide', float('nan')):+14.1f} ms "
            f"{r.get('pitch_err_cents_p50', float('nan')):+6.1f}")

    p, r_, f1, m, e, g = aggregate(rows)
    log(f"MICRO (note-weighted): P {100*p:.1f}%  R {100*r_:.1f}%  "
        f"F1 {100*f1:.1f}%   ({m} matched / {e} est / {g} ref)")
    po, ro, fo, mo, _, _ = aggregate(rows, "matched_off")
    log(f"MICRO with offsets   : P {100*po:.1f}%  R {100*ro:.1f}%  "
        f"F1 {100*fo:.1f}%")
    n = len(rows)
    log(f"MACRO (piece mean)   : P {100*sum(r['p'] for r in rows)/n:.1f}%  "
        f"R {100*sum(r['r'] for r in rows)/n:.1f}%  "
        f"F1 {100*sum(r['f1'] for r in rows)/n:.1f}%   "
        f"(with offsets F1 {100*sum(r['f1_off'] for r in rows)/n:.1f}%)")

    piano = [r for r in rows if r["instruments"] == ["piano"]]
    other = [r for r in rows if r["instruments"] != ["piano"]]
    for name, sub in (("solo piano", piano), ("everything else", other)):
        if sub:
            p2, r2, f2, _, _, _ = aggregate(sub)
            lags = [r.get("onset_err_ms_p50_wide") for r in sub
                    if "onset_err_ms_p50_wide" in r]
            lag = f"{sum(lags)/len(lags):+.1f} ms" if lags else "n/a"
            log(f"  {name:16} ({len(sub)} pieces): F1 {100*f2:.1f}%   "
                f"mean of per-piece onset lags {lag}")

    # metric audit
    dis = [r for r in rows if r.get("matched_dart_rules") != r.get("matched")]
    dis_off = [r for r in rows
               if r.get("matched_off_dart_rules") != r.get("matched_off")]
    if not dis and not dis_off:
        log("metric audit: our hand-rolled matcher agrees with mir_eval on "
            "every piece, onset-only and with offsets.")
    else:
        log("metric audit: DISAGREEMENT between mir_eval and the Dart rules")
        for r in dis:
            log(f"  {r['id']} onset-only: mir_eval {r['matched']} vs "
                f"ours {r['matched_dart_rules']} "
                f"(ours with mir_eval's boundary rounding: "
                f"{r['matched_dart_rounded']})")
        for r in dis_off:
            log(f"  {r['id']} with offsets: mir_eval {r['matched_off']} vs "
                f"ours {r['matched_off_dart_rules']} "
                f"(rounded: {r['matched_off_dart_rounded']})")
        if all(r["matched_dart_rounded"] == r["matched"] for r in dis) and \
                all(r["matched_off_dart_rounded"] == r["matched_off"]
                    for r in dis_off):
            log("  ...and every one of them disappears under mir_eval's "
                "distance rounding, so the rules agree and only the "
                "exactly-at-tolerance tie-break differs.")


# ---------------------------------------------------------------------------
# skipped models, with reasons
# ---------------------------------------------------------------------------

def try_magenta():
    log("")
    log("----- Magenta Onsets & Frames -----")
    try:
        r = subprocess.run(f"{sys.executable} -m pip install -q magenta",
                           shell=True, timeout=900,
                           capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        log("SKIPPED: `pip install magenta` did not resolve within 15 min.")
        return
    if r.returncode != 0:
        tail = (r.stderr or r.stdout).strip().splitlines()[-6:]
        log("SKIPPED: `pip install magenta` failed. The package pins "
            "tensorflow 2.9 and python<3.11; this worker is "
            f"python {sys.version.split()[0]}. pip said:")
        for line in tail:
            log("    " + line)
        log("The maintained route would be jongwook/onsets-and-frames "
            "(PyTorch), whose checkpoint is a Google Drive link rather than "
            "a package — not a dependable fetch inside a kernel. Kong's "
            "model below covers the same question (a dedicated onset head on "
            "piano) through a pip-installable path.")
        return
    log("magenta installed — but no pip-distributed checkpoint accompanies "
        "it; the Onsets & Frames weights ship via gs:// in the Magenta "
        "repo's own scripts. Not pursued further.")


def note_mt3():
    log("")
    log("----- MT3 / YourMT3 -----")
    log("SKIPPED by design. MT3 is t5x/JAX with gin configs and a "
        "gs://mt3/checkpoints checkpoint, and YourMT3 needs its repo plus "
        "HF weights and a spectrogram config to match. Neither is a "
        "`pip install` away, and the brief for this kernel is explicit that "
        "it should not sink the run into standing one up.")


# ---------------------------------------------------------------------------

def main():
    log(SCRIPT_VERSION)
    log(f"python {sys.version.split()[0]}")
    sh("nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader",
       check=False)
    sh("df -h /kaggle/working | tail -1", check=False)

    require_internet()
    sh(f"{sys.executable} -m pip install -q mir_eval")
    fetch_musicnet()

    pieces = load_pieces()
    total = sum(len(p["notes"]) for p in pieces)
    log("")
    log(f"{len(pieces)} test pieces, {total} reference notes "
        f"(expected 10 / 13589)")
    for p in pieces:
        log(f"  {p['id']}: {len(p['notes']):5d} notes  "
            f"{','.join(p['instrument_names'])}")
    json.dump([{k: v for k, v in p.items() if k != "notes"} for p in pieces],
              open(os.path.join(WORK, "pieces.json"), "w"), indent=1)

    installs = {
        # `pip install basic-pitch` on Linux/py>=3.11 pulls
        # `tensorflow<2.15.1` as a CORE dependency (checked against the
        # 0.4.0 wheel's metadata, not assumed), which would downgrade
        # Kaggle's TensorFlow and take Keras 3 with it. Install the package
        # without its dependency graph and supply only what the ONNX path
        # needs; librosa, scipy, scikit-learn and numpy are already in the
        # image. `[onnx]` is kept as a fallback in case a future wheel drops
        # the pin. (The wheel pins `resampy<0.4.3`, which needs
        # `pkg_resources` and so breaks on a modern setuptools; --no-deps
        # means that pin is not enforced and 0.4.3 is used instead.)
        "basic_pitch": [
            f"{sys.executable} -m pip install -q --no-deps basic-pitch "
            f"&& {sys.executable} -m pip install -q onnxruntime resampy "
            f"pretty_midi librosa scikit-learn setuptools",
            f"{sys.executable} -m pip install -q 'basic-pitch[onnx]'",
        ],
        "kong": [
            f"{sys.executable} -m pip install -q piano_transcription_inference",
        ],
        # The ORT arms reuse the package's official segmentation and
        # post-processor but not its model, so the same install serves.
        "kong_onnx": [
            f"{sys.executable} -m pip install -q piano_transcription_inference"
            f" onnxruntime",
        ],
        "kong_onnx_int8": [f"{sys.executable} -c 'pass'"],
        "onnx_throughput": [f"{sys.executable} -c 'pass'"],
    }

    results = {}
    for model in ("basic_pitch", "kong", "kong_onnx", "kong_onnx_int8"):
        log("")
        log(f"########## {model} ##########")
        installed = False
        for cmd in installs[model]:
            try:
                sh(cmd, timeout=2400)
                installed = True
                break
            except Exception as exc:  # noqa: BLE001
                log(f"  install attempt failed: {exc}")
        if not installed:
            log(f"SKIPPED {model}: every install attempt failed")
            continue
        out = os.path.join(WORK, f"preds_{model}.json")
        # Kong transcribes piano; the six pieces without any are not a test
        # of it, and the runtime arms exist to be compared with each other.
        subset = [q for q in pieces if q["id"] in KONG_PIECES] \
            if model.startswith("kong") else pieces
        # Child process: one model crashing must not end the run, and the
        # next model's pip install must not disturb one that already ran.
        rc = subprocess.run([sys.executable, __file__, "--child", model, out]).returncode
        if rc != 0:
            log(f"{model}: child exited {rc}")
        if not os.path.exists(out):
            log(f"SKIPPED {model}: no predictions written")
            continue
        preds = json.load(open(out))
        rows = [score_piece(p, preds[p["id"]]) for p in subset
                if p["id"] in preds]
        if len(rows) < len(subset):
            log(f"NOTE: only {len(rows)}/{len(subset)} pieces completed for "
                f"{model}; the aggregate below covers those only.")
        report(model, rows)
        results[model] = rows
        json.dump(results, open(os.path.join(WORK, "reference_scores.json"), "w"),
                  indent=1)

    # --- throughput of the two exports that are timed but not scored -----
    log("")
    log("########## onnxruntime throughput, unscored exports ##########")
    log("Onsets & Frames and HFT Transformer take features, not audio. "
        "Reimplementing their log-mel front ends and note decoders "
        "unverified is the exact failure mode this kernel exists to rule "
        "out, so these are timed only — which is the half of the question "
        "that decides whether a native-ORT backend is worth building.")
    tp = os.path.join(WORK, "onnx_throughput.json")
    subprocess.run([sys.executable, __file__, "--child", "onnx_throughput",
                    tp])

    # --- runtime comparison ----------------------------------------------
    log("")
    log("########## cost per second of audio ##########")
    log(f"{'arm':18} {'audio':>8} {'inference':>10} {'xRT':>8}  "
        f"(xRT < 1 is faster than real time)")
    timings = {}
    for model in ("basic_pitch", "kong", "kong_onnx", "kong_onnx_int8"):
        f = os.path.join(WORK, f"timing_{model}.json")
        if not os.path.exists(f):
            continue
        t = json.load(open(f))
        timings[model] = t
        a = sum(v["audio_sec"] for v in t.values())
        w = sum(v["infer_sec"] for v in t.values())
        log(f"{model:18} {a:7.0f}s {w:9.0f}s {w/a:7.3f}x")
    log("")
    log("For scale, bench/ measures the pure-Dart runtime at ~96x real time "
        "for Kong — 96 seconds of CPU per second of audio.")

    # --- do ORT and PyTorch agree on the transcription, not just tensors? -
    if "kong" in results and "kong_onnx" in results:
        log("")
        log("########## ORT vs PyTorch: same notes, or only same tensors? "
            "##########")
        a = json.load(open(os.path.join(WORK, "preds_kong.json")))
        b = json.load(open(os.path.join(WORK, "preds_kong_onnx.json")))
        tot_a = tot_b = same = 0
        for pid in sorted(set(a) & set(b)):
            sa = {(round(n[0], 3), int(n[2])) for n in a[pid]}
            sb = {(round(n[0], 3), int(n[2])) for n in b[pid]}
            tot_a += len(sa)
            tot_b += len(sb)
            same += len(sa & sb)
            log(f"  {pid}: torch {len(sa):5d}  ort {len(sb):5d}  "
                f"identical (onset to 1 ms, same pitch) {len(sa & sb):5d}  "
                f"= {100*len(sa & sb)/max(1, len(sa)):5.1f}% of torch's")
        log(f"  total: torch {tot_a}, ort {tot_b}, identical {same} "
            f"({100*same/max(1, tot_a):.1f}%)")
        pa = aggregate([r for r in results["kong"]
                        if r["id"] in KONG_PIECES])
        pb = aggregate(results["kong_onnx"])
        log(f"  F1 on the same four pieces: torch {100*pa[2]:.1f}%  "
            f"ort {100*pb[2]:.1f}%")

    try_magenta()
    note_mt3()

    log("")
    log("========== comparison with bench/REPORT.md §30 ==========")
    log("Dart port of Spotify note_creation, same ONNX model, same corpus:")
    log("    P 52.4%  R 37.9%  F1 44.0%   (with offsets 16.3%)")
    for model, rows in results.items():
        p, r_, f1, _, _, _ = aggregate(rows)
        _, _, fo, _, _, _ = aggregate(rows, "matched_off")
        log(f"{model:14} reference:  P {100*p:.1f}%  R {100*r_:.1f}%  "
            f"F1 {100*f1:.1f}%   (with offsets {100*fo:.1f}%)")
    log("")
    log("DONE")


if __name__ == "__main__":
    if len(sys.argv) > 3 and sys.argv[1] == "--child":
        _model, _out = sys.argv[2], sys.argv[3]
        _pieces = load_pieces()
        if _model.startswith("kong"):
            _pieces = [q for q in _pieces if q["id"] in KONG_PIECES]
        MODELS[_model](_pieces, _out)
    else:
        main()
