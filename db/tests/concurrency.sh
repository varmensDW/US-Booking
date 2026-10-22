#!/usr/bin/env bash
# Concurrent over-allocation test, called by run_local_tests.sh against the disposable cluster.
# Two sessions of the runtime role allocate the same order line into two different parcels at once.
# Session A holds its transaction open; session B must wait for it and then be rejected.
set -uo pipefail
: "${PG_BIN:?}" "${PORT:?}" "${DB:?}"

app() { "$PG_BIN/psql" -X -q -h 127.0.0.1 -p "$PORT" -U us_booking_app -d "$DB" "$@"; }
admin() { "$PG_BIN/psql" -X -q -At -h 127.0.0.1 -p "$PORT" -U usb_test_admin -d "$DB" "$@"; }
now_ms() { date +%s%3N; }

item_row() { # parcel_no item qty
  echo "INSERT INTO us_booking.parcel_item (parcel_id, fulfilment_group_id, oms_order_id, oms_order_item_id, quantity)
        SELECT p.id, p.fulfilment_group_id, 9003, $2, $3 FROM us_booking.parcel p
         JOIN us_booking.fulfilment_group g ON g.id = p.fulfilment_group_id
        WHERE g.group_key = 'oms:9003:g1' AND p.parcel_no = $1;"
}

run_case() { # label isolation item qtyA qtyB expected_total
  local label=$1 iso=$2 item=$3 qa=$4 qb=$5 expect=$6
  app -v ON_ERROR_STOP=1 -c "BEGIN" -c "$(item_row 1 "$item" "$qa")" -c "SELECT pg_sleep(3)" -c "COMMIT" \
    >"$TMPD/a.out" 2>&1 &
  local pid_a=$!
  sleep 1
  local t0; t0=$(now_ms)
  app -c "BEGIN ISOLATION LEVEL $iso" -c "$(item_row 2 "$item" "$qb")" -c "COMMIT" >"$TMPD/b.out" 2>&1
  local t1; t1=$(now_ms)
  wait "$pid_a"; local a_status=$?
  local waited=$(( t1 - t0 ))
  local total rows
  total=$(admin -c "SELECT allocated_qty FROM us_booking.item_allocation WHERE oms_order_item_id = $item")
  rows=$(admin -c "SELECT count(*) FROM us_booking.parcel_item WHERE oms_order_item_id = $item")
  local b_err; b_err=$(grep -m1 'ERROR' "$TMPD/b.out" || true)
  if [ "$a_status" = 0 ] && [ "$total" = "$expect" ] && [ "$rows" = 1 ] && [ "$waited" -ge 1500 ] \
     && echo "$b_err" | grep -Eq 'over-allocation|could not serialize'; then
    echo "PASS [T5 concurrent over-allocation, $label] B waited ${waited} ms then was rejected: ${b_err#*ERROR:  }; allocated=$total, rows=$rows"
  else
    echo "FAIL [T5 concurrent over-allocation, $label] a_status=$a_status waited=${waited}ms total=$total rows=$rows b=[$b_err]"
    sed 's/^/  A: /' "$TMPD/a.out"; sed 's/^/  B: /' "$TMPD/b.out"
    return 1
  fi
}

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
rc=0
# Line 90031: 2 ordered. A takes 2, B tries 1 more.
run_case "READ COMMITTED" "READ COMMITTED" 90031 2 1 2 || rc=1
# Line 90032: 1 ordered. A takes 1, B tries 1 under REPEATABLE READ.
run_case "REPEATABLE READ" "REPEATABLE READ" 90032 1 1 1 || rc=1
exit $rc
