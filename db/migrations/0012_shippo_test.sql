-- 0012_shippo_test: records for Shippo TEST-mode rate shopping and label purchase (Shopify/eBay,
-- provider = 'shippo'), isolated from live booking exactly as 0010 isolates the Wayfair sandbox.
--
-- The OMS stays the only source of orders: nothing here creates or updates a fulfilment_group,
-- parcel, booking_attempt, provider_shipment or label_file, and nothing here is read by any of
-- them. Recipient data is synthetic test data staff type in for this test only; no OMS customer
-- data is read or sent. src/server/shippo/config.ts refuses to call Shippo unless SHIPPO_MODE=test
-- and SHIPPO_API_TOKEN starts with shippo_test_ (Shippo's documented test-token prefix,
-- docs.goshippo.com/guides/authentication, read 2026-10-23); ENABLE_LIVE_BOOKING is not read by
-- this feature and this migration enables no live calls.
--
-- Three tables:
--   shippo_test_shipment  one row per rate-shopping call (ship-from snapshot, synthetic ship-to,
--                         parcel used, customs sent if any, the rates and messages Shippo
--                         returned). Fully append-only: a new rate request is a new row.
--   shippo_test_purchase  one row per attempt to buy a label for a staff-selected rate (never the
--                         cheapest automatically). Committed in state 'requested' BEFORE the
--                         provider is called, so a crash mid-call leaves a visible in-flight row.
--                         A unique index allows at most one requested/unknown purchase per
--                         shipment at a time: blocks duplicate clicks and concurrent purchases.
--                         'succeeded' requires the provider's own test-mode marker (Shippo
--                         Transaction.test = true); an outcome that cannot be read with confidence
--                         (timeout, HTTP 5xx, an unexpected response) is 'unknown' and is never
--                         retried automatically until a staff member resolves it with evidence,
--                         the same rule 0010 applies to Wayfair sandbox registrations.
--   shippo_test_label     the original label file Shippo returned for a succeeded or
--                         staff-confirmed purchase, downloaded and hashed once. Reopening,
--                         previewing or reprinting reuses this stored file; it never buys another
--                         label and never calls Shippo again.

CREATE TABLE IF NOT EXISTS us_booking.shippo_test_shipment (
  id                    bigserial PRIMARY KEY,
  environment           text NOT NULL DEFAULT 'test' CHECK (environment = 'test'),
  ship_from             jsonb NOT NULL,   -- snapshot of the explicitly configured ship-from address (SHIPPO_SHIP_FROM_*) at request time
  ship_to               jsonb NOT NULL,   -- synthetic recipient staff entered for this test only; never OMS customer data
  destination_country   text NOT NULL CHECK (destination_country ~ '^[A-Z]{2}$'),
  parcel                jsonb NOT NULL,   -- length/width/height/dimension_unit/weight/weight_unit used for this test (may differ from the saved profile)
  customs               jsonb,            -- customs declaration sent to Shippo, when the destination required one; NULL otherwise
  provider_shipment_id  text,             -- Shippo's shipment object_id
  rates                 jsonb NOT NULL DEFAULT '[]',  -- rates Shippo returned: carrier, service, amount, currency, estimated_days, duration_terms, rate id
  messages              jsonb NOT NULL DEFAULT '[]',  -- per-carrier messages/errors Shippo returned alongside the rates
  requested_by          text NOT NULL CHECK (length(btrim(requested_by)) > 0),
  requested_at          timestamptz NOT NULL DEFAULT now()
);
-- History: a rate-shopping record is never edited; requesting again creates a new row.
CREATE OR REPLACE TRIGGER shippo_test_shipment_append_only
  BEFORE UPDATE OR DELETE ON us_booking.shippo_test_shipment
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_append_only();

CREATE TABLE IF NOT EXISTS us_booking.shippo_test_purchase (
  id                      bigserial PRIMARY KEY,
  shipment_id             bigint NOT NULL REFERENCES us_booking.shippo_test_shipment(id),
  rate_object_id          text NOT NULL CHECK (length(btrim(rate_object_id)) > 0),
  rate_summary            jsonb NOT NULL,    -- carrier/service/amount/currency staff saw when explicitly selecting this rate
  correlation_key         text NOT NULL UNIQUE,  -- 'ust:<shipment_id>:p<n>', sent to Shippo as metadata so a purchase can be found later
  state                   text NOT NULL DEFAULT 'requested'
                          CHECK (state IN ('requested', 'succeeded', 'failed', 'unknown', 'rejected_not_test',
                                           'confirmed_purchased', 'resolved_not_purchased')),
  provider_transaction_id text,        -- Shippo transaction object_id; kept even when the outcome is unknown or rejected, for reconciliation
  test_mode               boolean,     -- Shippo Transaction.test as returned; 'succeeded' requires this to be true
  tracking_number         text,
  carrier                 text,
  service_level           text,
  amount                  numeric(10,2),
  currency                char(3),
  label_source_url        text,        -- Shippo's returned label_url, kept so a label can be fetched without buying again
  error                   text,
  requested_by            text NOT NULL CHECK (length(btrim(requested_by)) > 0),
  requested_at            timestamptz NOT NULL DEFAULT now(),
  completed_at            timestamptz,
  resolved_by             text,
  resolution              text,
  CHECK (state = 'requested' OR completed_at IS NOT NULL),
  CHECK (state NOT IN ('confirmed_purchased', 'resolved_not_purchased') OR (resolved_by IS NOT NULL AND resolution IS NOT NULL)),
  CHECK (state <> 'succeeded' OR test_mode IS TRUE)
);
-- At most one in-flight purchase per rate-shopping record: blocks duplicate clicks and concurrent
-- purchases for the same test shipment (mirrors booking_attempt_one_blocking_per_parcel, 0001).
CREATE UNIQUE INDEX IF NOT EXISTS shippo_test_purchase_one_blocking_per_shipment
  ON us_booking.shippo_test_purchase (shipment_id)
  WHERE state IN ('requested', 'unknown');

CREATE OR REPLACE TRIGGER shippo_test_purchase_no_delete
  BEFORE DELETE ON us_booking.shippo_test_purchase
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_append_only();

-- Allowed state changes. 'unknown' leaves only through a staff resolution with evidence, exactly
-- as 0010 requires for a Wayfair sandbox registration of unknown outcome.
CREATE OR REPLACE FUNCTION us_booking.tg_shippo_test_purchase_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF (NEW.id, NEW.shipment_id, NEW.rate_object_id, NEW.correlation_key, NEW.requested_by, NEW.requested_at)
     IS DISTINCT FROM (OLD.id, OLD.shipment_id, OLD.rate_object_id, OLD.correlation_key, OLD.requested_by, OLD.requested_at) THEN
    RAISE EXCEPTION 'Shippo test purchase % identity is immutable', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.state IS DISTINCT FROM OLD.state
     AND (OLD.state, NEW.state) NOT IN (('requested', 'succeeded'), ('requested', 'failed'), ('requested', 'unknown'), ('requested', 'rejected_not_test'),
                                       ('unknown', 'confirmed_purchased'), ('unknown', 'resolved_not_purchased')) THEN
    RAISE EXCEPTION 'Shippo test purchase % cannot move from % to %', OLD.id, OLD.state, NEW.state USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER shippo_test_purchase_update
  BEFORE UPDATE ON us_booking.shippo_test_purchase
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_shippo_test_purchase_update();

REVOKE EXECUTE ON FUNCTION us_booking.tg_shippo_test_purchase_update() FROM PUBLIC;

CREATE TABLE IF NOT EXISTS us_booking.shippo_test_label (
  id              bigserial PRIMARY KEY,
  purchase_id     bigint NOT NULL REFERENCES us_booking.shippo_test_purchase(id),
  content_type    text NOT NULL,
  file_name       text NOT NULL,                  -- under LABEL_STORAGE_DIR/shippo-test/
  size_bytes      integer NOT NULL CHECK (size_bytes > 0),
  sha256          text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  source_url      text,                           -- the Shippo label_url this copy was downloaded from, for the record only
  fetched_by      text NOT NULL CHECK (length(btrim(fetched_by)) > 0),
  fetched_at      timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE TRIGGER shippo_test_label_append_only
  BEFORE UPDATE OR DELETE ON us_booking.shippo_test_label
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_append_only();

-- ---------------------------------------------------------------------------------------------
-- Write functions used by the web server (src/server/shippo). Errors use the UB4xx codes of 0008.
-- ---------------------------------------------------------------------------------------------

-- Records one rate-shopping call after Shippo has answered. Payload: staff, ship_from, ship_to,
-- destination_country, parcel, customs, provider_shipment_id, rates, messages.
CREATE OR REPLACE FUNCTION us_booking.shippo_test_shipment_add(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff text := us_booking.staff_actor(p);
  v_dest  text := upper(btrim(coalesce(p->>'destination_country', '')));
  v_id    bigint;
BEGIN
  IF v_dest !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'destination_country must be a two-letter ISO code' USING ERRCODE = 'UB422';
  END IF;
  INSERT INTO us_booking.shippo_test_shipment (ship_from, ship_to, destination_country, parcel, customs, provider_shipment_id, rates, messages, requested_by)
  VALUES (coalesce(p->'ship_from', '{}'), coalesce(p->'ship_to', '{}'), v_dest, coalesce(p->'parcel', '{}'), p->'customs',
          p->>'provider_shipment_id', coalesce(p->'rates', '[]'), coalesce(p->'messages', '[]'), v_staff)
  RETURNING id INTO v_id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('shippo_test_shipment', v_id, NULL, 'rated', v_staff,
          jsonb_build_object('destination_country', v_dest, 'rate_count', jsonb_array_length(coalesce(p->'rates', '[]'))));
  RETURN jsonb_build_object('id', v_id);
END;
$$;

-- Starts a label purchase for one staff-selected rate: refuses if the shipment already has a
-- requested or unknown purchase in flight. Payload: staff, shipment_id, rate_object_id, rate_summary.
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
  SELECT * INTO v_row FROM us_booking.shippo_test_purchase WHERE shipment_id = v_ship_id AND state IN ('requested', 'unknown');
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

-- Records the outcome of a purchase call. Payload: id, state (succeeded|failed|unknown|rejected_not_test),
-- provider_transaction_id, test_mode, tracking_number, carrier, service_level, amount, currency,
-- label_source_url, error, actor. 'succeeded' is refused unless test_mode is true: the server must
-- have confirmed the transaction belongs to Shippo's test mode before calling this.
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
         amount = nullif(p->>'amount', '')::numeric, currency = p->>'currency', label_source_url = p->>'label_source_url',
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

-- Staff resolution of a purchase whose outcome is unknown, with evidence (Shippo dashboard or
-- support confirming whether it was actually purchased). Payload: staff, id, outcome
-- (confirmed_purchased|resolved_not_purchased), evidence.
CREATE OR REPLACE FUNCTION us_booking.shippo_test_purchase_resolve(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff    text := us_booking.staff_actor(p);
  v_evidence text := us_booking.staff_text(p, 'evidence', 'Evidence', 3, 1000);
  v_row      us_booking.shippo_test_purchase%ROWTYPE;
BEGIN
  IF coalesce(p->>'outcome', '') NOT IN ('confirmed_purchased', 'resolved_not_purchased') THEN
    RAISE EXCEPTION 'outcome must be confirmed_purchased or resolved_not_purchased' USING ERRCODE = 'UB422';
  END IF;
  UPDATE us_booking.shippo_test_purchase
     SET state = p->>'outcome', resolved_by = v_staff, resolution = v_evidence
   WHERE id = us_booking.staff_id(p, 'id') AND state = 'unknown'
  RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'only a purchase with an unknown outcome can be resolved' USING ERRCODE = 'UB409';
  END IF;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('shippo_test_purchase', v_row.id, 'unknown', v_row.state, v_staff,
          jsonb_build_object('shipment_id', v_row.shipment_id, 'evidence', v_evidence));
  RETURN jsonb_build_object('id', v_row.id, 'state', v_row.state);
END;
$$;

-- Records a downloaded test label file. Payload: staff, purchase_id, content_type, file_name,
-- size_bytes, sha256, source_url. The purchase must be succeeded or staff-confirmed purchased.
CREATE OR REPLACE FUNCTION us_booking.shippo_test_label_add(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_staff text := us_booking.staff_actor(p);
  v_pur   us_booking.shippo_test_purchase%ROWTYPE;
  v_id    bigint;
BEGIN
  SELECT * INTO v_pur FROM us_booking.shippo_test_purchase WHERE id = us_booking.staff_id(p, 'purchase_id');
  IF NOT FOUND OR v_pur.state NOT IN ('succeeded', 'confirmed_purchased') THEN
    RAISE EXCEPTION 'a label can be stored only for a succeeded or staff-confirmed test purchase' USING ERRCODE = 'UB409';
  END IF;
  INSERT INTO us_booking.shippo_test_label (purchase_id, content_type, file_name, size_bytes, sha256, source_url, fetched_by)
  VALUES (v_pur.id, p->>'content_type', p->>'file_name', (p->>'size_bytes')::int, p->>'sha256', p->>'source_url', v_staff)
  RETURNING id INTO v_id;
  INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
  VALUES ('shippo_test_label', v_id, NULL, 'stored', v_staff, jsonb_build_object('purchase_id', v_pur.id, 'sha256', p->>'sha256'));
  RETURN jsonb_build_object('id', v_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_shipment_add(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_purchase_begin(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_purchase_finish(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_purchase_resolve(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.shippo_test_label_add(jsonb) FROM PUBLIC;
