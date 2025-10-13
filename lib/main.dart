import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:fftea/fftea.dart';
import 'package:collection/collection.dart';
import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
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
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        useMaterial3: true,
      ),
      home: const TunerPage(),
    );
  }
}

// Tone Generator Class
class ToneGenerator {
  Synthesizer? _synth;
  bool _isInitialized = false;
  bool _isPlaying = false;
  int _currentNote = -1;

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
    
    if (!_isPlaying) {
      _isPlaying = true;
      FlutterPcmSound.setFeedCallback(_onFeed);
      _startFeeding();
    }
  }

  void _startFeeding() {
    _onFeed(0);
  }

  void _onFeed(int remainingFrames) async {
    if (!_isPlaying || _currentNote < 0) return;

    final frequency = 440.0 * math.pow(2, (_currentNote - 69) / 12.0);
    final samples = _generateSineWave(frequency, 2000);
    
    await FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
  }

  List<int> _generateSineWave(double frequency, int numSamples) {
    final samples = <int>[];
    const sampleRate = 44100;
    const amplitude = 8000;
    
    for (int i = 0; i < numSamples; i++) {
      final time = i / sampleRate;
      final value = (amplitude * math.sin(2 * math.pi * frequency * time)).toInt();
      samples.add(value);
    }
    
    return samples;
  }

  void stopNote() {
    _isPlaying = false;
    _currentNote = -1;
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
    if (_isGeneratingTone) {
      _stopToneGenerator();
    }
    
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

      _audioSubscription = stream.listen((data) {
        _processAudioData(data);
      });

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
      setState(() => _status = "Microphone permission denied");
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
    } catch (e) {
      // Ignore pitch detection errors
    }

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
        _status = "Start Tuning";
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

    final centsDifference =
        1200 * (math.log(detectedPitch / targetFrequency) / math.log(2));

    if (_pitchHistory.length >= 100) {
      _pitchHistory.removeFirst();
    }
    _pitchHistory.add(centsDifference.clamp(-50, 50));

    setState(() {
      _pitch = detectedPitch;
      _note = closestNote;
      _cents = centsDifference;
      if (centsDifference.abs() < 5) {
        _status = "In Tune";
      } else if (centsDifference > 5) {
        _status = "Too Sharp";
      } else {
        _status = "Too Flat";
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
    if (_isListening) {
      _stopCapture();
    }

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Pro Tuner'),
        centerTitle: true,
        backgroundColor: Colors.black,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                _note.replaceAll(RegExp(r'[0-9]'), ''),
                style: TextStyle(
                    fontSize: 120,
                    fontWeight: FontWeight.bold,
                    color: _status == "In Tune"
                        ? Colors.greenAccent
                        : Colors.white),
              ),
              const SizedBox(height: 10),
              Text(
                _status,
                style: TextStyle(
                    fontSize: 24,
                    color: _status == "In Tune"
                        ? Colors.greenAccent
                        : _status == "Start Tuning" || _status == "Listening..."
                            ? Colors.white
                            : _isGeneratingTone
                                ? Colors.cyanAccent
                                : Colors.orangeAccent),
              ),
              const SizedBox(height: 20),
              _buildTuningMeter(),
              const SizedBox(height: 10),
              Text('${_pitch.toStringAsFixed(2)} Hz',
                  style: const TextStyle(fontSize: 18, color: Colors.white70)),
              const SizedBox(height: 30),
              _buildStringIndicators(),
              const SizedBox(height: 30),
              const Text("Pitch History",
                  style: TextStyle(color: Colors.white70)),
              SizedBox(
                height: 100,
                width: double.infinity,
                child: CustomPaint(
                  painter: PitchHistoryPainter(
                      _pitchHistory.toList(), Colors.deepOrange),
                ),
              ),
              const SizedBox(height: 30),
              const Text("Frequency Spectrum",
                  style: TextStyle(color: Colors.white70)),
              SizedBox(
                height: 100,
                width: double.infinity,
                child: CustomPaint(
                  painter: FFTPainter(_fftData, Colors.greenAccent),
                ),
              ),
              const SizedBox(height: 30),
              _buildSettings(),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _toggleListening,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _isListening
                        ? Colors.redAccent
                        : Colors.greenAccent,
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(30)),
                child: Icon(_isListening ? Icons.mic_off : Icons.mic,
                    size: 40, color: Colors.black),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTuningMeter() {
    final clampedCents = _cents.clamp(-50.0, 50.0);
    final meterPosition = clampedCents / 50.0;
    
    final double leftMargin = meterPosition > 0 ? meterPosition * 140 : 0;
    final double rightMargin = meterPosition < 0 ? -meterPosition * 140 : 0;
    
    return Container(
      width: 300,
      height: 40,
      decoration: BoxDecoration(
          border: Border.all(color: Colors.white54, width: 2),
          borderRadius: BorderRadius.circular(20)),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
              width: 3, height: 40, color: Colors.greenAccent.withOpacity(0.8)),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: EdgeInsets.only(left: leftMargin, right: rightMargin),
            width: 5,
            height: 40,
            decoration: BoxDecoration(
              color: _status == "In Tune"
                  ? Colors.greenAccent
                  : Colors.orangeAccent,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                    color: (_status == "In Tune"
                            ? Colors.greenAccent
                            : Colors.orangeAccent)
                        .withOpacity(0.5),
                    blurRadius: 10,
                    spreadRadius: 2)
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStringIndicators() {
    List<String> strings = _instrumentTunings[_selectedInstrument]!;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: strings.map((stringNote) {
        final bool isCurrentNote = _note == stringNote;
        final bool isInTune = isCurrentNote && _status == "In Tune";
        final bool isPlayingThisTone = _currentlyPlayingNote == stringNote;
        
        return Column(
          children: [
            Text(stringNote.replaceAll(RegExp(r'[0-9]'), ''),
                style: const TextStyle(fontSize: 24, color: Colors.white)),
            const SizedBox(height: 5),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isInTune
                    ? Colors.greenAccent
                    : (isCurrentNote ? Colors.orangeAccent : Colors.grey[800]),
                boxShadow: isInTune
                    ? [
                        BoxShadow(
                            color: Colors.greenAccent.withOpacity(0.7),
                            blurRadius: 10,
                            spreadRadius: 2)
                      ]
                    : [],
              ),
            ),
            IconButton(
              icon: Icon(isPlayingThisTone
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline),
              color: isPlayingThisTone ? Colors.cyanAccent : Colors.white,
              iconSize: 30,
              onPressed: () => _toggleToneGenerator(stringNote),
            ),
          ],
        );
      }).toList(),
    );
  }

  Widget _buildSettings() {
    final bool isActionDisabled = _isListening || _isGeneratingTone;
    return Column(
      children: [
        Text("A4 Frequency: ${_a4Frequency.toStringAsFixed(1)} Hz",
            style: const TextStyle(color: Colors.white)),
        Slider(
          value: _a4Frequency,
          min: 415,
          max: 465,
          divisions: 500,
          label: _a4Frequency.toStringAsFixed(1),
          onChanged: isActionDisabled
              ? null
              : (value) {
                  setState(() {
                    _a4Frequency = value;
                    _recalculatePitches();
                  });
                },
          activeColor: Colors.deepOrange,
          inactiveColor: isActionDisabled ? Colors.grey[800] : Colors.grey,
        ),
        DropdownButton<Instrument>(
          value: _selectedInstrument,
          dropdownColor: Colors.grey[850],
          onChanged: isActionDisabled
              ? null
              : (Instrument? newValue) {
                  if (newValue != null) {
                    setState(() => _selectedInstrument = newValue);
                  }
                },
          items: Instrument.values
              .map<DropdownMenuItem<Instrument>>((Instrument value) {
            return DropdownMenuItem<Instrument>(
              value: value,
              child: Text(value.toString().split('.').last.capitalize(),
                  style: const TextStyle(fontSize: 18)),
            );
          }).toList(),
        ),
      ],
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

    final paint = Paint()..color = color;
    final double barWidth = size.width / (fftData.length / 8);
    final double maxMagnitude =
        fftData.sublist(0, fftData.length ~/ 2).reduce(math.max);

    for (int i = 0; i < fftData.length / 8; i++) {
      final double magnitude = fftData[i];
      final double barHeight = (magnitude / maxMagnitude) * size.height;
      canvas.drawRect(
        Rect.fromLTWH(
            i * barWidth, size.height - barHeight, barWidth * 0.8, barHeight),
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
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    final double stepX = size.width / (pitchHistory.length - 1);

    for (int i = 0; i < pitchHistory.length; i++) {
      final y =
          size.height / 2 - (pitchHistory[i] / 50.0) * (size.height / 2);
      if (i == 0) {
        path.moveTo(i * stepX, y);
      } else {
        path.lineTo(i * stepX, y);
      }
    }

    final centerLinePaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..strokeWidth = 1.0;
    canvas.drawLine(
        Offset(0, size.height / 2), Offset(size.width, size.height / 2),
        centerLinePaint);

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