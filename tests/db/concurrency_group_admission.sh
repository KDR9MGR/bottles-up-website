#!/usr/bin/env bash
# Two door people each admit 3 guests of a group of 4 at the same moment: no more than 4 may ever be admitted.
#
# door_admit_group() locks the order while it counts and records. Door A admits 3 and keeps its transaction open for 2 seconds; door B starts 0.5 s later and must WAIT for A,
# then be told only 1 is left ('too_many'). Without the lock B would count 0 admitted, admit 3 more, and 6 guests would be in on a ticket for 4.
# Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - group admission concurrency: $1"; exit 1; }
U=00000000-0000-0000-0000-0000000009d1
ORG=00000000-0000-0000-0000-0000000009d2
VEN=00000000-0000-0000-0000-0000000009d3
EV=00000000-0000-0000-0000-0000000009d4
TIER=00000000-0000-0000-0000-0000000009d5
ORD=00000000-0000-0000-0000-0000000009d6
CODE=GA-RACE-GROUP

cleanup() {
  psql_db -c "delete from public.scan_attempts where ticket_code_attempted = '$CODE'" \
          -c "delete from public.site_order_admissions where order_id = '$ORD'" \
          -c "delete from public.site_orders where id = '$ORD'" \
          -c "delete from public.site_ticket_tiers where id = '$TIER'" \
          -c "delete from public.site_events where id = '$EV'" \
          -c "delete from public.site_memberships where org_id = '$ORG'" \
          -c "delete from public.site_venues where id = '$VEN'" \
          -c "delete from public.site_organizations where id = '$ORG'" \
          -c "delete from auth.users where id = '$U'" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$U', 'racer@group.test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$ORG', 'Race Co', 'venue_owner', '$U');
insert into public.site_venues (id, name, org_id) values ('$VEN', 'Race Club', '$ORG');
insert into public.site_memberships (org_id, user_id, role, venue_id) values ('$ORG', '$U', 'door', '$VEN');
insert into public.site_events (id, title, description, venue_name, start_date, end_date, status, venue_id) values ('$EV', 'Race Night', 'd', 'Race Club', now() + interval '1 hour', now() + interval '9 hours', 'published', '$VEN');
insert into public.site_ticket_tiers (id, event_id, name, price_cents, capacity) values ('$TIER', '$EV', 'General', 5000, 100);
insert into public.site_orders (id, event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code) values ('$ORD', '$EV', '$TIER', 'Race Group', 'group@race.example', 4, 20000, 'paid', '$CODE');
SQL
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
call() { echo "select 'R:' || r.result || ':' || coalesce(r.admitted::text, '-') || ':' || coalesce(r.remaining::text, '-') from public.door_admit_group('$CODE', 3, '$EV') r;"; }

psql_db >"$OUT_A" <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$U","role":"authenticated","email":"racer@group.test.example"}', true) is not null;
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
select set_config('request.jwt.claims', '{"sub":"$U","role":"authenticated","email":"racer@group.test.example"}', true) is not null;
set local role authenticated;
$(call)
commit;
SQL
set -e
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

IN=$(psql_db -c "select coalesce(sum(guests), 0) from public.site_order_admissions where order_id = '$ORD'")
grep -q '^R:ok:3:1$' "$OUT_A"          || fail "door A should have admitted 3 (3 in, 1 left): $(cat "$OUT_A")"
grep -q '^R:too_many:3:1$' "$OUT_B"    || fail "door B should have been told only 1 is left, after waiting: $(cat "$OUT_B")"
[ "$IN" = "3" ]                         || fail "exactly 3 guests should be recorded as admitted, got $IN"
[ "$WAITED" -ge 1000 ]                  || fail "door B did not wait for A's lock (${WAITED} ms)"
echo "ok - two doors admitting 3 of a group of 4 at once: 3 in, the other waited ${WAITED} ms and was told only 1 is left"
