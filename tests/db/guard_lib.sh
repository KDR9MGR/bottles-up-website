# Shared by the guards for the migrations that replace a LIVE function (migration_guard.sh, migration_guard_verify.sh).
#
# Those migrations are compare-and-swap: they replace the function only if it is exactly the version they were written
# against. The scenarios here are the same for every such migration, so they live in one place and cannot drift apart:
#
#   already fixed   -> no-op, safe to run twice
#   hand-edited     -> STOPS, changes nothing (never overwrites an unknown version)
#   not security definer / different search_path -> also "unknown": the same text running differently is a different function
#   whitespace only -> still the known version (formatting, including Windows line endings, is not drift)
#   missing         -> stops with a clear message
#
# The caller sets: DB, MIG, BEFORE (fixture with the old function), FN, FN_ARGS (e.g. "p_ticket_code text"), and sources this.

psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - migration guard ($FN): $1"; exit 1; }

fp() {
  psql_db -c "select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = '$FN' and pg_get_function_identity_arguments(p.oid) = '$FN_ARGS'"
}

# Runs the migration; sets RC (exit code) and OUT (everything it printed).
run_mig() { OUT=$(psql -X -v ON_ERROR_STOP=1 -d "$DB" -f "$MIG" 2>&1) && RC=0 || RC=$?; }

# The fingerprints the migration DECLARES must be what the functions really have. If someone edits the function text in the
# migration and forgets the constant, the guard would later refuse to recognise an already-fixed database in production.
guard_declared() {
  FIXED=$(fp)
  DECLARED_AFTER=$(grep -E "c_after +constant" "$MIG" | grep -oE "[0-9a-f]{32}")
  DECLARED_BEFORE=$(grep -E "c_before +constant" "$MIG" | grep -oE "[0-9a-f]{32}")
  [ "$FIXED" = "$DECLARED_AFTER" ] || fail "the migration declares fingerprint $DECLARED_AFTER for the fixed function, but it really is $FIXED"
}

guard_already_fixed() {
  run_mig
  [ "$RC" = "0" ]                            || fail "running the migration on a fixed database failed: $OUT"
  echo "$OUT" | grep -q "already has this fix" || fail "expected the 'already has this fix' notice, got: $OUT"
  [ "$(fp)" = "$FIXED" ]                     || fail "a no-op run changed the function"
}

guard_hand_edited() {
  sed 's/v_result text;/v_result text; -- a hotfix someone made directly in the database/' "$BEFORE" | psql_db >/dev/null
  DRIFTED=$(fp)
  [ "$DRIFTED" != "$FIXED" ]                 || fail "test setup: the hand-edited function should differ"
  run_mig
  [ "$RC" != "0" ]                           || fail "the migration replaced a function it does not recognise"
  echo "$OUT" | grep -q "differs from the version" || fail "expected the 'differs' error, got: $OUT"
  echo "$OUT" | grep -q "Nothing was changed"      || fail "the error should say nothing was changed"
  [ "$(fp)" = "$DRIFTED" ]                   || fail "a refused migration still changed the function"
  psql_db -c "select prosrc from pg_proc where proname = '$FN'" | grep -q "a hotfix someone made" || fail "the hand-edit was lost"

  # The same text running differently is a different function: made SECURITY INVOKER, or given another search_path.
  sed 's/^security definer$/security invoker/' "$BEFORE" | psql_db >/dev/null
  [ "$(fp)" != "$FIXED" ] && [ "$(fp)" != "$DRIFTED" ] || fail "test setup: the security-invoker copy should be its own state"
  run_mig
  [ "$RC" != "0" ] && echo "$OUT" | grep -q "differs from the version" || fail "the migration replaced a copy that is not security definer"
  sed 's/^set search_path = public$/set search_path = public, pg_temp/' "$BEFORE" | psql_db >/dev/null
  run_mig
  [ "$RC" != "0" ] && echo "$OUT" | grep -q "differs from the version" || fail "the migration replaced a copy with a different search_path"
}

guard_whitespace() {
  sed -e 's/$/\r/' -e 's/^  /      /' "$BEFORE" | psql_db >/dev/null
  [ "$(fp)" != "$FIXED" ]                    || fail "test setup: the reformatted old function should still be the old one"
  run_mig
  [ "$RC" = "0" ]                            || fail "a reformatted copy of the known version was treated as drift: $OUT"
  [ "$(fp)" = "$FIXED" ]                     || fail "the reformatted old version was not replaced by the fix"
}

# Ends by putting the fixed function back, so later tests find the database as they expect.
guard_missing_then_restore() {
  psql_db -c "drop function public.$FN($(echo "$FN_ARGS" | sed 's/p_[a-z_]* //g'))" >/dev/null
  run_mig
  [ "$RC" != "0" ]                           || fail "the migration claimed success with no function to fix"
  echo "$OUT" | grep -q "does not exist"      || fail "expected a 'does not exist' error, got: $OUT"
  psql_db -f "$BEFORE" >/dev/null
  run_mig
  [ "$RC" = "0" ] && [ "$(fp)" = "$FIXED" ]  || fail "could not restore the fixed function at the end"
}
