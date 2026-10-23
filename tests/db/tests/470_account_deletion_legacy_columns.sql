-- Account deletion, the five older-table columns that 20261029100000 could not reach (20261030100000_account_deletion_legacy_columns.sql). Those tables exist only in production;
-- tests/db/prod_shapes/20261030100000_legacy_tables.sql gives them the shape production reported (id and the one column). What matters: an admin who has audit rows, the person who
-- started a conversation, the staff member who verified a guest-list entry, a vendor who referred another vendor and the manager of a venue can each be deleted; every one of those
-- records stays (same row, same other columns) with only the person gone; nothing else in the whole database is left in the way of a deletion; and running the migration again changes nothing.
begin;

-- One cell of one row as text; '(gone)' when the row does not exist, '(null)' when the cell is empty.
create function tests.cell(p_table text, p_col text, p_id uuid) returns text language plpgsql security definer as $$
declare r text; found_row boolean;
begin
  execute format('select true, %I::text from public.%I where id = $1', p_col, p_table) into found_row, r using p_id;
  if found_row is null then return '(gone)'; end if;
  return coalesce(r, '(null)');
end $$;
-- A fingerprint of the five foreign keys, to prove a second run changes nothing.
create function tests.shape() returns text language sql security definer as $$
  select md5(coalesce(string_agg(pg_get_constraintdef(c.oid) || c.conrelid::regclass::text || c.conname, '|' order by c.conrelid::regclass::text, c.conname), ''))
    from pg_constraint c where c.contype = 'f' and c.conrelid::regclass::text in ('admin_audit_log', 'conversations', 'event_rsvps', 'vendor_onboarding_data', 'venues') $$;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-000000000e01';
  starter constant uuid := '00000000-0000-0000-0000-000000000e02';
  verifier constant uuid := '00000000-0000-0000-0000-000000000e03';
  referrer constant uuid := '00000000-0000-0000-0000-000000000e04';
  referred constant uuid := '00000000-0000-0000-0000-000000000e05';
  mgr constant uuid := '00000000-0000-0000-0000-000000000e06';
  bystander constant uuid := '00000000-0000-0000-0000-0000000000a3';   -- a fixture person who is never deleted
  audit_row uuid; audit_other uuid; conv uuid; conv_other uuid; rsvp uuid; onboarding uuid; onboarding_other uuid; venue uuid; venue_other uuid;
  blockers text;
begin
  insert into auth.users (id, email) values (admin_u, 'admin@old.example'), (starter, 'starter@old.example'), (verifier, 'verifier@old.example'),
                                            (referrer, 'referrer@old.example'), (referred, 'referred@old.example'), (mgr, 'mgr@old.example');
  -- (a new sign-in may already get a profile / vendors row from a trigger, so these are "make sure it exists")
  insert into public.profiles (id, name) values (mgr, 'Venue Manager'), (bystander, 'Someone Else') on conflict (id) do nothing;
  insert into public.vendors (id, email, business_name) values (referrer, 'referrer@old.example', 'Referring Vendor'), (referred, 'referred@old.example', 'Referred Vendor') on conflict (id) do nothing;

  insert into public.admin_audit_log (admin_id, action, target_table, target_id, before, after) values (admin_u, 'approve_vendor', 'vendors', referred::text, '{"status":"pending"}', '{"status":"active"}') returning id into audit_row;
  insert into public.admin_audit_log (admin_id, action, target_table, target_id) values (bystander, 'view', 'vendors', referred::text) returning id into audit_other;
  insert into public.conversations (created_by) values (starter) returning id into conv;
  insert into public.conversations (created_by) values (bystander) returning id into conv_other;
  insert into public.event_rsvps (verified_by) values (verifier) returning id into rsvp;
  insert into public.vendor_onboarding_data (referrer_id) values (referrer) returning id into onboarding;
  insert into public.vendor_onboarding_data (referrer_id) values (null) returning id into onboarding_other;
  insert into public.venues (manager_id) values (mgr) returning id into venue;
  insert into public.venues (manager_id) values (bystander) returning id into venue_other;

  perform tests.assert_eq('the setup really ties each record to its person', concat_ws('/', tests.cell('admin_audit_log', 'admin_id', audit_row), tests.cell('conversations', 'created_by', conv), tests.cell('event_rsvps', 'verified_by', rsvp),
    tests.cell('vendor_onboarding_data', 'referrer_id', onboarding), tests.cell('venues', 'manager_id', venue)), concat_ws('/', admin_u, starter, verifier, referrer, mgr));

  ---------------------------------------------------------------- the admin who has audit rows (NOT NULL used to fight "set null")
  delete from auth.users where id = admin_u;
  perform tests.assert_eq('the admin is deleted', (select count(*)::int from auth.users where id = admin_u), 0);
  perform tests.assert_eq('their audit row stays with what was done, to what, and the before/after snapshots', (select concat_ws('/', action, target_table, (target_id = referred::text)::text, (before = '{"status":"pending"}'::jsonb)::text, (after = '{"status":"active"}'::jsonb)::text)
                                                                                                          from public.admin_audit_log where id = audit_row), 'approve_vendor/vendors/true/true/true');
  perform tests.assert_eq('...with nobody named as the admin', tests.cell('admin_audit_log', 'admin_id', audit_row), '(null)');
  perform tests.assert_eq('another admin''s audit row is untouched', tests.cell('admin_audit_log', 'admin_id', audit_other), bystander::text);

  ---------------------------------------------------------------- the person who started a conversation, the staff member who verified a guest-list entry
  delete from auth.users where id = starter;
  perform tests.assert_eq('the conversation stays, nobody named as its starter', tests.cell('conversations', 'created_by', conv), '(null)');
  perform tests.assert_eq('another person''s conversation is untouched', tests.cell('conversations', 'created_by', conv_other), bystander::text);
  delete from auth.users where id = verifier;
  perform tests.assert_eq('the guest-list entry stays, nobody named as the one who verified it', tests.cell('event_rsvps', 'verified_by', rsvp), '(null)');

  ---------------------------------------------------------------- a vendor who referred another vendor (their vendors row goes with their account)
  delete from auth.users where id = referrer;
  perform tests.assert_eq('the vendor is deleted along with their vendors row', (select count(*)::int from auth.users where id = referrer) + (select count(*)::int from public.vendors where id = referrer), 0);
  perform tests.assert_eq('the vendor they referred is untouched', (select count(*)::int from public.vendors where id = referred), 1);
  perform tests.assert_eq('the onboarding record they were named on stays, without a referrer', tests.cell('vendor_onboarding_data', 'referrer_id', onboarding), '(null)');
  perform tests.assert_eq('an onboarding record with no referrer is untouched', tests.cell('vendor_onboarding_data', 'referrer_id', onboarding_other), '(null)');

  ---------------------------------------------------------------- the manager of a venue (their profiles row goes with their account)
  delete from auth.users where id = mgr;
  perform tests.assert_eq('the manager is deleted along with their profile', (select count(*)::int from auth.users where id = mgr) + (select count(*)::int from public.profiles where id = mgr), 0);
  perform tests.assert_eq('the venue stays, without a manager', tests.cell('venues', 'manager_id', venue), '(null)');
  perform tests.assert_eq('another venue keeps its manager', tests.cell('venues', 'manager_id', venue_other), bystander::text);
  perform tests.assert_eq('nothing was lost: every record is still there', (select count(*)::int from public.admin_audit_log) + (select count(*)::int from public.conversations) + (select count(*)::int from public.event_rsvps)
                                                                           + (select count(*)::int from public.vendor_onboarding_data) + (select count(*)::int from public.venues), 9);

  ---------------------------------------------------------------- nothing left in the way, anywhere
  select coalesce(string_agg(c.conrelid::regclass::text || '.' || a.attname, ', '), 'none') into blockers from (
      with recursive gone(rel) as (select 'auth.users'::regclass union select c2.conrelid from pg_constraint c2 join gone on c2.confrelid = gone.rel where c2.contype = 'f' and c2.confdeltype = 'c')
      select c3.conrelid, c3.conkey from pg_constraint c3 join gone on c3.confrelid = gone.rel
       where c3.contype = 'f' and (c3.confdeltype in ('a', 'r') or (c3.confdeltype = 'n' and exists (select 1 from pg_attribute a2 where a2.attrelid = c3.conrelid and a2.attnum = any (c3.conkey) and a2.attnotnull)))
    ) c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey);
  perform tests.assert_eq('no foreign key into auth.users, or into anything deleted with the person, is left to refuse a deletion or to fail on a NOT NULL column', blockers, 'none');
  perform tests.assert_eq('the five foreign keys are set-null and point where they pointed before', (select string_agg(c.conrelid::regclass::text || '>' || c.confrelid::regclass::text || ':' || c.confdeltype::text, ', ' order by c.conrelid::regclass::text)
    from pg_constraint c where c.contype = 'f' and c.conrelid::regclass::text in ('admin_audit_log', 'conversations', 'event_rsvps', 'vendor_onboarding_data', 'venues')),
    'admin_audit_log>auth.users:n, conversations>auth.users:n, event_rsvps>auth.users:n, vendor_onboarding_data>vendors:n, venues>profiles:n');
  perform tests.assert_eq('every one of the five columns can hold null now', (select count(*)::int from pg_attribute where attnotnull and not attisdropped and (attrelid::regclass::text, attname) in
    (('admin_audit_log', 'admin_id'), ('conversations', 'created_by'), ('event_rsvps', 'verified_by'), ('vendor_onboarding_data', 'referrer_id'), ('venues', 'manager_id'))), 0);
end $$;

---------------------------------------------------------------- running the migration again changes nothing (it is safe to repeat)
create temp table shape_run as select tests.shape() as before;
\i supabase/migrations/20261030100000_account_deletion_legacy_columns.sql
select tests.assert_eq('the migration run a second time changes no constraint', tests.shape(), (select before from shape_run));

rollback;
