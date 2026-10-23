#!/usr/bin/env bash
# The last table of a kind, wanted by two people at the same moment (20261021100000_floor_plan_and_table_states.sql). Two races, each with its own committed rows:
#
#   1. Two managers move two DIFFERENT bookings into the LAST free booth at the same moment: exactly one move may happen.
#   2. One manager takes the last booth out of use while another books a walk-in on it: the table goes to one of them, never both.
#
#   3. Two managers take the last booth out of use at the same moment: exactly one block.
#
# Every function locks the table type while it counts and writes (desk_move_booking, desk_table_block, desk_create_walkin). Session A does its work and keeps its
# transaction open for 2 seconds; session B starts 0.5 s later and must WAIT for A, then be told there is nothing left. Without the lock B would count the table
# as free and both would get it. Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - floor concurrency: $1"; exit 1; }
U=00000000-0000-0000-0000-0000000008d1
ORG=00000000-0000-0000-0000-0000000008d2
VEN=00000000-0000-0000-0000-0000000008d3
BOOTH=00000000-0000-0000-0000-0000000008d4
PAIR=00000000-0000-0000-0000-0000000008d5
SLOT=00000000-0000-0000-0000-0000000008d6
B1=00000000-0000-0000-0000-0000000008e1
B2=00000000-0000-0000-0000-0000000008e2
CLAIMS="{\"sub\":\"$U\",\"role\":\"authenticated\",\"email\":\"racer@floor.test.example\"}"

cleanup() {
  psql_db -c "delete from public.site_table_blocks where venue_id = '$VEN'" \
          -c "delete from public.site_booking_moves where venue_id = '$VEN'" \
          -c "delete from public.site_outbox where venue_id = '$VEN'" \
          -c "delete from public.site_booking_seating where booking_id in (select id from public.site_table_bookings where venue_id = '$VEN')" \
          -c "delete from public.audit_log where details ->> 'venue_id' = '$VEN' or entity_id in ('$B1', '$B2')" \
          -c "delete from public.site_table_bookings where venue_id = '$VEN'" \
          -c "delete from public.site_venues where id = '$VEN'" \
          -c "delete from public.site_organizations where id = '$ORG'" \
          -c "delete from auth.users where id = '$U'" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

setup() {
  cleanup
  psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$U', 'racer@floor.test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$ORG', 'Floor Race Co', 'venue_owner', '$U');
insert into public.site_venues (id, name, org_id) values ('$VEN', 'Floor Race Club', '$ORG');
insert into public.site_memberships (org_id, user_id, role, venue_id) values ('$ORG', '$U', 'manager', '$VEN');
insert into public.site_table_types (id, venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values ('$BOOTH', '$VEN', 'Last booth', 6, 0, 10000, 1);
insert into public.site_table_types (id, venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values ('$PAIR', '$VEN', 'Pair tables', 4, 0, 2500, 5);
insert into public.site_venue_time_slots (id, venue_id, day_of_week, start_time) values ('$SLOT', '$VEN', extract(dow from current_date)::int, '21:00');
insert into public.site_table_bookings (id, venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
  values ('$B1', '$VEN', '$PAIR', '$SLOT', current_date, 'Mover One', 'one@floor.test.example', 2, 2500, 'paid'),
         ('$B2', '$VEN', '$PAIR', '$SLOT', current_date, 'Mover Two', 'two@floor.test.example', 2, 2500, 'paid');
SQL
}

# run_pair "<statement for A>" "<statement for B>": A keeps its transaction open 2 seconds, B starts 0.5 s later. Sets WAITED (ms B waited).
run_pair() {
  psql_db >"$OUT_A" <<SQL &
begin;
select set_config('request.jwt.claims', '$CLAIMS', true) is not null;
set local role authenticated;
$1
select pg_sleep(2);
commit;
SQL
  PID_A=$!
  sleep 0.5
  local start; start=$(now_ms)
  set +e
  psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" >"$OUT_B" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '$CLAIMS', true) is not null;
set local role authenticated;
$2
commit;
SQL
  set -e
  WAITED=$(( $(now_ms) - start ))
  wait "$PID_A"
}

# ---- 1. two moves into the last booth
setup
run_pair "select 'R:' || ((public.desk_move_booking('$B1', '$BOOTH', 'Race move one')) ->> 'to');" \
         "select 'R:' || ((public.desk_move_booking('$B2', '$BOOTH', 'Race move two')) ->> 'to');"
IN_BOOTH=$(psql_db -c "select count(*) from public.site_table_bookings where venue_id = '$VEN' and table_type_id = '$BOOTH'")
MOVES=$(psql_db -c "select count(*) from public.site_booking_moves where venue_id = '$VEN'")
grep -q '^R:Last booth' "$OUT_A"                                            || fail "move A should have succeeded: $(cat "$OUT_A")"
grep -q 'no tables of that type are free for that time' "$OUT_B"            || fail "move B should have been told the booth is taken: $(cat "$OUT_B")"
[ "$IN_BOOTH" = "1" ] && [ "$MOVES" = "1" ]                                 || fail "exactly one booking should be in the booth and one move recorded (booth=$IN_BOOTH, moves=$MOVES)"
[ "$WAITED" -ge 1000 ]                                                       || fail "move B did not wait for A's lock (${WAITED} ms)"
M1=$WAITED

# ---- 2. a block against a walk-in on the last booth
setup
run_pair "select 'R:' || ((public.desk_table_block('$VEN', current_date, '$BOOTH', '$SLOT', 'unavailable', 1, 'Race block', null)) ->> 'free_after');" \
         "select 'R:' || ((public.desk_create_walkin('$VEN', current_date, '$BOOTH', '$SLOT', 2, null, 'Walk Race', 'walk@floor.test.example', null, true)) ->> 'confirmation_code');"
BLOCKS=$(psql_db -c "select count(*) from public.site_table_blocks where venue_id = '$VEN' and released_at is null")
BOOKED=$(psql_db -c "select count(*) from public.site_table_bookings where venue_id = '$VEN' and customer_email = 'walk@floor.test.example'")
grep -q '^R:0' "$OUT_A"                                                      || fail "the block should have been made first: $(cat "$OUT_A")"
grep -q 'no tables of this type are left for that time' "$OUT_B"            || fail "the walk-in should have been told none is left: $(cat "$OUT_B")"
[ "$BLOCKS" = "1" ] && [ "$BOOKED" = "0" ]                                  || fail "the table should be blocked and not booked (blocks=$BLOCKS, booked=$BOOKED)"
[ "$WAITED" -ge 1000 ]                                                       || fail "the walk-in did not wait for the block's lock (${WAITED} ms)"

# ---- 3. two managers taking the last booth out of use at the same moment: exactly one block
setup
run_pair "select 'R:' || ((public.desk_table_block('$VEN', current_date, '$BOOTH', '$SLOT', 'unavailable', 1, 'Race block one', null)) ->> 'free_after');" \
         "select 'R:' || ((public.desk_table_block('$VEN', current_date, '$BOOTH', '$SLOT', 'unavailable', 1, 'Race block two', null)) ->> 'free_after');"
BLOCKS=$(psql_db -c "select count(*) from public.site_table_blocks where venue_id = '$VEN' and released_at is null")
grep -q '^R:0' "$OUT_A"                                                      || fail "the first block should have been made: $(cat "$OUT_A")"
grep -q 'only 0 of these tables are free' "$OUT_B"                           || fail "the second block should have been told none is free: $(cat "$OUT_B")"
[ "$BLOCKS" = "1" ]                                                          || fail "exactly one block should exist, got $BLOCKS"
[ "$WAITED" -ge 1000 ]                                                       || fail "the second block did not wait for the first's lock (${WAITED} ms)"

echo "ok - the last table wanted twice at once: two moves ended with one (the other waited ${M1} ms), a block against a walk-in ended with the block and no booking, and two blocks ended with one (waited ${WAITED} ms)"
