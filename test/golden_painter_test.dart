import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/main.dart';

/// Golden tests for FFTPainter and PitchHistoryPainter.
///
/// Run with: flutter test --update-goldens test/golden_painter_test.dart
/// Then verify the generated images in test/goldens/ visually.
void main() {
  group('FFTPainter golden tests', () {
    testWidgets('renders bar chart for known FFT data', (tester) async {
      // Simulated FFT magnitudes — a peak around bin 20 (≈440 Hz)
      final fftData = List<double>.generate(64, (i) {
        return math.exp(-0.5 * math.pow((i - 20) / 3.0, 2)) * 100;
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                child: Container(
                  width: 300,
                  height: 150,
                  color: const Color(0xFF0A0A0A),
                  child: CustomPaint(
                    painter: FFTPainter(fftData, Colors.greenAccent),
                    size: const Size(300, 150),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byType(RepaintBoundary),
        matchesGoldenFile('goldens/fft_painter_peak.png'),
      );
    });

    testWidgets('renders empty state', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                child: Container(
                  width: 300,
                  height: 150,
                  color: const Color(0xFF0A0A0A),
                  child: CustomPaint(
                    painter: FFTPainter([], Colors.greenAccent),
                    size: const Size(300, 150),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byType(RepaintBoundary),
        matchesGoldenFile('goldens/fft_painter_empty.png'),
      );
    });

    testWidgets('renders uniform data', (tester) async {
      final fftData = List<double>.filled(32, 50.0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                child: Container(
                  width: 300,
                  height: 150,
                  color: const Color(0xFF0A0A0A),
                  child: CustomPaint(
                    painter: FFTPainter(fftData, Colors.greenAccent),
                    size: const Size(300, 150),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byType(RepaintBoundary),
        matchesGoldenFile('goldens/fft_painter_uniform.png'),
      );
    });
  });

  group('PitchHistoryPainter golden tests', () {
    testWidgets('renders sine-wave pitch history', (tester) async {
      // Simulated cents-deviation history — a sine wave
      final pitchHistory = List<double>.generate(100, (i) {
        return 30 * math.sin(2 * math.pi * i / 25.0);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                child: Container(
                  width: 300,
                  height: 150,
                  color: const Color(0xFF0A0A0A),
                  child: CustomPaint(
                    painter: PitchHistoryPainter(pitchHistory, Colors.deepOrange),
                    size: const Size(300, 150),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byType(RepaintBoundary),
        matchesGoldenFile('goldens/pitch_history_sine.png'),
      );
    });

    testWidgets('renders flat (in-tune) history', (tester) async {
      final pitchHistory = List<double>.filled(100, 0.0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                child: Container(
                  width: 300,
                  height: 150,
                  color: const Color(0xFF0A0A0A),
                  child: CustomPaint(
                    painter: PitchHistoryPainter(pitchHistory, Colors.deepOrange),
                    size: const Size(300, 150),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byType(RepaintBoundary),
        matchesGoldenFile('goldens/pitch_history_flat.png'),
      );
    });

    testWidgets('renders single-point history (no line)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                child: Container(
                  width: 300,
                  height: 150,
                  color: const Color(0xFF0A0A0A),
                  child: CustomPaint(
                    painter: PitchHistoryPainter([10.0], Colors.deepOrange),
                    size: const Size(300, 150),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byType(RepaintBoundary),
        matchesGoldenFile('goldens/pitch_history_single.png'),
      );
    });
  });
}
