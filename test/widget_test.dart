import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/main.dart';

// Phone-sized surface to avoid overflow in widget tests
const _testSurfaceSize = Size(412, 915);

Future<void> _setUpTestSize(WidgetTester tester) async {
  tester.view.physicalSize = _testSurfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  group('TunerApp widget', () {
    testWidgets('renders with correct title', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(const TunerApp());
      expect(find.text('CrispTuner'), findsOneWidget);
    });

    testWidgets('supplies both a light and a dark theme', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(const TunerApp());
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      // A musician tuning on a dark stage should not be handed a white
      // screen, and one tuning by a window should not be handed a black one,
      // so neither theme may go missing.
      expect(materialApp.theme?.brightness, Brightness.light);
      expect(materialApp.darkTheme?.brightness, Brightness.dark);
      expect(materialApp.themeMode, ThemeMode.system);
    });

    testWidgets('hides the debug banner (App Store screenshots)', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(const TunerApp());
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.debugShowCheckedModeBanner, isFalse);
    });

    testWidgets('declares both supported locales', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(const TunerApp());
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final languages =
          materialApp.supportedLocales.map((l) => l.languageCode).toList();
      expect(languages, containsAll(<String>['en', 'de']));
    });
  });

  group('Localization', () {
    testWidgets('renders German strings under a de locale', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(const TunerApp());
      // Force the German locale through the same delegates the app ships.
      tester.platformDispatcher.localesTestValue = const [Locale('de')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpAndSettle();

      expect(find.text('Stimmen beginnen'), findsOneWidget);
      expect(find.text('Tonhöhenverlauf'), findsOneWidget);
      expect(find.text('Frequenzspektrum'), findsOneWidget);
      expect(find.text('Gitarre'), findsOneWidget);
    });

    testWidgets('falls back to English for an unsupported locale', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(const TunerApp());
      tester.platformDispatcher.localesTestValue = const [Locale('fr')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpAndSettle();

      expect(find.text('Start Tuning'), findsOneWidget);
    });
  });

  group('TunerPage widget', () {
    Widget buildApp() => const TunerApp();

    testWidgets('phone settings shortcut keeps the microphone within reach',
        (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      final mic = find.byTooltip('Start tuning');
      final settings = find.byTooltip('Settings');
      final micRect = tester.getRect(mic);
      expect(micRect.width, greaterThanOrEqualTo(56));
      expect(micRect.bottom, lessThan(64));
      // Settings sits to the right of the microphone, at the edge.
      expect(tester.getCenter(settings).dx, greaterThan(micRect.right));
      expect(tester.getTopRight(settings).dx, greaterThan(360));

      // It opens the settings over the tuner, which also works where the
      // settings panel is already on screen.
      await tester.tap(settings);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      final sheetSlider = find.descendant(
          of: find.byType(BottomSheet), matching: find.byType(Slider));
      expect(sheetSlider.hitTestable(), findsOneWidget);

      // A change in the sheet shows in the sheet straight away.
      final before = tester.widget<Slider>(sheetSlider).value;
      await tester.drag(sheetSlider, const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(sheetSlider).value, isNot(before));

      // Dismissed, the microphone is reachable where it was.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.getRect(mic), micRect);
      expect(mic.hitTestable(), findsOneWidget);
    });

    testWidgets('the settings button opens the sheet on an iPad too',
        (tester) async {
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final size in [const Size(820, 1180), const Size(1180, 820)]) {
      testWidgets('iPad settings fit in the right column at $size',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(buildApp());
        await tester.pumpAndSettle();

        final heading = tester.getTopLeft(find.text('Settings'));
        expect(heading.dx, greaterThan(size.width / 2));
        expect(heading.dy, lessThan(100));
        expect(find.byType(Slider).hitTestable(), findsOneWidget);
        expect(find.text('Steadier reading').hitTestable(), findsOneWidget);
        expect(find.text('Chord transcription').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('shows Start Tuning status initially', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.text('Start Tuning'), findsOneWidget);
    });

    testWidgets('shows microphone button', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.byIcon(Icons.mic), findsOneWidget);
    });

    testWidgets('shows frequency display at 0.00 Hz initially', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.text('0.00 Hz'), findsOneWidget);
    });

    testWidgets('shows A4 frequency label', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.text('A4: 440.0 Hz'), findsOneWidget);
    });

    testWidgets('shows Pitch History label', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.text('Pitch History'), findsOneWidget);
    });

    testWidgets('shows Frequency Spectrum label', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.text('Frequency Spectrum'), findsOneWidget);
    });

    testWidgets('renders guitar string indicators by default', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.text('E'), findsWidgets);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('D'), findsOneWidget);
      expect(find.text('G'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('renders instrument dropdown with Guitar selected', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.text('Guitar'), findsOneWidget);
    });

    testWidgets('renders play buttons for each string', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(6));
    });

    testWidgets('shows slider for A4 frequency', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('has CustomPaint widgets for visualizations', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('has an elevated button for mic control', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(buildApp());
      expect(find.byType(ElevatedButton), findsOneWidget);
    });
  });

  group('FFTPainter', () {
    test('shouldRepaint returns false for identical data', () {
      final data = [1.0, 2.0, 3.0];
      final p1 = FFTPainter(data, const Color(0xFF00FF00));
      final p2 = FFTPainter(List.of(data), const Color(0xFF00FF00));
      expect(p1.shouldRepaint(p2), isFalse);
    });

    test('shouldRepaint returns true for different data', () {
      final p1 = FFTPainter([1.0, 2.0, 3.0], const Color(0xFF00FF00));
      final p2 = FFTPainter([1.0, 2.0, 4.0], const Color(0xFF00FF00));
      expect(p1.shouldRepaint(p2), isTrue);
    });
  });

  group('PitchHistoryPainter', () {
    test('shouldRepaint returns false for identical data', () {
      final data = [0.0, 10.0, -10.0];
      final p1 = PitchHistoryPainter(data, const Color(0xFFFF5722));
      final p2 = PitchHistoryPainter(List.of(data), const Color(0xFFFF5722));
      expect(p1.shouldRepaint(p2), isFalse);
    });

    test('shouldRepaint returns true for different data', () {
      final p1 = PitchHistoryPainter([0.0, 10.0], const Color(0xFFFF5722));
      final p2 = PitchHistoryPainter([0.0, 20.0], const Color(0xFFFF5722));
      expect(p1.shouldRepaint(p2), isTrue);
    });
  });
}
