-- 0011_wayfair_managed_packaging: provider-specific packaging for Wayfair.
--
-- Workflow (warehouse team): Wayfair already holds the products' package weights and dimensions
-- from the listing, staff do not measure Wayfair orders, and they print the label Wayfair supplies.
-- Wayfair's documentation (Registration & Shipping API guide, read 2026-10-23) makes packageUnits
-- optional and says to send it when packing items/quantities into fewer boxes (consolidation);
-- a sandbox registration without packageUnits succeeded. The documentation does not state where
-- Wayfair takes package data from when packageUnits is omitted, so production behaviour is NOT
-- verified: provider_packaging_policy.production_verified_at stays NULL until a controlled
-- production test, and until then a Wayfair-managed parcel cannot pass the booking precondition.
--
-- 1. parcel.packaging_mode: 'measured' (every existing rule unchanged) or 'provider_managed'
--    (Wayfair only). A provider-managed parcel holds no measurements at all: no zeros, no profile
--    values, no values from labels. Its measurement requirement is met by the mode, for a group of
--    exactly one order (one purchase order); otherwise staff must decide.
-- 2. A packaging exception (consolidated or custom packaging) switches a Wayfair parcel to
--    'measured' with a recorded reason; staff then enter measurements in cm and kg, the units
--    Wayfair documents for packageUnits.
-- 3. Shippo and Amazon parcels are untouched: profiles, prefill and measurement checks as before;
--    provider_managed is refused for any group not routed to Wayfair.
-- 4. A Wayfair-managed parcel is one shipment record for the purchase order, not a carton: the
--    number of cartons and labels is Wayfair's; nothing is inferred from quantities or label pages.

CREATE TABLE IF NOT EXISTS us_booking.provider_packaging_policy (
  provider                text PRIMARY KEY CHECK (provider = 'wayfair_partner'),
  mode                    text NOT NULL CHECK (mode = 'provider_managed'),
  description             text NOT NULL,
  documentation_basis     text NOT NULL,
  sandbox_evidence        text,
  production_verified_by  text,
  production_verified_at  timestamptz,
  production_evidence     text,
  CHECK ((production_verified_at IS NULL) = (production_verified_by IS NULL)),
  CHECK (production_verified_at IS NULL OR production_evidence IS NOT NULL)
);
INSERT INTO us_booking.provider_packaging_policy (provider, mode, description, documentation_basis, sandbox_evidence)
VALUES ('wayfair_partner', 'provider_managed',
        'Register Wayfair purchase orders without packageUnits; Wayfair generates the labels. Staff send package units only for consolidated or custom packaging.',
        'Wayfair Registration & Shipping API guide (developer.wayfair.io, read 2026-10-23): packageUnits optional, used when consolidating items into fewer boxes; warehouseId defaults to the PO''s warehouse; shipping_label returns all labels of a PO.',
        'Sandbox registration on 2026-10-23 without packageUnits succeeded and its label PDF was downloaded (wayfair_sandbox_registration #1). Wayfair documents sandbox labels as static examples, so this does not show which package data production uses.')
ON CONFLICT (provider) DO NOTHING;

ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS packaging_mode text NOT NULL DEFAULT 'measured';
ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS packaging_exception_reason text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'us_booking.parcel'::regclass AND conname = 'parcel_packaging_mode_check') THEN
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_packaging_mode_check CHECK (packaging_mode IN ('measured', 'provider_managed'));
    -- Provider-managed packaging holds no measurement of any kind.
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_provider_managed_has_no_measurements CHECK (
      packaging_mode <> 'provider_managed'
      OR (length IS NULL AND width IS NULL AND height IS NULL AND dimension_unit IS NULL AND dimensions_source IS NULL
          AND weight IS NULL AND weight_unit IS NULL AND weight_source IS NULL AND measured_by IS NULL
          AND package_profile_id IS NULL AND packaging_exception_reason IS NULL));
  END IF;
END $$;

-- Provider-managed packaging only on Wayfair groups with the policy in place; Wayfair packaging
-- exceptions in the documented units; the mode is frozen while a purchase or label is live.
CREATE OR REPLACE FUNCTION us_booking.tg_parcel_packaging()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_provider text;
BEGIN
  SELECT provider INTO v_provider FROM us_booking.fulfilment_group WHERE id = NEW.fulfilment_group_id;
  IF TG_OP = 'UPDATE' AND NEW.packaging_mode IS DISTINCT FROM OLD.packaging_mode AND us_booking.parcel_is_locked(OLD.id) THEN
    RAISE EXCEPTION 'parcel % has a pending, unknown or active purchase; its packaging mode is frozen', OLD.parcel_no USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.packaging_mode = 'provider_managed' THEN
    IF v_provider IS DISTINCT FROM 'wayfair_partner'
       OR NOT EXISTS (SELECT 1 FROM us_booking.provider_packaging_policy WHERE provider = 'wayfair_partner') THEN
      RAISE EXCEPTION 'provider-managed packaging is only available for Wayfair orders (this group is routed to %)', coalesce(v_provider, '?')
        USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.length IS NOT NULL OR NEW.width IS NOT NULL OR NEW.height IS NOT NULL OR NEW.weight IS NOT NULL THEN
      RAISE EXCEPTION 'parcel % uses Wayfair-managed packaging: record a packaging exception before entering measurements', NEW.parcel_no
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF v_provider = 'wayfair_partner' AND NEW.packaging_exception_reason IS NOT NULL
        AND ((NEW.dimension_unit IS NOT NULL AND NEW.dimension_unit <> 'cm') OR (NEW.weight_unit IS NOT NULL AND NEW.weight_unit <> 'kg')) THEN
    RAISE EXCEPTION 'Wayfair package units are sent in centimetres and kilograms (the units Wayfair documents); enter the measurements in cm and kg'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER parcel_packaging
  BEFORE INSERT OR UPDATE ON us_booking.parcel
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_parcel_packaging();

-- Replaces 0009's booking precondition; adds the provider-managed packaging branch (marked 0011).
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
  -- 0011: Wayfair-managed packaging carries no measurements. It is accepted only for a Wayfair
  -- group of exactly one order, and only after the mode has been verified in production.
  IF v_parcel.packaging_mode = 'provider_managed' THEN
    IF v_group.provider IS DISTINCT FROM 'wayfair_partner' THEN
      RAISE EXCEPTION 'parcel % uses provider-managed packaging, which only Wayfair supports', NEW.parcel_id USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM us_booking.provider_packaging_policy
                    WHERE provider = 'wayfair_partner' AND production_verified_at IS NOT NULL) THEN
      RAISE EXCEPTION 'Wayfair-managed packaging has not been verified in production; parcel % cannot be booked with it yet', NEW.parcel_id
        USING ERRCODE = 'check_violation';
    END IF;
    IF (SELECT count(*) FROM us_booking.fulfilment_group_order WHERE fulfilment_group_id = v_group.id AND active) <> 1 THEN
      RAISE EXCEPTION 'Wayfair-managed packaging covers one purchase order; group % has several orders', v_group.id
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF v_parcel.length IS NULL OR v_parcel.width IS NULL OR v_parcel.height IS NULL OR v_parcel.dimension_unit IS NULL
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

-- Replaces 0009's parcel_requirements_refresh; counts Wayfair-managed packaging (marked 0011).
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
  v_managed   integer;   -- 0011: parcels with Wayfair-managed packaging
  v_orders    integer;   -- 0011: active orders in the group
  v_m_status  text;
  v_m_detail  text;
  v_c_status  text;
  v_c_detail  text;
BEGIN
  SELECT count(*) FILTER (WHERE state <> 'cancelled'),
         count(*) FILTER (WHERE state <> 'cancelled'
                            AND ((dimensions_source IS NOT NULL AND weight_source IS NOT NULL) OR packaging_mode = 'provider_managed')),
         count(*) FILTER (WHERE state <> 'cancelled' AND (dimensions_source = 'profile' OR weight_source = 'profile')),
         count(*) FILTER (WHERE state <> 'cancelled' AND contents_status = 'confirmed'),
         count(*) FILTER (WHERE state <> 'cancelled' AND contents_status = 'stale')
    INTO v_n, v_measured, v_profile, v_confirmed, v_stale
    FROM us_booking.parcel WHERE fulfilment_group_id = p_group_id;
  SELECT count(*) FILTER (WHERE state <> 'cancelled' AND packaging_mode = 'provider_managed') INTO v_managed
    FROM us_booking.parcel WHERE fulfilment_group_id = p_group_id;
  SELECT count(*) INTO v_orders FROM us_booking.fulfilment_group_order WHERE fulfilment_group_id = p_group_id AND active;
  SELECT count(*) INTO v_disc FROM us_booking.parcel_contents_discrepancy WHERE fulfilment_group_id = p_group_id AND status = 'open';
  SELECT COALESCE(sum(i.quantity_ordered), 0), COALESCE(sum(GREATEST(i.quantity_ordered - COALESCE(a.allocated_qty, 0), 0)), 0)
    INTO v_ordered, v_remaining
    FROM us_booking.fulfilment_group_order fo
    JOIN us_booking.oms_order_item i ON i.oms_order_id = fo.oms_order_id AND i.oms_absent_since IS NULL
    LEFT JOIN us_booking.item_allocation a ON a.oms_order_item_id = i.oms_order_item_id
   WHERE fo.fulfilment_group_id = p_group_id AND fo.active;
  v_problems := us_booking.group_allocation_problems(p_group_id);

  v_m_status := CASE WHEN v_n > 0 AND v_measured = v_n AND NOT (v_managed > 0 AND v_orders <> 1) THEN 'met' ELSE 'unmet' END;
  v_m_detail := CASE WHEN v_n = 0 THEN 'no parcels yet'
                     WHEN v_managed > 0 AND v_orders <> 1
                       THEN format('Wayfair-managed packaging covers one purchase order; this group has %s orders: staff decision needed', v_orders)
                     WHEN v_managed > 0
                       THEN concat_ws('; ', format('%s of %s parcel(s) use Wayfair-managed packaging (no measurements entered here)', v_managed, v_n),
                                      CASE WHEN v_n > v_managed THEN format('%s of %s other parcel(s) have dimensions and weight', v_measured - v_managed, v_n - v_managed) END)
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

-- Replaces 0008's staff_parcel_create; Wayfair groups start with Wayfair-managed packaging (marked 0011).
CREATE OR REPLACE FUNCTION us_booking.staff_parcel_create(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff  text := us_booking.staff_actor(p);
  v_group  us_booking.fulfilment_group%ROWTYPE;
  v_prof   record;
  v_ver    us_booking.package_profile_version%ROWTYPE;
  v_no     integer;
  v_parcel us_booking.parcel%ROWTYPE;
  v_prefill jsonb := NULL;
BEGIN
  SELECT * INTO v_group FROM us_booking.fulfilment_group WHERE id = us_booking.staff_id(p, 'group_id') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fulfilment group not found' USING ERRCODE = 'UB404';
  END IF;
  IF v_group.state <> 'review' THEN
    RAISE EXCEPTION 'the group is %; parcels can be prepared only while it is in review', v_group.state USING ERRCODE = 'UB409';
  END IF;
  SELECT coalesce(max(parcel_no), 0) + 1 INTO v_no FROM us_booking.parcel WHERE fulfilment_group_id = v_group.id;

  -- 0011: Wayfair groups start with Wayfair-managed packaging (no measurements, no profile).
  IF v_group.provider = 'wayfair_partner' AND EXISTS (SELECT 1 FROM us_booking.provider_packaging_policy WHERE provider = 'wayfair_partner') THEN
    INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, packaging_mode) VALUES (v_group.id, v_no, 'provider_managed')
    RETURNING * INTO v_parcel;
    INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
    VALUES ('parcel', v_parcel.id, NULL, 'open', v_staff,
            jsonb_build_object('action', 'created', 'fulfilment_group_id', v_group.id, 'parcel_no', v_no, 'packaging_mode', 'provider_managed'));
    PERFORM us_booking.parcel_requirements_refresh(v_group.id, v_staff);
    RETURN jsonb_build_object('parcel_id', v_parcel.id, 'parcel_no', v_no, 'prefill', NULL, 'packaging_mode', 'provider_managed');
  END IF;
  SELECT pp.id, pp.name, pp.current_version, pa.assignment INTO v_prof
    FROM us_booking.package_profile_assignment pa
    JOIN us_booking.package_profile pp ON pp.id = pa.profile_id
   WHERE pa.warehouse_id = v_group.warehouse_id AND pa.provider = v_group.provider AND pp.approval_status = 'approved';
  IF FOUND THEN
    SELECT * INTO v_ver FROM us_booking.package_profile_version WHERE profile_id = v_prof.id AND version = v_prof.current_version;
    INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, package_profile_id, package_profile_version,
           length, width, height, dimension_unit, dimensions_source, weight, weight_unit, weight_source)
    VALUES (v_group.id, v_no, v_ver.profile_id, v_ver.version, v_ver.length, v_ver.width, v_ver.height, v_ver.dimension_unit,
            'profile', v_ver.packed_weight, v_ver.packed_weight_unit, CASE WHEN v_ver.packed_weight IS NOT NULL THEN 'profile' END)
    RETURNING * INTO v_parcel;
    v_prefill := jsonb_build_object('assignment', v_prof.assignment, 'profile_id', v_prof.id, 'profile_name', v_prof.name,
                                    'version', v_ver.version, 'weight_prefilled', v_ver.packed_weight IS NOT NULL);
  ELSE
    INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no) VALUES (v_group.id, v_no) RETURNING * INTO v_parcel;
  END IF;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('parcel', v_parcel.id, NULL, 'open', v_staff,
          jsonb_build_object('action', 'created', 'fulfilment_group_id', v_group.id, 'parcel_no', v_no,
                             'prefill', v_prefill, 'values', us_booking.parcel_snapshot(v_parcel)));
  PERFORM us_booking.parcel_requirements_refresh(v_group.id, v_staff);
  RETURN jsonb_build_object('parcel_id', v_parcel.id, 'parcel_no', v_no, 'prefill', v_prefill);
END;
$$;

-- Switches a Wayfair parcel between Wayfair-managed packaging and a packaging exception.
-- Payload: staff, parcel_id, expected_row_version, mode ('measured' | 'provider_managed'), reason
-- (required for 'measured': why the package differs from Wayfair's own data, e.g. consolidated).
-- Returning to Wayfair-managed packaging clears the exception's measurements; they stay in event_log.
CREATE OR REPLACE FUNCTION us_booking.staff_parcel_set_packaging(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff  text := us_booking.staff_actor(p);
  v_parcel us_booking.parcel%ROWTYPE := us_booking.staff_parcel_for_edit(p);
  v_before jsonb := us_booking.parcel_snapshot(v_parcel);
  v_mode   text := p->>'mode';
  v_reason text;
  v_provider text;
BEGIN
  IF v_mode IS NULL OR v_mode NOT IN ('measured', 'provider_managed') THEN
    RAISE EXCEPTION 'mode must be measured or provider_managed' USING ERRCODE = 'UB422';
  END IF;
  SELECT provider INTO v_provider FROM us_booking.fulfilment_group WHERE id = v_parcel.fulfilment_group_id;
  IF v_provider IS DISTINCT FROM 'wayfair_partner' THEN
    RAISE EXCEPTION 'packaging modes apply to Wayfair orders only; this group is routed to %', v_provider USING ERRCODE = 'UB409';
  END IF;
  IF v_mode = v_parcel.packaging_mode THEN
    RETURN jsonb_build_object('parcel_id', v_parcel.id, 'row_version', v_parcel.row_version, 'unchanged', true);
  END IF;
  IF v_mode = 'measured' THEN
    v_reason := us_booking.staff_text(p, 'reason', 'Reason for the packaging exception', 3, 500);
    UPDATE us_booking.parcel SET packaging_mode = 'measured', packaging_exception_reason = v_reason
     WHERE id = v_parcel.id RETURNING * INTO v_parcel;
  ELSE
    UPDATE us_booking.parcel
       SET packaging_mode = 'provider_managed', packaging_exception_reason = NULL,
           length = NULL, width = NULL, height = NULL, dimension_unit = NULL, dimensions_source = NULL,
           weight = NULL, weight_unit = NULL, weight_source = NULL, measured_by = NULL, measured_at = NULL,
           package_profile_id = NULL, package_profile_version = NULL
     WHERE id = v_parcel.id RETURNING * INTO v_parcel;
  END IF;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('parcel', v_parcel.id, v_parcel.state, v_parcel.state, v_staff,
          jsonb_build_object('action', 'packaging_mode', 'to', v_mode, 'reason', v_reason,
                             'previous_values', v_before));
  PERFORM us_booking.parcel_requirements_refresh(v_parcel.fulfilment_group_id, v_staff);
  RETURN jsonb_build_object('parcel_id', v_parcel.id, 'row_version', v_parcel.row_version, 'packaging_mode', v_mode);
END;
$$;

REVOKE EXECUTE ON FUNCTION us_booking.tg_parcel_packaging() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_set_packaging(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_create(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.parcel_requirements_refresh(bigint, text) FROM PUBLIC;
