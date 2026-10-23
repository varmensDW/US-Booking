// Server-only database access for the web UI. Same rules as scripts/lib/db.mjs:
// - connection URLs come from this project's .env only and never leave the server;
// - they are handed to psql as PG* environment variables, never on a command line;
// - every UI read runs in a read-only session (default_transaction_read_only=on) and checks that
//   it reached the expected database;
// - error text is scrubbed of the URL, host and password before it is returned to a browser.
// The only write path is the explicit sync, which runs scripts/oms-sync.mjs (see sync-job.ts).
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

export function connection(kind: DbKind): Conn {
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
    PGOPTIONS: '-c default_transaction_read_only=on -c statement_timeout=15s',
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
