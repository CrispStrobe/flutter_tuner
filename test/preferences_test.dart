import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tuner/main.dart';

/// The app persists the concert pitch and instrument, and restoring them is
/// easy to break silently — nothing else in the UI would look wrong.
void main() {
  testWidgets('restores a saved A4 frequency and instrument on launch',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.a4_frequency': 432.0,
      'flutter.instrument_name': 'ukulele',
    });
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const TunerApp());
    await tester.pumpAndSettle();

    expect(find.text('A4: 432.0 Hz'), findsOneWidget);
    expect(find.text('Ukulele'), findsOneWidget);
    // Ukulele is a four-string instrument, so the guitar's six indicators
    // must have been replaced.
    expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(4));
  });

  testWidgets('falls back to defaults when nothing is stored', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const TunerApp());
    await tester.pumpAndSettle();

    expect(find.text('A4: 440.0 Hz'), findsOneWidget);
    expect(find.text('Guitar'), findsOneWidget);
  });

  testWidgets('migrates the pre-2.2 integer instrument preference',
      (tester) async {
    // 2.1.1 stored the instrument as an index into an enum that read
    // [guitar, cello, bass, violin, ukulele, mandolin]. Index 4 was the
    // ukulele then; in today's enum index 4 is something else entirely, and
    // asking for the key as a String would throw outright.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.a4_frequency': 440.0,
      'flutter.instrument': 4,
    });
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const TunerApp());
    await tester.pumpAndSettle();

    expect(find.text('Ukulele'), findsOneWidget);
  });

  testWidgets('migrates a pre-2.2 cello preference to the reordered enum',
      (tester) async {
    // Index 1 was the cello, which now sits at a different position.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.instrument': 1,
    });
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const TunerApp());
    await tester.pumpAndSettle();

    expect(find.text('Cello'), findsOneWidget);
  });
}
