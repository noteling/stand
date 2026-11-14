// Gemini Live adapter. Written from Google's docs and the SDK's type definitions
// (@google/genai 3.2.0) on 2026-11-11; not yet run against the live service.
import { GoogleGenAI, Modality } from '@google/genai';
import { keys, providers } from '../env.js';

const MODEL = process.env.GEMINI_LIVE_MODEL || 'gemini-3.8-live';
const VOICE = process.env.GEMINI_VOICE || 'Kore';
const { inputRate, outputRate } = providers.gemini;

// How readily the server decides someone has started speaking, which is what cuts
// Stand off. Unset leaves the service default (high). "low" should mean fewer
// false stops on coughs and "mm-hm", at the risk of slower real ones.
const SENSITIVITY = { low: 'START_SENSITIVITY_LOW', high: 'START_SENSITIVITY_HIGH' }[process.env.GEMINI_START_SENSITIVITY || ''];
// How long a sound must last before it counts as speech. Longer should let a short
// "mm-hm" pass without stopping Stand, and makes Stand that much slower to yield.
const PREFIX_PADDING_MS = process.env.GEMINI_PREFIX_PADDING_MS ? Number(process.env.GEMINI_PREFIX_PADDING_MS) : null;
const detection = {
  ...(SENSITIVITY && { startOfSpeechSensitivity: SENSITIVITY }),
  ...(PREFIX_PADDING_MS !== null && { prefixPaddingMs: PREFIX_PADDING_MS }),
};

// The rig cannot tell a stalled talk from Stand waiting on purpose, so Stand says
// which it is. NON_BLOCKING lets it keep speaking while the call is handled.
const FLOOR_TOOL = {
  name: 'open_the_floor',
  description:
    'Call this right after you have finished the talk and invited questions out loud. It tells the software ' +
    'running the session that you are now waiting for the audience, so it stops telling you to carry on.',
  behavior: 'NON_BLOCKING',
};

export async function connect({ instructions, handlers }) {
  if (!keys.gemini) throw new Error('GEMINI_API_KEY is not set (put it in .env at the repo root)');
  const ai = new GoogleGenAI({ apiKey: keys.gemini, httpOptions: { apiVersion: 'v1beta' } });

  let session = null;
  let generation = 0; // identifies the current connection, so callbacks from a replaced one are ignored
  let handle = null; // latest session resumption handle
  let closing = false;
  let resuming = false;

  function onMessage(message) {
    const content = message.serverContent;
    if (content) {
      for (const part of content.modelTurn?.parts ?? []) {
        if (part.inlineData?.data) handlers.onAudio(Buffer.from(part.inlineData.data, 'base64'));
      }
      if (content.inputTranscription?.text) handlers.onTranscript('room', content.inputTranscription.text);
      if (content.outputTranscription?.text) handlers.onTranscript('stand', content.outputTranscription.text);
      if (content.interrupted) handlers.onInterrupted();
      if (content.turnComplete) handlers.onTurnComplete?.();
    }
    // Stand's one tool: it calls open_the_floor when it hands the floor to the audience.
    for (const call of message.toolCall?.functionCalls ?? []) {
      if (call.name === FLOOR_TOOL.name) handlers.onSignal?.('floor_open');
      try {
        // SILENT: note the result without prompting Stand to say anything about it.
        session.sendToolResponse({ functionResponses: [{ id: call.id, name: call.name, response: { result: 'ok' }, scheduling: 'SILENT' }] });
      } catch { /* the socket is between connections */ }
    }
    if (message.usageMetadata) handlers.onUsage(message.usageMetadata);
    const update = message.sessionResumptionUpdate;
    if (update?.resumable && update.newHandle) handle = update.newHandle;
    // A connection lasts about ten minutes. The server warns with goAway before it drops.
    if (message.goAway) resume('the server announced it will disconnect');
  }

  function open(resumeHandle) {
    const mine = ++generation;
    return ai.live.connect({
      model: MODEL,
      config: {
        responseModalities: [Modality.AUDIO],
        systemInstruction: instructions,
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: VOICE } } },
        inputAudioTranscription: {},
        outputAudioTranscription: {},
        // Without compression an audio session ends after 15 minutes.
        contextWindowCompression: { slidingWindow: {} },
        sessionResumption: resumeHandle ? { handle: resumeHandle } : {},
        tools: [{ functionDeclarations: [FLOOR_TOOL] }],
        ...(Object.keys(detection).length && { realtimeInputConfig: { automaticActivityDetection: detection } }),
      },
      callbacks: {
        onopen: () => {},
        onmessage: (message) => { if (mine === generation) onMessage(message); },
        onerror: (event) => { if (mine === generation) handlers.onError(new Error(event?.message || 'Gemini Live error')); },
        onclose: (event) => {
          if (mine !== generation || closing || resuming) return;
          if (handle) resume('the connection closed');
          else handlers.onClose(event?.reason || 'the connection closed');
        },
      },
    });
  }

  async function resume(why) {
    if (resuming || closing) return;
    if (!handle) {
      handlers.onError(new Error(`Gemini: ${why}, and there is no resumption handle yet`));
      return;
    }
    resuming = true;
    const previous = session;
    try {
      session = await open(handle);
    } catch (err) {
      handlers.onError(err);
      handlers.onClose('could not resume the session');
      return;
    } finally {
      resuming = false;
    }
    try { previous?.close(); } catch { /* already closed */ }
  }

  session = await open(null);

  return {
    model: MODEL,
    inputRate,
    outputRate,
    sendAudio(buf) {
      try {
        session.sendRealtimeInput({ audio: { data: buf.toString('base64'), mimeType: `audio/pcm;rate=${inputRate}` } });
      } catch { /* the socket is between connections; this chunk is lost */ }
    },
    // A message that must be acted on, such as "begin the talk".
    instruct(text) {
      session.sendClientContent({ turns: [{ role: 'user', parts: [{ text }] }], turnComplete: true });
    },
    // A message Stand may answer with silence, such as "carry on if you are not done".
    // Sent as realtime text, it is treated like something heard in the room, which
    // the model is free to ignore; a complete turn would force it to say something.
    nudge(text) {
      if (process.env.GEMINI_NUDGE_VIA === 'turn') return this.instruct(text);
      session.sendRealtimeInput({ text });
    },
    async close() {
      closing = true;
      try { session?.close(); } catch { /* already closed */ }
    },
  };
}
