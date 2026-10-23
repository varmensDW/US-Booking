// Read models for the review UI. All queries are read-only and run against varmen_db.us_booking
// (BOOKING_DATABASE_URL). Nothing here reads or writes the OMS.
import {connection, envFileOverride, queryJson, projectEnv} from './db';
import type {GroupDetail, QueueResponse, StatusResponse, SyncRun} from '@/shared/types';

const DEST = `json_build_object('oms_order_id', d.oms_order_id, 'iso2', d.destination_iso2, 'source', d.destination_source,
                                'oms_country_id', d.oms_country_id, 'stale', COALESCE(d.confirmation_stale, false))`;
const REQ = `json_build_object('id', r.id, 'requirement', r.requirement, 'oms_order_id', r.oms_order_id, 'status', r.status,
                               'detail', r.detail, 'checked_by', r.checked_by, 'checked_at', r.checked_at)`;
const CASE = `json_build_object('id', c.id, 'case_type', c.case_type, 'oms_order_id', c.oms_order_id, 'status', c.status,
                                'opened_at', c.opened_at, 'resolved_by', c.resolved_by, 'resolved_at', c.resolved_at,
                                'resolution', c.resolution, 'details', c.details)`;
const ROUTING = `COALESCE((SELECT json_agg(json_build_object('oms_source_id', rr.oms_source_id, 'channel', rr.channel,
                   'provider', rr.provider, 'integration_status', rr.integration_status) ORDER BY rr.oms_source_id)
                   FROM us_booking.routing_rule rr), '[]'::json)`;

export async function getQueue(): Promise<QueueResponse> {
  return queryJson<QueueResponse>(connection('booking'), `json_build_object(
    'generated_at', now(),
    'last_success_at', (SELECT last_success_at FROM us_booking.sync_state WHERE stream = 'oms_orders'),
    'routing', ${ROUTING},
    'totals', json_build_object(
      'orders', (SELECT count(*) FROM us_booking.oms_order o
                  WHERE EXISTS (SELECT 1 FROM us_booking.fulfilment_group_order fo JOIN us_booking.fulfilment_group g ON g.id = fo.fulfilment_group_id
                                 WHERE fo.oms_order_id = o.oms_order_id AND fo.active AND g.state NOT IN ('superseded', 'cancelled'))),
      'lines', (SELECT sum(line_count) FROM us_booking.v_review_queue),
      'ordered_units', (SELECT sum(ordered_quantity_total) FROM us_booking.v_review_queue),
      'component_rows', (SELECT count(*) FROM us_booking.oms_order_item_component),
      'booking_attempts', (SELECT count(*) FROM us_booking.booking_attempt),
      'labels', (SELECT count(*) FROM us_booking.label_file),
      'prints', (SELECT count(*) FROM us_booking.print_event),
      'parcels', (SELECT count(*) FROM us_booking.parcel)),
    'groups', COALESCE((SELECT json_agg(x ORDER BY x.oldest_order_date_raw, x.id) FROM (
      SELECT q.fulfilment_group_id AS id, q.group_key, q.state, q.provider, q.provider_account,
             split_part(q.group_key, ':', 2)::bigint AS container_order_id,
             COALESCE((SELECT o.platform_order_ref FROM us_booking.oms_order o
                        WHERE o.oms_order_id = split_part(q.group_key, ':', 2)::bigint), q.group_key) AS main_ref,
             q.order_count, q.oms_order_ids, q.platform_order_refs, q.channels, q.accounts, q.oms_statuses,
             to_char(q.oldest_order_date_raw, 'YYYY-MM-DD"T"HH24:MI:SS') AS oldest_order_date_raw,
             q.line_count, q.ordered_quantity_total, q.parcel_count, q.prior_label_check,
             COALESCE((SELECT json_agg(${DEST} ORDER BY d.oms_order_id)
                         FROM us_booking.fulfilment_group_order fo JOIN us_booking.v_order_destination d ON d.oms_order_id = fo.oms_order_id
                        WHERE fo.fulfilment_group_id = q.fulfilment_group_id AND fo.active), '[]'::json) AS destinations,
             COALESCE((SELECT json_agg(${REQ} ORDER BY r.requirement, r.oms_order_id)
                         FROM us_booking.shipment_requirement r
                        WHERE r.fulfilment_group_id = q.fulfilment_group_id AND r.status = 'unmet'), '[]'::json) AS unmet,
             COALESCE((SELECT json_agg(${CASE} ORDER BY c.id) FROM us_booking.review_case c
                        WHERE c.status = 'open' AND (c.fulfilment_group_id = q.fulfilment_group_id OR c.oms_order_id = ANY (q.oms_order_ids))), '[]'::json) AS open_cases,
             COALESCE((SELECT json_agg(DISTINCT s) FROM (
                         SELECT i.item_sku AS s FROM us_booking.oms_order_item i WHERE i.oms_order_id = ANY (q.oms_order_ids)
                         UNION SELECT i.real_sku FROM us_booking.oms_order_item i WHERE i.oms_order_id = ANY (q.oms_order_ids) AND i.real_sku IS NOT NULL) z), '[]'::json) AS skus,
             (SELECT max(o.last_synced_at) FROM us_booking.oms_order o WHERE o.oms_order_id = ANY (q.oms_order_ids)) AS last_synced_at
        FROM us_booking.v_review_queue q) x), '[]'::json))`);
}

export async function getGroupDetail(id: number): Promise<GroupDetail | null> {
  if (!Number.isSafeInteger(id) || id <= 0) return null;
  return queryJson<GroupDetail | null>(connection('booking'), `(SELECT CASE WHEN g.id IS NULL THEN NULL ELSE json_build_object(
    'group', json_build_object('id', g.id, 'group_key', g.group_key, 'state', g.state, 'provider', g.provider,
                               'provider_account', g.provider_account, 'blocked_reason', g.blocked_reason,
                               'created_at', g.created_at, 'updated_at', g.updated_at),
    'routing', ${ROUTING},
    'orders', COALESCE((SELECT json_agg(json_build_object(
        'oms_order_id', o.oms_order_id, 'platform_order_ref', o.platform_order_ref, 'role', fo.role,
        'channel', o.channel, 'account_name', o.account_name, 'oms_status', o.oms_status, 'warehouse_id', o.warehouse_id,
        'order_date_raw', to_char(o.order_date_raw, 'YYYY-MM-DD"T"HH24:MI:SS'), 'oms_merge_raw', o.oms_merge_raw,
        'booking_country_flags', o.booking_country_flags, 'ebay_cancel_status', o.ebay_cancel_status,
        'ebay_cancel_requests', o.ebay_cancel_requests, 'oms_shipped_flag', o.oms_shipped_flag,
        'oms_shipped_error', o.oms_shipped_error, 'oms_shipping_method', o.oms_shipping_method,
        'oms_shipments', o.oms_shipments,
        'ship', json_build_object('name', o.ship_name, 'company', o.ship_company, 'line1', o.ship_line1, 'line2', o.ship_line2,
                                  'line3', o.ship_line3, 'city', o.ship_city, 'region', o.ship_region, 'postcode', o.ship_postcode,
                                  'phone_present', o.ship_phone IS NOT NULL, 'email_present', o.ship_email IS NOT NULL),
        'destination', (SELECT ${DEST} FROM us_booking.v_order_destination d WHERE d.oms_order_id = o.oms_order_id),
        'confirmations', COALESCE((SELECT json_agg(json_build_object(
            'id', dc.id, 'destination_iso2', dc.destination_iso2, 'evidence_type', dc.evidence_type, 'evidence_ref', dc.evidence_ref,
            'confirmed_by', dc.confirmed_by, 'confirmed_at', dc.confirmed_at, 'status', dc.status, 'revoke_reason', dc.revoke_reason,
            'valid_for_current_address', dc.status = 'active' AND dc.ship_address_hash = o.ship_address_hash) ORDER BY dc.id DESC)
            FROM us_booking.order_destination_confirmation dc WHERE dc.oms_order_id = o.oms_order_id), '[]'::json),
        'last_synced_at', o.last_synced_at, 'first_seen_at', o.first_seen_at)
        ORDER BY (fo.role <> 'merge_parent' AND fo.role <> 'single'), o.oms_order_id)
      FROM us_booking.fulfilment_group_order fo JOIN us_booking.oms_order o ON o.oms_order_id = fo.oms_order_id
      WHERE fo.fulfilment_group_id = g.id AND fo.active), '[]'::json),
    'lines', COALESCE((SELECT json_agg(json_build_object(
        'oms_order_item_id', i.oms_order_item_id, 'oms_order_id', i.oms_order_id, 'container_order_id', i.container_order_id,
        'line_item_id', i.line_item_id, 'item_sku', i.item_sku, 'real_sku', i.real_sku, 'quantity_ordered', i.quantity_ordered,
        'quantity_raw', i.quantity_raw, 'combo_count', i.combo_count,
        'components', COALESCE((SELECT json_agg(json_build_object('sku', c.component_sku, 'qty', c.component_qty) ORDER BY c.oms_combo_id)
                                  FROM us_booking.oms_order_item_component c WHERE c.oms_order_item_id = i.oms_order_item_id), '[]'::json))
        ORDER BY i.oms_order_id, i.oms_order_item_id)
      FROM us_booking.oms_order_item i
      WHERE i.oms_order_id IN (SELECT oms_order_id FROM us_booking.fulfilment_group_order WHERE fulfilment_group_id = g.id AND active)), '[]'::json),
    'parcels', COALESCE((SELECT json_agg(json_build_object(
        'id', p.id, 'parcel_no', p.parcel_no, 'state', p.state, 'contents_status', p.contents_status,
        'measured', p.measured_by IS NOT NULL,
        'items', COALESCE((SELECT json_agg(json_build_object('oms_order_item_id', pi.oms_order_item_id, 'quantity', pi.quantity))
                             FROM us_booking.parcel_item pi WHERE pi.parcel_id = p.id), '[]'::json)) ORDER BY p.parcel_no)
      FROM us_booking.parcel p WHERE p.fulfilment_group_id = g.id), '[]'::json),
    'requirements', COALESCE((SELECT json_agg(${REQ} ORDER BY r.oms_order_id NULLS FIRST, r.requirement)
      FROM us_booking.shipment_requirement r WHERE r.fulfilment_group_id = g.id), '[]'::json),
    'cases', COALESCE((SELECT json_agg(${CASE} ORDER BY c.status <> 'open', c.id DESC) FROM us_booking.review_case c
      WHERE c.fulfilment_group_id = g.id
         OR c.oms_order_id IN (SELECT oms_order_id FROM us_booking.fulfilment_group_order WHERE fulfilment_group_id = g.id AND active)), '[]'::json)
  ) END FROM (SELECT ${id}::bigint AS want) w LEFT JOIN us_booking.fulfilment_group g ON g.id = w.want)`);
}

export async function getSyncRuns(): Promise<{runs: SyncRun[]; last_success_at: string | null}> {
  return queryJson(connection('booking'), `json_build_object(
    'last_success_at', (SELECT last_success_at FROM us_booking.sync_state WHERE stream = 'oms_orders'),
    'runs', COALESCE((SELECT json_agg(json_build_object(
        'id', r.id, 'status', r.status, 'started_at', r.started_at, 'finished_at', r.finished_at, 'rows_read', r.rows_read,
        'rows_changed', r.rows_changed, 'review_cases_opened', r.review_cases_opened, 'error', r.error,
        'counts', e.details->'counts', 'cases_opened', e.details->'review_cases_opened') ORDER BY r.id DESC)
      FROM (SELECT * FROM us_booking.sync_run ORDER BY id DESC LIMIT 50) r
      LEFT JOIN LATERAL (SELECT details FROM us_booking.event_log
                          WHERE entity = 'sync_run' AND entity_id = r.id ORDER BY id DESC LIMIT 1) e ON true), '[]'::json))`);
}

// Connectivity and configuration, for the header and the Settings page. The OMS check is a
// read-only identity query; it never imports anything.
export async function getStatus(): Promise<StatusResponse> {
  const env = projectEnv();
  const names = ['OMS_READ_DATABASE_URL', 'BOOKING_DATABASE_URL', 'BOOKING_MIGRATION_DATABASE_URL',
                 'BOOKING_DATABASE_EXPECTED_NAME', 'BOOKING_ROLE_MODE', 'SHIPPO_API_TOKEN', 'SHIPPO_MODE', 'ENABLE_LIVE_BOOKING'];
  const result: StatusResponse = {
    checked_at: new Date().toISOString(),
    environment: envFileOverride ? 'synthetic' : 'live',
    booking: {ok: false, detail: 'not checked'},
    oms: {ok: false, detail: 'not checked'},
    sync_available: false,
    sync_unavailable_reason: null,
    config: names.map(name => ({name, configured: Boolean(env[name])})),
    role_mode: env.BOOKING_ROLE_MODE || 'separate',
    live_booking_enabled: env.ENABLE_LIVE_BOOKING === 'true',
    shippo: {mode: env.SHIPPO_MODE || 'not set', token_configured: Boolean(env.SHIPPO_API_TOKEN)},
    routing: [],
  };
  const [booking, oms] = await Promise.allSettled([
    (async () => queryJson<{role: string; migrations: string[]; routing: StatusResponse['routing']; sync_fn: boolean}>(connection('booking'),
      `json_build_object('role', current_user,
         'migrations', (SELECT json_agg(filename ORDER BY version) FROM us_booking.schema_migration),
         'routing', ${ROUTING},
         'sync_fn', to_regprocedure('us_booking.oms_sync_apply(jsonb, text)') IS NOT NULL)`))(),
    (async () => queryJson<{role: string}>(connection('oms'), `json_build_object('role', current_user)`))(),
  ]);
  if (booking.status === 'fulfilled') {
    result.booking = {ok: true, detail: 'connected (read-only check)', database: env.BOOKING_DATABASE_EXPECTED_NAME,
                      role: booking.value.role, migrations: booking.value.migrations ?? []};
    result.routing = booking.value.routing;
    if (!booking.value.sync_fn) {
      result.booking.ok = false;
      result.booking.detail = 'sync function missing: run npm run db:migrate';
    }
  } else {
    result.booking = {ok: false, detail: booking.reason instanceof Error ? booking.reason.message : 'unavailable'};
  }
  if (oms.status === 'fulfilled') {
    result.oms = {ok: true, detail: 'connected (read-only check)', database: env.OMS_DATABASE_EXPECTED_NAME || 'ledsone', role: oms.value.role};
  } else {
    result.oms = {ok: false, detail: oms.reason instanceof Error ? oms.reason.message : 'unavailable'};
  }
  result.sync_available = result.booking.ok && result.oms.ok;
  // The details already name the database ("Booking database: …" / "OMS database: …").
  result.sync_unavailable_reason = !result.booking.ok ? result.booking.detail : !result.oms.ok ? result.oms.detail : null;
  return result;
}
