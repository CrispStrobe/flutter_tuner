import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_tuner/main.dart' as app;

/// Captures App Store screenshots from a booted simulator.
///
/// The shots deliberately show what distinguishes this tuner — the tuning
/// catalogue, the custom tuning editor and the historical temperaments —
/// rather than five views of the same idle needle.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const prefix = String.fromEnvironment('SHOT_PREFIX', defaultValue: 'shot');
  const shotDir = String.fromEnvironment('SHOT_DIR');
  const shotRatio = int.fromEnvironment('SHOT_RATIO', defaultValue: 2);
  const shotLocale = String.fromEnvironment('SHOT_LOCALE', defaultValue: '');

  Future<void> hold(WidgetTester tester, {int ms = 1600}) async {
    for (var t = 0; t < ms; t += 150) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> writeLayerPng(WidgetTester tester, String file) async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final image = await layer.toImage(
      view.paintBounds,
      pixelRatio: shotRatio.toDouble(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return;

    Directory dir;
    try {
      dir = Directory(shotDir)..createSync(recursive: true);
    } on FileSystemException {
      dir = Directory('${Directory.systemTemp.path}/tuner-shots')
        ..createSync(recursive: true);
    }
    final f = File('${dir.path}/$file.png');
    await f.writeAsBytes(data.buffer.asUint8List());
    // ignore: avoid_print
    print('SHOT ${f.path} ${image.width}x${image.height}');
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await hold(tester);
    if (shotDir.isNotEmpty) {
      await writeLayerPng(tester, '${prefix}_$name');
    } else {
      try {
        await writeLayerPng(tester, '${prefix}_$name');
      } catch (_) {
        await binding.takeScreenshot('${prefix}_$name');
      }
    }
  }

  /// Open the dropdown currently showing [current] and choose the option whose
  /// label starts with [option].
  ///
  /// Every step is best-effort: a capture run that cannot find one control
  /// should still produce the other shots rather than abort with nothing.
  Future<bool> pick(WidgetTester tester, String current, String option) async {
    final field = find.textContaining(current);
    if (field.evaluate().isEmpty) return false;
    await tester.tap(field.last, warnIfMissed: false);
    await hold(tester, ms: 900);
    final choice = find.textContaining(option);
    if (choice.evaluate().isEmpty) {
      await tester.tapAt(const Offset(10, 10));
      await hold(tester, ms: 600);
      return false;
    }
    await tester.tap(choice.last, warnIfMissed: false);
    await hold(tester, ms: 900);
    return true;
  }

  testWidgets('capture store screenshots', (tester) async {
    // The workflow asks for a language; without this the shots simply follow
    // whatever language the simulator happens to boot in, and the German set
    // came out in English.
    if (shotLocale.isNotEmpty) {
      tester.platformDispatcher.localeTestValue = Locale(shotLocale);
      tester.platformDispatcher.localesTestValue = <Locale>[Locale(shotLocale)];
    }

    app.main();
    await hold(tester, ms: 1800);

    // 1) Home, as it opens.
    await shot(tester, '01_home');

    // 2) The tuning catalogue, open.
    final tuningField = find.textContaining('·');
    if (tuningField.evaluate().isNotEmpty) {
      await tester.tap(tuningField.last, warnIfMissed: false);
      await hold(tester, ms: 1000);
      await shot(tester, '02_tunings');
      final dadgad = find.textContaining('DADGAD');
      if (dadgad.evaluate().isNotEmpty) {
        await tester.tap(dadgad.last, warnIfMissed: false);
      } else {
        await tester.tapAt(const Offset(10, 10));
      }
      await hold(tester, ms: 900);
      await shot(tester, '03_dadgad');
    }

    // 3) A historical temperament — the thing no other tuner offers.
    const equal = shotLocale == 'de' ? 'Gleichstufig' : 'Equal';
    if (await pick(tester, equal, 'Werckmeister')) {
      await shot(tester, '04_temperament');
    }

    // 4) The custom tuning editor.
    const customLabel = shotLocale == 'de' ? 'Eigene' : 'Custom';
    if (await pick(tester, '·', customLabel)) {
      await shot(tester, '05_custom_tuning');
      final done = find.textContaining(shotLocale == 'de' ? 'Fertig' : 'Done');
      if (done.evaluate().isNotEmpty) {
        await tester.tap(done.last, warnIfMissed: false);
        await hold(tester, ms: 800);
      }
    }

    // 5) Listening.
    final mic = find.byType(ElevatedButton);
    if (mic.evaluate().isNotEmpty) {
      await tester.tap(mic.first, warnIfMissed: false);
      await hold(tester, ms: 3000);
      await shot(tester, '06_tuning');
    }
  });
}
