-- Synthetic fixtures for the us_booking schema tests. No real orders, customers or addresses.
-- Reference data is written as the owner role; the OMS snapshot and queue as the runtime role.
\set ON_ERROR_STOP 1

SET ROLE us_booking_owner;
-- Synthetic routing for the test only: Shippo is marked verified so the booking path can run.
INSERT INTO us_booking.routing_rule (oms_source_id, channel, provider, integration_status, notes) VALUES
  (1, 'AMAZON',  'amazon_seller_central', 'manual_only', 'test fixture'),
  (2, 'EBAY',    'shippo',                'verified',    'test fixture'),
  (3, 'SHOPIFY', 'shippo',                'verified',    'test fixture'),
  (6, 'WAYFAIR', 'wayfair_partner',       'manual_only', 'test fixture');

SET ROLE us_booking_app;
INSERT INTO us_booking.oms_order
  (oms_order_id, platform_order_ref, oms_source_id, channel, sub_source_id, account_name, warehouse_id,
   booking_country_flags, oms_status, order_date_raw,
   ship_name, ship_line1, ship_city, ship_region, ship_postcode, oms_country_id, ship_address_hash, source_hash)
VALUES
  (9001, 'SYN-EBAY-0001', 2, 'EBAY',    22,  'syn-ebay',    32, '{Book from US}', 'Inprogress', '2026-10-21 23:30:00',
   'Test Recipient A', '1 Example St', 'Testville', 'CA', '90001', 8,  'addr-9001', 'src-9001'),
  (9002, 'SYN-SHOP-0002', 3, 'SHOPIFY', 245, 'syn-shopify', 32, '{Book from US}', 'Inprogress', '2026-10-21 23:45:00',
   'Test Recipient B', '2 Example Ave', 'Testburg', 'ON', 'K1A 0B1', 12, 'addr-9002', 'src-9002'),
  (9003, 'SYN-EBAY-0003', 2, 'EBAY',    22,  'syn-ebay',    32, '{Book from US}', 'Inprogress', '2026-10-22 00:10:00',
   'Test Recipient C', '3 Example Rd', 'Testford', 'NY', '10001', 8,  'addr-9003', 'src-9003'),
  (9004, 'SYN-SHOP-0004', 3, 'SHOPIFY', 245, 'syn-shopify', 32, '{Book from US}', 'Inprogress', '2026-10-22 00:20:00',
   'Test Recipient D', '4 Example Ln', 'Testham', NULL, 'TE1 1ST', 197, 'addr-9004', 'src-9004'),
  (9005, 'SYN-AMZ-0005',  1, 'AMAZON',  239, 'syn-amazon',  32, '{Book from US}', 'Inprogress', '2026-10-22 00:30:00',
   'Test Recipient E', '5 Example Ct', 'Testdale', 'TX', '73301', 8,  'addr-9005', 'src-9005');

INSERT INTO us_booking.oms_order_item
  (oms_order_item_id, oms_order_id, container_order_id, line_item_id, item_sku, real_sku,
   quantity_ordered, real_qty, quantity_raw, combo_count, source_hash)
VALUES
  (90011, 9001, 9001, 'L1', 'SYN-LAMP-A', 'SYN-LAMP-A', 3, 3, '3', 1, 'h'),
  (90012, 9001, 9001, 'L2', 'SYN-PACK-2', 'SYN-PACK-2', 1, 1, '1', 2, 'h'),   -- pack SKU kept as ordered
  (90021, 9002, 9002, 'L1', 'SYN-SHADE-B', 'SYN-SHADE-B', 1, 1, '1', 1, 'h'),
  (90031, 9003, 9003, 'L1', 'SYN-CABLE-C', 'SYN-CABLE-C', 2, 2, '2', 1, 'h'),
  (90032, 9003, 9003, 'L2', 'SYN-PLUG-C', 'SYN-PLUG-C', 1, 1, '1', 1, 'h'),
  (90041, 9004, 9004, 'L1', 'SYN-BULB-D', 'SYN-BULB-D', 1, 1, '1', 1, 'h'),
  (90051, 9005, 9005, 'L1', 'SYN-LAMP-E', 'SYN-LAMP-E', 1, 1, '1', 1, 'h');

INSERT INTO us_booking.oms_order_item_component (oms_combo_id, oms_order_item_id, component_sku, component_qty) VALUES
  (1, 90012, 'SYN-PART-X', 1), (2, 90012, 'SYN-PART-Y', 1);

-- Per-order destination confirmations (country_map stays empty).
INSERT INTO us_booking.order_destination_confirmation
  (oms_order_id, destination_iso2, evidence_type, evidence_ref, oms_country_id_seen, ship_address_hash, confirmed_by)
VALUES
  (9001, 'US', 'marketplace_order_record', 'synthetic: eBay order page shows US', 8,   'addr-9001', 'tester@example.test'),
  (9002, 'CA', 'marketplace_order_record', 'synthetic: Shopify order shows CA',   12,  'addr-9002', 'tester@example.test'),
  (9003, 'US', 'marketplace_order_record', 'synthetic: eBay order page shows US', 8,   'addr-9003', 'tester@example.test'),
  (9004, 'GB', 'marketplace_order_record', 'synthetic: Shopify order shows GB',   197, 'addr-9004', 'tester@example.test'),
  (9005, 'US', 'marketplace_order_record', 'synthetic: Amazon order shows US',    8,   'addr-9005', 'tester@example.test');

INSERT INTO us_booking.fulfilment_group (group_key, provider, provider_account, warehouse_id, state) VALUES
  ('oms:9001:g1', 'shippo',                'shippo-test-acct', 32, 'ready'),
  ('oms:9002:g1', 'shippo',                'shippo-test-acct', 32, 'ready'),
  ('oms:9003:g1', 'shippo',                'shippo-test-acct', 32, 'ready'),
  ('oms:9004:g1', 'shippo',                'shippo-test-acct', 32, 'ready'),
  ('oms:9005:g1', 'amazon_seller_central', 'amz-test-acct',    32, 'ready');

INSERT INTO us_booking.fulfilment_group_order (fulfilment_group_id, oms_order_id, role)
SELECT g.id, split_part(g.group_key, ':', 2)::bigint, 'single' FROM us_booking.fulfilment_group g;

-- Parcels used by the concurrency test (group 9003): two open parcels, no items yet.
INSERT INTO us_booking.parcel (fulfilment_group_id, parcel_no)
SELECT g.id, n FROM us_booking.fulfilment_group g, generate_series(1, 2) n WHERE g.group_key = 'oms:9003:g1';

RESET ROLE;
