import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tuner/main.dart';

import 'support/fake_audio.dart';

/// End to end: synthesised audio in, what the player sees out — through the
/// real rolling window, YIN, median filter and tempered note search.
void main() {
  Future<void> listenTo(WidgetTester tester, double hz,
      {Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = const Size(412, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final mic = FakeAudioService(frequency: hz);
    await tester.pumpWidget(
        TunerApp(audioService: mic, toneGenerator: SilentToneGenerator()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ElevatedButton));
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  /// The large note name is the only 72-point text on screen.
  String? shownNote(WidgetTester tester) {
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      if ((text.style?.fontSize ?? 0) >= 72) return text.data;
    }
    return null;
  }

  testWidgets('an in-tune A2 reads as A, in tune', (tester) async {
    await listenTo(tester, 110.0);
    expect(shownNote(tester), 'A');
    expect(find.text('In Tune ✓'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a flat string reads as flat', (tester) async {
    await listenTo(tester, 110.0 * 0.985); // about 26 cents flat
    expect(shownNote(tester), 'A');
    expect(find.text('Too Flat ↓'), findsOneWidget);
    await stop(tester);
  });

  testWidgets("a bass guitar's open low E reads as E, not F", (tester) async {
    // The bug 2.2.0 fixed: a 2048-sample YIN window cannot represent anything
    // below 43.07 Hz, so 41.20 Hz came out as F1.
    await listenTo(tester, 41.2034,
        prefs: {'flutter.instrument_name': 'bass'});
    expect(shownNote(tester), 'E');
    await stop(tester);
  });

  testWidgets('a five-string bass low B is detected at all', (tester) async {
    await listenTo(tester, 30.8677,
        prefs: {'flutter.instrument_name': 'bass5'});
    expect(shownNote(tester), 'B');
    await stop(tester);
  });
}
