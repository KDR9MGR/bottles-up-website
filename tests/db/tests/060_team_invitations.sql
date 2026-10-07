-- Team and invitations: who sees whom, what each invitation state looks like, and the rules that make
-- emailing an invitation link safe (only the invited address, only the link holder, rate limited).
begin;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000e1';
  mgr_u constant uuid := '00000000-0000-0000-0000-0000000000e2';
  server_u constant uuid := '00000000-0000-0000-0000-0000000000e3';
  door_u constant uuid := '00000000-0000-0000-0000-0000000000e4';
  stranger_u constant uuid := '00000000-0000-0000-0000-0000000000e5';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000e6';
  mgr2_u constant uuid := '00000000-0000-0000-0000-0000000000e7';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; shift_f uuid; shift_old uuid;
  inv_mgr uuid; tok_mgr text; inv_mgr2 uuid; tok_mgr2 text; inv_srv uuid; tok_srv text;
  inv_door uuid; tok_door text; inv_new uuid; tok_new text; inv_rev uuid; tok_rev text; inv_exp uuid; tok_exp text;
  inv_mail uuid; tok_mail text; tok_mail2 text; srv_mid uuid;
  n int; txt text; r record; arr text[];
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@club.example'), (mgr_u, 'manager@club.example'), (server_u, 'server@club.example'),
    (door_u, 'door@club.example'), (stranger_u, 'stranger@example.com'), (rival_u, 'rival@club2.example'),
    (mgr2_u, 'manager2@club.example');
  insert into public.profiles (id, name, email) values (owner_u, 'Olivia Owner', 'owner@club.example');

  ---------------------------------------------------------------- set up a business with two clubs and two managers
  perform tests.login(owner_u, 'owner@club.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');

  select i.invitation_id, i.token into inv_mgr, tok_mgr from public.invite_member(org, 'manager@club.example', 'manager', venue_a) i;
  select i.invitation_id, i.token into inv_mgr2, tok_mgr2 from public.invite_member(org, 'manager2@club.example', 'manager', venue_b) i;
  perform tests.login(mgr_u, 'manager@club.example');
  perform public.accept_invitation(tok_mgr);
  perform tests.login(mgr2_u, 'manager2@club.example');
  perform public.accept_invitation(tok_mgr2);

  ---------------------------------------------------------------- the invite form only offers what the database allows
  perform tests.login(owner_u, 'owner@club.example');
  select array_agg(rl order by rl) into arr from public.invitable_roles(org, venue_a) rl;
  perform tests.assert_eq('an owner may appoint all five roles at their own club', arr, array['door', 'manager', 'security', 'server', 'verifier']);
  select count(*) into n from public.invitable_roles(org, null);
  perform tests.assert_eq('a venue is required: with none, nothing is offered', n, 0);

  perform tests.login(mgr_u, 'manager@club.example');
  select array_agg(rl order by rl) into arr from public.invitable_roles(org, venue_a) rl;
  perform tests.assert_eq('a manager may appoint staff but never another manager', arr, array['door', 'security', 'server', 'verifier']);
  select count(*) into n from public.invitable_roles(org, venue_b);
  perform tests.assert_eq('...and nothing at a club that is not theirs', n, 0);

  perform tests.login(stranger_u, 'stranger@example.com');
  select count(*) into n from public.invitable_roles(org, venue_a);
  perform tests.assert_eq('a stranger is offered nothing', n, 0);

  perform tests.login(rival_u, 'rival@club2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  select count(*) into n from public.invitable_roles(org, venue_a);
  perform tests.assert_eq('another business owner is offered nothing for this club', n, 0);

  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot ask', format($q$select * from public.invitable_roles(%L, %L)$q$, org, venue_a), 'permission denied');

  ---------------------------------------------------------------- shifts
  perform tests.login(owner_u, 'owner@club.example');
  shift_f := public.create_shift(venue_a, 'Friday doors', now() + interval '1 day', now() + interval '1 day 8 hours');
  shift_old := public.create_shift(venue_a, 'Last week', now() - interval '5 days', now() - interval '5 days' + interval '8 hours');
  select count(*) into n from public.list_shifts(venue_a);
  perform tests.assert_eq('an owner lists upcoming shifts and not old ones', n, 1);
  select name into txt from public.list_shifts(venue_a);
  perform tests.assert_eq('...the upcoming one', txt, 'Friday doors');
  perform tests.login(mgr_u, 'manager@club.example');
  select count(*) into n from public.list_shifts(venue_a);
  perform tests.assert_eq('the manager of that club sees them too', n, 1);
  perform tests.login(mgr2_u, 'manager2@club.example');
  perform tests.assert_raises('a manager of another club cannot', format($q$select * from public.list_shifts(%L)$q$, venue_a), 'not allowed');
  perform tests.login(stranger_u, 'stranger@example.com');
  perform tests.assert_raises('a stranger cannot', format($q$select * from public.list_shifts(%L)$q$, venue_a), 'not allowed');

  ---------------------------------------------------------------- appoint staff
  perform tests.login(owner_u, 'owner@club.example');
  select i.invitation_id, i.token into inv_srv, tok_srv from public.invite_member(org, 'server@club.example', 'server', venue_a, null, shift_f) i;
  perform tests.login(mgr_u, 'manager@club.example');
  select i.invitation_id, i.token into inv_door, tok_door
    from public.invite_member(org, 'door@club.example', 'door', venue_a, null, null, now() + interval '1 hour', now() + interval '9 hours') i;
  perform tests.login(server_u, 'server@club.example');
  perform public.accept_invitation(tok_srv);
  perform tests.login(door_u, 'door@club.example');
  perform public.accept_invitation(tok_door);

  ---------------------------------------------------------------- the team, as each person sees it
  perform tests.login(owner_u, 'owner@club.example');
  select count(*) into n from public.list_team(org);
  perform tests.assert_eq('an owner sees everyone: themselves, two managers, a server and a door person', n, 5);
  select role into txt from public.list_team(org) limit 1;
  perform tests.assert_eq('...the owner first', txt, 'owner');
  select name into txt from public.list_team(org) where role = 'owner';
  perform tests.assert_eq('...with the name from their profile', txt, 'Olivia Owner');
  select email into txt from public.list_team(org) where role = 'owner';
  perform tests.assert_eq('...and their email', txt, 'owner@club.example');
  select count(*) into n from public.list_team(org) where name is null and email is not null;
  perform tests.assert_eq('people without a profile still show by email', n, 4);
  select string_agg(role, ',' order by role) into txt from (select role from public.list_team(org) offset 1 limit 2) x;
  perform tests.assert_eq('managers are listed right after the owner', txt, 'manager,manager');
  select venue_name into txt from public.list_team(org) where email = 'manager@club.example';
  perform tests.assert_eq('each manager shows the club they run', txt, 'Club A');

  select state into txt from public.list_team(org) where email = 'server@club.example';
  perform tests.assert_eq('a server on a shift that has not started is scheduled, not active', txt, 'scheduled');
  select shift_name into txt from public.list_team(org) where email = 'server@club.example';
  perform tests.assert_eq('...and the shift is named', txt, 'Friday doors');
  select state into txt from public.list_team(org) where email = 'door@club.example';
  perform tests.assert_eq('a person whose window has not opened is scheduled', txt, 'scheduled');
  select state into txt from public.list_team(org) where email = 'manager@club.example';
  perform tests.assert_eq('a manager with no window is active', txt, 'active');

  perform tests.logout();
  update public.site_memberships set access_start_at = now() - interval '5 hours', access_end_at = now() + interval '5 hours'
    where user_id = door_u;
  perform tests.login(owner_u, 'owner@club.example');
  select state into txt from public.list_team(org) where email = 'door@club.example';
  perform tests.assert_eq('inside their window a person is active', txt, 'active');
  perform tests.logout();
  update public.site_memberships set access_start_at = now() - interval '9 hours', access_end_at = now() - interval '1 hour'
    where user_id = door_u;
  perform tests.login(owner_u, 'owner@club.example');
  select state into txt from public.list_team(org) where email = 'door@club.example';
  perform tests.assert_eq('once the window has ended they are expired', txt, 'expired');

  perform tests.logout();
  update public.site_shifts set starts_at = now() - interval '9 hours', ends_at = now() - interval '1 hour' where id = shift_f;
  perform tests.login(owner_u, 'owner@club.example');
  select state into txt from public.list_team(org) where email = 'server@club.example';
  perform tests.assert_eq('a server whose shift is over is expired', txt, 'expired');

  select membership_id into srv_mid from public.list_team(org) where email = 'server@club.example';
  perform public.revoke_membership(srv_mid);
  select state into txt from public.list_team(org) where email = 'server@club.example';
  perform tests.assert_eq('a removed person stays listed as revoked (the history is kept)', txt, 'revoked');

  perform tests.login(mgr_u, 'manager@club.example');
  select count(*) into n from public.list_team(org);
  perform tests.assert_eq('a manager sees only people at their own club (themselves, the server and the door person)', n, 3);
  select count(*) into n from public.list_team(org) where role in ('owner', 'organizer');
  perform tests.assert_eq('...never the owner', n, 0);
  select count(*) into n from public.list_team(org) where email = 'manager2@club.example';
  perform tests.assert_eq('...nor another club''s manager', n, 0);

  perform tests.login(server_u, 'server@club.example');
  perform tests.assert_raises('a removed server is no longer a member and cannot read the team', format($q$select * from public.list_team(%L)$q$, org), 'not allowed');
  perform tests.login(stranger_u, 'stranger@example.com');
  perform tests.assert_raises('a stranger cannot read the team', format($q$select * from public.list_team(%L)$q$, org), 'not allowed');
  perform tests.login(rival_u, 'rival@club2.example');
  perform tests.assert_raises('another business cannot read this team', format($q$select * from public.list_team(%L)$q$, org), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot', format($q$select * from public.list_team(%L)$q$, org), 'permission denied');
  perform tests.login(admin_u, 'admin@test.example');
  select count(*) into n from public.list_team(org);
  perform tests.assert_eq('a platform admin sees everyone', n, 5);

  ---------------------------------------------------------------- invitations in every state
  perform tests.login(owner_u, 'owner@club.example');
  select i.invitation_id, i.token into inv_new, tok_new
    from public.invite_member(org, 'new@staff.example', 'security', venue_b, null, null, now() + interval '2 days', now() + interval '3 days') i;
  select i.invitation_id, i.token into inv_rev, tok_rev from public.invite_member(org, 'gone@staff.example', 'verifier', venue_b) i;
  perform public.revoke_invitation(inv_rev);
  select i.invitation_id, i.token into inv_exp, tok_exp from public.invite_member(org, 'late@staff.example', 'server', venue_b) i;
  perform tests.logout();
  update public.site_invitations set expires_at = now() - interval '1 day' where id = inv_exp;
  perform tests.login(owner_u, 'owner@club.example');

  select state into txt from public.list_team_invitations(org) where invitation_id = inv_new;
  perform tests.assert_eq('a new invitation is pending', txt, 'pending');
  select state into txt from public.list_team_invitations(org) where invitation_id = inv_rev;
  perform tests.assert_eq('a cancelled one is revoked', txt, 'revoked');
  select state into txt from public.list_team_invitations(org) where invitation_id = inv_exp;
  perform tests.assert_eq('one past its expiry is expired, not pending', txt, 'expired');
  select state into txt from public.list_team_invitations(org) where invitation_id = inv_door;
  perform tests.assert_eq('one that was used is accepted', txt, 'accepted');
  select venue_name into txt from public.list_team_invitations(org) where invitation_id = inv_new;
  perform tests.assert_eq('each shows the club it is for', txt, 'Club B');
  select count(*) into n from public.list_team_invitations(org)
    where invitation_id = inv_new and access_start_at is not null and access_end_at is not null;
  perform tests.assert_eq('...and its temporary access window', n, 1);
  select shift_name into txt from public.list_team_invitations(org) where invitation_id = inv_srv;
  perform tests.assert_eq('...and its shift', txt, 'Friday doors');
  select count(*) into n from public.list_team_invitations(org);
  perform tests.assert_eq('an owner sees all seven', n, 7);

  perform tests.login(mgr_u, 'manager@club.example');
  select count(*) into n from public.list_team_invitations(org) where venue_id = venue_b;
  perform tests.assert_eq('a manager does not see invitations for another club', n, 0);
  select count(*) into n from public.list_team_invitations(org);
  perform tests.assert_eq('...only the three for their own', n, 3);

  perform tests.login(stranger_u, 'stranger@example.com');
  perform tests.assert_raises('a stranger cannot list invitations', format($q$select * from public.list_team_invitations(%L)$q$, org), 'not allowed');
  perform tests.assert_raises('the link token is not readable from the table', $q$select token_hash from public.site_invitations$q$, 'permission denied');
  perform tests.assert_raises('...nor the email bookkeeping', $q$select email_send_count from public.site_invitations$q$, 'permission denied');

  ---------------------------------------------------------------- emailing an invitation link
  perform tests.login(owner_u, 'owner@club.example');
  select i.invitation_id, i.token into inv_mail, tok_mail from public.invite_member(org, 'newdoor@club.example', 'door', venue_a) i;
  perform tests.assert_eq('the email function takes no recipient address, so it cannot mail anyone else',
    (select pronargs::int from pg_proc where proname = 'reserve_invitation_email'), 2);

  perform tests.login(stranger_u, 'stranger@example.com');
  perform tests.assert_raises('a stranger cannot send it, even holding the link', format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_mail, tok_mail), 'not allowed');
  perform tests.login(mgr2_u, 'manager2@club.example');
  perform tests.assert_raises('a manager of another club cannot', format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_mail, tok_mail), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot', format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_mail, tok_mail), 'permission denied');

  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('the wrong link is refused', format($q$select * from public.reserve_invitation_email(%L, 'not-the-token')$q$, inv_mail), 'not allowed');
  perform tests.assert_raises('...as is no link at all', format($q$select * from public.reserve_invitation_email(%L, null)$q$, inv_mail), 'not allowed');
  select count(*) into n from public.list_team_invitations(org) where invitation_id = inv_mail and emails_sent = 0;
  perform tests.assert_eq('refused attempts are not counted', n, 1);

  select * into r from public.reserve_invitation_email(inv_mail, tok_mail);
  perform tests.assert_eq('the right holder gets the context: the invited address', r.invitee_email, 'newdoor@club.example');
  perform tests.assert_eq('...the business', r.org_name, 'Club Co');
  perform tests.assert_eq('...the club', r.venue_name, 'Club A');
  perform tests.assert_eq('...the role', r.role, 'door');
  perform tests.assert_eq('...and who is inviting', r.inviter_name, 'Olivia Owner');
  select emails_sent into n from public.list_team_invitations(org) where invitation_id = inv_mail;
  perform tests.assert_eq('the attempt was counted', n, 1);
  perform tests.assert_raises('sending again straight away is refused', format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_mail, tok_mail), 'wait a minute');

  perform tests.logout();
  update public.site_invitations set email_sent_at = now() - interval '2 minutes' where id = inv_mail;
  perform tests.login(owner_u, 'owner@club.example');
  perform public.reserve_invitation_email(inv_mail, tok_mail);
  perform tests.logout();
  update public.site_invitations set email_sent_at = now() - interval '2 minutes' where id = inv_mail;
  perform tests.login(owner_u, 'owner@club.example');
  perform public.reserve_invitation_email(inv_mail, tok_mail);
  select emails_sent into n from public.list_team_invitations(org) where invitation_id = inv_mail;
  perform tests.assert_eq('after waiting, sends are allowed up to three', n, 3);
  perform tests.logout();
  update public.site_invitations set email_sent_at = now() - interval '2 minutes' where id = inv_mail;
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('a fourth send for one link is refused, however long you wait',
    format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_mail, tok_mail), 'limit reached');

  select token into tok_mail2 from public.resend_invitation(inv_mail) ;
  select emails_sent into n from public.list_team_invitations(org) where invitation_id = inv_mail;
  perform tests.assert_eq('a fresh link starts the count again', n, 0);
  perform tests.assert_raises('...and the old link no longer works', format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_mail, tok_mail), 'not allowed');
  perform public.reserve_invitation_email(inv_mail, tok_mail2);
  select emails_sent into n from public.list_team_invitations(org) where invitation_id = inv_mail;
  perform tests.assert_eq('...the new one can be sent', n, 1);

  perform tests.assert_raises('a cancelled invitation cannot be emailed', format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_rev, tok_rev), 'not pending');
  perform tests.assert_raises('an expired one cannot', format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_exp, tok_exp), 'not pending');
  perform tests.assert_raises('one already used cannot', format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_door, tok_door), 'not pending');

  perform tests.login(mgr_u, 'manager@club.example');
  perform tests.assert_raises('a manager cannot email the invitation of a manager, even with the link',
    format($q$select * from public.reserve_invitation_email(%L, %L)$q$, inv_mgr2, tok_mgr2), 'not allowed');
end $$;

rollback;
