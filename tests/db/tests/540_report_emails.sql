-- E-mailing a report (20261119100000_report_emails.sql). What matters: the three kinds of report never mix (a club's report goes only to that club's list, only the owner or manager of that club
-- keeps and sends it; the owner's combined report only the owner; an organizer's event report only the organizer business, and a club cannot send or read it); the addresses always
-- come from the configured list, never from the caller; every refusal is the same sentence; the lists are tidy (one address, lower case, no duplicates, ten at most); a send is limited (ten
-- an hour, a PDF of at most 5 MB, a safe file name); the provider's answer is written by the e-mail function only and only once; "send again" takes only the addresses whose latest
-- attempt failed; the log is readable only by the people who may send; the tables are closed to the app; and deleting a person's account does not block on what they sent.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
  perform tests.logout();
end $$;
create function tests.try(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into r;
  perform tests.logout();
  return coalesce(r, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
-- Run as the e-mail function would (service role).
create function tests.try_service(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login_service();
  execute p_sql into r;
  perform tests.logout();
  return coalesce(r, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.try_anon(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login_anon();
  execute p_sql into r;
  perform tests.logout();
  return coalesce(r, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-00000000e0d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-00000000e0d2';
  srv_a constant uuid := '00000000-0000-0000-0000-00000000e0d3';
  mgr_b constant uuid := '00000000-0000-0000-0000-00000000e0d4';
  other_owner constant uuid := '00000000-0000-0000-0000-00000000e0d5';
  org_u constant uuid := '00000000-0000-0000-0000-00000000e0d6';
  org_staff constant uuid := '00000000-0000-0000-0000-00000000e0d7';
  other_org_u constant uuid := '00000000-0000-0000-0000-00000000e0d8';
  door_e constant uuid := '00000000-0000-0000-0000-00000000e0d9';
  rando constant uuid := '00000000-0000-0000-0000-00000000e0da';
  org_boss constant uuid := '00000000-0000-0000-0000-00000000e0db';
  two_hats constant uuid := '00000000-0000-0000-0000-00000000e0dc';
  mgr_in_org constant uuid := '00000000-0000-0000-0000-00000000e0dd';
  club_org uuid; other_club_org uuid; org uuid; other_org uuid; venue_a uuid; venue_b uuid; venue_x uuid; ev uuid; ev_other uuid;
  r_owner uuid; r_a uuid; r_a2 uuid; r_b uuid; r_org uuid; r_any uuid;
  out text; batch1 uuid; ids uuid[]; d_ok uuid; d_bad uuid; n bigint; i int; sent_ids text;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@rep.example'), (mgr_a, 'mgra@rep.example'), (srv_a, 'srva@rep.example'), (mgr_b, 'mgrb@rep.example'), (other_owner, 'other@rep.example'),
    (org_u, 'org@rep.example'), (org_staff, 'orgstaff@rep.example'), (other_org_u, 'otherorg@rep.example'), (door_e, 'door@rep.example'), (rando, 'rando@rep.example'), (org_boss, 'orgboss@rep.example'), (two_hats, 'twohats@rep.example'), (mgr_in_org, 'mgrinorg@rep.example');

  perform tests.login(owner_u, 'owner@rep.example');
  club_org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(club_org, 'Club A');
  venue_b := public.create_org_venue(club_org, 'Club B');
  perform tests.login(other_owner, 'other@rep.example');
  other_club_org := public.create_organization('Other Club Co', 'venue_owner');
  venue_x := public.create_org_venue(other_club_org, 'Other Club');
  perform tests.login(org_u, 'org@rep.example');
  org := public.create_organization('Night Events', 'organizer');
  perform tests.login(other_org_u, 'otherorg@rep.example');
  other_org := public.create_organization('Other Events', 'organizer');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@rep.example', club_org, 'mgra@rep.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@rep.example', club_org, 'srva@rep.example', 'server', venue_a, srv_a);
  perform tests.join_as(owner_u, 'owner@rep.example', club_org, 'mgrb@rep.example', 'manager', venue_b, mgr_b);
  insert into public.site_memberships (org_id, user_id, role) values (org, org_staff, 'organizer'), (org, org_boss, 'owner');
  -- One person who is an organizer in BOTH organizer businesses, and who manages a club of the OTHER club business: the business named in a request has to be the one that really holds the club or the event.
  insert into public.site_memberships (org_id, user_id, role) values (org, two_hats, 'organizer'), (other_org, two_hats, 'organizer');
  perform tests.join_as(other_owner, 'other@rep.example', other_club_org, 'twohats@rep.example', 'manager', venue_x, two_hats);
  insert into public.site_memberships (org_id, user_id, role, venue_id) values (org, mgr_in_org, 'manager', venue_a);
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, venue_id)
    values ('Night One', 'x', 'Club A', now() + interval '3 days', now() + interval '3 days 6 hours', 'published', org, venue_a) returning id into ev;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Other Night', 'x', 'Elsewhere', now() + interval '3 days', now() + interval '3 days 6 hours', 'published', other_org) returning id into ev_other;
  insert into public.site_memberships (org_id, user_id, role, event_id) values (org, door_e, 'door', ev);

  -- ---------------------------------------------------------------- the lists: who may keep which one
  out := tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, '  Boss@Club.Example '));
  r_owner := out::uuid;
  perform tests.assert_true('the owner adds an address to the combined report list', r_owner is not null);
  perform tests.assert_eq('it is kept tidy: trimmed and in lower case', (select email from public.site_report_recipients where id = r_owner), 'boss@club.example');
  perform tests.assert_eq('the owner reads the list back', tests.try(owner_u, 'owner@rep.example', format('select string_agg(email, '','') from public.report_recipients(%L, %L, null)', 'owner_combined', club_org)), 'boss@club.example');
  perform tests.assert_eq('a manager does not keep the owner''s combined list', tests.try(mgr_a, 'mgra@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, 'x@y.zz')), 'ERROR: not allowed');
  perform tests.assert_eq('a manager does not read it either', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_recipients(%L, %L, null)', 'owner_combined', club_org)), 'ERROR: not allowed');
  perform tests.assert_eq('another business''s owner does not', tests.try(other_owner, 'other@rep.example', format('select count(*)::text from public.report_recipients(%L, %L, null)', 'owner_combined', club_org)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger does not', tests.try(rando, 'rando@rep.example', format('select count(*)::text from public.report_recipients(%L, %L, null)', 'owner_combined', club_org)), 'ERROR: not allowed');
  perform tests.assert_true('a visitor cannot call it at all', tests.try_anon(format('select count(*)::text from public.report_recipients(%L, %L, null)', 'owner_combined', club_org)) like 'ERROR: permission denied%');

  r_a := tests.try(mgr_a, 'mgra@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'venue_night', club_org, venue_a, 'manager@clubA.example'))::uuid;
  perform tests.assert_true('a club''s manager keeps that club''s night list', r_a is not null);
  r_a2 := tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'venue_night', club_org, venue_a, 'accountant@clubA.example'))::uuid;
  perform tests.assert_true('and so does the owner', r_a2 is not null);
  perform tests.assert_eq('another club''s manager cannot', tests.try(mgr_b, 'mgrb@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'venue_night', club_org, venue_a, 'x@y.zz')), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot', tests.try(srv_a, 'srva@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'venue_night', club_org, venue_a, 'x@y.zz')), 'ERROR: not allowed');
  perform tests.assert_eq('a club of another business cannot be named under this business', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'venue_night', club_org, venue_x, 'x@y.zz')), 'ERROR: not allowed');
  perform tests.assert_eq('a person who manages a club of another business cannot file it under their other business', tests.try(two_hats, 'twohats@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'venue_night', club_org, venue_x, 'x@y.zz')), 'ERROR: not allowed');
  perform tests.assert_true('under the business that holds the club they can', tests.try(two_hats, 'twohats@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'venue_night', other_club_org, venue_x, 'x@y.zz')) not like 'ERROR%');
  perform tests.assert_eq('nor can they send that club''s report under the wrong business', tests.try(two_hats, 'twohats@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_x, '2026-10-29', 'n.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('a club list needs a club', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'venue_night', club_org, 'x@y.zz')), 'ERROR: not allowed');
  perform tests.assert_eq('the combined list is not tied to a club', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'owner_combined', club_org, venue_a, 'x@y.zz')), 'ERROR: not allowed');
  perform tests.assert_eq('an unknown kind of report is refused', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'everything', club_org, 'x@y.zz')), 'ERROR: not allowed');

  r_org := tests.try(org_u, 'org@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'organizer_sales', org, 'promoter@events.example'))::uuid;
  perform tests.assert_true('the organizer business''s owner keeps the organizer list', r_org is not null);
  perform tests.assert_true('so does an organizer', tests.try(org_staff, 'orgstaff@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'organizer_sales', org, 'partner@events.example')) not like 'ERROR%');
  perform tests.assert_eq('a club''s owner cannot read the organizer''s list', tests.try(owner_u, 'owner@rep.example', format('select count(*)::text from public.report_recipients(%L, %L, null)', 'organizer_sales', org)), 'ERROR: not allowed');
  perform tests.assert_eq('another organizer cannot', tests.try(other_org_u, 'otherorg@rep.example', format('select count(*)::text from public.report_recipients(%L, %L, null)', 'organizer_sales', org)), 'ERROR: not allowed');
  perform tests.assert_eq('door staff of the event cannot', tests.try(door_e, 'door@rep.example', format('select count(*)::text from public.report_recipients(%L, %L, null)', 'organizer_sales', org)), 'ERROR: not allowed');
  perform tests.assert_eq('an organizer list is not tied to a club', tests.try(org_u, 'org@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'organizer_sales', org, venue_a, 'x@y.zz')), 'ERROR: not allowed');

  -- The owner of the organizer business may also keep the combined list there: the two lists of one business never mix.
  perform tests.assert_true('an organizer business that also has an owner: the owner can keep a combined list there', tests.try(org_boss, 'orgboss@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', org, 'cfo@events.example')) not like 'ERROR%');
  perform tests.assert_eq('an organizer cannot keep the combined list', tests.try(org_staff, 'orgstaff@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', org, 'x@y.zz')), 'ERROR: not allowed');
  perform tests.assert_eq('that owner reads the organizer list too, and it holds only its own two addresses', tests.try(org_boss, 'orgboss@rep.example', format('select string_agg(email, '','' order by email) from public.report_recipients(%L, %L, null)', 'organizer_sales', org)), 'partner@events.example,promoter@events.example');

  -- ---------------------------------------------------------------- the lists: tidy
  perform tests.assert_eq('not an address', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, 'nope')), 'ERROR: enter one e-mail address, like name@company.com');
  perform tests.assert_eq('no domain dot', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, 'a@b')), 'ERROR: enter one e-mail address, like name@company.com');
  perform tests.assert_eq('two addresses in one go', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, 'a@b.cc,d@e.ff')), 'ERROR: enter one e-mail address, like name@company.com');
  perform tests.assert_eq('a space inside', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, 'a b@c.dd')), 'ERROR: enter one e-mail address, like name@company.com');
  perform tests.assert_eq('nothing', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, null)::text', 'owner_combined', club_org)), 'ERROR: enter one e-mail address, like name@company.com');
  perform tests.assert_eq('a duplicate (any case)', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, 'BOSS@club.example')), 'ERROR: that address is already on the list');
  perform tests.assert_true('the same address may be on a different list', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, %L, %L)::text', 'venue_night', club_org, venue_b, 'boss@club.example')) not like 'ERROR%');
  for i in 1..8 loop
    perform tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, 'p' || i || '@club.example'));
  end loop;
  perform tests.assert_eq('nine addresses so far', (select count(*) from public.site_report_recipients where org_id = club_org and kind = 'owner_combined'), 9::bigint);
  perform tests.assert_true('the tenth address is accepted', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, 'p9@club.example')) not like 'ERROR%');
  perform tests.assert_eq('an eleventh is refused', tests.try(owner_u, 'owner@rep.example', format('select public.add_report_recipient(%L, %L, null, %L)::text', 'owner_combined', club_org, 'p10@club.example')), 'ERROR: a list can hold at most 10 addresses: remove one first');

  -- ---------------------------------------------------------------- removing
  perform tests.assert_eq('a manager cannot remove from the owner''s list', tests.try(mgr_a, 'mgra@rep.example', format('select public.remove_report_recipient(%L)::text', r_owner)), 'ERROR: not allowed');
  perform tests.assert_eq('nor an unknown row', tests.try(owner_u, 'owner@rep.example', 'select public.remove_report_recipient(''00000000-0000-0000-0000-00000000ffff'')::text'), 'ERROR: not allowed');
  perform tests.assert_eq('the owner removes one', tests.try(owner_u, 'owner@rep.example', format('select public.remove_report_recipient(%L)::text', r_owner)), '');
  perform tests.assert_true('it is gone', not exists (select 1 from public.site_report_recipients where id = r_owner));
  perform tests.assert_eq('the club''s manager removes from the club''s list', tests.try(mgr_a, 'mgra@rep.example', format('select public.remove_report_recipient(%L)::text', r_a2)), '');
  perform tests.assert_eq('the other club''s manager cannot remove from it', tests.try(mgr_b, 'mgrb@rep.example', format('select public.remove_report_recipient(%L)::text', r_a)), 'ERROR: not allowed');

  -- ---------------------------------------------------------------- sending: who and what
  -- Lists now: combined (owner) has 9 addresses; club A has manager@clubA.example; club B has boss@club.example; organizer has two.
  perform tests.assert_eq('a send reads the list of THAT club only', tests.try(mgr_a, 'mgra@rep.example',
    format('select string_agg(email, '','' order by email) from public.report_send_begin(%L, %L, %L, null, %L, %L, 1200, false)', 'venue_night', club_org, venue_a, '2026-10-30', 'night-2026-10-30.pdf')), 'manager@cluba.example');
  perform tests.assert_eq('the other club''s manager cannot send club A''s report', tests.try(mgr_b, 'mgrb@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 1200, false)', 'venue_night', club_org, venue_a, '2026-10-30', 'night.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot send a club report', tests.try(srv_a, 'srva@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 1200, false)', 'venue_night', club_org, venue_a, '2026-10-30', 'night.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('an organizer cannot send a club report', tests.try(org_u, 'org@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 1200, false)', 'venue_night', club_org, venue_a, '2026-10-30', 'night.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('a club report cannot be sent through the organizer''s list (kind and event must agree)', tests.try(mgr_a, 'mgra@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, %L, %L, %L, %L, 1200, false)', 'venue_night', club_org, venue_a, ev, '2026-10-30', 'night.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('the combined report goes only to the owner''s list, not a club''s', tests.try(owner_u, 'owner@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, null, null, %L, %L, 5000, false)', 'owner_combined', club_org, '2026-10-30', 'combined.pdf')), '9');
  perform tests.assert_eq('in a business with both lists, the combined report goes only to the combined list', tests.try(org_boss, 'orgboss@rep.example',
    format('select string_agg(email, '','') from public.report_send_begin(%L, %L, null, null, %L, %L, 4000, false)', 'owner_combined', org, '2026-10-30', 'combined.pdf')), 'cfo@events.example');
  perform tests.assert_eq('a manager cannot send the combined report', tests.try(mgr_a, 'mgra@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, null, null, %L, %L, 5000, false)', 'owner_combined', club_org, '2026-10-30', 'combined.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('the organizer''s event report goes to the organizer''s list', tests.try(org_staff, 'orgstaff@rep.example',
    format('select string_agg(email, '','' order by email) from public.report_send_begin(%L, %L, null, %L, %L, %L, 3000, false)', 'organizer_sales', org, ev, ev::text, 'sales.pdf')), 'partner@events.example,promoter@events.example');
  perform tests.assert_eq('an event of another business is refused', tests.try(org_u, 'org@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, null, %L, %L, %L, 3000, false)', 'organizer_sales', org, ev_other, ev_other::text, 'sales.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('so is an event with another business named', tests.try(other_org_u, 'otherorg@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, null, %L, %L, %L, 3000, false)', 'organizer_sales', other_org, ev, ev::text, 'sales.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('the organizer report needs an event', tests.try(org_u, 'org@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, null, null, %L, %L, 3000, false)', 'organizer_sales', org, 'x', 'sales.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('an organizer of two businesses cannot send one business''s event report under the other', tests.try(two_hats, 'twohats@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, null, %L, %L, %L, 3000, false)', 'organizer_sales', org, ev_other, ev_other::text, 'sales.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('a manager who sits in the organizer business is not an organizer: no list for them', tests.try(mgr_in_org, 'mgrinorg@rep.example', format('select count(*)::text from public.report_recipients(%L, %L, null)', 'organizer_sales', org)), 'ERROR: not allowed');
  perform tests.assert_eq('door staff of the event cannot send it', tests.try(door_e, 'door@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, null, %L, %L, %L, 3000, false)', 'organizer_sales', org, ev, ev::text, 'sales.pdf')), 'ERROR: not allowed');
  perform tests.assert_eq('the club''s owner cannot send the organizer''s report', tests.try(owner_u, 'owner@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, null, %L, %L, %L, 3000, false)', 'organizer_sales', org, ev, ev::text, 'sales.pdf')), 'ERROR: not allowed');
  perform tests.assert_true('a visitor cannot call it', tests.try_anon(format('select count(*)::text from public.report_send_begin(%L, %L, null, null, %L, %L, 10, false)', 'owner_combined', club_org, '2026-10-29', 'a.pdf')) like 'ERROR: permission denied%');

  perform tests.assert_eq('a night is a real date', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_a, '2026-13-45', 'n.pdf')), 'ERROR: say which night this report is for');
  perform tests.assert_eq('not words', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_a, 'Free money!', 'n.pdf')), 'ERROR: say which night this report is for');
  perform tests.assert_eq('nor a date with text after it', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_a, '2026-10-30 click here', 'n.pdf')), 'ERROR: say which night this report is for');
  perform tests.assert_eq('the organizer''s report is the event, not words', tests.try(org_u, 'org@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, null, %L, %L, %L, 100, false)', 'organizer_sales', org, ev, 'Free money!', 'n.pdf')), 'ERROR: say which report this is');
  perform tests.assert_eq('the names for the message come from the database', tests.try(mgr_a, 'mgra@rep.example', format('select min(org_name) || ''/'' || min(venue_name) || ''/'' || coalesce(min(event_title), ''-'') from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_a, '2026-10-27', 'n.pdf')), 'Club Co/Club A/-');
  perform tests.assert_eq('and the event''s title for the organizer', tests.try(org_u, 'org@rep.example', format('select min(org_name) || ''/'' || coalesce(min(venue_name), ''-'') || ''/'' || min(event_title) from public.report_send_begin(%L, %L, null, %L, %L, %L, 100, false)', 'organizer_sales', org, ev, ev::text, 'n.pdf')), 'Night Events/-/Night One');
  delete from public.site_report_deliveries where report_ref = '2026-10-27' or (kind = 'organizer_sales' and bytes = 100);

  -- ---------------------------------------------------------------- sending: what is written
  select count(*) into n from public.site_report_deliveries where kind = 'owner_combined' and org_id = club_org;
  perform tests.assert_eq('nine pending rows were written for the combined send', n, 9::bigint);
  perform tests.assert_true('all in one batch, all pending, all by the owner, with the size', (select count(distinct batch_id) = 1 and bool_and(status = 'pending') and bool_and(sent_by = owner_u) and bool_and(bytes = 5000) from public.site_report_deliveries where kind = 'owner_combined' and org_id = club_org));
  perform tests.assert_true('refused sends wrote nothing', (select count(*) from public.site_report_deliveries) = 9 + 1 + 2 + 1);
  perform tests.assert_true('the audit log has the sends and the list changes', (select count(*) from public.audit_log where action = 'report.send_started') = 6
    and exists (select 1 from public.audit_log where action = 'report.recipient_added') and exists (select 1 from public.audit_log where action = 'report.recipient_removed'));

  -- ---------------------------------------------------------------- sending: limits and tidy inputs
  perform tests.assert_eq('club B''s manager sends to club B''s own list', tests.try(mgr_b, 'mgrb@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_b, '2026-10-29', 'x.pdf')), '1');
  delete from public.site_report_recipients where kind = 'venue_night' and venue_id = venue_b;
  perform tests.assert_eq('an empty list says so', tests.try(mgr_b, 'mgrb@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_b, '2026-10-29', 'x.pdf')), 'ERROR: no one is set to receive this report: add an e-mail address first');
  perform tests.assert_eq('a file name must end in .pdf', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_a, '2026-10-29', 'night.exe')),
    'ERROR: the file name must end in .pdf and use only letters, numbers, spaces and . _ ( ) -');
  perform tests.assert_eq('and cannot climb folders', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_a, '2026-10-29', '../night.pdf')),
    'ERROR: the file name must end in .pdf and use only letters, numbers, spaces and . _ ( ) -');
  perform tests.assert_eq('an empty PDF', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 0, false)', 'venue_night', club_org, venue_a, '2026-10-29', 'n.pdf')), 'ERROR: the report is empty');
  perform tests.assert_eq('a PDF over 5 MB', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 5242881, false)', 'venue_night', club_org, venue_a, '2026-10-29', 'n.pdf')), 'ERROR: this report is too large to e-mail (5 MB at most)');
  perform tests.assert_eq('exactly 5 MB is fine', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 5242880, false)', 'venue_night', club_org, venue_a, '2026-10-29', 'n.pdf')), '1');
  perform tests.assert_eq('no name for the report', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_a, '  ', 'n.pdf')), 'ERROR: say which night this report is for');

  -- ten sends an hour per person: the owner has done 1 (combined); nine more are fine, the eleventh is not
  for i in 1..9 loop
    out := tests.try(owner_u, 'owner@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, null, null, %L, %L, 100, false)', 'owner_combined', club_org, '2026-09-0' || i, 'c' || i || '.pdf'));
  end loop;
  perform tests.assert_eq('the owner''s tenth send in the hour went through', out, '9');
  perform tests.assert_eq('the eleventh is refused', tests.try(owner_u, 'owner@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, null, null, %L, %L, 100, false)', 'owner_combined', club_org, '2026-09-10', 'c10.pdf')),
    'ERROR: too many reports sent this hour: try again later');
  perform tests.assert_eq('the limit is the person''s own: the manager is not held up by the owner''s sends', tests.try(mgr_a, 'mgra@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 100, false)', 'venue_night', club_org, venue_a, '2026-10-28', 'y.pdf')), '1');
  update public.site_report_deliveries set created_at = now() - interval '2 hours' where sent_by = owner_u;
  perform tests.assert_eq('after an hour it opens again', tests.try(owner_u, 'owner@rep.example', format('select count(*)::text from public.report_send_begin(%L, %L, null, null, %L, %L, 100, false)', 'owner_combined', club_org, '2026-09-11', 'c11.pdf')), '9');

  -- ---------------------------------------------------------------- the provider's answer
  select array_agg(id order by email) into ids from public.site_report_deliveries where sent_by = org_staff;
  perform tests.assert_eq('the organizer''s send is two pending rows', coalesce(cardinality(ids), 0), 2);
  perform tests.assert_eq('a signed-in person cannot write the answer', tests.try(org_staff, 'orgstaff@rep.example', format('select public.report_send_finish(%L::jsonb)::text', jsonb_build_array(jsonb_build_object('id', ids[1], 'ok', true)))), 'ERROR: permission denied for function report_send_finish');
  perform tests.assert_true('a visitor cannot', tests.try_anon(format('select public.report_send_finish(%L::jsonb)::text', jsonb_build_array(jsonb_build_object('id', ids[1], 'ok', true)))) like 'ERROR: permission denied%');
  perform tests.assert_eq('the e-mail function records one sent and one failed', tests.try_service(format('select public.report_send_finish(%L::jsonb)::text',
    jsonb_build_array(jsonb_build_object('id', ids[1], 'ok', true), jsonb_build_object('id', ids[2], 'ok', false, 'error', repeat('x', 400))))), '2');
  select id into d_ok from public.site_report_deliveries where id = ids[1]; select id into d_bad from public.site_report_deliveries where id = ids[2];
  perform tests.assert_eq('sent', (select status from public.site_report_deliveries where id = d_ok), 'sent');
  perform tests.assert_true('the sent one has a finish time and no error', (select finished_at is not null and error is null from public.site_report_deliveries where id = d_ok));
  perform tests.assert_true('failed, with the reason cut to 300 characters', (select status = 'failed' and char_length(error) = 300 from public.site_report_deliveries where id = d_bad));
  perform tests.assert_eq('a second answer changes nothing', tests.try_service(format('select public.report_send_finish(%L::jsonb)::text', jsonb_build_array(jsonb_build_object('id', ids[2], 'ok', true)))), '0');
  perform tests.assert_eq('still failed', (select status from public.site_report_deliveries where id = d_bad), 'failed');
  perform tests.assert_eq('an answer that is not a list is refused', tests.try_service('select public.report_send_finish(''{}''::jsonb)::text'), 'ERROR: results must be a list');
  perform tests.assert_eq('an answer without ok means failed', (select tests.try_service(format('select public.report_send_finish(%L::jsonb)::text', jsonb_build_array(jsonb_build_object('id', x.id))))
    from (select id from public.site_report_deliveries where sent_by = mgr_a and status = 'pending' limit 1) x), '1');
  perform tests.assert_true('with the stock reason', exists (select 1 from public.site_report_deliveries where sent_by = mgr_a and status = 'failed' and error = 'the e-mail was not accepted'));

  -- ---------------------------------------------------------------- send again
  perform tests.assert_eq('send again takes only the failed address', tests.try(org_staff, 'orgstaff@rep.example',
    format('select string_agg(email, '','') from public.report_send_begin(%L, %L, null, %L, %L, %L, 3000, true)', 'organizer_sales', org, ev, ev::text, 'sales.pdf')),
    (select email from public.site_report_deliveries where id = d_bad));
  update public.site_report_deliveries set status = 'sent', finished_at = now() where sent_by = org_staff and status = 'pending';
  perform tests.assert_eq('once it has gone through there is nothing to send again', tests.try(org_staff, 'orgstaff@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, null, %L, %L, %L, 3000, true)', 'organizer_sales', org, ev, ev::text, 'sales.pdf')), 'ERROR: there is nothing to send again');
  perform tests.assert_eq('a report never sent has nothing to send again either', tests.try(owner_u, 'owner@rep.example',
    format('select count(*)::text from public.report_send_begin(%L, %L, %L, null, %L, %L, 3000, true)', 'venue_night', club_org, venue_a, '2026-01-01', 'night.pdf')), 'ERROR: there is nothing to send again');

  -- ---------------------------------------------------------------- the log
  perform tests.assert_eq('the organizer reads the log of the event report', tests.try(org_u, 'org@rep.example',
    format('select count(*)::text from public.report_deliveries(%L, %L, null, %L, %L, 20)', 'organizer_sales', org, ev, ev::text)), '3');
  perform tests.assert_eq('newest first: the latest attempt is the one that went through', tests.try(org_u, 'org@rep.example',
    format('select email || ''/'' || status from public.report_deliveries(%L, %L, null, %L, %L, 20) limit 1', 'organizer_sales', org, ev, ev::text)), 'promoter@events.example/sent');
  perform tests.assert_eq('and the oldest is last', tests.try(org_u, 'org@rep.example',
    format('select email || ''/'' || status from (select * from public.report_deliveries(%L, %L, null, %L, %L, 20)) q offset 2 limit 1', 'organizer_sales', org, ev, ev::text)), 'partner@events.example/sent');
  perform tests.assert_eq('the limit is honoured (and never below one)', tests.try(org_u, 'org@rep.example',
    format('select count(*)::text from public.report_deliveries(%L, %L, null, %L, %L, 0)', 'organizer_sales', org, ev, ev::text)), '1');
  perform tests.assert_eq('the club''s owner cannot read the organizer''s log', tests.try(owner_u, 'owner@rep.example',
    format('select count(*)::text from public.report_deliveries(%L, %L, null, %L, %L, 20)', 'organizer_sales', org, ev, ev::text)), 'ERROR: not allowed');
  perform tests.assert_eq('the other club''s manager cannot read club A''s log', tests.try(mgr_b, 'mgrb@rep.example',
    format('select count(*)::text from public.report_deliveries(%L, %L, %L, null, %L, 20)', 'venue_night', club_org, venue_a, '2026-10-29')), 'ERROR: not allowed');
  perform tests.assert_eq('club A''s manager reads it', tests.try(mgr_a, 'mgra@rep.example',
    format('select count(*)::text from public.report_deliveries(%L, %L, %L, null, %L, 20)', 'venue_night', club_org, venue_a, '2026-10-29')), '1');
  perform tests.assert_true('a visitor cannot', tests.try_anon(format('select count(*)::text from public.report_deliveries(%L, %L, %L, null, %L, 20)', 'venue_night', club_org, venue_a, '2026-10-29')) like 'ERROR: permission denied%');

  -- ---------------------------------------------------------------- closed tables and deleting an account
  perform tests.assert_true('the app cannot read the lists directly', tests.try(owner_u, 'owner@rep.example', 'select count(*)::text from public.site_report_recipients') like 'ERROR: permission denied%');
  perform tests.assert_true('nor the log', tests.try(owner_u, 'owner@rep.example', 'select count(*)::text from public.site_report_deliveries') like 'ERROR: permission denied%');
  perform tests.assert_true('nor write to them', tests.try(owner_u, 'owner@rep.example', 'delete from public.site_report_deliveries') like 'ERROR: permission denied%');
  perform tests.assert_true('row level security is on for both', (select bool_and(relrowsecurity) from pg_class where oid in ('public.site_report_recipients'::regclass, 'public.site_report_deliveries'::regclass)));
  delete from auth.users where id = org_staff;
  perform tests.assert_true('deleting the account of someone who sent a report leaves the log, without the person', exists (select 1 from public.site_report_deliveries where sent_by is null)
    and not exists (select 1 from public.site_report_deliveries where sent_by = org_staff));
  delete from auth.users where id = mgr_a;
  perform tests.assert_true('and the account of someone who kept a list leaves the list, without the person', exists (select 1 from public.site_report_recipients where kind = 'venue_night' and venue_id = venue_a and added_by is null));
end $$;

rollback;
