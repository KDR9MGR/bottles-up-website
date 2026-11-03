#!/usr/bin/env bash
# Two guests start the online checkout for the LAST table of a kind at the same moment: exactly one pending booking may exist.
#
# site_reserve_table_booking() locks the table type while it counts and inserts. Session A reserves and keeps its transaction open for 2 seconds; session B starts
# 0.5 s later and must WAIT for A, then be told there is nothing left. Without the lock B would count the table as free (A's row is not committed yet) and both
# guests would be sent to pay for the same table. Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - checkout concurrency: $1"; exit 1; }
VEN=00000000-0000-0000-0000-0000000008b1
TYPE=00000000-0000-0000-0000-0000000008b2
SLOT=00000000-0000-0000-0000-0000000008b3

cleanup() {
  psql_db -c "delete from public.site_table_bookings where venue_id = '$VEN'" \
          -c "delete from public.site_venues where id = '$VEN'" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db >/dev/null <<SQL
insert into public.site_venues (id, name) values ('$VEN', 'Checkout Race Club');
insert into public.site_table_types (id, venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values ('$TYPE', '$VEN', 'Last booth', 6, 0, 10000, 1);
insert into public.site_venue_time_slots (id, venue_id, day_of_week, start_time) values ('$SLOT', '$VEN', extract(dow from current_date + 2)::int, '21:00');
SQL
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
call() { echo "select 'R:' || coalesce((public.site_reserve_table_booking('$VEN', '$TYPE', '$SLOT', current_date + 2, '$1', '$2', null, 2, null, 10000, 0, 0, 0, 10000, 'pay_ahead', 'cad', null, 0, null))::text, 'none');"; }

psql_db >"$OUT_A" <<SQL &
begin;
set local role service_role;
$(call 'Ann First' 'ann@race.example')
select pg_sleep(2);
commit;
SQL
PID_A=$!

sleep 0.5
START=$(now_ms)
set +e
psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" >"$OUT_B" 2>&1 <<SQL
begin;
set local role service_role;
$(call 'Bob Second' 'bob@race.example')
commit;
SQL
set -e
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

BOOKINGS=$(psql_db -c "select count(*) from public.site_table_bookings where venue_id = '$VEN'")
WHO=$(psql_db -c "select string_agg(customer_name, ',') from public.site_table_bookings where venue_id = '$VEN'")
grep -qE '^R:[0-9a-f-]{36}$' "$OUT_A"  || fail "session A should have reserved the table: $(cat "$OUT_A")"
grep -q '^R:none$' "$OUT_B"            || fail "session B should have been told none is left: $(cat "$OUT_B")"
[ "$BOOKINGS" = "1" ]                   || fail "exactly one booking should exist, got $BOOKINGS ($WHO)"
[ "$WHO" = "Ann First" ]                || fail "the first guest should hold the table, got $WHO"
[ "$WAITED" -ge 1000 ]                  || fail "session B did not wait for A's lock (${WAITED} ms)"
echo "ok - two guests checking out for the last table at once: one booking, the other waited ${WAITED} ms and was told none is left"
