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
- **Review dashboard:** `npm run build && npm run start` serves http://127.0.0.1:3100 (Order Review, Sync History, Settings, Settings → Package Profiles). Staff can prepare parcels from the default package profiles, confirm destinations the verified country map cannot resolve, and record decisions on findings (docs/setup.md §3d); otherwise it only reads, apart from the explicit Sync Orders action.
- **No provider integration exists yet.** Purchase and print are unavailable; nothing is booked or printed.
  - `ENABLE_LIVE_BOOKING` (false) and `SHIPPO_MODE` are placeholders that nothing reads yet.

## Folders

| Path | Responsibility |
|---|---|
| `db/migrations/` | Applied migrations (`0001` schema, `0002` schema security, `0003`/`0004` OMS sync), run by `npm run db:migrate` |
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
| `storage/labels/` | Local-development label storage only. Contents are git-ignored. Deployment storage is not configured yet |

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
