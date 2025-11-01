# Flutter Pro 🎸

A simple instrument tuner app built with Flutter, featuring real-time pitch detection, frequency analysis, and reference tone generation.

## Features

✨ **Real-time Pitch Detection** - Accurately detects musical notes from microphone input
📊 **Live Visualizations** - Pitch history graph and frequency spectrum analyzer
🎵 **Reference Tone Generator** - Play reference tones for each string
🎸 **Multiple Instruments** - Guitar, Bass, Cello, and Violin tunings
⚙️ **Customizable A4 Frequency** - Adjust concert pitch (415-465 Hz)
🎨 **Beautiful UI** - Dark theme with gradient backgrounds and smooth animations

## Technical Stack

- **Flutter** - Cross-platform UI framework
- **pitch_detector_dart** - YIN algorithm for pitch detection
- **fftea** - Fast Fourier Transform for frequency analysis
- **record** - Audio input from microphone
- **flutter_pcm_sound** - Real-time audio playback with phase-continuous sine wave generation

## Architecture

### Audio Processing Pipeline
1. Microphone captures PCM16 audio at 44.1kHz
2. Pitch detection using YIN algorithm (2048 sample buffer)
3. FFT analysis for frequency spectrum visualization
4. Cent deviation calculation for tuning accuracy

### Tone Generation
- Phase-continuous sine wave synthesis
- Sample rate: 44.1kHz
- Amplitude: 16000 (safe listening level)
- Real-time audio streaming via flutter_pcm_sound with phase tracking for clean tone generation

## Running Locally
```bash
# Get dependencies
flutter pub get

# Run on macOS
flutter run -d macos

# Run on iOS simulator
flutter run -d ios

# Run on Android emulator
flutter run -d android
```

## License
MIT

## Acknowledgments
- YIN pitch detection algorithm by Alain de Cheveigné
- FFT implementation by the fftea package authors
