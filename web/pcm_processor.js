/**
 * AudioWorklet processor that captures PCM audio data and forwards it
 * to the main thread as Int16 PCM bytes (little-endian).
 *
 * Replaces the deprecated ScriptProcessorNode for lower-latency capture.
 */
// The Web Audio spec hands a worklet 128 samples per render quantum — 345
// calls a second at 44.1 kHz. Posting each one separately meant 345 messages,
// 345 allocations and 345 wake-ups of the main thread per second, to deliver
// 2.9 ms of audio at a time to an analysis whose window is 93 ms long.
// Batching into blocks costs a little latency (one block) and removes most of
// that traffic; the analysis itself is rate-limited on the Dart side.
const BATCH_SAMPLES = 512;

class PcmProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._batch = new Int16Array(BATCH_SAMPLES);
    this._filled = 0;
  }

  process(inputs, outputs, parameters) {
    const input = inputs[0];
    if (!input || input.length === 0 || input[0].length === 0) {
      return true;
    }

    const float32Data = input[0]; // mono channel
    for (let i = 0; i < float32Data.length; i++) {
      const s = Math.max(-1, Math.min(1, float32Data[i]));
      this._batch[this._filled++] = s < 0 ? s * 0x8000 : s * 0x7FFF;

      if (this._filled === BATCH_SAMPLES) {
        // Copy out: the batch buffer is reused, and postMessage is async.
        this.port.postMessage(new Uint8Array(this._batch.buffer.slice(0)));
        this._filled = 0;
      }
    }
    return true;
  }
}

registerProcessor('pcm-processor', PcmProcessor);
