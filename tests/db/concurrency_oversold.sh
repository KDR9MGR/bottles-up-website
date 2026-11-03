#!/usr/bin/env bash
# The same late payment is reported twice at the same moment (Stripe's webhook and the self-heal path can both run): exactly one conflict may exist and neither call may fail.
#
# site_flag_oversold_booking() locks the table type while it looks for an existing conflict and writes one. Session A flags and keeps its transaction open for 2 seconds; session B
# asks 0.5 s later and must WAIT, then be told the same thing (true) with no error. Without the lock B would not see A's row yet and its insert would break the one-conflict-per-booking
# rule (a unique violation), which would fail the payment's fulfilment. Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - oversold concurrency: $1"; exit 1; }
VEN=00000000-0000-0000-0000-0000000008d1
TYPE=00000000-0000-0000-0000-0000000008d2
SLOT=00000000-0000-0000-0000-0000000008d3
B1=00000000-0000-0000-0000-0000000008d4
B2=00000000-0000-0000-0000-0000000008d5

cleanup() {
  psql_db -c "delete from public.site_booking_conflicts where venue_id = '$VEN'" \
          -c "delete from public.site_table_bookings where venue_id = '$VEN'" \
          -c "delete from public.site_venues where id = '$VEN'" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db >/dev/null <<SQL
insert into public.site_venues (id, name) values ('$VEN', 'Oversold Race Club');
insert into public.site_table_types (id, venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values ('$TYPE', '$VEN', 'Last booth', 6, 0, 10000, 1);
insert into public.site_venue_time_slots (id, venue_id, day_of_week, start_time) values ('$SLOT', '$VEN', extract(dow from current_date + 2)::int, '21:00');
insert into public.site_table_bookings (id, venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code, confirmation_sent_at)
  values ('$B1', '$VEN', '$TYPE', '$SLOT', current_date + 2, 'First Guest', 'first@oversold.race', 2, 10000, 'paid', 'OR0001', now());
insert into public.site_table_bookings (id, venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
  values ('$B2', '$VEN', '$TYPE', '$SLOT', current_date + 2, 'Late Payer', 'late@oversold.race', 2, 10000, 'paid', 'OR0002');
SQL
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

psql_db >"$OUT_A" <<SQL &
begin;
set local role service_role;
select 'R:' || public.site_flag_oversold_booking('$B2')::text;
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
select 'R:' || public.site_flag_oversold_booking('$B2')::text;
commit;
SQL
set -e
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

CONFLICTS=$(psql_db -c "select count(*) from public.site_booking_conflicts where venue_id = '$VEN'")
grep -q '^R:true$' "$OUT_A"  || fail "session A should have opened the conflict: $(cat "$OUT_A")"
grep -q '^R:true$' "$OUT_B"  || fail "session B should have been told the same, with no error: $(cat "$OUT_B")"
[ "$CONFLICTS" = "1" ]       || fail "exactly one conflict should exist, got $CONFLICTS"
[ "$WAITED" -ge 1000 ]       || fail "session B did not wait for A's lock (${WAITED} ms)"
echo "ok - the same late payment reported twice at once: one conflict, the second call waited ${WAITED} ms and got the same answer"
