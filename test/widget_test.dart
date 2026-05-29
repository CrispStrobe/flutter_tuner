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
      expect(find.text('Flutter Pro Tuner'), findsOneWidget);
    });

    testWidgets('has dark theme', (tester) async {
      await _setUpTestSize(tester);
      await tester.pumpWidget(const TunerApp());
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.theme?.brightness, Brightness.dark);
    });
  });

  group('TunerPage widget', () {
    Widget buildApp() => const TunerApp();

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
