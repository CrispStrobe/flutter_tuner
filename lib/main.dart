import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:collection/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'audio_service.dart';
import 'tuner_engine.dart';

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

class TunerPage extends StatefulWidget {
  const TunerPage({super.key});

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with WidgetsBindingObserver {
  late final AudioService _audioService;
  late final ToneGeneratorService _toneGenerator;
  final _pitchDetector = PitchDetector();
  final _engine = TunerEngine();

  String _status = 'Start Tuning';
  bool _isListening = false;
  bool _wasListeningBeforePause = false;
  Timer? _silenceTimer;

  bool _isGeneratingTone = false;
  String? _currentlyPlayingNote;

  // Throttle FFT display updates to ~20 fps
  DateTime _lastFftUpdate = DateTime.now();
  static const _fftFrameInterval = Duration(milliseconds: 50);

  static const _prefA4 = 'a4_frequency';
  static const _prefInstrument = 'instrument';

  @override
  void initState() {
    super.initState();
    _audioService = AudioService.create();
    _toneGenerator = ToneGeneratorService.create();
    WidgetsBinding.instance.addObserver(this);
    _audioService.init();
    _toneGenerator.init();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final a4 = prefs.getDouble(_prefA4);
    final instrumentIndex = prefs.getInt(_prefInstrument);
    if (mounted) {
      if (a4 != null) _engine.a4Frequency = a4;
      if (instrumentIndex != null && instrumentIndex < Instrument.values.length) {
        _engine.selectedInstrument = Instrument.values[instrumentIndex];
      }
    }
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefA4, _engine.a4Frequency);
    await prefs.setInt(_prefInstrument, _engine.selectedInstrument.index);
  }

  @override
  void dispose() {
    _stopCapture();
    _toneGenerator.dispose();
    _audioService.dispose();
    _engine.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _silenceTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _wasListeningBeforePause = _isListening;
      _stopCapture();
      _stopToneGenerator();
    } else if (state == AppLifecycleState.resumed && _wasListeningBeforePause) {
      _wasListeningBeforePause = false;
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
    if (await _audioService.hasPermission()) {
      await _audioService.startListening((data) => _processAudioData(data));
      setState(() {
        _isListening = true;
        _status = 'Listening...';
      });
      _resetSilenceTimer();
    } else {
      setState(() => _status = 'Microphone permission denied');
    }
  }

  void _resetSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _isListening) {
        setState(() => _status = 'Listening...');
      }
    });
  }

  void _processAudioData(dynamic data) {
    final floatData = _engine.pcmToFloat(data);
    if (floatData.length < TunerEngine.fftSize) return;

    // Pitch detection (async, fire-and-forget)
    _pitchDetector.getPitchFromFloatBuffer(floatData.toList()).then((result) {
      if (result.pitched && result.probability > 0.9) {
        final smoothed = _engine.smoothPitch(result.pitch);
        // detectNote calls notifyListeners — UI rebuilds via ListenableBuilder
        final detection = _engine.detectNote(smoothed);
        _resetSilenceTimer();
        if (mounted) {
          setState(() => _status = detection.statusText);
        }
      }
    });

    // FFT — throttled to ~20 fps
    final now = DateTime.now();
    if (now.difference(_lastFftUpdate) >= _fftFrameInterval) {
      _lastFftUpdate = now;
      // computeFFT calls notifyListeners — UI rebuilds via ListenableBuilder
      _engine.computeFFT(floatData);
    }
  }

  Future<void> _stopCapture() async {
    await _audioService.stopListening();
    _silenceTimer?.cancel();
    if (mounted) {
      setState(() {
        _isListening = false;
        _status = 'Start Tuning';
      });
      _engine.reset();
    }
  }

  void _toggleToneGenerator(String note) {
    if (_isListening) _stopCapture();
    if (_currentlyPlayingNote == note) {
      _stopToneGenerator();
    } else {
      final frequency = _engine.getFrequencyForNote(note);
      if (frequency != null) {
        _toneGenerator.playNote(frequency);
        setState(() {
          _currentlyPlayingNote = note;
          _isGeneratingTone = true;
          _status = 'Playing ${TunerEngine.stripOctave(note)}';
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
    return ListenableBuilder(
      listenable: _engine,
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final result = _engine.lastResult;
    final displayNote = result?.displayNote ?? '';
    final pitch = result?.pitch ?? 0.0;
    final cents = result?.cents ?? 0.0;
    final note = result?.note ?? '';

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Flutter Pro Tuner', style: TextStyle(fontSize: 18)),
        centerTitle: true,
        backgroundColor: const Color(0x4D000000),
        elevation: 0,
        toolbarHeight: 48,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0A0A0A),
              Color(0xFF1A1A1A),
              Color(0x1AFF5722),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 600;
              final meterWidth = isWide
                  ? constraints.maxWidth * 0.6
                  : constraints.maxWidth * 0.85;

              return SingleChildScrollView(
                padding: EdgeInsets.all(isWide ? 24.0 : 12.0),
                child: isWide
                    ? _buildWideLayout(displayNote, pitch, cents, note, meterWidth, constraints)
                    : _buildNarrowLayout(displayNote, pitch, cents, note, meterWidth),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Phone layout — single column, compact.
  Widget _buildNarrowLayout(
    String displayNote, double pitch, double cents, String note, double meterWidth,
  ) {
    return Column(
      children: [
        _buildNoteDisplay(displayNote),
        const SizedBox(height: 12),
        _buildTuningMeter(meterWidth, cents),
        const SizedBox(height: 4),
        Text('${pitch.toStringAsFixed(2)} Hz',
            style: const TextStyle(fontSize: 14, color: Colors.white60)),
        const SizedBox(height: 12),
        _buildCompactStringIndicators(note),
        const SizedBox(height: 12),
        _buildVisualizationRow(),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildCompactSettings()),
            const SizedBox(width: 12),
            _buildCompactMicButton(),
          ],
        ),
      ],
    );
  }

  /// Tablet / desktop layout — two-column with larger visualizations.
  Widget _buildWideLayout(
    String displayNote, double pitch, double cents, String note,
    double meterWidth, BoxConstraints constraints,
  ) {
    return Column(
      children: [
        _buildNoteDisplay(displayNote, scaleFactor: 1.3),
        const SizedBox(height: 16),
        _buildTuningMeter(meterWidth, cents),
        const SizedBox(height: 4),
        Text('${pitch.toStringAsFixed(2)} Hz',
            style: const TextStyle(fontSize: 16, color: Colors.white60)),
        const SizedBox(height: 16),
        _buildCompactStringIndicators(note),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left: visualizations stacked vertically
            Expanded(
              flex: 3,
              child: Column(
                children: [
                  _buildVisualizationCard(
                    'Pitch History',
                    PitchHistoryPainter(_engine.pitchHistory, Colors.deepOrange),
                    height: 140,
                  ),
                  const SizedBox(height: 12),
                  _buildVisualizationCard(
                    'Frequency Spectrum',
                    FFTPainter(_engine.fftMagnitudes, Colors.greenAccent),
                    height: 140,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 24),
            // Right: settings + mic
            Expanded(
              flex: 2,
              child: Column(
                children: [
                  _buildCompactSettings(),
                  const SizedBox(height: 16),
                  _buildCompactMicButton(),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNoteDisplay(String displayNote, {double scaleFactor = 1.0}) {
    return Semantics(
      liveRegion: true,
      label: displayNote.isEmpty
          ? 'No note detected. $_status'
          : 'Detected note: $displayNote. $_status',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ExcludeSemantics(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: Text(
                displayNote,
                key: ValueKey(displayNote),
                style: TextStyle(
                  fontSize: 72 * scaleFactor,
                  fontWeight: FontWeight.bold,
                  color: _status == 'In Tune ✓' ? Colors.greenAccent : Colors.white,
                  height: 1,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ExcludeSemantics(
            child: Text(_status, style: TextStyle(fontSize: 16 * scaleFactor, color: _getStatusColor())),
          ),
        ],
      ),
    );
  }

  Widget _buildVisualizationRow() {
    return Row(
      children: [
        Expanded(
          child: _buildVisualizationCard(
            'Pitch History',
            PitchHistoryPainter(_engine.pitchHistory, Colors.deepOrange),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildVisualizationCard(
            'Frequency Spectrum',
            FFTPainter(_engine.fftMagnitudes, Colors.greenAccent),
          ),
        ),
      ],
    );
  }

  Widget _buildVisualizationCard(String label, CustomPainter painter, {double height = 100}) {
    return Semantics(
      label: '$label visualization',
      excludeSemantics: true,
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 4),
          Container(
            height: height,
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox.expand(
                child: CustomPaint(painter: painter),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor() {
    if (_status == 'In Tune ✓') return Colors.greenAccent;
    if (_status == 'Start Tuning' || _status == 'Listening...') return Colors.white70;
    if (_isGeneratingTone) return Colors.cyanAccent;
    return Colors.orangeAccent;
  }

  Widget _buildTuningMeter(double width, double cents) {
    final clampedCents = cents.clamp(-50.0, 50.0);
    final meterPosition = clampedCents / 50.0;
    final leftMargin = meterPosition > 0 ? meterPosition * (width / 2 - 20) : 0.0;
    final rightMargin = meterPosition < 0 ? -meterPosition * (width / 2 - 20) : 0.0;
    final statusColor = _getStatusColor();

    return Semantics(
      label: 'Tuning meter: ${clampedCents.toStringAsFixed(0)} cents',
      value: '${(meterPosition * 100).toStringAsFixed(0)}%',
      child: Container(
      width: width,
      height: 40,
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
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
              color: statusColor,
              borderRadius: BorderRadius.circular(3),
              boxShadow: [
                BoxShadow(
                  color: Color.lerp(statusColor, Colors.transparent, 0.4)!,
                  blurRadius: 15,
                  spreadRadius: 3,
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildCompactStringIndicators(String currentNote) {
    final strings = _engine.currentTuningStrings;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: strings.map((stringNote) {
        final bool isCurrentNote = currentNote == stringNote;
        final bool isInTune = isCurrentNote && _status == 'In Tune ✓';
        final bool isPlayingThisTone = _currentlyPlayingNote == stringNote;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x0DFFFFFF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isCurrentNote ? Colors.deepOrange : Colors.white12,
                  width: 2,
                ),
              ),
              child: Text(
                TunerEngine.stripOctave(stringNote),
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
                    ? [BoxShadow(color: Color.lerp(Colors.greenAccent, Colors.transparent, 0.2)!, blurRadius: 8, spreadRadius: 2)]
                    : [],
              ),
            ),
            Semantics(
              button: true,
              label: isPlayingThisTone
                  ? 'Stop playing ${TunerEngine.stripOctave(stringNote)}'
                  : 'Play reference tone ${TunerEngine.stripOctave(stringNote)}',
              child: IconButton(
                icon: Icon(isPlayingThisTone ? Icons.stop_circle : Icons.play_circle_outline, size: 24),
                color: isPlayingThisTone ? Colors.cyanAccent : Colors.white70,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _toggleToneGenerator(stringNote),
              ),
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
        color: const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: 'A4 reference frequency',
            value: '${_engine.a4Frequency.toStringAsFixed(1)} Hz',
            child: Text('A4: ${_engine.a4Frequency.toStringAsFixed(1)} Hz',
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          SliderTheme(
            data: const SliderThemeData(
              activeTrackColor: Colors.deepOrange,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.deepOrange,
              overlayColor: Color(0x33FF5722),
              trackHeight: 2,
            ),
            child: Slider(
              value: _engine.a4Frequency,
              min: 415,
              max: 465,
              divisions: 500,
              onChanged: isActionDisabled
                  ? null
                  : (value) {
                      _engine.a4Frequency = value;
                      _savePreferences();
                    },
            ),
          ),
          DropdownButtonFormField<Instrument>(
            value: _engine.selectedInstrument,
            isDense: true,
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0x0DFFFFFF),
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
                      _engine.selectedInstrument = newValue;
                      _savePreferences();
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
            color: Color.lerp(_isListening ? Colors.redAccent : Colors.greenAccent, Colors.transparent, 0.6)!,
            blurRadius: 15,
            spreadRadius: 3,
          ),
        ],
      ),
      child: Semantics(
        button: true,
        label: _isListening ? 'Stop tuning' : 'Start tuning',
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

    final int barCount = fftData.length;
    if (barCount <= 0) return;
    final double barWidth = size.width / barCount;
    final double maxMagnitude = fftData.reduce(math.max);

    if (maxMagnitude <= 0 || maxMagnitude.isNaN || maxMagnitude.isInfinite) {
      return;
    }

    for (int i = 0; i < barCount; i++) {
      final double magnitude = fftData[i];
      final double barHeight = (magnitude / maxMagnitude) * size.height;

      if (barHeight.isNaN || barHeight.isInfinite || barHeight < 0) {
        continue;
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
  bool shouldRepaint(covariant FFTPainter oldDelegate) =>
      !const ListEquality<double>().equals(fftData, oldDelegate.fftData);
}

class PitchHistoryPainter extends CustomPainter {
  final List<double> pitchHistory;
  final Color color;

  PitchHistoryPainter(this.pitchHistory, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (pitchHistory.length < 2) return;
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
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      centerLinePaint,
    );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant PitchHistoryPainter oldDelegate) =>
      !const ListEquality<double>().equals(pitchHistory, oldDelegate.pitchHistory);
}
