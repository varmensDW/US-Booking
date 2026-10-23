-- Staff work between syncs (what the review screen will do), applied as the booking owner.
-- Staff checks record the OMS data they were made against (basis_hash), as the screen will.
\set ON_ERROR_STOP 1
-- Destination confirmed for 5002 (US) against its current ship-to; it changes in the OMS later.
INSERT INTO us_booking.order_destination_confirmation
  (oms_order_id, destination_iso2, evidence_type, evidence_ref, oms_country_id_seen, ship_address_hash, confirmed_by)
SELECT 5002, 'US', 'marketplace_order_record', 'synthetic: eBay order page shows US', oms_country_id, ship_address_hash, 'staff@example.test'
  FROM us_booking.oms_order WHERE oms_order_id = 5002;
-- Destination confirmed for 5003 (US) and 5011 (CA); their addresses do not change.
INSERT INTO us_booking.order_destination_confirmation
  (oms_order_id, destination_iso2, evidence_type, evidence_ref, oms_country_id_seen, ship_address_hash, confirmed_by)
SELECT oms_order_id, CASE oms_order_id WHEN 5003 THEN 'US' ELSE 'CA' END, 'marketplace_order_record',
       'synthetic: marketplace order page', oms_country_id, ship_address_hash, 'staff@example.test'
  FROM us_booking.oms_order WHERE oms_order_id IN (5003, 5011);
-- Phone obtained by staff for 5002 (its ship-to changes later) and 5005 (unchanged).
UPDATE us_booking.shipment_requirement r
   SET status = 'met', detail = 'synthetic: phone obtained from customer', checked_by = 'staff@example.test',
       checked_at = now(), basis_hash = o.ship_address_hash
  FROM us_booking.oms_order o
 WHERE o.oms_order_id = r.oms_order_id AND r.oms_order_id IN (5002, 5005) AND r.requirement = 'ship_to_phone';
-- A parcel started for 5002's group.
INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, length, width, height, dimension_unit, dimensions_source, measured_by, measured_at)
VALUES (test_support.gid(5002), 1, 10, 8, 6, 'in', 'staff', 'staff@example.test', now());
-- Findings reviewed by staff: 5002 cancellation dismissed (stays unchanged), 5007 shipping signal
-- dismissed (evidence changes later), 5007 blank real_sku resolved (fixed later, then recurs).
UPDATE us_booking.review_case
   SET status = 'dismissed', resolved_by = 'staff@example.test', resolved_at = now(), resolution = 'synthetic: reviewed'
 WHERE (oms_order_id = 5002 AND case_type = 'cancellation') OR (oms_order_id = 5007 AND case_type = 'already_shipped_suspect');
UPDATE us_booking.review_case
   SET status = 'resolved', resolved_by = 'staff@example.test', resolved_at = now(), resolution = 'synthetic: reviewed'
 WHERE oms_order_id = 5007 AND case_type = 'sku_missing';
-- 5011's group marked ready by staff.
UPDATE us_booking.fulfilment_group SET state = 'ready', blocked_reason = NULL WHERE group_key = 'oms:5011:g1';
SELECT test_support.ok('S5 staff confirmation makes 5002 in scope before the OMS change',
  (SELECT scope_status FROM us_booking.v_order_scope WHERE oms_order_id = 5002) = 'in_scope');
-- 0009: a confirmed parcel for the 5003 merge group holding all three lines; line 50051 then
-- disappears from the OMS (fake_oms_changes.sql), which must make this confirmation stale.
SELECT us_booking.staff_parcel_create(jsonb_build_object('staff', 'Synthetic Staff', 'group_id', test_support.gid(5003)));
SELECT us_booking.staff_parcel_set_contents(jsonb_build_object('staff', 'Synthetic Staff', 'parcel_id', test_support.pid(5003, 1),
  'expected_row_version', (SELECT row_version FROM us_booking.parcel WHERE id = test_support.pid(5003, 1)), 'confirm', true,
  'items', '[{"oms_order_item_id": 50031, "quantity": 2}, {"oms_order_item_id": 50041, "quantity": 1}, {"oms_order_item_id": 50051, "quantity": 4}]'::jsonb));
SELECT test_support.ok('S5 merge-group parcel confirmed by staff with all lines',
  (SELECT contents_status = 'confirmed' AND contents_basis_hash IS NOT NULL FROM us_booking.parcel WHERE id = test_support.pid(5003, 1))
  AND (SELECT status FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(5003) AND requirement = 'parcel_contents') = 'met');
