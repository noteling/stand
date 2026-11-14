// Helpers for raw audio: mono, 16-bit, little-endian PCM in Node Buffers.
import fs from 'node:fs';

export function rms(buf) {
  const n = buf.length >> 1;
  if (!n) return 0;
  let sum = 0;
  for (let i = 0; i < n; i++) {
    const s = buf.readInt16LE(i * 2);
    sum += s * s;
  }
  return Math.sqrt(sum / n);
}

export const durationMs = (buf, rate) => (buf.length / 2 / rate) * 1000;
export const samplesFor = (ms, rate) => Math.round((rate * ms) / 1000);
export const silence = (ms, rate) => Buffer.alloc(samplesFor(ms, rate) * 2);

function wavHeader(dataBytes, rate) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0);
  h.writeUInt32LE(36 + dataBytes, 4);
  h.write('WAVE', 8);
  h.write('fmt ', 12);
  h.writeUInt32LE(16, 16); // fmt chunk size
  h.writeUInt16LE(1, 20); // PCM
  h.writeUInt16LE(1, 22); // mono
  h.writeUInt32LE(rate, 24);
  h.writeUInt32LE(rate * 2, 28); // byte rate
  h.writeUInt16LE(2, 32); // block align
  h.writeUInt16LE(16, 34); // bits per sample
  h.write('data', 36);
  h.writeUInt32LE(dataBytes, 40);
  return h;
}

export function writeWav(file, pcm, rate) {
  fs.writeFileSync(file, Buffer.concat([wavHeader(pcm.length, rate), pcm]));
}

// Reads a WAV file and returns its PCM data. Only mono 16-bit PCM is accepted,
// because that is the only thing this rig produces or sends.
export function readWav(file) {
  const buf = fs.readFileSync(file);
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error(`${file} is not a WAV file`);
  }
  let rate = 0, channels = 0, bits = 0, pcm = null;
  for (let off = 12; off + 8 <= buf.length;) {
    const id = buf.toString('ascii', off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    const body = off + 8;
    if (id === 'fmt ') {
      channels = buf.readUInt16LE(body + 2);
      rate = buf.readUInt32LE(body + 4);
      bits = buf.readUInt16LE(body + 14);
    } else if (id === 'data') {
      pcm = buf.subarray(body, Math.min(body + size, buf.length));
    }
    off = body + size + (size % 2);
  }
  if (!pcm || channels !== 1 || bits !== 16) {
    throw new Error(`${file}: expected mono 16-bit PCM, got ${channels} channel(s) at ${bits} bits`);
  }
  return { rate, pcm };
}

// Linear-interpolation resampling. Good enough for a listenable recording.
export function resample(pcm, from, to) {
  if (from === to) return pcm;
  const inN = pcm.length >> 1;
  const outN = Math.floor((inN * to) / from);
  const out = Buffer.alloc(outN * 2);
  for (let i = 0; i < outN; i++) {
    const pos = (i * from) / to;
    const i0 = Math.floor(pos);
    const i1 = Math.min(i0 + 1, inN - 1);
    const frac = pos - i0;
    const s = pcm.readInt16LE(i0 * 2) * (1 - frac) + pcm.readInt16LE(i1 * 2) * frac;
    out.writeInt16LE(Math.round(s), i * 2);
  }
  return out;
}

// Adds `src` into `target` starting at `offsetSamples`, clipping at 16-bit limits.
export function mixInto(target, src, offsetSamples) {
  const n = Math.min(src.length >> 1, (target.length >> 1) - offsetSamples);
  for (let i = 0; i < n; i++) {
    const at = (offsetSamples + i) * 2;
    const s = target.readInt16LE(at) + src.readInt16LE(i * 2);
    target.writeInt16LE(Math.max(-32768, Math.min(32767, s)), at);
  }
}
