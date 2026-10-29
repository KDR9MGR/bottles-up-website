#!/usr/bin/env bash
# 20261031100000_signup_without_email.sql replaces handle_new_user(), the function of the on_auth_user_created trigger, which exists only in production. Guarded like the check-in and
# entry-code fixes (scenarios in guard_lib.sh, adapted: this function has no search_path to begin with and a trigger hangs on it, so the variants are written out here):
#
#   the known production version (also with Windows line endings and other indentation) -> fixed
#   run again where it is fixed                                                          -> a no-op
#   hand-edited, made security invoker, given a search_path, or missing                  -> STOPS, changes nothing
#
# plus what is specific to it: the defect is REPRODUCED in the old version (a sign-up with no e-mail is refused with the required-column error, exactly what Supabase Auth reports as
# "Database error saving new user"), then shown cured in the fixed one, and the trigger itself is left alone. Ends with the migration applied.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
MIG=supabase/migrations/20261031100000_signup_without_email.sql
BEFORE=tests/db/fixtures/handle_new_user_before.sql
FN=handle_new_user
FN_ARGS=""
NOMAIL=5d5a1c30-0000-4000-8000-000000000001
WITHMAIL=5d5a1c30-0000-4000-8000-000000000002
# shellcheck source=tests/db/guard_lib.sh
. tests/db/guard_lib.sh

trigger_state() { psql_db -c "select coalesce(string_agg(t.tgname || ':' || t.tgenabled::text, ','), 'none') from pg_trigger t where t.tgrelid = 'auth.users'::regclass and not t.tgisinternal"; }
clean_data() { psql_db -c "delete from auth.users where id in ('$NOMAIL', '$WITHMAIL')" >/dev/null 2>&1 || true; }
trap clean_data EXIT
clean_data
refused() {  # a drifted copy must be refused with the right message, change nothing, and leave the trigger alone
  local label="$1" drifted
  drifted=$(fp)
  [ "$drifted" != "$FIXED" ] && [ "$drifted" != "$DECLARED_BEFORE" ] || fail "test setup: the $label copy should be its own state"
  run_mig
  [ "$RC" != "0" ]                                   || fail "the migration replaced a $label copy it does not recognise"
  echo "$OUT" | grep -q "differs from the version"    || fail "$label: expected the 'differs' error, got: $OUT"
  echo "$OUT" | grep -q "Nothing was changed"         || fail "$label: the error should say nothing was changed"
  [ "$(fp)" = "$drifted" ]                            || fail "$label: a refused migration still changed the function"
  [ "$(trigger_state)" = "on_auth_user_created:O" ]   || fail "$label: the trigger changed"
}

guard_declared
guard_already_fixed

# The known production version, and the defect it has.
psql_db -f "$BEFORE" >/dev/null
[ "$(fp)" = "$DECLARED_BEFORE" ]                     || fail "the migration declares fingerprint $DECLARED_BEFORE for the old function, but the repository version is $(fp)"
[ "$(fp)" != "$FIXED" ]                              || fail "test setup: the old function should differ from the fixed one"
OUT=$(psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -c "insert into auth.users (id, email) values ('$NOMAIL', null)" 2>&1) && RC=0 || RC=$?
[ "$RC" != "0" ]                                     || fail "test setup: the old version should refuse a sign-up with no e-mail"
echo "$OUT" | grep -q 'null value in column "email"'  || fail "test setup: expected the required-column error for a sign-up with no e-mail, got: $OUT"
[ "$(psql_db -c "select count(*) from auth.users where id = '$NOMAIL'")" = "0" ] || fail "test setup: the refused sign-up left an account behind"
psql_db -c "insert into auth.users (id, email) values ('$WITHMAIL', 'withmail@guard.example')" >/dev/null
[ "$(psql_db -c "select count(*) from public.vendors where id = '$WITHMAIL'")" = "1" ] || fail "test setup: the old version should make a vendors row for an account with an e-mail"
clean_data

# The migration cures it, changes nothing else.
run_mig
[ "$RC" = "0" ]                                      || fail "the migration failed on the old version: $OUT"
echo "$OUT" | grep -q "fixed"                          || fail "expected the 'fixed' notice, got: $OUT"
[ "$(fp)" = "$FIXED" ]                               || fail "the fixed function does not match the fingerprint the migration declares"
[ "$(trigger_state)" = "on_auth_user_created:O" ]    || fail "the trigger on auth.users changed"
psql_db -c "insert into auth.users (id, email) values ('$NOMAIL', null)" >/dev/null || fail "a sign-up with no e-mail is still refused"
[ "$(psql_db -c "select count(*) from auth.users where id = '$NOMAIL'")" = "1" ]    || fail "the sign-up with no e-mail left no account"
[ "$(psql_db -c "select count(*) from public.vendors where id = '$NOMAIL'")" = "0" ] || fail "a vendors row was made for an account with no e-mail"
psql_db -c "insert into auth.users (id, email) values ('$WITHMAIL', 'withmail@guard.example')" >/dev/null
[ "$(psql_db -c "select count(*) from public.vendors where id = '$WITHMAIL' and email = 'withmail@guard.example' and business_name = 'User' and onboarding_completed = false")" = "1" ] || fail "the vendors row for an account with an e-mail changed"
clean_data

# Formatting is not drift.
sed -e 's/$/\r/' -e 's/^  /      /' "$BEFORE" | psql_db >/dev/null
[ "$(fp)" = "$DECLARED_BEFORE" ]                     || fail "test setup: a reformatted copy of the old version should still fingerprint as the old version"
run_mig
[ "$RC" = "0" ] && [ "$(fp)" = "$FIXED" ]            || fail "a reformatted copy of the known version was treated as drift: $OUT"

# Anything else is not recognised: hand-edited, security invoker, a search_path of its own.
sed 's/RETURN NEW;/RETURN NEW; -- a hotfix someone made directly in the database/' "$BEFORE" | psql_db >/dev/null
refused "hand-edited"
psql_db -c "select prosrc from pg_proc where proname = 'handle_new_user'" | grep -q "a hotfix someone made" || fail "the hand-edit was lost"
sed 's/^security definer$/security invoker/' "$BEFORE" | psql_db >/dev/null
refused "security-invoker"
awk '{ print } /^security definer$/ { print "set search_path = public" }' "$BEFORE" | psql_db >/dev/null
refused "search_path"

# Missing (its trigger has to go first, nothing can drop a function a trigger uses): stops with a clear message; then put everything back and apply.
psql_db -c "drop trigger on_auth_user_created on auth.users" -c "drop function public.handle_new_user()" >/dev/null
run_mig
[ "$RC" != "0" ]                                     || fail "the migration claimed success with no function to fix"
echo "$OUT" | grep -q "does not exist"                || fail "expected a 'does not exist' error, got: $OUT"
psql_db -f "$BEFORE" >/dev/null
psql_db -c "create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user()" >/dev/null
run_mig
[ "$RC" = "0" ] && [ "$(fp)" = "$FIXED" ]            || fail "could not restore the fixed function at the end: $OUT"
[ "$(trigger_state)" = "on_auth_user_created:O" ]    || fail "the trigger was not put back"
echo "ok - handle_new_user fix: guarded like the other live-function fixes, the defect (a sign-up with no e-mail refused by the required vendors.email) is reproduced in production's version and cured, accounts with an e-mail get the same row, the trigger is untouched"
