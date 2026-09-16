# CrispTuner 🎸

A precise chromatic instrument tuner built with Flutter — real-time pitch
detection, alternate and custom tunings, historical temperaments, frequency
analysis and reference tone generation, on iOS, macOS, Android, Windows, Linux
and the web.

## Features

- **Eleven instruments** — guitar, 7-string guitar, bass, 5-string bass,
  ukulele, banjo, mandolin, violin, viola, cello, double bass.
- **Over thirty tunings** — Drop D/C/A, DADGAD, Open G/D/E/C, half and whole
  step down, low-G and baritone ukulele, banjo double C, cello and double-bass
  solo tunings — plus a **custom tuning** of up to twelve strings, edited a
  semitone at a time and saved.
- **Six historical temperaments** — equal, Pythagorean, quarter-comma
  meantone, Werckmeister III, Kirnberger III, Vallotti — in any key, with a
  live readout of how far the current note sits from equal temperament.
- **Real-time pitch detection** — YIN over a 4096-sample rolling window, with a
  5-sample median filter so the reading stays steady instead of jittering.
- **Cent-accurate tuning meter** — in-tune / too sharp / too flat, with the
  exact deviation in cents.
- **Live visualisations** — pitch-history graph and frequency spectrum.
- **Reference tones** — phase-continuous sine waves for every string of the
  selected tuning, at the calibrated pitch *and* temperament.
- **Adjustable concert pitch** — 415–465 Hz.
- **Microphone selection** when more than one input is available.
- **Accessible** — VoiceOver labels throughout; the detected note is a live
  region.
- **Light and dark themes**, English and German.

### Two things worth knowing about the maths

**Temperaments are derived, not copied.** Each one is defined by the sizes of
the twelve fifths around the circle (`lib/temperament.dart`), and the cent
deviations fall out of that. Published tables for these temperaments disagree
in the last decimal and sometimes in which note is taken as zero; deriving them
means the result can be checked against a textbook, which
`test/temperament_test.dart` does. Every temperament is then anchored so **A is
exactly the concert pitch you set**, in every key.

**Notes are found logarithmically.** The nearest note comes from the pitch's
position on a log scale, not from scanning for the smallest linear frequency
difference. The boundary between two semitones is their geometric mean, not
their arithmetic one — between A4 and A♯4 the two differ by 0.19 Hz, and a
linear search hands that whole band to the lower note.

## Privacy

The app collects nothing. Audio is analysed on-device in real time and is never
recorded, stored or transmitted; there are no accounts, analytics, ads, tracking
or network requests. Only your settings — concert pitch, instrument, tuning,
custom tuning and temperament — are saved, locally.

Policy: [`web/privacy.html`](web/privacy.html) → https://crisptuner.vercel.app/privacy.html

## Technical stack

| Piece | Package |
|---|---|
| Pitch detection (YIN) | `pitch_detector_dart`, 4096-sample window |
| FFT / spectrum | `fftea` |
| Microphone capture (mobile/desktop) | `record` |
| Reference tone output | `flutter_pcm_sound` |
| Web audio | `AudioWorkletNode`, with a `ScriptProcessorNode` fallback |
| Settings | `shared_preferences` |

### Architecture

`lib/tuner_core.dart` holds the maths — note naming, cents, the tempered
nearest-note search, the median filter and the rolling sample window — and
imports **no Flutter whatsoever**, so it runs under a plain `dart run`.
`lib/temperament.dart` and `lib/tunings.dart` are likewise Flutter-free.
`TunerEngine` (`lib/tuner_engine.dart`) adds the mutable state and extends
`ChangeNotifier`, so the UI in `lib/main.dart` is a thin shell driven by a
`ListenableBuilder`. Platform audio lives behind an abstract interface
(`audio_service_stub.dart`) with conditional imports selecting the mobile or web
implementation.

Audio pipeline: PCM16 @ 44.1 kHz → `Float64List` → a 4096-sample
`RollingWindow` → YIN → median filter → nearest-note match against the
tempered targets → cents. The window accumulates across callbacks, so the
analysis size no longer depends on whatever chunk size the platform happens to
deliver. In parallel, a Hann-windowed 2048-point FFT over the most recent
samples feeds the spectrum display, throttled to ~20 fps.

## Running locally

```bash
flutter pub get
flutter run -d macos      # or ios / android / chrome
```

If CocoaPods fails with a missing `nkf` gem, a stale `GEM_HOME`/`GEM_PATH` from
a Ruby version manager is shadowing Homebrew's Ruby. Clear them:

```bash
env -u GEM_HOME -u GEM_PATH -u RUBYOPT flutter run -d macos
```

## Headless probe

`tool/tuner_probe.dart` runs the *real* detection pipeline — YIN, the median
filter, and the tempered nearest-note search — against a WAV file or a
synthesised tone, from a terminal. No device, no simulator, no microphone:

```bash
dart run tool/tuner_probe.dart --note E2                  # a plucked low E
dart run tool/tuner_probe.dart --note E2 --detune -31     # …pulled flat
dart run tool/tuner_probe.dart --note C#4 --temperament quarterCommaMeantone
dart run tool/tuner_probe.dart --wav /tmp/guitar.wav
dart run tool/tuner_probe.dart --note B0 --buffer 2048    # see the old floor
```

It prints a per-frame table with an ASCII meter and a summary. This is only
possible because the maths lives in `lib/tuner_core.dart`, which imports no
Flutter at all — `TunerEngine` is the `ChangeNotifier` wrapper around it. Move
the maths back behind Flutter and the probe stops running, which is the point.

It earns its keep: it is what found that a 2048-sample YIN window cannot
resolve anything below 43.07 Hz, so a bass guitar's open low E (41.20 Hz) was
being reported as an F and a five-string's low B (30.87 Hz) produced no reading
at all. Hence the 4096-sample window.

## UI previews

To eyeball layout without a device:

```bash
flutter test -t preview --update-goldens
```

writes phone, tablet, light, dark and dense-settings renders to
`test/goldens/preview/`. These are previews, not assertions.

## Tests

```bash
flutter test              # everything
flutter test -x golden    # skip golden images (what CI runs on Linux)
flutter test -t golden    # golden images only (macOS — where they were recorded)
```

Golden images are renderer-specific, so the checked-in PNGs are macOS renders and
CI verifies them on a macOS runner. After an intentional painter change, re-record
with `flutter test --update-goldens -t golden` and eyeball the result.

## Releasing

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | push / PR | analyze, test, build every platform |
| `release.yml` | tag `v*` | cross-platform binaries → GitHub Release |
| `ios-release.yml` | tag `v*` | signed IPA → App Store Connect |
| `macos-release.yml` | tag `macos-v*` | signed `.pkg` → App Store Connect |
| `deploy-vercel.yml` | push to `main` | web build → Vercel |

Both store workflows also accept a manual run with `dry_run=true`, which builds
and signs without uploading — use that to validate signing safely.

Bump `version:` in `pubspec.yaml` before tagging: Apple rejects a duplicate
`CFBundleVersion`, and once a version is approved the marketing version
(`x.y.z`) must increase too, not just the build number.

See [`APPSTORE.md`](APPSTORE.md) for the store submission state and the steps
that still need a human.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- YIN pitch detection algorithm by Alain de Cheveigné
- FFT implementation by the `fftea` package authors
