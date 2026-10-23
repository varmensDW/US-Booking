// Shippo TEST-mode HTTP client (server-only). The token is kept only in the config object handed
// in by the caller and is removed from every message this module produces.
import type {ShippoConfig} from './config';

export type ShippoErrorKind = 'config' | 'auth' | 'network' | 'timeout' | 'provider' | 'unexpected';

export class ShippoError extends Error {
  constructor(public kind: ShippoErrorKind, message: string, public status?: number, public sent = false) {
    super(message);
  }
}

const TIMEOUT_MS = 20_000;

function scrub(c: ShippoConfig, text: string): string {
  const out = c.token && c.token.length >= 4 ? text.split(c.token).join('[hidden]') : text;
  return out.replace(/\s+/g, ' ').slice(0, 500);
}

async function http(c: ShippoConfig, path: string, init: RequestInit): Promise<Response> {
  const url = path.startsWith('http') ? path : `${c.apiBase}${path}`;
  // The ShippoToken header is only sent to Shippo's own API. A label_url it returns is typically a
  // third-party storage URL authorised by its own signed query string; sending our token there
  // would serve no purpose and might trip an unrelated host's own header checks.
  const sameHost = url.startsWith(c.apiBase);
  try {
    return await fetch(url, {
      ...init,
      headers: {...(sameHost ? {Authorization: `ShippoToken ${c.token}`} : {}), Accept: 'application/json', ...(init.headers ?? {})},
      signal: AbortSignal.timeout(TIMEOUT_MS), redirect: 'follow', cache: 'no-store',
    });
  } catch (e) {
    const err = e as Error & {cause?: {code?: string}};
    if (err.name === 'TimeoutError' || err.name === 'AbortError') throw new ShippoError('timeout', 'Shippo did not answer within 20 s', undefined, true);
    const code = err.cause?.code ?? '';
    // A refused or unresolvable connection never reached Shippo; anything else may have.
    const sent = !['ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN'].includes(code);
    throw new ShippoError('network', scrub(c, `Shippo could not be reached (${code || err.message})`), undefined, sent);
  }
}

async function json<T>(c: ShippoConfig, res: Response): Promise<T> {
  const text = await res.text();
  let body: unknown = null;
  try {
    body = JSON.parse(text);
  } catch {
    body = null;
  }
  if (res.status === 401 || res.status === 403) {
    throw new ShippoError('auth', 'Shippo rejected the API token', res.status, false);
  }
  if (res.status >= 500) throw new ShippoError('provider', `Shippo returned HTTP ${res.status}`, res.status, true);
  if (body === null) throw new ShippoError('unexpected', scrub(c, `Shippo returned an unreadable response (HTTP ${res.status})`), res.status, true);
  if (res.status >= 400) {
    const detail = typeof body === 'object' && body ? JSON.stringify(body) : String(body);
    throw new ShippoError('provider', scrub(c, `Shippo returned HTTP ${res.status}: ${detail}`), res.status, false);
  }
  return body as T;
}

// Read-only call used only to confirm the token works: no shipment, rate or transaction is created.
export async function testAuth(c: ShippoConfig): Promise<void> {
  const res = await http(c, '/carrier_accounts?results=1', {method: 'GET'});
  await json(c, res);
}

export interface RawRate {
  object_id: string;
  amount: string;
  currency: string;
  provider: string;
  servicelevel: {name: string; token: string};
  estimated_days: number | null;
  duration_terms: string | null;
  attributes?: string[];
  carrier_account?: string;   // object_id of the specific carrier account used for this rate
}
export interface RawMessage {source?: string; code?: string; text?: string}
export interface RawShipment {
  object_id: string;
  status: string;
  rates: RawRate[];
  messages: RawMessage[];
}

// POST /shipments. address_from/address_to/parcel are sent inline (Shippo accepts an object in
// place of a pre-created address id); customs is sent inline too when supplied. async: false asks
// Shippo to answer with rates in this same response.
export async function createShipment(c: ShippoConfig, body: Record<string, unknown>): Promise<RawShipment> {
  const res = await http(c, '/shipments', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({...body, async: false})});
  return json<RawShipment>(c, res);
}

export interface RawTransaction {
  object_id: string;
  status: string;            // SUCCESS | ERROR | WAITING | QUEUED | REFUNDED | REFUNDPENDING | REFUNDREJECTED
  object_state: string;      // VALID | INVALID
  test: boolean;             // Shippo's own test-mode marker
  tracking_number: string | null;
  label_url: string | null;
  commercial_invoice_url?: string | null;   // present for some international transactions
  messages: RawMessage[];
  rate: string;
}

// Shippo's documented LabelFileTypeEnum (api-reference/transactions/create-a-shipping-label,
// read 2026-10-24). Passing none leaves it to "the default format set from the Shippo dashboard",
// which this app never assumes (see src/server/shippo/service.ts labelFormat()).
export const LABEL_FILE_TYPES = ['PNG', 'PNG_2.3x7.5', 'PDF', 'PDF_2.3x7.5', 'PDF_4x6', 'PDF_4x8',
                                 'PDF_A4', 'PDF_A5', 'PDF_A6', 'ZPLII'] as const;
export type LabelFileType = (typeof LABEL_FILE_TYPES)[number];

// POST /transactions. async: false asks Shippo to answer once the label is ready (or has failed)
// rather than returning QUEUED immediately. labelFileType is omitted entirely when null, so
// Shippo applies its own dashboard default rather than this app assuming one.
export async function purchaseTransaction(c: ShippoConfig, rateObjectId: string, metadata: string, labelFileType: LabelFileType | null): Promise<RawTransaction> {
  const res = await http(c, '/transactions', {
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({rate: rateObjectId, ...(labelFileType ? {label_file_type: labelFileType} : {}), async: false, metadata}),
  });
  return json<RawTransaction>(c, res);
}

// GET /transactions/{id}, used only to reconcile a purchase whose first outcome was unknown.
export async function getTransaction(c: ShippoConfig, transactionId: string): Promise<RawTransaction> {
  const res = await http(c, `/transactions/${encodeURIComponent(transactionId)}`, {method: 'GET'});
  return json<RawTransaction>(c, res);
}

// GET /rates/{id} (api-reference/rates/retrieve-a-rate, read 2026-10-24): a read-only lookup of a
// previously generated rate, used only to recover carrier_account for an existing attempt. Never
// used to guess anything from a tracking number -- it looks the rate up by its own saved id.
export async function getRate(c: ShippoConfig, rateObjectId: string): Promise<RawRate> {
  const res = await http(c, `/rates/${encodeURIComponent(rateObjectId)}`, {method: 'GET'});
  return json<RawRate>(c, res);
}

export interface Download {
  status: number;
  contentType: string;
  bytes: Buffer;
}

export async function download(c: ShippoConfig, url: string): Promise<Download> {
  const res = await http(c, url, {method: 'GET', headers: {Accept: 'application/pdf, application/octet-stream, */*'}});
  const bytes = Buffer.from(await res.arrayBuffer());
  return {status: res.status, contentType: (res.headers.get('content-type') ?? 'application/octet-stream').split(';')[0].trim(), bytes};
}
