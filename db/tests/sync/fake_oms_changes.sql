-- OMS changes between syncs (run against the fake ledsone by run_sync_tests.sh).
\set ON_ERROR_STOP 1

-- 5001 is merged into a new Amazon parent 5013; its line moves to the container (order_ref_id kept).
INSERT INTO order_management.orders VALUES (5013, 'SYN-AMZ-5013', 'Inprogress', '2026-10-07 10:00:00', 'merged', 239, 'US', 32);
UPDATE order_management.orders SET "merge" = '5013' WHERE id = 5001;
UPDATE order_management.order_item_info SET order_id = 5013 WHERE id = 50011;
INSERT INTO order_management.order_item_info VALUES (50131, 5013, 5013, 'L1', 'SYN-LAMP-M', 'SYN-LAMP-M', '2', '2', 0);
INSERT INTO order_management.order_info (order_id, shipped) VALUES (5013, 0);
INSERT INTO order_management.order_flag (order_id, flag_id) VALUES (5013, 15);
INSERT INTO customers.shipping_address (order_id, address_name, address_line_1, region, city, postcode, country_id, phone)
VALUES (5013, 'Synthetic A', '1 Test St', 'TX', 'Testville', '73301', 8, '5550001');

-- 5002 changes its ship-to (invalidates the staff destination confirmation), its quantity, and is
-- merged into 5014 although its group already has a staff parcel (the move must be refused).
UPDATE customers.shipping_address SET address_line_1 = '2B Test St' WHERE order_id = 5002;
UPDATE order_management.order_item_info SET item_quantity = '2', order_id = 5014 WHERE id = 50021;
INSERT INTO order_management.orders VALUES (5014, 'SYN-EBY-5014', 'Inprogress', '2026-10-08 10:00:00', 'merged', 22, 'US', 32);
UPDATE order_management.orders SET "merge" = '5014' WHERE id = 5002;
INSERT INTO order_management.order_item_info VALUES (50141, 5014, 5014, 'L1', 'SYN-CORD-N', 'SYN-CORD-N', '1', '1', 0);
INSERT INTO customers.shipping_address (order_id, address_name, address_line_1, region, city, postcode, country_id, phone)
VALUES (5014, 'Synthetic B', '2B Test St', 'NY', 'Testburg', '10001', 8, '5550014');

-- 5003 group: one child line disappears from the OMS.
DELETE FROM order_management.order_item_info WHERE id = 50051;

-- 5006 is cancelled and moved to another warehouse: still refreshed, and flagged.
UPDATE order_management.orders SET status = 'Cancelled', warehouse_id = 7 WHERE id = 5006;

-- 5011 becomes a merge parent with a new child 5012.
UPDATE order_management.orders SET "merge" = 'merged' WHERE id = 5011;
INSERT INTO order_management.orders VALUES (5012, 'SYN-SHO-5012', 'Inprogress', '2026-10-06 11:00:00', '5011', 245, 'US', 32);
INSERT INTO order_management.order_item_info VALUES (50121, 5011, 5012, 'L1', 'SYN-LAMP-I', 'SYN-LAMP-I', '1', '1', 0);
INSERT INTO customers.shipping_address (order_id, address_name, address_line_1, region, city, postcode, country_id, phone)
VALUES (5012, 'Synthetic H', '11 Test St', 'WA', 'Testshire', '98001', 9008, '5550011');

-- 5007: new tracking evidence (the dismissed shipping finding changes), and real_sku now filled
-- (the resolved blank-SKU finding clears).
INSERT INTO order_management.shipment (order_id, tracking_number, status) VALUES (5007, 'SYNTRK5007B', 'Completed');
UPDATE order_management.order_item_info SET real_sku = 'SYN-CORD-G' WHERE id = 50071;
