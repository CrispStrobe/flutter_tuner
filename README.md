# CrispTuner 🎸

A precise chromatic instrument tuner built with Flutter — real-time pitch
detection, frequency analysis and reference tone generation, on iOS, macOS,
Android, Windows, Linux and the web.

## Features

- **Real-time pitch detection** — YIN algorithm over a 2048-sample buffer, with a
  5-sample median filter so the reading stays steady instead of jittering.
- **Cent-accurate tuning meter** — in-tune / too sharp / too flat, with the exact
  deviation in cents.
- **Live visualisations** — pitch-history graph and frequency spectrum analyser.
- **Reference tones** — phase-continuous sine waves for every string of the
  selected instrument, at the *calibrated* pitch (not quantised to 440 Hz).
- **Six instruments** — guitar, bass, violin, cello, ukulele, mandolin.
- **Adjustable concert pitch** — 415–465 Hz.
- **Microphone selection** when more than one input is available.
- **Accessible** — VoiceOver labels throughout; the detected note is a live region.
- **Localised** — English and German.

## Privacy

The app collects nothing. Audio is analysed on-device in real time and is never
recorded, stored or transmitted; there are no accounts, analytics, ads, tracking
or network requests. Only your A4 setting and chosen instrument are saved, locally.

Policy: [`web/privacy.html`](web/privacy.html) → https://crisptuner.vercel.app/privacy.html

## Technical stack

| Piece | Package |
|---|---|
| Pitch detection (YIN) | `pitch_detector_dart` |
| FFT / spectrum | `fftea` |
| Microphone capture (mobile/desktop) | `record` |
| Reference tone output | `flutter_pcm_sound` |
| Web audio | `AudioWorkletNode`, with a `ScriptProcessorNode` fallback |
| Settings | `shared_preferences` |

### Architecture

`TunerEngine` (`lib/tuner_engine.dart`) is pure Dart and holds all the maths —
pitch detection, note matching, cents, FFT, pitch history. It extends
`ChangeNotifier`, so the UI in `lib/main.dart` is a thin shell driven by a
`ListenableBuilder`. Platform audio lives behind an abstract interface
(`audio_service_stub.dart`) with conditional imports selecting the mobile or web
implementation.

Audio pipeline: PCM16 @ 44.1 kHz → `Float64List` → YIN pitch detection → median
filter → nearest-note match → cents. In parallel, a Hann-windowed 2048-point FFT
feeds the spectrum display, throttled to ~20 fps.

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
