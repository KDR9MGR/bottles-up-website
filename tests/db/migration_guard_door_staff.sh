#!/usr/bin/env bash
# 20261020130000_organizer_door_staff.sql replaces a LIVE function (invite_member) and adds objects around it, as ONE all-or-nothing statement guarded by a
# compare-and-swap: already applied -> no-op; exactly the version this repository has (also with Windows line endings) -> replaced and built; anything else
# (hand-edited, not security definer, missing) -> STOPS with nothing built. Runs after the other guards and ends with the migration applied.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
MIG=supabase/migrations/20261020130000_organizer_door_staff.sql
BEFORE=tests/db/fixtures/invite_member_before.sql
FN=invite_member
FN_ARGS="p_org uuid, p_email text, p_role text, p_venue uuid, p_event uuid, p_shift uuid, p_access_start timestamp with time zone, p_access_end timestamp with time zone, p_valid_for interval"
# shellcheck source=tests/db/guard_lib.sh
. tests/db/guard_lib.sh

built()   { [ "$(psql_db -c "select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'site_agreements' and column_name = 'organizer_door_staff'")" != "0" ]; }
fn_count() { psql_db -c "select count(*) from pg_proc where proname in ('event_door_allowed','organizer_event_door_status','venue_door_permissions','set_organizer_door_staff','venue_event_door_staff','revoke_event_door_access')"; }
nothing_built() {
  built && fail "$1: the column was added even though the migration stopped"
  [ "$(fn_count)" = "0" ] || fail "$1: new functions were created even though the migration stopped"
  return 0
}
strip() {
  psql_db -c "drop function if exists public.organizer_event_door_status(uuid)" -c "drop function if exists public.venue_door_permissions(uuid)" \
          -c "drop function if exists public.set_organizer_door_staff(uuid, boolean)" -c "drop function if exists public.venue_event_door_staff(uuid)" \
          -c "drop function if exists public.revoke_event_door_access(uuid, uuid)" -c "drop function if exists public.event_door_allowed(uuid)" \
          -c "alter table public.site_agreements drop column if exists organizer_door_staff" >/dev/null
}

DECLARED=$(grep -E "c_before +constant" "$MIG" | grep -oE "[0-9a-f]{32}")
FINAL=$(fp)
[ "$FINAL" != "$DECLARED" ] || fail "test setup: the replayed function should be the new one"
built || fail "test setup: the replay should have built everything"

# 1. The old version is replaced and everything is built; the old fixture has the fingerprint the migration declares.
strip
psql_db -f "$BEFORE" >/dev/null
[ "$(fp)" = "$DECLARED" ]                     || fail "the migration declares $DECLARED for invite_member, but the repository version is $(fp)"
nothing_built "test setup"
run_mig
[ "$RC" = "0" ]                               || fail "the migration failed on the known version: $OUT"
echo "$OUT" | grep -q "door staff recorded"   || fail "expected the 'recorded' notice, got: $OUT"
[ "$(fp)" = "$FINAL" ]                        || fail "the replaced invite_member is not the one the replay produced"
built && [ "$(fn_count)" = "6" ]              || fail "the migration did not build everything"

# 2. Already applied: nothing changes.
run_mig
[ "$RC" = "0" ]                               || fail "running it where it is already applied failed: $OUT"
echo "$OUT" | grep -q "already applied"       || fail "expected the 'already applied' notice, got: $OUT"
[ "$(fp)" = "$FINAL" ]                        || fail "a no-op run changed invite_member"

# 3. Formatting is not drift.
strip
sed -e 's/$/\r/' -e 's/^  /      /' "$BEFORE" | psql_db >/dev/null
[ "$(fp)" = "$DECLARED" ]                     || fail "test setup: a reformatted copy should still fingerprint as the known version"
run_mig
[ "$RC" = "0" ] && [ "$(fp)" = "$FINAL" ]     || fail "a reformatted copy of the known version was treated as drift: $OUT"

# 4. A hand-edited invite_member is never overwritten, and nothing is half-built.
strip
sed 's/v_token text;/v_token text; -- a hotfix someone made directly in the database/' "$BEFORE" | psql_db >/dev/null
DRIFTED=$(fp)
run_mig
[ "$RC" != "0" ]                              || fail "the migration replaced an invite_member it does not recognise"
echo "$OUT" | grep -q "differs from the version" || fail "expected the 'differs' error, got: $OUT"
echo "$OUT" | grep -q "Nothing was changed"   || fail "the error should say nothing was changed"
[ "$(fp)" = "$DRIFTED" ]                      || fail "a refused migration still changed invite_member"
psql_db -c "select prosrc from pg_proc where proname = 'invite_member'" | grep -q "a hotfix someone made" || fail "the hand-edit was lost"
nothing_built "hand-edited invite_member"

# 5. The same text running differently is a different function.
strip
sed 's/^security definer$/security invoker/' "$BEFORE" | psql_db >/dev/null
run_mig
{ [ "$RC" != "0" ] && echo "$OUT" | grep -q "differs from the version"; } || fail "the migration replaced a copy that is not security definer"
nothing_built "security invoker invite_member"

# 6. No invite_member at all.
strip
psql_db -c "drop function public.invite_member($(echo "$FN_ARGS" | sed 's/p_[a-z_]* //g'))" >/dev/null
run_mig
{ [ "$RC" != "0" ] && echo "$OUT" | grep -q "does not exist"; } || fail "expected a 'does not exist' error, got: $OUT"
nothing_built "missing invite_member"

# Back to the real final state.
psql_db -f "$BEFORE" >/dev/null
run_mig
[ "$RC" = "0" ] && [ "$(fp)" = "$FINAL" ] && built || fail "could not put the door staff state back at the end: $OUT"

echo "ok - organizer door staff: no-op where applied, builds on the known invite_member (also reformatted), stops and builds nothing on a hand-edited, differently-secured or missing one"
