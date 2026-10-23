-- Tests for 0009: parcel contents confirmations follow OMS order-line changes.
-- Synthetic data only; runs after tests_actions.sql in the same disposable database. OMS changes
-- are fed through the real us_booking.oms_sync_apply() with snapshots built below; staff work goes
-- through the staff_* action functions.
\set ON_ERROR_STOP 1
SET client_min_messages = notice;

-- ---------------------------------------------------------------------------------------------
-- Snapshot builder. test_support.world holds the current synthetic OMS state as overrides; each
-- sync_world(p) merges p into it and syncs every group, so sync_world('{}') is an unchanged sync.
--   A 9311: SYN-A qty qa1 (3), SYN-B qty 1             B 9321: SYN-C qty qc (3)
--   C 9331 + child 9332 (+ child 9333 when c_new_child): lines 93311 qty 1, 93321 qty 2 (absent
--     when c_child_line = 'absent'), 93331 qty 1
--   D 9341: SYN-D1 qty qd1 (2), SYN-D2 qty 1            E 9351: SYN-E qty 1 (left out when e_present = false)
-- ---------------------------------------------------------------------------------------------
CREATE TABLE test_support.world (k text PRIMARY KEY, state jsonb NOT NULL);
INSERT INTO test_support.world VALUES ('contents', '{}');
CREATE FUNCTION test_support.o(p_id bigint, p_merge text DEFAULT NULL) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('id', p_id, 'platform_order_ref', 'SYN-SHO-' || p_id, 'source_id', 3, 'channel', 'SHOPIFY',
    'sub_source_id', 245, 'account_name', 'syn', 'market_place', 'US', 'warehouse_id', 32, 'flags', jsonb_build_array('Book from US'),
    'status', 'Inprogress', 'merge', p_merge, 'shipped', 0, 'order_date', '2026-10-21 10:00:00', 'email', NULL,
    'shipments', jsonb_build_object('total', 0, 'tracked_not_cancelled', 0, 'statuses', '[]'::jsonb), 'ebay_cancel_requests', '[]'::jsonb,
    'ship', jsonb_build_object('name', 'Syn ' || p_id, 'line1', p_id || ' Test St', 'city', 'Testville', 'region', 'TX',
                               'postcode', '73301', 'phone', '555', 'country_id', 8)) $$;
CREATE FUNCTION test_support.i(p_id bigint, p_container bigint, p_order bigint, p_sku text, p_qty int, p_real text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('id', p_id, 'order_id', p_container, 'order_ref_id', p_order, 'line_item_id', 'L' || p_id,
    'item_sku', p_sku, 'real_sku', COALESCE(p_real, p_sku), 'item_quantity', p_qty::text, 'real_qty', p_qty::text, 'combo_count', 0) $$;
CREATE FUNCTION test_support.sync_world(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  s jsonb;
  g jsonb := '[]';
  c_orders jsonb;
  c_items jsonb;
BEGIN
  UPDATE test_support.world SET state = state || p WHERE k = 'contents' RETURNING state INTO s;
  g := g || jsonb_build_object('container_id', 9311, 'combos', '[]'::jsonb, 'orders', jsonb_build_array(test_support.o(9311)),
    'items', jsonb_build_array(test_support.i(93111, 9311, 9311, COALESCE(s->>'skua1', 'SYN-A'), COALESCE((s->>'qa1')::int, 3)),
                               test_support.i(93112, 9311, 9311, 'SYN-B', 1)));
  g := g || jsonb_build_object('container_id', 9321, 'combos', '[]'::jsonb, 'orders', jsonb_build_array(test_support.o(9321)),
    'items', jsonb_build_array(test_support.i(93211, 9321, 9321, 'SYN-C', COALESCE((s->>'qc')::int, 3))));
  c_orders := jsonb_build_array(test_support.o(9331, 'merged'), test_support.o(9332, '9331'));
  c_items := jsonb_build_array(test_support.i(93311, 9331, 9331, 'SYN-C1', 1));
  IF COALESCE(s->>'c_child_line', 'present') = 'present' THEN
    c_items := c_items || test_support.i(93321, 9331, 9332, 'SYN-C2', 2);
  END IF;
  IF COALESCE((s->>'c_new_child')::boolean, false) THEN
    c_orders := c_orders || test_support.o(9333, '9331');
    c_items := c_items || test_support.i(93331, 9331, 9333, 'SYN-C3', 1);
  END IF;
  g := g || jsonb_build_object('container_id', 9331, 'combos', '[]'::jsonb, 'orders', c_orders, 'items', c_items);
  g := g || jsonb_build_object('container_id', 9341, 'combos', '[]'::jsonb, 'orders', jsonb_build_array(test_support.o(9341)),
    'items', jsonb_build_array(test_support.i(93411, 9341, 9341, 'SYN-D1', COALESCE((s->>'qd1')::int, 2)),
                               test_support.i(93412, 9341, 9341, 'SYN-D2', 1)));
  IF COALESCE((s->>'e_present')::boolean, true) THEN
    g := g || jsonb_build_object('container_id', 9351, 'combos', '[]'::jsonb, 'orders', jsonb_build_array(test_support.o(9351)),
      'items', jsonb_build_array(test_support.i(93511, 9351, 9351, 'SYN-E', 1)));
  END IF;
  RETURN us_booking.oms_sync_apply(jsonb_build_object('format', 'us_booking.oms_snapshot.v1', 'extracted_at', clock_timestamp()::text,
    'groups', g, 'refresh_ids', CASE WHEN COALESCE((s->>'e_present')::boolean, true) THEN '[]'::jsonb ELSE '[9351]'::jsonb END),
    'system:test-sync');
END $$;
-- Staff action shorthand (staff "Packer Two") and lookups.
CREATE FUNCTION test_support.staff(p_fn text, p jsonb) RETURNS jsonb LANGUAGE sql AS
  $$ SELECT test_support.act(p_fn, p || '{"staff": "Packer Two"}') $$;
CREATE FUNCTION test_support.pv(p_order bigint, p_no integer) RETURNS jsonb LANGUAGE sql STABLE AS
  $$ SELECT jsonb_build_object('parcel_id', test_support.pid(p_order, p_no), 'expected_row_version', test_support.rv(p_order, p_no)) $$;
CREATE FUNCTION test_support.items(VARIADIC p bigint[]) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('items', COALESCE(jsonb_agg(jsonb_build_object('oms_order_item_id', p[k], 'quantity', p[k + 1])), '[]'::jsonb))
    FROM generate_subscripts(p, 1) k WHERE k % 2 = 1 $$;
CREATE FUNCTION test_support.contents_req(p_order bigint) RETURNS us_booking.shipment_requirement LANGUAGE sql STABLE AS
  $$ SELECT * FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(p_order) AND requirement = 'parcel_contents' $$;
CREATE FUNCTION test_support.disc(p_order bigint, p_no integer) RETURNS us_booking.parcel_contents_discrepancy LANGUAGE sql STABLE AS
  $$ SELECT * FROM us_booking.parcel_contents_discrepancy WHERE parcel_id = test_support.pid(p_order, p_no) ORDER BY id DESC LIMIT 1 $$;
CREATE FUNCTION test_support.status(p_order bigint, p_no integer) RETURNS text LANGUAGE sql STABLE AS
  $$ SELECT contents_status FROM us_booking.parcel WHERE id = test_support.pid(p_order, p_no) $$;
GRANT ALL ON test_support.world TO PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_support TO PUBLIC;

SET ROLE us_booking_owner;

-- ============================================================================================
-- T16 Setup: five synthetic groups, parcels prepared and confirmed by staff.
-- ============================================================================================
SELECT test_support.ok('T16 synthetic groups imported', (test_support.sync_world('{}')->'counts'->>'groups_new')::int = 5);
SELECT test_support.staff('staff_parcel_create', jsonb_build_object('group_id', test_support.gid(g)))
  FROM unnest(ARRAY[9311, 9321, 9321, 9331, 9341, 9341, 9351]) g;
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9311, 1) || test_support.items(93111, 3, 93112, 1) || '{"confirm": true}');
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9321, 1) || test_support.items(93211, 2) || '{"confirm": true}');
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9321, 2) || test_support.items(93211, 1) || '{"confirm": true}');
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9331, 1) || test_support.items(93311, 1, 93321, 2) || '{"confirm": true}');
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9341, 1) || test_support.items(93411, 2) || '{"confirm": true}');
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9341, 2) || test_support.items(93412, 1) || '{"confirm": true}');
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9351, 1) || test_support.items(93511, 1) || '{"confirm": true}');
SELECT test_support.ok('T16 every group''s contents requirement met; each confirmation stamped with its basis',
  (SELECT bool_and((test_support.contents_req(g)).status = 'met') FROM unnest(ARRAY[9311, 9321, 9331, 9341, 9351]) g)
  AND NOT EXISTS (SELECT 1 FROM us_booking.parcel p JOIN us_booking.fulfilment_group fg ON fg.id = p.fulfilment_group_id
                   WHERE fg.group_key LIKE 'oms:93%' AND (p.contents_status <> 'confirmed' OR p.contents_basis_hash IS NULL)));
CREATE TEMP TABLE rv_before AS
  SELECT p.id, p.row_version, p.contents_basis_hash FROM us_booking.parcel p JOIN us_booking.fulfilment_group fg ON fg.id = p.fulfilment_group_id
   WHERE fg.group_key LIKE 'oms:93%';

-- ============================================================================================
-- T17 An unchanged sync keeps every valid confirmation.
-- ============================================================================================
SELECT test_support.ok('T17 unchanged sync reports no stale confirmation',
  NOT (test_support.sync_world('{}')->'counts' ? 'parcel_confirmations_stale'));
SELECT test_support.ok('T17 unchanged sync: confirmations, versions and bases untouched, no discrepancy',
  NOT EXISTS (SELECT 1 FROM rv_before b JOIN us_booking.parcel p ON p.id = b.id
               WHERE (p.row_version, p.contents_basis_hash, p.contents_status) IS DISTINCT FROM (b.row_version, b.contents_basis_hash, 'confirmed'))
  AND NOT EXISTS (SELECT 1 FROM us_booking.parcel_contents_discrepancy d JOIN rv_before b ON b.id = d.parcel_id)
  AND (SELECT bool_and((test_support.contents_req(g)).status = 'met') FROM unnest(ARRAY[9311, 9321, 9331, 9341, 9351]) g));

-- ============================================================================================
-- T18 Quantity increase after confirmation.
-- ============================================================================================
CREATE TEMP TABLE a_before AS SELECT test_support.rv(9311, 1) AS rv;
SELECT test_support.ok('T18 sync reports the stale confirmation',
  (test_support.sync_world('{"qa1": 4}')->'counts'->>'parcel_confirmations_stale')::int = 1);
SELECT test_support.ok('T18 confirmation marked stale; earlier confirmation evidence kept; packed quantity untouched',
  test_support.status(9311, 1) = 'stale'
  AND (SELECT confirmed_by = 'Packer Two' AND contents_basis IS NOT NULL FROM us_booking.parcel WHERE id = test_support.pid(9311, 1))
  AND (SELECT quantity FROM us_booking.parcel_item WHERE parcel_id = test_support.pid(9311, 1) AND oms_order_item_id = 93111) = 3);
SELECT test_support.ok('T18 discrepancy shows what changed (ordered 3 -> 4) and the previous confirmation',
  (SELECT status = 'open' AND NOT parcel_locked AND confirmed_by = 'Packer Two'
          AND changes @> '[{"kind": "ordered_quantity_changed", "line": 93111, "from": 3, "to": 4, "packed_here": 3, "below_packed": false}]'
          AND confirmed_basis->'items' @> '[{"line": 93111, "ordered": 3, "packed": 3}]'
     FROM test_support.disc(9311, 1) d));
SELECT test_support.ok('T18 group contents unmet: reconciliation and the extra unit are listed',
  (test_support.contents_req(9311)).status = 'unmet'
  AND (test_support.contents_req(9311)).detail LIKE '%4 of 5 ordered unit(s) in parcels%need reconciliation%');
SELECT test_support.ok('T18 the sync changed the parcel version (stale-edit protection)', test_support.rv(9311, 1) > (SELECT rv FROM a_before));
SELECT test_support.expect_action_error('T18 a staff screen holding the pre-sync version is refused', 'staff_parcel_confirm_contents',
  '{"staff": "Packer Two", "confirmed": true}'::jsonb || jsonb_build_object('parcel_id', test_support.pid(9311, 1), 'expected_row_version', (SELECT rv FROM a_before)),
  'UB409', 'OMS sync');
-- A review case closed by staff does not make stale contents valid.
INSERT INTO us_booking.review_case (case_type, oms_order_id, fulfilment_group_id, details)
VALUES ('oms_status_changed', 9311, test_support.gid(9311), '{"reason": "synthetic: line quantity changed"}');
SELECT test_support.staff('staff_case_close', jsonb_build_object('outcome', 'dismissed', 'evidence', 'synthetic: seen',
  'case_id', (SELECT id FROM us_booking.review_case WHERE oms_order_id = 9311 AND status = 'open'),
  'expected_details_hash', (SELECT md5(details::text) FROM us_booking.review_case WHERE oms_order_id = 9311 AND status = 'open')));
SELECT test_support.ok('T18 dismissing the review case leaves the contents stale and the requirement unmet',
  test_support.status(9311, 1) = 'stale' AND (test_support.contents_req(9311)).status = 'unmet'
  AND (test_support.disc(9311, 1)).status = 'open');
-- Reconcile: confirm the parcel again, then pack the extra unit in a second parcel.
SELECT test_support.staff('staff_parcel_confirm_contents', test_support.pv(9311, 1) || '{"confirmed": true}');
SELECT test_support.ok('T18 reconfirmation closes the discrepancy with the staff name and the new basis',
  (SELECT status = 'reconciled' AND resolved_by = 'Packer Two' AND resolution_basis->'items' @> '[{"line": 93111, "ordered": 4}]'
     FROM test_support.disc(9311, 1))
  AND test_support.status(9311, 1) = 'confirmed');
SELECT test_support.ok('T18 contents still unmet while one ordered unit is not packed',
  (test_support.contents_req(9311)).status = 'unmet' AND (test_support.contents_req(9311)).detail LIKE '4 of 5 ordered unit(s)%');
SELECT test_support.staff('staff_parcel_create', jsonb_build_object('group_id', test_support.gid(9311)));
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9311, 2) || test_support.items(93111, 1) || '{"confirm": true}');
SELECT test_support.ok('T18 after reconciliation and reconfirmation the requirement is met',
  (test_support.contents_req(9311)).status = 'met');

-- ============================================================================================
-- T19 Quantity falling below the packed units (split parcels).
-- ============================================================================================
SELECT test_support.sync_world('{"qc": 1}');
SELECT test_support.ok('T19 both split parcels holding the line become stale',
  test_support.status(9321, 1) = 'stale' AND test_support.status(9321, 2) = 'stale');
SELECT test_support.ok('T19 the change is explicit: 1 ordered, 3 packed across parcels',
  (test_support.disc(9321, 1)).changes @> '[{"kind": "ordered_quantity_changed", "from": 3, "to": 1, "packed_here": 2, "packed_all_parcels": 3, "below_packed": true}]');
SELECT test_support.ok('T19 nothing reduced or redistributed automatically',
  (SELECT array_agg(quantity ORDER BY parcel_id) FROM us_booking.parcel_item WHERE oms_order_item_id = 93211) = '{2,1}'
  AND (SELECT allocated_qty FROM us_booking.item_allocation WHERE oms_order_item_id = 93211) = 3);
SELECT test_support.ok('T19 requirement unmet and names the over-allocation',
  (test_support.contents_req(9321)).status = 'unmet'
  AND (test_support.contents_req(9321)).detail LIKE '%SYN-C (line 93211): 3 in parcels but 1 ordered%');
SELECT test_support.expect_action_error('T19 confirming over-allocated contents as they are is refused', 'staff_parcel_confirm_contents',
  '{"staff": "Packer Two", "confirmed": true}'::jsonb || test_support.pv(9321, 1), '23514', '3 unit\(s\) in parcels but only 1 ordered');
SELECT test_support.staff('staff_parcel_remove', test_support.pv(9321, 2));
SELECT test_support.ok('T19 a removed stale parcel is cancelled (history kept) and its discrepancy closed',
  (SELECT state FROM us_booking.parcel WHERE id = test_support.pid(9321, 2)) = 'cancelled'
  AND (test_support.disc(9321, 2)).status = 'reconciled');
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9321, 1) || test_support.items(93211, 1) || '{"confirm": true}');
SELECT test_support.ok('T19 reduced by staff and reconfirmed: requirement met, discrepancy reconciled',
  (test_support.contents_req(9321)).status = 'met' AND (test_support.disc(9321, 1)).status = 'reconciled'
  AND (SELECT allocated_qty FROM us_booking.item_allocation WHERE oms_order_item_id = 93211) = 1);

-- ============================================================================================
-- T20 Removed line and changed membership (merged orders).
-- ============================================================================================
SELECT test_support.sync_world('{"c_child_line": "absent"}');
SELECT test_support.ok('T20 line missing from the OMS is recorded on the line and the merged parcel goes stale',
  (SELECT oms_absent_since IS NOT NULL FROM us_booking.oms_order_item WHERE oms_order_item_id = 93321)
  AND test_support.status(9331, 1) = 'stale'
  AND (test_support.disc(9331, 1)).changes @> '[{"kind": "line_no_longer_in_oms", "line": 93321, "packed_here": 2}]');
SELECT test_support.expect_action_error('T20 contents with a line the OMS dropped cannot be confirmed', 'staff_parcel_confirm_contents',
  '{"staff": "Packer Two", "confirmed": true}'::jsonb || test_support.pv(9331, 1), '23514', 'no longer in the OMS');
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9331, 1) || test_support.items(93311, 1) || '{"confirm": true}');
SELECT test_support.ok('T20 reconciled without the dropped line: requirement met',
  (test_support.contents_req(9331)).status = 'met' AND (test_support.disc(9331, 1)).status = 'reconciled');
SELECT test_support.sync_world('{"c_new_child": true}');
SELECT test_support.ok('T20 an order merged into the group makes its confirmed parcel stale',
  test_support.status(9331, 1) = 'stale'
  AND (test_support.disc(9331, 1)).changes @> '[{"kind": "order_added_to_group", "order": 9333}]'
  AND (test_support.contents_req(9331)).status = 'unmet');
SELECT test_support.staff('staff_parcel_confirm_contents', test_support.pv(9331, 1) || '{"confirmed": true}');
SELECT test_support.staff('staff_parcel_create', jsonb_build_object('group_id', test_support.gid(9331)));
SELECT test_support.staff('staff_parcel_set_contents', test_support.pv(9331, 2) || test_support.items(93331, 1) || '{"confirm": true}');
SELECT test_support.ok('T20 reconfirmed and the new order packed: requirement met',
  (test_support.contents_req(9331)).status = 'met');

-- An order the OMS no longer returns (refresh id missing from the snapshot).
SELECT test_support.sync_world('{"e_present": false}');
SELECT test_support.ok('T20 order not returned by the OMS: its lines are marked and its parcel goes stale',
  (SELECT oms_absent_since IS NOT NULL FROM us_booking.oms_order_item WHERE oms_order_item_id = 93511)
  AND test_support.status(9351, 1) = 'stale'
  AND EXISTS (SELECT 1 FROM us_booking.review_case WHERE oms_order_id = 9351 AND details->>'signature' = 'missing-from-oms' AND status = 'open'));
SELECT test_support.staff('staff_case_close', jsonb_build_object('outcome', 'dismissed', 'evidence', 'synthetic: temporary OMS gap',
  'case_id', (SELECT id FROM us_booking.review_case WHERE oms_order_id = 9351 AND status = 'open'),
  'expected_details_hash', (SELECT md5(details::text) FROM us_booking.review_case WHERE oms_order_id = 9351 AND status = 'open')));
SELECT test_support.ok('T20 dismissing that case does not make the contents valid',
  test_support.status(9351, 1) = 'stale' AND (test_support.contents_req(9351)).status = 'unmet');
SELECT test_support.sync_world('{"e_present": true}');
SELECT test_support.ok('T20 the order returns: line present again, but nothing is confirmed automatically',
  (SELECT oms_absent_since IS NULL FROM us_booking.oms_order_item WHERE oms_order_item_id = 93511)
  AND test_support.status(9351, 1) = 'stale' AND (test_support.disc(9351, 1)).status = 'open'
  AND (test_support.disc(9351, 1)).changes = '[]');
SELECT test_support.staff('staff_parcel_confirm_contents', test_support.pv(9351, 1) || '{"confirmed": true}');
SELECT test_support.ok('T20 staff reconfirmation after the order returned: requirement met',
  (test_support.contents_req(9351)).status = 'met');
CREATE TEMP TABLE sku_sync AS SELECT test_support.sync_world('{"skua1": "SYN-A-NEW"}') AS summary;
SELECT test_support.ok('T20 SKU identity change makes the confirmation stale',
  (SELECT (summary->'counts'->>'parcel_confirmations_stale')::int = 2 FROM sku_sync)
  AND (test_support.disc(9311, 1)).changes @> '[{"kind": "sku_changed", "from": "SYN-A / SYN-A", "to": "SYN-A-NEW / SYN-A-NEW"}]');
SELECT test_support.staff('staff_parcel_confirm_contents', test_support.pv(9311, n) || '{"confirmed": true}') FROM generate_series(1, 2) n;
SELECT test_support.ok('T20 reconfirmed after the SKU change: requirement met', (test_support.contents_req(9311)).status = 'met');

-- ============================================================================================
-- T21 Locked parcels: never changed by the sync; discrepancy blocks further purchasing.
-- ============================================================================================
RESET ROLE;
BEGIN;
ALTER TABLE us_booking.booking_attempt DISABLE TRIGGER booking_attempt_insert;
INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 1, 'usb:test:contents-lock', 'rh', 'tester@example.test'
  FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9341, 1);
SET CONSTRAINTS ALL IMMEDIATE;  -- run the deferred outcome check now so the trigger can be re-enabled
ALTER TABLE us_booking.booking_attempt ENABLE TRIGGER booking_attempt_insert;
COMMIT;
CREATE TEMP TABLE d_before AS
  SELECT p.*, (SELECT jsonb_agg(to_jsonb(pi) ORDER BY pi.oms_order_item_id) FROM us_booking.parcel_item pi WHERE pi.parcel_id = p.id) AS items
    FROM us_booking.parcel p WHERE p.id = test_support.pid(9341, 1);
SELECT test_support.ok('T21 the sync completes although a changed line sits in a locked parcel',
  (test_support.sync_world('{"qd1": 3}')->'counts'->>'parcel_confirmations_stale')::int = 1);
SELECT test_support.ok('T21 locked parcel untouched: status, version, basis and items unchanged',
  (SELECT (p.contents_status, p.row_version, p.contents_basis_hash, p.confirmed_by) = (b.contents_status, b.row_version, b.contents_basis_hash, b.confirmed_by)
     FROM us_booking.parcel p, d_before b WHERE p.id = b.id)
  AND (SELECT jsonb_agg(to_jsonb(pi) ORDER BY pi.oms_order_item_id) FROM us_booking.parcel_item pi WHERE pi.parcel_id = test_support.pid(9341, 1))
      = (SELECT items FROM d_before)
  AND (SELECT count(*) FROM us_booking.booking_attempt WHERE parcel_id = test_support.pid(9341, 1)) = 1);
SELECT test_support.ok('T21 discrepancy recorded against the locked parcel',
  (SELECT status = 'open' AND parcel_locked AND changes @> '[{"kind": "ordered_quantity_changed", "from": 2, "to": 3}]'
     FROM test_support.disc(9341, 1)));
SELECT test_support.ok('T21 the unaffected parcel of the group keeps its confirmation', test_support.status(9341, 2) = 'confirmed');
UPDATE us_booking.fulfilment_group SET state = 'ready' WHERE id = test_support.gid(9341);
SELECT test_support.expect_error('T21 purchasing another parcel of the group is blocked by the discrepancy',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 1, 'usb:test:contents-p2', 'rh', 'tester@example.test'
       FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9341, 2)$q$,
  'discrepancies awaiting staff reconciliation');
SELECT test_support.expect_action_error('T21 acknowledging with an outdated view is refused', 'staff_discrepancy_acknowledge',
  jsonb_build_object('staff', 'Supervisor', 'evidence', 'synthetic', 'discrepancy_id', (test_support.disc(9341, 1)).id, 'expected_current_hash', md5('x')),
  'UB409', 'changed again');
SELECT test_support.expect_action_error('T21 acknowledging an unlocked parcel is refused (it must be reconfirmed)', 'staff_discrepancy_acknowledge',
  jsonb_build_object('staff', 'Supervisor', 'evidence', 'synthetic', 'discrepancy_id', (test_support.disc(9311, 1)).id,
                     'expected_current_hash', (test_support.disc(9311, 1)).current_hash),
  'UB409', 'already reconciled|not locked');
SELECT test_support.act('staff_discrepancy_acknowledge', jsonb_build_object('staff', 'Supervisor',
  'evidence', 'synthetic: the booked parcel holds the 2 units it should; the extra unit ships separately',
  'discrepancy_id', (test_support.disc(9341, 1)).id, 'expected_current_hash', (test_support.disc(9341, 1)).current_hash));
SELECT test_support.ok('T21 acknowledged with identity and evidence; the parcel itself still unchanged',
  (SELECT status = 'acknowledged' AND resolved_by = 'Supervisor' FROM test_support.disc(9341, 1))
  AND (SELECT row_version FROM us_booking.parcel WHERE id = test_support.pid(9341, 1)) = (SELECT row_version FROM d_before));
SELECT test_support.expect_error('T21 after acknowledgement the discrepancy no longer blocks; the unpacked extra unit still does',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 1, 'usb:test:contents-p2', 'rh', 'tester@example.test'
       FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9341, 2)$q$,
  'unmet shipment requirements');
SELECT test_support.sync_world('{}');
SELECT test_support.ok('T21 an unchanged sync does not reopen the acknowledged discrepancy',
  (SELECT count(*) FROM us_booking.parcel_contents_discrepancy WHERE parcel_id = test_support.pid(9341, 1)) = 1);
SELECT test_support.sync_world('{"qd1": 1}');
SELECT test_support.ok('T21 a further change (now below the packed units) opens a new discrepancy on the locked parcel',
  (SELECT status = 'open' AND parcel_locked AND changes @> '[{"kind": "ordered_quantity_changed", "from": 2, "to": 1, "below_packed": true}]'
     FROM test_support.disc(9341, 1))
  AND test_support.status(9341, 1) = 'confirmed');
SELECT test_support.act('staff_discrepancy_acknowledge', jsonb_build_object('staff', 'Supervisor', 'evidence', 'synthetic: label to be voided',
  'discrepancy_id', (test_support.disc(9341, 1)).id, 'expected_current_hash', (test_support.disc(9341, 1)).current_hash));
SELECT test_support.expect_error('T21 an allocation above the ordered quantity keeps purchasing blocked even after acknowledgement',
  $q$INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 1, 'usb:test:contents-p2', 'rh', 'tester@example.test'
       FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9341, 2)$q$,
  'no longer match its order lines.*2 in parcels but 1 ordered');
SELECT test_support.expect_error('T21 the stale locked parcel itself cannot be purchased again (basis check)',
  $q$UPDATE us_booking.booking_attempt SET state = 'failed' WHERE parcel_id = test_support.pid(9341, 1);
     INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
     SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 2, 'usb:test:contents-p1b', 'rh', 'tester@example.test'
       FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9341, 1)$q$,
  'confirmed against order data that has since changed');
SET ROLE us_booking_owner;
