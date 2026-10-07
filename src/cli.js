import { emitKeypressEvents } from 'node:readline';
import { setTimeout as sleep } from 'node:timers/promises';
import { BridgeError, LibreClient, normalizeBatch } from './client.js';

const help = `Usage: npm start -- [--watch SECONDS] [--show-readings]

Prompts for LibreLinkUp credentials in your terminal. The password is hidden.
Default: fetch once and show a summary without glucose values.
--watch SECONDS   Poll at this interval (minimum 60 seconds).
--show-readings   Print normalized readings. Terminal output is sensitive.
--help           Show this help without logging in.

No credentials, tokens, or readings are saved by this program.
Unofficial research client. Not for treatment decisions or alarms.
`;

function options(args) {
  let interval = 0;
  let showReadings = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--show-readings') showReadings = true;
    else if (args[i] === '--watch') {
      const raw = args[++i];
      interval = Number(raw);
      if (!/^\d+$/.test(raw ?? '') || !Number.isSafeInteger(interval) || interval < 60 || interval > 86400) {
        throw new BridgeError('Use a watch interval between 60 and 86400 seconds.');
      }
    } else throw new BridgeError('Unknown option. Run npm start -- --help.');
  }
  return { interval, showReadings };
}

// Read interactively, not through arguments, environment files, or shell history.
function prompt(label, hidden = false) {
  const input = process.stdin;
  const output = process.stderr;
  if (!input.isTTY || !output.isTTY) throw new BridgeError('Run this command in an interactive terminal.');
  return new Promise((resolve, reject) => {
    let text = '';
    const wasRaw = input.isRaw;
    output.write(label);
    input.setRawMode(true);
    input.resume();
    function finish(error) {
      input.removeListener('keypress', onKey);
      input.setRawMode(wasRaw);
      input.pause();
      output.write('\n');
      if (error) reject(error);
      else resolve(text);
      text = '';
    }
    function onKey(str, key = {}) {
      if (key.ctrl && ['c', 'd'].includes(key.name)) return finish(new BridgeError('Canceled.'));
      if (key.name === 'return' || key.name === 'enter') return finish();
      if (key.name === 'backspace') {
        if (text.length && !hidden) output.write('\b \b');
        text = Array.from(text).slice(0, -1).join('');
      } else if (!key.ctrl && !key.meta && str && !/[\x00-\x1f\x7f-\x9f]/.test(str)) {
        text += str;
        if (!hidden) output.write(str);
      }
    }
    input.on('keypress', onKey);
  });
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--help')) { console.log(help); return; }
  const { interval, showReadings } = options(args);
  emitKeypressEvents(process.stdin);
  console.error('LibreLinkUp research client. Keep LibreLink running normally.');
  console.error('No files are saved. Ctrl+C stops the client.');
  if (showReadings) console.error('Privacy: glucose readings will appear in terminal scrollback.');
  const email = (await prompt('LibreLinkUp email: ')).trim();
  const password = await prompt('LibreLinkUp password (hidden): ', true);
  if (!email || !password) throw new BridgeError('Email and password are required.');
  const client = new LibreClient({ email, password });
  const stop = new AbortController();
  const cancel = () => stop.abort();
  process.on('SIGINT', cancel);
  process.on('SIGTERM', cancel);
  try {
    let connections = await client.connections();
    if (!connections.length) throw new BridgeError('No shared connections. Accept the invitation in LibreLinkUp first.');
    let selected = connections[0];
    if (connections.length > 1) {
      console.error('Select your own connection. Names appear only in this terminal.');
      connections.forEach((c, i) => console.error(`${i + 1}: ${JSON.stringify(`${c.firstName ?? ''} ${c.lastName ?? ''}`.trim())}`));
      const answer = await prompt('Connection number: ');
      const index = Number(answer) - 1;
      if (!/^\d+$/.test(answer) || !Number.isInteger(index) || !connections[index]) {
        throw new BridgeError('Invalid connection selection.');
      }
      selected = connections[index];
    }
    // Keep the patient ID, not the list position, across polls.
    const patientId = selected.patientId;
    const seen = new Map();
    let firstPoll = true;
    while (!stop.signal.aborted) {
      if (!firstPoll) connections = await client.connections();
      firstPoll = false;
      selected = connections.find((c) => c.patientId === patientId);
      if (!selected) throw new BridgeError('The selected connection is no longer shared.');
      const graph = await client.graph(patientId);
      if (graph.connection?.patientId && graph.connection.patientId !== patientId) {
        throw new BridgeError('Graph response does not match the selected connection.');
      }
      const latest = graph.connection?.glucoseMeasurement ?? selected.glucoseMeasurement;
      const readings = normalizeBatch(graph.graphData, latest, patientId);
      const changed = readings.filter((r) => seen.get(r.id) !== JSON.stringify(r));
      for (const r of changed) seen.set(r.id, JSON.stringify(r));
      // Bound memory during long watches. No persistent deduplication in this prototype.
      while (seen.size > 10000) seen.delete(seen.keys().next().value);
      const newest = readings.at(-1);
      const ageSeconds = newest ? Math.round((Date.now() - Date.parse(newest.timestamp)) / 1000) : null;
      console.log(JSON.stringify({
        fetchedAt: new Date().toISOString(),
        endpoint: client.base,
        historyCount: graph.graphData.length,
        uniqueCount: readings.length,
        newOrChangedCount: changed.length,
        oldestTimestamp: readings[0]?.timestamp ?? null,
        newestTimestamp: newest?.timestamp ?? null,
        ageSeconds,
        timestampBasis: 'FactoryTimestamp interpreted as UTC; compare with LibreLinkUp',
        ...(showReadings ? { readings: changed } : {}),
      }, null, 2));
      if (ageSeconds !== null && ageSeconds < -120) {
        throw new BridgeError('The newest timestamp is in the future. Check the Mac clock and timestamp interpretation.');
      }
      if (!interval) break;
      try { await sleep(interval * 1000, undefined, { signal: stop.signal }); }
      catch (error) { if (error.name !== 'AbortError') throw error; }
    }
  } finally {
    client.dispose();
    process.removeListener('SIGINT', cancel);
    process.removeListener('SIGTERM', cancel);
  }
}

main().catch((error) => {
  console.error(error instanceof BridgeError ? error.message : 'Unexpected client error. Private response details were not logged.');
  process.exitCode = 1;
});
