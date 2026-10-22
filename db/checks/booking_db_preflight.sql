-- Read-only preflight for the database named by BOOKING_DATABASE_URL.
-- Every statement is a SELECT against catalog functions; nothing is created, granted or changed.
-- Run it inside a read-only transaction, e.g.  psql "$BOOKING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--   -c 'BEGIN READ ONLY' -f db/checks/booking_db_preflight.sql -c 'ROLLBACK'
-- Never paste the connection string into logs or chat.

-- 1. Identity: which server, database and role this URL really is.
SELECT current_database()                        AS database,
       current_user                              AS role,
       session_user                              AS session_role,
       inet_server_addr()                        AS server_addr,
       inet_server_port()                        AS server_port,
       split_part(version(), ' ', 2)             AS pg_version,
       current_setting('default_transaction_read_only') AS default_read_only,
       current_setting('ssl', true)              AS server_ssl;

-- 2. Must NOT be the OMS mirror. Expect false/0 here.
SELECT current_database() = 'ledsone'                                     AS is_ledsone,
       to_regnamespace('order_management') IS NOT NULL                    AS has_order_management_schema,
       to_regclass('order_management.orders') IS NOT NULL                 AS has_oms_orders_table;

-- 3. Role attributes (cluster level).
SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolbypassrls, rolconnlimit
FROM pg_roles WHERE rolname = current_user;

-- 4. Schema/table CREATION rights (needed only by the migration role).
SELECT pg_get_userbyid(d.datdba)                             AS database_owner,
       pg_get_userbyid(d.datdba) = current_user              AS i_own_database,
       has_database_privilege(current_database(), 'CREATE')  AS can_create_schema,
       has_database_privilege(current_database(), 'TEMP')    AS can_create_temp,
       d.datacl::text                                        AS database_acl
FROM pg_database d WHERE d.datname = current_database();

-- 5. Does the us_booking schema already exist, who owns it, and can this role create in it.
SELECT n.nspname, pg_get_userbyid(n.nspowner) AS owner,
       has_schema_privilege(n.oid, 'USAGE')  AS can_use,
       has_schema_privilege(n.oid, 'CREATE') AS can_create_tables
FROM pg_namespace n WHERE n.nspname = 'us_booking';

-- 6. DATA-WRITE rights on existing us_booking tables (needed by the runtime role).
SELECT c.relname,
       pg_get_userbyid(c.relowner)                    AS owner,
       has_table_privilege(c.oid, 'SELECT')           AS sel,
       has_table_privilege(c.oid, 'INSERT')           AS ins,
       has_table_privilege(c.oid, 'UPDATE')           AS upd,
       has_table_privilege(c.oid, 'DELETE')           AS del,
       has_table_privilege(c.oid, 'TRUNCATE')         AS trunc
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'us_booking' AND c.relkind IN ('r','p')
ORDER BY 1;

-- 7. Default privileges that will apply to future tables in us_booking.
SELECT pg_get_userbyid(defaclrole) AS for_role, defaclobjtype, defaclacl::text
FROM pg_default_acl a LEFT JOIN pg_namespace n ON n.oid = a.defaclnamespace
WHERE n.nspname = 'us_booking' OR a.defaclnamespace = 0;

-- 8. Other schemas this role could create objects in (should be none besides us_booking).
SELECT n.nspname
FROM pg_namespace n
WHERE n.nspname !~ '^(pg_|information_schema)' AND has_schema_privilege(n.oid, 'CREATE');

-- 9. Server version. 0001 uses UNIQUE NULLS NOT DISTINCT, which needs PostgreSQL 15 or later.
SELECT current_setting('server_version')                    AS server_version,
       current_setting('server_version_num')::int >= 150000 AS version_ok_for_0001;

-- 10. Roles named by the proposed migrations: do they exist, and is this role a member of them.
SELECT r.rolname,
       true                                   AS role_exists,
       r.rolcanlogin                          AS can_login,
       pg_has_role(current_user, r.oid, 'MEMBER') AS current_role_is_member
FROM pg_roles r WHERE r.rolname IN ('us_booking_owner', 'us_booking_app')
UNION ALL
SELECT x.rolname, false, NULL, NULL
FROM (VALUES ('us_booking_owner'), ('us_booking_app')) x(rolname)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles r WHERE r.rolname = x.rolname)
ORDER BY 1;

-- 11. Summary for this role. Migration needs: create the schema (or own an existing one) and a
-- supported version. Runtime should NOT be able to create schemas or own us_booking objects.
SELECT current_user AS role,
       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) AS is_superuser,
       has_database_privilege(current_database(), 'CREATE')       AS can_create_schema,
       to_regnamespace('us_booking') IS NOT NULL                   AS us_booking_exists,
       COALESCE((SELECT pg_has_role(current_user, nspowner, 'USAGE') FROM pg_namespace WHERE nspname = 'us_booking'), false)
                                                                   AS owns_us_booking,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'us_booking')                           AS us_booking_relations,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'us_booking')                           AS us_booking_functions,
       current_setting('server_version_num')::int >= 150000       AS version_ok_for_0001;
