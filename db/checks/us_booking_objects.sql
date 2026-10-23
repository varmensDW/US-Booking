-- Read-only verification of the applied us_booking schema in varmen_db:
--   npm run db:preflight -- --check=us_booking_objects
-- Every statement is a SELECT; nothing is created, granted or changed.

-- 1. Migration ledger. Expect one row per file in db/migrations.
SELECT version, filename, left(sha256, 12) AS sha256, applied_at, applied_by
FROM us_booking.schema_migration ORDER BY version;

-- 2. Object counts by kind. Expect 25 tables (24 + schema_migration), 2 views, 0 objects owned by
--    anyone but the schema owner.
SELECT CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view'
                      WHEN 'i' THEN 'index' WHEN 'S' THEN 'sequence' ELSE c.relkind::text END AS kind,
       count(*) AS objects,
       count(*) FILTER (WHERE c.relowner <> n.nspowner) AS not_owned_by_schema_owner
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'us_booking'
GROUP BY 1 ORDER BY 1;

-- 3. Tables with their row counts, constraint counts and triggers. Expect 0 rows everywhere except
--    schema_migration (no orders imported, nothing booked or printed).
SELECT c.relname AS table_name,
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM us_booking.%I', c.relname), false, true, '')))[1]::text::bigint AS row_count,
       (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'c') AS checks,
       (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f') AS foreign_keys,
       (SELECT count(*) FROM pg_index i WHERE i.indrelid = c.oid AND i.indisunique) AS unique_indexes,
       (SELECT string_agg(t.tgname || CASE t.tgenabled WHEN 'D' THEN ' (DISABLED)' ELSE '' END, ', ' ORDER BY t.tgname)
          FROM pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal) AS triggers
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'us_booking' AND c.relkind IN ('r', 'p')
ORDER BY 1;

-- 4. Key protections present. Expect every row present = t (and enabled = t for triggers).
SELECT x.kind, x.name,
       CASE x.kind
         WHEN 'index'   THEN to_regclass('us_booking.' || x.name) IS NOT NULL
         WHEN 'trigger' THEN EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                                      JOIN pg_namespace n ON n.oid = c.relnamespace
                                     WHERE n.nspname = 'us_booking' AND t.tgname = x.name)
       END AS present,
       CASE x.kind WHEN 'trigger' THEN (SELECT bool_and(t.tgenabled <> 'D') FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                                         JOIN pg_namespace n ON n.oid = c.relnamespace
                                        WHERE n.nspname = 'us_booking' AND t.tgname = x.name) END AS enabled
FROM (VALUES
  ('index',   'booking_attempt_one_blocking_per_parcel'),
  ('index',   'provider_shipment_one_live_per_parcel'),
  ('index',   'provider_shipment_tracking_uq'),
  ('index',   'print_event_one_initial_per_label'),
  ('index',   'fulfilment_group_order_one_active'),
  ('index',   'order_destination_confirmation_one_active'),
  ('index',   'review_case_one_open_per_order_type'),
  ('trigger', 'booking_attempt_insert'),
  ('trigger', 'booking_attempt_update'),
  ('trigger', 'booking_attempt_outcome_check'),
  ('trigger', 'provider_shipment_outcome_check'),
  ('trigger', 'provider_shipment_update'),
  ('trigger', 'print_event_insert'),
  ('trigger', 'parcel_item_guard'),
  ('trigger', 'parcel_guard'),
  ('trigger', 'parcel_cancel_release'),
  ('trigger', 'event_log_append_only'),
  ('trigger', 'event_log_no_truncate')
) x(kind, name)
ORDER BY 1, 2;

-- 5. Functions: owner, SECURITY DEFINER, and whether PUBLIC can execute them.
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
       pg_get_userbyid(p.proowner) AS owner, p.prosecdef AS security_definer,
       has_function_privilege('public', p.oid, 'EXECUTE') AS public_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'us_booking'
ORDER BY 1;

-- 6. Schema ownership and access. Expect PUBLIC to have no USAGE or CREATE.
SELECT n.nspname, pg_get_userbyid(n.nspowner) AS owner, n.nspacl::text AS acl,
       has_schema_privilege('public', n.oid, 'USAGE')  AS public_usage,
       has_schema_privilege('public', n.oid, 'CREATE') AS public_create
FROM pg_namespace n WHERE n.nspname = 'us_booking';

-- 7. Other roles with any table privilege in us_booking. Expect 0 rows (owner only).
SELECT DISTINCT grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'us_booking' AND grantee <> (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'us_booking')
ORDER BY 1, 2;
