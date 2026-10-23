-- After a dry run: nothing persisted.
\set ON_ERROR_STOP 1
SELECT test_support.ok('S1 dry run wrote no orders',        (SELECT count(*) FROM us_booking.oms_order) = 0);
SELECT test_support.ok('S1 dry run wrote no lines',         (SELECT count(*) FROM us_booking.oms_order_item) = 0);
SELECT test_support.ok('S1 dry run wrote no groups',        (SELECT count(*) FROM us_booking.fulfilment_group) = 0);
SELECT test_support.ok('S1 dry run wrote no requirements',  (SELECT count(*) FROM us_booking.shipment_requirement) = 0);
SELECT test_support.ok('S1 dry run wrote no review cases',  (SELECT count(*) FROM us_booking.review_case) = 0);
SELECT test_support.ok('S1 dry run wrote no sync runs',     (SELECT count(*) FROM us_booking.sync_run) = 0);
SELECT test_support.ok('S1 dry run wrote no audit events (only the two 0006 migration rows exist)',
  (SELECT count(*) FROM us_booking.event_log WHERE actor <> 'migration:0006') = 0);
