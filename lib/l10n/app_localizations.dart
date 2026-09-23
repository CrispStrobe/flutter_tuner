import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en')
  ];

  /// Application name, shown in the title bar and task switcher
  ///
  /// In en, this message translates to:
  /// **'CrispTuner'**
  String get appTitle;

  /// Idle status shown before listening starts
  ///
  /// In en, this message translates to:
  /// **'Start Tuning'**
  String get startTuning;

  /// Status shown while the microphone is active but no note is detected
  ///
  /// In en, this message translates to:
  /// **'Listening…'**
  String get listening;

  /// Status shown when the detected pitch is within 5 cents of the target
  ///
  /// In en, this message translates to:
  /// **'In Tune ✓'**
  String get inTune;

  /// Status shown when the detected pitch is above the target
  ///
  /// In en, this message translates to:
  /// **'Too Sharp ↑'**
  String get tooSharp;

  /// Status shown when the detected pitch is below the target
  ///
  /// In en, this message translates to:
  /// **'Too Flat ↓'**
  String get tooFlat;

  /// Status shown while a reference tone is sounding
  ///
  /// In en, this message translates to:
  /// **'Playing {note}'**
  String playing(String note);

  /// Status shown when the user declined microphone access
  ///
  /// In en, this message translates to:
  /// **'Microphone permission denied'**
  String get micPermissionDenied;

  /// No description provided for @pitchHistory.
  ///
  /// In en, this message translates to:
  /// **'Pitch History'**
  String get pitchHistory;

  /// No description provided for @frequencySpectrum.
  ///
  /// In en, this message translates to:
  /// **'Frequency Spectrum'**
  String get frequencySpectrum;

  /// A frequency reading, e.g. 440.00 Hz
  ///
  /// In en, this message translates to:
  /// **'{hz} Hz'**
  String hertzValue(String hz);

  /// Label above the A4 concert-pitch slider
  ///
  /// In en, this message translates to:
  /// **'A4: {hz} Hz'**
  String a4Label(String hz);

  /// Accessibility label for the A4 slider
  ///
  /// In en, this message translates to:
  /// **'A4 reference frequency'**
  String get a4ReferenceFrequency;

  /// No description provided for @instrumentGuitar.
  ///
  /// In en, this message translates to:
  /// **'Guitar'**
  String get instrumentGuitar;

  /// No description provided for @instrumentCello.
  ///
  /// In en, this message translates to:
  /// **'Cello'**
  String get instrumentCello;

  /// No description provided for @instrumentBass.
  ///
  /// In en, this message translates to:
  /// **'Bass'**
  String get instrumentBass;

  /// No description provided for @instrumentViolin.
  ///
  /// In en, this message translates to:
  /// **'Violin'**
  String get instrumentViolin;

  /// No description provided for @instrumentUkulele.
  ///
  /// In en, this message translates to:
  /// **'Ukulele'**
  String get instrumentUkulele;

  /// No description provided for @instrumentMandolin.
  ///
  /// In en, this message translates to:
  /// **'Mandolin'**
  String get instrumentMandolin;

  /// No description provided for @defaultMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Default mic'**
  String get defaultMicrophone;

  /// No description provided for @selectMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Select microphone input'**
  String get selectMicrophone;

  /// Accessibility live-region text when nothing is detected
  ///
  /// In en, this message translates to:
  /// **'No note detected. {status}'**
  String noNoteDetected(String status);

  /// Accessibility live-region text announcing the detected note
  ///
  /// In en, this message translates to:
  /// **'Detected note: {note}. {status}'**
  String detectedNote(String note, String status);

  /// Accessibility label for the cents deviation meter
  ///
  /// In en, this message translates to:
  /// **'Tuning meter: {cents} cents'**
  String tuningMeterLabel(String cents);

  /// Accessibility label for a string's play button
  ///
  /// In en, this message translates to:
  /// **'Play reference tone {note}'**
  String playReferenceTone(String note);

  /// Accessibility label for a string's play button while sounding
  ///
  /// In en, this message translates to:
  /// **'Stop playing {note}'**
  String stopReferenceTone(String note);

  /// No description provided for @startTuningButton.
  ///
  /// In en, this message translates to:
  /// **'Start tuning'**
  String get startTuningButton;

  /// No description provided for @stopTuningButton.
  ///
  /// In en, this message translates to:
  /// **'Stop tuning'**
  String get stopTuningButton;

  /// Tooltip and title for the About screen
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @aboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About CrispTuner'**
  String get aboutTitle;

  /// No description provided for @aboutTagline.
  ///
  /// In en, this message translates to:
  /// **'Chromatic tuner with historical temperaments'**
  String get aboutTagline;

  /// No description provided for @aboutServiceProvider.
  ///
  /// In en, this message translates to:
  /// **'Service Provider'**
  String get aboutServiceProvider;

  /// No description provided for @aboutLicense.
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get aboutLicense;

  /// No description provided for @aboutLicenseBody.
  ///
  /// In en, this message translates to:
  /// **'CrispTuner is licensed under the MIT License.\n\nYou are free to use, modify and distribute this software for any purpose, including commercial use.'**
  String get aboutLicenseBody;

  /// No description provided for @aboutComponents.
  ///
  /// In en, this message translates to:
  /// **'Open Source Components'**
  String get aboutComponents;

  /// No description provided for @aboutComponentsIntro.
  ///
  /// In en, this message translates to:
  /// **'CrispTuner is built on these open source packages. The full license texts are available under “Open Source Licenses” below.'**
  String get aboutComponentsIntro;

  /// No description provided for @aboutHowItWorks.
  ///
  /// In en, this message translates to:
  /// **'How It Works'**
  String get aboutHowItWorks;

  /// No description provided for @aboutHowItWorksBody.
  ///
  /// In en, this message translates to:
  /// **'Microphone audio is captured as 16-bit PCM at 44.1 kHz and accumulated into a 4096-sample window. That window is analysed with the YIN algorithm to estimate pitch, then passed through a 5-sample median filter so the reading stays steady. The width matters: YIN can only resolve frequencies above twice the sample rate divided by the window, so a narrower window would not reach the low B of a five-string bass at 30.9 Hz.\n\nThe result is matched to the nearest note by its position on a logarithmic pitch scale, against targets computed for your concert pitch and temperament, and the deviation is shown in cents. Each temperament is derived from the sizes of the twelve fifths that define it rather than from a table of published cent values, and is then anchored so that A sounds exactly where you set it.\n\nIn parallel a Hann-windowed FFT over the most recent 2048 samples drives the spectrum display.'**
  String get aboutHowItWorksBody;

  /// No description provided for @aboutPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get aboutPrivacy;

  /// No description provided for @aboutPrivacyBody.
  ///
  /// In en, this message translates to:
  /// **'Short version: CrispTuner collects nothing about you.\n\nMicrophone audio is analysed in real time on your device and is never recorded, stored or transmitted. There are no accounts, no analytics, no advertising and no tracking, and the app makes no network requests at all.\n\nOnly your settings — concert pitch, instrument, selected tuning, your custom tuning, and your temperament and its key — are saved, locally, so they persist between launches. They are removed when you uninstall the app.'**
  String get aboutPrivacyBody;

  /// No description provided for @aboutPrivacyPolicyLink.
  ///
  /// In en, this message translates to:
  /// **'Read the full privacy policy'**
  String get aboutPrivacyPolicyLink;

  /// No description provided for @aboutDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'Disclaimer'**
  String get aboutDisclaimer;

  /// No description provided for @aboutDisclaimerBody.
  ///
  /// In en, this message translates to:
  /// **'This software is provided “as is”, without warranty of any kind. The authors are not liable for any damages arising from the use of this software.'**
  String get aboutDisclaimerBody;

  /// No description provided for @aboutSourceCode.
  ///
  /// In en, this message translates to:
  /// **'Source Code'**
  String get aboutSourceCode;

  /// No description provided for @aboutContributions.
  ///
  /// In en, this message translates to:
  /// **'Contributions welcome. Please open an issue first for major changes.'**
  String get aboutContributions;

  /// No description provided for @aboutOpenSourceLicenses.
  ///
  /// In en, this message translates to:
  /// **'Open Source Licenses'**
  String get aboutOpenSourceLicenses;

  /// No description provided for @aboutCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get aboutCopied;

  /// Accessibility label for a chart
  ///
  /// In en, this message translates to:
  /// **'{label} visualization'**
  String visualizationLabel(String label);

  /// No description provided for @instrumentGuitar7.
  ///
  /// In en, this message translates to:
  /// **'7-string guitar'**
  String get instrumentGuitar7;

  /// No description provided for @instrumentBass5.
  ///
  /// In en, this message translates to:
  /// **'5-string bass'**
  String get instrumentBass5;

  /// No description provided for @instrumentViola.
  ///
  /// In en, this message translates to:
  /// **'Viola'**
  String get instrumentViola;

  /// No description provided for @instrumentDoubleBass.
  ///
  /// In en, this message translates to:
  /// **'Double bass'**
  String get instrumentDoubleBass;

  /// No description provided for @instrumentBanjo.
  ///
  /// In en, this message translates to:
  /// **'Banjo'**
  String get instrumentBanjo;

  /// No description provided for @instrumentLabel.
  ///
  /// In en, this message translates to:
  /// **'Instrument'**
  String get instrumentLabel;

  /// No description provided for @tuningLabel.
  ///
  /// In en, this message translates to:
  /// **'Tuning'**
  String get tuningLabel;

  /// No description provided for @tuningStandard.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get tuningStandard;

  /// No description provided for @tuningHalfStepDown.
  ///
  /// In en, this message translates to:
  /// **'Half step down'**
  String get tuningHalfStepDown;

  /// No description provided for @tuningWholeStepDown.
  ///
  /// In en, this message translates to:
  /// **'Whole step down'**
  String get tuningWholeStepDown;

  /// No description provided for @tuningLowG.
  ///
  /// In en, this message translates to:
  /// **'Low G'**
  String get tuningLowG;

  /// No description provided for @tuningBaritone.
  ///
  /// In en, this message translates to:
  /// **'Baritone'**
  String get tuningBaritone;

  /// No description provided for @tuningDTuning.
  ///
  /// In en, this message translates to:
  /// **'D tuning'**
  String get tuningDTuning;

  /// No description provided for @tuningSolo.
  ///
  /// In en, this message translates to:
  /// **'Solo tuning'**
  String get tuningSolo;

  /// No description provided for @tuningTenor.
  ///
  /// In en, this message translates to:
  /// **'Tenor'**
  String get tuningTenor;

  /// No description provided for @tuningOctave.
  ///
  /// In en, this message translates to:
  /// **'Octave'**
  String get tuningOctave;

  /// No description provided for @tuningCrossAEAE.
  ///
  /// In en, this message translates to:
  /// **'Cross-tuning AEAE'**
  String get tuningCrossAEAE;

  /// No description provided for @tuningCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get tuningCustom;

  /// No description provided for @temperamentLabel.
  ///
  /// In en, this message translates to:
  /// **'Temperament'**
  String get temperamentLabel;

  /// No description provided for @temperamentKey.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get temperamentKey;

  /// No description provided for @temperamentEqual.
  ///
  /// In en, this message translates to:
  /// **'Equal'**
  String get temperamentEqual;

  /// No description provided for @temperamentPythagorean.
  ///
  /// In en, this message translates to:
  /// **'Pythagorean'**
  String get temperamentPythagorean;

  /// No description provided for @temperamentMeantone.
  ///
  /// In en, this message translates to:
  /// **'1/4-comma meantone'**
  String get temperamentMeantone;

  /// No description provided for @temperamentWerckmeister.
  ///
  /// In en, this message translates to:
  /// **'Werckmeister III'**
  String get temperamentWerckmeister;

  /// No description provided for @temperamentKirnberger.
  ///
  /// In en, this message translates to:
  /// **'Kirnberger III'**
  String get temperamentKirnberger;

  /// No description provided for @temperamentVallotti.
  ///
  /// In en, this message translates to:
  /// **'Vallotti'**
  String get temperamentVallotti;

  /// No description provided for @editCustomTuning.
  ///
  /// In en, this message translates to:
  /// **'Edit custom tuning'**
  String get editCustomTuning;

  /// No description provided for @customTuningTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom tuning'**
  String get customTuningTitle;

  /// No description provided for @addString.
  ///
  /// In en, this message translates to:
  /// **'Add string'**
  String get addString;

  /// No description provided for @removeString.
  ///
  /// In en, this message translates to:
  /// **'Remove string'**
  String get removeString;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @resetTuning.
  ///
  /// In en, this message translates to:
  /// **'Reset to standard'**
  String get resetTuning;

  /// Accessibility label for one string row in the custom tuning editor
  ///
  /// In en, this message translates to:
  /// **'String {n}'**
  String stringNumber(String n);

  /// Accessibility label for the raise-pitch button
  ///
  /// In en, this message translates to:
  /// **'Raise {note} a semitone'**
  String raiseSemitone(String note);

  /// Accessibility label for the lower-pitch button
  ///
  /// In en, this message translates to:
  /// **'Lower {note} a semitone'**
  String lowerSemitone(String note);

  /// Readout showing how far the current note sits from equal temperament
  ///
  /// In en, this message translates to:
  /// **'{note} {cents} ¢ vs equal'**
  String temperamentOffset(String note, String cents);

  /// Label for the setting that chooses which pitch-detection algorithm runs
  ///
  /// In en, this message translates to:
  /// **'Pitch detector'**
  String get detectorLabel;

  /// Name of the default pitch detector
  ///
  /// In en, this message translates to:
  /// **'YIN (recommended)'**
  String get detectorYin;

  /// Name of the alternative pitch detector, which reports on more frames but is wrong more often
  ///
  /// In en, this message translates to:
  /// **'MPM (more sensitive)'**
  String get detectorMpm;

  /// Name of the third pitch detector option, a spectral estimator that is measurably less accurate than YIN
  ///
  /// In en, this message translates to:
  /// **'SWIPE′ (experimental)'**
  String get detectorSwipe;

  /// Title of the panel that lists every note currently detected, as opposed to the single note the tuner shows
  ///
  /// In en, this message translates to:
  /// **'Chord transcription'**
  String get transcriptionTitle;

  /// Label of the switch that turns polyphonic note detection on
  ///
  /// In en, this message translates to:
  /// **'Detect chords'**
  String get transcriptionEnable;

  /// Shown in the transcription panel while it has not yet detected anything
  ///
  /// In en, this message translates to:
  /// **'Listening for notes…'**
  String get transcriptionListening;

  /// Shown instead of the chord transcription panel on the web, where the model cannot run fast enough
  ///
  /// In en, this message translates to:
  /// **'Not available in the browser'**
  String get transcriptionUnsupported;

  /// Warning that the chord detector is not accurate enough in cents to tune with
  ///
  /// In en, this message translates to:
  /// **'Names notes only — use the meter above to tune'**
  String get transcriptionNotForTuning;

  /// Label for the setting that re-measures each detected pitch for higher precision and a less jittery needle
  ///
  /// In en, this message translates to:
  /// **'Steadier reading'**
  String get refinementLabel;

  /// One-line explanation of the steadier-reading setting
  ///
  /// In en, this message translates to:
  /// **'Re-measures every reading for a steadier, more precise needle. Costs a little more processing.'**
  String get refinementDescription;

  /// Label for the setting that chooses which note-transcription model runs
  ///
  /// In en, this message translates to:
  /// **'Transcription model'**
  String get transcriptionModelLabel;

  /// The default transcription model, which ships with the app and needs no download
  ///
  /// In en, this message translates to:
  /// **'Built-in — no download'**
  String get transcriptionModelBuiltIn;

  /// How much a transcription model weighs; it is fetched over the network the first time it is used
  ///
  /// In en, this message translates to:
  /// **'{size} MB download'**
  String transcriptionModelDownloadSize(String size);

  /// One line saying what the Basic Pitch model is good at
  ///
  /// In en, this message translates to:
  /// **'The built-in model, run by the native engine — for comparing the two runtimes'**
  String get transcriptionModelAboutBasicPitch;

  /// One line saying what the piano-transcription model is good at
  ///
  /// In en, this message translates to:
  /// **'Piano, in detail — the heaviest of the five to run'**
  String get transcriptionModelAboutPiano;

  /// One line saying what the MT3 model is good at
  ///
  /// In en, this message translates to:
  /// **'Best on real music, and the only one that names the instrument'**
  String get transcriptionModelAboutMt3;

  /// One line saying what the Onsets and Frames model is good at
  ///
  /// In en, this message translates to:
  /// **'Piano, and the best balance of accuracy, size and speed'**
  String get transcriptionModelAboutOnsetsAndFrames;

  /// One line saying what the hFT-Transformer model is good at, including that it cannot keep up in real time
  ///
  /// In en, this message translates to:
  /// **'Most accurate on piano, and the smallest — but too slow to follow live playing'**
  String get transcriptionModelAboutHft;

  /// Warning shown when the selected transcription model cannot keep up with live audio
  ///
  /// In en, this message translates to:
  /// **'Too slow to follow live playing on this kind of processor: it needs about {factor}× as long as the music lasts.'**
  String transcriptionModelOfflineOnly(String factor);

  /// Shown under the disabled model picker when the environment has already chosen the backend
  ///
  /// In en, this message translates to:
  /// **'Chosen by the CRISPTUNER_TRANSCRIPTION_BACKEND environment variable, which overrides this setting.'**
  String get transcriptionModelEnvOverride;

  /// Shown when a transcription model cannot be used because the native library is absent
  ///
  /// In en, this message translates to:
  /// **'This model needs the CrispASR engine, which this installation does not have.'**
  String get transcriptionLibraryMissing;

  /// Shown when the model file is neither cached nor downloadable
  ///
  /// In en, this message translates to:
  /// **'That model is not on this device yet and could not be downloaded. Check the connection and try again.'**
  String get transcriptionModelMissing;

  /// Honesty note under the model picker: no measurement in this project comes from a phone
  ///
  /// In en, this message translates to:
  /// **'Sizes and speeds measured on a desktop processor, not on a phone.'**
  String get transcriptionModelMeasurementNote;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
