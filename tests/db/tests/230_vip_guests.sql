-- Venue VIP list. What matters most: only the manager and owner of THAT club keep the list and see contact details and notes; a server sees
-- service perks only and the club's door entry perks only (no contact, notes or history, and never the whole list); event-only door staff,
-- organizers, security, other clubs and strangers see nothing; a perk with a limit cannot be redeemed past it (even by two people at once)
-- and an ended or expired membership redeems nothing; the invitation is only queued; every step is attributed.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.run_as(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.add(p_user uuid, p_email text, p_venue uuid, p_details jsonb) returns text language plpgsql as $$
declare id uuid;
begin
  perform tests.login(p_user, p_email);
  id := public.vip_add(p_venue, p_details);
  return 'ok:' || id::text;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.lookup(p_user uuid, p_email text, p_venue uuid, p_query text) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(concat_ws('/', name, tier, status, coalesce(host_name, '-'), coalesce(preferences, '-'), coalesce(email, '-'), coalesce(notes, '-'),
                     (select string_agg(p ->> 'label', '+' order by p ->> 'label') from jsonb_array_elements(perks) p)), ' | ' order by name)
                   from public.vip_lookup(p_venue, p_query)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.perk_id(p_member uuid, p_label text) returns uuid language sql security definer as $$
  select id from public.site_vip_perks where member_id = p_member and label = p_label $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000007d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000007d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000007d3';
  door_a constant uuid := '00000000-0000-0000-0000-0000000007d4';
  sec_1 constant uuid := '00000000-0000-0000-0000-0000000007d5';
  ev_door constant uuid := '00000000-0000-0000-0000-0000000007d6';
  org_u constant uuid := '00000000-0000-0000-0000-0000000007d7';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000007d8';
  rando constant uuid := '00000000-0000-0000-0000-0000000007d9';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; ev uuid;
  r text; ada uuid; bob uuid; cleo uuid; p_entry uuid; p_serv uuid; p_disc uuid; j jsonb; n int;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@vip.example'), (mgr_a, 'mgra@vip.example'), (srv_1, 'srv1@vip.example'), (door_a, 'doora@vip.example'), (sec_1, 'sec1@vip.example'),
    (ev_door, 'evdoor@vip.example'), (org_u, 'org@vip.example'), (mgr_b, 'mgrb@vip.example'), (rando, 'rando@vip.example');
  insert into public.profiles (id, name, email) values (mgr_a, 'Mia Manager', 'mgra@vip.example'), (srv_1, 'Sam Server', 'srv1@vip.example'), (door_a, 'Dee Door', 'doora@vip.example');

  perform tests.login(owner_u, 'owner@vip.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@vip.example', org, 'mgra@vip.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@vip.example', org, 'mgrb@vip.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@vip.example', org, 'srv1@vip.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@vip.example', org, 'doora@vip.example', 'door', venue_a, door_a);
  perform tests.join_as(mgr_a, 'mgra@vip.example', org, 'sec1@vip.example', 'security', venue_a, sec_1);
  perform tests.login(org_u, 'org@vip.example');
  org2 := public.create_organization('Night Events', 'organizer');
  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Night One', 'x', 'Somewhere', now() + interval '2 days', now() + interval '2 days 6 hours', 'draft', org2) returning id into ev;
  insert into public.site_memberships (org_id, user_id, role, event_id) values (org2, ev_door, 'door', ev);

  ---------------------------------------------------------------- adding a guest
  r := tests.add(mgr_a, 'mgra@vip.example', venue_a, jsonb_build_object('name', ' Ada Lovelace ', 'email', 'Ada@Example.com', 'tier', 'Gold', 'valid_until', to_char(current_date + 30, 'YYYY-MM-DD'),
        'host', mgr_a, 'preferences', 'still water, no ice', 'notes', 'allergic to nuts; likes booth 4'));
  perform tests.assert_true('a manager adds a guest', r like 'ok:%');
  ada := substr(r, 4)::uuid;
  bob := substr(tests.add(owner_u, 'owner@vip.example', venue_a, jsonb_build_object('name', 'Bob Barlow', 'phone', '+1 555 0100')), 4)::uuid;
  perform tests.assert_eq('the owner adds one too, with the default tier', tests.run_as(owner_u, 'owner@vip.example', format($q$select tier from (select (public.vip_detail(%L) ->> 'tier') as tier) x$q$, bob)), 'VIP');
  perform tests.assert_eq('the name is trimmed, the email lower-cased, a credential code is made', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select (d ->> 'name') || '/' || (d ->> 'email') || '/' || length(d ->> 'credential_code') from (select public.vip_detail(%L) d) x$q$, ada)), 'Ada Lovelace/ada@example.com/8');
  perform tests.assert_eq('a server cannot add', tests.add(srv_1, 'srv1@vip.example', venue_a, '{"name":"Zed Zebra","email":"z@example.com"}'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor the door', tests.add(door_a, 'doora@vip.example', venue_a, '{"name":"Zed Zebra","email":"z@example.com"}'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor security', tests.add(sec_1, 'sec1@vip.example', venue_a, '{"name":"Zed Zebra","email":"z@example.com"}'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s manager', tests.add(mgr_b, 'mgrb@vip.example', venue_a, '{"name":"Zed Zebra","email":"z@example.com"}'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor an organizer''s owner', tests.add(org_u, 'org@vip.example', venue_a, '{"name":"Zed Zebra","email":"z@example.com"}'), 'ERROR: not allowed');
  perform tests.assert_eq('a name is needed', tests.add(mgr_a, 'mgra@vip.example', venue_a, '{"email":"z@example.com"}'), 'ERROR: enter the guest''s name');
  perform tests.assert_eq('a way to reach them is needed', tests.add(mgr_a, 'mgra@vip.example', venue_a, '{"name":"Zed Zebra"}'), 'ERROR: enter an email or a phone number');
  perform tests.assert_eq('...a real email', tests.add(mgr_a, 'mgra@vip.example', venue_a, '{"name":"Zed Zebra","email":"not-an-email"}'), 'ERROR: that does not look like an email address');
  perform tests.assert_eq('...a real phone', tests.add(mgr_a, 'mgra@vip.example', venue_a, '{"name":"Zed Zebra","phone":"123"}'), 'ERROR: that phone number is too short');
  perform tests.assert_eq('an end date before the start', tests.add(mgr_a, 'mgra@vip.example', venue_a, jsonb_build_object('name', 'Zed Zebra', 'email', 'z@example.com', 'valid_from', to_char(current_date + 5, 'YYYY-MM-DD'), 'valid_until', to_char(current_date + 1, 'YYYY-MM-DD'))), 'ERROR: the end date is before the start date');
  perform tests.assert_eq('a date that is not a date', tests.add(mgr_a, 'mgra@vip.example', venue_a, '{"name":"Zed Zebra","email":"z@example.com","valid_until":"tomorrow"}'), 'ERROR: end date must be a date (YYYY-MM-DD)');
  perform tests.assert_eq('...or not a real one', tests.add(mgr_a, 'mgra@vip.example', venue_a, '{"name":"Zed Zebra","email":"z@example.com","valid_until":"2026-02-31"}'), 'ERROR: end date must be a real date');
  perform tests.assert_eq('a field that does not exist', tests.add(mgr_a, 'mgra@vip.example', venue_a, '{"name":"Zed Zebra","email":"z@example.com","vip_level":9}'), 'ERROR: unknown field: vip_level');
  perform tests.assert_eq('a host has to work at the club', tests.add(mgr_a, 'mgra@vip.example', venue_a, jsonb_build_object('name', 'Zed Zebra', 'email', 'z@example.com', 'host', mgr_b)), 'ERROR: the host has to be someone who works at this club');
  perform tests.assert_eq('...and has to be a real id', tests.add(mgr_a, 'mgra@vip.example', venue_a, '{"name":"Zed Zebra","email":"z@example.com","host":"nobody"}'), 'ERROR: the host has to be someone who works at this club');
  perform tests.assert_eq('long notes are refused', tests.add(mgr_a, 'mgra@vip.example', venue_a, jsonb_build_object('name', 'Zed Zebra', 'email', 'z@example.com', 'notes', repeat('x', 501))), 'ERROR: notes must be 500 characters or fewer');

  ---------------------------------------------------------------- perks
  p_entry := tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_add_perk(%L, 'entry', 'Priority entry', 1, 'night')::text$q$, ada))::uuid;
  p_serv := tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_add_perk(%L, 'service', 'Welcome shot', 1, 'night')::text$q$, ada))::uuid;
  p_disc := tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_add_perk(%L, 'discount', '10 percent off bottles', 3, 'total')::text$q$, ada))::uuid;
  perform tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_add_perk(%L, 'service', 'Reserved booth when available')::text$q$, ada));
  perform tests.assert_eq('a perk of an unknown kind', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_add_perk(%L, 'free', 'Anything')::text$q$, ada)), 'ERROR: choose entry, service or discount');
  perform tests.assert_eq('...needs a name', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_add_perk(%L, 'service', ' ')::text$q$, ada)), 'ERROR: say what the perk is');
  perform tests.assert_eq('...a sane limit', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_add_perk(%L, 'service', 'Welcome', 0)::text$q$, ada)), 'ERROR: the limit has to be from 1 to 1000, or none');
  perform tests.assert_eq('...and a period', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_add_perk(%L, 'service', 'Welcome', 1, 'yearly')::text$q$, ada)), 'ERROR: choose per night or in total');
  perform tests.assert_eq('a server cannot add a perk', tests.run_as(srv_1, 'srv1@vip.example', format($q$select public.vip_add_perk(%L, 'service', 'Free drinks')::text$q$, ada)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s manager', tests.run_as(mgr_b, 'mgrb@vip.example', format($q$select public.vip_add_perk(%L, 'service', 'Free drinks')::text$q$, ada)), 'ERROR: not allowed');

  ---------------------------------------------------------------- who sees what
  perform tests.assert_eq('the manager sees everything about a guest', tests.lookup(mgr_a, 'mgra@vip.example', venue_a, 'ada'),
    'Ada Lovelace/Gold/active/Mia Manager/still water, no ice/ada@example.com/allergic to nuts; likes booth 4/10 percent off bottles+Priority entry+Reserved booth when available+Welcome shot');
  perform tests.assert_eq('a server sees service perks and preferences only: no email, no notes, no entry or discount perks', tests.lookup(srv_1, 'srv1@vip.example', venue_a, 'ada'),
    'Ada Lovelace/Gold/active/Mia Manager/still water, no ice/-/-/Reserved booth when available+Welcome shot');
  perform tests.assert_eq('the door sees entry perks only: no preferences, no email, no notes', tests.lookup(door_a, 'doora@vip.example', venue_a, 'ada'),
    'Ada Lovelace/Gold/active/Mia Manager/-/-/-/Priority entry');
  perform tests.assert_eq('the credential code finds a guest', tests.run_as(door_a, 'doora@vip.example', format($q$select count(*)::text from public.vip_lookup(%L, (select credential_code from public.site_vip_members where id = %L))$q$, venue_a, ada)), 'ERROR: permission denied for table site_vip_members');
  perform tests.logout();
  perform tests.assert_eq('by credential code, even lower-case', tests.lookup(door_a, 'doora@vip.example', venue_a, lower((select credential_code from public.site_vip_members where id = ada))), 'Ada Lovelace/Gold/active/Mia Manager/-/-/-/Priority entry');
  perform tests.assert_eq('a search needs 3 letters', tests.lookup(srv_1, 'srv1@vip.example', venue_a, 'ad'), 'ERROR: type at least 3 letters of the name, or the credential code');
  perform tests.assert_eq('...and finds nothing for a stranger', tests.lookup(srv_1, 'srv1@vip.example', venue_a, 'zzz'), '(none)');
  perform tests.assert_eq('security sees no VIP', tests.lookup(sec_1, 'sec1@vip.example', venue_a, 'ada'), 'ERROR: not allowed');
  perform tests.assert_eq('event-only door staff see no VIP', tests.lookup(ev_door, 'evdoor@vip.example', venue_a, 'ada'), 'ERROR: not allowed');
  perform tests.assert_eq('an organizer sees no VIP', tests.lookup(org_u, 'org@vip.example', venue_a, 'ada'), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager sees no VIP', tests.lookup(mgr_b, 'mgrb@vip.example', venue_a, 'ada'), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger sees no VIP', tests.lookup(rando, 'rando@vip.example', venue_a, 'ada'), 'ERROR: not allowed');
  perform tests.assert_eq('the list is the manager''s only: a server cannot list it', tests.run_as(srv_1, 'srv1@vip.example', format($q$select count(*)::text from public.vip_list(%L)$q$, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor read a guest''s full profile', tests.run_as(srv_1, 'srv1@vip.example', format($q$select public.vip_detail(%L)::text$q$, ada)), 'ERROR: not allowed');

  ---------------------------------------------------------------- redeeming
  perform tests.assert_eq('the door redeems an entry perk', tests.run_as(door_a, 'doora@vip.example', format($q$select (public.vip_redeem(%L, null, 'at the front')) ->> 'uses_left'$q$, p_entry)), '0');
  perform tests.assert_eq('a perk with a limit of one per night cannot be used twice tonight', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_redeem(%L)::text$q$, p_entry)), 'ERROR: this benefit has already been used 1 of 1 tonight');
  perform tests.assert_eq('...but tomorrow night it works again', tests.run_as(door_a, 'doora@vip.example', format($q$select (public.vip_redeem(%L, current_date + 1)) ->> 'used'$q$, p_entry)), '1');
  perform tests.assert_eq('the door cannot redeem a service perk', tests.run_as(door_a, 'doora@vip.example', format($q$select public.vip_redeem(%L)::text$q$, p_serv)), 'ERROR: not allowed');
  perform tests.assert_eq('a server redeems a service perk', tests.run_as(srv_1, 'srv1@vip.example', format($q$select (public.vip_redeem(%L)) ->> 'used'$q$, p_serv)), '1');
  perform tests.assert_eq('...and not an entry perk', tests.run_as(srv_1, 'srv1@vip.example', format($q$select public.vip_redeem(%L)::text$q$, p_entry)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a discount', tests.run_as(srv_1, 'srv1@vip.example', format($q$select public.vip_redeem(%L)::text$q$, p_disc)), 'ERROR: not allowed');
  perform tests.assert_eq('a manager redeems a discount; a limit in total counts every night', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select (public.vip_redeem(%L)) ->> 'uses_left'$q$, p_disc)), '2');
  perform tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_redeem(%L, current_date + 1)::text$q$, p_disc));
  perform tests.run_as(owner_u, 'owner@vip.example', format($q$select public.vip_redeem(%L, current_date + 2)::text$q$, p_disc));
  perform tests.assert_eq('...up to its limit and no further', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_redeem(%L)::text$q$, p_disc)), 'ERROR: this benefit has already been used 3 of 3 in total');
  perform tests.assert_eq('a perk with no limit can be redeemed again and again', tests.run_as(srv_1, 'srv1@vip.example', format($q$select (public.vip_redeem(%L)) ->> 'used'$q$, tests.perk_id(ada, 'Reserved booth when available')))
    || ',' || tests.run_as(srv_1, 'srv1@vip.example', format($q$select (public.vip_redeem(%L)) ->> 'used'$q$, tests.perk_id(ada, 'Reserved booth when available'))), '1,2');
  perform tests.assert_eq('another club''s staff cannot redeem', tests.run_as(mgr_b, 'mgrb@vip.example', format($q$select public.vip_redeem(%L)::text$q$, p_serv)), 'ERROR: not allowed');
  perform tests.assert_eq('a night that is not current', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_redeem(%L, current_date + 40)::text$q$, p_serv)), 'ERROR: that is not a current night');
  perform tests.assert_eq('a long note', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_redeem(%L, current_date + 2, %L)::text$q$, p_serv, repeat('x', 201))), 'ERROR: keep the note to 200 characters or fewer');
  perform tests.assert_eq('what was used tonight shows on the lookup', tests.run_as(srv_1, 'srv1@vip.example', format($q$select (select (p ->> 'used') from jsonb_array_elements(perks) p where p ->> 'label' = 'Welcome shot') from public.vip_lookup(%L, 'ada')$q$, venue_a)), '1');

  ---------------------------------------------------------------- the manager's list and the profile
  perform tests.assert_eq('the list shows the active guests with hosts and perks', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select string_agg(name || ':' || status || ':' || coalesce(host_name, '-') || ':' || perks || ':' || coalesce(last_visit::text, '-'), ' | ' order by name) from public.vip_list(%L)$q$, venue_a)),
    'Ada Lovelace:active:Mia Manager:4:' || (current_date + 2) || ' | Bob Barlow:active:-:0:-');
  perform tests.assert_eq('a search narrows it', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select count(*)::text from public.vip_list(%L, 'bob')$q$, venue_a)), '1');
  perform tests.assert_eq('the profile has the visit history: perk, night and who', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select (d -> 'visits' -> 0 ->> 'by_name') || '/' || jsonb_array_length(d -> 'visits') from (select public.vip_detail(%L) d) x$q$, ada)), 'Sam Server/8');
  perform tests.assert_eq('...and the perks with their use tonight', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select (select (p ->> 'used') from jsonb_array_elements(d -> 'perks') p where p ->> 'label' = 'Priority entry') from (select public.vip_detail(%L) d) x$q$, ada)), '1');
  perform tests.assert_eq('another club''s manager cannot read the profile', tests.run_as(mgr_b, 'mgrb@vip.example', format($q$select public.vip_detail(%L)::text$q$, ada)), 'ERROR: not allowed');

  ---------------------------------------------------------------- changing and ending
  perform tests.assert_eq('a manager changes the tier and clears the host', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_update(%L, '{"tier":"Platinum","host":null}')::text$q$, ada)), '');
  perform tests.assert_eq('...it took', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select (d ->> 'tier') || '/' || coalesce(d ->> 'host_name', 'none') || '/' || (d ->> 'email') from (select public.vip_detail(%L) d) x$q$, ada)), 'Platinum/none/ada@example.com');
  perform tests.assert_eq('what is not mentioned is left alone', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select d ->> 'preferences' from (select public.vip_detail(%L) d) x$q$, ada)), 'still water, no ice');
  perform tests.assert_eq('a guest cannot be left with no way to reach them', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_update(%L, '{"email":null}')::text$q$, ada)), 'ERROR: enter an email or a phone number');
  perform tests.assert_eq('a server cannot change a guest', tests.run_as(srv_1, 'srv1@vip.example', format($q$select public.vip_update(%L, '{"tier":"Diamond"}')::text$q$, ada)), 'ERROR: not allowed');
  perform tests.assert_eq('a perk is ended, not deleted', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_end_perk(%L)::text$q$, p_serv)), '');
  perform tests.assert_eq('...an ended perk redeems nothing', tests.run_as(srv_1, 'srv1@vip.example', format($q$select public.vip_redeem(%L, current_date + 1)::text$q$, p_serv)), 'ERROR: this perk has ended');
  perform tests.assert_eq('...and is not offered at the club', tests.lookup(srv_1, 'srv1@vip.example', venue_a, 'ada') like '%Welcome shot%', false);
  perform tests.assert_eq('it cannot be ended twice', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_end_perk(%L)::text$q$, p_serv)), 'ERROR: this perk has already ended');
  perform tests.assert_eq('ending a membership needs a reason', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_end(%L, ' ')::text$q$, bob)), 'ERROR: say why the membership is ending');
  perform tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_add_perk(%L, 'entry', 'Fast lane')::text$q$, bob));
  perform tests.assert_eq('a manager ends it', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_end(%L, 'asked to leave')::text$q$, bob)), '');
  perform tests.assert_eq('...an ended membership shows as ended and offers no perks', tests.lookup(door_a, 'doora@vip.example', venue_a, 'bob'), 'Bob Barlow/VIP/ended/-/-/-/-');
  perform tests.assert_eq('...and redeems nothing', tests.run_as(door_a, 'doora@vip.example', format($q$select public.vip_redeem(%L)::text$q$, tests.perk_id(bob, 'Fast lane'))), 'ERROR: this membership is not active (ended)');
  perform tests.assert_eq('...it is hidden from the list unless asked for', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select count(*)::text from public.vip_list(%L, 'bob')$q$, venue_a)) || ' ' || tests.run_as(mgr_a, 'mgra@vip.example', format($q$select count(*)::text from public.vip_list(%L, 'bob', true)$q$, venue_a)), '0 1');
  perform tests.assert_eq('it cannot be ended twice', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_end(%L, 'again')::text$q$, bob)), 'ERROR: this membership has already ended');
  perform tests.assert_eq('it can be reinstated', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_reinstate(%L)::text$q$, bob)) || ' ' || tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_reinstate(%L)::text$q$, bob)), ' ERROR: this membership has not ended');

  ---------------------------------------------------------------- expiry and not-yet-started
  perform tests.logout();
  insert into public.site_vip_members (venue_id, name, email, tier, valid_from, valid_until, credential_code, created_by)
    values (venue_a, 'Cleo Past', 'cleo@example.com', 'Silver', current_date - 30, current_date - 1, 'EXPIRED1', mgr_a) returning id into cleo;
  insert into public.site_vip_perks (member_id, kind, label, created_by) values (cleo, 'entry', 'Old pass', mgr_a);
  insert into public.site_vip_members (venue_id, name, email, tier, valid_from, credential_code, created_by) values (venue_a, 'Dan Future', 'dan@example.com', 'Gold', current_date + 10, 'FUTURE01', mgr_a);
  perform tests.assert_eq('an expired membership says so and has no usable perks', tests.lookup(door_a, 'doora@vip.example', venue_a, 'cleo'), 'Cleo Past/Silver/expired/-/-/-/-');
  perform tests.assert_eq('...and one that has not started yet says so', tests.lookup(door_a, 'doora@vip.example', venue_a, 'dan'), 'Dan Future/Gold/upcoming/-/-/-/-');
  perform tests.assert_eq('an expired member redeems nothing', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_redeem(%L)::text$q$, tests.perk_id(cleo, 'Old pass'))), 'ERROR: this membership is not active (expired)');
  perform tests.assert_eq('but was valid last night', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select (public.vip_redeem(%L, current_date - 1)) ->> 'used'$q$, tests.perk_id(cleo, 'Old pass'))), '1');

  ---------------------------------------------------------------- the invitation is only queued
  perform tests.assert_eq('a manager invites a guest: queued', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select (public.vip_invite(%L)) ->> 'queued'$q$, ada)), 'true');
  perform tests.logout();
  perform tests.assert_eq('...one message is waiting, queued and not sent, with the code', (select count(*) from public.site_outbox where kind = 'vip_invite' and ref_id = ada and status = 'queued' and payload ? 'credential_code')::int, 1);
  perform tests.assert_eq('a second invitation straight away is refused', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_invite(%L)::text$q$, ada)), 'ERROR: an invitation was queued a moment ago');
  perform tests.assert_eq('a guest with no email cannot be invited', tests.run_as(mgr_a, 'mgra@vip.example', format($q$select public.vip_invite(%L)::text$q$, (select id from public.site_vip_members where name = 'Bob Barlow'))), 'ERROR: this guest has no email address to invite');
  perform tests.assert_eq('a server cannot invite', tests.run_as(srv_1, 'srv1@vip.example', format($q$select public.vip_invite(%L)::text$q$, ada)), 'ERROR: not allowed');

  ---------------------------------------------------------------- the log and the doors
  perform tests.logout();
  perform tests.assert_true('every step is attributed in the audit log', (select count(*) from public.audit_log where action like 'vip.%' and actor_id is not null) >= 20);
  insert into public.site_vip_members (venue_id, name, email, credential_code, created_by) select venue_a, 'Lookup Person ' || g, 'l' || g || '@example.com', 'LOOKUP' || lpad(g::text, 2, '0'), mgr_a from generate_series(1, 12) g;
  perform tests.assert_eq('a search shows at most ten guests', tests.run_as(srv_1, 'srv1@vip.example', format($q$select count(*)::text from public.vip_lookup(%L, 'lookup')$q$, venue_a)), '10');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot look anyone up', format($q$select * from public.vip_lookup(%L, 'ada')$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...or redeem', format('select public.vip_redeem(%L)', p_entry), 'permission denied');
  perform tests.logout();
  perform tests.login(srv_1, 'srv1@vip.example');
  perform tests.assert_raises('the tables cannot be read directly', 'select * from public.site_vip_members', 'permission denied');
  perform tests.assert_raises('...nor the perks', 'select * from public.site_vip_perks', 'permission denied');
  perform tests.assert_raises('...nor the redemptions', 'select * from public.site_vip_redemptions', 'permission denied');
  perform tests.assert_raises('the internal helpers cannot be called', 'select public.vip_new_code()', 'permission denied');
  perform tests.logout();
end $$;

rollback;
