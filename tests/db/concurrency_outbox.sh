#!/usr/bin/env bash
# Two runs of the outbox sender at the same moment must never be handed the same message (that would be a guest e-mailed twice).
#
# outbox_claim() picks its messages with FOR UPDATE SKIP LOCKED. Run A claims 20 of 40 queued messages and keeps its transaction open for 2
# seconds; run B starts 0.5s later and asks for up to 50. B must NOT wait for A (without SKIP LOCKED it would sit on A's locks for ~1.5s) and must
# get exactly the other 20, none of A's. (Without SKIP LOCKED the only visible difference is the wait, so the wait is what is measured.) Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - outbox concurrency: $1"; exit 1; }

# Other scripts in this run leave committed rows behind (for example the seating race leaves a queued "seated" message: its venue cannot be
# deleted while other bookings still point at it). They must not take part in this race, so they are parked (held for an hour) and released after.
cleanup() {
  psql_db -c "delete from public.site_outbox where payload ->> 'race' = 'outbox'" \
          -c "update public.site_outbox set claimed_at = null where status = 'queued' and claimed_at > clock_timestamp() + interval '30 minutes'" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db -c "update public.site_outbox set claimed_at = clock_timestamp() + interval '1 hour' where status = 'queued'" >/dev/null
psql_db -c "insert into public.site_outbox (kind, payload, created_at) select 'seated_ack', '{\"race\":\"outbox\"}', now() - (n || ' seconds')::interval from generate_series(1, 40) n" >/dev/null

psql_db >"$OUT_A" <<SQL &
begin;
set local role service_role;
select 'A:' || id from public.outbox_claim(20);
select pg_sleep(2);
commit;
SQL
PID_A=$!

sleep 0.5
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
START=$(now_ms)
psql_db >"$OUT_B" <<SQL
begin;
set local role service_role;
select 'B:' || id from public.outbox_claim(50);
commit;
SQL
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

A_IDS=$(grep '^A:' "$OUT_A" | sed 's/^A://' | sort)
B_IDS=$(grep '^B:' "$OUT_B" | sed 's/^B://' | sort)
NA=$(printf '%s\n' "$A_IDS" | grep -c . || true)
NB=$(printf '%s\n' "$B_IDS" | grep -c . || true)
SHARED=$(comm -12 <(printf '%s\n' "$A_IDS") <(printf '%s\n' "$B_IDS") | grep -c . || true)
HELD=$(psql_db -c "select count(*) from public.site_outbox where payload ->> 'race' = 'outbox' and claimed_at is not null and attempts = 1")

[ "$NA" = "20" ]       || fail "run A should have been handed 20 messages, got $NA"
[ "$NB" = "20" ]       || fail "run B should have been handed the other 20, got $NB"
[ "$SHARED" = "0" ]    || fail "the same message was handed to both runs ($SHARED shared)"
[ "$WAITED" -le 700 ]  || fail "run B waited ${WAITED} ms for A's locks instead of skipping them (A holds them for 1.5 s more)"
[ "$HELD" = "40" ]     || fail "expected all 40 messages held exactly once, got $HELD"
echo "ok - two simultaneous sender runs: 20 and 20 different messages, no waiting, none handed out twice (run B took ${WAITED} ms)"
