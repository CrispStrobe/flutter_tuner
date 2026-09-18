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

20 solo files, 23,510 frames, through the same `PitchSmoother` as everything
else:

| estimator | RPA% | rep% | oct% | gross% | \|err\| p50 | >5c% | FA% | ms/frame |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| app YIN | **68.3** | 71.1 | **0.66** | **3.2** | **3.00** | **26.1** | **17.0** | **4.1** |
| SWIPE′, global norm | 63.5 | 100 | 1.41 | 35.1 | 7.70 | 70.2 | 100 | 6.9 |
| SWIPE′, local norm | 67.3 | 100 | 4.25 | 28.4 | 6.65 | 63.0 | 100 | 8.2 |
| SWIPE′, global norm @ 0.7 | 47.1 | 68.8 | 0.97 | 30.6 | 7.40 | 68.6 | 42.8 | 6.9 |

**It loses on every axis a tuner cares about.** Twice YIN's median cent error,
eight to ten times its gross-error rate, and — the part that was supposed to
be its advantage — *more* octave errors, not fewer. On clean synthetic plucks
its intrinsic precision is about 3 cents against YIN's 0.05, and that does
not improve with a finer candidate grid: 1/48, 1/96 and 1/192 of an octave
give 2.6, 3.2 and 3.8 cents, so the limit is the breadth of the strength
curve, not the quantisation.

Its voicing decision is also awkward. The pitch strength lands around 0.77 on
a clean plucked string — nowhere near the scale the app's `probability > 0.9`
gate expects, and a first run of this file rejected literally every frame for
that reason. Swept properly, the threshold that gives an acceptable false
alarm rate throws away a third of the true frames.

A more faithful implementation would do better than this one. It would have
to close a 2× gap in precision and an 8× gap in gross errors while costing
more per frame, which is not where the evidence points.

### 4.6 Neural models

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

### 10.2 MT3

96 MB, 46.9M parameters, a T5 encoder–decoder emitting event tokens
autoregressively over multi-second context. Nothing about that is compatible
with a tuner's latency budget, and it would multiply the app's download size
many times over. As an offline "record a phrase, get a MIDI file" feature it
is plausible; as anything on the audio path it is not, and it was not
measured here because the architecture answers the question by itself.

### 10.3 So what would it be for?

Not the needle. YIN keeps that: 2.45 cents against 27, at a six-hundredth of
the cost per unit of audio.

What Basic Pitch could add is the thing the current app cannot do at all —
**polyphony**. Strum once and tune six strings; show a chord; transcribe a
phrase. Those are features, not accuracy improvements, and they would run as
a separate mode with its own budget, leaving the tuner path exactly as it is.
If that mode is wanted, the measured order is: native ORT works now; pure
Dart is within reach after the 3× above and would keep the app
dependency-free on all six platforms including web; MT3 stays offline.

## 11. What to do, now

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
   its own selling point — octave errors, while costing more per frame. Basic Pitch is better
   than YIN at naming notes and 10× worse at cents, which is the only
   question the needle asks. If polyphonic transcription is wanted as a
   separate mode, it is feasible — effectively causal, so a sliding window
   works — but only on native ONNX Runtime until `onnx_runtime_dart`'s
   convolutions get the same FFT treatment YIN's difference function got.

## 12. What would make this measurement better

* **The reference is itself an algorithm.** GuitarSet's contours come from
  pYIN on a hexaphonic pickup. Below a few cents, this benchmark is
  comparing two estimators, not measuring error. Held-note median errors
  around 2–3 cents should be read as an upper bound on the app's error, and
  the sub-cent claims in §4.3 rest on synthesis, not on the corpus.
* **Guitar only.** Nothing here speaks to bass, piano, voice, or wind
  instruments, and two of the report's conclusions (window size,
  inharmonicity) are explicitly limited by that.
* ~~**Frame-level, not note-level.**~~ Done — §9 times the pluck, §9.1 times
  the peg turn.
* **A busy shared VPS.** The timings are ratios worth trusting and absolutes
  worth re-measuring on a phone.

---

*Harness, exact commands and how the copied core is kept in sync:
[`README.md`](README.md). Raw aggregates:
`results/*.json`, gitignored — regenerate with `bin/bench.dart`.*
