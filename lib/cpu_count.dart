/// How many cores to size the inference pool for.
///
/// `dart:io`'s `Platform.numberOfProcessors` is the only way to ask, and
/// importing `dart:io` anywhere reachable from a web entry point fails the
/// build — the same constraint that shapes `crispasr_backend.dart`. So the
/// question goes through a conditional export and the web answer is 1, which
/// is also the truthful one: the transcription mode does not run there.
library;

export 'cpu_count_stub.dart' if (dart.library.io) 'cpu_count_io.dart';
