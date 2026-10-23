-- 0005_oms_sync_revalidation: staff input never keeps an outdated approval; recurring problems
-- are not suppressed; customs wording depends on the destination; OMS evidence kept for review.
--
-- Changes to the 0003/0004 sync (applied migrations are not edited):
--   1. Destination confirmations: when the OMS ship-to changes, an active confirmation made
--      against the old address is revoked (row kept, revoked_by system:oms-sync, with reason).
--      Requirements store the data they were evaluated against (shipment_requirement.basis_hash).
--      A staff-checked requirement is kept while that basis is unchanged, and invalidated (logged
--      in event_log with the previous staff values) when it changes. A staff check without a
--      recorded basis is invalidated when its order's OMS data changes.
--   2. Review cases: an unchanged finding that staff resolved or dismissed stays closed. A closed
--      finding whose condition disappears is marked cleared; if the problem appears again, a new
--      case opens with recurrence_of pointing at the earlier one (whose resolution is kept).
--      Changed evidence (a different signature) opens a new case, as before.
--   3. Customs: while the destination is unknown the requirement stays blocking but says that
--      applicability awaits destination confirmation; US -> not applicable; Canada -> required.
--   4. oms_order keeps the OMS shipment summary and eBay cancellation requests it was synced
--      with, so the review screen can show the evidence behind each finding.

ALTER TABLE us_booking.oms_order ADD COLUMN IF NOT EXISTS oms_shipments jsonb;
ALTER TABLE us_booking.oms_order ADD COLUMN IF NOT EXISTS ebay_cancel_requests jsonb;
ALTER TABLE us_booking.shipment_requirement ADD COLUMN IF NOT EXISTS basis_hash text;

-- Opens a system review case unless one of the same type is open for the order, or the same
-- finding (signature) was already closed by staff and has not cleared since. Records every finding
-- seen during a sync run (pg_temp.usb_sync_case_seen) so cleared findings can be detected.
CREATE OR REPLACE FUNCTION us_booking.oms_sync_open_case(
  p_case_type text, p_order_id bigint, p_group_id bigint, p_details jsonb, p_signature text,
  p_actor text, p_run_id bigint)
RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_open  record;
  v_prior bigint;
  v_id    bigint;
BEGIN
  IF to_regclass('pg_temp.usb_sync_case_seen') IS NOT NULL THEN
    EXECUTE 'INSERT INTO pg_temp.usb_sync_case_seen VALUES ($1, $2)' USING p_order_id, p_case_type;
  END IF;
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
              WHERE oms_order_id = p_order_id AND case_type = p_case_type AND details->>'signature' = p_signature
                AND NOT details ? 'condition_cleared_run') THEN
    RETURN false;
  END IF;
  SELECT max(id) INTO v_prior FROM us_booking.review_case
   WHERE oms_order_id = p_order_id AND case_type = p_case_type AND details->>'signature' = p_signature;
  INSERT INTO us_booking.review_case (case_type, oms_order_id, fulfilment_group_id, details)
  VALUES (p_case_type, p_order_id, p_group_id,
          p_details || jsonb_build_object('signature', p_signature, 'opened_by', p_actor, 'sync_run_id', p_run_id)
                    || CASE WHEN v_prior IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('recurrence_of', v_prior) END)
  RETURNING id INTO v_id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('review_case', v_id, NULL, 'open', p_actor,
          jsonb_build_object('case_type', p_case_type, 'oms_order_id', p_order_id, 'sync_run_id', p_run_id,
                             'recurrence_of', v_prior));
  RETURN true;
END;
$$;

-- Writes a system-computed requirement together with the data it was evaluated against (basis).
-- A row last checked by staff is left as staff set it while its basis is unchanged; when the basis
-- changes (or, with no recorded basis, when the order's OMS data changed in this run) the staff
-- check is invalidated: the system value replaces it and the previous staff values go to event_log.
-- Returns true when a staff check was invalidated.
DROP FUNCTION IF EXISTS us_booking.oms_sync_set_requirement(bigint, bigint, text, text, text, text);
CREATE OR REPLACE FUNCTION us_booking.oms_sync_set_requirement(
  p_group_id bigint, p_order_id bigint, p_requirement text, p_status text, p_detail text, p_actor text,
  p_basis text, p_source_changed boolean)
RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_row us_booking.shipment_requirement%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM us_booking.shipment_requirement
   WHERE fulfilment_group_id = p_group_id AND oms_order_id IS NOT DISTINCT FROM p_order_id AND requirement = p_requirement
   FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO us_booking.shipment_requirement (fulfilment_group_id, oms_order_id, requirement, status, detail, checked_by, basis_hash)
    VALUES (p_group_id, p_order_id, p_requirement, p_status, p_detail, p_actor, p_basis);
    RETURN false;
  END IF;
  IF v_row.checked_by NOT LIKE 'system:%' THEN
    IF (v_row.basis_hash IS NOT NULL AND v_row.basis_hash IS DISTINCT FROM p_basis)
       OR (v_row.basis_hash IS NULL AND p_source_changed) THEN
      INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
      VALUES ('shipment_requirement', v_row.id, v_row.status, p_status, p_actor,
              jsonb_build_object('reason', 'OMS data changed after the staff check; staff check invalidated',
                                 'invalidated_staff_check', jsonb_build_object(
                                   'status', v_row.status, 'detail', v_row.detail, 'checked_by', v_row.checked_by,
                                   'checked_at', v_row.checked_at, 'basis_hash', v_row.basis_hash),
                                 'oms_order_id', p_order_id, 'requirement', p_requirement));
      UPDATE us_booking.shipment_requirement
         SET status = p_status, detail = p_detail, checked_by = p_actor, checked_at = now(), basis_hash = p_basis
       WHERE id = v_row.id;
      RETURN true;
    END IF;
    RETURN false;
  END IF;
  IF (v_row.status, v_row.detail, v_row.basis_hash) IS DISTINCT FROM (p_status, p_detail, p_basis) THEN
    UPDATE us_booking.shipment_requirement
       SET status = p_status, detail = p_detail, checked_by = p_actor, checked_at = now(), basis_hash = p_basis
     WHERE id = v_row.id;
  END IF;
  RETURN false;
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
  v_ship       text;
  v_changed_orders bigint[] := '{}';
  v_count      integer;
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
  -- Findings seen in this run (filled by oms_sync_open_case), to tell recurring problems from
  -- unchanged ones. Dynamic SQL so no plan caches the temporary table.
  EXECUTE 'CREATE TEMP TABLE IF NOT EXISTS usb_sync_case_seen (oms_order_id bigint, case_type text) ON COMMIT DROP';
  EXECUTE 'TRUNCATE pg_temp.usb_sync_case_seen';

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

      v_ship := md5(array_to_string(ARRAY[
              COALESCE(btrim(o->'ship'->>'name'), ''), COALESCE(btrim(o->'ship'->>'company'), ''),
              COALESCE(btrim(o->'ship'->>'line1'), ''), COALESCE(btrim(o->'ship'->>'line2'), ''),
              COALESCE(btrim(o->'ship'->>'line3'), ''), COALESCE(btrim(o->'ship'->>'city'), ''),
              COALESCE(btrim(o->'ship'->>'region'), ''), COALESCE(btrim(o->'ship'->>'postcode'), ''),
              COALESCE(o->'ship'->>'country_id', '')], chr(31)));

      SELECT oms_status, warehouse_id, source_hash INTO v_old FROM us_booking.oms_order WHERE oms_order_id = v_oid FOR UPDATE;
      v_existed := FOUND;

      INSERT INTO us_booking.oms_order AS t (
        oms_order_id, platform_order_ref, oms_source_id, channel, sub_source_id, account_name, market_place_id,
        warehouse_id, booking_country_flags, oms_status, oms_merge_raw, merge_parent_order_id,
        ebay_cancel_status, oms_shipped_flag, oms_shipped_error, oms_shipping_method, order_date_raw,
        ship_name, ship_company, ship_line1, ship_line2, ship_line3, ship_city, ship_region, ship_postcode,
        ship_phone, ship_email, oms_country_id, ship_address_hash, source_hash, oms_shipments, ebay_cancel_requests)
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
        v_ship,
        v_hash, o->'shipments', COALESCE(o->'ebay_cancel_requests', '[]'::jsonb))
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
        oms_shipments = EXCLUDED.oms_shipments, ebay_cancel_requests = EXCLUDED.ebay_cancel_requests,
        last_synced_at = now(),
        oms_changed_at = CASE WHEN t.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN now() ELSE t.oms_changed_at END;

      IF NOT v_existed THEN
        v_n := us_booking.oms_sync_bump(v_n, 'orders_inserted');
        v_changed_orders := v_changed_orders || v_oid;
        v_group_changed := true;
        INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
        VALUES ('oms_order', v_oid, NULL, o->>'status', p_actor, jsonb_build_object('imported', true, 'sync_run_id', v_run_id));
      ELSIF v_old.source_hash IS DISTINCT FROM v_hash THEN
        v_n := us_booking.oms_sync_bump(v_n, 'orders_changed');
        v_changed_orders := v_changed_orders || v_oid;
        v_group_changed := true;
        INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
        VALUES ('oms_order', v_oid, v_old.oms_status, o->>'status', p_actor, jsonb_build_object('changed', true, 'sync_run_id', v_run_id));
      ELSE
        v_n := us_booking.oms_sync_bump(v_n, 'orders_unchanged');
      END IF;

      -- A destination confirmation is valid only for the ship-to it was made against. When the
      -- OMS address changes it is revoked (the row stays as history) and must be confirmed again.
      FOR r IN UPDATE us_booking.order_destination_confirmation
                  SET status = 'revoked', revoked_by = p_actor, revoked_at = now(),
                      revoke_reason = 'ship-to address changed in the OMS after this confirmation'
                WHERE oms_order_id = v_oid AND status = 'active' AND ship_address_hash IS DISTINCT FROM v_ship
            RETURNING id, destination_iso2 LOOP
        INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
        VALUES ('order_destination_confirmation', r.id, 'active', 'revoked', p_actor,
                jsonb_build_object('oms_order_id', v_oid, 'destination_iso2', r.destination_iso2,
                                   'reason', 'ship-to address changed', 'sync_run_id', v_run_id));
        v_n := us_booking.oms_sync_bump(v_n, 'confirmations_revoked');
      END LOOP;

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
      -- A combo (pack) line is one with combo_count > 1; its component rows should number
      -- combo_count. Lines with combo_count 1 normally carry several component rows in this OMS,
      -- so they are not checked (rule verified against 180 days of US1 lines, 2026-10-23).
      SELECT count(*) INTO v_gen FROM jsonb_array_elements(COALESCE(g->'combos', '[]'::jsonb)) c
       WHERE c->>'order_item_info_id' = it->>'id';
      IF COALESCE((it->>'combo_count')::int, 0) > 1 AND (it->>'combo_count')::int <> v_gen THEN
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
      -- Each requirement records the data it was evaluated against (basis); a staff check is
      -- invalidated when that data changes (see oms_sync_set_requirement).
      v_existed := r.oms_order_id = ANY (v_changed_orders);
      IF us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'destination_country',
        CASE WHEN r.destination_iso2 IS NOT NULL THEN 'met' ELSE 'unmet' END,
        CASE WHEN r.destination_iso2 IS NOT NULL THEN 'destination ' || r.destination_iso2 || ' via ' || r.destination_source
             WHEN r.destination_source = 'conflict' THEN 'verified country map and order confirmation disagree'
             WHEN r.oms_country_id IS NULL THEN 'OMS has no country_id for this ship-to; needs staff confirmation'
             ELSE 'OMS country_id ' || r.oms_country_id || ' has no verified mapping and no valid staff confirmation' END,
        p_actor, r.ship_address_hash, v_existed) THEN
        v_n := us_booking.oms_sync_bump(v_n, 'staff_checks_invalidated');
      END IF;
      v_txt := concat_ws(', ', CASE WHEN r.ship_name IS NULL THEN 'name' END, CASE WHEN r.ship_line1 IS NULL THEN 'line 1' END,
                               CASE WHEN r.ship_city IS NULL THEN 'city' END, CASE WHEN r.ship_postcode IS NULL THEN 'postcode' END);
      IF us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'ship_to_address',
        CASE WHEN v_txt = '' THEN 'met' ELSE 'unmet' END,
        CASE WHEN v_txt = '' THEN 'name, line 1, city and postcode present' ELSE 'missing: ' || v_txt END,
        p_actor, r.ship_address_hash, v_existed) THEN
        v_n := us_booking.oms_sync_bump(v_n, 'staff_checks_invalidated');
      END IF;
      IF us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'ship_to_state',
        CASE WHEN r.ship_region IS NOT NULL THEN 'met' ELSE 'unmet' END,
        CASE WHEN r.ship_region IS NOT NULL THEN 'state/region present' ELSE 'state/region is blank in the OMS' END,
        p_actor, r.ship_address_hash, v_existed) THEN
        v_n := us_booking.oms_sync_bump(v_n, 'staff_checks_invalidated');
      END IF;
      IF us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'ship_to_phone',
        CASE WHEN r.ship_phone IS NOT NULL THEN 'met' ELSE 'unmet' END,
        CASE WHEN r.ship_phone IS NOT NULL THEN 'phone present' ELSE 'phone is blank in the OMS; some carriers require it' END,
        p_actor, r.ship_address_hash, v_existed) THEN
        v_n := us_booking.oms_sync_bump(v_n, 'staff_checks_invalidated');
      END IF;
      -- Customs depends on the confirmed destination. While it is unknown the row stays blocking
      -- (unmet) but says that applicability awaits the destination; the review screen shows it as
      -- "awaiting destination", not as a missing declaration.
      IF us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'customs_declaration',
        CASE WHEN r.destination_iso2 = 'CA' THEN 'unmet' WHEN r.destination_iso2 IS NULL THEN 'unmet' ELSE 'not_applicable' END,
        CASE WHEN r.destination_iso2 = 'CA' THEN 'Canada destination: customs declaration needed (contents description, value, origin; HS code where the service requires it)'
             WHEN r.destination_iso2 = 'US' THEN 'domestic US shipment: no customs declaration'
             WHEN r.destination_iso2 IS NULL THEN 'awaiting destination confirmation: a customs declaration applies only if the destination is Canada'
             ELSE 'destination is outside US/Canada scope' END,
        p_actor, COALESCE(r.destination_iso2, '?') || ':' || r.ship_address_hash, v_existed) THEN
        v_n := us_booking.oms_sync_bump(v_n, 'staff_checks_invalidated');
      END IF;
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
           ELSE 'not verified for ' || v_mem.provider || ': ' || v_txt END,
      p_actor, v_mem.provider || ':' || COALESCE(v_txt, 'verified'), false);
    PERFORM us_booking.oms_sync_set_requirement(v_gid, NULL, 'provider_account',
      CASE WHEN v_mem.provider_account = 'unassigned' THEN 'unmet' ELSE 'met' END,
      CASE WHEN v_mem.provider_account = 'unassigned' THEN 'no ' || v_mem.provider || ' account assigned'
           ELSE 'account ' || v_mem.provider_account END,
      p_actor, v_mem.provider || '/' || v_mem.provider_account, false);
    -- Parcel work belongs to staff: created once as unmet, never recomputed by the sync.
    INSERT INTO us_booking.shipment_requirement (fulfilment_group_id, oms_order_id, requirement, status, detail, checked_by)
    VALUES (v_gid, NULL, 'parcel_measurements', 'unmet', 'no parcels measured yet', p_actor),
           (v_gid, NULL, 'parcel_contents', 'unmet', 'no parcel contents confirmed yet', p_actor)
    ON CONFLICT (fulfilment_group_id, oms_order_id, requirement) DO NOTHING;
  END LOOP;

  -- Closed findings whose condition was absent in this run are marked cleared, so the same
  -- problem appearing again later opens a new case (linked to the earlier one) instead of being
  -- suppressed by the earlier resolution. Unchanged findings are not touched.
  EXECUTE $q$
    WITH cleared AS (
      UPDATE us_booking.review_case rc
         SET details = rc.details || jsonb_build_object('condition_cleared_run', $2, 'condition_cleared_at', now())
       WHERE rc.oms_order_id = ANY ($1) AND rc.status <> 'open'
         AND rc.case_type IN ('warehouse_conflict', 'booking_flag_conflict', 'cancellation', 'already_shipped_suspect',
                              'sku_missing', 'combo_mismatch', 'scope', 'destination_conflict')
         AND NOT rc.details ? 'condition_cleared_run'
         AND NOT EXISTS (SELECT 1 FROM pg_temp.usb_sync_case_seen s
                          WHERE s.oms_order_id = rc.oms_order_id AND s.case_type = rc.case_type)
      RETURNING rc.id)
    SELECT count(*) FROM cleared$q$ INTO v_count USING v_seen, v_run_id;
  IF v_count > 0 THEN
    v_n := v_n || jsonb_build_object('closed_findings_cleared', v_count);
  END IF;

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

REVOKE EXECUTE ON FUNCTION us_booking.oms_sync_open_case(text, bigint, bigint, jsonb, text, text, bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.oms_sync_set_requirement(bigint, bigint, text, text, text, text, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.oms_sync_apply(jsonb, text) FROM PUBLIC;
