// The CrispASR models end to end on a native host: download through the
// real ModelStore, load the real libcrispasr, transcribe a real chord.
//
// Skipped unless CRISPTUNER_CRISPASR_LIB points at a libcrispasr — CI's
// "CrispASR (Linux)" job builds one with tool/crispasr/build.sh linux and
// sets it; locally:
//
//   tool/crispasr/build.sh linux
//   CRISPTUNER_CRISPASR_LIB=$PWD/tool/crispasr/linux/lib/libcrispasr.so \
//     flutter test test/crispasr_native_test.dart
//
// Basic Pitch is the model under test because it is 110 KB: the point is the
// path — catalogue, download, checksum, library, session, notes — not any
// one model's accuracy, which bench/ measures.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/crispasr_backend.dart';
import 'package:flutter_tuner/model_store.dart';
import 'package:flutter_tuner/transcription.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _TempPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String root;
  _TempPathProvider(this.root);

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  final lib = Platform.environment['CRISPTUNER_CRISPASR_LIB'];
  final skip = (lib == null || lib.isEmpty)
      ? 'set CRISPTUNER_CRISPASR_LIB to a libcrispasr to run'
      : false;

  late Directory support;
  setUp(() async {
    support = await Directory.systemTemp.createTemp('crisptuner-models');
    PathProviderPlatform.instance = _TempPathProvider(support.path);
  });
  tearDown(() => support.delete(recursive: true));

  test('downloads, verifies and runs Basic Pitch on an A major chord',
      () async {
    const model = CrispAsrModel.basicPitch;
    final store = createModelStore();
    expect(await store.location(model), anyOf(isNull, isNotEmpty));

    final progress = <int>[];
    final path = await store.download(model,
        onProgress: (received, total) => progress.add(received));
    expect(File(path).lengthSync(), model.file.bytes);
    expect(progress.last, model.file.bytes);
    expect(await store.location(model), path);

    final backend = CrispAsrBackend(
        libraryPath: lib, modelPath: path, model: model, allowDownload: false);
    expect(backend.isAvailable, isTrue);
    await backend.start();
    addTearDown(backend.stop);

    // A3, C#4, E4 — held for the whole window, as a strummed chord rings.
    const rate = BasicPitchGeometry.sampleRate;
    final window = Float64List(BasicPitchGeometry.windowSamples);
    for (final midi in const [57, 61, 64]) {
      final hz = 440.0 * math.pow(2, (midi - 69) / 12);
      for (int i = 0; i < window.length; i++) {
        window[i] += 0.2 * math.sin(2 * math.pi * hz * i / rate);
      }
    }
    final result = await backend.transcribe(window)!;
    final heard = result.notes.map((n) => n.midi % 12).toSet();
    expect(heard, containsAll(<int>[57 % 12, 61 % 12, 64 % 12]),
        reason: 'heard ${result.notes.map((n) => n.midi).toList()}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('a corrupt download is refused and leaves nothing behind', () async {
    // The checksum is the contract: write a wrong file where the model goes
    // and confirm location() does not take it, by size, and download()
    // replaces it rather than trusting it.
    const model = CrispAsrModel.basicPitch;
    final store = createModelStore();
    final dir = Directory('${support.path}/crispasr-models')..createSync();
    File('${dir.path}/${model.file.name}').writeAsBytesSync([1, 2, 3]);
    expect(await store.location(model), isNull);
    final path = await store.download(model);
    expect(File(path).lengthSync(), model.file.bytes);
    expect(File('$path.part').existsSync(), isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
