-- Door exits, live occupancy and controlled overrides (20261122100000_door_exits_and_overrides.sql). What matters: exits are tracked only where an owner, organizer or the club's manager
-- turned that on; "inside now" is admitted minus exited and never negative; nobody leaves who is not inside; door people who cover the event can record exits and read the count, nobody
-- else can; an override needs a written reason and a manager of THIS event, admits only a guest held back by the entry code, refuses everything else exactly as the scanner does, is kept
-- with its reason, and counts as an admission; no older table or function is changed by any of it.
begin;

create function tests.exit_of(p_user uuid, p_code text, p_count int, p_event uuid) returns text language plpgsql as $$
declare r record;
begin
  perform tests.login(p_user);
  select * into r from public.door_record_exit(p_code, p_count, p_event);
  perform tests.logout();
  return r.result || ' in=' || coalesce(r.admitted::text, '-') || ' out=' || coalesce(r.exited::text, '-') || ' inside=' || coalesce(r.inside::text, '-');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.occ(p_user uuid, p_event uuid) returns text language plpgsql as $$
declare r record;
begin
  perform tests.login(p_user);
  select * into r from public.door_occupancy(p_event);
  perform tests.logout();
  return r.tracking || ' ' || r.admitted || '/' || r.exited || '/' || r.inside;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.over(p_user uuid, p_code text, p_reason text, p_count int, p_event uuid) returns text language plpgsql as $$
declare r record;
begin
  perform tests.login(p_user);
  select * into r from public.door_override_entry(p_code, p_reason, p_count, p_event);
  perform tests.logout();
  return r.result || ' in=' || coalesce(r.admitted::text, '-') || ' left=' || coalesce(r.remaining::text, '-');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.admit(p_user uuid, p_code text, p_count int, p_event uuid) returns text language plpgsql as $$
declare r record;
begin
  perform tests.login(p_user);
  select * into r from public.door_admit_group(p_code, p_count, p_event);
  perform tests.logout();
  return r.result;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.ologged(p_user uuid, p_event uuid) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user);
  v := (select string_agg(l.customer_name || ':' || l.guests || ':' || l.reason || ':' || l.by_me, ',' order by l.customer_name) from public.door_override_log(p_event) l);
  perform tests.logout();
  return coalesce(v, 'none');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.tracking_on(p_user uuid, p_event uuid, p_on boolean) returns text language plpgsql as $$
begin
  perform tests.login(p_user);
  perform public.set_event_exit_tracking(p_event, p_on);
  perform tests.logout();
  return 'done';
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.nights(p_user uuid, p_venue uuid) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user);
  v := (select string_agg(n.title || ':' || n.track_exits || ':' || n.admitted || '/' || n.exited || '/' || n.inside, ',' order by n.title) from public.door_club_nights(p_venue) n);
  perform tests.logout();
  return coalesce(v, 'none');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.override_rows(p_event uuid) returns int language sql security definer as $$ select count(*)::int from public.site_door_overrides where event_id = p_event $$;
create function tests.exit_rows(p_event uuid) returns int language sql security definer as $$ select count(*)::int from public.site_order_exits x join public.site_orders o on o.id = x.order_id where o.event_id = p_event $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000e1';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000e2';
  door_b constant uuid := '00000000-0000-0000-0000-0000000000e3';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000000e4';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000000e5';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000e6';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_r uuid; tok text;
  ev_a uuid; ev_b uuid; ev_r uuid; ev_old uuid;
  t_a uuid; t_b uuid; t_r uuid; t_old uuid;
  o_solo uuid; o_group uuid; o_gated uuid; o_gated_group uuid; o_unpaid uuid; o_refunded uuid; o_old uuid; o_done uuid; o_other uuid;
  n int;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@dx.example'), (door_a, 'doora@dx.example'), (door_b, 'doorb@dx.example'), (mgr_a, 'mgra@dx.example'), (mgr_b, 'mgrb@dx.example'), (rival_u, 'rival@dx2.example');

  perform tests.login(owner_u, 'owner@dx.example');
  org := public.create_organization('Door Exits Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@dx2.example');
  org2 := public.create_organization('Rival Exits Co', 'venue_owner');
  venue_r := public.create_org_venue(org2, 'Rival Club');

  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Tonight', 'd', 'Club A', now() - interval '1 hour', now() + interval '8 hours', 'published', venue_a) returning id into ev_a;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Club B Night', 'd', 'Club B', now() - interval '1 hour', now() + interval '8 hours', 'published', venue_b) returning id into ev_b;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Rival Night', 'd', 'Rival Club', now() - interval '1 hour', now() + interval '8 hours', 'published', venue_r) returning id into ev_r;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Last Night', 'd', 'Club A', now() - interval '20 hours', now() - interval '10 hours', 'published', venue_a) returning id into ev_old;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Ancient Night', 'd', 'Club A', now() - interval '40 hours', now() - interval '30 hours', 'published', venue_a);
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Far Future Night', 'd', 'Club A', now() + interval '3 days', now() + interval '3 days 8 hours', 'published', venue_a);
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Draft Night', 'd', 'Club A', now() - interval '1 hour', now() + interval '8 hours', 'draft', venue_a);
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_a, 'General', 5000, 50) returning id into t_a;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_b, 'General', 5000, 50) returning id into t_b;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_r, 'General', 5000, 50) returning id into t_r;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_old, 'General', 5000, 50) returning id into t_old;

  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id) values
    (ev_a, t_a, 'Solo Sam', 'sam@t.example', 1, 5000, 'paid', 'DX-SOLO', 'cs_dx_1') returning id into o_solo;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id) values
    (ev_a, t_a, 'Group Gina', 'gina@t.example', 4, 20000, 'paid', 'DX-GROUP', 'cs_dx_2') returning id into o_group;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id, is_non_transferable, access_code_verified) values
    (ev_a, t_a, 'Gated Gus', 'gus@t.example', 1, 5000, 'paid', 'DX-GATED', 'cs_dx_3', true, false) returning id into o_gated;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id, is_non_transferable, access_code_verified) values
    (ev_a, t_a, 'Gated Group', 'gg@t.example', 3, 15000, 'paid', 'DX-GATEDG', 'cs_dx_4', true, false) returning id into o_gated_group;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id, is_non_transferable, access_code_verified) values
    (ev_a, t_a, 'Unpaid Una', 'una@t.example', 1, 5000, 'pending', 'DX-UNPAID', 'cs_dx_5', true, false) returning id into o_unpaid;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id, is_non_transferable, access_code_verified) values
    (ev_a, t_a, 'Refunded Rex', 'rex@t.example', 1, 5000, 'refunded', 'DX-REFUND', 'cs_dx_6', true, false) returning id into o_refunded;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id, is_non_transferable, access_code_verified) values
    (ev_old, t_old, 'Old Olga', 'olga@t.example', 1, 5000, 'paid', 'DX-OLD', 'cs_dx_7', true, false) returning id into o_old;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id, is_non_transferable, access_code_verified, checked_in_at) values
    (ev_a, t_a, 'Done Dan', 'dan@t.example', 1, 5000, 'paid', 'DX-DONE', 'cs_dx_8', true, false, now()) returning id into o_done;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id, is_non_transferable, access_code_verified) values
    (ev_b, t_b, 'Other Club Ola', 'ola@t.example', 1, 5000, 'paid', 'DX-OTHER', 'cs_dx_9', true, false) returning id into o_other;

  -- door people and managers
  perform tests.login(owner_u, 'owner@dx.example');
  select i.token into tok from public.invite_member(org, 'doora@dx.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@dx.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@dx.example');
  select i.token into tok from public.invite_member(org, 'doorb@dx.example', 'door', venue_b) i;
  perform tests.login(door_b, 'doorb@dx.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@dx.example');
  select i.token into tok from public.invite_member(org, 'mgra@dx.example', 'manager', venue_a) i;
  perform tests.login(mgr_a, 'mgra@dx.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@dx.example');
  select i.token into tok from public.invite_member(org, 'mgrb@dx.example', 'manager', venue_b) i;
  perform tests.login(mgr_b, 'mgrb@dx.example'); perform public.accept_invitation(tok);
  perform tests.logout();

  ---------------------------------------------------------------- the setting
  perform tests.assert_eq('exits are not tracked until someone turns it on', (select track_exits from public.site_events where id = ev_a), false);
  perform tests.assert_eq('a door person cannot turn exit tracking on', tests.tracking_on(door_a, ev_a, true), 'ERROR: not authorized');
  perform tests.assert_eq('another club''s manager cannot', tests.tracking_on(mgr_b, ev_a, true), 'ERROR: not authorized');
  perform tests.assert_eq('a rival cannot', tests.tracking_on(rival_u, ev_a, true), 'ERROR: not authorized');
  perform tests.assert_eq('...and it stayed off', (select track_exits from public.site_events where id = ev_a), false);
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot change it', format($q$select public.set_event_exit_tracking(%L, true)$q$, ev_a), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- occupancy before and without exits
  perform tests.assert_eq('nobody is in yet, exits not tracked', tests.occ(door_a, ev_a), 'false 1/0/1');   -- Done Dan was checked in by an older scanner
  perform tests.assert_eq('the club''s manager reads the same figure', tests.occ(mgr_a, ev_a), 'false 1/0/1');
  perform tests.assert_eq('the owner too', tests.occ(owner_u, ev_a), 'false 1/0/1');
  perform tests.assert_eq('another club''s door person cannot read it', tests.occ(door_b, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('...nor another club''s manager', tests.occ(mgr_b, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('...nor a rival', tests.occ(rival_u, ev_a), 'ERROR: not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read it', format($q$select * from public.door_occupancy(%L)$q$, ev_a), 'permission denied');
  perform tests.logout();

  perform tests.assert_eq('an exit is refused while exits are not tracked', tests.exit_of(door_a, 'DX-DONE', 1, ev_a), 'not_tracking in=- out=- inside=-');

  ---------------------------------------------------------------- tracking on
  perform tests.assert_eq('the club''s manager turns exit tracking on', tests.tracking_on(mgr_a, ev_a, true), 'done');
  perform tests.assert_eq('...it is on', (select track_exits from public.site_events where id = ev_a), true);
  perform tests.assert_eq('the occupancy now says so', tests.occ(door_a, ev_a), 'true 1/0/1');

  perform tests.assert_eq('a solo guest is admitted', tests.admit(door_a, 'DX-SOLO', null, ev_a), 'ok');
  perform tests.assert_eq('two of the four in a group are admitted', tests.admit(door_a, 'DX-GROUP', 2, ev_a), 'ok');
  perform tests.assert_eq('inside is admitted minus exited', tests.occ(door_a, ev_a), 'true 4/0/4');

  perform tests.assert_eq('the solo guest leaves', tests.exit_of(door_a, 'DX-SOLO', 1, ev_a), 'ok in=1 out=1 inside=0');
  perform tests.assert_eq('the same guest cannot leave twice', tests.exit_of(door_a, 'DX-SOLO', 1, ev_a), 'nothing_inside in=1 out=1 inside=0');
  perform tests.assert_eq('one of the two admitted group guests leaves', tests.exit_of(door_a, 'DX-GROUP', 1, ev_a), 'ok in=2 out=1 inside=1');
  perform tests.assert_eq('no more leave than are inside', tests.exit_of(door_a, 'DX-GROUP', 2, ev_a), 'too_many in=2 out=1 inside=1');
  perform tests.assert_eq('...and nothing was recorded for that', tests.exit_rows(ev_a), 2);   -- the solo guest and one of the group
  perform tests.assert_eq('a guest who never came in cannot leave', tests.exit_of(door_a, 'DX-GATED', 1, ev_a), 'nothing_inside in=0 out=0 inside=0');
  perform tests.assert_eq('a guest admitted whole by an older scanner can leave', tests.exit_of(door_a, 'DX-DONE', 1, ev_a), 'ok in=1 out=1 inside=0');
  perform tests.assert_eq('inside now follows', tests.occ(door_a, ev_a), 'true 4/3/1');
  perform tests.assert_eq('an exit never goes below zero or hides an entry', tests.occ(mgr_a, ev_a), 'true 4/3/1');
  perform tests.assert_eq('an unknown code is not found', tests.exit_of(door_a, 'NOPE', 1, ev_a), 'not_found in=- out=- inside=-');
  perform tests.assert_eq('another club''s ticket is the wrong event', tests.exit_of(door_a, 'DX-OTHER', 1, ev_a), 'wrong_event in=- out=- inside=-');
  perform tests.assert_eq('another club''s door person cannot record this club''s exit', tests.exit_of(door_b, 'DX-GROUP', 1, ev_a), 'wrong_event in=- out=- inside=-');
  perform tests.assert_eq('a manager is not a door person: no exits from them', tests.exit_of(mgr_a, 'DX-GROUP', 1, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('a count below one is refused', tests.exit_of(door_a, 'DX-GROUP', 0, ev_a), 'ERROR: choose how many are leaving');

  -- A guest admitted and refunded afterwards is still in the room: they can be counted out. Done in a sub-transaction that is rolled back, so the figures above and below are untouched.
  begin
    update public.site_orders set status = 'refunded' where id = o_group;
    perform tests.assert_eq('a guest refunded after coming in can still be counted out', tests.exit_of(door_a, 'DX-GROUP', 1, ev_a), 'ok in=2 out=2 inside=0');
    raise exception 'undo the refund again';
  exception when others then
    if sqlerrm <> 'undo the refund again' then raise; end if;
  end;
  perform tests.assert_eq('...and that left no trace', tests.occ(door_a, ev_a), 'true 4/3/1');

  perform tests.assert_eq('turning tracking off is allowed and keeps the exits',tests.tracking_on(owner_u, ev_a, false), 'done');
  perform tests.assert_eq('...the figure still reads the same', tests.occ(door_a, ev_a), 'false 4/3/1');
  perform tests.assert_eq('...but nobody can record another exit', tests.exit_of(door_a, 'DX-GROUP', 1, ev_a), 'not_tracking in=- out=- inside=-');

  ---------------------------------------------------------------- who may override
  perform tests.assert_eq('a door person cannot override', tests.over(door_a, 'DX-GATED', 'Guest lost their phone', null, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('another club''s manager cannot', tests.over(mgr_b, 'DX-GATED', 'Guest lost their phone', null, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('a rival cannot', tests.over(rival_u, 'DX-GATED', 'Guest lost their phone', null, ev_a), 'ERROR: not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot override', format($q$select * from public.door_override_entry('DX-GATED', 'Guest lost their phone', null, %L)$q$, ev_a), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('nothing was admitted or logged by those', tests.override_rows(ev_a), 0);
  perform tests.assert_eq('...and the gated guest is still not in', (select count(*)::int from public.site_order_admissions where order_id = o_gated), 0);

  ---------------------------------------------------------------- a reason is required
  perform tests.assert_eq('no reason is refused', tests.over(mgr_a, 'DX-GATED', '', null, ev_a), 'ERROR: give a reason of 5 to 300 characters');
  perform tests.assert_eq('a too short reason is refused', tests.over(mgr_a, 'DX-GATED', 'ok', null, ev_a), 'ERROR: give a reason of 5 to 300 characters');
  perform tests.assert_eq('spaces are not a reason', tests.over(mgr_a, 'DX-GATED', '      ', null, ev_a), 'ERROR: give a reason of 5 to 300 characters');
  perform tests.assert_eq('a reason that is far too long is refused', tests.over(mgr_a, 'DX-GATED', repeat('x', 301), null, ev_a), 'ERROR: give a reason of 5 to 300 characters');
  perform tests.assert_eq('...still nothing admitted', (select count(*)::int from public.site_order_admissions where order_id = o_gated), 0);

  ---------------------------------------------------------------- what an override may and may not do
  perform tests.assert_eq('the scanner holds the gated guest back for the entry code', tests.admit(door_a, 'DX-GATED', null, ev_a), 'code_required');
  perform tests.assert_eq('the club''s manager overrides it with a reason', tests.over(mgr_a, 'DX-GATED', 'Guest lost their phone, ID checked', null, ev_a), 'ok in=1 left=0');
  perform tests.assert_eq('the guest is admitted once', (select coalesce(sum(guests), 0)::int from public.site_order_admissions where order_id = o_gated), 1);
  perform tests.assert_eq('the order is checked in', (select checked_in_at is not null from public.site_orders where id = o_gated), true);
  perform tests.assert_eq('the entry code was NOT marked verified by the override', (select access_code_verified from public.site_orders where id = o_gated), false);
  perform tests.assert_eq('the override is kept with its reason', tests.override_rows(ev_a), 1);
  perform tests.assert_eq('an override cannot be repeated for the same guest', tests.over(mgr_a, 'DX-GATED', 'Trying again anyway', null, ev_a), 'already_checked_in in=1 left=0');
  perform tests.assert_eq('...and nothing more was logged', tests.override_rows(ev_a), 1);
  perform tests.assert_eq('the owner may override too, for a group by choosing how many', tests.over(owner_u, 'DX-GATEDG', 'Group lead has the code, others do not', null, ev_a), 'group in=0 left=3');
  perform tests.assert_eq('...nothing was admitted until a number was chosen', (select count(*)::int from public.site_order_admissions where order_id = o_gated_group), 0);
  perform tests.assert_eq('...more than the ticket allows is refused', tests.over(owner_u, 'DX-GATEDG', 'Group lead has the code, others do not', 4, ev_a), 'too_many in=0 left=3');
  perform tests.assert_eq('...two of the three are admitted', tests.over(owner_u, 'DX-GATEDG', 'Group lead has the code, others do not', 2, ev_a), 'ok in=2 left=1');
  perform tests.assert_eq('a count below one is refused', tests.over(owner_u, 'DX-GATEDG', 'Group lead has the code, others do not', 0, ev_a), 'ERROR: choose how many are coming in');

  perform tests.assert_eq('a ticket nothing holds back needs no override', tests.over(mgr_a, 'DX-GROUP', 'No reason needed really', 1, ev_a), 'no_override_needed in=2 left=2');
  perform tests.assert_eq('an unpaid order stays refused', tests.over(mgr_a, 'DX-UNPAID', 'The guest says they paid', null, ev_a), 'not_paid in=0 left=1');
  perform tests.assert_eq('a refunded order stays refused', tests.over(mgr_a, 'DX-REFUND', 'The guest says it was a mistake', null, ev_a), 'refunded in=0 left=1');
  perform tests.assert_eq('an event that is over stays refused', tests.over(mgr_a, 'DX-OLD', 'Late guest from last night', null, ev_old), 'expired in=0 left=1');
  perform tests.assert_eq('a ticket of another club is the wrong event', tests.over(mgr_a, 'DX-OTHER', 'Wrong door', null, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('an unknown code is not found for a manager', tests.over(mgr_a, 'NOPE', 'No such ticket', null, ev_a), 'not_found in=- left=-');
  perform tests.assert_eq('a different event for this club''s ticket is the wrong event', tests.over(mgr_a, 'DX-GATEDG', 'Wrong event chosen', null, ev_old), 'wrong_event in=- left=-');
  perform tests.assert_eq('only those refusals that came from the code were overridden', tests.override_rows(ev_a), 2);

  perform tests.assert_eq('the override counts as an admission in the occupancy', tests.occ(door_a, ev_a), 'false 7/3/4');

  ---------------------------------------------------------------- the log
  perform tests.assert_eq('the manager reads the log, with their own marked', tests.ologged(mgr_a, ev_a), 'Gated Group:2:Group lead has the code, others do not:false,Gated Gus:1:Guest lost their phone, ID checked:true');
  perform tests.assert_eq('a door person cannot read the log', tests.ologged(door_a, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('another club''s manager cannot', tests.ologged(mgr_b, ev_a), 'ERROR: not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select * from public.door_override_log(%L)$q$, ev_a), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the club's nights
  perform tests.assert_eq('the club''s manager sees the nights that are on or ended under 12 hours ago, with their figures (not a night over 30 hours ago, one 3 days away, or a draft)', tests.nights(mgr_a, venue_a), 'Last Night:false:0/0/0,Tonight:false:7/3/4');
  perform tests.assert_eq('the owner sees the same for the club', tests.nights(owner_u, venue_a), 'Last Night:false:0/0/0,Tonight:false:7/3/4');
  perform tests.assert_eq('another club''s manager cannot read this club''s nights', tests.nights(mgr_b, venue_a), 'ERROR: not authorized');
  perform tests.assert_eq('a door person cannot', tests.nights(door_a, venue_a), 'ERROR: not authorized');
  perform tests.assert_eq('a rival cannot', tests.nights(rival_u, venue_a), 'ERROR: not authorized');
  perform tests.assert_eq('the other club has its own night', tests.nights(mgr_b, venue_b), 'Club B Night:false:0/0/0');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select * from public.door_club_nights(%L)$q$, venue_a), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the closed tables
  perform tests.login(door_a);
  perform tests.assert_raises('door staff cannot read exits directly', $q$select * from public.site_order_exits$q$, 'permission denied');
  perform tests.assert_raises('...nor overrides', $q$select * from public.site_door_overrides$q$, 'permission denied');
  perform tests.assert_raises('...nor write one', format($q$insert into public.site_door_overrides (order_id, event_id, reason, previous_result, guests) values (%L, %L, 'sneaky reason', 'x', 1)$q$, o_gated, ev_a), 'permission denied');
  perform tests.assert_raises('the inside helper is not for signed-in people', format($q$select public.door_order_in(%L)$q$, o_gated), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- nothing else changed
  perform tests.assert_eq('the older scanner still answers a gated ticket as before', tests.admit(door_a, 'DX-DONE', null, ev_a), 'already_checked_in');
end $$;

rollback;
