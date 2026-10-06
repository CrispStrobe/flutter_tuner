// Runs CrispASR's single-threaded WebAssembly build off the page's main
// thread, for the note-transcription mode (lib/crispasr_backend_web.dart).
//
// libwhisper.js / libwhisper.wasm sit next to this file. They are not in the
// repository: CI builds them from a pinned CrispASR release plus
// tool/crispasr/wasm-piano-notes.patch, which adds the sessionPianoNotes
// binding this worker calls (tool/crispasr/build_wasm.sh).
//
// Messages in:
//   {type: 'open', url, name, backend}  load the model the page cached
//   {type: 'transcribe', id, pcm}        pcm: Float32Array at the model rate
//   {type: 'close'}
// Messages out:
//   {type: 'opened', rate}
//   {type: 'result', id, notes, ms}      notes: [{onMs, offMs, midi, velocity, program}]
//   {type: 'error', id, message}

// Must match kModelCacheName in lib/model_store_web.dart.
const CACHE_NAME = 'crisptuner-models-v1';

importScripts('libwhisper.js');

let modulePromise = null;

function crispasr() {
  if (!modulePromise) modulePromise = whisper_factory();
  return modulePromise;
}

async function open(msg) {
  const Module = await crispasr();
  const cache = await caches.open(CACHE_NAME);
  const hit = await cache.match(msg.url);
  if (!hit) throw new Error('model not downloaded: ' + msg.name);
  const bytes = new Uint8Array(await hit.arrayBuffer());

  try { Module.FS_createPath('/', 'models', true, true); } catch (_) {}
  const path = '/models/' + msg.name;
  try { Module.FS_unlink(path); } catch (_) {}
  Module.FS_createDataFile('/models', msg.name, bytes, true, false);
  let ok;
  try {
    ok = Module.ttsOpenExplicit(path, msg.backend, 1);
  } finally {
    // The session has read the weights into its own tensors; keeping the
    // file in MEMFS too would hold a second copy of up to 96 MB.
    try { Module.FS_unlink(path); } catch (_) {}
  }
  if (!ok) throw new Error('CrispASR could not open ' + msg.backend);
  const rate = Module.sessionPianoSampleRate();
  if (rate <= 0) throw new Error(msg.backend + ' has no note output in this build');
  return rate;
}

self.onmessage = async (event) => {
  const msg = event.data;
  try {
    if (msg.type === 'open') {
      self.postMessage({ type: 'opened', rate: await open(msg) });
    } else if (msg.type === 'transcribe') {
      const Module = await crispasr();
      const t0 = performance.now();
      const notes = Module.sessionPianoNotes(msg.pcm);
      self.postMessage({ type: 'result', id: msg.id, notes, ms: performance.now() - t0 });
    } else if (msg.type === 'close') {
      if (modulePromise) (await modulePromise).ttsClose();
      self.close();
    }
  } catch (err) {
    self.postMessage({ type: 'error', id: msg.id, message: String((err && err.message) || err) });
  }
};
