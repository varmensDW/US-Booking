-- 0006_country_map_oms_confirmed: verified meanings of two OMS country ids.
--
--   OMS country_id 8   -> United States (US)
--   OMS country_id 359 -> Canada (CA)
--
-- Source: confirmation from the OMS developer, as reported by the project owner on 2026-10-23. It
-- was not verified independently by this project. The OMS column (customers.shipping_address.
-- country_id) is an integer, so the representation "08" is the same value as 8; the sync casts the
-- snapshot value to integer, so "08" and 8 resolve to the same row here.
--
-- Effect: v_order_destination resolves orders with these ids through the verified map, so routine
-- US/Canada orders need no per-order confirmation. Any other id, a missing id, or a per-order
-- confirmation that disagrees with the map stays in review (unresolved / conflict). Nothing is
-- written to the OMS. Existing imported orders are recomputed by the next sync
-- (npm run sync:oms -- --apply --limit=0 refreshes them without importing new orders).
--
-- Guard: an existing row for either id with a different country or a non-verified status is a
-- conflict. It is reported (the migration stops and is rolled back) instead of being replaced.
-- Other country_map rows are not touched.

DO $$
DECLARE
  v_conflicts text;
BEGIN
  SELECT string_agg(format('country_id %s is %s (%s, evidence: %s)', m.oms_country_id, coalesce(m.iso2::text, 'no iso2'),
                           m.status, coalesce(m.evidence, 'none')), '; ' ORDER BY m.oms_country_id)
    INTO v_conflicts
    FROM us_booking.country_map m
    JOIN (VALUES (8, 'US'), (359, 'CA')) v(oms_country_id, iso2) ON v.oms_country_id = m.oms_country_id
   WHERE m.iso2 IS DISTINCT FROM v.iso2::char(2) OR m.status <> 'verified';
  IF v_conflicts IS NOT NULL THEN
    RAISE EXCEPTION 'country_map already holds a different mapping: %. Nothing was replaced; decide how to resolve it before applying 0006.', v_conflicts;
  END IF;
END $$;

WITH added AS (
  INSERT INTO us_booking.country_map (oms_country_id, iso2, country_name, status, evidence, verified_by, verified_at)
  VALUES (8,   'US', 'United States', 'verified', 'OMS developer confirmation reported by project owner on 2026-10-23.', 'project owner', now()),
         (359, 'CA', 'Canada',        'verified', 'OMS developer confirmation reported by project owner on 2026-10-23.', 'project owner', now())
  ON CONFLICT (oms_country_id) DO NOTHING
  RETURNING oms_country_id, iso2, evidence
)
INSERT INTO us_booking.event_log (entity, entity_id, from_state, to_state, actor, details)
SELECT 'country_map', oms_country_id, NULL, 'verified', 'migration:0006',
       jsonb_build_object('iso2', iso2, 'evidence', evidence, 'verified_by', 'project owner')
  FROM added;
