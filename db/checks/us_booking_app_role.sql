-- Read-only check of the us_booking_app runtime role, run in varmen_db by any role:
--   npm run db:preflight -- --check=us_booking_app_role
-- Every statement is a SELECT; nothing is granted or revoked.
-- Expected before the us_booking migration: the role exists, logs in, has no elevated attributes,
-- is a member of nothing, connects only to varmen_db, and can create nothing anywhere.

-- 1. Attributes. Expect can_login = t and every other flag f.
SELECT rolname, rolcanlogin AS can_login, rolsuper, rolcreatedb, rolcreaterole, rolreplication,
       rolbypassrls, rolinherit, rolconnlimit, rolvaliduntil
FROM pg_roles WHERE rolname = 'us_booking_app';

-- 2. Role memberships held by us_booking_app. Expect 0 rows.
SELECT r.rolname AS member_of, am.admin_option
FROM pg_auth_members am
JOIN pg_roles r ON r.oid = am.roleid
WHERE am.member = (SELECT oid FROM pg_roles WHERE rolname = 'us_booking_app');

-- 3. Databases it can connect to, create schemas in, or create temp tables in (server-wide).
--    Expect CONNECT on varmen_db; see docs/setup.md for databases reachable through PUBLIC.
SELECT d.datname,
       has_database_privilege('us_booking_app', d.oid, 'CONNECT') AS can_connect,
       has_database_privilege('us_booking_app', d.oid, 'CREATE')  AS can_create_schema,
       has_database_privilege('us_booking_app', d.oid, 'TEMP')    AS can_create_temp
FROM pg_database d
WHERE NOT d.datistemplate AND to_regrole('us_booking_app') IS NOT NULL
ORDER BY 1;

-- 4. Schemas in this database it can use or create in. Before the migration expect only
--    public (USAGE via PUBLIC, no CREATE); after it, also us_booking with USAGE only.
SELECT n.nspname,
       has_schema_privilege('us_booking_app', n.oid, 'USAGE')  AS can_use,
       has_schema_privilege('us_booking_app', n.oid, 'CREATE') AS can_create
FROM pg_namespace n
WHERE n.nspname !~ '^(pg_|information_schema$)' AND to_regrole('us_booking_app') IS NOT NULL
  AND (has_schema_privilege('us_booking_app', n.oid, 'USAGE') OR has_schema_privilege('us_booking_app', n.oid, 'CREATE'))
ORDER BY 1;

-- 5. Tables, views and sequences outside us_booking it can access in any way. Expect 0 rows.
SELECT n.nspname, c.relname, c.relkind
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE to_regrole('us_booking_app') IS NOT NULL
  AND n.nspname !~ '^(pg_|information_schema$)' AND n.nspname <> 'us_booking'
  AND c.relkind IN ('r','p','v','m','f','S')
  AND has_schema_privilege('us_booking_app', n.oid, 'USAGE')
  AND (CASE WHEN c.relkind = 'S'
            THEN has_sequence_privilege('us_booking_app', c.oid, 'USAGE,SELECT,UPDATE')
            ELSE has_table_privilege('us_booking_app', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') END)
ORDER BY 1, 2;

-- 6. Objects it owns. Expect 0 rows.
SELECT n.nspname, c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relowner = (SELECT oid FROM pg_roles WHERE rolname = 'us_booking_app')
UNION ALL
SELECT nspname, '(schema)' FROM pg_namespace
WHERE nspowner = (SELECT oid FROM pg_roles WHERE rolname = 'us_booking_app');
