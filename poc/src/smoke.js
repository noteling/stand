// Checks the browser page without a person: loads it in headless Chrome, runs the
// mock Stand, and confirms audio and events flow both ways, including an interruption.
// It makes no sound and uses no API key. The one thing it cannot cover is the real
// microphone: headless Chrome on a Mac hangs on the system's microphone permission,
// so the page feeds itself a test tone instead (?nomic=tone).
//
//   node src/smoke.js
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';
import { startServer } from './server.js';

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const DEBUG_PORT = Number(process.env.SMOKE_DEBUG_PORT || 9333);
const RUN_SECONDS = Number(process.env.SMOKE_SECONDS || 20);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

if (!fs.existsSync(CHROME)) {
  console.error(`Chrome was not found at ${CHROME}. Set CHROME to its path.`);
  process.exit(2);
}

const { server, url } = await startServer(Number(process.env.SMOKE_PORT || 5188));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'stand-smoke-'));
const chrome = spawn(CHROME, [
  '--headless=new',
  `--remote-debugging-port=${DEBUG_PORT}`,
  `--user-data-dir=${profile}`,
  '--autoplay-policy=no-user-gesture-required',
  '--mute-audio',
  '--no-first-run',
  '--no-default-browser-check',
  `${url}/?provider=mock&autostart&nomic=tone`,
], { stdio: 'ignore' });

let failed = false;
const problems = [];
try {
  // Find the page among Chrome's debugging targets.
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    await sleep(200);
    try {
      const targets = await (await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`)).json();
      target = targets.find((t) => t.type === 'page' && t.url.startsWith(url));
    } catch { /* Chrome is still starting */ }
  }
  if (!target) throw new Error('the page did not open in Chrome');

  const cdp = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { cdp.once('open', resolve); cdp.once('error', reject); });
  let nextId = 0;
  const pending = new Map();
  cdp.on('message', (data) => {
    const message = JSON.parse(data.toString());
    if (message.id && pending.has(message.id)) { pending.get(message.id)(message.result); pending.delete(message.id); }
    if (message.method === 'Runtime.exceptionThrown') problems.push(`page exception: ${message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text}`);
    if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') problems.push(`console error: ${message.params.args.map((a) => a.value ?? a.description).join(' ')}`);
  });
  const call = (method, params = {}) => new Promise((resolve) => { const id = ++nextId; pending.set(id, resolve); cdp.send(JSON.stringify({ id, method, params })); });
  const evaluate = async (expression) => (await call('Runtime.evaluate', { expression, returnByValue: true })).result?.value;
  await call('Runtime.enable');

  console.log(`Page open. Letting the mock talk run for ${RUN_SECONDS} seconds…`);
  await sleep(RUN_SECONDS * 1000);
  const during = JSON.parse(await evaluate('JSON.stringify(window.__stand)'));
  const shown = await evaluate("document.getElementById('status').textContent + ' | ' + document.getElementById('log').innerText.slice(0, 600)");
  await evaluate("document.getElementById('stop').click()");
  await sleep(1500);
  const after = JSON.parse(await evaluate('JSON.stringify(window.__stand)'));
  cdp.close();

  const checks = [
    ['the capture stream is running', during.micChunks > 100],
    ["Stand's audio reached the page", during.audioChunks > 50],
    ['the player started playing', during.playChanges > 0],
    ['transcript text arrived', during.fragments > 0],
    ['the test tone interrupted Stand and queued speech was dropped', during.interruptions > 0],
    ['no errors on the page', during.errors.length === 0 && problems.length === 0],
    ['Stop ended the session and saved the run', typeof after.closed === 'string'],
  ];
  for (const [name, ok] of checks) {
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}`);
    if (!ok) failed = true;
  }
  console.log(`  counters: ${JSON.stringify(during)}`);
  if (failed) console.log(`  the page showed: ${shown}`);
  for (const p of [...problems, ...during.errors]) console.log(`  problem: ${p}`);
} catch (err) {
  failed = true;
  console.error(`Smoke test could not run: ${err.message}`);
} finally {
  chrome.kill();
  server.close();
  await sleep(300);
  fs.rmSync(profile, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
