// One Stand session. It connects a voice model, relays audio both ways, keeps the
// clock, nudges a stalled talk, and writes the whole run to disk when it ends.
// The browser server and the scripted audience both drive this same class.
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import path from 'node:path';
import { connectAdapter } from './adapters/index.js';
import { RUNS, providers } from './env.js';
import * as pcm from './pcm.js';
import { buildInstructions, KICKOFF, NUDGE, TALK } from './prompt.js';

const VOICE_RMS = Number(process.env.ROOM_VOICE_RMS || 500); // louder than this counts as the room making sound
const SPEECH_GRACE_MS = 150; // gap in Stand's audio shorter than this is not a stop
const ROOM_HANG_MS = 600; // the room counts as quiet after this long below the threshold
const AFTER_CUT_MS = 2500; // room silence after Stand was cut off before "carry on"; longer than a pause inside a question
const AFTER_TURN_MS = 200; // pause before "carry on" once the model has reported its turn finished
const SHORT_REPLY_MS = 4000; // a reply to "carry on" shorter than this means Stand is waiting on purpose

// List prices per minute, used only for a rough cost line in the summary.
const LIST_PRICE = {
  gemini: { listen: 0.005, speak: 0.018, basis: 'Gemini list price: $0.005/min audio in, $0.018/min audio out; ignores context re-billing' },
  openai: { session: 0.05, basis: 'GPT-Live-1 list price: $0.05 per minute of open session' },
  mock: { basis: 'no model' },
};

const clock = (ms) => `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}`;

export class StandSession extends EventEmitter {
  constructor({
    provider,
    label = 'session',
    // After Stand finishes speaking and nobody answers, tell it to carry on this soon.
    // A voice model speaks one turn and then waits, so this is what keeps a talk moving.
    continueAfterMs = Number(process.env.CONTINUE_AFTER_MS ?? 1200),
    // After the room made sound and then went quiet without Stand saying anything more,
    // tell it to carry on after this long. A presenter stopped by noise, an echo or a
    // half-sentence waits a beat and resumes; Stand needs telling.
    nudgeAfterMs = Number(process.env.NUDGE_AFTER_MS ?? 3000),
  }) {
    super();
    if (!providers[provider]) throw new Error(`Unknown voice model "${provider}"`);
    this.provider = provider;
    this.continueAfterMs = continueAfterMs;
    this.nudgeAfterMs = nudgeAfterMs;
    this.inputRate = providers[provider].inputRate;
    this.outputRate = providers[provider].outputRate;
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    this.dir = path.join(RUNS, `${stamp}-${provider}-${label}`);
    this.t0 = Date.now();

    this.log = []; // every recorded event, kept in memory for reports
    this.lines = []; // transcript lines: { who, t, updated, text }
    this.roomChunks = []; // the room's audio, continuous from roomStartMs
    this.roomStartMs = null;
    this.standSegments = []; // Stand's audio as heard: { startMs, pcm }, cut short on interruption
    this.playUntil = 0; // session time at which Stand's already-sent speech runs out
    this.lastRoomVoice = -Infinity;
    this.standSpeaking = false;
    this.roomSpeaking = false;
    this.began = null;
    this.nudged = false; // one nudge per silence
    this.lastCarryOn = null; // the last "carry on" sent after Stand's own turn: { t, spokenMs }
    this.lastStandAudioAt = -Infinity; // when speech last arrived from the model
    this.turnCompleteAt = null; // when the model last reported a finished turn
    this.cutOff = false; // Stand's last speech was cut short by someone speaking
    this.floorOpenAt = null; // session time from which Stand is waiting for the audience, once it has said so
    this.nudges = 0;
    this.interruptions = 0;
    this.usage = null;
    this.closed = false;
    this.on('error', () => {}); // errors are recorded; an unhandled 'error' event must not crash the process
  }

  now() {
    return Date.now() - this.t0;
  }

  record(type, data = {}) {
    const event = { t: this.now(), type, ...data };
    this.log.push(event);
    this.stream?.write(`${JSON.stringify(event)}\n`);
    return event;
  }

  async open() {
    const instructions = buildInstructions(this.provider);
    this.adapter = await connectAdapter(this.provider, {
      instructions,
      handlers: {
        onAudio: (buf) => this.#standAudio(buf),
        onInterrupted: () => this.#interrupted(),
        onTranscript: (who, text) => this.#transcript(who, text),
        // The model saying it has finished a turn and is now waiting (not every model reports this).
        onTurnComplete: () => { this.turnCompleteAt = this.now(); },
        onUsage: (usage) => { this.usage = usage; },
        // Stand saying it has handed the floor to the audience (a tool call, where the model has tools).
        onSignal: (name) => { if (name === 'floor_open') this.#floorOpened(); },
        onError: (err) => { this.record('error', { message: err.message }); this.emit('error', err); },
        onClose: (reason) => this.close(`the voice model ended the session: ${reason}`),
      },
    });
    this.model = this.adapter.model;
    this.t0 = Date.now(); // session time counts from the moment the voice model is connected
    // The run folder is created only once connected, so a failed connection leaves nothing behind.
    fs.mkdirSync(this.dir, { recursive: true });
    this.stream = fs.createWriteStream(path.join(this.dir, 'events.jsonl'));
    fs.writeFileSync(path.join(this.dir, 'instructions.md'), instructions);
    this.record('opened', { provider: this.provider, model: this.model, talk: TALK });
    this.timer = setInterval(() => this.#tick(), 100);
  }

  // Tells Stand to start the talk.
  begin() {
    if (this.began !== null || this.closed) return;
    this.began = this.now();
    this.adapter.instruct(KICKOFF);
    this.record('begin');
  }

  // Audio from the room: mono 16-bit PCM at inputRate, sent continuously, silence included.
  pushRoomAudio(buf) {
    if (this.closed || !this.adapter) return;
    if (this.roomStartMs === null) this.roomStartMs = this.now();
    this.roomChunks.push(buf);
    if (pcm.rms(buf) > VOICE_RMS) {
      this.lastRoomVoice = this.now();
      this.nudged = false;
      if (!this.roomSpeaking) { this.roomSpeaking = true; this.record('room_start'); this.#state(); }
    }
    this.adapter.sendAudio(buf);
  }

  async close(reason = 'closed') {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.timer);
    try { await this.adapter?.close(); } catch { /* nothing left to close */ }
    this.record('closed', { reason });
    if (this.adapter) { // a session that never connected has nothing worth saving
      try { this.#writeRun(reason); } catch (err) { this.record('error', { message: `could not write the run: ${err.message}` }); }
    }
    this.stream?.end();
    this.emit('closed', reason);
  }

  #state() {
    this.emit('state', { standSpeaking: this.standSpeaking, roomSpeaking: this.roomSpeaking });
  }

  // True once Stand has said it is waiting for the audience and that moment has been heard.
  get floorOpen() {
    return this.floorOpenAt !== null && this.now() >= this.floorOpenAt;
  }

  // The signal arrives when the words are generated, which can be well before they
  // are heard, so the floor only counts as open once the speech sent so far has played.
  #floorOpened() {
    if (this.closed || this.floorOpenAt !== null) return;
    this.floorOpenAt = Math.max(this.now(), this.playUntil);
    this.record('floor_open', { at: Math.round(this.floorOpenAt) });
  }

  #standAudio(buf) {
    if (this.closed) return;
    // Models may send speech faster than it is spoken, so keep a virtual playhead:
    // each chunk starts when the previous one finishes, or now if Stand was silent.
    const startMs = Math.max(this.now(), this.playUntil);
    this.standSegments.push({ startMs, pcm: buf });
    this.lastStandAudioAt = this.now();
    this.cutOff = false;
    this.playUntil = startMs + pcm.durationMs(buf, this.outputRate);
    this.nudged = false;
    if (!this.standSpeaking) { this.standSpeaking = true; this.record('stand_start'); this.#state(); }
    this.emit('audio', buf);
  }

  #interrupted() {
    if (this.closed) return;
    const t = this.now();
    // Throw away speech that had been sent but not yet played.
    while (this.standSegments.length) {
      const last = this.standSegments[this.standSegments.length - 1];
      if (last.startMs >= t) { this.standSegments.pop(); continue; }
      const keep = pcm.samplesFor(t - last.startMs, this.outputRate) * 2;
      if (keep < last.pcm.length) last.pcm = last.pcm.subarray(0, keep);
      break;
    }
    this.playUntil = Math.min(this.playUntil, t);
    this.interruptions += 1;
    // Cut off before reaching the end of the talk: the floor is not open after all.
    if (this.floorOpenAt !== null && t < this.floorOpenAt) {
      this.floorOpenAt = null;
      this.record('floor_not_open_after_all');
    }
    this.cutOff = true; // until Stand speaks again
    this.record('interrupted');
    this.emit('interrupted');
  }

  #transcript(who, text) {
    if (this.closed || !text) return;
    const t = this.now();
    const last = this.lines[this.lines.length - 1];
    if (last && last.who === who && t - last.updated < 2500) {
      last.text += text;
      last.updated = t;
    } else {
      this.lines.push({ who, t, updated: t, text });
    }
    this.emit('transcript', { who, text });
  }

  #tick() {
    const t = this.now();
    const speaking = this.standSegments.length > 0 && t < this.playUntil + SPEECH_GRACE_MS;
    if (speaking !== this.standSpeaking) {
      this.standSpeaking = speaking;
      // `at` is when the speech actually ran out, a little before this tick noticed.
      if (speaking) this.record('stand_start');
      else this.record('stand_stop', { at: Math.round(this.playUntil) });
      this.#state();
    }
    if (this.roomSpeaking && t - this.lastRoomVoice > ROOM_HANG_MS) {
      this.roomSpeaking = false;
      this.record('room_stop');
      this.#state();
    }
    // The stage manager: once per silence, tell Stand to carry on. Quickly if Stand
    // was the last to speak (it finished a turn and is waiting), slowly if the room
    // was (give Stand time to answer first). The 300 ms margin keeps Stand's own
    // echo in the microphone from counting as the room speaking last.
    if (this.began !== null && !this.nudged) {
      const quietSince = Math.max(this.playUntil, this.lastRoomVoice, this.began);
      const standSpokeLast = this.standSegments.length > 0 && !this.cutOff && this.lastRoomVoice < this.playUntil + 300;
      // When the model itself reports that its turn is finished, there is no need to
      // wait and see whether it resumes: say "carry on" as soon as its speech has played.
      const turnDone = this.turnCompleteAt !== null && this.turnCompleteAt >= this.lastStandAudioAt;
      const carryOn = this.continueAfterMs > 0;
      const wait = this.cutOff ? (carryOn ? AFTER_CUT_MS : 0) // someone cut Stand off: it usually answers or resumes by itself
        : !standSpokeLast ? this.nudgeAfterMs // the room spoke last: give Stand time to answer
        : turnDone && carryOn ? AFTER_TURN_MS
        : this.continueAfterMs;
      if (wait > 0 && t - quietSince > wait) {
        this.nudged = true;
        // Stand is waiting on purpose, not stalled, if it has said so (floorOpen), or
        // if the last "carry on" drew only a line or nothing. Leave it alone until the
        // room speaks: each nudge would push it to fill the silence, then to say goodbye.
        const last = this.lastCarryOn;
        const shortReply = last && this.lastRoomVoice < last.t && this.spokenMs() - last.spokenMs < SHORT_REPLY_MS;
        if (this.floorOpen || (standSpokeLast && shortReply)) {
          this.record('left_waiting', { because: this.floorOpen ? 'Stand opened the floor' : 'its last reply was short' });
          return;
        }
        if (standSpokeLast) this.lastCarryOn = { t, spokenMs: this.spokenMs() };
        this.nudges += 1;
        (this.adapter.nudge ?? this.adapter.instruct).call(this.adapter, NUDGE);
        this.record('nudge', { after: this.cutOff ? 'cut' : standSpokeLast ? 'stand' : 'room' });
        this.emit('nudge');
      }
    }
  }

  // How long Stand has actually been heard speaking so far.
  spokenMs() {
    const t = this.now();
    let ms = 0;
    for (const s of this.standSegments) {
      ms += Math.max(0, Math.min(pcm.durationMs(s.pcm, this.outputRate), t - s.startMs));
    }
    return ms;
  }

  #writeRun(reason) {
    const endMs = this.now();
    const room = Buffer.concat(this.roomChunks);
    const speechMs = this.standSegments.reduce((sum, s) => sum + pcm.durationMs(s.pcm, this.outputRate), 0);
    const lastSpeechEnd = this.standSegments.reduce((max, s) => Math.max(max, s.startMs + pcm.durationMs(s.pcm, this.outputRate)), 0);

    // stand.wav puts Stand's speech on the session timeline; recording.wav adds the room.
    const timeline = Buffer.alloc(pcm.samplesFor(Math.max(endMs, lastSpeechEnd), this.outputRate) * 2);
    for (const s of this.standSegments) pcm.mixInto(timeline, s.pcm, pcm.samplesFor(s.startMs, this.outputRate));
    pcm.writeWav(path.join(this.dir, 'stand.wav'), timeline, this.outputRate);
    if (room.length) {
      pcm.writeWav(path.join(this.dir, 'room.wav'), room, this.inputRate);
      pcm.mixInto(timeline, pcm.resample(room, this.inputRate, this.outputRate), pcm.samplesFor(this.roomStartMs, this.outputRate));
      pcm.writeWav(path.join(this.dir, 'recording.wav'), timeline, this.outputRate);
    }

    const markers = {
      begin: 'the talk was started',
      interrupted: 'Stand stopped mid-speech',
      nudge: 'the stage manager told Stand to carry on',
      floor_open: 'Stand signalled that the talk is over and the floor is open',
    };
    const entries = [
      ...this.log.filter((e) => markers[e.type]).map((e) => ({ t: e.t, text: `_(${markers[e.type]})_` })),
      ...this.lines.map((l) => ({ t: l.t, text: `**${l.who === 'stand' ? 'Stand' : 'Room'}:** ${l.text.trim()}` })),
    ].sort((a, b) => a.t - b.t); // the sort is stable, so a marker comes before a line at the same instant
    fs.writeFileSync(
      path.join(this.dir, 'transcript.md'),
      `# Transcript\n\n${entries.map((e) => `- ${clock(e.t)} ${e.text}`).join('\n')}\n`,
    );

    const price = LIST_PRICE[this.provider];
    const minutes = endMs / 60000;
    const cost = price.session ? minutes * price.session
      : price.listen ? minutes * price.listen + (speechMs / 60000) * price.speak
      : 0;
    this.summary = {
      provider: this.provider,
      model: this.model,
      talk: TALK,
      startedAt: new Date(this.t0).toISOString(),
      endedBecause: reason,
      durationSeconds: Math.round(endMs / 1000),
      standSpeechSeconds: Math.round(speechMs / 1000),
      interruptions: this.interruptions,
      nudges: this.nudges,
      errors: this.log.filter((e) => e.type === 'error').map((e) => e.message),
      usageReportedByProvider: this.usage,
      estimatedCostUsd: Number(cost.toFixed(4)),
      costBasis: price.basis,
    };
    fs.writeFileSync(path.join(this.dir, 'summary.json'), `${JSON.stringify(this.summary, null, 2)}\n`);
  }
}
