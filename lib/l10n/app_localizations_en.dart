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
  String get about => 'About';

  @override
  String get aboutTitle => 'About CrispTuner';

  @override
  String get aboutTagline => 'Precise chromatic tuner for six instruments';

  @override
  String get aboutServiceProvider => 'Service Provider';

  @override
  String get aboutLicense => 'License';

  @override
  String get aboutLicenseBody =>
      'CrispTuner is licensed under the MIT License.\n\nYou are free to use, modify and distribute this software for any purpose, including commercial use.';

  @override
  String get aboutComponents => 'Open Source Components';

  @override
  String get aboutComponentsIntro =>
      'CrispTuner is built on these open source packages. The full license texts are available under “Open Source Licenses” below.';

  @override
  String get aboutHowItWorks => 'How It Works';

  @override
  String get aboutHowItWorksBody =>
      'Microphone audio is captured as 16-bit PCM at 44.1 kHz. Each 2048-sample block is analysed with the YIN algorithm to estimate pitch, then passed through a 5-sample median filter so the reading stays steady. The result is matched to the nearest note for your chosen concert pitch, and the deviation is shown in cents. In parallel a Hann-windowed FFT drives the spectrum display.';

  @override
  String get aboutPrivacy => 'Privacy';

  @override
  String get aboutPrivacyBody =>
      'Short version: CrispTuner collects nothing about you.\n\nMicrophone audio is analysed in real time on your device and is never recorded, stored or transmitted. There are no accounts, no analytics, no advertising and no tracking, and the app makes no network requests at all.\n\nOnly your A4 reference frequency and selected instrument are saved, locally, so they persist between launches. They are removed when you uninstall the app.';

  @override
  String get aboutPrivacyPolicyLink => 'Read the full privacy policy';

  @override
  String get aboutDisclaimer => 'Disclaimer';

  @override
  String get aboutDisclaimerBody =>
      'This software is provided “as is”, without warranty of any kind. The authors are not liable for any damages arising from the use of this software.';

  @override
  String get aboutSourceCode => 'Source Code';

  @override
  String get aboutContributions =>
      'Contributions welcome. Please open an issue first for major changes.';

  @override
  String get aboutOpenSourceLicenses => 'Open Source Licenses';

  @override
  String get aboutCopied => 'Copied to clipboard';

  @override
  String visualizationLabel(String label) {
    return '$label visualization';
  }
}
