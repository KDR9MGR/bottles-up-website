#!/usr/bin/env bash
# Two runs of the report job start at the same moment (the schedule fires while the last run is still going) and there is ONE report waiting. Exactly one of them may take it, and the other must
# not wait for it: it just finds nothing to do.
#
# report_job_claim() takes jobs with FOR UPDATE SKIP LOCKED. Run A takes the job and keeps its transaction open for 2 seconds; run B starts 0.5 s later. Without the lock B would see the job still
# "pending" and take it too (the report would be e-mailed twice); with a plain FOR UPDATE and no SKIP LOCKED B would wait for A. Committed rows are created for this and removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - report jobs concurrency: $1"; exit 1; }
ORG=00000000-0000-0000-0000-0000000009b1
VEN=00000000-0000-0000-0000-0000000009b2
JOB=00000000-0000-0000-0000-0000000009b3

cleanup() {
  psql_db -c "delete from public.site_report_jobs where id = '$JOB'" \
          -c "delete from public.site_venues where id = '$VEN'" \
          -c "delete from public.site_organizations where id = '$ORG'" >/dev/null 2>&1 || true
}
OUT_A=$(mktemp); OUT_B=$(mktemp)
trap 'rm -f "$OUT_A" "$OUT_B"; cleanup' EXIT
cleanup
psql_db >/dev/null <<SQL
insert into public.site_organizations (id, name, kind) values ('$ORG', 'Job Race Club Co', 'venue_owner');
insert into public.site_venues (id, name, org_id) values ('$VEN', 'Job Race Club', '$ORG');
insert into public.site_report_jobs (id, kind, org_id, venue_id, report_ref, revision) values ('$JOB', 'venue_night', '$ORG', '$VEN', '2026-01-01', 1);
SQL
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

psql_db >"$OUT_A" <<SQL &
begin;
set local role service_role;
select 'R:' || count(*) from public.report_job_claim(1);
select pg_sleep(2);
commit;
SQL
PID_A=$!
sleep 0.5
START=$(now_ms)
psql_db >"$OUT_B" <<SQL
begin;
set local role service_role;
select 'R:' || count(*) from public.report_job_claim(1);
commit;
SQL
WAITED=$(( $(now_ms) - START ))
wait "$PID_A"

ATTEMPTS=$(psql_db -c "select attempts from public.site_report_jobs where id = '$JOB'")
grep -q '^R:1$' "$OUT_A"  || fail "run A should have taken the report: $(cat "$OUT_A")"
grep -q '^R:0$' "$OUT_B"  || fail "run B should have found nothing to take: $(cat "$OUT_B")"
[ "$ATTEMPTS" = "1" ]     || fail "the report should have been taken once, got $ATTEMPTS"
[ "$WAITED" -lt 1000 ]    || fail "run B waited for A (${WAITED} ms) instead of skipping the job A holds"
echo "ok - two job runs at once: one took the report, the other did not wait and found nothing (${WAITED} ms)"
