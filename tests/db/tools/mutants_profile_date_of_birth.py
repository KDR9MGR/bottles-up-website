#!/usr/bin/env python3
"""Mutation check for 20261102100000_profile_date_of_birth.sql: break the migration on purpose, one change at a time, and confirm the SQL test
(tests/db/tests/490_profile_date_of_birth.sql) or the migration guard (tests/db/migration_guard_profile_date_of_birth.sh) fails. A mutant that survives is either a
test gap (add a test) or an equivalent change (document it below). Run it in a COPY of the repository (git worktree), never in the folder someone builds from: it edits the
migration in place and puts it back.

  PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres LC_ALL=en_US.UTF-8 python3 tests/db/tools/mutants_profile_date_of_birth.py

Known equivalent (cannot be told apart by any test):
  * "date_of_birth is null or" removed from the range check: a check that evaluates to NULL passes, so a missing date is allowed either way.
"""
import os, subprocess, sys, shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
MIG = os.path.join(ROOT, 'supabase', 'migrations', '20261102100000_profile_date_of_birth.sql')
DB = 'mutants_dob'
ENV = dict(os.environ, TEST_DB_NAME=DB, DEV_DB=DB)

MUTANTS = [
    ('pre-flight: profiles-exists check removed', "if to_regclass('public.profiles') is null then", "if false then"),
    ('pre-flight: age-exists check removed', "and column_name = 'age') then", "and column_name = 'age') and false then"),
    ('pre-flight: already-there check removed', "and column_name = 'date_of_birth') then", "and column_name = 'date_of_birth') and false then"),
    ('column is text', "add column date_of_birth date;", "add column date_of_birth text;"),
    ('column is required', "add column date_of_birth date;", "add column date_of_birth date not null default date '2000-01-01';"),
    ('range starts earlier', ">= date '1900-01-01'", ">= date '1800-01-01'"),
    ('range excludes its first day', ">= date '1900-01-01'", "> date '1900-01-01'"),
    ('range check dropped', "alter table public.profiles add constraint profiles_date_of_birth_range check (date_of_birth is null or date_of_birth >= date '1900-01-01');", ""),
    ('range check renamed', "add constraint profiles_date_of_birth_range", "add constraint profiles_dob_range"),
    ('arguments of age() swapped', "age(current_date::timestamp, new.date_of_birth::timestamp)", "age(new.date_of_birth::timestamp, current_date::timestamp)"),
    ('months instead of years', "extract(year from age(", "extract(month from age("),
    ('age counted from a fixed day', "age(current_date::timestamp,", "age(timestamp '2026-01-01',"),
    ('age rounded up (a day early)', "age(current_date::timestamp,", "age((current_date + 1)::timestamp,"),
    ('search_path dropped', "language plpgsql\nset search_path = public\nas $$", "language plpgsql\nas $$"),
    ('security definer', "language plpgsql\nset search_path = public", "language plpgsql\nsecurity definer\nset search_path = public"),
    ('execute not revoked', "revoke all on function public.profiles_set_age_from_date_of_birth() from public, anon, authenticated;", ""),
    ('execute revoked only from public', "from public, anon, authenticated;", "from public;"),
    ('trigger runs after the row is written', "before insert or update on public.profiles", "after insert or update on public.profiles"),
    ('trigger on insert only', "before insert or update on public.profiles", "before insert on public.profiles"),
    ('trigger on update only', "before insert or update on public.profiles", "before update on public.profiles"),
    ('trigger runs for rows without a date', "  when (new.date_of_birth is not null)\n", ""),
    ('trigger condition inverted', "when (new.date_of_birth is not null)", "when (new.date_of_birth is null)"),
    ('trigger renamed', "create trigger profiles_set_age_from_date_of_birth", "create trigger profiles_dob_age"),
    ('trigger never created', "create trigger profiles_set_age_from_date_of_birth\n  before insert or update on public.profiles\n  for each row\n  when (new.date_of_birth is not null)\n  execute function public.profiles_set_age_from_date_of_birth();", ""),
]

def sh(cmd):
    return subprocess.run(cmd, shell=True, cwd=ROOT, env=ENV, capture_output=True, text=True)

def build_and_check():
    b = sh('bash tests/db/dev/build_dev_db.sh')
    if b.returncode: return 'killed: the replay stops'
    t = sh(f'psql -X -v ON_ERROR_STOP=1 -d {DB} -f tests/db/tests/490_profile_date_of_birth.sql')
    if t.returncode: return 'killed by the SQL test'
    g = sh('bash tests/db/migration_guard_profile_date_of_birth.sh')
    if g.returncode: return 'killed by the guard'
    return 'passes'

original = open(MIG).read()
backup = MIG + '.orig'
shutil.copy(MIG, backup)
try:
    base = build_and_check()
    print('baseline:', base, flush=True)
    if base != 'passes':   # the unmodified migration must pass both the SQL test and the guard
        print('the unmodified migration does not pass; fix that first'); sys.exit(1)
    survivors = 0
    for name, old, new in MUTANTS:
        if original.count(old) != 1:
            print(f'  ?? {name}: pattern found {original.count(old)} times, skipped', flush=True); survivors += 1; continue
        open(MIG, 'w').write(original.replace(old, new))
        r = build_and_check()
        print(f'  {("SURVIVED" if r == "passes" else r):28s} {name}', flush=True)
        if r == 'passes': survivors += 1
finally:
    shutil.move(backup, MIG)
    sh(f'psql -X -q -d postgres -c "drop database if exists {DB} with (force)"')
print('survivors:', survivors)
