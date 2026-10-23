# Local setup

## Requirements

- Node.js ≥ 22. Developed with 24.x. It needs no npm packages yet: `.env` is loaded with Node's built-in `process.loadEnvFile()`.
- PostgreSQL 18 client tools (`psql`). Needed only for the preflight and the schema test suite.
- Git Bash. Needed to run the `.sh` test scripts on Windows.

## Confirmed database arrangement (2026-10-22)

One existing PostgreSQL server (18.4) holds both databases. No new database is needed.

| Database | Role in this project | Access |
|---|---|---|
| `ledsone` | OMS source (`OMS_READ_DATABASE_URL`) | Read-only, SELECT only. Never written to |
| `varmen_db` | Booking target (`BOOKING_DATABASE_URL`) | Booking objects go in the `us_booking` schema only. Other schemas in `varmen_db` belong to other applications and must not be changed |

`BOOKING_DATABASE_EXPECTED_NAME=varmen_db`. Tools stop if the connected database is anything else.

**Role setup (approved by the developer, 2026-10-23): single role.** `varmen_user` owns `us_booking`, runs the migrations, and is also the application's runtime login. `BOOKING_DATABASE_URL` and `BOOKING_MIGRATION_DATABASE_URL` are the same connection, and `.env` records the decision as `BOOKING_ROLE_MODE=single`. No other role is created or needed.

**Schema status:** `db/migrations/0001`–`0004` are applied to `varmen_db.us_booking` (2026-10-23). The first limited OMS import ran on 2026-10-23 (§3b). Nothing has been booked or printed.

## 1. Environment values

`.env` holds local values and is git-ignored. `.env.example` is the template with comments. If `.env` is missing, copy the template to create it.

| Variable | What to put there |
|---|---|
| `OMS_READ_DATABASE_URL` | OMS (`ledsone`) connection for a **SELECT-only** role. Used only by `npm run sync:oms` |
| `OMS_DATABASE_EXPECTED_NAME` | Optional; defaults to `ledsone`. The sync stops if the OMS URL connects elsewhere |
| `BOOKING_DATABASE_URL` | Booking database, runtime login. Approved: `varmen_user` on `varmen_db` |
| `BOOKING_MIGRATION_DATABASE_URL` | Booking database, schema owner, used by `npm run db:migrate`. In single-role mode, the same connection as above |
| `BOOKING_ROLE_MODE` | `single` (approved: one login owns and runs) or `separate` (a DML-only runtime role) |
| `BOOKING_DATABASE_EXPECTED_NAME` | `varmen_db`. Both booking URLs must point at it |
| `SHIPPO_API_TOKEN`, `SHIPPO_MODE` | Shippo **test** token (starts `shippo_test_`) and `test`. Not needed for the database preflight; required for Settings → Shippo Test (§3g) |
| `SHIPPO_SHIP_FROM_*` | This warehouse's ship-from address for Shippo TEST rate shopping (§3g). Required for that page only; never guessed from historical labels |
| `ENABLE_LIVE_BOOKING` | Keep `false`. A placeholder that nothing reads yet |
| `LABEL_STORAGE_DIR` | `./storage/labels`. Local development only |

Rules:

- Use `postgres://` or `postgresql://` URLs, with `sslmode=require` for remote servers.
- Never paste these values into chat, tickets, logs or commits.

## 2. Check the configuration

```
npm run check:env                                   # report only; always finishes
npm run check:env -- --strict                       # exit code 1 if anything is missing or invalid
npm run check:env -- --stage=db-preflight --strict  # only what the read-only preflight needs
npm run check:env -- --stage=db-migrate --strict    # both booking URLs + expected name
npm run check:env -- --stage=oms-sync --strict      # OMS URL + booking URL + expected name
```

The `db-preflight` stage requires only `BOOKING_DATABASE_URL` and `BOOKING_DATABASE_EXPECTED_NAME`. A missing OMS URL, migration URL or Shippo token shows as `not needed` and does not fail the check. Values that are supplied are still validated, including a migration URL.

The checker prints each variable name with `configured`, `missing`, `invalid`, `warning` or `ok`. It never prints values and never connects to a database.

It also checks:

- that both booking URLs name `BOOKING_DATABASE_EXPECTED_NAME`;
- that runtime and migration use separate roles, unless `BOOKING_ROLE_MODE=single` records the approved single-role setup (then the same role is `ok`);
- that the OMS URL does not point at the booking database.

## 3. Read-only preflight

```
npm run check:env -- --stage=db-preflight --strict
npm run db:preflight
```

`scripts/db-preflight.mjs`:

- reads `BOOKING_DATABASE_URL` (and `BOOKING_MIGRATION_DATABASE_URL`, if supplied) from this project's `.env` only, ignoring shell variables;
- passes the connection to `psql` through `PG*` environment variables, never on the command line, and never prints it;
- connects and **stops unless `current_database()` is exactly `varmen_db`**;
- runs `db/checks/booking_db_preflight.sql` inside `BEGIN READ ONLY … ROLLBACK`, with the session default also read-only;
- inspects each supplied URL separately.

`psql` is taken from `PG_BIN`, `PATH`, or `C:\Program Files\PostgreSQL8in`.

The preflight reports:

- identity, and confirmation that the target is not the OMS;
- role attributes, schema-creation rights and data-write rights;
- existing `us_booking` objects and default privileges;
- other schemas the role can create in;
- the server version (≥ 15 is required by `0001`);
- whether `us_booking_owner` and `us_booking_app` exist.

Do **not** apply `db/proposed/` until the preflight output has been reviewed.

## 3a. Migrations

```
npm run check:env -- --stage=db-migrate --strict
npm run db:preflight              # read-only; confirms varmen_db and shows existing us_booking objects
npm run db:migrate                # plan only (read-only): applied vs pending files
npm run db:migrate -- --dry-run   # applies pending files in one transaction, then ROLLBACK
npm run db:migrate -- --apply     # the same, then COMMIT
npm run db:preflight -- --check=us_booking_objects   # read-only verification of what exists
```

`scripts/db-migrate.mjs` applies `db/migrations/NNNN_*.sql` in order through `BOOKING_MIGRATION_DATABASE_URL`:

- All pending files run in **one** `REPEATABLE READ` transaction, with `lock_timeout=5s` and `statement_timeout=300s`.
- It stops unless `current_database()` is exactly `varmen_db`.
- It fingerprints every object **outside** `us_booking` (schemas, tables, functions, triggers, constraints, ACLs, extensions) before and after. Any difference rolls everything back, so other applications' schemas cannot change.
- It records each applied file, with its SHA-256, in `us_booking.schema_migration`. A recorded file whose content later changes stops the run; add a new numbered file instead.
- Files outside `db/migrations/` are never applied or recorded. `db/proposed/0002_us_booking_grants.sql` (per-table grants for a separate runtime role) is deliberately **not** applied in single-role mode: it has no grantee, and granting the owner its own privileges adds nothing.

Applied on 2026-10-23:

| Version | File | What it does |
|---|---|---|
| 0001 | `0001_us_booking_init.sql` | Schema rev 2: 24 tables, 2 views, 11 functions, 11 triggers and all constraints/indexes |
| 0002 | `0002_us_booking_schema_security.sql` | Revokes all PUBLIC access to the schema, and PUBLIC EXECUTE on `adjust_allocation` |
| 0003 | `0003_oms_sync.sql` | OMS snapshot import function `oms_sync_apply()`, its helpers, and the `v_review_queue` view |
| 0004 | `0004_oms_sync_combo_rule.sql` | Replaces `oms_sync_apply()` with the verified combo-mismatch rule (§3b) |
| 0005 | `0005_oms_sync_revalidation.sql` | Revokes confirmations when the address changes, invalidates outdated staff checks (`basis_hash`), reopens recurring findings, applies customs by destination, and stores OMS shipment/cancellation evidence |
| 0006 | `0006_country_map_oms_confirmed.sql` | Verified country map rows: 8 → US, 359 → CA (stops instead of replacing a conflicting row) (§3d) |
| 0007 | `0007_package_profiles_parcel_units.sql` | Versioned package profiles and route defaults; parcel units and value source; booking precondition accepts default-profile values (§3d) |
| 0008 | `0008_staff_review_actions.sql` | Staff actions (profiles, parcels, destination exceptions, findings) and failed-sync records (§3d) |
| 0011 | `0011_wayfair_managed_packaging.sql` | Wayfair-managed packaging mode, packaging exceptions, production-verification gate (§3f) |
| 0010 | `0010_wayfair_sandbox.sql` | Wayfair sandbox registration and label records, isolated from live booking (§3e) |
| 0009 | `0009_parcel_contents_revalidation.sql` | Parcel contents confirmations revalidated by the sync; discrepancies; booking checks the confirmation basis (§3d) |

Verified after applying 0001–0002:

- 25 tables (24 + ledger), 2 views, 57 indexes and 13 sequences, all owned by `varmen_user`.
- Every table except the ledger has 0 rows.
- All 7 protective unique indexes and all 11 triggers are present and enabled.
- PUBLIC has no access to the schema, and no other role has any table privilege.
- A structure-only `pg_dump` of the live schema is identical to the one built from the same migrations in a disposable local cluster, apart from the ledger table.

### Single-role setup: what still holds and what does not

The local suite (`db/tests`, 186 checks) proves the design with a **separate** DML-only runtime role (T0–T9), plus owner-level checks (T10).

**Still enforced when the app connects as the owner**, because constraints, unique indexes and enabled triggers apply to every role:

- duplicate-purchase blocking (trigger plus the partial unique index);
- the booking state machine and unknown-outcome rules;
- frozen measurements and contents once a purchase is pending;
- positive measurements and over-allocation checks;
- one live label per parcel, and only active labels being printable;
- `event_log` append-only, including TRUNCATE.

**Not enforced for the owner:** restrictions that came only from the runtime role *lacking* privileges. The owner can:

- write `item_allocation` and `country_map` directly, bypassing the SECURITY DEFINER counter and the owner-only reference data;
- UPDATE or DELETE tables that the runtime role could only insert into (`label_file`, `hist_*`);
- ALTER or DROP any `us_booking` object, including **disabling triggers**, which would switch off the protections above.

The application code must therefore avoid all of these. Schema changes go only through reviewed files in `db/migrations/`. If stronger isolation is wanted later, create a separate DML-only login and apply the grants in `db/proposed/0002_us_booking_grants.sql` as a new numbered migration.

### Other read-only checks

```
npm run db:preflight -- --check=public_exposure       # what any role inherits through PUBLIC
npm run db:preflight -- --check=us_booking_app_role   # only relevant if a separate runtime login is ever created
```

PUBLIC findings (2026-10-22):

- PUBLIC has CONNECT on `accounts_management`, `digitweb_tracker` and `postgres`, but not on `varmen_db`, `ledsone` or `ph_dashboard`.
- In `varmen_db`, PUBLIC can use only the `public` schema.
- Nothing in `varmen_db` is granted to PUBLIC.

`db/admin/create_us_booking_app_role.sql` is **not used** under the approved single-role setup. It is kept for a possible future separate runtime login.

## 3b. OMS order sync

```
npm run check:env -- --stage=oms-sync --strict
npm run sync:oms                          # dry run: full import in a transaction, then ROLLBACK
npm run sync:oms -- --apply               # import and commit
npm run sync:oms -- --apply --limit=5     # at most 5 NEW groups (1-20, default 20)
npm run db:preflight -- --check=oms_sync_status   # read-only status of what has been imported
```

**Connections.**

- The command reads `ledsone` through `OMS_READ_DATABASE_URL` only, in a `READ ONLY, REPEATABLE READ` transaction with a read-only session default. Its query is `src/server/sync/oms_extract.sql`.
- It writes `varmen_db.us_booking` through `BOOKING_DATABASE_URL` only.
- It stops if either database is not the expected one, or if both URLs point at the same database.
- It warns if the OMS role can write to OMS tables. The development MCP connector is not used.
- The OMS URL uses the `varmen_user` login. On `ledsone` that role is effectively SELECT-only (checked 2026-10-23): no elevated attributes, no CREATE on the database or any schema, no write privilege on any table, and no owned objects. It can read all 12 source tables. `check:env` warns that the OMS and booking URLs share a role; that warning is expected here.

**What is fetched.**

- At most `--limit` new **fulfilment groups**, oldest order first.
- Every previously imported group is fetched again, whatever its current OMS status or warehouse.
- A new group needs: US1 (warehouse 32), an open status (`New`, `Inprogress` or `Hold`), and source Amazon (1), eBay (2), Shopify (3) or Wayfair (6).
- A group is an OMS container order: a merge parent (`orders.merge = 'merged'`) with **all** of its children (`orders.merge = '<parent id>'`), or a single order. The extraction fetches all lines of the group.

**How it is stored.** `us_booking.oms_sync_apply()` (migrations `0003`/`0004`) writes one snapshot in a single transaction.

| Rule | How |
|---|---|
| Stable ids, no duplicates | Orders keyed by `orders.id`, lines by `order_item_info.id`, components by `order_combo.id`, groups by `oms:<container id>:g<generation>`. Re-runs upsert |
| Containing and originating order | `oms_order_item.container_order_id` = `order_item_info.order_id`; `oms_order_item.oms_order_id` = `order_ref_id`. Group membership roles: `single`, `merge_parent`, `merge_child` |
| As ordered | `item_sku`, `quantity_ordered` and `quantity_raw` are copied exactly. Pack lines stay one line; `order_combo` rows are reference only. No parcels, contents or allocations are created |
| Raw time | `order_date_raw` is copied unconverted |
| Country | `oms_country_id` is stored raw. The destination comes only from a verified `country_map` row or a staff confirmation; otherwise `destination_country` stays **unmet** and scope is `undetermined` |
| Refresh | OMS-owned columns are refreshed every run. A status change opens `oms_status_changed`; a warehouse other than 32 opens `warehouse_conflict`. Lines the OMS no longer returns are kept and flagged |
| Staff data | Never overwritten: destination confirmations, parcels, requirements last checked by staff, and cases that staff resolved or dismissed (the same finding is not reopened) |
| Regrouping by OMS merges | An order moves to its new container group only while its old group is in `review`/`ready` and has no parcels. An emptied old group becomes `superseded`; otherwise a `merge_inconsistent` case is opened |
| Review | New groups start in `review`. A `ready` group whose OMS data changes returns to `review`. After booking, a change only opens a case; nothing is voided |
| Shipping history | `already_shipped_suspect` opens only on a positive OMS signal: a shipment with tracking that is not cancelled, or `order_info.shipped = 1`. Missing tracking proves nothing (Amazon/Wayfair rows never carry it), so the queue shows `prior_label_check = not_established` |
| Historical exports | `hist_*` tables and `exports/` are not read; the queue (`v_review_queue`) never includes them |
| No booking | No `booking_attempt` is created and no provider is called. `routing_verified` and `provider_account` stay unmet |

**Review reasons.** Missing data becomes a `shipment_requirement`:

- `destination_country`, `ship_to_address`, `ship_to_state`, `ship_to_phone`, `customs_declaration` (Canada, or destination unknown);
- `routing_verified` and `provider_account`;
- `parcel_measurements` and `parcel_contents`, which are created once and then left to staff.

Decisions become a `review_case`:

- `cancellation`: an eBay `CancelRequested` status, or a cancellation request not rejected;
- `booking_flag_conflict`: any "Book from …" flag other than *Book from US*;
- `combo_mismatch`: `combo_count > 1` with a different number of component rows;
- `sku_missing`: blank `real_sku`;
- `already_shipped_suspect`, `oms_status_changed`, `warehouse_conflict`, `merge_inconsistent`;
- `scope` and `destination_conflict`, once a destination exists.

**Combo rule.** `0003` compared component rows with `combo_count` on every line. The first live dry run flagged 8 of 18 lines, because in `ledsone` lines with `combo_count = 1` normally carry several component rows (1,202 of 2,334 US1 lines in 180 days). `0004` limits the check to `combo_count > 1`; 25 of 808 such lines in 180 days are mismatched. `0003` was replaced before any import, so no case was ever opened under the old rule.

**First live import (2026-10-23, sync run 3).**

- 15 groups, 15 orders, 18 lines, 25 ordered units and 54 combo component rows.
- Groups: Amazon 12 → `amazon_seller_central`, eBay 1 and Shopify 1 → `shippo`, Wayfair 1 → `wayfair_partner`. None are merged. All 15 are in `review`.
- Every order's scope is `undetermined`: raw country ids 8 ×14 and 359 ×1, with no mapping and no confirmation.
- Unmet for all 15: `destination_country`, `customs_declaration`, `routing_verified`, `provider_account`, `parcel_measurements`, `parcel_contents`. Also unmet: `ship_to_state` on 1 order and `ship_to_phone` on 1.
- Cases: `already_shipped_suspect` ×2 (both from `order_info.shipped = 1` with no shipment row) and `combo_mismatch` ×1.
- 0 booking attempts, shipments, labels, prints or parcels.
- The line fingerprint (id, raw quantity, SKU) in `us_booking` equals the same fingerprint computed in `ledsone`.
- A repeat dry run found 0 new and 0 changed orders and opened no cases.

**Revalidation (`0005`).** Staff input never keeps an outdated approval:

- a destination confirmation is revoked (kept as history, with a reason) when the OMS ship-to changes;
- a staff-checked requirement is kept only while the data it was checked against is unchanged; otherwise it is reset and the old staff values are logged in `event_log`;
- an unchanged finding that staff resolved stays resolved;
- a finding whose condition disappears is marked cleared, and if it recurs, a new case links to the earlier one;
- `--limit=0` refreshes imported groups without importing new ones.

**Tests.** `bash db/tests/run_sync_tests.sh <empty scratch folder>` runs 127 checks against a synthetic `ledsone` in a disposable cluster, through the real `db-migrate` and `oms-sync` commands. It covers:

- dry run;
- the limit;
- repeated syncs;
- complete merge groups;
- quantity and pack preservation;
- verified (8, 359), missing and unmapped country ids;
- staff-data preservation;
- status, warehouse and line changes;
- regrouping and refused regrouping;
- that the OMS data is unchanged;
- a failed `--apply` that stays in sync history.

## 3c. Review dashboard (web UI)

```
npm run build                 # production build (also type-checks)
npm run start                 # http://127.0.0.1:3100  (npm run dev for development)
npm run typecheck
```

Stack: Next.js 16 (App Router) + TypeScript, Tailwind CSS 4, shadcn/ui components on Radix (`src/client/components/ui`), Motion, Lucide, TanStack Table and Query, flag-icons, and React Hook Form + Zod for the editable forms. Versions are pinned exactly in `package.json`, and `package-lock.json` is kept. `next` is on the 16.4.2 security patch (16.4.0 had three critical advisories).

| Path | What |
|---|---|
| `src/app/` | Pages (`/review`, `/sync-history`, `/settings`, `/settings/package-profiles`) and API routes (`/api/queue`, `/api/groups/[id]`, `/api/sync`, `/api/status`, `/api/package-profiles`, `/api/actions/[name]`) |
| `src/server/` | Server-only: `db.ts` (psql runner, read-only sessions, staff-action runner, error redaction), `queries.ts` (read models), `sync-job.ts` (explicit sync), `request.ts` (same-origin checks) |
| `src/client/` | UI components and display rules (`lib/domain.ts`) |
| `src/shared/` | API response types (`types.ts`) and staff-action request schemas (`actions.ts`, Zod) |

Behaviour:

- **Data.** It reads only `varmen_db.us_booking`, server-side, in read-only sessions. Connection strings never reach the browser; error text has the host and password removed. Page loads never import from the OMS. The Settings page checks OMS connectivity with a read-only identity query.
- **Sync Orders** runs the existing `scripts/oms-sync.mjs --apply` (at most 20 new groups) as a child process. It shows only the stages the command prints, never a percentage.
  - Duplicate prevention works at three levels: the button is disabled while a sync runs; the server refuses a second start with 409; and the database refuses a concurrent import (row lock with `NOWAIT`).
  - Sync is disabled, with the reason shown, when either database is unavailable.
- **Destinations.** A flag is shown only for a verified country mapping (8 → US, 359 → CA) or a valid, evidenced per-order confirmation. Everything else shows a globe and "Country not confirmed"; nothing is inferred from raw country ids, the US1 warehouse or the marketplace. A group shows a flag only when every order in it is confirmed.
- **Customs** is evaluated from the current confirmed destination: awaiting destination, not required (US), or required (Canada).
- **Ordered items vs parcels.** Ordered items (from the OMS), pack-component reference rows and confirmed parcel contents are shown separately.
- **Shipment evidence.** Missing tracking is shown as "Prior label: not established", never as proof that an order is unbooked.
- **Time.** Sync times are shown in the viewer's time zone with its name. OMS order dates are shown as recorded, labelled as having an unverified time zone.
- **Failure states.** If a refresh fails, the last good data stays on screen with a "Showing earlier data" banner. If nothing has loaded yet, an error panel with a retry button is shown. Synthetic data is never substituted.
- **Ship-to addresses** are hidden in the order drawer until staff choose "Show ship-to address".
- **Staff actions:** parcel preparation, destination exceptions and finding decisions (§3d). None of them makes an order eligible for purchase on its own: routes and provider accounts are still unverified.
- **Not available yet:** purchase and print. `ENABLE_LIVE_BOOKING` stays `false`.

Test instances: setting `USB_ENV_FILE=<env file>` before `npm run start` points a separate instance at a disposable setup, such as the synthetic cluster used by the sync tests. Such an instance shows a "Synthetic test data" banner on every page.

Checked on 2026-10-23:

- type check and production build are clean;
- API and screen counts equal the database: 15 groups, 15 orders, 18 lines, 25 units, 54 component rows, 0 confirmed destinations;
- 0 flags on live rows;
- merged groups are not duplicated (synthetic: 7 groups, 11 orders, 3 merged);
- no page-level horizontal scroll at 1440, 820 and 390 px;
- automated text contrast at ≥ 4.5:1 on every page, with no failures;
- keyboard: logical Tab order with visible focus; the drawer opens with Enter, traps focus, closes with Escape and returns focus to its button;
- reduced motion: spinner and skeleton animations reduced to ~0 ms;
- concurrent sync POSTs give 202 + 409, and only one run is recorded;
- a held database lock makes the sync fail cleanly with nothing written;
- with the database unreachable, the API returns 503 with the host hidden and Sync is disabled.

## 3d. Country mapping, package profiles, parcels and review actions (0006–0008)

**Verified country mapping (`0006`).** `country_map` holds two verified rows: OMS `country_id` 8 → United States (US) and 359 → Canada (CA). The evidence is recorded as "OMS developer confirmation reported by project owner on 2026-10-23.", with `verified_by` "project owner". This project did not verify it independently.

- The OMS column is an integer, so "08" and 8 are the same value; the sync casts the snapshot value to integer.
- Orders with these ids resolve automatically and need no per-order confirmation.
- Any other id, a missing id, or a staff confirmation that disagrees with the map stays in review.
- Applying the map changed no OMS data. Existing orders were recomputed with `npm run sync:oms -- --apply --limit=0` (refresh only, no new orders).

**Package profiles (`0007`).** Settings → Package Profiles (`/settings/package-profiles`).

- A profile has a name and immutable versions. Each version holds:
  - length, width and height with their unit (in/cm);
  - optionally, the **total packed shipment weight** with its unit;
  - optionally, the **empty packaging weight** with its unit (reference only, never used as a shipment weight).
- Units are stored as entered and never converted.
- Editing a profile adds a version. A stale edit (someone saved meanwhile) is refused.
- Defaults are assigned per route:
  - US1 Shippo (Shopify/eBay) → **US1 Shippo Default**: 9 × 6 × 6 in, 2 kg;
  - US1 Amazon → **US1 Amazon Default**: 9 × 6 × 6 in, 2 lb.
- Both were configured on 2026-10-23 through the app with the project owner's confirmed values. Wayfair has no default.

**Parcels.** In the order drawer, "Parcel preparation":

- shows ordered, allocated and remaining units per line, including the lines of merged orders;
- **Creating a draft parcel** copies the route's default dimensions and packed weight, and records the profile id and version. The copied values are marked "Default profile"; `measured_by`/`measured_at` stay empty, because nobody measured them.
- **Overrides.** Staff change values only when the package differs. A changed part becomes "Custom", with their name and time. "Use default …" returns to the parcel's own recorded profile version, never a newer one, so later profile edits never change existing parcels.
- **Contents** are never confirmed by a profile. For a single parcel, the remaining ordered items are proposed and staff confirm them in one step. "Add another parcel (split)" and "Choose items" allocate quantities per line.
- **Database rules:**
  - `parcel_provenance` refuses profile-labelled values that differ from the recorded version;
  - check constraints require a unit and a source for every value;
  - the existing allocation trigger refuses over-allocation;
  - the existing lock freezes a parcel with a pending, unknown or active purchase or label.
- **Booking precondition.** It now accepts profile-sourced or staff-entered measurements (each needs a value, a unit and a source). Contents must still be staff-confirmed.

**Review actions (`0008`).** Each one is a database function called through `POST /api/actions/<name>`:

- confirm a destination, only for unresolved orders (exceptions), with evidence;
- revoke a confirmation;
- resolve or dismiss a finding, with evidence.

How they work:

- **Identity.** Staff enter their name once (remembered in the browser; there is no sign-in yet). It is recorded with each action.
- **Stale-edit protection.** Every action sends the version it was shown (the ship-to hash, the finding's details hash, or the parcel's row version), and stale requests are refused with 409.
- **Scope.** Closing a finding changes only that finding. Address-change revocation and recurring-finding detection (0005) are unchanged.
- **Request checks.** The server accepts actions only as same-origin JSON requests.

**Failed syncs.** `oms-sync --apply` records a failure with `sync_record_failure()` in a separate transaction, so Sync History keeps it. Host names and credentials are removed from the stored message.

**Tests.** The synthetic suites cover:

- automatic mapping (including "08"), unknown and missing ids;
- profile prefill in kg and lb, manual overrides, profile version changes;
- allocation, split and merged parcels;
- booking locks and stale edits;
- case resolution;
- a real failed `--apply` (local suite: 186 checks; sync suite: 121 checks).

**Parcel contents after OMS changes (`0009`).**

- **What is recorded.** A contents confirmation stores its basis (`parcel.contents_basis`): the group's order membership plus, for each packed line, the ordered quantity, SKU identity and OMS presence.
- **What the sync does.** In its own transaction it marks lines the OMS no longer returns (`oms_order_item.oms_absent_since`) and compares every confirmed parcel with its basis:
  - an unlocked parcel becomes `stale` and gets an open `parcel_contents_discrepancy` that keeps the earlier confirmation and lists the changes;
  - a parcel locked by a purchase or label is left untouched, and its discrepancy blocks further purchasing until staff acknowledge it with evidence.
- **What it never does.** Nothing is redistributed, reduced or confirmed automatically, and an unchanged sync changes nothing.
- **Readiness checks.** Readiness (the `parcel_contents` requirement) and the booking precondition are recomputed per line in the database. Closing a review case does not make stale contents valid.
- **Stale edits.** A staff edit that overlaps a sync waits for it, then is refused as stale.

## 3e. Wayfair sandbox (Settings → Wayfair Sandbox)

The OMS stays the only source of orders; nothing imports Wayfair orders. This page is for checking the Wayfair account and the shipment registration and label workflow in Wayfair's SANDBOX.

**Configuration** (`.env`, server-only; see `.env.example`):

| Key | Meaning |
|---|---|
| `WAYFAIR_MODE` | must be `sandbox`; any other value disables the integration |
| `WAYFAIR_SANDBOX_CLIENT_ID`, `WAYFAIR_SANDBOX_CLIENT_SECRET` | the sandbox application's keys |
| `WAYFAIR_SUPPLIER_ID` | our Wayfair supplier id; sandbox POs from any other supplier are refused, and registration is refused while it is empty |
| `WAYFAIR_WAREHOUSE_ID` | optional Wayfair warehouse id (not the OMS warehouse 32); empty = Wayfair uses the PO's warehouse |
| `WAYFAIR_ORDER_IMPORT_ENABLED` | must stay `false` |

**Endpoints** are fixed in `src/server/wayfair/config.ts` from Wayfair's developer documentation, read on 2026-10-23. There are no production constants and no fallback.

- token: `POST https://sso.auth.wayfair.com/oauth/token` with `grant_type=client_credentials` and the sandbox audience `https://sandbox.api.wayfair.com/`;
- GraphQL: `https://sandbox.api.wayfair.com/v1/graphql`;
- label: `GET https://sandbox.api.wayfair.com/v1/shipping_label/<PO>`.

Tokens last 24 hours. The app renews a token after 12 hours, when it is about to expire, or after a 401.

**What each button does.** Every button is one explicit call:

- *Test authentication* requests a token.
- *Look up sandbox orders* runs `getDropshipPurchaseOrders`, at most 10 orders, requesting only PO numbers, dates, supplier ids and part numbers. It shows whether the supplier matches. A PO that also exists in the OMS (same reference, or the reference plus a suffix such as `-zen`) is flagged and never linked.
- *Check registration at Wayfair* runs `labelGenerationEvents`, filtered on the PO's nine digits as Wayfair requires.
- *Register in sandbox* runs the `register` mutation, optionally with explicitly entered test measurements in cm and kg (the documented units).
- *Fetch sandbox label* stores the file under `LABEL_STORAGE_DIR/wayfair-sandbox/` with a `SANDBOX-` file name, and offers preview and download.

**Protections (migration `0010`).**

- Sandbox registrations and labels are kept in their own tables, with no link to live parcels, booking attempts or readiness.
- A PO with a requested, succeeded, unknown or found-existing record is never registered again.
- The record is committed before the call. A call without a definite answer (timeout, HTTP 5xx) becomes "outcome unknown" and is never repeated automatically; staff record the real outcome with evidence.
- Sandbox success never marks the live Wayfair route verified.

**Tests.**

- `db/tests/tests_wayfair_sandbox.sql` is part of the local suite (247 checks).
- `tests/wayfair/mock-server.mjs` with `tests/wayfair/run-mock-tests.mjs` runs 33 API checks against a synthetic instance: credentials, expiry, revocation, wrong account, empty and failed order access, GraphQL errors, HTTP 500, timeout, repeats, labels, and leak checks.

## 3f. Wayfair-managed packaging (`0011`)

The warehouse team doesn't measure Wayfair orders: when `packageUnits` is omitted, Wayfair generates the label from package data it already holds. Staff print the label Wayfair supplies. **Where that data comes from is not verified** (see the correction below); earlier drafts of this page called it "the product listings" as if that were settled. It isn't.

**Documentation basis.** Wayfair's Registration & Shipping API guide says:

- `packageUnits` is optional;
- `packageUnits` is meant for consolidation ("if you pack multiple items/quantities into fewer boxes");
- `warehouseId` defaults to the PO's warehouse;
- `shipping_label` returns all labels of a PO.

**Sandbox evidence.** The first sandbox registration sent no `packageUnits` and succeeded. **Not verified:** which package data production uses when `packageUnits` is omitted. The documentation doesn't say.

**Correction to the production-test plan (2026-10-23), recorded before any production test is run.** Two points in the plan implied by this section needed fixing. Nothing below changes any code or data; `WAYFAIR_MODE` stays sandbox-only and no production call exists anywhere in this app. Full record: `docs/phase1/2026-10-23_wayfair_production_test_plan_correction.md`.

1. **Authorisation must not be circular.** `provider_packaging_policy.production_verified_at` (set only by a controlled production test, enforced by the booking precondition in `0011`) is the *outcome* of that test. The authorisation to *run* the test cannot be made to depend on that same outcome, or on any other evidence that can only exist after the test has already happened. The test needs its own, separate, narrowly scoped sign-off: one named purchase order, the production registration/label endpoints only, nothing broader. Until that specific authorisation is given, no production call is made.
2. **A production test verifies the operational result, not where the data came from.** The test is: register that one PO in production, then match the returned label(s) against the physical carton(s) actually packed for it (right count, right carton, correct destination). Passing that check shows the label-to-carton match works. It does not show, and this document must not claim, that the package dimensions and weight Wayfair used came from "the product listing" rather than a stored default, a warehouse assignment, or something else Wayfair holds. That provenance stays unverified regardless of how the operational test goes.

**How the app handles Wayfair parcels:**

- **The record.** A parcel on a Wayfair-routed group starts in `provider_managed` mode. It holds no measurements at all (no zeros, profile values or label-derived values), and the screen shows "Package details not returned to this app". It is one record for the purchase order, not a carton.
- **Readiness.** The measurement requirement is met by the mode for a group with exactly one order. A merged Wayfair group (several POs) needs a staff decision.
- **Packaging exception** (consolidated or custom packaging). It needs a reason, then measurements in cm and kg, the units Wayfair documents for `packageUnits`. Staff can return the parcel to Wayfair-managed mode; the cleared values stay in `event_log`.
- **Booking check.** It accepts `provider_managed` only for Wayfair, only for one-order groups, and only after `provider_packaging_policy.production_verified_at` is set by a controlled production test authorised as above. Until then, Wayfair-managed parcels cannot be booked.
- **Other providers.** Shippo and Amazon (profiles, prefill and measurement checks) are unchanged. `provider_managed` is refused for them.
- **Sandbox page.** Registration omits `packageUnits` unless a packaging exception is chosen. Stored labels are reused for preview, download and reprint, with no Wayfair call and no new registration.

Tests: local suite 270 checks (`tests_packaging.sql`), Wayfair mock suite 33 checks.

## 3g. Shippo TEST rate shopping and label purchase (Settings → Shippo Test)

The OMS stays the only source of orders; nothing here imports Shopify/eBay orders or updates any
marketplace fulfilment. This page requests TEST-mode rates and buys TEST-mode labels against
Shippo's real API (or a local mock for automated tests), for a synthetic shipment only. It never
touches a live `fulfilment_group`, `parcel`, `booking_attempt` or `provider_shipment`.

**Configuration** (`.env`, server-only; see `.env.example`):

| Key | Meaning |
|---|---|
| `SHIPPO_MODE` | must be `test`; any other value disables the page |
| `SHIPPO_API_TOKEN` | must start with `shippo_test_` (Shippo's documented test-token prefix); a token that looks like a live token (`shippo_live_...`) is refused before any call |
| `SHIPPO_SHIP_FROM_*` | this warehouse's ship-from address (name, company, street1, street2, city, state, zip, country, phone, email). **Required**; rate shopping is refused while any required field is missing. Never guessed from `hist_shippo_label` or any other historical data |
| `SHIPPO_SHIP_RETURN_*` | **Optional**, same shape as `SHIPPO_SHIP_FROM_*`. This Shippo account has a different default sender and return address; Shippo's documentation does not say what address a return label uses when `address_return` is omitted (not "defaults to the ship-from address", not "uses the dashboard return address" — undocumented either way). So this app sends `address_return` only when this is explicitly set, and the status card reports "not configured" rather than assuming either default. Setting only some of the fields is treated as a configuration error (complete it or clear it entirely) |

**Endpoints** are fixed in `src/server/shippo/config.ts` from Shippo's official API documentation
(docs.goshippo.com, read 2026-10-24): `POST /shipments` (rates), `POST /transactions` (label
purchase), `GET /transactions/{id}` (reconciliation), `GET /rates/{id}` (a read-only lookup used
only to recover `carrier_account` for an attempt that did not capture it), `GET /carrier_accounts`
(the authentication check: read-only, creates nothing). The `Authorization: ShippoToken <token>`
header is sent only to Shippo's own API, never to a returned label or invoice URL.

**Workflow:**

1. **Status.** Shows whether the token and ship-from address are configured, whether the token
   looks like a test token, and the result of the last "Test authentication" press (a read-only
   call; it books nothing).
2. **New test shipment.** Destination is restricted to United States or Canada, matching this
   app's scope. The recipient starts from Shippo's own documented example address (obviously
   synthetic; "Mr Hippo"), editable, and is never derived from an OMS order or a real customer. The
   parcel starts from the saved **US1 Shippo Default** profile (9 × 6 × 6 in, 2 kg) read from
   `package_profile`/`package_profile_version`; changing it here never writes to the saved profile.
   For Canada, a customs declaration is required and nothing in it is prefilled — contents type,
   certifier, and at least one item (description, weight, value, origin, HS/tariff number) must be
   entered explicitly. An optional "export compliance" group (incoterm, EEL/PFC, AES ITN, B13A
   filing) is shown with nothing pre-selected; Shippo's documentation names `NOEEI_30_36` as typical
   for most US→CA shipments, shown as a label only, not a default. "Get test rates" calls
   `POST /shipments` and stores the rates and any provider messages (`shippo_test_shipment`,
   append-only).
3. **Rate selection.** Each returned rate shows carrier, service, price, currency and delivery
   estimate (`estimated_days`, `duration_terms`) as radio choices with none pre-selected; staff
   must click one. Nothing picks the cheapest automatically.
4. **Purchase.** "Purchase TEST label" commits a `shippo_test_purchase` row in state `requested`
   *before* calling Shippo, with a correlation key sent as the transaction's `metadata`. The
   carrier, service, amount, currency and `carrier_account` of the exact rate staff selected are
   recorded on the attempt itself (not only inside `rate_summary`) regardless of outcome — this is
   Shippo's own data for that rate, never guessed from the tracking number. A unique index allows
   at most one `requested`/`unknown` purchase per test shipment at a time, **and once a shipment has
   a succeeded or staff-confirmed purchase it is done and is not purchased again** — a second click,
   a concurrent request, or a repeat attempt on a completed shipment is refused with 409 before it
   reaches Shippo; a failed or rejected attempt may still be retried. The outcome is accepted as
   `succeeded` only when Shippo's response has `status: SUCCESS` **and** `test: true`; anything else
   — `ERROR`, a transaction not marked test mode, a timeout, an HTTP 5xx, or an undocumented status
   such as `QUEUED`/`WAITING` — is recorded as `failed`, `rejected_not_test` or `unknown` and is
   **never** retried automatically. An `unknown` outcome blocks further purchases for that shipment
   until a staff member resolves it with evidence (Shippo's dashboard or support); if Shippo gave no
   transaction id, there is nothing to reconcile and the resolution says so rather than guessing.
5. **Label format.** A setting (`shippo_test_settings`, one row) holds the `label_file_type` sent
   on **future** purchases only (`PDF`, `PDF_4x6`, `PDF_A4`, …, Shippo's documented
   `LabelFileTypeEnum`); left unset, no `label_file_type` is sent at all, so Shippo applies whatever
   format its own dashboard has as the account default. This app never assumes a thermal printer or
   a paper size, and changing the setting never touches a label already stored.
6. **Label and customs invoice.** "Fetch and store TEST label" downloads the original file Shippo
   returned (via its `label_url`, or by re-checking `GET /transactions/{id}` first for a
   resolved-but-unknown purchase) and stores it under `LABEL_STORAGE_DIR/shippo-test/` with its
   SHA-256 (`shippo_test_label`, `kind = 'label'`, append-only). If Shippo also returned a
   `commercial_invoice_url` (seen for international TEST transactions), it is stored alongside the
   label as a second row (`kind = 'customs_invoice'`), with its own preview/download line. A second
   fetch for the same purchase, and every preview/download/reprint afterwards, reuses whichever file
   is already stored per kind: zero further calls to Shippo, and never a second purchase.
7. **Recovering missing details.** A purchase made before `carrier_account` was captured (or one
   whose rate omitted it) shows "Recover details"; it fills only columns that are still `NULL` and
   only for a purchase that has already completed, preferring the attempt's own saved `rate_summary`
   and falling back to a read-only `GET /rates/{id}` lookup by the purchase's own saved
   `rate_object_id`. It never overwrites a value already recorded and never guesses from the
   tracking number; if Shippo no longer has the rate on record (rates expire), it says so plainly.

**Isolation.** `shippo_test_shipment`, `shippo_test_purchase`, `shippo_test_label` and
`shippo_test_settings` have no foreign key to, and are read by no view or function of, the live
booking tables. Live totals (`booking_attempt`, `label_file`, `parcel`) are unaffected by anything
on this page.

**Verified against the real Shippo TEST API (2026-10-24):** a real US→CA rate request (with the
customs declaration above) returned 8 real carrier rates, each with a real `carrier_account`; one
of Shippo's own validation messages for this account/route was `Attribute
"customs_declaration.incoterm" must be present` for a subset of carriers — confirming `incoterm`
matters for at least this account even though Shippo's base schema lists it as optional, and
confirming messages are shown rather than swallowed. `recover-details` was also run for real against
the attempt made from the dashboard before this fix (§ below) and filled its `carrier_account` from
a live `GET /rates/{id}` call. No real label was purchased by this process; see "One real Canada
purchase" below for the dashboard steps to do that deliberately.

**Tests.**

- `db/tests/tests_shippo_test.sql` is part of the local suite (298 checks total after `0013`).
- `tests/shippo/mock-server.mjs` with `tests/shippo/run-mock-tests.mjs` runs 63 checks against a
  synthetic instance: authentication (rejected/outage/ok), units and `carrier_account` sent/received
  exactly as entered, Canada customs (including `eel_pfc`) required before any Shippo call, an
  address-return address sent only when configured, an empty-rate answer shown with its message,
  explicit (non-cheapest) rate selection, concurrent/duplicate purchase blocking, a completed
  shipment refusing a further purchase while a failed one may retry, HTTP 500 and a timeout both
  recorded as unknown, resolution with and without a provider transaction id to reconcile against,
  a rejected (`ERROR`) and a not-test-mode transaction both kept unusable, a Canada purchase storing
  its commercial invoice alongside the label, the label-format setting applying to future purchases
  only and never altering a stored label, `recover-details` filling a missing `carrier_account` from
  a live rate lookup (and reporting plainly when the rate has expired), stored-label reuse across
  repeated preview/download/reprint, a live-looking token refused mid-session, and a leak check.

### One real Canada purchase (staff, via the dashboard)

Mocks cover the mechanics above; this is the one real TEST-mode purchase a staff member should make
through Settings → Shippo Test to confirm Canada end-to-end against the live Shippo account:

1. Click **Canada** under Destination (fills the synthetic Toronto recipient; the parcel stays the
   US1 Shippo Default 9×6×6 in, 2 kg).
2. Fill the customs section: contents type, certifying signer, at least one item (description, net
   weight, value, origin country). Given the real message seen above, also set **Incoterm** (for
   example `DDU`) — leaving it unset may cause some carriers to return a rate-level error, which is
   expected and shown, not hidden.
3. Click **Get test rates**, read any per-carrier messages shown, then pick one rate explicitly —
   not necessarily the cheapest.
4. Click **Purchase TEST label for the selected rate**. Confirm it reaches `succeeded` with
   "Shippo test mode confirmed".
5. Click **Fetch and store TEST label**. Confirm the label preview opens, and — if Shippo returned
   one for this route — a separate "Customs invoice" line appears alongside it.
6. Reload the page and confirm the shipment now shows "Completed — label purchased" with no rate
   list or purchase button; reopen the stored label from the Settings page again to confirm preview
   and download still work without creating anything new.

## 4. Schema test suite (optional)

```
bash db/tests/run_local_tests.sh <empty scratch folder outside the project>
```

The suite:

- initialises a disposable PostgreSQL cluster on port 55432 (override with `TEST_PG_PORT`) and verifies it is talking to that cluster;
- applies `db/migrations/*.sql` (twice, to prove they are idempotent), then the deferred separate-role grants;
- loads synthetic fixtures and runs the tests (298 checks, including `tests_wayfair_sandbox.sql`, `tests_packaging.sql` and `tests_shippo_test.sql`; `tests.sql`, `tests_actions.sql` for 0006–0008, `tests_contents.sql` and `concurrency_contents.sh` for 0009);
- deletes the cluster afterwards.

It never touches an existing server.

## 5. Phase 1 exports

`exports/us-booking/2026-10-22_shippo_oms_match/_source/build.py` rebuilds the match CSVs from the raw extracts:

```
python -I exports/us-booking/2026-10-22_shippo_oms_match/_source/build.py <extracts dir> <shippo csv> <output dir>
```

The extracts are in `_source/`, and the Shippo CSV is `export_user_*.csv` at the project root.
