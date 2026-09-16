// Tagged `golden` as well as `preview`: these are host-renderer specific like
// any golden, and CI's Linux job runs `flutter test -x golden`, which would
// otherwise run them against macOS-recorded PNGs and fail.
@Tags(<String>['golden', 'preview'])
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tuner/main.dart';

/// Renders the app to PNGs so the UI can be eyeballed without a device.
/// Not part of the normal suite — run with `flutter test -t preview
/// --update-goldens`.
void main() {
  // The recorder plugin has no implementation under `flutter test`, and
  // pumpAndSettle waits long enough for its MissingPluginException to
  // surface. Stub the channel so these previews exercise layout, not plugins.
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async => null,
    );
  });

  Future<void> shoot(WidgetTester tester, String name, Size size,
      {Map<String, Object>? prefs, Brightness brightness = Brightness.light}) async {
    SharedPreferences.setMockInitialValues(prefs ?? <String, Object>{});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(const TunerApp());
    await tester.pumpAndSettle();
    await expectLater(find.byType(TunerApp),
        matchesGoldenFile('goldens/preview/$name.png'));
  }

  testWidgets('phone light', (t) async {
    await shoot(t, 'phone_light', const Size(412, 900));
  });

  testWidgets('phone dark', (t) async {
    await shoot(t, 'phone_dark', const Size(412, 900),
        brightness: Brightness.dark);
  });

  testWidgets('phone with a temperament and drop D', (t) async {
    await shoot(t, 'phone_temperament', const Size(412, 980), prefs: {
      'flutter.instrument_name': 'guitar',
      'flutter.tuning_id': 'dropD',
      'flutter.temperament': 'werckmeisterIII',
      'flutter.temperament_root': 0,
      'flutter.a4_frequency': 415.0,
    });
  });

  testWidgets('tablet', (t) async {
    await shoot(t, 'tablet', const Size(1024, 800), prefs: {
      'flutter.instrument_name': 'banjo',
    });
  });
}
