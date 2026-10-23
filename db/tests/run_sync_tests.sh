#!/usr/bin/env bash
# End-to-end tests for the OMS order sync, in a DISPOSABLE PostgreSQL cluster created for this run.
#
# The cluster holds a synthetic stand-in for the OMS (database "ledsone", SELECT-only role
# oms_reader) and a booking database owned by one role (the approved single-role setup). The real
# commands run against it: scripts/db-migrate.mjs and scripts/oms-sync.mjs, through a test env file
# in the work dir. It never connects to an existing server and deletes the cluster afterwards.
#
# usage: db/tests/run_sync_tests.sh <empty work dir>
#   PG_BIN             PostgreSQL bin directory (default: C:\Program Files\PostgreSQL\18\bin)
#   TEST_SYNC_PG_PORT  port for the disposable cluster (default 55434; must be free)
set -euo pipefail

PG_BIN=${PG_BIN:-"/c/Program Files/PostgreSQL/18/bin"}
WORK=${1:?usage: run_sync_tests.sh <empty work dir>}
PORT=${TEST_SYNC_PG_PORT:-55434}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
RUN_ID=$(date +%Y%m%d_%H%M%S)_$RANDOM
BOOKING_DB="usb_sync_$RUN_ID"
DATA="$WORK/cluster_$RUN_ID"
SUPER=usb_test_admin
LOG="$WORK/sync_test_$RUN_ID.log"
ENVF="$WORK/test_$RUN_ID.env"

mkdir -p "$WORK"
if "$PG_BIN/pg_isready" -q -h 127.0.0.1 -p "$PORT"; then
  echo "port $PORT is already in use; refusing to touch an existing server" >&2; exit 2
fi
"$PG_BIN/initdb" -D "$DATA" -U "$SUPER" --auth=trust --encoding=UTF8 --no-locale >"$WORK/initdb_$RUN_ID.log"
# Detach the server's stdio so it can never hold this script's output pipe open.
"$PG_BIN/pg_ctl" -D "$DATA" -o "-p $PORT -c listen_addresses=127.0.0.1" -l "$WORK/server_$RUN_ID.log" -w start \
  </dev/null >/dev/null 2>&1

cleanup() {
  "$PG_BIN/pg_ctl" -D "$DATA" -m fast -w stop </dev/null >/dev/null 2>&1 || true
  rm -rf "$DATA" "$ENVF"
}
trap cleanup EXIT

pg() { "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" "$@"; }
actual_dir=$(pg -U "$SUPER" -d postgres -At -c "select current_setting('data_directory')")
norm() { echo "$1" | tr '\\' '/' | tr '[:upper:]' '[:lower:]'; }
if [ "$(norm "$actual_dir")" != "$(norm "$(cygpath -m "$DATA")")" ]; then
  echo "connected server is not the disposable cluster; aborting" >&2; exit 3
fi

pg -U "$SUPER" -d postgres -c "CREATE ROLE booking_owner LOGIN" -c "CREATE DATABASE ledsone" -c "CREATE DATABASE $BOOKING_DB OWNER booking_owner"
pg -U "$SUPER" -d ledsone -f "$HERE/sync/fake_oms.sql"

cat >"$ENVF" <<EOF
OMS_READ_DATABASE_URL=postgresql://oms_reader@127.0.0.1:$PORT/ledsone
BOOKING_DATABASE_URL=postgresql://booking_owner@127.0.0.1:$PORT/$BOOKING_DB
BOOKING_MIGRATION_DATABASE_URL=postgresql://booking_owner@127.0.0.1:$PORT/$BOOKING_DB
BOOKING_DATABASE_EXPECTED_NAME=$BOOKING_DB
BOOKING_ROLE_MODE=single
ENABLE_LIVE_BOOKING=false
EOF

oms_fingerprint() {
  pg -U "$SUPER" -d ledsone -At -c "SELECT md5(string_agg(t, '|' ORDER BY t)) FROM (
    SELECT 'o' || o::text t FROM order_management.orders o UNION ALL SELECT 'i' || i::text FROM order_management.order_item_info i
    UNION ALL SELECT 'c' || c::text FROM order_management.order_combo c UNION ALL SELECT 'n' || n::text FROM order_management.order_info n
    UNION ALL SELECT 's' || s::text FROM customers.shipping_address s UNION ALL SELECT 'x' || x::text FROM order_management.shipment x) z"
}
check() { pg -U booking_owner -d "$BOOKING_DB" -f "$HERE/sync/$1" 2>&1; }
sync() { node "$ROOT/scripts/oms-sync.mjs" --env-file="$ENVF" "$@" 2>&1; }
summary_has() { # label, javascript predicate over the SUMMARY object `s`
  local line; line=$(grep '^SUMMARY ' "$WORK/last_sync.out" | sed 's/^SUMMARY //')
  if node -e "const s=JSON.parse(process.argv[1]); process.exit(($2) ? 0 : 1)" "$line"; then echo "PASS [$1]"; else echo "FAIL [$1]"; fi
}

{
  echo "== migrate (single role) with scripts/db-migrate.mjs"
  node "$ROOT/scripts/db-migrate.mjs" --env-file="$ENVF" --apply
  pg -U "$SUPER" -d "$BOOKING_DB" -f "$HERE/test_support.sql"
  pg -U "$SUPER" -d "$BOOKING_DB" -c "GRANT USAGE ON SCHEMA test_support TO booking_owner"
  before=$(oms_fingerprint)

  echo "== S1 dry run"
  sync | tee "$WORK/last_sync.out"
  summary_has 'S1 dry run reports 6 new groups' 's.mode === "dry-run" && s.counts.groups_new === 6'
  if grep -q '^WARNING' "$WORK/last_sync.out"; then echo "FAIL [S1 SELECT-only OMS role gives no write warning]"; else echo "PASS [S1 SELECT-only OMS role gives no write warning]"; fi
  check assert_dry_run.sql

  echo "== S2 apply, limit 2"
  sync --apply --limit=2 | tee "$WORK/last_sync.out"
  summary_has 'S2 two new groups' 's.counts.groups_new === 2 && s.counts.orders_inserted === 2'
  check assert_limit.sql

  echo "== S3 apply, limit 20"
  sync --apply | tee "$WORK/last_sync.out"
  summary_has 'S3 four new groups, two refreshed' 's.counts.groups_new === 4 && s.counts.groups_refreshed === 2'
  check assert_full.sql

  echo "== S4 re-run, no OMS change"
  sync --apply | tee "$WORK/last_sync.out"
  summary_has 'S4 nothing new or changed' '!s.counts.groups_new && !s.counts.orders_inserted && !s.counts.orders_changed && !s.counts.lines_inserted && !s.counts.lines_changed && Object.keys(s.review_cases_opened).length === 0'
  check assert_rerun.sql
  after=$(oms_fingerprint)
  if [ "$before" = "$after" ]; then echo "PASS [S4 OMS data unchanged by four syncs]"; else echo "FAIL [S4 OMS data unchanged by four syncs]"; fi

  echo "== S5 staff edits, then OMS changes"
  check staff_edits.sql
  pg -U "$SUPER" -d ledsone -f "$HERE/sync/fake_oms_changes.sql"

  echo "== S6 sync after changes"
  sync --apply | tee "$WORK/last_sync.out"
  summary_has 'S6 one group superseded, one order moved' 's.counts.groups_superseded === 1 && s.orders_moved.length === 1 && s.orders_moved[0].oms_order_id === 5001'
  check assert_changes.sql

  echo "== S7 re-run after changes"
  sync --apply | tee "$WORK/last_sync.out"
  check assert_stable.sql

  echo "== S8 a cleared finding recurs"
  pg -U "$SUPER" -d ledsone -f "$HERE/sync/fake_oms_recur.sql"
  sync --apply | tee "$WORK/last_sync.out"
  check assert_recur.sql
} 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}

passes=$(grep -c 'PASS \[' "$LOG" || true)
fails=$(grep -c 'FAIL' "$LOG" || true)
errors=$(grep -cE 'ERROR:|STOP:' "$LOG" || true)
echo "summary: $passes passed, $fails failed, $errors unexpected errors (exit $status); log: $LOG"
[ "$status" = 0 ] && [ "$fails" = 0 ] && [ "$errors" = 0 ]
