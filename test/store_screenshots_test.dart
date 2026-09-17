// Renders App Store screenshots from the real widget tree.
//
//   flutter test -t store --update-goldens test/store_screenshots_test.dart
//
// writes test/store_screenshots/{iphone,ipad}_{en,de}_NN_name.png at the exact
// sizes App Store Connect accepts. Audio comes from FakeAudioService, so every
// reading on screen is produced by the app's own detection pipeline.
//
// Tagged `preview` too, so CI's `-x preview` never runs it: these are artefacts
// to look at and upload, not assertions.
@Tags(<String>['store', 'preview'])
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tuner/main.dart';
import 'package:flutter_tuner/tuner_engine.dart';

import 'support/fake_audio.dart';

class Device {
  final String name;
  final Size logical;
  final double ratio;
  final EdgeInsets safeArea;
  final TargetPlatform platform;
  const Device(this.name, this.logical, this.ratio, this.safeArea,
      [this.platform = TargetPlatform.iOS]);
}

// iPhone 16 Pro Max: 440x956 @3x = 1320x2868. iPad Pro 13": 1032x1376 @2x.
// Mac: a 1440x900 window @2x = 2880x1800, one of the Mac App Store sizes.
const devices = [
  Device('iphone', Size(440, 956), 3, EdgeInsets.only(top: 62, bottom: 34)),
  Device('ipad', Size(1032, 1376), 2, EdgeInsets.only(top: 24, bottom: 20)),
  Device('mac', Size(1440, 900), 2, EdgeInsets.zero, TargetPlatform.macOS),
];

Future<void> loadFonts() async {
  final sf = File('/System/Library/Fonts/SFNS.ttf').readAsBytesSync();
  for (final family in const [
    'Roboto',
    '.SF UI Text',
    '.SF UI Display',
    '.SF Pro Text',
    '.SF Pro Display',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
    '.AppleSystemUIFont',
  ]) {
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(sf))))
        .load();
  }
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ?? '/opt/homebrew/share/flutter';
  final icons = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  await (FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync()))))
      .load();
}

void main() {
  setUpAll(loadFonts);

  for (final device in devices) {
    for (final lang in const ['en', 'de']) {
      final prefix = '${device.name}_$lang';

      Future<FakeAudioService> open(WidgetTester tester,
          {Map<String, Object> prefs = const {},
          Brightness brightness = Brightness.light}) async {
        SharedPreferences.setMockInitialValues(prefs);
        debugDefaultTargetPlatformOverride = device.platform;
        tester.view.physicalSize = device.logical * device.ratio;
        tester.view.devicePixelRatio = device.ratio;
        final pad = FakeViewPadding(
          top: device.safeArea.top * device.ratio,
          bottom: device.safeArea.bottom * device.ratio,
        );
        tester.view.padding = pad;
        tester.view.viewPadding = pad;
        tester.platformDispatcher.localeTestValue = Locale(lang);
        tester.platformDispatcher.localesTestValue = [Locale(lang)];
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(() {
          tester.view.reset();
          tester.platformDispatcher.clearAllTestValues();
        });

        final mic = FakeAudioService();
        await tester.pumpWidget(
            TunerApp(audioService: mic, toneGenerator: SilentToneGenerator()));
        await tester.pumpAndSettle();
        return mic;
      }

      Future<void> play(WidgetTester tester, FakeAudioService mic, double hz) async {
        mic.frequency = hz;
        await tester.tap(find.byType(ElevatedButton));
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
      }

      Future<void> snap(WidgetTester tester, String name) async {
        await expectLater(find.byType(TunerApp),
            matchesGoldenFile('store_screenshots/${prefix}_$name.png'));
      }

      Future<void> close(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
        debugDefaultTargetPlatformOverride = null;
      }

      /// Frequency of [note] under a concert pitch and temperament, detuned.
      double pitchOf(String note,
          {double a4 = 440,
          Temperament temperament = Temperament.equal,
          double cents = 0}) {
        final table = PitchTable(
            a4Frequency: a4, temperament: TemperamentTable(temperament));
        return table.frequencyForNote(note)! * math.pow(2, cents / 1200);
      }

      testWidgets('$prefix 01 in tune', (tester) async {
        final mic = await open(tester);
        await play(tester, mic, pitchOf('A2'));
        await snap(tester, '01_in_tune');
        await close(tester);
      });

      testWidgets('$prefix 02 tunings', (tester) async {
        await open(tester);
        await tester.tap(find.textContaining('·').last);
        await tester.pumpAndSettle();
        await snap(tester, '02_tunings');
        await close(tester);
      });

      testWidgets('$prefix 03 temperament', (tester) async {
        // Quarter-comma meantone puts F# 10.3 cents below equal temperament:
        // the string reads *in tune* while the readout shows how far that is
        // from where an ordinary tuner would have put it.
        final mic = await open(tester, prefs: {
          'flutter.instrument_name': 'guitar',
          'flutter.tuning_id': 'openD',
          'flutter.temperament': 'quarterCommaMeantone',
          'flutter.temperament_root': 0,
          'flutter.a4_frequency': 415.0,
        });
        await play(tester, mic,
            pitchOf('F#3',
                a4: 415, temperament: Temperament.quarterCommaMeantone));
        await snap(tester, '03_temperament');
        await close(tester);
      });

      testWidgets('$prefix 04 custom tuning', (tester) async {
        await open(tester, prefs: {
          'flutter.instrument_name': 'guitar',
          'flutter.tuning_id': 'openG',
        });
        await tester.tap(find.textContaining('·').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text(lang == 'de' ? 'Eigene …' : 'Custom…').last);
        await tester.pumpAndSettle();
        await snap(tester, '04_custom_tuning');
        await close(tester);
      });

      testWidgets('$prefix 05 low bass', (tester) async {
        final mic = await open(tester, prefs: {'flutter.instrument_name': 'bass5'},
            brightness: Brightness.dark);
        await play(tester, mic, pitchOf('B0', cents: 3));
        await snap(tester, '05_low_bass_dark');
        await close(tester);
      });
    }
  }
}
