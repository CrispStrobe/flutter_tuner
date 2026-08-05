import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_tuner/main.dart' as app;
import 'package:flutter_tuner/tuner_engine.dart';

/// Drives the real app to each screen worth photographing and *holds* it, so a
/// host script can grab native pixels with `xcrun simctl io … screenshot`.
///
/// There is no way to inject taps into a running Simulator from outside — no
/// `simctl tap`, and AppleScript cannot see inside the rendered iOS canvas. So
/// navigation has to happen from within the Flutter engine, which is what
/// `WidgetTester` gives us.
///
/// Run with:
///   flutter test integration_test/screenshots_test.dart -d <simulator-udid>
/// while `tool/capture_screenshots.sh` watches the log for SHOT_MARKER lines.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Holds the current frame for [seconds], pumping in small fixed steps.
  ///
  /// Deliberately NOT `pumpAndSettle`: the mic button's glow and the note
  /// AnimatedSwitcher mean a settle can hang, and we want the screen to stay
  /// put while the host grabs it anyway.
  Future<void> hold(WidgetTester tester, String name, {int seconds = 6}) async {
    debugPrint('SHOT_MARKER $name');
    for (int i = 0; i < seconds * 1000 ~/ 150; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  testWidgets('capture App Store screenshots', (tester) async {
    app.main();
    await tester.pump(const Duration(seconds: 2));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    // 1 — the main tuning screen, as it looks on launch.
    await hold(tester, 'main');

    // 2 — instrument picker open, showing all six presets.
    final dropdown = find.byType(DropdownButtonFormField<Instrument>);
    if (dropdown.evaluate().isNotEmpty) {
      await tester.tap(dropdown.first);
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      await hold(tester, 'instruments');

      // Pick Ukulele so the next shot differs from the first (4 strings, not 6).
      final ukulele = find.text('Ukulele').last;
      if (ukulele.evaluate().isNotEmpty) {
        await tester.tap(ukulele);
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        await hold(tester, 'ukulele');
      }
    }

    // 3 — the About screen: licences, privacy stance and imprint.
    final info = find.byIcon(Icons.info_outline);
    if (info.evaluate().isNotEmpty) {
      await tester.tap(info.first);
      for (int i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      await hold(tester, 'about');
    }

    debugPrint('SHOT_MARKER done');
  });
}
