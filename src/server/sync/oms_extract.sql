-- Read-only OMS snapshot for the us_booking sync. Run by scripts/oms-sync.mjs against ledsone
-- through OMS_READ_DATABASE_URL, inside a READ ONLY transaction. SELECT only.
--
-- psql variables:
--   lim      maximum number of NEW fulfilment groups (containers) to fetch (0..20; 0 = refresh only)
--   refresh  bigint array literal of previously imported order ids, e.g. '{}' or '{1,2}'. Their
--            groups are always fetched again, whatever their current status or warehouse.
--
-- A fulfilment group is an OMS container order: the merge parent (orders.merge = 'merged') with
-- every child (orders.merge = '<parent id>'), or a single order. The container holds all lines
-- (order_item_info.order_id); order_ref_id keeps each line's originating order.
-- New groups: US1 (warehouse 32), open status (New, Inprogress, Hold), source Amazon (1), eBay (2),
-- Shopify (3) or Wayfair (6); oldest order date first.
-- Output: one JSON document (format us_booking.oms_snapshot.v1). It contains PII; never print it.
WITH params AS (
  SELECT (:lim)::int AS lim, (:'refresh')::bigint[] AS refresh_ids
),
open_orders AS (
  SELECT o.id,
         CASE WHEN o."merge" ~ '^[0-9]+$' THEN o."merge"::bigint ELSE o.id END AS container_id,
         o.order_date
    FROM order_management.orders o
    JOIN order_management.sub_source ss ON ss.id = o.sub_source_id
   WHERE o.warehouse_id = 32
     AND o.status IN ('New', 'Inprogress', 'Hold')
     AND ss.source_id IN (1, 2, 3, 6)
),
refresh_containers AS (
  SELECT DISTINCT CASE WHEN o."merge" ~ '^[0-9]+$' THEN o."merge"::bigint ELSE o.id END AS container_id
    FROM order_management.orders o, params p
   WHERE o.id = ANY (p.refresh_ids)
),
new_containers AS (
  SELECT container_id
    FROM open_orders
   WHERE container_id NOT IN (SELECT container_id FROM refresh_containers)
   GROUP BY container_id
   ORDER BY min(order_date), container_id
   LIMIT (SELECT lim FROM params)
),
picked AS (
  SELECT container_id, 'new'::text AS reason FROM new_containers
  UNION ALL
  SELECT container_id, 'refresh' FROM refresh_containers
),
grp AS (
  SELECT p.container_id, p.reason, o.id AS order_id
    FROM picked p JOIN order_management.orders o ON o.id = p.container_id
  UNION
  SELECT p.container_id, p.reason, o.id
    FROM picked p JOIN order_management.orders o ON o."merge" = p.container_id::text
),
ord AS (
  SELECT g.container_id,
         jsonb_build_object(
           'id', o.id,
           'platform_order_ref', o.order_id,
           'status', o.status,
           'order_date', o.order_date::text,
           'merge', o."merge",
           'sub_source_id', o.sub_source_id,
           'source_id', ss.source_id,
           'channel', src.source_name,
           'account_name', ss.name,
           'market_place', o.market_place,
           'warehouse_id', o.warehouse_id,
           'flags', COALESCE((SELECT jsonb_agg(f.name ORDER BY f.name)
                                FROM order_management.order_flag ofl
                                JOIN order_management.flag f ON f.id = ofl.flag_id AND f.flag_group = 3
                               WHERE ofl.order_id = o.id), '[]'::jsonb),
           'ebay_cancel_status', oi.ebay_cancel_status,
           'shipped', oi.shipped,
           'shipped_error', oi.shipped_error,
           'shipping_method', oi.shipping_method,
           'ship', jsonb_build_object(
             'name', sa.address_name, 'company', sa.company,
             'line1', sa.address_line_1, 'line2', sa.address_line_2, 'line3', sa.address_line_3,
             'city', sa.city, 'region', sa.region, 'postcode', sa.postcode,
             'phone', sa.phone, 'country_id', sa.country_id),
           'email', ci.email,
           'shipments', (SELECT jsonb_build_object(
                                  'total', count(*),
                                  'tracked_not_cancelled', count(*) FILTER (WHERE COALESCE(btrim(s.tracking_number), '') <> ''
                                                                           AND s.status IS DISTINCT FROM 'Cancelled'),
                                  'statuses', COALESCE(jsonb_agg(DISTINCT s.status) FILTER (WHERE s.status IS NOT NULL), '[]'::jsonb))
                           FROM order_management.shipment s WHERE s.order_id = o.id),
           'ebay_cancel_requests', CASE WHEN ss.source_id = 2 THEN
               COALESCE((SELECT jsonb_agg(jsonb_build_object('status', c.status, 'current_state', c.current_state) ORDER BY c.id)
                           FROM customer_service.ebay_order_cancellations c
                          WHERE c.order_id = o.order_id), '[]'::jsonb)
             ELSE '[]'::jsonb END
         ) AS doc
    FROM grp g
    JOIN order_management.orders o ON o.id = g.order_id
    LEFT JOIN order_management.sub_source ss ON ss.id = o.sub_source_id
    LEFT JOIN order_management.source src ON src.id = ss.source_id
    LEFT JOIN LATERAL (SELECT * FROM order_management.order_info x WHERE x.order_id = o.id ORDER BY x.id DESC LIMIT 1) oi ON true
    LEFT JOIN LATERAL (SELECT * FROM customers.shipping_address x WHERE x.order_id = o.id ORDER BY x.id DESC LIMIT 1) sa ON true
    LEFT JOIN LATERAL (SELECT * FROM customers.customer_info x WHERE x.order_id = o.id ORDER BY x.id DESC LIMIT 1) ci ON true
),
items AS (
  SELECT g.container_id, i.*
    FROM (SELECT DISTINCT container_id, order_id FROM grp) g
    JOIN order_management.order_item_info i ON i.order_id = g.order_id
),
combos AS (
  SELECT it.container_id, c.*
    FROM items it JOIN order_management.order_combo c ON c.order_item_info_id = it.id
),
groups_json AS (
  SELECT p.container_id,
         jsonb_build_object(
           'container_id', p.container_id,
           'reason', p.reason,
           'orders', COALESCE((SELECT jsonb_agg(d.doc ORDER BY (d.doc->>'id')::bigint) FROM ord d WHERE d.container_id = p.container_id), '[]'::jsonb),
           'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                 'id', i.id, 'order_id', i.order_id, 'order_ref_id', i.order_ref_id,
                                 'line_item_id', i.line_item_id, 'item_sku', i.item_sku, 'real_sku', i.real_sku,
                                 'item_quantity', i.item_quantity, 'real_qty', i.real_qty, 'combo_count', i.combo_count)
                               ORDER BY i.id)
                                FROM items i WHERE i.container_id = p.container_id), '[]'::jsonb),
           'combos', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                  'id', c.id, 'order_item_info_id', c.order_item_info_id, 'sku', c.sku, 'qty', c.qty)
                                ORDER BY c.id)
                                 FROM combos c WHERE c.container_id = p.container_id), '[]'::jsonb)
         ) AS doc
    FROM picked p
   WHERE EXISTS (SELECT 1 FROM grp WHERE grp.container_id = p.container_id)
)
SELECT jsonb_build_object(
         'format', 'us_booking.oms_snapshot.v1',
         'oms_database', current_database(),
         'extracted_at', clock_timestamp()::text,
         'limit', (SELECT lim FROM params),
         'open_statuses', jsonb_build_array('New', 'Inprogress', 'Hold'),
         'refresh_ids', to_jsonb((SELECT refresh_ids FROM params)),
         'groups', COALESCE((SELECT jsonb_agg(doc ORDER BY doc->>'reason', container_id) FROM groups_json), '[]'::jsonb)
       )::text;
