-- 0008_staff_review_actions: the write actions behind the review screen, and failed-sync records.
--
-- Every staff action is one function taking a jsonb payload. It validates its input, names the staff
-- member (payload "staff"; the screen has no login yet, so this is the name staff enter), checks that
-- the data it was based on has not changed since it was loaded (stale-edit protection), writes, and
-- appends an event_log entry. Errors carry SQLSTATE UB4xx so the web server can map them:
--   UB404 not found, UB409 stale or not allowed in the current state, UB422 invalid input.
-- Integrity rules stay in the existing triggers (allocation limits, purchase/label locks, contents
-- confirmation), so these functions cannot bypass them.
--
-- Actions:
--   package profiles   staff_profile_save, staff_profile_assign
--   parcels            staff_parcel_create (prefills the assigned default profile), staff_parcel_measure,
--                      staff_parcel_set_contents, staff_parcel_confirm_contents, staff_parcel_remove
--   destination        staff_destination_confirm (exceptions only: unresolved orders), staff_destination_revoke
--   review findings    staff_case_close (resolve or dismiss with evidence; touches nothing else)
--   sync               sync_record_failure (called outside the rolled-back import transaction)

-- ---------------------------------------------------------------------------------------------
-- Input helpers
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION us_booking.staff_actor(p jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE
  v text := btrim(coalesce(p->>'staff', ''));
BEGIN
  IF length(v) < 2 OR length(v) > 120 THEN
    RAISE EXCEPTION 'enter your name (2 to 120 characters) so the action is recorded against it' USING ERRCODE = 'UB422';
  END IF;
  IF v ~* '^(system|migration):' THEN
    RAISE EXCEPTION 'a staff name cannot start with system: or migration:' USING ERRCODE = 'UB422';
  END IF;
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION us_booking.staff_id(p jsonb, p_key text)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
BEGIN
  IF coalesce(p->>p_key, '') !~ '^[1-9][0-9]{0,17}$' THEN
    RAISE EXCEPTION '% must be a positive whole number', p_key USING ERRCODE = 'UB422';
  END IF;
  RETURN (p->>p_key)::bigint;
END;
$$;

-- A positive measurement: digits with an optional decimal part, at most 99999.
CREATE OR REPLACE FUNCTION us_booking.staff_measure(p jsonb, p_key text, p_label text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE
  v text := btrim(coalesce(p->>p_key, ''));
BEGIN
  IF v !~ '^[0-9]{1,5}(\.[0-9]{1,3})?$' OR v::numeric <= 0 THEN
    RAISE EXCEPTION '% must be a positive number (up to 99999, at most 3 decimals)', p_label USING ERRCODE = 'UB422';
  END IF;
  RETURN v::numeric;
END;
$$;

CREATE OR REPLACE FUNCTION us_booking.staff_text(p jsonb, p_key text, p_label text, p_min integer, p_max integer)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE
  v text := btrim(coalesce(p->>p_key, ''));
BEGIN
  IF length(v) < p_min OR length(v) > p_max THEN
    RAISE EXCEPTION '% must be % to % characters', p_label, p_min, p_max USING ERRCODE = 'UB422';
  END IF;
  RETURN v;
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Package profiles
-- ---------------------------------------------------------------------------------------------

-- Creates a profile (profile_id absent) or adds a new version to one. Payload: staff, name,
-- length, width, height, dimension_unit, optional packed_weight + packed_weight_unit, optional
-- empty_weight + empty_weight_unit, optional note; for an edit also profile_id and
-- expected_version (the version the editor was showing). Identical values add no version.
CREATE OR REPLACE FUNCTION us_booking.staff_profile_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff   text := us_booking.staff_actor(p);
  v_name    text := us_booking.staff_text(p, 'name', 'Profile name', 2, 80);
  v_note    text := nullif(btrim(coalesce(p->>'note', '')), '');
  v_new     us_booking.package_profile_version%ROWTYPE;
  v_cur     us_booking.package_profile_version%ROWTYPE;
  v_prof    us_booking.package_profile%ROWTYPE;
  v_unit    text;
BEGIN
  v_new.length := us_booking.staff_measure(p, 'length', 'Length');
  v_new.width := us_booking.staff_measure(p, 'width', 'Width');
  v_new.height := us_booking.staff_measure(p, 'height', 'Height');
  v_new.dimension_unit := p->>'dimension_unit';
  IF v_new.dimension_unit IS NULL OR v_new.dimension_unit NOT IN ('in', 'cm') THEN
    RAISE EXCEPTION 'dimension unit must be in or cm' USING ERRCODE = 'UB422';
  END IF;
  FOREACH v_unit IN ARRAY ARRAY['packed_weight', 'empty_weight'] LOOP
    IF nullif(btrim(coalesce(p->>v_unit, '')), '') IS NOT NULL OR nullif(p->>(v_unit || '_unit'), '') IS NOT NULL THEN
      IF coalesce(p->>(v_unit || '_unit'), '') NOT IN ('lb', 'kg', 'oz', 'g') THEN
        RAISE EXCEPTION '% needs a unit: lb, kg, oz or g', replace(v_unit, '_', ' ') USING ERRCODE = 'UB422';
      END IF;
      IF v_unit = 'packed_weight' THEN
        v_new.packed_weight := us_booking.staff_measure(p, v_unit, 'Total packed shipment weight');
        v_new.packed_weight_unit := p->>'packed_weight_unit';
      ELSE
        v_new.empty_weight := us_booking.staff_measure(p, v_unit, 'Empty packaging weight');
        v_new.empty_weight_unit := p->>'empty_weight_unit';
      END IF;
    END IF;
  END LOOP;

  IF p->>'profile_id' IS NULL THEN
    IF EXISTS (SELECT 1 FROM us_booking.package_profile WHERE lower(name) = lower(v_name)) THEN
      RAISE EXCEPTION 'a profile named "%" already exists', v_name USING ERRCODE = 'UB409';
    END IF;
    INSERT INTO us_booking.package_profile (name, created_by) VALUES (v_name, v_staff) RETURNING * INTO v_prof;
  ELSE
    SELECT * INTO v_prof FROM us_booking.package_profile WHERE id = us_booking.staff_id(p, 'profile_id') FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'package profile not found' USING ERRCODE = 'UB404';
    END IF;
    IF v_prof.current_version IS DISTINCT FROM nullif(p->>'expected_version', '')::integer THEN
      RAISE EXCEPTION 'this profile was changed by someone else (now version %); reload before editing', coalesce(v_prof.current_version::text, 'none')
        USING ERRCODE = 'UB409';
    END IF;
    IF v_prof.approval_status = 'retired' THEN
      RAISE EXCEPTION 'profile "%" is retired', v_prof.name USING ERRCODE = 'UB409';
    END IF;
    IF lower(v_name) <> lower(v_prof.name)
       AND EXISTS (SELECT 1 FROM us_booking.package_profile WHERE lower(name) = lower(v_name) AND id <> v_prof.id) THEN
      RAISE EXCEPTION 'a profile named "%" already exists', v_name USING ERRCODE = 'UB409';
    END IF;
    SELECT * INTO v_cur FROM us_booking.package_profile_version WHERE profile_id = v_prof.id AND version = v_prof.current_version;
    IF FOUND AND v_name = v_prof.name
       AND (v_cur.length, v_cur.width, v_cur.height, v_cur.dimension_unit, v_cur.packed_weight, v_cur.packed_weight_unit,
            v_cur.empty_weight, v_cur.empty_weight_unit, v_cur.note)
           IS NOT DISTINCT FROM
           (v_new.length, v_new.width, v_new.height, v_new.dimension_unit, v_new.packed_weight, v_new.packed_weight_unit,
            v_new.empty_weight, v_new.empty_weight_unit, v_note) THEN
      RETURN jsonb_build_object('profile_id', v_prof.id, 'version', v_prof.current_version, 'unchanged', true);
    END IF;
  END IF;

  INSERT INTO us_booking.package_profile_version (profile_id, version, length, width, height, dimension_unit,
         packed_weight, packed_weight_unit, empty_weight, empty_weight_unit, note, approved_by)
  VALUES (v_prof.id, coalesce(v_prof.current_version, 0) + 1, v_new.length, v_new.width, v_new.height, v_new.dimension_unit,
          v_new.packed_weight, v_new.packed_weight_unit, v_new.empty_weight, v_new.empty_weight_unit, v_note, v_staff)
  RETURNING * INTO v_new;
  UPDATE us_booking.package_profile
     SET name = v_name, current_version = v_new.version, approval_status = 'approved',
         approved_by = v_staff, approved_at = v_new.approved_at, updated_at = now()
   WHERE id = v_prof.id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('package_profile', v_prof.id, v_prof.current_version::text, v_new.version::text, v_staff,
          jsonb_build_object('action', CASE WHEN v_prof.current_version IS NULL THEN 'created' ELSE 'new_version' END,
                             'name', v_name, 'values', to_jsonb(v_new) - 'profile_id'));
  RETURN jsonb_build_object('profile_id', v_prof.id, 'version', v_new.version, 'unchanged', false);
END;
$$;

-- Sets (or clears, profile_id null) the default profile of an assignment. Payload: staff,
-- assignment, profile_id, expected_profile_id (what the screen showed).
CREATE OR REPLACE FUNCTION us_booking.staff_profile_assign(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff text := us_booking.staff_actor(p);
  v_row   us_booking.package_profile_assignment%ROWTYPE;
  v_pid   bigint := CASE WHEN p->>'profile_id' IS NULL THEN NULL ELSE us_booking.staff_id(p, 'profile_id') END;
  v_prof  us_booking.package_profile%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM us_booking.package_profile_assignment WHERE assignment = p->>'assignment' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown assignment %', coalesce(p->>'assignment', '(none)') USING ERRCODE = 'UB404';
  END IF;
  IF v_row.profile_id IS DISTINCT FROM nullif(p->>'expected_profile_id', '')::bigint THEN
    RAISE EXCEPTION 'this default was changed by someone else; reload before changing it' USING ERRCODE = 'UB409';
  END IF;
  IF v_pid IS NOT NULL THEN
    SELECT * INTO v_prof FROM us_booking.package_profile WHERE id = v_pid FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'package profile not found' USING ERRCODE = 'UB404';
    END IF;
    IF v_prof.approval_status <> 'approved' THEN
      RAISE EXCEPTION 'profile "%" has no approved values yet', v_prof.name USING ERRCODE = 'UB409';
    END IF;
  END IF;
  IF v_row.profile_id IS NOT DISTINCT FROM v_pid THEN
    RETURN jsonb_build_object('assignment', v_row.assignment, 'profile_id', v_pid, 'unchanged', true);
  END IF;
  UPDATE us_booking.package_profile_assignment
     SET profile_id = v_pid, assigned_by = CASE WHEN v_pid IS NULL THEN NULL ELSE v_staff END,
         assigned_at = CASE WHEN v_pid IS NULL THEN NULL ELSE now() END
   WHERE assignment = v_row.assignment;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('package_profile_assignment', coalesce(v_pid, 0), v_row.profile_id::text, v_pid::text, v_staff,
          jsonb_build_object('assignment', v_row.assignment, 'warehouse_id', v_row.warehouse_id, 'provider', v_row.provider,
                             'profile_name', v_prof.name, 'profile_version', v_prof.current_version));
  RETURN jsonb_build_object('assignment', v_row.assignment, 'profile_id', v_pid, 'unchanged', false);
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Parcels
-- ---------------------------------------------------------------------------------------------

-- Recomputes the group's parcel requirements from its parcels (sync never touches these rows).
--   parcel_measurements: met when every non-cancelled parcel has dimensions and weight with a source.
--   parcel_contents:     met when every ordered unit of the group is in a parcel and every
--                        non-cancelled parcel's contents are confirmed by staff.
CREATE OR REPLACE FUNCTION us_booking.parcel_requirements_refresh(p_group_id bigint, p_actor text)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_n         integer;
  v_measured  integer;
  v_profile   integer;
  v_confirmed integer;
  v_ordered   integer;
  v_allocated integer;
  v_m_status  text;
  v_m_detail  text;
  v_c_status  text;
  v_c_detail  text;
BEGIN
  SELECT count(*) FILTER (WHERE state <> 'cancelled'),
         count(*) FILTER (WHERE state <> 'cancelled' AND dimensions_source IS NOT NULL AND weight_source IS NOT NULL),
         count(*) FILTER (WHERE state <> 'cancelled' AND (dimensions_source = 'profile' OR weight_source = 'profile')),
         count(*) FILTER (WHERE state <> 'cancelled' AND contents_status = 'confirmed')
    INTO v_n, v_measured, v_profile, v_confirmed
    FROM us_booking.parcel WHERE fulfilment_group_id = p_group_id;
  SELECT coalesce(sum(a.quantity_ordered), 0), coalesce(sum(a.allocated_qty), 0) INTO v_ordered, v_allocated
    FROM us_booking.v_order_item_allocation a
   WHERE a.oms_order_id IN (SELECT oms_order_id FROM us_booking.fulfilment_group_order WHERE fulfilment_group_id = p_group_id AND active);

  v_m_status := CASE WHEN v_n > 0 AND v_measured = v_n THEN 'met' ELSE 'unmet' END;
  v_m_detail := CASE WHEN v_n = 0 THEN 'no parcels yet'
                     ELSE format('%s of %s parcel(s) have dimensions and weight; %s use default-profile values',
                                 v_measured, v_n, v_profile) END;
  v_c_status := CASE WHEN v_n > 0 AND v_confirmed = v_n AND v_allocated = v_ordered THEN 'met' ELSE 'unmet' END;
  v_c_detail := CASE WHEN v_n = 0 THEN 'no parcel contents confirmed yet'
                     ELSE format('%s of %s ordered unit(s) in parcels; contents confirmed for %s of %s parcel(s)',
                                 v_allocated, v_ordered, v_confirmed, v_n) END;

  INSERT INTO us_booking.shipment_requirement AS r (fulfilment_group_id, oms_order_id, requirement, status, detail, checked_by)
  VALUES (p_group_id, NULL, 'parcel_measurements', v_m_status, v_m_detail, p_actor),
         (p_group_id, NULL, 'parcel_contents', v_c_status, v_c_detail, p_actor)
  ON CONFLICT (fulfilment_group_id, oms_order_id, requirement) DO UPDATE
     SET status = EXCLUDED.status, detail = EXCLUDED.detail, checked_by = EXCLUDED.checked_by, checked_at = now(), basis_hash = NULL
   WHERE (r.status, r.detail) IS DISTINCT FROM (EXCLUDED.status, EXCLUDED.detail);
END;
$$;

-- Locks a parcel and its group for a staff edit and checks it is still what the editor saw.
CREATE OR REPLACE FUNCTION us_booking.staff_parcel_for_edit(p jsonb)
RETURNS us_booking.parcel LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_parcel us_booking.parcel%ROWTYPE;
  v_state  text;
BEGIN
  SELECT * INTO v_parcel FROM us_booking.parcel WHERE id = us_booking.staff_id(p, 'parcel_id') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'parcel not found' USING ERRCODE = 'UB404';
  END IF;
  SELECT state INTO v_state FROM us_booking.fulfilment_group WHERE id = v_parcel.fulfilment_group_id FOR UPDATE;
  IF v_parcel.row_version IS DISTINCT FROM nullif(p->>'expected_row_version', '')::integer THEN
    RAISE EXCEPTION 'parcel % was changed by someone else since it was loaded; reload and try again', v_parcel.parcel_no
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

CREATE OR REPLACE FUNCTION us_booking.parcel_snapshot(v us_booking.parcel)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT jsonb_build_object('length', v.length, 'width', v.width, 'height', v.height, 'dimension_unit', v.dimension_unit,
                            'dimensions_source', v.dimensions_source, 'weight', v.weight, 'weight_unit', v.weight_unit,
                            'weight_source', v.weight_source, 'package_profile_id', v.package_profile_id,
                            'package_profile_version', v.package_profile_version, 'measured_by', v.measured_by,
                            'contents_status', v.contents_status)
$$;

-- New draft parcel for a group in review. Dimensions (and the packed weight, when the profile has
-- one) are copied from the default profile assigned to the group's warehouse and provider; the
-- profile id and version are recorded. Contents start empty and unconfirmed. Payload: staff, group_id.
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

-- Changes a parcel's dimensions and/or total packed weight. Payload: staff, parcel_id,
-- expected_row_version, and any of
--   dimensions: {length, width, height, unit}  -> staff-entered values
--               "profile"                       -> back to this parcel's recorded profile version
--   weight:     {value, unit}                   -> staff-entered total packed weight
--               "profile"                       -> back to the recorded profile version's packed weight
-- An omitted key leaves that part unchanged. The recorded profile version is never switched to a
-- newer one, so later profile edits do not alter this parcel.
CREATE OR REPLACE FUNCTION us_booking.staff_parcel_measure(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff  text := us_booking.staff_actor(p);
  v_old    us_booking.parcel%ROWTYPE := us_booking.staff_parcel_for_edit(p);
  v_new    us_booking.parcel%ROWTYPE;
  v_ver    us_booking.package_profile_version%ROWTYPE;
  v_staff_set boolean := false;
BEGIN
  v_new := v_old;
  IF v_old.package_profile_id IS NOT NULL THEN
    SELECT * INTO v_ver FROM us_booking.package_profile_version
     WHERE profile_id = v_old.package_profile_id AND version = v_old.package_profile_version;
  END IF;

  IF jsonb_typeof(p->'dimensions') = 'string' AND p->>'dimensions' = 'profile' THEN
    IF v_ver.profile_id IS NULL THEN
      RAISE EXCEPTION 'this parcel was not created from a default profile' USING ERRCODE = 'UB409';
    END IF;
    v_new.length := v_ver.length; v_new.width := v_ver.width; v_new.height := v_ver.height;
    v_new.dimension_unit := v_ver.dimension_unit; v_new.dimensions_source := 'profile';
  ELSIF jsonb_typeof(p->'dimensions') = 'object' THEN
    v_new.length := us_booking.staff_measure(p->'dimensions', 'length', 'Length');
    v_new.width := us_booking.staff_measure(p->'dimensions', 'width', 'Width');
    v_new.height := us_booking.staff_measure(p->'dimensions', 'height', 'Height');
    v_new.dimension_unit := p->'dimensions'->>'unit';
    IF v_new.dimension_unit IS NULL OR v_new.dimension_unit NOT IN ('in', 'cm') THEN
      RAISE EXCEPTION 'dimension unit must be in or cm' USING ERRCODE = 'UB422';
    END IF;
    v_new.dimensions_source := 'staff';
    v_staff_set := true;
  ELSIF p ? 'dimensions' AND jsonb_typeof(p->'dimensions') <> 'null' THEN
    RAISE EXCEPTION 'dimensions must be an object or "profile"' USING ERRCODE = 'UB422';
  END IF;

  IF jsonb_typeof(p->'weight') = 'string' AND p->>'weight' = 'profile' THEN
    IF v_ver.packed_weight IS NULL THEN
      RAISE EXCEPTION 'this parcel''s profile version has no packed weight' USING ERRCODE = 'UB409';
    END IF;
    v_new.weight := v_ver.packed_weight; v_new.weight_unit := v_ver.packed_weight_unit; v_new.weight_source := 'profile';
  ELSIF jsonb_typeof(p->'weight') = 'object' THEN
    v_new.weight := us_booking.staff_measure(p->'weight', 'value', 'Total packed weight');
    v_new.weight_unit := p->'weight'->>'unit';
    IF v_new.weight_unit IS NULL OR v_new.weight_unit NOT IN ('lb', 'kg', 'oz', 'g') THEN
      RAISE EXCEPTION 'weight unit must be lb, kg, oz or g' USING ERRCODE = 'UB422';
    END IF;
    v_new.weight_source := 'staff';
    v_staff_set := true;
  ELSIF p ? 'weight' AND jsonb_typeof(p->'weight') <> 'null' THEN
    RAISE EXCEPTION 'weight must be an object or "profile"' USING ERRCODE = 'UB422';
  END IF;

  IF (v_new.length, v_new.width, v_new.height, v_new.dimension_unit, v_new.dimensions_source,
      v_new.weight, v_new.weight_unit, v_new.weight_source)
     IS NOT DISTINCT FROM
     (v_old.length, v_old.width, v_old.height, v_old.dimension_unit, v_old.dimensions_source,
      v_old.weight, v_old.weight_unit, v_old.weight_source) THEN
    RETURN jsonb_build_object('parcel_id', v_old.id, 'row_version', v_old.row_version, 'unchanged', true);
  END IF;

  -- measured_by/at name who entered staff values; never set for profile values.
  IF coalesce(v_new.dimensions_source = 'staff', false) OR coalesce(v_new.weight_source = 'staff', false) THEN
    IF v_staff_set THEN
      v_new.measured_by := v_staff; v_new.measured_at := now();
    END IF;
  ELSE
    v_new.measured_by := NULL; v_new.measured_at := NULL;
  END IF;

  UPDATE us_booking.parcel
     SET length = v_new.length, width = v_new.width, height = v_new.height, dimension_unit = v_new.dimension_unit,
         dimensions_source = v_new.dimensions_source, weight = v_new.weight, weight_unit = v_new.weight_unit,
         weight_source = v_new.weight_source, measured_by = v_new.measured_by, measured_at = v_new.measured_at
   WHERE id = v_old.id
  RETURNING * INTO v_new;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('parcel', v_old.id, v_old.state, v_new.state, v_staff,
          jsonb_build_object('action', 'measurements', 'before', us_booking.parcel_snapshot(v_old),
                             'after', us_booking.parcel_snapshot(v_new)));
  PERFORM us_booking.parcel_requirements_refresh(v_old.fulfilment_group_id, v_staff);
  RETURN jsonb_build_object('parcel_id', v_new.id, 'row_version', v_new.row_version, 'unchanged', false);
END;
$$;

-- Replaces a parcel's contents. Payload: staff, parcel_id, expected_row_version,
-- items: [{oms_order_item_id, quantity}] (quantity 0 or a missing line = not in this parcel),
-- optional confirm: true to confirm the contents in the same step (the single-parcel workflow:
-- staff accept the proposed remaining items). Allocation limits are enforced by the existing
-- parcel_item trigger; a confirmed parcel must be unconfirmed first.
CREATE OR REPLACE FUNCTION us_booking.staff_parcel_set_contents(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff  text := us_booking.staff_actor(p);
  v_parcel us_booking.parcel%ROWTYPE := us_booking.staff_parcel_for_edit(p);
  v_before jsonb;
  v_after  jsonb;
  v_item   jsonb;
  v_iid    bigint;
  v_qty    integer;
  v_oid    bigint;
  v_cur    integer;
  v_want   jsonb := '{}'::jsonb;
  v_confirm boolean := coalesce((p->>'confirm')::boolean, false);
BEGIN
  IF jsonb_typeof(p->'items') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'items must be a list' USING ERRCODE = 'UB422';
  END IF;
  IF v_parcel.contents_status = 'confirmed' THEN
    RAISE EXCEPTION 'parcel % contents are confirmed; unconfirm them before changing them', v_parcel.parcel_no USING ERRCODE = 'UB409';
  END IF;
  FOR v_item IN SELECT x FROM jsonb_array_elements(p->'items') x LOOP
    v_iid := us_booking.staff_id(v_item, 'oms_order_item_id');
    IF coalesce(v_item->>'quantity', '') !~ '^[0-9]{1,6}$' THEN
      RAISE EXCEPTION 'quantity for order line % must be a whole number of 0 or more', v_iid USING ERRCODE = 'UB422';
    END IF;
    IF v_want ? v_iid::text THEN
      RAISE EXCEPTION 'order line % is listed twice', v_iid USING ERRCODE = 'UB422';
    END IF;
    v_want := v_want || jsonb_build_object(v_iid::text, (v_item->>'quantity')::integer);
  END LOOP;

  SELECT coalesce(jsonb_object_agg(oms_order_item_id::text, quantity), '{}'::jsonb) INTO v_before
    FROM us_booking.parcel_item WHERE parcel_id = v_parcel.id;

  -- Removals and reductions first, then additions, so units can move between lines in one save.
  FOR v_iid, v_cur IN SELECT oms_order_item_id, quantity FROM us_booking.parcel_item WHERE parcel_id = v_parcel.id LOOP
    v_qty := coalesce((v_want->>v_iid::text)::integer, 0);
    IF v_qty = 0 THEN
      DELETE FROM us_booking.parcel_item WHERE parcel_id = v_parcel.id AND oms_order_item_id = v_iid;
    ELSIF v_qty < v_cur THEN
      UPDATE us_booking.parcel_item SET quantity = v_qty WHERE parcel_id = v_parcel.id AND oms_order_item_id = v_iid;
    END IF;
  END LOOP;
  FOR v_iid, v_qty IN SELECT key::bigint, value::integer FROM jsonb_each_text(v_want) WHERE value::integer > 0 LOOP
    SELECT quantity INTO v_cur FROM us_booking.parcel_item WHERE parcel_id = v_parcel.id AND oms_order_item_id = v_iid;
    IF FOUND THEN
      IF v_qty > v_cur THEN
        UPDATE us_booking.parcel_item SET quantity = v_qty WHERE parcel_id = v_parcel.id AND oms_order_item_id = v_iid;
      END IF;
    ELSE
      SELECT oms_order_id INTO v_oid FROM us_booking.oms_order_item WHERE oms_order_item_id = v_iid;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'order line % not found', v_iid USING ERRCODE = 'UB404';
      END IF;
      INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity)
      VALUES (v_parcel.id, v_parcel.fulfilment_group_id, v_oid, v_iid, v_qty);
    END IF;
  END LOOP;

  SELECT coalesce(jsonb_object_agg(oms_order_item_id::text, quantity), '{}'::jsonb) INTO v_after
    FROM us_booking.parcel_item WHERE parcel_id = v_parcel.id;
  IF v_confirm THEN
    UPDATE us_booking.parcel SET contents_status = 'confirmed', confirmed_by = v_staff, confirmed_at = now()
     WHERE id = v_parcel.id RETURNING * INTO v_parcel;
  ELSE
    UPDATE us_booking.parcel SET updated_at = now() WHERE id = v_parcel.id RETURNING * INTO v_parcel;
  END IF;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('parcel', v_parcel.id, v_parcel.state, v_parcel.state, v_staff,
          jsonb_build_object('action', 'contents', 'before', v_before, 'after', v_after, 'confirmed', v_confirm));
  PERFORM us_booking.parcel_requirements_refresh(v_parcel.fulfilment_group_id, v_staff);
  RETURN jsonb_build_object('parcel_id', v_parcel.id, 'row_version', v_parcel.row_version, 'contents_status', v_parcel.contents_status);
END;
$$;

-- Confirms (confirmed: true) or unconfirms (false) a parcel's contents. Payload: staff, parcel_id,
-- expected_row_version, confirmed.
CREATE OR REPLACE FUNCTION us_booking.staff_parcel_confirm_contents(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff  text := us_booking.staff_actor(p);
  v_parcel us_booking.parcel%ROWTYPE := us_booking.staff_parcel_for_edit(p);
  v_want   boolean;
BEGIN
  IF jsonb_typeof(p->'confirmed') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'confirmed must be true or false' USING ERRCODE = 'UB422';
  END IF;
  v_want := (p->>'confirmed')::boolean;
  IF v_want = (v_parcel.contents_status = 'confirmed') THEN
    RETURN jsonb_build_object('parcel_id', v_parcel.id, 'row_version', v_parcel.row_version, 'unchanged', true);
  END IF;
  IF v_want THEN
    UPDATE us_booking.parcel SET contents_status = 'confirmed', confirmed_by = v_staff, confirmed_at = now()
     WHERE id = v_parcel.id RETURNING * INTO v_parcel;
  ELSE
    UPDATE us_booking.parcel SET contents_status = 'unconfirmed', confirmed_by = NULL, confirmed_at = NULL
     WHERE id = v_parcel.id RETURNING * INTO v_parcel;
  END IF;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('parcel', v_parcel.id, v_parcel.state, v_parcel.state, v_staff,
          jsonb_build_object('action', CASE WHEN v_want THEN 'contents_confirmed' ELSE 'contents_unconfirmed' END,
                             'items', (SELECT coalesce(jsonb_object_agg(oms_order_item_id::text, quantity), '{}'::jsonb)
                                         FROM us_booking.parcel_item WHERE parcel_id = v_parcel.id)));
  PERFORM us_booking.parcel_requirements_refresh(v_parcel.fulfilment_group_id, v_staff);
  RETURN jsonb_build_object('parcel_id', v_parcel.id, 'row_version', v_parcel.row_version, 'unchanged', false);
END;
$$;

-- Removes a draft parcel. A parcel that never had a booking attempt is deleted (its allocation is
-- released by the parcel_item trigger; the full row is kept in event_log); otherwise it is
-- cancelled, which the existing guard refuses while a purchase or label is live.
-- Payload: staff, parcel_id, expected_row_version.
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
  IF EXISTS (SELECT 1 FROM us_booking.booking_attempt WHERE parcel_id = v_parcel.id) THEN
    UPDATE us_booking.parcel SET state = 'cancelled' WHERE id = v_parcel.id;
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

-- ---------------------------------------------------------------------------------------------
-- Destination exceptions
-- ---------------------------------------------------------------------------------------------

-- Re-evaluates one order's destination and customs requirements (and scope / conflict findings)
-- exactly as the sync does, so a staff confirmation takes effect immediately. Uses the sync's
-- requirement writer, so staff-checked rows keep the same invalidation rules.
CREATE OR REPLACE FUNCTION us_booking.destination_requirements_refresh(p_order_id bigint, p_actor text)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  r     record;
  v_gid bigint;
BEGIN
  SELECT fulfilment_group_id INTO v_gid FROM us_booking.fulfilment_group_order WHERE oms_order_id = p_order_id AND active;
  IF v_gid IS NULL THEN
    RETURN;
  END IF;
  SELECT o.oms_order_id, o.oms_country_id, o.ship_address_hash, d.destination_iso2, d.destination_source INTO r
    FROM us_booking.oms_order o JOIN us_booking.v_order_destination d ON d.oms_order_id = o.oms_order_id
   WHERE o.oms_order_id = p_order_id;
  PERFORM us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'destination_country',
    CASE WHEN r.destination_iso2 IS NOT NULL THEN 'met' ELSE 'unmet' END,
    CASE WHEN r.destination_iso2 IS NOT NULL THEN 'destination ' || r.destination_iso2 || ' via ' || r.destination_source
         WHEN r.destination_source = 'conflict' THEN 'verified country map and order confirmation disagree'
         WHEN r.oms_country_id IS NULL THEN 'OMS has no country_id for this ship-to; needs staff confirmation'
         ELSE 'OMS country_id ' || r.oms_country_id || ' has no verified mapping and no valid staff confirmation' END,
    p_actor, r.ship_address_hash, false);
  PERFORM us_booking.oms_sync_set_requirement(v_gid, r.oms_order_id, 'customs_declaration',
    CASE WHEN r.destination_iso2 = 'CA' THEN 'unmet' WHEN r.destination_iso2 IS NULL THEN 'unmet' ELSE 'not_applicable' END,
    CASE WHEN r.destination_iso2 = 'CA' THEN 'Canada destination: customs declaration needed (contents description, value, origin; HS code where the service requires it)'
         WHEN r.destination_iso2 = 'US' THEN 'domestic US shipment: no customs declaration'
         WHEN r.destination_iso2 IS NULL THEN 'awaiting destination confirmation: a customs declaration applies only if the destination is Canada'
         ELSE 'destination is outside US/Canada scope' END,
    p_actor, coalesce(r.destination_iso2, '?') || ':' || r.ship_address_hash, false);
  IF r.destination_iso2 IS NOT NULL AND r.destination_iso2 NOT IN ('US', 'CA') THEN
    PERFORM us_booking.oms_sync_open_case('scope', r.oms_order_id, v_gid,
      jsonb_build_object('destination_iso2', r.destination_iso2, 'destination_source', r.destination_source),
      'destination:' || r.destination_iso2, p_actor, NULL);
  ELSIF r.destination_source = 'conflict' THEN
    PERFORM us_booking.oms_sync_open_case('destination_conflict', r.oms_order_id, v_gid,
      jsonb_build_object('oms_country_id', r.oms_country_id), 'conflict:' || coalesce(r.oms_country_id::text, ''), p_actor, NULL);
  END IF;
END;
$$;

-- Staff confirmation of one order's destination, for exceptions only: an order whose OMS country
-- id is missing or has no verified mapping. Orders resolved by the verified country map need no
-- confirmation and are refused here. Payload: staff, oms_order_id, iso2, evidence_type,
-- evidence_ref, expected_address_hash (the ship-to the screen showed).
CREATE OR REPLACE FUNCTION us_booking.staff_destination_confirm(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff text := us_booking.staff_actor(p);
  v_iso   text := upper(btrim(coalesce(p->>'iso2', '')));
  v_type  text := p->>'evidence_type';
  v_ref   text := us_booking.staff_text(p, 'evidence_ref', 'Evidence', 3, 500);
  v_order us_booking.oms_order%ROWTYPE;
  v_dest  record;
  v_id    bigint;
BEGIN
  IF v_iso !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'country must be a two-letter ISO code' USING ERRCODE = 'UB422';
  END IF;
  IF v_type IS NULL OR v_type NOT IN ('marketplace_order_record', 'customer_confirmation', 'carrier_address_validation', 'other') THEN
    RAISE EXCEPTION 'choose the kind of evidence' USING ERRCODE = 'UB422';
  END IF;
  SELECT * INTO v_order FROM us_booking.oms_order WHERE oms_order_id = us_booking.staff_id(p, 'oms_order_id') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'UB404';
  END IF;
  IF v_order.ship_address_hash IS DISTINCT FROM p->>'expected_address_hash' THEN
    RAISE EXCEPTION 'the ship-to address changed in the OMS since this order was loaded; reload and check again' USING ERRCODE = 'UB409';
  END IF;
  SELECT * INTO v_dest FROM us_booking.v_order_destination WHERE oms_order_id = v_order.oms_order_id;
  IF v_dest.destination_source = 'country_map' THEN
    RAISE EXCEPTION 'the destination is already resolved by the verified country map (OMS country_id %); no manual confirmation is needed',
      v_order.oms_country_id USING ERRCODE = 'UB409';
  ELSIF v_dest.destination_source IN ('order_confirmation', 'conflict') THEN
    RAISE EXCEPTION 'this order already has a valid confirmation; revoke it first if it is wrong' USING ERRCODE = 'UB409';
  END IF;
  -- An active confirmation for an earlier address no longer applies; keep it as revoked history.
  UPDATE us_booking.order_destination_confirmation
     SET status = 'revoked', revoked_by = v_staff, revoked_at = now(), revoke_reason = 'superseded: made for an earlier ship-to address'
   WHERE oms_order_id = v_order.oms_order_id AND status = 'active';
  INSERT INTO us_booking.order_destination_confirmation
    (oms_order_id, destination_iso2, evidence_type, evidence_ref, oms_country_id_seen, ship_address_hash, confirmed_by)
  VALUES (v_order.oms_order_id, v_iso, v_type, v_ref, v_order.oms_country_id, v_order.ship_address_hash, v_staff)
  RETURNING id INTO v_id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('order_destination_confirmation', v_id, NULL, 'active', v_staff,
          jsonb_build_object('oms_order_id', v_order.oms_order_id, 'destination_iso2', v_iso, 'evidence_type', v_type,
                             'evidence_ref', v_ref, 'oms_country_id_seen', v_order.oms_country_id));
  PERFORM us_booking.destination_requirements_refresh(v_order.oms_order_id, 'system:review-action');
  RETURN jsonb_build_object('confirmation_id', v_id, 'oms_order_id', v_order.oms_order_id, 'destination_iso2', v_iso);
END;
$$;

-- Revokes an active confirmation (kept as history). Payload: staff, confirmation_id, reason,
-- expected_address_hash.
CREATE OR REPLACE FUNCTION us_booking.staff_destination_revoke(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff  text := us_booking.staff_actor(p);
  v_reason text := us_booking.staff_text(p, 'reason', 'Reason', 3, 500);
  v_conf   us_booking.order_destination_confirmation%ROWTYPE;
  v_hash   text;
BEGIN
  SELECT * INTO v_conf FROM us_booking.order_destination_confirmation WHERE id = us_booking.staff_id(p, 'confirmation_id') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'confirmation not found' USING ERRCODE = 'UB404';
  END IF;
  SELECT ship_address_hash INTO v_hash FROM us_booking.oms_order WHERE oms_order_id = v_conf.oms_order_id FOR UPDATE;
  IF v_hash IS DISTINCT FROM p->>'expected_address_hash' THEN
    RAISE EXCEPTION 'the ship-to address changed in the OMS since this order was loaded; reload and check again' USING ERRCODE = 'UB409';
  END IF;
  IF v_conf.status <> 'active' THEN
    RAISE EXCEPTION 'this confirmation is already revoked' USING ERRCODE = 'UB409';
  END IF;
  UPDATE us_booking.order_destination_confirmation
     SET status = 'revoked', revoked_by = v_staff, revoked_at = now(), revoke_reason = v_reason
   WHERE id = v_conf.id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('order_destination_confirmation', v_conf.id, 'active', 'revoked', v_staff,
          jsonb_build_object('oms_order_id', v_conf.oms_order_id, 'destination_iso2', v_conf.destination_iso2, 'reason', v_reason));
  PERFORM us_booking.destination_requirements_refresh(v_conf.oms_order_id, 'system:review-action');
  RETURN jsonb_build_object('confirmation_id', v_conf.id, 'status', 'revoked');
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Review findings
-- ---------------------------------------------------------------------------------------------

-- Resolves or dismisses one open finding with staff identity and evidence. Only that case changes:
-- requirements, parcels and other findings are untouched. If the sync added evidence since the
-- screen loaded it (details changed), the action is refused. A later recurrence of the same
-- problem still opens a new case (0005). Payload: staff, case_id, outcome (resolved|dismissed),
-- evidence, expected_details_hash (md5 of the details the screen showed).
CREATE OR REPLACE FUNCTION us_booking.staff_case_close(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff    text := us_booking.staff_actor(p);
  v_outcome  text := p->>'outcome';
  v_evidence text := us_booking.staff_text(p, 'evidence', 'Evidence', 3, 1000);
  v_case     us_booking.review_case%ROWTYPE;
BEGIN
  IF v_outcome IS NULL OR v_outcome NOT IN ('resolved', 'dismissed') THEN
    RAISE EXCEPTION 'outcome must be resolved or dismissed' USING ERRCODE = 'UB422';
  END IF;
  SELECT * INTO v_case FROM us_booking.review_case WHERE id = us_booking.staff_id(p, 'case_id') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'finding not found' USING ERRCODE = 'UB404';
  END IF;
  IF v_case.status <> 'open' THEN
    RAISE EXCEPTION 'this finding is already %', v_case.status USING ERRCODE = 'UB409';
  END IF;
  IF md5(v_case.details::text) IS DISTINCT FROM p->>'expected_details_hash' THEN
    RAISE EXCEPTION 'this finding changed since it was loaded (new evidence from a sync); reload and review it again' USING ERRCODE = 'UB409';
  END IF;
  IF v_case.case_type IN ('booking_unknown', 'label_unretrievable', 'over_allocation') THEN
    RAISE EXCEPTION 'a % finding is closed by its own reconciliation step, not here', v_case.case_type USING ERRCODE = 'UB409';
  END IF;
  UPDATE us_booking.review_case
     SET status = v_outcome, resolved_by = v_staff, resolved_at = now(), resolution = v_evidence
   WHERE id = v_case.id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('review_case', v_case.id, 'open', v_outcome, v_staff,
          jsonb_build_object('case_type', v_case.case_type, 'oms_order_id', v_case.oms_order_id, 'evidence', v_evidence));
  RETURN jsonb_build_object('case_id', v_case.id, 'status', v_outcome);
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Failed sync runs
-- ---------------------------------------------------------------------------------------------

-- Records a failed sync in its own transaction (the import transaction was rolled back, taking its
-- 'running' row with it). Payload: started_at, error (already free of credentials and hosts),
-- stage, actor (system:<job>). Returns the sync_run id.
CREATE OR REPLACE FUNCTION us_booking.sync_record_failure(p jsonb)
RETURNS bigint LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_actor text := coalesce(p->>'actor', 'system:oms-sync');
  v_error text := left(coalesce(nullif(btrim(p->>'error'), ''), 'unknown error'), 1000);
  v_id    bigint;
BEGIN
  IF v_actor !~ '^system:' THEN
    RAISE EXCEPTION 'the sync actor must be system:<job>' USING ERRCODE = 'UB422';
  END IF;
  INSERT INTO us_booking.sync_state (stream) VALUES ('oms_orders') ON CONFLICT (stream) DO NOTHING;
  INSERT INTO us_booking.sync_run (stream, started_at, finished_at, status, error)
  VALUES ('oms_orders', coalesce((p->>'started_at')::timestamptz, now()), now(), 'failed', v_error)
  RETURNING id INTO v_id;
  UPDATE us_booking.sync_state SET last_error = v_error, updated_at = now() WHERE stream = 'oms_orders';
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('sync_run', v_id, NULL, 'failed', v_actor, jsonb_build_object('stage', p->>'stage', 'error', v_error));
  RETURN v_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION us_booking.staff_actor(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_id(jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_measure(jsonb, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_text(jsonb, text, text, integer, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_profile_save(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_profile_assign(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.parcel_requirements_refresh(bigint, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_for_edit(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.parcel_snapshot(us_booking.parcel) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_create(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_measure(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_set_contents(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_confirm_contents(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_parcel_remove(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.destination_requirements_refresh(bigint, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_destination_confirm(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_destination_revoke(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.staff_case_close(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.sync_record_failure(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.tg_parcel_provenance() FROM PUBLIC;
