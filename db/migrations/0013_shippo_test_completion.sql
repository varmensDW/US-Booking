-- 0013_shippo_test_completion: closes gaps found while reviewing the first real Shippo TEST
-- purchases against this app (2026-10-24).
--
-- 1. Carrier/service/rate/carrier-account were never copied from the staff-selected rate into the
--    attempt's own columns on success; a bug in src/server/shippo/service.ts hardcoded them to
--    NULL. Fixed there; this migration backfills the existing rows from their own already-saved
--    rate_summary (authoritative: it is Shippo's own rates-response data for the exact rate
--    purchased) and adds carrier_account_id, which rate_summary did not capture before this fix.
--    Nothing is guessed from the tracking number.
-- 2. A test shipment that already has a succeeded or staff-confirmed purchase can no longer start
--    another purchase: the one-blocking-purchase rule (0012) only covered requested/unknown. A
--    failed, rejected-not-test or resolved-not-purchased outcome still allows a retry; nothing
--    here changes that.
-- 3. shippo_test_purchase gets commercial_invoice_source_url (Shippo's commercial_invoice_url for
--    an international TEST transaction, when returned) and shippo_test_label gets a `kind` column
--    so a customs invoice can be stored alongside the label for the same purchase, not confused
--    with it.
-- 4. A singleton shippo_test_settings row holds the print label format to request on FUTURE
--    purchases only (shippo_test_purchase_finish and existing labels are never touched by a
--    change here). NULL (the starting value) means: send no label_file_type at all, so Shippo
--    uses whatever format is set as the account default in its own dashboard -- this app does not
--    assume a thermal printer or any specific paper size.

ALTER TABLE us_booking.shippo_test_purchase ADD COLUMN IF NOT EXISTS carrier_account_id text;
ALTER TABLE us_booking.shippo_test_purchase ADD COLUMN IF NOT EXISTS commercial_invoice_source_url text;

-- Deterministic, idempotent backfill from each row's own saved rate_summary (no network call, no
-- guess from tracking_number). Only fills rows that are missing it; running this again is a no-op.
UPDATE us_booking.shippo_test_purchase
   SET carrier = rate_summary->>'carrier',
       service_level = rate_summary->>'service',
       amount = nullif(rate_summary->>'amount', '')::numeric,
       currency = rate_summary->>'currency'
 WHERE carrier IS NULL AND rate_summary ? 'carrier' AND rate_summary->>'carrier' IS NOT NULL;

-- Widen the one-blocking-purchase rule to also cover a completed purchase: once a test shipment
-- has a succeeded or staff-confirmed purchase, it is done and is not purchased again. A failed,
-- rejected-not-test or resolved-not-purchased outcome is still retryable.
DROP INDEX IF EXISTS us_booking.shippo_test_purchase_one_blocking_per_shipment;
CREATE UNIQUE INDEX IF NOT EXISTS shippo_test_purchase_one_per_shipment
  ON us_booking.shippo_test_purchase (shipment_id)
  WHERE state IN ('requested', 'unknown', 'succeeded', 'confirmed_purchased');

-- Replaces 0012's shippo_test_purchase_begin: the pre-check (which gives a readable error instead
-- of a raw unique-violation) now matches the widened index above.
CREATE OR REPLACE FUNCTION us_booking.shippo_test_purchase_begin(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff   text := us_booking.staff_actor(p);
  v_ship_id bigint := us_booking.staff_id(p, 'shipment_id');
  v_rate    text := btrim(coalesce(p->>'rate_object_id', ''));
  v_n       integer;
  v_key     text;
  v_row     us_booking.shippo_test_purchase%ROWTYPE;
BEGIN
  IF v_rate = '' THEN
    RAISE EXCEPTION 'a rate must be selected' USING ERRCODE = 'UB422';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM us_booking.shippo_test_shipment WHERE id = v_ship_id) THEN
    RAISE EXCEPTION 'Shippo test shipment not found' USING ERRCODE = 'UB404';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('shippo_test_purchase:' || v_ship_id::text));
  SELECT * INTO v_row FROM us_booking.shippo_test_purchase
   WHERE shipment_id = v_ship_id AND state IN ('requested', 'unknown', 'succeeded', 'confirmed_purchased');
  IF FOUND AND v_row.state IN ('succeeded', 'confirmed_purchased') THEN
    RAISE EXCEPTION 'this test shipment already has a purchased label (#%); it is not purchased again', v_row.id USING ERRCODE = 'UB409';
  END IF;
  IF FOUND THEN
    RAISE EXCEPTION 'this test shipment already has a % purchase (#%); it is not purchased again until that is resolved', v_row.state, v_row.id
      USING ERRCODE = 'UB409';
  END IF;
  SELECT count(*) INTO v_n FROM us_booking.shippo_test_purchase WHERE shipment_id = v_ship_id;
  v_key := 'ust:' || v_ship_id::text || ':p' || (v_n + 1)::text;
  INSERT INTO us_booking.shippo_test_purchase (shipment_id, rate_object_id, rate_summary, correlation_key, requested_by)
  VALUES (v_ship_id, v_rate, coalesce(p->'rate_summary', '{}'), v_key, v_staff)
  RETURNING * INTO v_row;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('shippo_test_purchase', v_row.id, NULL, 'requested', v_staff,
          jsonb_build_object('shipment_id', v_ship_id, 'rate_object_id', v_rate, 'correlation_key', v_key));
  RETURN jsonb_build_object('id', v_row.id, 'correlation_key', v_key);
END;
$$;
REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_purchase_begin(jsonb) FROM PUBLIC;

ALTER TABLE us_booking.shippo_test_label ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'label';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'us_booking.shippo_test_label'::regclass AND conname = 'shippo_test_label_kind_check') THEN
    ALTER TABLE us_booking.shippo_test_label ADD CONSTRAINT shippo_test_label_kind_check CHECK (kind IN ('label', 'customs_invoice'));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS us_booking.shippo_test_settings (
  id              smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),   -- singleton row
  label_file_type text CHECK (label_file_type IN ('PNG', 'PNG_2.3x7.5', 'PDF', 'PDF_2.3x7.5', 'PDF_4x6', 'PDF_4x8',
                                                   'PDF_A4', 'PDF_A5', 'PDF_A6', 'ZPLII')),
  updated_by      text,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
INSERT INTO us_booking.shippo_test_settings (id, label_file_type) VALUES (1, NULL) ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------------------------
-- Write functions used by the web server (src/server/shippo). Errors use the UB4xx codes of 0008.
-- ---------------------------------------------------------------------------------------------

-- Replaces 0012's shippo_test_purchase_finish: also stores carrier_account_id and
-- commercial_invoice_source_url (new columns above). Everything else is unchanged.
CREATE OR REPLACE FUNCTION us_booking.shippo_test_purchase_finish(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_row   us_booking.shippo_test_purchase%ROWTYPE;
  v_state text := coalesce(p->>'state', '');
BEGIN
  IF v_state NOT IN ('succeeded', 'failed', 'unknown', 'rejected_not_test') THEN
    RAISE EXCEPTION 'invalid outcome' USING ERRCODE = 'UB422';
  END IF;
  IF v_state = 'succeeded' AND coalesce((p->>'test_mode')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'a purchase can be recorded as succeeded only when Shippo marked the transaction test mode' USING ERRCODE = 'UB422';
  END IF;
  UPDATE us_booking.shippo_test_purchase
     SET state = v_state, provider_transaction_id = p->>'provider_transaction_id', test_mode = (p->>'test_mode')::boolean,
         tracking_number = p->>'tracking_number', carrier = p->>'carrier', service_level = p->>'service_level',
         carrier_account_id = p->>'carrier_account_id', amount = nullif(p->>'amount', '')::numeric, currency = p->>'currency',
         label_source_url = p->>'label_source_url', commercial_invoice_source_url = p->>'commercial_invoice_source_url',
         error = left(p->>'error', 1000), completed_at = now()
   WHERE id = us_booking.staff_id(p, 'id') AND state = 'requested'
  RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shippo test purchase is not in flight' USING ERRCODE = 'UB409';
  END IF;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('shippo_test_purchase', v_row.id, 'requested', v_row.state, coalesce(p->>'actor', v_row.requested_by),
          jsonb_build_object('shipment_id', v_row.shipment_id, 'provider_transaction_id', v_row.provider_transaction_id, 'error', v_row.error));
  RETURN jsonb_build_object('id', v_row.id, 'state', v_row.state);
END;
$$;
REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_purchase_finish(jsonb) FROM PUBLIC;

-- Replaces 0012's shippo_test_label_add: accepts an optional `kind` ('label' default |
-- 'customs_invoice'), so a customs document can be stored alongside the label for the same
-- purchase without being confused with it. Everything else is unchanged.
CREATE OR REPLACE FUNCTION us_booking.shippo_test_label_add(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff text := us_booking.staff_actor(p);
  v_pur   us_booking.shippo_test_purchase%ROWTYPE;
  v_kind  text := coalesce(nullif(p->>'kind', ''), 'label');
  v_id    bigint;
BEGIN
  IF v_kind NOT IN ('label', 'customs_invoice') THEN
    RAISE EXCEPTION 'invalid label kind' USING ERRCODE = 'UB422';
  END IF;
  SELECT * INTO v_pur FROM us_booking.shippo_test_purchase WHERE id = us_booking.staff_id(p, 'purchase_id');
  IF NOT FOUND OR v_pur.state NOT IN ('succeeded', 'confirmed_purchased') THEN
    RAISE EXCEPTION 'a label can be stored only for a succeeded or staff-confirmed test purchase' USING ERRCODE = 'UB409';
  END IF;
  INSERT INTO us_booking.shippo_test_label (purchase_id, content_type, file_name, size_bytes, sha256, source_url, kind, fetched_by)
  VALUES (v_pur.id, p->>'content_type', p->>'file_name', (p->>'size_bytes')::int, p->>'sha256', p->>'source_url', v_kind, v_staff)
  RETURNING id INTO v_id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('shippo_test_label', v_id, NULL, 'stored', v_staff, jsonb_build_object('purchase_id', v_pur.id, 'sha256', p->>'sha256', 'kind', v_kind));
  RETURN jsonb_build_object('id', v_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_label_add(jsonb) FROM PUBLIC;

-- Fills in carrier/service/carrier_account/amount/currency on a COMPLETED purchase (completed_at
-- already set; the purchase's state and every other column are untouched) ONLY where the column is
-- currently NULL -- it never overwrites a value already recorded, and never changes outcome.
-- Payload: staff, id, carrier, service_level, carrier_account_id, amount, currency.
CREATE OR REPLACE FUNCTION us_booking.shippo_test_purchase_recover_details(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff text := us_booking.staff_actor(p);
  v_row   us_booking.shippo_test_purchase%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM us_booking.shippo_test_purchase WHERE id = us_booking.staff_id(p, 'id');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shippo test purchase not found' USING ERRCODE = 'UB404';
  END IF;
  IF v_row.completed_at IS NULL THEN
    RAISE EXCEPTION 'details can be recovered only for a purchase that has already completed' USING ERRCODE = 'UB409';
  END IF;
  UPDATE us_booking.shippo_test_purchase SET
    carrier = coalesce(carrier, nullif(p->>'carrier', '')),
    service_level = coalesce(service_level, nullif(p->>'service_level', '')),
    carrier_account_id = coalesce(carrier_account_id, nullif(p->>'carrier_account_id', '')),
    amount = coalesce(amount, nullif(p->>'amount', '')::numeric),
    currency = coalesce(currency, nullif(p->>'currency', ''))
   WHERE id = v_row.id
  RETURNING * INTO v_row;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('shippo_test_purchase', v_row.id, v_row.state, v_row.state, v_staff,
          jsonb_build_object('action', 'recover_details', 'carrier', v_row.carrier, 'carrier_account_id', v_row.carrier_account_id));
  RETURN jsonb_build_object('id', v_row.id, 'carrier', v_row.carrier, 'service_level', v_row.service_level,
                            'carrier_account_id', v_row.carrier_account_id, 'amount', v_row.amount, 'currency', v_row.currency);
END;
$$;

-- Sets the label format requested on FUTURE purchases only. Payload: staff, label_file_type
-- (absent or empty = clear it, so no label_file_type is sent and Shippo's dashboard default applies).
CREATE OR REPLACE FUNCTION us_booking.shippo_test_set_label_format(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff  text := us_booking.staff_actor(p);
  v_format text := nullif(btrim(coalesce(p->>'label_file_type', '')), '');
BEGIN
  IF v_format IS NOT NULL AND v_format NOT IN ('PNG', 'PNG_2.3x7.5', 'PDF', 'PDF_2.3x7.5', 'PDF_4x6', 'PDF_4x8',
                                               'PDF_A4', 'PDF_A5', 'PDF_A6', 'ZPLII') THEN
    RAISE EXCEPTION 'unsupported label format' USING ERRCODE = 'UB422';
  END IF;
  UPDATE us_booking.shippo_test_settings SET label_file_type = v_format, updated_by = v_staff, updated_at = now() WHERE id = 1;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('shippo_test_settings', 1, NULL, NULL, v_staff, jsonb_build_object('action', 'set_label_format', 'label_file_type', v_format));
  RETURN jsonb_build_object('label_file_type', v_format);
END;
$$;

REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_purchase_recover_details(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_set_label_format(jsonb) FROM PUBLIC;
