# Correction to the Wayfair production-test plan (2026-10-23)

Recorded before any production test is run. This note changes no code, no data and no
configuration: `WAYFAIR_MODE` stays `sandbox`-only (`src/server/wayfair/config.ts`), and this app
contains no production call for Wayfair anywhere. It corrects two points in how the eventual
controlled production test (referenced by `provider_packaging_policy` in
`db/migrations/0011_wayfair_managed_packaging.sql` and §3f of `docs/setup.md`) was being framed.

## 1. The authorisation must not depend on the test's own result

`provider_packaging_policy.production_verified_at` is set only after a controlled production test,
and the booking precondition (`tg_booking_attempt_insert`, 0011) refuses `provider_managed`
packaging until that column is set. That is correct and unchanged.

What needs correcting is what it takes to be *allowed to run* that test in the first place. A
production test is not a sandbox call: it registers a real purchase order with Wayfair's live
systems. Running it needs its own authorisation, and that authorisation must satisfy two
properties:

- **Separate.** It is not covered by whatever broader approval exists for the sandbox integration,
  for Wayfair-managed packaging in general, or for booking automation in general. It is a decision
  about this one test.
- **Narrowly scoped.** It names one selected purchase order, covers the production
  registration/shipping-label endpoints for that PO only, and expires once the test is complete.
  It does not open production access generally.
- **Not circular.** The authorisation must be grantable on evidence that exists *before* the test
  runs (the sandbox result, the documentation review, the business case for testing one PO in
  production). It must not be gated on `production_verified_at` itself, or on any other fact that
  can only come into existence once the test has already happened. A plan that required "proof the
  mode works in production" before authorising the one call that produces that proof would never
  be executable.

Until a sign-off meeting those three properties exists for a specific named PO, no production call
is made, and none is implemented by this change.

## 2. What the test would show, and what it would not show

The planned test is operational: register one named PO in production, then physically match the
label(s) Wayfair returns against the carton(s) actually packed and shipped for that PO (right
number of cartons, right label on each, correct destination). Passing that check demonstrates the
operational outcome — the labels Wayfair generates correspond to what the warehouse actually
shipped.

It does not demonstrate, and must not be documented as demonstrating, *where Wayfair's production
package data comes from*. Earlier text in `docs/setup.md` §3f stated as fact that "Wayfair holds
package data from the product listings." Wayfair's documentation does not say this, the sandbox
does not show it (sandbox labels are documented as static examples), and a successful label/carton
match in production would not show it either — the match would be consistent with listing data, a
stored default, a warehouse-level assignment, or anything else Wayfair's system might use. That
sentence has been corrected in `docs/setup.md` to state plainly that the provenance is unverified
and stays unverified regardless of the operational test's outcome.

## Where this is reflected

- `docs/setup.md` §3f: the overclaiming sentence is corrected, and this correction is recorded
  inline where the claim was made.
- `db/migrations/0011_wayfair_managed_packaging.sql`: unchanged (already applied; its own comment
  already says "Not verified: which package data production uses when `packageUnits` is omitted" —
  that phrasing was correct and is why only `docs/setup.md`'s summary needed fixing, not the
  migration).
- No change to `provider_packaging_policy`, the booking precondition, or any Wayfair sandbox code:
  the mechanism they implement (verification gates booking; nothing is assumed) was already sound.
  Only the plan for *how the one-time authorisation to test in production is obtained*, and *what
  the resulting test would prove*, needed correcting.
