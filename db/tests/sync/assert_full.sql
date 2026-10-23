-- After a full sync (limit 20) on top of the limit-2 run.
\set ON_ERROR_STOP 1

-- Selection
SELECT test_support.ok('S3 six open US1 groups imported',
  (SELECT array_agg(group_key ORDER BY group_key) FROM us_booking.fulfilment_group)
  = '{oms:5001:g1,oms:5002:g1,oms:5003:g1,oms:5006:g1,oms:5007:g1,oms:5011:g1}');
SELECT test_support.ok('S3 every imported group awaits review', NOT EXISTS (SELECT 1 FROM us_booking.fulfilment_group WHERE state <> 'review'));
SELECT test_support.ok('S3 completed, other-warehouse and RESEND orders not imported',
  NOT EXISTS (SELECT 1 FROM us_booking.oms_order WHERE oms_order_id IN (5008, 5009, 5010)));
SELECT test_support.ok('S3 eight orders imported (merge children included)', (SELECT count(*) FROM us_booking.oms_order) = 8);

-- Merges: whole group, originating and containing order ids kept
SELECT test_support.ok('S3 merge parent role',
  (SELECT role FROM us_booking.fulfilment_group_order WHERE oms_order_id = 5003 AND active) = 'merge_parent');
SELECT test_support.ok('S3 merge children in the parent''s group',
  (SELECT array_agg(fo.oms_order_id ORDER BY fo.oms_order_id) FROM us_booking.fulfilment_group_order fo
    WHERE fo.fulfilment_group_id = test_support.gid(5003) AND fo.active AND fo.role = 'merge_child') = '{5004,5005}');
SELECT test_support.ok('S3 child lines keep originating and containing order',
  (SELECT oms_order_id = 5004 AND container_order_id = 5003 FROM us_booking.oms_order_item WHERE oms_order_item_id = 50041)
  AND (SELECT oms_order_id = 5005 AND container_order_id = 5003 FROM us_booking.oms_order_item WHERE oms_order_item_id = 50051));
SELECT test_support.ok('S3 merge child keeps raw merge value and parent id',
  (SELECT oms_merge_raw = '5003' AND merge_parent_order_id = 5003 FROM us_booking.oms_order WHERE oms_order_id = 5004));
SELECT test_support.ok('S3 single order role', (SELECT role FROM us_booking.fulfilment_group_order WHERE oms_order_id = 5001 AND active) = 'single');

-- Quantities and SKUs exactly as ordered; nothing expanded or allocated
SELECT test_support.ok('S3 quantity preserved (3)',
  (SELECT quantity_ordered = 3 AND quantity_raw = '3' AND item_sku = 'SYN-LAMP-A' FROM us_booking.oms_order_item WHERE oms_order_item_id = 50011));
SELECT test_support.ok('S3 child quantity preserved (4)', (SELECT quantity_ordered FROM us_booking.oms_order_item WHERE oms_order_item_id = 50051) = 4);
SELECT test_support.ok('S3 pack line stays one line with its ordered quantity',
  (SELECT quantity_ordered = 2 AND item_sku = 'SYN-PACK-C2' AND combo_count = 2 FROM us_booking.oms_order_item WHERE oms_order_item_id = 50031));
SELECT test_support.ok('S3 eight lines, no extra lines from combos', (SELECT count(*) FROM us_booking.oms_order_item) = 8);
SELECT test_support.ok('S3 combo components stored as reference only', (SELECT count(*) FROM us_booking.oms_order_item_component) = 5);
SELECT test_support.ok('S3 combo_count 1 with several component rows is not a mismatch',
  NOT EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5011 AND case_type = 'combo_mismatch'));
SELECT test_support.ok('S3 no parcels, contents or allocations inferred',
  (SELECT count(*) FROM us_booking.parcel) = 0 AND (SELECT count(*) FROM us_booking.parcel_item) = 0
  AND (SELECT count(*) FROM us_booking.item_allocation) = 0);
SELECT test_support.ok('S3 raw order date unchanged',
  (SELECT order_date_raw FROM us_booking.oms_order WHERE oms_order_id = 5004) = timestamp '2026-10-03 09:00:00');

-- Country: never guessed
SELECT test_support.ok('S3 country map untouched and no confirmations created',
  (SELECT count(*) FROM us_booking.country_map) = 0 AND (SELECT count(*) FROM us_booking.order_destination_confirmation) = 0);
SELECT test_support.ok('S3 missing country stays undetermined',
  (SELECT oms_country_id IS NULL FROM us_booking.oms_order WHERE oms_order_id = 5002)
  AND (SELECT scope_status FROM us_booking.v_order_scope WHERE oms_order_id = 5002) = 'undetermined');
SELECT test_support.ok('S3 missing country is a visible unmet requirement',
  (SELECT status = 'unmet' AND detail LIKE '%no country_id%' FROM us_booking.shipment_requirement
    WHERE oms_order_id = 5002 AND requirement = 'destination_country'));
SELECT test_support.ok('S3 unmapped country id 359 is unmet, not guessed',
  (SELECT status = 'unmet' AND detail LIKE '%359%' FROM us_booking.shipment_requirement
    WHERE oms_order_id = 5006 AND requirement = 'destination_country'));
SELECT test_support.ok('S3 country id 8 is not assumed to be US either',
  (SELECT scope_status FROM us_booking.v_order_scope WHERE oms_order_id = 5001) = 'undetermined');
SELECT test_support.ok('S3 blank state is unmet', (SELECT status FROM us_booking.shipment_requirement
    WHERE oms_order_id = 5002 AND requirement = 'ship_to_state') = 'unmet');
SELECT test_support.ok('S3 customs awaits destination while it is unknown (still blocking)',
  (SELECT status = 'unmet' AND detail LIKE 'awaiting destination confirmation%' FROM us_booking.shipment_requirement
    WHERE oms_order_id = 5001 AND requirement = 'customs_declaration'));
SELECT test_support.ok('S3 OMS shipment evidence stored with the order',
  (SELECT (oms_shipments->>'tracked_not_cancelled')::int = 1 FROM us_booking.oms_order WHERE oms_order_id = 5007));

-- Review cases
SELECT test_support.ok('S3 eBay cancellation request opens a case',
  EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5002 AND case_type = 'cancellation' AND status = 'open'));
SELECT test_support.ok('S3 combo row count mismatch opens a case',
  EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5002 AND case_type = 'combo_mismatch' AND status = 'open'));
SELECT test_support.ok('S3 consistent pack has no combo case',
  NOT EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5003 AND case_type = 'combo_mismatch'));
SELECT test_support.ok('S3 Book-from-UK flag opens a case',
  EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5006 AND case_type = 'booking_flag_conflict'));
SELECT test_support.ok('S3 other flag groups are ignored',
  NOT EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5007 AND case_type = 'booking_flag_conflict'));
SELECT test_support.ok('S3 blank real_sku opens a case',
  EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5007 AND case_type = 'sku_missing'));
SELECT test_support.ok('S3 OMS tracking opens already_shipped_suspect',
  EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5007 AND case_type = 'already_shipped_suspect'));
SELECT test_support.ok('S3 missing tracking is not treated as anything',
  NOT EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5001));
SELECT test_support.ok('S3 five open cases in total', (SELECT count(*) FROM us_booking.review_case WHERE status = 'open') = 5);
SELECT test_support.ok('S3 queue: no tracking means not_established',
  (SELECT prior_label_check FROM us_booking.v_review_queue WHERE group_key = 'oms:5001:g1') = 'not_established');
SELECT test_support.ok('S3 queue: tracking means signal present',
  (SELECT prior_label_check FROM us_booking.v_review_queue WHERE group_key = 'oms:5007:g1') = 'oms_shipping_signal_present');

-- Routing and provider (unverified, so nothing is bookable)
SELECT test_support.ok('S3 routing by channel',
  (SELECT provider FROM us_booking.fulfilment_group WHERE id = test_support.gid(5001)) = 'amazon_seller_central'
  AND (SELECT provider FROM us_booking.fulfilment_group WHERE id = test_support.gid(5002)) = 'shippo'
  AND (SELECT provider FROM us_booking.fulfilment_group WHERE id = test_support.gid(5003)) = 'shippo'
  AND (SELECT provider FROM us_booking.fulfilment_group WHERE id = test_support.gid(5006)) = 'wayfair_partner');
SELECT test_support.ok('S3 routing and provider account unmet for every group',
  (SELECT count(*) FROM us_booking.shipment_requirement WHERE requirement IN ('routing_verified', 'provider_account') AND status = 'unmet') = 12);
SELECT test_support.ok('S3 parcel work left to staff (unmet)',
  (SELECT count(*) FROM us_booking.shipment_requirement WHERE requirement IN ('parcel_measurements', 'parcel_contents') AND status = 'unmet') = 12);

-- Nothing booked; history separate
SELECT test_support.ok('S3 no booking attempts or provider shipments',
  (SELECT count(*) FROM us_booking.booking_attempt) = 0 AND (SELECT count(*) FROM us_booking.provider_shipment) = 0);
SELECT test_support.ok('S3 historical tables untouched',
  (SELECT count(*) FROM us_booking.hist_import_batch) = 0 AND (SELECT count(*) FROM us_booking.hist_shippo_label) = 0);
SELECT test_support.ok('S3 review queue lists all six groups', (SELECT count(*) FROM us_booking.v_review_queue) = 6);
SELECT test_support.ok('S3 queue counts ordered quantity as ordered (3+1+... per group)',
  (SELECT ordered_quantity_total FROM us_booking.v_review_queue WHERE group_key = 'oms:5003:g1') = 7);
