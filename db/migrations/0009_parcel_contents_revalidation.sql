-- 0009_parcel_contents_revalidation: parcel contents confirmations follow the OMS order lines.
--
-- Problem fixed: when the OMS changed an order line after staff confirmed parcel contents, the
-- group went back to review but the confirmation (and the parcel_contents requirement) stayed
-- "confirmed" until someone edited the parcel.
--
-- 1. A confirmation records its basis (parcel.contents_basis): the group's active orders and, per
--    packed line, the packed quantity, the ordered quantity, the SKU identity (item_sku, real_sku),
--    whether the OMS still returns the line, and whether its order is still in the group. It is
--    stamped by a trigger whenever contents become confirmed, whatever the path.
-- 2. The sync (oms_sync_apply, replaced below with marked insertions only) records lines the OMS
--    no longer returns (oms_order_item.oms_absent_since) and, in the same transaction, compares
--    every confirmed parcel of the synced groups with its basis:
--      - unlocked parcel, basis changed -> contents_status 'stale' (the earlier confirmation stays
--        as evidence) and an open parcel_contents_discrepancy listing what changed. Staff must
--        reconcile: change the items if needed and confirm again. Nothing is redistributed,
--        reduced or confirmed automatically; packed quantities stay as staff left them.
--      - parcel locked by a pending/unknown/successful purchase or a live label -> the parcel and
--        shipment records are not touched; an open discrepancy (parcel_locked) records the change
--        and blocks further purchasing for the group until staff acknowledge it with evidence.
--    An unchanged sync changes nothing.
-- 3. Readiness is enforced in the database: the parcel_contents requirement is recomputed per
--    line (every present line of the group's orders fully allocated, nothing allocated to lines the
--    OMS dropped or orders that left the group, no stale parcel, no open discrepancy), and the
--    booking precondition recomputes the basis itself. Closing a review case changes none of this.
-- 4. Confirming contents is refused while one of its lines is over-allocated (OMS quantity fell
--    below the packed units), missing from the OMS, or belongs to an order no longer in the group.
-- 5. Lock order for staff parcel edits and booking attempts is now group, then parcel, the same
--    order the sync uses, so they wait for each other instead of deadlocking.

ALTER TABLE us_booking.oms_order_item ADD COLUMN IF NOT EXISTS oms_absent_since timestamptz;
COMMENT ON COLUMN us_booking.oms_order_item.oms_absent_since IS
  'set by the sync when the OMS no longer returns this line (or its order); cleared when it returns. The row is kept.';

ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS contents_basis jsonb;
ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS contents_basis_hash text;
COMMENT ON COLUMN us_booking.parcel.contents_basis IS
  'order data the contents were last confirmed against (see parcel_contents_basis); kept as evidence when the contents go stale';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'us_booking.parcel'::regclass AND conname = 'parcel_contents_status_check'
              AND pg_get_constraintdef(oid) NOT LIKE '%stale%') THEN
    ALTER TABLE us_booking.parcel DROP CONSTRAINT parcel_contents_status_check;
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_contents_status_check
      CHECK (contents_status IN ('unconfirmed', 'confirmed', 'stale'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'us_booking.parcel'::regclass AND conname = 'parcel_stale_keeps_evidence') THEN
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_stale_keeps_evidence
      CHECK (contents_status <> 'stale' OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL AND contents_basis IS NOT NULL));
  END IF;
END $$;

-- One row per detected mismatch between a parcel's confirmed contents and the current order data.
CREATE TABLE IF NOT EXISTS us_booking.parcel_contents_discrepancy (
  id                  bigserial PRIMARY KEY,
  parcel_id           bigint NOT NULL REFERENCES us_booking.parcel(id),
  fulfilment_group_id bigint NOT NULL REFERENCES us_booking.fulfilment_group(id),
  status              text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'reconciled', 'acknowledged')),
  parcel_locked       boolean NOT NULL,          -- purchase/label lock at detection: the parcel was left untouched
  confirmed_basis     jsonb NOT NULL,            -- what staff confirmed
  confirmed_by        text,
  confirmed_at        timestamptz,
  current_basis       jsonb NOT NULL,            -- the order data now (refreshed while open)
  current_hash        text NOT NULL,
  changes             jsonb NOT NULL,            -- readable list of what changed
  detected_by         text NOT NULL,
  detected_at         timestamptz NOT NULL DEFAULT now(),
  sync_run_id         bigint,
  last_checked_at     timestamptz NOT NULL DEFAULT now(),
  resolved_by         text,
  resolved_at         timestamptz,
  resolution          text,
  resolution_basis    jsonb,
  CHECK (status = 'open' OR (resolved_by IS NOT NULL AND resolved_at IS NOT NULL AND resolution IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS parcel_contents_discrepancy_one_open
  ON us_booking.parcel_contents_discrepancy (parcel_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS parcel_contents_discrepancy_group_open
  ON us_booking.parcel_contents_discrepancy (fulfilment_group_id) WHERE status = 'open';

-- The order data a parcel's contents depend on. Deterministic (sorted arrays; jsonb key order).
CREATE OR REPLACE FUNCTION us_booking.parcel_contents_basis(p_parcel_id bigint)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT jsonb_build_object(
    'members', COALESCE((SELECT jsonb_agg(fo.oms_order_id ORDER BY fo.oms_order_id)
                           FROM us_booking.fulfilment_group_order fo
                          WHERE fo.fulfilment_group_id = p.fulfilment_group_id AND fo.active), '[]'::jsonb),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                         'line', pi.oms_order_item_id, 'order', pi.oms_order_id, 'packed', pi.quantity,
                         'ordered', i.quantity_ordered, 'sku', i.item_sku, 'real_sku', i.real_sku,
                         'in_oms', i.oms_absent_since IS NULL, 'member', COALESCE(fo.active, false))
                         ORDER BY pi.oms_order_item_id)
                         FROM us_booking.parcel_item pi
                         JOIN us_booking.oms_order_item i ON i.oms_order_item_id = pi.oms_order_item_id
                         LEFT JOIN us_booking.fulfilment_group_order fo
                                ON fo.fulfilment_group_id = pi.fulfilment_group_id AND fo.oms_order_id = pi.oms_order_id
                        WHERE pi.parcel_id = p.id), '[]'::jsonb))
    FROM us_booking.parcel p WHERE p.id = p_parcel_id
$$;

-- Allocations of a group that the current order lines do not support, as text (NULL when none):
-- more units in parcels than ordered, units of a line the OMS no longer returns, units of an order
-- that is no longer in the group.
CREATE OR REPLACE FUNCTION us_booking.group_allocation_problems(p_group_id bigint)
RETURNS text LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT string_agg(msg, '; ' ORDER BY msg) FROM (
    SELECT format('%s (line %s): %s in parcels but %s ordered', i.item_sku, i.oms_order_item_id, sum(pi.quantity), i.quantity_ordered) AS msg
      FROM us_booking.parcel_item pi
      JOIN us_booking.parcel p ON p.id = pi.parcel_id AND p.state <> 'cancelled'
      JOIN us_booking.oms_order_item i ON i.oms_order_item_id = pi.oms_order_item_id
     WHERE p.fulfilment_group_id = p_group_id AND i.oms_absent_since IS NULL
     GROUP BY i.oms_order_item_id, i.item_sku, i.quantity_ordered
    HAVING sum(pi.quantity) > i.quantity_ordered
    UNION ALL
    SELECT format('%s (line %s): %s in parcels but the OMS no longer has this line', i.item_sku, i.oms_order_item_id, sum(pi.quantity))
      FROM us_booking.parcel_item pi
      JOIN us_booking.parcel p ON p.id = pi.parcel_id AND p.state <> 'cancelled'
      JOIN us_booking.oms_order_item i ON i.oms_order_item_id = pi.oms_order_item_id
     WHERE p.fulfilment_group_id = p_group_id AND i.oms_absent_since IS NOT NULL
     GROUP BY i.oms_order_item_id, i.item_sku
    UNION ALL
    SELECT format('order %s is packed but no longer in this group', pi.oms_order_id)
      FROM us_booking.parcel_item pi
      JOIN us_booking.parcel p ON p.id = pi.parcel_id AND p.state <> 'cancelled'
      LEFT JOIN us_booking.fulfilment_group_order fo ON fo.fulfilment_group_id = p.fulfilment_group_id AND fo.oms_order_id = pi.oms_order_id
     WHERE p.fulfilment_group_id = p_group_id AND NOT COALESCE(fo.active, false)
     GROUP BY pi.oms_order_id) x
$$;

-- What changed between a confirmed basis and the current one, as a list staff can read.
CREATE OR REPLACE FUNCTION us_booking.parcel_contents_changes(p_confirmed jsonb, p_current jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE
  v     jsonb := '[]'::jsonb;
  c     jsonb;
  n     jsonb;
  v_id  bigint;
  v_alloc integer;
BEGIN
  FOR v_id IN SELECT value::bigint FROM jsonb_array_elements_text(COALESCE(p_current->'members', '[]'))
              EXCEPT SELECT value::bigint FROM jsonb_array_elements_text(COALESCE(p_confirmed->'members', '[]')) LOOP
    v := v || jsonb_build_object('kind', 'order_added_to_group', 'order', v_id);
  END LOOP;
  FOR v_id IN SELECT value::bigint FROM jsonb_array_elements_text(COALESCE(p_confirmed->'members', '[]'))
              EXCEPT SELECT value::bigint FROM jsonb_array_elements_text(COALESCE(p_current->'members', '[]')) LOOP
    v := v || jsonb_build_object('kind', 'order_removed_from_group', 'order', v_id);
  END LOOP;
  FOR c IN SELECT x FROM jsonb_array_elements(COALESCE(p_confirmed->'items', '[]')) x LOOP
    n := NULL;
    SELECT x INTO n FROM jsonb_array_elements(COALESCE(p_current->'items', '[]')) x WHERE x->>'line' = c->>'line';
    IF n IS NULL THEN
      v := v || jsonb_build_object('kind', 'item_taken_out_of_parcel', 'line', (c->>'line')::bigint, 'sku', c->>'sku', 'from', (c->>'packed')::int);
      CONTINUE;
    END IF;
    SELECT allocated_qty INTO v_alloc FROM us_booking.item_allocation WHERE oms_order_item_id = (c->>'line')::bigint;
    IF (n->>'ordered') IS DISTINCT FROM (c->>'ordered') THEN
      v := v || jsonb_build_object('kind', 'ordered_quantity_changed', 'line', (c->>'line')::bigint, 'order', (c->>'order')::bigint,
                                   'sku', c->>'sku', 'from', (c->>'ordered')::int, 'to', (n->>'ordered')::int,
                                   'packed_here', (n->>'packed')::int, 'packed_all_parcels', COALESCE(v_alloc, 0),
                                   'below_packed', COALESCE(v_alloc, 0) > (n->>'ordered')::int);
    END IF;
    IF (n->>'sku', n->>'real_sku') IS DISTINCT FROM (c->>'sku', c->>'real_sku') THEN
      v := v || jsonb_build_object('kind', 'sku_changed', 'line', (c->>'line')::bigint, 'from', concat_ws(' / ', c->>'sku', c->>'real_sku'),
                                   'to', concat_ws(' / ', n->>'sku', n->>'real_sku'));
    END IF;
    IF (c->>'in_oms')::boolean AND NOT (n->>'in_oms')::boolean THEN
      v := v || jsonb_build_object('kind', 'line_no_longer_in_oms', 'line', (c->>'line')::bigint, 'sku', c->>'sku', 'packed_here', (n->>'packed')::int);
    ELSIF NOT (c->>'in_oms')::boolean AND (n->>'in_oms')::boolean THEN
      v := v || jsonb_build_object('kind', 'line_back_in_oms', 'line', (c->>'line')::bigint, 'sku', c->>'sku');
    END IF;
    IF (c->>'member')::boolean AND NOT (n->>'member')::boolean THEN
      v := v || jsonb_build_object('kind', 'order_left_group', 'line', (c->>'line')::bigint, 'order', (c->>'order')::bigint, 'sku', c->>'sku');
    END IF;
    IF (n->>'packed') IS DISTINCT FROM (c->>'packed') THEN
      v := v || jsonb_build_object('kind', 'packed_quantity_edited', 'line', (c->>'line')::bigint, 'sku', c->>'sku',
                                   'from', (c->>'packed')::int, 'to', (n->>'packed')::int);
    END IF;
  END LOOP;
  FOR n IN SELECT x FROM jsonb_array_elements(COALESCE(p_current->'items', '[]')) x
            WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_confirmed->'items', '[]')) y WHERE y->>'line' = x->>'line') LOOP
    v := v || jsonb_build_object('kind', 'item_added_to_parcel', 'line', (n->>'line')::bigint, 'sku', n->>'sku', 'to', (n->>'packed')::int);
  END LOOP;
  RETURN v;
END;
$$;

-- Readiness of a group's parcel requirements, recomputed from parcels and current order lines.
-- Replaces 0008's version: contents are complete only when every present line of the group's
-- orders is fully allocated, no allocation is unsupported (group_allocation_problems), every
-- non-cancelled parcel's contents are confirmed (not stale) and no discrepancy is open.
CREATE OR REPLACE FUNCTION us_booking.parcel_requirements_refresh(p_group_id bigint, p_actor text)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_n         integer;
  v_measured  integer;
  v_profile   integer;
  v_confirmed integer;
  v_stale     integer;
  v_disc      integer;
  v_ordered   integer;
  v_remaining integer;
  v_problems  text;
  v_m_status  text;
  v_m_detail  text;
  v_c_status  text;
  v_c_detail  text;
BEGIN
  SELECT count(*) FILTER (WHERE state <> 'cancelled'),
         count(*) FILTER (WHERE state <> 'cancelled' AND dimensions_source IS NOT NULL AND weight_source IS NOT NULL),
         count(*) FILTER (WHERE state <> 'cancelled' AND (dimensions_source = 'profile' OR weight_source = 'profile')),
         count(*) FILTER (WHERE state <> 'cancelled' AND contents_status = 'confirmed'),
         count(*) FILTER (WHERE state <> 'cancelled' AND contents_status = 'stale')
    INTO v_n, v_measured, v_profile, v_confirmed, v_stale
    FROM us_booking.parcel WHERE fulfilment_group_id = p_group_id;
  SELECT count(*) INTO v_disc FROM us_booking.parcel_contents_discrepancy WHERE fulfilment_group_id = p_group_id AND status = 'open';
  SELECT COALESCE(sum(i.quantity_ordered), 0), COALESCE(sum(GREATEST(i.quantity_ordered - COALESCE(a.allocated_qty, 0), 0)), 0)
    INTO v_ordered, v_remaining
    FROM us_booking.fulfilment_group_order fo
    JOIN us_booking.oms_order_item i ON i.oms_order_id = fo.oms_order_id AND i.oms_absent_since IS NULL
    LEFT JOIN us_booking.item_allocation a ON a.oms_order_item_id = i.oms_order_item_id
   WHERE fo.fulfilment_group_id = p_group_id AND fo.active;
  v_problems := us_booking.group_allocation_problems(p_group_id);

  v_m_status := CASE WHEN v_n > 0 AND v_measured = v_n THEN 'met' ELSE 'unmet' END;
  v_m_detail := CASE WHEN v_n = 0 THEN 'no parcels yet'
                     ELSE format('%s of %s parcel(s) have dimensions and weight; %s use default-profile values',
                                 v_measured, v_n, v_profile) END;
  v_c_status := CASE WHEN v_n > 0 AND v_confirmed = v_n AND v_disc = 0 AND v_remaining = 0 AND v_problems IS NULL
                     THEN 'met' ELSE 'unmet' END;
  v_c_detail := CASE WHEN v_n = 0 THEN 'no parcel contents confirmed yet'
                     ELSE concat_ws('; ',
                       format('%s of %s ordered unit(s) in parcels; contents confirmed for %s of %s parcel(s)',
                              v_ordered - v_remaining, v_ordered, v_confirmed, v_n),
                       CASE WHEN v_stale > 0 THEN format('%s parcel(s) need reconciliation after OMS changes', v_stale) END,
                       CASE WHEN v_disc > 0 THEN format('%s open contents discrepanc%s', v_disc, CASE WHEN v_disc = 1 THEN 'y' ELSE 'ies' END) END,
                       CASE WHEN v_problems IS NOT NULL THEN 'allocation no longer matches the order: ' || v_problems END) END;

  INSERT INTO us_booking.shipment_requirement AS r (fulfilment_group_id, oms_order_id, requirement, status, detail, checked_by)
  VALUES (p_group_id, NULL, 'parcel_measurements', v_m_status, v_m_detail, p_actor),
         (p_group_id, NULL, 'parcel_contents', v_c_status, v_c_detail, p_actor)
  ON CONFLICT (fulfilment_group_id, oms_order_id, requirement) DO UPDATE
     SET status = EXCLUDED.status, detail = EXCLUDED.detail, checked_by = EXCLUDED.checked_by, checked_at = now(), basis_hash = NULL
   WHERE (r.status, r.detail) IS DISTINCT FROM (EXCLUDED.status, EXCLUDED.detail);
END;
$$;

-- Compares the group's confirmed (or already stale) parcels with their basis. Called by the sync
-- for every synced group, in the sync transaction. Returns how many parcels newly became stale or
-- got a discrepancy.
CREATE OR REPLACE FUNCTION us_booking.parcel_contents_revalidate(p_group_id bigint, p_actor text, p_run_id bigint)
RETURNS integer LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  p        us_booking.parcel%ROWTYPE;
  v_cur    jsonb;
  v_hash   text;
  v_locked boolean;
  v_open   us_booking.parcel_contents_discrepancy%ROWTYPE;
  v_changes jsonb;
  v_new    boolean;
  v_count  integer := 0;
  v_id     bigint;
BEGIN
  FOR p IN SELECT * FROM us_booking.parcel
            WHERE fulfilment_group_id = p_group_id AND state <> 'cancelled'
              AND contents_status IN ('confirmed', 'stale') AND contents_basis IS NOT NULL
            ORDER BY id FOR UPDATE LOOP
    v_cur := us_booking.parcel_contents_basis(p.id);
    v_hash := md5(v_cur::text);
    v_open := NULL;
    SELECT * INTO v_open FROM us_booking.parcel_contents_discrepancy WHERE parcel_id = p.id AND status = 'open' FOR UPDATE;
    v_changes := us_booking.parcel_contents_changes(p.contents_basis, v_cur);
    IF v_hash = p.contents_basis_hash THEN
      -- The data matches the confirmation again. A stale parcel stays stale (staff confirm it); an
      -- open discrepancy is kept and shows that nothing differs now.
      IF v_open.id IS NOT NULL AND v_open.current_hash IS DISTINCT FROM v_hash THEN
        UPDATE us_booking.parcel_contents_discrepancy
           SET current_basis = v_cur, current_hash = v_hash, changes = v_changes, last_checked_at = now()
         WHERE id = v_open.id;
      END IF;
      CONTINUE;
    END IF;
    v_locked := us_booking.parcel_is_locked(p.id);
    v_new := false;
    IF v_open.id IS NOT NULL THEN
      IF v_open.current_hash IS DISTINCT FROM v_hash THEN
        UPDATE us_booking.parcel_contents_discrepancy
           SET current_basis = v_cur, current_hash = v_hash, changes = v_changes, last_checked_at = now(), sync_run_id = p_run_id
         WHERE id = v_open.id;
        INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
        VALUES ('parcel_contents_discrepancy', v_open.id, 'open', 'open', p_actor,
                jsonb_build_object('action', 'changed_again', 'parcel_id', p.id, 'changes', v_changes, 'sync_run_id', p_run_id));
      END IF;
    ELSIF v_locked AND EXISTS (SELECT 1 FROM us_booking.parcel_contents_discrepancy
                                WHERE parcel_id = p.id AND status = 'acknowledged' AND current_hash = v_hash) THEN
      NULL;  -- staff already acknowledged exactly this data for the locked parcel
    ELSE
      INSERT INTO us_booking.parcel_contents_discrepancy
        (parcel_id, fulfilment_group_id, parcel_locked, confirmed_basis, confirmed_by, confirmed_at,
         current_basis, current_hash, changes, detected_by, sync_run_id)
      VALUES (p.id, p.fulfilment_group_id, v_locked, p.contents_basis, p.confirmed_by, p.confirmed_at,
              v_cur, v_hash, v_changes, p_actor, p_run_id)
      RETURNING id INTO v_id;
      INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
      VALUES ('parcel_contents_discrepancy', v_id, NULL, 'open', p_actor,
              jsonb_build_object('parcel_id', p.id, 'parcel_no', p.parcel_no, 'parcel_locked', v_locked,
                                 'changes', v_changes, 'sync_run_id', p_run_id));
      v_new := true;
    END IF;
    -- An unlocked confirmed parcel becomes stale. The guard trigger increments row_version, so a
    -- screen still holding the earlier version is refused. Locked parcels are never written.
    IF NOT v_locked AND p.contents_status = 'confirmed' THEN
      UPDATE us_booking.parcel SET contents_status = 'stale' WHERE id = p.id;
      INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
      VALUES ('parcel', p.id, p.state, p.state, p_actor,
              jsonb_build_object('action', 'contents_stale', 'changes', v_changes, 'confirmed_by', p.confirmed_by,
                                 'confirmed_at', p.confirmed_at, 'sync_run_id', p_run_id));
      v_new := true;
    END IF;
    IF v_new THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;
  PERFORM us_booking.parcel_requirements_refresh(p_group_id, p_actor);
  RETURN v_count;
END;
$$;

-- Stamps the basis whenever contents become confirmed (any path), refuses confirmations the
-- current order data does not support, and closes the parcel's open discrepancy as reconciled.
CREATE OR REPLACE FUNCTION us_booking.tg_parcel_contents_basis()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_problem text;
BEGIN
  IF NEW.contents_status = 'confirmed' AND OLD.contents_status IS DISTINCT FROM 'confirmed' THEN
    SELECT string_agg(msg, '; ') INTO v_problem FROM (
      SELECT format('%s (line %s) is no longer in the OMS', i.item_sku, i.oms_order_item_id) AS msg
        FROM us_booking.parcel_item pi JOIN us_booking.oms_order_item i ON i.oms_order_item_id = pi.oms_order_item_id
       WHERE pi.parcel_id = NEW.id AND i.oms_absent_since IS NOT NULL
      UNION ALL
      SELECT format('order %s is no longer in this group', pi.oms_order_id)
        FROM us_booking.parcel_item pi
        LEFT JOIN us_booking.fulfilment_group_order fo ON fo.fulfilment_group_id = pi.fulfilment_group_id AND fo.oms_order_id = pi.oms_order_id
       WHERE pi.parcel_id = NEW.id AND NOT COALESCE(fo.active, false)
      UNION ALL
      SELECT format('%s (line %s) has %s unit(s) in parcels but only %s ordered', i.item_sku, i.oms_order_item_id, a.allocated_qty, i.quantity_ordered)
        FROM us_booking.parcel_item pi JOIN us_booking.oms_order_item i ON i.oms_order_item_id = pi.oms_order_item_id
        JOIN us_booking.item_allocation a ON a.oms_order_item_id = i.oms_order_item_id
       WHERE pi.parcel_id = NEW.id AND a.allocated_qty > i.quantity_ordered) x;
    IF v_problem IS NOT NULL THEN
      RAISE EXCEPTION 'parcel % contents cannot be confirmed: %', NEW.parcel_no, v_problem USING ERRCODE = 'check_violation';
    END IF;
    NEW.contents_basis := us_booking.parcel_contents_basis(NEW.id);
    NEW.contents_basis_hash := md5(NEW.contents_basis::text);
    UPDATE us_booking.parcel_contents_discrepancy
       SET status = 'reconciled', resolved_by = NEW.confirmed_by, resolved_at = now(),
           resolution = 'contents confirmed again against the current order data', resolution_basis = NEW.contents_basis
     WHERE parcel_id = NEW.id AND status = 'open';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER parcel_contents_basis
  BEFORE UPDATE ON us_booking.parcel
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_parcel_contents_basis();

-- Replaces 0008's: the group is locked before the parcel (the order the sync and booking use).
CREATE OR REPLACE FUNCTION us_booking.staff_parcel_for_edit(p jsonb)
RETURNS us_booking.parcel LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_parcel us_booking.parcel%ROWTYPE;
  v_gid    bigint;
  v_state  text;
BEGIN
  SELECT fulfilment_group_id INTO v_gid FROM us_booking.parcel WHERE id = us_booking.staff_id(p, 'parcel_id');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'parcel not found' USING ERRCODE = 'UB404';
  END IF;
  SELECT state INTO v_state FROM us_booking.fulfilment_group WHERE id = v_gid FOR UPDATE;
  SELECT * INTO v_parcel FROM us_booking.parcel WHERE id = us_booking.staff_id(p, 'parcel_id') FOR UPDATE;
  IF v_parcel.row_version IS DISTINCT FROM nullif(p->>'expected_row_version', '')::integer THEN
    RAISE EXCEPTION 'parcel % was changed by someone else or by an OMS sync since it was loaded; reload and try again', v_parcel.parcel_no
      USING ERRCODE = 'UB409';
  END IF;
  IF v_parcel.state <> 'open' THEN
    RAISE EXCEPTION 'parcel % is %; only open parcels can be changed', v_parcel.parcel_no, v_parcel.state USING ERRCODE = 'UB409';
  END IF;
  IF v_state <> 'review' THEN
    RAISE EXCEPTION 'the group is %; parcels can be prepared only while it is in review', v_state USING ERRCODE = 'UB409';
  END IF;
  IF us_booking.parcel_is_locked(v_parcel.id) THEN
    RAISE EXCEPTION 'parcel % has a pending, unknown or active purchase; it is locked', v_parcel.parcel_no USING ERRCODE = 'UB409';
  END IF;
  RETURN v_parcel;
END;
$$;

-- Replaces 0007's booking precondition; adds the contents-basis, discrepancy and allocation checks (marked 0009).
CREATE OR REPLACE FUNCTION us_booking.tg_booking_attempt_insert()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_parcel  record;
  v_group   record;
  v_bad     text;
  v_max_gen integer;
  v_prev    record;
BEGIN
  IF NEW.state <> 'created' OR NEW.released_at IS NOT NULL THEN
    RAISE EXCEPTION 'a booking attempt must start in state created' USING ERRCODE = 'check_violation';
  END IF;
  -- Serialise against parcel/contents edits, syncs and other attempts on the same parcel and group.
  -- 0009: group first, then parcel (the order the sync and staff actions use).
  SELECT * INTO v_group FROM us_booking.fulfilment_group WHERE id = NEW.fulfilment_group_id FOR UPDATE;
  SELECT * INTO v_parcel FROM us_booking.parcel WHERE id = NEW.parcel_id FOR UPDATE;

  IF us_booking.parcel_is_locked(NEW.parcel_id) THEN
    RAISE EXCEPTION 'parcel % already has a pending, unknown or active purchase', NEW.parcel_id USING ERRCODE = 'unique_violation';
  END IF;
  IF v_parcel.state <> 'open' THEN
    RAISE EXCEPTION 'parcel % is %, not open', NEW.parcel_id, v_parcel.state USING ERRCODE = 'check_violation';
  END IF;
  IF v_parcel.length IS NULL OR v_parcel.width IS NULL OR v_parcel.height IS NULL OR v_parcel.dimension_unit IS NULL
     OR v_parcel.dimensions_source IS NULL OR v_parcel.weight IS NULL OR v_parcel.weight_unit IS NULL OR v_parcel.weight_source IS NULL THEN
    RAISE EXCEPTION 'parcel % measurements are incomplete: dimensions and weight each need a value, a unit and a source (approved default profile or staff-entered)', NEW.parcel_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_parcel.contents_status <> 'confirmed' THEN
    RAISE EXCEPTION 'parcel % contents are not staff-confirmed', NEW.parcel_id USING ERRCODE = 'check_violation';
  END IF;
  -- 0009: the confirmation must still describe the current OMS data (recomputed here, not read
  -- from a requirement row or a review case), and no parcel of the group may have an unresolved
  -- contents discrepancy or an allocation the current order lines no longer support.
  IF v_parcel.contents_basis_hash IS DISTINCT FROM md5(us_booking.parcel_contents_basis(NEW.parcel_id)::text) THEN
    RAISE EXCEPTION 'parcel % contents were confirmed against order data that has since changed; staff must reconcile and confirm them again', NEW.parcel_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM us_booking.parcel_contents_discrepancy
              WHERE fulfilment_group_id = NEW.fulfilment_group_id AND status = 'open') THEN
    RAISE EXCEPTION 'group % has parcel contents discrepancies awaiting staff reconciliation', NEW.fulfilment_group_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF us_booking.group_allocation_problems(NEW.fulfilment_group_id) IS NOT NULL THEN
    RAISE EXCEPTION 'group % parcel allocations no longer match its order lines: %', NEW.fulfilment_group_id,
      us_booking.group_allocation_problems(NEW.fulfilment_group_id) USING ERRCODE = 'check_violation';
  END IF;
  IF v_group.state NOT IN ('ready','booking') THEN
    RAISE EXCEPTION 'fulfilment group % is %, not ready', v_group.id, v_group.state USING ERRCODE = 'check_violation';
  END IF;

  SELECT string_agg(fo.oms_order_id::text || ':' || coalesce(s.scope_status,'?') || '/' || coalesce(r.provider,'no-rule')
                    || '/' || coalesce(r.integration_status,'-'), ', ')
    INTO v_bad
    FROM us_booking.fulfilment_group_order fo
    JOIN us_booking.oms_order o ON o.oms_order_id = fo.oms_order_id
    LEFT JOIN us_booking.v_order_scope s ON s.oms_order_id = fo.oms_order_id
    LEFT JOIN us_booking.routing_rule r ON r.oms_source_id = o.oms_source_id
   WHERE fo.fulfilment_group_id = v_group.id AND fo.active
     AND (s.scope_status IS DISTINCT FROM 'in_scope'
          OR r.provider IS DISTINCT FROM v_group.provider
          OR r.integration_status IS DISTINCT FROM 'verified');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'group % has orders that are not in scope or not routed to a verified % integration: %', v_group.id, v_group.provider, v_bad
      USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (SELECT 1 FROM us_booking.shipment_requirement WHERE fulfilment_group_id = v_group.id AND status = 'unmet') THEN
    RAISE EXCEPTION 'group % has unmet shipment requirements', v_group.id USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM us_booking.review_case rc
              WHERE rc.status = 'open'
                AND (rc.fulfilment_group_id = v_group.id
                     OR rc.oms_order_id IN (SELECT oms_order_id FROM us_booking.fulfilment_group_order
                                             WHERE fulfilment_group_id = v_group.id AND active))) THEN
    RAISE EXCEPTION 'group % has open review cases', v_group.id USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM us_booking.parcel_item WHERE parcel_id = NEW.parcel_id) THEN
    RAISE EXCEPTION 'parcel % has no items', NEW.parcel_id USING ERRCODE = 'check_violation';
  END IF;

  -- Generations are consecutive. A replacement must name the latest successful attempt, which must
  -- have been released after a provider-confirmed void.
  SELECT max(attempt_generation) INTO v_max_gen FROM us_booking.booking_attempt WHERE parcel_id = NEW.parcel_id;
  IF NEW.attempt_generation <> coalesce(v_max_gen, 0) + 1 THEN
    RAISE EXCEPTION 'attempt_generation must be % for parcel %', coalesce(v_max_gen, 0) + 1, NEW.parcel_id USING ERRCODE = 'check_violation';
  END IF;
  SELECT id, released_at INTO v_prev FROM us_booking.booking_attempt
   WHERE parcel_id = NEW.parcel_id AND state IN ('succeeded','reconciled_found')
   ORDER BY attempt_generation DESC LIMIT 1;
  IF v_prev.id IS NULL THEN
    IF NEW.replaces_attempt_id IS NOT NULL THEN
      RAISE EXCEPTION 'parcel % has no earlier label to replace', NEW.parcel_id USING ERRCODE = 'check_violation';
    END IF;
  ELSE
    IF NEW.replaces_attempt_id IS DISTINCT FROM v_prev.id THEN
      RAISE EXCEPTION 'parcel % already had a label; a replacement must name attempt % and be authorised', NEW.parcel_id, v_prev.id
        USING ERRCODE = 'check_violation';
    END IF;
    IF v_prev.released_at IS NULL THEN
      RAISE EXCEPTION 'attempt % has not been released after a confirmed void', v_prev.id USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Replaces 0008's staff_parcel_remove; parcels with discrepancy history are cancelled, not deleted (marked 0009).
CREATE OR REPLACE FUNCTION us_booking.staff_parcel_remove(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff  text := us_booking.staff_actor(p);
  v_parcel us_booking.parcel%ROWTYPE := us_booking.staff_parcel_for_edit(p);
  v_items  jsonb;
  v_action text;
BEGIN
  SELECT coalesce(jsonb_object_agg(oms_order_item_id::text, quantity), '{}'::jsonb) INTO v_items
    FROM us_booking.parcel_item WHERE parcel_id = v_parcel.id;
  -- 0009: a parcel with contents-discrepancy history is cancelled, not deleted, so the history stays.
  IF EXISTS (SELECT 1 FROM us_booking.booking_attempt WHERE parcel_id = v_parcel.id)
     OR EXISTS (SELECT 1 FROM us_booking.parcel_contents_discrepancy WHERE parcel_id = v_parcel.id) THEN
    UPDATE us_booking.parcel SET state = 'cancelled' WHERE id = v_parcel.id;
    UPDATE us_booking.parcel_contents_discrepancy
       SET status = 'reconciled', resolved_by = v_staff, resolved_at = now(), resolution = 'parcel cancelled by staff'
     WHERE parcel_id = v_parcel.id AND status = 'open';
    v_action := 'cancelled';
  ELSE
    IF v_parcel.contents_status = 'confirmed' THEN
      UPDATE us_booking.parcel SET contents_status = 'unconfirmed', confirmed_by = NULL, confirmed_at = NULL WHERE id = v_parcel.id;
    END IF;
    DELETE FROM us_booking.parcel_item WHERE parcel_id = v_parcel.id;
    DELETE FROM us_booking.parcel WHERE id = v_parcel.id;
    v_action := 'deleted';
  END IF;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('parcel', v_parcel.id, v_parcel.state, v_action, v_staff,
          jsonb_build_object('action', v_action, 'fulfilment_group_id', v_parcel.fulfilment_group_id,
                             'parcel_no', v_parcel.parcel_no, 'values', us_booking.parcel_snapshot(v_parcel), 'items', v_items));
  PERFORM us_booking.parcel_requirements_refresh(v_parcel.fulfilment_group_id, v_staff);
  RETURN jsonb_build_object('parcel_id', v_parcel.id, 'result', v_action);
END;
$$;

-- Replaces 0005's oms_sync_apply. Unchanged except at the points marked 0009.
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
  v_stale      integer := 0;  -- 0009: parcel confirmations found stale in this run
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
        source_hash = EXCLUDED.source_hash, last_synced_at = now(),
        oms_absent_since = NULL;  -- 0009: the OMS returned this line again
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
      -- 0009: recorded on the line itself, so parcel checks see it whatever happens to the case.
      UPDATE us_booking.oms_order_item SET oms_absent_since = COALESCE(oms_absent_since, now())
       WHERE oms_order_item_id = ANY (r.ids);
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
    -- 0009: the order's lines are no longer confirmed by the OMS; revalidate its group's parcels.
    UPDATE us_booking.oms_order_item SET oms_absent_since = COALESCE(oms_absent_since, now())
     WHERE oms_order_id = r.oms_order_id AND oms_absent_since IS NULL;
    IF v_gid IS NOT NULL THEN
      v_groups := v_groups || v_gid;
    END IF;
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

  -- 0009: parcel contents confirmed against data this run changed (quantity, SKU identity, a line
  -- missing from the OMS, group membership) become stale or, for parcels locked by a purchase or
  -- label, an open discrepancy that blocks further purchasing. Group contents readiness is
  -- recomputed from the current lines. Nothing is redistributed, reduced or confirmed here.
  FOR v_gid IN SELECT DISTINCT x FROM unnest(v_groups) x LOOP
    v_stale := v_stale + us_booking.parcel_contents_revalidate(v_gid, p_actor, v_run_id);
  END LOOP;
  IF v_stale > 0 THEN
    v_n := v_n || jsonb_build_object('parcel_confirmations_stale', v_stale);
  END IF;

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
    'booking_attempts_total', (SELECT count(*) FROM us_booking.booking_attempt),
    'open_contents_discrepancies', (SELECT count(*) FROM us_booking.parcel_contents_discrepancy WHERE status = 'open'));

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

-- Staff acknowledgement of a discrepancy on a LOCKED parcel (pending/unknown/successful purchase
-- or live label). The parcel and shipment records stay as they are; the acknowledgement records
-- who accepted the difference and why, and lifts the purchase block it caused. An unlocked parcel
-- cannot be acknowledged: its contents must be changed and/or confirmed again. Payload: staff,
-- discrepancy_id, evidence, expected_current_hash (the data the screen showed).
CREATE OR REPLACE FUNCTION us_booking.staff_discrepancy_acknowledge(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff    text := us_booking.staff_actor(p);
  v_evidence text := us_booking.staff_text(p, 'evidence', 'Evidence', 3, 1000);
  v_d        us_booking.parcel_contents_discrepancy%ROWTYPE;
BEGIN
  SELECT * INTO v_d FROM us_booking.parcel_contents_discrepancy WHERE id = us_booking.staff_id(p, 'discrepancy_id');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'discrepancy not found' USING ERRCODE = 'UB404';
  END IF;
  PERFORM 1 FROM us_booking.fulfilment_group WHERE id = v_d.fulfilment_group_id FOR UPDATE;
  SELECT * INTO v_d FROM us_booking.parcel_contents_discrepancy WHERE id = v_d.id FOR UPDATE;
  IF v_d.status <> 'open' THEN
    RAISE EXCEPTION 'this discrepancy is already %', v_d.status USING ERRCODE = 'UB409';
  END IF;
  IF v_d.current_hash IS DISTINCT FROM p->>'expected_current_hash' THEN
    RAISE EXCEPTION 'the order data changed again since this was loaded; reload and review it again' USING ERRCODE = 'UB409';
  END IF;
  IF NOT us_booking.parcel_is_locked(v_d.parcel_id) THEN
    RAISE EXCEPTION 'this parcel is not locked by a purchase or label: change or confirm its contents again instead' USING ERRCODE = 'UB409';
  END IF;
  UPDATE us_booking.parcel_contents_discrepancy
     SET status = 'acknowledged', resolved_by = v_staff, resolved_at = now(), resolution = v_evidence, resolution_basis = current_basis
   WHERE id = v_d.id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('parcel_contents_discrepancy', v_d.id, 'open', 'acknowledged', v_staff,
          jsonb_build_object('parcel_id', v_d.parcel_id, 'evidence', v_evidence, 'changes', v_d.changes));
  PERFORM us_booking.parcel_requirements_refresh(v_d.fulfilment_group_id, v_staff);
  RETURN jsonb_build_object('discrepancy_id', v_d.id, 'status', 'acknowledged');
END;
$$;

-- Parcels confirmed before this migration get the basis of the current data (none exist in the
-- live schema when this was written; kept for completeness).
UPDATE us_booking.parcel p
   SET contents_basis = us_booking.parcel_contents_basis(p.id),
       contents_basis_hash = md5(us_booking.parcel_contents_basis(p.id)::text)
 WHERE p.contents_status = 'confirmed' AND p.contents_basis IS NULL AND NOT us_booking.parcel_is_locked(p.id);

REVOKE EXECUTE ON FUNCTION us_booking.parcel_contents_basis(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.group_allocation_problems(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.parcel_contents_changes(jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.parcel_contents_revalidate(bigint, text, bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.tg_parcel_contents_basis() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_discrepancy_acknowledge(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.oms_sync_apply(jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_remove(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_for_edit(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.parcel_requirements_refresh(bigint, text) FROM PUBLIC;
