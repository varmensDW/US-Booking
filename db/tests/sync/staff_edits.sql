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
INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no, length_in) VALUES (test_support.gid(5002), 1, 10);
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
