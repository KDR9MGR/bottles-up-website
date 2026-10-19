#!/usr/bin/env bash
# Two managers book the LAST table of a kind for the same time at the same moment: exactly one booking may exist.
#
# desk_create_walkin() locks the table type while it counts and inserts. Session A books and keeps its transaction open for 2 seconds; session B starts 0.5 s
# later and must WAIT for A, then be told there is nothing left. Without the lock B would count the table as free and both would be booked.
# Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - walk-in concurrency: $1"; exit 1; }
U=00000000-0000-0000-0000-0000000007d1
ORG=00000000-0000-0000-0000-0000000007d2
VEN=00000000-0000-0000-0000-0000000007d3
TYPE=00000000-0000-0000-0000-0000000007d4
SLOT=00000000-0000-0000-0000-0000000007d5

cleanup() {
  psql_db -c "delete from public.site_outbox where venue_id = '$VEN'" \
          -c "delete from public.audit_log where details ->> 'venue_id' = '$VEN'" \
          -c "delete from public.site_table_bookings where venue_id = '$VEN'" \
          -c "delete from public.site_venues where id = '$VEN'" \
          -c "delete from public.site_organizations where id = '$ORG'" \
          -c "delete from auth.users where id = '$U'" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$U', 'racer@walkin.test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$ORG', 'Race Co', 'venue_owner', '$U');
insert into public.site_venues (id, name, org_id) values ('$VEN', 'Race Club', '$ORG');
insert into public.site_memberships (org_id, user_id, role, venue_id) values ('$ORG', '$U', 'manager', '$VEN');
insert into public.site_table_types (id, venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values ('$TYPE', '$VEN', 'Last booth', 6, 0, 10000, 1);
insert into public.site_venue_time_slots (id, venue_id, day_of_week, start_time) values ('$SLOT', '$VEN', extract(dow from current_date)::int, '21:00');
SQL
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
call() { echo "select 'R:' || coalesce((public.desk_create_walkin('$VEN', current_date, '$TYPE', '$SLOT', 2, null, '$1', '$2', null, true)) ->> 'confirmation_code', 'none');"; }

psql_db >"$OUT_A" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$U","role":"authenticated","email":"racer@walkin.test.example"}', true) is not null;
set local role authenticated;
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
select set_config('request.jwt.claims', '{"sub":"$U","role":"authenticated","email":"racer@walkin.test.example"}', true) is not null;
set local role authenticated;
$(call 'Bob Second' 'bob@race.example')
commit;
SQL
set -e
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

BOOKINGS=$(psql_db -c "select count(*) from public.site_table_bookings where venue_id = '$VEN'")
WHO=$(psql_db -c "select string_agg(customer_name, ',') from public.site_table_bookings where venue_id = '$VEN'")
grep -q '^R:BT-' "$OUT_A"                                         || fail "session A should have booked the table: $(cat "$OUT_A")"
grep -q 'no tables of this type are left for that time' "$OUT_B"  || fail "session B should have been told nothing is left: $(cat "$OUT_B")"
[ "$BOOKINGS" = "1" ]                                              || fail "exactly one booking should exist, got $BOOKINGS ($WHO)"
[ "$WHO" = "Ann First" ]                                           || fail "the first booker should hold the table, got $WHO"
[ "$WAITED" -ge 1000 ]                                             || fail "session B did not wait for A's lock (${WAITED} ms)"
echo "ok - two managers booking the last table at once: one booking, the other waited ${WAITED} ms and was told none is left"
