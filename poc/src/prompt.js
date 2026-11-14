// Builds the instructions Stand runs on from the plain-text files at the repo root.
// Changing how Stand behaves means editing those files, not this one.
import fs from 'node:fs';
import path from 'node:path';
import { ROOT } from './env.js';

const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8').trim();

// Pushes every Markdown heading one level down, so a file can sit under a
// top-level section of the combined instructions.
const demote = (md) => md.replace(/^#/gm, '##');

export const TALK = process.env.STAND_TALK || 'talks/introducing-stand.md';

// What the stage manager says to Stand. Kept as text files so the Mac app reads the same words.
export const KICKOFF = read('prompts/stage-manager-begin.txt');
export const NUDGE = read('prompts/stage-manager-carry-on.txt');

export function buildInstructions(provider) {
  const parts = [
    read('prompts/presenter.md'),
    `# Your character\n\n${demote(read('identity/character.md'))}`,
    `# Who you are\n\n${demote(read('identity/stand.md'))}`,
    `# The talk\n\n${demote(read(TALK))}`,
  ];
  if (provider === 'gemini') parts.push(read('prompts/provider-gemini.md'));
  if (provider === 'openai') parts.push(read('prompts/provider-openai.md'));
  return parts.join('\n\n');
}
