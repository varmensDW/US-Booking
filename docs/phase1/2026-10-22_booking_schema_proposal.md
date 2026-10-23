# US Booking Automation, Phase 1: booking schema proposal and live-source verification

**Revision 2, 2026-10-22.** Private operational document. It contains aggregate counts only: no customer names, addresses, phone numbers or emails.

**Agreed scope**

- US1 warehouse fulfilment to the **US and Canada**.
- Booking and label printing only. The OMS stays read-only.
- Routing:
  - Shopify and eBay → Shippo
  - Amazon → Seller Central
  - Wayfair → Wayfair's own account
- Staff confirm package dimensions, weight and contents.

**Files**

| File | What |
|---|---|
| `db/proposed/0001_us_booking_init.sql` (now `db/migrations/0001_us_booking_init.sql`) | Proposed schema (tables, views, integrity triggers). Not applied at the time of this document. **Update 2026-10-23:** applied to `varmen_db.us_booking`; see `docs/setup.md` |
| `db/proposed/0002_us_booking_grants.sql` | Proposed runtime-role privileges, table by table. **Update 2026-10-23:** not applied, because the approved setup uses a single role |
| `db/checks/booking_db_preflight.sql` | Read-only catalog checks for the target in `BOOKING_DATABASE_URL` |
| `db/tests/run_local_tests.sh`, `concurrency.sh`, `fixtures.sql`, `test_support.sql`, `tests.sql` | Disposable-cluster test suite with synthetic data |
| `exports/us-booking/2026-10-22_shippo_oms_match/` | Phase 1 history exports (unchanged) |

No migration was run on any existing database. No label was purchased or printed, and the OMS was not modified. All OMS access was SELECT through the LEDSone MCP (`dbhub_readonly`).

---

## 1. Verdict

| Area | Status |
|---|---|
| Orders, lines, ordered SKU and quantity, merges, OMS status, US1 warehouse | **Available** in the OMS mirror |
| Full shipping address | **Mostly available.** State (`region`) is blank on 15% of recent US1 orders. This is tracked as a shipment requirement |
| Destination country | **No global mapping.** `country_id` has no lookup table. Revision 2 adds an **evidenced, staff-confirmed destination per order** as a stop-gap |
| Cancellation signal before shipping | **eBay only.** For Amazon, Shopify and Wayfair the only signal is `orders.status` |
| Hold signal | `orders.status = 'Hold'` only, with no reason field |
| Existing shipment records | **Partial.** Amazon and Wayfair US1 shipment rows never get tracking |
| Writable booking database | **Not configured.** `BOOKING_DATABASE_URL` is unset in the process, user and machine environment, so the preflight was not run |
| Schema integrity rules | **Validated locally:** 95/95 checks pass on a disposable PostgreSQL 18.6 cluster (§12) |

---

## 2. Existing project, stack and conventions

- **This folder** has the Phase 1 exports and a standard-library Python export script. It has no application code, no git repository and no `.env` file.
- **`OMS_READ_DATABASE_URL` and `BOOKING_DATABASE_URL` are both unset** (checked in the process, user and machine scopes; names only, no values).
- **The nearest app is `F:\Projects\ledsone-vendor-booking`**: Node ≥ 22, `pg` 8.23, numbered SQL migrations, and `scripts/db/migrate.mjs`. Its migrator uses:
  - one app-owned schema;
  - idempotent, schema-qualified statements;
  - an expected-database-name guard;
  - a CREATE-privilege check.

  The proposal copies these conventions, using schema `us_booking`.
- **Migrator compatibility:** the vendor-booking scope check rejects any DDL statement that does not contain `<schema>.`. Two statement types in `0002` would fail it: `GRANT USAGE ON SCHEMA us_booking` and `REVOKE ALL ON SCHEMA us_booking`. A port of that migrator needs an allowance for `ON SCHEMA us_booking`. Its naive `;` split would also cut through plpgsql bodies in `0001` (harmless for its check, but worth knowing).

---

## 3. Live-order source verification (OMS mirror, read-only)

**Timestamps.** The newest `order_date` (05:22) was later than the server's UTC `now()` (04:41). This **suggests** a zone ahead of UTC, such as UK BST, but it is not independent verification. **Revision 2 stores OMS timestamps raw** (`order_date_raw timestamp`) and converts nothing.

**Population.** US1 (`orders.warehouse_id = 32`) orders from the last 90 days: 1,474. By status: Completed 1,375, Refunded 58, Inprogress 18, Cancelled 16, New 6, Deleted 1.

| Requirement | Source | Finding | Status |
|---|---|---|---|
| Order header | `order_management.orders` | `id`, `order_id` (platform ref), `status`, `order_date`, `warehouse_id`, `merge`, `sub_source_id`, `market_place` | ✅ |
| Channel / account | `sub_source.name`, `source.source_name` | Amazon *Neighbour Market* (239) and *amazon Ledsone* (8); Wayfair *NeighbourmarketInc* (258); eBay *electricalsone* (22), *led_sone* (1), *neighbourmarket* (238) and *so_926407* (4); Shopify *ledsone-us* (245) and *electricalsoneuk* (112, 1 order) | ✅ |
| Ship-to name, line 1, city, postcode | `customers.shipping_address` | 1,474 / 1,474 populated. 1,469 postcodes have the US ZIP shape | ✅ |
| Ship-to line 2 / 3, company | same | Optional. Line 2 present on 90 orders | ✅ |
| **Ship-to state** | `shipping_address.region` | **Blank on 220 / 1,474 (15%)** | ⚠ Requirement `ship_to_state` |
| Phone | `shipping_address.phone` | 1,427 / 1,474 | ⚠ Requirement `ship_to_phone` where the carrier needs it |
| Email | `customers.customer_info` | Row present for 1,474 / 1,474 (values not inspected) | ✅ |
| **Destination country** | `shipping_address.country_id` | **No lookup table** in `ledsone`. Values on US1 orders: 8 (1,448), 359 (16), 12 (5), 197 (4), 289 (1). **Not interpreted.** `orders.market_place` is the selling site, not the destination | ❌ Global mapping unavailable. Per-order confirmation in revision 2 |
| US1 warehouse | `orders.warehouse_id` → `inventory.warehouse` (32 = US1) | Present on every order | ✅ |
| Booking-origin cross-check | `order_flag` + `flag` (`flag_group = 3`) | *Book from US* on 1,473 / 1,474. **1 US1 order is flagged *Book from UK*** | ✅ Mismatch → `booking_flag_conflict` review |
| Current status | `orders.status` | Vocabulary: Completed, Refunded, Cancelled, Inprogress, Hold, New, Deleted | ✅ |
| Released to warehouse | `booking_info` | Every Inprogress US1 order has a row; New orders have none | ✅ |
| Hold | `orders.status = 'Hold'` | 36 orders (all warehouses, last 365 days), 0 on US1 now. No reason field | ⚠ Status only |
| Cancellation (eBay) | `order_info.ebay_cancel_status`, `customer_service.ebay_order_cancellations` | Cancellations table is live (newest row today) | ✅ eBay only |
| Cancellation (Amazon, Shopify, Wayfair) | — | No pre-ship cancellation-request table | ❌ Beyond status |
| Merges | `orders.merge`; `order_item_info.order_id` / `order_ref_id` | 180 days of US1: 12 parents, 15 children, 64 `multi_line` flags. Parents all resolve, with the same warehouse and status | ✅ |
| Order lines | `order_item_info` | 2,321 lines. Quantities are varchar but always integer; `line_item_id` is never blank; `real_sku` is blank on 2 lines | ✅ |
| Pack / combo | `combo_count`, `order_combo` | 798 combo lines. 21 lines where the component row count ≠ `combo_count` | ⚠ `combo_mismatch` review |
| Existing shipments, eBay/Shopify | `order_management.shipment` | Completed rows carry tracking. `label_path` is almost never set | ✅ Usable as an "already shipped" signal |
| **Existing shipments, Amazon/Wayfair** | same | Rows stay `New` with no tracking, label or ref | ❌ Not an "already labelled" signal |
| Open-order state | `shipment`, `order_info.shipped/shipped_error` | 24 open US1 orders, 0 shipment rows. 16 carry `shipped_error` ("Shipment not created." ×14, "Can not shipped this order (WAYFAIR)." ×2). 2 have `shipped = 1` with no shipment row | ⚠ Meaning unconfirmed |
| Carrier integration in OMS | `carrier_service.integrated` | No US service is integrated. Some US1 orders have cancelled *Trossingen schmutter Stamp* shipments | ⚠ `warehouse_conflict` signal |
| Replacement / resend orders | `source` 9, 10, 11, 13 | Not in the mirror | ❌ → `scope` review |

---

## 4. Intended writable database: identity and permissions

`BOOKING_DATABASE_URL` is **not configured**, so the read-only preflight was **not run** and no target was inspected or changed. **No target is assumed:** this revision does not presume `varmen_db`, a new production database, or any other database. When the URL is set, run:

```
psql "$BOOKING_DATABASE_URL" -v ON_ERROR_STOP=1 -c 'BEGIN READ ONLY' -f db/checks/booking_db_preflight.sql -c 'ROLLBACK'
```

It reports:

- identity (database, role, server, version);
- whether the target is the OMS mirror (it must not be);
- role attributes;
- schema/table creation rights, kept separate from data-write rights;
- any existing `us_booking` objects;
- default privileges;
- any other schema where the role could create objects.

**What the MCP showed about the VPS cluster** (from the first revision; still accurate):

- `ledsone` is writable only by the superuser `postgres`.
- Database-level CREATE is held only by `postgres` and by each database's owner role.

**Privilege model that the target must support** (implemented in `0002` and tested):

| Need | Privilege | Role |
|---|---|---|
| Create the schema, tables, functions and triggers | CREATE on the database or schema. **Ownership** of the objects (`ALTER` needs it) | `us_booking_owner` (migrations only) |
| Read and write queue data | Per-table `SELECT/INSERT/UPDATE`; `DELETE` on `parcel_item` only; sequence `USAGE` | `us_booking_app` (runtime) |
| Audit log | `SELECT, INSERT` only. **No UPDATE, DELETE or TRUNCATE** | runtime |
| Allocation counter, country map, routing rules | `SELECT` only. Writes go through owner-defined triggers or owner maintenance | runtime |

---

## 5. Revision 2 corrections

| # | Correction | How it is implemented | Tested |
|---|---|---|---|
| 1 | Canada in scope; requirements separate from scope | `v_order_scope`: warehouse 32 and destination US/CA → `in_scope`; otherwise `out_of_scope` or `undetermined`. Missing data goes in **`shipment_requirement`** (`destination_country`, `ship_to_address`, `ship_to_state`, `ship_to_phone`, `parcel_measurements`, `parcel_contents`, `customs_declaration`, `routing_verified`, `provider_account`), and `review_case` no longer carries `address_incomplete` | T7, T9 |
| 2 | Raw OMS timestamps | `order_date_raw timestamp`. The generated Europe/London column is removed. The hist import keeps `shippo_created_at_raw` as text | T8 |
| 3 | Replacement-label lifecycle | A successful attempt is never rewritten. It is **released** (`released_at/by/reason`) only when its label is `voided` with `void_confirmed_at` and `void_evidence`. The blocking index covers `created`, `request_sent`, `unknown` and **unreleased** `succeeded`/`reconciled_found`. A replacement needs the next consecutive generation, `replaces_attempt_id` = the latest successful attempt, and `authorised_by`. Labels must go `active → void_requested → voided`; `voided` is terminal | T1, T2 |
| 4 | Cross-table consistency | Composite FKs: attempt (parcel, group) → parcel; attempt (group, provider, account) → group; shipment (attempt, parcel, provider, account) → attempt; parcel_item (parcel, group) → parcel, (item, order) → order_item, (group, order) → membership. A trigger rejects inactive memberships. Deferred constraint triggers: a successful attempt must have a label row, and a label row must belong to a successful attempt | T3 |
| 5 | Measurements and allocation | `CHECK (x > 0)` on length, width, height and weight; NULL means not measured yet. An attempt requires all four plus `measured_by`, confirmed contents and at least one item. Measurements and contents are frozen while a purchase is pending, unknown or live. Allocation goes through a per-line counter row (`item_allocation`) updated by a SECURITY DEFINER trigger, so concurrent writers serialise. Cancelling a parcel releases its units | T4, T5 |
| 6 | Append-only `event_log` | No UPDATE, DELETE or TRUNCATE grant (grants are per table, with no `ON ALL TABLES`). A row trigger and a TRUNCATE trigger reject the operation **even for the owner** | T0, T6 |
| 7 | Per-order destination | `order_destination_confirmation`: ISO2 code, evidence type and reference (required), confirmer, the raw `country_id` seen, and the **ship-to hash** it was made against. One active row per order. It goes stale automatically when the address changes. It never writes `country_map`, which the runtime role cannot write at all. If a verified map row disagrees with the confirmation, the result is `conflict` with no destination | T7 |
| 8 | Metadata = correlation, not idempotency | `idempotency_key` is renamed `correlation_key`. Duplicate prevention is local: the unique index plus a `FOR UPDATE` lock on parcel and group. `unknown` can leave only to `reconciled_found` or `reconciled_not_found`, and only with `resolution_evidence`, `resolved_by` and `resolved_at`. It can never become `failed`, and it cannot be released. After sending, `failed` requires `responded_at` | T1 |

Also gated at attempt time:

- every active order in the group is `in_scope`;
- every order is routed to the group's provider with `integration_status = 'verified'`;
- there are no unmet requirements and no open review cases;
- the group is `ready` or `booking`.

Further rules:

- Printing is allowed only for `active` labels.
- A reprint needs a reason and a unique `client_request_id`, and never touches booking attempts.

---

## 6. Proposed schema (`us_booking`), revision 2

| Group | Objects |
|---|---|
| Reference (owner-maintained) | `country_map` (empty; verified rows need ISO2, evidence, verifier and timestamp), `routing_rule`, `package_profile` (staff-created; approval needs approver and timestamp) |
| OMS snapshot | `oms_order` (raw timestamps, raw `country_id`, `ship_address_hash`), `oms_order_item` (ordered SKU and quantity preserved), `oms_order_item_component` (reference only) |
| Destination | `order_destination_confirmation`; views `v_order_destination` and `v_order_scope` |
| Queue | `fulfilment_group`, `fulfilment_group_order` (one active group per order), `shipment_requirement`, `parcel`, `parcel_item`, `item_allocation` (trigger-maintained) |
| Booking | `booking_attempt`, `provider_shipment`, `label_file`, `print_event` |
| Control | `review_case`, `event_log` (append-only), `sync_state`, `sync_run` |
| History | `hist_import_batch`, `hist_shippo_label`, `hist_oms_order_item` (no FKs into the live queue) |

Pack/combo SKUs and ordered quantities are stored exactly as ordered. Parcel contents exist only as staff-entered `parcel_item` rows. Nothing is inferred from Shippo history, and no package profile is approved from it.

---

## 7. Source-field mapping (OMS → `us_booking`)

| Target | OMS source (`order_management` unless noted) | Transform |
|---|---|---|
| `oms_order.oms_order_id`, `platform_order_ref` | `orders.id`, `orders.order_id` | none |
| `oms_source_id`, `channel`, `sub_source_id`, `account_name` | `sub_source` ⋈ `source` | — |
| `market_place_id` | `orders.market_place` | stored, not used as destination |
| `warehouse_id`, `oms_status`, `oms_merge_raw`, `merge_parent_order_id` | `orders.*` | parent = merge value if numeric |
| `booking_country_flags` | `order_flag` ⋈ `flag` where `flag_group = 3` | aggregated per order |
| `ebay_cancel_status`, `oms_shipped_flag`, `oms_shipped_error`, `oms_shipping_method` | `order_info.*` | — |
| `order_date_raw` | `orders.order_date` | **none** (raw) |
| `ship_*` | `customers.shipping_address`, `customers.customer_info` (email) | trimmed copy |
| `ship_address_hash` | the ship-to fields above | stable hash; invalidates confirmations |
| `oms_country_id` | `shipping_address.country_id` | raw |
| Destination | `country_map` (verified) or `order_destination_confirmation` (valid) | `v_order_destination` |
| `oms_order_item.*` | `order_item_info` | quantities cast after a `^\d+$` check; raw kept |
| `oms_order_item_component.*` | `order_combo` | — |
| "Already shipped" signal | `shipment` with tracking and status ≠ Cancelled | eBay/Shopify only |
| eBay cancel request | `customer_service.ebay_order_cancellations.order_id` = platform ref | → `cancellation` review |

---

## 8. Intake, scope and review

1. **Candidates:**
   - `warehouse_id = 32`;
   - source in 1, 2, 3 or 6;
   - status `Inprogress`. This is still to be confirmed (§10).
2. **Scope** comes from `v_order_scope` only. It is US or CA, from a verified map or a valid per-order confirmation.
   - Without a destination the order is `undetermined`, and the `destination_country` requirement is `unmet`.
   - A destination outside US/CA → `out_of_scope` → `scope` review.
3. **Requirements** (`shipment_requirement`) are about missing data. **Review cases** are about decisions:
   - scope, destination conflict, cancellation;
   - warehouse or flag conflict, merge inconsistency;
   - combo mismatch, missing SKU;
   - already-shipped suspicion, OMS status change, unknown booking;
   - unverified routing, over-allocation, unretrievable label.
4. Canada needs `customs_declaration` (contents description, value, origin, and possibly HS code). The OMS has no verified source for these fields, so staff supply them or the requirement stays unmet.
5. A source-hash change or status change after `ready` returns the group to `review`. After `booked` it opens a case and never voids automatically.

---

## 9. Duplicate prevention, unresolved outcomes and reprint

**Purchase blocking:** the guard trigger and the partial unique index both enforce it. The index alone was verified with the trigger disabled.

- **Blocks a new purchase:** `created`, `request_sent`, `unknown`, or `succeeded`/`reconciled_found` that has not been released.
- **Does not block:** `failed`, `reconciled_not_found`, or a released success.

**Booking flow:**

1. Lock the parcel and group rows.
2. Insert the attempt (`created`) and commit.
3. Send to the provider with `correlation_key` in metadata.
4. Record the response.

**Timeout.** A timeout or network error after send → `unknown` plus a `booking_unknown` case. The reconciler searches provider labels by correlation key and time window.

- **Label found** → `reconciled_found` with evidence, and a label row created in the same transaction.
- **Not found** → `reconciled_not_found` only with recorded evidence and a named person. Because metadata is not provider-side idempotency, "not found by metadata" alone is not enough. The evidence should also include the provider account's label and billing list for the window.
- **Unresolved** stays blocked indefinitely.

**Replacement.**

1. Request the void (`void_requested`).
2. The provider confirms the void → `voided`, with evidence.
3. Release the old attempt (reason, person).
4. Reopen the parcel; re-measuring is allowed now.
5. A new authorised attempt names the old one.

Both attempts and both labels remain in the history.

**Reprint** adds a `print_event` for the existing `label_file`. It needs a reason and a unique request id, and works only on an `active` label. If the file is missing, it is re-downloaded by the existing label reference. If that fails → `label_unretrievable`, never a new purchase.

---

## 10. Remaining blockers and decisions

| # | Item | Blocks |
|---|---|---|
| 1 | **Booking database target.** `BOOKING_DATABASE_URL` is unset. Choose the target, create `us_booking_owner` and `us_booking_app`, and run the read-only preflight | Any deployment |
| 2 | **Global `country_id` lookup** from the OMS application. Until then every order needs a per-order destination confirmation from staff | Throughput (not correctness) |
| 3 | **Shippo integration verification** with a test token: metadata searchability, label formats, void/refund flow and evidence. `routing_rule` stays `unverified`, which the schema enforces as non-bookable | Any Shippo purchase |
| 4 | **"Ready to book" status** (`Inprogress`?) and the meaning of `Hold` | Intake rules |
| 5 | **`shipped_error` / `shipped = 1` semantics** on open orders | Intake rules |
| 6 | **Pre-ship cancellation** for Amazon, Shopify and Wayfair | Safe purchase timing |
| 7 | **Missing state (15%)**: staff correction vs ZIP lookup with confirmation | Requirement handling |
| 8 | **Canada customs data source** (description, value, origin, HS code) | Canada bookings |
| 9 | **OMS timezone**, to be verified independently (for example from the OMS app config) before any conversion or time-window comparison | Time-based logic only |
| 10 | **Label storage location and PII retention** | Label files |
| 11 | **Stack confirmation** (Node 22 + `pg` + SQL migrations, like vendor-booking) and a migrator port that allows `ON SCHEMA us_booking` | Implementation |
| 12 | Amazon Seller Central and Wayfair label integrations stay **manual_only / unverified**. This app only routes those orders to them | — |

---

## 11. Next step: connecting the order-review screen

The review screen is the first thing to build. It needs no provider integration, because every live group currently sits in `review`.

1. **Target (blocker 1).** Set `BOOKING_DATABASE_URL` and run the preflight read-only. After approval, apply `0001` and `0002` as `us_booking_owner` through a migrator ported from vendor-booking. The migrator must have:
   - an expected-database guard;
   - the `ON SCHEMA` allowance;
   - no logging of connection strings.
2. **Read-only OMS snapshot sync** into `oms_order` / `oms_order_item` / `oms_order_item_component`.
   - Read through `OMS_READ_DATABASE_URL` with a dedicated SELECT-only role; the two URLs stay separate.
   - Bound the read to warehouse 32 and open statuses, plus the last 30 days.
   - The sync also generates `shipment_requirement` rows and review cases.
3. **Read model for the screen:** a `v_review_queue` view, one row per fulfilment group, with:
   - channel and account, raw order date;
   - scope status and destination source;
   - unmet requirements and open review cases (aggregated);
   - parcels, with measurement and contents status.
4. **Screen actions.** Each is a single transaction that writes `event_log`:
   - confirm a destination with evidence (`order_destination_confirmation`);
   - resolve or dismiss a review case;
   - mark a requirement met;
   - create parcels, enter measurements, allocate items, confirm contents.

   No purchase or print button until blocker 3 is closed.
5. **Acceptance:**
   - the snapshot counts reconcile with §3;
   - the screen shows every open US1 group;
   - no row is written to the OMS;
   - `booking_attempt` stays empty.

---

## 12. Local validation (2026-10-22)

**Environment**

- The installed service `postgresql-x64-18` (data directory `C:\Program Files\PostgreSQL\18\data`, port 5432) accepts SCRAM-password logins only, and no credentials for it were available. Credentials from other projects were deliberately **not** used.
- `db/tests/run_local_tests.sh` therefore used **the same installation's binaries (PostgreSQL 18.6)** to initialise a **disposable cluster** in the session scratchpad:
  - private port 55432, bound to 127.0.0.1;
  - the script verifies that the server's `data_directory` and `port` match the cluster it just created, and aborts otherwise;
  - a uniquely named database (`usb_test_<timestamp>_<random>`);
  - roles `us_booking_owner` and `us_booking_app` created inside that cluster only.
- After the run the database is dropped and the cluster is stopped and deleted. Port 55432 was confirmed closed afterwards.
- The existing 5432 service, its databases and the OMS were never connected to.

**Run**

- `0001` was applied twice (idempotency), then `0002`, both as the owner role.
- Fixtures are synthetic (`SYN-` SKUs, placeholder addresses, order ids 9001–9005).

**Final run: 95 passed, 0 failed, 0 unexpected errors.**

| Area | Checks | Examples of what was rejected |
|---|---|---|
| T0 privileges | 9 | app UPDATE/DELETE/TRUNCATE on `event_log`; app writes to `item_allocation` and `country_map`; CREATE in schema or database |
| T1 duplicates / unresolved | 14 | second purchase while pending, unknown or label active; the partial unique index alone (trigger disabled, rolled back); unknown → failed; resolution without evidence; release of unknown; success without a label row at commit; reused correlation key; disabling the guard trigger as app |
| T2 void / replace / reprint | 17 | release before confirmed void; active → voided jump; printing a void-pending label; replacement without naming the old attempt or without authorisation; non-consecutive generation; un-release; reactivating a voided label. **Accepted:** controlled replacement, with the old attempt (`reconciled_found`, released) and the voided label both kept |
| T3 mismatched relationships | 14 | another group's order item; item paired with the wrong order; attempt with another group's id or account; label for another parcel's or provider's attempt; label for an attempt still `created`; order active in two groups; inactive member; edits to a sent request |
| T4 measurements | 8 | zero or negative length, width, height and weight (insert and update); attempt with missing height, unconfirmed measurements or unconfirmed contents; editing confirmed contents; measurement edits while a purchase is pending |
| T5 allocation | 4 | sequential over-allocation; cancelled parcel reopened; allocation released on cancel |
| T5 concurrent | 2 | READ COMMITTED: session B **waited 2,061 ms** for A, then *over-allocation: 3 of 2*. REPEATABLE READ: B **waited 2,051 ms**, then *could not serialize access*. Both ended with exactly one allocation row |
| T6 audit log | 8 | app UPDATE/DELETE/TRUNCATE (permission denied); owner UPDATE/DELETE/TRUNCATE (append-only trigger) |
| T7 destination | 10 | app writing `country_map`; a second active confirmation; a confirmation without evidence; a verified map row without evidence. Stale confirmation → `undetermined`; map vs confirmation disagreement → `conflict` |
| T8 timestamps | 3 | raw value unchanged; column is `timestamp without time zone`; no generated columns |
| T9 scope / gating | 6 | out-of-scope GB order; unverified Amazon routing; unmet `customs_declaration`; open review case. **Accepted:** a Canada parcel once its requirement is met and its case resolved |

**Limits of this validation**

- This is a disposable cluster, not the eventual target. The target's roles, ownership and default privileges must still be confirmed with the preflight.
- The tests cover database rules only. No application code, sync, provider call or print path exists yet.

---

## Appendix: OMS verification queries (all SELECT via MCP, 2026-10-22)

1. Identity and privileges on `ledsone`/`ph_dashboard`; role × database CONNECT/CREATE/TEMP; writable tables per role.
2. Column search for `%countr%`, `%cancel%`.
3. US1 status distribution (90 days), channel/account split, freshness vs `now()`.
4. Address completeness (counts only); `country_id` distribution.
5. Flag groups 2/3 on US1 orders.
6. Cancel status; open-order shipped flag and error; shipment and `booking_info` presence.
7. US1 shipments by channel, status and carrier service.
8. Merge structure (180 days), item/combo columns and quality.
9. `ebay_order_cancellations` columns and freshness; `timezone()` volatility.
