// Does CrispAsrBackend actually resolve itself now?
//
//   dart run bin/backend_resolve.dart
//
// §25.2 found the merged backend was "available unless configured" only in
// theory: it required CRISPTUNER_BASIC_PITCH_GGUF to point at a file the
// user had to obtain, so it had never run outside this benchmark. The fix,
// taken from CometBeat, is to resolve the GGUF through CrispASR's own
// registry and cache. This checks that end to end, on a machine where
// nothing is configured.

import 'dart:ffi';
import 'dart:io';

import 'package:crispasr/crispasr.dart';

const String backendName = 'basic-pitch';

String libPath() {
  final ov = Platform.environment['CRISPTUNER_CRISPASR_LIB'];
  if (ov != null && ov.isNotEmpty) return ov;
  if (Platform.isMacOS) {
    try {
      final macos = File(Platform.resolvedExecutable).parent;
      final bundled = '${macos.parent.path}/Frameworks/libcrispasr.dylib';
      if (File(bundled).existsSync()) return bundled;
    } catch (_) {}
  }
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    final drop = '$home/.cache/crispasr/libcrispasr.$suffix';
    if (File(drop).existsSync()) return drop;
  }
  return CrispASR.defaultLibName();
}

void main(List<String> argv) {
  final allowDownload = argv.contains('--download');
  stdout.writeln('library path : ${libPath()}');

  final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(libPath());
    stdout.writeln('library      : opened');
  } catch (e) {
    stdout.writeln('library      : NOT AVAILABLE — $e');
    stdout.writeln('\n=> isAvailable would be false, and the app falls '
        'through to pure Dart. That is the designed outcome, not a failure.');
    return;
  }

  final entry = registryLookup(backendName, lib: lib);
  if (entry == null) {
    stdout.writeln('registry     : no "$backendName" in this build');
    return;
  }
  stdout.writeln('registry     : ${entry.filename} (${entry.approxSize})');
  stdout.writeln('               ${entry.url}');

  final dir = cacheDir(lib: lib);
  stdout.writeln('cache dir    : ${dir ?? "(none)"}');
  String? model;
  if (dir != null) {
    final cached = File('$dir/${entry.filename}');
    if (cached.existsSync() && cached.lengthSync() > 0) {
      model = cached.path;
      stdout.writeln('cached       : yes, ${cached.lengthSync()} bytes');
    } else {
      stdout.writeln('cached       : no');
    }
  }
  if (model == null && allowDownload) {
    stdout.writeln('downloading  : …');
    model = cacheEnsureFile(entry.filename, entry.url, quiet: true, lib: lib);
    stdout.writeln('downloaded   : ${model ?? "FAILED"}');
  }
  if (model == null) {
    stdout.writeln('\n=> would resolve on first use with download enabled.');
    return;
  }

  // The part that proves it: open a session on the resolved model.
  try {
    final s = CrispasrSession.open(model,
        libPath: libPath(), backend: backendName, nThreads: 2);
    stdout.writeln('session      : open, wants ${s.pianoSampleRate} Hz');
    s.close();
    stdout.writeln('\n=> resolved with nothing configured. This is what §25.2 '
        'said the old version could not do.');
  } catch (e) {
    stdout.writeln('session      : FAILED — $e');
  }
}
