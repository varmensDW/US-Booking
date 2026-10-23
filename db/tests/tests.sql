-- Behaviour tests for the proposed us_booking schema. Runs against synthetic fixtures only.
-- Runtime behaviour is exercised as us_booking_app; owner-only steps switch role explicitly.
\set ON_ERROR_STOP 1
SET client_min_messages = notice;

-- ============================================================================================
-- T0 Privileges: runtime role is DML-only and cannot change audit or trigger-maintained tables.
-- ============================================================================================
SELECT test_support.ok('T0 app has no UPDATE on event_log',   NOT has_table_privilege('us_booking_app', 'us_booking.event_log', 'UPDATE'));
SELECT test_support.ok('T0 app has no DELETE on event_log',   NOT has_table_privilege('us_booking_app', 'us_booking.event_log', 'DELETE'));
SELECT test_support.ok('T0 app has no TRUNCATE on event_log', NOT has_table_privilege('us_booking_app', 'us_booking.event_log', 'TRUNCATE'));
SELECT test_support.ok('T0 app can INSERT event_log',         has_table_privilege('us_booking_app', 'us_booking.event_log', 'INSERT'));
SELECT test_support.ok('T0 app UPDATE on parcel still works (general UPDATE does not cover event_log)',
                       has_table_privilege('us_booking_app', 'us_booking.parcel', 'UPDATE'));
SELECT test_support.ok('T0 app cannot write item_allocation',
                       NOT has_table_privilege('us_booking_app', 'us_booking.item_allocation', 'INSERT')
                       AND NOT has_table_privilege('us_booking_app', 'us_booking.item_allocation', 'UPDATE'));
SELECT test_support.ok('T0 app cannot write country_map',
                       NOT has_table_privilege('us_booking_app', 'us_booking.country_map', 'INSERT')
                       AND NOT has_table_privilege('us_booking_app', 'us_booking.country_map', 'UPDATE'));
SELECT test_support.ok('T0 app cannot create in schema',      NOT has_schema_privilege('us_booking_app', 'us_booking', 'CREATE'));
SELECT test_support.ok('T0 app cannot create in database',    NOT has_database_privilege('us_booking_app', current_database(), 'CREATE'));

SET ROLE us_booking_app;

-- ============================================================================================
-- T8 Raw OMS timestamps: stored exactly as given, no zone conversion anywhere.
-- ============================================================================================
SELECT test_support.ok('T8 order_date_raw stored unchanged',
  (SELECT order_date_raw FROM us_booking.oms_order WHERE oms_order_id = 9001) = timestamp '2026-10-21 23:30:00');
SELECT test_support.ok('T8 order_date_raw is timestamp without time zone',
  (SELECT data_type FROM information_schema.columns
    WHERE table_schema = 'us_booking' AND table_name = 'oms_order' AND column_name = 'order_date_raw') = 'timestamp without time zone');
SELECT test_support.ok('T8 no generated (converted) columns in schema',
  NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'us_booking' AND is_generated = 'ALWAYS'));

-- ============================================================================================
-- T7 Destination and scope: per-order confirmation, separate from the global country map.
-- ============================================================================================
SELECT test_support.ok('T7 US order in scope via order confirmation',
  (SELECT scope_status = 'in_scope' AND destination_source = 'order_confirmation' FROM us_booking.v_order_scope WHERE oms_order_id = 9001));
SELECT test_support.ok('T7 Canada order in scope',
  (SELECT scope_status = 'in_scope' AND destination_iso2 = 'CA' FROM us_booking.v_order_scope WHERE oms_order_id = 9002));
SELECT test_support.ok('T7 GB order out of scope',
  (SELECT scope_status FROM us_booking.v_order_scope WHERE oms_order_id = 9004) = 'out_of_scope');
SELECT test_support.ok('T7 confirmations did not create country_map rows (only the two from 0006 exist)',
  (SELECT count(*) FROM us_booking.country_map) = 2
  AND NOT EXISTS (SELECT 1 FROM us_booking.country_map WHERE oms_country_id NOT IN (8, 359)));
SELECT test_support.expect_error('T7 app cannot write the global country map',
  $q$INSERT INTO us_booking.country_map (oms_country_id, iso2, status) VALUES (8, 'US', 'unverified')$q$,
  'permission denied');
SELECT test_support.expect_error('T7 one active confirmation per order',
  $q$INSERT INTO us_booking.order_destination_confirmation (oms_order_id, destination_iso2, evidence_type, evidence_ref, ship_address_hash, confirmed_by)
     VALUES (9001, 'CA', 'other', 'x', 'addr-9001', 'tester@example.test')$q$,
  'duplicate key');
SELECT test_support.expect_error('T7 confirmation needs evidence',
  $q$INSERT INTO us_booking.order_destination_confirmation (oms_order_id, destination_iso2, evidence_type, evidence_ref, ship_address_hash, confirmed_by)
     VALUES (9003, 'US', 'other', '   ', 'addr-9003', 'tester@example.test')$q$,
  'check constraint');
-- Ship-to changes after confirmation -> confirmation is stale, scope becomes undetermined.
UPDATE us_booking.oms_order SET ship_address_hash = 'addr-9003-changed' WHERE oms_order_id = 9003;
SELECT test_support.ok('T7 stale confirmation no longer resolves destination',
  (SELECT scope_status = 'undetermined' FROM us_booking.v_order_scope WHERE oms_order_id = 9003)
  AND (SELECT confirmation_stale FROM us_booking.v_order_destination WHERE oms_order_id = 9003));
UPDATE us_booking.oms_order SET ship_address_hash = 'addr-9003' WHERE oms_order_id = 9003;
-- A verified global mapping that disagrees with an order confirmation -> conflict, no destination.
SET ROLE us_booking_owner;
INSERT INTO us_booking.country_map (oms_country_id, iso2, status, evidence, verified_by, verified_at)
VALUES (12, 'US', 'verified', 'synthetic test evidence', 'tester@example.test', now());
SET ROLE us_booking_app;
SELECT test_support.ok('T7 map/confirmation disagreement is a conflict',
  (SELECT destination_source = 'conflict' AND destination_iso2 IS NULL FROM us_booking.v_order_destination WHERE oms_order_id = 9002)
  AND (SELECT scope_status FROM us_booking.v_order_scope WHERE oms_order_id = 9002) = 'undetermined');
SET ROLE us_booking_owner;
DELETE FROM us_booking.country_map WHERE oms_country_id = 12;
SET ROLE us_booking_app;
SET ROLE us_booking_owner;
SELECT test_support.expect_error('T7 verified map row needs evidence and a verifier',
  $q$INSERT INTO us_booking.country_map (oms_country_id, iso2, status) VALUES (18, 'US', 'verified')$q$,
  'check constraint');
SET ROLE us_booking_app;

-- ============================================================================================
-- T4 Measurements: positive when supplied, with units and a source, complete before booking.
-- ============================================================================================
SELECT test_support.expect_error('T4 zero length rejected',
  $q$INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, length, width, height, dimension_unit, dimensions_source, measured_by, measured_at)
     VALUES (test_support.gid(9001), 9, 0, 1, 1, 'in', 'staff', 'packer@example.test', now())$q$,
  'parcel_length_check');
SELECT test_support.expect_error('T4 negative weight rejected',
  $q$INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, weight, weight_unit, weight_source, measured_by, measured_at)
     VALUES (test_support.gid(9001), 9, -1, 'lb', 'staff', 'packer@example.test', now())$q$,
  'parcel_weight_check');
SELECT test_support.expect_error('T4 negative width rejected',
  $q$INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, length, width, height, dimension_unit, dimensions_source, measured_by, measured_at)
     VALUES (test_support.gid(9001), 9, 1, -0.5, 1, 'in', 'staff', 'packer@example.test', now())$q$,
  'parcel_width_check');
SELECT test_support.expect_error('T4 partial dimensions rejected',
  $q$INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, length, width) VALUES (test_support.gid(9001), 9, 10, 8)$q$,
  'parcel_dimensions_complete');
SELECT test_support.expect_error('T4 dimensions need a unit',
  $q$INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, length, width, height, dimensions_source, measured_by, measured_at)
     VALUES (test_support.gid(9001), 9, 1, 1, 1, 'staff', 'packer@example.test', now())$q$,
  'parcel_dimensions_complete');
SELECT test_support.expect_error('T4 unknown dimension unit rejected',
  $q$INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, length, width, height, dimension_unit, dimensions_source, measured_by, measured_at)
     VALUES (test_support.gid(9001), 9, 1, 1, 1, 'ft', 'staff', 'packer@example.test', now())$q$,
  'parcel_dimension_unit_check');

-- Parcel 1 of group 9001: staff-measured dimensions, weight not entered yet.
INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, length, width, height, dimension_unit, dimensions_source, measured_by, measured_at)
VALUES (test_support.gid(9001), 1, 10, 8, 4, 'in', 'staff', 'packer@example.test', now());
SELECT test_support.expect_error('T4 negative height on update rejected',
  $q$UPDATE us_booking.parcel SET height = -2 WHERE id = test_support.pid(9001, 1)$q$,
  'parcel_height_check');
SELECT test_support.expect_error('T4 staff-entered values must name who entered them',
  $q$UPDATE us_booking.parcel SET measured_by = NULL, measured_at = NULL WHERE id = test_support.pid(9001, 1)$q$,
  'parcel_measured_by_only_for_staff_values');
SELECT test_support.expect_error('T4 profile source needs a recorded profile version',
  $q$UPDATE us_booking.parcel SET dimensions_source = 'profile', measured_by = NULL, measured_at = NULL WHERE id = test_support.pid(9001, 1)$q$,
  'parcel_profile_source_needs_profile');
INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity) VALUES
  (test_support.pid(9001, 1), test_support.gid(9001), 9001, 90011, 2),
  (test_support.pid(9001, 1), test_support.gid(9001), 9001, 90012, 1);

-- ============================================================================================
-- T3 Mismatched relationships.
-- ============================================================================================
SELECT test_support.expect_error('T3 item from another group''s order',
  $q$INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 9003, 90031, 1)$q$,
  'not an active member');
SELECT test_support.expect_error('T3 item claimed through the other group id',
  $q$INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity)
     VALUES (test_support.pid(9001, 1), test_support.gid(9003), 9003, 90031, 1)$q$,
  'foreign key');
SELECT test_support.expect_error('T3 item paired with the wrong order',
  $q$INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 9001, 90031, 1)$q$,
  'foreign key');
SELECT test_support.expect_error('T3 order cannot be active in two groups',
  $q$INSERT INTO us_booking.fulfilment_group_order (fulfilment_group_id, oms_order_id, role) VALUES (test_support.gid(9001), 9003, 'merge_child')$q$,
  'duplicate key');
-- Inactive membership: deactivate 9003 in its own group, then try to allocate its item.
UPDATE us_booking.fulfilment_group_order SET active = false WHERE fulfilment_group_id = test_support.gid(9003);
SELECT test_support.expect_error('T3 inactive member cannot be allocated',
  $q$INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity)
     VALUES (test_support.pid(9003, 1), test_support.gid(9003), 9003, 90031, 1)$q$,
  'not an active member');
UPDATE us_booking.fulfilment_group_order SET active = true WHERE fulfilment_group_id = test_support.gid(9003);
SELECT test_support.ok('T3 failed inserts left no allocation behind',
  NOT EXISTS (SELECT 1 FROM us_booking.item_allocation WHERE oms_order_item_id = 90031 AND allocated_qty <> 0));
SELECT test_support.expect_error('T3 attempt on a parcel with another group''s id',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9003), 'shippo', 'shippo-test-acct', 1, 'k-mismatch-1', 'rh', 'tester@example.test')$q$,
  'measurements are incomplete|foreign key');
SELECT test_support.expect_error('T3 attempt provider differs from group provider',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'wayfair_partner', 'shippo-test-acct', 1, 'k-mismatch-2', 'rh', 'tester@example.test')$q$,
  'measurements are incomplete|foreign key');

-- Over-allocation, sequential: line 90011 has 3 ordered, 2 already in parcel 1.
INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no) VALUES (test_support.gid(9001), 2);
SELECT test_support.expect_error('T5 sequential over-allocation rejected',
  $q$INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity)
     VALUES (test_support.pid(9001, 2), test_support.gid(9001), 9001, 90011, 2)$q$,
  'over-allocation');
INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity)
VALUES (test_support.pid(9001, 2), test_support.gid(9001), 9001, 90011, 1);
SELECT test_support.ok('T5 allocation reaches exactly the ordered quantity',
  (SELECT allocated_qty FROM us_booking.item_allocation WHERE oms_order_item_id = 90011) = 3);
UPDATE us_booking.parcel SET state = 'cancelled' WHERE id = test_support.pid(9001, 2);
SELECT test_support.ok('T5 cancelling a parcel releases its allocation',
  (SELECT allocated_qty FROM us_booking.item_allocation WHERE oms_order_item_id = 90011) = 2);
SELECT test_support.expect_error('T5 cancelled parcel is final',
  $q$UPDATE us_booking.parcel SET state = 'open' WHERE id = test_support.pid(9001, 2)$q$,
  'cancellation is final');

-- Back to T4: completeness before booking.
SELECT test_support.expect_error('T4 attempt rejected: weight missing',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 1, 'usb:oms:9001:g1:p1:a1', 'rh1', 'tester@example.test')$q$,
  'measurements are incomplete');
SELECT test_support.expect_error('T4 weight needs a unit',
  $q$UPDATE us_booking.parcel SET weight = 2.5, weight_source = 'staff' WHERE id = test_support.pid(9001, 1)$q$,
  'parcel_weight_complete');
UPDATE us_booking.parcel SET weight = 2.5, weight_unit = 'lb', weight_source = 'staff' WHERE id = test_support.pid(9001, 1);
SELECT test_support.expect_error('T4 attempt rejected: contents not confirmed',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 1, 'usb:oms:9001:g1:p1:a1', 'rh1', 'tester@example.test')$q$,
  'contents are not staff-confirmed');
UPDATE us_booking.parcel SET contents_status = 'confirmed', confirmed_by = 'packer@example.test', confirmed_at = now()
 WHERE id = test_support.pid(9001, 1);
SELECT test_support.expect_error('T4 confirmed contents cannot be edited',
  $q$UPDATE us_booking.parcel_item SET quantity = 1 WHERE parcel_id = test_support.pid(9001, 1) AND oms_order_item_id = 90011$q$,
  'unconfirm before changing');

-- Now the composite-key mismatches reach the foreign keys themselves.
SELECT test_support.expect_error('T3 attempt with another group''s id hits FK',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9003), 'shippo', 'shippo-test-acct', 1, 'k-mismatch-3', 'rh', 'tester@example.test')$q$,
  'booking_attempt_parcel_id_fulfilment_group_id_fkey');
SELECT test_support.expect_error('T3 attempt provider mismatch hits FK',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'some-other-acct', 1, 'k-mismatch-4', 'rh', 'tester@example.test')$q$,
  'booking_attempt_fulfilment_group_id_provider_provider_acco_fkey|fulfilment_group_id_provider');

-- ============================================================================================
-- T1 Duplicate purchases and unresolved outcomes.
-- ============================================================================================
INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 1, 'usb:oms:9001:g1:p1:a1', 'rh1', 'tester@example.test');
SELECT test_support.ok('T1 first attempt created', test_support.aid(9001, 1, 1) IS NOT NULL);
SELECT test_support.expect_error('T1 second purchase while first is pending',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 2, 'usb:oms:9001:g1:p1:a2', 'rh1', 'tester@example.test')$q$,
  'already has a pending');
SELECT test_support.expect_error('T1 app cannot disable the booking guard trigger',
  $q$ALTER TABLE us_booking.booking_attempt DISABLE TRIGGER booking_attempt_insert$q$,
  'must be owner');
-- Backstop: with the guard trigger disabled (superuser, rolled back), the partial unique index alone
-- still refuses a second live attempt for the parcel.
RESET ROLE;
BEGIN;
ALTER TABLE us_booking.booking_attempt DISABLE TRIGGER booking_attempt_insert;
SELECT test_support.expect_error('T1 partial unique index blocks a second live attempt without the trigger',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 2, 'usb:oms:9001:g1:p1:a2', 'rh1', 'tester@example.test')$q$,
  'booking_attempt_one_blocking_per_parcel');
ROLLBACK;
SET ROLE us_booking_app;
SELECT test_support.expect_error('T1 measurements frozen while purchase pending',
  $q$UPDATE us_booking.parcel SET weight = 3 WHERE id = test_support.pid(9001, 1)$q$,
  'frozen');
UPDATE us_booking.booking_attempt SET state = 'request_sent', sent_at = now() WHERE id = test_support.aid(9001, 1, 1);
UPDATE us_booking.booking_attempt SET state = 'unknown', error_message = 'synthetic timeout' WHERE id = test_support.aid(9001, 1, 1);
SELECT test_support.expect_error('T1 second purchase while outcome unknown',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 2, 'usb:oms:9001:g1:p1:a2', 'rh1', 'tester@example.test')$q$,
  'already has a pending');
SELECT test_support.expect_error('T1 unknown cannot be marked failed',
  $q$UPDATE us_booking.booking_attempt SET state = 'failed' WHERE id = test_support.aid(9001, 1, 1)$q$,
  'cannot move from unknown to failed');
SELECT test_support.expect_error('T1 unknown cannot be resolved without evidence',
  $q$UPDATE us_booking.booking_attempt SET state = 'reconciled_not_found' WHERE id = test_support.aid(9001, 1, 1)$q$,
  'check constraint');
SELECT test_support.expect_error('T1 unknown cannot be released',
  $q$UPDATE us_booking.booking_attempt SET released_at = now(), released_by = 'x', release_reason = 'x' WHERE id = test_support.aid(9001, 1, 1)$q$,
  'confirmed the void|check constraint');
SELECT test_support.expect_error('T1 parcel contents frozen while outcome unknown',
  $q$DELETE FROM us_booking.parcel_item WHERE parcel_id = test_support.pid(9001, 1)$q$,
  'frozen|unconfirm');
SELECT test_support.expect_error('T1 found outcome needs a provider_shipment at commit',
  $q$UPDATE us_booking.booking_attempt
        SET state = 'reconciled_found', resolution_evidence = 'synthetic', resolved_by = 'tester@example.test', resolved_at = now()
      WHERE id = test_support.aid(9001, 1, 1);
     SET CONSTRAINTS ALL IMMEDIATE$q$,
  'has no provider_shipment');

-- Reconcile properly: label found at the provider by correlation key.
BEGIN;
INSERT INTO us_booking.provider_shipment (booking_attempt_id, parcel_id, provider, provider_account, provider_label_ref, tracking_number, carrier, amount, currency)
VALUES (test_support.aid(9001, 1, 1), test_support.pid(9001, 1), 'shippo', 'shippo-test-acct', 'syn-txn-0001', 'SYNTRK0001', 'USPS', 6.45, 'USD');
UPDATE us_booking.booking_attempt
   SET state = 'reconciled_found', resolution_evidence = 'synthetic: provider label with matching metadata',
       resolved_by = 'tester@example.test', resolved_at = now()
 WHERE id = test_support.aid(9001, 1, 1);
UPDATE us_booking.parcel SET state = 'booked' WHERE id = test_support.pid(9001, 1);
COMMIT;
SELECT test_support.expect_error('T1 no new purchase while a label is active',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 2, 'usb:oms:9001:g1:p1:a2', 'rh1', 'tester@example.test')$q$,
  'already has a pending');
SELECT test_support.expect_error('T1 a second live label for the same parcel',
  $q$INSERT INTO us_booking.provider_shipment (booking_attempt_id, parcel_id, provider, provider_account, provider_label_ref)
     VALUES (test_support.aid(9001, 1, 1), test_support.pid(9001, 1), 'shippo', 'shippo-test-acct', 'syn-txn-dup')$q$,
  'duplicate key');

-- ============================================================================================
-- T2 Reprint, confirmed void and controlled replacement.
-- ============================================================================================
INSERT INTO us_booking.label_file (provider_shipment_id, format, storage_uri, sha256)
SELECT id, 'PDF_4x6', 'test://labels/syn-txn-0001.pdf', repeat('a', 64) FROM us_booking.provider_shipment WHERE provider_label_ref = 'syn-txn-0001';
INSERT INTO us_booking.print_event (label_file_id, kind, client_request_id, requested_by)
SELECT f.id, 'initial', 'print-1', 'packer@example.test' FROM us_booking.label_file f WHERE f.storage_uri = 'test://labels/syn-txn-0001.pdf';
SELECT test_support.expect_error('T2 reprint needs a reason',
  $q$INSERT INTO us_booking.print_event (label_file_id, kind, client_request_id, requested_by)
     SELECT id, 'reprint', 'print-2', 'packer@example.test' FROM us_booking.label_file WHERE storage_uri = 'test://labels/syn-txn-0001.pdf'$q$,
  'check constraint');
INSERT INTO us_booking.print_event (label_file_id, kind, client_request_id, requested_by, reason)
SELECT id, 'reprint', 'print-2', 'packer@example.test', 'printer jam' FROM us_booking.label_file WHERE storage_uri = 'test://labels/syn-txn-0001.pdf';
SELECT test_support.expect_error('T2 double-clicked reprint deduplicated',
  $q$INSERT INTO us_booking.print_event (label_file_id, kind, client_request_id, requested_by, reason)
     SELECT id, 'reprint', 'print-2', 'packer@example.test', 'printer jam' FROM us_booking.label_file WHERE storage_uri = 'test://labels/syn-txn-0001.pdf'$q$,
  'duplicate key');
SELECT test_support.ok('T2 reprint added no booking attempt',
  (SELECT count(*) FROM us_booking.booking_attempt WHERE parcel_id = test_support.pid(9001, 1)) = 1);
SELECT test_support.expect_error('T2 release before void',
  $q$UPDATE us_booking.booking_attempt SET released_at = now(), released_by = 'sup@example.test', release_reason = 'damaged label'
      WHERE id = test_support.aid(9001, 1, 1)$q$,
  'confirmed the void');
SELECT test_support.expect_error('T2 label cannot jump from active to voided',
  $q$UPDATE us_booking.provider_shipment SET label_status = 'voided', void_requested_by = 'sup@example.test', void_requested_at = now(),
            void_confirmed_at = now(), void_evidence = 'x' WHERE provider_label_ref = 'syn-txn-0001'$q$,
  'cannot move from active to voided');
UPDATE us_booking.provider_shipment SET label_status = 'void_requested', void_requested_by = 'sup@example.test', void_requested_at = now()
 WHERE provider_label_ref = 'syn-txn-0001';
SELECT test_support.expect_error('T2 cannot print a label with a void pending',
  $q$INSERT INTO us_booking.print_event (label_file_id, kind, client_request_id, requested_by, reason)
     SELECT id, 'reprint', 'print-3', 'packer@example.test', 'again' FROM us_booking.label_file WHERE storage_uri = 'test://labels/syn-txn-0001.pdf'$q$,
  'only active labels');
SELECT test_support.expect_error('T2 release while void only requested',
  $q$UPDATE us_booking.booking_attempt SET released_at = now(), released_by = 'sup@example.test', release_reason = 'damaged label'
      WHERE id = test_support.aid(9001, 1, 1)$q$,
  'confirmed the void');
SELECT test_support.expect_error('T2 voided requires provider evidence',
  $q$UPDATE us_booking.provider_shipment SET label_status = 'voided' WHERE provider_label_ref = 'syn-txn-0001'$q$,
  'check constraint');
UPDATE us_booking.provider_shipment
   SET label_status = 'voided', void_confirmed_at = now(), void_provider_ref = 'syn-refund-1', void_evidence = 'synthetic: provider refund status SUCCESS'
 WHERE provider_label_ref = 'syn-txn-0001';
SELECT test_support.expect_error('T2 still blocked until the attempt is released',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key,
       replaces_attempt_id, authorised_by, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 2, 'usb:oms:9001:g1:p1:a2',
       test_support.aid(9001, 1, 1), 'sup@example.test', 'rh1', 'tester@example.test')$q$,
  'already has a pending');
UPDATE us_booking.booking_attempt SET released_at = now(), released_by = 'sup@example.test', release_reason = 'damaged label, void confirmed'
 WHERE id = test_support.aid(9001, 1, 1);
UPDATE us_booking.parcel SET state = 'open' WHERE id = test_support.pid(9001, 1);
SELECT test_support.expect_error('T2 replacement must name the replaced attempt',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 2, 'usb:oms:9001:g1:p1:a2', 'rh1', 'tester@example.test')$q$,
  'must name attempt');
SELECT test_support.expect_error('T2 replacement must be authorised',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key,
       replaces_attempt_id, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 2, 'usb:oms:9001:g1:p1:a2',
       test_support.aid(9001, 1, 1), 'rh1', 'tester@example.test')$q$,
  'check constraint');
SELECT test_support.expect_error('T2 generation must be consecutive',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key,
       replaces_attempt_id, authorised_by, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 5, 'usb:oms:9001:g1:p1:a5',
       test_support.aid(9001, 1, 1), 'sup@example.test', 'rh1', 'tester@example.test')$q$,
  'attempt_generation must be 2');
INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key,
  replaces_attempt_id, authorised_by, request_hash, requested_by)
VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 2, 'usb:oms:9001:g1:p1:a2',
  test_support.aid(9001, 1, 1), 'sup@example.test', 'rh1', 'tester@example.test');
SELECT test_support.expect_error('T2 replacement in flight blocks a third purchase',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key,
       replaces_attempt_id, authorised_by, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 3, 'usb:oms:9001:g1:p1:a3',
       test_support.aid(9001, 1, 1), 'sup@example.test', 'rh1', 'tester@example.test')$q$,
  'already has a pending');
BEGIN;
UPDATE us_booking.booking_attempt SET state = 'request_sent', sent_at = now() WHERE id = test_support.aid(9001, 1, 2);
INSERT INTO us_booking.provider_shipment (booking_attempt_id, parcel_id, provider, provider_account, provider_label_ref, tracking_number, carrier, amount, currency)
VALUES (test_support.aid(9001, 1, 2), test_support.pid(9001, 1), 'shippo', 'shippo-test-acct', 'syn-txn-0002', 'SYNTRK0002', 'USPS', 6.45, 'USD');
UPDATE us_booking.booking_attempt SET state = 'succeeded', responded_at = now(), provider_status = 'SUCCESS' WHERE id = test_support.aid(9001, 1, 2);
UPDATE us_booking.parcel SET state = 'booked' WHERE id = test_support.pid(9001, 1);
COMMIT;
SELECT test_support.ok('T2 earlier successful attempt kept, released',
  (SELECT state = 'reconciled_found' AND released_at IS NOT NULL FROM us_booking.booking_attempt WHERE id = test_support.aid(9001, 1, 1)));
SELECT test_support.ok('T2 voided label kept, exactly one live label',
  (SELECT count(*) FILTER (WHERE label_status = 'voided') = 1 AND count(*) FILTER (WHERE label_status <> 'voided') = 1
     FROM us_booking.provider_shipment WHERE parcel_id = test_support.pid(9001, 1)));
SELECT test_support.expect_error('T2 release is final',
  $q$UPDATE us_booking.booking_attempt SET released_at = NULL WHERE id = test_support.aid(9001, 1, 1)$q$,
  'release is final|check constraint');
SELECT test_support.expect_error('T2 voided label cannot be reactivated',
  $q$UPDATE us_booking.provider_shipment SET label_status = 'active' WHERE provider_label_ref = 'syn-txn-0001'$q$,
  'cannot move from voided');
SELECT test_support.expect_error('T3 sent request is frozen',
  $q$UPDATE us_booking.booking_attempt SET rate_ref = 'other-rate' WHERE id = test_support.aid(9001, 1, 2)$q$,
  'frozen once sent');

-- ============================================================================================
-- T9 Scope, routing and requirements gate booking (Canada stays bookable).
-- ============================================================================================
-- Out-of-scope GB order (9004) and unverified Amazon routing (9005), each with a complete parcel.
INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, length, width, height, dimension_unit, dimensions_source,
                               weight, weight_unit, weight_source, measured_by, measured_at)
VALUES (test_support.gid(9004), 1, 6, 6, 6, 'in', 'staff', 1, 'lb', 'staff', 'packer@example.test', now()),
       (test_support.gid(9005), 1, 6, 6, 6, 'in', 'staff', 1, 'lb', 'staff', 'packer@example.test', now()),
       (test_support.gid(9002), 1, 30, 23, 13, 'cm', 'staff', 0.55, 'kg', 'staff', 'packer@example.test', now());
INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity) VALUES
  (test_support.pid(9004, 1), test_support.gid(9004), 9004, 90041, 1),
  (test_support.pid(9005, 1), test_support.gid(9005), 9005, 90051, 1),
  (test_support.pid(9002, 1), test_support.gid(9002), 9002, 90021, 1);
UPDATE us_booking.parcel SET contents_status = 'confirmed', confirmed_by = 'packer@example.test', confirmed_at = now()
 WHERE id IN (test_support.pid(9004, 1), test_support.pid(9005, 1), test_support.pid(9002, 1));
SELECT test_support.expect_error('T9 out-of-scope destination cannot be booked',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9004, 1), test_support.gid(9004), 'shippo', 'shippo-test-acct', 1, 'usb:oms:9004:g1:p1:a1', 'rh', 'tester@example.test')$q$,
  'not in scope');
SELECT test_support.expect_error('T9 unverified integration cannot be booked',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9005, 1), test_support.gid(9005), 'amazon_seller_central', 'amz-test-acct', 1, 'usb:oms:9005:g1:p1:a1', 'rh', 'tester@example.test')$q$,
  'verified amazon_seller_central integration');
-- Canada: in scope, but customs declaration still missing -> requirement blocks, not scope.
INSERT INTO us_booking.shipment_requirement (fulfilment_group_id, requirement, status, detail, checked_by)
VALUES (test_support.gid(9002), 'customs_declaration', 'unmet', 'synthetic: customs lines not entered', 'system:test');
SELECT test_support.ok('T9 unmet requirement leaves scope unchanged',
  (SELECT scope_status FROM us_booking.v_order_scope WHERE oms_order_id = 9002) = 'in_scope');
SELECT test_support.expect_error('T9 unmet requirement blocks booking',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9002, 1), test_support.gid(9002), 'shippo', 'shippo-test-acct', 1, 'usb:oms:9002:g1:p1:a1', 'rh', 'tester@example.test')$q$,
  'unmet shipment requirements');
UPDATE us_booking.shipment_requirement SET status = 'met', checked_by = 'packer@example.test', checked_at = now()
 WHERE fulfilment_group_id = test_support.gid(9002) AND requirement = 'customs_declaration';
INSERT INTO us_booking.review_case (case_type, oms_order_id, details) VALUES ('cancellation', 9002, '{"note":"synthetic"}');
SELECT test_support.expect_error('T9 open review case blocks booking',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9002, 1), test_support.gid(9002), 'shippo', 'shippo-test-acct', 1, 'usb:oms:9002:g1:p1:a1', 'rh', 'tester@example.test')$q$,
  'open review cases');
UPDATE us_booking.review_case SET status = 'resolved', resolved_by = 'sup@example.test', resolved_at = now(), resolution = 'not cancelled'
 WHERE oms_order_id = 9002;
SELECT test_support.expect_error('T1 correlation key reused on another parcel',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9002, 1), test_support.gid(9002), 'shippo', 'shippo-test-acct', 1, 'usb:oms:9001:g1:p1:a1', 'rh', 'tester@example.test')$q$,
  'duplicate key');
INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
VALUES (test_support.pid(9002, 1), test_support.gid(9002), 'shippo', 'shippo-test-acct', 1, 'usb:oms:9002:g1:p1:a1', 'rh', 'tester@example.test');
SELECT test_support.ok('T9 Canada parcel bookable once requirements met and case resolved', test_support.aid(9002, 1, 1) IS NOT NULL);

-- Label rows must match their attempt's parcel and provider (attempt 9002/p1/a1 has no label yet).
SELECT test_support.expect_error('T3 provider_shipment for an attempt of another parcel',
  $q$INSERT INTO us_booking.provider_shipment (booking_attempt_id, parcel_id, provider, provider_account, provider_label_ref)
     VALUES (test_support.aid(9002, 1, 1), test_support.pid(9004, 1), 'shippo', 'shippo-test-acct', 'syn-txn-wrong')$q$,
  'provider_shipment_booking_attempt_id_parcel_id_provider_pr_fkey|foreign key');
SELECT test_support.expect_error('T3 provider_shipment with a different provider than its attempt',
  $q$INSERT INTO us_booking.provider_shipment (booking_attempt_id, parcel_id, provider, provider_account, provider_label_ref)
     VALUES (test_support.aid(9002, 1, 1), test_support.pid(9002, 1), 'wayfair_partner', 'shippo-test-acct', 'syn-txn-wrong2')$q$,
  'provider_shipment_booking_attempt_id_parcel_id_provider_pr_fkey|foreign key');
SELECT test_support.expect_error('T3 label for an attempt still in created state',
  $q$INSERT INTO us_booking.provider_shipment (booking_attempt_id, parcel_id, provider, provider_account, provider_label_ref)
     VALUES (test_support.aid(9002, 1, 1), test_support.pid(9002, 1), 'shippo', 'shippo-test-acct', 'syn-txn-early');
     SET CONSTRAINTS ALL IMMEDIATE$q$,
  'belongs to attempt .* in state created');

-- ============================================================================================
-- T6 event_log is append-only.
-- ============================================================================================
INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor)
VALUES ('booking_attempt', test_support.aid(9001, 1, 2), 'request_sent', 'succeeded', 'system:test');
SELECT test_support.ok('T6 app can append to event_log', (SELECT count(*) FROM us_booking.event_log WHERE actor = 'system:test') = 1);
SELECT test_support.expect_error('T6 app UPDATE rejected',   $q$UPDATE us_booking.event_log SET actor = 'x'$q$, 'permission denied');
SELECT test_support.expect_error('T6 app DELETE rejected',   $q$DELETE FROM us_booking.event_log$q$, 'permission denied');
SELECT test_support.expect_error('T6 app TRUNCATE rejected', $q$TRUNCATE us_booking.event_log$q$, 'permission denied');
SET ROLE us_booking_owner;
SELECT test_support.expect_error('T6 even the owner cannot UPDATE',   $q$UPDATE us_booking.event_log SET actor = 'x'$q$, 'append-only');
SELECT test_support.expect_error('T6 even the owner cannot DELETE',   $q$DELETE FROM us_booking.event_log$q$, 'append-only');
SELECT test_support.expect_error('T6 even the owner cannot TRUNCATE', $q$TRUNCATE us_booking.event_log$q$, 'append-only');
RESET ROLE;
SELECT test_support.ok('T6 event_log rows intact (the test row and the two 0006 rows)',
  (SELECT array_agg(actor ORDER BY id) FROM us_booking.event_log) = '{migration:0006,migration:0006,system:test}');

-- ============================================================================================
-- T10 Single-role operation (approved setup: the owner login is also the runtime login).
-- Business rules enforced by constraints, unique indexes and enabled triggers bind the owner too.
-- Privilege-based restrictions do not; the "limitation" checks record that explicitly.
-- ============================================================================================
SELECT test_support.ok('T10 PUBLIC has no USAGE on us_booking',  NOT has_schema_privilege('public', 'us_booking', 'USAGE'));
SELECT test_support.ok('T10 PUBLIC has no CREATE on us_booking', NOT has_schema_privilege('public', 'us_booking', 'CREATE'));
SELECT test_support.ok('T10 PUBLIC cannot execute adjust_allocation',
  NOT has_function_privilege('public', 'us_booking.adjust_allocation(bigint, integer)', 'EXECUTE'));
SET ROLE us_booking_owner;
SELECT test_support.expect_error('T10 owner: second purchase while a label is active',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     VALUES (test_support.pid(9001, 1), test_support.gid(9001), 'shippo', 'shippo-test-acct', 9, 'usb:owner-dup', 'rh1', 'tester@example.test')$q$,
  'already has a pending');
SELECT test_support.expect_error('T10 owner: booked parcel measurements frozen',
  $q$UPDATE us_booking.parcel SET weight = 9 WHERE id = test_support.pid(9001, 1)$q$,
  'frozen|locked');
SELECT test_support.expect_error('T10 owner: zero dimension rejected',
  $q$WITH p AS (INSERT INTO us_booking.package_profile (name) VALUES ('owner-zero') RETURNING id)
     INSERT INTO us_booking.package_profile_version (profile_id, version, length, width, height, dimension_unit, approved_by)
     SELECT id, 1, 0, 1, 1, 'in', 'owner@example.test' FROM p$q$,
  'check constraint');
SELECT test_support.expect_error('T10 owner: event_log UPDATE rejected', $q$UPDATE us_booking.event_log SET actor = 'x'$q$, 'append-only');
SELECT test_support.ok('T10 limitation: owner holds UPDATE/DELETE on event_log (only the trigger stops it)',
  has_table_privilege('us_booking.event_log', 'UPDATE') AND has_table_privilege('us_booking.event_log', 'DELETE'));
SELECT test_support.ok('T10 limitation: owner can write item_allocation and country_map directly',
  has_table_privilege('us_booking.item_allocation', 'UPDATE') AND has_table_privilege('us_booking.country_map', 'INSERT'));
BEGIN;
ALTER TABLE us_booking.booking_attempt DISABLE TRIGGER booking_attempt_insert;
SELECT test_support.ok('T10 limitation: owner can disable the booking guard trigger (rolled back)', true);
ROLLBACK;
SELECT test_support.ok('T10 booking guard trigger still enabled after rollback',
  (SELECT tgenabled FROM pg_trigger WHERE tgname = 'booking_attempt_insert') = 'O');
RESET ROLE;
