-- 0010_wayfair_sandbox: records for the Wayfair SANDBOX integration, isolated from live booking.
--
-- The OMS stays the only source of orders for the live booking queue; nothing here imports orders.
-- These tables hold only sandbox registrations and sandbox labels, so a repeated or unknown
-- registration can be detected across server restarts. They have no foreign keys to, and are never
-- read by, the live tables (fulfilment_group, parcel, booking_attempt, provider_shipment, label_file,
-- shipment_requirement, routing_rule): sandbox success never changes live readiness, even when a
-- sandbox PO number happens to equal an OMS order reference.
--
-- No customer data is stored: only the PO number, ids, the request's package measurements (when
-- staff entered test measurements), tracking numbers and document availability returned by the
-- sandbox, and error text with credentials removed.

CREATE TABLE IF NOT EXISTS us_booking.wayfair_sandbox_registration (
  id                bigserial PRIMARY KEY,
  environment       text NOT NULL DEFAULT 'sandbox' CHECK (environment = 'sandbox'),
  po_number         text NOT NULL CHECK (po_number ~ '^[A-Za-z0-9_-]{1,40}$'),
  supplier_id       text,                           -- supplierId the PO was returned with
  warehouse_id      text,                           -- warehouseId sent (NULL = Wayfair default for the PO)
  -- requested: written and committed BEFORE the call, so a crash leaves a visible in-flight row.
  -- unknown:   the call was sent but no definitive answer arrived; never repeated automatically.
  state             text NOT NULL DEFAULT 'requested'
                    CHECK (state IN ('requested', 'succeeded', 'failed', 'unknown', 'found_existing', 'resolved_not_registered')),
  source            text NOT NULL DEFAULT 'register' CHECK (source IN ('register', 'lookup')),
  request_summary   jsonb NOT NULL DEFAULT '{}',    -- PO, warehouse, package units (test measurements only)
  response_summary  jsonb,                          -- event id, pickup date, tracking numbers, which document URLs exist
  error             text,
  requested_by      text NOT NULL CHECK (length(btrim(requested_by)) > 0),
  requested_at      timestamptz NOT NULL DEFAULT now(),
  completed_at      timestamptz,
  resolved_by       text,
  resolution        text,
  CHECK (state IN ('requested') OR completed_at IS NOT NULL),
  CHECK (state <> 'resolved_not_registered' OR (resolved_by IS NOT NULL AND resolution IS NOT NULL))
);
-- At most one live (not failed / not resolved-not-registered) registration record per sandbox PO.
CREATE UNIQUE INDEX IF NOT EXISTS wayfair_sandbox_registration_one_active
  ON us_booking.wayfair_sandbox_registration (po_number)
  WHERE state IN ('requested', 'succeeded', 'unknown', 'found_existing');

CREATE TABLE IF NOT EXISTS us_booking.wayfair_sandbox_label (
  id                bigserial PRIMARY KEY,
  registration_id   bigint NOT NULL REFERENCES us_booking.wayfair_sandbox_registration(id),
  po_number         text NOT NULL,
  content_type      text NOT NULL,
  file_name         text NOT NULL,                  -- under LABEL_STORAGE_DIR/wayfair-sandbox/
  size_bytes        integer NOT NULL CHECK (size_bytes > 0),
  sha256            text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  fetched_by        text NOT NULL,
  fetched_at        timestamptz NOT NULL DEFAULT now()
);

-- Records are history: labels are never updated or deleted; registrations change state only.
CREATE OR REPLACE TRIGGER wayfair_sandbox_label_append_only
  BEFORE UPDATE OR DELETE ON us_booking.wayfair_sandbox_label
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_append_only();
CREATE OR REPLACE TRIGGER wayfair_sandbox_registration_no_delete
  BEFORE DELETE ON us_booking.wayfair_sandbox_registration
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_append_only();

-- Allowed state changes. 'unknown' leaves only through a staff resolution with evidence.
CREATE OR REPLACE FUNCTION us_booking.tg_wayfair_sandbox_registration_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF (NEW.id, NEW.po_number, NEW.environment, NEW.requested_by, NEW.requested_at, NEW.source)
     IS DISTINCT FROM (OLD.id, OLD.po_number, OLD.environment, OLD.requested_by, OLD.requested_at, OLD.source) THEN
    RAISE EXCEPTION 'sandbox registration % identity is immutable', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.state IS DISTINCT FROM OLD.state
     AND (OLD.state, NEW.state) NOT IN (('requested', 'succeeded'), ('requested', 'failed'), ('requested', 'unknown'),
                                       ('unknown', 'found_existing'), ('unknown', 'resolved_not_registered')) THEN
    RAISE EXCEPTION 'sandbox registration % cannot move from % to %', OLD.id, OLD.state, NEW.state USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER wayfair_sandbox_registration_update
  BEFORE UPDATE ON us_booking.wayfair_sandbox_registration
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_wayfair_sandbox_registration_update();

REVOKE EXECUTE ON FUNCTION us_booking.tg_wayfair_sandbox_registration_update() FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------
-- Write functions used by the web server (src/server/wayfair). Errors use the UB4xx codes of 0008.
-- ---------------------------------------------------------------------------------------------

-- Starts a sandbox registration: refuses if the PO already has a requested, succeeded, unknown or
-- found-existing record. Payload: staff, po_number, supplier_id, warehouse_id, request_summary.
CREATE OR REPLACE FUNCTION us_booking.wayfair_sandbox_begin(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff text := us_booking.staff_actor(p);
  v_po    text := btrim(coalesce(p->>'po_number', ''));
  v_row   us_booking.wayfair_sandbox_registration%ROWTYPE;
BEGIN
  IF v_po !~ '^[A-Za-z0-9_-]{1,40}$' THEN
    RAISE EXCEPTION 'invalid PO number' USING ERRCODE = 'UB422';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('wayfair_sandbox:' || v_po));
  SELECT * INTO v_row FROM us_booking.wayfair_sandbox_registration
   WHERE po_number = v_po AND state IN ('requested', 'succeeded', 'unknown', 'found_existing');
  IF FOUND THEN
    RAISE EXCEPTION 'sandbox PO % already has a % registration record (#%); it is not registered again', v_po, v_row.state, v_row.id
      USING ERRCODE = 'UB409';
  END IF;
  INSERT INTO us_booking.wayfair_sandbox_registration (po_number, supplier_id, warehouse_id, request_summary, requested_by)
  VALUES (v_po, nullif(p->>'supplier_id', ''), nullif(p->>'warehouse_id', ''), coalesce(p->'request_summary', '{}'), v_staff)
  RETURNING * INTO v_row;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('wayfair_sandbox_registration', v_row.id, NULL, 'requested', v_staff,
          jsonb_build_object('po_number', v_po, 'environment', 'sandbox'));
  RETURN jsonb_build_object('id', v_row.id);
END;
$$;

-- Records the outcome of a sandbox registration call. Payload: id, state (succeeded|failed|unknown),
-- response_summary, error, actor.
CREATE OR REPLACE FUNCTION us_booking.wayfair_sandbox_finish(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_row us_booking.wayfair_sandbox_registration%ROWTYPE;
BEGIN
  IF coalesce(p->>'state', '') NOT IN ('succeeded', 'failed', 'unknown') THEN
    RAISE EXCEPTION 'invalid outcome' USING ERRCODE = 'UB422';
  END IF;
  UPDATE us_booking.wayfair_sandbox_registration
     SET state = p->>'state', response_summary = p->'response_summary', error = left(p->>'error', 1000), completed_at = now()
   WHERE id = us_booking.staff_id(p, 'id') AND state = 'requested'
  RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sandbox registration is not in flight' USING ERRCODE = 'UB409';
  END IF;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('wayfair_sandbox_registration', v_row.id, 'requested', v_row.state, coalesce(p->>'actor', v_row.requested_by),
          jsonb_build_object('po_number', v_row.po_number, 'error', v_row.error));
  RETURN jsonb_build_object('id', v_row.id, 'state', v_row.state);
END;
$$;

-- Records that a lookup found an existing Wayfair registration for a sandbox PO that has no
-- record here (so it is not registered again). Payload: staff, po_number, supplier_id, response_summary.
CREATE OR REPLACE FUNCTION us_booking.wayfair_sandbox_record_existing(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff text := us_booking.staff_actor(p);
  v_po    text := btrim(coalesce(p->>'po_number', ''));
  v_id    bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('wayfair_sandbox:' || v_po));
  IF EXISTS (SELECT 1 FROM us_booking.wayfair_sandbox_registration
              WHERE po_number = v_po AND state IN ('requested', 'succeeded', 'unknown', 'found_existing')) THEN
    RETURN jsonb_build_object('recorded', false);
  END IF;
  INSERT INTO us_booking.wayfair_sandbox_registration (po_number, supplier_id, state, source, response_summary, requested_by, completed_at)
  VALUES (v_po, nullif(p->>'supplier_id', ''), 'found_existing', 'lookup', p->'response_summary', v_staff, now())
  RETURNING id INTO v_id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('wayfair_sandbox_registration', v_id, NULL, 'found_existing', v_staff, jsonb_build_object('po_number', v_po));
  RETURN jsonb_build_object('recorded', true, 'id', v_id);
END;
$$;

-- Staff resolution of a registration whose outcome is unknown, with evidence. Payload: staff, id,
-- outcome (found_existing|resolved_not_registered), evidence.
CREATE OR REPLACE FUNCTION us_booking.wayfair_sandbox_resolve(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff    text := us_booking.staff_actor(p);
  v_evidence text := us_booking.staff_text(p, 'evidence', 'Evidence', 3, 1000);
  v_row      us_booking.wayfair_sandbox_registration%ROWTYPE;
BEGIN
  IF coalesce(p->>'outcome', '') NOT IN ('found_existing', 'resolved_not_registered') THEN
    RAISE EXCEPTION 'outcome must be found_existing or resolved_not_registered' USING ERRCODE = 'UB422';
  END IF;
  UPDATE us_booking.wayfair_sandbox_registration
     SET state = p->>'outcome', resolved_by = v_staff, resolution = v_evidence
   WHERE id = us_booking.staff_id(p, 'id') AND state = 'unknown'
  RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'only a registration with an unknown outcome can be resolved' USING ERRCODE = 'UB409';
  END IF;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('wayfair_sandbox_registration', v_row.id, 'unknown', v_row.state, v_staff,
          jsonb_build_object('po_number', v_row.po_number, 'evidence', v_evidence));
  RETURN jsonb_build_object('id', v_row.id, 'state', v_row.state);
END;
$$;

-- Records a downloaded sandbox label file. Payload: staff, registration_id, content_type, file_name,
-- size_bytes, sha256. The registration must be succeeded or found_existing.
CREATE OR REPLACE FUNCTION us_booking.wayfair_sandbox_label_add(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff text := us_booking.staff_actor(p);
  v_reg   us_booking.wayfair_sandbox_registration%ROWTYPE;
  v_id    bigint;
BEGIN
  SELECT * INTO v_reg FROM us_booking.wayfair_sandbox_registration WHERE id = us_booking.staff_id(p, 'registration_id');
  IF NOT FOUND OR v_reg.state NOT IN ('succeeded', 'found_existing') THEN
    RAISE EXCEPTION 'labels can be stored only for a registered sandbox PO' USING ERRCODE = 'UB409';
  END IF;
  INSERT INTO us_booking.wayfair_sandbox_label (registration_id, po_number, content_type, file_name, size_bytes, sha256, fetched_by)
  VALUES (v_reg.id, v_reg.po_number, p->>'content_type', p->>'file_name', (p->>'size_bytes')::int, p->>'sha256', v_staff)
  RETURNING id INTO v_id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('wayfair_sandbox_label', v_id, NULL, 'stored', v_staff,
          jsonb_build_object('po_number', v_reg.po_number, 'sha256', p->>'sha256', 'content_type', p->>'content_type'));
  RETURN jsonb_build_object('id', v_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION us_booking.wayfair_sandbox_begin(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.wayfair_sandbox_finish(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.wayfair_sandbox_record_existing(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.wayfair_sandbox_resolve(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.wayfair_sandbox_label_add(jsonb) FROM PUBLIC;
