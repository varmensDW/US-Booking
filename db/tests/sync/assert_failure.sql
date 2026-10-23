-- After a sync --apply that failed while reading the OMS (SELECT on one OMS table revoked), and a
-- successful sync afterwards.
\set ON_ERROR_STOP 1
SELECT test_support.ok('S9 failed run kept in sync history after the rolled-back import',
  EXISTS (SELECT 1 FROM us_booking.sync_run WHERE status = 'failed' AND finished_at IS NOT NULL
           AND error LIKE 'OMS extraction failed%' AND error LIKE '%permission denied%'));
SELECT test_support.ok('S9 failed run message holds no host or connection string',
  NOT EXISTS (SELECT 1 FROM us_booking.sync_run WHERE status = 'failed' AND (error LIKE '%127.0.0.1%' OR error LIKE '%postgresql://%')));
SELECT test_support.ok('S9 failure logged in event_log with its stage',
  EXISTS (SELECT 1 FROM us_booking.event_log WHERE entity = 'sync_run' AND to_state = 'failed' AND details->>'stage' = 'reading_oms'));
SELECT test_support.ok('S9 the failure changed no order data and opened no running row',
  NOT EXISTS (SELECT 1 FROM us_booking.sync_run WHERE status = 'running'));
SELECT test_support.ok('S10 next successful sync clears last_error; the failed run stays in history',
  (SELECT last_error IS NULL FROM us_booking.sync_state WHERE stream = 'oms_orders')
  AND (SELECT status FROM us_booking.sync_run ORDER BY id DESC LIMIT 1) = 'ok'
  AND (SELECT count(*) FROM us_booking.sync_run WHERE status = 'failed') = 1);
