-- After one more sync with no further OMS change: stable.
\set ON_ERROR_STOP 1
SELECT test_support.ok('S7 latest run changed nothing and opened nothing',
  (SELECT rows_changed = 0 AND review_cases_opened = 0 FROM us_booking.sync_run ORDER BY id DESC LIMIT 1));
SELECT test_support.ok('S7 still eleven orders', (SELECT count(*) FROM us_booking.oms_order) = 11);
SELECT test_support.ok('S7 no case refers to the latest run',
  NOT EXISTS (SELECT 1 FROM us_booking.review_case
               WHERE (details->>'sync_run_id')::bigint = (SELECT max(id) FROM us_booking.sync_run)));

-- 0009: re-running the sync leaves the stale parcel and its single open discrepancy as they were.
SELECT test_support.ok('S7 no duplicate discrepancy and no automatic reconfirmation',
  (SELECT count(*) FROM us_booking.parcel_contents_discrepancy WHERE parcel_id = test_support.pid(5003, 1)) = 1
  AND (SELECT contents_status FROM us_booking.parcel WHERE id = test_support.pid(5003, 1)) = 'stale');
