// Response shapes shared by the API routes (src/app/api) and the client.

export type DestinationSource = 'country_map' | 'order_confirmation' | 'conflict' | 'unresolved';

export interface OrderDestination {
  oms_order_id: number;
  iso2: string | null;            // only from a verified country_map row or a valid confirmation
  source: DestinationSource;
  oms_country_id: number | null;  // raw OMS value, never interpreted
  stale: boolean;                 // an active confirmation exists but was made for another address
}

export interface Requirement {
  id: number;
  requirement: string;
  oms_order_id: number | null;
  status: 'met' | 'unmet' | 'not_applicable';
  detail: string | null;
  checked_by: string;
  checked_at: string;
}

export interface ReviewCaseRow {
  id: number;
  case_type: string;
  oms_order_id: number | null;
  status: 'open' | 'resolved' | 'dismissed';
  opened_at: string;
  resolved_by: string | null;
  resolved_at: string | null;
  resolution: string | null;
  details: Record<string, unknown>;
  details_hash: string;           // md5 of details: sent back when closing, to refuse stale decisions
}

export interface QueueGroup {
  id: number;
  group_key: string;
  state: string;
  provider: string;
  provider_account: string;
  container_order_id: number;
  main_ref: string;
  order_count: number;
  oms_order_ids: number[];
  platform_order_refs: string[];
  channels: string[];
  accounts: string[];
  oms_statuses: string[];
  oldest_order_date_raw: string | null;
  line_count: number;
  ordered_quantity_total: number;
  parcel_count: number;
  prior_label_check: 'oms_shipping_signal_present' | 'not_established';
  open_discrepancies: number;     // parcels whose confirmed contents no longer match the OMS lines
  destinations: OrderDestination[];
  unmet: Requirement[];
  open_cases: ReviewCaseRow[];
  skus: string[];
  last_synced_at: string | null;
}

export interface RoutingRule {
  oms_source_id: number;
  channel: string;
  provider: string;
  integration_status: 'unverified' | 'manual_only' | 'verified';
}

export interface QueueResponse {
  generated_at: string;
  last_success_at: string | null;
  groups: QueueGroup[];
  routing: RoutingRule[];
  totals: {orders: number; lines: number; ordered_units: number; component_rows: number;
           booking_attempts: number; labels: number; prints: number; parcels: number};
}

export interface DetailOrder {
  oms_order_id: number;
  platform_order_ref: string;
  role: 'single' | 'merge_parent' | 'merge_child';
  channel: string;
  account_name: string | null;
  oms_status: string;
  warehouse_id: number;
  order_date_raw: string | null;
  oms_merge_raw: string | null;
  booking_country_flags: string[];
  ebay_cancel_status: string | null;
  ebay_cancel_requests: Array<{status: string | null; current_state: string | null}> | null;
  oms_shipped_flag: number | null;
  oms_shipped_error: string | null;
  oms_shipping_method: string | null;
  oms_shipments: {total: number; tracked_not_cancelled: number; statuses: string[]} | null;
  ship: {name: string | null; company: string | null; line1: string | null; line2: string | null;
         line3: string | null; city: string | null; region: string | null; postcode: string | null;
         phone_present: boolean; email_present: boolean};
  destination: OrderDestination;
  address_hash: string;           // ship-to version: sent back with destination actions (stale-edit check)
  confirmations: Array<{id: number; destination_iso2: string; evidence_type: string; evidence_ref: string;
                        confirmed_by: string; confirmed_at: string; status: string; revoke_reason: string | null;
                        valid_for_current_address: boolean}>;
  last_synced_at: string;
  first_seen_at: string;
}

export interface DetailLine {
  oms_order_item_id: number;
  oms_order_id: number;
  container_order_id: number;
  line_item_id: string | null;
  item_sku: string;
  real_sku: string | null;
  quantity_ordered: number;
  quantity_raw: string;
  combo_count: number | null;
  allocated_qty: number;          // units in non-cancelled parcels
  absent_from_oms_since: string | null;  // the OMS no longer returns this line (row kept)
  components: Array<{sku: string; qty: number | null}>;
}

export type DimensionUnit = 'in' | 'cm';
export type WeightUnit = 'lb' | 'kg' | 'oz' | 'g';
export type ValueSource = 'profile' | 'staff';

export interface ProfileVersion {
  version: number;
  length: number;
  width: number;
  height: number;
  dimension_unit: DimensionUnit;
  packed_weight: number | null;       // total packed shipment weight to prefill
  packed_weight_unit: WeightUnit | null;
  empty_weight: number | null;        // empty packaging only; never a shipment weight
  empty_weight_unit: WeightUnit | null;
  note: string | null;
  approved_by: string;
  approved_at: string;
}

export interface DetailParcel {
  id: number;
  parcel_no: number;
  state: string;
  row_version: number;
  contents_status: 'unconfirmed' | 'confirmed' | 'stale';  // stale: confirmed, then the order lines changed
  confirmed_by: string | null;
  confirmed_at: string | null;
  length: number | null;
  width: number | null;
  height: number | null;
  dimension_unit: DimensionUnit | null;
  dimensions_source: ValueSource | null;
  weight: number | null;              // total packed shipment weight
  weight_unit: WeightUnit | null;
  weight_source: ValueSource | null;
  measured_by: string | null;         // who entered staff values; null for profile values
  measured_at: string | null;
  profile: {profile_id: number; name: string; values: ProfileVersion} | null;  // the version recorded on this parcel
  locked: boolean;                    // pending/unknown/active purchase or live label
  packaging_mode: 'measured' | 'provider_managed';  // provider_managed: Wayfair uses its own package data
  packaging_exception_reason: string | null;        // why a Wayfair parcel is measured instead
  discrepancy: ContentsDiscrepancy | null;  // the open one, else the latest closed one
  items: Array<{oms_order_item_id: number; quantity: number}>;
}

export interface ContentsChange {
  kind: 'order_added_to_group' | 'order_removed_from_group' | 'item_taken_out_of_parcel' | 'ordered_quantity_changed' | 'sku_changed'
    | 'line_no_longer_in_oms' | 'line_back_in_oms' | 'order_left_group' | 'packed_quantity_edited' | 'item_added_to_parcel';
  line?: number;
  order?: number;
  sku?: string;
  from?: number | string;
  to?: number | string;
  packed_here?: number;
  packed_all_parcels?: number;
  below_packed?: boolean;
}

export interface ContentsDiscrepancy {
  id: number;
  status: 'open' | 'reconciled' | 'acknowledged';
  parcel_locked: boolean;
  changes: ContentsChange[];
  confirmed_basis: {members: number[]; items: Array<{line: number; order: number; packed: number; ordered: number; sku: string}>};
  confirmed_by: string | null;
  confirmed_at: string | null;
  current_hash: string;
  detected_at: string;
  last_checked_at: string;
  resolved_by: string | null;
  resolved_at: string | null;
  resolution: string | null;
}

export interface GroupDetail {
  group: {id: number; group_key: string; state: string; provider: string; provider_account: string;
          blocked_reason: string | null; warehouse_id: number; created_at: string; updated_at: string};
  allocation_problems: string | null;
  packaging_policy: {mode: 'provider_managed'; production_verified: boolean} | null;  // Wayfair groups only  // allocations the current order lines no longer support
  package_default: {assignment: string; profile_id: number; profile_name: string; values: ProfileVersion} | null;
  orders: DetailOrder[];
  lines: DetailLine[];
  parcels: DetailParcel[];
  requirements: Requirement[];
  cases: ReviewCaseRow[];
  routing: RoutingRule[];
}

export interface PackageProfile {
  id: number;
  name: string;
  approval_status: 'proposed' | 'approved' | 'retired';
  current_version: number | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
  parcels_using: number;
  versions: ProfileVersion[];         // newest first
}

export interface ProfileAssignment {
  assignment: 'us1_shippo' | 'us1_amazon';
  warehouse_id: number;
  provider: string;
  profile_id: number | null;
  assigned_by: string | null;
  assigned_at: string | null;
}

export interface PackageProfilesResponse {
  profiles: PackageProfile[];
  assignments: ProfileAssignment[];
}

export interface SyncRun {
  id: number;
  status: 'running' | 'ok' | 'failed';
  started_at: string;
  finished_at: string | null;
  rows_read: number | null;
  rows_changed: number | null;
  review_cases_opened: number | null;
  error: string | null;
  counts: Record<string, number> | null;
  cases_opened: Record<string, number> | null;
}

export type SyncStage = 'starting' | 'connecting' | 'reading_oms' | 'writing_booking' | 'finished' | 'failed';

export interface SyncJob {
  id: string;
  state: 'running' | 'succeeded' | 'failed';
  stage: SyncStage;
  stages: Array<{stage: SyncStage; at: string; note?: string}>;
  started_at: string;
  finished_at: string | null;
  message: string | null;
  summary: {counts: Record<string, number>; review_cases_opened: Record<string, number>; sync_run_id: number} | null;
}

export interface SyncStatusResponse {
  job: SyncJob | null;
  runs: SyncRun[];
  last_success_at: string | null;
  error?: string;
}

export interface ServiceCheck {
  ok: boolean;
  detail: string;
}

export interface StatusResponse {
  checked_at: string;
  environment: 'live' | 'synthetic';
  booking: ServiceCheck & {database?: string; role?: string; migrations?: string[]};
  oms: ServiceCheck & {database?: string; role?: string};
  sync_available: boolean;
  sync_unavailable_reason: string | null;
  config: Array<{name: string; configured: boolean}>;
  role_mode: string;
  live_booking_enabled: boolean;
  shippo: {mode: string; token_configured: boolean};
  routing: RoutingRule[];
}
