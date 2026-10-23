-- 0002_us_booking_schema_security: schema-level security for the approved single-role setup.
--
-- Approved setup (2026-10-23): varmen_user owns us_booking and every object in it, runs the
-- migrations, and is also the application's runtime login. No separate runtime role exists, so the
-- per-table runtime grants in db/proposed/0002_us_booking_grants.sql are NOT applied: granting them
-- to the owner would add nothing, because an owner already holds every privilege on its objects.
-- That file stays in db/proposed/ for a possible future separate runtime login.
--
-- What still applies from it, and is applied here:
--   * PUBLIC gets nothing in us_booking: no schema USAGE or CREATE.
--   * PUBLIC cannot call adjust_allocation(), the SECURITY DEFINER allocation counter.
-- Other roles that can connect to varmen_db (for example read-only tooling) therefore see nothing
-- in us_booking unless granted explicitly by a later, reviewed migration.
--
-- What the single-role setup does NOT give (see docs/setup.md): privilege-based restrictions that
-- were tested for a separate runtime role do not bind the owner. The app, connecting as the owner,
-- can UPDATE/DELETE tables the runtime role could only INSERT into or read, write item_allocation
-- and country_map directly, and ALTER or DROP objects, including disabling triggers. Constraints,
-- unique indexes and enabled triggers still apply to the owner: duplicate-purchase blocking,
-- state-machine guards, measurement/allocation checks and event_log append-only all hold unless
-- someone deliberately alters the schema.

DO $$
BEGIN
  IF to_regnamespace('us_booking') IS NULL THEN
    RAISE EXCEPTION 'schema us_booking does not exist; apply 0001 first';
  END IF;
  IF NOT pg_has_role(current_user, (SELECT nspowner FROM pg_namespace WHERE nspname = 'us_booking'), 'USAGE') THEN
    RAISE EXCEPTION 'current role % does not own schema us_booking', current_user;
  END IF;
END;
$$;

REVOKE ALL ON SCHEMA us_booking FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION us_booking.adjust_allocation(bigint, integer) FROM PUBLIC;
