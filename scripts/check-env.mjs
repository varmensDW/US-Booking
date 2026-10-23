// Local configuration checker: `npm run check:env` (add `-- --strict` to exit non-zero on problems).
// `-- --stage=db-preflight` requires only the settings the read-only booking DB preflight needs;
// other settings are still validated when supplied, but a missing one is reported as `not needed`.
//
// Loads .env with Node's built-in process.loadEnvFile() (variables already set in the shell take
// precedence) and checks presence and basic shape of each setting. It never connects anywhere and
// never prints a value: output is the variable name, a status, and a fixed explanatory note.
// Parser error text is not printed either, because it can echo the input.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const envFile = path.join(root, '.env');
const strict = process.argv.includes('--strict');

// Stages name the settings that must be present; `all` (the default) requires every setting.
const STAGES = {
  'all': null,
  'db-preflight': ['BOOKING_DATABASE_URL', 'BOOKING_DATABASE_EXPECTED_NAME'],
  'db-migrate': ['BOOKING_DATABASE_URL', 'BOOKING_MIGRATION_DATABASE_URL', 'BOOKING_DATABASE_EXPECTED_NAME'],
  'oms-sync': ['OMS_READ_DATABASE_URL', 'BOOKING_DATABASE_URL', 'BOOKING_DATABASE_EXPECTED_NAME'],
};
const stageArg = process.argv.find(a => a.startsWith('--stage='));
const stage = stageArg ? stageArg.slice('--stage='.length) : 'all';
if (!(stage in STAGES)) {
  console.error(`Unknown stage "${stage}". Known stages: ${Object.keys(STAGES).join(', ')}.`);
  process.exit(2);
}
const required = STAGES[stage];

if (fs.existsSync(envFile)) {
  process.loadEnvFile(envFile);
} else {
  console.log('.env not found; checking the shell environment only (copy .env.example to .env).');
}

const env = name => (process.env[name] ?? '').trim();
const results = [];
const report = (name, status, note = '') => {
  if (status === 'missing' && required && !required.includes(name)) status = 'not needed';
  results.push({name, status, note});
};

// Parses a postgres URL into the parts the cross-checks need. Returns {error} on failure.
function parsePg(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return {error: 'not a valid URL'};
  }
  if (url.protocol !== 'postgres:' && url.protocol !== 'postgresql:') return {error: 'scheme must be postgres:// or postgresql://'};
  if (!url.hostname) return {error: 'no host'};
  if (!url.username) return {error: 'no user'};
  const database = decodeURIComponent(url.pathname.replace(/^\//, ''));
  if (!database) return {error: 'no database name'};
  return {host: url.hostname.toLowerCase(), port: url.port || '5432', user: decodeURIComponent(url.username), database};
}

function checkDbUrl(name, purpose) {
  const value = env(name);
  if (!value) {
    report(name, 'missing', purpose);
    return null;
  }
  const parsed = parsePg(value);
  if (parsed.error) {
    report(name, 'invalid', parsed.error);
    return null;
  }
  report(name, 'configured', purpose);
  return parsed;
}

// BOOKING_ROLE_MODE: `separate` (default) expects a DML-only runtime role distinct from the owner;
// `single` records the explicitly approved setup where one login (the owner) does both.
const roleMode = env('BOOKING_ROLE_MODE') || 'separate';
if (!['separate', 'single'].includes(roleMode)) report('BOOKING_ROLE_MODE', 'invalid', 'separate | single');
else report('BOOKING_ROLE_MODE', 'configured', roleMode === 'single'
  ? 'single: approved owner login used for runtime too; runtime-role restrictions do not apply'
  : 'separate: runtime and migration roles must differ');

const oms = checkDbUrl('OMS_READ_DATABASE_URL', 'OMS read-only (SELECT-only role)');
const booking = checkDbUrl('BOOKING_DATABASE_URL', roleMode === 'single' ? 'booking runtime (owner login, single-role mode)' : 'booking runtime (DML-only role)');
const migration = checkDbUrl('BOOKING_MIGRATION_DATABASE_URL', 'booking migration/owner role');

const expected = env('BOOKING_DATABASE_EXPECTED_NAME');
if (!expected) report('BOOKING_DATABASE_EXPECTED_NAME', 'missing', 'name of the booking database');
else if (!/^[A-Za-z_][A-Za-z0-9_$-]*$/.test(expected)) report('BOOKING_DATABASE_EXPECTED_NAME', 'invalid', 'not a plain database name');
else if (expected === 'ledsone') report('BOOKING_DATABASE_EXPECTED_NAME', 'invalid', 'names the OMS mirror, not a booking database');
else report('BOOKING_DATABASE_EXPECTED_NAME', 'configured');

// Cross-checks compare parsed parts in memory; only the outcome is printed.
const sameDb = (a, b) => a.host === b.host && a.port === b.port && a.database === b.database;
if (booking && expected) {
  report('BOOKING_DATABASE_URL vs EXPECTED_NAME', booking.database === expected ? 'ok' : 'invalid',
    booking.database === expected ? 'database name matches' : 'database name differs from the expected name');
}
if (migration && expected) {
  report('BOOKING_MIGRATION_DATABASE_URL vs EXPECTED_NAME', migration.database === expected ? 'ok' : 'invalid',
    migration.database === expected ? 'database name matches' : 'database name differs from the expected name');
}
if (booking && migration) {
  report('booking runtime vs migration target', sameDb(booking, migration) ? 'ok' : 'invalid',
    sameDb(booking, migration) ? 'same host, port and database' : 'runtime and migration URLs point at different databases');
  const same = booking.user === migration.user;
  if (roleMode === 'single') {
    report('booking runtime vs migration role', same ? 'ok' : 'warning',
      same ? 'same role, as approved (BOOKING_ROLE_MODE=single)' : 'BOOKING_ROLE_MODE=single but the URLs use different roles');
  } else {
    report('booking runtime vs migration role', same ? 'warning' : 'ok',
      same ? 'same role for runtime and migrations; use separate roles or set BOOKING_ROLE_MODE=single if approved' : 'separate roles');
  }
}
if (oms && (booking || migration)) {
  const clash = [booking, migration].some(b => b && sameDb(oms, b));
  report('OMS vs booking separation', clash ? 'invalid' : 'ok',
    clash ? 'OMS read URL and a booking URL point at the same database' : 'OMS and booking databases are distinct');
  const sharedRole = [booking, migration].some(b => b && b.user === oms.user);
  if (sharedRole) report('OMS vs booking roles', 'warning', 'a booking URL uses the same role as the OMS read URL');
}

// Application settings.
const nodeEnv = env('NODE_ENV');
report('NODE_ENV', !nodeEnv ? 'missing' : ['development', 'test', 'production'].includes(nodeEnv) ? 'configured' : 'invalid',
  'development | test | production');
report('APP_HOST', env('APP_HOST') ? 'configured' : 'missing');
const port = Number(env('APP_PORT'));
report('APP_PORT', !env('APP_PORT') ? 'missing' : Number.isInteger(port) && port > 0 && port < 65536 ? 'configured' : 'invalid',
  'integer 1-65535');

const shippoMode = env('SHIPPO_MODE');
report('SHIPPO_MODE', !shippoMode ? 'missing' : ['test', 'live'].includes(shippoMode) ? 'configured' : 'invalid',
  shippoMode === 'live' ? 'live mode while the integration is unverified' : 'test | live');
const token = env('SHIPPO_API_TOKEN');
if (!token) report('SHIPPO_API_TOKEN', 'missing', 'not needed for the database preflight');
else if (shippoMode === 'test' && !token.startsWith('shippo_test_')) report('SHIPPO_API_TOKEN', 'warning', 'SHIPPO_MODE=test but the token does not look like a test token');
else report('SHIPPO_API_TOKEN', 'configured');

const live = env('ENABLE_LIVE_BOOKING');
report('ENABLE_LIVE_BOOKING', !live ? 'missing' : !['true', 'false'].includes(live) ? 'invalid' : live === 'true' ? 'warning' : 'configured',
  'placeholder; no application code reads it yet');

const labelDir = env('LABEL_STORAGE_DIR');
if (!labelDir) report('LABEL_STORAGE_DIR', 'missing');
else report('LABEL_STORAGE_DIR', fs.existsSync(path.resolve(root, labelDir)) ? 'configured' : 'invalid',
  fs.existsSync(path.resolve(root, labelDir)) ? 'local development only' : 'directory does not exist');

console.log(`Stage: ${stage}
`);
const width = Math.max(...results.map(r => r.name.length));
for (const r of results) console.log(`${r.name.padEnd(width)}  ${r.status.padEnd(10)}  ${r.note}`);

const problems = results.filter(r => r.status === 'missing' || r.status === 'invalid').length;
const warnings = results.filter(r => r.status === 'warning').length;
console.log(`\n${problems} missing/invalid, ${warnings} warning(s). Values are never printed.`);
if (strict && problems) process.exitCode = 1;
