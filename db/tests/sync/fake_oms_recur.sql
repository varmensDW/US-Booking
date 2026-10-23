-- The blank real_sku on 50071 comes back (the same problem recurs after it had cleared).
\set ON_ERROR_STOP 1
UPDATE order_management.order_item_info SET real_sku = '' WHERE id = 50071;
