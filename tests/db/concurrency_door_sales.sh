#!/usr/bin/env bash
# Two door people sell at the same moment. (1) Four tickets are left and each asks for three: only one sale may happen, and the other must be told one is left. (2) The same sale
# (the same person, the same key) arrives twice at once, as a double tap or a retry can: it must be ONE sale, the second answer marked as a repeat.
#
# door_sell_ticket() locks the ticket type while it counts, and looks for the key again once it has the lock. Door A sells and keeps its transaction open for 2 seconds; door B starts
# 0.5 s later and must WAIT for A. Without the lock B would count 4 left, sell 3 more, and 6 would be sold of 4; without the second look the same key would raise a unique-index error.
# Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - door sales concurrency: $1"; exit 1; }
UA=00000000-0000-0000-0000-0000000009e1
UB=00000000-0000-0000-0000-0000000009e2
ORG=00000000-0000-0000-0000-0000000009e3
VEN=00000000-0000-0000-0000-0000000009e4
EV=00000000-0000-0000-0000-0000000009e5
TIER=00000000-0000-0000-0000-0000000009e6
TIER2=00000000-0000-0000-0000-0000000009e7

cleanup() {
  psql_db -c "delete from public.site_order_admissions where order_id in (select id from public.site_orders where event_id = '$EV')" \
          -c "delete from public.audit_log where actor_id in ('$UA', '$UB')" \
          -c "delete from public.site_orders where event_id = '$EV'" \
          -c "delete from public.site_ticket_tiers where event_id = '$EV'" \
          -c "delete from public.site_events where id = '$EV'" \
          -c "delete from public.site_memberships where org_id = '$ORG'" \
          -c "delete from public.site_venues where id = '$VEN'" \
          -c "delete from public.site_organizations where id = '$ORG'" \
          -c "delete from auth.users where id in ('$UA', '$UB')" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$UA', 'doora@sales.test.example'), ('$UB', 'doorb@sales.test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$ORG', 'Sales Race Co', 'venue_owner', '$UA');
insert into public.site_venues (id, name, org_id) values ('$VEN', 'Sales Race Club', '$ORG');
insert into public.site_memberships (org_id, user_id, role, venue_id) values ('$ORG', '$UA', 'door', '$VEN'), ('$ORG', '$UB', 'door', '$VEN');
insert into public.site_events (id, title, description, venue_name, start_date, end_date, status, venue_id) values ('$EV', 'Sales Race Night', 'd', 'Sales Race Club', now() + interval '1 hour', now() + interval '9 hours', 'published', '$VEN');
insert into public.site_ticket_tiers (id, event_id, name, price_cents, capacity, sold_count) values ('$TIER', '$EV', 'Last Four', 5000, 10, 6), ('$TIER2', '$EV', 'Plenty', 2000, 100, 0);
SQL
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
claims() { echo "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\",\"email\":\"$2\"}', true) is not null;"; }
sell() { echo "select 'R:' || (r ->> 'quantity') || ':' || (r ->> 'available') || ':' || (r ->> 'repeated') || ':' || (r ->> 'order_id') from (select public.door_sell_ticket('$EV', '$1', $2, 'cash', 'Race Guest', null, null, null, '$3') as r) x;"; }

# ---- 1. the last tickets
psql_db >"$OUT_A" <<SQL &
begin;
$(claims "$UA" doora@sales.test.example)
set local role authenticated;
$(sell "$TIER" 3 key-race-last-a)
select pg_sleep(2);
commit;
SQL
PID_A=$!
sleep 0.5
START=$(now_ms)
set +e
psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" >"$OUT_B" 2>&1 <<SQL
begin;
$(claims "$UB" doorb@sales.test.example)
set local role authenticated;
$(sell "$TIER" 3 key-race-last-b)
commit;
SQL
set -e
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

SOLD=$(psql_db -c "select sold_count from public.site_ticket_tiers where id = '$TIER'")
ORDERS=$(psql_db -c "select count(*) from public.site_orders where tier_id = '$TIER'")
grep -q '^R:3:1:false:' "$OUT_A"                            || fail "door A should have sold 3 (1 left): $(cat "$OUT_A")"
grep -q 'only 1 of these tickets are left' "$OUT_B"         || fail "door B should have been told only 1 is left, after waiting: $(cat "$OUT_B")"
[ "$SOLD" = "9" ]                                            || fail "9 of 10 should be sold (6 before + 3), got $SOLD"
[ "$ORDERS" = "1" ]                                          || fail "exactly one order should exist for the last tickets, got $ORDERS"
[ "$WAITED" -ge 1000 ]                                       || fail "door B did not wait for A's lock (${WAITED} ms)"
echo "ok - two doors selling 3 of the last 4 at once: one sold, the other waited ${WAITED} ms and was told only 1 is left"

# ---- 2. the same sale arriving twice at once
psql_db >"$OUT_A" <<SQL &
begin;
$(claims "$UA" doora@sales.test.example)
set local role authenticated;
$(sell "$TIER2" 1 key-race-double-1)
select pg_sleep(2);
commit;
SQL
PID_A=$!
sleep 0.5
START=$(now_ms)
set +e
psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" >"$OUT_B" 2>&1 <<SQL
begin;
$(claims "$UA" doora@sales.test.example)
set local role authenticated;
$(sell "$TIER2" 1 key-race-double-1)
commit;
SQL
set -e
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

SOLD2=$(psql_db -c "select sold_count from public.site_ticket_tiers where id = '$TIER2'")
ORDERS2=$(psql_db -c "select count(*) from public.site_orders where tier_id = '$TIER2'")
ID_A=$(grep '^R:' "$OUT_A" | cut -d: -f5)
grep -q '^R:1:99:false:' "$OUT_A"                           || fail "the first request should have made the sale: $(cat "$OUT_A")"
grep -q "^R:1:99:true:$ID_A\$" "$OUT_B"                     || fail "the second request should be the same sale, marked as a repeat: $(cat "$OUT_B")"
[ "$SOLD2" = "1" ]                                           || fail "one ticket should be counted, got $SOLD2"
[ "$ORDERS2" = "1" ]                                         || fail "one order should exist, got $ORDERS2"
[ "$WAITED" -ge 1000 ]                                       || fail "the second request did not wait (${WAITED} ms)"
echo "ok - the same sale sent twice at once is one sale (the second waited ${WAITED} ms and was answered as a repeat)"
