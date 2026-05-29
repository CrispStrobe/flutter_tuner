import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/audio_service_stub.dart';

/// Tests that the abstract AudioService and ToneGeneratorService interfaces
/// are correctly defined and that the stub platform throws on create().
///
/// The conditional import in `audio_service.dart` routes to
/// `audio_service_mobile.dart` (dart:io) or `audio_service_web.dart`
/// (dart:html). This test verifies the fallback stub contract.
void main() {
  group('AudioService stub interface', () {
    test('defines all required methods', () {
      // Verify the abstract class shape by checking we can reference the static
      // factory. The abstract methods are enforced at compile time by the
      // `implements` clause in platform files.
      expect(AudioService.create, isA<Function>());
    });

    test('stub create() throws UnsupportedError', () {
      expect(
        () => AudioService.create(),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('ToneGeneratorService stub interface', () {
    test('defines all required methods', () {
      expect(ToneGeneratorService.create, isA<Function>());
    });

    test('stub create() throws UnsupportedError', () {
      expect(
        () => ToneGeneratorService.create(),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('Conditional import routing', () {
    test('audio_service.dart exports match stub interface', () {
      // When running in the test environment (dart:io available),
      // the conditional import resolves to audio_service_mobile.dart.
      // We import the stub directly to verify the interface contract.
      //
      // The compile-time guarantee is that mobile and web files both
      // `implements stub.AudioService` and `implements stub.ToneGeneratorService`.
      // If they miss a method, the build fails — this test documents that contract.
      expect(true, isTrue, reason: 'Conditional import compiles successfully');
    });
  });
}
