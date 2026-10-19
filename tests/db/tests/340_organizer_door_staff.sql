-- Organizer-provided door staff (20261020130000_organizer_door_staff.sql). What matters: an organizer can invite door staff for an event only when it has no
-- club or the club's approved agreement allows it; the club (and only that club) turns the permission on and off; turning it off cancels the invitations still
-- waiting but not people already in; the club sees the organizers' door staff at its events and can take their access away; other clubs, other organizers and
-- strangers can do none of it; and every other kind of invitation works exactly as before.
begin;

create function tests.try_invite(p_user uuid, p_email text, p_org uuid, p_to text, p_role text, p_venue uuid, p_event uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return (select i.token from public.invite_member(p_org, p_to, p_role, p_venue, p_event) i);
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.status_text(p_user uuid, p_email text, p_org uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(event_title || ':' || state || ':' || coalesce(club_name, '-'), ' | ' order by event_title) from public.organizer_event_door_status(p_org)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
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

do $$
declare
  vowner constant uuid := '00000000-0000-0000-0000-0000000005d1';
  vmgr constant uuid := '00000000-0000-0000-0000-0000000005d2';
  vmgr_b constant uuid := '00000000-0000-0000-0000-0000000005d3';
  org_u constant uuid := '00000000-0000-0000-0000-0000000005d4';
  org2_u constant uuid := '00000000-0000-0000-0000-0000000005d5';
  door1 constant uuid := '00000000-0000-0000-0000-0000000005d6';
  door2 constant uuid := '00000000-0000-0000-0000-0000000005d8';
  rando constant uuid := '00000000-0000-0000-0000-0000000005d7';
  vorg uuid; org uuid; org2 uuid; venue uuid; venue_b uuid; e_other_club uuid; e_own uuid; e_club uuid; e_wait uuid; e_old uuid; ag_club uuid; ag_wait uuid; ag_old uuid;
  tok text; r text; m_door uuid; inv uuid; n int;
begin
  insert into auth.users (id, email) values (vowner, 'vowner@dr.example'), (vmgr, 'vmgr@dr.example'), (vmgr_b, 'vmgrb@dr.example'), (org_u, 'org@dr.example'),
    (org2_u, 'org2@dr.example'), (door1, 'door1@dr.example'), (door2, 'door2@dr.example'), (rando, 'rando@dr.example');
  insert into public.profiles (id, name, email) values (door1, 'Dan Door', 'door1@dr.example');
  perform tests.login(vowner, 'vowner@dr.example');
  vorg := public.create_organization('Club Co', 'venue_owner');
  venue := public.create_org_venue(vorg, 'Club A');
  venue_b := public.create_org_venue(vorg, 'Club B');
  select i.token into tok from public.invite_member(vorg, 'vmgr@dr.example', 'manager', venue) i;
  perform tests.login(vmgr, 'vmgr@dr.example'); perform public.accept_invitation(tok);
  perform tests.login(vowner, 'vowner@dr.example');
  select i.token into tok from public.invite_member(vorg, 'vmgrb@dr.example', 'manager', venue_b) i;
  perform tests.login(vmgr_b, 'vmgrb@dr.example'); perform public.accept_invitation(tok);
  perform tests.login(org_u, 'org@dr.example');
  org := public.create_organization('Night Events', 'organizer');
  perform tests.login(org2_u, 'org2@dr.example');
  org2 := public.create_organization('Other Events', 'organizer');
  perform tests.logout();

  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Own event', 'd', 'tbc', now() + interval '9 days', now() + interval '10 days', 'draft', org) returning id into e_own;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Club event', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_club;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Waiting event', 'd', 'tbc', now() + interval '11 days', now() + interval '12 days', 'draft', org) returning id into e_wait;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Old event', 'd', 'tbc', now() + interval '12 days', now() + interval '13 days', 'draft', org) returning id into e_old;
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, current_version, active_version) values (e_club, venue, org, 'active', org_u, 1, 1) returning id into ag_club;
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by) values (e_wait, venue, org, 'requested', org_u) returning id into ag_wait;
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, closed_by, closed_at, closed_reason) values (e_old, venue, org, 'declined', org_u, vowner, now(), 'no') returning id into ag_old;

  ---------------------------------------------------------------- the rule
  r := tests.try_invite(org_u, 'org@dr.example', org, 'door1@dr.example', 'door', null, e_own);
  perform tests.assert_true('an organizer invites door staff for an event that has no club: as before', r not like 'ERROR%');
  r := tests.try_invite(org_u, 'org@dr.example', org, 'door1@dr.example', 'door', null, e_club);
  perform tests.assert_eq('...but not for an event whose approved club agreement does not allow it', r, 'ERROR: the club has not allowed door staff for this event');
  r := tests.try_invite(org_u, 'org@dr.example', org, 'door1@dr.example', 'door', null, e_wait);
  perform tests.assert_eq('...nor while the club has not yet agreed the terms', r, 'ERROR: the club has not allowed door staff for this event');
  r := tests.try_invite(org_u, 'org@dr.example', org, 'door1@dr.example', 'door', null, e_old);
  perform tests.assert_true('an event whose only agreement was declined has no club connection, so it is the organizer''s own again', r not like 'ERROR%');
  r := tests.try_invite(org2_u, 'org2@dr.example', org2, 'door1@dr.example', 'door', null, e_own);
  perform tests.assert_eq('another business cannot invite for this business''s event', r, 'ERROR: not allowed');
  perform tests.assert_eq('the status says so, per event', tests.status_text(org_u, 'org@dr.example', org),
    'Club event:not_allowed:Club A | Old event:own_event:- | Own event:own_event:- | Waiting event:awaiting_approval:Club A');

  ---------------------------------------------------------------- the club's permission
  perform tests.assert_eq('the organizer cannot grant themselves the permission', tests.run_as(org_u, 'org@dr.example', format($q$select public.set_organizer_door_staff(%L, true)$q$, ag_club)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.run_as(vmgr_b, 'vmgrb@dr.example', format($q$select public.set_organizer_door_staff(%L, true)$q$, ag_club)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.run_as(rando, 'rando@dr.example', format($q$select public.set_organizer_door_staff(%L, true)$q$, ag_club)), 'ERROR: not allowed');
  perform tests.assert_eq('a missing answer is refused', tests.run_as(vmgr, 'vmgr@dr.example', format($q$select public.set_organizer_door_staff(%L, null)$q$, ag_club)), 'ERROR: choose yes or no');
  perform tests.assert_eq('an agreement that has ended cannot be changed', tests.run_as(vmgr, 'vmgr@dr.example', format($q$select public.set_organizer_door_staff(%L, true)$q$, ag_old)), 'ERROR: this agreement has ended');
  perform tests.logout();
  perform tests.assert_eq('nothing changed by any of those', (select count(*)::int from public.site_agreements where organizer_door_staff), 0);
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call it', format($q$select public.set_organizer_door_staff(%L, true)$q$, ag_club), 'permission denied');

  perform tests.assert_eq('the club''s manager allows it', tests.run_as(vmgr, 'vmgr@dr.example', format($q$select public.set_organizer_door_staff(%L, true)$q$, ag_club)), 'true');
  perform tests.assert_eq('...and the organizer''s status follows', tests.status_text(org_u, 'org@dr.example', org), 'Club event:allowed:Club A | Old event:own_event:- | Own event:own_event:- | Waiting event:awaiting_approval:Club A');
  r := tests.try_invite(org_u, 'org@dr.example', org, 'door1@dr.example', 'door', null, e_club);
  perform tests.assert_true('now the organizer can invite door staff for that event', r not like 'ERROR%');
  tok := r;
  perform tests.login(door1, 'door1@dr.example');
  perform public.accept_invitation(tok);
  perform tests.logout();
  select m.id into m_door from public.site_memberships m where m.user_id = door1 and m.event_id = e_club and m.role = 'door';
  perform tests.assert_true('the person accepts and is door staff for that event only', m_door is not null and (select venue_id is null from public.site_memberships where id = m_door));
  r := tests.try_invite(org_u, 'org@dr.example', org, 'second@dr.example', 'door', null, e_club);
  perform tests.assert_true('a second invitation waits', r not like 'ERROR%');
  perform tests.logout();
  update public.site_agreements set organizer_door_staff = true where id = ag_wait;
  r := tests.try_invite(org_u, 'org@dr.example', org, 'third@dr.example', 'door', null, e_wait);
  perform tests.assert_eq('a permission switched on for an agreement that is not approved yet changes nothing', r, 'ERROR: the club has not allowed door staff for this event');
  update public.site_agreements set organizer_door_staff = false where id = ag_wait;

  ---------------------------------------------------------------- the club sees them and can take access away
  perform tests.logout();
  -- things that must NOT show in the club's view: another role at the same event, another club's agreement, and an invitation that has expired
  insert into public.site_memberships (org_id, user_id, role, event_id) values (org, rando, 'security', e_club);
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('At the other club', 'd', 'tbc', now() + interval '14 days', now() + interval '15 days', 'draft', org) returning id into e_other_club;
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, current_version, active_version, organizer_door_staff) values (e_other_club, venue_b, org, 'active', org_u, 1, 1, true);
  insert into public.site_invitations (org_id, email, role, event_id, token_hash, expires_at, invited_by) values (org, 'stale@dr.example', 'door', e_club, sha256('x'::bytea), now() - interval '1 day', org_u);
  perform tests.login(vmgr, 'vmgr@dr.example');
  perform tests.assert_eq('the club lists each live agreement with its permission', (select string_agg(event_title || ':' || approved || ':' || door_staff_allowed, ' | ' order by event_title) from public.venue_door_permissions(venue)), 'Club event:true:true | Waiting event:false:false');
  perform tests.assert_eq('...the declined one is not listed', (select count(*)::int from public.venue_door_permissions(venue) where event_title = 'Old event'), 0);
  perform tests.assert_eq('the club sees the organizer''s door staff and the invitation still waiting',
    (select string_agg(person || ':' || state || ':' || organizer_name, ' | ' order by person) from public.venue_event_door_staff(venue)), 'Dan Door:active:Night Events | second@dr.example:invited:Night Events | stale@dr.example:invitation_expired:Night Events');
  perform tests.assert_true('...and not the security person at the same event', (select count(*) from public.venue_event_door_staff(venue) where person like '%rando%') = 0);
  perform tests.assert_true('...and the agreement at the other club is not in this club''s permissions', (select count(*) from public.venue_door_permissions(venue) where event_title = 'At the other club') = 0);
  perform tests.assert_true('...and not the own-event invitation that has no club', (select count(*) from public.venue_event_door_staff(venue) where event_title = 'Own event') = 0);
  perform tests.login(vmgr_b, 'vmgrb@dr.example');
  perform tests.assert_raises('another club cannot list them', format($q$select * from public.venue_event_door_staff(%L)$q$, venue), 'not allowed');
  perform tests.assert_raises('...nor the permissions', format($q$select * from public.venue_door_permissions(%L)$q$, venue), 'not allowed');
  perform tests.assert_eq('...and sees none of its own (it hosts no such event)', (select count(*)::int from public.venue_event_door_staff(venue_b)), 0);
  perform tests.login(org_u, 'org@dr.example');
  perform tests.assert_raises('the organizer cannot list the club''s view', format($q$select * from public.venue_event_door_staff(%L)$q$, venue), 'not allowed');
  perform tests.login(rando, 'rando@dr.example');
  perform tests.assert_raises('a stranger cannot', format($q$select * from public.venue_event_door_staff(%L)$q$, venue), 'not allowed');

  perform tests.assert_eq('another club cannot take their access away', tests.run_as(vmgr_b, 'vmgrb@dr.example', format($q$select public.revoke_event_door_access(%L, null)$q$, m_door)), 'ERROR: not allowed');
  perform tests.assert_eq('the organizer is not the club (they use revoke_membership for their own people)', tests.run_as(org_u, 'org@dr.example', format($q$select public.revoke_event_door_access(%L, null)$q$, m_door)), 'ERROR: not allowed');
  perform tests.assert_eq('a person and an invitation together are refused', tests.run_as(vmgr, 'vmgr@dr.example', format($q$select public.revoke_event_door_access(%L, %L)$q$, m_door, gen_random_uuid())), 'ERROR: choose one person or one invitation');
  perform tests.assert_eq('neither is refused', tests.run_as(vmgr, 'vmgr@dr.example', 'select public.revoke_event_door_access(null, null)'), 'ERROR: choose one person or one invitation');
  perform tests.assert_eq('a person who does not exist is "not allowed"', tests.run_as(vmgr, 'vmgr@dr.example', 'select public.revoke_event_door_access(gen_random_uuid(), null)'), 'ERROR: not allowed');
  perform tests.assert_eq('the club takes the door staff member''s access away', tests.run_as(vmgr, 'vmgr@dr.example', format($q$select public.revoke_event_door_access(%L, null)$q$, m_door)), '');
  perform tests.logout();
  perform tests.assert_eq('...it is revoked, with who did it', (select status || ':' || (revoked_by = vmgr)::text from public.site_memberships where id = m_door), 'revoked:true');
  perform tests.assert_eq('...and recorded', (select count(*)::int from public.audit_log where action = 'event_door_staff.revoked_by_club'), 1);
  perform tests.assert_eq('revoking again finds nothing to revoke', tests.run_as(vmgr, 'vmgr@dr.example', format($q$select public.revoke_event_door_access(%L, null)$q$, m_door)), 'ERROR: not allowed');

  ---------------------------------------------------------------- turning it off
  select i.id into inv from public.site_invitations i where i.event_id = e_club and i.email = 'second@dr.example';
  perform tests.assert_eq('the club takes a waiting invitation back', tests.run_as(vmgr, 'vmgr@dr.example', format($q$select public.revoke_event_door_access(null, %L)$q$, inv)), '');
  perform tests.logout();
  perform tests.assert_eq('...the invitation is revoked', (select status from public.site_invitations where id = inv), 'revoked');
  r := tests.try_invite(org_u, 'org@dr.example', org, 'door2@dr.example', 'door', null, e_club);
  perform tests.assert_true('the organizer invites two more; one accepts', r not like 'ERROR%');
  perform tests.login(door2, 'door2@dr.example'); perform public.accept_invitation(r);
  r := tests.try_invite(org_u, 'org@dr.example', org, 'waiting@dr.example', 'door', null, e_club);
  perform tests.assert_true('...and one is still waiting', r not like 'ERROR%');
  perform tests.assert_eq('the club turns the permission off', tests.run_as(vmgr, 'vmgr@dr.example', format($q$select public.set_organizer_door_staff(%L, false)$q$, ag_club)), 'false');
  perform tests.logout();
  perform tests.assert_eq('...the invitation still waiting is cancelled', (select count(*)::int from public.site_invitations where event_id = e_club and role = 'door' and status = 'pending'), 0);
  perform tests.assert_eq('...the person already in keeps their access (the club removes people one by one)', (select count(*)::int from public.site_memberships where event_id = e_club and role = 'door' and status = 'active'), 1);
  r := tests.try_invite(org_u, 'org@dr.example', org, 'late@dr.example', 'door', null, e_club);
  perform tests.assert_eq('...and nobody new can be invited', r, 'ERROR: the club has not allowed door staff for this event');
  perform tests.assert_eq('the organizer''s status says not allowed again', tests.status_text(org_u, 'org@dr.example', org), 'At the other club:allowed:Club B | Club event:not_allowed:Club A | Old event:own_event:- | Own event:own_event:- | Waiting event:awaiting_approval:Club A');
  perform tests.assert_eq('turning it off again changes nothing and is not recorded twice', tests.run_as(vmgr, 'vmgr@dr.example', format($q$select public.set_organizer_door_staff(%L, false)$q$, ag_club)), 'false');
  perform tests.logout();
  perform tests.assert_eq('the changes are recorded (on, then off)', (select count(*)::int from public.audit_log where action = 'agreement.door_staff_set'), 2);
  perform tests.assert_eq('...with how many waiting invitations the switch cancelled (the one waiting and the one whose link had expired)', (select (details ->> 'pending_invitations_cancelled')::int from public.audit_log where action = 'agreement.door_staff_set' and details ->> 'allowed' = 'false'), 2);

  ---------------------------------------------------------------- everything else is as before
  r := tests.try_invite(vmgr, 'vmgr@dr.example', vorg, 'srv@dr.example', 'server', venue, null);
  perform tests.assert_true('a club manager still invites a server to the club', r not like 'ERROR%');
  r := tests.try_invite(vowner, 'vowner@dr.example', vorg, 'mgr2@dr.example', 'manager', venue_b, null);
  perform tests.assert_true('an owner still appoints a manager', r not like 'ERROR%');
  r := tests.try_invite(org_u, 'org@dr.example', org, 'sec@dr.example', 'security', null, e_own);
  perform tests.assert_eq('an organizer still cannot invite anything but door staff to an event', r, 'ERROR: not allowed');
  perform tests.login(org_u, 'org@dr.example');
  perform tests.assert_raises('nobody can call the rule itself', format($q$select public.event_door_allowed(%L)$q$, e_club), 'permission denied');

  ---------------------------------------------------------------- who may ask, and how the functions are declared
  perform tests.assert_raises('another organizer cannot read this business''s status', format($q$select * from public.organizer_event_door_status(%L)$q$, org), 'not allowed') where tests.login(org2_u, 'org2@dr.example') is not null;
  perform tests.login(vowner, 'vowner@dr.example');
  perform tests.assert_raises('a venue owner is not an organizer', format($q$select * from public.organizer_event_door_status(%L)$q$, org), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the status', format($q$select * from public.organizer_event_door_status(%L)$q$, org), 'permission denied');
  perform tests.logout();
  perform tests.assert_true('every function runs with its owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('event_door_allowed', 'invite_member', 'organizer_event_door_status', 'venue_door_permissions', 'set_organizer_door_staff', 'venue_event_door_staff', 'revoke_event_door_access')));
end $$;

rollback;
