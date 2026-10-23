# US Booking Automation

Phase 1: booking and label printing for **US1 warehouse shipments to the US and Canada**. The OMS (ledsone mirror) is read-only and is never written to.

| Channel | Labels via |
|---|---|
| Shopify, eBay | Shippo |
| Amazon | Seller Central |
| Wayfair | Wayfair's own account |

Staff confirm package dimensions, weight and contents before booking.

## Status

- The booking schema (rev 2) is **applied** in `varmen_db.us_booking` via `npm run db:migrate` (migrations 0001–0004, 2026-10-23).
- Approved role setup: `varmen_user` owns the schema and is also the runtime login (`BOOKING_ROLE_MODE=single`). See `docs/setup.md` for what that does and does not enforce.
- **OMS order sync:** `npm run sync:oms` (dry run) / `-- --apply`. It reads `ledsone` read-only and imports open US1 groups into the review queue. The first limited import ran on 2026-10-23: 15 groups, all awaiting review.
- **Review dashboard:** `npm run build && npm run start` serves http://127.0.0.1:3100 (Order Review, Sync History, Settings, Settings → Package Profiles, Settings → Wayfair Sandbox, Settings → Shippo Test). Staff can prepare parcels from the default package profiles, confirm destinations the verified country map cannot resolve, and record decisions on findings (docs/setup.md §3d); otherwise it only reads, apart from the explicit Sync Orders action and the Wayfair/Shippo test-mode pages below.
- **Wayfair SANDBOX** (Settings → Wayfair Sandbox, docs/setup.md §3e–§3f): checks the Wayfair account and the sandbox registration/label workflow; Wayfair-managed packaging for live parcels stays gated on a controlled production test (not run yet — see `docs/phase1/2026-10-23_wayfair_production_test_plan_correction.md` for a correction to that plan recorded before any such test).
- **Shippo TEST** (Settings → Shippo Test, docs/setup.md §3g): requests TEST-mode rates and buys TEST-mode labels for a synthetic shipment (Shopify/eBay route, US and Canada), against Shippo's real API with a `shippo_test_` token. Requires `SHIPPO_SHIP_FROM_*` to be configured locally; no live credential is accepted. A completed (succeeded/confirmed) test shipment is never purchased again; label print format is a settable preference that applies to future purchases only. `SHIPPO_SHIP_RETURN_*` is optional and reported explicitly (never silently defaulted) since this account's return address differs from its sender address.
- **No live provider purchase exists yet.** Nothing is booked or printed against a real order; `ENABLE_LIVE_BOOKING` stays `false` and is not read by the Wayfair sandbox or Shippo test workflows above.

## Folders

| Path | Responsibility |
|---|---|
| `db/migrations/` | Applied migrations (`0001` schema, `0002` schema security, `0003`/`0004` OMS sync, ... `0010` Wayfair sandbox, `0011` Wayfair-managed packaging, `0012`/`0013` Shippo TEST records), run by `npm run db:migrate` |
| `db/proposed/` | Not applied: grants for a possible future separate runtime role |
| `db/admin/` | DBA scripts. Not used in single-role mode |
| `db/checks/` | Read-only checks: preflight, applied objects, OMS sync status, PUBLIC exposure |
| `db/tests/` | Schema suite (`run_local_tests.sh`) and OMS sync suite (`run_sync_tests.sh`, synthetic OMS). Each creates and deletes its own disposable cluster |
| `docs/phase1/` | Schema proposal, source verification and test results |
| `docs/setup.md` | Local setup |
| `exports/` | **Private** Phase 1 Shippo↔OMS match exports, raw extracts and `build.py`. Git-ignored |
| `src/app/` | Next.js pages and API routes |
| `src/server/` | Server-only code: database access, read models, sync job; `sync/oms_extract.sql` (read-only OMS extraction) |
| `src/client/` | Dashboard UI components and display rules |
| `scripts/` | Commands: `check-env`, `db-preflight`, `db-migrate`, `oms-sync`; shared helpers in `lib/` |
| `src/server/wayfair/`, `src/server/shippo/` | Server-only clients for the Wayfair SANDBOX and Shippo TEST-mode workflows |
| `tests/wayfair/`, `tests/shippo/` | Mock-API integration test suites for those two workflows, run against a synthetic app instance |
| `storage/labels/` | Local-development label storage only (`wayfair-sandbox/`, `shippo-test/` subfolders). Contents are git-ignored. Deployment storage is not configured yet |

The original Shippo export, `export_user_*.csv`, stays at the project root because the Phase 1 exports reference it. It contains customer names and addresses and is git-ignored.

## Quick start

```
copy .env.example .env      # only if .env does not exist yet; then fill in values locally
npm run check:env           # names and status only, never values; connects to nothing
npm run db:preflight        # read-only inspection of the booking database
npm run db:migrate          # plan only; -- --dry-run / -- --apply
npm run sync:oms            # OMS import dry run; -- --apply to commit
```

See `docs/setup.md` for details.
