import { createHash } from 'node:crypto';

export class BridgeError extends Error {}
export const hash = (value) => createHash('sha256').update(value).digest('hex');

// Protocol references are listed in README.md. This is not an official API.
export class LibreClient {
  constructor({ email, password, fetchImpl = fetch, version = '4.16.0' }) {
    this.email = email;
    this.password = password;
    this.fetch = fetchImpl;
    this.version = version;
    this.base = 'https://api.libreview.io';
  }

  async request(path, body, authenticated = false) {
    const headers = { product: 'llu.android', version: this.version, Accept: 'application/json' };
    if (body) headers['Content-Type'] = 'application/json';
    if (authenticated) {
      headers.Authorization = `Bearer ${this.token}`;
      headers['account-id'] = this.accountId;
    }
    let response;
    try {
      response = await this.fetch(`${this.base}${path}`, {
        method: body ? 'POST' : 'GET', headers,
        body: body ? JSON.stringify(body) : undefined,
        redirect: 'error', // Never forward credentials through an HTTP redirect.
        signal: AbortSignal.timeout(20_000),
      });
    } catch {
      throw new BridgeError('Network request failed or timed out. No response details were logged.');
    }
    if (!response.ok) {
      const error = new BridgeError(
        response.status === 429
          ? 'Rate limit reached. Stop polling and try again later.'
          : `Cloud request failed (HTTP ${response.status}).`,
      );
      error.httpStatus = response.status;
      throw error;
    }
    let result;
    try { result = await response.json(); }
    catch { throw new BridgeError('The cloud returned an invalid JSON response.'); }
    if (!result || typeof result !== 'object') throw new BridgeError('Unexpected cloud response.');
    if (result.status !== 0) {
      if (result.status === 4) {
        throw new BridgeError('Open LibreLinkUp and review the required terms. This client cannot accept terms.');
      }
      // Do not print server messages or payloads: they can contain private data.
      const status = Number.isInteger(result.status) ? result.status : 'unknown';
      throw new BridgeError(`Cloud API status ${status}. Check LibreLinkUp login and account access.`);
    }
    return result.data;
  }

  async login() {
    this.token = undefined;
    this.accountId = undefined;
    const visited = new Set();
    for (let attempt = 0; attempt < 4; attempt++) {
      if (visited.has(this.base)) throw new BridgeError('Regional login redirect loop.');
      visited.add(this.base);
      const data = await this.request('/llu/auth/login', { email: this.email, password: this.password });
      if (data?.redirect) {
        // A region is a label, not a server-supplied URL. Reject host/path injection.
        if (typeof data.region !== 'string' || !/^[a-z]{2,8}$/.test(data.region)) {
          throw new BridgeError('Unrecognized regional login response.');
        }
        this.base = `https://api-${data.region}.libreview.io`;
        continue;
      }
      if (typeof data?.authTicket?.token !== 'string' || !data.authTicket.token ||
          typeof data?.user?.id !== 'string' || !data.user.id) {
        throw new BridgeError('Login response lacks the expected token or account identifier.');
      }
      this.token = data.authTicket.token;
      this.accountId = hash(data.user.id);
      return;
    }
    throw new BridgeError('Too many regional login redirects.');
  }

  async get(path) {
    if (!this.token) await this.login();
    try { return await this.request(path, undefined, true); }
    catch (error) {
      if (error.httpStatus !== 401) throw error;
      // Retry once only. A repeated 401 or a rate limit stops the client.
      await this.login();
      return this.request(path, undefined, true);
    }
  }

  async connections() {
    const data = await this.get('/llu/connections');
    if (!Array.isArray(data) || data.some((c) => typeof c?.patientId !== 'string' || !c.patientId)) {
      throw new BridgeError('Unexpected connections response.');
    }
    return data;
  }

  async graph(patientId) {
    const data = await this.get(`/llu/connections/${encodeURIComponent(patientId)}/graph`);
    if (!Array.isArray(data?.graphData)) throw new BridgeError('Unexpected graph response.');
    return data;
  }

  dispose() {
    // Best effort only: JavaScript cannot guarantee secure memory erasure.
    this.email = this.password = this.token = this.accountId = undefined;
  }
}

// FactoryTimestamp is treated as UTC by existing uploader implementations.
// Do not parse the localized Timestamp as the Mac's local time.
export function factoryTime(value) {
  const match = typeof value === 'string' && value.match(
    /^(\d{1,2})\/(\d{1,2})\/(\d{4}) (\d{1,2}):(\d{2}):(\d{2}) (AM|PM)$/,
  );
  if (!match) throw new BridgeError('Unrecognized FactoryTimestamp format.');
  const [, mo, da, yr, hr, mi, se, ap] = match;
  const [month, day, year, hour, minute, second] = [mo, da, yr, hr, mi, se].map(Number);
  if (year < 2000 || month < 1 || month > 12 || day < 1 || day > 31 ||
      hour < 1 || hour > 12 || minute > 59 || second > 59) {
    throw new BridgeError('Invalid FactoryTimestamp.');
  }
  const date = new Date(Date.UTC(year, month - 1, day, hour % 12 + (ap === 'PM' ? 12 : 0), minute, second));
  if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) {
    throw new BridgeError('Invalid FactoryTimestamp calendar date.');
  }
  return date.toISOString();
}

export function normalize(measurement, patientId) {
  const value = measurement?.ValueInMgPerDl;
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) {
    throw new BridgeError('Reading lacks a valid ValueInMgPerDl. No unit conversion was guessed.');
  }
  if (typeof measurement.isHigh !== 'boolean' || typeof measurement.isLow !== 'boolean') {
    throw new BridgeError('Reading lacks the expected range flags.');
  }
  const time = factoryTime(measurement.FactoryTimestamp);
  const outOfRange = measurement.isHigh || measurement.isLow;
  return {
    id: hash(`${patientId}\n${time}`),
    timestamp: time,
    valueMgDl: outOfRange ? null : value,
    valueMmolL: outOfRange ? null : Math.round(value / 18.0182 * 100) / 100,
    outOfRange,
    // Useful for local comparison. Never include names, account IDs, or tokens.
    sourceLocalTimestamp: typeof measurement.Timestamp === 'string' ? measurement.Timestamp : null,
    source: 'LibreLinkUp',
  };
}

export function normalizeBatch(history, latest, patientId) {
  const unique = new Map();
  for (const measurement of [...history, ...(latest ? [latest] : [])]) {
    const reading = normalize(measurement, patientId);
    unique.set(reading.id, reading); // Prefer the latest endpoint for matching timestamps.
  }
  return [...unique.values()].sort((a, b) => a.timestamp.localeCompare(b.timestamp));
}
