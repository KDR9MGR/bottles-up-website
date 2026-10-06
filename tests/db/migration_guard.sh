#!/usr/bin/env bash
# The checkin_ticket() fix replaces a LIVE function, and the live one may not be the one this repository describes. So the
# migration is a compare-and-swap: it replaces the function only if it is exactly the version it was written against.
# This runs the real migration file against a database put into each situation and checks what it does:
#
#   already fixed   -> no-op, safe to run twice
#   hand-edited     -> STOPS, changes nothing (never overwrites an unknown version)
#   whitespace only -> still treated as the known version (formatting is not drift)
#   old version     -> replaced; expired and code-protected tickets are then refused WITHOUT being admitted
#   missing         -> stops with a clear message
#
# It also reproduces the bug in the old version and checks that supabase/audit/checkin_fallthrough.sql finds the damage.
# Leaves the database with the fixed function, as it found it.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
MIG=supabase/migrations/20260830120000_fix_checkin_ticket_early_returns.sql
BEFORE=tests/db/fixtures/checkin_ticket_before_fix.sql
AUDIT=supabase/audit/checkin_fallthrough.sql
STAFF=00000000-0000-0000-0000-0000000000a1

psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fp() {
  psql_db -c "select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'checkin_ticket' and pg_get_function_identity_arguments(p.oid) = 'p_ticket_code text'"
}
fail() { echo "FAIL - migration guard: $1"; exit 1; }

# Run the migration; sets RC (exit code) and OUT (everything it printed).
run_mig() { OUT=$(psql -X -v ON_ERROR_STOP=1 -d "$DB" -f "$MIG" 2>&1) && RC=0 || RC=$?; }
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

FIXED=$(fp)

# The fingerprints the migration DECLARES must be what the functions really have. If someone edits the function text in the
# migration and forgets the constant, the guard would later refuse to recognise an already-fixed database in production.
DECLARED_AFTER=$(grep -E "c_after +constant" "$MIG" | grep -oE "[0-9a-f]{32}")
DECLARED_BEFORE=$(grep -E "c_before +constant" "$MIG" | grep -oE "[0-9a-f]{32}")
[ "$FIXED" = "$DECLARED_AFTER" ]                 || fail "the migration declares fingerprint $DECLARED_AFTER for the fixed function, but it really is $FIXED"

# 1. Already fixed: a no-op.
run_mig
[ "$RC" = "0" ]                                  || fail "running the migration on a fixed database failed: $OUT"
echo "$OUT" | grep -q "already has this fix"       || fail "expected the 'already has this fix' notice, got: $OUT"
[ "$(fp)" = "$FIXED" ]                           || fail "a no-op run changed the function"

# 2. Hand-edited: must stop and change nothing.
sed 's/v_result text;/v_result text; -- a hotfix someone made directly in the database/' "$BEFORE" | psql_db >/dev/null
DRIFTED=$(fp)
[ "$DRIFTED" != "$FIXED" ]                       || fail "test setup: the hand-edited function should differ"
run_mig
[ "$RC" != "0" ]                                 || fail "the migration replaced a function it does not recognise"
echo "$OUT" | grep -q "differs from the version"  || fail "expected the 'differs' error, got: $OUT"
echo "$OUT" | grep -q "Nothing was changed"       || fail "the error should say nothing was changed"
[ "$(fp)" = "$DRIFTED" ]                         || fail "a refused migration still changed the function"
psql_db -c "select prosrc from pg_proc where proname = 'checkin_ticket'" | grep -q "a hotfix someone made" || fail "the hand-edit was lost"

# 2b. The fingerprint also covers HOW the function runs: the same body made SECURITY INVOKER, or given a different
#     search_path, is a different function and must not be overwritten.
sed 's/^security definer$/security invoker/' "$BEFORE" | psql_db >/dev/null
[ "$(fp)" != "$FIXED" ] && [ "$(fp)" != "$DRIFTED" ] || fail "test setup: the security-invoker copy should be its own state"
run_mig
[ "$RC" != "0" ] && echo "$OUT" | grep -q "differs from the version" || fail "the migration replaced a copy that is not security definer"
sed 's/^set search_path = public$/set search_path = public, pg_temp/' "$BEFORE" | psql_db >/dev/null
run_mig
[ "$RC" != "0" ] && echo "$OUT" | grep -q "differs from the version" || fail "the migration replaced a copy with a different search_path"

# 3. Whitespace-only differences are formatting, not drift: Windows line endings, extra blank lines, extra indentation.
sed -e 's/$/\r/' -e 's/^  /      /' "$BEFORE" | psql_db >/dev/null
[ "$(fp)" != "$FIXED" ]                          || fail "test setup: the reformatted old function should still be the old one"
run_mig
[ "$RC" = "0" ]                                  || fail "a reformatted copy of the known version was treated as drift: $OUT"
[ "$(fp)" = "$FIXED" ]                           || fail "the reformatted old version was not replaced by the fix"

# 4. The old version really has the bug, the audit finds what it did, and the migration cures it.
psql_db -f "$BEFORE" >/dev/null
[ "$(fp)" = "$DECLARED_BEFORE" ]               || fail "the migration declares fingerprint $DECLARED_BEFORE for the old function, but the repository version is $(fp)"
scan T-ENDED; scan T-NT
ADMITTED=$(psql_db -c "select count(*) from public.site_orders where ticket_code in ('T-ENDED', 'T-NT') and checked_in_at is not null")
[ "$ADMITTED" = "2" ]                            || fail "test setup: the old version should have admitted both refused tickets (got $ADMITTED)"
AUDIT_OUT=$(psql -X -t -A -F '|' -v ON_ERROR_STOP=1 -d "$DB" -f "$AUDIT" 2>&1) || fail "the audit script failed: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -q "T-ENDED"              || fail "the audit did not list the expired ticket that was admitted: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -q "T-NT"                 || fail "the audit did not list the code-protected ticket that was admitted: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -qE '^1\|1\|2\|'          || fail "the audit summary should count 1 expired + 1 code-required over 2 orders: $AUDIT_OUT"
psql_db -c "select count(*) from public.scan_attempts" >/dev/null   # the audit is read-only: the log is still there
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

# 5. Missing function: stop with a clear message, then put everything back.
psql_db -c "drop function public.checkin_ticket(text)" >/dev/null
run_mig
[ "$RC" != "0" ]                                 || fail "the migration claimed success with no function to fix"
echo "$OUT" | grep -q "does not exist"            || fail "expected a 'does not exist' error, got: $OUT"
psql_db -f "$BEFORE" >/dev/null
run_mig
[ "$RC" = "0" ] && [ "$(fp)" = "$FIXED" ]        || fail "could not restore the fixed function at the end"

echo "ok - checkin_ticket fix: no-op when fixed, refuses a hand-edited function, tolerates formatting, cures the old version (and the audit finds what the bug did)"
