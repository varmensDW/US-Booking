-- Read-only status of the OMS order sync in varmen_db.us_booking:
--   npm run db:preflight -- --check=oms_sync_status
-- Every statement is a SELECT. Prints counts, ids and reasons only (no names or addresses).

-- 1. Recent sync runs (dry runs are rolled back and leave no row).
SELECT id, status, started_at, finished_at, rows_read, rows_changed, review_cases_opened
FROM us_booking.sync_run ORDER BY id DESC LIMIT 10;

-- 2. Imported volume.
SELECT (SELECT count(*) FROM us_booking.oms_order)                AS orders,
       (SELECT count(*) FROM us_booking.oms_order_item)           AS lines,
       (SELECT sum(quantity_ordered) FROM us_booking.oms_order_item) AS ordered_units,
       (SELECT count(*) FROM us_booking.oms_order_item_component) AS combo_component_rows,
       (SELECT count(*) FROM us_booking.fulfilment_group)         AS groups,
       (SELECT count(*) FROM us_booking.fulfilment_group_order WHERE active) AS active_memberships;

-- 3. Groups by state, provider and channel.
SELECT g.state, g.provider, o.channel, count(DISTINCT g.id) AS groups, count(*) AS orders
FROM us_booking.fulfilment_group g
JOIN us_booking.fulfilment_group_order fo ON fo.fulfilment_group_id = g.id AND fo.active
JOIN us_booking.oms_order o ON o.oms_order_id = fo.oms_order_id
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

-- 4. Scope of imported orders (destination from verified map or staff confirmation only).
SELECT scope_status, destination_source, count(*) AS orders
FROM us_booking.v_order_scope GROUP BY 1, 2 ORDER BY 1, 2;

-- 5. Unmet requirements by type.
SELECT requirement, count(*) AS unmet
FROM us_booking.shipment_requirement WHERE status = 'unmet' GROUP BY 1 ORDER BY 1;

-- 6. Review cases by type and status.
SELECT case_type, status, count(*) AS cases
FROM us_booking.review_case GROUP BY 1, 2 ORDER BY 1, 2;

-- 7. Raw OMS country ids on imported orders (not interpreted).
SELECT oms_country_id, count(*) AS orders FROM us_booking.oms_order GROUP BY 1 ORDER BY 2 DESC;

-- 8. Nothing booked or printed. Expect 0 everywhere.
SELECT (SELECT count(*) FROM us_booking.booking_attempt)   AS booking_attempts,
       (SELECT count(*) FROM us_booking.provider_shipment) AS provider_shipments,
       (SELECT count(*) FROM us_booking.label_file)        AS label_files,
       (SELECT count(*) FROM us_booking.print_event)       AS print_events,
       (SELECT count(*) FROM us_booking.parcel)            AS parcels,
       (SELECT count(*) FROM us_booking.hist_import_batch) AS historical_batches;

-- 9. Line fingerprint (oms_order_item_id:quantity_raw:item_sku), for comparison with the OMS.
SELECT count(*) AS lines,
       md5(string_agg(oms_order_item_id || ':' || quantity_raw || ':' || item_sku, ',' ORDER BY oms_order_item_id)) AS lines_md5
FROM us_booking.oms_order_item;
