// Booking schema migrator: `npm run db:migrate` (plan only), `-- --dry-run`, `-- --apply`.
//
// Applies db/migrations/NNNN_name.sql to BOOKING_DATABASE_EXPECTED_NAME through
// BOOKING_MIGRATION_DATABASE_URL (read from this project's .env only; never printed).
//   plan (default)  read-only: connects, checks the ledger and lists pending files.
//   --dry-run       applies every pending file in one transaction, then ROLLBACK.
//   --apply         the same, then COMMIT.
// Safeguards, all inside the one transaction (REPEATABLE READ, so other sessions' commits cannot
// make the comparison below fail spuriously):
//   * current_database() must equal the expected name;
//   * a fingerprint of every catalog object OUTSIDE us_booking (schemas, relations, functions,
//     triggers, constraints, default ACLs, extensions, database ACL) is taken before and after;
//     any difference rolls the whole transaction back, so other applications' schemas cannot change;
//   * each applied file is recorded in us_booking.schema_migration with its SHA-256 (line endings
//     normalised). A recorded file whose content has changed, or a recorded version with no file,
//     stops the run. Files outside db/migrations (e.g. db/proposed) are never applied or recorded.
// Lock and statement timeouts keep it from waiting on, or holding up, other applications.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {root, loadProjectEnv, requireSettings, connectionEnv, runPsql, queryRows, identify} from './lib/db.mjs';

const mode = process.argv.includes('--apply') ? 'apply' : process.argv.includes('--dry-run') ? 'dry-run' : 'plan';
// --env-file=PATH replaces the project .env (synthetic test harness only).
const env = loadProjectEnv(process.argv.find(a => a.startsWith('--env-file='))?.slice('--env-file='.length));
requireSettings(env, ['BOOKING_MIGRATION_DATABASE_URL', 'BOOKING_DATABASE_EXPECTED_NAME']);
const expected = env('BOOKING_DATABASE_EXPECTED_NAME');
if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(expected)) {
  console.error('BOOKING_DATABASE_EXPECTED_NAME must be a plain identifier.');
  process.exit(1);
}

const dir = path.join(root, 'db', 'migrations');
const files = fs.readdirSync(dir).filter(f => f.endsWith('.sql')).sort().map(name => {
  const m = /^(\d{4})_[a-z0-9_]+\.sql$/.exec(name);
  if (!m) {
    console.error(`STOP: unexpected file name in db/migrations: ${name}`);
    process.exit(1);
  }
  const sql = fs.readFileSync(path.join(dir, name), 'utf8').replace(/\r\n/g, '\n');
  if (/^\s*\\/m.test(sql)) {
    console.error(`STOP: ${name} contains psql meta-commands; migrations must be plain SQL.`);
    process.exit(1);
  }
  return {version: m[1], name, sql, sha256: crypto.createHash('sha256').update(sql).digest('hex')};
});
if (new Set(files.map(f => f.version)).size !== files.length) {
  console.error('STOP: duplicate version numbers in db/migrations.');
  process.exit(1);
}

const options = '-c lock_timeout=5s -c statement_timeout=300s' + (mode === 'plan' ? ' -c default_transaction_read_only=on' : '');
const conn = connectionEnv(env('BOOKING_MIGRATION_DATABASE_URL'), expected, {appName: 'us-booking-migrate', options});
if (conn.error) {
  console.error(`STOP: BOOKING_MIGRATION_DATABASE_URL: ${conn.error}.`);
  process.exit(1);
}
const id = identify(conn, expected);
if (id.error) {
  console.error(`STOP: ${id.error}. Nothing applied.`);
  process.exit(1);
}
console.log(`Connected: database ${id.database}, role ${id.role}. Mode: ${mode}.`);

// Current state of us_booking and its ledger.
const state = queryRows(conn, `SELECT to_regnamespace('us_booking') IS NOT NULL,
  to_regclass('us_booking.schema_migration') IS NOT NULL,
  COALESCE((SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'us_booking'), '')`);
if (state.error) {
  console.error(`STOP: ${state.error}`);
  process.exit(1);
}
const [schemaExists, ledgerExists, schemaOwner] = state.rows[0];
let applied = [];
if (schemaExists === 't' && ledgerExists !== 't') {
  console.error('STOP: schema us_booking exists but has no schema_migration ledger. Inspect it manually; nothing applied.');
  process.exit(1);
}
if (schemaExists === 't' && schemaOwner !== id.role) {
  console.error(`STOP: schema us_booking is owned by ${schemaOwner}, not the connected role ${id.role}. Nothing applied.`);
  process.exit(1);
}
if (ledgerExists === 't') {
  const q = queryRows(conn, 'SELECT version, filename, sha256, applied_at, applied_by FROM us_booking.schema_migration ORDER BY version');
  if (q.error) {
    console.error(`STOP: ${q.error}`);
    process.exit(1);
  }
  applied = q.rows.map(([version, filename, sha256, at, by]) => ({version, filename, sha256, at, by}));
}

let drift = false;
for (const a of applied) {
  const f = files.find(x => x.version === a.version);
  if (!f) {
    console.error(`STOP: version ${a.version} (${a.filename}) is recorded as applied but has no file in db/migrations.`);
    drift = true;
  } else if (f.sha256 !== a.sha256 || f.name !== a.filename) {
    console.error(`STOP: ${f.name} differs from the applied ${a.filename} (checksum or name changed). Add a new migration instead.`);
    drift = true;
  }
}
if (drift) process.exit(1);

const pending = files.filter(f => !applied.some(a => a.version === f.version));
for (const a of applied) console.log(`  applied  ${a.filename}  ${a.sha256.slice(0, 12)}  ${a.at}  by ${a.by}`);
for (const f of pending) console.log(`  pending  ${f.name}  ${f.sha256.slice(0, 12)}`);
if (!pending.length) {
  console.log('Nothing to apply.');
  process.exit(0);
}
if (mode === 'plan') {
  console.log('\nPlan only. Run with -- --dry-run to test in a rolled-back transaction, or -- --apply to commit.');
  process.exit(0);
}

// Fingerprint of everything outside us_booking and the system schemas.
const FINGERPRINT = `(SELECT md5(string_agg(x, E'\\n' ORDER BY x)) FROM (
  SELECT 'n|' || n.oid || '|' || n.nspname || '|' || n.nspowner || '|' || COALESCE(n.nspacl::text, '') AS x
    FROM pg_namespace n WHERE n.nspname <> 'us_booking' AND n.nspname !~ '^(pg_|information_schema$)'
  UNION ALL
  SELECT 'c|' || c.oid || '|' || c.relnamespace || '|' || c.relname || '|' || c.relkind::text || '|' || c.relowner || '|'
         || c.relnatts || '|' || COALESCE(c.relacl::text, '')
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname <> 'us_booking' AND n.nspname !~ '^(pg_|information_schema$)'
  UNION ALL
  SELECT 'p|' || p.oid || '|' || p.pronamespace || '|' || p.proname || '|' || p.proowner || '|' || COALESCE(p.proacl::text, '')
         || '|' || md5(p.prosrc)
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname <> 'us_booking' AND n.nspname !~ '^(pg_|information_schema$)'
  UNION ALL
  SELECT 't|' || t.oid || '|' || t.tgrelid || '|' || t.tgname || '|' || t.tgenabled::text
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname <> 'us_booking' AND n.nspname !~ '^(pg_|information_schema$)'
  UNION ALL
  SELECT 'k|' || k.oid || '|' || k.conrelid || '|' || k.conname || '|' || k.confrelid
    FROM pg_constraint k JOIN pg_namespace n ON n.oid = k.connamespace
   WHERE n.nspname <> 'us_booking' AND n.nspname !~ '^(pg_|information_schema$)'
  UNION ALL
  SELECT 'd|' || d.oid || '|' || d.defaclrole || '|' || d.defaclnamespace || '|' || d.defaclobjtype::text || '|' || d.defaclacl::text
    FROM pg_default_acl d
  UNION ALL
  SELECT 'e|' || e.extname || '|' || e.extversion FROM pg_extension e
  UNION ALL
  SELECT 'b|' || COALESCE(datacl::text, '') FROM pg_database WHERE datname = current_database()
) s)`;

const lit = s => `'${s.replace(/'/g, "''")}'`;
const script = [
  '\\set ON_ERROR_STOP on',
  'BEGIN ISOLATION LEVEL REPEATABLE READ;',
  `CREATE FUNCTION pg_temp.usb_fail(msg text) RETURNS boolean LANGUAGE plpgsql AS $f$ BEGIN RAISE EXCEPTION '%', msg; END $f$;`,
  `SELECT current_database() = ${lit(expected)} OR pg_temp.usb_fail('wrong database: ' || current_database()) AS database_ok;`,
  `SELECT ${FINGERPRINT} AS fp_before \\gset`,
  ...pending.flatMap(f => [`\\echo '== applying ${f.name}'`, f.sql]),
  `CREATE TABLE IF NOT EXISTS us_booking.schema_migration (
  version    text PRIMARY KEY CHECK (version ~ '^[0-9]{4}$'),
  filename   text NOT NULL UNIQUE,
  sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  applied_at timestamptz NOT NULL DEFAULT now(),
  applied_by text NOT NULL DEFAULT current_user,
  tool       text NOT NULL
);`,
  `COMMENT ON TABLE us_booking.schema_migration IS 'Migrations applied by scripts/db-migrate.mjs. Only files that were actually applied are recorded.';`,
  ...pending.map(f => `INSERT INTO us_booking.schema_migration (version, filename, sha256, tool) VALUES (${lit(f.version)}, ${lit(f.name)}, ${lit(f.sha256)}, 'scripts/db-migrate.mjs');`),
  `SELECT ${FINGERPRINT} = :'fp_before' OR pg_temp.usb_fail('objects outside us_booking changed; rolling back') AS outside_unchanged;`,
  `SELECT pg_get_userbyid(nspowner) = current_user OR pg_temp.usb_fail('us_booking is not owned by the migration role') AS owner_ok FROM pg_namespace WHERE nspname = 'us_booking';`,
  `SET CONSTRAINTS ALL IMMEDIATE;`,
  mode === 'apply' ? 'COMMIT;' : 'ROLLBACK;',
  `\\echo '== ${mode === 'apply' ? 'committed' : 'rolled back (dry run)'}'`,
  '',
].join('\n');

const r = runPsql(conn, ['-q'], script);
process.stdout.write(r.stdout);
if (r.status !== 0) {
  console.error(`\nFAILED (psql exit ${r.status}); the transaction was rolled back, nothing was applied.\n${r.stderr.trim()}`);
  process.exit(1);
}
if (r.stderr.trim()) console.log(r.stderr.trim());
console.log(mode === 'apply' ? `\nApplied ${pending.length} migration(s).` : `\nDry run OK: ${pending.length} migration(s) applied and rolled back.`);
