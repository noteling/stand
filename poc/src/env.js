// Paths and API keys. Keys come from the environment or from .env at the repo root.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const POC = path.join(ROOT, 'poc');
export const RUNS = path.join(POC, 'runs');
export const CACHE = path.join(POC, '.cache');

const envFile = path.join(ROOT, '.env');
if (fs.existsSync(envFile)) process.loadEnvFile(envFile);

export const keys = {
  gemini: process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '',
  openai: process.env.OPENAI_API_KEY || '',
};

// Sample rates each provider uses, known up front so the page can create its
// audio contexts inside the click that starts the session.
export const providers = {
  gemini: { label: 'Gemini 3.8 Live', inputRate: 16000, outputRate: 24000, ready: () => !!keys.gemini },
  openai: { label: 'GPT-Live-1', inputRate: 24000, outputRate: 24000, ready: () => !!keys.openai },
  mock: { label: 'Mock (no model, plumbing test)', inputRate: 24000, outputRate: 24000, ready: () => true },
};

export function providerList() {
  return Object.entries(providers).map(([id, p]) => ({
    id, label: p.label, inputRate: p.inputRate, outputRate: p.outputRate, ready: p.ready(),
  }));
}
