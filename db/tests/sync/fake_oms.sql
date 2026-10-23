-- Synthetic stand-in for the ledsone OMS, for db/tests/run_sync_tests.sh only. Same schema, table
-- and column names as the real source for the columns the extraction reads; synthetic rows only.
\set ON_ERROR_STOP 1

CREATE SCHEMA order_management;
CREATE SCHEMA customers;
CREATE SCHEMA customer_service;

CREATE TABLE order_management.source (id integer PRIMARY KEY, source_name varchar);
CREATE TABLE order_management.sub_source (id integer PRIMARY KEY, source_id integer, name varchar);
CREATE TABLE order_management.orders (
  id bigint PRIMARY KEY, order_id varchar, status varchar, order_date timestamp, "merge" varchar,
  sub_source_id integer, market_place varchar, warehouse_id integer);
CREATE TABLE order_management.order_info (
  id bigserial PRIMARY KEY, order_id bigint, ebay_cancel_status text, shipping_method varchar, shipped integer, shipped_error text);
CREATE TABLE order_management.flag (id integer PRIMARY KEY, name varchar, flag_group integer);
CREATE TABLE order_management.order_flag (id bigserial PRIMARY KEY, order_id bigint, flag_id integer);
CREATE TABLE order_management.order_item_info (
  id bigint PRIMARY KEY, order_id bigint, order_ref_id bigint, line_item_id varchar, item_sku varchar,
  real_sku varchar, item_quantity varchar, real_qty varchar, combo_count integer);
CREATE TABLE order_management.order_combo (id bigint PRIMARY KEY, order_item_info_id bigint, sku varchar, qty integer);
CREATE TABLE order_management.shipment (id bigserial PRIMARY KEY, order_id bigint, tracking_number varchar, status varchar);
CREATE TABLE customers.shipping_address (
  id bigserial PRIMARY KEY, order_id bigint, address_name varchar, company varchar, address_line_1 varchar,
  address_line_2 varchar, address_line_3 varchar, region varchar, city varchar, postcode varchar,
  country_id integer, phone varchar);
CREATE TABLE customers.customer_info (id bigserial PRIMARY KEY, order_id bigint, email varchar);
CREATE TABLE customer_service.ebay_order_cancellations (
  id bigserial PRIMARY KEY, order_id varchar, status varchar, current_state varchar);

INSERT INTO order_management.source VALUES (1, 'AMAZON'), (2, 'EBAY'), (3, 'SHOPIFY'), (6, 'WAYFAIR'), (9, 'RESEND');
INSERT INTO order_management.sub_source VALUES
  (239, 1, 'Syn Amazon'), (22, 2, 'Syn eBay'), (245, 3, 'Syn Shopify'), (258, 6, 'Syn Wayfair'), (900, 9, 'Syn Resend');
INSERT INTO order_management.flag VALUES (15, 'Book from US', 3), (8, 'Book from UK', 3), (2, 'Other group flag', 2);

-- 5001 Amazon, quantity 3 (preservation), New shipment row without tracking (Amazon norm).
-- 5002 eBay, no country_id, blank state, no phone, combo line with a missing component row,
--      cancellation requested.
-- 5003 Shopify merge parent with children 5004 and 5005; a pack line with consistent components.
-- 5006 Wayfair, status New, country_id 359 (verified Canada, migration 0006), flagged "Book from UK".
-- Country ids: 8 and 359 are the verified mappings from 0006; 9008 is a synthetic id with no mapping.
-- 5007 eBay, status Hold, Completed shipment with tracking, blank real_sku.
-- 5011 Shopify single order (merged later, in the changes stage); combo_count 1 with 2 component rows.
-- Excluded: 5008 Completed, 5009 warehouse 7, 5010 RESEND source.
INSERT INTO order_management.orders VALUES
  (5001, 'SYN-AMZ-5001', 'Inprogress', '2026-10-01 10:00:00', NULL,      239, 'US', 32),
  (5002, 'SYN-EBY-5002', 'Inprogress', '2026-10-02 10:00:00', NULL,      22,  'US', 32),
  (5003, 'SYN-SHO-5003', 'Inprogress', '2026-10-03 10:00:00', 'merged',  245, 'US', 32),
  (5004, 'SYN-SHO-5004', 'Inprogress', '2026-10-03 09:00:00', '5003',    245, 'US', 32),
  (5005, 'SYN-SHO-5005', 'Inprogress', '2026-10-03 09:30:00', '5003',    245, 'US', 32),
  (5006, 'SYN-WAY-5006', 'New',        '2026-10-04 10:00:00', NULL,      258, 'US', 32),
  (5007, 'SYN-EBY-5007', 'Hold',       '2026-10-05 10:00:00', 'multi_line', 22, 'US', 32),
  (5008, 'SYN-AMZ-5008', 'Completed',  '2026-09-01 10:00:00', NULL,      239, 'US', 32),
  (5009, 'SYN-AMZ-5009', 'Inprogress', '2026-09-02 10:00:00', NULL,      239, 'US', 7),
  (5010, 'SYN-RES-5010', 'Inprogress', '2026-09-03 10:00:00', NULL,      900, 'US', 32),
  (5011, 'SYN-SHO-5011', 'Inprogress', '2026-10-06 10:00:00', NULL,      245, 'US', 32);

INSERT INTO order_management.order_info (order_id, ebay_cancel_status, shipping_method, shipped, shipped_error) VALUES
  (5001, NULL, 'Standard', 0, 'Shipment not created.'), (5002, 'CancelRequested', 'Standard', 0, NULL),
  (5003, NULL, 'Standard', 0, NULL), (5004, NULL, 'Standard', 0, NULL), (5005, NULL, 'Standard', 0, NULL),
  (5006, NULL, 'Standard', 0, 'Can not shipped this order (WAYFAIR).'), (5007, 'NotApplicable', 'Standard', 0, NULL),
  (5011, NULL, 'Standard', 0, NULL);

INSERT INTO order_management.order_flag (order_id, flag_id) VALUES
  (5001, 15), (5002, 15), (5003, 15), (5004, 15), (5005, 15), (5006, 8), (5007, 15), (5007, 2), (5011, 15);

INSERT INTO order_management.order_item_info VALUES
  (50011, 5001, 5001, 'L1', 'SYN-LAMP-A',  'SYN-LAMP-A',  '3', '3', 0),
  (50021, 5002, 5002, 'L1', 'SYN-PACK-B2', 'SYN-PACK-B2', '1', '1', 2),
  (50031, 5003, 5003, 'L1', 'SYN-PACK-C2', 'SYN-PACK-C2', '2', '2', 2),
  (50041, 5003, 5004, 'L1', 'SYN-BULB-D',  'SYN-BULB-D',  '1', '1', 0),
  (50051, 5003, 5005, 'L1', 'SYN-BULB-E',  'SYN-BULB-E',  '4', '4', 0),
  (50061, 5006, 5006, 'L1', 'SYN-SHADE-F', 'SYN-SHADE-F', '1', '1', 0),
  (50071, 5007, 5007, 'L1', 'SYN-CORD-G',  '',            '2', '2', 0),
  (50081, 5008, 5008, 'L1', 'SYN-X',       'SYN-X',       '1', '1', 0),
  (50091, 5009, 5009, 'L1', 'SYN-Y',       'SYN-Y',       '1', '1', 0),
  (50101, 5010, 5010, 'L1', 'SYN-Z',       'SYN-Z',       '1', '1', 0),
  (50111, 5011, 5011, 'L1', 'SYN-LAMP-H',  'SYN-LAMP-H',  '5', '5', 1);

INSERT INTO order_management.order_combo VALUES
  (70021, 50021, 'SYN-BULB-B', 1),
  (70031, 50031, 'SYN-BULB-C', 1), (70032, 50031, 'SYN-BULB-C', 1),
  -- combo_count 1 with several component rows is normal in the OMS: no case expected.
  (70111, 50111, 'SYN-LAMP-H-BASE', 1), (70112, 50111, 'SYN-LAMP-H-SHADE', 1);

INSERT INTO order_management.shipment (order_id, tracking_number, status) VALUES
  (5001, NULL, 'New'), (5007, 'SYNTRK5007', 'Completed');

INSERT INTO customers.shipping_address
  (order_id, address_name, company, address_line_1, address_line_2, address_line_3, region, city, postcode, country_id, phone) VALUES
  (5001, 'Synthetic A', NULL, '1 Test St', NULL, NULL, 'TX', 'Testville',  '73301', 8,    '5550001'),
  (5002, 'Synthetic B', NULL, '2 Test St', NULL, NULL, '',   'Testburg',   '10001', NULL, NULL),
  (5003, 'Synthetic C', NULL, '3 Test St', NULL, NULL, 'NY', 'Testford',   '10002', 9008, '5550003'),
  (5004, 'Synthetic C', NULL, '3 Test St', NULL, NULL, 'NY', 'Testford',   '10002', 9008, '5550003'),
  (5005, 'Synthetic C', NULL, '3 Test St', NULL, NULL, 'NY', 'Testford',   '10002', 9008, '5550003'),
  (5006, 'Synthetic F', NULL, '6 Test St', NULL, NULL, 'ON', 'Testtown',   'K1A0B1', 359, '5550006'),
  (5007, 'Synthetic G', NULL, '7 Test St', NULL, NULL, 'CA', 'Testcity',   '90001', 9008, '5550007'),
  (5011, 'Synthetic H', NULL, '11 Test St', NULL, NULL, 'WA', 'Testshire', '98001', 9008, '5550011');

INSERT INTO customers.customer_info (order_id, email) VALUES
  (5001, 'a@example.test'), (5002, 'b@example.test'), (5003, 'c@example.test'), (5006, 'f@example.test'),
  (5007, 'g@example.test'), (5011, 'h@example.test');

INSERT INTO customer_service.ebay_order_cancellations (order_id, status, current_state) VALUES
  ('SYN-EBY-5002', NULL, NULL);

-- SELECT-only role for the sync, like the production OMS_READ_DATABASE_URL role.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'oms_reader') THEN CREATE ROLE oms_reader LOGIN; END IF;
END $$;
GRANT USAGE ON SCHEMA order_management, customers, customer_service TO oms_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA order_management, customers, customer_service TO oms_reader;
