-- After re-running the sync with no OMS change: nothing duplicated, nothing changed.
\set ON_ERROR_STOP 1
SELECT test_support.ok('S4 still six groups',         (SELECT count(*) FROM us_booking.fulfilment_group) = 6);
SELECT test_support.ok('S4 still eight orders',       (SELECT count(*) FROM us_booking.oms_order) = 8);
SELECT test_support.ok('S4 still eight lines',        (SELECT count(*) FROM us_booking.oms_order_item) = 8);
SELECT test_support.ok('S4 still five components',    (SELECT count(*) FROM us_booking.oms_order_item_component) = 5);
SELECT test_support.ok('S4 one active membership per order',
  (SELECT count(*) FROM us_booking.fulfilment_group_order WHERE active) = 8);
SELECT test_support.ok('S4 no duplicate requirements',
  (SELECT count(*) FROM (SELECT fulfilment_group_id, oms_order_id, requirement FROM us_booking.shipment_requirement
                          GROUP BY 1, 2, 3 HAVING count(*) > 1) d) = 0);
SELECT test_support.ok('S4 still five open cases',    (SELECT count(*) FROM us_booking.review_case WHERE status = 'open') = 5);
SELECT test_support.ok('S4 latest run changed nothing and opened nothing',
  (SELECT rows_changed = 0 AND review_cases_opened = 0 AND status = 'ok' FROM us_booking.sync_run ORDER BY id DESC LIMIT 1));
SELECT test_support.ok('S4 one import event per order', (SELECT count(*) FROM us_booking.event_log WHERE entity = 'oms_order') = 8);
SELECT test_support.ok('S4 three committed runs recorded', (SELECT count(*) FROM us_booking.sync_run WHERE status = 'ok') = 3);
