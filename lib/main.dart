import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:fftea/fftea.dart';
import 'package:collection/collection.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

void main() {
  runApp(const TunerApp());
}

class TunerApp extends StatelessWidget {
  const TunerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Tuner',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.deepOrange,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        useMaterial3: true,
      ),
      home: const TunerPage(),
    );
  }
}

class ToneGenerator {
  bool _isInitialized = false;
  bool _isPlaying = false;
  int _currentNote = -1;
  double _phase = 0.0;
  double _envelope = 0.0; // For smooth fade-in/out
  static const double _fadeInDuration = 0.05; // 50ms fade-in
  static const double _fadeOutDuration = 0.05; // 50ms fade-out
  int _sampleCount = 0;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      await FlutterPcmSound.setup(sampleRate: 44100, channelCount: 1);
      await FlutterPcmSound.setFeedThreshold(4000);
      _isInitialized = true;
    } catch (e) {
      print('Error initializing tone generator: $e');
    }
  }

  void playNote(double frequency) {
    if (!_isInitialized) return;
    _currentNote = (69 + 12 * (math.log(frequency / 440.0) / math.log(2))).round();
    _phase = 0.0;
    _envelope = 0.0;
    _sampleCount = 0;
    if (!_isPlaying) {
      _isPlaying = true;
      FlutterPcmSound.setFeedCallback(_onFeed);
      _startFeeding();
    }
  }

  void _startFeeding() => _onFeed(0);

  void _onFeed(int remainingFrames) async {
    if (!_isPlaying || _currentNote < 0) return;
    final frequency = 440.0 * math.pow(2, (_currentNote - 69) / 12.0);
    final samples = _generateSineWave(frequency, 2000);
    await FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
  }

  List<int> _generateSineWave(double frequency, int numSamples) {
    final samples = <int>[];
    const sampleRate = 44100;
    const amplitude = 20000; // Increased amplitude for better volume
    const fadeInSamples = sampleRate * _fadeInDuration;
    
    for (int i = 0; i < numSamples; i++) {
      // Calculate envelope (fade-in)
      if (_sampleCount < fadeInSamples) {
        _envelope = _sampleCount / fadeInSamples;
      } else {
        _envelope = 1.0;
      }
      
      // Generate sine wave with envelope
      final value = (amplitude * _envelope * math.sin(_phase)).toInt();
      samples.add(value);
      
      // Update phase
      _phase += 2 * math.pi * frequency / sampleRate;
      if (_phase > 2 * math.pi) _phase -= 2 * math.pi;
      
      _sampleCount++;
    }
    return samples;
  }

  void stopNote() {
    if (!_isPlaying) return;
    
    // Generate fade-out samples before stopping
    if (_isInitialized && _currentNote >= 0) {
      final frequency = 440.0 * math.pow(2, (_currentNote - 69) / 12.0);
      final fadeOutSamples = _generateFadeOut(frequency, (44100 * _fadeOutDuration).toInt());
      FlutterPcmSound.feed(PcmArrayInt16.fromList(fadeOutSamples));
    }
    
    _isPlaying = false;
    _currentNote = -1;
    _phase = 0.0;
    _envelope = 0.0;
    _sampleCount = 0;
  }

  List<int> _generateFadeOut(double frequency, int numSamples) {
    final samples = <int>[];
    const sampleRate = 44100;
    const amplitude = 20000;
    
    for (int i = 0; i < numSamples; i++) {
      // Linear fade-out
      final fadeOut = 1.0 - (i / numSamples);
      final value = (amplitude * fadeOut * math.sin(_phase)).toInt();
      samples.add(value);
      
      _phase += 2 * math.pi * frequency / sampleRate;
      if (_phase > 2 * math.pi) _phase -= 2 * math.pi;
    }
    return samples;
  }

  void dispose() {
    stopNote();
    FlutterPcmSound.release();
  }
}

class TunerPage extends StatefulWidget {
  const TunerPage({super.key});

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with WidgetsBindingObserver {
  final _audioRecorder = AudioRecorder();
  final _pitchDetector = PitchDetector();
  final _toneGenerator = ToneGenerator();

  String _note = '';
  String _status = 'Start Tuning';
  double _pitch = 0.0;
  double _cents = 0.0;
  bool _isListening = false;
  Timer? _timer;
  StreamSubscription? _audioSubscription;

  double _a4Frequency = 440.0;
  Instrument _selectedInstrument = Instrument.guitar;
  Map<String, double> _standardPitches = {};

  List<double> _fftData = [];
  final QueueList<double> _pitchHistory = QueueList<double>(100);

  bool _isGeneratingTone = false;
  String? _currentlyPlayingNote;

  static const Map<Instrument, List<String>> _instrumentTunings = {
    Instrument.guitar: ['E2', 'A2', 'D3', 'G3', 'B3', 'E4'],
    Instrument.cello: ['C2', 'G2', 'D3', 'A3'],
    Instrument.bass: ['E1', 'A1', 'D2', 'G2'],
    Instrument.violin: ['G3', 'D4', 'A4', 'E5'],
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _recalculatePitches();
    for (int i = 0; i < 100; i++) {
      _pitchHistory.add(0);
    }
    _toneGenerator.init();
  }

  @override
  void dispose() {
    _stopCapture();
    _toneGenerator.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _audioSubscription?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _stopCapture();
      _stopToneGenerator();
    } else if (state == AppLifecycleState.resumed && _isListening) {
      _startCapture();
    }
  }

  Future<void> _toggleListening() async {
    if (_isGeneratingTone) _stopToneGenerator();
    if (_isListening) {
      _stopCapture();
    } else {
      await _startCapture();
    }
  }

  Future<void> _startCapture() async {
    if (await _audioRecorder.hasPermission()) {
      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 44100,
          numChannels: 1,
        ),
      );
      _audioSubscription = stream.listen((data) => _processAudioData(data));
      setState(() => _isListening = true);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (mounted && _isListening) {
          setState(() {
            _note = '';
            _status = 'Listening...';
            _pitch = 0;
            _cents = 0;
          });
        }
      });
    } else {
      setState(() => _status = 'Microphone permission denied');
    }
  }

  void _processAudioData(Uint8List data) async {
    final floatData = <double>[];
    for (int i = 0; i < data.length - 1; i += 2) {
      final int sample = data[i] | (data[i + 1] << 8);
      final int signedSample = sample > 32767 ? sample - 65536 : sample;
      floatData.add(signedSample / 32768.0);
    }
    if (floatData.length < 2048) return;

    try {
      final result = await _pitchDetector.getPitchFromFloatBuffer(floatData);
      if (result.pitched && result.probability > 0.9) {
        _updatePitch(result.pitch);
      }
    } catch (e) {}

    final fftSize = 2048;
    final paddedSample = List<double>.filled(fftSize, 0.0);
    for (int i = 0; i < floatData.length && i < fftSize; i++) {
      paddedSample[i] = floatData[i];
    }
    final fft = FFT(fftSize);
    final fftResult = fft.realFft(paddedSample);
    if (mounted) {
      setState(() => _fftData = fftResult.discardConjugates().magnitudes().toList());
    }
  }

  void _stopCapture() async {
    await _audioRecorder.stop();
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    _timer?.cancel();
    if (mounted) {
      setState(() {
        _note = '';
        _pitch = 0.0;
        _cents = 0.0;
        _isListening = false;
        _status = 'Start Tuning';
        _fftData = [];
      });
    }
  }

  void _updatePitch(double detectedPitch) {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted && _isListening) {
        setState(() {
          _note = '';
          _status = 'Listening...';
          _pitch = 0;
          _cents = 0;
        });
      }
    });

    if (!mounted || detectedPitch <= 0) return;

    String closestNote = '';
    double minDifference = double.infinity;
    double targetFrequency = 0;

    _standardPitches.forEach((note, frequency) {
      final difference = (detectedPitch - frequency).abs();
      if (difference < minDifference) {
        minDifference = difference;
        closestNote = note;
        targetFrequency = frequency;
      }
    });

    final centsDifference = 1200 * (math.log(detectedPitch / targetFrequency) / math.log(2));
    if (_pitchHistory.length >= 100) _pitchHistory.removeFirst();
    _pitchHistory.add(centsDifference.clamp(-50, 50));

    setState(() {
      _pitch = detectedPitch;
      _note = closestNote;
      _cents = centsDifference;
      if (centsDifference.abs() < 5) {
        _status = 'In Tune ✓';
      } else if (centsDifference > 5) {
        _status = 'Too Sharp ↑';
      } else {
        _status = 'Too Flat ↓';
      }
    });
  }

  void _recalculatePitches() {
    const Map<String, int> noteOffsets = {
      'A0': -48, 'A#0': -47, 'B0': -46, 'C1': -45, 'C#1': -44, 'D1': -43,
      'D#1': -42, 'E1': -41, 'F1': -40, 'F#1': -39, 'G1': -38, 'G#1': -37,
      'A1': -36, 'A#1': -35, 'B1': -34, 'C2': -33, 'C#2': -32, 'D2': -31,
      'D#2': -30, 'E2': -29, 'F2': -28, 'F#2': -27, 'G2': -26, 'G#2': -25,
      'A2': -24, 'A#2': -23, 'B2': -22, 'C3': -21, 'C#3': -20, 'D3': -19,
      'D#3': -18, 'E3': -17, 'F3': -16, 'F#3': -15, 'G3': -14, 'G#3': -13,
      'A3': -12, 'A#3': -11, 'B3': -10, 'C4': -9, 'C#4': -8, 'D4': -7,
      'D#4': -6, 'E4': -5, 'F4': -4, 'F#4': -3, 'G4': -2, 'G#4': -1, 'A4': 0,
      'A#4': 1, 'B4': 2, 'C5': 3, 'C#5': 4, 'D5': 5, 'D#5': 6, 'E5': 7,
      'F5': 8, 'F#5': 9, 'G5': 10, 'G#5': 11, 'A5': 12, 'A#5': 13, 'B5': 14,
      'C6': 15,
    };
    _standardPitches.clear();
    noteOffsets.forEach((note, offset) {
      _standardPitches[note] = _a4Frequency * math.pow(2, offset / 12.0);
    });
  }

  void _toggleToneGenerator(String note) {
    if (_isListening) _stopCapture();
    if (_currentlyPlayingNote == note) {
      _stopToneGenerator();
    } else {
      final frequency = _standardPitches[note];
      if (frequency != null) {
        _toneGenerator.playNote(frequency);
        setState(() {
          _currentlyPlayingNote = note;
          _isGeneratingTone = true;
          _status = 'Playing ${note.replaceAll(RegExp(r'[0-9]'), '')}';
        });
      }
    }
  }

  void _stopToneGenerator() {
    _toneGenerator.stopNote();
    setState(() {
      _currentlyPlayingNote = null;
      _isGeneratingTone = false;
      _status = 'Start Tuning';
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Flutter Pro Tuner', style: TextStyle(fontSize: 18)),
        centerTitle: true,
        backgroundColor: Colors.black.withOpacity(0.3),
        elevation: 0,
        toolbarHeight: 48,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF0A0A0A),
              const Color(0xFF1A1A1A),
              Colors.deepOrange.withOpacity(0.1),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                // Compact note display
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      _note.replaceAll(RegExp(r'[0-9]'), ''),
                      style: TextStyle(
                        fontSize: 72,
                        fontWeight: FontWeight.bold,
                        color: _status == 'In Tune ✓' ? Colors.greenAccent : Colors.white,
                        height: 1,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(_status, style: TextStyle(fontSize: 16, color: _getStatusColor())),
                  ],
                ),
                const SizedBox(height: 12),

                // Tuning meter
                _buildTuningMeter(size.width * 0.85),
                const SizedBox(height: 4),
                Text('${_pitch.toStringAsFixed(2)} Hz',
                    style: const TextStyle(fontSize: 14, color: Colors.white60)),
                const SizedBox(height: 12),

                // String indicators
                _buildCompactStringIndicators(),
                const SizedBox(height: 12),

                // Visualizations side by side
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          const Text('Pitch History',
                              style: TextStyle(color: Colors.white60, fontSize: 12)),
                          const SizedBox(height: 4),
                          Container(
                            height: 100,
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox.expand(
                                child: CustomPaint(
                                  painter: PitchHistoryPainter(_pitchHistory.toList(), Colors.deepOrange),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        children: [
                          const Text('Frequency Spectrum',
                              style: TextStyle(color: Colors.white60, fontSize: 12)),
                          const SizedBox(height: 4),
                          Container(
                            height: 100,
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox.expand(
                                child: CustomPaint(
                                  painter: FFTPainter(_fftData, Colors.greenAccent),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Compact settings and mic button
                Row(
                  children: [
                    Expanded(child: _buildCompactSettings()),
                    const SizedBox(width: 12),
                    _buildCompactMicButton(),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _getStatusColor() {
    if (_status == 'In Tune ✓') return Colors.greenAccent;
    if (_status == 'Start Tuning' || _status == 'Listening...') return Colors.white70;
    if (_isGeneratingTone) return Colors.cyanAccent;
    return Colors.orangeAccent;
  }

  Widget _buildTuningMeter(double width) {
    final clampedCents = _cents.clamp(-50.0, 50.0);
    final meterPosition = clampedCents / 50.0;
    final leftMargin = meterPosition > 0 ? meterPosition * (width / 2 - 20) : 0.0;
    final rightMargin = meterPosition < 0 ? -meterPosition * (width / 2 - 20) : 0.0;

    return Container(
      width: width,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white24, width: 2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(width: 3, height: 40, color: Colors.white24),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: EdgeInsets.only(left: leftMargin, right: rightMargin),
            width: 6,
            height: 40,
            decoration: BoxDecoration(
              color: _getStatusColor(),
              borderRadius: BorderRadius.circular(3),
              boxShadow: [
                BoxShadow(
                  color: _getStatusColor().withOpacity(0.6),
                  blurRadius: 15,
                  spreadRadius: 3,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactStringIndicators() {
    List<String> strings = _instrumentTunings[_selectedInstrument]!;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: strings.map((stringNote) {
        final bool isCurrentNote = _note == stringNote;
        final bool isInTune = isCurrentNote && _status == 'In Tune ✓';
        final bool isPlayingThisTone = _currentlyPlayingNote == stringNote;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isCurrentNote ? Colors.deepOrange : Colors.white12,
                  width: 2,
                ),
              ),
              child: Text(
                stringNote.replaceAll(RegExp(r'[0-9]'), ''),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isInTune ? Colors.greenAccent : (isCurrentNote ? Colors.orangeAccent : Colors.white12),
                boxShadow: isInTune
                    ? [BoxShadow(color: Colors.greenAccent.withOpacity(0.8), blurRadius: 8, spreadRadius: 2)]
                    : [],
              ),
            ),
            IconButton(
              icon: Icon(isPlayingThisTone ? Icons.stop_circle : Icons.play_circle_outline, size: 24),
              color: isPlayingThisTone ? Colors.cyanAccent : Colors.white70,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => _toggleToneGenerator(stringNote),
            ),
          ],
        );
      }).toList(),
    );
  }

  Widget _buildCompactSettings() {
    final bool isActionDisabled = _isListening || _isGeneratingTone;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('A4: ${_a4Frequency.toStringAsFixed(1)} Hz',
              style: const TextStyle(color: Colors.white, fontSize: 13)),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.deepOrange,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.deepOrange,
              overlayColor: Colors.deepOrange.withOpacity(0.2),
              trackHeight: 2,
            ),
            child: Slider(
              value: _a4Frequency,
              min: 415,
              max: 465,
              divisions: 500,
              onChanged: isActionDisabled
                  ? null
                  : (value) {
                      setState(() {
                        _a4Frequency = value;
                        _recalculatePitches();
                      });
                    },
            ),
          ),
          DropdownButtonFormField<Instrument>(
            value: _selectedInstrument,
            isDense: true,
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.white12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.white12),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            dropdownColor: const Color(0xFF1A1A1A),
            onChanged: isActionDisabled
                ? null
                : (Instrument? newValue) {
                    if (newValue != null) {
                      setState(() => _selectedInstrument = newValue);
                    }
                  },
            items: Instrument.values.map<DropdownMenuItem<Instrument>>((value) {
              return DropdownMenuItem<Instrument>(
                value: value,
                child: Text(value.name.capitalize(), style: const TextStyle(fontSize: 14)),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactMicButton() {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: (_isListening ? Colors.redAccent : Colors.greenAccent).withOpacity(0.4),
            blurRadius: 15,
            spreadRadius: 3,
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: _toggleListening,
        style: ElevatedButton.styleFrom(
          backgroundColor: _isListening ? Colors.redAccent : Colors.greenAccent,
          shape: const CircleBorder(),
          padding: const EdgeInsets.all(20),
          elevation: 8,
        ),
        child: Icon(
          _isListening ? Icons.mic_off : Icons.mic,
          size: 32,
          color: Colors.black87,
        ),
      ),
    );
  }
}

class FFTPainter extends CustomPainter {
  final List<double> fftData;
  final Color color;

  FFTPainter(this.fftData, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (fftData.isEmpty) return;
    
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    
    final double barWidth = size.width / (fftData.length / 8);
    final double maxMagnitude = fftData.sublist(0, fftData.length ~/ 2).reduce(math.max);
    
    // Fix: Check if maxMagnitude is valid before drawing
    if (maxMagnitude <= 0 || maxMagnitude.isNaN || maxMagnitude.isInfinite) {
      return; // Skip drawing if no valid data
    }
    
    for (int i = 0; i < fftData.length / 8; i++) {
      final double magnitude = fftData[i];
      final double barHeight = (magnitude / maxMagnitude) * size.height;
      
      // Additional safety check for the calculated values
      if (barHeight.isNaN || barHeight.isInfinite || barHeight < 0) {
        continue; // Skip this bar if invalid
      }
      
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * barWidth, size.height - barHeight, barWidth * 0.8, barHeight),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class PitchHistoryPainter extends CustomPainter {
  final List<double> pitchHistory;
  final Color color;

  PitchHistoryPainter(this.pitchHistory, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    final double stepX = size.width / (pitchHistory.length - 1);
    for (int i = 0; i < pitchHistory.length; i++) {
      final y = size.height / 2 - (pitchHistory[i] / 50.0) * (size.height / 2);
      if (i == 0) {
        path.moveTo(i * stepX, y);
      } else {
        path.lineTo(i * stepX, y);
      }
    }
    final centerLinePaint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      centerLinePaint,
    );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

enum Instrument { guitar, cello, bass, violin }

extension StringExtension on String {
  String capitalize() {
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}