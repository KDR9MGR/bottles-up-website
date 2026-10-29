#!/usr/bin/env python3
"""Mutation check for 20261031100000_signup_without_email.sql: break the migration on purpose, one change at a time, and confirm the SQL test
(tests/db/tests/480_signup_without_email.sql) or the migration guard (tests/db/migration_guard_signup_without_email.sh) fails. A mutant that survives is either a
test gap (add a test) or an equivalent change (document it below). Run it in a COPY of the repository (git worktree), never in the folder someone builds from: it edits the
migration in place and puts it back.

  PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres LC_ALL=en_US.UTF-8 python3 tests/db/tools/mutants_signup_without_email.py

Known equivalents (cannot be told apart by any test):
  * "on conflict (id) do nothing" removed: the trigger fires after the account's own insert, so a vendors row with that id cannot exist yet (vendors.id references auth.users.id).
  * "return null" instead of "return new" in the no-e-mail branch: the return value of an AFTER row trigger is ignored.
"""
import os, subprocess, sys, shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
MIG = os.path.join(ROOT, 'supabase', 'migrations', '20261031100000_signup_without_email.sql')
DB = 'mutants_signup'
ENV = dict(os.environ, TEST_DB_NAME=DB, DEV_DB=DB)

MUTANTS = [
    ('no e-mail check removed', "      if new.email is null then\n        return new;\n      end if;\n", ""),
    ('check inverted', "if new.email is null then", "if new.email is not null then"),
    ('empty e-mail treated as none too', "if new.email is null then", "if coalesce(new.email, '') = '' then"),
    ('row skipped for every account', "if new.email is null then", "if true then"),
    ('default business name changed', "'User'), false)\n      on conflict", "'Guest'), false)\n      on conflict"),
    ('onboarding marked complete', "'User'), false)", "'User'), true)"),
    ('e-mail not copied', "values (new.id, new.email,", "values (new.id, 'x@y.example',"),
    ('name from the wrong key', "raw_user_meta_data->>'name'", "raw_user_meta_data->>'full_name'"),
    ('search_path dropped', "    set search_path = public\n    as $$\n    begin", "    as $$\n    begin"),
    ('security invoker', "    security definer\n    set search_path = public\n    as $$\n    begin", "    security invoker\n    set search_path = public\n    as $$\n    begin"),
    ('declared fixed fingerprint wrong', "c_after  constant text := '", "c_after  constant text := 'ffff"),
    ('declared old fingerprint wrong', "c_before constant text := '0f54", "c_before constant text := 'ffff"),
    ('already-fixed shortcut removed', "if v_live = c_after then", "if false then"),
    ('drift check removed', "if v_live <> c_before then", "if false then"),
    ('missing-function check removed', "if v_live is null then", "if false then"),
    ('trigger dropped by the migration', "  raise notice 'handle_new_user() fixed", "  drop trigger on_auth_user_created on auth.users;\n  raise notice 'handle_new_user() fixed"),
]

def sh(cmd):
    return subprocess.run(cmd, shell=True, cwd=ROOT, env=ENV, capture_output=True, text=True)

def build_and_check():
    b = sh('bash tests/db/dev/build_dev_db.sh')
    if b.returncode: return 'killed: the replay stops'
    t = sh(f'psql -X -v ON_ERROR_STOP=1 -d {DB} -f tests/db/tests/480_signup_without_email.sql')
    if t.returncode: return 'killed by the SQL test'
    g = sh('bash tests/db/migration_guard_signup_without_email.sh')
    if g.returncode: return 'killed by the guard'
    return 'passes'

original = open(MIG).read()
backup = MIG + '.orig'
shutil.copy(MIG, backup)
try:
    base = build_and_check()
    print('baseline:', base)
    if base != 'passes':   # the unmodified migration must pass both the SQL test and the guard
        print('the unmodified migration does not pass; fix that first'); sys.exit(1)
    survivors = 0
    for name, old, new in MUTANTS:
        if original.count(old) != 1:
            print(f'  ?? {name}: pattern found {original.count(old)} times, skipped'); survivors += 1; continue
        open(MIG, 'w').write(original.replace(old, new))
        r = build_and_check()
        print(f'  {("SURVIVED" if r == "passes" else r):28s} {name}')
        if r == 'passes': survivors += 1
finally:
    shutil.move(backup, MIG)
    sh(f'psql -X -q -d postgres -c "drop database if exists {DB} with (force)"')
print('survivors:', survivors)
