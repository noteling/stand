// A stand-in for the voice model, so the rig can be exercised without an API key.
// It speaks a short canned talk with the Mac's built-in voice, stops when it hears
// sound, gives a canned reply, and carries on. It understands nothing.
import { providers } from '../env.js';
import { durationMs, rms } from '../pcm.js';
import { synthesize } from '../speech.js';

const { inputRate, outputRate } = providers.mock;
const CHUNK_MS = 40;
const LEAD_MS = 120; // how far ahead of real time speech is sent
const LOUD = 500; // RMS above this counts as someone making sound

const TALK = [
  'Hello. I am the mock Stand. No voice model is running, so this only tests the plumbing.',
  'Section two. A real Stand would explain what it is here.',
  'Section three. Make a noise now to check that I stop.',
  'Section four. This is the last section of the mock talk.',
];
const INVITE = 'That is the end of the mock talk. Any questions?';
const REPLY = 'I heard something, so I stopped. Back to where I was.';
const ANSWER = 'This is a mock answer to your question.';
const GOODBYE = 'Thank you. That is all from the mock.';

export async function connect({ handlers }) {
  const clip = (text) => ({ text, pcm: synthesize(text, { rate: outputRate }) });
  const talk = TALK.map(clip);
  const invite = clip(INVITE), reply = clip(REPLY), answer = clip(ANSWER), goodbye = clip(GOODBYE);
  const chunkBytes = Math.round((outputRate * CHUNK_MS) / 1000) * 2;

  let phase = 'idle'; // idle -> talk -> questions -> done
  let section = 0;
  let current = null; // the clip being spoken: { pcm, pos, startedAt, onDone }
  let waiting = false; // heard something, waiting for the room to go quiet
  let loudMs = 0, quietMs = 0, answered = 0, closed = false;

  function say(c, onDone) {
    current = { pcm: c.pcm, pos: 0, startedAt: Date.now(), onDone };
    handlers.onTranscript('stand', `${c.text} `);
  }

  function saySection(i) {
    if (i >= talk.length) return say(invite, () => { phase = 'questions'; });
    say(talk[i], () => {
      section = i + 1;
      setTimeout(() => { if (!closed && !waiting && !current && phase === 'talk') saySection(section); }, 400);
    });
  }

  function respond() {
    waiting = false;
    handlers.onTranscript('room', '(sound) ');
    if (phase === 'talk') return say(reply, () => saySection(section));
    if (phase === 'questions') {
      answered += 1;
      if (answered >= 2) say(goodbye, () => { phase = 'done'; });
      else say(answer);
    }
  }

  const pump = setInterval(() => {
    const sentMs = () => (current.pos / 2 / outputRate) * 1000;
    while (current && sentMs() < Date.now() - current.startedAt + LEAD_MS) {
      handlers.onAudio(current.pcm.subarray(current.pos, current.pos + chunkBytes));
      current.pos += chunkBytes;
      if (current.pos >= current.pcm.length) {
        const { onDone } = current;
        current = null;
        onDone?.();
      }
    }
  }, CHUNK_MS / 2);

  return {
    model: 'mock',
    inputRate,
    outputRate,
    sendAudio(buf) {
      const ms = durationMs(buf, inputRate);
      if (rms(buf) > LOUD) { loudMs += ms; quietMs = 0; } else { quietMs += ms; if (quietMs > 300) loudMs = 0; }
      if (loudMs >= 200 && (phase === 'talk' || phase === 'questions') && !waiting) {
        if (current) { current = null; handlers.onInterrupted(); }
        waiting = true;
      }
      if (waiting && quietMs >= 700) respond();
    },
    instruct(text) {
      if (phase === 'idle' && /begin/i.test(text)) { phase = 'talk'; saySection(0); }
      else if (phase === 'talk' && !current && !waiting) saySection(section);
    },
    async close() {
      closed = true;
      clearInterval(pump);
    },
  };
}
