// Local server for the browser rig: serves the page and relays audio between the
// page and a Stand session. It listens on this machine only.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { WebSocketServer } from 'ws';
import { POC, providerList, providers } from './env.js';
import { StandSession } from './session.js';

const PUBLIC = path.join(POC, 'public');
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8' };

export function startServer(port = Number(process.env.PORT || 5177)) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/api/config') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ providers: providerList() }));
    }
    const file = path.join(PUBLIC, path.normalize(url.pathname === '/' ? '/index.html' : url.pathname));
    if (!file.startsWith(PUBLIC + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404, { 'content-type': 'text/plain' });
      return res.end('Not found');
    }
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  });

  const wss = new WebSocketServer({ server, path: '/ws' });
  wss.on('connection', async (ws, req) => {
    const provider = new URL(req.url, 'http://localhost').searchParams.get('provider') || 'mock';
    const send = (message) => { if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(message)); };
    if (!providers[provider]?.ready()) {
      send({ type: 'error', message: `"${provider}" is not available. Is its API key in .env?` });
      return ws.close();
    }

    const session = new StandSession({ provider, label: 'browser' });
    session.on('audio', (buf) => { if (ws.readyState === ws.OPEN) ws.send(buf); });
    session.on('interrupted', () => send({ type: 'interrupted' }));
    session.on('transcript', (t) => send({ type: 'transcript', ...t }));
    session.on('state', (s) => send({ type: 'state', ...s }));
    session.on('nudge', () => send({ type: 'nudge' }));
    session.on('error', (err) => send({ type: 'error', message: err.message }));
    session.on('closed', (reason) => {
      console.log(`Session ended (${reason}). Run saved in ${session.dir}`);
      send({ type: 'closed', reason, dir: session.dir, summary: session.summary });
      ws.close();
    });

    ws.on('message', (data, isBinary) => {
      if (isBinary) return session.pushRoomAudio(data);
      let message;
      try { message = JSON.parse(data.toString()); } catch { return; }
      if (message.type === 'begin') session.begin();
      if (message.type === 'stop') session.close('stopped from the page');
    });
    ws.on('close', () => session.close('the page disconnected'));

    try {
      await session.open();
      console.log(`Session started with ${session.model}`);
      send({ type: 'ready', provider, model: session.model });
    } catch (err) {
      console.error(`Could not start a session with ${provider}: ${err.message}`);
      send({ type: 'error', message: err.message });
      ws.close();
    }
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    wss.on('error', () => {}); // the HTTP server reports the same error; this one must not crash the process
    server.listen(port, '127.0.0.1', () => resolve({ server, port, url: `http://localhost:${port}` }));
  });
}

// Run directly: node src/server.js
if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const { url } = await startServer();
    const ready = providerList().filter((p) => p.ready).map((p) => p.label).join(', ');
    console.log(`Stand PoC is running at ${url}\nVoice models available: ${ready}\nPress Ctrl+C to stop.`);
  } catch (err) {
    if (err.code === 'EADDRINUSE') {
      console.error(`Stand PoC is already running. Open http://localhost:${err.port}, or stop it first with: npm run stop`);
    } else {
      console.error(`Could not start: ${err.message}`);
    }
    process.exit(1);
  }
}
