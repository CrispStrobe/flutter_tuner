import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'about_screen.dart';
import 'audio_service.dart';
import 'audio_service_stub.dart' as audio;
import 'l10n/app_localizations.dart';
import 'theme.dart';
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
  /// Audio capture and tone output. Left null in the shipping app, which
  /// creates the platform implementations; supplied by tests and by the
  /// store-screenshot renderer, which feed synthesised audio through the real
  /// detection pipeline instead of a microphone.
  final audio.AudioService? audioService;
  final audio.ToneGeneratorService? toneGenerator;

  const TunerApp({super.key, this.audioService, this.toneGenerator});

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
      theme: TunerPalette.light.themeData,
      darkTheme: TunerPalette.dark.themeData,
      themeMode: ThemeMode.system,
      home: TunerPage(
        audioService: audioService,
        toneGenerator: toneGenerator,
      ),
    );
  }
}

class TunerPage extends StatefulWidget {
  final audio.AudioService? audioService;
  final audio.ToneGeneratorService? toneGenerator;

  const TunerPage({super.key, this.audioService, this.toneGenerator});

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with WidgetsBindingObserver {
  late final audio.AudioService _audioService;
  late final audio.ToneGeneratorService _toneGenerator;
  // The window must match what the rolling buffer feeds it, or the lag
  // search is sized for audio it never sees. Rebuilt whenever the detector
  // setting changes — each engine carries its own scratch buffers and FFT
  // plan, so switching means a new one rather than a flag.
  PitchEngine _pitchEngine = PitchEngine.of(
    DetectorKind.yin,
    sampleRate: 44100,
    windowSize: pitchWindowSize,
  );
  final _pitchWindow = RollingWindow(pitchWindowSize);

  /// How much new audio to wait for between analyses. 1024 samples is 23 ms
  /// at 44.1 kHz — 43 readings a second.
  static const int analysisHopSamples = 1024;
  int _samplesSinceAnalysis = 0;
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
  static const _prefInstrumentName = 'instrument_name';
  static const _prefTuning = 'tuning_id';
  static const _prefCustomStrings = 'custom_strings';
  static const _prefTemperament = 'temperament';
  static const _prefTemperamentRoot = 'temperament_root';
  static const _prefDetector = 'detector';

  /// Pre-2.2 builds stored the instrument as an index into the enum, under a
  /// key that now holds a string. Two things follow, and skipping either one
  /// breaks the app for everyone upgrading rather than installing fresh:
  /// the old value has to be read with [SharedPreferences.getInt] (asking for
  /// a String throws on a stored int), and the index has to be resolved
  /// against the enum *as it was then*, not as it is now.
  static const _prefLegacyInstrumentIndex = 'instrument';
  static const List<Instrument> _legacyInstrumentOrder = [
    Instrument.guitar,
    Instrument.cello,
    Instrument.bass,
    Instrument.violin,
    Instrument.ukulele,
    Instrument.mandolin,
  ];

  @override
  void initState() {
    super.initState();
    _audioService = widget.audioService ?? AudioService.create();
    _toneGenerator = widget.toneGenerator ?? ToneGeneratorService.create();
    WidgetsBinding.instance.addObserver(this);
    _audioService.init().then((_) => _refreshInputDevices());
    _toneGenerator.init();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final a4 = prefs.getDouble(_prefA4);
    if (a4 != null) _engine.a4Frequency = a4;

    // Instruments and tunings are persisted by name, not by index: an index
    // silently means a different instrument the moment the enum gains a
    // member, which it just did.
    final instrumentName = prefs.getString(_prefInstrumentName);
    final instrument =
        Instrument.values.firstWhereOrNull((v) => v.name == instrumentName) ??
            _migrateLegacyInstrument(prefs);
    if (instrument != null) _engine.selectedInstrument = instrument;

    final customStrings = prefs.getStringList(_prefCustomStrings);
    if (customStrings != null && customStrings.isNotEmpty) {
      _engine.customStrings = customStrings;
    }

    final tuningId = prefs.getString(_prefTuning);
    if (tuningId != null) {
      final valid = tuningId == customTuningId ||
          tuningsFor(_engine.selectedInstrument).any((t) => t.id == tuningId);
      if (valid) _engine.tuningId = tuningId;
    }

    final temperamentName = prefs.getString(_prefTemperament);
    final temperament = Temperament.values
        .firstWhereOrNull((value) => value.name == temperamentName);
    if (temperament != null) _engine.temperament = temperament;

    final detectorName = prefs.getString(_prefDetector);
    final detector =
        DetectorKind.values.firstWhereOrNull((d) => d.name == detectorName);
    if (detector != null) _selectDetector(detector);

    final root = prefs.getInt(_prefTemperamentRoot);
    if (root != null) _engine.temperamentRoot = root;
  }

  /// Read the pre-2.2 integer instrument preference, if one is there.
  static Instrument? _migrateLegacyInstrument(SharedPreferences prefs) {
    int? index;
    try {
      index = prefs.getInt(_prefLegacyInstrumentIndex);
    } catch (_) {
      // Already migrated on a previous launch, or written by a build that
      // used a different type. Either way there is nothing to recover.
      return null;
    }
    if (index == null || index < 0 || index >= _legacyInstrumentOrder.length) {
      return null;
    }
    return _legacyInstrumentOrder[index];
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefA4, _engine.a4Frequency);
    await prefs.setString(
        _prefInstrumentName, _engine.selectedInstrument.name);
    // Drop the pre-2.2 integer key once the new one is written, so the
    // migration path is walked at most once per install.
    await prefs.remove(_prefLegacyInstrumentIndex);
    await prefs.setString(_prefTuning, _engine.tuningId);
    await prefs.setStringList(_prefCustomStrings, _engine.customStrings);
    await prefs.setString(_prefTemperament, _engine.temperament.name);
    await prefs.setInt(_prefTemperamentRoot, _engine.temperamentRoot);
    await prefs.setString(_prefDetector, _engine.detectorKind.name);
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

  /// Switch detector, rebuilding the engine that carries the scratch
  /// buffers. Cheap, and never on the audio path: this runs from settings.
  void _selectDetector(DetectorKind kind) {
    if (_engine.detectorKind == kind) return;
    _engine.detectorKind = kind;
    _pitchEngine = PitchEngine.of(
      kind,
      sampleRate: 44100,
      windowSize: pitchWindowSize,
    );
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
    // Accumulate rather than analysing the callback's own buffer: the chunk
    // size is the platform's choice, and anything smaller than the analysis
    // window used to be dropped on the floor entirely.
    final samples = _engine.pcmToFloat(data);
    _pitchWindow.add(samples);
    if (!_pitchWindow.isFull) return;

    // Analyse at a bounded rate rather than once per callback.
    //
    // The callback size is the platform's choice and on the web it is not a
    // choice at all: an AudioWorklet is handed 128 samples per render quantum
    // by the Web Audio spec, so this ran a full 4096-sample analysis ~345
    // times a second. Consecutive analyses that far apart share 97% of their
    // samples — they are very nearly the same number, recomputed. Measured in
    // dart2js at the time, that was 1765% of a core for the detector alone,
    // which a browser cannot do, so the readings queued and the needle lagged.
    //
    // Nothing is lost by declining: the reading's content is dominated by a
    // 93 ms window, so its latency floor is the window, not the hop
    // (bench/REPORT.md §9). A 1024-sample hop gives 43 readings a second,
    // which is more than a needle can usefully show.
    _samplesSinceAnalysis += samples.length;
    if (_samplesSinceAnalysis < analysisHopSamples) return;
    _samplesSinceAnalysis = 0;

    // Pitch detection. This used to be a fire-and-forget Future because the
    // package's API was asynchronous; the work was always synchronous, and
    // by FFT it now costs a fraction of one callback (bench/REPORT.md §3.3),
    // so there is nothing left to defer.
    final result = _pitchEngine.analyse(_pitchWindow.lastN(pitchWindowSize));
    // The gate and the median live together in the engine: a rejected frame
    // has to clear the smoothing window, or the window goes on averaging
    // over pitches from before the gap.
    final smoothed = _engine.acceptFrame(
      pitched: result.pitched,
      probability: result.probability,
      pitch: result.frequency,
    );
    if (smoothed != null) {
      final detection = _engine.detectNote(smoothed);
      _resetSilenceTimer();
      if (mounted) {
        setState(() => _status = _statusFromTuning(detection.status));
      }
    }

    // FFT — throttled to ~20 fps, over the most recent 2048 samples.
    final now = DateTime.now();
    if (now.difference(_lastFftUpdate) >= _fftFrameInterval) {
      _lastFftUpdate = now;
      _engine.computeFFT(_pitchWindow.lastN(TunerEngine.fftSize));
    }
  }

  Future<void> _stopCapture() async {
    await _audioService.stopListening();
    _pitchWindow.clear();
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

  static String instrumentName(AppLocalizations l10n, Instrument instrument) {
    switch (instrument) {
      case Instrument.guitar:
        return l10n.instrumentGuitar;
      case Instrument.guitar7:
        return l10n.instrumentGuitar7;
      case Instrument.bass:
        return l10n.instrumentBass;
      case Instrument.bass5:
        return l10n.instrumentBass5;
      case Instrument.ukulele:
        return l10n.instrumentUkulele;
      case Instrument.banjo:
        return l10n.instrumentBanjo;
      case Instrument.mandolin:
        return l10n.instrumentMandolin;
      case Instrument.violin:
        return l10n.instrumentViolin;
      case Instrument.viola:
        return l10n.instrumentViola;
      case Instrument.cello:
        return l10n.instrumentCello;
      case Instrument.doubleBass:
        return l10n.instrumentDoubleBass;
    }
  }

  /// Display name for a tuning id.
  ///
  /// Names like "DADGAD" and "Drop D" are the terms players actually use in
  /// every language, so they are deliberately not translated; the descriptive
  /// ones are.
  static String tuningName(AppLocalizations l10n, String id) {
    switch (id) {
      case 'standard':
        return l10n.tuningStandard;
      case 'halfStepDown':
        return l10n.tuningHalfStepDown;
      case 'wholeStepDown':
        return l10n.tuningWholeStepDown;
      case 'lowG':
        return l10n.tuningLowG;
      case 'baritone':
        return l10n.tuningBaritone;
      case 'dTuning':
        return l10n.tuningDTuning;
      case 'solo':
        return l10n.tuningSolo;
      case 'tenor':
        return l10n.tuningTenor;
      case 'octave':
        return l10n.tuningOctave;
      case 'crossAEAE':
        return l10n.tuningCrossAEAE;
      case customTuningId:
        return l10n.tuningCustom;
      case 'dropD':
        return 'Drop D';
      case 'dropC':
        return 'Drop C';
      case 'dropA':
        return 'Drop A';
      case 'dadgad':
        return 'DADGAD';
      case 'openG':
        return 'Open G';
      case 'openD':
        return 'Open D';
      case 'openE':
        return 'Open E';
      case 'openC':
        return 'Open C';
      case 'doubleC':
        return 'Double C';
      default:
        return id;
    }
  }

  static String temperamentName(AppLocalizations l10n, Temperament t) {
    switch (t) {
      case Temperament.equal:
        return l10n.temperamentEqual;
      case Temperament.pythagorean:
        return l10n.temperamentPythagorean;
      case Temperament.quarterCommaMeantone:
        return l10n.temperamentMeantone;
      case Temperament.werckmeisterIII:
        return l10n.temperamentWerckmeister;
      case Temperament.kirnbergerIII:
        return l10n.temperamentKirnberger;
      case Temperament.vallotti:
        return l10n.temperamentVallotti;
    }
  }

  static String detectorName(AppLocalizations l10n, DetectorKind kind) {
    switch (kind) {
      case DetectorKind.yin:
        return l10n.detectorYin;
      case DetectorKind.mpm:
        return l10n.detectorMpm;
    }
  }

  static const List<String> pitchClassNames = [
    'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _engine,
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = TunerPalette.of(context);
    final result = _engine.lastResult;
    final displayNote = result?.displayNote ?? '';
    final pitch = result?.pitch ?? 0.0;
    final cents = result?.cents ?? 0.0;
    final note = result?.note ?? '';

    return Scaffold(
      // Not transparent: nothing paints behind the app bar, so a transparent
      // scaffold let the bare window show through as a black (or white) band
      // above the warm background on a device.
      backgroundColor: palette.backgroundTop,
      appBar: AppBar(
        title: Text(l10n.appTitle,
            style: TextStyle(fontSize: 18, color: palette.textPrimary)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 48,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, size: 20),
            color: palette.textSecondary,
            tooltip: l10n.about,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
            ),
          ),
        ],
      ),
      body: Container(
        // Fill the viewport. Without this the Container sizes to its scrolling
        // child, so on a tall screen the gradient stopped where the content
        // ended and left a black band below it.
        constraints: const BoxConstraints.expand(),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [palette.backgroundTop, palette.backgroundBottom],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const maxContentWidth = 900.0;
              final isWide = constraints.maxWidth >= 600;
              // Derive the meter from the width the content will actually get,
              // not the raw viewport — otherwise it overflows the cap on a wide
              // desktop window.
              final contentWidth =
                  math.min(constraints.maxWidth, maxContentWidth);
              final meterWidth =
                  isWide ? contentWidth * 0.6 : contentWidth * 0.85;

              final padding = isWide ? 24.0 : 12.0;
              return SingleChildScrollView(
                padding: EdgeInsets.all(padding),
                // Centre the content when it is shorter than the viewport —
                // otherwise on a tall tablet everything crowds into the top
                // half and leaves a large empty band underneath. Still scrolls
                // normally once the content outgrows the screen.
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - padding * 2,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      // Keep the two-column layout readable instead of letting
                      // it stretch the full width of a large display.
                      constraints: const BoxConstraints(maxWidth: maxContentWidth),
                      child: isWide
                          ? _buildWideLayout(
                              l10n, palette, displayNote, pitch, cents, note, meterWidth)
                          : _buildNarrowLayout(
                              l10n, palette, displayNote, pitch, cents, note, meterWidth),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Phone layout — single column, compact.
  Widget _buildNarrowLayout(
    AppLocalizations l10n, TunerPalette palette,
    String displayNote, double pitch, double cents, String note, double meterWidth,
  ) {
    return Column(
      children: [
        _buildNoteDisplay(l10n, palette, displayNote),
        const SizedBox(height: 12),
        _buildTuningMeter(l10n, palette, meterWidth, cents),
        const SizedBox(height: 4),
        _buildReadout(l10n, palette, pitch, note),
        const SizedBox(height: 12),
        _buildStringIndicators(l10n, palette, note),
        const SizedBox(height: 12),
        _buildVisualizationRow(l10n, palette),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildSettings(l10n, palette)),
            const SizedBox(width: 12),
            _buildMicButton(l10n, palette),
          ],
        ),
      ],
    );
  }

  /// Tablet / desktop layout — two-column with larger visualizations.
  Widget _buildWideLayout(
    AppLocalizations l10n, TunerPalette palette,
    String displayNote, double pitch, double cents, String note,
    double meterWidth,
  ) {
    return Column(
      children: [
        _buildNoteDisplay(l10n, palette, displayNote, scaleFactor: 1.3),
        const SizedBox(height: 16),
        _buildTuningMeter(l10n, palette, meterWidth, cents),
        const SizedBox(height: 4),
        _buildReadout(l10n, palette, pitch, note),
        const SizedBox(height: 16),
        _buildStringIndicators(l10n, palette, note),
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
                    PitchHistoryPainter(_engine.pitchHistory, palette.accent,
                        baselineColor: palette.outline),
                    l10n,
                    palette,
                    height: 140,
                  ),
                  const SizedBox(height: 12),
                  _buildVisualizationCard(
                    l10n.frequencySpectrum,
                    FFTPainter(_engine.fftMagnitudes, palette.spectrum),
                    l10n,
                    palette,
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
                  _buildSettings(l10n, palette),
                  const SizedBox(height: 16),
                  _buildMicButton(l10n, palette),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Frequency, plus the temperament deviation when one is in force.
  Widget _buildReadout(
      AppLocalizations l10n, TunerPalette palette, double pitch, String note) {
    final offset =
        note.isEmpty ? 0.0 : _engine.centsOffsetForNote(note);
    final showOffset = !_engine.temperamentTable.isEqual && note.isNotEmpty;
    return Column(
      children: [
        Text(l10n.hertzValue(pitch.toStringAsFixed(2)),
            style: TextStyle(fontSize: 14, color: palette.textSecondary)),
        if (showOffset)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              l10n.temperamentOffset(
                TunerEngine.stripOctave(note),
                '${offset >= 0 ? '+' : ''}${offset.toStringAsFixed(1)}',
              ),
              style: TextStyle(fontSize: 12, color: palette.textFaint),
            ),
          ),
      ],
    );
  }

  Widget _buildNoteDisplay(
      AppLocalizations l10n, TunerPalette palette, String displayNote,
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
                      ? palette.inTune
                      : palette.textPrimary,
                  height: 1,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ExcludeSemantics(
            child: Text(statusText,
                style: TextStyle(
                    fontSize: 16 * scaleFactor,
                    color: _statusColor(palette))),
          ),
        ],
      ),
    );
  }

  Widget _buildVisualizationRow(AppLocalizations l10n, TunerPalette palette) {
    return Row(
      children: [
        Expanded(
          child: _buildVisualizationCard(
            l10n.pitchHistory,
            PitchHistoryPainter(_engine.pitchHistory, palette.accent,
                        baselineColor: palette.outline),
            l10n,
            palette,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildVisualizationCard(
            l10n.frequencySpectrum,
            FFTPainter(_engine.fftMagnitudes, palette.spectrum),
            l10n,
            palette,
          ),
        ),
      ],
    );
  }

  Widget _buildVisualizationCard(String label, CustomPainter painter,
      AppLocalizations l10n, TunerPalette palette,
      {double height = 100}) {
    return Semantics(
      label: l10n.visualizationLabel(label),
      excludeSemantics: true,
      child: Column(
        children: [
          Text(label,
              style: TextStyle(color: palette.textSecondary, fontSize: 12)),
          const SizedBox(height: 4),
          Container(
            height: height,
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.outline),
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

  Color _statusColor(TunerPalette palette) {
    switch (_status) {
      case TunerStatus.inTune:
        return palette.inTune;
      case TunerStatus.idle:
      case TunerStatus.listening:
        return palette.textSecondary;
      case TunerStatus.playing:
        return palette.tone;
      case TunerStatus.sharp:
      case TunerStatus.flat:
      case TunerStatus.permissionDenied:
        return palette.offPitch;
    }
  }

  Widget _buildTuningMeter(AppLocalizations l10n, TunerPalette palette,
      double width, double cents) {
    final clampedCents = cents.clamp(-50.0, 50.0);
    final meterPosition = clampedCents / 50.0;
    final leftMargin = meterPosition > 0 ? meterPosition * (width / 2 - 20) : 0.0;
    final rightMargin = meterPosition < 0 ? -meterPosition * (width / 2 - 20) : 0.0;
    final statusColor = _statusColor(palette);

    return Semantics(
      label: l10n.tuningMeterLabel(clampedCents.toStringAsFixed(0)),
      value: '${(meterPosition * 100).toStringAsFixed(0)}%',
      child: Container(
        width: width,
        height: 40,
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(color: palette.outline, width: 2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(width: 3, height: 40, color: palette.outline),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: EdgeInsets.only(left: leftMargin, right: rightMargin),
              width: 6,
              height: 40,
              decoration: BoxDecoration(
                color: statusColor,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One chip per open string.
  ///
  /// A [Wrap] rather than a [Row]: a seven-string guitar or a five-string
  /// banjo does not fit across a phone in one line, and `spaceEvenly` would
  /// simply overflow.
  Widget _buildStringIndicators(
      AppLocalizations l10n, TunerPalette palette, String currentNote) {
    final strings = _engine.currentTuningStrings;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: strings.mapIndexed((index, stringNote) {
        final bool isCurrentNote = currentNote == stringNote;
        final bool isInTune = isCurrentNote && _status == TunerStatus.inTune;
        final bool isPlayingThisTone = _currentlyPlayingNote == stringNote;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isCurrentNote ? palette.accent : palette.outline,
                  width: 2,
                ),
              ),
              child: Text(
                TunerEngine.stripOctave(stringNote),
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: palette.textPrimary),
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isInTune
                    ? palette.inTune
                    : (isCurrentNote ? palette.offPitch : palette.outline),
              ),
            ),
            Semantics(
              button: true,
              label: isPlayingThisTone
                  ? l10n.stopReferenceTone(TunerEngine.stripOctave(stringNote))
                  : l10n.playReferenceTone(TunerEngine.stripOctave(stringNote)),
              child: IconButton(
                icon: Icon(
                    isPlayingThisTone
                        ? Icons.stop_circle
                        : Icons.play_circle_outline,
                    size: 24),
                color: isPlayingThisTone ? palette.tone : palette.textSecondary,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                // Two strings of a tuning can carry the same note (open C on a
                // banjo, the octave pairs a 12-string implies) — keying the
                // tone by name alone would light both.
                onPressed: () => _toggleToneGenerator(stringNote),
              ),
            ),
            if (index < 0) const SizedBox.shrink(),
          ],
        );
      }).toList(),
    );
  }

  InputDecoration _fieldDecoration(TunerPalette palette, {Widget? prefixIcon}) {
    return InputDecoration(
      filled: true,
      fillColor: palette.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: palette.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: palette.outline),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      prefixIcon: prefixIcon,
      prefixIconConstraints:
          prefixIcon == null ? null : const BoxConstraints(minWidth: 28),
    );
  }

  Widget _buildSettings(AppLocalizations l10n, TunerPalette palette) {
    final bool isActionDisabled = _isListening || _isGeneratingTone;
    final tunings = tuningsFor(_engine.selectedInstrument);
    final textStyle = TextStyle(fontSize: 14, color: palette.textPrimary);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: l10n.a4ReferenceFrequency,
            value: l10n.hertzValue(_engine.a4Frequency.toStringAsFixed(1)),
            child: Text(l10n.a4Label(_engine.a4Frequency.toStringAsFixed(1)),
                style: TextStyle(color: palette.textPrimary, fontSize: 13)),
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: palette.accent,
              inactiveTrackColor: palette.outline,
              thumbColor: palette.accent,
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

          // Instrument
          Semantics(
            label: l10n.instrumentLabel,
            child: DropdownButtonFormField<Instrument>(
              initialValue: _engine.selectedInstrument,
              isDense: true,
              isExpanded: true,
              decoration: _fieldDecoration(palette),
              dropdownColor: palette.surfaceStrong,
              onChanged: isActionDisabled
                  ? null
                  : (Instrument? newValue) {
                      if (newValue != null) {
                        _engine.selectedInstrument = newValue;
                        _savePreferences();
                      }
                    },
              items: Instrument.values.map((value) {
                return DropdownMenuItem<Instrument>(
                  value: value,
                  child: Text(instrumentName(l10n, value), style: textStyle),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),

          // Tuning, including the user's own
          Semantics(
            label: l10n.tuningLabel,
            child: DropdownButtonFormField<String>(
              initialValue: _engine.tuningId,
              isDense: true,
              isExpanded: true,
              decoration: _fieldDecoration(palette),
              dropdownColor: palette.surfaceStrong,
              onChanged: isActionDisabled
                  ? null
                  : (String? newValue) {
                      if (newValue == null) return;
                      _engine.tuningId = newValue;
                      _savePreferences();
                      if (newValue == customTuningId) _openCustomTuningEditor();
                    },
              items: [
                ...tunings.map((tuning) => DropdownMenuItem<String>(
                      value: tuning.id,
                      child: Text(
                        '${tuningName(l10n, tuning.id)} · '
                        '${tuning.strings.map(TunerEngine.stripOctave).join(' ')}',
                        style: textStyle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    )),
                DropdownMenuItem<String>(
                  value: customTuningId,
                  child: Text(tuningName(l10n, customTuningId), style: textStyle),
                ),
              ],
            ),
          ),
          if (_engine.tuningId == customTuningId) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: isActionDisabled ? null : _openCustomTuningEditor,
                icon: const Icon(Icons.tune, size: 16),
                label: Text(l10n.editCustomTuning,
                    style: TextStyle(fontSize: 12, color: palette.accent)),
                style: TextButton.styleFrom(
                  foregroundColor: palette.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),

          // Temperament
          Semantics(
            label: l10n.temperamentLabel,
            child: DropdownButtonFormField<Temperament>(
              initialValue: _engine.temperament,
              isDense: true,
              isExpanded: true,
              decoration: _fieldDecoration(palette),
              dropdownColor: palette.surfaceStrong,
              onChanged: isActionDisabled
                  ? null
                  : (Temperament? newValue) {
                      if (newValue != null) {
                        _engine.temperament = newValue;
                        _savePreferences();
                      }
                    },
              items: Temperament.values.map((value) {
                return DropdownMenuItem<Temperament>(
                  value: value,
                  child: Text(temperamentName(l10n, value),
                      style: textStyle, overflow: TextOverflow.ellipsis),
                );
              }).toList(),
            ),
          ),

          // The key only means anything for an unequal temperament — in equal
          // temperament every key is identical by construction, so offering
          // the choice there would imply a difference that does not exist.
          if (!_engine.temperamentTable.isEqual) ...[
            const SizedBox(height: 8),
            Semantics(
              label: l10n.temperamentKey,
              child: DropdownButtonFormField<int>(
                initialValue: _engine.temperamentRoot,
                isDense: true,
                isExpanded: true,
                decoration: _fieldDecoration(palette),
                dropdownColor: palette.surfaceStrong,
                onChanged: isActionDisabled
                    ? null
                    : (int? newValue) {
                        if (newValue != null) {
                          _engine.temperamentRoot = newValue;
                          _savePreferences();
                        }
                      },
                items: List.generate(12, (pitchClass) {
                  return DropdownMenuItem<int>(
                    value: pitchClass,
                    child: Text(
                        '${l10n.temperamentKey}: ${pitchClassNames[pitchClass]}',
                        style: textStyle),
                  );
                }),
              ),
            ),
          ],

          const SizedBox(height: 8),

          // Which detector runs. YIN is the default and is what every number
          // in bench/REPORT.md describes; MPM answers on more frames and is
          // wrong on more of them, which on a quiet instrument is sometimes
          // the trade a player wants.
          Semantics(
            label: l10n.detectorLabel,
            child: DropdownButtonFormField<DetectorKind>(
              initialValue: _engine.detectorKind,
              isDense: true,
              isExpanded: true,
              decoration: _fieldDecoration(
                palette,
                prefixIcon: Icon(Icons.graphic_eq,
                    size: 16, color: palette.textFaint),
              ),
              dropdownColor: palette.surfaceStrong,
              onChanged: isActionDisabled
                  ? null
                  : (DetectorKind? newValue) {
                      if (newValue != null) {
                        setState(() => _selectDetector(newValue));
                        _savePreferences();
                      }
                    },
              items: DetectorKind.values.map((value) {
                return DropdownMenuItem<DetectorKind>(
                  value: value,
                  child: Text(detectorName(l10n, value),
                      style: textStyle, overflow: TextOverflow.ellipsis),
                );
              }).toList(),
            ),
          ),

          if (_inputDevices.length > 1) ...[
            const SizedBox(height: 8),
            Semantics(
              label: l10n.selectMicrophone,
              child: DropdownButtonFormField<String?>(
                initialValue: _selectedDeviceId,
                isDense: true,
                isExpanded: true,
                decoration: _fieldDecoration(
                  palette,
                  prefixIcon:
                      Icon(Icons.mic, size: 16, color: palette.textFaint),
                ),
                dropdownColor: palette.surfaceStrong,
                onChanged: isActionDisabled
                    ? null
                    : (String? deviceId) {
                        setState(() => _selectedDeviceId = deviceId);
                      },
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(l10n.defaultMicrophone,
                        style: TextStyle(
                            fontSize: 12, color: palette.textPrimary)),
                  ),
                  ..._inputDevices.map((d) => DropdownMenuItem<String?>(
                        value: d.id,
                        child: Text(
                          d.label,
                          style: TextStyle(
                              fontSize: 12, color: palette.textPrimary),
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

  Future<void> _openCustomTuningEditor() async {
    final edited = await showDialog<List<String>>(
      context: context,
      builder: (context) => CustomTuningDialog(
        initial: _engine.customStrings,
        standard: tuningsFor(_engine.selectedInstrument).first.strings,
      ),
    );
    if (edited != null) {
      _engine.customStrings = edited;
      await _savePreferences();
    }
  }

  Widget _buildMicButton(AppLocalizations l10n, TunerPalette palette) {
    return Semantics(
      button: true,
      label: _isListening ? l10n.stopTuningButton : l10n.startTuningButton,
      child: ElevatedButton(
        onPressed: _toggleListening,
        style: ElevatedButton.styleFrom(
          backgroundColor: _isListening ? palette.offPitch : palette.accent,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          padding: const EdgeInsets.all(20),
          elevation: 2,
        ),
        child: Icon(
          _isListening ? Icons.mic_off : Icons.mic,
          size: 32,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Editor for the user's own tuning.
///
/// Notes are moved by semitone rather than typed: a text field invites "H4"
/// and "E١٢", and every one of those has to be rejected with a message. The
/// buttons cannot produce an invalid note at all.
class CustomTuningDialog extends StatefulWidget {
  final List<String> initial;
  final List<String> standard;

  const CustomTuningDialog({
    super.key,
    required this.initial,
    required this.standard,
  });

  @override
  State<CustomTuningDialog> createState() => _CustomTuningDialogState();
}

class _CustomTuningDialogState extends State<CustomTuningDialog> {
  late List<String> _strings = List<String>.from(widget.initial);

  void _shift(int index, int semitones) {
    final midi = TunerEngine.midiForNoteName(_strings[index]);
    if (midi == null) return;
    final next = midi + semitones;
    if (next < TunerEngine.minMidi || next > TunerEngine.maxMidi) return;
    setState(() => _strings[index] = TunerEngine.noteNameForMidi(next));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = TunerPalette.of(context);

    return AlertDialog(
      backgroundColor: palette.surfaceStrong,
      title: Text(l10n.customTuningTitle,
          style: TextStyle(color: palette.textPrimary, fontSize: 18)),
      content: SizedBox(
        // As wide as a phone allows, but no wider than reads well: a bare
        // double.maxFinite stretched the dialog across nearly the whole of an
        // iPad, and a fixed 320 overflowed a small phone.
        width: math.min(420, MediaQuery.sizeOf(context).width - 80),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._strings.mapIndexed((index, note) {
                return Semantics(
                  label: l10n.stringNumber('${index + 1}'),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text('${index + 1}',
                            style: TextStyle(color: palette.textFaint)),
                      ),
                      Expanded(
                        child: Text(note,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: palette.textPrimary)),
                      ),
                      IconButton(
                        tooltip: l10n.lowerSemitone(note),
                        icon: const Icon(Icons.remove, size: 18),
                        color: palette.textSecondary,
                        onPressed: () => _shift(index, -1),
                      ),
                      IconButton(
                        tooltip: l10n.raiseSemitone(note),
                        icon: const Icon(Icons.add, size: 18),
                        color: palette.textSecondary,
                        onPressed: () => _shift(index, 1),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 8),
              // A Wrap, not a Row: an AlertDialog on a narrow phone leaves
              // well under 320 logical pixels for its content, and two
              // labelled buttons side by side overflowed it.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: _strings.length <= minCustomStrings
                        ? null
                        : () => setState(() => _strings.removeLast()),
                    icon: const Icon(Icons.remove_circle_outline, size: 16),
                    label: Text(l10n.removeString,
                        style: const TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                        foregroundColor: palette.textSecondary,
                        visualDensity: VisualDensity.compact),
                  ),
                  TextButton.icon(
                    onPressed: _strings.length >= maxCustomStrings
                        ? null
                        : () => setState(() => _strings.add(_strings.last)),
                    icon: const Icon(Icons.add_circle_outline, size: 16),
                    label: Text(l10n.addString,
                        style: const TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                        foregroundColor: palette.textSecondary,
                        visualDensity: VisualDensity.compact),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              setState(() => _strings = List<String>.from(widget.standard)),
          style: TextButton.styleFrom(foregroundColor: palette.textSecondary),
          child: Text(l10n.resetTuning),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_strings),
          style: TextButton.styleFrom(foregroundColor: palette.accent),
          child: Text(l10n.done),
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
      color != oldDelegate.color ||
      !const ListEquality<double>().equals(fftData, oldDelegate.fftData);
}

class PitchHistoryPainter extends CustomPainter {
  final List<double> pitchHistory;
  final Color color;

  /// Colour of the zero-cents centre line.
  ///
  /// This used to be a hardcoded translucent white, which was invisible the
  /// moment the app gained a light theme.
  final Color baselineColor;

  PitchHistoryPainter(this.pitchHistory, this.color,
      {this.baselineColor = const Color(0x33FFFFFF)});

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
      ..color = baselineColor
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
      color != oldDelegate.color ||
      baselineColor != oldDelegate.baselineColor ||
      !const ListEquality<double>().equals(
          pitchHistory, oldDelegate.pitchHistory);
}
