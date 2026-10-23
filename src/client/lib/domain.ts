// Display rules for the review screen. These mirror the backend rules and never add knowledge
// the backend does not have: no destination from raw country ids, warehouse or marketplace.
import type {BadgeTone} from '@/client/components/ui/badge';
import type {OrderDestination, QueueGroup, Requirement, RoutingRule} from '@/shared/types';

export const COUNTRY_NAMES: Record<string, string> = {US: 'United States', CA: 'Canada'};
export function countryName(iso2: string): string {
  if (COUNTRY_NAMES[iso2]) return COUNTRY_NAMES[iso2];
  try {
    return new Intl.DisplayNames(['en'], {type: 'region'}).of(iso2) ?? iso2;
  } catch {
    return iso2;
  }
}

// A destination is confirmed only from a verified country map row or a valid, evidenced
// per-order confirmation (the backend's v_order_destination). Everything else is unconfirmed.
export function confirmedIso2(d: OrderDestination | undefined): string | null {
  if (!d || !d.iso2) return null;
  return d.source === 'country_map' || d.source === 'order_confirmation' ? d.iso2 : null;
}

export type GroupDestination =
  | {kind: 'confirmed'; iso2: string}
  | {kind: 'mixed'; iso2s: string[]}
  | {kind: 'unconfirmed'; confirmed: number; total: number}
  | {kind: 'conflict'};

export function groupDestination(g: Pick<QueueGroup, 'destinations'>): GroupDestination {
  if (g.destinations.some(d => d.source === 'conflict')) return {kind: 'conflict'};
  const iso = g.destinations.map(confirmedIso2);
  if (iso.length && iso.every(Boolean)) {
    const set = [...new Set(iso as string[])];
    return set.length === 1 ? {kind: 'confirmed', iso2: set[0]} : {kind: 'mixed', iso2s: set};
  }
  return {kind: 'unconfirmed', confirmed: iso.filter(Boolean).length, total: iso.length};
}

export function destinationKey(g: QueueGroup): 'US' | 'CA' | 'other' | 'unconfirmed' | 'conflict' {
  const d = groupDestination(g);
  if (d.kind === 'conflict') return 'conflict';
  if (d.kind === 'confirmed') return d.iso2 === 'US' ? 'US' : d.iso2 === 'CA' ? 'CA' : 'other';
  return d.kind === 'mixed' ? 'other' : 'unconfirmed';
}

// Customs applicability is evaluated from the CURRENT confirmed destination, so a confirmation made
// after the last sync is reflected immediately.
export type CustomsState = 'awaiting_destination' | 'not_required' | 'required' | 'provided';
export function customsState(dest: OrderDestination | undefined, row: Requirement | undefined): CustomsState {
  const iso = confirmedIso2(dest);
  if (!iso) return 'awaiting_destination';
  if (iso !== 'CA') return 'not_required';
  return row?.status === 'met' ? 'provided' : 'required';
}

export const CHANNELS: Record<string, {label: string; tone: BadgeTone; icon: 'Package' | 'Tag' | 'ShoppingBag' | 'Sofa'}> = {
  AMAZON: {label: 'Amazon', tone: 'orange', icon: 'Package'},
  EBAY: {label: 'eBay', tone: 'info', icon: 'Tag'},
  SHOPIFY: {label: 'Shopify', tone: 'teal', icon: 'ShoppingBag'},
  WAYFAIR: {label: 'Wayfair', tone: 'violet', icon: 'Sofa'},
};
export function channelLabel(channel: string): string {
  return CHANNELS[channel]?.label ?? channel;
}

// Established routes (Shopify/eBay -> Shippo, Amazon -> Seller Central, Wayfair -> Wayfair).
export const PROVIDERS: Record<string, string> = {
  shippo: 'Shippo',
  amazon_seller_central: 'Amazon Seller Central',
  wayfair_partner: 'Wayfair',
  none: 'No route',
};
export const SOURCE_IDS: Record<string, number> = {AMAZON: 1, EBAY: 2, SHOPIFY: 3, WAYFAIR: 6};

export type Readiness = {label: string; tone: BadgeTone; detail: string};
// Readiness comes only from the backend routing_rule table (and the live-booking switch).
export function routeReadiness(provider: string, channels: string[], routing: RoutingRule[], liveBooking: boolean | undefined): Readiness {
  const rules = channels.map(c => routing.find(r => r.oms_source_id === SOURCE_IDS[c]));
  if (rules.some(r => !r)) {
    return {label: 'Not verified', tone: 'review', detail: `No routing rule is configured for ${PROVIDERS[provider] ?? provider} yet, so booking through this route is not available.`};
  }
  if (rules.some(r => r!.provider !== provider)) {
    return {label: 'Route mismatch', tone: 'danger', detail: 'The configured routing rule names a different provider.'};
  }
  if (rules.some(r => r!.integration_status === 'manual_only')) {
    return {label: 'Manual only', tone: 'info', detail: 'Labels for this route are bought outside this app.'};
  }
  if (rules.some(r => r!.integration_status !== 'verified')) {
    return {label: 'Not verified', tone: 'review', detail: 'The integration has not been verified.'};
  }
  return liveBooking
    ? {label: 'Verified', tone: 'success', detail: 'Integration verified.'}
    : {label: 'Verified, booking off', tone: 'info', detail: 'Integration verified; live booking is switched off (ENABLE_LIVE_BOOKING=false).'};
}

export const REQUIREMENT_LABELS: Record<string, string> = {
  destination_country: 'Destination country',
  ship_to_address: 'Ship-to address',
  ship_to_state: 'Ship-to state',
  ship_to_phone: 'Ship-to phone',
  parcel_measurements: 'Parcel measurements',
  parcel_contents: 'Parcel contents',
  customs_declaration: 'Customs declaration',
  routing_verified: 'Route verified',
  provider_account: 'Provider account',
};

export const CASE_LABELS: Record<string, string> = {
  scope: 'Outside US/Canada scope',
  destination_conflict: 'Destination conflict',
  cancellation: 'Cancellation request',
  warehouse_conflict: 'Warehouse changed',
  booking_flag_conflict: 'Booking flag conflict',
  merge_inconsistent: 'Merge inconsistency',
  combo_mismatch: 'Pack components mismatch',
  sku_missing: 'Internal SKU missing',
  already_shipped_suspect: 'OMS shows shipping activity',
  oms_status_changed: 'OMS order changed',
  booking_unknown: 'Booking outcome unknown',
  routing_unverified: 'Route not verified',
  over_allocation: 'Over-allocation',
  label_unretrievable: 'Label cannot be retrieved',
};
export const CASE_TONE: Record<string, BadgeTone> = {
  cancellation: 'danger', already_shipped_suspect: 'danger', booking_unknown: 'danger', scope: 'danger',
  destination_conflict: 'danger', warehouse_conflict: 'danger', label_unretrievable: 'danger',
};

export interface ReviewItem {
  key: string;
  label: string;
  tone: BadgeTone;
  kind: 'finding' | 'data' | 'setup' | 'info';
}

// One list of review reasons per group, most important first. Customs is only listed as missing
// when the confirmed destination is Canada; while the destination is unknown it is an info note.
export function reviewItems(g: QueueGroup): ReviewItem[] {
  const items: ReviewItem[] = [];
  const caseTypes = new Map<string, number>();
  for (const c of g.open_cases) caseTypes.set(c.case_type, (caseTypes.get(c.case_type) ?? 0) + 1);
  for (const [type, n] of caseTypes) {
    items.push({key: `case:${type}`, label: CASE_LABELS[type] ?? type, tone: CASE_TONE[type] ?? 'review', kind: 'finding',
                ...(n > 1 ? {label: `${CASE_LABELS[type] ?? type} ×${n}`} : {})});
  }
  if (g.open_discrepancies > 0) {
    items.push({key: 'contents:stale', label: 'Parcel contents need reconciliation', tone: 'danger', kind: 'finding'});
  }
  const unmetBy = (req: string) => g.unmet.filter(r => r.requirement === req);
  const dest = groupDestination(g);
  if (dest.kind !== 'confirmed' && dest.kind !== 'mixed') {
    items.push({key: 'req:destination', label: 'Destination not confirmed', tone: 'review', kind: 'data'});
  }
  for (const req of ['ship_to_address', 'ship_to_state', 'ship_to_phone']) {
    if (unmetBy(req).length) items.push({key: `req:${req}`, label: `${REQUIREMENT_LABELS[req]} missing`, tone: 'review', kind: 'data'});
  }
  const customsRequired = g.destinations.some(d => customsState(d, g.unmet.find(r => r.requirement === 'customs_declaration' && r.oms_order_id === d.oms_order_id)) === 'required');
  if (customsRequired) items.push({key: 'req:customs', label: 'Customs declaration needed', tone: 'review', kind: 'data'});
  if (unmetBy('parcel_measurements').length || unmetBy('parcel_contents').length) {
    items.push({key: 'req:parcels', label: 'Parcels not prepared', tone: 'neutral', kind: 'setup'});
  }
  if (unmetBy('routing_verified').length || unmetBy('provider_account').length) {
    items.push({key: 'req:route', label: 'Route not ready', tone: 'neutral', kind: 'setup'});
  }
  return items;
}

export type ReviewStatus = 'findings' | 'needs_data' | 'setup_only' | 'ready';
export function reviewStatus(g: QueueGroup): ReviewStatus {
  if (g.state === 'ready') return 'ready';
  const items = reviewItems(g);
  if (items.some(i => i.kind === 'finding')) return 'findings';
  if (items.some(i => i.kind === 'data')) return 'needs_data';
  return 'setup_only';
}
export const REVIEW_STATUS_LABELS: Record<ReviewStatus, string> = {
  findings: 'Open findings',
  needs_data: 'Missing information',
  setup_only: 'Awaiting parcels and route',
  ready: 'Marked ready',
};

export const STATUS_TONE: Record<string, BadgeTone> = {
  Inprogress: 'primary', New: 'info', Hold: 'review', Completed: 'neutral', Cancelled: 'danger',
  Refunded: 'danger', Deleted: 'danger',
};
export function omsStatusLabel(s: string): string {
  return s === 'Inprogress' ? 'In progress' : s;
}

export function requirementSort(a: Requirement, b: Requirement) {
  const order = ['unmet', 'met', 'not_applicable'];
  return order.indexOf(a.status) - order.indexOf(b.status) || a.requirement.localeCompare(b.requirement);
}

// Measurements are shown exactly as stored, in their own unit; nothing is converted.
export function formatMeasure(n: number | string | null | undefined): string {
  if (n == null || n === '') return '';
  const v = Number(n);
  return Number.isFinite(v) ? String(Number(v.toFixed(3))) : String(n);
}
export const UNIT_LABELS: Record<string, string> = {in: 'in', cm: 'cm', lb: 'lbs', kg: 'kg', oz: 'oz', g: 'g'};
export function unitLabel(u: string | null | undefined): string {
  return u ? UNIT_LABELS[u] ?? u : '';
}
export function formatDimensions(l: number | null, w: number | null, h: number | null, unit: string | null): string {
  if (l == null || w == null || h == null) return 'Not entered';
  return `${formatMeasure(l)} × ${formatMeasure(w)} × ${formatMeasure(h)} ${unitLabel(unit)}`;
}
export function formatWeight(v: number | null | undefined, unit: string | null | undefined): string {
  return v == null ? 'Not entered' : `${formatMeasure(v)} ${unitLabel(unit)}`;
}

export const ASSIGNMENTS: Record<string, {label: string; detail: string}> = {
  us1_shippo: {label: 'US1 Shippo orders', detail: 'Shopify and eBay orders shipped from US1 through Shippo'},
  us1_amazon: {label: 'US1 Amazon orders', detail: 'Amazon orders shipped from US1 through Seller Central'},
};

export const EVIDENCE_LABELS: Record<string, string> = {
  marketplace_order_record: 'Marketplace order record',
  customer_confirmation: 'Customer confirmation',
  carrier_address_validation: 'Carrier address validation',
  other: 'Other',
};
