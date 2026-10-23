-- Tests for migrations 0006-0008: verified country mapping, package profiles and parcel
-- provenance, the parcel workflow, staff review actions and failed-sync records.
-- Synthetic data only. Runs after tests.sql in the same disposable database; staff actions run as
-- the schema owner (the approved single-role setup).
\set ON_ERROR_STOP 1
SET client_min_messages = notice;

-- Test helpers (test cluster only).
CREATE FUNCTION test_support.rv(p_order bigint, p_no integer) RETURNS integer LANGUAGE sql STABLE AS
  $$ SELECT row_version FROM us_booking.parcel WHERE id = test_support.pid(p_order, p_no) $$;
CREATE FUNCTION test_support.act(p_fn text, p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  EXECUTE format('SELECT us_booking.%I($1)', p_fn) INTO r USING p;
  RETURN r;
END $$;
-- Like expect_error, but for a staff action with a jsonb payload, also checking the SQLSTATE.
CREATE FUNCTION test_support.expect_action_error(p_label text, p_fn text, p jsonb, p_state text, p_pattern text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_msg text; v_state text;
BEGIN
  BEGIN
    PERFORM test_support.act(p_fn, p);
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM; v_state := SQLSTATE;
  END;
  IF v_state IS NULL THEN
    RAISE EXCEPTION 'FAIL [%]: action was accepted but should have been rejected', p_label;
  END IF;
  IF v_state !~ ('^(' || p_state || ')$') OR v_msg !~* p_pattern THEN
    RAISE EXCEPTION 'FAIL [%]: rejected with an unexpected error (%): %', p_label, v_state, v_msg;
  END IF;
  RAISE NOTICE 'PASS [%] rejected (%): %', p_label, v_state, v_msg;
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_support TO PUBLIC;

SET ROLE us_booking_owner;

-- ============================================================================================
-- T11 Verified country mapping (0006): 8 -> US, 359 -> CA, applied automatically.
-- ============================================================================================
SELECT test_support.ok('T11 0006 rows are verified with the reported evidence',
  (SELECT array_agg(oms_country_id || ':' || iso2 || ':' || status || ':' || verified_by ORDER BY oms_country_id) FROM us_booking.country_map
    WHERE evidence = 'OMS developer confirmation reported by project owner on 2026-10-23.')
  = '{8:US:verified:project owner,359:CA:verified:project owner}');
SELECT test_support.ok('T11 0006 is logged in event_log',
  (SELECT count(*) FROM us_booking.event_log WHERE entity = 'country_map' AND actor = 'migration:0006') = 2);

-- Import through the real sync function. 9201: Shopify, country_id sent as the text "08".
-- 9202: Amazon, 359. 9203: Wayfair, unmapped id 9999, flagged Book from UK, OMS shipped flag set.
-- 9204 + 9205: Shopify merge (parent 9204, child 9205), country 8, lines held by the container.
-- 9206: eBay, no country id.
CREATE TEMP TABLE snap AS SELECT $j${
  "format": "us_booking.oms_snapshot.v1", "extracted_at": "2026-10-23T10:00:00Z", "refresh_ids": [],
  "groups": [
    {"container_id": 9201, "combos": [],
     "orders": [{"id": 9201, "platform_order_ref": "SYN-SHO-9201", "source_id": 3, "channel": "SHOPIFY", "sub_source_id": 245,
                 "account_name": "syn", "market_place": "US", "warehouse_id": 32, "flags": ["Book from US"], "status": "Inprogress",
                 "merge": null, "shipped": 0, "order_date": "2026-10-20 10:00:00", "email": "a@example.test",
                 "shipments": {"total": 0, "tracked_not_cancelled": 0, "statuses": []}, "ebay_cancel_requests": [],
                 "ship": {"name": "Syn A", "line1": "1 Test St", "city": "Testville", "region": "TX", "postcode": "73301", "phone": "555", "country_id": "08"}}],
     "items": [{"id": 92011, "order_id": 9201, "order_ref_id": 9201, "line_item_id": "L1", "item_sku": "SYN-A", "real_sku": "SYN-A", "item_quantity": "3", "real_qty": "3", "combo_count": 0},
               {"id": 92012, "order_id": 9201, "order_ref_id": 9201, "line_item_id": "L2", "item_sku": "SYN-B", "real_sku": "SYN-B", "item_quantity": "1", "real_qty": "1", "combo_count": 0}]},
    {"container_id": 9202, "combos": [],
     "orders": [{"id": 9202, "platform_order_ref": "SYN-AMZ-9202", "source_id": 1, "channel": "AMAZON", "sub_source_id": 239,
                 "account_name": "syn", "market_place": "US", "warehouse_id": 32, "flags": ["Book from US"], "status": "Inprogress",
                 "merge": null, "shipped": 0, "order_date": "2026-10-20 11:00:00", "email": null,
                 "shipments": {"total": 0, "tracked_not_cancelled": 0, "statuses": []}, "ebay_cancel_requests": [],
                 "ship": {"name": "Syn B", "line1": "2 Test St", "city": "Testtown", "region": "ON", "postcode": "K1A0B1", "phone": "555", "country_id": 359}}],
     "items": [{"id": 92021, "order_id": 9202, "order_ref_id": 9202, "line_item_id": "L1", "item_sku": "SYN-C", "real_sku": "SYN-C", "item_quantity": "2", "real_qty": "2", "combo_count": 0}]},
    {"container_id": 9203, "combos": [],
     "orders": [{"id": 9203, "platform_order_ref": "SYN-WAY-9203", "source_id": 6, "channel": "WAYFAIR", "sub_source_id": 258,
                 "account_name": "syn", "market_place": "US", "warehouse_id": 32, "flags": ["Book from UK"], "status": "New",
                 "merge": null, "shipped": 1, "order_date": "2026-10-20 12:00:00", "email": null,
                 "shipments": {"total": 0, "tracked_not_cancelled": 0, "statuses": []}, "ebay_cancel_requests": [],
                 "ship": {"name": "Syn C", "line1": "3 Test St", "city": "Testford", "region": "NY", "postcode": "10001", "phone": "555", "country_id": 9999}}],
     "items": [{"id": 92031, "order_id": 9203, "order_ref_id": 9203, "line_item_id": "L1", "item_sku": "SYN-D", "real_sku": "SYN-D", "item_quantity": "1", "real_qty": "1", "combo_count": 0}]},
    {"container_id": 9204, "combos": [],
     "orders": [{"id": 9204, "platform_order_ref": "SYN-SHO-9204", "source_id": 3, "channel": "SHOPIFY", "sub_source_id": 245,
                 "account_name": "syn", "market_place": "US", "warehouse_id": 32, "flags": ["Book from US"], "status": "Inprogress",
                 "merge": "merged", "shipped": 0, "order_date": "2026-10-20 13:00:00", "email": null,
                 "shipments": {"total": 0, "tracked_not_cancelled": 0, "statuses": []}, "ebay_cancel_requests": [],
                 "ship": {"name": "Syn D", "line1": "4 Test St", "city": "Testham", "region": "WA", "postcode": "98001", "phone": "555", "country_id": 8}},
                {"id": 9205, "platform_order_ref": "SYN-SHO-9205", "source_id": 3, "channel": "SHOPIFY", "sub_source_id": 245,
                 "account_name": "syn", "market_place": "US", "warehouse_id": 32, "flags": ["Book from US"], "status": "Inprogress",
                 "merge": "9204", "shipped": 0, "order_date": "2026-10-20 12:30:00", "email": null,
                 "shipments": {"total": 0, "tracked_not_cancelled": 0, "statuses": []}, "ebay_cancel_requests": [],
                 "ship": {"name": "Syn D", "line1": "4 Test St", "city": "Testham", "region": "WA", "postcode": "98001", "phone": "555", "country_id": 8}}],
     "items": [{"id": 92041, "order_id": 9204, "order_ref_id": 9204, "line_item_id": "L1", "item_sku": "SYN-E", "real_sku": "SYN-E", "item_quantity": "2", "real_qty": "2", "combo_count": 0},
               {"id": 92051, "order_id": 9204, "order_ref_id": 9205, "line_item_id": "L1", "item_sku": "SYN-F", "real_sku": "SYN-F", "item_quantity": "4", "real_qty": "4", "combo_count": 0}]},
    {"container_id": 9206, "combos": [],
     "orders": [{"id": 9206, "platform_order_ref": "SYN-EBY-9206", "source_id": 2, "channel": "EBAY", "sub_source_id": 22,
                 "account_name": "syn", "market_place": "US", "warehouse_id": 32, "flags": ["Book from US"], "status": "Inprogress",
                 "merge": null, "shipped": 0, "order_date": "2026-10-20 14:00:00", "email": null,
                 "shipments": {"total": 0, "tracked_not_cancelled": 0, "statuses": []}, "ebay_cancel_requests": [],
                 "ship": {"name": "Syn E", "line1": "6 Test St", "city": "Testcity", "region": "CA", "postcode": "90001", "phone": "555", "country_id": null}}],
     "items": [{"id": 92061, "order_id": 9206, "order_ref_id": 9206, "line_item_id": "L1", "item_sku": "SYN-G", "real_sku": "SYN-G", "item_quantity": "1", "real_qty": "1", "combo_count": 0}]}
  ]}$j$::jsonb AS doc;
SELECT test_support.ok('T11 sync imports the synthetic snapshot',
  (SELECT (us_booking.oms_sync_apply(doc, 'system:test-sync')->'counts'->>'groups_new')::int = 5 FROM snap));

SELECT test_support.ok('T11 country id sent as "08" is stored as 8 and resolves to US',
  (SELECT o.oms_country_id = 8 AND d.destination_iso2 = 'US' AND d.destination_source = 'country_map'
     FROM us_booking.oms_order o JOIN us_booking.v_order_destination d USING (oms_order_id) WHERE o.oms_order_id = 9201));
SELECT test_support.ok('T11 country id 359 resolves to Canada',
  (SELECT destination_iso2 = 'CA' AND destination_source = 'country_map' FROM us_booking.v_order_destination WHERE oms_order_id = 9202));
SELECT test_support.ok('T11 both orders of a merge resolve through the map',
  (SELECT bool_and(destination_iso2 = 'US') FROM us_booking.v_order_destination WHERE oms_order_id IN (9204, 9205)));
SELECT test_support.ok('T11 mapped orders: destination requirement met without any confirmation',
  (SELECT bool_and(status = 'met') FROM us_booking.shipment_requirement
    WHERE oms_order_id IN (9201, 9202, 9204, 9205) AND requirement = 'destination_country')
  AND NOT EXISTS (SELECT 1 FROM us_booking.order_destination_confirmation WHERE oms_order_id BETWEEN 9201 AND 9206));
SELECT test_support.ok('T11 mapped US: customs not applicable; mapped Canada: customs required',
  (SELECT status FROM us_booking.shipment_requirement WHERE oms_order_id = 9201 AND requirement = 'customs_declaration') = 'not_applicable'
  AND (SELECT status = 'unmet' AND detail LIKE 'Canada destination%' FROM us_booking.shipment_requirement
        WHERE oms_order_id = 9202 AND requirement = 'customs_declaration'));
SELECT test_support.ok('T11 unknown country id stays in review',
  (SELECT destination_iso2 IS NULL AND destination_source = 'unresolved' FROM us_booking.v_order_destination WHERE oms_order_id = 9203)
  AND (SELECT status = 'unmet' AND detail LIKE '%9999%' FROM us_booking.shipment_requirement
        WHERE oms_order_id = 9203 AND requirement = 'destination_country'));
SELECT test_support.ok('T11 missing country id stays in review',
  (SELECT destination_source = 'unresolved' FROM us_booking.v_order_destination WHERE oms_order_id = 9206)
  AND (SELECT status FROM us_booking.shipment_requirement WHERE oms_order_id = 9206 AND requirement = 'destination_country') = 'unmet');
SELECT test_support.ok('T11 mapping does not verify provider accounts or routes',
  (SELECT bool_and(status = 'unmet') FROM us_booking.shipment_requirement
    WHERE fulfilment_group_id IN (test_support.gid(9201), test_support.gid(9202)) AND requirement = 'provider_account')
  AND (SELECT status FROM us_booking.shipment_requirement
        WHERE fulfilment_group_id = test_support.gid(9202) AND requirement = 'routing_verified') = 'unmet');

-- Manual confirmation: exceptions only, with evidence and stale-address protection.
SELECT test_support.expect_action_error('T11 confirmation refused for a mapped order', 'staff_destination_confirm',
  jsonb_build_object('staff', 'Synthetic Staff', 'oms_order_id', 9201, 'iso2', 'US', 'evidence_type', 'other', 'evidence_ref', 'synthetic',
                     'expected_address_hash', (SELECT ship_address_hash FROM us_booking.oms_order WHERE oms_order_id = 9201)),
  'UB409', 'already resolved by the verified country map');
SELECT test_support.expect_action_error('T11 confirmation refused against an outdated address', 'staff_destination_confirm',
  jsonb_build_object('staff', 'Synthetic Staff', 'oms_order_id', 9203, 'iso2', 'US', 'evidence_type', 'other', 'evidence_ref', 'synthetic',
                     'expected_address_hash', 'not-the-current-hash'),
  'UB409', 'ship-to address changed');
SELECT test_support.expect_action_error('T11 confirmation needs a staff name', 'staff_destination_confirm',
  jsonb_build_object('staff', ' ', 'oms_order_id', 9203, 'iso2', 'US', 'evidence_type', 'other', 'evidence_ref', 'synthetic'),
  'UB422', 'enter your name');
SELECT test_support.expect_action_error('T11 confirmation needs evidence', 'staff_destination_confirm',
  jsonb_build_object('staff', 'Synthetic Staff', 'oms_order_id', 9203, 'iso2', 'US', 'evidence_type', 'other', 'evidence_ref', ' ',
                     'expected_address_hash', (SELECT ship_address_hash FROM us_booking.oms_order WHERE oms_order_id = 9203)),
  'UB422', 'Evidence must be');
SELECT test_support.act('staff_destination_confirm',
  jsonb_build_object('staff', 'Synthetic Staff', 'oms_order_id', 9203, 'iso2', 'US', 'evidence_type', 'marketplace_order_record',
                     'evidence_ref', 'synthetic: Wayfair order page shows a US address',
                     'expected_address_hash', (SELECT ship_address_hash FROM us_booking.oms_order WHERE oms_order_id = 9203)));
SELECT test_support.ok('T11 exception confirmed with staff identity and evidence; requirements updated at once',
  (SELECT destination_iso2 = 'US' AND destination_source = 'order_confirmation' FROM us_booking.v_order_destination WHERE oms_order_id = 9203)
  AND (SELECT confirmed_by = 'Synthetic Staff' AND oms_country_id_seen = 9999 FROM us_booking.order_destination_confirmation
        WHERE oms_order_id = 9203 AND status = 'active')
  AND (SELECT status FROM us_booking.shipment_requirement WHERE oms_order_id = 9203 AND requirement = 'destination_country') = 'met'
  AND (SELECT status FROM us_booking.shipment_requirement WHERE oms_order_id = 9203 AND requirement = 'customs_declaration') = 'not_applicable');
SELECT test_support.expect_action_error('T11 a second confirmation is refused', 'staff_destination_confirm',
  jsonb_build_object('staff', 'Synthetic Staff', 'oms_order_id', 9203, 'iso2', 'CA', 'evidence_type', 'other', 'evidence_ref', 'synthetic',
                     'expected_address_hash', (SELECT ship_address_hash FROM us_booking.oms_order WHERE oms_order_id = 9203)),
  'UB409', 'already has a valid confirmation');
SELECT test_support.act('staff_destination_revoke',
  jsonb_build_object('staff', 'Synthetic Staff', 'reason', 'synthetic: entered on the wrong order',
                     'confirmation_id', (SELECT id FROM us_booking.order_destination_confirmation WHERE oms_order_id = 9203 AND status = 'active'),
                     'expected_address_hash', (SELECT ship_address_hash FROM us_booking.oms_order WHERE oms_order_id = 9203)));
SELECT test_support.ok('T11 revoked confirmation: order back in review, history kept',
  (SELECT destination_source = 'unresolved' FROM us_booking.v_order_destination WHERE oms_order_id = 9203)
  AND (SELECT status FROM us_booking.shipment_requirement WHERE oms_order_id = 9203 AND requirement = 'destination_country') = 'unmet'
  AND (SELECT revoked_by = 'Synthetic Staff' FROM us_booking.order_destination_confirmation WHERE oms_order_id = 9203));

-- ============================================================================================
-- T12 Package profiles: versions, assignments, prefilling, manual overrides.
-- ============================================================================================
SELECT test_support.act('staff_parcel_create', jsonb_build_object('staff', 'Synthetic Staff', 'group_id', test_support.gid(9206)));
SELECT test_support.ok('T12 no default assigned yet: parcel starts without dimensions or weight',
  (SELECT length IS NULL AND weight IS NULL AND dimensions_source IS NULL AND package_profile_id IS NULL AND measured_by IS NULL
     FROM us_booking.parcel WHERE id = test_support.pid(9206, 1)));

SELECT test_support.expect_action_error('T12 zero dimension rejected', 'staff_profile_save',
  '{"staff": "Synthetic Staff", "name": "Bad", "length": "0", "width": "6", "height": "6", "dimension_unit": "in"}', 'UB422', 'Length must be a positive number');
SELECT test_support.expect_action_error('T12 weight needs a unit', 'staff_profile_save',
  '{"staff": "Synthetic Staff", "name": "Bad", "length": "9", "width": "6", "height": "6", "dimension_unit": "in", "packed_weight": "2"}', 'UB422', 'needs a unit');
SELECT test_support.expect_action_error('T12 unknown dimension unit rejected', 'staff_profile_save',
  '{"staff": "Synthetic Staff", "name": "Bad", "length": "9", "width": "6", "height": "6", "dimension_unit": "ft"}', 'UB422', 'dimension unit');
SELECT test_support.act('staff_profile_save',
  '{"staff": "Synthetic Staff", "name": "Syn Shippo Default", "length": "9", "width": "6", "height": "6", "dimension_unit": "in", "packed_weight": "2", "packed_weight_unit": "kg"}');
SELECT test_support.act('staff_profile_save',
  '{"staff": "Synthetic Staff", "name": "Syn Amazon Default", "length": "9", "width": "6", "height": "6", "dimension_unit": "in", "packed_weight": "2", "packed_weight_unit": "lb", "empty_weight": "0.4", "empty_weight_unit": "lb"}');
SELECT test_support.expect_action_error('T12 duplicate profile name rejected', 'staff_profile_save',
  '{"staff": "Synthetic Staff", "name": "syn shippo default", "length": "1", "width": "1", "height": "1", "dimension_unit": "in"}', 'UB409', 'already exists');
SELECT test_support.ok('T12 profiles saved as approved version 1 with units as entered',
  (SELECT array_agg(pp.name || ':' || v.version || ':' || v.packed_weight || v.packed_weight_unit ORDER BY pp.name)
     FROM us_booking.package_profile pp JOIN us_booking.package_profile_version v ON v.profile_id = pp.id AND v.version = pp.current_version
    WHERE pp.approval_status = 'approved')
  = '{Syn Amazon Default:1:2.000lb,Syn Shippo Default:1:2.000kg}');
SELECT test_support.ok('T12 empty packaging weight kept separate from packed weight',
  (SELECT empty_weight = 0.4 AND empty_weight_unit = 'lb' AND packed_weight = 2 FROM us_booking.package_profile_version v
     JOIN us_booking.package_profile pp ON pp.id = v.profile_id WHERE pp.name = 'Syn Amazon Default'));

SELECT test_support.act('staff_profile_assign', jsonb_build_object('staff', 'Synthetic Staff', 'assignment', 'us1_shippo',
  'profile_id', (SELECT id FROM us_booking.package_profile WHERE name = 'Syn Shippo Default'), 'expected_profile_id', NULL));
SELECT test_support.act('staff_profile_assign', jsonb_build_object('staff', 'Synthetic Staff', 'assignment', 'us1_amazon',
  'profile_id', (SELECT id FROM us_booking.package_profile WHERE name = 'Syn Amazon Default'), 'expected_profile_id', NULL));
SELECT test_support.expect_action_error('T12 stale assignment change refused', 'staff_profile_assign',
  jsonb_build_object('staff', 'Synthetic Staff', 'assignment', 'us1_shippo', 'profile_id', NULL, 'expected_profile_id', NULL),
  'UB409', 'changed by someone else');

-- Prefill: Shippo group (Shopify), Amazon group, Wayfair group (no assignment).
SELECT test_support.act('staff_parcel_create', jsonb_build_object('staff', 'Synthetic Staff', 'group_id', test_support.gid(9201)));
SELECT test_support.act('staff_parcel_create', jsonb_build_object('staff', 'Synthetic Staff', 'group_id', test_support.gid(9202)));
SELECT test_support.act('staff_parcel_create', jsonb_build_object('staff', 'Synthetic Staff', 'group_id', test_support.gid(9203)));
SELECT test_support.ok('T12 Shippo parcel prefilled: 9 x 6 x 6 in, 2 kg, from the profile, not measured by staff',
  (SELECT length = 9 AND width = 6 AND height = 6 AND dimension_unit = 'in' AND weight = 2 AND weight_unit = 'kg'
          AND dimensions_source = 'profile' AND weight_source = 'profile' AND measured_by IS NULL AND measured_at IS NULL
          AND package_profile_version = 1
     FROM us_booking.parcel WHERE id = test_support.pid(9201, 1)));
SELECT test_support.ok('T12 Amazon parcel prefilled with 2 lb (units preserved, not kg)',
  (SELECT weight = 2 AND weight_unit = 'lb' AND weight_source = 'profile' FROM us_booking.parcel WHERE id = test_support.pid(9202, 1)));
SELECT test_support.ok('T12 Wayfair parcel: no default assigned, nothing prefilled',
  (SELECT length IS NULL AND weight IS NULL FROM us_booking.parcel WHERE id = test_support.pid(9203, 1)));
SELECT test_support.ok('T12 a profile never confirms contents',
  (SELECT contents_status = 'unconfirmed' AND confirmed_by IS NULL FROM us_booking.parcel WHERE id = test_support.pid(9201, 1)));
SELECT test_support.ok('T12 prefilled measurements meet the measurement requirement without re-entry',
  (SELECT status FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9201) AND requirement = 'parcel_measurements') = 'met');

-- Profile edit: new version; existing parcels keep their snapshot, new parcels use the new version.
SELECT test_support.act('staff_profile_save', jsonb_build_object('staff', 'Synthetic Staff', 'name', 'Syn Shippo Default',
  'profile_id', (SELECT id FROM us_booking.package_profile WHERE name = 'Syn Shippo Default'), 'expected_version', 1,
  'length', '9', 'width', '6', 'height', '6', 'dimension_unit', 'in', 'packed_weight', '2.5', 'packed_weight_unit', 'kg'));
SELECT test_support.expect_action_error('T12 stale profile edit refused', 'staff_profile_save',
  jsonb_build_object('staff', 'Synthetic Staff', 'name', 'Syn Shippo Default',
    'profile_id', (SELECT id FROM us_booking.package_profile WHERE name = 'Syn Shippo Default'), 'expected_version', 1,
    'length', '10', 'width', '6', 'height', '6', 'dimension_unit', 'in'),
  'UB409', 'changed by someone else');
SELECT test_support.ok('T12 identical save adds no version',
  (SELECT (test_support.act('staff_profile_save', jsonb_build_object('staff', 'Synthetic Staff', 'name', 'Syn Shippo Default',
     'profile_id', id, 'expected_version', 2, 'length', '9', 'width', '6', 'height', '6', 'dimension_unit', 'in',
     'packed_weight', '2.5', 'packed_weight_unit', 'kg'))->>'unchanged')::boolean
     FROM us_booking.package_profile WHERE name = 'Syn Shippo Default')
  AND (SELECT current_version FROM us_booking.package_profile WHERE name = 'Syn Shippo Default') = 2);
SELECT test_support.ok('T12 existing parcel unchanged by the profile edit (still version 1, 2 kg)',
  (SELECT weight = 2 AND weight_unit = 'kg' AND package_profile_version = 1 FROM us_booking.parcel WHERE id = test_support.pid(9201, 1)));
SELECT test_support.act('staff_parcel_create', jsonb_build_object('staff', 'Synthetic Staff', 'group_id', test_support.gid(9201)));
SELECT test_support.ok('T12 new parcel uses the new version (2.5 kg, version 2)',
  (SELECT weight = 2.5 AND package_profile_version = 2 FROM us_booking.parcel WHERE id = test_support.pid(9201, 2)));
SELECT test_support.expect_error('T12 profile versions are append-only',
  $q$UPDATE us_booking.package_profile_version SET packed_weight = 5$q$, 'append-only');
SELECT test_support.expect_error('T12 values cannot be labelled as profile values when they differ',
  $q$UPDATE us_booking.parcel SET weight = 3 WHERE id = test_support.pid(9201, 1)$q$, 'differs from the packed weight');
SELECT test_support.expect_error('T12 measured_by is never set for profile values',
  $q$UPDATE us_booking.parcel SET measured_by = 'x', measured_at = now() WHERE id = test_support.pid(9201, 1)$q$,
  'parcel_measured_by_only_for_staff_values');

-- Manual override of the weight only; dimensions stay "default profile".
SELECT test_support.expect_action_error('T12 stale parcel edit refused', 'staff_parcel_measure',
  jsonb_build_object('staff', 'Synthetic Staff', 'parcel_id', test_support.pid(9201, 1), 'expected_row_version', test_support.rv(9201, 1) - 1,
                     'weight', jsonb_build_object('value', '2.4', 'unit', 'kg')),
  'UB409', 'changed by someone else');
SELECT test_support.expect_action_error('T12 override rejects a non-positive weight', 'staff_parcel_measure',
  jsonb_build_object('staff', 'Synthetic Staff', 'parcel_id', test_support.pid(9201, 1), 'expected_row_version', test_support.rv(9201, 1),
                     'weight', jsonb_build_object('value', '0', 'unit', 'kg')),
  'UB422', 'positive number');
SELECT test_support.act('staff_parcel_measure', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 1),
  'expected_row_version', test_support.rv(9201, 1), 'weight', jsonb_build_object('value', '2.4', 'unit', 'kg')));
SELECT test_support.ok('T12 weight override recorded as staff-entered, dimensions still from the profile',
  (SELECT weight = 2.4 AND weight_unit = 'kg' AND weight_source = 'staff' AND dimensions_source = 'profile'
          AND measured_by = 'Packer One' AND measured_at IS NOT NULL AND package_profile_version = 1
     FROM us_booking.parcel WHERE id = test_support.pid(9201, 1)));
SELECT test_support.act('staff_parcel_measure', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 1),
  'expected_row_version', test_support.rv(9201, 1), 'dimensions', jsonb_build_object('length', '25', 'width', '16', 'height', '15.5', 'unit', 'cm')));
SELECT test_support.ok('T12 dimension override kept in the unit entered (cm)',
  (SELECT length = 25 AND height = 15.5 AND dimension_unit = 'cm' AND dimensions_source = 'staff' FROM us_booking.parcel WHERE id = test_support.pid(9201, 1)));
SELECT test_support.act('staff_parcel_measure', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 1),
  'expected_row_version', test_support.rv(9201, 1), 'dimensions', 'profile', 'weight', 'profile'));
SELECT test_support.ok('T12 reset to default uses the parcel''s own version (2 kg), not the newer 2.5 kg; measured_by cleared',
  (SELECT weight = 2 AND weight_unit = 'kg' AND length = 9 AND dimension_unit = 'in' AND weight_source = 'profile'
          AND dimensions_source = 'profile' AND measured_by IS NULL AND measured_at IS NULL
     FROM us_booking.parcel WHERE id = test_support.pid(9201, 1)));
SELECT test_support.ok('T12 every measurement change is in the audit log',
  (SELECT count(*) FROM us_booking.event_log WHERE entity = 'parcel' AND entity_id = test_support.pid(9201, 1)
     AND details->>'action' = 'measurements') = 3);
SELECT test_support.act('staff_parcel_measure', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9203, 1),
  'expected_row_version', test_support.rv(9203, 1), 'dimensions', jsonb_build_object('length', '12', 'width', '10', 'height', '8', 'unit', 'in'),
  'weight', jsonb_build_object('value', '3.25', 'unit', 'lb')));
SELECT test_support.ok('T12 parcel without a default: staff enter values once',
  (SELECT weight = 3.25 AND weight_unit = 'lb' AND dimensions_source = 'staff' AND measured_by = 'Packer One'
     FROM us_booking.parcel WHERE id = test_support.pid(9203, 1)));
SELECT test_support.expect_action_error('T12 reset to default refused when the parcel had none', 'staff_parcel_measure',
  jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9203, 1), 'expected_row_version', test_support.rv(9203, 1), 'dimensions', 'profile'),
  'UB409', 'not created from a default profile');

-- ============================================================================================
-- T13 Parcel contents: allocation, single-parcel confirmation, split parcels, merged orders.
-- ============================================================================================
-- Group 9201 has two parcels (3 x SYN-A, 1 x SYN-B ordered). Remove parcel 2 first.
SELECT test_support.act('staff_parcel_remove', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 2),
  'expected_row_version', test_support.rv(9201, 2)));
SELECT test_support.ok('T13 removed draft parcel deleted and logged',
  test_support.pid(9201, 2) IS NULL
  AND EXISTS (SELECT 1 FROM us_booking.event_log WHERE entity = 'parcel' AND details->>'action' = 'deleted' AND (details->>'parcel_no')::int = 2));
-- Single-parcel workflow: accept the proposed remaining items and confirm in one step.
SELECT test_support.act('staff_parcel_set_contents', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 1),
  'expected_row_version', test_support.rv(9201, 1), 'confirm', true,
  'items', (SELECT jsonb_agg(jsonb_build_object('oms_order_item_id', oms_order_item_id, 'quantity', remaining_qty))
              FROM us_booking.v_order_item_allocation WHERE oms_order_id = 9201 AND remaining_qty > 0)));
SELECT test_support.ok('T13 single parcel: all ordered units allocated, contents confirmed by staff',
  (SELECT sum(remaining_qty) = 0 AND sum(allocated_qty) = 4 FROM us_booking.v_order_item_allocation WHERE oms_order_id = 9201)
  AND (SELECT contents_status = 'confirmed' AND confirmed_by = 'Packer One' FROM us_booking.parcel WHERE id = test_support.pid(9201, 1)));
SELECT test_support.ok('T13 parcel requirements met once measurements and contents are complete',
  (SELECT bool_and(status = 'met') FROM us_booking.shipment_requirement
    WHERE fulfilment_group_id = test_support.gid(9201) AND requirement IN ('parcel_measurements', 'parcel_contents')));
SELECT test_support.expect_action_error('T13 confirmed contents cannot be changed', 'staff_parcel_set_contents',
  jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 1), 'expected_row_version', test_support.rv(9201, 1),
                     'items', '[]'::jsonb), 'UB409', 'unconfirm them');
SELECT test_support.expect_action_error('T13 an outdated row version is refused',
  'staff_parcel_measure', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 1), 'expected_row_version', 1,
                     'weight', jsonb_build_object('value', '2', 'unit', 'kg')), 'UB409', 'changed by someone else');
SELECT test_support.act('staff_parcel_create', jsonb_build_object('staff', 'Packer One', 'group_id', test_support.gid(9201)));
SELECT test_support.expect_action_error('T13 over-allocation refused (nothing remains)', 'staff_parcel_set_contents',
  jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 2), 'expected_row_version', test_support.rv(9201, 2),
                     'items', jsonb_build_array(jsonb_build_object('oms_order_item_id', 92011, 'quantity', 1))),
  '23514', 'over-allocation');
SELECT test_support.ok('T13 contents requirement unmet while the new parcel is unconfirmed',
  (SELECT status FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9201) AND requirement = 'parcel_contents') = 'unmet');
-- Split: unconfirm parcel 1, move 1 x SYN-A to the new parcel (number 2: the deleted draft's number is reused).
SELECT test_support.act('staff_parcel_confirm_contents', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 1),
  'expected_row_version', test_support.rv(9201, 1), 'confirmed', false));
SELECT test_support.act('staff_parcel_set_contents', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 1),
  'expected_row_version', test_support.rv(9201, 1), 'confirm', true,
  'items', jsonb_build_array(jsonb_build_object('oms_order_item_id', 92011, 'quantity', 2), jsonb_build_object('oms_order_item_id', 92012, 'quantity', 1))));
SELECT test_support.act('staff_parcel_set_contents', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 2),
  'expected_row_version', test_support.rv(9201, 2), 'items', jsonb_build_array(jsonb_build_object('oms_order_item_id', 92011, 'quantity', 1))));
SELECT test_support.ok('T13 split: 2 + 1 units of the same line across two parcels, nothing remaining',
  (SELECT allocated_qty = 3 AND remaining_qty = 0 FROM us_booking.v_order_item_allocation WHERE oms_order_item_id = 92011));
SELECT test_support.ok('T13 split: contents requirement waits for the second confirmation',
  (SELECT status FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9201) AND requirement = 'parcel_contents') = 'unmet');
SELECT test_support.act('staff_parcel_confirm_contents', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9201, 2),
  'expected_row_version', test_support.rv(9201, 2), 'confirmed', true));
SELECT test_support.ok('T13 split: both parcels confirmed, requirement met',
  (SELECT status FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9201) AND requirement = 'parcel_contents') = 'met');
SELECT test_support.expect_action_error('T13 negative quantity rejected', 'staff_parcel_set_contents',
  jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9202, 1), 'expected_row_version', test_support.rv(9202, 1),
                     'items', jsonb_build_array(jsonb_build_object('oms_order_item_id', 92021, 'quantity', -1))),
  'UB422', 'whole number');
SELECT test_support.expect_action_error('T13 a line from another group is refused', 'staff_parcel_set_contents',
  jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9202, 1), 'expected_row_version', test_support.rv(9202, 1),
                     'items', jsonb_build_array(jsonb_build_object('oms_order_item_id', 92011, 'quantity', 1))),
  '23503|23514', 'not an active member|foreign key');
-- Merged group 9204 + 9205: one parcel holding lines of both orders.
SELECT test_support.act('staff_parcel_create', jsonb_build_object('staff', 'Packer One', 'group_id', test_support.gid(9204)));
SELECT test_support.act('staff_parcel_set_contents', jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9204, 1),
  'expected_row_version', test_support.rv(9204, 1), 'confirm', true,
  'items', jsonb_build_array(jsonb_build_object('oms_order_item_id', 92041, 'quantity', 2), jsonb_build_object('oms_order_item_id', 92051, 'quantity', 4))));
SELECT test_support.ok('T13 merged orders: one parcel holds both orders'' lines (child line keeps its originating order)',
  (SELECT array_agg(oms_order_id || ':' || quantity ORDER BY oms_order_id) FROM us_booking.parcel_item WHERE parcel_id = test_support.pid(9204, 1))
  = '{9204:2,9205:4}');

-- Locks: no edits once the group has left review, or while a purchase is pending on the parcel.
UPDATE us_booking.fulfilment_group SET state = 'ready' WHERE id = test_support.gid(9202);
SELECT test_support.expect_action_error('T13 parcels frozen once the group is no longer in review', 'staff_parcel_measure',
  jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9202, 1), 'expected_row_version', test_support.rv(9202, 1),
                     'weight', jsonb_build_object('value', '3', 'unit', 'lb')), 'UB409', 'only while it is in review');
SELECT test_support.expect_action_error('T13 no new parcels once the group is no longer in review', 'staff_parcel_create',
  jsonb_build_object('staff', 'Packer One', 'group_id', test_support.gid(9202)), 'UB409', 'only while it is in review');
UPDATE us_booking.fulfilment_group SET state = 'review' WHERE id = test_support.gid(9202);
RESET ROLE;
BEGIN;
-- A pending purchase on parcel 9204/1 (inserted with the booking precondition trigger disabled,
-- inside a transaction that is rolled back, which also re-enables the trigger): the existing lock
-- must still apply to staff actions.
ALTER TABLE us_booking.booking_attempt DISABLE TRIGGER booking_attempt_insert;
INSERT INTO us_booking.booking_attempt (parcel_id, fulfilment_group_id, provider, provider_account, attempt_generation, correlation_key, request_hash, requested_by)
SELECT p.id, p.fulfilment_group_id, g.provider, g.provider_account, 1, 'usb:test:lock', 'rh', 'tester@example.test'
  FROM us_booking.parcel p JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id WHERE p.id = test_support.pid(9204, 1);
SELECT test_support.expect_action_error('T13 parcel with a pending purchase refuses measurement changes', 'staff_parcel_measure',
  jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9204, 1), 'expected_row_version', test_support.rv(9204, 1),
                     'weight', jsonb_build_object('value', '3', 'unit', 'kg')), 'UB409', 'locked');
SELECT test_support.expect_action_error('T13 parcel with a pending purchase cannot be removed', 'staff_parcel_remove',
  jsonb_build_object('staff', 'Packer One', 'parcel_id', test_support.pid(9204, 1), 'expected_row_version', test_support.rv(9204, 1)),
  'UB409', 'locked');
SELECT test_support.expect_error('T13 the lock also binds direct updates',
  $q$UPDATE us_booking.parcel SET weight = 9, weight_unit = 'kg', weight_source = 'staff', measured_by = 'x', measured_at = now() WHERE id = test_support.pid(9204, 1)$q$,
  'frozen');
ROLLBACK;
SELECT test_support.ok('T13 booking guard trigger enabled again after the rollback',
  (SELECT tgenabled FROM pg_trigger WHERE tgname = 'booking_attempt_insert') = 'O');
SET ROLE us_booking_owner;

-- ============================================================================================
-- T14 Review findings: resolution with identity and evidence touches nothing else.
-- ============================================================================================
SELECT test_support.ok('T14 setup: order 9203 has two open findings',
  (SELECT array_agg(case_type ORDER BY case_type) FROM us_booking.review_case WHERE oms_order_id = 9203 AND status = 'open')
  = '{already_shipped_suspect,booking_flag_conflict}');
CREATE TEMP TABLE req_before AS
  SELECT id, status, detail, checked_by FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9203);
SELECT test_support.expect_action_error('T14 resolution needs evidence', 'staff_case_close',
  jsonb_build_object('staff', 'Supervisor', 'outcome', 'resolved', 'evidence', '',
    'case_id', (SELECT id FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'booking_flag_conflict'),
    'expected_details_hash', (SELECT md5(details::text) FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'booking_flag_conflict')),
  'UB422', 'Evidence must be');
SELECT test_support.expect_action_error('T14 resolution refused when the finding changed since loading', 'staff_case_close',
  jsonb_build_object('staff', 'Supervisor', 'outcome', 'resolved', 'evidence', 'synthetic: checked',
    'case_id', (SELECT id FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'booking_flag_conflict'),
    'expected_details_hash', md5('something else')),
  'UB409', 'changed since it was loaded');
SELECT test_support.act('staff_case_close', jsonb_build_object('staff', 'Supervisor', 'outcome', 'dismissed',
  'evidence', 'synthetic: flag set in error, confirmed with the OMS team',
  'case_id', (SELECT id FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'booking_flag_conflict'),
  'expected_details_hash', (SELECT md5(details::text) FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'booking_flag_conflict')));
SELECT test_support.ok('T14 finding closed with staff identity and evidence',
  (SELECT status = 'dismissed' AND resolved_by = 'Supervisor' AND resolution LIKE 'synthetic: flag set in error%'
     FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'booking_flag_conflict'));
SELECT test_support.ok('T14 other finding of the same order still open',
  (SELECT status FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'already_shipped_suspect') = 'open');
SELECT test_support.ok('T14 no requirement changed by the resolution',
  NOT EXISTS (SELECT id, status, detail, checked_by FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9203)
              EXCEPT SELECT * FROM req_before)
  AND (SELECT count(*) FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9203)) = (SELECT count(*) FROM req_before));
SELECT test_support.expect_action_error('T14 closing twice is refused', 'staff_case_close',
  jsonb_build_object('staff', 'Supervisor', 'outcome', 'resolved', 'evidence', 'again',
    'case_id', (SELECT id FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'booking_flag_conflict'),
    'expected_details_hash', (SELECT md5(details::text) FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'booking_flag_conflict')),
  'UB409', 'already dismissed');
SELECT test_support.ok('T14 an unchanged finding stays closed on the next sync; staff parcels survive the sync',
  (SELECT us_booking.oms_sync_apply(doc || '{"extracted_at": "2026-10-23T11:00:00Z"}', 'system:test-sync') IS NOT NULL FROM snap)
  AND (SELECT count(*) FROM us_booking.review_case WHERE oms_order_id = 9203 AND case_type = 'booking_flag_conflict') = 1
  AND (SELECT weight = 2 AND weight_unit = 'kg' FROM us_booking.parcel WHERE id = test_support.pid(9201, 1))
  AND (SELECT status FROM us_booking.shipment_requirement WHERE fulfilment_group_id = test_support.gid(9201) AND requirement = 'parcel_contents') = 'met');

-- ============================================================================================
-- T15 Failed sync runs are kept.
-- ============================================================================================
SELECT us_booking.sync_record_failure('{"started_at": "2026-10-23T09:00:00Z", "error": "STOP: synthetic failure", "stage": "reading_oms", "actor": "system:oms-sync"}');
SELECT test_support.ok('T15 failed run recorded with its error',
  (SELECT status = 'failed' AND error = 'STOP: synthetic failure' AND finished_at IS NOT NULL
     FROM us_booking.sync_run ORDER BY id DESC LIMIT 1)
  AND (SELECT last_error FROM us_booking.sync_state WHERE stream = 'oms_orders') = 'STOP: synthetic failure');
SELECT test_support.expect_error('T15 only a system actor can record a sync failure',
  $q$SELECT us_booking.sync_record_failure('{"error": "x", "actor": "someone"}')$q$, 'system:');
RESET ROLE;
