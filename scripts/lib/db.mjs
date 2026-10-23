// Shared helpers for the database scripts (db-preflight, db-migrate). No npm dependencies: psql
// does the talking. Connection URLs come from this project's .env only (shell variables are
// ignored), are handed to psql as PG* environment variables (never on the command line), and are
// never printed; psql output is scrubbed of the URL and password before it is shown.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {parseEnv} from 'node:util';

export const root = fileURLToPath(new URL('../../', import.meta.url));

// Returns a getter over .env values, or exits if .env is missing. `file` overrides the project
// .env (used by the synthetic test harness to point at its disposable cluster).
export function loadProjectEnv(file) {
  const envFile = file ? path.resolve(file) : path.join(root, '.env');
  if (!fs.existsSync(envFile)) {
    console.error(file ? 'The given env file does not exist.' : '.env not found in the project root (copy .env.example to .env and fill it in locally).');
    process.exit(1);
  }
  const config = parseEnv(fs.readFileSync(envFile, 'utf8'));
  return name => (config[name] ?? '').trim();
}

// Exits with the names (never values) of required settings that are empty.
export function requireSettings(env, names) {
  const missing = names.filter(n => !env(n));
  if (missing.length) {
    console.error(`Missing in .env: ${missing.join(', ')}. Fill it in locally; do not paste it anywhere.`);
    process.exit(1);
  }
}

// URL query parameters psql understands, mapped to their libpq environment variables.
const PARAM_ENV = {
  sslmode: 'PGSSLMODE', sslrootcert: 'PGSSLROOTCERT', sslcert: 'PGSSLCERT', sslkey: 'PGSSLKEY',
  channel_binding: 'PGCHANNELBINDING', gssencmode: 'PGGSSENCMODE', connect_timeout: 'PGCONNECT_TIMEOUT',
  target_session_attrs: 'PGTARGETSESSIONATTRS', application_name: 'PGAPPNAME',
};

// Returns {env, user, secrets} for psql, or {error} (fixed text only; nothing from the URL is
// echoed except a rejected query-parameter name). `options` becomes PGOPTIONS.
export function connectionEnv(value, expected, {appName, options}) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return {error: 'not a valid URL'};
  }
  if (url.protocol !== 'postgres:' && url.protocol !== 'postgresql:') return {error: 'scheme must be postgres:// or postgresql://'};
  const database = decodeURIComponent(url.pathname.replace(/^\//, ''));
  if (!url.hostname || !url.username || !database) return {error: 'host, user and database name are required'};
  if (database !== expected) return {error: 'database name in the URL differs from BOOKING_DATABASE_EXPECTED_NAME'};
  const out = {
    PGHOST: url.hostname.replace(/^\[|\]$/g, ''), PGPORT: url.port || '5432',
    PGUSER: decodeURIComponent(url.username), PGDATABASE: database,
    PGAPPNAME: appName, PGCONNECT_TIMEOUT: '10', PGOPTIONS: options,
  };
  if (url.password) out.PGPASSWORD = decodeURIComponent(url.password);
  for (const [key, val] of url.searchParams) {
    if (!(key in PARAM_ENV)) return {error: `unsupported URL parameter "${key}"`};
    out[PARAM_ENV[key]] = val;
  }
  return {env: out, user: out.PGUSER, secrets: [value, out.PGPASSWORD, url.password].filter(Boolean)};
}

function findPsql() {
  const exe = process.platform === 'win32' ? 'psql.exe' : 'psql';
  if (process.env.PG_BIN) return path.join(process.env.PG_BIN, exe);
  const probe = spawnSync(exe, ['--version'], {encoding: 'utf8'});
  if (!probe.error) return exe;
  const fallback = path.join('C:\\Program Files\\PostgreSQL\\18\\bin', exe);
  return fs.existsSync(fallback) ? fallback : exe;
}
const psql = findPsql();

export function runPsql(conn, args, input) {
  const childEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('PG')));
  const r = spawnSync(psql, ['-X', '-v', 'ON_ERROR_STOP=1', ...args], {
    cwd: root, env: {...childEnv, ...conn.env}, input, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
  });
  const redact = text => conn.secrets.reduce((t, s) => t.split(s).join('[redacted]'), text ?? '');
  return {status: r.error ? -1 : r.status, stdout: redact(r.stdout), stderr: redact(r.stderr || r.error?.message)};
}

// Runs one query and returns its rows as arrays of strings, or {error}.
export function queryRows(conn, sql) {
  const r = runPsql(conn, ['-A', '-t', '-F', '\x1f', '-c', sql]);
  if (r.status !== 0) return {error: r.stderr.trim()};
  return {rows: r.stdout.split(/\r?\n/).filter(Boolean).map(line => line.split('\x1f'))};
}

// Connects and confirms the database is exactly `expected`. Returns {database, role} or {error}.
export function identify(conn, expected) {
  const q = queryRows(conn, 'SELECT current_database(), current_user');
  if (q.error) return {error: `could not connect.\n${q.error}`};
  const [database, role] = q.rows[0] ?? [];
  if (database !== expected) return {error: `connected database is "${database}", expected "${expected}"`};
  return {database, role};
}
