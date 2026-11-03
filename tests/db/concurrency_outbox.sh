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
fail() {
  echo "FAIL - outbox concurrency: $1"
  if [ -n "${OUT_A:-}" ]; then echo "--- run A output:"; head -5 "$OUT_A"; echo "--- run B output:"; head -5 "$OUT_B"; fi
  # This failed intermittently in CI (30 Oct: run B was handed nothing and raised no error, while run A got its 20) and never on a developer machine in 65 runs,
  # so when it does, say what the database looked like: where the 40 messages were, and who was still running.
  echo "--- the race messages now (status, attempts, claimed or not, how many):"
  psql_db -F ' | ' -c "select status, attempts, (claimed_at is not null) as claimed, count(*) from public.site_outbox where payload ->> 'race' = 'outbox' group by 1, 2, 3 order by 1, 2, 3" 2>&1 || true
  echo "--- messages that were NOT part of this race and could still have been handed out (queued, unclaimed or claim older than 10 minutes):"
  psql_db -F ' | ' -c "select kind, attempts, claimed_at, created_at from public.site_outbox where status = 'queued' and coalesce(payload ->> 'race', '') <> 'outbox' and attempts < 5 and (claimed_at is null or claimed_at < clock_timestamp() - interval '10 minutes') limit 10" 2>&1 || true
  echo "--- database sessions at this moment (pid, state, waiting on, started, query):"
  psql_db -F ' | ' -c "select pid, state, wait_event_type, backend_start, left(query, 70) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() order by backend_start" 2>&1 || true
  exit 1
}

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

# (no match must reach the checks below, which say what went wrong: with pipefail a run that was handed nothing would end the script here without a word)
A_IDS=$(grep '^A:' "$OUT_A" | sed 's/^A://' | sort || true)
B_IDS=$(grep '^B:' "$OUT_B" | sed 's/^B://' | sort || true)
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
