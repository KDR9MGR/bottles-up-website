-- Changing a person's role. What matters most: it is the same rule as inviting and removing (a manager changes staff of their own club,
-- only the owner touches a manager, nobody changes their own role or an owner's or an event's); the old access ends at once and the new
-- one starts at once with the same club, shift and window; and it is one step in the log.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid, p_shift uuid default null) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue, null, p_shift) i;
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
create function tests.change(p_user uuid, p_email text, p_membership uuid, p_role text) returns text language plpgsql as $$
declare id uuid;
begin
  perform tests.login(p_user, p_email);
  id := public.change_member_role(p_membership, p_role);
  return 'ok';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.mid(p_user uuid, p_role text) returns uuid language sql security definer as $$
  select id from public.site_memberships where user_id = p_user and role = p_role and status = 'active' limit 1 $$;
create function tests.roles_of(p_user uuid) returns text language sql security definer as $$
  select coalesce(string_agg(role || ':' || status, ' ' order by role), '(none)') from public.site_memberships where user_id = p_user $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000008d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000008d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000008d3';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000008d4';
  door_e constant uuid := '00000000-0000-0000-0000-0000000008d5';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000008d6';
  org_u constant uuid := '00000000-0000-0000-0000-0000000008d7';
  rando constant uuid := '00000000-0000-0000-0000-0000000008d8';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; ev uuid; shift_a uuid; m_srv uuid; m_srv2 uuid; m_mgr uuid; m_door uuid; m_new uuid;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@role.example'), (mgr_a, 'mgra@role.example'), (srv_1, 'srv1@role.example'), (srv_2, 'srv2@role.example'),
    (door_e, 'doore@role.example'), (mgr_b, 'mgrb@role.example'), (org_u, 'org@role.example'), (rando, 'rando@role.example');

  perform tests.login(owner_u, 'owner@role.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  shift_a := public.create_shift(venue_a, 'Friday night', now() - interval '1 hour', now() + interval '8 hours');
  perform tests.join_as(owner_u, 'owner@role.example', org, 'mgra@role.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@role.example', org, 'mgrb@role.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@role.example', org, 'srv1@role.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@role.example', org, 'srv2@role.example', 'server', venue_a, srv_2, shift_a);
  perform tests.login(org_u, 'org@role.example');
  org2 := public.create_organization('Night Events', 'organizer');
  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Night One', 'x', 'Somewhere', now() + interval '2 days', now() + interval '2 days 6 hours', 'draft', org2) returning id into ev;
  insert into public.site_memberships (org_id, user_id, role, event_id) values (org2, door_e, 'door', ev);
  m_srv := tests.mid(srv_1, 'server');
  m_srv2 := tests.mid(srv_2, 'server');
  m_mgr := tests.mid(mgr_a, 'manager');
  m_door := tests.mid(door_e, 'door');

  ---------------------------------------------------------------- a manager changes staff of their own club
  perform tests.assert_eq('a server can be made security by their club''s manager', tests.change(mgr_a, 'mgra@role.example', m_srv, 'security'), 'ok');
  perform tests.assert_eq('the old role ended and the new one began', tests.roles_of(srv_1), 'security:active server:revoked');
  perform tests.assert_eq('...and the person is now security at that club, no longer a server', tests.run_as(srv_1, 'srv1@role.example', format($q$select (public.can_access_venue(%L, array['security']))::text || (public.can_access_venue(%L, array['server']))::text$q$, venue_a, venue_a)), 'truefalse');
  perform tests.assert_eq('the old membership records who ended it', (select (revoked_by = mgr_a)::text from public.site_memberships where id = m_srv), 'true');
  perform tests.assert_eq('the new one records who appointed it', (select (invited_by = mgr_a)::text from public.site_memberships where user_id = srv_1 and role = 'security'), 'true');
  perform tests.assert_eq('a shift and its window carry over', tests.change(mgr_a, 'mgra@role.example', m_srv2, 'verifier'), 'ok');
  perform tests.assert_eq('...the new membership keeps the shift', (select (shift_id = shift_a)::text from public.site_memberships where user_id = srv_2 and role = 'verifier' and status = 'active'), 'true');
  perform tests.assert_eq('the old one is gone from the active ones', tests.roles_of(srv_2), 'server:revoked verifier:active');

  ---------------------------------------------------------------- what is refused
  m_new := tests.mid(srv_1, 'security');
  perform tests.assert_eq('the same role again', tests.change(mgr_a, 'mgra@role.example', m_new, 'security'), 'ERROR: they already have that role');
  perform tests.assert_eq('a role that does not exist', tests.change(mgr_a, 'mgra@role.example', m_new, 'boss'), 'ERROR: choose a role');
  perform tests.assert_eq('no role', tests.change(mgr_a, 'mgra@role.example', m_new, null), 'ERROR: choose a role');
  perform tests.assert_eq('a manager cannot make someone a manager', tests.change(mgr_a, 'mgra@role.example', m_new, 'manager'), 'ERROR: not allowed');
  perform tests.assert_eq('a manager cannot change another manager', tests.change(mgr_a, 'mgra@role.example', tests.mid(mgr_b, 'manager'), 'server'), 'ERROR: not allowed');
  perform tests.assert_eq('nobody changes their own role', tests.change(owner_u, 'owner@role.example', tests.mid(owner_u, 'owner'), 'manager'), 'ERROR: you cannot change your own role');
  perform tests.assert_eq('a manager cannot change their own either', tests.change(mgr_a, 'mgra@role.example', m_mgr, 'server'), 'ERROR: you cannot change your own role');
  perform tests.assert_eq('an owner''s role is not changed here', tests.change(mgr_a, 'mgra@role.example', tests.mid(owner_u, 'owner'), 'server'), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot change this club''s staff', tests.change(mgr_b, 'mgrb@role.example', m_new, 'server'), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot change anyone', tests.change(srv_2, 'srv2@role.example', m_new, 'server'), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.change(rando, 'rando@role.example', m_new, 'server'), 'ERROR: not allowed');
  perform tests.assert_eq('an event role cannot be changed', tests.change(org_u, 'org@role.example', m_door, 'server'), 'ERROR: a role at an event cannot be changed: remove access and invite again');
  perform tests.assert_eq('a membership that is already ended', tests.change(mgr_a, 'mgra@role.example', m_srv, 'verifier'), 'ERROR: membership not found');
  perform tests.assert_eq('a membership that does not exist', tests.change(mgr_a, 'mgra@role.example', gen_random_uuid(), 'verifier'), 'ERROR: membership not found');
  perform tests.assert_eq('nothing changed by the refusals', tests.roles_of(srv_1), 'security:active server:revoked');

  ---------------------------------------------------------------- the owner can promote and demote
  perform tests.assert_eq('the owner makes a server a manager', tests.change(owner_u, 'owner@role.example', m_new, 'manager'), 'ok');
  perform tests.assert_eq('...at the same club', (select (venue_id = venue_a)::text from public.site_memberships where user_id = srv_1 and role = 'manager' and status = 'active'), 'true');
  perform tests.assert_eq('the owner demotes a manager', tests.change(owner_u, 'owner@role.example', tests.mid(srv_1, 'manager'), 'door'), 'ok');
  perform tests.assert_eq('a manager on a shift cannot be made: a manager has a club', tests.change(owner_u, 'owner@role.example', tests.mid(srv_2, 'verifier'), 'manager'), 'ERROR: a manager works at a club, not on a shift: remove access and invite again');
  perform tests.assert_eq('the whole history is kept', tests.roles_of(srv_1), 'door:active manager:revoked security:revoked server:revoked');

  ---------------------------------------------------------------- a duplicate role is refused, not doubled
  perform tests.join_as(mgr_a, 'mgra@role.example', org, 'srv1@role.example', 'verifier', venue_a, srv_1);
  perform tests.assert_eq('someone who already has the role there', tests.change(mgr_a, 'mgra@role.example', tests.mid(srv_1, 'door'), 'verifier'), 'ERROR: they already have that role here');

  ---------------------------------------------------------------- logged, and closed
  perform tests.logout();
  perform tests.assert_eq('each change is one entry in the audit log with who made it', (select count(*) from public.audit_log where action = 'team.role_changed' and actor_id in (mgr_a, owner_u))::int, 4);
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot change a role', format($q$select public.change_member_role(%L, 'server')$q$, m_new), 'permission denied');
  perform tests.logout();
end $$;

rollback;
