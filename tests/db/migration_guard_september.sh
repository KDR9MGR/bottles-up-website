#!/usr/bin/env bash
# The two September migrations record changes that were made by hand in production and are already live there. Both replace or build on LIVE
# objects, so both are guarded, and this proves the guards:
#   20260923100000_guest_tickets_and_checkin_fix.sql   already applied -> no-op; the two checkin_ticket versions this repository has produced
#                                                       -> built; anything else -> STOPS with nothing changed (and nothing half-built)
#   20260925100000_after_midnight_availability.sql     already applied -> no-op; the 20260731 version -> replaced; anything else -> STOPS
# Runs last (it takes the objects apart to recreate production's "before" state) and ends with both migrations applied again.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
# shellcheck source=tests/db/guard_lib.sh
. tests/db/guard_lib.sh

CHECKIN_0821=tests/db/fixtures/checkin_ticket_before_fix.sql
CHECKIN_0830_MIG=supabase/migrations/20260830120000_fix_checkin_ticket_early_returns.sql
GUEST_MIG=supabase/migrations/20260923100000_guest_tickets_and_checkin_fix.sql
AVAIL_MIG=supabase/migrations/20260925100000_after_midnight_availability.sql
AVAIL_BEFORE=tests/db/fixtures/get_unavailable_table_types_before.sql

# ---------------------------------------------------------------------------------------------------------------------------------------
# Guest tickets + checkin_ticket()
# ---------------------------------------------------------------------------------------------------------------------------------------
FN=checkin_ticket
FN_ARGS="p_ticket_code text"
MIG=$GUEST_MIG
BEFORE=$CHECKIN_0821

exists_table()  { [ "$(psql_db -c "select to_regclass('public.guest_tickets') is not null")" = "t" ]; }
exists_lookup() { [ "$(psql_db -c "select count(*) from pg_proc where proname = 'lookup_table_booking_for_checkin'")" != "0" ]; }
exists_column() { [ "$(psql_db -c "select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'scan_attempts' and column_name = 'guest_ticket_id'")" != "0" ]; }
nothing_built() {  # the migration refused: none of its objects may exist
  exists_table  && fail "$1: guest_tickets was created even though the migration stopped"
  exists_lookup && fail "$1: the lookup function was created even though the migration stopped"
  exists_column && fail "$1: scan_attempts.guest_ticket_id was added even though the migration stopped"
  return 0
}

# Production's state before 23 Sep: no guest tickets, no lookup function, no scan_attempts.guest_ticket_id.
strip_september() {
  psql_db -c "drop function if exists public.lookup_table_booking_for_checkin(text)" \
          -c "alter table public.scan_attempts drop column if exists guest_ticket_id" \
          -c "drop table if exists public.guest_tickets cascade" >/dev/null
}
# ... with checkin_ticket() as the 21 Aug definition, optionally followed by the 30 Aug early-return fix.
before_state() {  # before_state [with0830]
  strip_september
  psql_db -f "$CHECKIN_0821" >/dev/null
  if [ "${1:-}" = "with0830" ]; then
    local save_mig=$MIG; MIG=$CHECKIN_0830_MIG; run_mig; MIG=$save_mig
    [ "$RC" = "0" ] || fail "test setup: could not apply the 30 Aug fix: $OUT"
  fi
}

# The declared constants must really be the two versions this repository has produced.
DECLARED_0821=$(grep -E "c_0821 +constant" "$GUEST_MIG" | grep -oE "[0-9a-f]{32}")
DECLARED_0830=$(grep -E "c_0830 +constant" "$GUEST_MIG" | grep -oE "[0-9a-f]{32}")
before_state;           [ "$(fp)" = "$DECLARED_0821" ] || fail "the migration declares $DECLARED_0821 for the 21 Aug checkin_ticket, but the repository version is $(fp)"
before_state with0830;  [ "$(fp)" = "$DECLARED_0830" ] || fail "the migration declares $DECLARED_0830 for the 30 Aug checkin_ticket, but the repository version is $(fp)"

# 1. The 30 Aug version (what production had) is built on; this is the state every other scenario is compared with.
nothing_built "test setup"
run_mig
[ "$RC" = "0" ]                                  || fail "the migration failed on the 30 Aug version: $OUT"
echo "$OUT" | grep -q "guest tickets recorded"   || fail "expected the 'recorded' notice, got: $OUT"
exists_table && exists_lookup && exists_column   || fail "the migration did not build everything (table, lookup function, scan_attempts column)"
GUEST_FINAL=$(fp)
[ "$GUEST_FINAL" != "$DECLARED_0830" ]           || fail "checkin_ticket() was not rewritten"

# 2. Run again: already applied, nothing changes.
run_mig
[ "$RC" = "0" ]                                  || fail "running the migration where it is already applied failed: $OUT"
echo "$OUT" | grep -q "already applied"          || fail "expected the 'already applied' notice, got: $OUT"
[ "$(fp)" = "$GUEST_FINAL" ]                     || fail "a no-op run changed checkin_ticket()"

# 3. The 21 Aug version (before the early-return fix) is also known, and ends in exactly the same place.
before_state
run_mig
[ "$RC" = "0" ]                                  || fail "the migration failed on the 21 Aug version: $OUT"
[ "$(fp)" = "$GUEST_FINAL" ]                     || fail "starting from the 21 Aug version did not end with the same checkin_ticket()"

# 4. Formatting is not drift (CRLF line endings, different indentation).
strip_september
sed -e 's/$/\r/' -e 's/^  /      /' "$CHECKIN_0821" | psql_db >/dev/null
[ "$(fp)" = "$DECLARED_0821" ]                   || fail "test setup: a reformatted copy should still fingerprint as the 21 Aug version"
run_mig
[ "$RC" = "0" ] && [ "$(fp)" = "$GUEST_FINAL" ] || fail "a reformatted copy of a known version was treated as drift: $OUT"

# 5. A hand-edited function is never overwritten, and nothing is half-built.
strip_september
sed 's/v_result text;/v_result text; -- a hotfix someone made directly in the database/' "$CHECKIN_0821" | psql_db >/dev/null
DRIFTED=$(fp)
run_mig
[ "$RC" != "0" ]                                 || fail "the migration replaced a checkin_ticket() it does not recognise"
echo "$OUT" | grep -q "differs from the versions"  || fail "expected the 'differs' error, got: $OUT"
echo "$OUT" | grep -q "Nothing was changed"        || fail "the error should say nothing was changed"
[ "$(fp)" = "$DRIFTED" ]                         || fail "a refused migration still changed checkin_ticket()"
psql_db -c "select prosrc from pg_proc where proname = 'checkin_ticket'" | grep -q "a hotfix someone made" || fail "the hand-edit was lost"
nothing_built "hand-edited checkin_ticket"

# 6. The same text running differently is a different function.
strip_september
sed 's/^security definer$/security invoker/' "$CHECKIN_0821" | psql_db >/dev/null
run_mig
{ [ "$RC" != "0" ] && echo "$OUT" | grep -q "differs from the versions"; } || fail "the migration replaced a checkin_ticket() that is not security definer"
nothing_built "security invoker checkin_ticket"
strip_september
sed 's/^set search_path = public$/set search_path = public, pg_temp/' "$CHECKIN_0821" | psql_db >/dev/null
run_mig
{ [ "$RC" != "0" ] && echo "$OUT" | grep -q "differs from the versions"; } || fail "the migration replaced a checkin_ticket() with another search_path"
nothing_built "checkin_ticket with another search_path"

# 7. No checkin_ticket() at all.
strip_september
psql_db -c "drop function public.checkin_ticket(text)" >/dev/null
run_mig
{ [ "$RC" != "0" ] && echo "$OUT" | grep -q "does not exist"; } || fail "expected a 'does not exist' error with no checkin_ticket(), got: $OUT"
nothing_built "missing checkin_ticket"

# 8. A lookup function already exists (made some other way) but guest_tickets does not: the all-or-nothing block must roll back completely.
before_state with0830
BEFORE_RESTORE=$(fp)
psql_db -c "create function public.lookup_table_booking_for_checkin(p_code text) returns jsonb language sql as \$\$ select '{}'::jsonb \$\$" >/dev/null
run_mig
[ "$RC" != "0" ]                                 || fail "the migration carried on over an unknown lookup function: $OUT"
exists_table  && fail "guest_tickets was left behind by a migration that failed half way"
exists_column && fail "scan_attempts.guest_ticket_id was left behind by a migration that failed half way"
[ "$(fp)" = "$BEFORE_RESTORE" ]                  || fail "checkin_ticket() was changed by a migration that failed half way"

# Back to the real final state.
before_state with0830
run_mig
[ "$RC" = "0" ] && [ "$(fp)" = "$GUEST_FINAL" ] && exists_table && exists_lookup && exists_column || fail "could not put the September guest ticket state back at the end: $OUT"

# ---------------------------------------------------------------------------------------------------------------------------------------
# After-midnight availability
# ---------------------------------------------------------------------------------------------------------------------------------------
FN=get_unavailable_table_types
FN_ARGS="p_venue_id uuid, p_booking_date date, p_time_slot_id uuid"
MIG=$AVAIL_MIG
BEFORE=$AVAIL_BEFORE

AVAIL_FINAL=$(fp)
DECLARED_BEFORE=$(grep -E "c_before +constant" "$AVAIL_MIG" | grep -oE "[0-9a-f]{32}")
[ "$AVAIL_FINAL" != "$DECLARED_BEFORE" ]         || fail "test setup: the replayed function should be the new one"
psql_db -f "$AVAIL_BEFORE" >/dev/null
[ "$(fp)" = "$DECLARED_BEFORE" ]                 || fail "the migration declares fingerprint $DECLARED_BEFORE for the 20260731 function, but the repository version is $(fp)"

# 1. The 20260731 version is replaced, and ends exactly where the replay did.
run_mig
[ "$RC" = "0" ]                                  || fail "the migration failed on the 20260731 version: $OUT"
echo "$OUT" | grep -q "one day later"            || fail "expected the 'one day later' notice, got: $OUT"
[ "$(fp)" = "$AVAIL_FINAL" ]                     || fail "the replaced function does not match the one the replay produced"

# 2. Already applied: nothing changes.
run_mig
[ "$RC" = "0" ]                                  || fail "running the migration where it is already applied failed: $OUT"
echo "$OUT" | grep -q "already rolls the date forward" || fail "expected the 'already' notice, got: $OUT"
[ "$(fp)" = "$AVAIL_FINAL" ]                     || fail "a no-op run changed the function"

# 3. A hand-edited old function is never overwritten.
sed 's/select distinct table_type_id/select distinct table_type_id -- a hotfix someone made directly in the database/' "$AVAIL_BEFORE" | psql_db >/dev/null
DRIFTED=$(fp)
[ "$DRIFTED" != "$DECLARED_BEFORE" ]             || fail "test setup: the hand-edited function should differ"
run_mig
[ "$RC" != "0" ]                                 || fail "the migration replaced a function it does not recognise"
echo "$OUT" | grep -q "differs from the version"   || fail "expected the 'differs' error, got: $OUT"
echo "$OUT" | grep -q "Nothing was changed"        || fail "the error should say nothing was changed"
[ "$(fp)" = "$DRIFTED" ]                         || fail "a refused migration still changed the function"
psql_db -c "select prosrc from pg_proc where proname = '$FN'" | grep -q "a hotfix someone made" || fail "the hand-edit was lost"

# 4. The same text running differently is a different function.
sed 's/^security definer$/security invoker/' "$AVAIL_BEFORE" | psql_db >/dev/null
run_mig
{ [ "$RC" != "0" ] && echo "$OUT" | grep -q "differs from the version"; } || fail "the migration replaced a copy that is not security definer"
sed 's/^set search_path = public$/set search_path = public, pg_temp/' "$AVAIL_BEFORE" | psql_db >/dev/null
run_mig
{ [ "$RC" != "0" ] && echo "$OUT" | grep -q "differs from the version"; } || fail "the migration replaced a copy with another search_path"

# 5. Formatting is not drift.
sed -e 's/$/\r/' -e 's/^  /      /' "$AVAIL_BEFORE" | psql_db >/dev/null
[ "$(fp)" = "$DECLARED_BEFORE" ]                 || fail "test setup: a reformatted copy should still fingerprint as the 20260731 version"
run_mig
[ "$RC" = "0" ] && [ "$(fp)" = "$AVAIL_FINAL" ]  || fail "a reformatted copy of the known version was treated as drift: $OUT"

# 6. Missing function.
psql_db -c "drop function public.$FN(uuid, date, uuid)" >/dev/null
run_mig
{ [ "$RC" != "0" ] && echo "$OUT" | grep -q "does not exist"; } || fail "expected a 'does not exist' error, got: $OUT"
psql_db -f "$AVAIL_BEFORE" >/dev/null
run_mig
[ "$RC" = "0" ] && [ "$(fp)" = "$AVAIL_FINAL" ]  || fail "could not put the new function back at the end: $OUT"

echo "ok - September migrations: no-op where already live, build on both known checkin_ticket versions, stop (and leave nothing half-built) on a hand-edited, differently-secured, missing or conflicting object, replace the 20260731 availability function, tolerate formatting"
