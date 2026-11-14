// Turns the microphone into fixed-size chunks of 16-bit PCM. The stream never
// pauses: with no microphone connected it sends silence.
class Capture extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.chunk = new Int16Array(options.processorOptions?.chunk || 640);
    this.filled = 0;
  }

  process(inputs) {
    const input = inputs[0]?.[0];
    const frames = input ? input.length : 128;
    for (let i = 0; i < frames; i++) {
      const s = input ? Math.max(-1, Math.min(1, input[i])) : 0;
      this.chunk[this.filled++] = s < 0 ? s * 0x8000 : s * 0x7fff;
      if (this.filled === this.chunk.length) {
        const out = this.chunk.slice();
        this.port.postMessage(out.buffer, [out.buffer]);
        this.filled = 0;
      }
    }
    return true;
  }
}

registerProcessor('capture', Capture);
