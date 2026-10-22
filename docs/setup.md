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

## 1. Environment values

`.env` holds local values and is git-ignored. `.env.example` is the template with comments. If `.env` is missing, copy the template to create it.

| Variable | What to put there |
|---|---|
| `OMS_READ_DATABASE_URL` | OMS (ledsone mirror) connection for a **SELECT-only** role |
| `BOOKING_DATABASE_URL` | Booking database, **runtime** role (DML only) |
| `BOOKING_MIGRATION_DATABASE_URL` | Booking database, **owner/migration** role. Used only for reviewed migrations |
| `BOOKING_DATABASE_EXPECTED_NAME` | `varmen_db`. Both booking URLs must point at it |
| `SHIPPO_API_TOKEN`, `SHIPPO_MODE` | Shippo **test** token and `test`. Not needed for the database preflight |
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
```

The `db-preflight` stage requires only `BOOKING_DATABASE_URL` and `BOOKING_DATABASE_EXPECTED_NAME`. A missing OMS URL, migration URL or Shippo token shows as `not needed` and does not fail the check. Values that are supplied are still validated, including a migration URL.

The checker prints each variable name with `configured`, `missing`, `invalid`, `warning` or `ok`. It never prints values and never connects to a database.

It also checks:

- that both booking URLs name `BOOKING_DATABASE_EXPECTED_NAME`;
- that runtime and migration use separate roles;
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

### Runtime role `us_booking_app`

`varmen_user` stays the migration and schema owner. The app connects as a separate login role, `us_booking_app`. `varmen_user` has no CREATEROLE, so a database administrator must create the role with `db/admin/create_us_booking_app_role.sql` (interactive psql; the password is hashed client-side via `\password`). The script grants only CONNECT on `varmen_db` and changes no shared grants. Rights inside `us_booking` come from migration `0002`.

Read-only checks, runnable as `varmen_user`:

```
npm run db:preflight -- --check=us_booking_app_role   # attributes, memberships, reachable databases/schemas/tables
npm run db:preflight -- --check=public_exposure       # what any new role inherits through PUBLIC
```

PUBLIC findings (2026-10-22):

- PUBLIC has CONNECT on `accounts_management`, `digitweb_tracker` and `postgres`, but not on `varmen_db`, `ledsone` or `ph_dashboard`. PUBLIC has TEMP on all of them.
- In `varmen_db`, PUBLIC can use only the `public` schema (no CREATE).
- No tables, columns, sequences, large objects or default privileges are granted to PUBLIC.
- The 6 PUBLIC-executable functions are in schemas PUBLIC cannot use.

To keep `us_booking_app` out of the three PUBLIC-connectable databases without changing shared grants, the administrator can add a per-role `pg_hba.conf` rule (see the end of the admin script). The contents of those three databases were not inspected.

## 4. Schema test suite (optional)

```
bash db/tests/run_local_tests.sh <empty scratch folder outside the project>
```

The suite:

- initialises a disposable PostgreSQL cluster on port 55432 (override with `TEST_PG_PORT`) and verifies it is talking to that cluster;
- loads synthetic fixtures and runs the tests;
- deletes the cluster afterwards.

It never touches an existing server.

## 5. Phase 1 exports

`exports/us-booking/2026-10-22_shippo_oms_match/_source/build.py` rebuilds the match CSVs from the raw extracts:

```
python -I exports/us-booking/2026-10-22_shippo_oms_match/_source/build.py <extracts dir> <shippo csv> <output dir>
```

The extracts are in `_source/`, and the Shippo CSV is `export_user_*.csv` at the project root.
