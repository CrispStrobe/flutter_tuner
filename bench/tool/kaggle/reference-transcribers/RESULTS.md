# Reference transcribers on MusicNet — what the official code scores

Run: `chr1s4/crisptuner-reference-transcribers`, CPU worker, python 3.12.13.
Log: [`run-v3.log`](run-v3.log) (Basic Pitch), [`run-v4.log`](run-v4.log)
(Kong). Corpus: MusicNet test split, Zenodo 5120004, streamed inside the
kernel and never committed. Metric: `mir_eval.transcription`, 50 ms onset,
50 cents pitch.

The corpus reads back exactly as documented: **10 pieces, 13,589 reference
notes**. (The test members turn out to sit at the *front* of the 11 GB
tarball, so the stream is abandoned after ~230 MB and the fetch takes 12
seconds rather than the ten minutes budgeted for it.)

## 1. Is 44.0% corroborated? Yes — to within two tenths of a point.

| | precision | recall | **F1** | F1 with offsets |
| --- | --- | --- | --- | --- |
| **Reference** — `basic-pitch` 0.4.0, official `predict()` | 50.3% | 39.5% | **44.2%** | 16.7% |
| Ours — Dart port of `note_creation.py` (`REPORT.md` §30) | 52.4% | 37.9% | **44.0%** | 16.3% |

Same model file: the kernel pins `basic_pitch/saved_models/icassp_2022/nmp.onnx`,
which is the same `nmp.onnx` the Dart pipeline runs, so this is decoder
against decoder and not two exports of the same weights.

**44.0% is the model on this corpus, not a third clock bug.** The port is
0.2 points off the official implementation, trading 2.1 points of precision
for 1.6 of recall — the signature of small differences in peak-picking and
window-seam handling, not of a defect.

And the agreement is not only in the aggregate. Every piece §29.2 scored
individually lands within about two points:

| piece | ours (§29.2) | reference | Δ |
| --- | --- | --- | --- |
| 1759 | 53.0% | 52.5% | −0.5 |
| 1819 | 40.7% | 38.6% | −2.1 |
| 2106 | 24.0% | 24.9% | +0.9 |
| 2191 | 36.3% | 36.1% | −0.2 |
| 2298 | 45.7% | 46.6% | +0.9 |

Ten pieces of agreement piece by piece is much stronger evidence than one
matching aggregate, which two different error patterns could produce by
coincidence.

## 2. Reference, per piece

| piece | instruments | ref | est | P | R | F1 | F1+off | onset p50 (wide) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1759 | piano | 1723 | 1722 | 52.6% | 52.5% | 52.5% | 16.4% | **+3.3 ms** |
| 2303 | piano | 718 | 697 | 75.3% | 73.1% | **74.2%** | 29.8% | **+4.6 ms** |
| 2556 | piano | 1446 | 1213 | 60.3% | 50.6% | 55.0% | 22.5% | **+3.3 ms** |
| 2628 | piano, violin | 1518 | 1485 | 57.8% | 56.5% | 57.1% | 23.6% | +32.7 ms |
| 2416 | horn, bassoon, clarinet | 1386 | 1016 | 63.5% | 46.5% | 53.7% | 16.5% | +25.2 ms |
| 1819 | horn, bassoon, clarinet | 1321 | 1297 | 38.9% | 38.2% | 38.6% | 15.2% | +61.3 ms |
| 2298 | cello | 966 | 690 | 55.9% | 40.0% | 46.6% | 18.0% | +45.5 ms |
| 2191 | violin | 551 | 490 | 38.4% | 34.1% | 36.1% | 11.0% | +60.0 ms |
| 2106 | violin, viola, cello | 2004 | 1560 | 28.5% | 22.2% | 24.9% | 13.6% | +88.4 ms |
| 2382 | violin, viola, cello | 1956 | 493 | 36.1% | 9.1% | **14.5%** | 2.1% | **+111.4 ms** |
| | **micro** | 13589 | 10663 | **50.3%** | **39.5%** | **44.2%** | **16.7%** | |
| | macro (piece mean) | | | 50.7% | 42.3% | 45.3% | 16.9% | |

Pitch error of matched notes is **+0.0 cents on every single piece**, which
is §30's finding reproduced exactly: when these systems find a note they
have its pitch right, and everything separating them from a good score is
timing.

## 3. The per-instrument onset lag reproduces — and it is larger

`onset p50 (wide)` is the median signed onset error of matched notes at a
deliberately wide 500 ms tolerance. It has to be measured wide: at the
standard 50 ms the error distribution is *truncated at ±50 ms by
construction*, so a median computed there cannot show a +88 ms bias even
when one is there. (§29.2 says "measured at a wide tolerance" and this is
the same move.)

| | pieces | F1 | mean of per-piece onset lags |
| --- | --- | --- | --- |
| solo piano | 3 | **57.5%** | **+3.8 ms** |
| everything else | 7 | 38.3% | **+60.7 ms** |

The split is clean and it sorts by instrument family, not by piece
difficulty — which is what rules out label noise. Piano is at the frame
grid; every bowed and blown piece lags, and the two worst-lagging pieces
(2106 at +88 ms, 2382 at +111 ms) are the two worst-scoring pieces. The
19-point F1 gap between the two rows is the same fact.

**Two corrections to how §29.2 states this.**

*First:* §29.2 records piano 1759 at **−12 ms**; the reference on that same
file says **+3.3 ms**, and the other two solo-piano pieces agree with it at
+3.3 and +4.6 ms. The *pattern* is confirmed and strengthened, but the
specific −12 ms looks like about 15 ms of our own, not the model's. Across
the other shared pieces the offsets go the same way but not by a constant
(1819 +39 vs +61, 2106 +70 vs +88, 2191 +58 vs +60, 2298 +42 vs +46), so
this is a hint worth chasing rather than a demonstrated fixed shift — the
two runs use different decoders and so match different notes.

*Second, and more important:* **a reference implementation reproducing the
lag does not establish that the lag belongs to the model.** MusicNet's
labels were produced by aligning MIDI scores to the recordings with dynamic
time warping, and the alignment is least reliable exactly where the attack
is least percussive. So +60 ms on bowed strings is equally consistent with
"the model fires when pitch becomes stable" and with "the annotation marks
where the score says the note is". This corpus cannot separate those. A
corpus whose ground truth is captured rather than aligned — MAESTRO, from a
Disklavier — would, and it is also the corpus where the piano number can be
trusted at face value. Worth noting that the only three pieces here with
near-zero lag are the three where the attack is percussive *and* the
alignment is therefore easiest, so the two explanations predict the same
thing on this data.

## 4. `bench/lib/note_metrics.dart` is correct

The kernel re-implements the Dart matcher in Python and runs it on the same
reference/estimate arrays `mir_eval` gets.

Nine of ten pieces: **identical**, onset-only and with offsets. Piece 1759
differs by 4 matches out of 905 (0.4%) onset-only and 1 of 283 with
offsets — and **every one of those disappears when `mir_eval`'s own
rounding is applied**.

The mechanism: `mir_eval.transcription` rounds onset and offset distances to
four decimals before comparing, deliberately, so that a note exactly 50 ms
away is a hit rather than a float-precision miss. `note_metrics.dart` does
not round. The difference can only bite a note within 50 µs of the
tolerance, and its effect here is under 0.1 F1 points.

A randomised cross-check run before pushing — 240 cases, dense and sparse,
with and without the offset condition — found the same thing and nothing
else: 2 disagreements out of 240 with the faithful Dart rules, **0 of 240**
once the rounding is applied. So the maximum-bipartite matching, the
admissibility rules, the offset tolerance `max(50 ms, 0.2 × duration)` and
the cents comparison are all right. If you want exact parity, round the
onset and offset distances to 4 decimals before the comparison in
`scoreNotes`; nothing else needs to change.

(This audit also caught a bug in *my* Python transcription of the Dart
before it ever ran — it compared MIDI numbers with the Hz cents formula —
which is a small argument for writing the cross-check rather than eyeballing
the two files.)

## 5. The other models

**Kong / ByteDance high-resolution piano transcription** — see §6.

**Magenta Onsets & Frames — skipped, and the log says why.** `pip install
magenta` fails at metadata generation: the package pins `tensorflow==2.9`
and `python<3.11`, and the worker is python 3.12.13. The maintained route is
`jongwook/onsets-and-frames` (PyTorch), whose checkpoint is a Google Drive
link rather than a package — not something to depend on inside a kernel.
Kong covers the same question (a dedicated onset head, on piano) through a
path that installs.

**MT3 / YourMT3 — skipped by design.** t5x/JAX, gin configs, a
`gs://mt3/checkpoints` checkpoint; YourMT3 additionally needs its repo, HF
weights and a matching spectrogram config. Not a `pip install`, and the
brief was explicit about not sinking the run into it.

## 6. Kong / ByteDance, piano-only

See `run-v4.log`. Note that Kong is trained on MAESTRO and transcribes
*piano*: on the six pieces with no piano in them its output is not a
transcription of anything, and the only rows worth reading are 1759, 2303,
2556 (solo piano) and 2628 (piano + violin).

<!-- KONG RESULTS -->

## Operational notes

* The CPU worker **had** internet, so the gotcha in
  `/mnt/volume1/kaggle-usage.md` #3 did not bite; the fail-fast check at the
  top makes a bad draw cost about a minute rather than a session. No GPU
  quota was spent.
* `pip install basic-pitch` on Linux/py≥3.11 pulls `tensorflow<2.15.1` as a
  **core** dependency, which would downgrade the image's TensorFlow 2.20 and
  take Keras 3 with it. `--no-deps` plus `onnxruntime` avoids that and pins
  the ONNX path, which is also the tighter comparison.
* `piano_transcription_inference` 0.0.6 needs three things patched around
  it: its checkpoint fetch is an unchecked `os.system("wget")`, `torch.load`
  now defaults to `weights_only=True`, and its `load_audio` calls
  `librosa.core.audio.util`, which librosa's lazy loader no longer exposes.
  All three are handled in the kernel with the reason written next to them.
