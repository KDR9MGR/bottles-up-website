#!/usr/bin/env python3
"""Mutation check for 20261113100000_oversold_booking_queue.sql: break the functions and the table on purpose, one change at a time, and confirm the SQL test
(tests/db/tests/495_oversold_booking_queue.sql) or the race (tests/db/concurrency_oversold.sh) fails. A mutant that survives is either a test gap (add a test) or an
equivalent change (document it below). Run it in a COPY of the repository (git worktree), never in the folder someone builds from: it edits the migration in place and
puts it back.

  PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres LC_ALL=en_US.UTF-8 python3 tests/db/tools/mutants_oversold_booking_queue.py

Known equivalents (cannot be told apart by any test):
  * "for update" removed from the conflict row in desk_resolve_booking_conflict: it only matters for two managers closing the same conflict at the very same moment, and the
    second would then see 'resolved' and be refused either way.
"""
import os, subprocess, sys, shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
MIG = os.path.join(ROOT, 'supabase', 'migrations', '20261113100000_oversold_booking_queue.sql')
DB = 'mutants_oversold'
ENV = dict(os.environ, TEST_DB_NAME=DB, DEV_DB=DB)

MUTANTS = [
    # the flag
    ('a pending booking can be flagged', "if not found or b.status <> 'paid' then return false; end if;", "if not found then return false; end if;"),
    ('flagged when exactly full', "if v_paid + v_held <= v_inventory then return false; end if;", "if v_paid + v_held < v_inventory then return false; end if;"),
    ('one more than the club has is allowed', "if v_paid + v_held <= v_inventory then return false; end if;", "if v_paid + v_held <= v_inventory + 1 then return false; end if;"),
    ('held tables are not counted', "if v_paid + v_held <= v_inventory then return false; end if;", "if v_paid <= v_inventory then return false; end if;"),
    ('pending checkouts are counted as paid', "where k.table_type_id = b.table_type_id and k.time_slot_id = b.time_slot_id and k.booking_date = b.booking_date and k.status = 'paid';\n  select coalesce(sum", "where k.table_type_id = b.table_type_id and k.time_slot_id = b.time_slot_id and k.booking_date = b.booking_date and k.status in ('paid', 'pending');\n  select coalesce(sum"),
    ('refunded bookings are counted', "k.booking_date = b.booking_date and k.status = 'paid';\n  select coalesce(sum", "k.booking_date = b.booking_date and k.status in ('paid', 'refunded', 'cancelled');\n  select coalesce(sum"),
    ('every date is counted together', "where k.table_type_id = b.table_type_id and k.time_slot_id = b.time_slot_id and k.booking_date = b.booking_date and k.status = 'paid';\n  select coalesce(sum", "where k.table_type_id = b.table_type_id and k.time_slot_id = b.time_slot_id and k.status = 'paid';\n  select coalesce(sum"),
    ('every arrival time is counted together', "where k.table_type_id = b.table_type_id and k.time_slot_id = b.time_slot_id and k.booking_date = b.booking_date and k.status = 'paid';\n  select coalesce(sum", "where k.table_type_id = b.table_type_id and k.booking_date = b.booking_date and k.status = 'paid';\n  select coalesce(sum"),
    ('released holds are counted', " and k.released_at is null and (k.expires_at is null or k.expires_at > now());\n\n  if v_paid", " and (k.expires_at is null or k.expires_at > now());\n\n  if v_paid"),
    ('ended holds are counted', " and k.released_at is null and (k.expires_at is null or k.expires_at > now());\n\n  if v_paid", " and k.released_at is null;\n\n  if v_paid"),
    ('a confirmed guest can be flagged afterwards', "  if b.confirmation_sent_at is not null then return false; end if;\n", ""),
    ('a closed conflict still reads as open', "if found then return c.status = 'open'; end if;", "if found then return true; end if;"),
    ('an existing conflict is not looked for', "  select * into c from public.site_booking_conflicts k where k.booking_id = b.id;\n  if found then return c.status = 'open'; end if;\n", ""),
    ('the lock is gone', "select t.inventory_count into v_inventory from public.site_table_types t where t.id = b.table_type_id for update;\n  if not found then return false; end if;", "select t.inventory_count into v_inventory from public.site_table_types t where t.id = b.table_type_id;\n  if not found then return false; end if;"),
    ('the count is stored wrong', "v_paid + v_held, v_inventory);", "v_paid, v_inventory);"),
    ('the booking date is stored wrong', "b.time_slot_id, b.booking_date, v_paid", "b.time_slot_id, current_date, v_paid"),
    # the list
    ('the list needs no manager', "  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;\n  return query", "  return query"),
    ('a server may list', "  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;\n  return query", "  if public.desk_level(p_venue) is null then raise exception 'not allowed'; end if;\n  return query"),
    ('the list shows other clubs', "where k.venue_id = p_venue and (p_include_resolved", "where (p_include_resolved"),
    ('the list always shows closed ones', "(p_include_resolved or k.status = 'open')", "(true or k.status = 'open')"),
    ('the list never shows closed ones', "(p_include_resolved or k.status = 'open')", "(k.status = 'open')"),
    ('the guest\'s phone is not given', "b.customer_email, b.customer_phone,\n           t.name", "b.customer_email, null,\n           t.name"),
    # closing one
    ('closing needs no manager', "  if public.desk_level(c.venue_id) is distinct from 'manager' then raise exception 'not allowed'; end if;\n  if p_resolution is null", "  if p_resolution is null"),
    ('an unknown way is accepted', "p_resolution not in ('moved', 'refunded', 'kept')", "p_resolution not in ('moved', 'refunded', 'kept', 'ignored')"),
    ('"kept" is not a way', "p_resolution not in ('moved', 'refunded', 'kept')", "p_resolution not in ('moved', 'refunded')"),
    ('a two-letter note is enough', "char_length(v_note) < 3", "char_length(v_note) < 2"),
    ('a long note is accepted', "if char_length(v_note) > 500 then", "if char_length(v_note) > 501 then"),
    ('a closed conflict can be closed again', "  if c.status <> 'open' then raise exception 'this has already been dealt with'; end if;\n", ""),
    ('"moved" with no check', "    if b.status <> 'paid' or v_taken > v_inventory then", "    if false then"),
    ('"moved" refused when exactly full', "v_taken > v_inventory then", "v_taken >= v_inventory then"),
    ('"moved" accepted for a booking that is not paid', "    if b.status <> 'paid' or v_taken > v_inventory then", "    if v_taken > v_inventory then"),
    ('"refunded" with no check', "    if b.status not in ('refunded', 'cancelled') then raise exception 'refund or cancel the booking first'; end if;\n", ""),
    ('"refunded" refuses a cancelled booking', "if b.status not in ('refunded', 'cancelled') then", "if b.status not in ('refunded') then"),
    ('who closed it is not kept', "resolved_at = now(), resolved_by = auth.uid()", "resolved_at = now(), resolved_by = null"),
    ('the note is stored untrimmed', "resolution_note = v_note,", "resolution_note = p_note,"),
    ('closing is not logged', "  perform public.desk_log('booking.conflict_resolved'", "  perform null; -- public.desk_log('booking.conflict_resolved'"),
    # the table and the grants
    ('the person who closed it blocks their deletion', "resolved_by uuid references auth.users (id) on delete set null", "resolved_by uuid references auth.users (id)"),
    ('row level security is off', "alter table public.site_booking_conflicts enable row level security;\n", ""),
    ('signed-in people can read the table', "revoke all on table public.site_booking_conflicts from public, anon, authenticated;", "revoke all on table public.site_booking_conflicts from public, anon;"),
    ('the flag runs with the caller\'s rights', "returns boolean\nlanguage plpgsql\nsecurity definer\nset search_path = public\nas $$\ndeclare\n  b public", "returns boolean\nlanguage plpgsql\nset search_path = public\nas $$\ndeclare\n  b public"),
    ('signed-in people can call the flag', "grant execute on function public.site_flag_oversold_booking(uuid) to service_role;", "grant execute on function public.site_flag_oversold_booking(uuid) to service_role, authenticated;"),
    ('visitors can call the list', "revoke all on function public.desk_booking_conflicts(uuid, boolean) from public, anon;", "revoke all on function public.desk_booking_conflicts(uuid, boolean) from public;"),
    ('visitors can close one', "revoke all on function public.desk_resolve_booking_conflict(uuid, text, text) from public, anon;", "revoke all on function public.desk_resolve_booking_conflict(uuid, text, text) from public;"),
    ('the state rule is gone', "  constraint site_booking_conflicts_state_check check (", "  constraint site_booking_conflicts_state_check check (true or "),
]

def sh(cmd):
    return subprocess.run(cmd, shell=True, cwd=ROOT, env=ENV, capture_output=True, text=True)

def build_and_check():
    b = sh('bash tests/db/dev/build_dev_db.sh')
    if b.returncode: return 'killed: the replay stops'
    t = sh(f'psql -X -v ON_ERROR_STOP=1 -d {DB} -f tests/db/tests/495_oversold_booking_queue.sql')
    if t.returncode: return 'killed by the SQL test'
    r = sh('bash tests/db/concurrency_oversold.sh')
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
