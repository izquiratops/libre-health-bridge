import test from 'node:test';
import assert from 'node:assert/strict';
import { BridgeError, LibreClient, factoryTime, hash, normalize, normalizeBatch } from '../src/client.js';

const reading = (overrides = {}) => ({
  FactoryTimestamp: '10/6/2026 6:30:00 AM',
  Timestamp: '10/6/2026 8:30:00 AM',
  ValueInMgPerDl: 108,
  Value: 6,
  GlucoseUnits: 1,
  isHigh: false,
  isLow: false,
  ...overrides,
});
const login = { user: { id: 'test-account' }, authTicket: { token: 'test-token' } };
function fixture(replies) {
  const calls = [];
  const client = new LibreClient({
    email: 'example@example.com', password: 'not-a-real-password',
    fetchImpl: async (url, options) => {
      calls.push({ url, ...options });
      assert.ok(replies.length, 'Unexpected extra request');
      const reply = replies.shift();
      return new Response(JSON.stringify(reply.body ?? { status: 0, data: reply.data }), {
        status: reply.http ?? 200, headers: { 'content-type': 'application/json' },
      });
    },
  });
  return { client, calls };
}

test('regional login, account hash, and graph path', async () => {
  const { client, calls } = fixture([
    { data: { redirect: true, region: 'eu' } }, { data: login },
    { data: [{ patientId: 'patient-a' }] }, { data: { graphData: [reading()] } },
  ]);
  assert.equal((await client.connections()).length, 1);
  assert.equal((await client.graph('patient-a')).graphData.length, 1);
  assert.equal(calls[0].url, 'https://api.libreview.io/llu/auth/login');
  assert.equal(calls[1].url, 'https://api-eu.libreview.io/llu/auth/login');
  assert.equal(calls[0].headers.Authorization, undefined);
  assert.equal(calls[2].headers.Authorization, 'Bearer test-token');
  assert.equal(calls[2].headers['account-id'], hash('test-account'));
  assert.equal(calls[2].body, undefined);
  assert.equal(calls[3].url, 'https://api-eu.libreview.io/llu/connections/patient-a/graph');
  assert.ok(calls.every((c) => c.redirect === 'error'));
});

test('rejects regional host injection without sending a second login', async () => {
  const { client, calls } = fixture([{ data: { redirect: true, region: 'eu.attacker.example/' } }]);
  await assert.rejects(client.login(), /Unrecognized regional/);
  assert.equal(calls.length, 1);
});

test('detects regional redirect loops', async () => {
  const { client, calls } = fixture([
    { data: { redirect: true, region: 'eu' } }, { data: { redirect: true, region: 'eu' } },
  ]);
  await assert.rejects(client.login(), /redirect loop/);
  assert.equal(calls.length, 2);
});

test('requires terms acceptance in the official app', async () => {
  const { client, calls } = fixture([{ body: { status: 4, data: { authTicket: { token: 'private' } } } }]);
  await assert.rejects(client.login(), /review the required terms/);
  assert.equal(calls.length, 1);
});

test('reauthenticates once after HTTP 401', async () => {
  const { client, calls } = fixture([
    { data: login }, { http: 401 }, { data: login }, { data: [] },
  ]);
  assert.deepEqual(await client.connections(), []);
  assert.equal(calls.length, 4);
});

test('stops after a second HTTP 401', async () => {
  const { client, calls } = fixture([
    { data: login }, { http: 401 }, { data: login }, { http: 401 },
  ]);
  await assert.rejects(client.connections(), /HTTP 401/);
  assert.equal(calls.length, 4);
});

test('stops on rate limits instead of retrying', async () => {
  const { client, calls } = fixture([{ data: login }, { http: 429 }]);
  await assert.rejects(client.connections(), /Rate limit/);
  assert.equal(calls.length, 2);
});

test('does not expose private server messages', async () => {
  const { client } = fixture([{ body: { status: 2, error: { message: 'SECRET-EMAIL-AND-TOKEN' } } }]);
  await assert.rejects(client.login(), (e) => e instanceof BridgeError && !e.message.includes('SECRET'));
});

test('rejects malformed successful responses', async () => {
  const { client } = fixture([{ data: { user: { id: 'a' } } }]);
  await assert.rejects(client.login(), /lacks the expected/);
  const f = fixture([{ data: login }, { data: [{ patientId: null }] }]);
  await assert.rejects(f.client.connections(), /Unexpected connections/);
  const g = fixture([{ data: login }, { data: {} }]);
  await assert.rejects(g.client.graph('a'), /Unexpected graph/);
});

test('network exception details are not exposed', async () => {
  const client = new LibreClient({ fetchImpl: async () => { throw new Error('SECRET'); } });
  await assert.rejects(client.login(), (e) => e instanceof BridgeError && !e.message.includes('SECRET'));
});

test('dispose clears client references to credentials', () => {
  const { client } = fixture([]);
  client.token = 'private';
  client.dispose();
  assert.equal(client.email, undefined);
  assert.equal(client.password, undefined);
  assert.equal(client.token, undefined);
});

test('timestamps do not depend on the computer timezone', () => {
  assert.equal(factoryTime('10/6/2026 6:30:00 AM'), '2026-10-06T06:30:00.000Z');
  assert.equal(factoryTime('10/6/2026 12:00:00 AM'), '2026-10-06T00:00:00.000Z');
  assert.equal(factoryTime('10/6/2026 12:00:00 PM'), '2026-10-06T12:00:00.000Z');
  assert.equal(factoryTime('10/25/2026 1:30:00 AM'), '2026-10-25T01:30:00.000Z');
  assert.equal(factoryTime('2/29/2028 1:30:00 AM'), '2028-02-29T01:30:00.000Z');
});

test('rejects malformed, overflowing, and ambiguous timestamps', () => {
  for (const value of [undefined, '', '06/10/26', '2/29/2026 1:00:00 AM', '13/1/2026 1:00:00 AM',
    '2/30/2026 1:00:00 AM', '1/1/2026 0:00:00 AM', '1/1/2026 13:00:00 PM', '1/1/2026 1:60:00 AM']) {
    assert.throws(() => factoryTime(value), BridgeError);
  }
});

test('uses the explicit mg/dL field rather than the display units', () => {
  const r = normalize(reading(), 'patient-a');
  assert.equal(r.valueMgDl, 108);
  assert.equal(r.valueMmolL, 5.99);
  assert.equal(r.timestamp, '2026-10-06T06:30:00.000Z');
  assert.equal(r.sourceLocalTimestamp, '10/6/2026 8:30:00 AM');
  assert.ok(!JSON.stringify(r).includes('patient-a'));
});

test('does not treat flagged readings as exact glucose values', () => {
  const r = normalize(reading({ isHigh: true }), 'patient-a');
  assert.equal(r.valueMgDl, null);
  assert.equal(r.valueMmolL, null);
  assert.equal(r.outOfRange, true);
});

test('does not guess missing units, numbers, or range flags', () => {
  for (const value of [undefined, null, '108', NaN, Infinity, -1, 0]) {
    assert.throws(() => normalize(reading({ ValueInMgPerDl: value }), 'a'), BridgeError);
  }
  assert.throws(() => normalize(reading({ isHigh: undefined }), 'a'), BridgeError);
});

test('deduplicates overlap and sorts, preferring the latest value', () => {
  const history = [reading(), reading({ FactoryTimestamp: '10/6/2026 6:00:00 AM' }), reading()];
  const result = normalizeBatch(history, reading({ ValueInMgPerDl: 109 }), 'patient-a');
  assert.equal(result.length, 2);
  assert.equal(result[0].timestamp, '2026-10-06T06:00:00.000Z');
  assert.equal(result[1].valueMgDl, 109);
  assert.notEqual(normalize(reading(), 'a').id, normalize(reading(), 'b').id);
});

test('empty graph and missing latest reading produce an empty batch', () => {
  assert.deepEqual(normalizeBatch([], undefined, 'patient-a'), []);
});
