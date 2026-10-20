#!/usr/bin/env bash
# 20261022100000_order_accepted_stage.sql replaces FOUR live functions (desk_set_service_status, desk_tonight, night_report_data and the website's hand-made
# update_bottle_service_status) and widens a check constraint. Its first statement is a guard, so nothing changes unless the constraint is exactly the known five-value
# list (or already allows 'accepted') and every function is either already updated or exactly the version this repository / the production definition has:
#
#   known versions (also with Windows line endings and other indentation)  -> replaced, constraint widened
#   ANY one hand-edited, not security definer, with another search_path, or missing -> STOPS, nothing changed (checked for each of the four)
#   a constraint that is not the known list                                 -> STOPS, nothing changed
#   run again where it is applied                                           -> a no-op, nothing changes
#
# Runs after the other guards and ends with the migration applied.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
export PGOPTIONS="-c client_min_messages=warning"
MIG=supabase/migrations/20261022100000_order_accepted_stage.sql
BEFORE=tests/db/fixtures/order_accepted_before.sql
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - migration guard (order accepted stage): $1"; exit 1; }
run_mig() { OUT=$(psql -X -v ON_ERROR_STOP=1 -d "$DB" -f "$MIG" 2>&1) && RC=0 || RC=$?; }

FNS=(desk_set_service_status desk_tonight night_report_data update_bottle_service_status)
ARGS_desk_set_service_status="p_line uuid, p_status text"
ARGS_desk_tonight="p_venue uuid, p_night date"
ARGS_night_report_data="p_venue uuid, p_night date"
ARGS_update_bottle_service_status="p_bottle_line_id uuid, p_status text"

fp() {
  local args="ARGS_$1"
  psql_db -c "select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = '$1' and pg_get_function_identity_arguments(p.oid) = '${!args}'"
}
declared() { # the fingerprint the migration declares for a function, in the order of its list
  case "$1" in
    desk_set_service_status) n=1 ;; desk_tonight) n=2 ;; night_report_data) n=3 ;; update_bottle_service_status) n=4 ;;
  esac
  grep -E "^      \('(desk_set_service_status|desk_tonight|night_report_data|update_bottle_service_status)'" "$MIG" | sed -n "${n}p" | grep -oE "[0-9a-f]{32}"
}
accepted_in() { [ "$(psql_db -c "select position('accepted' in prosrc) > 0 from pg_proc where proname = '$1'")" = "t" ]; }
constraint_def() { psql_db -c "select pg_get_constraintdef(oid) from pg_constraint where conname = 'site_table_booking_bottles_service_status_check'"; }
widened() { constraint_def | grep -q accepted; }
old_constraint() {
  psql_db -c "alter table public.site_table_booking_bottles drop constraint if exists site_table_booking_bottles_service_status_check" \
          -c "alter table public.site_table_booking_bottles add constraint site_table_booking_bottles_service_status_check check (service_status = any (array['awaiting_prep', 'preparing', 'ready', 'picked_up', 'served']))" >/dev/null
}
old_functions() { psql_db -f "$BEFORE" >/dev/null; }
nothing_changed() {
  widened && fail "$1: the constraint was widened even though the migration stopped"
  for f in "${FNS[@]}"; do accepted_in "$f" && fail "$1: $f was replaced even though the migration stopped"; done
  return 0
}
final() { local v="FINAL_$1"; echo "${!v}"; }   # bash 3.2 has no associative arrays

for f in "${FNS[@]}"; do printf -v "FINAL_$f" '%s' "$(fp "$f")"; done
widened || fail "test setup: the replay should have widened the constraint"
old_constraint; old_functions
for f in "${FNS[@]}"; do
  [ "$(fp "$f")" = "$(declared "$f")" ] || fail "the migration declares $(declared "$f") for $f, but the old version is $(fp "$f")"
  [ "$(fp "$f")" != "$(final "$f")" ]   || fail "test setup: the old $f should differ from the replayed new one"
done
nothing_changed "test setup"

# 1. The known versions are replaced and the constraint is widened.
run_mig
[ "$RC" = "0" ]                                 || fail "the migration failed on the known versions: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "the replaced $f is not the one the replay produced"; done
widened                                         || fail "the constraint was not widened"

# 2. Run again where it is applied: a no-op.
run_mig
[ "$RC" = "0" ]                                 || fail "running it where it is already applied failed: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "a second run changed $f"; done

# 3. Formatting is not drift: CRLF line endings and other indentation of the known versions.
old_constraint; old_functions
sed -e 's/$/\r/' -e 's/^  /      /' "$BEFORE" | psql_db >/dev/null
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(declared "$f")" ] || fail "test setup: a reformatted $f should still fingerprint as the known version"; done
run_mig
[ "$RC" = "0" ]                                 || fail "reformatted copies of the known versions were treated as drift: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "reformatted $f was not replaced by the replayed one"; done

# 4. For EACH of the four: hand-edited, not security definer, another search_path, missing -> STOP, nothing changed.
for target in "${FNS[@]}"; do
  for variant in hand_edit invoker search_path missing; do
    old_constraint; old_functions
    case "$variant" in
      hand_edit)   awk -v t="$target" '/CREATE OR REPLACE FUNCTION public\./ { cur = ($0 ~ "public\\." t "\\(") } { print } cur && /^AS \$function\$/ { print "-- a hotfix someone made directly in the database" }' "$BEFORE" | psql_db >/dev/null ;;
      invoker)     awk -v t="$target" '/CREATE OR REPLACE FUNCTION public\./ { cur = ($0 ~ "public\\." t "\\(") } { if (cur) sub(/ ?SECURITY DEFINER$/, ""); print }' "$BEFORE" | psql_db >/dev/null ;;
      search_path) awk -v t="$target" '/CREATE OR REPLACE FUNCTION public\./ { cur = ($0 ~ "public\\." t "\\(") } { if (cur && /^ SET search_path TO/) print " SET search_path TO '\''public'\'', '\''pg_temp'\''"; else print }' "$BEFORE" | psql_db >/dev/null ;;
      missing)     psql_db -c "drop function public.$target($(echo "$(eval echo \${ARGS_$target})" | sed -E 's/p_[a-z_]+ //g'))" >/dev/null ;;
    esac
    if [ "$variant" != "missing" ]; then
      [ "$(fp "$target")" != "$(declared "$target")" ] || fail "test setup: the $variant copy of $target should differ from the known version"
    fi
    run_mig
    [ "$RC" != "0" ]                                                  || fail "$target ($variant): the migration went ahead on a version it does not recognise"
    if [ "$variant" = "missing" ]; then
      echo "$OUT" | grep -q "does not exist"                          || fail "$target (missing): expected a 'does not exist' error, got: $OUT"
    else
      echo "$OUT" | grep -q "differs from the version"                || fail "$target ($variant): expected the 'differs' error, got: $OUT"
    fi
    echo "$OUT" | grep -q "Nothing was changed"                       || fail "$target ($variant): the error should say nothing was changed"
    nothing_changed "$target ($variant)"
    for f in "${FNS[@]}"; do
      [ "$f" = "$target" ] && continue
      [ "$(fp "$f")" = "$(declared "$f")" ]                           || fail "$target ($variant): the migration changed $f"
    done
  done
done

# 5. A constraint that is not the known list (someone added a value by hand) is never replaced.
old_functions
psql_db -c "alter table public.site_table_booking_bottles drop constraint site_table_booking_bottles_service_status_check" \
        -c "alter table public.site_table_booking_bottles add constraint site_table_booking_bottles_service_status_check check (service_status = any (array['awaiting_prep', 'preparing', 'ready', 'picked_up', 'served', 'on_hold']))" >/dev/null
run_mig
[ "$RC" != "0" ] && echo "$OUT" | grep -q "not the one this change was written against" && echo "$OUT" | grep -q "Nothing was changed" || fail "a different constraint was not refused: $OUT"
for f in "${FNS[@]}"; do accepted_in "$f" && fail "a refused constraint still let $f be replaced"; done
# ... and a missing constraint
psql_db -c "alter table public.site_table_booking_bottles drop constraint site_table_booking_bottles_service_status_check" >/dev/null
run_mig
[ "$RC" != "0" ] && echo "$OUT" | grep -q "does not exist in this database. Nothing was changed" || fail "a missing constraint was not refused: $OUT"

# Back to the real final state.
old_constraint; old_functions
run_mig
[ "$RC" = "0" ] && widened || fail "could not put the accepted-stage state back at the end: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "the final $f is not the replayed one"; done

echo "ok - order accepted stage: replaces the four live functions and widens the constraint only when each is exactly the known version (also reformatted), stops with nothing changed on any hand-edited, not security definer, differently pathed or missing one and on an unknown constraint, and is a no-op when applied"
