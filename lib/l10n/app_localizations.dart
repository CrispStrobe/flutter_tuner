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
  /// **'Precise chromatic tuner for six instruments'**
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
  /// **'Microphone audio is captured as 16-bit PCM at 44.1 kHz. Each 2048-sample block is analysed with the YIN algorithm to estimate pitch, then passed through a 5-sample median filter so the reading stays steady. The result is matched to the nearest note for your chosen concert pitch, and the deviation is shown in cents. In parallel a Hann-windowed FFT drives the spectrum display.'**
  String get aboutHowItWorksBody;

  /// No description provided for @aboutPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get aboutPrivacy;

  /// No description provided for @aboutPrivacyBody.
  ///
  /// In en, this message translates to:
  /// **'Short version: CrispTuner collects nothing about you.\n\nMicrophone audio is analysed in real time on your device and is never recorded, stored or transmitted. There are no accounts, no analytics, no advertising and no tracking, and the app makes no network requests at all.\n\nOnly your A4 reference frequency and selected instrument are saved, locally, so they persist between launches. They are removed when you uninstall the app.'**
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
