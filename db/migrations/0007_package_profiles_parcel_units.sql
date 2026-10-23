-- 0007_package_profiles_parcel_units: versioned package profiles, default-profile assignments, and
-- parcel measurements with explicit units and a recorded source.
--
-- 1. package_profile becomes a named profile whose values live in immutable versions
--    (package_profile_version). Editing a profile adds a version; nothing is overwritten. A version
--    holds the box dimensions with their unit and, separately and optionally, the TOTAL PACKED
--    shipment weight and the EMPTY packaging weight, each with its own unit. Units are stored as
--    entered and never converted (2 kg is not 2 lb).
-- 2. package_profile_assignment names the default profile for US1 Shippo orders (Shopify/eBay) and
--    US1 Amazon orders. Rows start unassigned; staff assign profiles in Settings.
-- 3. parcel: length/width/height/weight lose their implied in/lb suffix and gain dimension_unit and
--    weight_unit. Each of dimensions and weight records its source:
--      'profile' = copied from an approved default profile version (package_profile_id + version
--                  are kept, and the values must equal that version's values);
--      'staff'   = entered by staff (measured_by / measured_at name who entered them).
--    measured_by / measured_at are never set for values copied from a profile. Later profile edits
--    create new versions and so never change an existing parcel.
-- 4. The booking precondition accepts either source: dimensions and weight must be complete, with
--    units and a source. Contents still need explicit staff confirmation; a profile never confirms
--    contents. Positive-value checks, allocation limits and purchase/label locks are unchanged.
--
-- Guard: the column changes need empty package_profile and parcel tables (true when written:
-- neither table has ever held a row). If either holds rows, the migration stops and nothing is
-- changed.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'us_booking' AND table_name = 'package_profile' AND column_name = 'length_in')
     AND EXISTS (SELECT 1 FROM us_booking.package_profile) THEN
    RAISE EXCEPTION '0007: us_booking.package_profile already holds rows; convert them by hand before applying this migration';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'us_booking' AND table_name = 'parcel' AND column_name = 'length_in')
     AND EXISTS (SELECT 1 FROM us_booking.parcel) THEN
    RAISE EXCEPTION '0007: us_booking.parcel already holds rows; their units cannot be recorded automatically';
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------
-- Profiles and versions
-- ---------------------------------------------------------------------------------------------
ALTER TABLE us_booking.package_profile DROP COLUMN IF EXISTS length_in;
ALTER TABLE us_booking.package_profile DROP COLUMN IF EXISTS width_in;
ALTER TABLE us_booking.package_profile DROP COLUMN IF EXISTS height_in;
ALTER TABLE us_booking.package_profile DROP COLUMN IF EXISTS empty_weight_lb;
ALTER TABLE us_booking.package_profile ADD COLUMN IF NOT EXISTS current_version integer;
ALTER TABLE us_booking.package_profile ADD COLUMN IF NOT EXISTS created_by text;
ALTER TABLE us_booking.package_profile ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
COMMENT ON COLUMN us_booking.package_profile.approval_status IS
  'proposed = no approved values yet; approved = current_version holds staff-approved values; retired = not offered for new parcels';

CREATE TABLE IF NOT EXISTS us_booking.package_profile_version (
  profile_id          bigint NOT NULL REFERENCES us_booking.package_profile(id),
  version             integer NOT NULL CHECK (version > 0),
  length              numeric(8,2) NOT NULL CHECK (length > 0),
  width               numeric(8,2) NOT NULL CHECK (width > 0),
  height              numeric(8,2) NOT NULL CHECK (height > 0),
  dimension_unit      text NOT NULL CHECK (dimension_unit IN ('in', 'cm')),
  -- Total packed shipment weight to prefill on a new parcel (optional). Not the box's own weight.
  packed_weight       numeric(8,3) CHECK (packed_weight > 0),
  packed_weight_unit  text CHECK (packed_weight_unit IN ('lb', 'kg', 'oz', 'g')),
  -- Weight of the empty packaging (optional, reference only; never used as a shipment weight).
  empty_weight        numeric(8,3) CHECK (empty_weight > 0),
  empty_weight_unit   text CHECK (empty_weight_unit IN ('lb', 'kg', 'oz', 'g')),
  note                text,
  approved_by         text NOT NULL CHECK (length(btrim(approved_by)) > 0 AND approved_by !~ '^(system|migration):'),
  approved_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (profile_id, version),
  CHECK ((packed_weight IS NULL) = (packed_weight_unit IS NULL)),
  CHECK ((empty_weight IS NULL) = (empty_weight_unit IS NULL))
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'package_profile_current_version_fkey'
                    AND conrelid = 'us_booking.package_profile'::regclass) THEN
    ALTER TABLE us_booking.package_profile ADD CONSTRAINT package_profile_current_version_fkey
      FOREIGN KEY (id, current_version) REFERENCES us_booking.package_profile_version(profile_id, version);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'package_profile_approved_has_version'
                    AND conrelid = 'us_booking.package_profile'::regclass) THEN
    ALTER TABLE us_booking.package_profile ADD CONSTRAINT package_profile_approved_has_version
      CHECK (approval_status <> 'approved' OR current_version IS NOT NULL);
  END IF;
END $$;

-- Versions are history: never updated or deleted.
CREATE OR REPLACE TRIGGER package_profile_version_append_only
  BEFORE UPDATE OR DELETE ON us_booking.package_profile_version
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_append_only();
CREATE OR REPLACE TRIGGER package_profile_version_no_truncate
  BEFORE TRUNCATE ON us_booking.package_profile_version
  FOR EACH STATEMENT EXECUTE FUNCTION us_booking.tg_append_only();

-- Which profile prefills new parcels, per warehouse and provider route.
CREATE TABLE IF NOT EXISTS us_booking.package_profile_assignment (
  assignment      text PRIMARY KEY CHECK (assignment IN ('us1_shippo', 'us1_amazon')),
  warehouse_id    integer NOT NULL,
  provider        text NOT NULL CHECK (provider IN ('shippo', 'amazon_seller_central')),
  profile_id      bigint REFERENCES us_booking.package_profile(id),
  assigned_by     text,
  assigned_at     timestamptz,
  UNIQUE (warehouse_id, provider),
  CHECK (profile_id IS NULL OR (assigned_by IS NOT NULL AND assigned_at IS NOT NULL))
);
INSERT INTO us_booking.package_profile_assignment (assignment, warehouse_id, provider) VALUES
  ('us1_shippo', 32, 'shippo'),
  ('us1_amazon', 32, 'amazon_seller_central')
ON CONFLICT (assignment) DO NOTHING;

-- ---------------------------------------------------------------------------------------------
-- Parcel units and provenance
-- ---------------------------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'us_booking' AND table_name = 'parcel' AND column_name = 'length_in') THEN
    ALTER TABLE us_booking.parcel RENAME COLUMN length_in TO length;
    ALTER TABLE us_booking.parcel RENAME COLUMN width_in TO width;
    ALTER TABLE us_booking.parcel RENAME COLUMN height_in TO height;
    ALTER TABLE us_booking.parcel RENAME COLUMN weight_lb TO weight;
    ALTER TABLE us_booking.parcel RENAME CONSTRAINT parcel_length_in_check TO parcel_length_check;
    ALTER TABLE us_booking.parcel RENAME CONSTRAINT parcel_width_in_check TO parcel_width_check;
    ALTER TABLE us_booking.parcel RENAME CONSTRAINT parcel_height_in_check TO parcel_height_check;
    ALTER TABLE us_booking.parcel RENAME CONSTRAINT parcel_weight_lb_check TO parcel_weight_check;
  END IF;
END $$;
ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS dimension_unit text CHECK (dimension_unit IN ('in', 'cm'));
ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS weight_unit text CHECK (weight_unit IN ('lb', 'kg', 'oz', 'g'));
ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS dimensions_source text CHECK (dimensions_source IN ('profile', 'staff'));
ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS weight_source text CHECK (weight_source IN ('profile', 'staff'));
ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS package_profile_version integer;
ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS row_version integer NOT NULL DEFAULT 1;
ALTER TABLE us_booking.parcel ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
COMMENT ON COLUMN us_booking.parcel.weight IS 'total packed shipment weight, in weight_unit';
COMMENT ON COLUMN us_booking.parcel.measured_by IS 'who entered the staff-sourced values; never set for values copied from a profile';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'us_booking.parcel'::regclass AND conname = 'parcel_dimensions_complete') THEN
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_dimensions_complete CHECK (
      (length IS NULL AND width IS NULL AND height IS NULL AND dimension_unit IS NULL AND dimensions_source IS NULL)
      OR (length IS NOT NULL AND width IS NOT NULL AND height IS NOT NULL AND dimension_unit IS NOT NULL AND dimensions_source IS NOT NULL));
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_weight_complete CHECK (
      (weight IS NULL AND weight_unit IS NULL AND weight_source IS NULL)
      OR (weight IS NOT NULL AND weight_unit IS NOT NULL AND weight_source IS NOT NULL));
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_profile_reference CHECK (
      (package_profile_id IS NULL) = (package_profile_version IS NULL));
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_profile_source_needs_profile CHECK (
      package_profile_version IS NOT NULL OR (dimensions_source IS DISTINCT FROM 'profile' AND weight_source IS DISTINCT FROM 'profile'));
    -- measured_by/measured_at exactly when some value was entered by staff.
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_measured_by_only_for_staff_values CHECK (
      (measured_by IS NOT NULL) = (coalesce(dimensions_source = 'staff', false) OR coalesce(weight_source = 'staff', false)));
    ALTER TABLE us_booking.parcel ADD CONSTRAINT parcel_profile_version_fkey
      FOREIGN KEY (package_profile_id, package_profile_version) REFERENCES us_booking.package_profile_version(profile_id, version);
  END IF;
END $$;

-- Values marked as coming from a profile must be exactly that profile version's values.
CREATE OR REPLACE FUNCTION us_booking.tg_parcel_provenance()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v us_booking.package_profile_version%ROWTYPE;
BEGIN
  -- Without a recorded version the parcel_profile_source_needs_profile check rejects the row.
  IF (NEW.dimensions_source = 'profile' OR NEW.weight_source = 'profile') AND NEW.package_profile_version IS NOT NULL THEN
    SELECT * INTO v FROM us_booking.package_profile_version
     WHERE profile_id = NEW.package_profile_id AND version = NEW.package_profile_version;
    IF NEW.dimensions_source = 'profile'
       AND (NEW.length, NEW.width, NEW.height, NEW.dimension_unit) IS DISTINCT FROM (v.length, v.width, v.height, v.dimension_unit) THEN
      RAISE EXCEPTION 'parcel dimensions marked as default profile differ from profile % version %; record them as staff-entered',
        NEW.package_profile_id, NEW.package_profile_version USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.weight_source = 'profile'
       AND (v.packed_weight IS NULL OR (NEW.weight, NEW.weight_unit) IS DISTINCT FROM (v.packed_weight, v.packed_weight_unit)) THEN
      RAISE EXCEPTION 'parcel weight marked as default profile differs from the packed weight of profile % version %; record it as staff-entered',
        NEW.package_profile_id, NEW.package_profile_version USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER parcel_provenance
  BEFORE INSERT OR UPDATE ON us_booking.parcel
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_parcel_provenance();

-- Replaces 0001's guard: same rules over the renamed and new columns, plus a row version for
-- stale-edit detection (every update increments it).
CREATE OR REPLACE FUNCTION us_booking.tg_parcel_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF (NEW.id, NEW.fulfilment_group_id, NEW.parcel_no) IS DISTINCT FROM (OLD.id, OLD.fulfilment_group_id, OLD.parcel_no) THEN
    RAISE EXCEPTION 'parcel identity is immutable' USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.state = 'cancelled' THEN
    RAISE EXCEPTION 'parcel % is cancelled; cancellation is final', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  IF (NEW.length, NEW.width, NEW.height, NEW.dimension_unit, NEW.dimensions_source, NEW.weight, NEW.weight_unit,
      NEW.weight_source, NEW.package_profile_id, NEW.package_profile_version, NEW.measured_by, NEW.measured_at,
      NEW.contents_status, NEW.confirmed_by, NEW.confirmed_at)
     IS DISTINCT FROM
     (OLD.length, OLD.width, OLD.height, OLD.dimension_unit, OLD.dimensions_source, OLD.weight, OLD.weight_unit,
      OLD.weight_source, OLD.package_profile_id, OLD.package_profile_version, OLD.measured_by, OLD.measured_at,
      OLD.contents_status, OLD.confirmed_by, OLD.confirmed_at)
     AND us_booking.parcel_is_locked(OLD.id) THEN
    RAISE EXCEPTION 'parcel % has a pending, unknown or active purchase; measurements and contents are frozen', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.state IS DISTINCT FROM OLD.state AND NEW.state IN ('open','cancelled') AND us_booking.parcel_is_locked(OLD.id) THEN
    RAISE EXCEPTION 'parcel % cannot become % while a purchase or label is live; confirm the void first', OLD.id, NEW.state
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.contents_status = 'confirmed' AND OLD.contents_status <> 'confirmed'
     AND NOT EXISTS (SELECT 1 FROM us_booking.parcel_item WHERE parcel_id = OLD.id) THEN
    RAISE EXCEPTION 'parcel % has no items; nothing to confirm', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  NEW.row_version := OLD.row_version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- Replaces 0001's booking precondition. Only the measurement check changes: dimensions and weight
-- must be complete with units and a recorded source (approved default profile or staff-entered).
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
  -- Serialise against parcel/contents edits and other attempts on the same parcel and group.
  SELECT * INTO v_parcel FROM us_booking.parcel WHERE id = NEW.parcel_id FOR UPDATE;
  SELECT * INTO v_group FROM us_booking.fulfilment_group WHERE id = NEW.fulfilment_group_id FOR UPDATE;

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

-- Ordered, allocated (non-cancelled parcels) and remaining units per order line.
CREATE OR REPLACE VIEW us_booking.v_order_item_allocation AS
SELECT i.oms_order_item_id,
       i.oms_order_id,
       i.quantity_ordered,
       coalesce(a.allocated_qty, 0)                        AS allocated_qty,
       i.quantity_ordered - coalesce(a.allocated_qty, 0)   AS remaining_qty
  FROM us_booking.oms_order_item i
  LEFT JOIN us_booking.item_allocation a ON a.oms_order_item_id = i.oms_order_item_id;
