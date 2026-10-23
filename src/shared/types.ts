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
  components: Array<{sku: string; qty: number | null}>;
}

export interface DetailParcel {
  id: number;
  parcel_no: number;
  state: string;
  contents_status: string;
  measured: boolean;
  items: Array<{oms_order_item_id: number; quantity: number}>;
}

export interface GroupDetail {
  group: {id: number; group_key: string; state: string; provider: string; provider_account: string;
          blocked_reason: string | null; created_at: string; updated_at: string};
  orders: DetailOrder[];
  lines: DetailLine[];
  parcels: DetailParcel[];
  requirements: Requirement[];
  cases: ReviewCaseRow[];
  routing: RoutingRule[];
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
