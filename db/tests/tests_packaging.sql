-- Tests for 0011: Wayfair-managed packaging, packaging exceptions, and unchanged Shippo/Amazon
-- measurement rules. Synthetic data only; runs after tests_wayfair_sandbox.sql.
\set ON_ERROR_STOP 1
SET client_min_messages = notice;
SET ROLE us_booking_owner;

-- Synthetic Wayfair orders through the real sync: 9401 single; 9402 + child 9403 merged.
CREATE FUNCTION pg_temp.wf_order(p_id bigint, p_merge text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT test_support.o(p_id, p_merge) || jsonb_build_object('source_id', 6, 'channel', 'WAYFAIR', 'sub_source_id', 258,
                                                             'platform_order_ref', 'SYN-WAY-' || p_id) $$;
SELECT test_support.ok('T24 synthetic Wayfair orders imported',
  (us_booking.oms_sync_apply(jsonb_build_object('format', 'us_booking.oms_snapshot.v1', 'extracted_at', clock_timestamp()::text, 'refresh_ids', '[]'::jsonb,
     'groups', jsonb_build_array(
       jsonb_build_object('container_id', 9401, 'combos', '[]'::jsonb, 'orders', jsonb_build_array(pg_temp.wf_order(9401, NULL)),
         'items', jsonb_build_array(test_support.i(94011, 9401, 9401, 'SYN-W1', 2))),
       jsonb_build_object('container_id', 9402, 'combos', '[]'::jsonb,
         'orders', jsonb_build_array(pg_temp.wf_order(9402, 'merged'), pg_temp.wf_order(9403, '9402')),
         'items', jsonb_build_array(test_support.i(94021, 9402, 9402, 'SYN-W2', 1), test_support.i(94031, 9402, 9403, 'SYN-W3', 1))))),
   'system:test-sync')->'counts'->>'groups_new')::int = 2);
SELECT test_support.ok('T24 the Wayfair orders are routed to Wayfair',
  (SELECT provider FROM us_booking.fulfilment_group WHERE id = test_support.gid(9401)) = 'wayfair_partner');

-- ============================================================================================
-- T24 Wayfair-managed packaging
-- ============================================================================================
SELECT test_support.ok('T24 policy recorded, production NOT verified',
  (SELECT mode = 'provider_managed' AND production_verified_at IS NULL AND sandbox_evidence IS NOT NULL
     FROM us_booking.provider_packaging_policy WHERE provider = 'wayfair_partner'));
SELECT test_support.staff('staff_parcel_create', jsonb_build_object('group_id', test_support.gid(9401)));
SELECT test_support.ok('T24 a Wayfair parcel starts Wayfair-managed: no measurements, no profile, no zeros, not measured by anyone',
  (SELECT packaging_mode = 'provider_managed' AND length IS NULL AND width IS NULL AND height IS NULL AND weight IS NULL
          AND dimension_unit IS NULL AND weight_unit IS NULL AND package_profile_id IS NULL AND measured_by IS NULL
     FROM us_booking.parcel WHERE id = test_support.pid(9401, 1)));
SELECT test_support.ok('T24 the measurement requirement is met by the Wayfair mode for a single purchase order',
  (SELECT status = 'met' AND detail LIKE '%Wayfair-managed packaging%' FROM us_booking.shipment_requirement
    WHERE fulfilment_group_id = test_support.gid(9401) AND requirement = 'parcel_measurements'));
SELECT test_support.expect_action_error('T24 entering measurements on a Wayfair-managed parcel is refused', 'staff_parcel_measure',
  jsonb_build_object('staff', 'Packer Two', 'parcel_id', test_support.pid(9401, 1), 'expected_row_version', test_support.rv(9401, 1),
                     'weight', jsonb_build_object('value', '2', 'unit', 'kg')),
  '23514', 'record a packaging exception before entering measurements');
SELECT test_support.expect_error('T24 a zero or any value cannot be stored on a Wayfair-managed parcel, even directly',
  $q$UPDATE us_booking.parcel SET weight = 0.001, weight_unit = 'kg', weight_source = 'staff', measured_by = 'x', measured_at = now()
      WHERE id = test_support.pid(9401, 1)$q$, 'packaging exception|parcel_provider_managed_has_no_measurements');
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9401, 1) || test_support.items(94011, 2) || '{"confirm": true}');
SELECT test_support.ok('T24 contents still need staff confirmation and are not taken from labels',
  (SELECT contents_status = 'confirmed' AND confirmed_by = 'Packer Two' FROM us_booking.parcel WHERE id = test_support.pid(9401, 1))
  AND (SELECT bool_and(status = 'met') FROM us_booking.shipment_requirement
        WHERE fulfilment_group_id = test_support.gid(9401) AND requirement IN ('parcel_measurements', 'parcel_contents')));

-- Merged Wayfair group: one registration covers one PO, so staff must decide.
SELECT test_support.staff('staff_parcel_create', jsonb_build_object('group_id', test_support.gid(9402)));
SELECT test_support.ok('T24 a merged Wayfair group (two POs) needs a staff decision',
  (SELECT status = 'unmet' AND detail LIKE '%covers one purchase order; this group has 2 orders%' FROM us_booking.shipment_requirement
    WHERE fulfilment_group_id = test_support.gid(9402) AND requirement = 'parcel_measurements'));

-- Packaging exception (consolidated / custom packaging).
SELECT test_support.expect_action_error('T24 a packaging exception needs a reason', 'staff_parcel_set_packaging',
  jsonb_build_object('staff', 'Packer Two', 'mode', 'measured', 'reason', '') || test_support.pv(9401, 1), 'UB422', 'Reason');
SELECT test_support.staff('staff_parcel_set_packaging', test_support.pv(9401, 1) || '{"mode": "measured", "reason": "synthetic: two items consolidated into one carton"}');
SELECT test_support.ok('T24 exception recorded; measurements now required (requirement unmet until entered)',
  (SELECT packaging_mode = 'measured' AND packaging_exception_reason LIKE 'synthetic: two items%' FROM us_booking.parcel WHERE id = test_support.pid(9401, 1))
  AND (SELECT status FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9401) AND requirement = 'parcel_measurements') = 'unmet');
SELECT test_support.expect_action_error('T24 Wayfair exception measurements must use the documented units (cm, kg)', 'staff_parcel_measure',
  jsonb_build_object('staff', 'Packer Two', 'parcel_id', test_support.pid(9401, 1), 'expected_row_version', test_support.rv(9401, 1),
                     'dimensions', jsonb_build_object('length', '12', 'width', '8', 'height', '6', 'unit', 'in'),
                     'weight', jsonb_build_object('value', '3', 'unit', 'lb')),
  '23514', 'centimetres and kilograms');
SELECT test_support.staff('staff_parcel_measure', test_support.pv(9401, 1) || jsonb_build_object(
  'dimensions', jsonb_build_object('length', '30', 'width', '20', 'height', '15', 'unit', 'cm'), 'weight', jsonb_build_object('value', '1.4', 'unit', 'kg')));
SELECT test_support.ok('T24 exception measurements entered by staff in cm/kg: requirement met',
  (SELECT status FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9401) AND requirement = 'parcel_measurements') = 'met'
  AND (SELECT measured_by = 'Packer Two' AND dimensions_source = 'staff' FROM us_booking.parcel WHERE id = test_support.pid(9401, 1)));
SELECT test_support.staff('staff_parcel_set_packaging', test_support.pv(9401, 1) || '{"mode": "provider_managed"}');
SELECT test_support.ok('T24 back to Wayfair-managed: measurements cleared, kept in the audit log',
  (SELECT packaging_mode = 'provider_managed' AND length IS NULL AND weight IS NULL AND measured_by IS NULL
     FROM us_booking.parcel WHERE id = test_support.pid(9401, 1))
  AND EXISTS (SELECT 1 FROM us_booking.event_log WHERE entity = 'parcel' AND entity_id = test_support.pid(9401, 1)
               AND details->>'action' = 'packaging_mode' AND details->'previous_values'->>'weight' = '1.400'));

-- ============================================================================================
-- T25 Other providers are unchanged
-- ============================================================================================
SELECT test_support.staff('staff_parcel_create', jsonb_build_object('group_id', test_support.gid(9201)));
SELECT test_support.ok('T25 Shippo parcels still start from the Shippo default profile (measured mode)',
  (SELECT packaging_mode = 'measured' AND dimensions_source = 'profile' AND weight_unit = 'kg' AND dimension_unit = 'in'
     FROM us_booking.parcel WHERE fulfilment_group_id = test_support.gid(9201) ORDER BY parcel_no DESC LIMIT 1));
SELECT test_support.ok('T25 Amazon default still in pounds',
  (SELECT weight = 2 AND weight_unit = 'lb' AND packaging_mode = 'measured' FROM us_booking.parcel WHERE id = test_support.pid(9202, 1)));
SELECT test_support.expect_error('T25 provider-managed packaging refused for a Shippo group',
  $q$UPDATE us_booking.parcel SET packaging_mode = 'provider_managed', length = NULL, width = NULL, height = NULL, dimension_unit = NULL,
       dimensions_source = NULL, weight = NULL, weight_unit = NULL, weight_source = NULL, measured_by = NULL, measured_at = NULL,
       package_profile_id = NULL, package_profile_version = NULL
     WHERE id = (SELECT id FROM us_booking.parcel WHERE fulfilment_group_id = test_support.gid(9201) ORDER BY parcel_no DESC LIMIT 1)$q$,
  'only available for Wayfair orders');
SELECT test_support.expect_action_error('T25 the packaging switch is refused for a non-Wayfair group', 'staff_parcel_set_packaging',
  jsonb_build_object('staff', 'Packer Two', 'mode', 'provider_managed') || test_support.pv(9202, 1), 'UB409', 'Wayfair orders only');

-- ============================================================================================
-- T26 Booking precondition: the exemption is Wayfair-specific and needs production verification
-- ============================================================================================
RESET ROLE;
BEGIN;
UPDATE us_booking.fulfilment_group SET state = 'ready' WHERE id = test_support.gid(9401);
SELECT test_support.expect_error('T26 a Wayfair-managed parcel cannot be booked before production verification',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 1, 'usb:test:wf-managed', 'rh', 'tester@example.test'
       FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9401, 1)$q$,
  'not been verified in production');
UPDATE us_booking.provider_packaging_policy SET production_verified_by = 'synthetic', production_verified_at = now(), production_evidence = 'synthetic test only';
SELECT test_support.expect_error('T26 once verified, the measurement check passes and later checks still apply (routing is not verified)',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 1, 'usb:test:wf-managed', 'rh', 'tester@example.test'
       FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9401, 1)$q$,
  'not in scope or not routed to a verified wayfair_partner integration');
UPDATE us_booking.fulfilment_group SET state = 'ready' WHERE id = test_support.gid(9402);
SELECT test_support.expect_error('T26 even when verified, a Wayfair-managed parcel in a multi-order group is refused',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 1, 'usb:test:wf-merged', 'rh', 'tester@example.test'
       FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9402, 1)$q$,
  'covers one purchase order');
SELECT test_support.expect_error('T26 a Shippo parcel without measurements is still refused (validation not disabled)',
  $q$INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no) VALUES (test_support.gid(9206), 99);
     UPDATE us_booking.fulfilment_group SET state = 'ready' WHERE id = test_support.gid(9206);
     INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 1, 'usb:test:shippo-empty', 'rh', 'tester@example.test'
       FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9206, 99)$q$,
  'measurements are incomplete');
ROLLBACK;
SELECT test_support.ok('T26 production verification flag back to unverified after the rolled-back test',
  (SELECT production_verified_at IS NULL FROM us_booking.provider_packaging_policy WHERE provider = 'wayfair_partner'));
