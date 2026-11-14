// Ears for whoever cannot listen to a recording directly: sends a stretch of a WAV
// file to a Gemini model and prints what it hears. Useful for checking what a short
// sound actually was. It is no substitute for a person judging how Stand sounds.
//
//   node src/listen.js runs/<run>/stand.wav --from 30 --to 31
//   node src/listen.js runs/<run>/recording.wav --ask "Does the speaker ever repeat a sentence?"
import path from 'node:path';
import { GoogleGenAI } from '@google/genai';
import { keys } from './env.js';
import { readWav, resample } from './pcm.js';

const MODEL = process.env.LISTEN_MODEL || 'gemini-3.8-flash';
const DEFAULT_ASK =
  'Listen to this audio. Write down exactly what is said, word for word. If a sound is not a word ' +
  '(a breath, a hum, a click, silence), describe it in brackets. Then, in one line, say how the voice sounds.';

const argv = process.argv.slice(2);
const file = argv.find((a) => !a.startsWith('--'));
const flag = (name) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : undefined; };
if (!file) {
  console.error('usage: node src/listen.js <file.wav> [--from seconds] [--to seconds] [--ask "question"]');
  process.exit(2);
}
if (!keys.gemini) {
  console.error('GEMINI_API_KEY is not set (put it in .env at the repo root)');
  process.exit(2);
}

let { rate, pcm } = readWav(path.resolve(file));
const from = Number(flag('from') ?? 0);
const to = Number(flag('to') ?? pcm.length / 2 / rate);
pcm = pcm.subarray(Math.floor(from * rate) * 2, Math.floor(to * rate) * 2);
if (rate > 16000) { pcm = resample(pcm, rate, 16000); rate = 16000; } // smaller upload, plenty for speech

const header = Buffer.alloc(44);
header.write('RIFF', 0); header.writeUInt32LE(36 + pcm.length, 4); header.write('WAVEfmt ', 8);
header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate * 2, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
header.write('data', 36); header.writeUInt32LE(pcm.length, 40);

const ai = new GoogleGenAI({ apiKey: keys.gemini });
const response = await ai.models.generateContent({
  model: MODEL,
  contents: [{
    role: 'user',
    parts: [
      { inlineData: { mimeType: 'audio/wav', data: Buffer.concat([header, pcm]).toString('base64') } },
      { text: flag('ask') || DEFAULT_ASK },
    ],
  }],
});
console.log(response.text);
