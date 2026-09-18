#!/usr/bin/env python3
"""Regenerate the Kaggle kernel from bench/tool/neural_eval.py.

A Kaggle script kernel uploads only its `code_file`, so the kernel has to be
self-contained. Rather than maintain two copies of the evaluation, this
concatenates a Kaggle-specific preamble (pip installs, corpus download from
Zenodo, argv) with the local evaluator verbatim.

  python3 tool/kaggle/build_kernel.py
  cd tool/kaggle/neural-pitch-eval
  export KAGGLE_API_TOKEN=...          # see /mnt/volume1/kaggle-usage.md
  python -m kaggle kernels push -p .
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(BENCH, "tool", "neural_eval.py")
TARGET_DIR = os.path.join(HERE, "neural-pitch-eval")
TARGET = os.path.join(TARGET_DIR, "neural_pitch_eval.py")

PREAMBLE = '''#!/usr/bin/env python3
"""CrispTuner: neural pitch estimators against GuitarSet, on Kaggle.

Generated from bench/tool/neural_eval.py by bench/tool/kaggle/build_kernel.py —
do not edit here; the local copy is the one that gets reviewed.

It runs off-box for a plain reason: the evaluation is CPU-bound for tens of
minutes per model, and the VPS this project is developed on is shared. Nothing
here strictly needs a GPU, but Kaggle only gives a worker internet when one
is attached (gotcha #3), and a GPU turns CREPE-full from hours into minutes —
so the quota spent is small and the run is reliable.

The corpus is fetched from Zenodo inside the kernel rather than mirrored as a
Kaggle dataset, so nothing redistributes GuitarSet.
"""

import os
import subprocess
import sys
import zipfile
import urllib.request

WORK = "/kaggle/working"
DATA = os.path.join(WORK, "datasets")


def sh(cmd):
    print(f"$ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=True)


def fetch_guitarset():
    """GuitarSet (Zenodo 3371780, CC BY 4.0): annotations + mono-mic audio."""
    audio_dir = os.path.join(DATA, "audio")
    ann_dir = os.path.join(DATA, "annotation")
    if os.path.isdir(audio_dir) and len(os.listdir(audio_dir)) > 100:
        return
    os.makedirs(DATA, exist_ok=True)
    for name, url in [
        ("annotation.zip",
         "https://zenodo.org/records/3371780/files/annotation.zip?download=1"),
        ("audio_mono-mic.zip",
         "https://zenodo.org/records/3371780/files/audio_mono-mic.zip?download=1"),
    ]:
        target = os.path.join(DATA, name)
        print(f"fetching {name}", flush=True)
        urllib.request.urlretrieve(url, target)
        out = ann_dir if "annotation" in name else audio_dir
        os.makedirs(out, exist_ok=True)
        with zipfile.ZipFile(target) as z:
            z.extractall(out)
        os.remove(target)
    print(f"audio: {len(os.listdir(audio_dir))} files, "
          f"annotations: {len(os.listdir(ann_dir))}", flush=True)


def install():
    # Kaggle pre-installs torch; only the small wrappers are needed, and
    # re-installing torch wastes minutes and risks a version conflict.
    # Kaggle pre-installs torch and tensorflow; only the small wrappers are
    # needed. tensorflow_hub/kagglehub are for SPICE, the one model here that
    # is not a torch model.
    sh(f"{sys.executable} -m pip install -q torchcrepe pesto-pitch penn "
       f"tensorflow_hub kagglehub")


def require_internet():
    """Fail loudly and early rather than hanging.

    Kaggle CPU workers get no internet even with `enable_internet: "true"`,
    and a GPU worker can lose it too. Everything here — the pip installs, the
    model weights, the corpus — needs it, so there is no degraded mode worth
    attempting.
    """
    try:
        urllib.request.urlopen("https://zenodo.org", timeout=20).close()
    except Exception as exc:  # noqa: BLE001 - any failure means the same thing
        raise SystemExit(
            f"no internet on this worker ({exc}); re-run until a connected "
            "GPU worker is drawn, or deliver the corpus via dataset_sources"
        )


require_internet()
install()
fetch_guitarset()

# Everything below is bench/tool/neural_eval.py, verbatim.
# ---------------------------------------------------------------------------

'''

METADATA = {
    "id": "chr1s4/crisptuner-neural-pitch-eval",
    "title": "CrispTuner neural pitch eval",
    "code_file": "neural_pitch_eval.py",
    "language": "python",
    "kernel_type": "script",
    "is_private": "true",
    "enable_gpu": "true",
    "enable_internet": "true",
    "competition_sources": [],
    "dataset_sources": [],
    "kernel_sources": [],
    "model_sources": [],
}


def main():
    source = open(SOURCE).read()
    body = source[source.index("import argparse"):]
    body = body.replace('default="/mnt/storage/tuner-bench/datasets"', "default=DATA")
    body = body.replace(
        'if __name__ == "__main__":\n    main()',
        'if __name__ == "__main__":\n'
        '    sys.argv = [\n'
        '        "neural_eval",\n'
        '        "--models", os.environ.get("MODELS", '
        '"crepe-tiny,crepe-tiny-viterbi,crepe-full,crepe-full-viterbi,pesto,pesto-mir-1k,fcnf0++,spice"),\n'
        '        "--limit", os.environ.get("LIMIT", "60"),\n'
        '        "--out", os.path.join(WORK, "neural.json"),\n'
        '    ]\n'
        '    main()',
    )
    os.makedirs(TARGET_DIR, exist_ok=True)
    with open(TARGET, "w") as f:
        f.write(PREAMBLE + body)
    with open(os.path.join(TARGET_DIR, "kernel-metadata.json"), "w") as f:
        json.dump(METADATA, f, indent=1)
    print(f"wrote {TARGET}")


if __name__ == "__main__":
    main()
