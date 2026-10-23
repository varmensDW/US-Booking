// Manual OMS order sync: `npm run sync:oms` (dry run), `npm run sync:oms -- --apply`.
//
//   --limit=N        at most N NEW fulfilment groups per run (0..20, default 20; 0 = refresh only). Groups imported
//                    earlier are always refreshed in addition, whatever their OMS status/warehouse.
//   --apply          commit. Without it the whole import runs in a transaction that is rolled back.
//   --env-file=PATH  read settings from PATH instead of the project .env (test harness only).
//
// Reads ledsone through OMS_READ_DATABASE_URL in a READ ONLY, REPEATABLE READ transaction
// (src/server/sync/oms_extract.sql) and writes varmen_db.us_booking through BOOKING_DATABASE_URL
// with us_booking.oms_sync_apply() (db/migrations/0003). Connection strings are never printed,
// and the snapshot itself (which holds customer addresses) is never printed or written to disk:
// only counts, ids and review reasons are reported. No booking attempt is created and no shipping
// provider is contacted.
//
// A failed --apply run is recorded in us_booking.sync_run (status failed) by a separate, committed
// call to us_booking.sync_record_failure() (db/migrations/0008), because the import transaction and
// its 'running' row are rolled back. The stored message has credentials and host names removed.
// Failures before the booking database is reachable cannot be recorded there.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {root, loadProjectEnv, requireSettings, connectionEnv, runPsql, queryRows, identify} from './lib/db.mjs';

const arg = name => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const apply = process.argv.includes('--apply');
const limit = Number(arg('limit') ?? 20);
if (!Number.isInteger(limit) || limit < 0 || limit > 20) {
  console.error('--limit must be an integer from 0 (refresh only) to 20.');
  process.exit(2);
}

const env = loadProjectEnv(arg('env-file'));
requireSettings(env, ['OMS_READ_DATABASE_URL', 'BOOKING_DATABASE_URL', 'BOOKING_DATABASE_EXPECTED_NAME']);
const bookingName = env('BOOKING_DATABASE_EXPECTED_NAME');
const omsName = env('OMS_DATABASE_EXPECTED_NAME') || 'ledsone';
if (env('ENABLE_LIVE_BOOKING') === 'true') {
  console.log('Note: ENABLE_LIVE_BOOKING=true has no effect here; this command never books or prints.');
}

const startedAt = new Date().toISOString();
let booking = null; // set once the booking connection is identified; enables failure records
let failureStage = 'connecting';

// Stores a failed --apply run in its own transaction. Dry runs write nothing, so they record nothing.
function recordFailure(msg) {
  if (!apply || !booking) return;
  const hosts = [booking.env.PGHOST, oms?.env?.PGHOST].filter(Boolean);
  const clean = hosts.reduce((t, h) => t.split(h).join('[host]'), msg)
    .split(/\r?\n/).filter(l => l.trim() && !/^(LOCATION|CONTEXT|DETAIL|HINT|STATEMENT):/.test(l.trim())).join(' | ').slice(0, 900);
  const payload = Buffer.from(JSON.stringify({started_at: startedAt, error: clean, stage: failureStage, actor: 'system:oms-sync'})).toString('base64');
  const r = runPsql({...booking, env: {...booking.env, PGOPTIONS: '-c lock_timeout=3s -c statement_timeout=15s'}}, ['-q', '-A', '-t'],
    `SELECT us_booking.sync_record_failure(convert_from(decode('${payload}', 'base64'), 'UTF8')::jsonb);\n`);
  if (r.status === 0) console.error(`Failure recorded as sync run ${r.stdout.trim()} (Sync History).`);
  else console.error('The failure could not be recorded in sync history (another sync may hold the lock, or migration 0008 is not applied).');
}

const fail = msg => {
  console.error(`STOP: ${msg}`);
  recordFailure(msg);
  process.exit(1);
};

// --- Connections and identity -----------------------------------------------------------------
const oms = connectionEnv(env('OMS_READ_DATABASE_URL'), omsName,
  {appName: 'us-booking-oms-sync', options: '-c default_transaction_read_only=on -c statement_timeout=120s'});
if (oms.error) fail(`OMS_READ_DATABASE_URL: ${oms.error.replace('BOOKING_DATABASE_EXPECTED_NAME', `the OMS database name (${omsName})`)}.`);
const bookingConn = connectionEnv(env('BOOKING_DATABASE_URL'), bookingName,
  {appName: 'us-booking-oms-sync', options: '-c lock_timeout=5s -c statement_timeout=120s'});
if (bookingConn.error) fail(`BOOKING_DATABASE_URL: ${bookingConn.error}.`);
if (oms.env.PGHOST === bookingConn.env.PGHOST && oms.env.PGPORT === bookingConn.env.PGPORT && oms.env.PGDATABASE === bookingConn.env.PGDATABASE) {
  fail('OMS and booking URLs point at the same database.');
}

const bookingId = identify(bookingConn, bookingName);
if (bookingId.error) fail(`booking: ${bookingId.error}.`);
booking = bookingConn;
const omsId = identify(oms, omsName);
if (omsId.error) fail(`OMS: ${omsId.error}.`);
console.log(`OMS:     database ${omsId.database}, role ${omsId.role} (read-only session)`);
console.log(`Booking: database ${bookingId.database}, role ${bookingId.role}`);
console.log(`Mode:    ${apply ? 'APPLY (commit)' : 'dry run (rolled back)'}; at most ${limit} new group(s)\n`);

// The OMS role should be SELECT-only. The session is read-only regardless; a role that could write
// is reported so it can be replaced.
const priv = queryRows(oms, `SELECT r.rolsuper,
  EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname IN ('order_management', 'customers', 'customer_service') AND c.relkind IN ('r', 'p')
             AND has_table_privilege(c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE'))
  FROM pg_roles r WHERE r.rolname = current_user`);
if (priv.error) fail(`OMS privilege check failed.\n${priv.error}`);
const [omsSuper, omsCanWrite] = priv.rows[0] ?? [];
if (omsSuper === 't' || omsCanWrite === 't') {
  console.log('WARNING: the OMS role can write to OMS tables. This command only reads (read-only transaction), but a SELECT-only role should be used.\n');
}

const ready = queryRows(booking, `SELECT to_regprocedure('us_booking.oms_sync_apply(jsonb, text)') IS NOT NULL,
  EXISTS (SELECT 1 FROM us_booking.schema_migration WHERE version = '0003')`);
if (ready.error) fail(`booking schema check failed.\n${ready.error}`);
if (ready.rows[0]?.[0] !== 't' || ready.rows[0]?.[1] !== 't') fail('migration 0003 is not applied (npm run db:migrate).');

// --- Read the OMS ------------------------------------------------------------------------------
failureStage = 'reading_oms';
const refresh = queryRows(booking, `SELECT fo.oms_order_id FROM us_booking.fulfilment_group_order fo
  JOIN us_booking.fulfilment_group g ON g.id = fo.fulfilment_group_id
 WHERE fo.active AND g.state NOT IN ('superseded', 'cancelled') ORDER BY 1`);
if (refresh.error) fail(`could not read previously imported orders.\n${refresh.error}`);
const refreshIds = refresh.rows.map(r => r[0]).filter(v => /^\d+$/.test(v));

const extractSql = fs.readFileSync(path.join(root, 'src', 'server', 'sync', 'oms_extract.sql'), 'utf8');
const extract = runPsql(oms, ['-q', '-A', '-t', '-v', `lim=${limit}`, '-v', `refresh={${refreshIds.join(',')}}`],
  `BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;\n${extractSql}\nROLLBACK;\n`);
if (extract.status !== 0) fail(`OMS extraction failed (psql exit ${extract.status}).\n${extract.stderr.trim()}`);
let snapshot;
try {
  snapshot = JSON.parse(extract.stdout.trim());
} catch {
  fail('OMS extraction did not return a JSON snapshot.');
}
if (snapshot.format !== 'us_booking.oms_snapshot.v1' || snapshot.oms_database !== omsName) fail('unexpected snapshot.');
const groups = snapshot.groups;
const count = (key, reason) => groups.filter(g => !reason || g.reason === reason).reduce((n, g) => n + g[key].length, 0);
console.log(`Read from OMS: ${groups.filter(g => g.reason === 'new').length} new group(s), `
  + `${groups.filter(g => g.reason === 'refresh').length} previously imported group(s); `
  + `${count('orders')} order(s), ${count('items')} line(s), ${count('combos')} combo component row(s).`);

// --- Write the booking schema --------------------------------------------------------------------
failureStage = 'writing_booking';
const json = JSON.stringify(snapshot);
let tag;
do tag = `$snap_${crypto.randomBytes(6).toString('hex')}$`; while (json.includes(tag));
const script = [
  '\\set ON_ERROR_STOP on',
  'BEGIN;',
  `SELECT us_booking.oms_sync_apply(${tag}${json}${tag}::jsonb, 'system:oms-sync')::text;`,
  apply ? 'COMMIT;' : 'ROLLBACK;',
  '',
].join('\n');
const result = runPsql(booking, ['-q', '-A', '-t'], script);
if (result.status !== 0) fail(`import failed and was rolled back; nothing was written.\n${result.stderr.trim()}`);
const summary = JSON.parse(result.stdout.trim().split('\n').find(l => l.startsWith('{')));

// --- Report (counts, ids and reasons only) ------------------------------------------------------
const c = summary.counts;
const n = k => c[k] ?? 0;
console.log(`\n${apply ? 'Imported' : 'Would import'} (sync run ${summary.sync_run_id}${apply ? '' : ', rolled back'}):`);
console.log(`  groups:  ${n('groups_new')} new, ${n('groups_refreshed')} refreshed, ${n('groups_superseded')} superseded, ${n('groups_returned_to_review')} returned to review`);
console.log(`  orders:  ${n('orders_inserted')} new, ${n('orders_changed')} changed, ${n('orders_unchanged')} unchanged`);
console.log(`  lines:   ${n('lines_inserted')} new, ${n('lines_changed')} changed, ${n('lines_unchanged')} unchanged`);
const cases = Object.entries(summary.review_cases_opened);
console.log(`  review cases opened: ${cases.length ? cases.map(([k, v]) => `${k} ${v}`).join(', ') : 'none'}`);
if (summary.groups_skipped.length) console.log(`  SKIPPED: ${summary.groups_skipped.map(s => `${s.container_id} (${s.reason})`).join('; ')}`);
if (summary.orders_moved.length) console.log(`  regrouped: ${summary.orders_moved.map(m => `${m.oms_order_id} ${m.from_group}->${m.to_group}`).join('; ')}`);
console.log(`  booking attempts in schema: ${summary.booking_attempts_total} (this command creates none)\n`);
console.log('Review queue for these groups:');
for (const g of summary.groups) {
  console.log(`  ${g.group_key.padEnd(18)} ${g.state.padEnd(7)} ${g.provider.padEnd(22)} orders ${g.oms_order_ids.join(',')} `
    + `[${g.oms_statuses.join(',')}] lines ${g.line_count} qty ${g.ordered_quantity_total} `
    + `scope in/undet/out ${g.scope.in_scope}/${g.scope.undetermined}/${g.scope.out_of_scope}`);
  console.log(`      unmet: ${g.unmet_requirements.join(', ') || '-'}`);
  console.log(`      cases: ${g.open_cases.join(', ') || '-'}   prior label: ${g.prior_label_check}`);
}
console.log(`\nSUMMARY ${JSON.stringify({mode: apply ? 'apply' : 'dry-run', ...summary, groups: summary.groups.map(g => g.group_key)})}`);
