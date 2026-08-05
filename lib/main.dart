import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:collection/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'about_screen.dart';
import 'audio_service.dart';
import 'l10n/app_localizations.dart';
import 'tuner_engine.dart';

void main() {
  // Adds CrispTuner's own MIT licence and the YIN citation to the registry;
  // pub packages register themselves, but the app would otherwise be absent
  // from its own licence page.
  registerAppLicenses();
  runApp(const TunerApp());
}

/// What the status line is currently reporting.
///
/// Held as an enum rather than a display string so that comparisons stay
/// correct in every locale — the UI previously tested `_status == 'In Tune ✓'`,
/// which silently stops matching the moment the text is translated.
enum TunerStatus { idle, listening, inTune, sharp, flat, playing, permissionDenied }

class TunerApp extends StatelessWidget {
  const TunerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      // The debug banner paints only under an assert, so release builds never
      // showed it — but simulator builds are debug-only and App Store
      // screenshots must not carry it.
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // `supportedLocales` is generated in alphabetical order, so 'de' sits
      // first and Flutter's default resolution would hand an unsupported
      // locale (fr, ja, …) a German UI. English is the template locale.
      localeResolutionCallback: (locale, supported) {
        if (locale != null) {
          for (final candidate in supported) {
            if (candidate.languageCode == locale.languageCode) return candidate;
          }
        }
        return const Locale('en');
      },
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

  TunerStatus _status = TunerStatus.idle;
  bool _isListening = false;
  bool _wasListeningBeforePause = false;
  Timer? _silenceTimer;

  bool _isGeneratingTone = false;
  String? _currentlyPlayingNote;

  // Input device selection
  List<AudioInputDevice> _inputDevices = [];
  String? _selectedDeviceId;

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
    _audioService.init().then((_) => _refreshInputDevices());
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

  Future<void> _refreshInputDevices() async {
    final devices = await _audioService.listInputDevices();
    if (mounted) {
      setState(() {
        _inputDevices = devices;
        // Keep selection if device still exists, otherwise reset
        if (_selectedDeviceId != null &&
            !devices.any((d) => d.id == _selectedDeviceId)) {
          _selectedDeviceId = null;
        }
      });
    }
  }

  Future<void> _startCapture() async {
    if (!await _audioService.hasPermission()) {
      if (mounted) setState(() => _status = TunerStatus.permissionDenied);
      return;
    }
    try {
      // Refresh device list (labels become available after permission)
      await _refreshInputDevices();
      await _audioService.startListening(
        (data) => _processAudioData(data),
        deviceId: _selectedDeviceId,
      );
    } catch (_) {
      // Capture can fail if the chosen device vanished or is held by another
      // app. Report it as unavailable rather than leaving a stuck "Listening".
      if (mounted) setState(() => _status = TunerStatus.permissionDenied);
      return;
    }
    if (!mounted) return;
    setState(() {
      _isListening = true;
      _status = TunerStatus.listening;
    });
    _resetSilenceTimer();
  }

  void _resetSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _isListening) {
        setState(() => _status = TunerStatus.listening);
      }
    });
  }

  void _processAudioData(Uint8List data) {
    final floatData = _engine.pcmToFloat(data);
    if (floatData.length < TunerEngine.fftSize) return;

    // Pitch detection (async, fire-and-forget). Float64List already implements
    // List<double>, so no copy is needed here — this runs per audio callback.
    _pitchDetector.getPitchFromFloatBuffer(floatData).then((result) {
      if (result.pitched && result.probability > 0.9) {
        final smoothed = _engine.smoothPitch(result.pitch);
        // detectNote calls notifyListeners — UI rebuilds via ListenableBuilder
        final detection = _engine.detectNote(smoothed);
        _resetSilenceTimer();
        if (mounted) {
          setState(() => _status = _statusFromTuning(detection.status));
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
        _status = TunerStatus.idle;
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
          _status = TunerStatus.playing;
        });
      }
    }
  }

  void _stopToneGenerator() {
    _toneGenerator.stopNote();
    setState(() {
      _currentlyPlayingNote = null;
      _isGeneratingTone = false;
      _status = TunerStatus.idle;
    });
  }

  static TunerStatus _statusFromTuning(TuningStatus status) {
    switch (status) {
      case TuningStatus.inTune:
        return TunerStatus.inTune;
      case TuningStatus.sharp:
        return TunerStatus.sharp;
      case TuningStatus.flat:
        return TunerStatus.flat;
      case TuningStatus.idle:
        return TunerStatus.listening;
    }
  }

  /// The localized text for the current [_status].
  String _statusText(AppLocalizations l10n) {
    switch (_status) {
      case TunerStatus.idle:
        return l10n.startTuning;
      case TunerStatus.listening:
        return l10n.listening;
      case TunerStatus.inTune:
        return l10n.inTune;
      case TunerStatus.sharp:
        return l10n.tooSharp;
      case TunerStatus.flat:
        return l10n.tooFlat;
      case TunerStatus.playing:
        return l10n.playing(
            TunerEngine.stripOctave(_currentlyPlayingNote ?? ''));
      case TunerStatus.permissionDenied:
        return l10n.micPermissionDenied;
    }
  }

  static String _instrumentName(AppLocalizations l10n, Instrument instrument) {
    switch (instrument) {
      case Instrument.guitar:
        return l10n.instrumentGuitar;
      case Instrument.cello:
        return l10n.instrumentCello;
      case Instrument.bass:
        return l10n.instrumentBass;
      case Instrument.violin:
        return l10n.instrumentViolin;
      case Instrument.ukulele:
        return l10n.instrumentUkulele;
      case Instrument.mandolin:
        return l10n.instrumentMandolin;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _engine,
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final result = _engine.lastResult;
    final displayNote = result?.displayNote ?? '';
    final pitch = result?.pitch ?? 0.0;
    final cents = result?.cents ?? 0.0;
    final note = result?.note ?? '';

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.appTitle, style: const TextStyle(fontSize: 18)),
        centerTitle: true,
        backgroundColor: const Color(0x4D000000),
        elevation: 0,
        toolbarHeight: 48,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, size: 20),
            tooltip: l10n.about,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
            ),
          ),
        ],
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
                    ? _buildWideLayout(l10n, displayNote, pitch, cents, note, meterWidth)
                    : _buildNarrowLayout(l10n, displayNote, pitch, cents, note, meterWidth),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Phone layout — single column, compact.
  Widget _buildNarrowLayout(
    AppLocalizations l10n,
    String displayNote, double pitch, double cents, String note, double meterWidth,
  ) {
    return Column(
      children: [
        _buildNoteDisplay(l10n, displayNote),
        const SizedBox(height: 12),
        _buildTuningMeter(l10n, meterWidth, cents),
        const SizedBox(height: 4),
        Text(l10n.hertzValue(pitch.toStringAsFixed(2)),
            style: const TextStyle(fontSize: 14, color: Colors.white60)),
        const SizedBox(height: 12),
        _buildCompactStringIndicators(l10n, note),
        const SizedBox(height: 12),
        _buildVisualizationRow(l10n),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildCompactSettings(l10n)),
            const SizedBox(width: 12),
            _buildCompactMicButton(l10n),
          ],
        ),
      ],
    );
  }

  /// Tablet / desktop layout — two-column with larger visualizations.
  Widget _buildWideLayout(
    AppLocalizations l10n,
    String displayNote, double pitch, double cents, String note,
    double meterWidth,
  ) {
    return Column(
      children: [
        _buildNoteDisplay(l10n, displayNote, scaleFactor: 1.3),
        const SizedBox(height: 16),
        _buildTuningMeter(l10n, meterWidth, cents),
        const SizedBox(height: 4),
        Text(l10n.hertzValue(pitch.toStringAsFixed(2)),
            style: const TextStyle(fontSize: 16, color: Colors.white60)),
        const SizedBox(height: 16),
        _buildCompactStringIndicators(l10n, note),
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
                    l10n.pitchHistory,
                    PitchHistoryPainter(_engine.pitchHistory, Colors.deepOrange),
                    l10n,
                    height: 140,
                  ),
                  const SizedBox(height: 12),
                  _buildVisualizationCard(
                    l10n.frequencySpectrum,
                    FFTPainter(_engine.fftMagnitudes, Colors.greenAccent),
                    l10n,
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
                  _buildCompactSettings(l10n),
                  const SizedBox(height: 16),
                  _buildCompactMicButton(l10n),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNoteDisplay(AppLocalizations l10n, String displayNote,
      {double scaleFactor = 1.0}) {
    final statusText = _statusText(l10n);
    return Semantics(
      liveRegion: true,
      label: displayNote.isEmpty
          ? l10n.noNoteDetected(statusText)
          : l10n.detectedNote(displayNote, statusText),
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
                  color: _status == TunerStatus.inTune
                      ? Colors.greenAccent
                      : Colors.white,
                  height: 1,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ExcludeSemantics(
            child: Text(statusText,
                style: TextStyle(
                    fontSize: 16 * scaleFactor, color: _getStatusColor())),
          ),
        ],
      ),
    );
  }

  Widget _buildVisualizationRow(AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(
          child: _buildVisualizationCard(
            l10n.pitchHistory,
            PitchHistoryPainter(_engine.pitchHistory, Colors.deepOrange),
            l10n,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildVisualizationCard(
            l10n.frequencySpectrum,
            FFTPainter(_engine.fftMagnitudes, Colors.greenAccent),
            l10n,
          ),
        ),
      ],
    );
  }

  Widget _buildVisualizationCard(
      String label, CustomPainter painter, AppLocalizations l10n,
      {double height = 100}) {
    return Semantics(
      label: l10n.visualizationLabel(label),
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
    switch (_status) {
      case TunerStatus.inTune:
        return Colors.greenAccent;
      case TunerStatus.idle:
      case TunerStatus.listening:
        return Colors.white70;
      case TunerStatus.playing:
        return Colors.cyanAccent;
      case TunerStatus.sharp:
      case TunerStatus.flat:
      case TunerStatus.permissionDenied:
        return Colors.orangeAccent;
    }
  }

  Widget _buildTuningMeter(AppLocalizations l10n, double width, double cents) {
    final clampedCents = cents.clamp(-50.0, 50.0);
    final meterPosition = clampedCents / 50.0;
    final leftMargin = meterPosition > 0 ? meterPosition * (width / 2 - 20) : 0.0;
    final rightMargin = meterPosition < 0 ? -meterPosition * (width / 2 - 20) : 0.0;
    final statusColor = _getStatusColor();

    return Semantics(
      label: l10n.tuningMeterLabel(clampedCents.toStringAsFixed(0)),
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

  Widget _buildCompactStringIndicators(
      AppLocalizations l10n, String currentNote) {
    final strings = _engine.currentTuningStrings;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: strings.map((stringNote) {
        final bool isCurrentNote = currentNote == stringNote;
        final bool isInTune = isCurrentNote && _status == TunerStatus.inTune;
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
                  ? l10n.stopReferenceTone(TunerEngine.stripOctave(stringNote))
                  : l10n.playReferenceTone(TunerEngine.stripOctave(stringNote)),
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

  Widget _buildCompactSettings(AppLocalizations l10n) {
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
            label: l10n.a4ReferenceFrequency,
            value: l10n.hertzValue(_engine.a4Frequency.toStringAsFixed(1)),
            child: Text(l10n.a4Label(_engine.a4Frequency.toStringAsFixed(1)),
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
            initialValue: _engine.selectedInstrument,
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
                child: Text(_instrumentName(l10n, value),
                    style: const TextStyle(fontSize: 14)),
              );
            }).toList(),
          ),
          if (_inputDevices.length > 1) ...[
            const SizedBox(height: 8),
            Semantics(
              label: l10n.selectMicrophone,
              child: DropdownButtonFormField<String?>(
                initialValue: _selectedDeviceId,
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
                  prefixIcon: const Icon(Icons.mic, size: 16, color: Colors.white38),
                  prefixIconConstraints: const BoxConstraints(minWidth: 28),
                ),
                dropdownColor: const Color(0xFF1A1A1A),
                isExpanded: true,
                onChanged: isActionDisabled
                    ? null
                    : (String? deviceId) {
                        setState(() => _selectedDeviceId = deviceId);
                      },
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(l10n.defaultMicrophone,
                        style: const TextStyle(fontSize: 12)),
                  ),
                  ..._inputDevices.map((d) => DropdownMenuItem<String?>(
                        value: d.id,
                        child: Text(
                          d.label,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompactMicButton(AppLocalizations l10n) {
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
        label: _isListening ? l10n.stopTuningButton : l10n.startTuningButton,
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
