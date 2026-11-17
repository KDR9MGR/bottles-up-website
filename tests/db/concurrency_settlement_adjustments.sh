#!/usr/bin/env bash
# Two adjustments after payment arrive at the same moment (two refunds of the same bottle reported from two screens), and together they would take back more than was paid. The net amount owed
# to the organizer must never go below zero, so only ONE may be recorded and the other must be told so.
#
# settlement_adjustment_record() locks the settlement row while it adds up what is already recorded and writes the new one. Owner A records a refund of the whole amount paid and keeps its
# transaction open for 2 seconds; owner B (a second tap, a second device) asks 0.5 s later and must WAIT for A, then see A's adjustment and be refused. Without the lock B would add up an empty
# list, find room, and both would be recorded: the organizer would be owed less than nothing. Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - settlement adjustments concurrency: $1"; exit 1; }
UA=00000000-0000-0000-0000-0000000009c1
UB=00000000-0000-0000-0000-0000000009c2
ORG=00000000-0000-0000-0000-0000000009c3
ORG2=00000000-0000-0000-0000-0000000009c4
VEN=00000000-0000-0000-0000-0000000009c5
EV=00000000-0000-0000-0000-0000000009c6
AG=00000000-0000-0000-0000-0000000009c7
SET=00000000-0000-0000-0000-0000000009c8

cleanup() {
  psql_db -c "delete from public.site_settlement_adjustment_log where settlement_id = '$SET'" \
          -c "delete from public.site_settlement_adjustments where settlement_id = '$SET'" \
          -c "delete from public.site_settlements where id = '$SET'" \
          -c "delete from public.site_agreements where id = '$AG'" \
          -c "delete from public.site_events where id = '$EV'" \
          -c "delete from public.site_memberships where org_id in ('$ORG', '$ORG2')" \
          -c "delete from public.site_venues where id = '$VEN'" \
          -c "delete from public.site_organizations where id in ('$ORG', '$ORG2')" \
          -c "delete from auth.users where id in ('$UA', '$UB')" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db >/dev/null <<SQL
insert into auth.users (id, email) values ('$UA', 'ownera@adj.test.example'), ('$UB', 'ownerb@adj.test.example');
insert into public.site_organizations (id, name, kind, created_by) values ('$ORG', 'Adjustment Race Club Co', 'venue_owner', '$UA'), ('$ORG2', 'Adjustment Race Events', 'organizer', '$UB');
insert into public.site_venues (id, name, org_id) values ('$VEN', 'Adjustment Race Club', '$ORG');
insert into public.site_memberships (org_id, user_id, role) values ('$ORG', '$UA', 'owner');
insert into public.site_events (id, title, description, venue_name, start_date, end_date, status, org_id) values ('$EV', 'Adjustment Race Night', 'd', 'Adjustment Race Club', now() + interval '1 hour', now() + interval '9 hours', 'draft', '$ORG2');
insert into public.site_agreements (id, event_id, venue_id, organizer_org_id, status, current_version, active_version, requested_by) values ('$AG', '$EV', '$VEN', '$ORG2', 'active', 1, 1, '$UB');
insert into public.site_settlements (id, agreement_id, agreement_version, event_id, venue_id, organizer_org_id, terms, eligible_sales_cents, sales_note, share_cents, status, entered_by,
    approved_by, approved_at, paid_amount_cents, paid_on, payment_reference, paid_recorded_by, paid_recorded_at)
  values ('$SET', '$AG', 1, '$EV', '$VEN', '$ORG2', '{"bar_percent":10,"threshold_cents":0,"formula":"above_threshold"}', 100000, 'Race report', 10000, 'paid', '$UA', '$UA', now(), 10000, current_date, 'RACE-1', '$UA', now());
SQL
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
claims() { echo "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\",\"email\":\"$2\"}', true) is not null;"; }
record() { echo "select 'R:' || public.settlement_adjustment_record('$SET', 'refund', -10000, '$1', '$2');"; }

psql_db >"$OUT_A" <<SQL &
begin;
$(claims "$UA" ownera@adj.test.example)
set local role authenticated;
$(record 'Refund of the whole night' 'RACE-RF-A')
select pg_sleep(2);
commit;
SQL
PID_A=$!
sleep 0.5
START=$(now_ms)
set +e
psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" >"$OUT_B" 2>&1 <<SQL
begin;
$(claims "$UA" ownera@adj.test.example)
set local role authenticated;
$(record 'Refund of the whole night, sent again' 'RACE-RF-B')
commit;
SQL
set -e
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

COUNT=$(psql_db -c "select count(*) from public.site_settlement_adjustments where settlement_id = '$SET'")
SUM=$(psql_db -c "select coalesce(sum(amount_cents), 0) from public.site_settlement_adjustments where settlement_id = '$SET'")
grep -q '^R:' "$OUT_A"                                                   || fail "owner A should have recorded the refund: $(cat "$OUT_A")"
grep -q 'the adjustments cannot take back more than was paid' "$OUT_B"   || fail "owner B should have been refused, after waiting: $(cat "$OUT_B")"
[ "$COUNT" = "1" ]                                                        || fail "exactly one adjustment should exist, got $COUNT"
[ "$SUM" = "-10000" ]                                                     || fail "the adjustments should add up to -10000 (all of what was paid, no more), got $SUM"
[ "$WAITED" -ge 1000 ]                                                    || fail "owner B did not wait for A's lock (${WAITED} ms)"
echo "ok - two refunds of the whole amount at once: one recorded, the other waited ${WAITED} ms and was refused (the organizer is never owed less than nothing)"
