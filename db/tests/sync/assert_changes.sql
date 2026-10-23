-- After the OMS changed (fake_oms_changes.sql) and the sync ran again.
\set ON_ERROR_STOP 1

-- Merge into a new parent: order moves, old group superseded, line keeps its originating order.
SELECT test_support.ok('S6 new merge parent group created',
  (SELECT role FROM us_booking.fulfilment_group_order WHERE oms_order_id = 5013 AND active) = 'merge_parent');
SELECT test_support.ok('S6 merged order moved to the parent''s group as child',
  (SELECT fo.role = 'merge_child' AND g.group_key = 'oms:5013:g1' FROM us_booking.fulfilment_group_order fo
     JOIN us_booking.fulfilment_group g ON g.id = fo.fulfilment_group_id WHERE fo.oms_order_id = 5001 AND fo.active));
SELECT test_support.ok('S6 emptied old group superseded and hidden from the queue',
  (SELECT state FROM us_booking.fulfilment_group WHERE group_key = 'oms:5001:g1') = 'superseded'
  AND NOT EXISTS (SELECT 1 FROM us_booking.v_review_queue WHERE group_key = 'oms:5001:g1'));
SELECT test_support.ok('S6 moved line: container 5013, originating 5001, quantity still 3',
  (SELECT container_order_id = 5013 AND oms_order_id = 5001 AND quantity_ordered = 3
     FROM us_booking.oms_order_item WHERE oms_order_item_id = 50011));

-- Merge refused because staff already started a parcel.
SELECT test_support.ok('S6 order with a staff parcel is not moved',
  (SELECT g.group_key FROM us_booking.fulfilment_group_order fo JOIN us_booking.fulfilment_group g ON g.id = fo.fulfilment_group_id
    WHERE fo.oms_order_id = 5002 AND fo.active) = 'oms:5002:g1');
SELECT test_support.ok('S6 refused move opens merge_inconsistent',
  EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5002 AND case_type = 'merge_inconsistent' AND status = 'open'));
SELECT test_support.ok('S6 refused move: new parent group holds only its own order',
  (SELECT array_agg(oms_order_id) FROM us_booking.fulfilment_group_order WHERE fulfilment_group_id = test_support.gid(5014) AND active) = '{5014}');
SELECT test_support.ok('S6 quantity change refreshed (1 -> 2)',
  (SELECT quantity_ordered = 2 AND quantity_raw = '2' FROM us_booking.oms_order_item WHERE oms_order_item_id = 50021));

-- Staff data preserved, but never as an outdated approval.
SELECT test_support.ok('S6 confirmation for the changed address revoked, row kept as history',
  (SELECT status = 'revoked' AND confirmed_by = 'staff@example.test' AND revoked_by = 'system:oms-sync'
          AND revoke_reason LIKE 'ship-to address changed%'
     FROM us_booking.order_destination_confirmation WHERE oms_order_id = 5002));
SELECT test_support.ok('S6 revoked confirmation no longer gives a destination',
  (SELECT destination_iso2 IS NULL FROM us_booking.v_order_destination WHERE oms_order_id = 5002));
SELECT test_support.ok('S6 destination requirement unmet again',
  (SELECT status FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(5002) AND oms_order_id = 5002
     AND requirement = 'destination_country') = 'unmet');
SELECT test_support.ok('S6 confirmation for an unchanged address stays active',
  (SELECT count(*) FROM us_booking.order_destination_confirmation WHERE oms_order_id IN (5003, 5011) AND status = 'active') = 2);
SELECT test_support.ok('S6 staff check invalidated when its ship-to changed',
  (SELECT status = 'unmet' AND checked_by = 'system:oms-sync' FROM us_booking.shipment_requirement
    WHERE fulfilment_group_id = test_support.gid(5002) AND oms_order_id = 5002 AND requirement = 'ship_to_phone'));
SELECT test_support.ok('S6 invalidated staff check kept in the audit log',
  EXISTS (SELECT 1 FROM us_booking.event_log WHERE entity = 'shipment_requirement'
           AND details->'invalidated_staff_check'->>'checked_by' = 'staff@example.test' AND (details->>'oms_order_id')::bigint = 5002));
SELECT test_support.ok('S6 staff check on unchanged data left as staff set it',
  (SELECT status = 'met' AND checked_by = 'staff@example.test' FROM us_booking.shipment_requirement
    WHERE oms_order_id = 5005 AND requirement = 'ship_to_phone'));
SELECT test_support.ok('S6 staff parcel kept',
  (SELECT count(*) FROM us_booking.parcel WHERE fulfilment_group_id = test_support.gid(5002) AND length_in = 10) = 1);
SELECT test_support.ok('S6 unchanged dismissed cancellation not reopened',
  (SELECT count(*) FROM us_booking.review_case WHERE oms_order_id = 5002 AND case_type = 'cancellation') = 1
  AND NOT EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5002 AND case_type = 'cancellation' AND status = 'open'));
SELECT test_support.ok('S6 changed shipping evidence opens a new case, dismissal kept',
  (SELECT count(*) FILTER (WHERE status = 'open') = 1 AND count(*) FILTER (WHERE status = 'dismissed') = 1
     FROM us_booking.review_case WHERE oms_order_id = 5007 AND case_type = 'already_shipped_suspect'));
SELECT test_support.ok('S6 fixed blank SKU: resolved case marked cleared, nothing reopened',
  (SELECT status = 'resolved' AND details ? 'condition_cleared_run' FROM us_booking.review_case
    WHERE oms_order_id = 5007 AND case_type = 'sku_missing')
  AND (SELECT count(*) FROM us_booking.review_case WHERE oms_order_id = 5007 AND case_type = 'sku_missing') = 1);

-- Customs follows the confirmed destination.
SELECT test_support.ok('S6 confirmed Canada: customs declaration required',
  (SELECT status = 'unmet' AND detail LIKE 'Canada destination%' FROM us_booking.shipment_requirement
    WHERE oms_order_id = 5011 AND requirement = 'customs_declaration'));
SELECT test_support.ok('S6 confirmed US: customs not applicable',
  (SELECT status FROM us_booking.shipment_requirement WHERE oms_order_id = 5003 AND requirement = 'customs_declaration') = 'not_applicable');
SELECT test_support.ok('S6 unknown destination: customs awaits destination',
  (SELECT detail LIKE 'awaiting destination confirmation%' FROM us_booking.shipment_requirement
    WHERE oms_order_id = 5012 AND requirement = 'customs_declaration'));

-- Previously imported orders are refreshed even after leaving the open/US1 filter.
SELECT test_support.ok('S6 cancelled order in another warehouse still refreshed',
  (SELECT oms_status = 'Cancelled' AND warehouse_id = 7 FROM us_booking.oms_order WHERE oms_order_id = 5006));
SELECT test_support.ok('S6 status change opens a case',
  (SELECT details->>'from_status' = 'New' AND details->>'to_status' = 'Cancelled' FROM us_booking.review_case
    WHERE oms_order_id = 5006 AND case_type = 'oms_status_changed' AND status = 'open'));
SELECT test_support.ok('S6 warehouse change opens a case',
  EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5006 AND case_type = 'warehouse_conflict' AND status = 'open'));

-- Lines removed from the OMS are kept and flagged.
SELECT test_support.ok('S6 removed OMS line kept', EXISTS (SELECT 1 FROM us_booking.oms_order_item WHERE oms_order_item_id = 50051));
SELECT test_support.ok('S6 removed OMS line flagged',
  EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5005 AND case_type = 'oms_status_changed'
            AND details->'oms_order_item_ids' = '[50051]'::jsonb));

-- Single order becomes a merge parent; ready group goes back to review.
SELECT test_support.ok('S6 single order became merge parent',
  (SELECT role FROM us_booking.fulfilment_group_order WHERE oms_order_id = 5011 AND active) = 'merge_parent');
SELECT test_support.ok('S6 new child joined the existing group',
  (SELECT role = 'merge_child' FROM us_booking.fulfilment_group_order
    WHERE oms_order_id = 5012 AND active AND fulfilment_group_id = test_support.gid(5011)));
SELECT test_support.ok('S6 ready group returned to review after OMS change',
  (SELECT state FROM us_booking.fulfilment_group WHERE group_key = 'oms:5011:g1') = 'review');

SELECT test_support.ok('S6 eleven orders, no duplicates', (SELECT count(*) FROM us_booking.oms_order) = 11);
SELECT test_support.ok('S6 one active membership per order',
  (SELECT count(*) FROM us_booking.fulfilment_group_order WHERE active) = 11
  AND (SELECT count(DISTINCT oms_order_id) FROM us_booking.fulfilment_group_order WHERE active) = 11);
SELECT test_support.ok('S6 still no booking attempts', (SELECT count(*) FROM us_booking.booking_attempt) = 0);
