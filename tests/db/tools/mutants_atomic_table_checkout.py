#!/usr/bin/env python3
"""Mutation check for 20261111100000_atomic_table_checkout.sql: break the function on purpose, one change at a time, and confirm the SQL test
(tests/db/tests/485_atomic_table_checkout.sql) or the two-guests race (tests/db/concurrency_checkout.sh) fails. A mutant that survives is either a test gap (add a
test) or an equivalent change (document it below). Run it in a COPY of the repository (git worktree), never in the folder someone builds from: it edits the migration
in place and puts it back.

  PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres LC_ALL=en_US.UTF-8 python3 tests/db/tools/mutants_atomic_table_checkout.py

Known equivalents (cannot be told apart by any test):
  * "t.id" instead of "p_table_type" in the count and the insert: the lock query already found the row by that id.
  * "venue_id" taken from the table row (t.venue_id) instead of p_venue in the insert: the lock query matched on both.
"""
import os, subprocess, sys, shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
MIG = os.path.join(ROOT, 'supabase', 'migrations', '20261111100000_atomic_table_checkout.sql')
DB = 'mutants_checkout'
ENV = dict(os.environ, TEST_DB_NAME=DB, DEV_DB=DB)

LOCK = "where id = p_table_type and venue_id = p_venue for update;"
VALUES = "    p_venue, t.id, p_slot, p_arrival, p_customer_name, p_customer_email, p_customer_phone, p_guests, p_hours,\n    p_deposit_cents, p_bottle_subtotal_cents, p_tax_cents, p_fee_cents, p_total_cents, p_bottle_payment_choice, p_currency,\n    'pending', p_promo_code_id, p_discount_cents, p_sign_text\n"

def swap(a, b):
    return ('values: %s and %s swapped' % (a, b), VALUES, VALUES.replace(a, '@@').replace(b, a).replace('@@', b))

MUTANTS = [
    ('the lock is gone', LOCK, "where id = p_table_type and venue_id = p_venue;"),
    ('the lock ignores the venue', LOCK, "where id = p_table_type for update;"),
    ('one table too many is sold (only more than the stock refuses)', ">= t.inventory_count", "> t.inventory_count"),
    ('the guest\'s own checkout blocks them', "p_slot, p_arrival, p_customer_email) >=", "p_slot, p_arrival, null) >="),
    ('the count looks at the wrong date', "p_slot, p_arrival, p_customer_email) >=", "p_slot, p_arrival + 1, p_customer_email) >="),
    ('the count looks at the wrong time', "site_table_taken_count(t.id, p_slot,", "site_table_taken_count(t.id, gen_random_uuid(),"),
    ('sold out raises instead of answering none', "    return null;\n  end if;\n\n  insert", "    raise exception 'sold out';\n  end if;\n\n  insert"),
    ('another club\'s time is accepted', "where s.id = p_slot and s.venue_id = p_venue", "where s.id = p_slot"),
    ('the time check is gone', "if not exists (select 1 from public.site_venue_time_slots s where s.id = p_slot and s.venue_id = p_venue) then\n    raise exception 'arrival time not found';\n  end if;\n", ""),
    ('the table check is gone', "  if not found then raise exception 'table not found'; end if;\n", ""),
    ('the arrival date check is gone', "  if p_arrival is null then raise exception 'an arrival date is needed'; end if;\n", ""),
    ('the e-mail check is gone', "  if p_customer_email is null or btrim(p_customer_email) = '' then raise exception 'an e-mail address is needed'; end if;\n", ""),
    ('a blank e-mail is accepted', "p_customer_email is null or btrim(p_customer_email) = ''", "p_customer_email is null"),
    ('a missing e-mail is accepted', "p_customer_email is null or btrim(p_customer_email) = ''", "btrim(p_customer_email) = ''"),
    ('the booking is made paid', "    'pending', p_promo_code_id", "    'paid', p_promo_code_id"),
    ('the booking is made on another date', "p_venue, t.id, p_slot, p_arrival,", "p_venue, t.id, p_slot, p_arrival + 1,"),
    ('the booking is made at another time', "p_venue, t.id, p_slot, p_arrival,", "p_venue, t.id, (select s.id from public.site_venue_time_slots s where s.venue_id = p_venue and s.id <> p_slot limit 1), p_arrival,"),
    ('the phone is dropped', "p_customer_email, p_customer_phone, p_guests", "p_customer_email, null, p_guests"),
    ('the sign text is dropped', "p_discount_cents, p_sign_text\n  ) returning", "p_discount_cents, null\n  ) returning"),
    ('the promo code is dropped', "'pending', p_promo_code_id,", "'pending', null,"),
    ('the discount is dropped', "p_promo_code_id, p_discount_cents,", "p_promo_code_id, 0,"),
    ('the currency is forced', "p_bottle_payment_choice, p_currency,\n    'pending'", "p_bottle_payment_choice, 'cad',\n    'pending'"),
    ('the hours are dropped', "p_guests, p_hours,\n    p_deposit_cents", "p_guests, null,\n    p_deposit_cents"),
    swap('p_tax_cents', 'p_fee_cents'),
    swap('p_deposit_cents', 'p_bottle_subtotal_cents'),
    swap('p_guests', 'p_hours'),
    swap('p_customer_name', 'p_customer_email'),
    swap('p_bottle_payment_choice', 'p_currency'),
    ('it returns nothing for a booking made', "returning id into v_id;\n\n  return v_id;", "returning id into v_id;\n\n  return null;"),
    ('it runs with the caller\'s rights', "security definer\nset search_path = public\nas $$\ndeclare\n  t public", "set search_path = public\nas $$\ndeclare\n  t public"),
    ('the search path is not fixed', "security definer\nset search_path = public\nas $$\ndeclare\n  t public", "security definer\nas $$\ndeclare\n  t public"),
    ('everyone may call it', "  from public, anon, authenticated;\n", "  from anon;\n"),
    ('signed-in people may call it', "  to service_role;", "  to service_role, authenticated;"),
    ('visitors may call it', "  to service_role;", "  to service_role, anon;"),
]

def sh(cmd):
    return subprocess.run(cmd, shell=True, cwd=ROOT, env=ENV, capture_output=True, text=True)

def build_and_check():
    b = sh('bash tests/db/dev/build_dev_db.sh')
    if b.returncode: return 'killed: the replay stops'
    t = sh(f'psql -X -v ON_ERROR_STOP=1 -d {DB} -f tests/db/tests/485_atomic_table_checkout.sql')
    if t.returncode: return 'killed by the SQL test'
    r = sh('bash tests/db/concurrency_checkout.sh')
    if r.returncode: return 'killed by the race'
    return 'passes'

original = open(MIG).read()
backup = MIG + '.orig'
shutil.copy(MIG, backup)
try:
    base = build_and_check()
    print('baseline:', base)
    if base != 'passes':   # the unmodified migration must pass both the SQL test and the race
        print('the unmodified migration does not pass; fix that first'); sys.exit(1)
    only = os.environ.get('ONLY')
    survivors = 0
    for name, old, new in MUTANTS:
        if only and only not in name: continue
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
