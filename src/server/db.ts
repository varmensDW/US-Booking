// Server-only database access for the web UI. Same rules as scripts/lib/db.mjs:
// - connection URLs come from this project's .env only and never leave the server;
// - they are handed to psql as PG* environment variables, never on a command line;
// - every UI read runs in a read-only session (default_transaction_read_only=on) and checks that
//   it reached the expected database;
// - error text is scrubbed of the URL, host and password before it is returned to a browser.
// Write paths: the explicit sync, which runs scripts/oms-sync.mjs (sync-job.ts), and staff actions,
// each one call to a whitelisted us_booking.staff_* function (runAction below; db/migrations/0008).
import {spawn, spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {parseEnv} from 'node:util';

export const projectRoot = process.cwd();

// USB_ENV_FILE points a separate server instance at a disposable synthetic test setup (as the
// scripts' --env-file does). Such an instance labels everything as synthetic test data.
export const envFileOverride = process.env.USB_ENV_FILE ? path.resolve(/*turbopackIgnore: true*/ process.env.USB_ENV_FILE) : null;

export function projectEnv(): Record<string, string> {
  const file = envFileOverride ?? path.join(/*turbopackIgnore: true*/ projectRoot, '.env');
  if (!fs.existsSync(file)) return {};
  const parsed = parseEnv(fs.readFileSync(file, 'utf8')) as Record<string, string | undefined>;
  return Object.fromEntries(Object.entries(parsed).map(([k, v]) => [k, (v ?? '').trim()]));
}

export type DbKind = 'booking' | 'oms';
export interface Conn {
  kind: DbKind;
  expected: string;
  env: Record<string, string>;
  secrets: string[];
}
export class DbError extends Error {
  constructor(public kind: DbKind, public reason: string) {
    super(`${kind === 'booking' ? 'Booking database' : 'OMS database'}: ${reason}`);
  }
}

const PARAM_ENV: Record<string, string> = {
  sslmode: 'PGSSLMODE', sslrootcert: 'PGSSLROOTCERT', sslcert: 'PGSSLCERT', sslkey: 'PGSSLKEY',
  channel_binding: 'PGCHANNELBINDING', gssencmode: 'PGGSSENCMODE', connect_timeout: 'PGCONNECT_TIMEOUT',
  target_session_attrs: 'PGTARGETSESSIONATTRS', application_name: 'PGAPPNAME',
};

export function connection(kind: DbKind, {write = false}: {write?: boolean} = {}): Conn {
  const env = projectEnv();
  const name = kind === 'booking' ? 'BOOKING_DATABASE_URL' : 'OMS_READ_DATABASE_URL';
  const expected = kind === 'booking' ? env.BOOKING_DATABASE_EXPECTED_NAME : env.OMS_DATABASE_EXPECTED_NAME || 'ledsone';
  const value = env[name];
  if (!value) throw new DbError(kind, `${name} is not set in .env`);
  if (!expected) throw new DbError(kind, 'BOOKING_DATABASE_EXPECTED_NAME is not set in .env');
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new DbError(kind, `${name} is not a valid URL`);
  }
  const database = decodeURIComponent(url.pathname.replace(/^\//, ''));
  if (database !== expected) throw new DbError(kind, `${name} does not name the expected database`);
  const out: Record<string, string> = {
    PGHOST: url.hostname.replace(/^\[|\]$/g, ''), PGPORT: url.port || '5432',
    PGUSER: decodeURIComponent(url.username), PGDATABASE: database,
    PGAPPNAME: 'us-booking-web', PGCONNECT_TIMEOUT: '8',
    // Reads are read-only sessions. Writes (staff actions, booking database only) wait at most 5 s
    // for a lock, so a running sync makes an action fail fast instead of hanging.
    PGOPTIONS: write && kind === 'booking' ? '-c lock_timeout=5s -c statement_timeout=15s' : '-c default_transaction_read_only=on -c statement_timeout=15s',
  };
  if (url.password) out.PGPASSWORD = decodeURIComponent(url.password);
  for (const [key, val] of url.searchParams) {
    if (!(key in PARAM_ENV)) throw new DbError(kind, `unsupported URL parameter "${key}"`);
    out[PARAM_ENV[key]] = val;
  }
  const secrets = [value, out.PGPASSWORD, url.password, out.PGHOST].filter((s): s is string => Boolean(s));
  return {kind, expected, env: out, secrets};
}

let psqlPath: string | undefined;
function findPsql(): string {
  if (psqlPath) return psqlPath;
  const exe = process.platform === 'win32' ? 'psql.exe' : 'psql';
  if (process.env.PG_BIN) return (psqlPath = path.join(process.env.PG_BIN, exe));
  if (!spawnSync(/*turbopackIgnore: true*/ exe, ['--version']).error) return (psqlPath = exe);
  // Built at runtime so the bundler does not try to trace it as a project file.
  const fallback = [process.env.ProgramFiles || 'C:\\Program Files', 'PostgreSQL', '18', 'bin', exe].join(path.sep);
  return (psqlPath = fs.existsSync(fallback) ? fallback : exe);
}

function redact(conn: Conn, text: string): string {
  return conn.secrets.reduce((t, s) => t.split(s).join('[hidden]'), text)
    .replace(/\s+/g, ' ').trim().slice(0, 300);
}

// Runs `inner` (an SQL expression returning json) in a read-only transaction and returns it.
export async function queryJson<T>(conn: Conn, inner: string, timeoutMs = 20000): Promise<T> {
  const sql = `BEGIN READ ONLY;
SELECT json_build_object('db', current_database(), 'data', (${inner}))::jsonb::text;
COMMIT;
`;
  return runScript<T>(conn, sql, timeoutMs);
}

// Staff actions (db/migrations/0008). Only these functions can be called from the web server.
export const ACTIONS = [
  'staff_profile_save', 'staff_profile_assign',
  'staff_parcel_create', 'staff_parcel_measure', 'staff_parcel_set_contents', 'staff_parcel_confirm_contents', 'staff_parcel_remove',
  'staff_destination_confirm', 'staff_destination_revoke', 'staff_case_close', 'staff_discrepancy_acknowledge',
] as const;
export type ActionName = (typeof ACTIONS)[number];
// Wayfair sandbox record functions (db/migrations/0010): called only by server code
// (src/server/wayfair), never mapped to /api/actions.
export const SANDBOX_FUNCTIONS = [
  'wayfair_sandbox_begin', 'wayfair_sandbox_finish', 'wayfair_sandbox_record_existing', 'wayfair_sandbox_resolve',
  'wayfair_sandbox_label_add',
] as const;
export type SandboxFunctionName = (typeof SANDBOX_FUNCTIONS)[number];

// Rejection of a staff action by the database (validation, stale data, locks), safe to show staff.
export class ActionError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

// Calls one staff action in its own transaction. The payload travels base64-encoded inside the
// SQL text, so no value can break out of its literal; the database name is checked before writing.
export async function runAction<T>(fn: ActionName | SandboxFunctionName, payload: Record<string, unknown>): Promise<T> {
  if (!(ACTIONS as readonly string[]).includes(fn) && !(SANDBOX_FUNCTIONS as readonly string[]).includes(fn)) {
    throw new ActionError(400, 'Unknown action');
  }
  const conn = connection('booking', {write: true});
  if (!/^[A-Za-z0-9_]+$/.test(conn.expected)) throw new DbError('booking', 'unexpected database name format');
  const b64 = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64');
  const sql = `\\set VERBOSITY verbose
BEGIN;
DO $chk$ BEGIN IF current_database() <> '${conn.expected}' THEN RAISE EXCEPTION 'connected to an unexpected database'; END IF; END $chk$;
SELECT json_build_object('db', current_database(), 'data', us_booking.${fn}(convert_from(decode('${b64}', 'base64'), 'UTF8')::jsonb))::jsonb::text;
COMMIT;
`;
  try {
    return await runScript<T>(conn, sql, 20000);
  } catch (e) {
    if (e instanceof DbError) {
      // psql (VERBOSITY verbose) prints "ERROR:  <SQLSTATE>: <message>".
      const m = /ERROR:\s+([0-9A-Z]{5}): (.*?)(?: LOCATION:| CONTEXT:|$)/.exec(e.reason);
      if (m) {
        const [, code, message] = m;
        if (code === 'UB404') throw new ActionError(404, message);
        if (code === 'UB409' || code === '55P03' || code === '40001' || code === '40P01') throw new ActionError(409, code === '55P03' ? 'The record is locked by another action or a running sync; try again in a moment.' : message);
        if (code === 'UB422' || code.startsWith('23') || code === '22P02') throw new ActionError(422, message);
      }
    }
    throw e;
  }
}

async function runScript<T>(conn: Conn, sql: string, timeoutMs: number): Promise<T> {
  const childEnv = {
    ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('PG'))),
    ...conn.env,
  } as NodeJS.ProcessEnv;
  const output = await new Promise<string>((resolve, reject) => {
    const child = spawn(/*turbopackIgnore: true*/ findPsql(), ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1'], {env: childEnv, windowsHide: true});
    let out = '';
    let err = '';
    const timer = setTimeout(() => {
      child.kill();
      reject(new DbError(conn.kind, 'query timed out'));
    }, timeoutMs);
    child.stdout.on('data', (d: Buffer) => (out += d));
    child.stderr.on('data', (d: Buffer) => (err += d));
    child.on('error', e => {
      clearTimeout(timer);
      reject(new DbError(conn.kind, `psql could not start (${e.message})`));
    });
    child.on('close', code => {
      clearTimeout(timer);
      if (code === 0) resolve(out);
      else reject(new DbError(conn.kind, redact(conn, err) || `psql exited with ${code}`));
    });
    child.stdin.end(sql);
  });
  const line = output.split(/\r?\n/).find(l => l.startsWith('{'));
  if (!line) throw new DbError(conn.kind, 'no result');
  const parsed = JSON.parse(line) as {db: string; data: T};
  if (parsed.db !== conn.expected) throw new DbError(conn.kind, `connected to an unexpected database`);
  return parsed.data;
}

export function errorBody(e: unknown) {
  if (e instanceof DbError) return {error: e.message, source: e.kind};
  // Not a database error, so it carries no connection data; log it for the operator.
  console.error('[us-booking] unexpected server error:', e instanceof Error ? e.message : e);
  return {error: 'Unexpected server error', source: 'server'};
}
