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
  String get aboutTagline => 'Chromatic tuner with historical temperaments';

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
      'Microphone audio is captured as 16-bit PCM at 44.1 kHz and accumulated into a 4096-sample window. That window is analysed with the YIN algorithm to estimate pitch, then passed through a 5-sample median filter so the reading stays steady. The width matters: YIN can only resolve frequencies above twice the sample rate divided by the window, so a narrower window would not reach the low B of a five-string bass at 30.9 Hz.\n\nThe result is matched to the nearest note by its position on a logarithmic pitch scale, against targets computed for your concert pitch and temperament, and the deviation is shown in cents. Each temperament is derived from the sizes of the twelve fifths that define it rather than from a table of published cent values, and is then anchored so that A sounds exactly where you set it.\n\nIn parallel a Hann-windowed FFT over the most recent 2048 samples drives the spectrum display.';

  @override
  String get aboutPrivacy => 'Privacy';

  @override
  String get aboutPrivacyBody =>
      'Short version: CrispTuner collects nothing about you.\n\nMicrophone audio is analysed in real time on your device and is never recorded, stored or transmitted. There are no accounts, no analytics, no advertising and no tracking, and the app makes no network requests at all.\n\nOnly your settings — concert pitch, instrument, selected tuning, your custom tuning, and your temperament and its key — are saved, locally, so they persist between launches. They are removed when you uninstall the app.';

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

  @override
  String get instrumentGuitar7 => '7-string guitar';

  @override
  String get instrumentBass5 => '5-string bass';

  @override
  String get instrumentViola => 'Viola';

  @override
  String get instrumentDoubleBass => 'Double bass';

  @override
  String get instrumentBanjo => 'Banjo';

  @override
  String get instrumentLabel => 'Instrument';

  @override
  String get tuningLabel => 'Tuning';

  @override
  String get tuningStandard => 'Standard';

  @override
  String get tuningHalfStepDown => 'Half step down';

  @override
  String get tuningWholeStepDown => 'Whole step down';

  @override
  String get tuningLowG => 'Low G';

  @override
  String get tuningBaritone => 'Baritone';

  @override
  String get tuningDTuning => 'D tuning';

  @override
  String get tuningSolo => 'Solo tuning';

  @override
  String get tuningTenor => 'Tenor';

  @override
  String get tuningOctave => 'Octave';

  @override
  String get tuningCrossAEAE => 'Cross-tuning AEAE';

  @override
  String get tuningCustom => 'Custom…';

  @override
  String get temperamentLabel => 'Temperament';

  @override
  String get temperamentKey => 'Key';

  @override
  String get temperamentEqual => 'Equal';

  @override
  String get temperamentPythagorean => 'Pythagorean';

  @override
  String get temperamentMeantone => '1/4-comma meantone';

  @override
  String get temperamentWerckmeister => 'Werckmeister III';

  @override
  String get temperamentKirnberger => 'Kirnberger III';

  @override
  String get temperamentVallotti => 'Vallotti';

  @override
  String get editCustomTuning => 'Edit custom tuning';

  @override
  String get customTuningTitle => 'Custom tuning';

  @override
  String get addString => 'Add string';

  @override
  String get removeString => 'Remove string';

  @override
  String get done => 'Done';

  @override
  String get resetTuning => 'Reset to standard';

  @override
  String stringNumber(String n) {
    return 'String $n';
  }

  @override
  String raiseSemitone(String note) {
    return 'Raise $note a semitone';
  }

  @override
  String lowerSemitone(String note) {
    return 'Lower $note a semitone';
  }

  @override
  String temperamentOffset(String note, String cents) {
    return '$note $cents ¢ vs equal';
  }

  @override
  String get detectorLabel => 'Pitch detector';

  @override
  String get detectorYin => 'YIN (recommended)';

  @override
  String get detectorMpm => 'MPM (more sensitive)';

  @override
  String get detectorSwipe => 'SWIPE′ (experimental)';

  @override
  String get transcriptionTitle => 'Chord transcription';

  @override
  String get transcriptionEnable => 'Detect chords';

  @override
  String get transcriptionListening => 'Listening for notes…';

  @override
  String get transcriptionUnsupported => 'Not available in the browser';

  @override
  String get transcriptionNotForTuning =>
      'Names notes only — use the meter above to tune';

  @override
  String get refinementLabel => 'Steadier reading';

  @override
  String get refinementDescription =>
      'Re-measures every reading for a steadier, more precise needle. Costs a little more processing.';

  @override
  String get transcriptionModelLabel => 'Transcription model';

  @override
  String get transcriptionModelBuiltIn => 'Built-in — no download';

  @override
  String transcriptionModelDownloadSize(String size) {
    return '$size MB download';
  }

  @override
  String get transcriptionModelAboutBasicPitch =>
      'The built-in model, run by the native engine — for comparing the two runtimes';

  @override
  String get transcriptionModelAboutPiano =>
      'Piano, in detail — the heaviest of the five to run';

  @override
  String get transcriptionModelAboutMt3 =>
      'Best on real music, and the only one that names the instrument';

  @override
  String get transcriptionModelAboutOnsetsAndFrames =>
      'Piano, and the best balance of accuracy, size and speed';

  @override
  String get transcriptionModelAboutHft =>
      'The smallest of all, and the most accurate on piano';

  @override
  String get transcriptionModelSpeedUnmeasured =>
      'How fast this model runs on a phone, tablet or Mac has not been measured. It may not keep up with live playing.';

  @override
  String get transcriptionModelEnvOverride =>
      'Chosen by the CRISPTUNER_TRANSCRIPTION_BACKEND environment variable, which overrides this setting.';

  @override
  String get transcriptionLibraryMissing =>
      'This model needs the CrispASR engine, which this installation does not have.';

  @override
  String get transcriptionModelMissing =>
      'That model is not on this device yet and could not be downloaded. Check the connection and try again.';

  @override
  String get transcriptionModelMeasurementNote =>
      'Sizes and speeds measured on a desktop processor, not on a phone.';
}
