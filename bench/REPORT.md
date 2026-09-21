# How good is CrispTuner's pitch detection, really?

A measurement of the shipped detection pipeline against 360 real recordings
with ground truth, and of every alternative that looked promising enough to
be worth the arithmetic.

**Short version.** The detector is fine, and one thing around it was not:
the app's own median filter, now fixed and re-measured (§2.1) at +9.09 points
of frame-level accuracy. The three things that looked wrong
in `pitch_detector_dart` turn out to be: one that is wrong in the opposite
direction from the complaint (the threshold), one that changes almost nothing
(the missing step 6), and one that is a genuine and large problem but has
nothing to do with accuracy (the O(N²) difference function costs more than
the entire real-time budget). pYIN, MPM and phase-based refinement all lose to
what is already there, once it is measured against real audio rather than a
synthesiser. The one accuracy bug found is not in YIN at all: it is
CrispTuner's own five-frame median, which had no notion of time and, on a
corpus of real playing, threw away nine points of frame accuracy.

Since then the detector has been made a seam and measured as one (§7): YIN
vendored with the FFT difference function, at 6.8% of an audio callback's
budget where the package cost 201%, with MPM offered as a setting for people
who want a detector that commits more readily and is wrong more often. The
partials are measured too (§8) — inharmonicity, timbre, and an octave guard
that was built, measured and *not* shipped, because at a 0.58% octave-error
rate it would discard more good frames than bad.

---

## 1. What was measured, and how

**Corpus.** [GuitarSet](https://zenodo.org/records/3371780) (Xi, Bittner,
Pauwels, Ye & Bello, ISMIR 2018; CC BY 4.0): 360 recordings by six players,
mono microphone, 44.1 kHz, with per-string pitch contours annotated from a
hexaphonic pickup. The 180 `_solo` files are single-line playing — what a
tuner is built for. The 180 `_comp` files are chordal and are reported
separately. Audio and annotations never enter this repository.

**Pipeline under test.** Exactly what the app runs: `pitch_detector_dart`
0.0.7 (an aubio-YIN port) over a 4096-sample window, the
`result.pitched && result.probability > 0.9` gate from `main.dart`, then
`MedianFilter(size: 5)` from `tuner_core.dart`. `bin/verify.dart` checks the
benchmark's own YIN against the package frame by frame on real audio: 0
mismatches, worst deviation 2.3 × 10⁻¹² cents. Every number below therefore
describes the code in the App Store, not a lookalike.

**Frames.** A 4096-sample window every 1024 samples (43.1 frames/s), 151,882
monophonic frames in the solo set. A frame is *monophonic* when exactly one
string is annotated as sounding at the reference instant; frames with two or
more sounding strings (a chord voicing, or one note still ringing under the
next) are counted separately, because "which note is this" is not a
well-posed question there.

**Held notes.** Frame-level accuracy over all frames punishes a pipeline for
lagging through an attack, which is not what a tuner is doing when someone is
watching the needle. So every table also reports the subset where the
reference has been monophonic and within ±20 cents for the preceding five
frames — 72,518 of the 151,882. Both numbers are given throughout; neither
alone is the honest one.

**Where the answer belongs (this mattered).** YIN's difference function at a
4096-sample window only ever reads the first half of it, so its estimate
describes the *beginning* of the window. Sweeping the assumed reference
instant across the window (`bin/alignment.dart`, 12 files, 6,515 pitched
frames):

| reference instant | YIN \|err\| p50 | p90 | YIN+phase-refinement p50 | p90 |
| --- | --- | --- | --- | --- |
| +0 samples (0 ms) | **2.20** | **7.35** | 4.30 | 25.25 |
| +1024 (23 ms) | 2.65 | 10.20 | 3.50 | 22.05 |
| +2048 (46 ms) | 3.55 | 17.70 | 2.45 | 16.75 |
| +2560 (58 ms) | 3.80 | 21.05 | **2.40** | **14.25** |
| +4095 (93 ms) | 4.70 | 24.55 | 3.40 | 22.55 |

A first pass that scored everything at the window's midpoint credited
phase-based refinement with a 30% improvement in median error that was
entirely a timing shift. Each variant is now scored at the instant its answer
actually describes (0 samples for YIN and MPM, +2560 for the phase-refined
ones), which is also how the refinement's *real* benefit — about 58 ms less
lag — became visible.

That lag is worth stating plainly: **the needle describes a moment roughly 90
ms in the past**, before the median filter adds its own delay.

---

## 2. The shipped pipeline, and each piece of it

180 solo files, 151,882 monophonic frames (72,518 held). `RPA` is raw pitch
accuracy, frames within 50 cents of truth as a fraction of all reference
frames. `rep%` is how often the pipeline says anything at all. `oct%` and
`gross%` are as a fraction of frames where it did. `VR`/`FA` are voicing
recall and false alarm.

| variant | RPA% | rep% | oct% | gross% | held RPA% | held gross% | held \|err\| p50 | p90 | p99 | >5c% | jitter p90 | VR% | FA% |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **`app` (shipped)** | 62.79 | 74.71 | 0.43 | 15.52 | 80.86 | 0.91 | 2.45 | 7.70 | 16.25 | 22.18 | 3.65 | 71.69 | 17.07 |
| `app` without the median | 72.68 | 74.71 | 0.62 | 2.09 | 80.55 | 1.17 | 1.85 | 6.50 | 22.20 | 15.55 | 3.75 | 71.69 | 17.07 |
| `app` without the 0.9 gate | 73.81 | 86.23 | 1.25 | 13.16 | 88.29 | 1.04 | 2.60 | 8.40 | 17.65 | 24.51 | 3.85 | 86.05 | 33.83 |
| raw YIN, no gate, no median | 79.90 | 86.23 | 1.95 | 5.39 | 85.99 | 3.14 | 1.95 | 7.40 | 27.00 | 18.10 | 4.25 | 86.05 | 33.83 |

Read carefully, this table says three things.

**The `probability > 0.9` gate is doing real work.** It is an aperiodicity
threshold of 0.10 applied *after* tau has been chosen with a threshold of
0.20. That combination — choose the period loosely, accept the frame strictly
— is better than either threshold used for both jobs. Selecting with 0.10
directly (`yin-raw-0.10`, below) gives 2.22% octave errors; selecting with
0.20 and accepting at 0.10, as the app does, gives **0.43%**, at a comparable
report rate. Whether this was designed or fortunate, it should not be
"simplified" away.

**The median filter is the weak link.** It costs ten points of frame-level
RPA (62.79 vs 72.68) and multiplies gross errors sevenfold (15.52% vs 2.09%).
The cause is that `MedianFilter` is a window over the last five *accepted*
pitches with no notion of time. When frames are dropped — and one frame in
four is dropped — the window still holds pitches from a quarter of a second
ago, from a different note. It earns its place on the tail (held-note p99
16.25 vs 22.20 cents, and less jitter), but not at this price.

**Clearing the window when a frame is dropped fixes it:**

| variant | RPA% | gross% | held RPA% | held p99 | jitter p90 |
| --- | --- | --- | --- | --- | --- |
| `app` (shipped) | 62.79 | 15.52 | 80.86 | 16.25 | 3.65 |
| `app`, median cleared on a dropped frame | **71.88** | **3.20** | 80.80 | 16.20 | **3.25** |
| `app`, also cleared on a >100-cent jump | 71.93 | 3.10 | 80.76 | 16.20 | 3.25 |
| `app` without the median at all | 72.68 | 2.09 | 80.55 | 22.20 | 3.75 |

Clearing on a gap recovers nearly all of the lost accuracy, *keeps* the tail
benefit the median was there for, and lowers needle wobble as well. Adding a
jump reset on top changes nothing measurable — the gap reset already catches
note changes, because a note change drops frames.

### 2.1 The fix, implemented and re-measured

This is the one finding in the report that was acted on. The gate and the
median used to be two statements at the call site in `main.dart`, behind a
Flutter import where nothing could measure them; they are now
`PitchSmoother` in `lib/tuner_core.dart`, which gates the frame, smooths it,
and **clears the window whenever a frame is rejected**. `main.dart`,
`TunerEngine` and `tool/tuner_probe.dart` all go through it, and the
benchmark scores that class itself — the `app-fixed` variant below calls the
shipped code, not a model of it.

180 solo files, 151,882 monophonic frames, both variants in the same run:

| | RPA% | oct% | gross% | oct+gross% | held RPA% | held gross% | held p99 | jitter p90 | rep% | VR% | FA% |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| before (`app`) | 62.79 | 0.43 | 15.52 | 15.95 | 80.86 | 0.91 | 16.25 | 3.65 | 74.71 | 71.69 | 17.07 |
| after (`app-fixed`) | **71.88** | 0.59 | **3.20** | **3.79** | 80.80 | 0.87 | 16.20 | **3.25** | 74.71 | 71.69 | 17.07 |

**+9.09 points of frame-level accuracy, gross errors down from 15.5% to
3.2%, and 11% less needle wobble.** The modelled `app+median-gapreset`
variant produces identical numbers to three decimal places, which is the
check that the model and the implementation are the same thing.

Two honest caveats. First, the gain is entirely in *transitions*: on held
notes the numbers are unchanged to within a rounding error (80.86 → 80.80
RPA, p99 16.25 → 16.20), because a held note drops few frames and the stale
window rarely reaches back past the attack. What improves is the half-second
after you move to a new string, where the old behaviour could display a
pitch belonging to the previous note. Second, the octave-error rate goes
*up* slightly, 0.43% → 0.59% of reported frames. That is not a regression in
detection: it is the stale median having previously overwritten some
octave-wrong frames with stale-but-right-octave values, turning an octave
error into a gross error. Adding the two together, 15.95% → 3.79%, is the
fair comparison.

Nothing else changes: the gate is untouched, so the report rate, voicing
recall and false-alarm rate are identical to the digit. On the chordal
`_comp` set — material a tuner is not built for, §6 — the same change is
worth RPA 28.51 → 32.33 and gross errors 23.53% → 14.87%.

---

## 3. The three complaints against `pitch_detector_dart`

### 3.1 `defaultThreshold = 0.20`, "should be around 0.10~0.15"

The package's own comment is wrong for this application. Raw YIN, no gate, no
median, threshold swept:

| threshold | RPA% | rep% | **oct%** | gross% | VR% | FA% |
| --- | --- | --- | --- | --- | --- | --- |
| 0.05 | 62.55 | 67.05 | 2.99 | 3.72 | 64.33 | 11.41 |
| 0.10 | 73.04 | 77.80 | 2.22 | 3.90 | 76.50 | 19.93 |
| 0.15 | 77.51 | 82.92 | 1.98 | 4.54 | 82.34 | 27.39 |
| **0.20 (shipped)** | 79.90 | 86.23 | **1.95** | 5.39 | 86.05 | 33.83 |
| 0.30 | 82.05 | 91.00 | 2.27 | 7.56 | 91.13 | 44.58 |
| 0.40 | 82.07 | 94.29 | 2.81 | 10.16 | 94.49 | 52.87 |

The octave-error rate is not monotonic in the threshold; it *bottoms out* at
0.15–0.20 and rises in both directions. The reason is the selection rule:
aubio-YIN takes the first dip below the threshold. Lower the threshold and
the true period's dip — often 0.10 to 0.18 deep on a plucked string in a room
— stops qualifying, so the search runs on and settles on a deeper dip at
twice the period. The loose threshold is not admitting octave errors; it is
preventing them, and the strict `probability > 0.9` gate downstream is what
keeps the aperiodic frames out.

Tightening the threshold inside the app makes it slightly worse, and the
effect is on recall: `app-thr-0.10` gives 64.34% RPA with 1.24% octave errors
against the shipped 62.79% and 0.43%.

**Verdict: leave it at 0.20.** The comment in the package describes the YIN
paper's advice for a different decision than the one the app is making.

### 3.2 Step 6 of the YIN paper is a `TODO`

Implemented as the best local estimate within ±20% of the chosen tau (the
paper re-estimates over a longer window than the frame; within a frame this
is the same idea).

| variant | RPA% | oct% | gross% |
| --- | --- | --- | --- |
| raw YIN 0.20 | 79.90 | 1.95 | 5.39 |
| raw YIN 0.20 + step 6 | 79.98 | 1.95 | 5.30 |
| `app` | 62.79 | 0.43 | 15.52 |
| `app` + step 6 | 62.86 | 0.43 | 15.52 |

Eight hundredths of a point, on 151,882 frames. The paper's 0.77% → 0.5%
figure is for a speech corpus and a frame-level task; on plucked guitar at a
4096-sample window, the first dip and the best local minimum are the same
dip almost every time.

**Verdict: the `TODO` is harmless. Implementing it is neither a win nor a
risk.** Also measured: replacing the first-dip rule with the CMNDF's global
minimum, which some implementations prefer — that is much worse, 14.14%
octave errors against 1.95%.

### 3.3 The O(N²) difference function

This one is real, and it is the largest number in the report. Per frame, 4096
samples, on one core of this (busy, shared) VPS — treat the ratios as the
result and the absolute values as indicative:

| implementation | ms/frame | share of a 23 ms callback budget |
| --- | --- | --- |
| `pitch_detector_dart` 0.0.7, as shipped | 49–56 | **210–240%** |
| same algorithm, typed buffer + local accumulator | 17.6 | 76% |
| FFT difference function (this repo's `RefYin`) | 1.6–1.9 | **7–8%** |
| MPM / NSDF (also FFT) | 1.8–2.1 | 8–9% |
| phase-refinement alone | 0.4 | 2% |
| pYIN front end (FFT YIN + candidate set) | 1.6–1.9 | 7–8% |

The FFT version is bit-for-bit equivalent to 10⁻¹² cents and about **30×
faster than the shipped package**. Two separate things are going on: the
algorithm (10× — O(N log N) instead of O(N²)) and the package's Dart (3× —
it accumulates into a growable `List<double>` element rather than a local,
and the analysis buffer arrives as `List<double>` rather than `Float64List`).

The consequence is not theoretical. The app calls the detector on *every*
audio callback with a 4096-sample window. If a callback delivers 1024 samples
every 23 ms and a frame costs 50 ms, the detector cannot keep up; the futures
queue, the needle lags further than the 90 ms the window already costs, and
on a slower phone the app spends its battery budget on a double loop. This is
worth fixing whether or not anything else in this report is acted on — and it
is a pure drop-in: same output, same API shape, `fftea` is already a
dependency.

---

## 4. The alternatives

### 4.1 pYIN

A candidate distribution per frame (every CMNDF local minimum, weighted by a
Beta(2,18) prior over thresholds) and a Viterbi decode over a 10-cent pitch
grid with voiced/unvoiced states. Simplified relative to Mauch & Dixon 2014 —
see `lib/pyin.dart` — but faithful in shape.

| variant | RPA% | rep% | oct% | gross% | held RPA% | VR% | FA% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| raw YIN 0.20 | 79.90 | 86.23 | 1.95 | 5.39 | 85.99 | 86.05 | 33.83 |
| **pYIN** | **83.38** | 89.85 | **0.96** | 6.23 | **89.30** | 89.47 | 39.52 |
| `app` (shipped) | 62.79 | 74.71 | **0.43** | 15.52 | 80.86 | 71.69 | 17.07 |

pYIN does exactly what it promises: the best raw accuracy measured here, and
it halves raw YIN's octave errors. But the octave errors it is halving are
the ones the app has already removed by other means — the shipped pipeline's
0.43% is *less than half of pYIN's* 0.96%, because the gate throws out the
frames pYIN has to reason about. And the cost is structural, not
computational: Viterbi cannot decide frame *t* until it has seen the end of
the file. An online version needs a fixed decoding lag, which is more latency
on top of the ~90 ms the window already costs, in an app whose remaining
accuracy problem *is* latency.

**Verdict: not worth adopting for a tuner.** It would be the right answer for
offline transcription.

> **Correction (§24).** The second reason above — that an online pYIN needs
> a decoding lag costing prohibitive latency — was asserted, not measured,
> and it is **wrong**. Two frames of lookahead, 46 ms, reaches the offline
> accuracy. The first reason survives and is the one the verdict now rests
> on.

### 4.2 MPM / McLeod (NSDF)

| variant | RPA% | rep% | oct% | gross% | held RPA% | FA% |
| --- | --- | --- | --- | --- | --- | --- |
| MPM | 82.85 | 96.14 | 2.78 | 11.04 | 88.26 | 57.02 |
| MPM + median | 82.10 | 96.14 | 2.49 | 12.12 | 93.82 | 57.02 |
| raw YIN 0.20 | 79.90 | 86.23 | 1.95 | 5.39 | 85.99 | 33.83 |

MPM answers far more often (96% vs 86%) and is accordingly more accurate
per reference frame — but it answers when it should not: a 57% false-alarm
rate against YIN's 34%, and twice the gross-error rate. For a transcriber
that is a good trade. For a tuner, a needle that moves confidently while the
room is silent is the worse failure. Its clarity floor could be raised to
trade recall back, at which point it converges on YIN's behaviour.

**Verdict: no reason to switch.**

### 4.3 Precision refinements: instantaneous frequency and harmonic fitting

The premise of this line of work — that a tuner wanting ±0.1 cent is limited
by YIN's integer lag grid and parabolic interpolation — is false. On
synthetic plucked tones where f0 is known exactly (`bin/precision.dart`, 168
frames per case):

| estimator | quiet: bias / \|err\| p50 / p90 | noisy: bias / p50 / p90 | stiff string (B=10⁻⁴) |
| --- | --- | --- | --- |
| YIN, parabolic only | 0.02 / 0.05 / 0.10 | 0.11 / 0.25 / 0.65 | 0.74 / 0.70 / 1.00 |
| YIN + step 6 | 0.02 / 0.05 / 0.10 | 0.11 / 0.25 / 0.65 | 0.74 / 0.70 / 1.00 |
| MPM | 0.00 / 0.05 / 0.05 | 0.05 / 0.25 / 0.65 | 0.72 / 0.70 / 0.95 |
| YIN + instantaneous frequency | −0.00 / 0.05 / 0.65 | 0.01 / 0.25 / 1.10 | 1.86 / 1.90 / 2.20 |
| YIN + IF, stiffness fitted | −0.15 / 0.05 / 0.90 | −0.25 / 0.20 / 1.25 | **−0.02 / 0.05 / 0.90** |

(cents; all at a 4096-sample window)

YIN's existing interpolation already resolves **0.05 cents** on a clean tone.
It is not the bottleneck; noise is, and on real audio the reference itself
is. Phase-based refinement adds nothing on clean signals and makes the tail
worse on noisy ones. On the corpus, at each estimator's own best alignment,
it loses: held-note \|err\| p90 9.35 cents against the shipped pipeline's
7.70, and >5-cent frames 23.4% against 22.2%.

**Verdict: no.** Its one real benefit is the ~58 ms of latency it removes by
describing the end of the window instead of the start — which is worth
remembering if latency is ever attacked directly, but it is the wrong tool
for precision.

### 4.4 Inharmonicity

The stiffness fit works: given synthetic partials at f_n = n·f₀·√(1+Bn²) it
recovers B to within 25% and f₀ to within 0.05 cents, where every
periodicity-based detector (YIN, MPM) is 0.7 cents sharp — because the
*period* of a stiff string is set by its partials, not by its nominal
fundamental. That 0.7 cents at B = 10⁻⁴ is the size of the whole effect on
a guitar; at the corpus median of 1.7 × 10⁻⁴ it is a little over a cent.

Measured across the corpus (per-file medians of per-frame estimates): B ≈
**1.7 × 10⁻⁴** on the solo set (p10 1.2 × 10⁻⁴, p90 2.7 × 10⁻⁴), higher and
much noisier on the chordal set, where the peak-picking is contaminated by
other strings' partials.

So the machinery is sound and the numbers are plausible for steel strings.
But: it buys about a cent on guitar, GuitarSet contains nothing else, and the
instrument where inharmonicity genuinely matters — a piano, where B is an
order of magnitude larger on the bass strings and stretch tuning is a real
practice — is exactly the instrument this corpus cannot speak for. The
honest position is that this is a *feature* worth prototyping against piano
recordings, not a detector change justified by these measurements.

### 4.5 SWIPE′

The last of the brief's comparison points, and the one this report kept
putting off because it is expensive to run. SWIPE′ (Camacho 2007) works in
the spectral domain rather than the lag domain: it scores candidate pitches
by how well a cosine kernel placed at their *prime* harmonics matches the
square-root spectrum. Dropping the even harmonics is what is supposed to make
it octave-robust — a kernel an octave up cannot borrow support from the
partials it shares, because the shared ones are exactly the ones it dropped.

`lib/swipe.dart` implements it in shape: log-spaced candidates, a window
length per candidate (about eight periods) with interpolation between the two
bracketing power-of-two sizes, square-root spectra, prime-harmonic kernels.
It is not Camacho's MATLAB — his full estimator includes an ERB-scaled
loudness normalisation this does not — so read these as "SWIPE′-like".

**180 solo files, 235,560 frames**, through the same `PitchSmoother` as
everything else. (An earlier version of this section quoted 20 files, a
subset chosen by what one loaded VPS core would tolerate; the CI workflow
`bench-guitarset.yml` removed that constraint, and two of the conclusions
below changed when it did.)

| estimator | RPA% | rep% | oct% | gross% | \|err\| p50 | >5c% | FA% | ms/frame |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| app YIN | 71.88 | 74.71 | **0.59** | **3.20** | **3.00** | **28.6** | **17.1** | **1.02** |
| SWIPE′, global norm | **74.46** | 100 | 1.26 | 24.28 | 7.15 | 66.2 | 100 | 1.20 |
| SWIPE′, local norm | 59.01 | 100 | 8.71 | 32.28 | 6.80 | 64.5 | 100 | 1.20 |

Two corrections to what the 20-file subset suggested, both worth stating
because they went against the earlier reading.

**It is not several times more expensive; it is 18% more.** 1.20 ms a frame
against YIN's 1.02, measured in the same process on the same frames. The
earlier "several times" came from a standalone timing on a machine under load
10–30, where JIT warm-up and scheduling dominated. The structural argument —
several transforms per frame against YIN's one — is real, but `fftea` on a
quiet core absorbs it.

**And on the full corpus it out-scores YIN on raw pitch accuracy**, 74.46%
against 71.88%, which the subset did not show. That needs its context rather
than a headline: it answers on *100%* of frames where YIN answers on 75%, so
it collects correct frames YIN declines to guess at — and pays with a
false-alarm rate of 100%. It never rejects anything. A tuner whose needle
moves confidently in a silent room is worse than one that waits, which is why
this does not translate into a recommendation.

**What has not changed is everything a tuner is for.** Twice YIN's median
cent error (7.15 against 3.00), eight times the gross-error rate (24.3%
against 3.2%), and no usable voicing decision at any threshold — the
local-norm variant's strengths cluster so close to 1 that every threshold
from 0.2 to 0.75 gives the identical answer. Its intrinsic precision on clean
synthetic plucks is about 3 cents against YIN's 0.05, and a finer candidate
grid does not help (2.6 / 3.2 / 3.8 cents at 1/48, 1/96, 1/192 of an octave),
so the limit is the breadth of the strength curve rather than quantisation.

Recorded in the code because it is a trap: SWIPE′'s strength lands around
0.77 on a clean pluck, nothing like YIN's periodicity scale, so the app's
`probability > 0.9` gate rejects *every* frame. The first run of
`bin/swipe.dart` reported 0.00% across the board for exactly that reason.

This is a SWIPE′-*like* implementation, not Camacho's MATLAB — his full
estimator includes an ERB-scaled loudness normalisation this does not.

### 4.6 Neural models### 4.6 Neural models

Not measured, and the argument for skipping them is the shape of the results
above rather than a prejudice. CREPE and SPICE are frame-level classifiers
over a pitch grid — CREPE's is 360 bins of 20 cents, which still needs local
interpolation to reach a tuner's resolution — and even CREPE's smallest
configuration is on the order of half a million parameters, orders of
magnitude more arithmetic per frame than the 1.6 ms measured above, plus a
model file to ship and an inference runtime to embed in a Flutter app on four
platforms. What they would buy is robustness in polyphony and noise. What
this report shows is that in the monophonic case the app is built for, the
remaining error is not detection at all: the detector is right about the note
on 98.6% of the held-note frames it accepts, and the cent-level error is
dominated by latency and by what the string is actually doing. Nothing there is a neural
network's problem to solve.

---

## 5. Window size

60 solo files, all variants at the same alignment:

| window | `app` RPA% | held RPA% | held \|err\| p50 | jitter p90 | detection floor |
| --- | --- | --- | --- | --- | --- |
| 2048 (46 ms) | 59.22 | 78.67 | 3.00 | 4.10 | 43.1 Hz |
| **4096 (93 ms, shipped)** | 57.49 | 73.04 | 2.80 | 3.80 | 21.5 Hz |
| 8192 (186 ms) | 51.59 | 61.48 | 2.45 | 3.10 | 10.8 Hz |

The trade-off is exactly the textbook one: a longer window gives a finer
reading of a steady note (p50 3.00 → 2.45 cents) and tracks a moving one
worse (held RPA 78.67 → 61.48). On guitar alone, 2048 scores slightly better
than 4096 — but that is precisely the measurement GuitarSet cannot settle,
because the reason 4096 exists is a bass guitar's low E at 41.2 Hz and low B
at 30.9 Hz, which a 2048-sample window cannot represent at all and which this
corpus does not contain. 8192 is worse on every axis a tuner cares about.

**Verdict: 4096 stands.**

---

## 6. Chords, for completeness

The 180 `_comp` files, which are chordal and which a monophonic tuner is not
built for. 31,032 monophonic frames, 163,102 polyphonic ones.

On the frames that happen to be monophonic, everything degrades roughly in
proportion (`app` before the §2.1 fix: 28.51% RPA, 7.45% octave errors —
seventeen times the solo rate, because a "monophonic" instant inside chordal
playing still has other strings ringing in the window). On genuinely
polyphonic frames, the pipeline names *some* sounding string 22% of the time
it says anything at all (58% in the solo set, where the polyphonic frames are
mostly one note ringing under the next).

The median fix helps here too, for the same reason and by less: RPA 28.51 →
32.33, gross errors 23.53% → 14.87%, held-note p99 25.45 → 24.65 cents.

This is not a defect to fix. It is the reason a tuner asks you to play one
string at a time, and the numbers are here so that nobody has to guess how
badly it fails when you do not.

---

## 7. Two engines, measured against each other

The detector is now a seam (`lib/detectors.dart`) rather than a call, for two
reasons: the FFT difference function of §3.3 had to go somewhere, and once
there is an interface there can be an alternative — chosen in settings, and
measured here rather than argued about.

`engine-yin` and `engine-mpm` below run the app's own classes end to end:
`PitchEngine.of(kind)` into `PitchSmoother`, with nothing of the benchmark's
in between. `engine-yin` reproduces `app-fixed` to the digit across all
151,882 frames, which is the check that the vendored YIN really is the
shipped path and not a lookalike.

180 solo files:

| engine | RPA% | rep% | oct% | gross% | held RPA% | held \|err\| p50 | jitter p90 | VR% | FA% |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **YIN** (default) | 71.88 | 74.71 | **0.59** | **3.20** | 80.80 | 2.45 | 3.25 | 71.69 | **17.07** |
| MPM | 72.06 | 75.67 | 1.03 | 3.73 | 80.96 | 2.35 | 3.25 | 73.45 | 18.04 |

180 chordal files, where neither is really applicable:

| engine | RPA% | rep% | oct% | gross% | held RPA% |
| --- | --- | --- | --- | --- | --- |
| YIN | 32.33 | 41.30 | **6.86** | **14.87** | 52.86 |
| MPM | 32.30 | 43.52 | 9.53 | 16.26 | 52.91 |

MPM answers about a point more often and is a hair more accurate per
reference frame; it pays for that with nearly twice the octave-error rate on
solo material and a third more on chordal. Note how much tamer this is than
raw MPM in §4.2 (57% false alarm): the app's `probability > 0.9` gate reads
MPM's NSDF peak height, and demanding 0.9 clarity from an NSDF peak is a much
stricter test than demanding it of YIN's aperiodicity. The gate does most of
the work in both cases.

**So YIN stays the default**, and MPM is offered as "more sensitive", which
is exactly what the numbers say it is: it commits where YIN abstains, and is
wrong more often when it does. On a quiet instrument that trade is sometimes
the one a player wants; it is not the one to make for everybody.

Cost per frame, same machine and caveats as §3.3:

| | ms/frame | share of a 23 ms budget |
| --- | --- | --- |
| `pitch_detector_dart` 0.0.7 (what shipped) | 46.7 | 201% |
| app `YinEngine`, naive difference (same class, FFT off) | 10.7 | 46% |
| **app `YinEngine`** (what ships now) | **1.58** | **6.8%** |
| app `MpmEngine` | 1.64 | 7.0% |

The engine costs about a thirtieth of what the package did. Two thirds of
that came from the FFT and a third from writing the same double loop against
typed buffers.

## 8. What the partials say

`lib/harmonics.dart` measures the spectrum around the detector's answer: each
partial's frequency from its phase advance, the stiffness coefficient B, how
much energy is in the fundamental, and which partial the detector locked on
to. Measured over 160 solo files — deliberately *not* the 20 the thresholds
were tuned on — 121,834 pitched frames:

| | p10 | median | p90 |
| --- | --- | --- | --- |
| partials measurable per frame | 5 | 10 | 12 |
| share of measured energy in the fundamental | 0.16 | **0.48** | 0.79 |
| inharmonicity B (53% of frames support a fit) | 2.8×10⁻⁵ | **9.3×10⁻⁵** | 2.4×10⁻⁴ |

Two things worth taking away.

**The fundamental is not where the sound is.** Half the frames have under
half their measured partial energy in partial 1, and a tenth have under 16%.
A tuner that found pitch by looking for the strongest spectral peak would be
wrong constantly; this is the quantitative reason the period-based family
(YIN, MPM) is the right one, and it is also why the octave-guard idea below
does not work.

**Inharmonicity on a guitar is real but small.** B ≈ 9.3×10⁻⁵ stretches the
octave by **0.24 cents** — audible to nobody, and a quarter of the ~1 cent
§4.4 guessed at from a cruder estimator on all frames rather than on fitted
ones. It is measurable, the fit is validated against synthesis to within 25%,
and it remains the right machinery for a *piano* feature. On guitar it is a
curiosity.

### 8.1 The octave guard that does not work

The appealing idea: an octave error is the detector reporting partial 2 as if
it were partial 1, so the spectrum should be able to catch it. The
measurement says no.

A first version accepted "there is a peak an octave below" as evidence, and
claimed the detector was on the wrong partial for one frame in five. Requiring
the *odd* partials of the candidate fundamental instead — peaks at 1.5·f and
2.5·f, which cannot exist if f is the fundamental — quietens it down. Both
operating points, scored against the annotation:

| rule | recall on octave-wrong frames | correct frames wrongly flagged | precision |
| --- | --- | --- | --- |
| "a peak an octave below" | 39.7% | 28.30% | 1.0% |
| "the odd partials are there too" (held out, 160 files) | 9.0% | **0.81%** | 6.3% |

Neither is shippable, and the reason is arithmetic rather than tuning. After
the median fix the detector makes an octave error on **0.58%** of monophonic
frames (602 of 103,171). A guard that flags 0.81% of the correct frames to
catch 9% of the wrong ones makes the reading worse, not better — it would
throw away eight good frames for every bad one it caught. And the quiet rule
misses 91% of the errors because the frames where YIN takes the wrong octave
are exactly the frames where the fundamental is weak or the note is in
transition — the spectrum does not know either, because the information is
not there.

So the partial analyser ships as a measurement tool and the basis of the
inharmonicity work, and nothing in the UI consumes it. Nothing references it
at run time, so it is tree-shaken out of the app binary; it costs a reader's
attention and no bytes.

## 9. After the pluck: what the needle actually does

Everything above counts frames. A frame is not what anyone experiences: a
player plucks a string and watches, and what they notice is how long the
needle takes to mean anything and whether it stays put. Two pipelines with
identical RPA can feel completely different — a lagging median scores well on
a held note and still shows the *previous* note for a fifth of a second after
the pluck.

So `bin/notes.dart` takes GuitarSet's `note_midi` onsets, runs the pipeline in
time order, and times every reading from the pluck that produced it. A reading
is timed at the moment it could be **displayed** — when the last sample of its
window has arrived — which deliberately charges the analysis window to the
latency, because the user is charged for it too.

951 isolated notes (300 ms or longer, nothing else sounding across the pluck),
180 solo files, 512-sample hop. Times in ms from the pluck:

| pipeline | first reading p50 / p90 | first correct p50 / p90 | settled p50 | correct share | stale before settling (p90) |
| --- | --- | --- | --- | --- | --- |
| before the §2.1 fix | 96 / 126 | 121 / 161 | 110 | 76% | **13%** |
| **after the fix (ships now)** | 96 / 126 | **101 / 144** | **90** | 80% | **0%** |
| no median at all | 96 / 126 | 101 / 142 | 90 | 80% | 0% |
| MPM + `PitchSmoother` | 95 / 120 | 101 / 145 | 89 | 80% | 0% |

The same 951 notes at a 1024-sample hop — 23 ms between readings, closer to
what a phone's audio callback actually delivers:

| pipeline | first reading p50 / p90 | first correct p50 / p90 | settled p50 | correct share | stale before settling (p90) |
| --- | --- | --- | --- | --- | --- |
| before the §2.1 fix | 102 / 134 | 148 / 188 | 125 | 72% | **25%** |
| **after the fix** | 102 / 134 | **107 / 152** | **84** | 80% | **0%** |
| no median at all | 102 / 134 | 107 / 150 | 84 | 80% | 0% |
| MPM + `PitchSmoother` | 101 / 130 | 107 / 153 | 84 | 80% | 0% |

Three things fall out of these tables that the frame-level numbers could not
say.

**The median fix is worth 20 to 41 ms of visible latency**, and it removes
the stale display completely. "Stale before settling" is the share of readings
between the pluck and settling that were within 50 cents of the note you
played *previously* — at the 90th percentile, 13% of them were before the fix
at a 512-sample hop, and **25% at 1024**. That is the concrete form of the
bug: for a moment after you move to a new string, the old one is still on the
dial. It also explains why the cost scales with the hop: the stale window
spans five *accepted* readings, so the longer each reading takes to arrive,
the further back it reaches. On a device with large audio callbacks the old
behaviour was materially worse than these solo numbers suggest, and nothing
in the frame-level metrics would have shown that.

**The floor is the window, and the detector cannot beat it.** First reading
lands at 96 ms, and 4096 samples *is* 92.9 ms. Every millisecond of the
tuner's responsiveness beyond that is window and hop, not algorithm — so the
window is where latency work has to start, not the detector. (A window
straddling the pluck can sometimes already be right, since YIN needs only a
few periods; that is why the floor is a little under the full window rather
than exactly it.)

**The median is nearly free once it is time-aware.** Its remaining cost is
inside the noise against no median at all (107 vs 107 ms, 84 vs 84 ms at the
larger hop), while it still buys the tail and the jitter of §2.1. Before the
fix it cost 41 ms and a quarter of the post-pluck readings for the same
benefit.

Note that ~20% of notes never "settle" under this definition, for all four
pipelines alike: a reading goes wrong again in the last 150 ms of the note,
where the string has decayed into the noise floor. That is a property of
plucked notes ending, not of a pipeline.

### 9.1 While the pitch is moving

§9 times the tuner's cold start. The other half of the experience is what
happens *while you turn the peg*: the pitch slides and the needle follows it
at some remove. Every frame-level metric in this report is blind to that — a
pipeline that is uniformly 60 ms late scores a perfect RPA.

GuitarSet has no peg-turning, but it has the same signal musically: bends and
slides, where the annotated pitch moves smoothly within one sounding string.
`bin/tracking.dart` finds how far the detected contour has to be shifted in
time to best match the annotated one. Only *monotonic* movement of at least
40 cents counts — vibrato is movement too, but it is periodic, so a 5 Hz
wobble fits a lag of 0 ms and 200 ms equally well, and including it would
report aliases as measurements.

60 solo files, 739 qualifying segments, 512-sample hop:

| pipeline | tracking lag p10 / p50 / p90 | RMS error at best lag | RMS error unshifted |
| --- | --- | --- | --- |
| before the §2.1 fix | −0 / **26** / 93 ms | 4.51 cents | **16.58 cents** |
| **after the fix** | −12 / **17** / 76 ms | 3.50 cents | **5.94 cents** |
| no median at all | −18 / **−0** / 58 ms | 4.00 cents | 5.23 cents |
| MPM + `PitchSmoother` | −12 / 17 / 70 ms | 3.42 cents | 5.65 cents |

**Unsmoothed YIN tracks a moving pitch with no lag at all** — a median of
zero, to the resolution of the hop. That is a second, independent
confirmation of §1's alignment finding: YIN's answer really does describe the
start of its window, because assuming so makes the lag vanish.

**The median costs 17 ms of tracking lag**, and that is what it is worth
asking whether to pay. It buys the tail and the jitter of §2.1; it costs a
needle that trails the string by about a frame and a half while you are
turning the peg. Before the fix it cost 26 ms *and* left the displayed value
**16.6 cents** off the true pitch during a bend, against 5.9 after — because
a window that reaches back across a gap is averaging pitches from a fifth of
a second ago, which on a moving string is a different pitch entirely.

There is a design suggestion buried in that last column, not acted on here:
the median is helping on a held note and hurting on a moving one, and the
pipeline already knows which it is looking at.

## 10. Neural transcription: Basic Pitch and MT3, measured

§4.6 argued against neural models from the shape of the other results rather
than from measurement. Two GGUF conversions — `cstr/basic-pitch-GGUF` and
`cstr/mt3-GGUF` — made it cheap to stop arguing, so `tool/basic_pitch_eval.py`
runs Spotify's Basic Pitch over the same corpus, scored by the same rules as
`bin/bench.dart`: same annotations, same monophonic-frame definition, same
50-cent rule, same octave/gross split, alignment swept the way §1 swept it.

60 solo files, 96,302 monophonic frames, ONNX Runtime on CPU:

| | Basic Pitch | app YIN (§7) |
| --- | --- | --- |
| RPA | **86.15%** | 71.88% |
| reported | 92.28% | 74.71% |
| accuracy when reporting | 93.35% | **96.18%** |
| octave errors | **0.18%** | 0.59% |
| gross errors | 6.47% | **3.20%** |
| \|err\| p50 / p90 / p99 | **27.5 / 34.6 / 46.1 cents** | **2.45 / 7.70 / 16.25** |
| frames beyond 5 cents | 98.95% | 22.18% |
| voicing recall / false alarm | 93.6% / 30.1% | 71.7% / **17.1%** |
| cost per unit of audio | 270 ms per 2 s window | 1.58 ms per 93 ms window |

**It names notes well and cannot measure cents at all.** That is the finding,
and it is structural rather than a matter of tuning: the contour head is a
posteriogram at 3 bins per semitone — 33 cents a bin — and even with parabolic
interpolation across the peak the median error is **27 cents**. Nearly every
frame is beyond the ±5 cents a tuner exists to resolve. No amount of inference
speed changes that; it is what the output layer can represent.

Everywhere else it is a genuinely strong model: it answers on 92% of frames
against YIN's 75%, and its octave-error rate is a third of YIN's. It is
better than YIN at the question *it* was built for — which note, and when —
and useless at the question a tuner asks.

### 10.1 Could it run in something like real time?

Two numbers decide that, and they point in opposite directions.

**It is effectively causal, which was not obvious.** Every frame Basic Pitch
emits sits inside a fixed 2-second window and is computed with audio from
*after* it, so the natural assumption is that a realtime sliding-window
implementation would have to display frames that had no right-context and
were therefore worse. Measured, they are not:

| audio following the frame inside its window | accuracy |
| --- | --- |
| 0–99 ms (what a realtime implementation would show) | 92.85% |
| 400–499 ms | 93.55% |
| 1500–1599 ms | 94.02% |

Under a point of difference between the newest frame and the most
comfortably-padded one. So a sliding window is viable, and the latency is
inference time plus hop — not the 2 seconds the input length suggests.

**The cost is the problem, and it depends entirely on the runtime.** On this
(shared, loaded) VPS core:

| runtime | per 2 s window | share of real time | parity |
| --- | --- | --- | --- |
| ONNX Runtime, C++ CPU | 174–270 ms | 9–14% | reference |
| `onnx_runtime_dart` 0.10.7, pure Dart JIT | ~1.5 s | ~75% | **exact** — contour sum 4766.68 vs 4766.676, same argmaxes, no missing operators |
| same, AOT (`dart compile exe`) | ~3.0 s | ~150% | exact |
| **after optimisation** (see below) | **498 ms** best, 600–730 ms typical under load | 25–37% | **bitwise identical** |

Native ORT leaves room for a sliding window updated two to four times a
second at a fraction of a core. Pure Dart did not, at first: ~5.6–8.7× ORT.
(AOT is *slower* than JIT here, which is ordinary for hot numeric loops.)

So the runtime was optimised, and the result is worth recording because the
obvious hypothesis was wrong.

Profiling the graph with **native ORT** attributes 66% of node time to `Conv`,
with the nnAudio CQT front end — convolutions with very long kernels —
prominent among them. Long-kernel convolution is exactly what an FFT does
cheaply, the same trade §3.3 made for YIN's difference function at 10×. That
was the plan.

**Profiling it in Dart said something else.** The 256-tap CQT convolutions are
about 6% of the Dart cost. What dominates is *small-output-channel* 2-D
convolutions, and the reason is an implementation detail rather than
arithmetic: an im2col GEMM materialises a column matrix of
`cPerGroup·kh·kw × oh·ow` floats and reuses each entry only `mPerGroup`
times, so the model's 8→8-channel 3×39 convolution was building a **170 MB
column matrix to perform 340 MMAC**. Replacing im2col with a direct,
`Float32x4`-accumulated kernel for few-channel convolutions was worth 11.1×
on that shape alone.

| change | worth |
| --- | --- |
| im2col-free direct conv for few output channels | 1.8–11.1× per shape |
| `Slice` contiguous-run fast path | 112 ms → 8.6 ms in-graph |
| `ReduceSum`/`Pad`/`Concat` fast paths, cached `Tensor.length` | 1.9–9.4× per op |
| register-rotated input window | 1.13–1.24× on the affected convs |
| **total** | **1509 ms → 498 ms, ~3×** |

Parity is not approximate: each kernel accumulates in the same order as the
GEMM it replaces, so conv outputs are **bitwise identical**, and the model's
353-test fixture suite passes unchanged. The FFT idea was assessed with
numbers and *not* implemented: for the dominant 39-tap convolution a 512-point
real FFT is ~5× fewer operations, but scalar-complex ones against a
`Float32x4` direct kernel — under 2× on that node, at the cost of
reassociating the arithmetic and losing bitwise parity.

That work is a PR against `CrispStrobe/onnx_runtime_dart`, not part of this
repository. What it means here: **pure-Dart Basic Pitch now runs at roughly a
quarter to a third of real time on one core of a loaded shared VPS**, which
puts a sliding window updated once or twice a second within reach on a decent
device — without any native dependency, on every platform including web. The
next step, if it is wanted, is multi-core: convolution is now 86% of the
profile and one node is 38% of a run, so banding it across isolates is the
obvious 2–3× — but the pool copies the whole activation per message today,
which has to be fixed first.

### 10.2 The rest of the neural field, measured

Basic Pitch answers a different question (polyphonic transcription). The
models below answer *this* one: they are monophonic frame-level f0
estimators, the job `lib/detectors.dart` does. All were run on Kaggle, on the
same 60 solo files, scored by the same rules, with the frame alignment swept
as §1 sweeps it — and with each model's confidence threshold swept too,
because a single fixed threshold is not a comparison. SWIPE′ already showed
how badly that can mislead (§4.5, where one scale mismatch rejected every
frame); PESTO showed it again here, scoring 40% RPA at a 0.5 threshold and
85% at 0.1.

Each model at the threshold that puts its false-alarm rate closest to YIN's
17%, which is the only way to compare them on equal terms:

| estimator | RPA% | rep% | oct% | gross% | \|err\| p50 | >5c% | FA% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **app YIN** | 71.9 | 74.7 | 0.59 | 3.20 | **2.45** | **22.2** | 17.1 |
| crepe-tiny @0.75 | 74.3 | 76.0 | 0.27 | **1.98** | 5.16 | 51.2 | 15.0 |
| crepe-full @0.75 | **80.7** | 83.0 | 0.24 | 2.55 | 5.23 | 51.8 | 22.1 |
| crepe-full-viterbi @0.75 | 69.2 | 70.8 | **0.07** | 2.25 | 8.12 | 67.6 | 15.9 |
| crepe-tiny-viterbi @0.5 | 55.0 | 57.3 | 0.21 | 3.86 | 8.33 | 68.2 | 17.2 |
| pesto @0.25 | 53.9 | 57.7 | 0.47 | 6.19 | 8.70 | 69.9 | 13.5 |
| fcnf0++ @0.25 | 40.1 | 49.1 | 4.67 | 13.6 | 7.23 | 64.8 | 16.3 |
| spice @0.9 | 52.0 | 56.5 | 0.05 | 7.93 | 6.74 | 62.9 | 27.7 |

**CREPE beats YIN at deciding which note, and loses at cents by a factor of
two.** crepe-full finds the right note on 81% of reference frames against
YIN's 72%, with a third of the octave errors — and its median cent error is
5.5 against 2.45, with more than half its frames beyond the ±5 cents a tuner
exists to resolve. That is the same shape of result as Basic Pitch, from an
entirely different architecture, which is what makes it worth believing.

Three things worth drawing out.

**Viterbi decoding does exactly what it claims, and it is not enough.**
CREPE's temporal decoder cuts octave errors to 0.07% — the lowest figure
anywhere in this report, a quarter of YIN's — and costs precision: p50 goes
from 5.49 to 8.08 cents. It is the same trade pYIN offered in §4.1 and it
fails for the same reason: the octave errors it removes are ones the app's
gate has already removed.

**Bin resolution is not the binding constraint.** FCNF0++ quantises to
**5-cent bins**, four times finer than CREPE's 20, and still lands at 7.60
cents median — worse than CREPE. So the coarse output grid is not what stops
these models measuring cents; what they learned to represent is.

**Precision improves with confidence, and never far enough.** crepe-tiny's
median error falls from 5.77 cents at a 0.1 threshold to 3.66 at 0.9 — but at
0.9 it answers on 15% of frames. YIN gives 2.45 cents on 75% of them.

Two models need a footnote. **SPICE** is the only one here predicting
*relative* pitch: its output needs the published affine calibration to become
hertz, so a systematic error in that calibration is indistinguishable from a
tuning error. It never reaches YIN's false-alarm rate at all — 27.7% at its
most conservative setting against YIN's 17.1% — so its row is the only one
not matched on FA. **PESTO's second checkpoint** (`mir-1k`, against the
default `mir-1k_g7`) could not be run: through the packaged `predict` path it
raises `mat1 and mat2 shapes cannot be multiplied (2233x87 and 72x1)`, the
checkpoint expecting a different CQT width. Reported as a failure rather than
quietly omitted.

**A caveat on the cent figures.** Three runs of crepe-tiny over the same
corpus, same alignment, same threshold gave medians of 5.58, 6.06 and 5.77
cents. Pinning cuDNN's algorithm choice narrowed the spread without removing
it — most likely because Kaggle hands out different GPU hardware between
sessions, which changes floating-point results regardless. PESTO was
bit-identical across all three. So read CREPE's precision as "about 5.5 to 6
cents", not to three digits; nothing in the conclusion turns on it, since
YIN's 2.45 is a factor of two away.

### 10.3 MT3

96 MB, 46.9M parameters, a T5 encoder–decoder emitting event tokens
autoregressively over multi-second context. Nothing about that is compatible
with a tuner's latency budget, and it would multiply the app's download size
many times over. As an offline "record a phrase, get a MIDI file" feature it
is plausible; as anything on the audio path it is not, and it was not
measured here because the architecture answers the question by itself.

### 10.4 So what would it be for?

Not the needle. YIN keeps that: 2.45 cents against 27, at a six-hundredth of
the cost per unit of audio.

What Basic Pitch could add is the thing the current app cannot do at all —
**polyphony**. Strum once and tune six strings; show a chord; transcribe a
phrase. Those are features, not accuracy improvements, and they would run as
a separate mode with its own budget, leaving the tuner path exactly as it is.
If that mode is wanted, the measured order is: native ORT works now; pure
Dart is within reach after the 3× above and would keep the app
dependency-free on all six platforms including web; MT3 stays offline.

## 11. A bowed instrument: cello

Every result above this line is guitar, and §12 has listed that as the
report's largest limitation from the beginning. MUSERC (Zenodo 1560651,
CC BY 4.0) closes part of it: 132 recordings of one professional and one
amateur cellist, 48 kHz, seven notes from D3 to C♯4, in steady "tune" takes,
"novib" takes at three dynamics, and vibrato takes. It runs on CI
(`.github/workflows/bench-cello.yml`) rather than on a developer's machine.

What that corpus can answer is narrower than GuitarSet's, and worth stating
before the numbers. Its own ground truth is a finger-position sensor which
needs a physical calibration to become hertz, so it is not used here. The
filename gives the note the cellist was aiming at — enough to ask whether the
tuner names the right note and whether it ever jumps an octave. And the
questions that need no reference at all are the ones a player actually cares
about: how still the needle sits, and what happens to vibrato.

### Steady takes, bow attack excluded

**With the `tune` takes excluded, and that exclusion is the point of §11.1.**

| pipeline | named correctly | octave errors | frames reported | spread p90 | jitter p90 |
| --- | --- | --- | --- | --- | --- |
| before the §2.1 fix | 100.0% | **0.0%** | 99.7% | 5.48 c | 0.44 c |
| **after the fix (ships now)** | 100.0% | **0.0%** | 99.7% | 5.48 c | **0.44 c** |
| no median at all | 100.0% | 0.0% | 99.7% | 5.48 c | 0.90 c |
| MPM + `PitchSmoother` | 100.0% | 0.0% | 100.0% | 5.49 c | 0.45 c |

**The tuner is better on a cello than on a guitar, on every axis.** Not one
octave error in any pipeline; a reading on 99.7% of frames against 74.7% on
guitar; needle jitter of **0.44 cents against 3.25**; and on the takes whose
label can be trusted, it names the right note on *every* frame.

The reason is not subtle and it reframes most of this report: a bowed note is
*sustained*. It does not decay into the noise floor while you look at it, so
the detector is never working with the tail of a transient. Everything
measured on guitar was measured on the harder case.

Note also what the median does here: it halves the jitter (0.44 against 0.90)
and costs nothing measurable in return. On a steady bowed note it is doing
exactly the job it was put there for.

### Vibrato — does the smoothing flatten it?

A cellist holding a note is moving it, several times a second, by tens of
cents. Every smoothing decision in `PitchSmoother` was made on a corpus where
that was rare, so it needs checking rather than assuming.

| pipeline | vibrato excursion recovered, p50 | p90 |
| --- | --- | --- |
| no median at all | **38.98 c** | 60.22 c |
| after the fix | 35.41 c | 55.48 c |
| before the fix | 34.01 c | 55.45 c |
| MPM + `PitchSmoother` | 34.95 c | 55.50 c |

The median costs about **9% of the vibrato** — 3.6 cents of a 39-cent
excursion. Real, measurable, and modest: the needle still shows a cellist
their vibrato, slightly narrowed. That is the trade for halving the jitter,
and on this evidence it is the right one. It is also invisible to every
guitar measurement in this report.

### Per note, and one anomaly that is the corpus's

| note | nominal | takes | named | spread p90 | measured offset |
| --- | --- | --- | --- | --- | --- |
| D3 | 146.83 Hz | 10 | 100.0% | 5.23 c | +1.9 c |
| D♯3 | 155.56 Hz | 10 | 100.0% | 11.06 c | +1.9 c |
| E3 | 164.81 Hz | 9 | 100.0% | 6.26 c | −1.1 c |
| **F3** | 174.61 Hz | 4 | **0.0%** | 6.05 c | **−86.2 c** |

Median offset across takes: **−3.6 cents**. The instrument was at A440, and
the tuner agrees with it to within a few cents on every note but one.

The F3 row is the corpus's, not the detector's. All four takes labelled 53
measure 165.5–169 Hz — **E3**, some 90 cents below the F3 the label claims —
and an independent FFT of the raw audio agrees with the detector to within a
few cents. Either those files are mislabelled or the note was played nearly a
semitone flat four times running by a professional; four takes cannot settle
which, and scoring it as a detector error would be wrong either way.

### 11.1 The numbers this section used to carry were wrong

An earlier version of this section reported "named 98.7%" and a median offset
of **−31.8 cents**, and concluded from the second of those that the cellist
had tuned to A = 432 Hz — a tidy story, and false.

MUSERC's takes come in four kinds, and I read the filenames as though they
came in one. The `tune` takes are the cellist *tuning the instrument*:
`pro_60_tune_1` is labelled 60 and contains a 220 Hz open A;
`pro_53_tune_2` is labelled 53 and contains a 97 Hz open G. Scored against
the label, 23 of the 55 "steady" takes were being compared to a note they do
not contain, and the −31.8 cent "A432 tuning" was the median of that damage
rather than a property of the instrument. With them excluded the offset is
−3.6 cents: A440, as one would expect.

Two things kept it standing longer than it should have. The headline figures
were medians *over takes*, which survive a minority of bad takes almost
unchanged — that robustness hid the problem instead of exposing it. And the
error had an explanation ready to hand: a cellist at A432 is a perfectly
ordinary thing, so the number looked like a finding rather than a bug.

It was caught by running the neural models over the same corpus and noticing
they disagreed with the labels far more than with each other — CREPE reported
220 Hz for a file labelled C4, stably, to within one cent. The generalisable
lesson is that **a plausible explanation is not evidence**, and the check
that mattered was the cheap one nobody had run: looking at the actual
spectrum of one file.

### 11.2 The neural models on a bowed instrument

None of CREPE, PESTO or FCNF0++ has seen much cello: they are trained
overwhelmingly on speech, singing and plucked instruments, so a bowed string
with heavy vibrato is where a learned model has most room to disappoint.
Measured over the same steady takes, by the same rules, median over takes:

| estimator | reported | named | octave | spread p90 | offset |
| --- | --- | --- | --- | --- | --- |
| **app YIN** | 99.7% | 100% | 0.0% | 5.48 c | −3.6 c |
| crepe-full @0.5 | 99.8% | 100% | 0.0% | **1.10 c** | +3.0 c |
| fcnf0++ @0.5 | 90.3% | 100% | 0.0% | 6.53 c | −5.7 c |
| crepe-tiny @0.5 | 99.7% | 100% | 0.0% | 16.79 c | +2.0 c |
| pesto @0.5 | 83.3% | 100% | 0.0% | — | −0.0 c |

They do not disappoint. Every one of them names the right note on
essentially every frame, with no octave errors at all — the instrument that
was supposed to be hardest for them turns out to be the easiest thing in this
report for everybody.

And one number here runs against the grain of §10. **crepe-full's reading is
five times steadier than YIN's on a sustained bowed note** — 1.10 cents of
spread at the 90th percentile against 5.48 — while sitting 3 cents from the
nominal. That is not the same quantity as §10's cent *error*, which is
measured against a reference; this is stillness, measured against the take's
own median, and stillness is what a needle shows. On a bowed note, which
does not decay, a model that reads the whole spectrum has more to work with
than a lag-domain detector does.

It does not change the recommendation, for a reason that has nothing to do
with accuracy: crepe-full costs 8.2% of real time *on a GPU*, and roughly
eight times real time on one CPU core. A tuner cannot spend that. But the
accuracy objection to neural pitch detection, which §10 established on
guitar, does not hold for bowed strings, and that is worth knowing before
anyone decides what to build next.

PESTO's spread is blank because the harness recorded none for it — not a
zero, an absence — and it has not been chased.

### 11.3 So: no, do not fine-tune on cello

The question this section was run to answer was whether these models need
fine-tuning for bowed strings. On this evidence there is nothing to fix:
100% note naming, no octave errors, and in crepe-full's case a steadier
reading than the shipped detector's.

It is also worth saying what fine-tuning *could* have used. MUSERC is 132
takes of seven notes between D3 and C♯4 from two players — a register and a
half, one instrument, one room. Training on it would buy a model that is
excellent at seven notes. The data to do it properly does not exist here, and
the measurement says it is not needed.

## 12. Chords: the measurement the transcription mode rests on

Every neural number above came from GuitarSet's `_solo` files. That is
single-line playing, and for judging a *polyphonic* transcriber it is the
wrong material: it measures how well Basic Pitch does a job YIN already does,
and says nothing about whether it can name several notes at once. Since the
app now has a transcription mode built on exactly that claim, it needed
testing.

`bench/tool/kaggle/polyphonic-eval` scores the note head against the chordal
half of the corpus with the metric that applies to sets rather than to single
values: per-frame precision, recall and F1 over the notes sounding,
micro-averaged. **All 180 files, 377,956 reference frames**, and the material
is genuinely polyphonic —

| notes sounding | share of frames |
| --- | --- |
| 1 | 16.3% |
| 2 | 18.6% |
| 3 | 25.3% |
| 4 | 27.1% |
| 5 | 9.5% |
| 6 | 3.2% |

— averaging 3.04 notes at once, which sets the ceiling for anything
monophonic. **A perfect single-note detector can reach 32.9% recall on this
material and no more**, because naming one note of three is all it can do.

| threshold | precision | recall | F1 |
| --- | --- | --- | --- |
| 0.3 | 78.6% | **80.1%** | **79.3%** |
| **0.4 (shipped)** | 84.9% | 72.1% | 78.0% |
| 0.5 | 89.2% | 61.6% | 72.8% |
| 0.6 | 92.3% | 46.8% | 62.1% |
| 0.7 | 94.9% | 28.6% | 44.0% |

**2.4× the recall a monophonic detector could reach, at 85% precision** at
the threshold the app ships. This table is the whole corpus; an earlier run
on 60 of the 180 files gave 86.7% precision and 72.0% recall at the same
threshold, so the subset was not misleading here — which is worth knowing,
since it was not something to assume. That
is the justification for the mode existing, and it is the first number in
this report that argues *for* adding something rather than against.

The app ships the 0.4 threshold rather than the F1-optimal 0.3: a display is
not an F1 score, and a note shown that is not being played is the worse error,
because the player can see what they are holding.

### 12.1 How this nearly went the other way

The first run of this evaluation returned **28.1% F1 with 21.2% recall** —
below the monophonic ceiling, which would have meant a polyphonic model that
cannot beat naming one note, and the honest conclusion would have been to
delete the mode.

It was wrong. The ONNX export names neither of its two 88-wide heads, and the
order is not the obvious one: `StatefulPartitionedCall:1` is the note head,
`:2` is onset. Having assumed otherwise, I had scored the **onset** head as
if it were notes. Onsets fire for a few frames at a note's start; note
activations are sustained for its duration, so the mistake shows up as a
plausible-looking bad model rather than as an error.

Two things now prevent it recurring: the kernel identifies the heads at
runtime by how long their activations run — 59 frames against 11.5 on real
audio — and prints its decision, and the app hard-codes the answer with a
test asserting it. Worth stating in full because the failure mode is general:
**an unlabelled model output does not announce that it has been misread, and
a wrong answer that looks like a mediocre model is the hardest kind to
notice.**

## 13. Every number in one place

Two corpora, one set of rules: a 4096-sample window, the frame scored at the
instant the estimator's answer actually describes (§1), correct within 50
cents, octave errors separated from gross ones.

### Guitar — GuitarSet, 180 solo files, 151,882 monophonic frames

| pipeline | RPA% | rep% | oct% | gross% | \|err\| p50 | >5c% | VR% | FA% |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **app, as it ships** | 71.88 | 74.71 | **0.59** | **3.20** | **2.45** | **22.2** | 71.7 | **17.1** |
| app before the §2.1 fix | 62.79 | 74.71 | 0.43 | 15.52 | 2.45 | 22.2 | 71.7 | 17.1 |
| app with no median | 72.68 | 74.71 | 0.62 | 2.09 | 1.85 | 15.6 | 71.7 | 17.1 |
| MPM + `PitchSmoother` | 72.06 | 75.67 | 1.03 | 3.73 | 2.35 | 21.4 | 73.5 | 18.0 |
| SWIPE′ (global norm) | 74.46 | 100 | 1.26 | 24.28 | 7.15 | 66.2 | 100 | 100 |
| raw YIN, no gate or median | 79.90 | 86.23 | 1.95 | 5.39 | 1.95 | 18.1 | 86.1 | 33.8 |
| pYIN (offline Viterbi) | 83.38 | 89.85 | 0.96 | 6.23 | 2.05 | 19.5 | 89.5 | 39.5 |
| crepe-full @0.75 | 80.71 | 83.02 | 0.24 | 2.54 | 5.23 | 51.8 | 78.3 | 22.1 |
| crepe-tiny @0.75 | 74.32 | 76.03 | 0.27 | 1.98 | 5.16 | 51.2 | 69.8 | 15.0 |
| crepe-full-viterbi @0.75 | 69.16 | 70.81 | **0.07** | 2.25 | 8.12 | 67.6 | 65.6 | 15.9 |
| pesto @0.25 | 53.86 | 57.70 | 0.47 | 6.19 | 8.70 | 69.9 | 57.6 | 13.5 |
| fcnf0++ @0.25 | 40.12 | 49.07 | 4.67 | 13.56 | 7.23 | 64.8 | 46.5 | 16.3 |
| spice @0.9 | 52.02 | 56.54 | 0.05 | 7.93 | 6.74 | 62.9 | 48.7 | 27.7 |
| Basic Pitch @0.5 | 86.15 | 92.28 | 0.18 | 6.47 | 27.5 | 99.0 | 93.6 | 30.1 |

Guitar, in time rather than in frames (§9, §9.1):

| | first reading | first correct | tracking lag |
| --- | --- | --- | --- |
| app, as it ships | 96 ms | **101 ms** | **17 ms** |
| app before the fix | 96 ms | 121 ms | 26 ms |
| app with no median | 96 ms | 101 ms | −0 ms |

### Cello — MUSERC, steady takes with a trustworthy label

| pipeline | reported | named | octave | spread p90 | jitter p90 | offset |
| --- | --- | --- | --- | --- | --- | --- |
| **app, as it ships** | 99.7% | **100%** | **0.0%** | 5.48 c | **0.44 c** | −3.6 c |
| app before the §2.1 fix | 99.7% | 100% | 0.0% | 5.48 c | 0.44 c | −3.6 c |
| app with no median | 99.7% | 100% | 0.0% | 5.48 c | 0.90 c | −3.6 c |
| MPM + `PitchSmoother` | 100% | 100% | 0.0% | 5.49 c | 0.45 c | −3.6 c |
| crepe-full @0.5 | 99.8% | 100% | 0.0% | **1.10 c** | — | +3.0 c |
| fcnf0++ @0.5 | 90.3% | 100% | 0.0% | 6.53 c | — | −5.7 c |
| crepe-tiny @0.5 | 99.7% | 100% | 0.0% | 16.79 c | — | +2.0 c |
| pesto @0.5 | 83.3% | 100% | 0.0% | — | — | −0.0 c |

Cello, in time (§13.1): **85 ms** to a first reading after the bow starts,
**96 ms** to a correct one, and nothing wrong after it — identical across all
four pipelines, because on a bowed note there is nothing for the smoothing to
rescue.

### Chords — GuitarSet, 180 comp files, 377,956 frames

| | precision | recall | F1 |
| --- | --- | --- | --- |
| Basic Pitch @0.4 (ships) | 84.9% | 72.1% | 78.0% |
| Basic Pitch @0.3 | 78.6% | 80.1% | **79.3%** |
| any monophonic detector | — | **32.9% ceiling** | — |

The runtime comparison of §17 scores the same model on a subset of the same
material (8 files rather than 180), so its absolute numbers are not
comparable to the rows above — the rows to compare are against each other:

| runtime, 8 comp files, 1 thread | precision | recall | F1 | per 2 s window |
| --- | --- | --- | --- | --- |
| Basic Pitch @0.4, pure Dart (ships) | 88.2% | 67.2% | 76.2% | 624 ms |
| Basic Pitch, CrispASR/ggml | 84.4% | 75.6% | **79.7%** | **345 ms** |

### The one-line summary

The shipped pipeline is the best thing here for the job it does. Three
estimators beat it on raw pitch accuracy — pYIN, raw YIN and SWIPE′ — and
every one of them does so by answering more often and being wrong more often
when it does. Nothing comes within a factor of two of it on cents, which is
the only number a needle shows.

### 13.1 Using the cello corpus's sensor track

MUSERC ships more than audio: every take has a 752 Hz CSV carrying the
finger position on the fingerboard, three accelerometer axes, and a low-rate
copy of the audio. §11 did not use it, which was defensible for the steady
takes — the filename gives the note — and not for the vibrato takes, where
the filename gives one number for a pitch that moves five times a second.

Turning position into hertz needs a physical model, and the useful one is
simple. For a string stopped at distance `x` from the nut,
`f = f_open · L / (L − x)`, so **1/f is linear in finger position** — the
calibration is a straight-line fit over the steady takes, whose pitch the
label gives, with no free parameters beyond two coefficients.

It holds structurally and imprecisely: **R² = 0.974** on both sensors, with a
residual of **6.2 and 12.1 cents**. So it is a *contour* reference — good for
when the pitch moved, useless for scoring anyone's intonation. Two details
that mattered more than the fit: the CSV's `Time` column runs on the
session's clock (one take's starts at 140.45 s), and rebasing on the first
timestamp still leaves 10–30 ms of drift, which is fatal when the effect
being measured is about 20 ms. The CSV's own audio column makes that
measurable per take rather than assumed away — the applied correction has a
median of −5 ms and a p10–p90 of −19 to +13 ms.

Tracking lag against that reference, over 70 vibrato takes:

| pipeline | lag p10 | p50 | p90 |
| --- | --- | --- | --- |
| before the §2.1 fix | −11 ms | **+11 ms** | +32 ms |
| after the fix | −11 ms | **+11 ms** | +32 ms |
| no median at all | −32 ms | **−21 ms** | +11 ms |

**The median costs about 32 ms of tracking on cello vibrato**, against the
17 ms §9.1 measured on guitar bends — the same effect, larger here because
the hop is longer at 48 kHz. What is *not* trustworthy is the absolute
column: the reference carries ±20 ms of its own timing error, so the lag of
a single pipeline is not meaningful to better than that. The *difference*
between pipelines is, because they share the reference exactly.

A note on why the search window matters. Vibrato is periodic, so a lag of
zero and a lag of one whole cycle fit equally well — the aliasing that made
§9.1 exclude vibrato from the guitar measurement. A first run of this with a
±192 ms search returned percentiles pinned to the boundary, which looked like
a wide distribution and was really a fit with no unique answer. Holding the
search inside a half-cycle is what makes the numbers above mean anything.

## 14. What a phone or a laptop would do with this

Every timing above came from one shared VPS core whose load average ranged
from 2 to 30 over the course of this work, and several sections say so. The
question that actually matters — can a phone run it — deserved a number
rather than an extrapolation, and GitHub's macOS runners are Apple Silicon,
so `bench-platforms.yml` simply asks.

Identical synthesised work, minimum of several rounds:

| | YIN | MPM | SWIPE′ | Basic Pitch, one 2 s window |
| --- | --- | --- | --- | --- |
| **Apple Silicon** (macos runner) | **0.83 ms** | 0.74 ms | 0.94 ms | **324 ms** — 16% of real time |
| x86-64 Xeon (ubuntu runner) | 0.51 ms | 0.51 ms | 0.78 ms | 214 ms — 11% |
| this VPS, one shared core | 1.40 ms | 1.54 ms | 1.86 ms | 638 ms — 32% |

Read against the 23 ms budget one analysis hop allows: on Apple Silicon the
detector uses **3.6% of it**. The needle has never been the problem, on any
hardware measured.

The transcription mode is the interesting column. **324 ms per two-second
window in pure Dart on Apple Silicon** — no FFI, no CoreML, no native
build — is comfortably enough for a display updating twice a second. An
iPhone's core is in the same family and typically a little slower than a Mac's
under a sustained load, so somewhere around 350–450 ms is the reasonable
expectation; that is an inference from the same architecture, not a
measurement, and it is the one number here that has not been measured on the
hardware it describes.

**CoreML was not tried and would change this picture.** A 35.7k-parameter CNN
is exactly what the Neural Engine is for, and single-digit milliseconds would
be unsurprising. It would also mean a converted model, a platform channel, and
a second inference path to maintain — the trade §10.4 declined. At 324 ms
nothing forces that trade.

## 15. What to do, now

1. ~~**Replace the difference function with the FFT one.**~~ **Done** — see
   §7. YIN is vendored in `lib/detectors.dart`, asserted frame-identical to
   `pitch_detector_dart` by `test/detector_equivalence_test.dart`, and costs
   6.8% of an audio callback's budget where the package cost 201%.
2. ~~**Clear the median window when a frame is dropped.**~~ **Done** — see
   §2.1. `PitchSmoother` in `lib/tuner_core.dart`, measured at +9.09 points
   of frame-level RPA and gross errors 15.5% → 3.2%.
3. **Change nothing else in the detector.** Not the threshold, which is at
   the minimum of the octave-error curve where it is; not step 6, which
   changes 0.08 points; not the window, which is sized for an instrument this
   corpus does not contain; not the default detector, since pYIN and MPM each
   win on one axis by losing on the one a tuner cares about more. MPM is now
   offered as a setting (§7), which is a different thing from making it the
   default.
4. **If latency is ever attacked**, the numbers to start from are in §1: the
   window costs ~90 ms of it, the median adds more, and reading the end of
   the window rather than the start is worth ~58 ms.
5. **Inharmonicity is a feature idea, not a fix.** The estimator works and is
   now measured across the corpus (§8): B ≈ 9.3×10⁻⁵ on guitar, which
   stretches the octave by 0.24 cents. Prototype it against piano recordings
   with ground truth before believing anything about stretch tuning.
6. **Do not add a spectral octave guard.** One was built and measured
   (§8.1). At the rate the detector now makes octave errors — 0.58% of
   monophonic frames — every version of it discards more good frames than it
   rescues.
7. **Neural models stay off the tuning path** (§10), and SWIPE′ is not worth
   adopting either (§4.5): it loses to YIN on precision, gross errors and —
   its own selling point on the 20-file subset. On the full corpus it
   actually out-scores YIN on raw pitch accuracy, by answering on every frame
   and never rejecting anything — a 100% false-alarm rate, which is the wrong
   trade for a needle. Basic Pitch is better
   than YIN at naming notes and 10× worse at cents, which is the only
   question the needle asks. If polyphonic transcription is wanted as a
   separate mode, it is feasible — effectively causal, so a sliding window
   works — but only on native ONNX Runtime until `onnx_runtime_dart`'s
   convolutions get the same FFT treatment YIN's difference function got.

## 16. What would make this measurement better

* **The reference is itself an algorithm.** GuitarSet's contours come from
  pYIN on a hexaphonic pickup. Below a few cents, this benchmark is
  comparing two estimators, not measuring error. Held-note median errors
  around 2–3 cents should be read as an upper bound on the app's error, and
  the sub-cent claims in §4.3 rest on synthesis, not on the corpus.
* ~~**Guitar only.**~~ Partly closed — §11 adds cello, where the tuner does
  better than on guitar, and §11.2 puts the neural models there too. Still nothing on bass, piano, voice or wind, and the
  window-size and inharmonicity conclusions remain limited by that. The cello
  corpus is also narrow: two players, seven notes, all in one register.
* ~~**Frame-level, not note-level.**~~ Done — §9 times the pluck, §9.1 times
  the peg turn.
* ~~**A busy shared VPS.**~~ Partly closed — §14 measures Apple Silicon,
  x86-64 Linux and Windows on CI. An actual iPhone, and CoreML, remain
  unmeasured.

## 17. Two runtimes for one model: CrispASR against pure Dart

> **Correction (§17.3).** This section was first published as "ggml against
> pure Dart" and attributed CrispASR's speed to ggml. That is wrong: the
> basic-pitch backend runs its convolutions in hand-written C++ loops and uses
> ggml only to read the GGUF. §17.3 has the measurement and what it changes.

§10 measured Basic Pitch; this measures the *runtime*. The app runs the model
through `onnx_runtime_dart` — pure Dart, no FFI, no native build on any of six
platforms. The sibling project CrisperWeaver runs its transcription through
CrispASR's ggml over FFI. The same 35.7k-parameter model exists as both a 225
KB ONNX graph and a 142 KB GGUF, so the two can be put on the same audio and
asked the same questions.

`bin/runtime_compare.dart` does that. Eight GuitarSet chordal recordings,
**one thread on each side** so this compares runtimes and not core counts,
scored frame-by-frame against `note_midi` truth on the same 11.6 ms grid as
§12:

| runtime | precision | recall | F1 | per 2 s window |
| --- | --- | --- | --- | --- |
| pure Dart (ONNX) | 88.2% | 67.2% | 76.2% | 624 ms |
| CrispASR (ggml) | 84.4% | 75.6% | **79.7%** | **345 ms** |

Two findings, and the second matters more than the first.

**They are the same model, faithfully.** Over those eight files the two name
the same set of pitches: identical on five of them, and never below 83%
agreement. Where they differ it is one or two pitches at the edges — a D♯3 one
runtime keeps and the other drops, two implausibly high partials (D6, C♯7)
that only ggml reports. Nothing here suggests either port is wrong.

**The accuracy gap is the decoder, not the runtime.** ggml trades 3.8 points
of precision for 8.4 of recall because it returns segmented note *events* with
onsets, offsets and velocities, while the ONNX arm is scored on per-frame
activations above 0.4. A note event bridges the frames where activation dips
below threshold; a threshold does not. That is a decoding choice this
repository could make on either runtime, and it points at a cheaper
improvement than switching runtimes at all.

**Speed is real but is not the constraint.** 1.8× is a genuine speedup, and
threads buy a little more (345 → 329 ms at two threads, nothing beyond). But
§14 already measured 324 ms per window on Apple Silicon in pure Dart, against
a mode that updates twice a second. The pure-Dart path is not the thing
standing between a user and this feature.

### 17.1 What it would cost

From the `crispasr` package's own README: it "is pure Dart FFI and does not
bundle the native library." The build used here is 23 MB. Shipping this means
a native library on five platforms, a per-platform build to maintain, and
**no web build at all** — to speed up a mode that already runs fast enough,
and to gain recall obtainable by changing a decoder.

So the backend is built and is not the default. `lib/crispasr_backend.dart`
implements `TranscriptionBackend` behind a conditional export, so the web
compilation unit never sees `dart:ffi`; it reports itself unavailable unless
a host is explicitly configured (`CRISPTUNER_BASIC_PITCH_GGUF`, optionally
`CRISPTUNER_CRISPASR_LIB`), and `main.dart` holds the interface and prefers
ggml only when that configuration is present. The case that would change this
is MT3 — 96 MB and 46.9M parameters, where a 1.8× factor decides whether the
mode runs at all rather than how comfortably.

### 17.2 Two things found in the reading

Neither affects a number above; both are the kind of thing that costs an
afternoon if unwritten.

* **Basic Pitch hangs off CrispASR's *piano* arm, not its pitch arm.**
  `crispasr_session_pitch` is CREPE's monophonic F0 track;
  `crispasr_session_piano` is the note-event API that basic-pitch, MT3 and
  piano-transcription all serve. Asking `pitchSampleRate` for a basic-pitch
  session returns **0** rather than throwing — it is deliberately a
  capability probe — which resampled a whole run's audio to nothing and
  produced zero notes before the cause was obvious. The C parameter is still
  named `pcm_16k`; Basic Pitch wants 22050. Query `pianoSampleRate`, never
  assume.
* **A latent guard asymmetry upstream.** In `crispasr_c_api.cpp`,
  `crispasr_session_piano_n_notes` is guarded by
  `PIANO_TRANSCRIPTION || BASIC_PITCH || MT3`, but
  `crispasr_session_piano_notes` — the accessor that returns the data — is
  guarded by `#ifdef CA_HAVE_PIANO_TRANSCRIPTION` alone. A build with
  basic-pitch but without piano-transcription would transcribe successfully,
  report a note count, and hand back a null pointer. The build used here has
  both compiled in, so it is invisible from this side; reported rather than
  patched, since it is a different repository.

### 17.3 There is no ggml runtime in that path

The 1.8× looked like a runtime difference. It is not, and the question that
exposed it was a good one: *it is not plausible that ggml should be slower
than ONNX Runtime.* It was not slower — but it also was not ggml.

From `src/basic_pitch.cpp`'s own header:

> The whole network is six small convolutions, so everything runs in plain
> C++ loops rather than a ggml graph: at (172, 264, 8) the largest activation
> is 363k floats and the biggest conv is 8x8x3x39, which a graph would only
> add scheduling overhead to. ggml is still used for GGUF loading, which is
> what every other backend here does.

So §17 compared **optimised pure Dart against a scalar C++ reference
implementation**, not against ggml. That also explains the thread result this
report under-read: `nThreads` reaches a ggml backend that only loads tensors,
which is why 4 threads bought nothing over 2.

What the convolutions actually cost, counted from the call sites:

| layer | shape | MMAC |
| --- | --- | --- |
| contour_conv | 8→8, 3×39, out 172×264 | **340.0** |
| onset_conv | 8→32, 5×5 /3, out 172×88 | 96.9 |
| note_conv | 1→32, 7×7 /3, out 172×88 | 23.7 |
| note_out | 32→1, 7×3, out 172×88 | 10.2 |
| contour_out | 8→1, 5×5, out 172×264 | 9.1 |
| onset_out | 33→1, 3×3, out 172×88 | 4.5 |
| | **per 43844-sample window** | **484.4** |

Half a GMAC per two-second window is not "six small convolutions", and one
layer is 70% of it. Against measured time — CrispASR computes **14
overlapping** windows for the 22.32 s file where the ONNX arm computes 11
non-overlapping ones, so per window of model work it is 292 ms against 624:

| | ms/window | achieved |
| --- | --- | --- |
| CrispASR, scalar C++ | 292 | 1.66 GMAC/s |
| onnx_runtime_dart | 624 | 0.78 GMAC/s |

Both are far below what the hardware can do, and the disassembly says why.
`bp_conv2d` compiles to **SSE only** — `mulps`/`addps` on 4-wide `%xmm`,
**zero AVX, zero FMA, no `%ymm`** — because the build sets
`CMAKE_CXX_FLAGS` empty and takes only `-O3 -DNDEBUG`, i.e. baseline
x86-64.

> **Correction.** This paragraph first went on to estimate that "a tuned
> im2col + SGEMM with AVX2/FMA reaches 10–25 GMAC/s on one core of this
> class, so **6–15× is sitting on the table**". §20 measured it: **1.45×**.
> The estimate assumed dense-GEMM efficiency that this layer's shape cannot
> reach — `contour_conv` has only **8 output channels**, so each input
> element is read about eight times against 936 multiply-adds of reuse in a
> real GEMM. The kernel is bound by loads and dependencies, not by
> floating-point throughput, which §20 confirms from the other end: FMA buys
> nothing at all over plain AVX2, and AVX-512 is no better than AVX2. A MAC
> count tells you the work; it does not tell you the achievable rate.

The irony is *partial*, not exact: the header declined a ggml graph because
it "would only add scheduling overhead", and ggml's `conv_2d` is im2col plus
a threaded, FMA-vectorised `mul_mat`. The reasoning was wrong about the
network being cheap and **right to avoid the graph** — see §20, where the
im2col matrix for `contour_conv` is 170 MB per window against a 1.45 MB
largest activation, and with `OC=8` amortises nothing.

Two caveats on this sub-section, stated because they are the parts not
directly measured. `perf` is unavailable on the measurement host
(`perf_event_paranoid=4`) and `ptrace_scope=1` blocked a sampling profiler,
so the 1.66 GMAC/s is *implied* by assuming the convolutions are essentially
all of the runtime rather than observed. The header comment claims "the
expensive part is the CQT front end, not the network" — but the CQT is 9
octaves of 256-tap filtering over ~344 summed frames, about 6 MMAC against
the network's 484, so that claim cannot be right for this build unless the
front end is implemented far off its operation count.

### 17.4 What this changes above

Three things, none of which move a number already published:

* **The runtime is not why ggml is faster, and it is not why it is slower
  than it should be.** Both paths are leaving most of the machine unused.
* **The window overlap is a second pipeline difference.** CrispASR runs 14
  overlapping windows and drops 15 frames from each side before stitching,
  so it scores its better-conditioned interior frames; the ONNX arm scored
  every frame of 11 independent windows. That belongs on the same list as the
  decoder — pipeline, not runtime.
* **The optimisation worth doing for *this* app is the Dart one.** CrispTuner
  ships `onnx_runtime_dart` and does not ship libcrispasr (§17.1), so its
  0.78 GMAC/s is the number that reaches a user. `Float32x4` is available on
  every native target and is the same im2col+SGEMM shape.

## 18. The decoder, not the runtime

§17.4 left a claim outstanding: that CrispASR's eight extra points of recall
came from its decoder rather than from its runtime, because it emits
segmented note *events* that span the frames where an activation dips, while
this repository thresholded every frame independently. If that is right, the
recall is available in pure Dart at no packaging cost at all.

It is right. The fix is a Schmitt trigger — a high bar to start a note, a
lower one to keep it — which is one `if` in `BasicPitchDecoder.decodeFrames`.
`bin/hysteresis.dart`, all 180 chordal files, the same 11.6 ms grid and
`note_midi` truth as §12 and §17:

| start | sustain | precision | recall | F1 |
| --- | --- | --- | --- | --- |
| 0.4 | 0.4 | 87.3% | 72.6% | 79.2% |
| 0.4 | 0.3 | 85.2% | 78.5% | 81.7% |
| 0.4 | 0.25 | 83.9% | 81.4% | 82.6% |
| 0.4 | 0.2 | 81.9% | 84.5% | 83.2% |
| 0.4 | 0.15 | 77.9% | 88.0% | 82.6% |
| **0.5** | **0.25** | **87.8%** | **77.8%** | 82.5% |
| 0.5 | 0.2 | 86.0% | 81.1% | **83.5%** |
| 0.3 | 0.3 | 80.4% | 81.1% | 80.7% |

The first row is what shipped: one threshold, every frame judged alone.

**0.5 / 0.25 now ships, because it is strictly better than that on both
axes** — higher precision *and* five points more recall. There is no trade to
argue about; nothing that previously worked gets worse. 0.5/0.2 takes the
best F1 and is a one-line change, but it is not the default: a display is not
an F1 score, and a note shown that is not being played is a worse error than
one missed, because the player can see what they are holding. When a
dominating option exists, it beats a maximising one.

For scale, CrispASR/ggml on the 8-file subset scored 84.4% / 75.6% / 79.7%
(§17). The pure-Dart path now exceeds that on every axis, on every platform
the app ships to, including the web — which is the honest epitaph for the
FFI backend merged one section earlier.

### 18.1 Measuring it is not shipping it

The app's live display called `BasicPitchDecoder.decode`, which averages the
tail of one window and judges each note against a single threshold. Raising
that threshold to 0.5 on its own would have made the display *worse*: §12
measured 0.5 alone at 90.3% precision for 61.3% recall. The table above is
the *sequence* decoder, and hysteresis is stateful — so the benefit only
reaches a user if the live path becomes stateful too.

`LiveNoteTracker` is that state, and it is deliberately small: the set of
notes still sounding when the last window ended. Without it a note whose
activation dips exactly across a window boundary is reported as two notes,
which is the same defect the sustain threshold fixes within a window.

One safeguard came out of the change rather than out of the measurement.
Hysteresis makes a single frame decisive in a way it was not before, and one
frame is 11.6 ms, so a borderline note would flicker on and off between
windows. The tracker therefore reports a note when it sounds in **most** of
the last 8 frames rather than merely in the final one, and a test pins that.

### 18.2 What this says about the previous section

The CrispASR backend of §17 is now harder to justify than when it was
merged, and that is the correct outcome rather than an awkward one. Its
advantage was never its runtime (§17.3 — there is no ggml runtime in that
path) and is now demonstrably not its decoder either. What remains is 2.1×
on speed against a mode that already updates twice a second, bought with a
23 MB native library on five platforms and no web build.

The backend stays, unavailable by default, for the reason it was built:
MT3 is 96 MB and 46.9M parameters, and there the factor decides whether the
mode runs at all. Nothing about this section changes that case.

## 19. The Dart runtime: where its 0.78 GMAC/s goes

§17.3 left the pure-Dart path at 0.78 GMAC/s against 484.4 MMAC per window
and said most of the machine was unused. `bin/dart_parallel.dart` asks which
part of "unused" is available.

The package already ships an isolate pool — `parallelize(workers:,
poolConv:)` partitions work across isolates and `runAsync` executes on them
— and **the app does not use it**: `TranscriptionService` calls the
synchronous `run()`. So the first question is not what to write but what is
already there.

Four arms, **each in its own process** (see §19.1), median of five
inferences, on one shared VPS core of four:

| arm | ms/window | GMAC/s |
| --- | --- | --- |
| `run()`, single isolate — what ships | 621 | 0.78 |
| `parallelize(2)` | 596 | 0.81 |
| `parallelize(2, poolConv)` | 476 | 1.02 |
| `parallelize(4, poolConv)` | **441** | **1.10** |

**`poolConv` is worth 1.41×, and the package's own documentation says it
should not be.** From `parallelize`'s doc comment: "Off by default: conv
messages carry the whole input activation to every worker, and for CNN
workloads measured so far that copying costs more than the banded compute
saves." That is a fair description of most CNNs and the wrong prediction for
this one — Basic Pitch's activations are large enough (172 × 264 × 8) that
the banded compute wins.

**`parallelize` without `poolConv` does nothing, and that is not noise-free
luck.** `tool/dump_ops.dart` on the shipped model: 248 nodes, **32 `Conv`
and zero `MatMul`**. Without `poolConv` there is literally nothing for the
pool to partition, so the 621 → 596 is the noise floor of a loaded box, not
a small win. Worth stating because a 4% "improvement" with no mechanism is
exactly the kind of number that gets quoted later.

Also worth recording: the ONNX graph has 32 convolutions where the native
port has six, because the export implements the CQT front end as
convolutions too. That reconciles the two profiles — the front end is ~6% of
the Dart cost and a rounding error in the native one, because they are not
computing it the same way.

### 19.1 The harness lied to me first

The first version of `dart_parallel.dart` ran every arm in one process and
reported **1.76×**. Per-process it is **1.41×**.

Dart's JIT optimises hot code across the isolate, so the arm that runs first
pays to warm kernels that every later arm then inherits — and the baseline
ran first. The gap between 1.76 and 1.41 is entirely that.

This is embarrassing in a useful way: hours earlier I had briefed a
subagent, in writing, that a shared process manufactures wins and that each
configuration must be a separate process. I then wrote a single-process
harness. The rule is in CrispASR's development guide as "measure both arms
under IDENTICAL load, back-to-back — a noisy box fabricates wins", and it
cost nothing to follow once remembered. `--only <arm>` exists now so the
harness cannot make that mistake again.

### 19.2 On hardware nobody here owns

The VPS numbers were never going to decide this. `bench-platforms.yml` runs
the same four arms, one process each, median of three, on CI:

| | single isolate | `p(2, poolConv)` | `p(4, poolConv)` | gain |
| --- | --- | --- | --- | --- |
| Apple Silicon (3 cores) | 353 ms | 174 | **159** | **2.22×** |
| x86-64 Linux (4) | 208 ms | 148 | **143** | 1.45× |
| x86-64 Windows (4) | 222 ms | 164 | **153** | 1.45× |
| this VPS (4, shared) | 621 ms | 476 | 441 | 1.41× |

**It wins everywhere, and most where it matters most.** Apple Silicon is the
closest proxy available for the phones this app actually ships to, and it
gains the most: a two-second window drops from 353 ms to 159, which against
the mode's 500 ms update interval is a duty cycle of 32% rather than 71%.
That is the real result — nobody was waiting on the latency, but a mode that
holds a core busy two-thirds of the time is a battery and thermal problem on
a device that is not plugged in.

Four workers wins or ties on all four machines, so the cap is four; two
captures most of it on a smaller machine. The floor is two, because one
worker is strictly worse than not pooling — it pays the per-conv message
copy and gains no parallelism, and `poolWorkersFor` is tested to never
return it.

The memory objection also failed to survive contact: weight replication
across workers sounded expensive until counted. Basic Pitch is 35.7k
parameters — about 143 KB — so four copies is not a number worth writing
down.

### 19.3 Shipped

`TranscriptionService` now calls `parallelize(workers: poolWorkersFor(cpuCount),
poolConv: true)` on its first window and `runAsync` thereafter. Three details
worth stating because each was a decision rather than an obvious step:

* **The pool is built lazily, on the first window, not at `start()`.**
  Spawning isolates and replicating weights is work that should not happen
  because a user toggled a switch and toggled it back.
* **A pool failure is not a mode failure.** If `parallelize` throws, the
  worker keeps going unpooled; `runAsync` computes the same answer on the
  calling isolate. The mode gets slower, never broken.
* **Core count goes through a conditional export** (`cpu_count.dart`), for
  the same reason `crispasr_backend.dart` does: `dart:io` in anything
  reachable from a web entry point fails the build. The web answer is 1,
  which is also true — the mode does not run there.

One loose end was recorded here rather than smoothed over: `parallelize`
*without* `poolConv` measured 6–17% faster than `run()` on all four
machines, and should have measured nothing, because the graph has zero
`MatMul` for it to partition. **§23 closes it — there was no effect.**

## 20. Optimising the native path

Commissioned after §17.3, on `/mnt/volume1/CrispASR` branch
`perf/basic-pitch-conv`. The work followed CrispASR's own development guide:
both paths kept, gated on `CRISPASR_BASIC_PITCH_FASTCONV` (default **off**),
old path still the default until a clean box proves the threading half.

Runtime-dispatched AVX2 / AVX-512 / AVX2+FMA kernels, reusing the tree's
existing `Isa` dispatch rather than a new one, no `-march=native`, plus
`core_parallel::for_each_chunk` over the disjoint `(oc, h)` output rows — so
`n_threads`, which previously reached only the GGUF loader (§17.3), now
reaches all six call sites. CPU time is primary because the box sat at load
15–26 throughout; separate processes per arm, cold run discarded.

| arm | CPU ms/window (conv only) | GMAC/s | vs ref |
| --- | --- | --- | --- |
| reference (SSE) | 237 | 2.04 | 1.00× |
| **AVX2** | **163** | **2.96** | **1.45×** |
| AVX-512F | 167 | 2.90 | 1.42× |
| AVX2 + FMA | 163 | 2.98 | 1.46× |

Whole file 4.36 s → 3.31 s CPU (1.32×); essentially all of the win is
`contour_conv`, 148 → 90 ms. Output is **byte-identical** — FNV over raw
float bits plus L2 norms on all three heads, and every note event unchanged
— with a hermetic test asserting `memcmp == 0` on the six real shapes, which
was checked to actually fail when forced onto a different kernel.

### 20.0 Closed on CI, and the default flipped

The VPS could not settle the threading half — a single-threaded process
never exceeded 36–54% of one core there. A hermetic CI workflow did, one arm
per process, cold discarded, median of three, within-run variance 0.05%:

| | reference | SIMD, 1 thread | 4 threads |
| --- | --- | --- | --- |
| ubuntu-24.04, 4 cores | 104.8 ms | **1.66×** | **3.59×** |
| macos-14 (M1), 3 cores | 94.8 ms | **1.01×** | **2.67×** |

Byte-identical on both, at 1 and 4 threads, so the gate now defaults **on**
with `=0` as the way back and `bp_conv2d_ref` kept verbatim.

Three results here are worth more than the speedup:

* **A contended box understates the faster kernel.** SIMD-only measures 1.45×
  on the loaded VPS and 1.66× clean — contention costs the faster kernel
  proportionally more, because it has less slack to hide a stall in.
* **arm64 gains nothing from SIMD — 1.01×.** Its entire 2.67× is threading.
  NEON is already baseline on aarch64, so the portable path was always
  4-wide there and the new kernels add nothing. Anyone reading "AVX2 made it
  1.66× faster" and planning for a phone would plan wrong.
* **FMA buys 0–3%, inside run-to-run spread.** That is the §17.3 correction
  arriving independently: a kernel this low in arithmetic reuse is not
  FP-throughput bound, so the instruction that doubles FP throughput does
  nothing.

Shipped with one caveat, not smoothed over: `n_threads` defaults to 4, and
at 4 threads the per-call `std::thread` spawn — six convolutions per window,
~84 spawns for a 22-second file — costs about 75% more CPU than 2 threads
for about 9% less wall time. Batch and server callers should pass 2 until it
routes through the tree's existing worker pool.

### 20.1 What it corrects in this report

* **The headroom estimate, by an order of magnitude.** I predicted "6–15×
  … before any threading". SIMD alone delivers **1.66×** on x86-64 and
  **1.01×** on arm64. The clean-box total of 3.59× partly closes the gap,
  but it closes it with threading, which the prediction had explicitly
  excluded — so the correction sharpens rather than softens. See §17.3.
* **"Nothing gets AVX2" was half wrong.** `GGML_AVX2:BOOL=OFF` in the cache
  is superseded by `GGML_NATIVE:BOOL=ON`, and `libggml-cpu.so` carries 19,886
  `%ymm` references. It is CrispASR's own `src/` that compiles baseline —
  `basic_pitch.cpp.o` has 1,460 `%xmm` and zero `%ymm`. An asymmetry between
  the vendored library and the project's own sources, not a blanket. That
  asymmetry is a larger and cheaper lever than any kernel.
* **`ggml_conv_2d` is the wrong answer here, and memory is only half the
  reason.** 170 MB per window against a 1.45 MB largest activation, yes —
  but the decisive point is that `contour_conv` has `OC=8`, making the GEMM
  `M=45408, K=936, N=8`, where every element of that 170 MB is read
  essentially once. im2col amortises nothing at this shape. `onset_conv` is
  the exception worth measuring later: 12.1 MB, `OC=32`, 20% of the work.

### 20.1a The `src/` ISA gap, which is the larger finding

Promoted out of the perf write-up into `docs/improvements/SRC_ISA_GAP.md`.
The evidence turned out to be sharper than "flags are empty". In
`release.yml`: **15 legs** pass `-DGGML_AVX2=ON -DGGML_FMA=ON
-DGGML_F16C=ON`, **2** ship `GGML_BACKEND_DL` with
`GGML_CPU_ALL_VARIANTS` (runtime multi-variant dispatch), **3** pass
`CRISPASR_PORTABLE_CPU=ON` (deliberate baseline) — and **zero** mention
`CMAKE_CXX_FLAGS`.

So there *is* a considered ISA policy, documented in `CMakeLists.txt`: ggml's
CPU backend initialises before CUDA or Vulkan is selected, so an AVX2 CPU
helper raises `SIGILL` at model load before the runtime ISA diagnostic can
print. It is applied to ggml through three separate strategies. **CrispASR's
own `src/` is in none of them** — and the tell that this is scope rather
than intent is that the legs which *deliberately* hand ggml AVX2 do not hand
it to `src/` either, which no policy would ask for, since on those artifacts
AVX2 is already accepted.

Not decided here, and not this repository's call. Recorded because it is a
tree-wide multiplier available from a build-system change rather than from
writing kernels one at a time — worth more than the optimisation that
uncovered it.

### 20.2 One number that did not reconcile

The agent's reference build reports **153** note events on
`00_BN1-129-Eb_comp_mic.wav` where this report's harness reports **151**,
and attributed the difference to the harness. It is not the harness: re-run
against `libcrispasr.so.0.8.33` it still gives 151, deterministically, with
the same pitch set and the same earliest event (midi 51 at 35 ms, velocity
74). The `.so` was built on 17 September and the agent compiled current
`src/`, which has moved since.

Both numbers are therefore right for their own build, and the A/B is
unaffected — byte-identity was established between reference and fast paths
*within one build*, which is what the comparison requires. Recorded because
§17's published baseline is 151 and should stay reproducible.

### 20.2a A green tick that measured nothing

Flipping the gate's default silently broke the A/B workflow that proved it,
in the worst possible direction. The reference arm passed **no** environment
variable — correct only while the gate defaulted off. One run therefore
reported **1.00× for every arm, and passed**.

The fix was to pin `=0` explicitly *and* to assert that the arm name the
harness prints matches the one requested, so a harness measuring the wrong
thing fails rather than reporting parity. The general lesson is worth more
than the bug: **a gate's default is part of every harness that reads it**,
and "no difference" is the one result a broken benchmark produces most
convincingly.

### 20.3 Whether it generalises

Recommendation, not work done: screen each backend with one multiplication —
im2col bytes `(H·W_out)·(IC·KH·KW)·4` against `OC`. CREPE and
piano-transcription likely sit on the favourable side; **mt3 is a T5 and
attention-bound**, which is precisely the "inverse-default regime" the
development guide warns about. Before any of that, the `src/`-is-baseline
finding above is the bigger and cheaper lever.

## 21. Stretch tuning: the estimator works, the feature does not earn its place

The brief named this the likeliest big win: *"Inharmonicity: real strings are
stiff, f_n = n·f0·√(1+B·n²). Estimating B is the gateway to stretch tuning,
and would pair with the app's existing historical temperaments. Potentially
the most valuable feature here — but measure first, and note GuitarSet is
guitar only."* That last clause turns out to carry the whole result.

`harmonics.dart` has estimated B since it was written and **nothing has ever
called it** — `analyseHarmonics` appears in no engine or UI code. The reason
was mechanical, not editorial: the module imported `package:fftea`, whose
`Float64x2List` is precisely the construct dart2js cannot give SIMD lanes
(15.56 ms per 8192-point transform against 0.38 ms native). Wiring harmonic
analysis into the live path would have re-created, in the browser, the exact
stall `fft_real.dart` was written to remove.

So the module is now ported onto `fft_real.dart`. That needed one addition —
`RealSpectrum` exposes its complex buffer, because magnitude alone cannot
give the phase of a bin across two frames, which is how a partial's
instantaneous frequency is recovered.

### 21.1 Does the estimate recover a B it was given?

`bin/inharmonicity.dart`, synthesised stiff strings where B is an input:

| f0 | B given | B found | error |
| --- | --- | --- | --- |
| 82.41 | 0 | 8.0e-6 | (noise floor) |
| 82.41 | 2.0e-4 | 2.1e-4 | 6% |
| 110.00 | 1.0e-4 | 1.1e-4 | 6% |
| 146.83 | 5.0e-5 | 4.8e-5 | 4% |
| 196.00 | 3.0e-5 | 3.0e-5 | 1% |
| 246.94 | 1.5e-5 | 1.5e-5 | 1% |
| 329.63 | 1.0e-5 | 1.0e-5 | 0% |

Good across the range a guitar actually occupies, with a **noise floor near
1e-5**: given a perfectly flexible string it reports 8e-6 rather than zero,
so any B below about 1e-5 is indistinguishable from none. The bias is upward,
as peak-picking noise should make it.

This is a weaker test than the corpus and is labelled as such — the report's
own standing caution is that a synthetic tone is a far easier signal than a
plucked string. It establishes that the estimator is not broken. It cannot
establish that it works in a room.

### 21.2 What it is worth on real guitars: 0.27 cents

On GuitarSet, 3742 pitched frames, stiffness fitted on 46.4% of the frames
that had measurable partials:

| | p10 | median | p90 |
| --- | --- | --- | --- |
| inharmonicity B | 2.98e-5 | **1.06e-4** | 2.78e-4 |

which is squarely where the synthetic check says the estimator is accurate
to a few percent. At the median B, the octave stretch is **0.27 cents**.

**That is the answer, and it is no.** The app's own median cent error is
**2.45 cents** (§13). A correction of 0.27 cents is roughly an order of
magnitude below the precision of the instrument applying it — it would move
the needle by a fraction of the width of its own noise. Even at p90 the
stretch is about 0.6 cents, still a quarter of the median error.

The physics is the reason, and it is not a defect in the estimate: guitar
strings are long and thin, so B sits around 1e-4. Piano bass strings are
short, thick and under far more tension, reaching 1e-3 and beyond, and a
piano accumulates stretch across seven octaves rather than one. **Stretch
tuning is a piano technique for piano reasons.** This app is chromatic and
supports many instruments, so the feature might well earn its place there —
but GuitarSet cannot show that, no piano corpus is at hand, and the brief's
own caution said exactly this would happen.

### 21.3 What the port did buy

Not nothing, and worth separating from the negative result:

* **The module is now usable at all.** Whatever is eventually built on the
  partials — a diagnostic readout, an octave guard, timbre display — no
  longer has to choose between having it and having a web build.
* **The partial-lock measurement is real and interesting**: the detector
  locks onto partial 1 in **97.3%** of frames, partial 0.5 (a period double)
  in 2.4%, partial 2 in 0.2%. That is a direct measurement of *how* the
  detector fails when it fails.
* **The octave guard built on it is not shippable**, and this is the second
  negative result here: it catches 4 of 32 octave-wrong frames (12.5%
  recall) while wrongly flagging 22 of 2606 correct ones — a flag precision
  of **15.4%**. A guard that is wrong six times out of seven is worse than
  no guard, because a user cannot tell which kind of answer they are looking
  at.

## 22. The two rules that did not port, and the one that did

§18 predicted the remaining headroom was in decoding rather than kernels, and
named two rules `note_creation.py` has that this repository never ported.
Both are now implemented and measured. Neither ships.

### 22.1 Minimum note length and onset gating: no

`minimum_note_length_ms = 127.7` (about 11 frames) and `infer_onsets`. The
first had to change shape to port at all: Spotify's is a post-filter over a
segmented signal, and a live display cannot see a note end before deciding
whether to show its beginning. `minNoteFrames` is the causal equivalent — a
debounce on the start, costing exactly that much latency.

All 180 chordal files, at the shipped 0.5/0.25 thresholds:

| min length | onset gate | precision | recall | F1 |
| --- | --- | --- | --- | --- |
| **0 frames** | **none** | **87.8%** | **77.8%** | **82.5%** |
| 2 frames | none | 88.7% | 76.7% | 82.2% |
| 4 frames | none | 89.5% | 73.0% | 80.4% |
| 6 frames | none | 90.1% | 68.7% | 78.0% |
| 11 frames | none | 91.0% | 58.0% | 70.9% |
| 0 frames | ≥ 0.5 | 89.7% | 70.4% | 78.9% |
| 0 frames | ≥ 0.3 | 88.9% | 74.9% | 81.3% |
| 0 frames | ≥ 0.2 | 88.3% | 76.7% | 82.1% |
| 2 frames | ≥ 0.3 | 89.6% | 73.9% | 81.0% |
| 4 frames | ≥ 0.3 | 90.2% | 70.9% | 79.4% |

Every row is precision-up, recall-down, F1-down. **Nothing dominates**, which
is the difference from §18 and the reason nothing ships: there the chosen
setting was better on both axes, so adopting it cost nothing that had been
working. Here each option is a trade, and §18's tie-break — a false note is
worse than a missed one — was a rule for choosing between a dominating and a
maximising option, not a licence to spend recall freely.

The 2-frame row is the closest call: 0.9 points of precision for 1.1 of
recall and 23 ms of added latency. Available, not taken.

The shape has a structural explanation rather than being a tuning accident.
Spotify's rules run offline over a segmented signal, so they can delete a
short note *after* watching it end. A causal debounce cannot do that; it
delays every note's appearance equally, and pays for each blip it suppresses
with frames lost at the start of a genuine note — where the ground truth
already says the note is sounding. An offline post-filter and a live
debounce are not the same rule wearing different clothes.

Both default to off — `minNoteFrames: 0`, `requireOnset: false` — which is
§18's behaviour exactly. The 8-file pilot predicted this shape and the
180-file run reproduced §18's baseline row to the decimal, which is the
cross-check that the harness is measuring what it claims.

### 22.2 Pacing: yes

The rule that does ship attacks a different quantity. §19 made a window cost
159 ms on Apple Silicon, but at two inferences a second the mode still holds
a third of a core continuously on a device running off a battery. Nothing in
§19 or §20 makes that cheaper — `TranscriptionPacing` decides how often it is
worth paying at all:

* **Silence is skipped entirely.** An RMS check over the window, costing
  microseconds, against half a second of inference that has nothing to find.
  The threshold sits well below a quietly played string, and a test asserts
  a −46 dBFS note is *not* treated as silence — a silence gate that swallows
  soft notes is a worse bug than the cost it saves.
* **A repeated answer backs off**, from twice a second to once every two
  seconds, resetting the instant the notes change. A player holding a chord
  does not need the model re-run four times to be told the same thing.

The backoff is bounded on purpose, and a test pins the bound: the only way
to discover that something changed is to look, so two seconds is the longest
a newly played note can wait. Unbounded backoff would trade a real
responsiveness failure for a saving nobody asked for.

## 23. Closing the loose end, and a default it changed

§19 published a number it could not explain, and flagged it as unexplained
so nothing would quietly depend on it. This is what it was.

### 23.1 There was no effect

The hypothesis was that `runAsync` differs from `run` in more than pooling.
A second CI run added the arm that separates them — the same async node loop
with **no workers spawned at all**:

| median of 3 | `run()` | `runAsync`, no pool | `parallelize(2)` |
| --- | --- | --- | --- |
| x86-64 Linux | 229 ms | 225 | 226 |
| x86-64 Windows | 212 ms | 218 | 208 |
| Apple Silicon | 266 ms | 218 | 224 |

On Linux all three are within 2% of each other. On Windows the supposedly
faster path is **slower** than the baseline. A real mechanism does not change
sign between platforms.

What it actually was: **arm ordering across processes.** `base` ran first in
every loop, so it alone paid the cold costs of the first process in a
sequence — page cache for the 225 KB model and the Dart snapshot, and runner
warm-up. The tell was visible in the spread and went unread: on Apple
Silicon the `base` arm ranges 239–283 ms while every later arm sits inside a
few percent. Running each arm in its own process removed the JIT artefact of
§19.1 and introduced a different one in the same place.

The harness now runs a throwaway process first and loops **reps outer, arms
inner**, so every arm takes every ordinal position. Both defences exist
because the first fix taught the wrong lesson: isolation was necessary and
was not sufficient.

**What survives unchanged is the finding that mattered.** `poolConv` is
163 ms against 229 on Linux — 1.40× — which is twenty times the ordering
noise and reproduces across two runs, three platforms and both worker
counts.

### 23.2 The worker count was never supported, and is now two

Chasing the artefact turned up something the first run had hidden. Across
both runs:

| | 2 workers | 4 workers |
| --- | --- | --- |
| Apple Silicon | 174 / **164** | **159** / 175 |
| x86-64 Linux | 148 / **163** | **143** / 179 |
| x86-64 Windows | 164 / **167** | **153** / **150** |

Four was faster on all three machines in the first run and slower on two of
three in the second: **six comparisons, three each way.** The worker count is
inside the noise; only the pool is outside it.

§19 shipped `poolWorkersFor` capping at four on the strength of the first run
alone — "four wins or ties on all four machines, so the cap is four" — which
was true of the data then in hand and is not true of the data now. It caps at
**two**, which reaches the same place with half the isolates and half the
weight replication.

One genuine use for the core count survives, and it is not about speed: on a
single-core machine a worker cannot run in parallel with the isolate waiting
for it, so it pays the per-conv message copy for nothing. `poolWorkersFor(1)`
returns **0** — do not pool — and a test pins it.

### 23.3 What this cost and what it bought

An unexplained 6–17% would have been quoted as a property of `runAsync` by
the next person to read §19. It was worth one CI run to find that it was a
property of the loop that measured it.

The habit that produced both artefacts is the same one: changing a harness
to fix a known bias, and not asking what bias the change introduced. The
answer both times was in data already collected — the spread column said
`base` was cold long before anyone looked at it.

## 24. How much lookahead pYIN actually needs: two frames

§4.1 rejected pYIN on two grounds. The first was measured. The second was
not:

> Viterbi cannot decide frame *t* until it has seen the end of the file. An
> online version needs a fixed decoding lag, which is more latency on top of
> the ~90 ms the window already costs, in an app whose remaining accuracy
> problem *is* latency.

True about Viterbi, and an argument only if the required lag is large.
`decode` now takes a bounded lag — frame *t* decided from the best state at
frame *t+lag*, exactly what a streaming decoder could do — sharing the
forward pass, so only the backtrace changes. All 180 solo files, hop 1024,
one frame = 23.2 ms:

| lag | RPA% | oct% | held RPA% | \|err\| p50 | FA% |
| --- | --- | --- | --- | --- | --- |
| 0 (greedy) | 80.30 | 1.37 | **89.81** | 2.05 | **24.79** |
| 1 (23 ms) | 82.25 | 1.23 | 89.36 | 2.05 | 33.37 |
| **2 (46 ms)** | **83.18** | 1.14 | 89.47 | 2.05 | 40.76 |
| 4 (93 ms) | 83.33 | 0.99 | 89.30 | 2.05 | 39.73 |
| 16 (371 ms) | 83.37 | 0.96 | 89.29 | 2.05 | 39.51 |
| offline | 83.38 | 0.96 | 89.30 | 2.05 | 39.52 |

**Two frames reaches 99.8% of the offline accuracy.** The latency objection
is refuted: 46 ms of lookahead, not the end of the file.

### 24.1 The verdict survives, on one leg instead of two

§4.1's first reason is untouched and is the stronger one. Against the
shipped pipeline:

| | RPA% | oct% | FA% |
| --- | --- | --- | --- |
| `app` (ships) | 62.79 | **0.43** | **17.07** |
| pyin-lag2 | 83.18 | 1.14 | 40.76 |
| pyin-lag0 | 80.30 | 1.37 | 24.79 |

pYIN's octave rate is more than twice the app's and its false alarm more
than twice as high. It answers far more often and is wrong more often when
it does — the same trade this report declines everywhere.

What is new is that **lag 0 is a different operating point rather than a
worse one**: greedy decoding gives the *best held-note accuracy in the whole
set* (89.81% against the app's 80.86%), the best cent error (2.05 against
2.45), and a false alarm rate of 24.79% — far closer to the app's 17.07%
than any other pYIN variant. On the measurement a tuner actually performs —
a note held while the user turns a peg — greedy pYIN is nine points more
accurate and half a cent tighter than what ships.

### 24.2 An experiment that did not answer its question

The obvious follow-up is to put the app's gate-and-median on top of pYIN,
since rejecting low-confidence frames is exactly what the app does well and
pYIN does not. Measured, on 12 files:

| | RPA% | oct% | held RPA% | \|err\| p50 | FA% |
| --- | --- | --- | --- | --- | --- |
| pyin-lag0 | 80.17 | 0.87 | 87.52 | 2.45 | 36.49 |
| pyin-lag0 + smoother | 78.94 | 0.90 | **88.83** | 2.95 | **36.49** |

**This does not test what it was built to test, and the tell is in the
table.** The false alarm rate is *identical* to the ungated variant, because
the harness hands the smoother `probability: 1.0` for every decoded frame —
so the `> 0.9` gate never rejects anything and only the median contributes.
What the median does is what §2 already established: held accuracy up,
precision down (2.45 → 2.95 cents).

Recorded as a null result rather than deleted, because the reason it failed
is itself the finding: **pYIN already has a voicing model.** Its Viterbi
decides voiced against unvoiced with a proper transition prior, and the
app's gate is a cruder version of the same decision. Stacking them is
redundant by construction. Making pYIN more conservative is a matter of its
own `switchProbability` and unvoiced floor, not of bolting the app's
threshold on top — and that is the experiment worth running next.

## 25. What CometBeat does with CrispASR, and what we should take from it

CometBeat is the sibling project that overlaps this one most: Flutter, the
same owner, live pitch detection, and the same `crispasr` package. Its
`lib/core/audio/transcription/` holds **67 files** — pYIN with a note-HMM,
rhythm and quantisation, CREPE, RMVPE, FCPE, WORLD DIO, Basic Pitch, chord
recognition, stem separation, TabCNN — against this app's four. It is worth
reading precisely because it solved the same integration problem first.

### 25.1 Side by side

| | CrispTuner (§17) | CometBeat |
| --- | --- | --- |
| runtimes | 2: pure-Dart ONNX, CrispASR ggml | **3**: + native ONNX Runtime FFI |
| the seam | `TranscriptionBackend` interface | function typedefs — `F0Estimator`, `NeuralTranscriber`, `ChordEstimator` |
| web safety | conditional export on `dart.library.ffi` | conditional export on `dart.library.io` |
| unavailable | `isAvailable` false; `start()` throws | **returns `null`** at every failure point |
| model | bundled 225 KB asset; GGUF from an env var | **CrispASR registry + cache, fetched on first use, never bundled** |
| library path | env override → package default | env → macOS `Frameworks/` → `~/.cache/crispasr/` → package default |
| choosing | `fromEnvironment() ?? TranscriptionService()` | user setting → `config.resolve()` → provider availability → fallback |
| concurrency | isolate, drop-latest | direct call |
| CrispASR arm | piano (basic-pitch GGUF) | pitch (CREPE), piano (Kong), separate, tab |

The two differences that are *not* worth copying are the last two rows, and
for the same reason: CometBeat transcribes a finished recording, this app
drives a live display at 2 Hz. An isolate and drop-latest are the right
answer here and unnecessary there.

### 25.2 The one that exposes a defect in ours

**Model resolution.** `crispasr_ffi_pitch_io.dart` resolves its GGUF through
CrispASR's own registry and cache:

```dart
final RegistryEntry? entry = registryLookup('crepe', lib: lib);
final dir = cacheDir(lib: lib);
// cached? use it. download requested? cacheEnsureFile(entry.filename, entry.url)
```

— "no hand-rolled URLs", as its own comment puts it, and the model arrives on
first use.

Ours requires the user to set `CRISPTUNER_BASIC_PITCH_GGUF` to a path they
obtained somehow, and `CrispAsrBackend.fromEnvironment()` returns null
otherwise. §17.1 presented that as a deliberate "unavailable unless
configured" stance. Read against CometBeat, it is better described as
**a backend that is effectively never available** — nobody sets that variable,
so the code path merged in #19 has never run outside the benchmark.

The library-path chain is the same story in miniature. CometBeat looks in a
built macOS app's `Frameworks/` directory, which is how the library would
actually reach a user; ours looks at an environment variable and then the
system loader, neither of which describes a shipped app.

### 25.3 What CometBeat confirms about §22

CometBeat ports Spotify's `note_creation` faithfully — `minNoteLenFrames`
(127.7 ms), `inferOnsets`, onset peak-picking by `argrelmax`, and the melodia
trick as an option. §22 measured causal versions of the first two here and
found they **cost** F1, and concluded the reason was structural: an offline
post-filter can delete a short note after watching it end, and a live
debounce cannot.

CometBeat is the offline case, and implements exactly the post-filter form.
Both projects are right, which is the useful confirmation — the rules are not
wrong, they are **not portable to a live display**, and that distinction now
has an independent example rather than only an argument.

### 25.4 What was done

All three, and `bin/backend_resolve.dart` proves the result on a machine
with nothing configured:

```
library path : /home/claudeuser/.cache/crispasr/libcrispasr.so
library      : opened
registry     : basic-pitch-f16.gguf (~110 KB)
cache dir    : /home/claudeuser/.cache/crispasr
cached       : yes, 112160 bytes
session      : open, wants 22050 Hz
```

1. **The GGUF resolves through CrispASR's registry and cache.**
   `registryLookup('basic-pitch')` → cached file, or `cacheEnsureFile`
   downloads it (110 KB from `cstr/basic-pitch-GGUF`) on the *worker
   isolate*, never on the UI thread. Verified from cold: no cache, download,
   session open.
2. **The library-path chain** is env → a built macOS app's `Frameworks/` →
   `~/.cache/crispasr/` → the package default. The `Frameworks/` entry is
   the one that matters, because it is the only one that describes a shipped
   app rather than a developer's shell.
3. **Nothing throws to say "not here."** `isAvailable` probes and returns
   false — a test asserts it stays `returnsNormally` against a nonexistent
   library — and `fromEnvironment` returns null. The worker replies with an
   error message instead of propagating an exception.

**Availability is now separate from preference, which is the part that
needed care.** Once a model downloads itself, this backend is available
anywhere libcrispasr is, and §18.2 is precisely why that must not make it
the default. Measured on this box with the library present:

| | |
| --- | --- |
| `isAvailable` | **true** |
| `fromEnvironment()` with no opt-in | **null** |
| `fromEnvironment()` with `CRISPTUNER_TRANSCRIPTION_BACKEND=crispasr` | a backend |

The old `CRISPTUNER_BASIC_PITCH_GGUF` still opts in on its own, so anyone
already using it keeps working.

### 25.5 One thing the fix could not use

CometBeat drops a development copy of the library at
`~/.cache/crispasr/libcrispasr.{so,dylib}`, and the chain looks there. On
this box `~/.cache` is a symlink onto `/mnt/volume1`, and creating a symlink
inside it fails with `Input/output error` — so the drop had to be a real 23
MB copy rather than a link. Recorded because it is the kind of thing that
reads as a broken build for an hour: the filesystem is ext4 and writable,
`touch` succeeds, and only `ln -s` fails.

Not recommended: the third runtime. Native ONNX Runtime FFI earns its place
in an app with chords, stems and tablature to accelerate. Here §19 and §23
already got 2.22× from an isolate pool in pure Dart, with nothing to ship.

## 26. CometBeat's detectors on both corpora

§25 compared the two projects' CrispASR integration. This compares their
*detectors*, which turned out to be possible: all 67 files of CometBeat's
transcription tree are Flutter-free, so its engines run in this harness
directly (`tool/sync_cometbeat.sh` copies them; CI fails if the copies
drift). Only the model-free engines are included — WORLD DIO, which this app
has no equivalent of, and CometBeat's own pYIN. The rest would measure a
model rather than CometBeat.

### Guitar — GuitarSet, 180 solo files

| engine | RPA% | rep% | oct% | gross% | \|err\| p50 | VR% | FA% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| cb-dio | 52.24 | 63.32 | 7.30 | 29.38 | 3.90 | 80.53 | 53.78 |
| cb-dio (no refine) | 41.87 | 50.76 | 2.70 | 46.54 | 9.75 | 80.53 | 53.78 |
| cb-pyin | 82.63 | 83.98 | 4.59 | 11.44 | 3.10 | 98.45 | 53.90 |
| *this app, as it ships* | *71.88* | *74.71* | ***0.59*** | ***3.20*** | ***2.45*** | *71.7* | ***17.1*** |

### Cello — MUSERC, 109 takes

| engine | RPA% | rep% | oct% | gross% | \|err\| p50 |
| --- | --- | --- | --- | --- | --- |
| cb-dio | 86.92 | 90.90 | **0.67** | 8.44 | 12.30 |
| cb-dio (no refine) | 86.47 | 90.43 | 0.86 | 8.71 | 14.15 |
| cb-pyin | 88.32 | 91.55 | 1.05 | 7.41 | 11.95 |

### What it says

**CometBeat's pYIN is the better *detector*; this app is the better
*tuner*.** cb-pyin answers 84% of the time against this app's 75% and is
right more often in absolute terms — but it is wrong in the ways a tuner
cannot afford: 4.59% octave errors against 0.59%, 11.44% gross against 3.20%,
and a false alarm rate of 53.9% against 17.1%. That is the same trade §4.1
found in this repo's own pYIN and declined, arrived at independently by
another project with different priorities. A transcription app wants the
answer; a tuner wants the silence.

**WORLD DIO is not a music estimator and does not pretend to be.** It was
built for speech, and on plucked guitar it manages 52% with 7.3% octave
errors. On sustained cello it reaches 86.9% — bowed strings are much closer
to the periodic, continuously-excited signal DIO assumes. Worth recording
precisely because the gap between 52% and 87% *for the same algorithm* is a
statement about the corpus, not the code.

**Everything is worse on cello than the app's guitar numbers, including
CometBeat's best.** 11.95 cents of median error against 2.45 on guitar. §11
already found the cello hard; this is independent confirmation from
algorithms that share no code with ours.

One caveat on the false-alarm column: it is high for *every* CometBeat engine
including on frames where the reference is silent, and these engines were
built to feed a note-HMM that cleans voicing up afterwards. Judging them
without it measures the estimator rather than CometBeat's pipeline, which is
the comparison asked for but is not the same as how CometBeat behaves.

### 26.1 Putting the HMM back, and a trap in doing so

§26 scored raw `pyinF0`. That is a component, not CometBeat: `route.dart:179`
runs `segmentNotes` — an HMM over the pitch lattice — after the estimator, so
unvoiced frames its own pipeline discards were being counted against it. Two
arms put it back. `+hmm` is the shipped pipeline; `+hmm-mask` uses the HMM
only for the voiced/unvoiced decision and keeps the estimator's own frequency
inside a note.

MUSERC, 12 cello takes:

| engine | RPA% | rep% | oct% | gross% | \|err\| p50 |
| --- | --- | --- | --- | --- | --- |
| cb-pyin | 96.50 | 98.44 | 0.56 | 1.00 | 3.35 |
| cb-pyin+hmm | 96.14 | 99.50 | **0.37** | **0.12** | **0.05** |
| cb-pyin+hmm-mask | 96.17 | 99.53 | 0.35 | 0.12 | 3.35 |

The HMM is doing real work: gross errors fall from 1.00% to 0.12% and octave
errors from 0.56% to 0.37%. §26's false-alarm complaint was the right
complaint.

**And that 0.05-cent column is a measurement artefact, not a result.** It is
the most dangerous number produced anywhere in this report, because it looks
like a seventy-fold improvement in exactly the quantity a tuner cares about.

`segmentNotes` returns `int midi` — semitone-quantised output. MUSERC's
reference is `take.nominal`, the *exact equal-tempered frequency of the
labelled MIDI note*. So an estimator that snaps to the nearest semitone is
being scored against a reference that is itself a nominal semitone, and it
scores near-zero by construction while saying nothing whatever about whether
the cellist was in tune. The ruler is being measured against itself.

Two consequences, both of which outlive this table:

* **MUSERC cannot evaluate quantised output.** Any pipeline that rounds to a
  semitone will score perfectly on cents there. GuitarSet can, because its
  reference is a measured pitch contour rather than a nominal — on guitar the
  same quantisation should appear as a *penalty*.
* **`+hmm` is disqualified for a tuner regardless**, and the artefact hides
  it rather than revealing it. A tuner needs the deviation from the nominal;
  an output that *is* the nominal has thrown that away. `+hmm-mask` keeps the
  estimator's frequency (3.35 cents, unchanged) while taking the HMM's
  voicing — which is the only one of the three shapes worth considering here.

The voicing question that motivated all this is unanswerable on MUSERC: each
take is one sustained note, so there is no unvoiced span and the false-alarm
column is 0.00% for every arm. GuitarSet answers it; that run is on CI,
because this box needs 70 s per file where CI needs 5.

## 27. pYIN, reconsidered: the strongest candidate this benchmark has produced

§4.1 rejected pYIN for a tuner on two grounds, and this report has now
dismantled both.

* **Latency.** §24 measured it: two frames of lookahead reach offline
  accuracy, and the variant that wins below uses **zero** — greedy decoding,
  no lookahead at all.
* **Error rates.** §24.1 left this standing: pYIN answered far more often and
  was wrong more often when it did, with 39.52% false alarm against the
  shipped pipeline's 17.07%. §24.2 then showed this app's threshold gate
  could not fix it, because pYIN already has a voicing model and the gate is
  a cruder version of the same decision.

What was missing was a *different mechanism*. CometBeat's `segmentNotes` is
one: an HMM over the pitch lattice, temporal rather than per-frame. Used as a
**voicing mask** — its note boundaries decide when to answer, pYIN's own
frequency decides what to answer — all 180 solo files:

| variant | RPA% | oct% | gross% | held RPA% | \|err\| p50 | VR% | FA% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **app, as it ships** | 71.88 | **0.59** | **3.20** | 80.80 | 2.45 | 71.69 | **17.07** |
| pyin-lag0, no HMM | 80.30 | 1.37 | 5.85 | 89.81 | 2.05 | 85.66 | 24.79 |
| **pyin-lag0 + HMM mask** | 73.60 | 0.65 | 3.45 | **88.21** | **2.00** | **75.68** | 19.22 |
| pyin-lag2 + HMM mask | 79.05 | 0.82 | 5.15 | 88.92 | 2.00 | 83.45 | 32.73 |

**The voicing gap closed from 22 points to 2.** And on the axes a tuner is
judged by, the masked variant wins:

* **held-note accuracy 88.21% against 80.80%** — a note held while a peg
  turns, which is the measurement the product exists to perform;
* **2.00 cents against 2.45** on the number the needle shows;
* voicing recall 75.68% against 71.69%, so it answers *more* often as well as
  more accurately.

What it concedes is now marginal rather than disqualifying: 0.65% octave
errors against 0.59%, 3.45% gross against 3.20%, 19.22% false alarm against
17.07%.

### 27.1 Why the mask, and not the HMM's own output

`segmentNotes` returns `int midi`. Taking that as the reading quantises to
the semitone and **discards the deviation a tuner exists to show** — and
§26.1 records how badly that can hide: on MUSERC, whose reference is a
nominal semitone, quantised output scores **0.05 cents**, an apparent
seventyfold improvement that is pure artefact.

§26.1 predicted the same quantisation would appear as a *penalty* on
GuitarSet, whose reference is a measured contour rather than a nominal. It
does, and the sign flip is the cleanest demonstration in this report that the
reference matters more than the metric — CometBeat's own engine, 180 files:

| | \|err\| p50 on cello (nominal ref) | \|err\| p50 on guitar (measured ref) |
| --- | --- | --- |
| cb-pyin | 11.95 | 3.10 |
| cb-pyin + hmm (quantised) | **0.05** | **7.35** |
| cb-pyin + hmm mask | 11.85 | 3.00 |

Same code, opposite conclusion, depending only on what it is scored against.

The mask is also the better choice for **CometBeat**, whose shipped pipeline
currently takes the quantised output: `+hmm-mask` dominates raw `cb-pyin` on
every axis — false alarm 53.90% → 29.59%, octave 4.59% → 2.14%, gross 11.44%
→ 6.92% — while *improving* cents from 3.10 to 3.00.

### 27.2 What stands between this and shipping

One structural thing, and it is the same problem this report has already
solved once.

**`segmentNotes` is a Viterbi over the whole track.** It is offline, exactly
as pYIN's own decode was before §24 gave it a bounded lag. A live tuner needs
a streaming version, and the numbers above do not account for one. The
pattern is known — decide frame *t* from the best state at *t+lag*, sharing
the forward pass — but it is real work, and until it exists this is a result
rather than a feature.

Two smaller ones. pYIN costs more per frame than YIN (§4 put its front end at
7–8% of the frame budget, which is affordable but not free). And
`segmentNotes` is CometBeat's code: shipping needs a port and a licence
check, not a copy.

**Recommendation: this is worth building.** It is the only change this
benchmark has found that improves the tuner on its own terms — better on
held notes, better on cents, near-parity on the errors — rather than
improving a side mode or a runtime. Every runtime result in §17–§23 made
something faster that was already fast enough; this makes the needle better.

### 27.3 A streaming voicing model that does not work, and why

§27.2 named the blocker — the note-HMM is offline — and the obvious fix
looked small. The mask throws away the HMM's note identity (§27.1), so a
model that decides *only* voiced against unvoiced should serve: two states
instead of one per MIDI note, bounded lag instead of the whole track.
`lib/voicing_hmm.dart` is that, built on §24's structure.

It does not reproduce §27. Ten solo files:

| variant | RPA% | oct% | gross% | held RPA% | \|err\| p50 | FA% |
| --- | --- | --- | --- | --- | --- | --- |
| `engine-yin` (ships) | 69.39 | 0.62 | 3.58 | 76.23 | 2.85 | 19.08 |
| pyin-lag0 **+ note HMM** (offline) | 77.49 | 0.48 | 5.48 | **86.59** | 2.45 | 31.32 |
| pyin-lag0 + voicing HMM, lag 2 | 67.46 | 0.64 | 3.64 | 75.41 | 2.20 | **15.02** |

It is far more conservative — false alarm 15.02%, better than the shipped
19.08% — and it gives up almost all of §27's gain: held-note accuracy 75.41%
against the note-HMM's 86.59%.

**The constants are not the reason.** A sweep of the two costs across an
order of magnitude each moves nothing that matters:

| switch / evidence | RPA% | held RPA% | FA% |
| --- | --- | --- | --- |
| 0.4 / 1.0 | 67.52 | 75.46 | 14.94 |
| 0.4 / 2.0 | 67.69 | 75.48 | 15.02 |
| 2.5 / 2.0 | 67.48 | 75.96 | 14.47 |
| 5.0 / 1.0 | 65.09 | 75.80 | 18.12 |
| 5.0 / 0.5 | 66.62 | 78.01 | 20.83 |

Every setting lands in the same place. That is the signature of a model that
lacks information rather than one that is mistuned.

**The diagnosis corrects an assumption in §27.1.** That section established
that the note HMM's *output* must be discarded, because `int midi` quantises
away the deviation a tuner exists to show — and that is still right. What it
led me to assume, wrongly, is that the note states were therefore not
load-bearing.

They are. The note HMM decides voicing **using pitch continuity**: a frame
belongs to note N when its f0 sits near N, and staying on N is cheap, so a
frame whose *confidence* dipped is still held if its *pitch* is consistent
with the note already in progress. A two-state model sees only pYIN's
probability mass — a scalar — and has no way to know that the wobbly frame
it is about to cut is the middle of a perfectly steady note.

So the note states are needed for the **decision** and must not be used for
the **answer**. Those are compatible, and they point at the design this
should have had: a note-state HMM with a bounded lag, not a smaller model
with a bounded lag. That is §24's trick applied to the structure that
actually earns the result, and it is the next piece of work rather than a
tuning exercise.

---

*Harness, exact commands and how the copied core is kept in sync:
[`README.md`](README.md). Raw aggregates:
`results/*.json`, gitignored — regenerate with `bin/bench.dart`.*
