/// Where the CrispASR models live once downloaded, and how they get there.
///
/// The models are downloads, never bundled — 110 KB to 96 MB each — so the
/// first selection of one fetches it, and from then on it is on the device.
/// The download is this app's job rather than CrispASR's own
/// `cacheEnsureFile`: that one shells out to `curl`/`wget` where libcurl is
/// not linked, which is every mobile build, and it reports no progress. A
/// 96 MB download with no progress bar reads as a hang.
///
/// Two halves behind a conditional export: files under the app's support
/// directory on native platforms, the Cache Storage API in the browser.
library;

import 'crispasr_model.dart';

export 'model_store_io.dart' if (dart.library.js_interop) 'model_store_web.dart'
    show createModelStore;

/// Progress callback: bytes so far, and the total the download will reach.
typedef DownloadProgress = void Function(int received, int total);

abstract class ModelStore {
  /// Where [model] already is, or null if it has not been downloaded.
  ///
  /// A file path on native platforms; on the web, the URL the bytes are
  /// cached under, which the worker looks up itself. Either way it is what
  /// `CrispAsrBackend.modelPath` takes.
  Future<String?> location(CrispAsrModel model);

  /// Download [model] if it is not already here, and return its location.
  ///
  /// The bytes are checked against the size and SHA-256 in [ModelFile]
  /// before anything is kept, so a truncated or substituted download never
  /// becomes the model. Throws [ModelDownloadException] on any failure,
  /// including [cancelled] returning true.
  Future<String> download(CrispAsrModel model,
      {DownloadProgress? onProgress, bool Function()? cancelled});

  /// Forget a downloaded model. Not an error if it was never here.
  Future<void> remove(CrispAsrModel model);
}

class ModelDownloadException implements Exception {
  final String message;

  /// True when the user stopped it, which the UI says differently from a
  /// failure.
  final bool wasCancelled;

  const ModelDownloadException(this.message, {this.wasCancelled = false});

  @override
  String toString() => 'ModelDownloadException: $message';
}
