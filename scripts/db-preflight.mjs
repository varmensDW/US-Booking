// Read-only booking DB preflight: `npm run db:preflight`.
//
// Reads BOOKING_DATABASE_URL (and BOOKING_MIGRATION_DATABASE_URL, when supplied and different)
// from this project's .env only. For each target it:
//   1. connects and stops unless current_database() is exactly BOOKING_DATABASE_EXPECTED_NAME;
//   2. runs db/checks/booking_db_preflight.sql inside BEGIN READ ONLY ... ROLLBACK, with the
//      session default also set to read-only.
// It creates, grants and migrates nothing. psql comes from PG_BIN, PATH, or the default install.
import fs from 'node:fs';
import path from 'node:path';
import {root, loadProjectEnv, requireSettings, connectionEnv, runPsql, identify} from './lib/db.mjs';

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

const env = loadProjectEnv();
requireSettings(env, ['BOOKING_DATABASE_URL', 'BOOKING_DATABASE_EXPECTED_NAME']);
const expected = env('BOOKING_DATABASE_EXPECTED_NAME');

// The SQL file is split on its "-- N. title" headers so each result set prints under its title.
function preflightScript() {
  const sql = fs.readFileSync(sqlFile, 'utf8');
  const parts = sql.split(/^(?=-- \d+\. )/m).filter(p => /^-- \d+\. /.test(p));
  const titled = parts.map(p => `\\pset title '${p.split('\n')[0].slice(3).replace(/'/g, "''")}'\n${p}`);
  return ['BEGIN READ ONLY;', ...titled, 'ROLLBACK;', ''].join('\n');
}

function preflight(label, varName) {
  console.log(`\n=== ${label} (${varName}) ===`);
  const conn = connectionEnv(env(varName), expected,
    {appName: 'us-booking-preflight', options: '-c default_transaction_read_only=on'});
  if (conn.error) {
    console.log(`STOP: ${varName}: ${conn.error}.`);
    return false;
  }
  const id = identify(conn, expected);
  if (id.error) {
    console.log(`STOP: ${id.error}. Preflight not run.`);
    return false;
  }
  console.log(`Connected: database ${id.database}, role ${id.role}. Running db/checks/${checkName}.sql read-only.\n`);
  const r = runPsql(conn, ['-q'], preflightScript());
  process.stdout.write(r.stdout);
  if (r.status !== 0) {
    console.log(`Preflight failed (psql exit ${r.status}).\n${r.stderr.trim()}`);
    return false;
  }
  return true;
}

let ok = preflight('Runtime target', 'BOOKING_DATABASE_URL');
const migrationUrl = env('BOOKING_MIGRATION_DATABASE_URL');
if (!migrationUrl) console.log('\nBOOKING_MIGRATION_DATABASE_URL not supplied; only the runtime URL was inspected.');
else if (migrationUrl === env('BOOKING_DATABASE_URL')) console.log('\nBOOKING_MIGRATION_DATABASE_URL is the same connection as the runtime URL; inspected once.');
else ok = preflight('Migration target', 'BOOKING_MIGRATION_DATABASE_URL') && ok;
process.exitCode = ok ? 0 : 1;
