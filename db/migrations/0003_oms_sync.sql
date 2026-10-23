-- 0003_oms_sync: import of OMS order snapshots into the live queue, and the review-queue read model.
--
-- The OMS is read by scripts/oms-sync.mjs through OMS_READ_DATABASE_URL (read-only session) with
-- src/server/sync/oms_extract.sql, which returns one JSON snapshot. oms_sync_apply() writes that
-- snapshot here in the caller's transaction (the command commits it, or rolls back for a dry run).
--
-- Rules (docs/setup.md, "OMS order sync"):
--   * Stable source ids: orders by orders.id, lines by order_item_info.id, components by
--     order_combo.id, groups by 'oms:<container order id>:g<generation>'. Re-running never
--     duplicates anything.
--   * OMS-owned columns are refreshed on every run. Staff data is never overwritten: destination
--     confirmations, parcels, staff-checked requirements (checked_by not 'system:%'), and review
--     cases resolved or dismissed by staff (a case is not reopened for the same signature).
--   * Ordered SKUs and quantities are kept as ordered; pack/combo lines are not expanded and no
--     parcel contents are created. order_date stays raw. Country ids are never interpreted here.
--   * New groups start in state 'review'. Nothing here creates booking attempts or calls providers.
--   * Missing OMS tracking is never recorded as "not labelled": already_shipped_suspect is opened
--     only on a positive OMS signal, and the queue reports 'not_established' otherwise.

-- Adds one to a counter in a jsonb object of counters.
CREATE OR REPLACE FUNCTION us_booking.oms_sync_bump(p_counts jsonb, p_key text)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT p_counts || jsonb_build_object(p_key, COALESCE((p_counts->>p_key)::int, 0) + 1)
$$;

-- Opens a system review case for an order unless one of the same type is already open, or the same
-- finding (signature) was already reviewed by staff. A different finding while a case of that type
-- is open is appended to the open case's details instead. Returns true when a new case was opened.
CREATE OR REPLACE FUNCTION us_booking.oms_sync_open_case(
  p_case_type text, p_order_id bigint, p_group_id bigint, p_details jsonb, p_signature text,
  p_actor text, p_run_id bigint)
RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_open record;
  v_id   bigint;
BEGIN
  SELECT id, details INTO v_open FROM us_booking.review_case
   WHERE oms_order_id = p_order_id AND case_type = p_case_type AND status = 'open'
   FOR UPDATE;
  IF FOUND THEN
    IF v_open.details->>'signature' IS DISTINCT FROM p_signature
       AND NOT COALESCE(v_open.details->'additional', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('signature', p_signature)) THEN
      UPDATE us_booking.review_case
         SET details = details || jsonb_build_object('additional',
               COALESCE(details->'additional', '[]'::jsonb)
               || jsonb_build_array(p_details || jsonb_build_object('signature', p_signature, 'sync_run_id', p_run_id)))
       WHERE id = v_open.id;
    END IF;
    RETURN false;
  END IF;
  IF EXISTS (SELECT 1 FROM us_booking.review_case
              WHERE oms_order_id = p_order_id AND case_type = p_case_type AND details->>'signature' = p_signature) THEN
    RETURN false;
  END IF;
  INSERT INTO us_booking.review_case (case_type, oms_order_id, fulfilment_group_id, details)
  VALUES (p_case_type, p_order_id, p_group_id,
          p_details || jsonb_build_object('signature', p_signature, 'opened_by', p_actor, 'sync_run_id', p_run_id))
  RETURNING id INTO v_id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('review_case', v_id, NULL, 'open', p_actor,
          jsonb_build_object('case_type', p_case_type, 'oms_order_id', p_order_id, 'sync_run_id', p_run_id));
  RETURN true;
END;
$$;

-- Writes a system-computed requirement. A row last checked by staff (checked_by not 'system:%') is
-- left exactly as staff left it.
CREATE OR REPLACE FUNCTION us_booking.oms_sync_set_requirement(
  p_group_id bigint, p_order_id bigint, p_requirement text, p_status text, p_detail text, p_actor text)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  INSERT INTO us_booking.shipment_requirement (fulfilment_group_id, oms_order_id, requirement, status, detail, checked_by)
  VALUES (p_group_id, p_order_id, p_requirement, p_status, p_detail, p_actor)
  ON CONFLICT (fulfilment_group_id, oms_order_id, requirement) DO UPDATE
     SET status = EXCLUDED.status, detail = EXCLUDED.detail, checked_by = EXCLUDED.checked_by, checked_at = now()
   WHERE us_booking.shipment_requirement.checked_by LIKE 'system:%'
     AND (us_booking.shipment_requirement.status, us_booking.shipment_requirement.detail)
         IS DISTINCT FROM (EXCLUDED.status, EXCLUDED.detail);
END;
$$;

CREATE OR REPLACE FUNCTION us_booking.oms_sync_apply(p_snapshot jsonb, p_actor text DEFAULT 'system:oms-sync')
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  g            jsonb;
  o            jsonb;
  it           jsonb;
  cb           jsonb;
  v_cont       jsonb;
  r            record;
  v_old        record;
  v_mem        record;
  v_run_id     bigint;
  v_container  bigint;
  v_gid        bigint;
  v_gstate     text;
  v_gen        integer;
  v_src        integer;
  v_provider   text;
  v_oid        bigint;
  v_role       text;
  v_merge      text;
  v_flags      text[];
  v_hash       text;
  v_txt        text;
  v_existed    boolean;
  v_blocked    boolean;
  v_group_changed boolean;
  v_order_ids  bigint[];
  v_item_ids   bigint[];
  v_combo_ids  bigint[];
  v_missing    bigint[];
  v_groups     bigint[] := '{}';
  v_new_groups bigint[] := '{}';
  v_seen       bigint[] := '{}';
  v_cases      jsonb := '{}';
  v_skipped    jsonb := '[]';
  v_moved      jsonb := '[]';
  v_n          jsonb := '{}';
  v_summary    jsonb;
BEGIN
  IF p_snapshot->>'format' IS DISTINCT FROM 'us_booking.oms_snapshot.v1' THEN
    RAISE EXCEPTION 'unexpected snapshot format: %', p_snapshot->>'format';
  END IF;
  IF p_actor !~ '^system:' THEN
    RAISE EXCEPTION 'the sync actor must be system:<job>, not %', p_actor;
  END IF;

  -- One sync at a time: a concurrent run fails immediately instead of waiting.
  INSERT INTO us_booking.sync_state (stream) VALUES ('oms_orders') ON CONFLICT (stream) DO NOTHING;
  PERFORM 1 FROM us_booking.sync_state WHERE stream = 'oms_orders' FOR UPDATE NOWAIT;
  UPDATE us_booking.sync_state SET last_started_at = now(), updated_at = now() WHERE stream = 'oms_orders';
  INSERT INTO us_booking.sync_run (stream) VALUES ('oms_orders') RETURNING id INTO v_run_id;

  FOR g IN SELECT x FROM jsonb_array_elements(COALESCE(p_snapshot->'groups', '[]'::jsonb)) x LOOP
    v_container := (g->>'container_id')::bigint;
    SELECT x INTO v_cont FROM jsonb_array_elements(g->'orders') x WHERE (x->>'id')::bigint = v_container;

    -- Structural checks. A failing group is skipped whole (and reported), never half-imported.
    v_txt := CASE
      WHEN v_cont IS NULL THEN 'container order missing from snapshot'
      WHEN COALESCE(jsonb_array_length(g->'items'), 0) = 0 THEN 'group has no order lines'
      WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(g->'items') x
                    WHERE COALESCE(x->>'item_quantity', '') !~ '^[0-9]+$' OR (x->>'item_quantity')::numeric = 0)
        THEN 'an order line quantity is not a positive integer'
      WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(g->'items') x WHERE COALESCE(btrim(x->>'item_sku'), '') = '')
        THEN 'an order line has no item_sku'
      WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(g->'items') x
                    WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(g->'orders') y WHERE y->>'id' = x->>'order_ref_id'))
        THEN 'an order line originates from an order outside the group'
    END;
    IF v_txt IS NOT NULL THEN
      v_skipped := v_skipped || jsonb_build_object('container_id', v_container, 'reason', v_txt);
      CONTINUE;
    END IF;

    v_order_ids := ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(g->'orders') x);
    v_item_ids  := ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(g->'items') x);
    v_combo_ids := ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(COALESCE(g->'combos', '[]'::jsonb)) x);
    v_group_changed := false;

    -- Group: the live generation for this container, or a new one awaiting review.
    v_src := (v_cont->>'source_id')::int;
    v_provider := CASE v_src WHEN 1 THEN 'amazon_seller_central' WHEN 2 THEN 'shippo' WHEN 3 THEN 'shippo'
                             WHEN 6 THEN 'wayfair_partner' ELSE 'none' END;
    SELECT id, state INTO v_gid, v_gstate FROM us_booking.fulfilment_group
     WHERE group_key LIKE 'oms:' || v_container || ':g%' AND state NOT IN ('superseded', 'cancelled')
     ORDER BY generation DESC LIMIT 1 FOR UPDATE;
    IF v_gid IS NULL THEN
      SELECT COALESCE(max(generation), 0) + 1 INTO v_gen FROM us_booking.fulfilment_group
       WHERE group_key LIKE 'oms:' || v_container || ':g%';
      INSERT INTO us_booking.fulfilment_group (group_key, generation, provider, provider_account, warehouse_id, state, blocked_reason)
      VALUES ('oms:' || v_container || ':g' || v_gen, v_gen, v_provider, 'unassigned',
              (v_cont->>'warehouse_id')::int, 'review', 'imported from OMS; awaiting staff review')
      RETURNING id, state INTO v_gid, v_gstate;
      INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
      VALUES ('fulfilment_group', v_gid, NULL, 'review', p_actor,
              jsonb_build_object('container_order_id', v_container, 'provider', v_provider, 'sync_run_id', v_run_id));
      v_new_groups := v_new_groups || v_gid;
      v_n := us_booking.oms_sync_bump(v_n, 'groups_new');
    ELSE
      v_n := us_booking.oms_sync_bump(v_n, 'groups_refreshed');
    END IF;
    v_groups := v_groups || v_gid;

    IF EXISTS (SELECT 1 FROM jsonb_array_elements(g->'orders') x WHERE (x->>'source_id')::int IS DISTINCT FROM v_src) THEN
      IF us_booking.oms_sync_open_case('merge_inconsistent', v_container, v_gid,
           jsonb_build_object('reason', 'orders in one OMS merge come from different channels'),
           'mixed-sources', p_actor, v_run_id) THEN
        v_cases := us_booking.oms_sync_bump(v_cases, 'merge_inconsistent');
      END IF;
    END IF;

    -- Orders (one row per originating order).
    FOR o IN SELECT x FROM jsonb_array_elements(g->'orders') x ORDER BY (x->>'id')::bigint LOOP
      v_oid := (o->>'id')::bigint;
      v_seen := v_seen || v_oid;
      v_n := us_booking.oms_sync_bump(v_n, 'orders_read');
      v_merge := NULLIF(btrim(o->>'merge'), '');
      v_flags := ARRAY(SELECT jsonb_array_elements_text(COALESCE(o->'flags', '[]'::jsonb)));
      v_hash := md5(o::text);

      SELECT oms_status, warehouse_id, source_hash INTO v_old FROM us_booking.oms_order WHERE oms_order_id = v_oid FOR UPDATE;
      v_existed := FOUND;

      INSERT INTO us_booking.oms_order AS t (
        oms_order_id, platform_order_ref, oms_source_id, channel, sub_source_id, account_name, market_place_id,
        warehouse_id, booking_country_flags, oms_status, oms_merge_raw, merge_parent_order_id,
        ebay_cancel_status, oms_shipped_flag, oms_shipped_error, oms_shipping_method, order_date_raw,
        ship_name, ship_company, ship_line1, ship_line2, ship_line3, ship_city, ship_region, ship_postcode,
        ship_phone, ship_email, oms_country_id, ship_address_hash, source_hash)
      VALUES (
        v_oid, o->>'platform_order_ref', (o->>'source_id')::int, o->>'channel', (o->>'sub_source_id')::int,
        o->>'account_name', o->>'market_place', (o->>'warehouse_id')::int, v_flags, o->>'status', v_merge,
        CASE WHEN v_merge ~ '^[0-9]+$' THEN v_merge::bigint END,
        o->>'ebay_cancel_status', (o->>'shipped')::int, o->>'shipped_error', o->>'shipping_method',
        (o->>'order_date')::timestamp,
        NULLIF(btrim(o->'ship'->>'name'), ''), NULLIF(btrim(o->'ship'->>'company'), ''),
        NULLIF(btrim(o->'ship'->>'line1'), ''), NULLIF(btrim(o->'ship'->>'line2'), ''),
        NULLIF(btrim(o->'ship'->>'line3'), ''), NULLIF(btrim(o->'ship'->>'city'), ''),
        NULLIF(btrim(o->'ship'->>'region'), ''), NULLIF(btrim(o->'ship'->>'postcode'), ''),
        NULLIF(btrim(o->'ship'->>'phone'), ''), NULLIF(btrim(o->>'email'), ''),
        (o->'ship'->>'country_id')::int,
        md5(array_to_string(ARRAY[
              COALESCE(btrim(o->'ship'->>'name'), ''), COALESCE(btrim(o->'ship'->>'company'), ''),
              COALESCE(btrim(o->'ship'->>'line1'), ''), COALESCE(btrim(o->'ship'->>'line2'), ''),
              COALESCE(btrim(o->'ship'->>'line3'), ''), COALESCE(btrim(o->'ship'->>'city'), ''),
              COALESCE(btrim(o->'ship'->>'region'), ''), COALESCE(btrim(o->'ship'->>'postcode'), ''),
              COALESCE(o->'ship'->>'country_id', '')], chr(31))),
        v_hash)
      ON CONFLICT (oms_order_id) DO UPDATE SET
        platform_order_ref = EXCLUDED.platform_order_ref, oms_source_id = EXCLUDED.oms_source_id,
        channel = EXCLUDED.channel, sub_source_id = EXCLUDED.sub_source_id, account_name = EXCLUDED.account_name,
        market_place_id = EXCLUDED.market_place_id, warehouse_id = EXCLUDED.warehouse_id,
        booking_country_flags = EXCLUDED.booking_country_flags, oms_status = EXCLUDED.oms_status,
        oms_merge_raw = EXCLUDED.oms_merge_raw, merge_parent_order_id = EXCLUDED.merge_parent_order_id,
        ebay_cancel_status = EXCLUDED.ebay_cancel_status, oms_shipped_flag = EXCLUDED.oms_shipped_flag,
        oms_shipped_error = EXCLUDED.oms_shipped_error, oms_shipping_method = EXCLUDED.oms_shipping_method,
        order_date_raw = EXCLUDED.order_date_raw,
        ship_name = EXCLUDED.ship_name, ship_company = EXCLUDED.ship_company, ship_line1 = EXCLUDED.ship_line1,
        ship_line2 = EXCLUDED.ship_line2, ship_line3 = EXCLUDED.ship_line3, ship_city = EXCLUDED.ship_city,
        ship_region = EXCLUDED.ship_region, ship_postcode = EXCLUDED.ship_postcode, ship_phone = EXCLUDED.ship_phone,
        ship_email = EXCLUDED.ship_email, oms_country_id = EXCLUDED.oms_country_id,
        ship_address_hash = EXCLUDED.ship_address_hash, source_hash = EXCLUDED.source_hash,
        last_synced_at = now(),
        oms_changed_at = CASE WHEN t.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN now() ELSE t.oms_changed_at END;

      IF NOT v_existed THEN
        v_n := us_booking.oms_sync_bump(v_n, 'orders_inserted');
        v_group_changed := true;
        INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
        VALUES ('oms_order', v_oid, NULL, o->>'status', p_actor, jsonb_build_object('imported', true, 'sync_run_id', v_run_id));
      ELSIF v_old.source_hash IS DISTINCT FROM v_hash THEN
        v_n := us_booking.oms_sync_bump(v_n, 'orders_changed');
        v_group_changed := true;
        INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
        VALUES ('oms_order', v_oid, v_old.oms_status, o->>'status', p_actor, jsonb_build_object('changed', true, 'sync_run_id', v_run_id));
      ELSE
        v_n := us_booking.oms_sync_bump(v_n, 'orders_unchanged');
      END IF;

      -- Membership. An order regrouped by an OMS merge moves only while its old group is still in
      -- review/ready and has no parcels; otherwise staff must decide (merge_inconsistent).
      v_role := CASE WHEN v_oid <> v_container THEN 'merge_child'
                     WHEN v_merge = 'merged' OR jsonb_array_length(g->'orders') > 1 THEN 'merge_parent'
                     ELSE 'single' END;
      v_blocked := false;
      SELECT fo.fulfilment_group_id, fg.state INTO v_mem
        FROM us_booking.fulfilment_group_order fo JOIN us_booking.fulfilment_group fg ON fg.id = fo.fulfilment_group_id
       WHERE fo.oms_order_id = v_oid AND fo.active
       FOR UPDATE OF fo;
      IF FOUND AND v_mem.fulfilment_group_id <> v_gid THEN
        IF v_mem.state IN ('review', 'ready')
           AND NOT EXISTS (SELECT 1 FROM us_booking.parcel WHERE fulfilment_group_id = v_mem.fulfilment_group_id) THEN
          UPDATE us_booking.fulfilment_group_order SET active = false
           WHERE fulfilment_group_id = v_mem.fulfilment_group_id AND oms_order_id = v_oid;
          INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
          VALUES ('fulfilment_group', v_mem.fulfilment_group_id, v_mem.state, v_mem.state, p_actor,
                  jsonb_build_object('order_moved_out', v_oid, 'to_group', v_gid, 'sync_run_id', v_run_id));
          v_moved := v_moved || jsonb_build_object('oms_order_id', v_oid, 'from_group', v_mem.fulfilment_group_id, 'to_group', v_gid);
          IF NOT EXISTS (SELECT 1 FROM us_booking.fulfilment_group_order
                          WHERE fulfilment_group_id = v_mem.fulfilment_group_id AND active) THEN
            UPDATE us_booking.fulfilment_group
               SET state = 'superseded', blocked_reason = 'all orders regrouped by an OMS merge', updated_at = now()
             WHERE id = v_mem.fulfilment_group_id;
            INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
            VALUES ('fulfilment_group', v_mem.fulfilment_group_id, v_mem.state, 'superseded', p_actor,
                    jsonb_build_object('replaced_by_group', v_gid, 'sync_run_id', v_run_id));
            v_n := us_booking.oms_sync_bump(v_n, 'groups_superseded');
          END IF;
        ELSE
          v_blocked := true;
          IF us_booking.oms_sync_open_case('merge_inconsistent', v_oid, v_mem.fulfilment_group_id,
               jsonb_build_object('reason', 'OMS regrouped this order but its current group already has parcels or is past review',
                                  'current_group_id', v_mem.fulfilment_group_id, 'oms_container_order_id', v_container),
               'move:' || v_mem.fulfilment_group_id || '>' || v_container, p_actor, v_run_id) THEN
            v_cases := us_booking.oms_sync_bump(v_cases, 'merge_inconsistent');
          END IF;
        END IF;
      END IF;
      IF NOT v_blocked THEN
        INSERT INTO us_booking.fulfilment_group_order AS t (fulfilment_group_id, oms_order_id, role)
        VALUES (v_gid, v_oid, v_role)
        ON CONFLICT (fulfilment_group_id, oms_order_id) DO UPDATE SET active = true, role = EXCLUDED.role
         WHERE (t.active, t.role) IS DISTINCT FROM (true, EXCLUDED.role);
      END IF;

      -- Findings that need a decision.
      IF v_existed AND v_old.oms_status IS DISTINCT FROM o->>'status' THEN
        IF us_booking.oms_sync_open_case('oms_status_changed', v_oid, v_gid,
             jsonb_build_object('from_status', v_old.oms_status, 'to_status', o->>'status'),
             'status:' || COALESCE(v_old.oms_status, '') || '>' || COALESCE(o->>'status', ''), p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'oms_status_changed');
        END IF;
      END IF;
      IF (o->>'warehouse_id')::int IS DISTINCT FROM 32 THEN
        IF us_booking.oms_sync_open_case('warehouse_conflict', v_oid, v_gid,
             jsonb_build_object('warehouse_id', o->>'warehouse_id', 'expected_warehouse_id', 32),
             'warehouse:' || COALESCE(o->>'warehouse_id', ''), p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'warehouse_conflict');
        END IF;
      END IF;
      IF EXISTS (SELECT 1 FROM unnest(v_flags) f WHERE f <> 'Book from US') THEN
        IF us_booking.oms_sync_open_case('booking_flag_conflict', v_oid, v_gid,
             jsonb_build_object('booking_flags', to_jsonb(v_flags)),
             'flags:' || array_to_string(v_flags, '|'), p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'booking_flag_conflict');
        END IF;
      END IF;
      IF o->>'ebay_cancel_status' = 'CancelRequested'
         OR EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(o->'ebay_cancel_requests', '[]'::jsonb)) c
                     WHERE c->>'status' IS DISTINCT FROM 'CANCEL_REJECTED') THEN
        IF us_booking.oms_sync_open_case('cancellation', v_oid, v_gid,
             jsonb_build_object('ebay_cancel_status', o->>'ebay_cancel_status', 'ebay_cancel_requests', o->'ebay_cancel_requests'),
             'cancel:' || COALESCE(o->>'ebay_cancel_status', '') || ':' || md5(COALESCE(o->'ebay_cancel_requests', '[]'::jsonb)::text),
             p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'cancellation');
        END IF;
      END IF;
      -- Positive OMS shipping signals only. Their absence proves nothing (Amazon/Wayfair rows never
      -- carry tracking), so no "not labelled" state is ever recorded.
      IF COALESCE((o->'shipments'->>'tracked_not_cancelled')::int, 0) > 0 OR (o->>'shipped')::int = 1 THEN
        IF us_booking.oms_sync_open_case('already_shipped_suspect', v_oid, v_gid,
             jsonb_build_object('oms_shipments', o->'shipments', 'order_info_shipped', o->'shipped'),
             'shipping:' || COALESCE(o->'shipments'->>'tracked_not_cancelled', '0') || ':' || COALESCE(o->>'shipped', ''),
             p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'already_shipped_suspect');
        END IF;
      END IF;
      IF v_oid <> v_container AND ((o->>'status') IS DISTINCT FROM (v_cont->>'status')
                                   OR (o->>'warehouse_id') IS DISTINCT FROM (v_cont->>'warehouse_id')) THEN
        IF us_booking.oms_sync_open_case('merge_inconsistent', v_oid, v_gid,
             jsonb_build_object('reason', 'merge child differs from its parent in status or warehouse',
                                'child_status', o->>'status', 'parent_status', v_cont->>'status',
                                'child_warehouse_id', o->>'warehouse_id', 'parent_warehouse_id', v_cont->>'warehouse_id'),
             'child:' || COALESCE(o->>'status', '') || '/' || COALESCE(o->>'warehouse_id', ''), p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'merge_inconsistent');
        END IF;
      END IF;
    END LOOP;

    IF v_cont->>'merge' = 'merged' AND jsonb_array_length(g->'orders') = 1 THEN
      IF us_booking.oms_sync_open_case('merge_inconsistent', v_container, v_gid,
           jsonb_build_object('reason', 'order is marked merged but no merge children were found'),
           'parent-without-children', p_actor, v_run_id) THEN
        v_cases := us_booking.oms_sync_bump(v_cases, 'merge_inconsistent');
      END IF;
    END IF;

    -- Order lines: ordered SKU and quantity exactly as ordered; nothing is expanded or allocated.
    FOR it IN SELECT x FROM jsonb_array_elements(g->'items') x ORDER BY (x->>'id')::bigint LOOP
      v_hash := md5(it::text);
      SELECT source_hash INTO v_txt FROM us_booking.oms_order_item WHERE oms_order_item_id = (it->>'id')::bigint;
      v_existed := FOUND;
      INSERT INTO us_booking.oms_order_item AS t (
        oms_order_item_id, oms_order_id, container_order_id, line_item_id, item_sku, real_sku,
        quantity_ordered, real_qty, quantity_raw, combo_count, source_hash)
      VALUES (
        (it->>'id')::bigint, (it->>'order_ref_id')::bigint, (it->>'order_id')::bigint, it->>'line_item_id',
        it->>'item_sku', NULLIF(btrim(it->>'real_sku'), ''), (it->>'item_quantity')::int,
        CASE WHEN it->>'real_qty' ~ '^[0-9]+$' THEN (it->>'real_qty')::int END, it->>'item_quantity',
        (it->>'combo_count')::int, v_hash)
      ON CONFLICT (oms_order_item_id) DO UPDATE SET
        oms_order_id = EXCLUDED.oms_order_id, container_order_id = EXCLUDED.container_order_id,
        line_item_id = EXCLUDED.line_item_id, item_sku = EXCLUDED.item_sku, real_sku = EXCLUDED.real_sku,
        quantity_ordered = EXCLUDED.quantity_ordered, real_qty = EXCLUDED.real_qty,
        quantity_raw = EXCLUDED.quantity_raw, combo_count = EXCLUDED.combo_count,
        source_hash = EXCLUDED.source_hash, last_synced_at = now();
      IF NOT v_existed THEN
        v_n := us_booking.oms_sync_bump(v_n, 'lines_inserted');
        v_group_changed := true;
      ELSIF v_txt IS DISTINCT FROM v_hash THEN
        v_n := us_booking.oms_sync_bump(v_n, 'lines_changed');
        v_group_changed := true;
      ELSE
        v_n := us_booking.oms_sync_bump(v_n, 'lines_unchanged');
      END IF;

      IF COALESCE(btrim(it->>'real_sku'), '') = '' THEN
        IF us_booking.oms_sync_open_case('sku_missing', (it->>'order_ref_id')::bigint, v_gid,
             jsonb_build_object('oms_order_item_id', (it->>'id')::bigint, 'item_sku', it->>'item_sku',
                                'reason', 'real_sku is blank in the OMS'),
             'real_sku:' || (it->>'id'), p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'sku_missing');
        END IF;
      END IF;
      SELECT count(*) INTO v_gen FROM jsonb_array_elements(COALESCE(g->'combos', '[]'::jsonb)) c
       WHERE c->>'order_item_info_id' = it->>'id';
      IF COALESCE((it->>'combo_count')::int, 0) <> v_gen THEN
        IF us_booking.oms_sync_open_case('combo_mismatch', (it->>'order_ref_id')::bigint, v_gid,
             jsonb_build_object('oms_order_item_id', (it->>'id')::bigint, 'item_sku', it->>'item_sku',
                                'combo_count', it->'combo_count', 'component_rows', v_gen),
             'combo:' || (it->>'id') || ':' || COALESCE(it->>'combo_count', '') || ':' || v_gen, p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'combo_mismatch');
        END IF;
      END IF;
    END LOOP;

    -- Lines previously imported for these orders that the OMS no longer has: kept, and flagged.
    FOR r IN SELECT i.oms_order_id, array_agg(i.oms_order_item_id ORDER BY i.oms_order_item_id) AS ids
               FROM us_booking.oms_order_item i
              WHERE i.oms_order_id = ANY (v_order_ids) AND i.oms_order_item_id <> ALL (v_item_ids)
              GROUP BY i.oms_order_id LOOP
      IF us_booking.oms_sync_open_case('oms_status_changed', r.oms_order_id, v_gid,
           jsonb_build_object('reason', 'order lines no longer present in the OMS', 'oms_order_item_ids', to_jsonb(r.ids)),
           'lines-missing:' || array_to_string(r.ids, ','), p_actor, v_run_id) THEN
        v_cases := us_booking.oms_sync_bump(v_cases, 'oms_status_changed');
      END IF;
    END LOOP;

    -- Combo components: reference only (never parcel contents); mirror the OMS rows exactly.
    FOR cb IN SELECT x FROM jsonb_array_elements(COALESCE(g->'combos', '[]'::jsonb)) x LOOP
      INSERT INTO us_booking.oms_order_item_component (oms_combo_id, oms_order_item_id, component_sku, component_qty)
      VALUES ((cb->>'id')::bigint, (cb->>'order_item_info_id')::bigint, COALESCE(cb->>'sku', ''), (cb->>'qty')::int)
      ON CONFLICT (oms_combo_id) DO UPDATE SET
        oms_order_item_id = EXCLUDED.oms_order_item_id, component_sku = EXCLUDED.component_sku,
        component_qty = EXCLUDED.component_qty, last_synced_at = now();
    END LOOP;
    DELETE FROM us_booking.oms_order_item_component
     WHERE oms_order_item_id = ANY (v_item_ids) AND oms_combo_id <> ALL (v_combo_ids);

    -- A group that changed after staff marked it ready goes back to review; after booking it only
    -- raises a case (labels are never voided automatically).
    IF v_group_changed AND v_gstate = 'ready' THEN
      UPDATE us_booking.fulfilment_group SET state = 'review', blocked_reason = 'OMS data changed after ready', updated_at = now()
       WHERE id = v_gid;
      INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
      VALUES ('fulfilment_group', v_gid, 'ready', 'review', p_actor, jsonb_build_object('reason', 'OMS data changed', 'sync_run_id', v_run_id));
      v_n := us_booking.oms_sync_bump(v_n, 'groups_returned_to_review');
    ELSIF v_group_changed AND v_gstate IN ('booking', 'booked', 'printed') THEN
      IF us_booking.oms_sync_open_case('oms_status_changed', v_container, v_gid,
           jsonb_build_object('reason', 'OMS data changed after the group entered ' || v_gstate),
           'after:' || v_gstate || ':' || md5(g::text), p_actor, v_run_id) THEN
        v_cases := us_booking.oms_sync_bump(v_cases, 'oms_status_changed');
      END IF;
    END IF;
  END LOOP;

  -- Previously imported orders the OMS no longer returned: kept as they were, and flagged.
  FOR r IN SELECT x::bigint AS oms_order_id
             FROM jsonb_array_elements_text(COALESCE(p_snapshot->'refresh_ids', '[]'::jsonb)) x
            WHERE x::bigint <> ALL (v_seen) LOOP
    SELECT fulfilment_group_id INTO v_gid FROM us_booking.fulfilment_group_order WHERE oms_order_id = r.oms_order_id AND active;
    IF EXISTS (SELECT 1 FROM us_booking.oms_order WHERE oms_order_id = r.oms_order_id)
       AND us_booking.oms_sync_open_case('oms_status_changed', r.oms_order_id, v_gid,
             jsonb_build_object('reason', 'previously imported order was not returned by the OMS'),
             'missing-from-oms', p_actor, v_run_id) THEN
      v_cases := us_booking.oms_sync_bump(v_cases, 'oms_status_changed');
    END IF;
  END LOOP;

  -- Requirements (missing data) and destination/scope cases, recomputed for every touched group and
  -- for the current group of every synced order (an order whose move was refused stays there).
  v_groups := v_groups || ARRAY(SELECT fulfilment_group_id FROM us_booking.fulfilment_group_order
                                 WHERE active AND oms_order_id = ANY (v_seen));
  FOR v_gid IN SELECT DISTINCT x FROM unnest(v_groups) x LOOP
    FOR r IN SELECT o.*, d.destination_iso2, d.destination_source
               FROM us_booking.fulfilment_group_order fo
               JOIN us_booking.oms_order o ON o.oms_order_id = fo.oms_order_id
               JOIN us_booking.v_order_destination d ON d.oms_order_id = fo.oms_order_id
              WHERE fo.fulfilment_group_id = v_gid AND fo.active LOOP
      PERFORM us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'destination_country',
        CASE WHEN r.destination_iso2 IS NOT NULL THEN 'met' ELSE 'unmet' END,
        CASE WHEN r.destination_iso2 IS NOT NULL THEN 'destination ' || r.destination_iso2 || ' via ' || r.destination_source
             WHEN r.destination_source = 'conflict' THEN 'verified country map and order confirmation disagree'
             WHEN r.oms_country_id IS NULL THEN 'OMS has no country_id for this ship-to; needs staff confirmation'
             ELSE 'OMS country_id ' || r.oms_country_id || ' has no verified mapping and no valid staff confirmation' END,
        p_actor);
      v_txt := concat_ws(', ', CASE WHEN r.ship_name IS NULL THEN 'name' END, CASE WHEN r.ship_line1 IS NULL THEN 'line 1' END,
                               CASE WHEN r.ship_city IS NULL THEN 'city' END, CASE WHEN r.ship_postcode IS NULL THEN 'postcode' END);
      PERFORM us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'ship_to_address',
        CASE WHEN v_txt = '' THEN 'met' ELSE 'unmet' END,
        CASE WHEN v_txt = '' THEN 'name, line 1, city and postcode present' ELSE 'missing: ' || v_txt END, p_actor);
      PERFORM us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'ship_to_state',
        CASE WHEN r.ship_region IS NOT NULL THEN 'met' ELSE 'unmet' END,
        CASE WHEN r.ship_region IS NOT NULL THEN 'state/region present' ELSE 'state/region is blank in the OMS' END, p_actor);
      PERFORM us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'ship_to_phone',
        CASE WHEN r.ship_phone IS NOT NULL THEN 'met' ELSE 'unmet' END,
        CASE WHEN r.ship_phone IS NOT NULL THEN 'phone present' ELSE 'phone is blank in the OMS; some carriers require it' END, p_actor);
      PERFORM us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'customs_declaration',
        CASE WHEN r.destination_iso2 = 'CA' THEN 'unmet' WHEN r.destination_iso2 = 'US' THEN 'not_applicable'
             WHEN r.destination_iso2 IS NULL THEN 'unmet' ELSE 'not_applicable' END,
        CASE WHEN r.destination_iso2 = 'CA' THEN 'Canada: contents description, value and origin (possibly HS code) needed from staff'
             WHEN r.destination_iso2 = 'US' THEN 'domestic US shipment'
             WHEN r.destination_iso2 IS NULL THEN 'destination unresolved; required if the destination is Canada'
             ELSE 'destination is out of scope' END,
        p_actor);
      IF r.destination_iso2 IS NOT NULL AND r.destination_iso2 NOT IN ('US', 'CA') THEN
        IF us_booking.oms_sync_open_case('scope', r.oms_order_id, v_gid,
             jsonb_build_object('destination_iso2', r.destination_iso2, 'destination_source', r.destination_source),
             'destination:' || r.destination_iso2, p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'scope');
        END IF;
      ELSIF r.destination_source = 'conflict' THEN
        IF us_booking.oms_sync_open_case('destination_conflict', r.oms_order_id, v_gid,
             jsonb_build_object('oms_country_id', r.oms_country_id),
             'conflict:' || COALESCE(r.oms_country_id::text, ''), p_actor, v_run_id) THEN
          v_cases := us_booking.oms_sync_bump(v_cases, 'destination_conflict');
        END IF;
      END IF;
    END LOOP;

    SELECT provider, provider_account INTO v_mem FROM us_booking.fulfilment_group WHERE id = v_gid;
    SELECT string_agg(DISTINCT o.oms_source_id || ' (' || o.channel || '): '
                      || COALESCE(rr.provider || '/' || rr.integration_status, 'no routing rule'), '; ')
      INTO v_txt
      FROM us_booking.fulfilment_group_order fo
      JOIN us_booking.oms_order o ON o.oms_order_id = fo.oms_order_id
      LEFT JOIN us_booking.routing_rule rr ON rr.oms_source_id = o.oms_source_id
     WHERE fo.fulfilment_group_id = v_gid AND fo.active
       AND (rr.oms_source_id IS NULL OR rr.provider IS DISTINCT FROM v_mem.provider OR rr.integration_status <> 'verified');
    PERFORM us_booking.oms_sync_set_requirement(v_gid, NULL, 'routing_verified',
      CASE WHEN v_txt IS NULL THEN 'met' ELSE 'unmet' END,
      CASE WHEN v_txt IS NULL THEN 'every order routes to a verified ' || v_mem.provider || ' integration'
           ELSE 'not verified for ' || v_mem.provider || ': ' || v_txt END, p_actor);
    PERFORM us_booking.oms_sync_set_requirement(v_gid, NULL, 'provider_account',
      CASE WHEN v_mem.provider_account = 'unassigned' THEN 'unmet' ELSE 'met' END,
      CASE WHEN v_mem.provider_account = 'unassigned' THEN 'no ' || v_mem.provider || ' account assigned'
           ELSE 'account ' || v_mem.provider_account END, p_actor);
    -- Parcel work belongs to staff: created once as unmet, never recomputed by the sync.
    INSERT INTO us_booking.shipment_requirement (fulfilment_group_id, oms_order_id, requirement, status, detail, checked_by)
    VALUES (v_gid, NULL, 'parcel_measurements', 'unmet', 'no parcels measured yet', p_actor),
           (v_gid, NULL, 'parcel_contents', 'unmet', 'no parcel contents confirmed yet', p_actor)
    ON CONFLICT (fulfilment_group_id, oms_order_id, requirement) DO NOTHING;
  END LOOP;

  v_summary := jsonb_build_object(
    'sync_run_id', v_run_id,
    'extracted_at', p_snapshot->>'extracted_at',
    'groups_in_snapshot', jsonb_array_length(COALESCE(p_snapshot->'groups', '[]'::jsonb)),
    'counts', v_n,
    'review_cases_opened', v_cases,
    'groups_skipped', v_skipped,
    'orders_moved', v_moved,
    'groups', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'fulfilment_group_id', q.fulfilment_group_id, 'group_key', q.group_key, 'state', q.state,
               'provider', q.provider, 'new', q.fulfilment_group_id = ANY (v_new_groups),
               'oms_order_ids', q.oms_order_ids, 'channels', q.channels, 'oms_statuses', q.oms_statuses,
               'line_count', q.line_count, 'ordered_quantity_total', q.ordered_quantity_total,
               'scope', jsonb_build_object('in_scope', q.in_scope_orders, 'undetermined', q.undetermined_orders,
                                           'out_of_scope', q.out_of_scope_orders),
               'unmet_requirements', q.unmet_requirements, 'open_cases', q.open_cases,
               'prior_label_check', q.prior_label_check)
             ORDER BY q.fulfilment_group_id)
        FROM us_booking.v_review_queue q WHERE q.fulfilment_group_id = ANY (v_groups)), '[]'::jsonb),
    'booking_attempts_total', (SELECT count(*) FROM us_booking.booking_attempt));

  UPDATE us_booking.sync_run
     SET finished_at = now(), status = 'ok',
         rows_read = COALESCE((v_n->>'orders_read')::int, 0),
         rows_changed = COALESCE((v_n->>'orders_inserted')::int, 0) + COALESCE((v_n->>'orders_changed')::int, 0)
                      + COALESCE((v_n->>'lines_inserted')::int, 0) + COALESCE((v_n->>'lines_changed')::int, 0),
         review_cases_opened = (SELECT COALESCE(sum(value::int), 0) FROM jsonb_each_text(v_cases))
   WHERE id = v_run_id;
  UPDATE us_booking.sync_state
     SET last_success_at = now(), cursor_value = p_snapshot->>'extracted_at', last_error = NULL, updated_at = now()
   WHERE stream = 'oms_orders';
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('sync_run', v_run_id, 'running', 'ok', p_actor,
          jsonb_build_object('counts', v_n, 'review_cases_opened', v_cases, 'groups_skipped', v_skipped,
                             'orders_moved', v_moved));
  RETURN v_summary;
END;
$$;

-- Review queue: one row per live fulfilment group (superseded and cancelled groups are hidden).
-- Historical Shippo exports (hist_*) are deliberately not part of it.
CREATE OR REPLACE VIEW us_booking.v_review_queue AS
SELECT g.id AS fulfilment_group_id,
       g.group_key,
       g.state,
       g.provider,
       g.provider_account,
       g.blocked_reason,
       g.created_at,
       g.updated_at,
       COALESCE(m.order_count, 0)        AS order_count,
       m.oms_order_ids,
       m.platform_order_refs,
       m.channels,
       m.accounts,
       m.oms_statuses,
       m.oldest_order_date_raw,
       COALESCE(m.in_scope_orders, 0)     AS in_scope_orders,
       COALESCE(m.undetermined_orders, 0) AS undetermined_orders,
       COALESCE(m.out_of_scope_orders, 0) AS out_of_scope_orders,
       COALESCE(li.line_count, 0)         AS line_count,
       COALESCE(li.ordered_quantity_total, 0) AS ordered_quantity_total,
       COALESCE(rq.unmet_requirements, '{}') AS unmet_requirements,
       COALESCE(rc.open_cases, '{}')      AS open_cases,
       COALESCE(pc.parcel_count, 0)       AS parcel_count,
       -- Only a positive OMS signal is reported. No tracking in the OMS is not evidence that the
       -- order was never labelled (Amazon/Wayfair shipment rows never carry tracking).
       CASE WHEN EXISTS (SELECT 1 FROM us_booking.review_case c
                          JOIN us_booking.fulfilment_group_order fo ON fo.oms_order_id = c.oms_order_id
                         WHERE fo.fulfilment_group_id = g.id AND fo.active AND c.case_type = 'already_shipped_suspect')
            THEN 'oms_shipping_signal_present' ELSE 'not_established' END AS prior_label_check
FROM us_booking.fulfilment_group g
LEFT JOIN LATERAL (
  SELECT count(*) AS order_count,
         array_agg(o.oms_order_id ORDER BY o.oms_order_id)       AS oms_order_ids,
         array_agg(o.platform_order_ref ORDER BY o.oms_order_id) AS platform_order_refs,
         array_agg(DISTINCT o.channel)                            AS channels,
         array_agg(DISTINCT o.account_name)                       AS accounts,
         array_agg(DISTINCT o.oms_status)                         AS oms_statuses,
         min(o.order_date_raw)                                    AS oldest_order_date_raw,
         count(*) FILTER (WHERE s.scope_status = 'in_scope')      AS in_scope_orders,
         count(*) FILTER (WHERE s.scope_status = 'undetermined')  AS undetermined_orders,
         count(*) FILTER (WHERE s.scope_status = 'out_of_scope')  AS out_of_scope_orders
    FROM us_booking.fulfilment_group_order fo
    JOIN us_booking.oms_order o ON o.oms_order_id = fo.oms_order_id
    JOIN us_booking.v_order_scope s ON s.oms_order_id = fo.oms_order_id
   WHERE fo.fulfilment_group_id = g.id AND fo.active) m ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS line_count, sum(i.quantity_ordered) AS ordered_quantity_total
    FROM us_booking.fulfilment_group_order fo
    JOIN us_booking.oms_order_item i ON i.oms_order_id = fo.oms_order_id
   WHERE fo.fulfilment_group_id = g.id AND fo.active) li ON true
LEFT JOIN LATERAL (
  SELECT array_agg(r.requirement || COALESCE(':' || r.oms_order_id, '') ORDER BY r.requirement, r.oms_order_id) AS unmet_requirements
    FROM us_booking.shipment_requirement r
   WHERE r.fulfilment_group_id = g.id AND r.status = 'unmet') rq ON true
LEFT JOIN LATERAL (
  SELECT array_agg(c.case_type || COALESCE(':' || c.oms_order_id, '') ORDER BY c.case_type, c.oms_order_id) AS open_cases
    FROM us_booking.review_case c
   WHERE c.status = 'open'
     AND (c.fulfilment_group_id = g.id
          OR c.oms_order_id IN (SELECT fo.oms_order_id FROM us_booking.fulfilment_group_order fo
                                 WHERE fo.fulfilment_group_id = g.id AND fo.active))) rc ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS parcel_count FROM us_booking.parcel p
   WHERE p.fulfilment_group_id = g.id AND p.state <> 'cancelled') pc ON true
WHERE g.state NOT IN ('superseded', 'cancelled');

REVOKE EXECUTE ON FUNCTION us_booking.oms_sync_bump(jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.oms_sync_open_case(text, bigint, bigint, jsonb, text, text, bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.oms_sync_set_requirement(bigint, bigint, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.oms_sync_apply(jsonb, text) FROM PUBLIC;
