#!/usr/bin/env bash
# 20261021100000_floor_plan_and_table_states.sql replaces THREE live functions (get_unavailable_table_types, desk_walkin_options, desk_create_walkin) and builds a
# lot around them. Its first statement is a guard, so nothing is built unless every one of the three is either already using the shared count or exactly the version
# this repository has:
#
#   known versions (also with Windows line endings and other indentation)  -> replaced, everything built
#   ANY one hand-edited, not security definer, with another search_path, or missing -> STOPS, nothing built, nothing replaced (checked for each of the three)
#   run again where it is applied -> stops at its first plain CREATE (nothing changes): the objects are already there
#
# Runs after the other guards and ends with the migration applied.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
export PGOPTIONS="-c client_min_messages=warning"   # the "does not exist, skipping" notices of the strip step are noise
MIG=supabase/migrations/20261021100000_floor_plan_and_table_states.sql
BEFORE=tests/db/fixtures/floor_before.sql
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - migration guard (floor plan): $1"; exit 1; }
run_mig() { OUT=$(psql -X -v ON_ERROR_STOP=1 -d "$DB" -f "$MIG" 2>&1) && RC=0 || RC=$?; }

FNS=(get_unavailable_table_types desk_walkin_options desk_create_walkin)
ARGS_get_unavailable_table_types="p_venue_id uuid, p_booking_date date, p_time_slot_id uuid"
ARGS_desk_walkin_options="p_venue uuid, p_night date"
ARGS_desk_create_walkin="p_venue uuid, p_night date, p_table_type uuid, p_slot uuid, p_guests integer, p_hours integer, p_name text, p_email text, p_phone text, p_terms_confirmed boolean"
CONST_get_unavailable_table_types=c_before_unavail
CONST_desk_walkin_options=c_before_options
CONST_desk_create_walkin=c_before_walkin

fp() { # fingerprint of one function
  local args="ARGS_$1"
  psql_db -c "select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = '$1' and pg_get_function_identity_arguments(p.oid) = '${!args}'"
}
declared() { local c="CONST_$1"; grep -E "${!c} +constant" "$MIG" | grep -oE "[0-9a-f]{32}"; }
uses_count() { [ "$(psql_db -c "select position('site_table_taken_count' in prosrc) > 0 from pg_proc where proname = '$1'")" = "t" ]; }
built() { [ "$(psql_db -c "select to_regclass('public.site_table_blocks') is not null")" = "t" ]; }
nothing_built() {
  built && fail "$1: the blocks table was built even though the migration stopped"
  [ "$(psql_db -c "select count(*) from information_schema.columns where table_schema = 'public' and column_name in ('included_admissions', 'deposit_terms')")" = "0" ] || fail "$1: columns were added even though the migration stopped"
  [ "$(psql_db -c "select count(*) from pg_proc where proname in ('site_table_taken_count', 'desk_table_block', 'desk_move_booking', 'place_venue_table', 'save_venue_deposit_terms')")" = "0" ] || fail "$1: functions were built even though the migration stopped"
  for f in "${FNS[@]}"; do uses_count "$f" && fail "$1: $f was replaced even though the migration stopped"; done
  return 0
}
strip() { # remove everything the migration builds (the three replaced functions are put back by the caller)
  psql_db -c "drop trigger if exists site_table_bookings_snapshot_terms on public.site_table_bookings" \
          -c "drop function if exists public.site_table_bookings_snapshot_terms()" \
          -c "drop function if exists public.list_venue_table_layout(uuid), public.place_venue_table(uuid, uuid, uuid, numeric, numeric, numeric, numeric), public.unplace_venue_table(uuid, uuid), public.set_table_included_admissions(uuid, uuid, int)" \
          -c "drop function if exists public.desk_table_states(uuid, date), public.desk_table_block(uuid, date, uuid, uuid, text, int, text, int), public.desk_table_release(uuid), public.desk_table_blocks(uuid, date)" \
          -c "drop function if exists public.desk_move_booking(uuid, uuid, text), public.desk_booking_moves(uuid), public.venue_deposit_terms(uuid), public.save_venue_deposit_terms(uuid, jsonb)" \
          -c "drop function if exists public.site_table_taken_count(uuid, uuid, date, text), public.site_checkout_hold()" \
          -c "drop table if exists public.site_table_blocks, public.site_booking_moves" \
          -c "alter table public.site_table_types drop column if exists included_admissions" \
          -c "alter table public.site_table_bookings drop column if exists included_admissions, drop column if exists deposit_terms" \
          -c "alter table public.site_venues drop column if exists deposit_terms" >/dev/null
}
old_functions() { psql_db -f "$BEFORE" >/dev/null; }

# the fingerprints the migration DECLARES must be what the old functions really have, and the replayed (new) ones must differ
final() { local v="FINAL_$1"; echo "${!v}"; }   # bash 3.2 has no associative arrays
for f in "${FNS[@]}"; do printf -v "FINAL_$f" '%s' "$(fp "$f")"; done
built || fail "test setup: the replay should have built everything"
strip
old_functions
for f in "${FNS[@]}"; do
  [ "$(fp "$f")" = "$(declared "$f")" ] || fail "the migration declares $(declared "$f") for $f, but the repository version is $(fp "$f")"
  [ "$(fp "$f")" != "$(final "$f")" ]    || fail "test setup: the old $f should differ from the replayed new one"
done
nothing_built "test setup"

# 1. The known versions are replaced and everything is built.
run_mig
[ "$RC" = "0" ]                                 || fail "the migration failed on the known versions: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "the replaced $f is not the one the replay produced"; done
built                                           || fail "the migration did not build everything"

# 2. Run again where it is applied: it stops at the first plain CREATE and changes nothing.
run_mig
[ "$RC" != "0" ]                                || fail "running it twice should stop (the objects exist), it did not: $OUT"
echo "$OUT" | grep -q "already exists"           || fail "expected an 'already exists' error on a second run, got: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "a refused second run changed $f"; done

# 3. Formatting is not drift: CRLF line endings and other indentation of the known versions.
strip; old_functions
sed -e 's/$/\r/' -e 's/^  /      /' "$BEFORE" | psql_db >/dev/null
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(declared "$f")" ] || fail "test setup: a reformatted $f should still fingerprint as the known version"; done
run_mig
[ "$RC" = "0" ]                                 || fail "reformatted copies of the known versions were treated as drift: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "reformatted $f was not replaced by the replayed one"; done

# 4. For EACH of the three: hand-edited, not security definer, another search_path, missing -> STOP, nothing built, nothing replaced.
for target in "${FNS[@]}"; do
  for variant in hand_edit invoker search_path missing; do
    strip; old_functions
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
    nothing_built "$target ($variant)"
    # the two OTHER functions are untouched (still the known old versions)
    for f in "${FNS[@]}"; do
      [ "$f" = "$target" ] && continue
      [ "$(fp "$f")" = "$(declared "$f")" ]                           || fail "$target ($variant): the migration changed $f"
    done
  done
done
# the hand-edit itself was not lost
strip; old_functions
awk '/CREATE OR REPLACE FUNCTION public\.desk_walkin_options/ { cur = 1 } /CREATE OR REPLACE FUNCTION public\.desk_create_walkin/ { cur = 0 } { print } cur && /^AS \$function\$/ { print "-- a hotfix someone made directly in the database" }' "$BEFORE" | psql_db >/dev/null
run_mig
psql_db -c "select prosrc from pg_proc where proname = 'desk_walkin_options'" | grep -q "a hotfix someone made" || fail "the hand-edit was lost"

# Back to the real final state.
strip; old_functions
run_mig
[ "$RC" = "0" ] && built || fail "could not put the floor plan state back at the end: $OUT"
for f in "${FNS[@]}"; do [ "$(fp "$f")" = "$(final "$f")" ] || fail "the final $f is not the replayed one"; done

echo "ok - floor plan: replaces the three live functions only when each is exactly the known version (also reformatted), and stops with nothing built when any one is hand-edited, not security definer, differently pathed or missing"
