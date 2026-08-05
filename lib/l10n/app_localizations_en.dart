// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'CrispTuner';

  @override
  String get startTuning => 'Start Tuning';

  @override
  String get listening => 'Listening…';

  @override
  String get inTune => 'In Tune ✓';

  @override
  String get tooSharp => 'Too Sharp ↑';

  @override
  String get tooFlat => 'Too Flat ↓';

  @override
  String playing(String note) {
    return 'Playing $note';
  }

  @override
  String get micPermissionDenied => 'Microphone permission denied';

  @override
  String get pitchHistory => 'Pitch History';

  @override
  String get frequencySpectrum => 'Frequency Spectrum';

  @override
  String hertzValue(String hz) {
    return '$hz Hz';
  }

  @override
  String a4Label(String hz) {
    return 'A4: $hz Hz';
  }

  @override
  String get a4ReferenceFrequency => 'A4 reference frequency';

  @override
  String get instrumentGuitar => 'Guitar';

  @override
  String get instrumentCello => 'Cello';

  @override
  String get instrumentBass => 'Bass';

  @override
  String get instrumentViolin => 'Violin';

  @override
  String get instrumentUkulele => 'Ukulele';

  @override
  String get instrumentMandolin => 'Mandolin';

  @override
  String get defaultMicrophone => 'Default mic';

  @override
  String get selectMicrophone => 'Select microphone input';

  @override
  String noNoteDetected(String status) {
    return 'No note detected. $status';
  }

  @override
  String detectedNote(String note, String status) {
    return 'Detected note: $note. $status';
  }

  @override
  String tuningMeterLabel(String cents) {
    return 'Tuning meter: $cents cents';
  }

  @override
  String playReferenceTone(String note) {
    return 'Play reference tone $note';
  }

  @override
  String stopReferenceTone(String note) {
    return 'Stop playing $note';
  }

  @override
  String get startTuningButton => 'Start tuning';

  @override
  String get stopTuningButton => 'Stop tuning';

  @override
  String visualizationLabel(String label) {
    return '$label visualization';
  }
}
