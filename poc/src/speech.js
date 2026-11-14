// Turns text into PCM with the Mac's built-in `say` command. Used for the scripted
// audience and for the mock Stand, never for Stand's real voice.
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { CACHE } from './env.js';
import { readWav } from './pcm.js';

let voices;
function installedVoices() {
  if (!voices) {
    try {
      const out = execFileSync('say', ['-v', '?'], { encoding: 'utf8' });
      voices = new Set(out.split('\n').map((line) => line.split(/\s{2,}/)[0].trim()).filter(Boolean));
    } catch {
      voices = new Set();
    }
  }
  return voices;
}

// Returns mono 16-bit PCM at `rate`. A voice that is not installed falls back to the system default.
export function synthesize(text, { voice, rate }) {
  const useVoice = voice && installedVoices().has(voice) ? voice : null;
  const key = crypto.createHash('sha1').update(`${useVoice}|${rate}|${text}`).digest('hex').slice(0, 16);
  const wav = path.join(CACHE, 'speech', `${key}.wav`);
  if (!fs.existsSync(wav)) {
    fs.mkdirSync(path.dirname(wav), { recursive: true });
    const aiff = wav.replace(/\.wav$/, '.aiff');
    execFileSync('say', [...(useVoice ? ['-v', useVoice] : []), '-o', aiff, text]);
    execFileSync('afconvert', ['-f', 'WAVE', '-d', `LEI16@${rate}`, '-c', '1', aiff, wav]);
    fs.rmSync(aiff, { force: true });
  }
  return readWav(wav).pcm;
}
