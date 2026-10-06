/// The browser half of [ModelStore]: the Cache Storage API.
///
/// The bytes are fetched here, on the page, so that progress can be shown,
/// checked with SubtleCrypto, and only then put in the cache under the
/// pinned URL. The transcription worker (`web/crispasr/worker.js`) reads
/// them back out of the same cache by that URL, so a model crosses from the
/// page to the worker without being copied through `postMessage`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'crispasr_model.dart';
import 'model_store.dart';

ModelStore createModelStore() => _WebModelStore();

/// Must match `CACHE_NAME` in `web/crispasr/worker.js`.
const String kModelCacheName = 'crisptuner-models-v1';

class _WebModelStore implements ModelStore {
  Future<web.Cache> _cache() => web.window.caches.open(kModelCacheName).toDart;

  @override
  Future<String?> location(CrispAsrModel model) async {
    try {
      final url = model.file.url.toString();
      final hit = await (await _cache()).match(url.toJS).toDart;
      return hit == null ? null : url;
    } catch (_) {
      // No Cache Storage (an insecure origin, or a private window that
      // refuses it): nothing is cached, and download() will say why.
      return null;
    }
  }

  @override
  Future<String> download(CrispAsrModel model,
      {DownloadProgress? onProgress, bool Function()? cancelled}) async {
    final existing = await location(model);
    if (existing != null) return existing;

    final url = model.file.url.toString();
    final total = model.file.bytes;
    try {
      final response = await web.window.fetch(url.toJS).toDart;
      if (!response.ok) {
        throw ModelDownloadException('HTTP ${response.status} for $url');
      }
      final body = response.body;
      if (body == null) throw ModelDownloadException('empty response for $url');
      final reader = body.getReader() as web.ReadableStreamDefaultReader;
      final bytes = Uint8List(total);
      var received = 0;
      onProgress?.call(0, total);
      while (true) {
        if (cancelled?.call() ?? false) {
          await reader.cancel().toDart;
          throw const ModelDownloadException('cancelled', wasCancelled: true);
        }
        final chunk = await reader.read().toDart;
        if (chunk.done) break;
        final data = (chunk.value as JSUint8Array).toDart;
        if (received + data.length > total) {
          throw ModelDownloadException(
              'more than the expected $total bytes for ${model.file.name}');
        }
        bytes.setRange(received, received + data.length, data);
        received += data.length;
        onProgress?.call(received, total);
      }
      if (received != total) {
        throw ModelDownloadException(
            'got $received of $total bytes for ${model.file.name}');
      }
      final digest = (await web.window.crypto.subtle
              .digest('SHA-256'.toJS, bytes.toJS)
              .toDart as JSArrayBuffer)
          .toDart
          .asUint8List();
      final hex = [
        for (final b in digest) b.toRadixString(16).padLeft(2, '0')
      ].join();
      if (hex != model.file.sha256) {
        throw ModelDownloadException(
            'checksum mismatch for ${model.file.name}');
      }
      await (await _cache())
          .put(url.toJS, web.Response(bytes.toJS))
          .toDart;
      return url;
    } on ModelDownloadException {
      rethrow;
    } catch (e) {
      throw ModelDownloadException('$e');
    }
  }

  @override
  Future<void> remove(CrispAsrModel model) async {
    try {
      await (await _cache()).delete(model.file.url.toString().toJS).toDart;
    } catch (_) {
      // Nothing cached is the same as removed.
    }
  }
}
