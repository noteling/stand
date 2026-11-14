// The page is only a microphone and a speaker for a Stand session running on the
// local server. For tests: ?nomic sends silence instead of the microphone,
// ?nomic=tone adds a one-second tone every six seconds as a fake interruption,
// ?provider=<id> preselects a voice model, ?autostart begins without a click.
const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const NO_MIC = params.has('nomic');
const TEST_TONE = params.get('nomic') === 'tone';
// ?noaec turns the browser's echo cancellation off, to test what it contributes:
// on speakers, Stand should then hear its own voice.
const ECHO_CANCELLATION = !params.has('noaec');

let config, ws, playCtx, captureCtx, player, micStream, clockTimer, toneTimer, startedAt;
let standPlaying = false, roomSpeaking = false, running = false;
let lastLine = null;

// Counters the smoke test reads to confirm audio and events are flowing.
const stats = { micChunks: 0, audioChunks: 0, playChanges: 0, interruptions: 0, nudges: 0, fragments: 0, errors: [], closed: null };
window.__stand = stats;

init().catch((err) => fail(err.message));

async function init() {
  config = await (await fetch('/api/config')).json();
  for (const p of config.providers) {
    const option = new Option(p.ready ? p.label : `${p.label} (no API key)`, p.id);
    option.disabled = !p.ready;
    $('provider').add(option);
  }
  const firstReal = config.providers.find((p) => p.ready && p.id !== 'mock');
  $('provider').value = params.get('provider') || (firstReal ? firstReal.id : 'mock');
  $('start').onclick = start;
  $('stop').onclick = () => ws?.send(JSON.stringify({ type: 'stop' }));
  if (params.has('autostart')) start();
}

async function start() {
  const provider = config.providers.find((p) => p.id === $('provider').value);
  $('start').disabled = true;
  $('provider').disabled = true;
  $('log').textContent = '';
  lastLine = null;
  setStatus('Connecting…');

  // Create the audio contexts inside the click, so the browser lets them play.
  playCtx = new AudioContext({ sampleRate: provider.outputRate });
  captureCtx = new AudioContext({ sampleRate: provider.inputRate });
  try {
    await playCtx.audioWorklet.addModule('player-worklet.js');
    await captureCtx.audioWorklet.addModule('capture-worklet.js');
    if (!NO_MIC) {
      micStream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: ECHO_CANCELLATION, noiseSuppression: ECHO_CANCELLATION, autoGainControl: ECHO_CANCELLATION, channelCount: 1 },
      });
    }
  } catch (err) {
    cleanup();
    return fail(`Could not set up audio: ${err.message}`);
  }

  player = new AudioWorkletNode(playCtx, 'player', { numberOfInputs: 0, outputChannelCount: [1] });
  player.connect(playCtx.destination);
  player.port.onmessage = (e) => { stats.playChanges += 1; standPlaying = e.data.playing; renderStatus(); };

  ws = new WebSocket(`ws://${location.host}/ws?provider=${provider.id}`);
  ws.binaryType = 'arraybuffer';
  ws.onmessage = (e) => (typeof e.data === 'string' ? onEvent(JSON.parse(e.data), provider) : onAudio(e.data));
  ws.onclose = cleanup;
}

function onEvent(event, provider) {
  switch (event.type) {
    case 'ready':
      startCapture(provider);
      ws.send(JSON.stringify({ type: 'begin' }));
      running = true;
      startedAt = performance.now();
      clockTimer = setInterval(renderStatus, 500);
      $('stop').disabled = false;
      mark(`Connected to ${event.model}. The talk is starting.${ECHO_CANCELLATION ? '' : ' Echo cancellation is OFF for this test.'}`);
      renderStatus();
      break;
    case 'interrupted':
      stats.interruptions += 1;
      player.port.postMessage('flush');
      mark('Stand stopped mid-speech.');
      break;
    case 'transcript':
      stats.fragments += 1;
      say(event.who, event.text);
      break;
    case 'state':
      roomSpeaking = event.roomSpeaking;
      renderStatus();
      break;
    case 'nudge':
      stats.nudges += 1;
      mark('Silence: the stage manager nudged Stand to carry on.');
      break;
    case 'error':
      fail(event.message);
      break;
    case 'closed':
      stats.closed = event.reason;
      mark(`Session ended: ${event.reason}. Run saved in ${event.dir}`);
      break;
  }
}

function startCapture(provider) {
  const capture = new AudioWorkletNode(captureCtx, 'capture', {
    processorOptions: { chunk: Math.round(provider.inputRate * 0.04) },
  });
  capture.port.onmessage = (e) => {
    stats.micChunks += 1;
    if (ws.readyState === WebSocket.OPEN) ws.send(e.data);
  };
  if (micStream) {
    captureCtx.createMediaStreamSource(micStream).connect(capture);
  } else if (TEST_TONE) {
    const tone = captureCtx.createOscillator();
    const gate = captureCtx.createGain();
    gate.gain.value = 0;
    tone.connect(gate).connect(capture);
    tone.start();
    toneTimer = setInterval(() => {
      const now = captureCtx.currentTime;
      gate.gain.setValueAtTime(0.3, now);
      gate.gain.setValueAtTime(0, now + 1);
    }, 6000);
  }
  // A worklet only runs while it leads to the output. The silent gain keeps it
  // running without playing the microphone back through the speakers.
  const silent = captureCtx.createGain();
  silent.gain.value = 0;
  capture.connect(silent).connect(captureCtx.destination);
}

function onAudio(buffer) {
  stats.audioChunks += 1;
  const pcm = new Int16Array(buffer, 0, Math.floor(buffer.byteLength / 2));
  const samples = new Float32Array(pcm.length);
  for (let i = 0; i < pcm.length; i++) samples[i] = pcm[i] / 32768;
  player.port.postMessage(samples.buffer, [samples.buffer]);
}

function cleanup() {
  running = false;
  clearInterval(clockTimer);
  clearInterval(toneTimer);
  micStream?.getTracks().forEach((track) => track.stop());
  micStream = null;
  playCtx?.close();
  captureCtx?.close();
  playCtx = captureCtx = null;
  standPlaying = roomSpeaking = false;
  $('start').disabled = false;
  $('provider').disabled = false;
  $('stop').disabled = true;
  setStatus('Idle');
}

function renderStatus() {
  if (!running) return;
  const elapsed = Math.floor((performance.now() - startedAt) / 1000);
  const time = `${Math.floor(elapsed / 60)}:${String(elapsed % 60).padStart(2, '0')}`;
  const what = standPlaying ? 'Stand is speaking' : roomSpeaking ? 'Hearing the room' : 'Listening';
  setStatus(what, `${time} · stopped mid-speech ${stats.interruptions}× · nudged ${stats.nudges}×`);
}

function setStatus(text, detail = '') {
  $('status').textContent = text;
  if (detail) {
    const span = document.createElement('span');
    span.className = 'dim';
    span.textContent = ` · ${detail}`;
    $('status').append(span);
  }
}

function say(who, text) {
  if (!lastLine || lastLine.dataset.who !== who) {
    lastLine = document.createElement('p');
    lastLine.className = who;
    lastLine.dataset.who = who;
    const name = document.createElement('b');
    name.textContent = who === 'stand' ? 'Stand: ' : 'Room: ';
    lastLine.append(name, document.createElement('span'));
    $('log').append(lastLine);
  }
  lastLine.lastChild.textContent += text;
  lastLine.scrollIntoView({ block: 'nearest' });
}

function mark(text, className = 'mark') {
  const p = document.createElement('p');
  p.className = className;
  p.textContent = text;
  $('log').append(p);
  lastLine = null;
  p.scrollIntoView({ block: 'nearest' });
}

function fail(message) {
  stats.errors.push(message);
  mark(message, 'error');
}
