#!/usr/bin/env bash
# 20261028100000_refund_receipt_evidence.sql corrects TWO live functions of an already applied migration (desk_complete_club_refund: the receipt photo must belong to the booking;
# desk_refund_requests: two more columns, so it is dropped and made again with its grants). Its first statement is a guard, so nothing changes unless each function is exactly the
# version 20261023100000 made (or is already corrected):
#
#   the known old versions (also with Windows line endings and other indentation) -> corrected
#   run again where it is corrected                                              -> a no-op, nothing changes
#   ANY one hand-edited, not security definer, with another search_path, or missing -> STOPS, nothing changed (checked for each of the two, and the other is not touched)
#
# Runs after the other guards and ends with the migration applied.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
export PGOPTIONS="-c client_min_messages=warning"
MIG=supabase/migrations/20261028100000_refund_receipt_evidence.sql
BEFORE=tests/db/fixtures/refund_receipt_before.sql
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - migration guard (refund receipt evidence): $1"; exit 1; }
run_mig() { OUT=$(psql -X -v ON_ERROR_STOP=1 -d "$DB" -f "$MIG" 2>&1) && RC=0 || RC=$?; }

FNS=(desk_complete_club_refund desk_refund_requests)
ARGS_desk_complete_club_refund="p_request uuid, p_pos_reference text, p_receipt_path text"
ARGS_desk_refund_requests="p_venue uuid, p_status text"
SIG_desk_complete_club_refund="uuid, text, text"
SIG_desk_refund_requests="uuid, text"

fp() {
  local args="ARGS_$1"
  psql_db -c "select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = '$1' and pg_get_function_identity_arguments(p.oid) = '${!args}'"
}
declared() { # the fingerprint the migration declares for a function: $2 = before | after
  local row; row=$(grep -E "^      \('$1'" "$MIG" | head -1)
  local n=1; [ "$2" = "after" ] && n=2
  echo "$row" | grep -oE "[0-9a-f]{32}|__AFTER_[A-Z]+__" | sed -n "${n}p"
}
old_state() { psql_db -f "$BEFORE" >/dev/null; }
snapshot() { for f in "${FNS[@]}"; do printf '%s=%s;' "$f" "$(fp "$f")"; done; }
can_call() { psql_db -c "select has_function_privilege('$1', 'public.$2($3)', 'execute')"; }
final() { local v="FINAL_$1"; echo "${!v}"; }   # bash 3.2 has no associative arrays

for f in "${FNS[@]}"; do printf -v "FINAL_$f" '%s' "$(fp "$f")"; done
for f in "${FNS[@]}"; do
  [ "$(declared "$f" after)" = "$(final "$f")" ] || fail "the migration declares $(declared "$f" after) for the corrected $f, but the replay made $(final "$f")"
done
old_state
for f in "${FNS[@]}"; do
  [ "$(fp "$f")" = "$(declared "$f" before)" ] || fail "the migration declares $(declared "$f" before) for the old $f, but the old version is $(fp "$f")"
  [ "$(fp "$f")" != "$(final "$f")" ]          || fail "test setup: the old $f should differ from the corrected one"
done

# 1. The known old versions are corrected, with the right grants and the two new columns.
run_mig
[ "$RC" = "0" ]                                 || fail "the migration failed on the known old versions: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "the corrected $f is not the one the replay produced"; done
[ "$(can_call anon desk_refund_requests 'uuid, text')" = "f" ]          || fail "visitors can call desk_refund_requests after it was made again"
[ "$(can_call authenticated desk_refund_requests 'uuid, text')" = "t" ] || fail "signed-in people cannot call desk_refund_requests after it was made again"
[ "$(can_call service_role desk_refund_requests 'uuid, text')" = "t" ]  || fail "the service role cannot call desk_refund_requests after it was made again"
[ "$(psql_db -c "select count(*) from pg_proc p, unnest(p.proargnames) a where p.proname = 'desk_refund_requests' and a in ('refund_reference', 'refund_receipt_path')")" = "2" ] || fail "the evidence columns are not returned"

# 2. Run again where it is corrected: a no-op (the notices are shown for this run, to see it say so).
OUT=$(PGOPTIONS="-c client_min_messages=notice" psql -X -v ON_ERROR_STOP=1 -d "$DB" -f "$MIG" 2>&1) && RC=0 || RC=$?
[ "$RC" = "0" ]                                 || fail "running it where it is already corrected failed: $OUT"
echo "$OUT" | grep -q "already has the receipt check" && echo "$OUT" | grep -q "already returns the evidence columns" || fail "expected both 'already' notices, got: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "a second run changed $f"; done

# 3. Formatting is not drift: CRLF line endings and other indentation of the known old versions.
old_state
sed -e 's/$/\r/' -e 's/^  /      /' "$BEFORE" | psql_db >/dev/null
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(declared "$f" before)" ] || fail "test setup: a reformatted $f should still fingerprint as the old version"; done
run_mig
[ "$RC" = "0" ]                                 || fail "reformatted copies of the old versions were treated as drift: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "reformatted $f was not corrected"; done

# 4. For EACH of the two: hand-edited, not security definer, another search_path, missing -> STOP, nothing changed (and the other one is not touched either).
for target in "${FNS[@]}"; do
  for variant in hand_edit invoker search_path missing; do
    old_state
    case "$variant" in
      hand_edit)   awk -v t="$target" '/^(create or replace function|create function) public\./ { cur = ($0 ~ "public\\." t "\\(") } { print } cur && /^as \$\$$/ { print "-- a hotfix someone made directly in the database" }' "$BEFORE" | psql_db >/dev/null ;;
      invoker)     awk -v t="$target" '/^(create or replace function|create function) public\./ { cur = ($0 ~ "public\\." t "\\(") } { if (cur && /^security definer$/) print "security invoker"; else print }' "$BEFORE" | psql_db >/dev/null ;;
      search_path) awk -v t="$target" '/^(create or replace function|create function) public\./ { cur = ($0 ~ "public\\." t "\\(") } { if (cur && /^set search_path = public$/) print "set search_path = public, pg_temp"; else print }' "$BEFORE" | psql_db >/dev/null ;;
      missing)     psql_db -c "drop function public.$target($(eval echo \${SIG_$target}))" >/dev/null ;;
    esac
    if [ "$variant" != "missing" ]; then
      [ "$(fp "$target")" != "$(declared "$target" before)" ] || fail "test setup: the $variant copy of $target should differ from the old version"
      [ "$(fp "$target")" != "$(final "$target")" ]           || fail "test setup: the $variant copy of $target should differ from the corrected version"
    fi
    BEFORE_RUN=$(snapshot)
    run_mig
    [ "$RC" != "0" ]                                                  || fail "$target ($variant): the migration went ahead on a version it does not recognise"
    if [ "$variant" = "missing" ]; then
      echo "$OUT" | grep -q "does not exist"                          || fail "$target (missing): expected a 'does not exist' error, got: $OUT"
    else
      echo "$OUT" | grep -q "differs from the version"                || fail "$target ($variant): expected the 'differs' error, got: $OUT"
    fi
    echo "$OUT" | grep -q "Nothing was changed"                       || fail "$target ($variant): the error should say nothing was changed"
    [ "$(snapshot)" = "$BEFORE_RUN" ]                                 || fail "$target ($variant): the migration stopped but still changed a function"
  done
done

# Back to the real final state.
old_state
run_mig
[ "$RC" = "0" ] || fail "could not put the corrected state back at the end: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "the final $f is not the replayed one"; done

echo "ok - refund receipt evidence: corrects the two live functions only when each is exactly the version 20261023100000 made (also reformatted), is a no-op where corrected, and stops with nothing changed on any hand-edited, not security definer, differently pathed or missing one"
