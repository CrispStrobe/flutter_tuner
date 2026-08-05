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
  String get about => 'Über';

  @override
  String get aboutTitle => 'Über CrispTuner';

  @override
  String get aboutTagline =>
      'Präzises chromatisches Stimmgerät für sechs Instrumente';

  @override
  String get aboutServiceProvider => 'Diensteanbieter';

  @override
  String get aboutLicense => 'Lizenz';

  @override
  String get aboutLicenseBody =>
      'CrispTuner steht unter der MIT-Lizenz.\n\nSie dürfen diese Software zu jedem Zweck frei verwenden, verändern und weitergeben, auch kommerziell.';

  @override
  String get aboutComponents => 'Open-Source-Komponenten';

  @override
  String get aboutComponentsIntro =>
      'CrispTuner baut auf diesen Open-Source-Paketen auf. Die vollständigen Lizenztexte finden Sie unten unter „Open-Source-Lizenzen“.';

  @override
  String get aboutHowItWorks => 'Funktionsweise';

  @override
  String get aboutHowItWorksBody =>
      'Das Mikrofonsignal wird als 16-Bit-PCM mit 44,1 kHz aufgenommen. Jeder Block von 2048 Samples wird mit dem YIN-Algorithmus auf seine Tonhöhe untersucht und anschließend durch einen Medianfilter über 5 Werte geglättet, damit die Anzeige ruhig bleibt. Das Ergebnis wird dem nächstgelegenen Ton für Ihren Kammerton zugeordnet und die Abweichung in Cent angezeigt. Parallel dazu speist eine Hann-gefensterte FFT die Spektrumanzeige.';

  @override
  String get aboutPrivacy => 'Datenschutz';

  @override
  String get aboutPrivacyBody =>
      'Kurz gesagt: CrispTuner erfasst nichts über Sie.\n\nDas Mikrofonsignal wird in Echtzeit auf Ihrem Gerät ausgewertet und niemals aufgezeichnet, gespeichert oder übertragen. Es gibt keine Konten, keine Analyse, keine Werbung und kein Tracking; die App stellt überhaupt keine Netzwerkverbindungen her.\n\nGespeichert werden lokal nur Ihr A4-Kammerton und das gewählte Instrument, damit sie beim nächsten Start erhalten bleiben. Beim Deinstallieren werden sie entfernt.';

  @override
  String get aboutPrivacyPolicyLink =>
      'Vollständige Datenschutzerklärung lesen';

  @override
  String get aboutDisclaimer => 'Haftungsausschluss';

  @override
  String get aboutDisclaimerBody =>
      'Diese Software wird „wie besehen“ und ohne jegliche Gewährleistung bereitgestellt. Die Autoren haften nicht für Schäden, die aus der Nutzung dieser Software entstehen.';

  @override
  String get aboutSourceCode => 'Quellcode';

  @override
  String get aboutContributions =>
      'Beiträge sind willkommen. Bitte eröffnen Sie vor größeren Änderungen zuerst ein Issue.';

  @override
  String get aboutOpenSourceLicenses => 'Open-Source-Lizenzen';

  @override
  String get aboutCopied => 'In die Zwischenablage kopiert';

  @override
  String visualizationLabel(String label) {
    return 'Visualisierung: $label';
  }
}
