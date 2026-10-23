-- Tests for 0012: Shippo TEST records are isolated from live booking, never purchase twice for
-- the same shipment while a purchase is in flight or unknown, and only reach 'succeeded' with
-- Shippo's own test-mode marker. Synthetic data only.
\set ON_ERROR_STOP 1
SET client_min_messages = notice;
SET ROLE us_booking_owner;

SELECT test_support.ok('T27 Shippo test tables have no foreign key to live booking tables',
  NOT EXISTS (SELECT 1 FROM pg_constraint c
               WHERE c.contype = 'f'
                 AND c.conrelid IN ('us_booking.shippo_test_shipment'::regclass, 'us_booking.shippo_test_purchase'::regclass, 'us_booking.shippo_test_label'::regclass)
                 AND c.confrelid NOT IN ('us_booking.shippo_test_shipment'::regclass, 'us_booking.shippo_test_purchase'::regclass)));
SELECT test_support.ok('T27 no live object reads the Shippo test tables',
  NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid
               WHERE d.refobjid IN ('us_booking.shippo_test_shipment'::regclass, 'us_booking.shippo_test_purchase'::regclass, 'us_booking.shippo_test_label'::regclass))
  AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'us_booking' AND p.proname !~ '^(shippo_test_|tg_shippo_test_)'
                     AND p.prosrc ~ 'shippo_test_'));

CREATE TEMP TABLE sts AS SELECT (us_booking.shippo_test_shipment_add(
  '{"staff": "Tester", "destination_country": "US", "ship_from": {"city": "Chicago"}, "ship_to": {"city": "New York"},
    "parcel": {"length": "9", "width": "6", "height": "6", "dimension_unit": "in", "weight": "2", "weight_unit": "kg"},
    "rates": [{"rate_object_id": "rate_1", "carrier": "USPS", "amount": "8.10", "currency": "USD"}]}')->>'id')::bigint AS id;
SELECT test_support.expect_action_error('T27 destination_country must be a two-letter code', 'shippo_test_shipment_add',
  '{"staff": "Tester", "destination_country": "USA", "ship_from": {}, "ship_to": {}, "parcel": {}}', 'UB422', 'two-letter ISO code');

CREATE TEMP TABLE stp AS SELECT (us_booking.shippo_test_purchase_begin(
  jsonb_build_object('staff', 'Tester', 'shipment_id', (SELECT id FROM sts), 'rate_object_id', 'rate_1',
                      'rate_summary', '{"carrier": "USPS", "amount": "8.10", "currency": "USD"}'))->>'id')::bigint AS id;
SELECT test_support.expect_action_error('T27 a shipment with a purchase in flight is not purchased again', 'shippo_test_purchase_begin',
  jsonb_build_object('staff', 'Tester', 'shipment_id', (SELECT id FROM sts), 'rate_object_id', 'rate_1', 'rate_summary', '{}'),
  'UB409', 'already has a requested purchase');
SELECT test_support.expect_action_error('T27 succeeded is refused without Shippo''s test-mode marker', 'shippo_test_purchase_finish',
  jsonb_build_object('id', (SELECT id FROM stp), 'state', 'succeeded', 'test_mode', false), 'UB422', 'test mode');
SELECT us_booking.shippo_test_purchase_finish(jsonb_build_object('id', (SELECT id FROM stp), 'state', 'unknown', 'error', 'synthetic timeout'));
SELECT test_support.expect_action_error('T27 an unknown outcome blocks a repeat purchase', 'shippo_test_purchase_begin',
  jsonb_build_object('staff', 'Tester', 'shipment_id', (SELECT id FROM sts), 'rate_object_id', 'rate_1', 'rate_summary', '{}'),
  'UB409', 'already has a unknown purchase');
SELECT test_support.expect_error('T27 unknown cannot be turned into succeeded directly',
  $q$UPDATE us_booking.shippo_test_purchase SET state = 'succeeded', test_mode = true WHERE id = (SELECT id FROM stp)$q$,
  'cannot move from unknown to succeeded');
SELECT test_support.expect_action_error('T27 labels need a succeeded or confirmed purchase', 'shippo_test_label_add',
  jsonb_build_object('staff', 'Tester', 'purchase_id', (SELECT id FROM stp), 'content_type', 'application/pdf', 'file_name', 'x.pdf',
                     'size_bytes', 10, 'sha256', repeat('a', 64)), 'UB409', 'succeeded or staff-confirmed');
SELECT test_support.expect_action_error('T27 resolving an unknown outcome needs evidence', 'shippo_test_purchase_resolve',
  jsonb_build_object('staff', 'Tester', 'id', (SELECT id FROM stp), 'outcome', 'resolved_not_purchased', 'evidence', ''), 'UB422', 'Evidence');
SELECT us_booking.shippo_test_purchase_resolve(jsonb_build_object('staff', 'Tester', 'id', (SELECT id FROM stp), 'outcome', 'confirmed_purchased',
  'evidence', 'synthetic: Shippo dashboard shows this transaction as SUCCESS and test mode'));
SELECT test_support.ok('T27 a confirmed-purchased outcome can now have a label stored',
  (us_booking.shippo_test_label_add(jsonb_build_object('staff', 'Tester', 'purchase_id', (SELECT id FROM stp), 'content_type', 'application/pdf',
    'file_name', 'SHIPPOTEST-1-1.pdf', 'size_bytes', 10, 'sha256', repeat('a', 64)))->>'id') IS NOT NULL);
SELECT test_support.expect_error('T27 stored test labels are append-only',
  $q$UPDATE us_booking.shippo_test_label SET file_name = 'x'$q$, 'append-only');
SELECT test_support.expect_error('T27 test purchases cannot be deleted',
  $q$DELETE FROM us_booking.shippo_test_purchase$q$, 'append-only');
SELECT test_support.expect_error('T27 test shipments are append-only (never edited)',
  $q$UPDATE us_booking.shippo_test_shipment SET destination_country = 'CA' WHERE id = (SELECT id FROM sts)$q$, 'append-only');

-- 0013: once a shipment has a completed (confirmed_purchased or succeeded) purchase, it is done
-- and is NOT purchased again -- unlike the earlier 'unknown' case above, this is terminal.
SELECT test_support.expect_action_error('T28 a shipment with an already-purchased label is not purchased again', 'shippo_test_purchase_begin',
  jsonb_build_object('staff', 'Tester', 'shipment_id', (SELECT id FROM sts), 'rate_object_id', 'rate_2', 'rate_summary', '{}'),
  'UB409', 'already has a purchased label');

-- A failed (or rejected-not-test, or resolved-not-purchased) attempt is still retryable: a second,
-- independent test shipment proves that path without touching the already-completed one above.
CREATE TEMP TABLE sts2 AS SELECT (us_booking.shippo_test_shipment_add(
  '{"staff": "Tester", "destination_country": "US", "ship_from": {"city": "Chicago"}, "ship_to": {"city": "Boston"},
    "parcel": {"length": "9", "width": "6", "height": "6", "dimension_unit": "in", "weight": "2", "weight_unit": "kg"},
    "rates": [{"rate_object_id": "rate_3", "carrier": "USPS", "amount": "9.00", "currency": "USD"}]}')->>'id')::bigint AS id;
CREATE TEMP TABLE stp2 AS SELECT (us_booking.shippo_test_purchase_begin(
  jsonb_build_object('staff', 'Tester', 'shipment_id', (SELECT id FROM sts2), 'rate_object_id', 'rate_3',
                      'rate_summary', '{"carrier": "USPS", "service": "Ground Advantage", "amount": "9.00", "currency": "USD"}'))->>'id')::bigint AS id;
SELECT us_booking.shippo_test_purchase_finish(jsonb_build_object('id', (SELECT id FROM stp2), 'state', 'failed', 'error', 'synthetic address error'));
CREATE TEMP TABLE stp3 AS SELECT (us_booking.shippo_test_purchase_begin(
  jsonb_build_object('staff', 'Tester', 'shipment_id', (SELECT id FROM sts2), 'rate_object_id', 'rate_3',
                      'rate_summary', '{"carrier": "USPS", "service": "Ground Advantage", "amount": "9.00", "currency": "USD"}'))->>'id')::bigint AS id;
SELECT test_support.ok('T28 a failed attempt may be retried on the same test shipment',
  (SELECT count(*) FROM us_booking.shippo_test_purchase WHERE shipment_id = (SELECT id FROM sts2)) = 2);
SELECT test_support.expect_action_error('T28 details cannot be recovered for a purchase still in flight', 'shippo_test_purchase_recover_details',
  jsonb_build_object('staff', 'Tester', 'id', (SELECT id FROM stp3)), 'UB409', 'already completed');
SELECT us_booking.shippo_test_purchase_finish(jsonb_build_object('id', (SELECT id FROM stp3),
  'state', 'succeeded', 'test_mode', true, 'provider_transaction_id', 'txn_mock_1', 'tracking_number', 'MOCKTRK1',
  'carrier', 'USPS', 'service_level', 'Ground Advantage', 'amount', '9.00', 'currency', 'USD', 'label_source_url', 'http://mock/label.pdf'));
SELECT test_support.ok('T28 succeeded with the test-mode marker carries carrier/service/amount/currency',
  (SELECT (carrier, service_level, amount, currency) = ('USPS', 'Ground Advantage', 9.00, 'USD')
     FROM us_booking.shippo_test_purchase WHERE provider_transaction_id = 'txn_mock_1'));
SELECT test_support.expect_action_error('T28 and that shipment, too, is now done', 'shippo_test_purchase_begin',
  jsonb_build_object('staff', 'Tester', 'shipment_id', (SELECT id FROM sts2), 'rate_object_id', 'rate_3', 'rate_summary', '{}'),
  'UB409', 'already has a purchased label');

-- Recovering missing details: fills NULL columns only, never overwrites a value already recorded.
SELECT us_booking.shippo_test_purchase_recover_details(jsonb_build_object('staff', 'Tester',
  'id', (SELECT id FROM us_booking.shippo_test_purchase WHERE provider_transaction_id = 'txn_mock_1'),
  'carrier_account_id', 'ca_recovered', 'amount', '999.00'));
SELECT test_support.ok('T28 recover-details fills a missing column (carrier_account_id)',
  (SELECT carrier_account_id FROM us_booking.shippo_test_purchase WHERE provider_transaction_id = 'txn_mock_1') = 'ca_recovered');
SELECT test_support.ok('T28 recover-details never overwrites a column that already has a value (amount stays 9.00, not 999.00)',
  (SELECT amount FROM us_booking.shippo_test_purchase WHERE provider_transaction_id = 'txn_mock_1') = 9.00);

-- A customs invoice can be stored alongside the label for the same purchase, distinguished by kind.
SELECT us_booking.shippo_test_label_add(jsonb_build_object('staff', 'Tester',
  'purchase_id', (SELECT id FROM us_booking.shippo_test_purchase WHERE provider_transaction_id = 'txn_mock_1'),
  'content_type', 'application/pdf', 'file_name', 'SHIPPOTEST-x-1.pdf', 'size_bytes', 10, 'sha256', repeat('b', 64), 'kind', 'customs_invoice'));
SELECT test_support.ok('T28 a customs invoice is stored with kind = customs_invoice, distinct from the label',
  (SELECT count(*) FROM us_booking.shippo_test_label l
     JOIN us_booking.shippo_test_purchase p ON p.id = l.purchase_id
    WHERE p.provider_transaction_id = 'txn_mock_1' AND l.kind = 'customs_invoice') = 1);
SELECT test_support.expect_action_error('T28 an unsupported label kind is refused', 'shippo_test_label_add',
  jsonb_build_object('staff', 'Tester', 'purchase_id', (SELECT id FROM us_booking.shippo_test_purchase WHERE provider_transaction_id = 'txn_mock_1'),
    'content_type', 'application/pdf', 'file_name', 'x.pdf', 'size_bytes', 10, 'sha256', repeat('c', 64), 'kind', 'bogus'), 'UB422', 'invalid label kind');

-- Label format setting: applies to future purchases only; this migration never touches a stored label.
SELECT test_support.ok('T28 the label format setting starts unset (Shippo''s own dashboard default applies)',
  (SELECT label_file_type FROM us_booking.shippo_test_settings WHERE id = 1) IS NULL);
SELECT test_support.expect_action_error('T28 an unsupported label format is refused', 'shippo_test_set_label_format',
  jsonb_build_object('staff', 'Tester', 'label_file_type', 'THERMAL_9000'), 'UB422', 'unsupported label format');
SELECT us_booking.shippo_test_set_label_format(jsonb_build_object('staff', 'Tester', 'label_file_type', 'PDF_4x6'));
SELECT test_support.ok('T28 a supported label format is accepted',
  (SELECT label_file_type FROM us_booking.shippo_test_settings WHERE id = 1) = 'PDF_4x6');
SELECT us_booking.shippo_test_set_label_format(jsonb_build_object('staff', 'Tester', 'label_file_type', ''));
SELECT test_support.ok('T28 the format can be cleared back to "use the dashboard default"',
  (SELECT label_file_type FROM us_booking.shippo_test_settings WHERE id = 1) IS NULL);
SELECT test_support.ok('T28 the stored label from before the format change is untouched',
  (SELECT file_name FROM us_booking.shippo_test_label WHERE file_name = 'SHIPPOTEST-1-1.pdf') = 'SHIPPOTEST-1-1.pdf');

SELECT test_support.ok('T28 live booking tables untouched by Shippo test records',
  NOT EXISTS (SELECT 1 FROM us_booking.booking_attempt WHERE correlation_key LIKE 'ust:%')
  AND NOT EXISTS (SELECT 1 FROM us_booking.provider_shipment WHERE provider_label_ref LIKE '%rate_%')
  AND NOT EXISTS (SELECT 1 FROM us_booking.fulfilment_group WHERE group_key LIKE '%ust%'));
RESET ROLE;
