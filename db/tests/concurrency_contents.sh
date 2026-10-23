#!/usr/bin/env bash
# Sync and staff edit overlapping on the same parcel (0009), called by run_local_tests.sh after
# tests_contents.sql. Session A runs an OMS sync that changes a packed line and holds its
# transaction open; session B (a staff edit using the parcel version it loaded before the sync)
# must wait for A, then be refused as stale instead of overwriting the sync's result.
set -uo pipefail
: "${PG_BIN:?}" "${PORT:?}" "${DB:?}"

owner() { "$PG_BIN/psql" -X -q -At -h 127.0.0.1 -p "$PORT" -U us_booking_owner -d "$DB" "$@"; }
now_ms() { date +%s%3N; }
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

parcel=$(owner -c "SELECT test_support.pid(9321, 1)")
version=$(owner -c "SELECT test_support.rv(9321, 1)")
owner -v ON_ERROR_STOP=1 -c "BEGIN" -c "SELECT test_support.sync_world('{\"qc\": 2}')" -c "SELECT pg_sleep(3)" -c "COMMIT" >"$TMPD/a.out" 2>&1 &
pid_a=$!
sleep 1
t0=$(now_ms)
owner -c "SELECT us_booking.staff_parcel_measure('{\"staff\": \"Packer Two\", \"parcel_id\": $parcel, \"expected_row_version\": $version, \"weight\": {\"value\": \"3\", \"unit\": \"kg\"}}')" >"$TMPD/b.out" 2>&1
t1=$(now_ms)
wait "$pid_a"; a_status=$?
waited=$(( t1 - t0 ))
b_err=$(grep -m1 'ERROR' "$TMPD/b.out" || true)
state=$(owner -c "SELECT contents_status || '/' || weight || weight_unit || '/' || weight_source FROM us_booking.parcel WHERE id = $parcel")
if [ "$a_status" = 0 ] && [ "$waited" -ge 1500 ] && echo "$b_err" | grep -q 'changed by someone else or by an OMS sync' \
   && [ "$state" = "stale/2.500kg/profile" ]; then
  echo "PASS [T22 staff edit overlapping a sync waited ${waited} ms, then was refused as stale; parcel left as the sync set it ($state)]"
else
  echo "FAIL [T22 sync/staff overlap] a_status=$a_status waited=${waited}ms state=$state b=[$b_err]"
  sed 's/^/  A: /' "$TMPD/a.out"; sed 's/^/  B: /' "$TMPD/b.out"
  exit 1
fi
# The refused staff can reload and reconcile: reduce to the new quantity is not needed (2 ordered,
# 1 packed); confirm again with the current version.
version=$(owner -c "SELECT test_support.rv(9321, 1)")
owner -c "SELECT us_booking.staff_parcel_confirm_contents('{\"staff\": \"Packer Two\", \"parcel_id\": $parcel, \"expected_row_version\": $version, \"confirmed\": true}')" >/dev/null 2>"$TMPD/c.err"
after=$(owner -c "SELECT p.contents_status || '/' || d.status || '/' || r.status FROM us_booking.parcel p
  JOIN us_booking.parcel_contents_discrepancy d ON d.parcel_id = p.id
  JOIN us_booking.shipment_requirement r ON r.fulfilment_group_id = p.fulfilment_group_id AND r.requirement = 'parcel_contents'
  WHERE p.id = $parcel ORDER BY d.id DESC LIMIT 1")
if [ "$after" = "confirmed/reconciled/unmet" ]; then
  echo "PASS [T22 after reloading, staff reconfirm; the extra ordered unit keeps the group incomplete ($after)]"
else
  echo "FAIL [T22 reconfirm after reload] $after $(cat "$TMPD/c.err")"; exit 1
fi
