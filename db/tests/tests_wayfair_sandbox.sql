-- Tests for 0010: Wayfair SANDBOX records are isolated from live booking and never repeat a
-- registration. Synthetic data only.
\set ON_ERROR_STOP 1
SET client_min_messages = notice;
SET ROLE us_booking_owner;

SELECT test_support.ok('T23 sandbox tables have no foreign key to live booking tables',
  NOT EXISTS (SELECT 1 FROM pg_constraint c
               WHERE c.contype = 'f' AND c.conrelid IN ('us_booking.wayfair_sandbox_registration'::regclass, 'us_booking.wayfair_sandbox_label'::regclass)
                 AND c.confrelid <> 'us_booking.wayfair_sandbox_registration'::regclass));
SELECT test_support.ok('T23 no live object reads the sandbox tables',
  NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid
               WHERE d.refobjid IN ('us_booking.wayfair_sandbox_registration'::regclass, 'us_booking.wayfair_sandbox_label'::regclass))
  AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'us_booking' AND p.proname !~ '^(wayfair_sandbox_|tg_wayfair_sandbox_)'
                     AND p.prosrc ~ 'wayfair_sandbox_'));

CREATE TEMP TABLE wf AS SELECT (us_booking.wayfair_sandbox_begin('{"staff": "Tester", "po_number": "TEST_100001", "supplier_id": "12345"}')->>'id')::bigint AS id;
SELECT test_support.expect_action_error('T23 a PO with a registration in flight is not registered again', 'wayfair_sandbox_begin',
  '{"staff": "Tester", "po_number": "TEST_100001"}', 'UB409', 'already has a requested registration');
SELECT us_booking.wayfair_sandbox_finish(jsonb_build_object('id', (SELECT id FROM wf), 'state', 'unknown', 'error', 'synthetic timeout'));
SELECT test_support.expect_action_error('T23 an unknown outcome blocks a repeat', 'wayfair_sandbox_begin',
  '{"staff": "Tester", "po_number": "TEST_100001"}', 'UB409', 'already has a unknown registration');
SELECT test_support.expect_error('T23 unknown cannot be turned into success directly',
  $q$UPDATE us_booking.wayfair_sandbox_registration SET state = 'succeeded' WHERE po_number = 'TEST_100001'$q$, 'cannot move from unknown to succeeded');
SELECT test_support.expect_action_error('T23 labels need a registered PO', 'wayfair_sandbox_label_add',
  jsonb_build_object('staff', 'Tester', 'registration_id', (SELECT id FROM wf), 'content_type', 'application/pdf', 'file_name', 'x.pdf',
                     'size_bytes', 10, 'sha256', repeat('a', 64)), 'UB409', 'only for a registered');
SELECT test_support.expect_action_error('T23 resolving an unknown outcome needs evidence', 'wayfair_sandbox_resolve',
  jsonb_build_object('staff', 'Tester', 'id', (SELECT id FROM wf), 'outcome', 'resolved_not_registered', 'evidence', ''), 'UB422', 'Evidence');
SELECT us_booking.wayfair_sandbox_resolve(jsonb_build_object('staff', 'Tester', 'id', (SELECT id FROM wf), 'outcome', 'resolved_not_registered',
  'evidence', 'synthetic: Wayfair support confirmed no registration'));
SELECT us_booking.wayfair_sandbox_begin('{"staff": "Tester", "po_number": "TEST_100001"}');
SELECT test_support.ok('T23 after resolving "not registered" the PO can be registered again (new record, history kept)',
  (SELECT count(*) FROM us_booking.wayfair_sandbox_registration WHERE po_number = 'TEST_100001') = 2);
SELECT us_booking.wayfair_sandbox_finish(jsonb_build_object('id', (SELECT max(id) FROM us_booking.wayfair_sandbox_registration), 'state', 'succeeded',
  'response_summary', '{"event_id": "1"}'));
SELECT us_booking.wayfair_sandbox_label_add(jsonb_build_object('staff', 'Tester', 'registration_id', (SELECT max(id) FROM us_booking.wayfair_sandbox_registration),
  'content_type', 'application/pdf', 'file_name', 'SANDBOX-TEST_100001-1.pdf', 'size_bytes', 10, 'sha256', repeat('a', 64)));
SELECT test_support.expect_error('T23 stored sandbox labels are append-only',
  $q$UPDATE us_booking.wayfair_sandbox_label SET file_name = 'x'$q$, 'append-only');
SELECT test_support.expect_error('T23 sandbox registrations cannot be deleted',
  $q$DELETE FROM us_booking.wayfair_sandbox_registration$q$, 'append-only');
SELECT test_support.ok('T23 a lookup that finds a Wayfair registration is recorded',
  (us_booking.wayfair_sandbox_record_existing('{"staff": "Tester", "po_number": "TEST_100002"}')->>'recorded')::boolean);
SELECT test_support.ok('T23 a second lookup records nothing new',
  NOT (us_booking.wayfair_sandbox_record_existing('{"staff": "Tester", "po_number": "TEST_100002"}')->>'recorded')::boolean);
SELECT test_support.expect_action_error('T23 a PO found registered at Wayfair is not registered again', 'wayfair_sandbox_begin',
  '{"staff": "Tester", "po_number": "TEST_100002"}', 'UB409', 'found_existing');
SELECT test_support.ok('T23 live booking tables untouched by sandbox records',
  NOT EXISTS (SELECT 1 FROM us_booking.booking_attempt WHERE correlation_key LIKE '%TEST_1000%')
  AND NOT EXISTS (SELECT 1 FROM us_booking.provider_shipment WHERE provider_label_ref LIKE '%TEST_1000%'));
RESET ROLE;
