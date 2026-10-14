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

# ---------------------------------------------------------------------------------------------------------------
# The same race for the SCOPED scanner: two invited door staff, both covering Club A, scan one ticket at once.
# door_scan_ticket() also locks the order row, so the second must wait and then be told "already checked in".
# This scenario needs real, committed memberships, so it creates them and removes them afterwards.
# ---------------------------------------------------------------------------------------------------------------
D1=00000000-0000-0000-0000-0000000000d1
D2=00000000-0000-0000-0000-0000000000d2
OWN=00000000-0000-0000-0000-0000000000d3
ORG=00000000-0000-0000-0000-0000000000d4
VEN=00000000-0000-0000-0000-0000000000d5
EV=00000000-0000-0000-0000-0000000000e1

cleanup_door() {
  psql_db -c "update public.site_orders set checked_in_at = null, checked_in_by = null where ticket_code = 'C-1'" \
          -c "delete from public.scan_attempts where scanned_by in ('$D1', '$D2')" \
          -c "update public.site_events set venue_id = null where id = '$EV'" \
          -c "delete from public.site_venues where id = '$VEN'" \
          -c "delete from public.site_organizations where id = '$ORG'" \
          -c "delete from auth.users where id in ('$D1', '$D2', '$OWN')" >/dev/null 2>&1 || true
}
trap 'rm -f "$OUT_A" "$OUT_B"; reset; cleanup_door' EXIT
cleanup_door

psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$D1', 'cdoor1@test.example'), ('$D2', 'cdoor2@test.example'), ('$OWN', 'cowner@test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$ORG', 'Concurrency Co', 'venue_owner', '$OWN');
insert into public.site_venues (id, name, org_id) values ('$VEN', 'Concurrency Club', '$ORG');
insert into public.site_memberships (org_id, user_id, role, venue_id) values ('$ORG', '$D1', 'door', '$VEN'), ('$ORG', '$D2', 'door', '$VEN');
update public.site_events set venue_id = '$VEN' where id = '$EV';
SQL

OUT_C=$(mktemp); OUT_D=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B" "$OUT_C" "$OUT_D"; reset; cleanup_door' EXIT

psql_db >"$OUT_C" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$D1","role":"authenticated"}', true) is not null;
set local role authenticated;
select 'A:' || result from public.door_scan_ticket('C-1', '$EV');
select pg_sleep(2);
commit;
SQL
PID_C=$!

sleep 0.7
START=$SECONDS
psql_db >"$OUT_D" <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$D2","role":"authenticated"}', true) is not null;
set local role authenticated;
select 'B:' || result from public.door_scan_ticket('C-1', '$EV');
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_C"

RESULTS=$(cat "$OUT_C" "$OUT_D" | grep -E '^[AB]:' | sort | tr '\n' ' ')
OKS=$(printf '%s' "$RESULTS" | grep -o ':ok' | wc -l | tr -d ' ')
ATTEMPTS=$(psql_db -c "select count(*) from public.scan_attempts where scanned_by in ('$D1', '$D2') and ticket_code_attempted = 'C-1'")
WINNER=$(psql_db -c "select checked_in_by from public.site_orders where ticket_code = 'C-1'")

fail_door() { echo "FAIL - scoped scanner concurrency: $1 (results: $RESULTS, session B waited ${WAITED}s)"; exit 1; }
[ "$OKS" = "1" ]                              || fail_door "expected exactly one ok"
[ "$RESULTS" = "A:ok B:already_checked_in " ] || fail_door "expected A:ok and B:already_checked_in"
[ "$WAITED" -ge 1 ]                           || fail_door "session B did not wait for the row lock"
[ "$ATTEMPTS" = "2" ]                         || fail_door "expected 2 scan_attempts rows, got $ATTEMPTS"
[ "$WINNER" = "$D1" ]                         || fail_door "the first scanner should be recorded as the one who checked in"
echo "ok - two door staff scanning one ticket at once through the scoped scanner: exactly one admitted, the other waited ${WAITED}s and was told already_checked_in"

# ---------------------------------------------------------------------------------------------------------------
# Venue setup: two people add the SAME arrival time (a double click, or two managers) at the same moment. There is no
# unique index on (venue, day, time), so add_venue_time_slot() locks the venue row before it checks for a duplicate.
# Session A adds and holds its transaction open for 2 seconds; session B starts 0.7s later, must WAIT, and must then be
# told the time is already added. Without the lock both would pass the check and the venue would list the time twice.
# ---------------------------------------------------------------------------------------------------------------
SOWN=00000000-0000-0000-0000-0000000000d6
SORG=00000000-0000-0000-0000-0000000000d7
SVEN=00000000-0000-0000-0000-0000000000d8

cleanup_setup() {
  psql_db -c "delete from public.audit_log where actor_id = '$SOWN'" \
          -c "delete from public.site_venues where id = '$SVEN'" \
          -c "delete from public.site_organizations where id = '$SORG'" \
          -c "delete from auth.users where id = '$SOWN'" >/dev/null 2>&1 || true
}
trap 'rm -f "$OUT_A" "$OUT_B" "$OUT_C" "$OUT_D" "$OUT_E" "$OUT_F"; reset; cleanup_door; cleanup_setup' EXIT
cleanup_setup

psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$SOWN', 'sowner@test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$SORG', 'Setup Co', 'venue_owner', '$SOWN');
insert into public.site_memberships (org_id, user_id, role) values ('$SORG', '$SOWN', 'owner');
insert into public.site_venues (id, name, org_id) values ('$SVEN', 'Setup Club', '$SORG');
SQL

OUT_E=$(mktemp); OUT_F=$(mktemp)

psql_db >"$OUT_E" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$SOWN","role":"authenticated","email":"sowner@test.example"}', true) is not null;
set local role authenticated;
select 'A:added' from (select public.add_venue_time_slot('$SVEN', 5, '21:00')) s;
select pg_sleep(2);
commit;
SQL
PID_E=$!

sleep 0.7
START=$SECONDS
# Session B is expected to fail, so it must not stop at the error: run it without ON_ERROR_STOP and keep its messages.
psql -X -q -t -A -d "$DB" >"$OUT_F" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$SOWN","role":"authenticated","email":"sowner@test.example"}', true) is not null;
set local role authenticated;
select 'B:added' from (select public.add_venue_time_slot('$SVEN', 5, '21:00')) s;
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_E"

COPIES=$(psql_db -c "select count(*) from public.site_venue_time_slots where venue_id = '$SVEN' and day_of_week = 5 and start_time = '21:00'")
fail_setup() { echo "FAIL - venue setup concurrency: $1 (copies: $COPIES, session B waited ${WAITED}s, B said: $(tr '\n' ' ' <"$OUT_F"))"; exit 1; }
grep -q '^A:added' "$OUT_E"                  || fail_setup "session A should have added the time"
! grep -q '^B:added' "$OUT_F"                || fail_setup "session B must not also add the same time"
grep -q 'already added' "$OUT_F"             || fail_setup "session B should be told the time is already added"
[ "$COPIES" = "1" ]                          || fail_setup "expected exactly one copy of the arrival time"
[ "$WAITED" -ge 1 ]                          || fail_setup "session B did not wait for the venue lock"
echo "ok - two people adding the same arrival time at once: exactly one copy, the other waited ${WAITED}s and was told it is already added"

# ---------------------------------------------------------------------------------------------------------------
# Service requests: two servers press Acknowledge on the same unclaimed request at the same moment ("multiple staff cannot claim
# the same work accidentally"). update_service_request() locks the request row, so the second must WAIT and then be told someone
# else has it. Without the lock both would read "New", both would be told ok, and the last write would silently win.
# ---------------------------------------------------------------------------------------------------------------
RS1=00000000-0000-0000-0000-0000000000d9
RS2=00000000-0000-0000-0000-0000000000da
ROWN=00000000-0000-0000-0000-0000000000db
RORG=00000000-0000-0000-0000-0000000000dc
RVEN=00000000-0000-0000-0000-0000000000dd
RTYPE=00000000-0000-0000-0000-0000000000de
RSLOT=00000000-0000-0000-0000-0000000000df
RBOOK=00000000-0000-0000-0000-0000000000c1
RREQ=00000000-0000-0000-0000-0000000000c2
RM1=00000000-0000-0000-0000-0000000000c3
RM2=00000000-0000-0000-0000-0000000000c4

cleanup_requests() {
  psql_db -c "delete from public.audit_log where entity_id = '$RREQ'" \
          -c "delete from public.site_venues where id = '$RVEN'" \
          -c "delete from public.site_organizations where id = '$RORG'" \
          -c "delete from auth.users where id in ('$RS1', '$RS2', '$ROWN')" >/dev/null 2>&1 || true
}
trap 'rm -f "$OUT_A" "$OUT_B" "$OUT_C" "$OUT_D" "$OUT_E" "$OUT_F" "$OUT_G" "$OUT_H"; reset; cleanup_door; cleanup_setup; cleanup_requests' EXIT
cleanup_requests

psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$RS1', 'rserver1@test.example'), ('$RS2', 'rserver2@test.example'), ('$ROWN', 'rowner@test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$RORG', 'Requests Co', 'venue_owner', '$ROWN');
insert into public.site_venues (id, name, org_id) values ('$RVEN', 'Requests Club', '$RORG');
insert into public.site_memberships (id, org_id, user_id, role, venue_id) values ('$RM1', '$RORG', '$RS1', 'server', '$RVEN'), ('$RM2', '$RORG', '$RS2', 'server', '$RVEN');
insert into public.site_table_types (id, venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values ('$RTYPE', '$RVEN', 'Booth', 6, 0, 0, 3);
insert into public.site_venue_time_slots (id, venue_id, day_of_week, start_time, label) values ('$RSLOT', '$RVEN', 6, '21:00', 'Evening');
insert into public.site_table_bookings (id, venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
  values ('$RBOOK', '$RVEN', '$RTYPE', '$RSLOT', current_date + 3, 'Race Guest', 'race@test.example', 2, 1000, 'paid');
insert into public.site_service_requests (id, venue_id, booking_id, kind) values ('$RREQ', '$RVEN', '$RBOOK', 'assistance');
SQL

OUT_G=$(mktemp); OUT_H=$(mktemp)

psql_db >"$OUT_G" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$RS1","role":"authenticated","email":"rserver1@test.example"}', true) is not null;
set local role authenticated;
select 'A:acknowledged' from (select public.update_service_request('$RREQ', 'acknowledge')) s;
select pg_sleep(2);
commit;
SQL
PID_G=$!

sleep 0.7
START=$SECONDS
# Session B is expected to be refused, so it must not stop at the error: run it without ON_ERROR_STOP and keep its messages.
psql -X -q -t -A -d "$DB" >"$OUT_H" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$RS2","role":"authenticated","email":"rserver2@test.example"}', true) is not null;
set local role authenticated;
select 'B:acknowledged' from (select public.update_service_request('$RREQ', 'acknowledge')) s;
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_G"

HOLDER=$(psql_db -c "select assigned_membership_id from public.site_service_requests where id = '$RREQ'")
ACKS=$(psql_db -c "select count(*) from public.audit_log where action = 'service_request.acknowledged' and entity_id = '$RREQ'")
fail_req() { echo "FAIL - service request concurrency: $1 (holder: $HOLDER, acknowledgements recorded: $ACKS, session B waited ${WAITED}s, B said: $(tr '\n' ' ' <"$OUT_H"))"; exit 1; }
grep -q '^A:acknowledged' "$OUT_G"                         || fail_req "the first server should have acknowledged it"
! grep -q '^B:acknowledged' "$OUT_H"                       || fail_req "the second server must not also acknowledge it"
grep -q 'someone else has already taken this request' "$OUT_H" || fail_req "the second server should be told someone else has it"
[ "$HOLDER" = "$RM1" ]                                     || fail_req "the request should belong to the first server"
[ "$ACKS" = "1" ]                                          || fail_req "exactly one acknowledgement should be recorded"
[ "$WAITED" -ge 1 ]                                        || fail_req "session B did not wait for the row lock"
echo "ok - two servers acknowledging one request at once: exactly one took it, the other waited ${WAITED}s and was told someone else has it"
