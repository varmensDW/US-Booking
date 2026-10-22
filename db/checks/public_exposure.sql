-- Read-only check: what a new role with no grants of its own (us_booking_app) would inherit
-- through PUBLIC. Run in varmen_db:  npm run db:preflight -- --check=public_exposure
-- Every statement is a SELECT against the catalogs; nothing is granted or revoked. Any PUBLIC
-- grant found here is shared by other applications and must not be changed from this project.
-- Sections 2-7 cover only the connected database; section 1 covers every database on the server.

-- 1. Databases a new role could connect to (or create temp tables in) via PUBLIC, server-wide.
SELECT d.datname,
       d.datallowconn                                                   AS allows_connections,
       d.datacl IS NULL                                                 AS default_acl,
       d.datacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(d.datacl) a
                                   WHERE a.grantee = 0 AND a.privilege_type = 'CONNECT')   AS public_connect,
       d.datacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(d.datacl) a
                                   WHERE a.grantee = 0 AND a.privilege_type = 'TEMPORARY') AS public_temp,
       EXISTS (SELECT 1 FROM aclexplode(d.datacl) a
               WHERE a.grantee = 0 AND a.privilege_type = 'CREATE')                         AS public_create
FROM pg_database d
WHERE NOT d.datistemplate
ORDER BY 1;

-- 2. Schemas in this database where PUBLIC has USAGE or CREATE.
SELECT n.nspname,
       pg_get_userbyid(n.nspowner) AS owner,
       bool_or(a.privilege_type = 'USAGE')  AS public_usage,
       bool_or(a.privilege_type = 'CREATE') AS public_create
FROM pg_namespace n
CROSS JOIN LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) a
WHERE a.grantee = 0 AND n.nspname !~ '^(pg_|information_schema$)'
GROUP BY n.nspname, n.nspowner
ORDER BY 1;

-- 3. Tables, views, sequences with privileges granted to PUBLIC (non-system schemas), and whether
--    they are actually reachable (PUBLIC also has USAGE on the schema).
SELECT n.nspname, c.relname, c.relkind,
       string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS public_privileges,
       has_schema_privilege('public', n.oid, 'USAGE')               AS reachable
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(c.relacl) a
WHERE a.grantee = 0 AND n.nspname !~ '^(pg_|information_schema$)'
GROUP BY n.nspname, n.oid, c.relname, c.relkind
ORDER BY 1, 2;

-- 4. Column-level privileges granted to PUBLIC (non-system schemas).
SELECT n.nspname, c.relname, count(*) AS columns, string_agg(DISTINCT a.privilege_type, ',') AS public_privileges
FROM pg_attribute att
JOIN pg_class c ON c.oid = att.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(att.attacl) a
WHERE a.grantee = 0 AND n.nspname !~ '^(pg_|information_schema$)'
GROUP BY 1, 2
ORDER BY 1, 2;

-- 5. Functions PUBLIC can execute in non-system schemas (the default unless revoked). SECURITY
--    DEFINER ones run with their owner's rights, so they matter most.
SELECT n.nspname,
       count(*)                                     AS public_executable,
       count(*) FILTER (WHERE p.prosecdef)          AS security_definer,
       has_schema_privilege('public', n.oid, 'USAGE') AS reachable
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname !~ '^(pg_|information_schema$)'
  AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
GROUP BY n.nspname, n.oid
ORDER BY 1;

-- 6. SECURITY DEFINER functions reachable by PUBLIC, listed individually.
SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args,
       pg_get_userbyid(p.proowner) AS owner
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prosecdef
  AND n.nspname !~ '^(pg_|information_schema$)'
  AND has_schema_privilege('public', n.oid, 'USAGE')
  AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
ORDER BY 1, 2;

-- 7. Default privileges that will grant to PUBLIC on future objects.
SELECT pg_get_userbyid(d.defaclrole) AS for_role, n.nspname, d.defaclobjtype,
       string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS public_privileges
FROM pg_default_acl d
LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
CROSS JOIN LATERAL aclexplode(d.defaclacl) a
WHERE a.grantee = 0
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- 8. Large objects readable or writable by PUBLIC.
SELECT count(*) AS public_large_objects
FROM pg_largeobject_metadata l
WHERE EXISTS (SELECT 1 FROM aclexplode(l.lomacl) a WHERE a.grantee = 0);

-- 9. Predefined roles with broad data access, and their current members (a new role gets none
--    unless granted; listed so the DBA can confirm us_booking_app stays out of them).
SELECT r.rolname AS predefined_role, string_agg(m.rolname, ', ' ORDER BY m.rolname) AS members
FROM pg_roles r
LEFT JOIN pg_auth_members am ON am.roleid = r.oid
LEFT JOIN pg_roles m ON m.oid = am.member
WHERE r.rolname IN ('pg_read_all_data', 'pg_write_all_data', 'pg_read_server_files',
                    'pg_write_server_files', 'pg_execute_server_program', 'pg_monitor')
GROUP BY 1
ORDER BY 1;
