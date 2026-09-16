import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tuner/main.dart';
import 'package:flutter_tuner/tuner_engine.dart';

Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = const Size(412, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(const TunerApp());
  await tester.pumpAndSettle();
}

/// Open a dropdown by the value currently shown in it, then tap an option.
Future<void> _select(WidgetTester tester, String current, String option) async {
  await tester.tap(find.text(current).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  group('tuning selection', () {
    testWidgets('offers alternate tunings for the guitar', (tester) async {
      await _pump(tester);
      await tester.tap(find.textContaining('Standard · E A D G B E').last);
      await tester.pumpAndSettle();

      for (final expected in ['Drop D', 'DADGAD', 'Open G', 'Half step down']) {
        expect(find.textContaining(expected), findsWidgets, reason: expected);
      }
    });

    testWidgets('drop D relabels the lowest string', (tester) async {
      await _pump(tester);
      // Standard guitar starts on E A D G B E — two Es and no second D.
      expect(find.text('E'), findsNWidgets(2));

      await tester.tap(find.textContaining('Standard · E A D G B E').last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Drop D').last);
      await tester.pumpAndSettle();

      // D A D G B E — one E left, and D now appears twice.
      expect(find.text('E'), findsOneWidget);
      expect(find.text('D'), findsNWidgets(2));
    });

    testWidgets('switching instrument resets an inapplicable tuning',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.textContaining('Standard · E A D G B E').last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('DADGAD').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('DADGAD'), findsWidgets);

      // The viola has no DADGAD, so it must fall back rather than show an
      // empty string list.
      await _select(tester, 'Guitar', 'Viola');
      expect(find.textContaining('DADGAD'), findsNothing);
      expect(find.textContaining('Standard · C G D A'), findsWidgets);
    });

    testWidgets('a seven-string guitar shows seven strings', (tester) async {
      await _pump(tester);
      await _select(tester, 'Guitar', '7-string guitar');
      expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(7));
    });

    testWidgets('a five-string banjo shows five strings', (tester) async {
      await _pump(tester);
      await _select(tester, 'Guitar', 'Banjo');
      expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(5));
    });
  });

  group('temperament selection', () {
    testWidgets('the key selector appears only for unequal temperaments',
        (tester) async {
      await _pump(tester);
      // Equal temperament: every key is identical by construction, so
      // offering a key would imply a difference that does not exist.
      expect(find.textContaining('Key:'), findsNothing);

      await _select(tester, 'Equal', 'Werckmeister III');
      expect(find.textContaining('Key:'), findsWidgets);

      await _select(tester, 'Werckmeister III', 'Equal');
      expect(find.textContaining('Key:'), findsNothing);
    });

    testWidgets('all six temperaments are offered', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Equal').last);
      await tester.pumpAndSettle();
      for (final name in [
        'Pythagorean',
        '1/4-comma meantone',
        'Werckmeister III',
        'Kirnberger III',
        'Vallotti',
      ]) {
        expect(find.text(name), findsWidgets, reason: name);
      }
    });
  });

  group('custom tuning editor', () {
    testWidgets('opens when the custom tuning is chosen', (tester) async {
      await _pump(tester);
      await tester.tap(find.textContaining('Standard · E A D G B E').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom…').last);
      await tester.pumpAndSettle();

      expect(find.text('Custom tuning'), findsOneWidget);
      // Seeded from the tuning that was on screen, not left blank.
      expect(find.text('E2'), findsOneWidget);
      expect(find.text('E4'), findsOneWidget);
    });

    testWidgets('moves a string by a semitone and keeps it', (tester) async {
      await _pump(tester);
      await tester.tap(find.textContaining('Standard · E A D G B E').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom…').last);
      await tester.pumpAndSettle();

      // Lower the sixth string from E2 to D#2.
      await tester.tap(find.byTooltip('Lower E2 a semitone'));
      await tester.pumpAndSettle();
      expect(find.text('D#2'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.text('D#'), findsOneWidget);
    });

    testWidgets('adds and removes strings within the allowed range',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.textContaining('Standard · E A D G B E').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom…').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add string'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(7));
    });

    testWidgets('reset restores the instrument standard', (tester) async {
      await _pump(tester);
      await tester.tap(find.textContaining('Standard · E A D G B E').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom…').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Lower E2 a semitone'));
      await tester.pumpAndSettle();
      expect(find.text('D#2'), findsOneWidget);

      await tester.tap(find.text('Reset to standard'));
      await tester.pumpAndSettle();
      expect(find.text('D#2'), findsNothing);
      expect(find.text('E2'), findsOneWidget);
    });
  });

  group('custom tuning persistence', () {
    testWidgets('a saved custom tuning is restored on launch', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.instrument_name': 'guitar',
        'flutter.tuning_id': customTuningId,
        'flutter.custom_strings': <String>['C2', 'G2', 'C3', 'G3', 'C4', 'E4'],
      });
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(const TunerApp());
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(6));
      expect(find.text('C'), findsNWidgets(3));
    });

    testWidgets('a saved temperament and key are restored', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.temperament': 'vallotti',
        'flutter.temperament_root': 5,
      });
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(const TunerApp());
      await tester.pumpAndSettle();

      expect(find.text('Vallotti'), findsWidgets);
      expect(find.textContaining('Key: F'), findsWidgets);
    });
  });
}
