-- 0001_us_booking_init: schema for US Booking Automation, Phase 1 (revision 2, 2026-10-22).
--
-- Applied by scripts/db-migrate.mjs (npm run db:migrate) into varmen_db.us_booking, which records
-- it in us_booking.schema_migration. Validated in a disposable local cluster by
-- db/tests/run_local_tests.sh. Approved role setup: varmen_user owns the schema and is also the
-- runtime login (single role). See 0002 and docs/setup.md for what that means for privileges.
--
-- Agreed scope: US1 warehouse fulfilment to US and Canada; booking and label printing only; the OMS
-- (ledsone mirror, OMS_READ_DATABASE_URL) stays read-only and is never referenced by foreign key.
-- Routing: Shopify/eBay -> Shippo, Amazon -> Seller Central, Wayfair -> Wayfair's own account.
-- Staff confirm package dimensions, weight and contents.
--
-- Conventions follow ledsone-vendor-booking: one app-owned schema, idempotent statements, every
-- object schema-qualified. Runtime-role grants for a future separate login are kept in db/proposed/.
--
-- Revision 2 corrections:
--   1. Canada in scope; shipment requirements tracked separately from scope.
--   2. OMS timestamps kept raw; no timezone conversion until the source zone is verified.
--   3. Confirmed void allows a controlled replacement attempt; the earlier attempt is kept.
--   4. Attempt/parcel/group/shipment consistency by composite keys; no cross-group allocation.
--   5. Positive measurements when supplied, complete before booking; allocation race-safe.
--   6. event_log append-only (trigger + no UPDATE/DELETE grant).
--   7. Per-order, evidenced destination confirmation, separate from the global country map.
--   8. Provider metadata is a correlation value only; unresolved purchases stay blocked.

CREATE SCHEMA IF NOT EXISTS us_booking;

-- =============================================================================================
-- Reference data. Empty by default; nothing is seeded from historical labels. Written only by the
-- owner role (see grants), not by the runtime app.
-- =============================================================================================

-- Global mapping of the OMS country_id. Only rows marked verified from an authoritative OMS source
-- count. A per-order staff confirmation (order_destination_confirmation) never writes here.
CREATE TABLE IF NOT EXISTS us_booking.country_map (
  oms_country_id   integer PRIMARY KEY,
  iso2             char(2) CHECK (iso2 ~ '^[A-Z]{2}$'),
  country_name     text,
  status           text NOT NULL DEFAULT 'unverified' CHECK (status IN ('unverified','verified','rejected')),
  evidence         text,
  verified_by      text,
  verified_at      timestamptz,
  CHECK (status <> 'verified' OR (iso2 IS NOT NULL AND evidence IS NOT NULL AND verified_by IS NOT NULL AND verified_at IS NOT NULL))
);

-- OMS source -> label provider. Only 'verified' integrations may be booked through this app.
CREATE TABLE IF NOT EXISTS us_booking.routing_rule (
  oms_source_id       integer PRIMARY KEY,
  channel             text NOT NULL,
  provider            text NOT NULL CHECK (provider IN ('shippo','amazon_seller_central','wayfair_partner','none')),
  integration_status  text NOT NULL DEFAULT 'unverified' CHECK (integration_status IN ('unverified','manual_only','verified')),
  notes               text,
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Staff-created package profiles. Never derived from Shippo history.
CREATE TABLE IF NOT EXISTS us_booking.package_profile (
  id               bigserial PRIMARY KEY,
  name             text NOT NULL UNIQUE,
  length_in        numeric(8,2) NOT NULL CHECK (length_in > 0),
  width_in         numeric(8,2) NOT NULL CHECK (width_in > 0),
  height_in        numeric(8,2) NOT NULL CHECK (height_in > 0),
  empty_weight_lb  numeric(8,3) CHECK (empty_weight_lb > 0),
  approval_status  text NOT NULL DEFAULT 'proposed' CHECK (approval_status IN ('proposed','approved','retired')),
  approved_by      text,
  approved_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (approval_status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);

-- =============================================================================================
-- Live OMS snapshot (copied from the OMS, never written back). One row per ORIGINATING order.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS us_booking.oms_order (
  oms_order_id            bigint PRIMARY KEY,          -- orders.id
  platform_order_ref      text NOT NULL,               -- orders.order_id
  oms_source_id           integer NOT NULL,            -- source.id via sub_source
  channel                 text NOT NULL,
  sub_source_id           integer NOT NULL,
  account_name            text,
  market_place_id         text,                        -- selling site, NOT destination
  warehouse_id            integer NOT NULL,            -- 32 = US1
  booking_country_flags   text[] NOT NULL DEFAULT '{}',
  oms_status              text NOT NULL,
  oms_merge_raw           text,
  merge_parent_order_id   bigint,
  ebay_cancel_status      text,
  oms_shipped_flag        integer,
  oms_shipped_error       text,
  oms_shipping_method     text,
  -- Exactly as stored in OMS (timestamp without time zone). The source zone is NOT verified, so
  -- no conversion is applied anywhere in this schema. Do not compare it with timestamptz values.
  order_date_raw          timestamp,
  -- Ship-to (PII; needed to buy a label). Copied verbatim.
  ship_name               text,
  ship_company            text,
  ship_line1              text,
  ship_line2              text,
  ship_line3              text,
  ship_city               text,
  ship_region             text,
  ship_postcode           text,
  ship_phone              text,
  ship_email              text,
  oms_country_id          integer,                     -- raw; never interpreted without country_map
  ship_address_hash       text NOT NULL,               -- hash of the ship-to fields; invalidates stale confirmations
  source_hash             text NOT NULL,
  first_seen_at           timestamptz NOT NULL DEFAULT now(),
  last_synced_at          timestamptz NOT NULL DEFAULT now(),
  oms_changed_at          timestamptz
);
CREATE INDEX IF NOT EXISTS oms_order_platform_ref_idx ON us_booking.oms_order (platform_order_ref);
CREATE INDEX IF NOT EXISTS oms_order_status_wh_idx ON us_booking.oms_order (oms_status, warehouse_id);
CREATE INDEX IF NOT EXISTS oms_order_merge_parent_idx ON us_booking.oms_order (merge_parent_order_id);

-- One row per OMS order line. Ordered SKU and quantity preserved; pack/combo SKUs stay as ordered.
CREATE TABLE IF NOT EXISTS us_booking.oms_order_item (
  oms_order_item_id       bigint PRIMARY KEY,
  oms_order_id            bigint NOT NULL REFERENCES us_booking.oms_order(oms_order_id),
  container_order_id      bigint NOT NULL,             -- order_item_info.order_id (merge parent after a merge)
  line_item_id            text,
  item_sku                text NOT NULL,
  real_sku                text,
  quantity_ordered        integer NOT NULL CHECK (quantity_ordered > 0),
  real_qty                integer,
  quantity_raw            text NOT NULL,
  combo_count             integer,
  source_hash             text NOT NULL,
  last_synced_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (oms_order_item_id, oms_order_id)             -- target for parcel_item's composite key
);
CREATE INDEX IF NOT EXISTS oms_order_item_order_idx ON us_booking.oms_order_item (oms_order_id);

-- order_combo components: reference only, never parcel contents.
CREATE TABLE IF NOT EXISTS us_booking.oms_order_item_component (
  oms_combo_id            bigint PRIMARY KEY,
  oms_order_item_id       bigint NOT NULL REFERENCES us_booking.oms_order_item(oms_order_item_id),
  component_sku           text NOT NULL,
  component_qty           integer,
  last_synced_at          timestamptz NOT NULL DEFAULT now()
);

-- Staff confirmation of ONE order's destination, with evidence. Valid only while the order's
-- ship-to is unchanged (ship_address_hash). It never creates or verifies a country_map row.
CREATE TABLE IF NOT EXISTS us_booking.order_destination_confirmation (
  id                      bigserial PRIMARY KEY,
  oms_order_id            bigint NOT NULL REFERENCES us_booking.oms_order(oms_order_id),
  destination_iso2        char(2) NOT NULL CHECK (destination_iso2 ~ '^[A-Z]{2}$'),
  evidence_type           text NOT NULL CHECK (evidence_type IN ('marketplace_order_record','customer_confirmation','carrier_address_validation','other')),
  evidence_ref            text NOT NULL CHECK (length(btrim(evidence_ref)) > 0),
  oms_country_id_seen     integer,                     -- raw OMS value at confirmation time, for audit
  ship_address_hash       text NOT NULL,               -- ship-to the confirmation was made against
  confirmed_by            text NOT NULL,
  confirmed_at            timestamptz NOT NULL DEFAULT now(),
  status                  text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
  revoked_by              text,
  revoked_at              timestamptz,
  revoke_reason           text,
  CHECK (status = 'active' OR (revoked_by IS NOT NULL AND revoked_at IS NOT NULL AND revoke_reason IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS order_destination_confirmation_one_active
  ON us_booking.order_destination_confirmation (oms_order_id) WHERE status = 'active';

-- =============================================================================================
-- Live booking queue.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS us_booking.fulfilment_group (
  id                      bigserial PRIMARY KEY,
  group_key               text NOT NULL UNIQUE,        -- 'oms:<merge parent or single order id>:g<generation>'
  generation              integer NOT NULL DEFAULT 1 CHECK (generation > 0),
  provider                text NOT NULL CHECK (provider IN ('shippo','amazon_seller_central','wayfair_partner','none')),
  provider_account        text NOT NULL,
  warehouse_id            integer NOT NULL,
  state                   text NOT NULL DEFAULT 'review'
                          CHECK (state IN ('review','ready','booking','booked','printed','cancelled','superseded')),
  blocked_reason          text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, provider, provider_account)              -- target for booking_attempt's composite key
);

CREATE TABLE IF NOT EXISTS us_booking.fulfilment_group_order (
  fulfilment_group_id     bigint NOT NULL REFERENCES us_booking.fulfilment_group(id),
  oms_order_id            bigint NOT NULL REFERENCES us_booking.oms_order(oms_order_id),
  role                    text NOT NULL CHECK (role IN ('single','merge_parent','merge_child')),
  active                  boolean NOT NULL DEFAULT true,
  added_at                timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fulfilment_group_id, oms_order_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS fulfilment_group_order_one_active
  ON us_booking.fulfilment_group_order (oms_order_id) WHERE active;

-- What is still missing before a group can ship. Separate from scope: an in-scope order can have
-- unmet requirements, and meeting requirements never brings an out-of-scope order into scope.
CREATE TABLE IF NOT EXISTS us_booking.shipment_requirement (
  id                      bigserial PRIMARY KEY,
  fulfilment_group_id     bigint NOT NULL REFERENCES us_booking.fulfilment_group(id),
  oms_order_id            bigint REFERENCES us_booking.oms_order(oms_order_id),  -- NULL = whole group
  requirement             text NOT NULL CHECK (requirement IN (
                            'destination_country','ship_to_address','ship_to_state','ship_to_phone',
                            'parcel_measurements','parcel_contents','customs_declaration',
                            'routing_verified','provider_account')),
  status                  text NOT NULL CHECK (status IN ('met','unmet','not_applicable')),
  detail                  text,
  checked_by              text NOT NULL,               -- user email or 'system:<job>'
  checked_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (fulfilment_group_id, oms_order_id, requirement)
);

CREATE TABLE IF NOT EXISTS us_booking.parcel (
  id                      bigserial PRIMARY KEY,
  fulfilment_group_id     bigint NOT NULL REFERENCES us_booking.fulfilment_group(id),
  parcel_no               integer NOT NULL CHECK (parcel_no > 0),
  package_profile_id      bigint REFERENCES us_booking.package_profile(id),
  -- NULL = not measured yet; any supplied value must be positive. Completeness is enforced when a
  -- booking attempt is created, not here, so staff can save a parcel before measuring it.
  length_in               numeric(8,2) CHECK (length_in > 0),
  width_in                numeric(8,2) CHECK (width_in > 0),
  height_in               numeric(8,2) CHECK (height_in > 0),
  weight_lb               numeric(8,3) CHECK (weight_lb > 0),
  measured_by             text,
  measured_at             timestamptz,
  contents_status         text NOT NULL DEFAULT 'unconfirmed' CHECK (contents_status IN ('unconfirmed','confirmed')),
  confirmed_by            text,
  confirmed_at            timestamptz,
  state                   text NOT NULL DEFAULT 'open' CHECK (state IN ('open','booked','cancelled')),
  created_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fulfilment_group_id, parcel_no),
  UNIQUE (id, fulfilment_group_id),                    -- target for composite keys below
  CHECK ((measured_by IS NULL) = (measured_at IS NULL)),
  CHECK (contents_status <> 'confirmed' OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL))
);

-- Units of an ORDERED line placed in a parcel. The composite keys make it impossible to put an item
-- into a parcel of a group its order does not belong to, or to pair an item with the wrong order.
CREATE TABLE IF NOT EXISTS us_booking.parcel_item (
  parcel_id               bigint NOT NULL,
  fulfilment_group_id     bigint NOT NULL,
  oms_order_id            bigint NOT NULL,
  oms_order_item_id       bigint NOT NULL,
  quantity                integer NOT NULL CHECK (quantity > 0),
  PRIMARY KEY (parcel_id, oms_order_item_id),
  FOREIGN KEY (parcel_id, fulfilment_group_id) REFERENCES us_booking.parcel(id, fulfilment_group_id),
  FOREIGN KEY (oms_order_item_id, oms_order_id) REFERENCES us_booking.oms_order_item(oms_order_item_id, oms_order_id),
  FOREIGN KEY (fulfilment_group_id, oms_order_id) REFERENCES us_booking.fulfilment_group_order(fulfilment_group_id, oms_order_id)
);

-- Running total of units allocated to non-cancelled parcels, per order line. Maintained only by
-- triggers (the runtime role has SELECT only). Updating one counter row per line serialises
-- concurrent allocations: a second writer waits and then sees the first one's total.
CREATE TABLE IF NOT EXISTS us_booking.item_allocation (
  oms_order_item_id       bigint PRIMARY KEY REFERENCES us_booking.oms_order_item(oms_order_item_id),
  allocated_qty           integer NOT NULL DEFAULT 0 CHECK (allocated_qty >= 0),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

-- One row per attempt to buy a label.
-- correlation_key is sent to the provider as metadata so a label can be FOUND later. It is not
-- provider-side idempotency: the provider may accept the same key twice. Duplicate prevention is
-- local (the unique index below) and an unresolved outcome blocks the parcel until reconciled.
CREATE TABLE IF NOT EXISTS us_booking.booking_attempt (
  id                      bigserial PRIMARY KEY,
  parcel_id               bigint NOT NULL,
  fulfilment_group_id     bigint NOT NULL,
  provider                text NOT NULL,
  provider_account        text NOT NULL,
  attempt_generation      integer NOT NULL CHECK (attempt_generation > 0),
  correlation_key         text NOT NULL UNIQUE,        -- 'usb:<group_key>:p<parcel_no>:a<attempt_generation>'
  replaces_attempt_id     bigint REFERENCES us_booking.booking_attempt(id),
  authorised_by           text,                        -- required for a replacement
  state                   text NOT NULL DEFAULT 'created'
                          CHECK (state IN ('created','request_sent','succeeded','failed','unknown',
                                           'reconciled_found','reconciled_not_found')),
  request_hash            text NOT NULL,
  rate_ref                text,
  service_level           text,
  quoted_amount           numeric(10,2),
  quoted_currency         char(3),
  requested_by            text NOT NULL,
  sent_at                 timestamptz,
  responded_at            timestamptz,
  provider_status         text,
  error_code              text,
  error_message           text,
  reconcile_checks        integer NOT NULL DEFAULT 0,
  last_reconcile_at       timestamptz,
  resolution_evidence     text,                        -- what proved the outcome of an unknown purchase
  resolved_by             text,
  resolved_at             timestamptz,
  -- Set only after the provider has confirmed the void of this attempt's label. The attempt row
  -- keeps state 'succeeded'; release just stops it blocking a controlled replacement.
  released_at             timestamptz,
  released_by             text,
  release_reason          text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (parcel_id, attempt_generation),
  UNIQUE (id, parcel_id, provider, provider_account),  -- target for provider_shipment's composite key
  FOREIGN KEY (parcel_id, fulfilment_group_id) REFERENCES us_booking.parcel(id, fulfilment_group_id),
  FOREIGN KEY (fulfilment_group_id, provider, provider_account)
    REFERENCES us_booking.fulfilment_group(id, provider, provider_account),
  CHECK (replaces_attempt_id IS NULL OR authorised_by IS NOT NULL),
  CHECK (state NOT IN ('reconciled_found','reconciled_not_found')
         OR (resolution_evidence IS NOT NULL AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL)),
  CHECK (released_at IS NULL OR (state IN ('succeeded','reconciled_found') AND released_by IS NOT NULL AND release_reason IS NOT NULL))
);
-- Pending, in-flight, unknown and unreleased successful purchases all block another purchase.
CREATE UNIQUE INDEX IF NOT EXISTS booking_attempt_one_blocking_per_parcel
  ON us_booking.booking_attempt (parcel_id)
  WHERE released_at IS NULL AND state IN ('created','request_sent','unknown','succeeded','reconciled_found');
CREATE INDEX IF NOT EXISTS booking_attempt_unresolved_idx
  ON us_booking.booking_attempt (state, last_reconcile_at) WHERE state IN ('request_sent','unknown');

CREATE TABLE IF NOT EXISTS us_booking.provider_shipment (
  id                      bigserial PRIMARY KEY,
  booking_attempt_id      bigint NOT NULL UNIQUE,
  parcel_id               bigint NOT NULL,
  provider                text NOT NULL,
  provider_account        text NOT NULL,
  provider_shipment_ref   text,
  provider_label_ref      text NOT NULL,
  tracking_number         text,
  carrier                 text,
  service_level           text,
  amount                  numeric(10,2),
  currency                char(3),
  label_status            text NOT NULL DEFAULT 'active'
                          CHECK (label_status IN ('active','void_requested','voided','void_rejected')),
  void_requested_by       text,
  void_requested_at       timestamptz,
  void_confirmed_at       timestamptz,
  void_provider_ref       text,
  void_evidence           text,
  provider_created_at     timestamptz,
  recorded_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_label_ref),
  FOREIGN KEY (booking_attempt_id, parcel_id, provider, provider_account)
    REFERENCES us_booking.booking_attempt(id, parcel_id, provider, provider_account),
  CHECK (label_status NOT IN ('void_requested','voided','void_rejected') OR (void_requested_by IS NOT NULL AND void_requested_at IS NOT NULL)),
  CHECK (label_status <> 'voided' OR (void_confirmed_at IS NOT NULL AND void_evidence IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS provider_shipment_tracking_uq
  ON us_booking.provider_shipment (provider, tracking_number) WHERE tracking_number IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS provider_shipment_one_live_per_parcel
  ON us_booking.provider_shipment (parcel_id) WHERE label_status <> 'voided';

CREATE TABLE IF NOT EXISTS us_booking.label_file (
  id                      bigserial PRIMARY KEY,
  provider_shipment_id    bigint NOT NULL REFERENCES us_booking.provider_shipment(id),
  format                  text NOT NULL CHECK (format IN ('PDF','PDF_4x6','ZPLII','PNG')),
  storage_uri             text NOT NULL,
  provider_label_url      text,
  sha256                  text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  byte_size               integer CHECK (byte_size > 0),
  fetched_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider_shipment_id, format)
);

-- Every print. A reprint only adds a row here and never creates a booking attempt.
CREATE TABLE IF NOT EXISTS us_booking.print_event (
  id                      bigserial PRIMARY KEY,
  label_file_id           bigint NOT NULL REFERENCES us_booking.label_file(id),
  kind                    text NOT NULL CHECK (kind IN ('initial','reprint')),
  client_request_id       text NOT NULL UNIQUE,
  printer_ref             text,
  requested_by            text NOT NULL,
  reason                  text,
  status                  text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','printed','failed')),
  error_message           text,
  requested_at            timestamptz NOT NULL DEFAULT now(),
  completed_at            timestamptz,
  CHECK (kind <> 'reprint' OR reason IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS print_event_one_initial_per_label
  ON us_booking.print_event (label_file_id) WHERE kind = 'initial';

-- Decisions the automation must not take alone. Missing data is a shipment_requirement, not a case.
CREATE TABLE IF NOT EXISTS us_booking.review_case (
  id                      bigserial PRIMARY KEY,
  case_type               text NOT NULL CHECK (case_type IN (
                            'scope','destination_conflict','cancellation','warehouse_conflict',
                            'booking_flag_conflict','merge_inconsistent','combo_mismatch','sku_missing',
                            'already_shipped_suspect','oms_status_changed','booking_unknown',
                            'routing_unverified','over_allocation','label_unretrievable')),
  oms_order_id            bigint REFERENCES us_booking.oms_order(oms_order_id),
  fulfilment_group_id     bigint REFERENCES us_booking.fulfilment_group(id),
  booking_attempt_id      bigint REFERENCES us_booking.booking_attempt(id),
  status                  text NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','dismissed')),
  details                 jsonb NOT NULL DEFAULT '{}',
  opened_at               timestamptz NOT NULL DEFAULT now(),
  resolved_by             text,
  resolved_at             timestamptz,
  resolution              text,
  CHECK (oms_order_id IS NOT NULL OR fulfilment_group_id IS NOT NULL OR booking_attempt_id IS NOT NULL),
  CHECK (status = 'open' OR (resolved_by IS NOT NULL AND resolved_at IS NOT NULL AND resolution IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS review_case_one_open_per_order_type
  ON us_booking.review_case (oms_order_id, case_type) WHERE status = 'open' AND oms_order_id IS NOT NULL;

-- Append-only audit trail. Runtime role: SELECT + INSERT only; a trigger also rejects UPDATE,
-- DELETE and TRUNCATE for every role.
CREATE TABLE IF NOT EXISTS us_booking.event_log (
  id                      bigserial PRIMARY KEY,
  entity                  text NOT NULL,
  entity_id               bigint NOT NULL,
  from_state              text,
  to_state                text,
  actor                   text NOT NULL,
  details                 jsonb NOT NULL DEFAULT '{}',
  occurred_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS event_log_entity_idx ON us_booking.event_log (entity, entity_id);

-- =============================================================================================
-- Sync state.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS us_booking.sync_state (
  stream                  text PRIMARY KEY,
  cursor_value            text,
  last_started_at         timestamptz,
  last_success_at         timestamptz,
  last_error              text,
  lock_owner              text,
  lock_expires_at         timestamptz,
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS us_booking.sync_run (
  id                      bigserial PRIMARY KEY,
  stream                  text NOT NULL REFERENCES us_booking.sync_state(stream),
  started_at              timestamptz NOT NULL DEFAULT now(),
  finished_at             timestamptz,
  status                  text NOT NULL DEFAULT 'running' CHECK (status IN ('running','ok','failed')),
  rows_read               integer,
  rows_changed            integer,
  review_cases_opened     integer,
  error                   text
);

-- =============================================================================================
-- Historical imports. No foreign keys into the live queue; cross-check only.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS us_booking.hist_import_batch (
  id                      bigserial PRIMARY KEY,
  source_file             text NOT NULL,
  source_sha256           text NOT NULL UNIQUE,
  kind                    text NOT NULL CHECK (kind IN ('shippo_label_export','oms_match_audit','oms_order_items_export')),
  row_count               integer NOT NULL,
  imported_by             text NOT NULL,
  imported_at             timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS us_booking.hist_shippo_label (
  batch_id                bigint NOT NULL REFERENCES us_booking.hist_import_batch(id),
  source_row              integer NOT NULL,
  shippo_created_at_raw   text,                        -- as exported, unparsed
  tracking_number         text,
  provider                text,
  service_level           text,
  origin_country          text,                        -- as on the label; not an OMS mapping
  destination_country     text,                        -- as on the label; not an OMS mapping
  original_metadata       text,
  extracted_order_ref     text,
  match_status            text,
  match_method            text,
  oms_order_id            bigint,                      -- plain copy, deliberately no FK
  oms_shipment_id         bigint,
  scope_status            text,
  notes                   text,
  PRIMARY KEY (batch_id, source_row)
);
CREATE INDEX IF NOT EXISTS hist_shippo_label_ref_idx ON us_booking.hist_shippo_label (extracted_order_ref);
CREATE INDEX IF NOT EXISTS hist_shippo_label_trk_idx ON us_booking.hist_shippo_label (tracking_number);
CREATE INDEX IF NOT EXISTS hist_shippo_label_order_idx ON us_booking.hist_shippo_label (oms_order_id);

CREATE TABLE IF NOT EXISTS us_booking.hist_oms_order_item (
  batch_id                bigint NOT NULL REFERENCES us_booking.hist_import_batch(id),
  oms_order_item_id       bigint NOT NULL,
  oms_order_id            bigint NOT NULL,
  merged_into_oms_order_id bigint,
  marketplace_order_number text,
  channel                 text,
  account                 text,
  warehouse_id            integer,
  ordered_sku             text,
  internal_sku            text,
  quantity_ordered        integer,
  combo_component_count   integer,
  order_status            text,
  cancellation_status     text,
  PRIMARY KEY (batch_id, oms_order_item_id)
);

-- =============================================================================================
-- Derived views: destination and scope.
-- =============================================================================================

-- Effective destination per order. Sources, in order: a verified global country_map row, or a
-- still-valid (same ship-to) active per-order confirmation. If both exist and disagree the result
-- is 'conflict' with no destination.
CREATE OR REPLACE VIEW us_booking.v_order_destination AS
SELECT o.oms_order_id,
       o.oms_country_id,
       cm.iso2                                         AS mapped_iso2,
       dc.destination_iso2                             AS confirmed_iso2,
       (dc.id IS NOT NULL AND dc.ship_address_hash <> o.ship_address_hash) AS confirmation_stale,
       CASE
         WHEN cm.iso2 IS NOT NULL AND dcv.iso2 IS NOT NULL AND cm.iso2 <> dcv.iso2 THEN NULL
         ELSE coalesce(cm.iso2, dcv.iso2)
       END                                             AS destination_iso2,
       CASE
         WHEN cm.iso2 IS NOT NULL AND dcv.iso2 IS NOT NULL AND cm.iso2 <> dcv.iso2 THEN 'conflict'
         WHEN cm.iso2 IS NOT NULL THEN 'country_map'
         WHEN dcv.iso2 IS NOT NULL THEN 'order_confirmation'
         ELSE 'unresolved'
       END                                             AS destination_source
FROM us_booking.oms_order o
LEFT JOIN us_booking.country_map cm
       ON cm.oms_country_id = o.oms_country_id AND cm.status = 'verified'
LEFT JOIN us_booking.order_destination_confirmation dc
       ON dc.oms_order_id = o.oms_order_id AND dc.status = 'active'
LEFT JOIN LATERAL (SELECT dc.destination_iso2 AS iso2
                   WHERE dc.id IS NOT NULL AND dc.ship_address_hash = o.ship_address_hash) dcv ON true;

-- Scope only: US1 warehouse shipping to the US or Canada. Says nothing about readiness.
CREATE OR REPLACE VIEW us_booking.v_order_scope AS
SELECT d.oms_order_id,
       o.warehouse_id,
       d.destination_iso2,
       d.destination_source,
       CASE
         WHEN o.warehouse_id <> 32 THEN 'out_of_scope'
         WHEN d.destination_iso2 IS NULL THEN 'undetermined'
         WHEN d.destination_iso2 IN ('US','CA') THEN 'in_scope'
         ELSE 'out_of_scope'
       END AS scope_status
FROM us_booking.v_order_destination d
JOIN us_booking.oms_order o ON o.oms_order_id = d.oms_order_id;

-- =============================================================================================
-- Integrity functions and triggers.
-- =============================================================================================

-- True while a parcel has a pending/in-flight/unknown purchase, an unreleased successful one, or a
-- label that is not confirmed voided. Measurements, contents and allocation are frozen meanwhile.
CREATE OR REPLACE FUNCTION us_booking.parcel_is_locked(p_parcel_id bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM us_booking.booking_attempt a
                  WHERE a.parcel_id = p_parcel_id AND a.released_at IS NULL
                    AND a.state IN ('created','request_sent','unknown','succeeded','reconciled_found'))
      OR EXISTS (SELECT 1 FROM us_booking.provider_shipment s
                  WHERE s.parcel_id = p_parcel_id AND s.label_status <> 'voided')
$$;

-- Adds p_delta to an order line's allocated total and rejects totals above the ordered quantity.
-- SECURITY DEFINER so the runtime role cannot write item_allocation directly.
CREATE OR REPLACE FUNCTION us_booking.adjust_allocation(p_item_id bigint, p_delta integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_total   integer;
  v_ordered integer;
BEGIN
  INSERT INTO us_booking.item_allocation (oms_order_item_id) VALUES (p_item_id) ON CONFLICT DO NOTHING;
  UPDATE us_booking.item_allocation
     SET allocated_qty = allocated_qty + p_delta, updated_at = now()
   WHERE oms_order_item_id = p_item_id
  RETURNING allocated_qty INTO v_total;
  IF p_delta > 0 THEN
    SELECT quantity_ordered INTO v_ordered FROM us_booking.oms_order_item WHERE oms_order_item_id = p_item_id;
    IF v_total > v_ordered THEN
      RAISE EXCEPTION 'over-allocation: order item % would have % of % ordered units in parcels', p_item_id, v_total, v_ordered
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION us_booking.tg_parcel_item_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_parcel_id bigint := CASE WHEN TG_OP = 'DELETE' THEN OLD.parcel_id ELSE NEW.parcel_id END;
  v_parcel    record;
  v_active    boolean;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.parcel_id, NEW.fulfilment_group_id, NEW.oms_order_id, NEW.oms_order_item_id)
       IS DISTINCT FROM (OLD.parcel_id, OLD.fulfilment_group_id, OLD.oms_order_id, OLD.oms_order_item_id) THEN
    RAISE EXCEPTION 'parcel_item keys are immutable; delete the row and add a new one' USING ERRCODE = 'check_violation';
  END IF;
  -- FOR SHARE conflicts with the FOR UPDATE taken when a booking attempt is created.
  SELECT state, contents_status INTO v_parcel FROM us_booking.parcel WHERE id = v_parcel_id FOR SHARE;
  IF v_parcel.state <> 'open' THEN
    RAISE EXCEPTION 'parcel % is %; contents can only change while it is open', v_parcel_id, v_parcel.state USING ERRCODE = 'check_violation';
  END IF;
  IF v_parcel.contents_status = 'confirmed' THEN
    RAISE EXCEPTION 'parcel % contents are confirmed; unconfirm before changing them', v_parcel_id USING ERRCODE = 'check_violation';
  END IF;
  IF us_booking.parcel_is_locked(v_parcel_id) THEN
    RAISE EXCEPTION 'parcel % has a pending, unknown or active purchase; contents are frozen', v_parcel_id USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP <> 'DELETE' THEN
    SELECT active INTO v_active FROM us_booking.fulfilment_group_order
     WHERE fulfilment_group_id = NEW.fulfilment_group_id AND oms_order_id = NEW.oms_order_id FOR SHARE;
    IF NOT coalesce(v_active, false) THEN
      RAISE EXCEPTION 'order % is not an active member of fulfilment group %', NEW.oms_order_id, NEW.fulfilment_group_id
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;
  IF TG_OP IN ('UPDATE','DELETE') THEN
    PERFORM us_booking.adjust_allocation(OLD.oms_order_item_id, -OLD.quantity);
  END IF;
  IF TG_OP IN ('INSERT','UPDATE') THEN
    PERFORM us_booking.adjust_allocation(NEW.oms_order_item_id, NEW.quantity);
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE OR REPLACE TRIGGER parcel_item_guard
  BEFORE INSERT OR UPDATE OR DELETE ON us_booking.parcel_item
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_parcel_item_guard();

CREATE OR REPLACE FUNCTION us_booking.tg_parcel_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF (NEW.id, NEW.fulfilment_group_id, NEW.parcel_no) IS DISTINCT FROM (OLD.id, OLD.fulfilment_group_id, OLD.parcel_no) THEN
    RAISE EXCEPTION 'parcel identity is immutable' USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.state = 'cancelled' THEN
    RAISE EXCEPTION 'parcel % is cancelled; cancellation is final', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  IF (NEW.length_in, NEW.width_in, NEW.height_in, NEW.weight_lb, NEW.package_profile_id,
      NEW.measured_by, NEW.measured_at, NEW.contents_status, NEW.confirmed_by, NEW.confirmed_at)
     IS DISTINCT FROM
     (OLD.length_in, OLD.width_in, OLD.height_in, OLD.weight_lb, OLD.package_profile_id,
      OLD.measured_by, OLD.measured_at, OLD.contents_status, OLD.confirmed_by, OLD.confirmed_at)
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
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER parcel_guard
  BEFORE UPDATE ON us_booking.parcel
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_parcel_guard();

-- A cancelled parcel releases its allocation.
CREATE OR REPLACE FUNCTION us_booking.tg_parcel_cancel_release()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT oms_order_item_id, quantity FROM us_booking.parcel_item WHERE parcel_id = NEW.id LOOP
    PERFORM us_booking.adjust_allocation(r.oms_order_item_id, -r.quantity);
  END LOOP;
  RETURN NULL;
END;
$$;
CREATE OR REPLACE TRIGGER parcel_cancel_release
  AFTER UPDATE OF state ON us_booking.parcel
  FOR EACH ROW WHEN (OLD.state <> 'cancelled' AND NEW.state = 'cancelled')
  EXECUTE FUNCTION us_booking.tg_parcel_cancel_release();

-- Preconditions for buying a label.
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
  IF v_parcel.length_in IS NULL OR v_parcel.width_in IS NULL OR v_parcel.height_in IS NULL OR v_parcel.weight_lb IS NULL
     OR v_parcel.measured_by IS NULL THEN
    RAISE EXCEPTION 'parcel % measurements are incomplete or not staff-confirmed', NEW.parcel_id USING ERRCODE = 'check_violation';
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
CREATE OR REPLACE TRIGGER booking_attempt_insert
  BEFORE INSERT ON us_booking.booking_attempt
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_booking_attempt_insert();

CREATE OR REPLACE FUNCTION us_booking.tg_booking_attempt_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF (NEW.id, NEW.parcel_id, NEW.fulfilment_group_id, NEW.provider, NEW.provider_account, NEW.attempt_generation,
      NEW.correlation_key, NEW.replaces_attempt_id, NEW.authorised_by, NEW.requested_by, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.parcel_id, OLD.fulfilment_group_id, OLD.provider, OLD.provider_account, OLD.attempt_generation,
      OLD.correlation_key, OLD.replaces_attempt_id, OLD.authorised_by, OLD.requested_by, OLD.created_at) THEN
    RAISE EXCEPTION 'booking attempt % identity is immutable', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.state <> 'created' AND (NEW.request_hash, NEW.rate_ref, NEW.service_level, NEW.quoted_amount, NEW.quoted_currency)
       IS DISTINCT FROM (OLD.request_hash, OLD.rate_ref, OLD.service_level, OLD.quoted_amount, OLD.quoted_currency) THEN
    RAISE EXCEPTION 'booking attempt % request is frozen once sent', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.state IS DISTINCT FROM OLD.state THEN
    -- 'unknown' leaves only through reconciliation with evidence; it can never become 'failed'.
    IF (OLD.state, NEW.state) NOT IN (('created','request_sent'), ('created','failed'),
                                      ('request_sent','succeeded'), ('request_sent','failed'), ('request_sent','unknown'),
                                      ('unknown','reconciled_found'), ('unknown','reconciled_not_found')) THEN
      RAISE EXCEPTION 'booking attempt % cannot move from % to %', OLD.id, OLD.state, NEW.state USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.state = 'request_sent' AND NEW.sent_at IS NULL THEN
      RAISE EXCEPTION 'request_sent requires sent_at' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.state = 'request_sent' AND NEW.state IN ('succeeded','failed') AND NEW.responded_at IS NULL THEN
      RAISE EXCEPTION '% after sending requires a definitive provider response (responded_at)', NEW.state USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF OLD.released_at IS NOT NULL AND (NEW.released_at, NEW.released_by, NEW.release_reason)
       IS DISTINCT FROM (OLD.released_at, OLD.released_by, OLD.release_reason) THEN
    RAISE EXCEPTION 'booking attempt % release is final', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.released_at IS NULL AND NEW.released_at IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM us_booking.provider_shipment
                      WHERE booking_attempt_id = OLD.id AND label_status = 'voided') THEN
    RAISE EXCEPTION 'booking attempt % can only be released after the provider confirmed the void of its label', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER booking_attempt_update
  BEFORE UPDATE ON us_booking.booking_attempt
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_booking_attempt_update();

-- At commit: a successful attempt has its label row, and a label row belongs to a successful attempt.
CREATE OR REPLACE FUNCTION us_booking.tg_attempt_outcome_check()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_state text;
BEGIN
  IF TG_TABLE_NAME = 'booking_attempt' THEN
    SELECT state INTO v_state FROM us_booking.booking_attempt WHERE id = NEW.id;
    IF v_state IN ('succeeded','reconciled_found')
       AND NOT EXISTS (SELECT 1 FROM us_booking.provider_shipment WHERE booking_attempt_id = NEW.id) THEN
      RAISE EXCEPTION 'booking attempt % is % but has no provider_shipment', NEW.id, v_state USING ERRCODE = 'check_violation';
    END IF;
  ELSE
    SELECT state INTO v_state FROM us_booking.booking_attempt WHERE id = NEW.booking_attempt_id;
    IF v_state NOT IN ('succeeded','reconciled_found') THEN
      RAISE EXCEPTION 'provider_shipment % belongs to attempt % in state %', NEW.id, NEW.booking_attempt_id, v_state
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS booking_attempt_outcome_check ON us_booking.booking_attempt;
CREATE CONSTRAINT TRIGGER booking_attempt_outcome_check
  AFTER INSERT OR UPDATE ON us_booking.booking_attempt
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_attempt_outcome_check();
DROP TRIGGER IF EXISTS provider_shipment_outcome_check ON us_booking.provider_shipment;
CREATE CONSTRAINT TRIGGER provider_shipment_outcome_check
  AFTER INSERT OR UPDATE ON us_booking.provider_shipment
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_attempt_outcome_check();

CREATE OR REPLACE FUNCTION us_booking.tg_provider_shipment_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF (NEW.id, NEW.booking_attempt_id, NEW.parcel_id, NEW.provider, NEW.provider_account, NEW.provider_label_ref,
      NEW.tracking_number, NEW.amount, NEW.currency)
     IS DISTINCT FROM
     (OLD.id, OLD.booking_attempt_id, OLD.parcel_id, OLD.provider, OLD.provider_account, OLD.provider_label_ref,
      OLD.tracking_number, OLD.amount, OLD.currency) THEN
    RAISE EXCEPTION 'provider_shipment % identity is immutable', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.label_status IS DISTINCT FROM OLD.label_status
     AND (OLD.label_status, NEW.label_status) NOT IN (('active','void_requested'), ('void_requested','voided'),
                                                     ('void_requested','void_rejected'), ('void_rejected','void_requested')) THEN
    RAISE EXCEPTION 'label % cannot move from % to %', OLD.id, OLD.label_status, NEW.label_status USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER provider_shipment_update
  BEFORE UPDATE ON us_booking.provider_shipment
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_provider_shipment_update();

-- Only an active label can be printed or reprinted.
CREATE OR REPLACE FUNCTION us_booking.tg_print_event_insert()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_status text;
BEGIN
  SELECT s.label_status INTO v_status
    FROM us_booking.label_file f JOIN us_booking.provider_shipment s ON s.id = f.provider_shipment_id
   WHERE f.id = NEW.label_file_id;
  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'label file % belongs to a % label; only active labels can be printed', NEW.label_file_id, v_status
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER print_event_insert
  BEFORE INSERT ON us_booking.print_event
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_print_event_insert();

CREATE OR REPLACE FUNCTION us_booking.tg_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%.% is append-only (% rejected)', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP USING ERRCODE = 'insufficient_privilege';
END;
$$;
CREATE OR REPLACE TRIGGER event_log_append_only
  BEFORE UPDATE OR DELETE ON us_booking.event_log
  FOR EACH ROW EXECUTE FUNCTION us_booking.tg_append_only();
CREATE OR REPLACE TRIGGER event_log_no_truncate
  BEFORE TRUNCATE ON us_booking.event_log
  FOR EACH STATEMENT EXECUTE FUNCTION us_booking.tg_append_only();
