// Wayfair SANDBOX operations used by the dashboard (server-only). Every call here is an explicit
// staff action; page loads never contact Wayfair. Results are sandbox data, shown separately and
// never written to the live tables (orders still come only from the OMS sync).
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {ActionError, connection, projectEnv, projectRoot, queryJson, runAction} from '../db';
import {configView, wayfairConfig, type WayfairConfig, type WayfairConfigView} from './config';
import {authState, download, getToken, graphql, WayfairError, type AuthState} from './client';

// Documented query and fields only (Guide to Dropship Orders and ASN APIs).
const ORDERS_QUERY = `query getDropshipPurchaseOrders($limit: Int32, $hasResponse: Boolean, $fromDate: IsoDateTime, $poNumbers: [String], $sortOrder: SortOrder) {
  getDropshipPurchaseOrders(limit: $limit, hasResponse: $hasResponse, fromDate: $fromDate, poNumbers: $poNumbers, sortOrder: $sortOrder) {
    poNumber
    poDate
    supplierId
    products { partNumber quantity price }
  }
}`;
// Documented fields (Guide to the Registration & Shipping API).
const EVENT_FIELDS = `id poNumber pickupDate
      billOfLading { url }
      consolidatedShippingLabel { url }
      customsDocument { url }
      purchaseOrder { packingSlipUrl }
      generatedShippingLabels { carrierCode trackingNumber }`;
const EVENTS_QUERY = `query LabelGenerationEvents($filters: [LabelGenerationEventFilterInput!], $limit: Int) {
  labelGenerationEvents(filters: $filters, limit: $limit) {
      ${EVENT_FIELDS}
  }
}`;
const REGISTER_MUTATION = `mutation register($registrationInput: RegistrationInput!) {
  purchaseOrders {
    register(registrationInput: $registrationInput) {
      ${EVENT_FIELDS}
    }
  }
}`;

export interface SandboxOrder {
  po_number: string;
  po_date: string | null;
  supplier_id: string | null;
  account_match: 'supplier' | 'warehouse' | 'mismatch' | 'not_configured';
  products: Array<{part_number: string; quantity: number}>;
  also_in_oms: boolean;        // a possibly matching OMS reference exists; sandbox results are never linked to it
  oms_refs: string[];
}
interface OrdersState {
  ok: boolean;
  at: string;
  detail: string;
  count: number | null;
}
let lastOrders: OrdersState | null = null;

export interface SandboxStatus {
  config: WayfairConfigView;
  auth: AuthState | null;
  orders: OrdersState | null;
  live_booking_enabled: boolean;
}

export function sandboxStatus(): SandboxStatus {
  const c = wayfairConfig();
  return {config: configView(c), auth: authState(), orders: lastOrders, live_booking_enabled: projectEnv().ENABLE_LIVE_BOOKING === 'true'};
}

function usableConfig(): WayfairConfig {
  const c = wayfairConfig();
  if (!c.usable) throw new WayfairError('config', c.problems.join('; '));
  return c;
}

export async function testAuth(): Promise<AuthState> {
  const c = usableConfig();
  await getToken(c, true);
  return authState()!;
}

function accountMatch(c: WayfairConfig, supplierId: string | null): SandboxOrder['account_match'] {
  if (!c.supplierId && !c.warehouseId) return 'not_configured';
  if (supplierId && supplierId === c.supplierId) return 'supplier';
  if (supplierId && supplierId === c.warehouseId) return 'warehouse';
  return 'mismatch';
}

interface RawOrder {
  poNumber?: string;
  poDate?: string;
  supplierId?: string | number;
  products?: Array<{partNumber?: string; quantity?: number}>;
}

async function fetchOrders(c: WayfairConfig, variables: Record<string, unknown>): Promise<RawOrder[]> {
  const r = await graphql<{getDropshipPurchaseOrders: RawOrder[] | null}>(c, ORDERS_QUERY, variables);
  if (r.errors.length && !r.data?.getDropshipPurchaseOrders) {
    throw new WayfairError('graphql', `Wayfair returned errors: ${r.errors.map(e => e.message).join('; ')}`, r.status);
  }
  return r.data?.getDropshipPurchaseOrders ?? [];
}

// A small sample of sandbox purchase orders (at most 10). Only order numbers, dates, supplier ids and
// part numbers/quantities are requested: no customer names or addresses.
export async function lookupOrders(input: {limit: number; hasResponse: boolean | null; poNumbers?: string[]}): Promise<{orders: SandboxOrder[]; note: string | null}> {
  const c = usableConfig();
  const variables: Record<string, unknown> = {limit: Math.min(Math.max(input.limit, 1), 10), sortOrder: 'DESC'};
  if (input.hasResponse !== null) variables.hasResponse = input.hasResponse;
  if (input.poNumbers?.length) variables.poNumbers = input.poNumbers;
  let raw: RawOrder[];
  try {
    raw = await fetchOrders(c, variables);
  } catch (e) {
    lastOrders = {ok: false, at: new Date().toISOString(), detail: e instanceof Error ? e.message : 'failed', count: null};
    throw e;
  }
  const refs = raw.map(o => String(o.poNumber ?? '')).filter(Boolean);
  // Possible OMS counterparts: the same reference, or the reference followed by a suffix (the OMS
  // stores some Wayfair POs as e.g. "<PO>-zen"). Shown as information only; never linked.
  const inOms = refs.length
    ? await queryJson<Array<{po: string; oms_ref: string}>>(connection('booking'), `COALESCE((SELECT json_agg(json_build_object('po', r.po, 'oms_ref', o.platform_order_ref))
        FROM unnest(ARRAY[${refs.map(r => `'${r.replace(/[^A-Za-z0-9_-]/g, '')}'`).join(',')}]::text[]) AS r(po)
        JOIN us_booking.oms_order o ON o.platform_order_ref = r.po OR o.platform_order_ref LIKE r.po || '-%'), '[]'::json)`)
    : [];
  const orders: SandboxOrder[] = raw.map(o => {
    const supplierId = o.supplierId == null ? null : String(o.supplierId);
    return {
      po_number: String(o.poNumber ?? ''), po_date: o.poDate ?? null, supplier_id: supplierId,
      account_match: accountMatch(c, supplierId),
      products: (o.products ?? []).map(p => ({part_number: String(p.partNumber ?? ''), quantity: Number(p.quantity ?? 0)})),
      also_in_oms: inOms.some(m => m.po === String(o.poNumber ?? '')),
      oms_refs: inOms.filter(m => m.po === String(o.poNumber ?? '')).map(m => m.oms_ref),
    };
  });
  const mismatches = orders.filter(o => o.account_match === 'mismatch').length;
  lastOrders = {
    ok: true, at: new Date().toISOString(), count: orders.length,
    detail: orders.length === 0
      ? 'Access worked but no sandbox orders were returned (this says nothing about label access)'
      : mismatches ? `${orders.length} order(s); ${mismatches} with a supplier id that matches neither configured id`
      : `${orders.length} order(s) returned`,
  };
  return {
    orders,
    note: orders.length === 0
      ? 'No sandbox orders were returned. Wayfair: "If no data is found in the sandbox, please enter an API setup ticket." An empty answer does not show that registration or label access works.'
      : null,
  };
}

interface RawEvent {
  id?: string | number;
  poNumber?: string;
  pickupDate?: string;
  billOfLading?: {url?: string} | null;
  consolidatedShippingLabel?: {url?: string} | null;
  customsDocument?: {url?: string} | null;
  purchaseOrder?: {packingSlipUrl?: string} | null;
  generatedShippingLabels?: Array<{carrierCode?: string; trackingNumber?: string}> | null;
}

function eventSummary(e: RawEvent) {
  return {
    event_id: e.id == null ? null : String(e.id), po_number: e.poNumber ?? null, pickup_date: e.pickupDate ?? null,
    tracking: (e.generatedShippingLabels ?? []).map(l => ({carrier: l.carrierCode ?? null, tracking_number: l.trackingNumber ?? null})),
    documents: {
      shipping_label: Boolean(e.consolidatedShippingLabel?.url), bill_of_lading: Boolean(e.billOfLading?.url),
      packing_slip: Boolean(e.purchaseOrder?.packingSlipUrl), customs: Boolean(e.customsDocument?.url),
    },
  };
}

// Wayfair-side registration state for a PO. In the sandbox labelGenerationEvents returns static
// responses not tied to the test PO (Wayfair documentation), so only an event naming this exact PO
// counts as an existing registration.
export async function checkRegistration(po: string) {
  const c = usableConfig();
  // Wayfair's filter takes the nine digits only ("For filters, provide only nine digits", API error
  // INVALID_PURCHASE_ORDER_NUMBER; the documented example also filters on digits).
  const digits = /^[A-Za-z]{2}([0-9]{9})$/.exec(po)?.[1] ?? po;
  const r = await graphql<{labelGenerationEvents: RawEvent[] | null}>(c, EVENTS_QUERY, {filters: [{field: 'poNumber', equals: digits}], limit: 5});
  if (r.errors.length && !r.data?.labelGenerationEvents) {
    throw new WayfairError('graphql', `Wayfair returned errors: ${r.errors.map(e => e.message).join('; ')}`, r.status);
  }
  const events = (r.data?.labelGenerationEvents ?? []).map(eventSummary);
  const matching = events.filter(e => e.po_number === po || e.po_number === digits);
  return {
    po_number: po, events_returned: events.length, matching,
    note: events.length > matching.length
      ? 'Wayfair returned events for other PO numbers; in the sandbox this query returns static examples, so they are ignored.'
      : null,
  };
}

export interface PackageInput {
  length: string;
  width: string;
  height: string;
  weight: string;
}

// Registers one sandbox PO for shipping documents. Order of checks: configuration; the PO exists in
// the sandbox for the configured account; no local record (requested/succeeded/unknown/found); no
// Wayfair event for this PO. The record is committed before the call; a call without a definitive
// answer is recorded as 'unknown' and never repeated automatically.
export async function register(input: {staff: string; po: string; pkg: PackageInput | null}) {
  const c = usableConfig();
  if (!c.supplierId && !c.warehouseId) {
    throw new ActionError(409, 'Set WAYFAIR_SUPPLIER_ID (and WAYFAIR_WAREHOUSE_ID if used) so the account can be verified before registering.');
  }
  // Local state first: a requested, succeeded, unknown or found registration is never repeated.
  const active = await queryJson<{id: number; state: string} | null>(connection('booking'),
    `(SELECT json_build_object('id', id, 'state', state) FROM us_booking.wayfair_sandbox_registration
       WHERE po_number = '${input.po.replace(/[^A-Za-z0-9_-]/g, '')}' AND state IN ('requested', 'succeeded', 'unknown', 'found_existing') LIMIT 1)`);
  if (active) {
    throw new ActionError(409, `Sandbox PO ${input.po} already has a ${active.state} registration record (#${active.id}); it is not registered again.`
      + (active.state === 'unknown' ? ' Resolve the unknown outcome first.' : ''));
  }
  const found = await fetchOrders(c, {poNumbers: [input.po], limit: 1});
  const order = found.find(o => String(o.poNumber) === input.po);
  if (!order) throw new ActionError(404, `PO ${input.po} was not returned by the Wayfair sandbox for these credentials.`);
  const supplierId = order.supplierId == null ? null : String(order.supplierId);
  if (accountMatch(c, supplierId) === 'mismatch') {
    throw new ActionError(409, `PO ${input.po} belongs to supplier ${supplierId ?? 'unknown'}, which matches neither WAYFAIR_SUPPLIER_ID nor WAYFAIR_WAREHOUSE_ID. Not registered.`);
  }
  const existing = await checkRegistration(input.po);
  if (existing.matching.length) {
    await runAction('wayfair_sandbox_record_existing', {staff: input.staff, po_number: input.po, supplier_id: supplierId,
      response_summary: existing.matching[0]});
    return {result: 'existing' as const, summary: existing.matching[0]};
  }

  const registrationInput: Record<string, unknown> = {poNumber: input.po};
  if (c.warehouseId) registrationInput.warehouseId = c.warehouseId;
  if (input.pkg) {
    // Units as documented (KILOGRAMS, CENTIMETERS); measurements are the test values staff entered.
    const parts = (order.products ?? []).flatMap(p => Array.from({length: Math.max(Number(p.quantity ?? 0), 0)},
      (_, i) => ({partNumber: String(p.partNumber ?? ''), groupIdentifier: i + 1})));
    registrationInput.packageUnits = [{
      unitType: 'CARTON',
      weight: {unit: 'KILOGRAMS', value: Number(input.pkg.weight)},
      dimensions: {
        height: {unit: 'CENTIMETERS', value: Number(input.pkg.height)},
        width: {unit: 'CENTIMETERS', value: Number(input.pkg.width)},
        length: {unit: 'CENTIMETERS', value: Number(input.pkg.length)},
      },
      containedParts: parts,
    }];
  }
  const begun = await runAction<{id: number}>('wayfair_sandbox_begin', {
    staff: input.staff, po_number: input.po, supplier_id: supplierId, warehouse_id: c.warehouseId,
    request_summary: {warehouse_id: c.warehouseId, package_units: registrationInput.packageUnits ?? null},
  });

  let state: 'succeeded' | 'failed' | 'unknown';
  let summary: unknown = null;
  let error: string | null = null;
  try {
    const r = await graphql<{purchaseOrders: {register: RawEvent | null} | null}>(c, REGISTER_MUTATION, {registrationInput}, false);
    const ev = r.data?.purchaseOrders?.register ?? null;
    if (ev) {
      state = 'succeeded';
      summary = eventSummary(ev);
      if (r.errors.length) error = `with validation messages: ${r.errors.map(e => e.message).join('; ')}`;
    } else if (r.errors.length) {
      state = 'failed';
      error = r.errors.map(e => e.message).join('; ');
    } else {
      state = 'unknown';
      error = 'Wayfair answered without a registration or an error';
    }
  } catch (e) {
    const err = e instanceof WayfairError ? e : new WayfairError('unexpected', 'unexpected error', undefined, true);
    state = err.sent ? 'unknown' : 'failed';
    error = err.message;
  }
  await runAction('wayfair_sandbox_finish', {id: begun.id, state, response_summary: summary, error, actor: input.staff});
  return {result: state, id: begun.id, summary, error};
}

function storageDir(): string {
  const configured = projectEnv().LABEL_STORAGE_DIR || './storage/labels';
  return path.resolve(/*turbopackIgnore: true*/ projectRoot, configured, 'wayfair-sandbox');
}

const EXT: Record<string, string> = {'application/pdf': 'pdf', 'application/zpl': 'zpl', 'text/plain': 'zpl', 'application/octet-stream': 'bin'};

// Downloads the sandbox shipping label for a registered sandbox PO and stores it, marked SANDBOX.
export async function fetchLabel(input: {staff: string; registrationId: number}) {
  const c = usableConfig();
  const reg = await queryJson<{id: number; po_number: string; state: string} | null>(connection('booking'),
    `(SELECT json_build_object('id', id, 'po_number', po_number, 'state', state) FROM us_booking.wayfair_sandbox_registration WHERE id = ${input.registrationId})`);
  if (!reg) throw new ActionError(404, 'Sandbox registration not found');
  if (!['succeeded', 'found_existing'].includes(reg.state)) throw new ActionError(409, `The sandbox PO is ${reg.state}, not registered; no label can be fetched.`);
  const d = await download(c, c.endpoints.shippingLabelBase + encodeURIComponent(reg.po_number));
  if (d.status === 400 || d.status === 404) {
    throw new ActionError(409, `Wayfair has no label for ${reg.po_number} yet (HTTP ${d.status}). Documents are generated asynchronously; Wayfair recommends waiting 15 minutes after registering.`);
  }
  if (d.status === 401 || d.status === 403) throw new ActionError(409, `Wayfair refused the label download (HTTP ${d.status}); check the application's permissions.`);
  if (d.status !== 200 || d.bytes.length === 0) throw new ActionError(502, `Wayfair returned HTTP ${d.status} for the label download.`);
  const sha256 = crypto.createHash('sha256').update(d.bytes).digest('hex');
  const ext = EXT[d.contentType] ?? (d.fileName?.split('.').pop()?.replace(/[^a-z0-9]/gi, '').slice(0, 5) || 'bin');
  const fileName = `SANDBOX-${reg.po_number}-${Date.now()}.${ext}`;
  const dir = storageDir();
  fs.mkdirSync(dir, {recursive: true});
  fs.writeFileSync(path.join(dir, fileName), d.bytes);
  const r = await runAction<{id: number}>('wayfair_sandbox_label_add', {
    staff: input.staff, registration_id: reg.id, content_type: d.contentType, file_name: fileName, size_bytes: d.bytes.length, sha256,
  });
  return {label_id: r.id, content_type: d.contentType, size_bytes: d.bytes.length, sha256};
}

export function readLabelFile(fileName: string): Buffer | null {
  if (!/^SANDBOX-[A-Za-z0-9_-]+-[0-9]+\.[a-z0-9]{1,5}$/i.test(fileName)) return null;
  const file = path.join(storageDir(), fileName);
  return fs.existsSync(file) ? fs.readFileSync(file) : null;
}

export async function sandboxRecords() {
  return queryJson<{registrations: unknown[]; labels: unknown[]}>(connection('booking'), `json_build_object(
    'registrations', COALESCE((SELECT json_agg(json_build_object('id', r.id, 'po_number', r.po_number, 'supplier_id', r.supplier_id,
        'warehouse_id', r.warehouse_id, 'state', r.state, 'source', r.source, 'request_summary', r.request_summary,
        'response_summary', r.response_summary, 'error', r.error, 'requested_by', r.requested_by, 'requested_at', r.requested_at,
        'completed_at', r.completed_at, 'resolved_by', r.resolved_by, 'resolution', r.resolution) ORDER BY r.id DESC)
      FROM us_booking.wayfair_sandbox_registration r), '[]'::json),
    'labels', COALESCE((SELECT json_agg(json_build_object('id', l.id, 'registration_id', l.registration_id, 'po_number', l.po_number,
        'content_type', l.content_type, 'file_name', l.file_name, 'size_bytes', l.size_bytes, 'sha256', l.sha256,
        'fetched_by', l.fetched_by, 'fetched_at', l.fetched_at) ORDER BY l.id DESC)
      FROM us_booking.wayfair_sandbox_label l), '[]'::json))`);
}
