#!/usr/bin/env bash
# 20261112100000_profile_date_of_birth.sql adds a column, a check, a function and a trigger to profiles, a table that exists only in production. It is not a compare-and-swap (it replaces
# nothing), but it must refuse to run where it would collide with something that is already there, and say so before changing anything. Scenarios, each inside a transaction that is
# rolled back, on the database as the replay left it (the migration already applied):
#
#   run again                    -> STOPS: date_of_birth already exists, nothing changed
#   profiles has no age column   -> STOPS: it relies on age
#   profiles does not exist      -> STOPS: it extends the shared table
#   the state production is in BEFORE the migration (our objects taken away again) -> applies cleanly, in one go
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
MIG=supabase/migrations/20261112100000_profile_date_of_birth.sql
FN=profiles_set_age_from_date_of_birth
psql_db() { psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAIL - migration guard (profile date of birth): $1"; exit 1; }

# $1 = setup SQL run first, inside the transaction; sets RC and OUT. Always rolled back.
try() { OUT=$( { echo "begin;"; echo "$1"; cat "$MIG"; echo "rollback;"; } | psql -X -v ON_ERROR_STOP=1 -d "$DB" 2>&1) && RC=0 || RC=$?; }
objects() {  # what the migration owns, as a number: column + check + function + trigger
  psql_db -c "select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'date_of_birth')
            + (select count(*) from pg_constraint where conrelid = 'public.profiles'::regclass and conname = 'profiles_date_of_birth_range')
            + (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '$FN')
            + (select count(*) from pg_trigger where tgrelid = 'public.profiles'::regclass and tgname = '$FN')"
}

[ "$(objects)" = "4" ] || fail "test setup: the replay should have left all four objects, found $(objects)"

# Run again: stops before touching anything.
try ""
[ "$RC" != "0" ]                                   || fail "the migration ran twice without complaint"
echo "$OUT" | grep -q "date_of_birth already exists" || fail "expected the 'already exists' message, got: $OUT"
[ "$(objects)" = "4" ]                             || fail "a refused run changed what is there"

# No age column.
try "alter table public.profiles drop column age cascade;"
[ "$RC" != "0" ]                                   || fail "the migration ran on a table with no age column"
echo "$OUT" | grep -q "profiles.age is missing"     || fail "expected the 'age is missing' message, got: $OUT"

# No profiles table.
try "drop table public.profiles cascade;"
[ "$RC" != "0" ]                                   || fail "the migration ran with no profiles table"
echo "$OUT" | grep -q "profiles does not exist"     || fail "expected the 'does not exist' message, got: $OUT"

# Production before the migration: our four objects are not there. It applies cleanly and leaves exactly them.
BEFORE_SQL="drop trigger $FN on public.profiles; drop function public.$FN(); alter table public.profiles drop constraint profiles_date_of_birth_range; alter table public.profiles drop column date_of_birth;"
try "$BEFORE_SQL"
[ "$RC" = "0" ]                                    || fail "the migration failed on production's state before it: $OUT"
OUT=$( { echo "begin;"; echo "$BEFORE_SQL"; cat "$MIG"; echo "select 'objects=' || ("; echo "(select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'date_of_birth')"; echo "+ (select count(*) from pg_constraint where conrelid = 'public.profiles'::regclass and conname = 'profiles_date_of_birth_range')"; echo "+ (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '$FN')"; echo "+ (select count(*) from pg_trigger where tgrelid = 'public.profiles'::regclass and tgname = '$FN'));"; echo "rollback;"; } | psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" 2>&1) || fail "could not count what the migration made: $OUT"
echo "$OUT" | grep -q "objects=4" || fail "the migration did not leave all four objects: $OUT"

echo "ok - profile date of birth: refuses a second run, a table without age and a missing table before changing anything, and applies cleanly on production's state before it"
