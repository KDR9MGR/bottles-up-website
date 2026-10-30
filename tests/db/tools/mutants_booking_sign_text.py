#!/usr/bin/env python3
"""Mutation check for 20261114100000_booking_sign_text.sql: break the function on purpose, one change at a time, and confirm the SQL test
(tests/db/tests/497_booking_sign_text.sql) fails. Run it in a COPY of the repository (git worktree): it edits the migration in place and puts it back.

  PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres LC_ALL=en_US.UTF-8 python3 tests/db/tools/mutants_booking_sign_text.py

Known equivalent: "signed-in people may not call it" (the grant moved to service_role): the database grants execute on new functions to signed-in roles by default, so the explicit grant
changes nothing there; the revoke from visitors is what matters, and is tested.
"""
import os, subprocess, sys, shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
MIG = os.path.join(ROOT, 'supabase', 'migrations', '20261114100000_booking_sign_text.sql')
DB = 'mutants_sign'
ENV = dict(os.environ, TEST_DB_NAME=DB, DEV_DB=DB)

MUTANTS = [
    ('no sign-in check', "  if auth.uid() is null then raise exception 'not authenticated'; end if;\n", ""),
    ('anyone with no role may read', "if v_level is null or v_level = 'verifier' then", "if v_level = 'verifier' then"),
    ('the verifier may read', "if v_level is null or v_level = 'verifier' then", "if v_level is null then"),
    ('every role is refused', "if v_level is null or v_level = 'verifier' then", "if true then"),
    ('the sign is not trimmed', "select nullif(btrim(b.bottle_sign_text), '') into v_sign", "select nullif(b.bottle_sign_text, '') into v_sign"),
    ('spaces count as a sign', "select nullif(btrim(b.bottle_sign_text), '') into v_sign", "select btrim(b.bottle_sign_text) into v_sign"),
    ('the wrong column is read', "select nullif(btrim(b.bottle_sign_text), '')", "select nullif(btrim(b.customer_name), '')"),
    ('any booking is read', "from public.site_table_bookings b where b.id = p_booking;", "from public.site_table_bookings b limit 1;"),
    ('it runs with the caller\'s rights', "stable\nsecurity definer\nset search_path = public", "stable\nset search_path = public"),
    ('no fixed search path', "stable\nsecurity definer\nset search_path = public", "stable\nsecurity definer"),
    ('it is no longer read only', "language plpgsql\nstable\nsecurity definer", "language plpgsql\nsecurity definer"),
    ('visitors may call it', "revoke all on function public.desk_booking_sign(uuid) from public, anon;", "revoke all on function public.desk_booking_sign(uuid) from public;"),
    ('signed-in people may not call it', "grant execute on function public.desk_booking_sign(uuid) to authenticated;", "grant execute on function public.desk_booking_sign(uuid) to service_role;"),
]

def sh(cmd):
    return subprocess.run(cmd, shell=True, cwd=ROOT, env=ENV, capture_output=True, text=True)

def build_and_check():
    b = sh('bash tests/db/dev/build_dev_db.sh')
    if b.returncode: return 'killed: the replay stops'
    t = sh(f'psql -X -v ON_ERROR_STOP=1 -d {DB} -f tests/db/tests/497_booking_sign_text.sql')
    return 'killed by the SQL test' if t.returncode else 'passes'

original = open(MIG).read()
backup = MIG + '.orig'
shutil.copy(MIG, backup)
try:
    base = build_and_check()
    print('baseline:', base)
    if base != 'passes':
        print('the unmodified migration does not pass; fix that first'); sys.exit(1)
    survivors = 0
    for name, old, new in MUTANTS:
        if original.count(old) != 1:
            print(f'  ?? {name}: pattern found {original.count(old)} times, skipped'); survivors += 1; continue
        open(MIG, 'w').write(original.replace(old, new))
        r = build_and_check()
        print(f'  {("SURVIVED" if r == "passes" else r):30s} {name}', flush=True)
        if r == 'passes': survivors += 1
finally:
    shutil.move(backup, MIG)
    sh(f'psql -X -q -d postgres -c "drop database if exists {DB} with (force)"')
print('survivors:', survivors)
