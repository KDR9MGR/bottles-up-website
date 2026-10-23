#!/usr/bin/env bash
# 20261029100000_account_deletion_actor_fks.sql changes constraints on live tables as ONE all-or-nothing statement, guarded: a column already fixed is skipped, a CHECK that is exactly
# what the earlier migrations created is replaced, one already replaced is recognised (safe to run twice), and a CHECK that is anything else (hand-edited in production) STOPS the
# migration with nothing changed. Runs after the other guards on the fully migrated database and ends with the migration applied.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB_NAME:-bottlesup_test}"
MIG=supabase/migrations/20261029100000_account_deletion_actor_fks.sql
FN=account_deletion_actor_fks
# shellcheck source=tests/db/guard_lib.sh
. tests/db/guard_lib.sh

# One fingerprint of every foreign key into auth.users and of the CHECKs the migration replaces.
shape() {
  psql_db -c "select md5(coalesce(string_agg(c.conrelid::regclass::text || '.' || c.conname || '=' || pg_get_constraintdef(c.oid), '|' order by c.conrelid::regclass::text, c.conname), ''))
                from pg_constraint c
               where (c.contype = 'f' and c.confrelid = 'auth.users'::regclass) or (c.contype = 'c' and c.conname ~ '(_together|_not_own|_release_check|_decided_check)\$')"
}
scan_fk()       { psql_db -c "select confdeltype from pg_constraint where conname = 'scan_attempts_scanned_by_fkey'"; }
scan_notnull()  { psql_db -c "select attnotnull from pg_attribute where attrelid = 'public.scan_attempts'::regclass and attname = 'scanned_by'"; }
vip_check()     { psql_db -c "select coalesce((select pg_get_constraintdef(oid) from pg_constraint where conname = 'site_vip_ended_together' and conrelid = 'public.site_vip_members'::regclass), '(none)')"; }
blockers()      { psql_db -c "select count(*) from pg_constraint where contype = 'f' and confrelid = 'auth.users'::regclass and confdeltype in ('a', 'r')"; }

# What production looks like BEFORE this migration, for the one foreign key and the one CHECK these scenarios work with.
make_old_fk()    { psql_db -c "alter table public.scan_attempts drop constraint scan_attempts_scanned_by_fkey, add constraint scan_attempts_scanned_by_fkey foreign key (scanned_by) references auth.users (id)" \
                           -c "alter table public.scan_attempts alter column scanned_by set not null" >/dev/null; }
make_old_check() { psql_db -c "alter table public.site_vip_members drop constraint if exists site_vip_ended_together" \
                           -c "alter table public.site_vip_members add constraint site_vip_ended_together check ((ended_at is null) = (ended_by is null))" >/dev/null; }

# The guards that ran before this one rebuilt older shapes (the September guard re-runs the migration that creates guest_tickets, whose foreign key predates this fix), so start from
# the migration applied once more: that is also the "run it again where tables came back" case.
run_mig
[ "$RC" = "0" ]               || fail "the migration failed on the database the earlier guards left: $OUT"
FIXED=$(shape)
[ "$(blockers)" = "0" ]       || fail "test setup: after the migration no foreign key into auth.users should be left without an on-delete rule"
[ "$(scan_fk)" = "n" ] && [ "$(scan_notnull)" = "f" ] || fail "test setup: scan_attempts.scanned_by should be nullable with on delete set null after the replay"

# 1. The old shape of one foreign key and one CHECK is repaired, and nothing else is touched.
make_old_fk; make_old_check
[ "$(scan_fk)" = "a" ] && [ "$(scan_notnull)" = "t" ] || fail "test setup: the old foreign key should be back"
[ "$(shape)" != "$FIXED" ]    || fail "test setup: the old shape should differ"
run_mig
[ "$RC" = "0" ]               || fail "the migration failed on the old shape: $OUT"
echo "$OUT" | grep -q "1 foreign keys changed to set null, 1 checks relaxed" || fail "expected exactly one foreign key and one CHECK to be changed, got: $OUT"
[ "$(scan_fk)" = "n" ] && [ "$(scan_notnull)" = "f" ] || fail "scan_attempts.scanned_by was not made nullable with on delete set null"
[ "$(shape)" = "$FIXED" ]     || fail "repairing the old shape did not give the same constraints as the replay"

# 2. Run again: nothing changes (safe to repeat).
run_mig
[ "$RC" = "0" ]               || fail "running it where it is already applied failed: $OUT"
echo "$OUT" | grep -q "0 foreign keys changed to set null, 0 checks relaxed" || fail "expected nothing to change on a second run, got: $OUT"
[ "$(shape)" = "$FIXED" ]     || fail "a no-op run changed a constraint"

# 3. A CHECK that is not what the earlier migrations created is never replaced, and the whole statement stops: the foreign keys, which the file handles after the CHECKs, are not touched either.
make_old_fk
psql_db -c "alter table public.site_vip_members drop constraint site_vip_ended_together" -c "alter table public.site_vip_members add constraint site_vip_ended_together check (ended_at is null or ended_by is not null)" >/dev/null
DRIFTED=$(shape)
DRIFTED_CHECK=$(vip_check)
run_mig
[ "$RC" != "0" ]              || fail "the migration replaced a CHECK it does not recognise"
echo "$OUT" | grep -q "site_vip_ended_together" || fail "the error should name the constraint, got: $OUT"
echo "$OUT" | grep -qi "nothing was changed"    || fail "the error should say nothing was changed, got: $OUT"
[ "$(vip_check)" = "$DRIFTED_CHECK" ]     || fail "a refused migration still replaced the hand-edited CHECK"
[ "$(scan_fk)" = "a" ] && [ "$(scan_notnull)" = "t" ] || fail "a refused migration still changed a foreign key"
[ "$(shape)" = "$DRIFTED" ]   || fail "a refused migration changed something"

# 4. A CHECK that is missing altogether is skipped (nothing to relax); the foreign keys are still fixed.
psql_db -c "alter table public.site_vip_members drop constraint site_vip_ended_together" >/dev/null
[ "$(vip_check)" = "(none)" ] || fail "test setup: the CHECK should be gone"
run_mig
[ "$RC" = "0" ]               || fail "the migration failed where a CHECK is missing: $OUT"
echo "$OUT" | grep -q "has no constraint site_vip_ended_together" || fail "expected the 'skipped' notice, got: $OUT"
[ "$(scan_fk)" = "n" ] && [ "$(scan_notnull)" = "f" ] || fail "the foreign key was not fixed where a CHECK is missing"
[ "$(vip_check)" = "(none)" ] || fail "a missing CHECK was invented"

# 5. Put the database back as the replay left it, and prove it with the same fingerprint.
make_old_check
run_mig
[ "$RC" = "0" ]               || fail "the migration failed on the restored shape: $OUT"
[ "$(shape)" = "$FIXED" ]     || fail "the database is not back to the migrated shape"
[ "$(blockers)" = "0" ]       || fail "a foreign key without an on-delete rule is left"
echo "ok - migration guard (account deletion): old shape repaired, safe to repeat, a hand-edited CHECK stops everything, a missing one is skipped"
