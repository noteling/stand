// Plays queued speech without gaps. 'flush' drops everything not yet played,
// which is how Stand stops the instant it is interrupted.
class Player extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.offset = 0;
    this.playing = false;
    this.idle = 30; // render blocks since audio was last written; 30 or more means stopped
    this.port.onmessage = (e) => {
      if (e.data === 'flush') {
        this.queue = [];
        this.offset = 0;
      } else {
        this.queue.push(new Float32Array(e.data));
      }
    };
  }

  process(_inputs, outputs) {
    const out = outputs[0][0];
    let written = 0;
    while (written < out.length && this.queue.length) {
      const head = this.queue[0];
      const n = Math.min(out.length - written, head.length - this.offset);
      out.set(head.subarray(this.offset, this.offset + n), written);
      written += n;
      this.offset += n;
      if (this.offset >= head.length) {
        this.queue.shift();
        this.offset = 0;
      }
    }
    // Report "stopped" only after about 150 ms of nothing, so a short gap between
    // chunks does not flicker the status.
    this.idle = written > 0 ? 0 : Math.min(this.idle + 1, 30);
    const playing = this.idle < 30;
    if (playing !== this.playing) {
      this.playing = playing;
      this.port.postMessage({ playing });
    }
    return true;
  }
}

registerProcessor('player', Player);
