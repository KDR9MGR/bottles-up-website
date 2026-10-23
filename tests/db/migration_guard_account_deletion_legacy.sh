#!/usr/bin/env bash
# 20261030100000_account_deletion_legacy_columns.sql changes five columns of tables this repository does not define (they exist only in production), as ONE all-or-nothing statement,
# so it checks the shape it finds before it touches anything: a foreign key pointing somewhere else, or a CHECK / unique rule involving the column, STOPS it with nothing changed;
# a table or column that is not there is skipped; one already fixed is skipped. Runs after the other guards on the fully migrated database and ends with the migration applied.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
MIG=supabase/migrations/20261030100000_account_deletion_legacy_columns.sql
FN=account_deletion_legacy_columns
# shellcheck source=tests/db/guard_lib.sh
. tests/db/guard_lib.sh

# What the five foreign keys and the one NOT NULL look like: a fingerprint, and the pieces the scenarios look at.
shape() {
  psql_db -c "select md5(coalesce(string_agg(c.conrelid::regclass::text || '.' || c.conname || '=' || pg_get_constraintdef(c.oid), '|' order by c.conrelid::regclass::text, c.conname), '')
                     || (select string_agg(attrelid::regclass::text || '.' || attname || attnotnull::text, '|' order by attrelid::regclass::text, attname) from pg_attribute
                          where not attisdropped and (attrelid::regclass::text, attname) in (('admin_audit_log', 'admin_id'), ('conversations', 'created_by'), ('event_rsvps', 'verified_by'), ('vendor_onboarding_data', 'referrer_id'), ('venues', 'manager_id'))))
                from pg_constraint c where c.contype = 'f' and c.conrelid::regclass::text in ('admin_audit_log', 'conversations', 'event_rsvps', 'vendor_onboarding_data', 'venues')"
}
action() { psql_db -c "select confdeltype from pg_constraint where conname = '$1'"; }
admin_notnull() { psql_db -c "select attnotnull from pg_attribute where attrelid = 'public.admin_audit_log'::regclass and attname = 'admin_id'"; }
blockers() { psql_db -c "select count(*) from pg_constraint where contype = 'f' and confdeltype in ('a', 'r') and conrelid::regclass::text in ('admin_audit_log', 'conversations', 'event_rsvps', 'vendor_onboarding_data', 'venues')"; }

# What production looked like before: no rule on the foreign key (and, for the admin log, the NOT NULL that fought its "set null").
make_old() {   # <table> <column> <constraint> <target>
  psql_db -c "alter table public.$1 drop constraint $3, add constraint $3 foreign key ($2) references $4 (id)" >/dev/null
}

run_mig
[ "$RC" = "0" ]               || fail "the migration failed on the database the earlier guards left: $OUT"
FIXED=$(shape)
[ "$(blockers)" = "0" ] && [ "$(admin_notnull)" = "f" ] || fail "test setup: after the migration none of the five should be left in the way"

# 1. The old shape (no rule on two keys, NOT NULL on the admin log) is repaired and nothing else is touched.
make_old conversations created_by conversations_created_by_fkey auth.users
make_old venues manager_id venues_manager_id_fkey public.profiles
psql_db -c "alter table public.admin_audit_log alter column admin_id set not null" >/dev/null
[ "$(action conversations_created_by_fkey)" = "a" ] && [ "$(admin_notnull)" = "t" ] || fail "test setup: the old shape should be back"
[ "$(shape)" != "$FIXED" ]    || fail "test setup: the old shape should differ"
run_mig
[ "$RC" = "0" ]               || fail "the migration failed on the old shape: $OUT"
echo "$OUT" | grep -q "2 foreign keys changed to set null, 1 columns made nullable" || fail "expected two foreign keys and one NOT NULL to be changed, got: $OUT"
[ "$(shape)" = "$FIXED" ]     || fail "repairing the old shape did not give the shape of the replay"

# 2. Run again: nothing changes.
run_mig
[ "$RC" = "0" ]               || fail "running it where it is already applied failed: $OUT"
echo "$OUT" | grep -q "0 foreign keys changed to set null, 0 columns made nullable" || fail "expected nothing to change on a second run, got: $OUT"
[ "$(shape)" = "$FIXED" ]     || fail "a no-op run changed a constraint"

# 3. A rule involving the column that the file cannot judge (a CHECK here) stops everything: not even the admin log, which comes first in the file, is touched.
make_old conversations created_by conversations_created_by_fkey auth.users
psql_db -c "alter table public.admin_audit_log alter column admin_id set not null" -c "alter table public.conversations add constraint conversations_starter_known check (created_by is not null or id is not null)" >/dev/null
BEFORE=$(shape)
run_mig
[ "$RC" != "0" ]              || fail "the migration changed a column that a CHECK constraint involves"
echo "$OUT" | grep -q "conversations_starter_known" || fail "the error should name the CHECK, got: $OUT"
echo "$OUT" | grep -qi "nothing was changed"        || fail "the error should say nothing was changed, got: $OUT"
[ "$(shape)" = "$BEFORE" ] && [ "$(admin_notnull)" = "t" ] && [ "$(action conversations_created_by_fkey)" = "a" ] || fail "a refused migration still changed something"
psql_db -c "alter table public.conversations drop constraint conversations_starter_known" >/dev/null

# 4. A unique index on the column stops it too.
psql_db -c "create unique index conversations_starter_once on public.conversations (created_by)" >/dev/null
BEFORE=$(shape)
run_mig
[ "$RC" != "0" ] && echo "$OUT" | grep -q "conversations_starter_once" || fail "a unique index on the column should stop the migration, got: $OUT"
[ "$(shape)" = "$BEFORE" ]    || fail "a refused migration still changed something"
psql_db -c "drop index public.conversations_starter_once" >/dev/null

# 5. A foreign key that points somewhere other than where production's audit found it stops it (a different table is a different situation).
psql_db -c "alter table public.venues drop constraint venues_manager_id_fkey, add constraint venues_manager_id_fkey foreign key (manager_id) references public.vendors (id)" >/dev/null
BEFORE=$(shape)
run_mig
[ "$RC" != "0" ] && echo "$OUT" | grep -q "not at public.profiles" || fail "a foreign key to another table should stop the migration, got: $OUT"
[ "$(shape)" = "$BEFORE" ]    || fail "a refused migration still changed something"
make_old venues manager_id venues_manager_id_fkey public.profiles

# 6. A table that is not there (a database that never had the older tables) is skipped, the rest is still done.
psql_db -c "alter table public.event_rsvps rename to event_rsvps_away" >/dev/null
run_mig
[ "$RC" = "0" ]               || fail "the migration failed where one table is missing: $OUT"
echo "$OUT" | grep -q "public.event_rsvps does not exist" || fail "expected the 'skipped' notice, got: $OUT"
[ "$(action venues_manager_id_fkey)" = "n" ] && [ "$(action conversations_created_by_fkey)" = "n" ] || fail "the other columns were not fixed where one table is missing"
psql_db -c "alter table public.event_rsvps_away rename to event_rsvps" >/dev/null

# 7. Back to the shape the replay left, proved by the same fingerprint.
run_mig
[ "$RC" = "0" ]               || fail "the migration failed on the restored shape: $OUT"
[ "$(shape)" = "$FIXED" ]     || fail "the database is not back to the migrated shape"
[ "$(blockers)" = "0" ] && [ "$(admin_notnull)" = "f" ] || fail "a column is left in the way"
echo "ok - migration guard (account deletion, older tables): old shape repaired, safe to repeat, a CHECK / unique rule / foreign key elsewhere stops everything, a missing table is skipped"
