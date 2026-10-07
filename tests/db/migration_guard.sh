#!/usr/bin/env bash
# The checkin_ticket() fix replaces a LIVE function, and the live one may not be the one this repository describes, so the
# migration is a compare-and-swap. The scenarios every such migration must pass are in guard_lib.sh; this adds what is
# specific to this one: it reproduces the bug in the old version, checks that supabase/audit/checkin_fallthrough.sql finds the
# damage (and nothing else), and checks the fixed version no longer admits. Leaves the fixed function in place.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
MIG=supabase/migrations/20260830120000_fix_checkin_ticket_early_returns.sql
BEFORE=tests/db/fixtures/checkin_ticket_before_fix.sql
AUDIT=supabase/audit/checkin_fallthrough.sql
FN=checkin_ticket
FN_ARGS="p_ticket_code text"
STAFF=00000000-0000-0000-0000-0000000000a1
# shellcheck source=tests/db/guard_lib.sh
. tests/db/guard_lib.sh

scan() {  # scan <ticket code> : one real call as door staff, committed
  psql_db >/dev/null <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$STAFF","role":"authenticated"}', true) is not null;
set local role authenticated;
select * from public.checkin_ticket('$1');
commit;
SQL
}
clean_data() {
  psql_db -c "update public.site_orders set checked_in_at = null, checked_in_by = null where ticket_code in ('T-ENDED', 'T-NT', 'T-STALE')" \
          -c "delete from public.scan_attempts where ticket_code_attempted in ('T-ENDED', 'T-NT', 'T-STALE')" >/dev/null
}
trap clean_data EXIT
clean_data

guard_declared
guard_already_fixed
guard_hand_edited
guard_whitespace

# The old version really has the bug, the audit finds what it did, and the migration cures it.
psql_db -f "$BEFORE" >/dev/null
[ "$(fp)" = "$DECLARED_BEFORE" ]                 || fail "the migration declares fingerprint $DECLARED_BEFORE for the old function, but the repository version is $(fp)"
scan T-ENDED; scan T-NT
ADMITTED=$(psql_db -c "select count(*) from public.site_orders where ticket_code in ('T-ENDED', 'T-NT') and checked_in_at is not null")
[ "$ADMITTED" = "2" ]                            || fail "test setup: the old version should have admitted both refused tickets (got $ADMITTED)"
AUDIT_OUT=$(psql -X -t -A -F '|' -v ON_ERROR_STOP=1 -d "$DB" -f "$AUDIT" 2>&1) || fail "the audit script failed: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -q "T-ENDED"              || fail "the audit did not list the expired ticket that was admitted: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -q "T-NT"                 || fail "the audit did not list the code-protected ticket that was admitted: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -qE '^1\|1\|2\|'          || fail "the audit summary should count 1 expired + 1 code-required over 2 orders: $AUDIT_OUT"

# A LEGITIMATE refusal followed, in a separate moment, by an admission (the guest then entered their code) is not the bug and
# must not be flagged: the bug writes both rows in one instant.
psql_db >/dev/null <<SQL
insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by, created_at)
  select 'T-STALE', 'code_required', id, '$STAFF', now() - interval '3 minutes' from public.site_orders where ticket_code = 'T-STALE';
insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by, created_at)
  select 'T-STALE', 'ok', id, '$STAFF', now() - interval '1 minute' from public.site_orders where ticket_code = 'T-STALE';
SQL
AUDIT_OUT=$(psql -X -t -A -F '|' -v ON_ERROR_STOP=1 -d "$DB" -f "$AUDIT" 2>&1)
echo "$AUDIT_OUT" | grep -q "T-STALE"             && fail "the audit flagged a legitimate refuse-then-admit sequence: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -qE '^1\|1\|2\|'          || fail "the audit SUMMARY counted a legitimate refuse-then-admit sequence (it should still be 1 + 1 over 2 orders): $AUDIT_OUT"
clean_data
run_mig
[ "$RC" = "0" ]                                  || fail "the migration failed on the old version: $OUT"
echo "$OUT" | grep -q "fixed"                      || fail "expected the 'fixed' notice, got: $OUT"
[ "$(fp)" = "$FIXED" ]                           || fail "the fixed function does not match the fingerprint the migration declares"
scan T-ENDED; scan T-NT
ADMITTED=$(psql_db -c "select count(*) from public.site_orders where ticket_code in ('T-ENDED', 'T-NT') and checked_in_at is not null")
[ "$ADMITTED" = "0" ]                            || fail "after the fix, a refused ticket was still admitted ($ADMITTED)"
OKS=$(psql_db -c "select count(*) from public.scan_attempts where ticket_code_attempted in ('T-ENDED', 'T-NT') and result = 'ok'")
[ "$OKS" = "0" ]                                 || fail "after the fix, a refused scan was still logged as admitted"
AFTER_AUDIT=$(psql -X -t -A -F '|' -v ON_ERROR_STOP=1 -d "$DB" -f "$AUDIT" 2>&1)
echo "$AFTER_AUDIT" | grep -qE '^0\|0\|0\|'        || fail "after the fix the audit should find nothing new: $AFTER_AUDIT"

guard_missing_then_restore
echo "ok - checkin_ticket fix: no-op when fixed, refuses a hand-edited function, tolerates formatting, cures the old version (and the audit finds what the bug did)"
