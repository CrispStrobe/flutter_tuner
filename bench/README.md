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

# what the partials say: inharmonicity, timbre, and whether the spectrum can
# catch the detector's octave errors (--skip holds files out of the tuning set)
dart run bin/harmonics.dart --subset solo --skip 20
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
| `bin/harmonics.dart` | The partial measurements of REPORT.md §8, scored against the annotation. |
| `lib/refine.dart` | Instantaneous frequency from FFT phase, harmonic least squares, and the stiffness fit that yields an inharmonicity coefficient. |
| `lib/evaluate.dart` | One file in, every variant scored out. All YIN variants share one difference function per frame. The `app-fixed` variant calls the app's own `PitchSmoother` rather than reproducing it. |
| `lib/metrics.dart` | RPA, octave and gross error rates, voicing recall and false alarm, and cent-error histograms. |
| `lib/jams.dart`, `lib/wav.dart` | Just enough of each format. |
| `bin/bench.dart` | The corpus run, one isolate per core. |
| `bin/verify.dart` | Frame-by-frame agreement with the shipped package. |
| `bin/timing.dart`, `bin/precision.dart`, `bin/alignment.dart` | Cost, precision floor, and where in the window an answer belongs. |

## A caution that cost a day

A synthetic sine is a far easier signal than a plucked string, and a plucked
string is far easier than a real recording in a room. `bin/precision.dart`
exists to establish a floor, not to predict behaviour. Where the two
disagree, the corpus wins.
