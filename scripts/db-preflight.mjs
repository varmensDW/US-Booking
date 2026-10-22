// Read-only booking DB preflight: `npm run db:preflight`.
//
// Reads BOOKING_DATABASE_URL (and BOOKING_MIGRATION_DATABASE_URL, when supplied) from this
// project's .env only; shell variables are ignored. Each URL is passed to psql as PG* environment
// variables, never on the command line, and is never printed. For each target it:
//   1. connects and stops unless current_database() is exactly BOOKING_DATABASE_EXPECTED_NAME;
//   2. runs db/checks/booking_db_preflight.sql inside BEGIN READ ONLY ... ROLLBACK, with the
//      session default also set to read-only.
// It creates, grants and migrates nothing. psql comes from PG_BIN, PATH, or the default install.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {parseEnv} from 'node:util';

const root = fileURLToPath(new URL('../', import.meta.url));
const envFile = path.join(root, '.env');
// `-- --check=<name>` runs db/checks/<name>.sql instead of the default preflight (same safeguards).
const checkArg = process.argv.find(a => a.startsWith('--check='));
const checkName = checkArg ? checkArg.slice('--check='.length) : 'booking_db_preflight';
if (!/^[a-z0-9_]+$/.test(checkName)) {
  console.error('--check must be a file name in db/checks without the .sql extension.');
  process.exit(2);
}
const sqlFile = path.join(root, 'db', 'checks', `${checkName}.sql`);
if (!fs.existsSync(sqlFile)) {
  console.error(`No such check: db/checks/${checkName}.sql`);
  process.exit(2);
}

if (!fs.existsSync(envFile)) {
  console.error('.env not found in the project root (copy .env.example to .env and fill it in locally).');
  process.exit(1);
}
const config = parseEnv(fs.readFileSync(envFile, 'utf8'));
const env = name => (config[name] ?? '').trim();

const missing = ['BOOKING_DATABASE_URL', 'BOOKING_DATABASE_EXPECTED_NAME'].filter(n => !env(n));
if (missing.length) {
  console.error(`Missing in .env: ${missing.join(', ')}. Fill it in locally; do not paste it anywhere.`);
  process.exit(1);
}
const expected = env('BOOKING_DATABASE_EXPECTED_NAME');

// URL query parameters psql understands, mapped to their libpq environment variables.
const PARAM_ENV = {
  sslmode: 'PGSSLMODE', sslrootcert: 'PGSSLROOTCERT', sslcert: 'PGSSLCERT', sslkey: 'PGSSLKEY',
  channel_binding: 'PGCHANNELBINDING', gssencmode: 'PGGSSENCMODE', connect_timeout: 'PGCONNECT_TIMEOUT',
  target_session_attrs: 'PGTARGETSESSIONATTRS', application_name: 'PGAPPNAME',
};

// Returns {env, secrets} for psql, or {error} (fixed text only; nothing from the URL is echoed
// except a rejected query-parameter name).
function connectionEnv(value) {
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
    PGAPPNAME: 'us-booking-preflight', PGCONNECT_TIMEOUT: '10',
    PGOPTIONS: '-c default_transaction_read_only=on',
  };
  if (url.password) out.PGPASSWORD = decodeURIComponent(url.password);
  for (const [key, val] of url.searchParams) {
    if (!(key in PARAM_ENV)) return {error: `unsupported URL parameter "${key}"`};
    out[PARAM_ENV[key]] = val;
  }
  return {env: out, secrets: [value, out.PGPASSWORD, url.password].filter(Boolean)};
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

function runPsql(conn, args, input) {
  const childEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('PG')));
  const r = spawnSync(psql, ['-X', '-v', 'ON_ERROR_STOP=1', ...args], {
    cwd: root, env: {...childEnv, ...conn.env}, input, encoding: 'utf8',
  });
  const redact = text => conn.secrets.reduce((t, s) => t.split(s).join('[redacted]'), text ?? '');
  return {status: r.error ? -1 : r.status, stdout: redact(r.stdout), stderr: redact(r.stderr || r.error?.message)};
}

// The SQL file is split on its "-- N. title" headers so each result set prints under its title.
function preflightScript() {
  const sql = fs.readFileSync(sqlFile, 'utf8');
  const parts = sql.split(/^(?=-- \d+\. )/m).filter(p => /^-- \d+\. /.test(p));
  const titled = parts.map(p => `\\pset title '${p.split('\n')[0].slice(3).replace(/'/g, "''")}'\n${p}`);
  return ['BEGIN READ ONLY;', ...titled, 'ROLLBACK;', ''].join('\n');
}

function preflight(label, varName) {
  console.log(`\n=== ${label} (${varName}) ===`);
  const conn = connectionEnv(env(varName));
  if (conn.error) {
    console.log(`STOP: ${varName}: ${conn.error}.`);
    return false;
  }
  const id = runPsql(conn, ['-A', '-t', '-F', '|', '-c', 'SELECT current_database(), current_user']);
  if (id.status !== 0) {
    console.log(`STOP: could not connect.\n${id.stderr.trim()}`);
    return false;
  }
  const [database, role] = id.stdout.trim().split('|');
  if (database !== expected) {
    console.log(`STOP: connected database is "${database}", expected "${expected}". Preflight not run.`);
    return false;
  }
  console.log(`Connected: database ${database}, role ${role}. Running the read-only preflight.\n`);
  const r = runPsql(conn, ['-q'], preflightScript());
  process.stdout.write(r.stdout);
  if (r.status !== 0) {
    console.log(`Preflight failed (psql exit ${r.status}).\n${r.stderr.trim()}`);
    return false;
  }
  return true;
}

let ok = preflight('Runtime target', 'BOOKING_DATABASE_URL');
if (env('BOOKING_MIGRATION_DATABASE_URL')) ok = preflight('Migration target', 'BOOKING_MIGRATION_DATABASE_URL') && ok;
else console.log('\nBOOKING_MIGRATION_DATABASE_URL not supplied; only the runtime URL was inspected.');
process.exitCode = ok ? 0 : 1;
