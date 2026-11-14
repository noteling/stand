// GPT-Live adapter over the primary WebSocket. Written from OpenAI's docs and the SDK's
// type definitions (openai 7.55.0) on 2026-11-11; not yet run against the live service.
//
// GPT-Live is full-duplex: it sends speech at the pace it is spoken and stops by itself
// when someone talks over it, so there is no "interrupted" event to forward.
import WebSocket from 'ws';
import { keys, providers } from '../env.js';

const URL = 'wss://api.openai.com/v1/live/sessions';
const MODEL = process.env.OPENAI_LIVE_MODEL || 'gpt-live-1';
const VOICE = process.env.OPENAI_VOICE || 'marin';
const { inputRate, outputRate } = providers.openai;

export function connect({ instructions, handlers }) {
  if (!keys.openai) return Promise.reject(new Error('OPENAI_API_KEY is not set (put it in .env at the repo root)'));

  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL, { headers: { Authorization: `Bearer ${keys.openai}` } });
    let started = false;
    let closing = false;
    let counter = 0;
    const send = (event) => { if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(event)); };
    const id = (prefix) => `${prefix}_${++counter}`;

    const api = {
      model: MODEL,
      inputRate,
      outputRate,
      sendAudio(buf) {
        send({ type: 'session.input_audio.append', audio: buf.toString('base64') });
      },
      instruct(text) {
        send({ type: 'session.instructions.append', event_id: id('instruct'), delegation_id: null, content: text });
      },
      close() {
        closing = true;
        return new Promise((done) => {
          const finish = () => { clearTimeout(timer); try { ws.close(); } catch { /* already closed */ } done(); };
          const timer = setTimeout(finish, 3000);
          ws.once('close', finish);
          send({ type: 'session.close' });
        });
      },
    };

    ws.on('open', () => {
      send({
        type: 'session.start',
        event_id: 'start',
        session: {
          model: MODEL,
          instructions,
          // One format for both directions on a WebSocket session.
          audio: { format: { type: 'audio/pcm', rate: outputRate }, output: { voice: VOICE } },
          delegation: { type: 'client' },
        },
      });
    });

    ws.on('message', (data) => {
      let event;
      try { event = JSON.parse(data.toString()); } catch { return; }
      switch (event.type) {
        case 'session.started':
          started = true;
          resolve(api);
          break;
        case 'session.output_audio.delta':
          handlers.onAudio(Buffer.from(event.delta, 'base64'));
          break;
        case 'session.output_transcript.delta':
          handlers.onTranscript('stand', event.delta);
          break;
        case 'session.input_transcript.delta':
          handlers.onTranscript('room', event.delta);
          break;
        case 'session.usage.updated':
          handlers.onUsage({ seconds: event.usage?.seconds, contextRatio: event.context_window?.usage_ratio });
          break;
        case 'session.delegation.created':
          // The model asked a backend for help. There is none, so tell it quietly.
          if (event.delegation?.target === 'client') {
            send({
              type: 'session.thinking.append',
              event_id: id('nobackend'),
              delegation_id: event.delegation.id,
              content: 'There is no backend in this session. Answer from what you already know, or say you do not know.',
            });
          }
          break;
        case 'error': {
          const detail = event.error || {};
          const err = new Error(`GPT-Live: ${detail.message || 'error'}${detail.code ? ` (${detail.code})` : ''}`);
          if (started) handlers.onError(err);
          else reject(err);
          break;
        }
        case 'session.closed':
          if (event.usage) handlers.onUsage({ seconds: event.usage.seconds });
          if (!closing) handlers.onClose(event.reason || 'the session closed');
          break;
        default:
          break;
      }
    });

    ws.on('unexpected-response', (_request, response) => {
      const why = response.statusCode === 401 ? 'the API key was rejected' : `HTTP ${response.statusCode}`;
      reject(new Error(`GPT-Live refused the connection: ${why}`));
    });
    ws.on('error', (err) => {
      if (started) handlers.onError(err);
      else reject(err);
    });
    ws.on('close', (code) => {
      if (!started) reject(new Error(`GPT-Live closed the connection before the session started (code ${code})`));
      else if (!closing) handlers.onClose(`the connection closed (code ${code})`);
    });
  });
}
