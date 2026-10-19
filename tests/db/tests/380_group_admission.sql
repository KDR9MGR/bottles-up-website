-- Group admission at the door (20261020170000_group_admission.sql). What matters: a group is admitted in pieces and never more than its allowance; a scan that does not say
-- how many never admits a group by accident; only door staff who cover the event can admit anyone; every outcome of the older scanner is still there (not found, wrong event,
-- unpaid, refunded, ended, entry code, already in) and nothing leaks across clubs; the older scanners refuse an order once any of it was admitted; the counts are exact; and two doors
-- cannot both admit the last guests.
begin;

create function tests.admit(p_user uuid, p_code text, p_count int, p_event uuid default null) returns text language plpgsql as $$
declare r record;
begin
  perform tests.login(p_user);
  select * into r from public.door_admit_group(p_code, p_count, p_event);
  return r.result || ' ' || coalesce(r.quantity::text, '-') || '/' || coalesce(r.admitted::text, '-') || '/' || coalesce(r.remaining::text, '-');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.admitted(p_code text) returns int language sql security definer as $$
  select coalesce(sum(a.guests), 0)::int from public.site_order_admissions a join public.site_orders o on o.id = a.order_id where o.ticket_code = p_code $$;
create function tests.checked_in(p_code text) returns boolean language sql security definer as $$
  select checked_in_at is not null from public.site_orders where ticket_code = p_code $$;
create function tests.admitted_by(p_code text) returns uuid language sql security definer as $$
  select a.admitted_by from public.site_order_admissions a join public.site_orders o on o.id = a.order_id where o.ticket_code = p_code limit 1 $$;
create function tests.code_of(p_order uuid) returns text language sql security definer as $$ select ticket_code from public.site_orders where id = p_order $$;
create function tests.scan_count(p_code text, p_result text) returns int language sql security definer as $$
  select count(*)::int from public.scan_attempts where ticket_code_attempted = p_code and result = p_result $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000c1';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000c2';
  door_ev constant uuid := '00000000-0000-0000-0000-0000000000c3';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000c4';
  rival_door constant uuid := '00000000-0000-0000-0000-0000000000c5';
  door_b constant uuid := '00000000-0000-0000-0000-0000000000c6';
  legacy_staff constant uuid := '00000000-0000-0000-0000-0000000000a1';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_r uuid; tok text;
  ev_a uuid; ev_a2 uuid; ev_b uuid; ev_r uuid; ev_old uuid;
  tier_a uuid; tier_a2 uuid; tier_b uuid; tier_r uuid; tier_old uuid;
  r record; n int; txt text; t timestamptz;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@ga.example'), (door_a, 'doora@ga.example'), (door_ev, 'doorev@ga.example'), (rival_u, 'rival@ga2.example'), (rival_door, 'doorr@ga2.example'), (door_b, 'doorb@ga.example');

  perform tests.login(owner_u, 'owner@ga.example');
  org := public.create_organization('Door Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@ga2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  venue_r := public.create_org_venue(org2, 'Rival Club');

  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Club A Night', 'd', 'Club A', now() + interval '1 hour', now() + interval '9 hours', 'published', venue_a) returning id into ev_a;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Club A Second Room', 'd', 'Club A', now() + interval '1 hour', now() + interval '9 hours', 'published', venue_a) returning id into ev_a2;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Club B Night', 'd', 'Club B', now() + interval '1 hour', now() + interval '9 hours', 'published', venue_b) returning id into ev_b;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Rival Night', 'd', 'Rival Club', now() + interval '1 hour', now() + interval '9 hours', 'published', venue_r) returning id into ev_r;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Old Night', 'd', 'Club A', now() - interval '20 hours', now() - interval '10 hours', 'published', venue_a) returning id into ev_old;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_a, 'General', 5000, 100) returning id into tier_a;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_a2, 'Room 2', 5000, 100) returning id into tier_a2;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_b, 'General', 5000, 100) returning id into tier_b;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_r, 'General', 5000, 100) returning id into tier_r;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_old, 'General', 5000, 100) returning id into tier_old;

  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, is_non_transferable) values
    (ev_a, tier_a, 'Solo Sam', 'sam@t.example', 1, 5000, 'paid', 'GA-SOLO', false),
    (ev_a, tier_a, 'Group Gina', 'gina@t.example', 4, 20000, 'paid', 'GA-GROUP4', false),
    (ev_a, tier_a, 'Group Gus', 'gus@t.example', 3, 15000, 'paid', 'GA-GROUP3', false),
    (ev_a, tier_a, 'Old Ollie', 'ollie@t.example', 3, 15000, 'paid', 'GA-OLD', false),
    (ev_a, tier_a, 'Refund Rita', 'rita@t.example', 2, 10000, 'refunded', 'GA-REF', false),
    (ev_a, tier_a, 'Pending Pat', 'pat@t.example', 2, 10000, 'pending', 'GA-PEND', false),
    (ev_a, tier_a, 'Failed Fay', 'fay@t.example', 2, 10000, 'failed', 'GA-FAIL', false),
    (ev_a, tier_a, 'Code Cleo', 'cleo@t.example', 2, 10000, 'paid', 'GA-NT', true),
    (ev_a2, tier_a2, 'Room Rob', 'rob@t.example', 2, 10000, 'paid', 'GA-ROOM2', false),
    (ev_b, tier_b, 'Bea Club-B', 'bea@t.example', 2, 10000, 'paid', 'GA-CLUBB', false),
    (ev_r, tier_r, 'Rex Rival', 'rex@t.example', 2, 10000, 'paid', 'GA-RIVAL', false),
    (ev_old, tier_old, 'Late Lena', 'lena@t.example', 2, 10000, 'paid', 'GA-ENDED', false);

  perform tests.login(owner_u, 'owner@ga.example');
  select i.token into tok from public.invite_member(org, 'doora@ga.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@ga.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@ga.example');
  select i.token into tok from public.invite_member(org, 'doorb@ga.example', 'door', venue_b) i;
  perform tests.login(door_b, 'doorb@ga.example'); perform public.accept_invitation(tok);
  perform tests.login(rival_u, 'rival@ga2.example');
  select i.token into tok from public.invite_member(org2, 'doorr@ga2.example', 'door', venue_r) i;
  perform tests.login(rival_door, 'doorr@ga2.example'); perform public.accept_invitation(tok);
  perform tests.logout();

  ---------------------------------------------------------------- who may
  perform tests.assert_eq('the owner is not a door person', tests.admit(owner_u, 'GA-SOLO', null), 'ERROR: not authorized');
  perform tests.assert_eq('existing door_staff have their own pages, not this scanner', tests.admit(legacy_staff, 'GA-SOLO', null), 'ERROR: not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor is refused outright', $q$select * from public.door_admit_group('GA-SOLO', null, null)$q$, 'permission denied');
  perform tests.assert_raises('...also for the counts', format($q$select * from public.door_admission_counts(array[%L]::uuid[])$q$, ev_a), 'permission denied');
  perform tests.assert_raises('...and the guest list', format($q$select * from public.door_guest_admissions(%L)$q$, ev_a), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- what is not a valid admission
  perform tests.assert_eq('a code that is not a ticket is not found, and says nothing else', tests.admit(door_a, 'NOPE', null), 'not_found -/-/-');
  perform tests.assert_eq('...and it is logged', tests.scan_count('NOPE', 'not_found'), 1);
  perform tests.assert_eq('another club''s ticket is the wrong event, with nothing about the guest', tests.admit(door_a, 'GA-CLUBB', null), 'wrong_event -/-/-');
  perform tests.login(door_a);
  select * into r from public.door_admit_group('GA-CLUBB', null, null);
  perform tests.assert_true('...no name, no title, no tier', r.customer_name is null and r.event_title is null and r.tier_name is null);
  perform tests.assert_eq('a rival''s ticket is the wrong event too', tests.admit(door_a, 'GA-RIVAL', null), 'wrong_event -/-/-');
  perform tests.assert_eq('a ticket of this club but not of the event chosen on the screen is the wrong event', tests.admit(door_a, 'GA-ROOM2', null, ev_a), 'wrong_event -/-/-');
  perform tests.login(door_a);
  select * into r from public.door_admit_group('GA-ROOM2', null, ev_a);
  perform tests.assert_eq('...and the event it IS for is named, because this person covers it', r.event_title, 'Club A Second Room');
  perform tests.assert_eq('without an event chosen, any event the person covers works', tests.admit(door_a, 'GA-ROOM2', 2, null), 'ok 2/2/0');
  perform tests.assert_eq('a refunded order is told apart from an unpaid one', tests.admit(door_a, 'GA-REF', 2), 'refunded 2/0/2');
  perform tests.assert_eq('a pending order is not paid', tests.admit(door_a, 'GA-PEND', 1), 'not_paid 2/0/2');
  perform tests.assert_eq('so is a failed one', tests.admit(door_a, 'GA-FAIL', null), 'not_paid 2/0/2');
  perform tests.assert_eq('a ticket for an event that is over says so', tests.admit(door_a, 'GA-ENDED', 1), 'expired 2/0/2');
  perform tests.assert_eq('a ticket that needs its entry code is not admitted here', tests.admit(door_a, 'GA-NT', 1), 'code_required 2/0/2');
  perform tests.assert_eq('a refused refund or unpaid scan is logged as not paid', tests.scan_count('GA-REF', 'not_paid') + tests.scan_count('GA-PEND', 'not_paid') + tests.scan_count('GA-FAIL', 'not_paid'), 3);
  perform tests.assert_eq('none of those admitted anyone', tests.admitted('GA-REF') + tests.admitted('GA-PEND') + tests.admitted('GA-FAIL') + tests.admitted('GA-ENDED') + tests.admitted('GA-NT') + tests.admitted('GA-CLUBB'), 0);
  perform tests.assert_eq('...nor marked any order as used', (tests.checked_in('GA-REF') or tests.checked_in('GA-PEND') or tests.checked_in('GA-ENDED') or tests.checked_in('GA-NT'))::int, 0);

  ---------------------------------------------------------------- one guest: a scan is still one scan
  perform tests.assert_eq('a ticket of one guest is admitted by a scan with no count', tests.admit(door_a, 'GA-SOLO', null), 'ok 1/1/0');
  perform tests.assert_true('...the order is marked used, as a whole-order scan does', tests.checked_in('GA-SOLO'));
  perform tests.assert_eq('...an admission is recorded', tests.admitted('GA-SOLO'), 1);
  perform tests.assert_eq('scanning it again is "already checked in"', tests.admit(door_a, 'GA-SOLO', null), 'already_checked_in 1/1/0');
  perform tests.assert_eq('...also when asked for a count', tests.admit(door_a, 'GA-SOLO', 1), 'already_checked_in 1/1/0');
  perform tests.assert_eq('...and nothing more was admitted', tests.admitted('GA-SOLO'), 1);

  ---------------------------------------------------------------- a group
  perform tests.assert_eq('a group scanned with no count admits NOBODY: it says how many it covers', tests.admit(door_a, 'GA-GROUP4', null), 'group 4/0/4');
  perform tests.assert_eq('...nothing was recorded', tests.admitted('GA-GROUP4'), 0);
  perform tests.assert_true('...and the order is not marked used', not tests.checked_in('GA-GROUP4'));
  perform tests.assert_eq('...nor was an "ok" logged', tests.scan_count('GA-GROUP4', 'ok'), 0);
  perform tests.assert_eq('two of the four come in', tests.admit(door_a, 'GA-GROUP4', 2), 'ok 4/2/2');
  perform tests.assert_true('...the order is marked used from the first admission, so no older scanner can admit the rest', tests.checked_in('GA-GROUP4'));
  perform tests.assert_eq('...two admitted', tests.admitted('GA-GROUP4'), 2);
  perform tests.assert_eq('...by the person who scanned', tests.admitted_by('GA-GROUP4'), door_a);
  perform tests.assert_eq('a scan with no count now says how many are in and how many are left', tests.admit(door_a, 'GA-GROUP4', null), 'group 4/2/2');
  perform tests.assert_eq('more than the allowance is refused and nothing is admitted', tests.admit(door_a, 'GA-GROUP4', 3), 'too_many 4/2/2');
  perform tests.assert_eq('...nothing changed', tests.admitted('GA-GROUP4'), 2);
  perform tests.assert_eq('zero is not a number of guests', tests.admit(door_a, 'GA-GROUP4', 0), 'ERROR: choose how many are coming in');
  perform tests.assert_eq('...nor a negative number', tests.admit(door_a, 'GA-GROUP4', -1), 'ERROR: choose how many are coming in');
  perform tests.assert_eq('one more comes in', tests.admit(door_a, 'GA-GROUP4', 1), 'ok 4/3/1');
  perform tests.assert_eq('and the last', tests.admit(door_a, 'GA-GROUP4', 1), 'ok 4/4/0');
  perform tests.assert_eq('after that the ticket is used up', tests.admit(door_a, 'GA-GROUP4', 1), 'already_checked_in 4/4/0');
  perform tests.assert_eq('...also with no count', tests.admit(door_a, 'GA-GROUP4', null), 'already_checked_in 4/4/0');
  perform tests.assert_eq('...four admitted in all, never five', tests.admitted('GA-GROUP4'), 4);
  perform tests.assert_eq('three "ok" scans were logged for the group, with who', tests.scan_count('GA-GROUP4', 'ok'), 3);
  perform tests.assert_eq('the others that came back were logged as already checked in', tests.scan_count('GA-GROUP4', 'already_checked_in'), 2);
  perform tests.assert_eq('a group may all come in together', tests.admit(door_a, 'GA-GROUP3', 3), 'ok 3/3/0');
  perform tests.assert_eq('...and then it is used up', tests.admit(door_a, 'GA-GROUP3', null), 'already_checked_in 3/3/0');

  ---------------------------------------------------------------- the older scanners
  perform tests.login(door_a);
  select result into txt from public.door_scan_ticket('GA-OLD', ev_a);
  perform tests.assert_eq('the older scan admits a whole order at once, as before', txt, 'ok');
  perform tests.assert_eq('...and this scanner then sees it as fully in', tests.admit(door_a, 'GA-OLD', null), 'already_checked_in 3/3/0');
  perform tests.assert_eq('...also when asked for a count', tests.admit(door_a, 'GA-OLD', 1), 'already_checked_in 3/3/0');
  perform tests.login(door_a);
  select result into txt from public.door_scan_ticket('GA-GROUP4', ev_a);
  perform tests.assert_eq('an order that is partly or wholly admitted here is refused by the older scanner (it cannot admit the rest twice)', txt, 'already_checked_in');

  ---------------------------------------------------------------- an order whose quantity was lowered after guests came in
  perform tests.logout();
  update public.site_orders set quantity = 3 where ticket_code = 'GA-GROUP4';
  perform tests.assert_eq('four came in, the order now says three: nothing more is admitted, and nothing goes negative', tests.admit(door_a, 'GA-GROUP4', 1), 'already_checked_in 3/4/0');
  perform tests.logout();
  update public.site_orders set quantity = 4 where ticket_code = 'GA-GROUP4';

  ---------------------------------------------------------------- the exact counts
  perform tests.login(door_a);
  perform tests.assert_eq('guests really in at the event: Sam 1, Gina 4, Gus 3, Ollie 3 (older scanner), nobody else', (select c.guests_admitted from public.door_admission_counts(array[ev_a]) c where c.event_id = ev_a), 11);
  perform tests.assert_eq('the second room is counted on its own', (select c.guests_admitted from public.door_admission_counts(array[ev_a2]) c where c.event_id = ev_a2), 2);
  perform tests.assert_eq('several events at once', (select count(*) from public.door_admission_counts(array[ev_a, ev_a2]))::int, 2);
  perform tests.assert_eq('another club''s event is left out entirely', (select count(*) from public.door_admission_counts(array[ev_b, ev_r]))::int, 0);
  perform tests.assert_eq('...and an event that does not exist', (select count(*) from public.door_admission_counts(array[gen_random_uuid()]))::int, 0);
  perform tests.assert_eq('no events asked for, none answered', (select count(*) from public.door_admission_counts(null))::int, 0);
  perform tests.login(door_b);
  perform tests.assert_eq('the other club''s door gets nothing for this club''s event', (select count(*) from public.door_admission_counts(array[ev_a, ev_b]) c where c.event_id = ev_a)::int, 0);
  perform tests.assert_eq('...with nothing admitted there yet', (select c.guests_admitted from public.door_admission_counts(array[ev_a, ev_b]) c where c.event_id = ev_b), 0);

  -- a partly admitted group counts only the guests who came in
  perform tests.logout();
  update public.site_orders set quantity = 4 where ticket_code = 'GA-CLUBB';
  perform tests.assert_eq('a half-admitted group at the other club', tests.admit(door_b, 'GA-CLUBB', 1), 'ok 4/1/3');
  perform tests.login(door_b);
  perform tests.assert_eq('...counts one guest, not four', (select c.guests_admitted from public.door_admission_counts(array[ev_b]) c), 1);
  perform tests.assert_eq('...while the older figure counts the whole order (the reason the exact count exists)', (select d.guests_admitted from public.door_events((select m.id from public.active_memberships() m where m.role = 'door')) d where d.event_id = ev_b), 4);

  -- only paid orders count, like the older figure: an order refunded after guests came in no longer counts
  perform tests.logout();
  update public.site_orders set status = 'refunded' where ticket_code = 'GA-GROUP3';
  perform tests.login(door_a);
  perform tests.assert_eq('a refunded order is no longer counted as guests in (3 fewer)', (select c.guests_admitted from public.door_admission_counts(array[ev_a]) c where c.event_id = ev_a), 8);
  perform tests.assert_eq('...nor listed on the guest list', (select count(*) from public.door_guest_admissions(ev_a) g where tests.code_of(g.order_id) = 'GA-GROUP3')::int, 0);
  perform tests.logout();
  update public.site_orders set status = 'paid' where ticket_code = 'GA-GROUP3';

  ---------------------------------------------------------------- the guest list
  perform tests.login(door_a);
  perform tests.assert_eq('the guest list says how many of each order are in (only orders admitted through this scanner)',
    (select string_agg(tests.code_of(g.order_id) || '=' || g.admitted, ',' order by tests.code_of(g.order_id)) from public.door_guest_admissions(ev_a) g), 'GA-GROUP3=3,GA-GROUP4=4,GA-SOLO=1');
  perform tests.assert_raises('another club''s event is not allowed', format($q$select * from public.door_guest_admissions(%L)$q$, ev_b), 'not allowed');
  perform tests.assert_raises('...nor a rival''s', format($q$select * from public.door_guest_admissions(%L)$q$, ev_r), 'not allowed');
  perform tests.login(owner_u, 'owner@ga.example');
  perform tests.assert_raises('the owner is not a door person', format($q$select * from public.door_guest_admissions(%L)$q$, ev_a), 'not authorized');

  ---------------------------------------------------------------- the table and the functions stay closed
  perform tests.login(door_a);
  perform tests.assert_raises('door staff cannot read the admissions table directly', $q$select * from public.site_order_admissions$q$, 'permission denied');
  perform tests.assert_raises('...nor write to it', format($q$insert into public.site_order_admissions (order_id, guests) select id, 1 from public.site_orders limit 1$q$), 'permission denied');
  perform tests.logout();
  perform tests.assert_true('row level security is on', (select relrowsecurity from pg_class where oid = 'public.site_order_admissions'::regclass));
  perform tests.assert_true('the functions run with their owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('door_admit_group', 'door_admission_counts', 'door_guest_admissions')));
  perform tests.assert_true('visitors cannot run any of them',
    not has_function_privilege('anon', 'public.door_admit_group(text,int,uuid)', 'execute') and not has_function_privilege('anon', 'public.door_admission_counts(uuid[])', 'execute') and not has_function_privilege('anon', 'public.door_guest_admissions(uuid)', 'execute'));
end $$;

rollback;
