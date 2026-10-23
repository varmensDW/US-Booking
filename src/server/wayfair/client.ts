// Wayfair SANDBOX HTTP client (server-only): token acquisition and renewal, GraphQL calls and
// document downloads. Credentials and tokens are kept in memory only and are removed from every
// message this module produces.
import type {WayfairConfig} from './config';

export type WayfairErrorKind = 'config' | 'auth' | 'network' | 'timeout' | 'provider' | 'graphql' | 'unexpected';

export class WayfairError extends Error {
  constructor(public kind: WayfairErrorKind, message: string, public status?: number, public sent = false) {
    super(message);
  }
}

interface Token {
  value: string;
  obtainedAt: number;
  expiresAt: number;
}
let token: Token | null = null;
let tokenKey = '';              // which client id/endpoint the cached token belongs to

export interface AuthState {
  ok: boolean;
  at: string;
  detail: string;
  expires_at: string | null;
}
let lastAuth: AuthState | null = null;
export const authState = () => lastAuth;

// Wayfair recommends requesting a new token every 12 hours (tokens last 24 hours).
const RENEW_AFTER_MS = 12 * 60 * 60 * 1000;
const TIMEOUT_MS = 20_000;

function scrub(c: WayfairConfig, text: string): string {
  let out = text;
  for (const s of [c.clientSecret, c.clientId, token?.value].filter((x): x is string => Boolean(x) && x!.length >= 4)) {
    out = out.split(s).join('[hidden]');
  }
  return out.replace(/\s+/g, ' ').slice(0, 300);
}

async function http(c: WayfairConfig, url: string, init: RequestInit): Promise<Response> {
  try {
    return await fetch(url, {...init, signal: AbortSignal.timeout(TIMEOUT_MS), redirect: 'error', cache: 'no-store'});
  } catch (e) {
    const err = e as Error & {cause?: {code?: string}};
    if (err.name === 'TimeoutError' || err.name === 'AbortError') throw new WayfairError('timeout', 'Wayfair did not answer within 20 s', undefined, true);
    const code = err.cause?.code ?? '';
    // A refused or unresolvable connection never reached Wayfair; anything else may have.
    const sent = !['ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN'].includes(code);
    throw new WayfairError('network', scrub(c, `Wayfair could not be reached (${code || err.message})`), undefined, sent);
  }
}

export function forgetToken() {
  token = null;
}

// Returns a valid token, requesting a new one when there is none, it is older than 12 hours, it
// expires within a minute, or `force` is set.
export async function getToken(c: WayfairConfig, force = false): Promise<string> {
  if (!c.usable) throw new WayfairError('config', c.problems.join('; '));
  const key = `${c.endpoints.tokenUrl}|${c.clientId}`;
  const now = Date.now();
  if (!force && token && tokenKey === key && now - token.obtainedAt < RENEW_AFTER_MS && token.expiresAt - now > 60_000) {
    return token.value;
  }
  token = null;
  let res: Response;
  try {
    res = await http(c, c.endpoints.tokenUrl, {
      method: 'POST',
      headers: {'Content-Type': 'application/json', Accept: 'application/json'},
      body: JSON.stringify({grant_type: 'client_credentials', client_id: c.clientId, client_secret: c.clientSecret,
                            audience: c.endpoints.audience}),
    });
  } catch (e) {
    const err = e instanceof WayfairError ? e : new WayfairError('network', 'token request failed');
    lastAuth = {ok: false, at: new Date().toISOString(), detail: err.message, expires_at: null};
    throw err;
  }
  const body = await res.json().catch(() => null) as {access_token?: string; expires_in?: number; error?: string; error_description?: string} | null;
  if (!res.ok || !body?.access_token) {
    const reason = body?.error ? `${body.error}${body.error_description ? `: ${body.error_description}` : ''}` : `HTTP ${res.status}`;
    const kind: WayfairErrorKind = res.status === 401 || res.status === 403 || body?.error === 'access_denied' || body?.error === 'invalid_client' ? 'auth' : 'provider';
    const err = new WayfairError(kind, scrub(c, kind === 'auth' ? `Wayfair rejected the sandbox credentials (${reason})` : `Token request failed (${reason})`), res.status);
    lastAuth = {ok: false, at: new Date().toISOString(), detail: err.message, expires_at: null};
    throw err;
  }
  const lifetime = Number.isFinite(body.expires_in) && body.expires_in! > 0 ? body.expires_in! * 1000 : 3600_000;
  token = {value: body.access_token, obtainedAt: now, expiresAt: now + lifetime};
  tokenKey = key;
  lastAuth = {ok: true, at: new Date(now).toISOString(), detail: 'sandbox token issued', expires_at: new Date(token.expiresAt).toISOString()};
  return token.value;
}

// Sends a request with the bearer token. A 401 means the token expired or was revoked: it is
// renewed once and the request repeated (safe for queries and downloads; see graphql() for mutations).
async function authorised(c: WayfairConfig, url: string, init: RequestInit, retryOn401: boolean): Promise<Response> {
  let t = await getToken(c);
  let res = await http(c, url, {...init, headers: {...(init.headers ?? {}), Authorization: `Bearer ${t}`}});
  if (res.status === 401 && retryOn401) {
    forgetToken();
    t = await getToken(c, true);
    res = await http(c, url, {...init, headers: {...(init.headers ?? {}), Authorization: `Bearer ${t}`}});
  }
  return res;
}

export interface GraphqlResult<T> {
  data: T | null;
  errors: Array<{message: string; path?: unknown}>;
  status: number;
}

// One GraphQL call. For mutations (`retryOn401` false) a 401 is reported, not repeated: Wayfair
// rejected the request before acting on it, so the caller records a definite failure.
export async function graphql<T>(c: WayfairConfig, query: string, variables: Record<string, unknown>, retryOn401 = true): Promise<GraphqlResult<T>> {
  const res = await authorised(c, c.endpoints.graphqlUrl, {
    method: 'POST', headers: {'Content-Type': 'application/json', Accept: 'application/json'},
    body: JSON.stringify({query, variables}),
  }, retryOn401);
  const text = await res.text();
  let body: {data?: T; errors?: Array<{message?: string; path?: unknown}>} | null = null;
  try {
    body = JSON.parse(text);
  } catch {
    body = null;
  }
  if (res.status === 401 || res.status === 403) {
    throw new WayfairError('auth', `Wayfair refused access (HTTP ${res.status}); check the application's permissions`, res.status, false);
  }
  if (res.status >= 500) throw new WayfairError('provider', `Wayfair returned HTTP ${res.status}`, res.status, true);
  if (!body) throw new WayfairError('unexpected', `Wayfair returned an unreadable response (HTTP ${res.status})`, res.status, true);
  if (res.status >= 400 && !body.errors) throw new WayfairError('provider', `Wayfair returned HTTP ${res.status}`, res.status, false);
  return {
    data: body.data ?? null,
    errors: (body.errors ?? []).map(e => ({message: scrub(c, String(e.message ?? 'error')), path: e.path})),
    status: res.status,
  };
}

export interface Download {
  status: number;
  contentType: string;
  fileName: string | null;
  bytes: Buffer;
}

export async function download(c: WayfairConfig, url: string): Promise<Download> {
  const res = await authorised(c, url, {method: 'GET', headers: {Accept: 'application/pdf, application/octet-stream, */*'}}, true);
  const bytes = Buffer.from(await res.arrayBuffer());
  const disposition = res.headers.get('content-disposition') ?? '';
  const name = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/i.exec(disposition)?.[1] ?? null;
  return {status: res.status, contentType: (res.headers.get('content-type') ?? 'application/octet-stream').split(';')[0].trim(), fileName: name, bytes};
}
