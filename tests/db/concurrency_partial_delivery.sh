#!/usr/bin/env bash
# Two people hand over bottles of the same order at the same moment, both having seen the same count: exactly one hand-over may be recorded.
#
# desk_deliver_part() locks the booking and then the line, and compares the delivered count the caller saw with the real one. Session A delivers 1 (3 to 4 of 5) and
# keeps its transaction open for 2 seconds; session B (0.5 s later, having seen the same 3 delivered) must WAIT for A, then be told someone else changed the item.
# Without the lock B would read 3, deliver 1 more and both hand-overs would be recorded for what was one bottle (4 of 5 counted twice).
# Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - partial delivery concurrency: $1"; exit 1; }
U=00000000-0000-0000-0000-0000000008d1
ORG=00000000-0000-0000-0000-0000000008d2
VEN=00000000-0000-0000-0000-0000000008d3
TYPE=00000000-0000-0000-0000-0000000008d4
SLOT=00000000-0000-0000-0000-0000000008d5
BOOK=00000000-0000-0000-0000-0000000008d6
LINE=00000000-0000-0000-0000-0000000008d7

cleanup() {
  psql_db -c "delete from public.audit_log where details ->> 'venue_id' = '$VEN'" \
          -c "delete from public.site_table_booking_bottles where booking_id = '$BOOK'" \
          -c "delete from public.site_table_bookings where venue_id = '$VEN'" \
          -c "delete from public.site_venues where id = '$VEN'" \
          -c "delete from public.site_organizations where id = '$ORG'" \
          -c "delete from auth.users where id = '$U'" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$U', 'racer@partial.test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$ORG', 'Race Co', 'venue_owner', '$U');
insert into public.site_venues (id, name, org_id) values ('$VEN', 'Race Club', '$ORG');
insert into public.site_memberships (org_id, user_id, role, venue_id) values ('$ORG', '$U', 'manager', '$VEN');
insert into public.site_table_types (id, venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values ('$TYPE', '$VEN', 'Booth', 6, 0, 0, 1);
insert into public.site_venue_time_slots (id, venue_id, day_of_week, start_time) values ('$SLOT', '$VEN', extract(dow from current_date)::int, '21:00');
insert into public.site_table_bookings (id, venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values ('$BOOK', '$VEN', '$TYPE', '$SLOT', current_date, 'Race Guest', 'guest@partial.test.example', 2, 1000, 1000, 'paid', 'RACE-PARTIAL');
insert into public.site_table_booking_bottles (id, booking_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, payment_status, service_status, delivered_quantity)
  values ('$LINE', '$BOOK', 'Patron', '750ml', 1000, 5, 5000, 'paid', 'picked_up', 3);
SQL
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
call() { echo "select 'R:' || coalesce((public.desk_deliver_part('$LINE', 1, 3)) ->> 'delivered', 'none');"; }

psql_db >"$OUT_A" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$U","role":"authenticated","email":"racer@partial.test.example"}', true) is not null;
set local role authenticated;
$(call)
select pg_sleep(2);
commit;
SQL
PID_A=$!

sleep 0.5
START=$(now_ms)
set +e
psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" >"$OUT_B" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$U","role":"authenticated","email":"racer@partial.test.example"}', true) is not null;
set local role authenticated;
$(call)
commit;
SQL
set -e
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

STATE=$(psql_db -c "select delivered_quantity || '/' || quantity || ' ' || service_status from public.site_table_booking_bottles where id = '$LINE'")
ENTRIES=$(psql_db -c "select count(*) from public.audit_log where action = 'table_booking.bottle_delivered_part' and entity_id = '$LINE'")
grep -q '^R:4$' "$OUT_A"                                                    || fail "session A should have delivered 1 (4 of 5): $(cat "$OUT_A")"
grep -q 'someone else has just changed this item' "$OUT_B"                  || fail "session B should have been told someone else changed the item: $(cat "$OUT_B")"
[ "$STATE" = "4/5 picked_up" ]                                               || fail "the line should end at 4/5 picked_up, got $STATE"
[ "$ENTRIES" = "1" ]                                                         || fail "exactly one hand-over should be recorded, got $ENTRIES"
[ "$WAITED" -ge 1000 ]                                                       || fail "session B did not wait for A's lock (${WAITED} ms)"
echo "ok - two people delivering a bottle at once: delivered once, the other waited ${WAITED} ms and was told someone else changed the item"
