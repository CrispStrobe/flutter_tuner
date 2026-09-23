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
      'Chromatisches Stimmgerät mit historischen Temperaturen';

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
      'Das Mikrofonsignal wird als 16-Bit-PCM mit 44,1 kHz aufgenommen und in einem Fenster von 4096 Samples gesammelt. Dieses Fenster wird mit dem YIN-Algorithmus analysiert und anschließend durch einen Medianfilter über 5 Werte geglättet. Die Fensterbreite ist entscheidend: YIN erfasst nur Frequenzen oberhalb der doppelten Abtastrate geteilt durch die Fensterlänge – ein schmaleres Fenster würde das tiefe H eines 5-saitigen Basses bei 30,9 Hz nicht mehr erreichen.\n\nDer ermittelte Ton wird über seine Position auf einer logarithmischen Tonhöhenskala dem nächstgelegenen Ton zugeordnet – anhand von Zielfrequenzen, die aus Kammerton und Temperatur berechnet werden –, und die Abweichung wird in Cent angezeigt. Jede Temperatur wird aus den Größen der zwölf Quinten hergeleitet, die sie definieren, und so verankert, dass das A genau dort klingt, wo Sie es eingestellt haben.\n\nParallel dazu speist eine Hann-gefensterte FFT über die letzten 2048 Samples die Spektrumanzeige.';

  @override
  String get aboutPrivacy => 'Datenschutz';

  @override
  String get aboutPrivacyBody =>
      'Kurz gesagt: CrispTuner erfasst nichts über Sie.\n\nDas Mikrofonsignal wird in Echtzeit auf Ihrem Gerät ausgewertet und niemals aufgezeichnet, gespeichert oder übertragen. Es gibt keine Konten, keine Analyse, keine Werbung und kein Tracking, und die App stellt überhaupt keine Netzwerkverbindungen her.\n\nNur Ihre Einstellungen – Kammerton, Instrument, gewählte Stimmung, Ihre eigene Stimmung sowie Temperatur und deren Tonart – werden lokal gespeichert, damit sie beim nächsten Start wieder bereitstehen. Beim Deinstallieren werden sie entfernt.';

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

  @override
  String get instrumentGuitar7 => '7-saitige Gitarre';

  @override
  String get instrumentBass5 => '5-saitiger Bass';

  @override
  String get instrumentViola => 'Bratsche';

  @override
  String get instrumentDoubleBass => 'Kontrabass';

  @override
  String get instrumentBanjo => 'Banjo';

  @override
  String get instrumentLabel => 'Instrument';

  @override
  String get tuningLabel => 'Stimmung';

  @override
  String get tuningStandard => 'Standard';

  @override
  String get tuningHalfStepDown => 'Einen Halbton tiefer';

  @override
  String get tuningWholeStepDown => 'Einen Ganzton tiefer';

  @override
  String get tuningLowG => 'Tiefes G';

  @override
  String get tuningBaritone => 'Bariton';

  @override
  String get tuningDTuning => 'D-Stimmung';

  @override
  String get tuningSolo => 'Solostimmung';

  @override
  String get tuningTenor => 'Tenor';

  @override
  String get tuningOctave => 'Oktav';

  @override
  String get tuningCrossAEAE => 'Skordatur AEAE';

  @override
  String get tuningCustom => 'Eigene …';

  @override
  String get temperamentLabel => 'Temperatur';

  @override
  String get temperamentKey => 'Tonart';

  @override
  String get temperamentEqual => 'Gleichstufig';

  @override
  String get temperamentPythagorean => 'Pythagoreisch';

  @override
  String get temperamentMeantone => '1/4-Komma-mitteltönig';

  @override
  String get temperamentWerckmeister => 'Werckmeister III';

  @override
  String get temperamentKirnberger => 'Kirnberger III';

  @override
  String get temperamentVallotti => 'Vallotti';

  @override
  String get editCustomTuning => 'Eigene Stimmung bearbeiten';

  @override
  String get customTuningTitle => 'Eigene Stimmung';

  @override
  String get addString => 'Saite hinzufügen';

  @override
  String get removeString => 'Saite entfernen';

  @override
  String get done => 'Fertig';

  @override
  String get resetTuning => 'Auf Standard zurücksetzen';

  @override
  String stringNumber(String n) {
    return 'Saite $n';
  }

  @override
  String raiseSemitone(String note) {
    return '$note einen Halbton höher';
  }

  @override
  String lowerSemitone(String note) {
    return '$note einen Halbton tiefer';
  }

  @override
  String temperamentOffset(String note, String cents) {
    return '$note $cents ¢ ggü. gleichstufig';
  }

  @override
  String get detectorLabel => 'Tonhöhenerkennung';

  @override
  String get detectorYin => 'YIN (empfohlen)';

  @override
  String get detectorMpm => 'MPM (empfindlicher)';

  @override
  String get detectorSwipe => 'SWIPE′ (experimentell)';

  @override
  String get transcriptionTitle => 'Akkorderkennung';

  @override
  String get transcriptionEnable => 'Akkorde erkennen';

  @override
  String get transcriptionListening => 'Warte auf Töne …';

  @override
  String get transcriptionUnsupported => 'Im Browser nicht verfügbar';

  @override
  String get transcriptionNotForTuning =>
      'Nur Tonnamen — zum Stimmen die Anzeige oben verwenden';

  @override
  String get refinementLabel => 'Ruhigere Anzeige';

  @override
  String get refinementDescription =>
      'Misst jede Anzeige nach — ruhiger und genauer, mit etwas mehr Rechenaufwand.';

  @override
  String get transcriptionModelLabel => 'Erkennungsmodell';

  @override
  String get transcriptionModelBuiltIn => 'Eingebaut — kein Download';

  @override
  String transcriptionModelDownloadSize(String size) {
    return '$size MB Download';
  }

  @override
  String get transcriptionModelAboutBasicPitch =>
      'Das eingebaute Modell auf der nativen Engine — zum Vergleich beider Laufzeiten';

  @override
  String get transcriptionModelAboutPiano =>
      'Klavier, sehr genau — das rechenintensivste der fünf';

  @override
  String get transcriptionModelAboutMt3 =>
      'Am besten bei echter Musik, und als einziges mit Instrumentenerkennung';

  @override
  String get transcriptionModelAboutOnsetsAndFrames =>
      'Klavier, mit dem besten Verhältnis aus Genauigkeit, Größe und Tempo';

  @override
  String get transcriptionModelAboutHft =>
      'Das kleinste Modell und bei Klavier das genaueste';

  @override
  String get transcriptionModelSpeedAppleSilicon =>
      'Auf einem Apple-Silicon-Mac gemessen: schnell genug für Live-Spiel. Auf Telefon und Tablet nicht gemessen.';

  @override
  String get transcriptionModelEnvOverride =>
      'Durch die Umgebungsvariable CRISPTUNER_TRANSCRIPTION_BACKEND festgelegt; diese Einstellung wird dadurch übergangen.';

  @override
  String get transcriptionLibraryMissing =>
      'Dieses Modell benötigt die CrispASR-Engine, die in dieser Installation fehlt.';

  @override
  String get transcriptionModelMissing =>
      'Dieses Modell liegt noch nicht auf dem Gerät und konnte nicht geladen werden. Verbindung prüfen und erneut versuchen.';

  @override
  String get transcriptionModelMeasurementNote =>
      'Größen und Geschwindigkeiten auf einem Desktop-Prozessor gemessen, nicht auf einem Telefon.';
}
