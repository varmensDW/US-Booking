// Shippo TEST-mode operations used by the dashboard (server-only). Every call here is an explicit
// staff action; page loads never contact Shippo. Results are test data, shown separately from the
// live queue and never written to the live tables (orders still come only from the OMS sync; no
// group, parcel, booking attempt or provider_shipment is created, read or changed by this file).
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {ActionError, connection, projectEnv, projectRoot, queryJson, runAction} from '../db';
import {configView, shippoConfig, type ShippoConfig, type ShippoConfigView} from './config';
import {createShipment, download, getRate, getTransaction, purchaseTransaction, testAuth as clientTestAuth,
  LABEL_FILE_TYPES, type LabelFileType, type RawRate, type RawTransaction, ShippoError} from './client';

export interface AuthState {
  ok: boolean;
  at: string;
  detail: string;
}
let lastAuth: AuthState | null = null;
export const authState = () => lastAuth;

export interface ShippoStatus {
  config: ShippoConfigView;
  auth: AuthState | null;
  live_booking_enabled: boolean;
  label_format: LabelFileType | null;
}

// The print format requested on FUTURE purchases only (never applied retroactively to a stored
// label). NULL = no label_file_type is sent, so Shippo uses whatever format its own dashboard has
// set as the account default; this app does not assume a thermal printer or any paper size.
async function labelFormatSetting(): Promise<LabelFileType | null> {
  const row = await queryJson<{label_file_type: LabelFileType | null} | null>(connection('booking'),
    `(SELECT json_build_object('label_file_type', label_file_type) FROM us_booking.shippo_test_settings WHERE id = 1)`);
  return row?.label_file_type ?? null;
}

export async function shippoStatus(): Promise<ShippoStatus> {
  const c = shippoConfig();
  let labelFormat: LabelFileType | null = null;
  try {
    labelFormat = await labelFormatSetting();
  } catch {
    // Settings table unreadable (e.g. migration 0013 not applied yet): report as unset, not an error.
  }
  return {config: configView(c), auth: authState(), live_booking_enabled: projectEnv().ENABLE_LIVE_BOOKING === 'true', label_format: labelFormat};
}

export async function setLabelFormat(input: {staff: string; labelFileType: LabelFileType | null}) {
  if (input.labelFileType !== null && !LABEL_FILE_TYPES.includes(input.labelFileType)) {
    throw new ActionError(422, 'Unsupported label format');
  }
  const r = await runAction<{label_file_type: LabelFileType | null}>('shippo_test_set_label_format', {
    staff: input.staff, label_file_type: input.labelFileType ?? '',
  });
  return r;
}

function usableConfig(): ShippoConfig {
  const c = shippoConfig();
  if (!c.usable) throw new ShippoError('config', c.problems.join('; '));
  return c;
}

export async function testAuth(): Promise<AuthState> {
  const c = usableConfig();
  try {
    await clientTestAuth(c);
    lastAuth = {ok: true, at: new Date().toISOString(), detail: 'Shippo accepted the test token'};
  } catch (e) {
    const err = e instanceof ShippoError ? e : new ShippoError('unexpected', 'unexpected error');
    lastAuth = {ok: false, at: new Date().toISOString(), detail: err.message};
    throw err;
  }
  return lastAuth;
}

export interface AddressInput {
  name: string; company?: string | null; street1: string; street2?: string | null; city: string; state?: string | null;
  zip: string; country: string; phone: string; email: string;
}
export interface ParcelInput {length: string; width: string; height: string; dimension_unit: string; weight: string; weight_unit: string}
export interface CustomsItemInput {
  description: string; quantity: number; net_weight: string; mass_unit: string;
  value_amount: string; value_currency: string; origin_country: string; tariff_number?: string;
}
export interface CustomsInput {
  contents_type: string; contents_explanation?: string; non_delivery_option: string;
  certify: boolean; certify_signer: string; items: CustomsItemInput[];
  // Optional export-compliance fields (Shippo "Create a new customs declaration", read 2026-10-24).
  // None is prefilled or defaulted by this app; staff choose them explicitly, or leave them unset
  // and let Shippo's own validation say if the selected carrier needs one for this shipment.
  incoterm?: string;
  eel_pfc?: string;
  aes_itn?: string;               // required by Shippo if eel_pfc is AES_ITN
  b13a_filing_option?: string;
  b13a_number?: string;           // required by Shippo if b13a_filing_option is set
}

function toShippoAddress(a: AddressInput) {
  return {name: a.name, company: a.company || undefined, street1: a.street1, street2: a.street2 || undefined,
          city: a.city, state: a.state || undefined, zip: a.zip, country: a.country, phone: a.phone, email: a.email};
}
function toShippoParcel(p: ParcelInput) {
  return {length: p.length, width: p.width, height: p.height, distance_unit: p.dimension_unit, weight: p.weight, mass_unit: p.weight_unit};
}
function toShippoCustoms(c: CustomsInput) {
  return {
    contents_type: c.contents_type, contents_explanation: c.contents_explanation || undefined,
    non_delivery_option: c.non_delivery_option, certify: c.certify, certify_signer: c.certify_signer,
    incoterm: c.incoterm || undefined, eel_pfc: c.eel_pfc || undefined, aes_itn: c.aes_itn || undefined,
    b13a_filing_option: c.b13a_filing_option || undefined, b13a_number: c.b13a_number || undefined,
    items: c.items.map(i => ({description: i.description, quantity: i.quantity, net_weight: i.net_weight, mass_unit: i.mass_unit,
                              value_amount: i.value_amount, value_currency: i.value_currency, origin_country: i.origin_country,
                              tariff_number: i.tariff_number || undefined})),
  };
}

export interface RateOut {
  rate_object_id: string; carrier: string; service: string; service_token: string; amount: string; currency: string;
  estimated_days: number | null; duration_terms: string | null; carrier_account_id: string | null;
}
function mapRate(r: RawRate): RateOut {
  return {rate_object_id: r.object_id, carrier: r.provider, service: r.servicelevel?.name ?? r.servicelevel?.token ?? 'service',
          service_token: r.servicelevel?.token ?? '', amount: r.amount, currency: r.currency,
          estimated_days: r.estimated_days ?? null, duration_terms: r.duration_terms ?? null,
          carrier_account_id: r.carrier_account ?? null};
}

// Requests test rates for one synthetic shipment. The ship-from address is always the explicitly
// configured one (never guessed); ship-to is synthetic test data staff entered for this call only.
// Customs is required whenever the destination differs from the ship-from country (in this phase,
// that means Canada) and is never filled with invented values.
export async function getRates(input: {staff: string; shipTo: AddressInput; parcel: ParcelInput; customs: CustomsInput | null}) {
  const c = usableConfig();
  if (!c.shipFrom) throw new ActionError(409, 'Configure SHIPPO_SHIP_FROM_* in .env before requesting test rates; it is not guessed from historical labels.');
  const destCountry = input.shipTo.country.toUpperCase();
  const needsCustoms = destCountry !== c.shipFrom.country.toUpperCase();
  if (needsCustoms && !input.customs) {
    throw new ActionError(422, `Customs information is required: the destination (${destCountry}) differs from the ship-from country (${c.shipFrom.country}).`);
  }
  const body: Record<string, unknown> = {
    address_from: toShippoAddress(c.shipFrom), address_to: toShippoAddress(input.shipTo), parcels: [toShippoParcel(input.parcel)],
  };
  if (needsCustoms && input.customs) body.customs_declaration = toShippoCustoms(input.customs);
  // address_return is sent only when explicitly configured (SHIPPO_SHIP_RETURN_*); Shippo's
  // documentation does not say what it falls back to otherwise, so this app never guesses.
  if (c.shipReturn) body.address_return = toShippoAddress(c.shipReturn);
  const shipment = await createShipment(c, body);
  const rates = (shipment.rates ?? []).map(mapRate);
  const record = await runAction<{id: number}>('shippo_test_shipment_add', {
    staff: input.staff, ship_from: c.shipFrom, ship_to: input.shipTo, destination_country: destCountry,
    parcel: input.parcel, customs: needsCustoms ? input.customs : null, provider_shipment_id: shipment.object_id,
    rates, messages: shipment.messages ?? [],
  });
  return {
    shipment_id: record.id, rates,
    note: rates.length === 0 ? 'Shippo returned no rates for this parcel and destination; see the messages below.' : null,
    messages: shipment.messages ?? [],
  };
}

function classify(e: unknown): {state: 'failed' | 'unknown'; error: string} {
  const err = e instanceof ShippoError ? e : new ShippoError('unexpected', e instanceof Error ? e.message : 'unexpected error');
  // A definite rejection before anything was sent is 'failed'; anything that may have reached
  // Shippo without a readable answer (timeout, 5xx, an unparsable body) is 'unknown' and is never
  // retried automatically (see shippo_test_purchase_begin's one-blocking-purchase rule).
  return {state: err.sent ? 'unknown' : 'failed', error: err.message};
}

// Purchases a TEST label for one staff-selected rate (never chosen automatically). The purchase
// row is committed in state 'requested' before Shippo is called. A test shipment that already has
// a requested, unknown, succeeded or staff-confirmed purchase is refused (the database enforces
// this with a unique index; see 0012/0013): once a label has actually been bought, that shipment
// is done and is not purchased again; a failed or rejected attempt may still be retried.
export async function purchaseLabel(input: {staff: string; shipmentId: number; rateObjectId: string; rateSummary: RateOut}) {
  const c = usableConfig();
  const labelFileType = await labelFormatSetting().catch(() => null);
  const begun = await runAction<{id: number; correlation_key: string}>('shippo_test_purchase_begin', {
    staff: input.staff, shipment_id: input.shipmentId, rate_object_id: input.rateObjectId, rate_summary: input.rateSummary,
  });
  // The rate staff explicitly selected is Shippo's own data for that exact rate (captured when
  // "Get test rates" ran): authoritative regardless of the purchase's outcome, so it is recorded
  // here rather than left null or guessed later from the tracking number.
  const fromRate = {
    carrier: input.rateSummary.carrier ?? null, service_level: input.rateSummary.service ?? null,
    carrier_account_id: input.rateSummary.carrier_account_id ?? null,
    amount: input.rateSummary.amount ?? null, currency: input.rateSummary.currency ?? null,
  };
  let finish: Record<string, unknown>;
  try {
    const txn = await purchaseTransaction(c, input.rateObjectId, begun.correlation_key, labelFileType);
    finish = {...fromRate, ...outcomeFromTransaction(txn)};
  } catch (e) {
    const {state, error} = classify(e);
    finish = {...fromRate, state, error, provider_transaction_id: null, test_mode: null};
  }
  const result = await runAction<{id: number; state: string}>('shippo_test_purchase_finish', {id: begun.id, actor: input.staff, ...finish});
  return {purchase_id: begun.id, ...result};
}

// Shippo's own test-mode marker (Transaction.test) must be true, and status must be SUCCESS,
// before a purchase is presented as a usable test label. Anything else is recorded, never shown as
// usable, and keeps the provider's transaction id for reconciliation.
function outcomeFromTransaction(txn: RawTransaction): Record<string, unknown> {
  const base = {provider_transaction_id: txn.object_id, test_mode: txn.test};
  if (txn.status === 'SUCCESS' && txn.object_state === 'VALID' && txn.test === true) {
    return {...base, state: 'succeeded', tracking_number: txn.tracking_number, label_source_url: txn.label_url,
            commercial_invoice_source_url: txn.commercial_invoice_url ?? null, error: null};
  }
  if (txn.status === 'SUCCESS' && txn.test !== true) {
    // Should not happen given the pre-flight token check, but is never presented as usable if it does.
    return {...base, state: 'rejected_not_test', error: 'Shippo returned a transaction not marked test mode; it is not shown as a usable test label.'};
  }
  if (txn.status === 'ERROR') {
    return {...base, state: 'failed', error: (txn.messages ?? []).map(m => m.text).filter(Boolean).join('; ') || 'Shippo rejected the purchase'};
  }
  // WAITING / QUEUED / anything undocumented: not a definite answer despite a 200 response.
  return {...base, state: 'unknown', error: `Shippo returned status ${txn.status} without a definite outcome`};
}

// Recovers carrier/service/carrier_account/amount/currency for a COMPLETED purchase that is still
// missing them, filling only columns that are currently NULL (never overwrites a saved value, and
// never changes the purchase's state). Prefers data already saved on the purchase itself
// (rate_summary, from Shippo's own rates response); for carrier_account_id specifically, which
// earlier attempts did not capture, it falls back to a read-only GET /rates/{id} lookup by the
// purchase's own saved rate_object_id -- never anything derived from the tracking number.
export async function recoverPurchaseDetails(input: {staff: string; purchaseId: number}) {
  const c = usableConfig();
  const pur = await queryJson<{id: number; rate_object_id: string; completed_at: string | null;
    carrier: string | null; service_level: string | null; carrier_account_id: string | null; amount: string | null; currency: string | null;
    rate_summary: {carrier?: string; service?: string; amount?: string; currency?: string; carrier_account_id?: string} | null} | null>(
    connection('booking'),
    `(SELECT json_build_object('id', id, 'rate_object_id', rate_object_id, 'completed_at', completed_at, 'carrier', carrier,
         'service_level', service_level, 'carrier_account_id', carrier_account_id, 'amount', amount, 'currency', currency,
         'rate_summary', rate_summary)
        FROM us_booking.shippo_test_purchase WHERE id = ${input.purchaseId})`);
  if (!pur) throw new ActionError(404, 'Shippo test purchase not found');
  if (!pur.completed_at) throw new ActionError(409, 'This purchase has not already completed; details can be recovered only afterwards.');
  const rs = pur.rate_summary ?? {};
  let fromLookup: {carrier?: string; service_level?: string; carrier_account_id?: string; amount?: string; currency?: string} = {};
  let lookupNote: string | null = null;
  if (!pur.carrier_account_id) {
    try {
      const rate = await getRate(c, pur.rate_object_id);
      fromLookup = {carrier: rate.provider, service_level: rate.servicelevel?.name, carrier_account_id: rate.carrier_account,
                    amount: rate.amount, currency: rate.currency};
    } catch (e) {
      const err = e instanceof ShippoError ? e : null;
      lookupNote = err?.status === 404
        ? 'Shippo no longer has this rate on record (rates expire); carrier account id could not be recovered this way.'
        : `Shippo rate lookup failed: ${err?.message ?? 'unexpected error'}`;
    }
  }
  const payload = {
    staff: input.staff, id: pur.id,
    carrier: pur.carrier ?? rs.carrier ?? fromLookup.carrier ?? null,
    service_level: pur.service_level ?? rs.service ?? fromLookup.service_level ?? null,
    carrier_account_id: pur.carrier_account_id ?? rs.carrier_account_id ?? fromLookup.carrier_account_id ?? null,
    amount: pur.amount ?? rs.amount ?? fromLookup.amount ?? null,
    currency: pur.currency ?? rs.currency ?? fromLookup.currency ?? null,
  };
  const result = await runAction<{id: number; carrier: string | null; service_level: string | null; carrier_account_id: string | null;
    amount: string | null; currency: string | null}>('shippo_test_purchase_recover_details', payload);
  return {...result, note: lookupNote};
}

export async function resolvePurchase(input: {staff: string; id: number; outcome: 'confirmed_purchased' | 'resolved_not_purchased'; evidence: string}) {
  return runAction('shippo_test_purchase_resolve', input);
}

function storageDir(): string {
  const configured = projectEnv().LABEL_STORAGE_DIR || './storage/labels';
  return path.resolve(/*turbopackIgnore: true*/ projectRoot, configured, 'shippo-test');
}

async function downloadAndStore(c: ShippoConfig, input: {staff: string; purchaseId: number; url: string; kind: 'label' | 'customs_invoice'}) {
  const d = await download(c, input.url);
  if (d.status !== 200 || d.bytes.length === 0) throw new ActionError(502, `Could not download the ${input.kind === 'label' ? 'label' : 'customs invoice'} (HTTP ${d.status}).`);
  const sha256 = crypto.createHash('sha256').update(d.bytes).digest('hex');
  const ext = d.contentType === 'application/pdf' ? 'pdf' : 'bin';
  const fileName = `SHIPPOTEST-${input.purchaseId}-${input.kind === 'customs_invoice' ? 'invoice-' : ''}${Date.now()}.${ext}`;
  const dir = storageDir();
  fs.mkdirSync(dir, {recursive: true});
  fs.writeFileSync(path.join(dir, fileName), d.bytes);
  const r = await runAction<{id: number}>('shippo_test_label_add', {
    staff: input.staff, purchase_id: input.purchaseId, content_type: d.contentType, file_name: fileName, size_bytes: d.bytes.length,
    sha256, source_url: input.url, kind: input.kind,
  });
  return {label_id: r.id, content_type: d.contentType, size_bytes: d.bytes.length, sha256};
}

// Downloads and stores the label (and, when Shippo returned one, the customs invoice) for a
// succeeded or staff-confirmed test purchase. Idempotent per file kind: either one already stored
// is reused without contacting Shippo again; the main label is never bought a second time.
export async function fetchLabel(input: {staff: string; purchaseId: number}) {
  const c = usableConfig();
  const existing = await queryJson<Array<{id: number; kind: string}>>(connection('booking'),
    `COALESCE((SELECT json_agg(json_build_object('id', id, 'kind', kind)) FROM us_booking.shippo_test_label WHERE purchase_id = ${input.purchaseId}), '[]'::json)`);
  const existingLabel = existing.find(l => l.kind === 'label');
  const existingInvoice = existing.find(l => l.kind === 'customs_invoice');
  const pur = await queryJson<{id: number; state: string; label_source_url: string | null; commercial_invoice_source_url: string | null;
    provider_transaction_id: string | null} | null>(
    connection('booking'),
    `(SELECT json_build_object('id', id, 'state', state, 'label_source_url', label_source_url,
         'commercial_invoice_source_url', commercial_invoice_source_url, 'provider_transaction_id', provider_transaction_id)
        FROM us_booking.shippo_test_purchase WHERE id = ${input.purchaseId})`);
  if (!pur) throw new ActionError(404, 'Shippo test purchase not found');
  if (!['succeeded', 'confirmed_purchased'].includes(pur.state)) {
    throw new ActionError(409, `The test purchase is ${pur.state}, not a usable label; nothing can be fetched.`);
  }
  let labelUrl = pur.label_source_url;
  let invoiceUrl = pur.commercial_invoice_source_url;
  if (!labelUrl && !existingLabel) {
    // 'confirmed_purchased' (resolved from 'unknown'): re-check with Shippo before trusting a label.
    if (!pur.provider_transaction_id) throw new ActionError(409, 'No provider transaction id was recorded for this purchase; it cannot be reconciled.');
    const txn = await getTransaction(c, pur.provider_transaction_id);
    if (!(txn.status === 'SUCCESS' && txn.test === true)) {
      throw new ActionError(409, `Shippo's own record of this transaction is ${txn.status}${txn.test !== true ? ' (not test mode)' : ''}; no usable label.`);
    }
    labelUrl = txn.label_url;
    invoiceUrl = invoiceUrl ?? txn.commercial_invoice_url ?? null;
  }
  let label: {label_id: number; content_type: string; size_bytes: number; sha256: string; already_stored: boolean};
  if (existingLabel) {
    label = {label_id: existingLabel.id, content_type: '', size_bytes: 0, sha256: '', already_stored: true};
  } else {
    if (!labelUrl) throw new ActionError(409, 'Shippo has not returned a label URL for this purchase yet.');
    label = {...(await downloadAndStore(c, {staff: input.staff, purchaseId: pur.id, url: labelUrl, kind: 'label'})), already_stored: false};
  }
  let invoice: {label_id: number; already_stored: boolean} | null = null;
  if (existingInvoice) {
    invoice = {label_id: existingInvoice.id, already_stored: true};
  } else if (invoiceUrl) {
    invoice = {...(await downloadAndStore(c, {staff: input.staff, purchaseId: pur.id, url: invoiceUrl, kind: 'customs_invoice'})), already_stored: false};
  }
  return {...label, customs_invoice: invoice};
}

export function readLabelFile(fileName: string): Buffer | null {
  if (!/^SHIPPOTEST-[0-9]+-(invoice-)?[0-9]+\.[a-z0-9]{1,5}$/i.test(fileName)) return null;
  const file = path.join(storageDir(), fileName);
  return fs.existsSync(file) ? fs.readFileSync(file) : null;
}

export async function testRecords() {
  return queryJson<{shipments: unknown[]; purchases: unknown[]; labels: unknown[]}>(connection('booking'), `json_build_object(
    'shipments', COALESCE((SELECT json_agg(json_build_object('id', s.id, 'ship_from', s.ship_from, 'ship_to', s.ship_to,
        'destination_country', s.destination_country, 'parcel', s.parcel, 'customs', s.customs,
        'provider_shipment_id', s.provider_shipment_id, 'rates', s.rates, 'messages', s.messages,
        'requested_by', s.requested_by, 'requested_at', s.requested_at) ORDER BY s.id DESC)
      FROM us_booking.shippo_test_shipment s), '[]'::json),
    'purchases', COALESCE((SELECT json_agg(json_build_object('id', p.id, 'shipment_id', p.shipment_id, 'rate_object_id', p.rate_object_id,
        'rate_summary', p.rate_summary, 'state', p.state, 'provider_transaction_id', p.provider_transaction_id, 'test_mode', p.test_mode,
        'tracking_number', p.tracking_number, 'carrier', p.carrier, 'service_level', p.service_level, 'carrier_account_id', p.carrier_account_id,
        'amount', p.amount, 'currency', p.currency, 'commercial_invoice_source_url', p.commercial_invoice_source_url,
        'error', p.error, 'requested_by', p.requested_by, 'requested_at', p.requested_at, 'completed_at', p.completed_at,
        'resolved_by', p.resolved_by, 'resolution', p.resolution) ORDER BY p.id DESC)
      FROM us_booking.shippo_test_purchase p), '[]'::json),
    'labels', COALESCE((SELECT json_agg(json_build_object('id', l.id, 'purchase_id', l.purchase_id, 'kind', l.kind, 'content_type', l.content_type,
        'file_name', l.file_name, 'size_bytes', l.size_bytes, 'sha256', l.sha256, 'fetched_by', l.fetched_by, 'fetched_at', l.fetched_at)
        ORDER BY l.id DESC)
      FROM us_booking.shippo_test_label l), '[]'::json))`);
}
