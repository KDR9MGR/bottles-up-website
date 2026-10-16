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

# ---------------------------------------------------------------------------------------------------------------
# Table service money, three races on committed data (a server with a booking, two verifiers):
#   1. one server taps "record payment" twice at once (two devices, the same receipt): exactly one payment, the second waits for
#      the booking lock and is told it is a repeat;
#   2. two verifiers press Verify on the same payment at once: exactly one verifies, the other waits and is told it was already
#      verified (without the row lock both would succeed and the later one would overwrite the first one's name);
#   3. one server taps "Preparing" twice at once: the order changes once, the second tap is told nothing changed, one log entry;
#   4. a server records the payment that settles the table while a colleague marks an item that is to be paid at the venue as
#      delivered: the delivery waits for the payment and then sees the table paid (without the booking lock it would read the old
#      balance and be refused).
# ---------------------------------------------------------------------------------------------------------------
PU=00000000-0000-0000-0000-0000000000f1
PV1=00000000-0000-0000-0000-0000000000f2
PV2=00000000-0000-0000-0000-0000000000f3
POWN=00000000-0000-0000-0000-0000000000f4
PORG=00000000-0000-0000-0000-0000000000f5
PVEN=00000000-0000-0000-0000-0000000000f6
PTYPE=00000000-0000-0000-0000-0000000000f7
PSLOT=00000000-0000-0000-0000-0000000000f8
PBOOK=00000000-0000-0000-0000-0000000000f9
PLINE=00000000-0000-0000-0000-0000000000fa
PPAY=00000000-0000-0000-0000-0000000000fb
PM1=00000000-0000-0000-0000-0000000000fc
PM2=00000000-0000-0000-0000-0000000000fd
PM3=00000000-0000-0000-0000-0000000000fe
PLINE2=00000000-0000-0000-0000-0000000000ff

cleanup_pay() {
  psql_db -c "delete from public.audit_log where entity_id in ('$PBOOK', '$PLINE', '$PLINE2', '$PPAY', '${ALERT:-}', '${SBOOK:-}', '${CBOOK:-}')" \
          -c "delete from public.site_table_booking_club_payments where booking_id = '$PBOOK'" \
          -c "delete from public.site_table_bookings where id = '$PBOOK'" \
          -c "delete from public.site_night_closes where venue_id = '$PVEN'" \
          -c "delete from public.site_venues where id = '$PVEN'" \
          -c "delete from public.site_organizations where id = '$PORG'" \
          -c "delete from auth.users where id in ('$PU', '$PV1', '$PV2', '$POWN')" >/dev/null 2>&1 || true
}
trap 'rm -f "$OUT_A" "$OUT_B" "$OUT_C" "$OUT_D" "$OUT_E" "$OUT_F" "$OUT_G" "$OUT_H" "$OUT_I" "$OUT_J" "$OUT_K" "$OUT_L" "$OUT_M" "$OUT_N" "$OUT_O" "$OUT_P" "$OUT_Q" "$OUT_S" "$OUT_T" "$OUT_U" "$OUT_V" "$OUT_W"; reset; cleanup_door; cleanup_setup; cleanup_requests; cleanup_pay' EXIT
cleanup_pay

psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$PU', 'pserver@test.example'), ('$PV1', 'pver1@test.example'), ('$PV2', 'pver2@test.example'), ('$POWN', 'powner@test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$PORG', 'Pay Co', 'venue_owner', '$POWN');
insert into public.site_venues (id, name, org_id) values ('$PVEN', 'Pay Club', '$PORG');
insert into public.site_memberships (id, org_id, user_id, role, venue_id)
  values ('$PM1', '$PORG', '$PU', 'server', '$PVEN'), ('$PM2', '$PORG', '$PV1', 'verifier', '$PVEN'), ('$PM3', '$PORG', '$PV2', 'verifier', '$PVEN');
insert into public.site_table_types (id, venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values ('$PTYPE', '$PVEN', 'Booth', 6, 0, 0, 3);
insert into public.site_venue_time_slots (id, venue_id, day_of_week, start_time, label) values ('$PSLOT', '$PVEN', 6, '21:00', 'Evening');
insert into public.site_table_bookings (id, venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
  values ('$PBOOK', '$PVEN', '$PTYPE', '$PSLOT', current_date + 3, 'Pay Guest', 'payguest@test.example', 2, 10000, 'paid');
insert into public.site_booking_servers (booking_id, membership_id, assigned_by) values ('$PBOOK', '$PM1', '$PU');
insert into public.site_table_booking_bottles (id, booking_id, bottle_name, unit_price_cents, quantity, line_total_cents, payment_status, service_status)
  values ('$PLINE', '$PBOOK', 'Race Bottle', 5000, 1, 5000, 'paid', 'awaiting_prep');
SQL

# --- 1. the same receipt twice at once
OUT_I=$(mktemp); OUT_J=$(mktemp)
psql_db >"$OUT_I" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
select 'A:duplicate=' || (public.desk_record_payment('$PBOOK', 4000, 4000, 'cash', null, null, '$PBOOK/race.jpg') ->> 'duplicate');
select pg_sleep(2);
commit;
SQL
PID_I=$!
sleep 0.7
START=$SECONDS
psql_db >"$OUT_J" <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
select 'B:duplicate=' || (public.desk_record_payment('$PBOOK', 4000, 4000, 'cash', null, null, '$PBOOK/race.jpg') ->> 'duplicate');
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_I"
PAYMENTS=$(psql_db -c "select count(*) from public.site_table_booking_club_payments where booking_id = '$PBOOK'")
PAID=$(psql_db -c "select amount_paid_cents from public.site_table_bookings where id = '$PBOOK'")
LOGGED=$(psql_db -c "select count(*) from public.audit_log where action = 'table_booking.club_payment_recorded' and entity_id = '$PBOOK'")
fail_pay() { echo "FAIL - payment concurrency: $1 (payments: $PAYMENTS, paid: $PAID, logged: $LOGGED, session B waited ${WAITED}s, A said: $(tr '\n' ' ' <"$OUT_I"), B said: $(tr '\n' ' ' <"$OUT_J"))"; exit 1; }
grep -q '^A:duplicate=false' "$OUT_I"  || fail_pay "the first tap should have recorded the payment"
grep -q '^B:duplicate=true' "$OUT_J"   || fail_pay "the second tap should have been told it is a repeat"
[ "$PAYMENTS" = "1" ]                  || fail_pay "expected exactly one payment"
[ "$PAID" = "4000" ]                   || fail_pay "the booking should have been credited once"
[ "$LOGGED" = "1" ]                    || fail_pay "expected exactly one log entry"
[ "$WAITED" -ge 1 ]                    || fail_pay "session B did not wait for the booking lock"
echo "ok - one receipt sent twice at once: exactly one payment recorded, the other waited ${WAITED}s and was told it is a repeat"

# --- 2. two verifiers on one payment
psql_db >/dev/null <<SQL
insert into public.site_table_booking_club_payments (id, booking_id, billed_amount_cents, amount_paid_cents, payment_method, recorded_by, missing_receipt_reason)
  values ('$PPAY', '$PBOOK', 100, 100, 'cash', '$PU', 'seeded');
SQL
OUT_K=$(mktemp); OUT_L=$(mktemp)
psql_db >"$OUT_K" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$PV1","role":"authenticated","email":"pver1@test.example"}', true) is not null;
set local role authenticated;
select 'A:verified' from (select public.desk_verify_payment('$PPAY', 'first')) s;
select pg_sleep(2);
commit;
SQL
PID_K=$!
sleep 0.7
START=$SECONDS
psql -X -q -t -A -d "$DB" >"$OUT_L" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$PV2","role":"authenticated","email":"pver2@test.example"}', true) is not null;
set local role authenticated;
select 'B:verified' from (select public.desk_verify_payment('$PPAY', 'second')) s;
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_K"
VERIFIER=$(psql_db -c "select manager_verified_by || '|' || manager_verified_note from public.site_table_booking_club_payments where id = '$PPAY'")
VERIFIED_LOGGED=$(psql_db -c "select count(*) from public.audit_log where action = 'table_booking.club_payment_manager_verified' and entity_id = '$PPAY'")
fail_ver() { echo "FAIL - verification concurrency: $1 (kept: $VERIFIER, logged: $VERIFIED_LOGGED, session B waited ${WAITED}s, B said: $(tr '\n' ' ' <"$OUT_L"))"; exit 1; }
grep -q '^A:verified' "$OUT_K"                     || fail_ver "the first verifier should have verified it"
! grep -q '^B:verified' "$OUT_L"                   || fail_ver "the second verifier must not also verify it"
grep -q 'this payment was already verified' "$OUT_L" || fail_ver "the second verifier should be told it was already verified"
[ "$VERIFIER" = "$PV1|first" ]                     || fail_ver "the first verifier's name and note should stand"
[ "$VERIFIED_LOGGED" = "1" ]                       || fail_ver "exactly one verification should be logged"
[ "$WAITED" -ge 1 ]                                || fail_ver "session B did not wait for the row lock"
echo "ok - two verifiers pressing Verify at once: exactly one verified it, the other waited ${WAITED}s and was told it was already verified"

# --- 3. the same order tapped twice
OUT_M=$(mktemp); OUT_N=$(mktemp)
psql_db >"$OUT_M" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
select 'A:changed=' || public.desk_set_service_status('$PLINE', 'preparing');
select pg_sleep(2);
commit;
SQL
PID_M=$!
sleep 0.7
START=$SECONDS
psql_db >"$OUT_N" <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
select 'B:changed=' || public.desk_set_service_status('$PLINE', 'preparing');
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_M"
MOVES=$(psql_db -c "select count(*) from public.audit_log where action = 'table_booking.bottle_service_status_updated' and entity_id = '$PLINE'")
fail_svc() { echo "FAIL - order concurrency: $1 (moves logged: $MOVES, session B waited ${WAITED}s, A said: $(tr '\n' ' ' <"$OUT_M"), B said: $(tr '\n' ' ' <"$OUT_N"))"; exit 1; }
grep -q '^A:changed=true' "$OUT_M"   || fail_svc "the first tap should have moved the order"
grep -q '^B:changed=false' "$OUT_N"  || fail_svc "the second tap should be told nothing changed"
[ "$MOVES" = "1" ]                   || fail_svc "exactly one move should be logged"
[ "$WAITED" -ge 1 ]                  || fail_svc "session B did not wait for the booking lock"
echo "ok - one order tapped twice at once: it moved once, the other waited ${WAITED}s and was told nothing changed"

# --- 4. a payment settling the table, and the delivery that waits for it
psql_db >/dev/null <<SQL
insert into public.site_table_booking_bottles (id, booking_id, bottle_name, unit_price_cents, quantity, line_total_cents, payment_status, service_status)
  values ('$PLINE2', '$PBOOK', 'Pay At Venue Bottle', 6000, 1, 6000, 'due_at_venue', 'ready');
SQL
BALANCE_BEFORE=$(psql_db -c "select greatest(amount_total_cents - amount_paid_cents, 0) from public.site_table_bookings where id = '$PBOOK'")
OUT_O=$(mktemp); OUT_P=$(mktemp)
psql_db >"$OUT_O" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
select 'A:balance_after=' || (public.desk_record_payment('$PBOOK', 6000, 6000, 'cash', null, null, '$PBOOK/settle.jpg') ->> 'balance_due_cents');
select pg_sleep(2);
commit;
SQL
PID_O=$!
sleep 0.7
START=$SECONDS
psql -X -q -t -A -d "$DB" >"$OUT_P" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
select 'B:delivered=' || public.desk_set_service_status('$PLINE2', 'served');
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_O"
STATE=$(psql_db -c "select service_status from public.site_table_booking_bottles where id = '$PLINE2'")
fail_pd() { echo "FAIL - payment-then-delivery concurrency: $1 (balance before: $BALANCE_BEFORE, item: $STATE, session B waited ${WAITED}s, A said: $(tr '\n' ' ' <"$OUT_O"), B said: $(tr '\n' ' ' <"$OUT_P"))"; exit 1; }
[ "$BALANCE_BEFORE" -gt 0 ]              || fail_pd "the table should owe something before the payment"
grep -q '^A:balance_after=0' "$OUT_O"    || fail_pd "the payment should have settled the table"
grep -q '^B:delivered=true' "$OUT_P"     || fail_pd "the delivery should have gone through once the payment was in"
[ "$STATE" = "served" ]                  || fail_pd "the item should be delivered"
[ "$WAITED" -ge 1 ]                      || fail_pd "session B did not wait for the booking lock"
echo "ok - a payment settling the table and a delivery at the same moment: the delivery waited ${WAITED}s and saw the table paid"

# --- 9. the same cash handed in twice at once (the whole cash held, tapped twice)
CBOOK=$(psql_db -c "insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
  values ('$PVEN', '$PTYPE', '$PSLOT', current_date + 30, 'Cash Guest', 'cashguest@test.example', 2, 4000, 'paid') returning id")
psql_db -c "insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, recorded_by, missing_receipt_reason)
  values ('$CBOOK', 4000, 4000, 'cash', '$PU', 'seeded')" >/dev/null
OUT_Q=$(mktemp)
psql_db >"$OUT_Q" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
select 'A:handed in as ' || public.desk_submit_handover('$PVEN', current_date + 30, 4000)::text;
select pg_sleep(2);
commit;
SQL
PID_Q=$!
sleep 0.7
START=$SECONDS
OUT_R=$(psql_db 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
do \$\$ begin
  perform public.desk_submit_handover('$PVEN', current_date + 30, 4000);
  raise notice 'B:handed in';
exception when others then raise notice 'B:%', sqlerrm;
end \$\$;
commit;
SQL
)
WAITED=$((SECONDS - START))
wait "$PID_Q"
HANDOVERS=$(psql_db -c "select count(*) from public.site_cash_handovers where venue_id = '$PVEN' and business_night = current_date + 30")
CLAIMED=$(psql_db -c "select coalesce(sum(claimed_cents), 0) from public.site_cash_handovers where venue_id = '$PVEN' and business_night = current_date + 30")
fail_cash() { echo "FAIL - cash handover concurrency: $1 (handovers: $HANDOVERS, claimed: $CLAIMED, session B waited ${WAITED}s, A said: $(tr '\n' ' ' <"$OUT_Q"), B said: $(echo "$OUT_R" | tr '\n' ' '))"; exit 1; }
grep -q '^A:handed in as ' "$OUT_Q"                       || fail_cash "the first tap should have handed the cash in"
echo "$OUT_R" | grep -q 'B:you are not holding any cash'   || fail_cash "the second tap should have found nothing left to hand in"
[ "$HANDOVERS" = "1" ]                                      || fail_cash "expected exactly one handover"
[ "$CLAIMED" = "4000" ]                                     || fail_cash "the cash should have been handed in once"
[ "$WAITED" -ge 1 ]                                         || fail_cash "session B did not wait for the first tap"
echo "ok - the same cash handed in twice at once: exactly one handover, the other waited ${WAITED}s and found nothing left to hand in"

# --- 10. the same guest seated twice at once (a scan and a search, or a double tap)
SBOOK=$(psql_db -c "insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
  values ('$PVEN', '$PTYPE', '$PSLOT', current_date + 31, 'Seat Guest', 'seatguest@test.example', 2, 4000, 'paid', 'SEAT01') returning id")
psql_db -c "insert into public.site_booking_servers (booking_id, membership_id, assigned_by) values ('$SBOOK', '$PM1', '$PU')" >/dev/null
OUT_S=$(mktemp); OUT_T=$(mktemp)
psql_db >"$OUT_S" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
select 'A:already=' || (public.desk_mark_seated('$SBOOK', 'scan', null, 20) ->> 'already');
select pg_sleep(2);
commit;
SQL
PID_S=$!
sleep 0.7
START=$SECONDS
psql_db >"$OUT_T" <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$PU","role":"authenticated","email":"pserver@test.example"}', true) is not null;
set local role authenticated;
select 'B:already=' || (public.desk_mark_seated('$SBOOK', 'scan', null, 30) ->> 'already');
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_S"
SEATINGS=$(psql_db -c "select count(*) from public.site_booking_seating where booking_id = '$SBOOK'")
ACKS=$(psql_db -c "select count(*) from public.site_outbox where ref_id = '$SBOOK' and kind = 'seated_ack'")
EST=$(psql_db -c "select estimate_minutes from public.site_booking_seating where booking_id = '$SBOOK'")
fail_seat() { echo "FAIL - seating concurrency: $1 (seatings: $SEATINGS, acknowledgments: $ACKS, estimate: $EST, session B waited ${WAITED}s, A said: $(tr '\n' ' ' <"$OUT_S"), B said: $(tr '\n' ' ' <"$OUT_T"))"; exit 1; }
grep -q '^A:already=false' "$OUT_S"  || fail_seat "the first tap should have seated the guest"
grep -q '^B:already=true' "$OUT_T"   || fail_seat "the second tap should have been told the guest is already seated"
[ "$SEATINGS" = "1" ]                || fail_seat "expected exactly one seating"
[ "$ACKS" = "1" ]                    || fail_seat "expected exactly one acknowledgment to the guest"
[ "$EST" = "20" ]                    || fail_seat "the first estimate should stand (the second tap changes nothing)"
[ "$WAITED" -ge 1 ]                  || fail_seat "session B did not wait for the booking lock"
echo "ok - a guest seated twice at once: exactly one seating and one message, the other waited ${WAITED}s and was told it is done"

# --- 11. the same alert taken by two people at once (two security staff both tap Acknowledge)
psql_db >/dev/null <<SQL
insert into public.site_memberships (org_id, user_id, role, venue_id) values ('$PORG', '$PV1', 'security', '$PVEN'), ('$PORG', '$PV2', 'security', '$PVEN');
SQL
ALERT=$(psql_db -c "insert into public.site_security_alerts (venue_id, business_night, kind, urgent, location, raised_by)
  values ('$PVEN', current_date, 'fight', true, 'Terrace', '$PU') returning id")
OUT_U=$(mktemp); OUT_V=$(mktemp)
psql_db >"$OUT_U" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$PV1","role":"authenticated","email":"pver1@test.example"}', true) is not null;
set local role authenticated;
select 'A:changed=' || (public.security_alert_act('$ALERT', 'acknowledge') ->> 'changed');
select pg_sleep(2);
commit;
SQL
PID_U=$!
sleep 0.7
START=$SECONDS
psql_db >"$OUT_V" <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$PV2","role":"authenticated","email":"pver2@test.example"}', true) is not null;
set local role authenticated;
select 'B:changed=' || (public.security_alert_act('$ALERT', 'acknowledge') ->> 'changed');
commit;
SQL
WAITED=$((SECONDS - START))
wait "$PID_U"
HOLDER=$(psql_db -c "select acknowledged_by from public.site_security_alerts where id = '$ALERT'")
STATUS=$(psql_db -c "select status from public.site_security_alerts where id = '$ALERT'")
LOGGED=$(psql_db -c "select count(*) from public.audit_log where entity_id = '$ALERT' and action = 'security.alert_acknowledge'")
fail_alert() { echo "FAIL - alert concurrency: $1 (holder: $HOLDER, status: $STATUS, logged: $LOGGED, session B waited ${WAITED}s, A said: $(tr '\n' ' ' <"$OUT_U"), B said: $(tr '\n' ' ' <"$OUT_V"))"; exit 1; }
grep -q '^A:changed=true' "$OUT_U"   || fail_alert "the first tap should have taken the alert"
grep -q '^B:changed=false' "$OUT_V"  || fail_alert "the second tap should have been told it is already taken"
[ "$HOLDER" = "$PV1" ]               || fail_alert "the alert should stay with the first person"
[ "$STATUS" = "acknowledged" ]       || fail_alert "the alert should be acknowledged"
[ "$LOGGED" = "1" ]                  || fail_alert "expected exactly one 'taken' entry in the audit log"
[ "$WAITED" -ge 1 ]                  || fail_alert "session B did not wait for the alert's lock"
echo "ok - an alert taken by two people at once: exactly one holds it, the other waited ${WAITED}s and was told who has it"
rm -f "$OUT_U" "$OUT_V"

# --- 12. the same night closed by two managers at once
psql_db >/dev/null <<SQL
insert into public.site_memberships (org_id, user_id, role, venue_id) values ('$PORG', '$PV1', 'manager', '$PVEN'), ('$PORG', '$PV2', 'manager', '$PVEN');
SQL
OUT_W=$(mktemp)
psql_db >"$OUT_W" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$PV1","role":"authenticated","email":"pver1@test.example"}', true) is not null;
set local role authenticated;
select 'A:closed, exceptions=' || (public.close_night('$PVEN', current_date, true, 'closing with whatever is open') ->> 'exceptions');
select pg_sleep(2);
commit;
SQL
PID_W=$!
sleep 0.7
START=$SECONDS
OUT_X=$(psql_db 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$PV2","role":"authenticated","email":"pver2@test.example"}', true) is not null;
set local role authenticated;
do \$\$ begin
  perform public.close_night('$PVEN', current_date, true, 'closing with whatever is open');
  raise notice 'B:closed';
exception when others then raise notice 'B:%', sqlerrm;
end \$\$;
commit;
SQL
)
WAITED=$((SECONDS - START))
wait "$PID_W"
CLOSES=$(psql_db -c "select count(*) from public.site_night_closes where venue_id = '$PVEN' and business_night = current_date")
CLOSER=$(psql_db -c "select closed_by from public.site_night_closes where venue_id = '$PVEN' and business_night = current_date")
LOGGED=$(psql_db -c "select count(*) from public.audit_log where action = 'night.closed' and entity_id = '$PVEN'")
fail_close() { echo "FAIL - closing concurrency: $1 (closes: $CLOSES, closed by: $CLOSER, logged: $LOGGED, session B waited ${WAITED}s, A said: $(tr '\n' ' ' <"$OUT_W"), B said: $(echo "$OUT_X" | tr '\n' ' '))"; exit 1; }
grep -q '^A:closed' "$OUT_W"                                  || fail_close "the first manager should have closed the night"
echo "$OUT_X" | grep -q 'B:this night is already closed'      || fail_close "the second manager should have been told it is already closed"
[ "$CLOSES" = "1" ]                                           || fail_close "expected exactly one close"
[ "$CLOSER" = "$PV1" ]                                        || fail_close "the first manager should be the one who closed it"
[ "$LOGGED" = "1" ]                                           || fail_close "expected exactly one 'closed' entry in the audit log"
[ "$WAITED" -ge 1 ]                                           || fail_close "session B did not wait for the first close"
echo "ok - a night closed by two managers at once: exactly one close, the other waited ${WAITED}s and was told it is already closed"
rm -f "$OUT_W"
