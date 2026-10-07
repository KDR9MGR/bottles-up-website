#!/usr/bin/env bash
# Two staff scan the SAME ticket at the same moment. Exactly one may be admitted.
#
# checkin_ticket() takes a row lock (select ... for update). Session A scans and
# then keeps its transaction open for 2 seconds; session B starts 0.7s later and
# must WAIT for A, then see that the ticket is already checked in. If the lock
# were removed, B would not wait and both would be admitted.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
STAFF=00000000-0000-0000-0000-0000000000a1
ADMIN=00000000-0000-0000-0000-0000000000a2

psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
reset() {
  psql_db -c "update public.site_orders set checked_in_at = null, checked_in_by = null where ticket_code = 'C-1'" \
          -c "delete from public.scan_attempts where ticket_code_attempted = 'C-1'" >/dev/null
}

reset
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; reset' EXIT

psql_db >"$OUT_A" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$STAFF","role":"authenticated"}', true) is not null;
set local role authenticated;
select 'A:' || result from public.checkin_ticket('C-1');
select pg_sleep(2);
commit;
SQL
PID_A=$!

sleep 0.7
START=$SECONDS
psql_db >"$OUT_B" <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$ADMIN","role":"authenticated"}', true) is not null;
set local role authenticated;
select 'B:' || result from public.checkin_ticket('C-1');
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_A"

RESULTS=$(cat "$OUT_A" "$OUT_B" | grep -E '^[AB]:' | sort | tr '\n' ' ')
OKS=$(printf '%s' "$RESULTS" | grep -o ':ok' | wc -l | tr -d ' ')
ATTEMPTS=$(psql_db -c "select count(*) from public.scan_attempts where ticket_code_attempted = 'C-1'")
WINNER=$(psql_db -c "select checked_in_by from public.site_orders where ticket_code = 'C-1'")

fail() { echo "FAIL - concurrency: $1 (results: $RESULTS, session B waited ${WAITED}s)"; exit 1; }
[ "$OKS" = "1" ]                          || fail "expected exactly one ok"
[ "$RESULTS" = "A:ok B:already_checked_in " ] || fail "expected A:ok and B:already_checked_in"
[ "$WAITED" -ge 1 ]                       || fail "session B did not wait for the row lock"
[ "$ATTEMPTS" = "2" ]                     || fail "expected 2 scan_attempts rows, got $ATTEMPTS"
[ "$WINNER" = "$STAFF" ]                  || fail "the first scanner should be recorded as the one who checked in"
echo "ok - two simultaneous scans of one ticket: exactly one admitted, the other waited ${WAITED}s and was told already_checked_in"
