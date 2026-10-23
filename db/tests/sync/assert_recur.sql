-- After a resolved, cleared finding recurred with the same evidence.
\set ON_ERROR_STOP 1
SELECT test_support.ok('S8 recurring blank SKU opens a new case',
  EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5007 AND case_type = 'sku_missing' AND status = 'open'));
SELECT test_support.ok('S8 new case links to the earlier resolution',
  (SELECT (details->>'recurrence_of')::bigint FROM us_booking.review_case WHERE oms_order_id = 5007 AND case_type = 'sku_missing' AND status = 'open')
  = (SELECT id FROM us_booking.review_case WHERE oms_order_id = 5007 AND case_type = 'sku_missing' AND status = 'resolved'));
SELECT test_support.ok('S8 earlier resolution kept',
  (SELECT resolution FROM us_booking.review_case WHERE oms_order_id = 5007 AND case_type = 'sku_missing' AND status = 'resolved') = 'synthetic: reviewed');
SELECT test_support.ok('S8 unchanged dismissed cancellation still not reopened',
  NOT EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 5002 AND case_type = 'cancellation' AND status = 'open'));
