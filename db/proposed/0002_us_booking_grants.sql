-- 0002_us_booking_grants: PROPOSED runtime privileges for the us_booking schema (revision 2).
--
-- Two roles, created by a DBA beforehand (roles are cluster-level and are not created here):
--   us_booking_owner  owns the schema and every object; runs migrations (DDL). Never used by the app.
--   us_booking_app    runtime role. DML only, granted table by table below.
-- Privileges are listed per table on purpose: there is no "GRANT UPDATE ON ALL TABLES", so tables
-- that must be append-only (event_log) or trigger-maintained (item_allocation) cannot pick up
-- UPDATE/DELETE by accident. A new table gets no runtime access until it is added here.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'us_booking_app') THEN
    RAISE EXCEPTION 'role us_booking_app does not exist; ask the DBA to create it before applying us_booking grants';
  END IF;
END;
$$;

REVOKE ALL ON SCHEMA us_booking FROM PUBLIC;
GRANT USAGE ON SCHEMA us_booking TO us_booking_app;

-- Read access to every table and view the app works with.
GRANT SELECT ON
  us_booking.country_map, us_booking.routing_rule, us_booking.package_profile,
  us_booking.oms_order, us_booking.oms_order_item, us_booking.oms_order_item_component,
  us_booking.order_destination_confirmation,
  us_booking.fulfilment_group, us_booking.fulfilment_group_order, us_booking.shipment_requirement,
  us_booking.parcel, us_booking.parcel_item, us_booking.item_allocation,
  us_booking.booking_attempt, us_booking.provider_shipment, us_booking.label_file, us_booking.print_event,
  us_booking.review_case, us_booking.event_log, us_booking.sync_state, us_booking.sync_run,
  us_booking.hist_import_batch, us_booking.hist_shippo_label, us_booking.hist_oms_order_item,
  us_booking.v_order_destination, us_booking.v_order_scope
TO us_booking_app;

-- Snapshot sync and queue state: insert + update, no delete (history is kept).
GRANT INSERT, UPDATE ON
  us_booking.oms_order, us_booking.oms_order_item, us_booking.oms_order_item_component,
  us_booking.order_destination_confirmation,
  us_booking.fulfilment_group, us_booking.fulfilment_group_order, us_booking.shipment_requirement,
  us_booking.package_profile, us_booking.parcel,
  us_booking.booking_attempt, us_booking.provider_shipment, us_booking.print_event,
  us_booking.review_case, us_booking.sync_state, us_booking.sync_run
TO us_booking_app;

-- Staff may remove an item from an open, unlocked parcel (guarded by trigger).
GRANT INSERT, UPDATE, DELETE ON us_booking.parcel_item TO us_booking_app;

-- Insert-only.
GRANT INSERT ON
  us_booking.event_log, us_booking.label_file,
  us_booking.hist_import_batch, us_booking.hist_shippo_label, us_booking.hist_oms_order_item
TO us_booking_app;

-- country_map, routing_rule: owner-maintained reference data; item_allocation: trigger-maintained.
-- The runtime role gets SELECT only on these (granted above).

GRANT USAGE ON
  us_booking.package_profile_id_seq, us_booking.order_destination_confirmation_id_seq,
  us_booking.fulfilment_group_id_seq, us_booking.shipment_requirement_id_seq, us_booking.parcel_id_seq,
  us_booking.booking_attempt_id_seq, us_booking.provider_shipment_id_seq, us_booking.label_file_id_seq,
  us_booking.print_event_id_seq, us_booking.review_case_id_seq, us_booking.event_log_id_seq,
  us_booking.sync_run_id_seq, us_booking.hist_import_batch_id_seq
TO us_booking_app;

-- Trigger/helper functions are called by triggers, not by the app directly.
REVOKE EXECUTE ON FUNCTION us_booking.adjust_allocation(bigint, integer) FROM PUBLIC;
