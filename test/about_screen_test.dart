import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/about_screen.dart';
import 'package:flutter_tuner/l10n/app_localizations.dart';
import 'package:flutter_tuner/main.dart';

const _surface = Size(412, 915);

/// The About screen is a long lazy [ListView]; a phone-sized viewport never
/// builds the lower cards, so assertions on them would fail for layout reasons
/// rather than real ones. Give these tests a tall viewport instead.
const _tallSurface = Size(500, 3200);

Future<void> _pumpAbout(WidgetTester tester, {Locale? locale}) async {
  tester.view.physicalSize = _tallSurface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const AboutScreen(),
  ));
  await tester.pump();
}

void main() {
  group('AboutScreen', () {
    testWidgets('shows the app name, tagline and legal sections', (tester) async {
      await _pumpAbout(tester);

      expect(find.text('About CrispTuner'), findsOneWidget);
      expect(find.text('CrispTuner'), findsWidgets);
      expect(find.text('Chromatic tuner with historical temperaments'), findsOneWidget);
      expect(find.text('License'), findsOneWidget);
      expect(find.text('Disclaimer'), findsOneWidget);
      expect(find.text('Privacy'), findsOneWidget);
    });

    testWidgets('carries the service-provider imprint', (tester) async {
      await _pumpAbout(tester);
      expect(find.text('Service Provider'), findsOneWidget);
      // The imprint must name a reachable contact.
      expect(
        find.textContaining('postmaster@crispstro.be', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('lists the open source components with their licences', (tester) async {
      await _pumpAbout(tester);

      expect(find.text('pitch_detector_dart'), findsOneWidget);
      expect(find.text('fftea'), findsOneWidget);
      expect(find.text('record'), findsOneWidget);
      expect(find.text('flutter_pcm_sound'), findsOneWidget);
      // The transcription mode ships a model file, which is not a pub
      // package and so is not discovered automatically — it has to be listed
      // here or its Apache-2.0 attribution appears nowhere.
      expect(find.text('Basic Pitch (model weights)'), findsOneWidget);
      expect(find.text('onnx_runtime_dart'), findsOneWidget);
      // Licence names shown next to the components. Two components are
      // Apache-2.0 now: fftea and the model weights.
      expect(find.text('Apache-2.0'), findsNWidgets(2));
      expect(find.text('Unlicense'), findsOneWidget);
      expect(find.text('BSD 3-Clause'), findsWidgets);
    });

    testWidgets('offers the full open source licence page', (tester) async {
      await _pumpAbout(tester);
      final button = find.widgetWithText(OutlinedButton, 'Open Source Licenses');
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
    });

    testWidgets('renders in German', (tester) async {
      await _pumpAbout(tester, locale: const Locale('de'));
      expect(find.text('Über CrispTuner'), findsOneWidget);
      expect(find.text('Lizenz'), findsOneWidget);
      expect(find.text('Datenschutz'), findsOneWidget);
      expect(find.text('Diensteanbieter'), findsOneWidget);
    });
  });

  group('registerAppLicenses', () {
    test('adds CrispTuner\'s own licence and the YIN citation', () async {
      // Flutter collects licences from pub packages automatically, but nothing
      // registers the application's own — this guards that regression.
      registerAppLicenses();

      final packages = <String>{};
      await for (final entry in LicenseRegistry.licenses) {
        packages.addAll(entry.packages);
      }
      expect(packages, contains('CrispTuner'));
      expect(packages, contains('YIN pitch detection algorithm'));
    });
  });

  group('app entry', () {
    testWidgets('the tuner screen exposes an About action', (tester) async {
      tester.view.physicalSize = _surface;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(const TunerApp());
      await tester.pump();

      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });
  });
}
