-- After `--apply --limit=2`: exactly the two oldest open groups.
\set ON_ERROR_STOP 1
SELECT test_support.ok('S2 limit 2 imported exactly 2 groups', (SELECT count(*) FROM us_booking.fulfilment_group) = 2);
SELECT test_support.ok('S2 oldest open groups first',
  (SELECT array_agg(group_key ORDER BY group_key) FROM us_booking.fulfilment_group) = '{oms:5001:g1,oms:5002:g1}');
SELECT test_support.ok('S2 only their orders imported',
  (SELECT array_agg(oms_order_id ORDER BY oms_order_id) FROM us_booking.oms_order) = '{5001,5002}');
