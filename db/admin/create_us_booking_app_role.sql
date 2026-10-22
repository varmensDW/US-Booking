-- Create the us_booking_app runtime login role. FOR THE DATABASE ADMINISTRATOR.
--
-- Run interactively with psql, connected to varmen_db as a role that has CREATEROLE (or a
-- superuser). varmen_user cannot run it: it has no CREATEROLE.
--   psql -X "<admin connection to varmen_db>" -f db/admin/create_us_booking_app_role.sql
--
-- What it does:
--   * creates us_booking_app: LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOREPLICATION,
--     NOBYPASSRLS, no role memberships, no ownership;
--   * grants CONNECT on varmen_db only (PUBLIC has no CONNECT on varmen_db, so this is needed);
--   * prompts for the password with \password, which hashes it in psql (SCRAM) before sending,
--     so the plain password never appears in this file, the server log or pg_stat_activity.
-- It changes no PUBLIC or other shared grants. Schema and table rights in us_booking are granted
-- later by the project's migration (db/proposed/0002), run as varmen_user.
--
-- Share the password only through the team's secure channel. The project owner stores it in
-- their local .env as BOOKING_DATABASE_URL; it must not be sent in chat, tickets or email.

\set ON_ERROR_STOP on

SELECT current_database() = 'varmen_db' AS on_varmen_db \gset
\if :on_varmen_db
\else
  \echo 'Not connected to varmen_db. Nothing was changed.'
  \quit
\endif

SHOW password_encryption;   -- expect scram-sha-256

BEGIN;
CREATE ROLE us_booking_app
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT
  CONNECTION LIMIT 20;
COMMENT ON ROLE us_booking_app IS 'US Booking Automation runtime role. DML on varmen_db.us_booking only, granted by migration. Owner/migrations: varmen_user.';
GRANT CONNECT ON DATABASE varmen_db TO us_booking_app;
COMMIT;

\echo 'Enter the new password for us_booking_app (hashed client-side):'
\password us_booking_app

-- Verification (read-only). Expect: can_login t, all other flags f, no memberships,
-- CONNECT on varmen_db, CREATE on no database or schema.
SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls,
       rolconnlimit
FROM pg_roles WHERE rolname = 'us_booking_app';
SELECT count(*) AS memberships
FROM pg_auth_members WHERE member = 'us_booking_app'::regrole;
SELECT datname,
       has_database_privilege('us_booking_app', oid, 'CONNECT') AS can_connect,
       has_database_privilege('us_booking_app', oid, 'CREATE')  AS can_create_schema
FROM pg_database WHERE NOT datistemplate ORDER BY 1;

-- Optional, recommended (server configuration, not a grant): PUBLIC has CONNECT on
-- accounts_management, digitweb_tracker and postgres, so this role could connect there too.
-- To confine it without touching shared grants, add pg_hba.conf lines ABOVE the general rules,
-- then reload (SELECT pg_reload_conf();):
--   hostssl  varmen_db  us_booking_app  <app host/CIDR>  scram-sha-256
--   host     all        us_booking_app  all              reject
