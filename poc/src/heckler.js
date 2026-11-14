// A scripted audience for the north-star test. It starts a Stand session, plays
// spoken lines into it at set moments (using the Mac's built-in voices), and writes
// a report of how Stand reacted. No browser and no human needed.
//
//   node src/heckler.js --provider gemini
//   node src/heckler.js --provider mock            (checks the rig itself)
//   node src/heckler.js --provider openai --script heckler/north-star.json
import fs from 'node:fs';
import path from 'node:path';
import { POC, providers } from './env.js';
import * as pcm from './pcm.js';
import { StandSession } from './session.js';
import { synthesize } from './speech.js';

const CHUNK_MS = 20;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const clock = (ms) => `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}`;
const seconds = (ms) => `${(ms / 1000).toFixed(1)} s`;

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue;
    const [key, inline] = argv[i].slice(2).split('=');
    args[key] = inline ?? (argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true);
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const provider = args.provider || 'mock';
if (!providers[provider]) {
  console.error(`Unknown voice model "${provider}". Choose one of: ${Object.keys(providers).join(', ')}`);
  process.exit(2);
}
if (!providers[provider].ready()) {
  console.error(`"${provider}" has no API key. Put it in .env at the repo root (see .env.example).`);
  process.exit(2);
}
const scriptFile = path.resolve(args.script || path.join(POC, 'heckler', provider === 'mock' ? 'smoke.json' : 'north-star.json'));
const script = JSON.parse(fs.readFileSync(scriptFile, 'utf8'));
const maxMs = (script.maxMinutes || 12) * 60000;
const quietEndsTalkMs = (script.talkEndsAfterQuietSeconds || 12) * 1000;

const session = new StandSession({ provider, label: 'heckler' });
session.on('error', (err) => console.error(`  error: ${err.message}`));
session.on('nudge', () => say('the stage manager told Stand to carry on'));
session.on('interrupted', () => say('Stand stopped mid-speech'));

function say(text) {
  console.log(`${clock(session.now()).padStart(5)}  ${text}`);
}

async function until(condition, timeoutMs) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (condition()) return true;
    await sleep(50);
  }
  return false;
}

// Prepare every line's audio before connecting, so the session clock is not spent on it.
const rate = providers[provider].inputRate;
// `howlSeconds` adds a harsh rising tone after the words, like audio feedback in a call.
function howl(seconds) {
  const out = Buffer.alloc(Math.round(seconds * rate) * 2);
  for (let i = 0; i < out.length / 2; i++) {
    const at = i / rate;
    const hz = 900 + 1800 * (at / seconds);
    out.writeInt16LE(Math.round(Math.sin(2 * Math.PI * hz * at) * 0.7 * 32767), i * 2);
  }
  return out;
}
const prepare = (item) => {
  const words = synthesize(item.say, { voice: item.voice, rate });
  return { ...item, pcm: item.howlSeconds ? Buffer.concat([words, howl(item.howlSeconds)]) : words };
};
// A line is due after Stand has spoken for `afterSpeechSeconds` in total, which keeps it
// inside the talk whatever the talk's pace, or at a fixed `atSeconds` on the clock.
const when = (item) => item.afterSpeechSeconds ?? item.atSeconds;
const during = (script.during || []).map(prepare).sort((a, b) => when(a) - when(b));
const after = (script.after || []).map(prepare);
const goodbye = script.goodbye ? prepare(script.goodbye) : null;

try {
  await session.open();
} catch (err) {
  console.error(`Could not start a session with ${provider}: ${err.message}`);
  process.exit(1);
}
console.log(`Scripted audience against ${session.model}, script ${path.basename(scriptFile)}`);

// The room's audio is sent without pause, in real time: a line when the audience
// speaks, silence otherwise.
const chunkBytes = pcm.samplesFor(CHUNK_MS, rate) * 2;
const quiet = Buffer.alloc(chunkBytes);
let speaking = null; // { pcm, pos, done }
let sent = 0;
const pumpStart = Date.now();
const pump = setInterval(() => {
  const due = Math.floor((Date.now() - pumpStart) / CHUNK_MS);
  for (; sent < due; sent++) {
    let chunk = quiet;
    if (speaking) {
      chunk = speaking.pcm.subarray(speaking.pos, speaking.pos + chunkBytes);
      speaking.pos += chunkBytes;
      if (chunk.length < chunkBytes) chunk = Buffer.concat([chunk, Buffer.alloc(chunkBytes - chunk.length)]);
      if (speaking.pos >= speaking.pcm.length) {
        const { done } = speaking;
        speaking = null;
        done();
      }
    }
    session.pushRoomAudio(chunk);
  }
}, 10);

const utterances = [];
async function utter(item, kind) {
  const u = { label: item.label || kind, kind, text: item.say, standWasSpeaking: session.standSpeaking, startMs: session.now() };
  say(`audience (${u.label}): "${item.say}"`);
  await new Promise((done) => { speaking = { pcm: item.pcm, pos: 0, done }; });
  u.endMs = session.now();
  utterances.push(u);
  return u;
}

// Stand has answered once it starts speaking after the line and then goes quiet.
async function untilAnswered(u, startWithinMs = 15000) {
  const started = await until(() => session.closed || session.log.some((e) => e.type === 'stand_start' && e.t >= u.endMs - 300), startWithinMs);
  if (!started || session.closed) return false;
  await until(() => session.closed || (!session.standSpeaking && session.now() - session.playUntil > 2500), 90000);
  return true;
}

// The talk is over when Stand invites questions and then pauses, or stays quiet
// longer than a stall-and-nudge would take. The opening also mentions questions,
// so the invitation only counts once Stand has spoken for a while.
const minTalkSpeechMs = (script.talkIsAtLeastSpeechSeconds ?? 45) * 1000;
function talkOver() {
  if (session.standSpeaking) return null;
  const quietFor = session.now() - session.playUntil;
  const lastLine = [...session.lines].reverse().find((l) => l.who === 'stand');
  const invited = !!lastLine && /question/i.test(lastLine.text.slice(-200)) && session.spokenMs() >= minTalkSpeechMs;
  if (session.floorOpen && quietFor > 2000) return 'Stand signalled that the floor is open';
  if (invited && quietFor > 3000) return 'Stand invited questions';
  if (quietFor > quietEndsTalkMs) return 'Stand went quiet';
  return null;
}
async function untilTalkEnds() {
  while (session.now() < maxMs && !session.closed) {
    const over = talkOver();
    if (over) return over;
    await sleep(100);
  }
  return session.closed ? 'the session closed' : 'the time limit was reached';
}

session.begin();
say('the talk was started');

const isDue = (item) => (item.afterSpeechSeconds !== undefined
  ? session.spokenMs() >= item.afterSpeechSeconds * 1000
  : session.now() - session.began >= item.atSeconds * 1000);

// If the talk finishes before a line comes due, questions that were meant to
// interrupt are asked with the closing questions instead, so they are still tested.
const missed = [];
for (const [i, item] of during.entries()) {
  await until(() => session.closed || isDue(item) || talkOver(), maxMs - session.now());
  if (session.closed || session.now() >= maxMs) break;
  if (!isDue(item)) {
    missed.push(...during.slice(i).filter((d) => d.kind !== 'noise'));
    say(`the talk ended before ${during.length - i} planned line(s); the questions among them move to the end`);
    break;
  }
  await until(() => session.closed || session.standSpeaking, 15000); // talk over Stand, as a real interruption would
  const u = await utter(item, item.kind || 'question');
  // Let Stand begin its reply before anything else happens. A noise needs no reply.
  if (u.kind !== 'noise') await until(() => session.closed || session.log.some((e) => e.type === 'stand_start' && e.t >= u.endMs - 300), 15000);
}

const talkEnded = await untilTalkEnds();
const talkEndedAt = session.now();
say(`talk over: ${talkEnded}`);

if (!session.closed && session.now() < maxMs) {
  for (const item of [...missed, ...after]) {
    const u = await utter(item, 'closing question');
    await untilAnswered(u);
    if (session.closed) break;
  }
  if (goodbye && !session.closed) {
    const u = await utter(goodbye, 'goodbye');
    await untilAnswered(u, 6000);
  }
}

clearInterval(pump);
await session.close('the scripted audience finished');

// ---- Report ---------------------------------------------------------------

const find = (type, from, to = Infinity, key = 't') => session.log.find((e) => e.type === type && e[key] >= from && e[key] <= to);
utterances.forEach((u, i) => {
  if (u.standWasSpeaking) {
    const cut = find('interrupted', u.startMs, u.endMs + 3000);
    const ran = find('stand_stop', u.startMs - 50, u.endMs + 3000, 'at');
    const stopAt = cut ? cut.t : ran ? ran.at : null;
    u.stoppedAfterMs = stopAt === null ? null : Math.max(0, stopAt - u.startMs);
  }
  const stopped = !u.standWasSpeaking || u.stoppedAfterMs !== null;
  const reply = stopped ? find('stand_start', u.endMs - 300) : null;
  u.repliedAfterMs = reply ? Math.max(0, reply.t - u.endMs) : null;
  // What Stand said next: up to 40 seconds of it, or until the audience speaks again.
  const until = Math.min(utterances[i + 1]?.startMs ?? Infinity, u.endMs + 40000);
  const text = session.lines
    .filter((l) => l.who === 'stand' && l.updated >= u.endMs && l.t < until)
    .map((l) => l.text.trim())
    .join(' ');
  u.standSaid = text.length > 700 ? `${text.slice(0, 700)}…` : text;
});

const s = session.summary || {};
const rows = utterances.map((u) => {
  const stopped = !u.standWasSpeaking ? 'was not talking'
    : u.stoppedAfterMs === null ? 'kept talking'
    : `stopped after ${seconds(u.stoppedAfterMs)}`;
  const replied = u.repliedAfterMs === null ? 'no reply' : `replied after ${seconds(u.repliedAfterMs)}`;
  return `| ${clock(u.startMs)} | ${u.label} | ${stopped} | ${u.stoppedAfterMs === null && u.standWasSpeaking ? 'n/a' : replied} |`;
});
const said = utterances.map((u) => `**${u.label}** at ${clock(u.startMs)}: "${u.text}"\n\n> ${u.standSaid || '(nothing)'}`);

const facts = [
  `Script: ${path.basename(scriptFile)}`,
  `Length: ${clock((s.durationSeconds || 0) * 1000)}, of which Stand spoke for ${clock((s.standSpeechSeconds || 0) * 1000)}`,
  `Talk over at ${clock(talkEndedAt)}: ${talkEnded}`,
  `The stage manager told Stand to carry on ${session.log.filter((e) => e.type === 'nudge' && e.after === 'stand').length} times after Stand's own turn, and ${session.log.filter((e) => e.type === 'nudge' && e.after !== 'stand').length} times after a silence nobody filled`,
  `Estimated cost: $${s.estimatedCostUsd ?? 0} (${s.costBasis || 'no basis'})`,
  ...(s.errors || []).map((e) => `Error: ${e}`),
];

const report = `# North-star rehearsal: ${s.model || provider}

${facts.map((f) => `- ${f}`).join('\n')}

## What the audience did

| When | What | Stand | Then |
|---|---|---|---|
${rows.join('\n')}

For a listening noise such as "mm-hm", "kept talking" is the right result.

## What Stand said next

Text is grouped by when it arrived, which can run slightly ahead of when it was heard.

${said.join('\n\n')}

## Pass test

Judge these by reading \`transcript.md\` and listening to \`recording.wav\`.

- [ ] Gave the whole talk, every section
- [ ] Returned to the talk after each interruption, without restarting
- [ ] Kept talking through the listening noise
- [ ] Dealt with the off-topic question in a sentence
- [ ] Said it did not know when asked something outside its background
- [ ] Finished the talk within about seven minutes
- [ ] Answered the closing questions and ended cleanly
- [ ] Invented nothing
- [ ] The recording is good enough to show someone
`;
fs.writeFileSync(path.join(session.dir, 'report.md'), report);
console.log(`\nReport: ${path.join(session.dir, 'report.md')}\nRecording: ${path.join(session.dir, 'recording.wav')}`);
process.exit(0);
