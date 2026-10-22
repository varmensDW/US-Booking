#!/usr/bin/env bash
# Runs the us_booking schema tests in a DISPOSABLE PostgreSQL cluster created for this run only.
#
# It never connects to an existing server: it runs initdb in <work dir>, starts that cluster on a
# private localhost port, verifies the connection really is that cluster (data_directory + port),
# creates a uniquely named database, applies db/proposed/*.sql, loads synthetic fixtures, runs the
# tests, then drops the database and deletes the cluster (set KEEP=1 to keep it for inspection).
#
# usage: db/tests/run_local_tests.sh <empty work dir>
#   PG_BIN        PostgreSQL bin directory (default: C:\Program Files\PostgreSQL\18\bin)
#   TEST_PG_PORT  port for the disposable cluster (default 55432; must be free)
set -euo pipefail

PG_BIN=${PG_BIN:-"/c/Program Files/PostgreSQL/18/bin"}
WORK=${1:?usage: run_local_tests.sh <empty work dir>}
PORT=${TEST_PG_PORT:-55432}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
RUN_ID=$(date +%Y%m%d_%H%M%S)_$RANDOM
DB="usb_test_$RUN_ID"
DATA="$WORK/cluster_$RUN_ID"
SUPER=usb_test_admin
LOG="$WORK/test_$RUN_ID.log"

mkdir -p "$WORK"
if "$PG_BIN/pg_isready" -q -h 127.0.0.1 -p "$PORT"; then
  echo "port $PORT is already in use; refusing to touch an existing server" >&2; exit 2
fi

"$PG_BIN/initdb" -D "$DATA" -U "$SUPER" --auth=trust --encoding=UTF8 --no-locale >"$WORK/initdb_$RUN_ID.log"
"$PG_BIN/pg_ctl" -D "$DATA" -o "-p $PORT -c listen_addresses=127.0.0.1" -l "$WORK/server_$RUN_ID.log" -w start >/dev/null

cleanup() {
  if [ "${KEEP:-0}" != 1 ]; then
    "$PG_BIN/psql" -X -q -h 127.0.0.1 -p "$PORT" -U "$SUPER" -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 || true
    "$PG_BIN/pg_ctl" -D "$DATA" -m fast -w stop >/dev/null 2>&1 || true
    rm -rf "$DATA"
  else
    echo "KEEP=1: cluster left running at $DATA on port $PORT"
  fi
}
trap cleanup EXIT

pg() { "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" "$@"; }

# Positive identification: the server we talk to must be the cluster this script just created.
actual_dir=$(pg -U "$SUPER" -d postgres -At -c "select current_setting('data_directory')")
actual_port=$(pg -U "$SUPER" -d postgres -At -c "select current_setting('port')")
norm() { echo "$1" | tr '\\' '/' | tr '[:upper:]' '[:lower:]'; }
if [ "$(norm "$actual_dir")" != "$(norm "$(cygpath -m "$DATA")")" ] || [ "$actual_port" != "$PORT" ]; then
  echo "connected server is not the disposable cluster ($actual_dir:$actual_port); aborting" >&2; exit 3
fi
echo "server: disposable cluster $(pg -U "$SUPER" -d postgres -At -c "select split_part(version(), ',', 1)") at $DATA, port $PORT"
echo "database: $DB"

pg -U "$SUPER" -d postgres -c "CREATE ROLE us_booking_owner LOGIN" -c "CREATE ROLE us_booking_app LOGIN"
pg -U "$SUPER" -d postgres -c "CREATE DATABASE $DB OWNER us_booking_owner" \
   -c "REVOKE ALL ON DATABASE $DB FROM PUBLIC" -c "GRANT CONNECT ON DATABASE $DB TO us_booking_app"

{
  echo "== apply 0001 (first run) as us_booking_owner"
  pg -U us_booking_owner -d "$DB" -f "$ROOT/db/proposed/0001_us_booking_init.sql"
  echo "== apply 0001 again (idempotency)"
  pg -U us_booking_owner -d "$DB" -f "$ROOT/db/proposed/0001_us_booking_init.sql"
  echo "== apply 0002 grants"
  pg -U us_booking_owner -d "$DB" -f "$ROOT/db/proposed/0002_us_booking_grants.sql"
  echo "== test support + fixtures"
  pg -U "$SUPER" -d "$DB" -f "$HERE/test_support.sql"
  pg -U "$SUPER" -d "$DB" -f "$HERE/fixtures.sql"
  echo "== tests"
  pg -U "$SUPER" -d "$DB" -f "$HERE/tests.sql"
  echo "== concurrency"
  PG_BIN="$PG_BIN" PORT="$PORT" DB="$DB" bash "$HERE/concurrency.sh"
} 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}

passes=$(grep -c 'PASS \[' "$LOG" || true)
fails=$(grep -c 'FAIL' "$LOG" || true)
errors=$(grep -c 'ERROR:' "$LOG" || true)
echo "summary: $passes passed, $fails failed, $errors unexpected errors (exit $status); log: $LOG"
[ "$status" = 0 ] && [ "$fails" = 0 ] && [ "$errors" = 0 ]
