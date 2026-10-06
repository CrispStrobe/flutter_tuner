/// The native half of [ModelStore]: files under the app's support directory.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'crispasr_model.dart';
import 'model_store.dart';

ModelStore createModelStore() => _IoModelStore();

class _IoModelStore implements ModelStore {
  Future<Directory>? _dir;

  /// `Application Support/crispasr-models` — not Documents, which iOS backs
  /// up to iCloud and shows in the Files app, and not Caches, which iOS
  /// empties under storage pressure and would turn into a silent 96 MB
  /// re-download.
  Future<Directory> _modelsDir() => _dir ??= () async {
        final base = await getApplicationSupportDirectory();
        final dir = Directory('${base.path}${Platform.pathSeparator}'
            'crispasr-models');
        await dir.create(recursive: true);
        return dir;
      }();

  Future<File> _fileFor(CrispAsrModel model) async =>
      File('${(await _modelsDir()).path}${Platform.pathSeparator}'
          '${model.file.name}');

  @override
  Future<String?> location(CrispAsrModel model) async {
    final file = await _fileFor(model);
    // Size, not hash: hashing 96 MB on every launch to re-check a file this
    // code verified before renaming it into place buys nothing.
    if (await file.exists() && await file.length() == model.file.bytes) {
      return file.path;
    }
    return null;
  }

  @override
  Future<String> download(CrispAsrModel model,
      {DownloadProgress? onProgress, bool Function()? cancelled}) async {
    final existing = await location(model);
    if (existing != null) return existing;

    final target = await _fileFor(model);
    final part = File('${target.path}.part');
    final client = HttpClient()..userAgent = 'CrispTuner';
    IOSink? sink;
    try {
      final request = await client.getUrl(model.file.url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw ModelDownloadException(
            'HTTP ${response.statusCode} for ${model.file.url}');
      }
      final total = model.file.bytes;
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      sink = part.openWrite();
      var received = 0;
      onProgress?.call(0, total);
      await for (final chunk in response) {
        if (cancelled?.call() ?? false) {
          throw const ModelDownloadException('cancelled', wasCancelled: true);
        }
        received += chunk.length;
        if (received > total) {
          throw ModelDownloadException(
              'more than the expected $total bytes for ${model.file.name}');
        }
        hasher.add(chunk);
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      hasher.close();
      await sink.close();
      sink = null;
      if (received != total) {
        throw ModelDownloadException(
            'got $received of $total bytes for ${model.file.name}');
      }
      if (digest.value.toString() != model.file.sha256) {
        throw ModelDownloadException(
            'checksum mismatch for ${model.file.name}');
      }
      await part.rename(target.path);
      return target.path;
    } on ModelDownloadException {
      rethrow;
    } on Object catch (e) {
      throw ModelDownloadException('$e');
    } finally {
      await sink?.close();
      client.close(force: true);
      if (await part.exists()) {
        try {
          await part.delete();
        } on FileSystemException {
          // Best effort; the next attempt overwrites it anyway.
        }
      }
    }
  }

  @override
  Future<void> remove(CrispAsrModel model) async {
    final file = await _fileFor(model);
    if (await file.exists()) await file.delete();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
