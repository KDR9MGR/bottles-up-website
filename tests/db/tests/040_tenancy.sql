-- Tenancy foundation: organizations, memberships, invitations, shifts.
-- Mirrors the client's Phase 2 scenarios: owner adds two clubs, manager sees only
-- their club, temporary staff expire or are revoked, an organizer's access stays
-- inside its own events, nobody grants more than their own role allows.
begin;

do $$
declare
  owner_u    constant uuid := '00000000-0000-0000-0000-0000000000c1';
  mgr_u      constant uuid := '00000000-0000-0000-0000-0000000000c2';
  server_u   constant uuid := '00000000-0000-0000-0000-0000000000c3';
  rival_u    constant uuid := '00000000-0000-0000-0000-0000000000c4';
  promoter_u constant uuid := '00000000-0000-0000-0000-0000000000c5';
  door_u     constant uuid := '00000000-0000-0000-0000-0000000000c6';
  stranger_u constant uuid := '00000000-0000-0000-0000-0000000000c7';
  verifier_u constant uuid := '00000000-0000-0000-0000-0000000000c8';
  casual_u   constant uuid := '00000000-0000-0000-0000-0000000000c9';
  sec_u      constant uuid := '00000000-0000-0000-0000-0000000000ca';
  admin_u    constant uuid := '00000000-0000-0000-0000-0000000000a2'; -- CMS admin from the shared fixtures
  org uuid; org2 uuid; porg uuid;
  venue_a uuid; venue_b uuid; venue_r uuid;
  ev uuid; ev_other uuid;
  tok text; tok2 text; inv uuid; inv2 uuid; mid uuid; shift_b uuid; shift uuid; server_mid uuid; mgr_mid uuid;
  r record; n int; txt text;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@club.example'), (mgr_u, 'manager@club.example'), (server_u, 'server@club.example'),
    (rival_u, 'rival@club2.example'), (promoter_u, 'promoter@events.example'), (door_u, 'door@events.example'),
    (stranger_u, 'stranger@example.com'), (verifier_u, 'verifier@club.example'),
    (casual_u, 'casual@club.example'), (sec_u, 'security@club.example');

  ---------------------------------------------------------------- organizations and venues
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot create an organization', $q$select public.create_organization('X', 'venue_owner')$q$, 'permission denied');

  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('an organization needs a valid kind', $q$select public.create_organization('X', 'wizard')$q$, 'invalid organization kind');
  perform tests.assert_raises('an organization needs a name', $q$select public.create_organization('   ', 'venue_owner')$q$, 'name required');
  org := public.create_organization('Club Co', 'venue_owner');
  select count(*) into n from public.my_workspaces() where org_id = org and role = 'owner';
  perform tests.assert_eq('the creator becomes the owner of the new organization', n, 1);

  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  select count(*) into n from public.my_venues();
  perform tests.assert_eq('an owner can add two clubs and sees both', n, 2);
  perform tests.assert_true('...and can reach each of them', public.can_access_venue(venue_a) and public.can_access_venue(venue_b));

  perform tests.login(rival_u, 'rival@club2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  venue_r := public.create_org_venue(org2, 'Rival Club');
  select count(*) into n from public.my_venues();
  perform tests.assert_eq('another owner sees only their own club', n, 1);
  perform tests.assert_true('...and cannot reach the first owner''s clubs', not public.can_access_venue(venue_a));
  perform tests.assert_raises('...nor add a club to the first owner''s organization', format($q$select public.create_org_venue(%L, 'Sneaky')$q$, org), 'not allowed');

  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_true('the first owner cannot reach the rival''s club either', not public.can_access_venue(venue_r));

  ---------------------------------------------------------------- inviting a manager
  select i.invitation_id, i.token into inv, tok from public.invite_member(org, 'Manager@Club.Example ', 'manager', venue_a) i;
  perform tests.assert_true('an owner can invite a manager for a venue', tok is not null and length(tok) >= 32);
  select state into txt from public.list_invitations(org) where invitation_id = inv;
  perform tests.assert_eq('the invitation starts as pending', txt, 'pending');
  perform tests.logout();
  select count(*) into n from public.site_invitations where token_hash = sha256(convert_to(tok, 'utf8'));
  perform tests.assert_eq('only a hash of the link token is stored', n, 1);
  select count(*) into n from public.site_invitations where encode(token_hash, 'escape') = tok;
  perform tests.assert_eq('...never the token itself', n, 0);

  perform tests.login(stranger_u, 'stranger@example.com');
  select * into r from public.accept_invitation(tok);
  perform tests.assert_eq('someone else''s link does not work for a different email', r.outcome, 'email_mismatch');
  select * into r from public.accept_invitation('not-a-real-token');
  perform tests.assert_eq('a made-up link is invalid', r.outcome, 'invalid');
  select count(*) into n from public.my_workspaces();
  perform tests.assert_eq('...and neither gave the stranger any workspace', n, 0);

  perform tests.login(mgr_u, 'manager@club.example');
  select * into r from public.accept_invitation(tok);
  perform tests.assert_eq('the invited manager accepts (email matches case-insensitively)', r.outcome, 'ok');
  mgr_mid := r.joined_membership_id;
  select * into r from public.accept_invitation(tok);
  perform tests.assert_eq('opening the link again says already_accepted', r.outcome, 'already_accepted');
  perform tests.logout();
  select count(*) into n from public.site_memberships where user_id = mgr_u and status = 'active';
  perform tests.assert_eq('...and never creates a second membership', n, 1);

  perform tests.login(mgr_u, 'manager@club.example');
  select count(*) into n from public.my_workspaces() where role = 'manager' and venue_id = venue_a;
  perform tests.assert_eq('the manager lands in exactly their club', n, 1);
  perform tests.assert_true('manager can reach their club', public.can_access_venue(venue_a));
  perform tests.assert_true('...but not the owner''s other club', not public.can_access_venue(venue_b));
  select count(*) into n from public.my_venues();
  perform tests.assert_eq('the manager''s venue list holds only their club', n, 1);
  select count(*) into n from public.site_venues where id = venue_b;
  perform tests.assert_eq('the other club does not even show up in a direct query (RLS)', n, 0);
  select count(*) into n from public.site_venues where id = venue_a;
  perform tests.assert_eq('...while their own club does, though it is still a draft', n, 1);

  ---------------------------------------------------------------- who may grant what
  perform tests.assert_raises('a manager cannot invite another manager', format($q$select * from public.invite_member(%L, 'm2@club.example', 'manager', %L)$q$, org, venue_a), 'not allowed');
  perform tests.assert_raises('a manager cannot invite staff to a different club', format($q$select * from public.invite_member(%L, 's@club.example', 'server', %L)$q$, org, venue_b), 'not allowed');
  perform tests.assert_raises('nobody can grant ownership by invitation', format($q$select * from public.invite_member(%L, 'o@club.example', 'owner', %L)$q$, org, venue_a), 'not allowed');
  perform tests.assert_raises('an invitation needs a valid email', format($q$select * from public.invite_member(%L, 'nope', 'server', %L)$q$, org, venue_a), 'valid email required');

  select i.token into tok from public.invite_member(org, 'server@club.example', 'server', venue_a) i;
  perform tests.assert_true('a manager can invite venue staff to their own club', tok is not null);

  perform tests.login(server_u, 'server@club.example');
  select * into r from public.accept_invitation(tok);
  perform tests.assert_eq('the server accepts', r.outcome, 'ok');
  server_mid := r.joined_membership_id;
  select count(*) into n from public.my_workspaces() where role = 'server' and venue_id = venue_a;
  perform tests.assert_eq('the server lands in the club they were assigned', n, 1);
  perform tests.assert_raises('a server cannot invite anyone', format($q$select * from public.invite_member(%L, 'x@club.example', 'door', %L)$q$, org, venue_a), 'not allowed');
  perform tests.assert_raises('a server cannot create a shift', format($q$select public.create_shift(%L, 'Night', now(), now() + interval '8 hours')$q$, venue_a), 'not allowed');
  select count(*) into n from public.site_memberships;
  perform tests.assert_eq('a server sees only their own membership row, not the team', n, 1);

  perform tests.login(mgr_u, 'manager@club.example');
  select count(*) into n from public.site_memberships where venue_id = venue_a;
  perform tests.assert_eq('the manager sees their club''s team (manager and server)', n, 2);

  ---------------------------------------------------------------- expiry, resend, revoke an invitation
  perform tests.login(owner_u, 'owner@club.example');
  select i.invitation_id, i.token into inv, tok from public.invite_member(org, 'verifier@club.example', 'verifier', venue_a) i;
  perform tests.logout();
  update public.site_invitations set expires_at = now() - interval '1 minute' where id = inv;

  perform tests.login(owner_u, 'owner@club.example');
  select state into txt from public.list_invitations(org) where invitation_id = inv;
  perform tests.assert_eq('an invitation past its expiry shows as expired', txt, 'expired');
  perform tests.login(verifier_u, 'verifier@club.example');
  select * into r from public.accept_invitation(tok);
  perform tests.assert_eq('an expired link cannot be accepted', r.outcome, 'expired');
  select count(*) into n from public.my_workspaces();
  perform tests.assert_eq('...and gives no access', n, 0);

  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok2 from public.resend_invitation(inv) i;
  perform tests.assert_true('an expired invitation can be renewed with a fresh link', tok2 is not null and tok2 <> tok);
  perform tests.login(verifier_u, 'verifier@club.example');
  select * into r from public.accept_invitation(tok);
  perform tests.assert_eq('...and the old link no longer works', r.outcome, 'invalid');
  select * into r from public.accept_invitation(tok2);
  perform tests.assert_eq('...while the new one does', r.outcome, 'ok');
  perform tests.logout();
  select count(*) into n from public.site_memberships where user_id = verifier_u and status = 'active';
  perform tests.assert_eq('resending created no duplicate membership', n, 1);
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('an accepted invitation cannot be resent', format($q$select * from public.resend_invitation(%L)$q$, inv), 'already accepted');

  select i.invitation_id, i.token into inv, tok from public.invite_member(org, 'casual@club.example', 'door', venue_a) i;
  perform public.revoke_invitation(inv);
  perform tests.login(casual_u, 'casual@club.example');
  select * into r from public.accept_invitation(tok);
  perform tests.assert_eq('a revoked invitation cannot be accepted', r.outcome, 'revoked');
  select count(*) into n from public.my_workspaces();
  perform tests.assert_eq('...and gives no access', n, 0);

  perform tests.login(owner_u, 'owner@club.example');
  select i.invitation_id into inv from public.invite_member(org, 'dup@club.example', 'security', venue_a) i;
  select i.invitation_id into inv2 from public.invite_member(org, 'dup@club.example', 'security', venue_a) i;
  select count(*) into n from public.site_invitations where email = 'dup@club.example';
  perform tests.assert_true('inviting the same person to the same role twice renews one invitation', inv = inv2 and n = 1);

  shift_b := public.create_shift(venue_b, 'Club B night', now(), now() + interval '6 hours');
  perform tests.assert_raises('a shift from another club cannot be attached to an invitation',
    format($q$select * from public.invite_member(%L, 'sh@club.example', 'server', %L, null, %L)$q$, org, venue_a, shift_b),
    'shift does not belong to this venue');

  ---------------------------------------------------------------- temporary access windows and shifts
  perform tests.logout();
  insert into public.site_memberships (org_id, user_id, role, venue_id, access_start_at, access_end_at)
    values (org, sec_u, 'security', venue_a, now() - interval '2 hours', now() - interval '1 hour');
  perform tests.login(sec_u, 'security@club.example');
  select count(*) into n from public.my_workspaces();
  perform tests.assert_eq('temporary staff whose window has ended get no workspace', n, 0);
  perform tests.assert_true('...and cannot reach the club', not public.can_access_venue(venue_a));

  perform tests.logout();
  update public.site_memberships set access_start_at = now() + interval '1 hour', access_end_at = now() + interval '3 hours' where user_id = sec_u;
  perform tests.login(sec_u, 'security@club.example');
  select count(*) into n from public.my_workspaces();
  perform tests.assert_eq('...nor do staff whose window has not started yet', n, 0);

  perform tests.logout();
  update public.site_memberships set access_start_at = now() - interval '1 hour', access_end_at = now() + interval '1 hour' where user_id = sec_u;
  perform tests.login(sec_u, 'security@club.example');
  select count(*) into n from public.my_workspaces() where role = 'security' and venue_id = venue_a;
  perform tests.assert_eq('inside the window the access works', n, 1);

  perform tests.login(mgr_u, 'manager@club.example');
  shift := public.create_shift(venue_a, 'Saturday night', now() - interval '1 hour', now() + interval '5 hours');
  perform tests.logout();
  insert into public.site_memberships (org_id, user_id, role, venue_id, shift_id) values (org, casual_u, 'door', venue_a, shift);
  perform tests.login(casual_u, 'casual@club.example');
  select count(*) into n from public.my_workspaces() where shift_name = 'Saturday night';
  perform tests.assert_eq('a shift-scoped member can work during their shift', n, 1);
  perform tests.logout();
  update public.site_shifts set starts_at = now() - interval '10 hours', ends_at = now() - interval '5 hours' where id = shift;
  perform tests.login(casual_u, 'casual@club.example');
  select count(*) into n from public.my_workspaces();
  perform tests.assert_eq('...and loses access when the shift is over', n, 0);

  ---------------------------------------------------------------- revoking access
  perform tests.login(server_u, 'server@club.example');
  perform tests.assert_raises('a server cannot revoke the manager', format($q$select public.revoke_membership(%L)$q$, mgr_mid), 'not allowed');
  perform tests.login(stranger_u, 'stranger@example.com');
  perform tests.assert_raises('a stranger cannot revoke anyone', format($q$select public.revoke_membership(%L)$q$, server_mid), 'not allowed');
  perform tests.logout();
  select id into mid from public.site_memberships where user_id = owner_u and role = 'owner';
  perform tests.login(mgr_u, 'manager@club.example');
  perform tests.assert_raises('a manager cannot revoke the owner', format($q$select public.revoke_membership(%L)$q$, mid), 'not allowed');
  perform tests.assert_raises('revoking something that does not exist is an error', $q$select public.revoke_membership('00000000-0000-0000-0000-00000000dead')$q$, 'membership not found');

  perform public.revoke_membership(server_mid);
  perform tests.login(server_u, 'server@club.example');
  select count(*) into n from public.my_workspaces();
  perform tests.assert_eq('a revoked server loses access immediately', n, 0);
  perform tests.logout();
  select status, revoked_by into r from public.site_memberships where id = server_mid;
  perform tests.assert_true('...and the record stays, showing who revoked it', r.status = 'revoked' and r.revoked_by = mgr_u);

  perform tests.login(owner_u, 'owner@club.example');
  perform public.revoke_membership(mgr_mid);
  perform tests.login(mgr_u, 'manager@club.example');
  select count(*) into n from public.my_workspaces();
  perform tests.assert_eq('the owner can revoke a manager, who then loses access', n, 0);

  ---------------------------------------------------------------- organizer and event-scoped door staff
  perform tests.login(promoter_u, 'promoter@events.example');
  porg := public.create_organization('Night Events', 'organizer');
  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, org_id)
    values ('Promoter Night', 'd', 'Club A', now() + interval '1 day', porg) returning id into ev;
  insert into public.site_events (title, description, venue_name, start_date, org_id)
    values ('Someone Else Night', 'd', 'Elsewhere', now() + interval '1 day', org2) returning id into ev_other;

  perform tests.login(promoter_u, 'promoter@events.example');
  select i.token into tok from public.invite_member(porg, 'door@events.example', 'door', null, ev) i;
  perform tests.assert_true('an organizer can appoint door staff for their own event', tok is not null);
  perform tests.assert_raises('...but not for someone else''s event', format($q$select * from public.invite_member(%L, 'd2@events.example', 'door', null, %L)$q$, porg, ev_other), 'not allowed');
  perform tests.assert_raises('...nor by borrowing another organization', format($q$select * from public.invite_member(%L, 'd2@events.example', 'door', null, %L)$q$, org2, ev_other), 'not allowed');
  perform tests.assert_raises('...only door staff, not servers', format($q$select * from public.invite_member(%L, 's2@events.example', 'server', null, %L)$q$, porg, ev), 'not allowed');
  perform tests.assert_raises('...and never venue-wide access', format($q$select * from public.invite_member(%L, 'm2@events.example', 'manager', %L)$q$, porg, venue_a), 'not allowed');
  perform tests.assert_raises('...not even venue staff at a venue they do not own', format($q$select * from public.invite_member(%L, 'd3@events.example', 'door', %L)$q$, porg, venue_a), 'not allowed');

  perform tests.login(door_u, 'door@events.example');
  select * into r from public.accept_invitation(tok);
  perform tests.assert_eq('the door user accepts', r.outcome, 'ok');
  select count(*) into n from public.my_workspaces() where role = 'door' and event_title = 'Promoter Night' and venue_id is null;
  perform tests.assert_eq('door staff land on the one event they were given', n, 1);
  perform tests.assert_true('they can reach that event', public.can_access_event(ev));
  perform tests.assert_true('...not another organizer''s event', not public.can_access_event(ev_other));
  perform tests.assert_true('...and no venue at all', not public.can_access_venue(venue_a));
  select count(*) into n from public.site_events where id = ev;
  perform tests.assert_eq('they can read their event even while it is a draft', n, 1);
  select count(*) into n from public.site_events where id = ev_other;
  perform tests.assert_eq('...but a draft event of someone else stays hidden', n, 0);

  perform tests.login(promoter_u, 'promoter@events.example');
  perform tests.assert_true('the organizer reaches every event their organization owns', public.can_access_event(ev));
  perform tests.assert_true('...but not venues', not public.can_access_venue(venue_a));

  perform tests.login(owner_u, 'owner@club.example');
  select count(*) into n from public.site_organizations;
  perform tests.assert_eq('a venue owner sees only their own organization', n, 1);

  ---------------------------------------------------------------- privileges and secrets
  perform tests.assert_raises('the app cannot write memberships directly',
    format($q$insert into public.site_memberships (org_id, user_id, role) values (%L, %L, 'owner')$q$, org, owner_u), 'permission denied');
  perform tests.assert_raises('...nor edit them', format($q$update public.site_memberships set role = 'owner' where id = %L$q$, mgr_mid), 'permission denied');
  perform tests.assert_raises('...nor delete them', format($q$delete from public.site_memberships where id = %L$q$, mgr_mid), 'permission denied');
  perform tests.assert_raises('the invitation link hash cannot be read by the app', $q$select token_hash from public.site_invitations$q$, 'permission denied');
  select count(*) into n from public.site_memberships where org_id = org2;
  perform tests.assert_eq('an owner cannot read another organization''s team', n, 0);
  select count(*) into n from public.site_invitations where org_id = org2;
  perform tests.assert_eq('...nor its invitations', n, 0);
  select count(*) into n from public.site_organizations where id = org2;
  perform tests.assert_eq('...nor the organization itself', n, 0);

  perform tests.login(admin_u, 'admin@test.example');
  select count(*) into n from public.site_organizations;
  perform tests.assert_true('a platform admin can see every organization', n >= 3);

  ---------------------------------------------------------------- the public site must keep working
  -- Regression: the permission functions are not executable by anonymous callers,
  -- so any policy that uses them must apply to signed-in users only. Otherwise every
  -- visitor browsing events or venues hits "permission denied".
  perform tests.logout();
  insert into public.site_venues (name, status) values ('Public Venue', 'published');
  perform tests.login_anon();
  select count(*) into n from public.site_events where status = 'published';
  perform tests.assert_true('anonymous visitors can still browse published events', n >= 1);
  select count(*) into n from public.site_venues where name = 'Public Venue';
  perform tests.assert_eq('...and published venues', n, 1);
  select count(*) into n from public.site_venues where name like 'Club %';
  perform tests.assert_eq('...but see no draft clubs', n, 0);
  perform tests.login(stranger_u, 'stranger@example.com');
  select count(*) into n from public.site_venues where name like 'Club %';
  perform tests.assert_eq('a signed-in user with no membership sees no draft clubs either', n, 0);
end $$;

rollback;
