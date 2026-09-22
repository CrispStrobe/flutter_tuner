# `bench/` — measuring CrispTuner's pitch detection

A standalone, pure-Dart benchmark for the app's detection pipeline against
real recorded audio with ground truth. The findings live in
[`REPORT.md`](REPORT.md); this file is about running it.

It is a separate package on purpose. The app package depends on the Flutter
SDK, and anything that depends on the app package inherits that; the maths in
`lib/tuner_core.dart` has no Flutter import precisely so it can be measured
with a plain `dart run`, and this keeps it that way.

## Running it

```sh
cd bench
dart pub get

# the whole monophonic corpus, every pipeline variant
dart run bin/bench.dart --subset solo --jobs 4 --out results/solo.json

# the chordal recordings, where a tuner is not supposed to work
dart run bin/bench.dart --subset comp --jobs 4 --out results/comp.json

# does our YIN still agree with the one the app ships?
dart run bin/verify.dart /path/to/some.wav 200

# what each detector costs per frame
dart run bin/timing.dart /path/to/some.wav 300

# the precision floor, on synthetic tones whose f0 is known exactly
dart run bin/precision.dart

# where in the analysis window each estimator's answer belongs
dart run bin/alignment.dart 12

# after a pluck: how long until the needle is right, and does it stay
dart run bin/notes.dart --subset solo --hop 512

# tracking lag: how far the needle trails while the pitch is moving
dart run bin/tracking.dart --subset solo --limit 60

# SWIPE' against YIN on the same frames (slow — hence the subset)
dart run bin/swipe.dart --limit 20 --hop 1024

# what the partials say: inharmonicity, timbre, and whether the spectrum can
# catch the detector's octave errors (--skip holds files out of the tuning set)
dart run bin/harmonics.dart --subset solo --skip 20
```

Note-level transcription, and the two models §31 exported but never ran:

```sh
# hFT-Transformer and Onsets & Frames: what one costs in the pure-Dart
# runtime, measured against a co-run of the model the app ships
dart run bin/spectro_timing.dart --seconds 30

# the front end, checked against librosa rather than assumed
dart run bin/mel_check.dart > /tmp/dart_mel.json
python3 tool/mel_reference.py /tmp/dart_mel.json

# cache the head activations under native ORT, then decode and score in Dart
python3 tool/prune_hft.py                       # once: drop the unused heads
python3 tool/spectro_activations.py --model hft --out /mnt/storage/tuner-bench/acts
python3 tool/spectro_activations.py --model oaf --out /mnt/storage/tuner-bench/acts
dart run bin/spectro_eval.dart --acts /mnt/storage/tuner-bench/acts --sweep
```

`--data` points at the corpus and defaults to
`/mnt/storage/tuner-bench/datasets`, which must contain `audio/*.wav` and
`annotation/*.jams`.

## The corpus

[GuitarSet](https://zenodo.org/records/3371780) (Xi, Bittner, Pauwels, Ye &
Bello, ISMIR 2018), CC BY 4.0: 360 recordings of six players, mono microphone
at 44.1 kHz, with per-string pitch contours derived from a hexaphonic pickup.
Files ending `_solo` are single-line playing; `_comp` is chordal.

**The audio, the annotations and anything derived from them stay out of this
repository.** They are downloaded to `/mnt/storage/tuner-bench/datasets` and
evaluated in place; only aggregate numbers come back. `results/` is
gitignored for the same reason.

Ground truth is read straight out of the JAMS: six `pitch_contour`
annotations per file, columnar (`time[]`, `value[]`), each value
`{voiced, index, frequency}`. Unvoiced instants are simply absent rather than
flagged, so "is this string sounding" is a question about whether a sample
exists near the instant. A frame with exactly one string sounding is scored
as monophonic; frames with two or more are counted separately and scored only
leniently, because naming one note out of a chord is not a well-posed
question for a tuner.

## Keeping the copied core in sync

`bench/lib/app/` holds byte-identical copies of the Flutter-free files from
the app: `tuner_core.dart`, `detectors.dart`, `harmonics.dart`,
`temperament.dart`, `tunings.dart`. They are
copies rather than a path dependency because a path dependency on the app
package would drag in the Flutter SDK.

```sh
bin/fft_real_timing.dart   # real-input vs complex FFT (REPORT.md §34);
                           # one arm per process, see --list and --only

tool/sync_core.sh          # copy ../lib/*.dart -> lib/app/*.dart
tool/sync_core.sh --check  # exit 1 if they have drifted
```

Run `--check` in CI, or before trusting a number: a benchmark of a stale copy
of the maths measures nothing.

## What is where

| file | what it is |
| --- | --- |
| `lib/yin.dart` | YIN with every step a parameter — threshold, tau rule, the paper's step 6, naive or FFT difference function. Reproduces `pitch_detector_dart` 0.0.7 exactly at its defaults. |
| `lib/mpm.dart` | McLeod's NSDF, as a comparison point. |
| `lib/pyin.dart` | A pYIN-shaped tracker: candidate distribution per frame, Viterbi across frames. Simplified; see the file. |
| `lib/tracking.dart`, `bin/tracking.dart` | Tracking lag during bends and slides (REPORT.md §9.1). |
| `lib/swipe.dart`, `bin/swipe.dart` | A SWIPE′-like spectral estimator, as a comparison point (REPORT.md §4.5). |
| `lib/note_latency.dart`, `bin/notes.dart` | Note-level latency: time from the pluck to a correct, settled reading (REPORT.md §9). |
| `tool/basic_pitch_eval.py` | Offline evaluation of Spotify's Basic Pitch on the same corpus, by the same rules (REPORT.md §10). Python, because it is an evaluation and not app code — it needs `onnxruntime`, `numpy` and `scipy`, and the model from `basic_pitch/saved_models/icassp_2022/nmp.onnx`. |
| `bin/harmonics.dart` | The partial measurements of REPORT.md §8, scored against the annotation. |
| `lib/refine.dart` | Instantaneous frequency from FFT phase, harmonic least squares, and the stiffness fit that yields an inharmonicity coefficient. |
| `lib/evaluate.dart` | One file in, every variant scored out. All YIN variants share one difference function per frame. The `app-fixed` variant calls the app's own `PitchSmoother` rather than reproducing it. |
| `lib/metrics.dart` | RPA, octave and gross error rates, voicing recall and false alarm, and cent-error histograms. |
| `lib/jams.dart`, `lib/wav.dart` | Just enough of each format. |
| `lib/mel.dart` | A log-mel front end matching `torchaudio.transforms.MelSpectrogram` — periodic Hann, HTK mel scale, Slaney filter normalisation — plus torchaudio's `sinc_interp_hann` resampler. Two of the exported models take a spectrogram rather than audio, and this is it. Checked against librosa by `bin/mel_check.dart` + `tool/mel_reference.py`. |
| `lib/hft.dart`, `lib/oaf.dart` | hFT-Transformer and Onsets & Frames: the window arithmetic and each model's own note decoder, ported from its inference code. REPORT.md §35. |
| `bin/spectro_timing.dart` | What those two cost in the pure-Dart runtime, with the shipped Basic Pitch co-measured so the number survives a loaded box. |
| `bin/spectro_eval.dart`, `tool/spectro_activations.py` | Note-level scoring on MusicNet from cached ORT activations — the model runs where it is fast, the decoder and the metric stay here. |
| `tool/spectro_notes.py` | The same two models scored a second way: decoders ported to numpy, metric taken from `mir_eval` itself. A cross-check of the Dart path, not a substitute for it (REPORT.md §36.1). |
| `tool/onnx_timing.py` | All four models under native ONNX Runtime at 1/2/4 intra-op threads, one process per (model, thread count) so the peak RSS belongs to a model (REPORT.md §36.2). |
| `tool/kaggle/build_spectro_kernel.py` | Generates the four Kaggle kernels that finished §35's unfinished measurements, by concatenating a preamble with these tools verbatim — a script kernel uploads only its `code_file`, so it has to be one file, and it must not be a second copy of the evaluation. |
| `tool/prune_hft.py` | Cuts hFT's graph to the four outputs a transcriber reads. Without it the pure-Dart runtime cannot load the graph on a 7.7 GB box. |
| `bin/bench.dart` | The corpus run, one isolate per core. |
| `bin/verify.dart` | Frame-by-frame agreement with the shipped package. |
| `bin/timing.dart`, `bin/precision.dart`, `bin/alignment.dart` | Cost, precision floor, and where in the window an answer belongs. |

## A caution that cost a day

A synthetic sine is a far easier signal than a plucked string, and a plucked
string is far easier than a real recording in a room. `bin/precision.dart`
exists to establish a floor, not to predict behaviour. Where the two
disagree, the corpus wins.
