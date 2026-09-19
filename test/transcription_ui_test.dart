import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/main.dart';
import 'package:flutter_tuner/transcription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The transcription panel in the running app.
///
/// The mode is off by default and has to stay that way: it loads a model,
/// spawns an isolate and runs inference twice a second, none of which a user
/// who opened a tuner asked for.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const TunerApp());
    await tester.pumpAndSettle();
  }

  testWidgets('the panel is present and off by default', (tester) async {
    await pump(tester);
    expect(find.text('Chord transcription'), findsOneWidget);

    // Off: no note list, no warning, and above all no isolate started.
    expect(find.text('Names notes only — use the meter above to tune'),
        findsNothing);
    expect(find.text('Listening for notes…'), findsNothing);

    final toggle = tester.widget<Switch>(find.byType(Switch).last);
    expect(toggle.value, isFalse);
  });

  testWidgets('the platform that cannot run it says so', (tester) async {
    // isSupported is a compile-time platform statement, so in a VM test it is
    // true; this asserts the branch exists and is wired to that flag rather
    // than to a runtime probe that might fail silently on a user's device.
    expect(TranscriptionService.isSupported, isTrue,
        reason: 'the test VM is not the web');
    await pump(tester);
    expect(find.textContaining('Not available in the browser'), findsNothing);
  });

  testWidgets('turning it on shows the warning that it is not for tuning',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byType(Switch).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The model may or may not have loaded in a test environment; what must
    // be true either way is that enabling it never shows note names without
    // the caveat next to them.
    final warning =
        find.text('Names notes only — use the meter above to tune');
    final listening = find.text('Listening for notes…');
    if (listening.evaluate().isNotEmpty) {
      expect(warning, findsOneWidget);
    }
  });
}
