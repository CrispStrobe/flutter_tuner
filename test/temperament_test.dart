import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/tuner_engine.dart';

/// The temperaments are built from their fifth sizes rather than from a table
/// of cent values, so these tests check the derivation against the published
/// figures. If the construction is ever "simplified" into a hardcoded table,
/// these are what catch a transcription slip.
void main() {
  /// Absolute cents above the root for each pitch class, C first.
  List<double> absoluteCents(Temperament t) {
    const circle = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5];
    final fifths = fifthSizes(t);
    final out = List<double>.filled(12, 0);
    double cumulative = 0;
    for (int i = 0; i < 12; i++) {
      out[circle[i]] = cumulative % 1200;
      cumulative += fifths[i];
    }
    return out;
  }

  group('fifth sizes', () {
    test('every temperament closes the circle at seven octaves', () {
      for (final t in Temperament.values) {
        final sum = fifthSizes(t).reduce((a, b) => a + b);
        expect(sum, closeTo(8400.0, 1e-9), reason: t.name);
      }
    });

    test('equal temperament is twelve 700-cent fifths', () {
      expect(fifthSizes(Temperament.equal), everyElement(closeTo(700.0, 1e-9)));
    });

    test('Pythagorean has eleven pure fifths and one wolf', () {
      final fifths = fifthSizes(Temperament.pythagorean);
      final pure = fifths.where((f) => (f - pureFifthCents).abs() < 1e-9);
      expect(pure.length, 11);
      // The wolf is a Pythagorean comma narrower than pure — 678.495.
      expect(fifths[8], closeTo(pureFifthCents - pythagoreanComma, 1e-9));
    });

    test('quarter-comma meantone has a wide wolf of about 737.6 cents', () {
      expect(fifthSizes(Temperament.quarterCommaMeantone)[8],
          closeTo(737.637, 0.001));
    });
  });

  group('published cent values', () {
    // Textbook tables, cents above C.
    const published = {
      Temperament.werckmeisterIII: [
        0, 90.225, 192.18, 294.135, 390.225, 498.045,
        588.27, 696.09, 792.18, 888.27, 996.09, 1092.18,
      ],
      Temperament.kirnbergerIII: [
        0, 90.225, 193.157, 294.135, 386.314, 498.045,
        590.224, 696.578, 792.18, 889.735, 996.09, 1088.269,
      ],
      Temperament.vallotti: [
        0, 94.135, 196.09, 298.045, 392.18, 501.955,
        592.18, 698.045, 796.09, 894.135, 1000, 1090.225,
      ],
      Temperament.quarterCommaMeantone: [
        0, 76.049, 193.157, 310.265, 386.314, 503.422,
        579.471, 696.578, 772.627, 889.735, 1006.843, 1082.892,
      ],
    };

    published.forEach((temperament, expected) {
      test('${temperament.name} matches the published table', () {
        final got = absoluteCents(temperament);
        for (int pc = 0; pc < 12; pc++) {
          expect(got[pc], closeTo(expected[pc], 0.01),
              reason: 'pitch class $pc of ${temperament.name}');
        }
      });
    });

    test('quarter-comma meantone gives a pure major third on C', () {
      // 5:4 is 386.314 cents; that purity is the whole point of the tuning.
      final third = absoluteCents(Temperament.quarterCommaMeantone)[4];
      expect(third, closeTo(1200 * math.log(1.25) / math.ln2, 0.001));
    });
  });

  group('TemperamentTable', () {
    test('equal temperament deviates nowhere', () {
      final table = TemperamentTable(Temperament.equal);
      for (int pc = 0; pc < 12; pc++) {
        expect(table.centsForPitchClass(pc), closeTo(0, 1e-9));
      }
      expect(table.isEqual, isTrue);
    });

    test('A is always the anchor, in every temperament and key', () {
      // Otherwise the concert-pitch slider would be a lie: set it to 415 Hz
      // and the A would sound somewhere else.
      for (final t in Temperament.values) {
        for (int root = 0; root < 12; root++) {
          final table = TemperamentTable(t, root: root);
          expect(table.centsForPitchClass(9), closeTo(0, 1e-9),
              reason: '${t.name} in key $root');
        }
      }
    });

    test('changing the key rotates the pattern', () {
      final onC = TemperamentTable(Temperament.werckmeisterIII, root: 0);
      final onD = TemperamentTable(Temperament.werckmeisterIII, root: 2);
      // D's deviation under the D-rooted table equals C's under the C-rooted
      // one, once both are re-anchored on A.
      final shift = onC.centsForPitchClass(0) - onD.centsForPitchClass(2);
      for (int pc = 0; pc < 12; pc++) {
        expect(onD.centsForPitchClass((pc + 2) % 12) + shift,
            closeTo(onC.centsForPitchClass(pc), 1e-9),
            reason: 'pitch class $pc');
      }
    });

    test('no temperament bends a note more than a quarter tone', () {
      for (final t in Temperament.values) {
        final table = TemperamentTable(t);
        for (int pc = 0; pc < 12; pc++) {
          expect(table.centsForPitchClass(pc).abs(), lessThan(50),
              reason: '${t.name} pitch class $pc');
        }
      }
    });
  });

  group('engine integration', () {
    test('A4 sounds at the concert pitch under every temperament', () {
      for (final t in Temperament.values) {
        final engine = TunerEngine(a4Frequency: 415.0, temperament: t);
        expect(engine.getFrequencyForNote('A4'), closeTo(415.0, 1e-9),
            reason: t.name);
      }
    });

    test('meantone flattens C# noticeably against equal temperament', () {
      final equal = TunerEngine();
      final meantone =
          TunerEngine(temperament: Temperament.quarterCommaMeantone);
      final equalCs = equal.getFrequencyForNote('C#4')!;
      final meantoneCs = meantone.getFrequencyForNote('C#4')!;
      final cents = TunerEngine.computeCents(meantoneCs, equalCs);
      // C# sits a quarter-comma meantone chromatic semitone below equal.
      expect(cents, closeTo(-13.686, 0.01));
    });

    test('detection targets follow the temperament', () {
      final engine =
          TunerEngine(temperament: Temperament.quarterCommaMeantone);
      final target = engine.getFrequencyForNote('C#4')!;
      final result = engine.detectNote(target);
      expect(result.note, 'C#4');
      expect(result.cents, closeTo(0, 1e-6));
      expect(result.status, TuningStatus.inTune);
    });

    test('switching temperament re-derives the pitch table', () {
      final engine = TunerEngine();
      final before = engine.getFrequencyForNote('E4')!;
      engine.temperament = Temperament.werckmeisterIII;
      final after = engine.getFrequencyForNote('E4')!;
      expect(after, isNot(closeTo(before, 0.01)));
      // Werckmeister III puts E 9.775 cents below equal, once anchored on A.
      final table = TemperamentTable(Temperament.werckmeisterIII);
      expect(TunerEngine.computeCents(after, before),
          closeTo(table.centsForPitchClass(4), 0.001));
    });
  });
}
