-- 0002_us_booking_grants: PROPOSED runtime privileges for the us_booking schema (revision 2).
--
-- STATUS: NOT APPLIED, deferred. The approved setup (2026-10-23) uses varmen_user as both owner and
-- runtime login, so these grants have no grantee. Kept for a possible future separate runtime
-- login; it would then become a new numbered file in db/migrations/ (not 0002, which is taken by
-- 0002_us_booking_schema_security.sql). The local test suite still applies it, to prove the
-- separate-role design.
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

-- Added with 0007/0008 (package profiles and staff actions). Profile versions are append-only;
-- assignments are changed through us_booking.staff_profile_assign. Staff actions are plain
-- (SECURITY INVOKER) functions, so a separate runtime role also needs EXECUTE on them.
GRANT SELECT ON us_booking.package_profile_version, us_booking.package_profile_assignment,
  us_booking.v_order_item_allocation TO us_booking_app;
GRANT INSERT ON us_booking.package_profile_version TO us_booking_app;
GRANT UPDATE ON us_booking.package_profile_assignment TO us_booking_app;
GRANT DELETE ON us_booking.parcel TO us_booking_app;
GRANT EXECUTE ON FUNCTION
  us_booking.staff_profile_save(jsonb), us_booking.staff_profile_assign(jsonb),
  us_booking.staff_parcel_create(jsonb), us_booking.staff_parcel_measure(jsonb), us_booking.staff_parcel_set_contents(jsonb),
  us_booking.staff_parcel_confirm_contents(jsonb), us_booking.staff_parcel_remove(jsonb),
  us_booking.staff_destination_confirm(jsonb), us_booking.staff_destination_revoke(jsonb), us_booking.staff_case_close(jsonb),
  us_booking.staff_actor(jsonb), us_booking.staff_id(jsonb, text), us_booking.staff_measure(jsonb, text, text),
  us_booking.staff_text(jsonb, text, text, integer, integer), us_booking.staff_parcel_for_edit(jsonb),
  us_booking.parcel_snapshot(us_booking.parcel), us_booking.parcel_requirements_refresh(bigint, text),
  us_booking.destination_requirements_refresh(bigint, text), us_booking.sync_record_failure(jsonb)
TO us_booking_app;

-- Added with 0009 (parcel contents revalidation). Discrepancies are kept as history: no DELETE.
GRANT SELECT, INSERT, UPDATE ON us_booking.parcel_contents_discrepancy TO us_booking_app;
GRANT USAGE ON us_booking.parcel_contents_discrepancy_id_seq TO us_booking_app;
GRANT EXECUTE ON FUNCTION
  us_booking.parcel_contents_basis(bigint), us_booking.group_allocation_problems(bigint),
  us_booking.parcel_contents_changes(jsonb, jsonb), us_booking.parcel_contents_revalidate(bigint, text, bigint),
  us_booking.staff_discrepancy_acknowledge(jsonb)
TO us_booking_app;

-- Added with 0010 (Wayfair sandbox records; written only through the wayfair_sandbox_* functions).
GRANT SELECT, INSERT, UPDATE ON us_booking.wayfair_sandbox_registration TO us_booking_app;
GRANT SELECT, INSERT ON us_booking.wayfair_sandbox_label TO us_booking_app;
GRANT USAGE ON us_booking.wayfair_sandbox_registration_id_seq, us_booking.wayfair_sandbox_label_id_seq TO us_booking_app;
GRANT EXECUTE ON FUNCTION
  us_booking.wayfair_sandbox_begin(jsonb), us_booking.wayfair_sandbox_finish(jsonb), us_booking.wayfair_sandbox_record_existing(jsonb),
  us_booking.wayfair_sandbox_resolve(jsonb), us_booking.wayfair_sandbox_label_add(jsonb)
TO us_booking_app;

-- Added with 0011 (Wayfair-managed packaging).
GRANT SELECT ON us_booking.provider_packaging_policy TO us_booking_app;
GRANT EXECUTE ON FUNCTION us_booking.staff_parcel_set_packaging(jsonb) TO us_booking_app;

-- Added with 0012 (Shippo TEST records; written only through the shippo_test_* functions).
GRANT SELECT, INSERT ON us_booking.shippo_test_shipment TO us_booking_app;
GRANT SELECT, INSERT, UPDATE ON us_booking.shippo_test_purchase TO us_booking_app;
GRANT SELECT, INSERT ON us_booking.shippo_test_label TO us_booking_app;
GRANT USAGE ON us_booking.shippo_test_shipment_id_seq, us_booking.shippo_test_purchase_id_seq, us_booking.shippo_test_label_id_seq TO us_booking_app;
GRANT EXECUTE ON FUNCTION
  us_booking.shippo_test_shipment_add(jsonb), us_booking.shippo_test_purchase_begin(jsonb), us_booking.shippo_test_purchase_finish(jsonb),
  us_booking.shippo_test_purchase_resolve(jsonb), us_booking.shippo_test_label_add(jsonb)
TO us_booking_app;

-- Added with 0013 (carrier/carrier-account backfill, label format setting). New columns on
-- shippo_test_purchase/shippo_test_label are covered by the table-level grants just above.
GRANT SELECT, UPDATE ON us_booking.shippo_test_settings TO us_booking_app;
GRANT EXECUTE ON FUNCTION
  us_booking.shippo_test_purchase_recover_details(jsonb), us_booking.shippo_test_set_label_format(jsonb)
TO us_booking_app;
