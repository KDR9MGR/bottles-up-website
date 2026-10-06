#!/usr/bin/env bash
# The verify_ticket_otp() fix, guarded the same way as the check-in fix (scenarios in guard_lib.sh), plus what is specific to it:
# the three defects are REPRODUCED in the old version, then shown cured in the fixed one. Leaves the fixed function in place.
#
#   1. a correct code admitted a guest of an event that had ended
#   2. an ordinary ticket answered "ok" but was never marked used (so it could be admitted again)
#   3. a missing code skipped the wrong-code branch and admitted the guest
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
MIG=supabase/migrations/20260830130000_fix_verify_ticket_otp_expiry.sql
BEFORE=tests/db/fixtures/verify_ticket_otp_before_fix.sql
FN=verify_ticket_otp
FN_ARGS="p_ticket_code text, p_code text"
AUDIT=supabase/audit/verify_otp_after_event.sql
STAFF=00000000-0000-0000-0000-0000000000a1
E1=00000000-0000-0000-0000-0000000000e1; E2=00000000-0000-0000-0000-0000000000e2; E3=00000000-0000-0000-0000-0000000000e3
B1=00000000-0000-0000-0000-0000000000b1; B2=00000000-0000-0000-0000-0000000000b2; B3=00000000-0000-0000-0000-0000000000b3; B4=00000000-0000-0000-0000-0000000000b4
# shellcheck source=tests/db/guard_lib.sh
. tests/db/guard_lib.sh

verify() {  # verify <ticket code> <code or NULL> : one real call as door staff, committed; prints the result
  local code="$2"; [ "$code" = "NULL" ] || code="'$2'"
  psql_db <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$STAFF","role":"authenticated"}', true) is not null;
set local role authenticated;
select result from public.verify_ticket_otp('$1', $code);
commit;
SQL
}
# (the helper prints the set_config result before the answer, so callers use the last line)
vr() { verify "$@" | tail -n 1; }
admitted() { psql_db -c "select count(*) from public.site_orders where ticket_code = '$1' and checked_in_at is not null"; }
seed() {  # three committed orders, each exercising one defect; non-transferable ones get a valid code (123456)
  psql_db >/dev/null <<SQL
insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, is_non_transferable) values
  ('$E2', '$B3', 'G Ended', 'gended@test.example', 1, 5000, 'paid', 'GV-ENDED', true),
  ('$E1', '$B1', 'G Plain', 'gplain@test.example', 1, 5000, 'paid', 'GV-PLAIN', false),
  ('$E1', '$B2', 'G Null',  'gnull@test.example',  1, 9000, 'paid', 'GV-NULL',  true),
  ('$E3', '$B4', 'G Stale', 'gstale@test.example', 1, 5000, 'paid', 'GV-STALE', true);   -- an event with NO end time, started 13h ago
insert into public.ticket_otp_codes (order_id, code_hash, sent_to_email, expires_at)
  select id, crypt('123456', gen_salt('bf', 4)), customer_email, now() + interval '5 minutes'
  from public.site_orders where ticket_code in ('GV-ENDED', 'GV-NULL', 'GV-STALE');
SQL
}
clean_data() {
  psql_db -c "delete from public.scan_attempts where ticket_code_attempted like 'GV-%'" \
          -c "delete from public.site_orders where ticket_code like 'GV-%'" >/dev/null
}
trap clean_data EXIT
clean_data

guard_declared
guard_already_fixed
guard_hand_edited
guard_whitespace

# The old version has all three defects.
psql_db -f "$BEFORE" >/dev/null
[ "$(fp)" = "$DECLARED_BEFORE" ]                 || fail "the migration declares fingerprint $DECLARED_BEFORE for the old function, but the repository version is $(fp)"
seed
[ "$(vr GV-ENDED 123456)" = "ok" ] && [ "$(admitted GV-ENDED)" = "1" ] || fail "test setup: the old version should admit a guest of an ended event on a correct code"
[ "$(vr GV-PLAIN '')" = "ok" ]     && [ "$(admitted GV-PLAIN)" = "0" ] || fail "test setup: the old version should answer ok for an ordinary ticket without marking it used"
[ "$(vr GV-NULL NULL)" = "ok" ]    && [ "$(admitted GV-NULL)" = "1" ]  || fail "test setup: the old version should admit on a missing code"
[ "$(vr GV-STALE 123456)" = "ok" ]   && [ "$(admitted GV-STALE)" = "1" ] || fail "test setup: the old version should admit a guest of an event with no end time, 13 hours after it started"
# The one defect that leaves a trace is findable: a code accepted after the event had ended (an event with no end time counts as
# over 12 hours after it started).
AUDIT_OUT=$(psql -X -t -A -F '|' -v ON_ERROR_STOP=1 -d "$DB" -f "$AUDIT" 2>&1) || fail "the audit script failed: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -q "GV-ENDED"             || fail "the audit did not list the guest admitted by code after the event ended: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -q "GV-STALE"             || fail "the audit did not list the guest admitted after an event with no end time had passed its 12-hour window: $AUDIT_OUT"
echo "$AUDIT_OUT" | grep -q "GV-NULL"              && fail "the audit listed a code accepted BEFORE the event ended: $AUDIT_OUT"
clean_data

# The migration cures all three.
run_mig
[ "$RC" = "0" ]                                  || fail "the migration failed on the old version: $OUT"
echo "$OUT" | grep -q "fixed"                      || fail "expected the 'fixed' notice, got: $OUT"
[ "$(fp)" = "$FIXED" ]                           || fail "the fixed function does not match the fingerprint the migration declares"
seed
[ "$(vr GV-ENDED 123456)" = "expired" ] && [ "$(admitted GV-ENDED)" = "0" ] || fail "an ended event still admits on a correct code"
[ "$(vr GV-STALE 123456)" = "expired" ] && [ "$(admitted GV-STALE)" = "0" ] || fail "an event with no end time still admits on a correct code 13 hours after it started"
[ "$(vr GV-PLAIN '')" = "ok" ]          && [ "$(admitted GV-PLAIN)" = "1" ] || fail "an ordinary ticket is not really marked used"
[ "$(vr GV-NULL NULL)" = "code_incorrect" ] && [ "$(admitted GV-NULL)" = "0" ] || fail "a missing code still admits"
[ "$(vr GV-NULL 123456)" = "ok" ]       && [ "$(admitted GV-NULL)" = "1" ] || fail "the real code no longer works after a missing one"
AFTER_AUDIT=$(psql -X -t -A -F '|' -v ON_ERROR_STOP=1 -d "$DB" -f "$AUDIT" 2>&1)
echo "$AFTER_AUDIT" | grep -q "GV-"                && fail "after the fix the audit should find nothing new: $AFTER_AUDIT"

guard_missing_then_restore
echo "ok - verify_ticket_otp fix: guarded like the check-in fix, and the three old defects (ended event, ordinary ticket not marked used, missing code) are reproduced and cured"
