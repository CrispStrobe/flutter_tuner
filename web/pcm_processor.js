/**
 * AudioWorklet processor that captures PCM audio data and forwards it
 * to the main thread as Int16 PCM bytes (little-endian).
 *
 * Replaces the deprecated ScriptProcessorNode for lower-latency capture.
 */
class PcmProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
  }

  process(inputs, outputs, parameters) {
    const input = inputs[0];
    if (!input || input.length === 0 || input[0].length === 0) {
      return true;
    }

    const float32Data = input[0]; // mono channel
    const int16 = new Int16Array(float32Data.length);
    for (let i = 0; i < float32Data.length; i++) {
      const s = Math.max(-1, Math.min(1, float32Data[i]));
      int16[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
    }

    // Transfer the raw bytes to the main thread
    this.port.postMessage(new Uint8Array(int16.buffer));
    return true;
  }
}

registerProcessor('pcm-processor', PcmProcessor);
