import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/main.dart';

/// Golden tests for FFTPainter and PitchHistoryPainter.
///
/// Run with: flutter test --update-goldens test/golden_painter_test.dart
/// Then verify the generated images in test/goldens/ visually.
void main() {
  Widget buildPainterWidget(CustomPainter painter, {Key? key}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: Container(
              width: 300,
              height: 150,
              color: const Color(0xFF0A0A0A),
              child: CustomPaint(
                painter: painter,
                size: const Size(300, 150),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('FFTPainter golden tests', () {
    testWidgets('renders bar chart for known FFT data', (tester) async {
      final key = UniqueKey();
      final fftData = List<double>.generate(64, (i) {
        return math.exp(-0.5 * math.pow((i - 20) / 3.0, 2)) * 100;
      });

      await tester.pumpWidget(
        buildPainterWidget(FFTPainter(fftData, Colors.greenAccent), key: key),
      );

      await expectLater(
        find.byKey(key),
        matchesGoldenFile('goldens/fft_painter_peak.png'),
      );
    });

    testWidgets('renders empty state', (tester) async {
      final key = UniqueKey();
      await tester.pumpWidget(
        buildPainterWidget(FFTPainter([], Colors.greenAccent), key: key),
      );

      await expectLater(
        find.byKey(key),
        matchesGoldenFile('goldens/fft_painter_empty.png'),
      );
    });

    testWidgets('renders uniform data', (tester) async {
      final key = UniqueKey();
      final fftData = List<double>.filled(32, 50.0);

      await tester.pumpWidget(
        buildPainterWidget(FFTPainter(fftData, Colors.greenAccent), key: key),
      );

      await expectLater(
        find.byKey(key),
        matchesGoldenFile('goldens/fft_painter_uniform.png'),
      );
    });
  });

  group('PitchHistoryPainter golden tests', () {
    testWidgets('renders sine-wave pitch history', (tester) async {
      final key = UniqueKey();
      final pitchHistory = List<double>.generate(100, (i) {
        return 30 * math.sin(2 * math.pi * i / 25.0);
      });

      await tester.pumpWidget(
        buildPainterWidget(PitchHistoryPainter(pitchHistory, Colors.deepOrange), key: key),
      );

      await expectLater(
        find.byKey(key),
        matchesGoldenFile('goldens/pitch_history_sine.png'),
      );
    });

    testWidgets('renders flat (in-tune) history', (tester) async {
      final key = UniqueKey();
      final pitchHistory = List<double>.filled(100, 0.0);

      await tester.pumpWidget(
        buildPainterWidget(PitchHistoryPainter(pitchHistory, Colors.deepOrange), key: key),
      );

      await expectLater(
        find.byKey(key),
        matchesGoldenFile('goldens/pitch_history_flat.png'),
      );
    });

    testWidgets('renders single-point history (no line)', (tester) async {
      final key = UniqueKey();
      await tester.pumpWidget(
        buildPainterWidget(PitchHistoryPainter([10.0], Colors.deepOrange), key: key),
      );

      await expectLater(
        find.byKey(key),
        matchesGoldenFile('goldens/pitch_history_single.png'),
      );
    });
  });
}
