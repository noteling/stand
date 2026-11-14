// Every adapter connects one voice model and exposes the same small surface:
//
//   connect({ instructions, handlers }) -> { model, inputRate, outputRate, sendAudio(buf), instruct(text), close() }
//
// `sendAudio` takes mono 16-bit PCM at `inputRate`. `instruct` sends a text message from
// the rig itself (start the talk, carry on). Handlers the adapter calls:
//
//   onAudio(buf)            speech from the model, mono 16-bit PCM at `outputRate`
//   onInterrupted()         the model cut its own speech short; drop anything not yet played
//   onTranscript(who, text) a transcript fragment, who is 'stand' or 'room'
//   onUsage(obj)            whatever usage figures the provider reports
//   onError(err), onClose(reason)
export async function connectAdapter(provider, options) {
  if (provider === 'gemini') return (await import('./gemini.js')).connect(options);
  if (provider === 'openai') return (await import('./openai-live.js')).connect(options);
  if (provider === 'mock') return (await import('./mock.js')).connect(options);
  throw new Error(`Unknown voice model "${provider}"`);
}
