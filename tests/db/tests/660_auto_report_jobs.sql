-- Sending the reports automatically when a night is closed (20261126100000_auto_report_jobs.sql; brief section 27, scenario 22). What matters: the switch is off until someone who may send that kind
-- of report switches it on (the same people as the button); closing a night queues each switched-on report once per close (the club's, the owner's once EVERY club has closed, an organizer's once
-- every club hosting the event has); queueing can NEVER stop a night from closing; the server job acts AS the person who switched it on through the existing report functions, so a person who
-- lost access gets "not allowed" and nothing is sent; the acting-as is put back; only the service role can run the job functions; the delivery log is the button's; retries wait and stop.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
-- run one statement as a person (an error is returned as text)
create function tests.run_as(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
-- run one statement as the SERVICE ROLE
create function tests.svc(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login_service();
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
-- read a closed table as its owner
create function tests.q(p_sql text) returns text language plpgsql security definer as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, 'null');
end $$;
-- run one statement that returns nothing, as its owner
create function tests.x(p_sql text) returns void language plpgsql security definer as $$ begin execute p_sql; end $$;
-- every job in one line, oldest first: kind:club-or-event:ref-offset:revision:status
create function tests.jobs() returns text language sql security definer as $$
  select coalesce(string_agg(j.kind || ':' || coalesce((select v.name from public.site_venues v where v.id = j.venue_id), (select e.title from public.site_events e where e.id = j.event_id), '-') || ':' || j.revision || ':' || j.status, ' | ' order by j.created_at, j.id), '(none)') from public.site_report_jobs j $$;
create function tests.njobs() returns int language sql security definer as $$ select count(*)::int from public.site_report_jobs $$;
-- the id of the one job of a kind for a club or an event title and a revision
create function tests.jobid(p_kind text, p_label text, p_rev int, p_ref text default null) returns uuid language sql security definer as $$
  select j.id from public.site_report_jobs j where j.kind = p_kind and p_label = coalesce((select v.name from public.site_venues v where v.id = j.venue_id), (select e.title from public.site_events e where e.id = j.event_id), '-')
     and j.revision = p_rev and (p_ref is null or j.report_ref = p_ref) $$;
create function tests.close(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language plpgsql as $$
begin
  return tests.run_as(p_user, p_email, format($q$select public.close_night(%L, %L, true, 'Closing with nothing left to report here')::text$q$, p_venue, p_night));
end $$;

do $$
declare
  vowner constant uuid := '00000000-0000-0000-0000-0000000009a1';
  vmgr constant uuid := '00000000-0000-0000-0000-0000000009a2';
  vmgr_b constant uuid := '00000000-0000-0000-0000-0000000009a3';
  vsrv constant uuid := '00000000-0000-0000-0000-0000000009a4';
  oorg constant uuid := '00000000-0000-0000-0000-0000000009a5';
  ostaff constant uuid := '00000000-0000-0000-0000-0000000009a6';
  rival constant uuid := '00000000-0000-0000-0000-0000000009a7';
  rando constant uuid := '00000000-0000-0000-0000-0000000009a8';
  vorg uuid; oorg_id uuid; rival_org uuid; venue_a uuid; venue_b uuid; ev1 uuid; ev2 uuid; ev3 uuid; ev4 uuid; ag1a uuid; ag1b uuid; ag2a uuid; ag3a uuid; ag3b uuid; ag4a uuid;
  n0 date := current_date - 6; n1 date := current_date - 5; n2 date := current_date - 4;
  r text; i int; j1 uuid; j2 uuid; j3 uuid; jo uuid; je uuid; svc_before text; cnt_before int;
  terms constant text := '{"capacity":300,"bar_percent":0}';
begin
  insert into auth.users (id, email) values
    (vowner, 'vowner@ar.example'), (vmgr, 'vmgr@ar.example'), (vmgr_b, 'vmgrb@ar.example'), (vsrv, 'vsrv@ar.example'), (oorg, 'org@ar.example'), (ostaff, 'ostaff@ar.example'), (rival, 'rival@ar.example'), (rando, 'rando@ar.example');
  insert into public.profiles (id, name, email) values (vowner, 'Olly Owner', 'vowner@ar.example'), (vmgr, 'Mia Manager', 'vmgr@ar.example'), (oorg, 'Olive Organizer', 'org@ar.example'), (ostaff, 'Sam Staff', 'ostaff@ar.example');

  perform tests.login(vowner, 'vowner@ar.example');
  vorg := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(vorg, 'Club A');
  venue_b := public.create_org_venue(vorg, 'Club B');
  perform tests.join_as(vowner, 'vowner@ar.example', vorg, 'vmgr@ar.example', 'manager', venue_a, vmgr);
  perform tests.join_as(vowner, 'vowner@ar.example', vorg, 'vmgrb@ar.example', 'manager', venue_b, vmgr_b);
  perform tests.join_as(vmgr, 'vmgr@ar.example', vorg, 'vsrv@ar.example', 'server', venue_a, vsrv);
  perform tests.login(oorg, 'org@ar.example');
  oorg_id := public.create_organization('Night Events', 'organizer');
  perform tests.login(rival, 'rival@ar.example');
  rival_org := public.create_organization('Rival Events', 'organizer');
  perform tests.logout();
  insert into public.site_memberships (org_id, user_id, role) values (oorg_id, ostaff, 'organizer');
  -- Night One (n1) is hosted by BOTH clubs; Night Two (n2) by Club A only. 22:00 in the clubs' time zone, so the night is the date it starts on.
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Night One', 'x', 'Somewhere', (n1 + time '22:00') at time zone 'America/Toronto', (n1 + time '22:00') at time zone 'America/Toronto' + interval '6 hours', 'draft', oorg_id) returning id into ev1;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Night Two', 'x', 'Somewhere', (n2 + time '22:00') at time zone 'America/Toronto', (n2 + time '22:00') at time zone 'America/Toronto' + interval '6 hours', 'draft', oorg_id) returning id into ev2;
  -- "Late Night" starts at 05:30 the morning after Night Two, which still belongs to Night Two (the business night ends at 06:00); a second club asked to host it and the agreement was cancelled.
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Late Night', 'x', 'Somewhere', (n2 + 1 + time '05:30') at time zone 'America/Toronto', (n2 + 1 + time '05:30') at time zone 'America/Toronto' + interval '3 hours', 'draft', oorg_id) returning id into ev3;
  -- A rival organizer hosts an event at Club A on Night Two but never switched its reports on.
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Rival Night', 'x', 'Somewhere', (n2 + time '22:00') at time zone 'America/Toronto', (n2 + time '22:00') at time zone 'America/Toronto' + interval '6 hours', 'draft', rival_org) returning id into ev4;
  ag1a := tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev1, venue_a))::uuid;
  ag3a := tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev3, venue_a))::uuid;
  ag3b := tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev3, venue_b))::uuid;
  ag4a := tests.run_as(rival, 'rival@ar.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev4, venue_a))::uuid;
  ag1b := tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev1, venue_b))::uuid;
  ag2a := tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev2, venue_a))::uuid;
  perform tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'x')::text$q$, ag1a, terms));
  perform tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'x')::text$q$, ag1b, terms));
  perform tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'x')::text$q$, ag2a, terms));
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag1a));
  perform tests.run_as(vmgr_b, 'vmgrb@ar.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag1b));
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag2a));
  perform tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'x')::text$q$, ag3a, terms));
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag3a));
  perform tests.run_as(oorg, 'org@ar.example', format($q$select public.agreement_close(%L, 'The event is at Club A only')::text$q$, ag3b));
  perform tests.run_as(rival, 'rival@ar.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'x')::text$q$, ag4a, terms));
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag4a));
  perform tests.logout();
  perform tests.assert_eq('the agreements are as the test needs them (One at both clubs, Two and Late Night at Club A, Late Night''s second club cancelled, the rival''s at Club A)',
    (select string_agg(status, ',' order by id = ag1a desc, id = ag1b desc, id = ag2a desc, id = ag3a desc, id = ag3b desc) from public.site_agreements where id in (ag1a, ag1b, ag2a, ag3a, ag3b, ag4a)), 'active,active,active,active,cancelled,active');

  -- the lists the reports go to
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.add_report_recipient('venue_night', %L, %L, 'a1@ar.example')::text$q$, vorg, venue_a));
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.add_report_recipient('venue_night', %L, %L, 'a2@ar.example')::text$q$, vorg, venue_a));
  perform tests.run_as(vowner, 'vowner@ar.example', format($q$select public.add_report_recipient('venue_night', %L, %L, 'b1@ar.example')::text$q$, vorg, venue_b));
  perform tests.run_as(vowner, 'vowner@ar.example', format($q$select public.add_report_recipient('owner_combined', %L, null, 'owner@ar.example')::text$q$, vorg));
  perform tests.run_as(oorg, 'org@ar.example', format($q$select public.add_report_recipient('organizer_sales', %L, null, 'org@ar.example')::text$q$, oorg_id));
  perform tests.run_as(vowner, 'vowner@ar.example', format($q$select public.add_report_recipient('organizer_sales', %L, null, 'extra@ar.example')::text$q$, vorg));
  perform tests.logout();

  ---------------------------------------------------------------- it is off until someone switches it on
  perform tests.assert_eq('the club''s status says off, with two addresses on its list and nothing sent yet', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select (select s.enabled::text || ' ' || s.recipients || ' ' || coalesce(s.last_status, '-') from public.report_auto_status('venue_night', %L, %L) s)$q$, vorg, venue_a)), 'false 2 -');
  perform tests.assert_eq('closing a night with nothing switched on queues nothing', tests.close(vmgr, 'vmgr@ar.example', venue_a, n0) like 'ERROR%' or tests.njobs() = 0, true);
  perform tests.assert_eq('...the night is closed all the same', tests.q(format($q$select status from public.site_night_closes where venue_id = %L and business_night = %L$q$, venue_a, n0)), 'closed');
  perform tests.assert_eq('...and there are no jobs', tests.njobs(), 0);

  ---------------------------------------------------------------- who may switch it on
  perform tests.assert_eq('a club''s manager switches on their club''s night report', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_a)), 'true');
  perform tests.assert_eq('the owner switches on another club''s', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_b)), 'true');
  perform tests.assert_eq('the manager of one club cannot switch on another club''s', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_b)), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot', tests.run_as(vsrv, 'vsrv@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('a rival business and a stranger cannot', tests.run_as(rival, 'rival@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_a)) || ' ' || tests.run_as(rando, 'rando@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_a)), 'ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('a club''s report needs its club, and the owner''s combined report must have none', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('venue_night', %L, null, true)::text$q$, vorg)) || ' ' || tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('owner_combined', %L, %L, true)::text$q$, vorg, venue_a)), 'ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('a club of another business is not this business''s club', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, rival_org, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('only the owner switches on the combined report; a manager cannot', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_auto_set('owner_combined', %L, null, true)::text$q$, vorg)), 'ERROR: not allowed');
  perform tests.assert_eq('the owner does', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('owner_combined', %L, null, true)::text$q$, vorg)), 'true');
  perform tests.assert_eq('an organizer switches on their event reports; the club''s owner cannot (not their business)', tests.run_as(oorg, 'org@ar.example', format($q$select public.report_auto_set('organizer_sales', %L, null, true)::text$q$, oorg_id)) || ' ' || tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('organizer_sales', %L, null, true)::text$q$, oorg_id)), 'true ERROR: not allowed');
  perform tests.run_as(rival, 'rival@ar.example', format($q$select public.report_auto_set('organizer_sales', %L, null, true)::text$q$, rival_org));
  perform tests.run_as(rival, 'rival@ar.example', format($q$select public.report_auto_set('organizer_sales', %L, null, false)::text$q$, rival_org));
  perform tests.assert_eq('every change of a switch is written to the audit log (six so far: the refusals are not)', tests.q($q$select count(*)::text from public.audit_log where action = 'report.auto_set'$q$), '6');
  perform tests.assert_eq('a club''s report cannot be switched on as an organizer report, nor with a club', tests.run_as(oorg, 'org@ar.example', format($q$select public.report_auto_set('organizer_sales', %L, %L, true)::text$q$, oorg_id, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('on or off has to be said', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, null)::text$q$, vorg, venue_a)), 'ERROR: choose on or off');
  perform tests.assert_eq('a kind that does not exist', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('everything', %L, null, true)::text$q$, vorg)), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select public.report_auto_set('venue_night', %L, %L, true)$q$, vorg, venue_a), 'permission denied');
  perform tests.assert_raises('...nor read the status', format($q$select * from public.report_auto_status('venue_night', %L, %L)$q$, vorg, venue_a), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('no signed-in person is told to sign in', format($q$select public.report_auto_set('venue_night', %L, %L, true)$q$, vorg, venue_a), 'not authenticated');
  perform tests.logout();
  perform tests.assert_eq('the status says on, by whom, that it is theirs (for them) and not (for the owner)', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select (select s.enabled::text || ' ' || s.changed_by_name || ' ' || s.mine::text from public.report_auto_status('venue_night', %L, %L) s)$q$, vorg, venue_a)) || ' / ' ||
    tests.run_as(vowner, 'vowner@ar.example', format($q$select (select s.enabled::text || ' ' || s.changed_by_name || ' ' || s.mine::text from public.report_auto_status('venue_night', %L, %L) s)$q$, vorg, venue_a)), 'true Mia Manager true / true Mia Manager false');
  perform tests.assert_eq('a stranger cannot read the status', tests.run_as(rando, 'rando@ar.example', format($q$select (select s.enabled::text from public.report_auto_status('venue_night', %L, %L) s)$q$, vorg, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('a person is named by their profile, and "Someone" when they have no name', tests.run_as(vowner, 'vowner@ar.example', format($q$select (select s.changed_by_name from public.report_auto_status('venue_night', %L, %L) s)$q$, vorg, venue_b)), 'Olly Owner');
  perform tests.assert_eq('there is one switch per club, kind and business (five: two clubs, the owner, two organizers, one of them off)', tests.q('select count(*)::text from public.site_report_auto'), '5');

  perform tests.assert_eq('another authorized person taking it over becomes the person it acts as', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_a)) || ' ' || tests.q(format($q$select (select pr.name from public.profiles pr where pr.id = a.enabled_by) from public.site_report_auto a where a.venue_id = %L$q$, venue_a)), 'true Olly Owner');
  perform tests.assert_eq('...and back (the manager switches it on again)', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_a)) || ' ' || tests.q('select count(*)::text from public.site_report_auto'), 'true 5');
  perform tests.assert_eq('switching off keeps the row and says off', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('owner_combined', %L, null, false)::text$q$, vorg)) || ' ' || tests.run_as(vowner, 'vowner@ar.example', format($q$select (select s.enabled::text from public.report_auto_status('owner_combined', %L) s)$q$, vorg)), 'false false');
  perform tests.assert_eq('...and on again', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('owner_combined', %L, null, true)::text$q$, vorg)), 'true');
  perform tests.assert_eq('the owner''s status counts only the owner''s list (one address), not the business''s other lists', tests.run_as(vowner, 'vowner@ar.example', format($q$select (select s.recipients::text from public.report_auto_status('owner_combined', %L) s)$q$, vorg)), '1');

  ---------------------------------------------------------------- closing a night queues what is switched on
  perform tests.assert_true('Club A closes Night One', tests.close(vmgr, 'vmgr@ar.example', venue_a, n1) not like 'ERROR%');
  perform tests.assert_eq('only the club''s own report is queued: the owner''s waits for Club B, and event One waits for Club B', tests.jobs(), 'venue_night:Club A:1:pending');
  perform tests.assert_eq('...for the person who switched it on, for that night', tests.q(format($q$select (select pr.name from public.profiles pr where pr.id = j.run_as) || ' ' || j.report_ref || ' ' || j.attempts from public.site_report_jobs j where j.kind = 'venue_night' and j.venue_id = %L$q$, venue_a)), 'Mia Manager ' || n1 || ' 0');
  perform tests.assert_true('Club B closes Night One', tests.close(vmgr_b, 'vmgrb@ar.example', venue_b, n1) not like 'ERROR%');
  perform tests.assert_eq('Club B''s report, the owner''s combined report (both clubs closed) and event One''s report (both hosts closed) are queued, the last two at revision 2 (two closes)',
    tests.jobs(), 'venue_night:Club A:1:pending | venue_night:Club B:1:pending | owner_combined:-:2:pending | organizer_sales:Night One:2:pending');
  perform tests.assert_eq('the owner''s combined report acts as the owner; the organizer''s as the organizer', tests.q(format($q$select (select pr.name from public.profiles pr where pr.id = (select run_as from public.site_report_jobs where kind = 'owner_combined')) || ' / ' || (select pr.name from public.profiles pr where pr.id = (select run_as from public.site_report_jobs where kind = 'organizer_sales'))$q$)), 'Olly Owner / Olive Organizer');
  perform tests.assert_true('Club A closes Night Two, which only Club A hosts', tests.close(vmgr, 'vmgr@ar.example', venue_a, n2) not like 'ERROR%');
  perform tests.assert_eq('the club''s report, event Two''s and Late Night''s (05:30 the next morning is still Night Two; its second club cancelled, so it does not wait) are queued; the owner''s is not (Club B is still open that night); the rival''s switch is off',
    tests.jobs(), 'venue_night:Club A:1:pending | venue_night:Club B:1:pending | owner_combined:-:2:pending | organizer_sales:Night One:2:pending | venue_night:Club A:1:pending | organizer_sales:Night Two:1:pending | organizer_sales:Late Night:1:pending');
  perform tests.assert_eq('a job is queued once: asking again for the same close changes nothing', tests.q(format($q$select public.report_jobs_enqueue(%L, %L)::text$q$, venue_a, n1)), '0');
  perform tests.assert_eq('...so seven jobs in all', tests.njobs(), 7);

  ---------------------------------------------------------------- a night closed again after a reopen goes out again
  perform tests.assert_eq('only the owner reopens', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.reopen_night(%L, %L, 'The counts were wrong, closing again')::text$q$, venue_a, n1)), 'ERROR: not allowed');
  perform tests.run_as(vowner, 'vowner@ar.example', format($q$select public.reopen_night(%L, %L, 'The counts were wrong, closing again')::text$q$, venue_a, n1));
  perform tests.assert_eq('reopening queues nothing', tests.njobs(), 7);
  perform tests.assert_true('the club closes it again', tests.close(vmgr, 'vmgr@ar.example', venue_a, n1) not like 'ERROR%');
  perform tests.assert_eq('the corrected report is queued again (revision 2 for the club, 3 for the owner''s combined report and for event One)', tests.jobs(),
    'venue_night:Club A:1:pending | venue_night:Club B:1:pending | owner_combined:-:2:pending | organizer_sales:Night One:2:pending | venue_night:Club A:1:pending | organizer_sales:Night Two:1:pending | organizer_sales:Late Night:1:pending | venue_night:Club A:2:pending | owner_combined:-:3:pending | organizer_sales:Night One:3:pending');

  ---------------------------------------------------------------- a switch that is off, or a person who is gone, queues nothing
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, false)::text$q$, vorg, venue_a));
  perform tests.assert_true('Club A closes another night with its switch off', tests.close(vmgr, 'vmgr@ar.example', venue_a, current_date - 3) not like 'ERROR%');
  perform tests.assert_eq('nothing is queued for it', tests.njobs(), 10);
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_a));
  perform tests.x(format($q$update public.site_report_auto set enabled_by = null where venue_id = %L$q$, venue_a));
  perform tests.assert_eq('a switch whose person has gone (account deleted) queues nothing, and the night still closes', tests.close(vmgr, 'vmgr@ar.example', venue_a, current_date - 2) not like 'ERROR%' and tests.njobs() = 10, true);
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_a));

  ---------------------------------------------------------------- queueing can NEVER stop a night from closing
  perform tests.x('alter table public.site_report_jobs rename to site_report_jobs_away');
  perform tests.assert_eq('even if the queue itself is broken the night closes', tests.close(vmgr, 'vmgr@ar.example', venue_a, current_date - 1) not like 'ERROR%' and tests.q(format($q$select status from public.site_night_closes where venue_id = %L and business_night = current_date - 1$q$, venue_a)) = 'closed', true);
  perform tests.x('alter table public.site_report_jobs_away rename to site_report_jobs');
  perform tests.assert_eq('...and nothing was queued for it', tests.njobs(), 10);
  perform tests.assert_true('the trigger is the only change to an existing table: one trigger on site_night_closes', tests.q($q$select count(*)::text from pg_trigger t where t.tgrelid = 'public.site_night_closes'::regclass and t.tgname = 'report_jobs_after_close' and not t.tgisinternal$q$) = '1');

  ---------------------------------------------------------------- the server job takes jobs
  perform tests.assert_eq('only the service role can take jobs', tests.run_as(vowner, 'vowner@ar.example', 'select count(*)::text from public.report_job_claim(3)'), 'ERROR: permission denied for function report_job_claim');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', 'select * from public.report_job_claim(3)', 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('it takes up to the limit, oldest first, and counts the try', tests.svc('select string_agg(j.kind || '':'' || j.attempts, '','') from public.report_job_claim(2) j'), 'venue_night:1,venue_night:1');
  perform tests.assert_eq('...they are running now, with the time each was taken', tests.q($q$select count(*)::text || ' ' || count(claimed_at) from public.site_report_jobs where status = 'running'$q$), '2 2');
  perform tests.assert_eq('a limit of 0 still takes one, and no limit takes three', tests.svc('select count(*)::text from public.report_job_claim(0)') || ' ' || tests.svc('select count(*)::text from public.report_job_claim(null)'), '1 3');
  perform tests.assert_eq('the rest are taken, and then there is nothing to take', tests.svc('select count(*)::text from public.report_job_claim(100)') || ' ' || tests.svc('select count(*)::text from public.report_job_claim(5)'), '4 0');
  perform tests.assert_eq('all ten are running, each tried once', tests.q($q$select count(*)::text || ' ' || sum(attempts) from public.site_report_jobs where status = 'running'$q$), '10 10');
  -- a job that is not due yet is not taken
  perform tests.logout();
  update public.site_report_jobs set status = 'pending', next_attempt_at = clock_timestamp() + interval '1 hour', finished_at = null where id = tests.jobid('venue_night', 'Club B', 1);
  perform tests.assert_eq('a job whose time has not come is not taken', tests.svc('select count(*)::text from public.report_job_claim(5)'), '0');
  perform tests.logout();
  update public.site_report_jobs set next_attempt_at = clock_timestamp() - interval '1 second' where id = tests.jobid('venue_night', 'Club B', 1);
  perform tests.assert_eq('...and is when it has', tests.svc('select count(*)::text from public.report_job_claim(5)'), '1');
  -- a run that stopped
  perform tests.logout();
  update public.site_report_jobs set claimed_at = clock_timestamp() - interval '20 minutes' where id = tests.jobid('organizer_sales', 'Night Two', 1);
  perform tests.assert_eq('a run that stopped (running for 20 minutes) is taken again, counted as a second try', tests.svc('select string_agg(j.kind || '':'' || j.attempts, '','') from public.report_job_claim(5) j'), 'organizer_sales:2');
  perform tests.logout();
  update public.site_report_jobs set claimed_at = clock_timestamp() - interval '20 minutes', attempts = 5 where id = tests.jobid('organizer_sales', 'Night Two', 1);
  perform tests.assert_eq('...and one that has had five tries is given up on, with the reason', tests.svc('select count(*)::text from public.report_job_claim(5)') || ' ' || tests.q(format($q$select status || ' ' || last_error from public.site_report_jobs where id = %L$q$, tests.jobid('organizer_sales', 'Night Two', 1))), '0 failed the run stopped before it finished');
  perform tests.logout();
  update public.site_report_jobs set claimed_at = clock_timestamp() - interval '5 minutes' where id = tests.jobid('organizer_sales', 'Late Night', 1);
  perform tests.assert_eq('a run that is still going (running for 5 minutes) is left alone', tests.svc('select count(*)::text from public.report_job_claim(5)') || ' ' || tests.q(format($q$select status || ' ' || attempts from public.site_report_jobs where id = %L$q$, tests.jobid('organizer_sales', 'Late Night', 1))), '0 running 1');
  perform tests.logout();
  insert into public.site_report_jobs (kind, org_id, venue_id, report_ref, revision)
    select 'venue_night', vorg, venue_b, 'bulk' || g, 1 from generate_series(1, 12) g;
  perform tests.assert_eq('however large the limit, at most ten are taken at once', tests.svc('select count(*)::text from public.report_job_claim(100)') || ' ' || tests.svc('select count(*)::text from public.report_job_claim(100)') || ' ' || tests.svc('select count(*)::text from public.report_job_claim(100)'), '10 2 0');
  perform tests.logout();
  delete from public.site_report_jobs where report_ref like 'bulk%';

  ---------------------------------------------------------------- the report, asked for AS the person who switched it on
  j1 := tests.jobid('venue_night', 'Club A', 1, n1::text);   -- Night One, switched on by the manager, attempts 1, running
  perform tests.assert_eq('the club''s report: the full nightly report, final, for the right club and night, in the club''s time zone', tests.svc(format($q$select (d #>> '{report,view}') || ' ' || (d #>> '{report,final}') || ' ' || (d #>> '{report,venue_name}') || ' ' || (d #>> '{report,business_night}') || ' ' || (d ->> 'time_zone') || ' ' || (d ->> 'ref') from (select public.report_job_data(%L) as d) x$q$, j1)), 'full true Club A ' || n1 || ' America/Toronto ' || n1);
  perform tests.assert_eq('...with the sections the manager sees (bookings, payments, cash, flags, bottles, service) and the closing details', tests.svc(format($q$select (d #> '{report}' ? 'bookings')::text || (d #> '{report}' ? 'payments')::text || (d #> '{report}' ? 'cash')::text || (d #> '{report}' ? 'bottles')::text || (d #> '{report}' ? 'service')::text || (d #> '{report}' ? 'closed_by_name')::text from (select public.report_job_data(%L) as d) x$q$, j1)), 'truetruetruetruetruetrue');
  perform tests.assert_eq('...and who closed it', tests.svc(format($q$select (public.report_job_data(%L) #>> '{report,closed_by_name}')$q$, j1)), 'Mia Manager');
  perform tests.assert_eq('...and where the sales came from, as the club reports them (there is a "sales" part, empty or not)', tests.svc(format($q$select (public.report_job_data(%L) ? 'sales')::text$q$, j1)), 'true');
  perform tests.assert_eq('the person it acted as is put back: nobody is signed in afterwards', tests.svc(format($q$select (public.report_job_data(%L) is not null)::text || ' ' || coalesce(auth.uid()::text, 'nobody')$q$, j1)), 'true nobody');
  perform tests.assert_eq('...and the claims are as they were (the service role)', tests.svc(format($q$select (public.report_job_data(%L) is not null)::text || ' ' || coalesce(current_setting('request.jwt.claims', true), '')$q$, j1)), 'true {"role" : "service_role"}');
  jo := tests.jobid('owner_combined', '-', 3);
  perform tests.assert_eq('the owner''s combined report is the combined report: both clubs, the business name, the night', tests.svc(format($q$select jsonb_array_length(d #> '{report,venues}')::text || ' ' || (d #>> '{report,org_name}') || ' ' || (d #>> '{report,venues,0,venue_name}') || ' ' || (d #>> '{report,business_night}') from (select public.report_job_data(%L) as d) x$q$, jo)), '2 Club Co Club A ' || n1::text);
  perform tests.assert_eq('...in the time zone of the business''s first club', tests.svc(format($q$select (public.report_job_data(%L) ->> 'time_zone')$q$, jo)), 'America/Toronto');
  je := tests.jobid('organizer_sales', 'Night One', 3);
  perform tests.assert_eq('the organizer''s event report is the organizer''s report: the event, its tickets', tests.svc(format($q$select (d #>> '{report,event,title}') || ' ' || (d #> '{report}' ? 'tickets')::text from (select public.report_job_data(%L) as d) x$q$, je)), 'Night One true');
  perform tests.assert_eq('...in the time zone of the club that hosts it', tests.svc(format($q$select (public.report_job_data(%L) ->> 'time_zone')$q$, je)), 'America/Toronto');
  perform tests.assert_eq('a job that is not running gives nothing', tests.svc(format($q$select public.report_job_data(%L)::text$q$, tests.jobid('organizer_sales', 'Night Two', 1))), 'ERROR: this job is not running');
  perform tests.assert_eq('...nor one that does not exist', tests.svc(format($q$select public.report_job_data(%L)::text$q$, gen_random_uuid())), 'ERROR: this job is not running');
  perform tests.assert_eq('a signed-in person cannot ask for a report this way', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_job_data(%L)::text$q$, j1)), 'ERROR: permission denied for function report_job_data');
  perform tests.assert_eq('...nor use the acting-as directly', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_job_act_as(%L)::text$q$, vowner)) || ' | ' || tests.svc(format($q$select public.report_job_act_as(%L)::text$q$, vowner)), 'ERROR: permission denied for function report_job_act_as | ERROR: permission denied for function report_job_act_as');
  -- the person lost access, or switched it off
  perform tests.logout();
  update public.site_memberships set status = 'revoked', revoked_at = now(), revoked_by = vowner where user_id = vmgr and role = 'manager';
  perform tests.assert_eq('a person who has lost access gets "not allowed" and nothing is returned', tests.svc(format($q$select public.report_job_data(%L)::text$q$, j1)), 'ERROR: not allowed');
  perform tests.logout();
  update public.site_memberships set status = 'active', revoked_at = null, revoked_by = null where user_id = vmgr and role = 'manager';
  perform tests.assert_eq('...and when they have it back, it works', tests.svc(format($q$select (public.report_job_data(%L) #>> '{report,venue_name}')$q$, j1)), 'Club A');
  perform tests.logout();
  update public.site_report_auto set enabled = false where venue_id = venue_a;
  perform tests.assert_eq('a switch that was turned off after the job was queued is respected', tests.svc(format($q$select public.report_job_data(%L)::text$q$, j1)), 'ERROR: automatic sending was switched off');
  perform tests.logout();
  update public.site_report_auto set enabled = true, enabled_by = vowner where venue_id = venue_a;
  perform tests.assert_eq('...and so is a switch another person has taken over (the job was theirs to send, not theirs)', tests.svc(format($q$select public.report_job_data(%L)::text$q$, j1)), 'ERROR: automatic sending was switched off');
  perform tests.logout();
  update public.site_report_auto set enabled_by = vmgr where venue_id = venue_a;
  perform tests.logout();
  update public.site_report_jobs set run_as = null where id = j1;
  perform tests.assert_eq('a job with no person to act as is refused', tests.svc(format($q$select public.report_job_data(%L)::text$q$, j1)), 'ERROR: nobody is set to send it');
  perform tests.logout();
  update public.site_report_jobs set run_as = vmgr where id = j1;
  perform tests.logout();
  perform tests.x(format($q$delete from public.site_report_auto where venue_id = %L$q$, venue_a));
  perform tests.assert_eq('a switch that no longer exists is respected', tests.svc(format($q$select public.report_job_data(%L)::text$q$, j1)), 'ERROR: automatic sending was switched off');
  perform tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_auto_set('venue_night', %L, %L, true)::text$q$, vorg, venue_a));
  perform tests.logout();
  perform tests.x('alter function public.night_sales_sources(uuid, date) rename to night_sales_sources_away');
  perform tests.assert_eq('if the sales cannot be read the report is still returned, with no sales part', tests.svc(format($q$select (public.report_job_data(%L) #>> '{report,view}') || ' ' || coalesce((public.report_job_data(%L) -> 'sales')::text, 'no sales')$q$, j1, j1)), 'full null');
  perform tests.x('alter function public.night_sales_sources_away(uuid, date) rename to night_sales_sources');

  ---------------------------------------------------------------- the delivery log, started as the same person and by the same checks as the button
  perform tests.assert_eq('the club''s two addresses, in order, each pending, with the club''s names for the e-mail', tests.svc(format($q$select string_agg(b.email || ' ' || b.org_name || ' ' || b.venue_name || ' ' || coalesce(b.event_title, '-'), ' | ' order by b.email) from public.report_job_begin(%L, 'club-a-night.pdf', 1234) b$q$, j1)),
    'a1@ar.example Club Co Club A - | a2@ar.example Club Co Club A -');
  perform tests.assert_eq('the rows are the button''s rows: pending, for this report, sent by the person who switched it on, the right size', tests.q(format($q$select string_agg(d.status || ' ' || d.kind || ' ' || d.report_ref || ' ' || d.bytes || ' ' || (select pr.name from public.profiles pr where pr.id = d.sent_by), ',' order by d.email) from public.site_report_deliveries d where d.report_ref = %L and d.venue_id = %L$q$, n1::text, venue_a)),
    'pending venue_night ' || n1 || ' 1234 Mia Manager,pending venue_night ' || n1 || ' 1234 Mia Manager');
  perform tests.assert_eq('the job remembers the batch', tests.q(format($q$select (j.batch_id = (select d.batch_id from public.site_report_deliveries d where d.venue_id = %L and d.report_ref = %L limit 1))::text from public.site_report_jobs j where j.id = %L$q$, venue_a, n1::text, j1)), 'true');
  perform tests.assert_eq('the acting-as was put back', tests.svc(format($q$select coalesce(auth.uid()::text, 'nobody')$q$)), 'nobody');
  perform tests.assert_eq('a name that is not a PDF name is refused by the button''s own rule', tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'club<a>.pdf', 1234)$q$, j1)), 'ERROR: the file name must end in .pdf and use only letters, numbers, spaces and . _ ( ) -');
  perform tests.assert_eq('an empty or oversize PDF is refused too', tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'club-a-night.pdf', 0)$q$, j1)) || ' | ' || tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'club-a-night.pdf', 5242881)$q$, j1)), 'ERROR: the report is empty | ERROR: this report is too large to e-mail (5 MB at most)');
  perform tests.logout();
  update public.site_memberships set status = 'revoked', revoked_at = now(), revoked_by = vowner where user_id = vmgr and role = 'manager';
  perform tests.assert_eq('a job whose person has lost access starts no delivery', tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'club-a-night.pdf', 1234)$q$, j1)), 'ERROR: not allowed');
  perform tests.logout();
  update public.site_memberships set status = 'active', revoked_at = null, revoked_by = null where user_id = vmgr and role = 'manager';
  perform tests.logout();
  update public.site_report_auto set enabled_by = vowner where venue_id = venue_a;
  perform tests.assert_eq('a switch another person took over starts no delivery', tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'club-a-night.pdf', 1234)$q$, j1)), 'ERROR: automatic sending was switched off');
  perform tests.logout();
  update public.site_report_auto set enabled_by = vmgr where venue_id = venue_a;
  update public.site_report_jobs set run_as = null where id = j1;
  perform tests.assert_eq('a job with no person starts no delivery', tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'club-a-night.pdf', 1234)$q$, j1)), 'ERROR: nobody is set to send it');
  perform tests.logout();
  update public.site_report_jobs set run_as = vmgr where id = j1;
  perform tests.assert_eq('a job that is not running, or does not exist, begins nothing', tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'x.pdf', 10)$q$, tests.jobid('organizer_sales', 'Night Two', 1))) || ' | ' || tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'x.pdf', 10)$q$, gen_random_uuid())), 'ERROR: this job is not running | ERROR: this job is not running');
  perform tests.logout();
  update public.site_report_auto set enabled = false where venue_id = venue_a;
  perform tests.assert_eq('a switch turned off after the job was queued starts no delivery', tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'club-a-night.pdf', 1234)$q$, j1)), 'ERROR: automatic sending was switched off');
  perform tests.logout();
  update public.site_report_auto set enabled = true where venue_id = venue_a;
  perform tests.assert_eq('a signed-in person cannot begin a delivery this way', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select count(*)::text from public.report_job_begin(%L, 'club-a-night.pdf', 1234)$q$, j1)), 'ERROR: permission denied for function report_job_begin');
  -- an organizer's report: its event, its list
  perform tests.assert_eq('the organizer''s event report goes to the organizer''s own list only, with the event''s name', tests.svc(format($q$select string_agg(b.email || ' ' || b.org_name || ' ' || coalesce(b.venue_name, '-') || ' ' || b.event_title, ' | ') from public.report_job_begin(%L, 'night-one-sales.pdf', 900) b$q$, je)), 'org@ar.example Night Events - Night One');
  perform tests.assert_eq('the owner''s combined report goes to the owner''s list only', tests.svc(format($q$select string_agg(b.email || ' ' || b.org_name || ' ' || coalesce(b.venue_name, '-'), ' | ') from public.report_job_begin(%L, 'all-clubs.pdf', 900) b$q$, jo)), 'owner@ar.example Club Co -');
  -- an empty list
  perform tests.logout();
  update public.site_report_jobs set status = 'running', finished_at = null where id = tests.jobid('venue_night', 'Club B', 1);
  perform tests.logout();
  delete from public.site_report_recipients where venue_id = venue_b;
  perform tests.assert_eq('a club with nobody on its list: the button''s own sentence', tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'club-b.pdf', 100)$q$, tests.jobid('venue_night', 'Club B', 1))), 'ERROR: no one is set to receive this report: add an e-mail address first');
  -- the button's hourly limit applies to the person
  perform tests.logout();
  insert into public.site_report_deliveries (batch_id, org_id, venue_id, kind, report_ref, filename, email, status, bytes, sent_by, created_at, finished_at)
    select gen_random_uuid(), vorg, venue_a, 'venue_night', 'x' || g, 'x.pdf', 'z@ar.example', 'sent', 10, vmgr, now(), now() from generate_series(1, 10) g;
  perform tests.assert_eq('ten reports in the last hour by the same person: the eleventh waits (the job is told to try again later)', tests.svc(format($q$select count(*)::text from public.report_job_begin(%L, 'club-a-night.pdf', 1234)$q$, j1)), 'ERROR: too many reports sent this hour: try again later');
  perform tests.logout();
  delete from public.site_report_deliveries where report_ref like 'x%';

  ---------------------------------------------------------------- how a run ends
  perform tests.assert_eq('a bad outcome is refused', tests.svc(format($q$select public.report_job_finish(%L, 'done')$q$, j1)) || ' | ' || tests.svc(format($q$select public.report_job_finish(%L, null)$q$, j1)), 'ERROR: say how the run went | ERROR: say how the run went');
  perform tests.assert_eq('sent (whatever error text came with it is not kept)', tests.svc(format($q$select public.report_job_finish(%L, 'sent', 'oops')$q$, j1)) || ' ' || tests.q(format($q$select status || ' ' || coalesce(last_error, 'no error') || ' ' || (finished_at is not null)::text from public.site_report_jobs where id = %L$q$, j1)), 'sent sent no error true');
  perform tests.assert_eq('a finished job cannot be finished again', tests.svc(format($q$select public.report_job_finish(%L, 'failed', 'again')$q$, j1)), 'ERROR: this job is not running');
  perform tests.assert_eq('skipped, with the reason', tests.svc(format($q$select public.report_job_finish(%L, 'skipped', ' No one is set to receive it. ')$q$, tests.jobid('venue_night', 'Club B', 1))) || ' ' || tests.q(format($q$select status || ' ' || last_error from public.site_report_jobs where id = %L$q$, tests.jobid('venue_night', 'Club B', 1))), 'skipped skipped No one is set to receive it.');
  perform tests.assert_eq('failed, with the reason, cut at 300 characters', tests.svc(format($q$select public.report_job_finish(%L, 'failed', %L)$q$, jo, repeat('e', 400))) || ' ' || tests.q(format($q$select length(last_error)::text from public.site_report_jobs where id = %L$q$, jo)), 'failed 300');
  -- retries: five minutes, fifteen, an hour, three hours, then it stops
  perform tests.logout();
  update public.site_report_jobs set status = 'running', finished_at = null, attempts = 1 where id = je;
  perform tests.assert_eq('the first failure waits 5 minutes and stays pending, with the reason', tests.svc(format($q$select public.report_job_finish(%L, 'retry', 'The report could not be built.')$q$, je)) || ' ' || tests.q(format($q$select status || ' ' || last_error || ' ' || round(extract(epoch from next_attempt_at - clock_timestamp()) / 60)::text || ' ' || coalesce(finished_at::text, 'not finished') from public.site_report_jobs where id = %L$q$, je)), 'pending pending The report could not be built. 5 not finished');
  perform tests.logout();
  update public.site_report_jobs set status = 'running', attempts = 2 where id = je;
  perform tests.assert_eq('the second waits 15', tests.svc(format($q$select public.report_job_finish(%L, 'retry', 'x')$q$, je)) || ' ' || tests.q(format($q$select round(extract(epoch from next_attempt_at - clock_timestamp()) / 60)::text from public.site_report_jobs where id = %L$q$, je)), 'pending 15');
  perform tests.logout();
  update public.site_report_jobs set status = 'running', attempts = 3 where id = je;
  perform tests.assert_eq('the third waits an hour', tests.svc(format($q$select public.report_job_finish(%L, 'retry', 'x')$q$, je)) || ' ' || tests.q(format($q$select round(extract(epoch from next_attempt_at - clock_timestamp()) / 60)::text from public.site_report_jobs where id = %L$q$, je)), 'pending 60');
  perform tests.logout();
  update public.site_report_jobs set status = 'running', attempts = 4 where id = je;
  perform tests.assert_eq('the fourth waits three hours', tests.svc(format($q$select public.report_job_finish(%L, 'retry', 'x')$q$, je)) || ' ' || tests.q(format($q$select round(extract(epoch from next_attempt_at - clock_timestamp()) / 60)::text from public.site_report_jobs where id = %L$q$, je)), 'pending 180');
  perform tests.logout();
  update public.site_report_jobs set status = 'running', attempts = 5 where id = je;
  perform tests.assert_eq('after the fifth try it stops, failed, with the reason', tests.svc(format($q$select public.report_job_finish(%L, 'retry', 'The e-mail provider is not configured.')$q$, je)) || ' ' || tests.q(format($q$select status || ' ' || last_error || ' ' || (finished_at is not null)::text from public.site_report_jobs where id = %L$q$, je)), 'failed failed The e-mail provider is not configured. true');
  perform tests.assert_eq('a signed-in person cannot say how a run went', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select public.report_job_finish(%L, 'sent')$q$, j1)), 'ERROR: permission denied for function report_job_finish');
  perform tests.assert_eq('a job that failed at the first try and is retried is taken again when due', (select tests.svc('select count(*)::text from public.report_job_claim(5)')), '0');

  ---------------------------------------------------------------- what the status says afterwards
  perform tests.assert_eq('the club''s status shows the latest automatic send (the newest job for that club): which night, how it ended', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select (select s.last_status || ' ' || s.last_ref from public.report_auto_status('venue_night', %L, %L) s)$q$, vorg, venue_a)),
    'running ' || n1::text);
  perform tests.logout();
  update public.site_report_jobs set status = 'failed', last_error = 'The person who switched it on no longer has access.', finished_at = clock_timestamp() where id = (select j.id from public.site_report_jobs j where j.kind = 'venue_night' and j.venue_id = venue_a order by j.created_at desc, j.id limit 1);
  perform tests.assert_eq('...and why, when it failed', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select (select s.last_status || ' / ' || s.last_error from public.report_auto_status('venue_night', %L, %L) s)$q$, vorg, venue_a)), 'failed / The person who switched it on no longer has access.');
  perform tests.assert_eq('another club''s status is its own job''s: Club B''s was skipped', tests.run_as(vowner, 'vowner@ar.example', format($q$select (select s.last_status || ' ' || s.last_ref || ' ' || s.last_error from public.report_auto_status('venue_night', %L, %L) s)$q$, vorg, venue_b)), 'skipped ' || n1::text || ' No one is set to receive it.');
  perform tests.assert_eq('the owner''s status and the organizer''s are their own', tests.run_as(vowner, 'vowner@ar.example', format($q$select (select s.last_status from public.report_auto_status('owner_combined', %L) s)$q$, vorg)) || ' ' || tests.run_as(oorg, 'org@ar.example', format($q$select (select s.last_status from public.report_auto_status('organizer_sales', %L) s)$q$, oorg_id)), 'failed failed');

  ---------------------------------------------------------------- a club that is reopened holds the combined and the event reports back, and a switch that is off queues nothing
  perform tests.logout();
  perform tests.run_as(vowner, 'vowner@ar.example', format($q$select public.reopen_night(%L, %L, 'Reopening a night closed with the switch off')::text$q$, venue_a, current_date - 3));
  perform tests.assert_eq('a night that is reopened is not queued, even when it is asked for directly (the switch is on, no report for it exists yet)', tests.q(format($q$select public.report_jobs_enqueue(%L, %L)::text$q$, venue_a, current_date - 3)), '0');
  perform tests.assert_eq('Club B reopens Night One (the owner reopens it)', tests.run_as(vowner, 'vowner@ar.example', format($q$select public.reopen_night(%L, %L, 'Reopening to correct a count')::text$q$, venue_b, n1)) not like 'ERROR%', true);
  perform tests.run_as(vowner, 'vowner@ar.example', format($q$select public.reopen_night(%L, %L, 'Reopening to correct a count')::text$q$, venue_a, n1));
  cnt_before := tests.njobs();
  perform tests.close(vmgr, 'vmgr@ar.example', venue_a, n1);
  perform tests.run_as(vowner, 'vowner@ar.example', format($q$select public.reopen_night(%L, %L, 'Reopening to correct a count again')::text$q$, venue_a, n1));
  perform tests.close(vmgr, 'vmgr@ar.example', venue_a, n1);
  perform tests.assert_eq('with Club B still reopened, Club A''s two closes queue only Club A''s own report (twice: new revisions), not the owner''s combined report and not event One''s', tests.njobs() - cnt_before, 2);
  perform tests.assert_eq('...they are Club A''s, revisions 3 and 4', tests.q(format($q$select string_agg(j.revision::text, ',' order by j.revision) from public.site_report_jobs j where j.kind = 'venue_night' and j.venue_id = %L and j.report_ref = %L and j.revision > 2$q$, venue_a, n1::text)), '3,4');
  perform tests.assert_eq('Club B closes it again: now every club has closed, so the owner''s combined report and event One''s are queued (revision 6: Club A four closes, Club B two)', tests.close(vmgr_b, 'vmgrb@ar.example', venue_b, n1) not like 'ERROR%'
    and tests.q($q$select string_agg(j.kind || ':' || j.revision, ',' order by j.kind) from public.site_report_jobs j where j.revision = 6$q$) = 'organizer_sales:6,owner_combined:6', true);
  -- a night that both clubs close with the owner's switch off
  perform tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('owner_combined', %L, null, false)::text$q$, vorg));
  perform tests.assert_eq('with the owner''s switch off, Club B closing the night Club A closed earlier queues Club B''s own report and not the combined one', tests.close(vmgr_b, 'vmgrb@ar.example', venue_b, current_date - 1) not like 'ERROR%'
    and tests.q(format($q$select string_agg(j.kind, ',' order by j.kind) from public.site_report_jobs j where j.report_ref = %L$q$, (current_date - 1)::text)) = 'venue_night', true);
  perform tests.run_as(vowner, 'vowner@ar.example', format($q$select public.report_auto_set('owner_combined', %L, null, true)::text$q$, vorg));
  perform tests.assert_eq('switched on again and asked again, the combined report for that night is queued', tests.q(format($q$select public.report_jobs_enqueue(%L, %L)::text$q$, venue_b, current_date - 1)), '1');

  ---------------------------------------------------------------- the tables are closed, the functions are what they say
  perform tests.logout();
  perform tests.login(vmgr, 'vmgr@ar.example');
  perform tests.assert_raises('a signed-in person cannot read the switches', 'select * from public.site_report_auto', 'permission denied');
  perform tests.assert_raises('...nor the jobs', 'select * from public.site_report_jobs', 'permission denied');
  perform tests.assert_raises('...nor write a job', format($q$insert into public.site_report_jobs (kind, org_id, venue_id, report_ref, revision, run_as) values ('venue_night', %L, %L, 'x', 1, %L)$q$, vorg, venue_a, vmgr), 'permission denied');
  perform tests.assert_raises('...nor switch one on directly', format($q$insert into public.site_report_auto (org_id, venue_id, kind, enabled, enabled_by) values (%L, %L, 'venue_night', true, %L)$q$, vorg, venue_b, vmgr), 'permission denied');
  perform tests.assert_raises('...nor queue reports', format($q$select public.report_jobs_enqueue(%L, current_date)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...nor call the trigger''s function', 'select public.report_jobs_on_close()', 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the jobs', 'select * from public.site_report_jobs', 'permission denied');
  perform tests.logout();
  perform tests.assert_true('the database refuses a job that is not the right shape (a club report with no club, an event report with no event)',
    (select count(*) = 1 from pg_constraint c where c.conrelid = 'public.site_report_jobs'::regclass and c.conname = 'site_report_jobs_shape'));
  perform tests.assert_raises('...a club report with no club', format($q$insert into public.site_report_jobs (kind, org_id, report_ref, revision) values ('venue_night', %L, 'x', 1)$q$, vorg), 'site_report_jobs_shape');
  perform tests.assert_raises('...an event report with no event', format($q$insert into public.site_report_jobs (kind, org_id, report_ref, revision) values ('organizer_sales', %L, 'x', 1)$q$, oorg_id), 'site_report_jobs_shape');
  perform tests.assert_raises('...a finished job with no finish time', format($q$update public.site_report_jobs set status = 'sent', finished_at = null where id = %L$q$, tests.jobid('organizer_sales', 'Night Two', 1)), 'site_report_jobs_finished_together');
  perform tests.assert_raises('...a state that does not exist', format($q$update public.site_report_jobs set status = 'lost', finished_at = null where id = %L$q$, tests.jobid('organizer_sales', 'Night Two', 1)), 'site_report_jobs_status_check');
  perform tests.assert_raises('...an error longer than 300 characters', format($q$update public.site_report_jobs set last_error = %L where id = %L$q$, repeat('e', 301), tests.jobid('organizer_sales', 'Night Two', 1)), 'site_report_jobs_last_error_check');
  perform tests.assert_raises('...more than five tries', format($q$update public.site_report_jobs set attempts = 6 where id = %L$q$, tests.jobid('organizer_sales', 'Night Two', 1)), 'site_report_jobs_attempts_check');
  perform tests.assert_raises('...a club''s switch with no club', format($q$insert into public.site_report_auto (org_id, kind, enabled, enabled_by) values (%L, 'venue_night', true, %L)$q$, vorg, vmgr), 'site_report_auto_check');
  perform tests.assert_raises('...the owner''s switch with a club', format($q$insert into public.site_report_auto (org_id, venue_id, kind, enabled, enabled_by) values (%L, %L, 'owner_combined', true, %L)$q$, vorg, venue_a, vmgr), 'site_report_auto_check');
  perform tests.assert_raises('...a second switch for the same club', format($q$insert into public.site_report_auto (org_id, venue_id, kind, enabled, enabled_by) values (%L, %L, 'venue_night', true, %L)$q$, vorg, venue_a, vmgr), 'site_report_auto_one');
  perform tests.assert_raises('...a second job for the same report and close', format($q$insert into public.site_report_jobs (kind, org_id, venue_id, report_ref, revision) values ('venue_night', %L, %L, %L, 1)$q$, vorg, venue_a, n1::text), 'site_report_jobs_once');
  perform tests.assert_true('every function runs with its owner''s rights and a fixed search path',
    (select count(*) = 10 and bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%') from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname in ('report_job_act_as', 'report_job_act_as_end', 'report_auto_set', 'report_auto_status', 'report_jobs_enqueue', 'report_jobs_on_close', 'report_job_claim', 'report_job_data', 'report_job_begin', 'report_job_finish')));
  perform tests.assert_true('signed-in people and the service role can use the switch and read its status; visitors cannot',
    (select count(*) = 2 and bool_and(not has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('service_role', p.oid, 'execute')) from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname in ('report_auto_set', 'report_auto_status')));
  perform tests.assert_true('only the service role can run the job functions',
    (select count(*) = 4 and bool_and(not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('service_role', p.oid, 'execute')) from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname in ('report_job_claim', 'report_job_data', 'report_job_begin', 'report_job_finish')));
  perform tests.assert_true('nobody can run the internal helpers: not a visitor, not a signed-in person, not even the service role',
    (select count(*) = 4 and bool_and(not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('service_role', p.oid, 'execute')) from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname in ('report_job_act_as', 'report_job_act_as_end', 'report_jobs_enqueue', 'report_jobs_on_close')));

  ---------------------------------------------------------------- the button still works as it did
  perform tests.assert_eq('the owner''s own e-mail button is unaffected: the list, the begin and the log', tests.run_as(vowner, 'vowner@ar.example', format($q$select (select count(*)::text from public.report_send_begin('venue_night', %L, %L, null, %L, 'club-b.pdf', 100))$q$, vorg, venue_b, (current_date - 1)::text)), 'ERROR: no one is set to receive this report: add an e-mail address first');
  perform tests.assert_eq('...and for a club with addresses', tests.run_as(vmgr, 'vmgr@ar.example', format($q$select (select count(*)::text from public.report_send_begin('venue_night', %L, %L, null, %L, 'club-a.pdf', 100))$q$, vorg, venue_a, (current_date - 1)::text)), '2');
end $$;

rollback;
