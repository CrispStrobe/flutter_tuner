// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'CrispTuner';

  @override
  String get startTuning => 'Stimmen beginnen';

  @override
  String get listening => 'Höre zu…';

  @override
  String get inTune => 'Gestimmt ✓';

  @override
  String get tooSharp => 'Zu hoch ↑';

  @override
  String get tooFlat => 'Zu tief ↓';

  @override
  String playing(String note) {
    return '$note erklingt';
  }

  @override
  String get micPermissionDenied => 'Mikrofonzugriff verweigert';

  @override
  String get pitchHistory => 'Tonhöhenverlauf';

  @override
  String get frequencySpectrum => 'Frequenzspektrum';

  @override
  String hertzValue(String hz) {
    return '$hz Hz';
  }

  @override
  String a4Label(String hz) {
    return 'A4: $hz Hz';
  }

  @override
  String get a4ReferenceFrequency => 'A4-Referenzfrequenz';

  @override
  String get instrumentGuitar => 'Gitarre';

  @override
  String get instrumentCello => 'Cello';

  @override
  String get instrumentBass => 'Bass';

  @override
  String get instrumentViolin => 'Geige';

  @override
  String get instrumentUkulele => 'Ukulele';

  @override
  String get instrumentMandolin => 'Mandoline';

  @override
  String get defaultMicrophone => 'Standardmikrofon';

  @override
  String get selectMicrophone => 'Mikrofoneingang wählen';

  @override
  String noNoteDetected(String status) {
    return 'Kein Ton erkannt. $status';
  }

  @override
  String detectedNote(String note, String status) {
    return 'Erkannter Ton: $note. $status';
  }

  @override
  String tuningMeterLabel(String cents) {
    return 'Stimmanzeige: $cents Cent';
  }

  @override
  String playReferenceTone(String note) {
    return 'Referenzton $note abspielen';
  }

  @override
  String stopReferenceTone(String note) {
    return 'Wiedergabe von $note stoppen';
  }

  @override
  String get startTuningButton => 'Stimmen starten';

  @override
  String get stopTuningButton => 'Stimmen stoppen';

  @override
  String visualizationLabel(String label) {
    return 'Visualisierung: $label';
  }
}
