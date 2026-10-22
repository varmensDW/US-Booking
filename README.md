# US Booking Automation

Phase 1: booking and label printing for **US1 warehouse shipments to the US and Canada**. The OMS (ledsone mirror) is read-only and is never written to.

| Channel | Labels via |
|---|---|
| Shopify, eBay | Shippo |
| Amazon | Seller Central |
| Wayfair | Wayfair's own account |

Staff confirm package dimensions, weight and contents before booking.

## Status

- The booking schema is **proposed only** (`db/proposed/`). It has been tested in a disposable local PostgreSQL cluster, but not applied to any real database.
- **No application, OMS sync or provider integration exists yet.**
  - `src/` is empty.
  - `ENABLE_LIVE_BOOKING` and `SHIPPO_MODE` are placeholders that nothing reads yet.
- Booking target confirmed: `varmen_db`, schema `us_booking` (same server as the `ledsone` OMS, which stays read-only). The read-only preflight passed on 2026-10-22; nothing has been applied yet. See `docs/setup.md`.

## Folders

| Path | Responsibility |
|---|---|
| `db/proposed/` | Proposed schema (`0001`) and runtime grants (`0002`). Not applied anywhere |
| `db/checks/` | Read-only preflight for the booking database |
| `db/tests/` | Schema test suite. Creates and deletes its own disposable cluster |
| `docs/phase1/` | Schema proposal, source verification and test results |
| `docs/setup.md` | Local setup |
| `exports/` | **Private** Phase 1 Shippo↔OMS match exports, raw extracts and `build.py`. Git-ignored |
| `src/server/` | Future backend |
| `src/client/` | Future booking interface |
| `scripts/` | Project utilities (`check-env.mjs`) |
| `storage/labels/` | Local-development label storage only. Contents are git-ignored. Deployment storage is not configured yet |

The original Shippo export, `export_user_*.csv`, stays at the project root because the Phase 1 exports reference it. It contains customer names and addresses and is git-ignored.

## Quick start

```
copy .env.example .env      # only if .env does not exist yet; then fill in values locally
npm run check:env           # names and status only, never values; connects to nothing
npm run db:preflight        # read-only inspection of the booking database
```

See `docs/setup.md` for details.
