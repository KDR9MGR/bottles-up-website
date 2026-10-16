-- Security. What matters most: who may raise, take, resolve and escalate an alert is worked out from the person's CURRENT role at THAT club
-- (a server only raises, and sees only what they raised; security, the manager and the owner work the alerts; nobody at another club, no
-- verifier and no stranger can touch them); every step happens once even if two people press at once and a repeat changes nothing; tasks are
-- given by a manager to a member of security and finished by them; an incident report is RETAINED (it cannot be edited, deleted or orphaned,
-- later facts are added as notes, and nobody reviews their own); and security can see nothing about money.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
-- Runs one statement that returns a single value as this person; the answer as text, or 'ERROR: <what the database said>'.
create function tests.run_as(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.alerts_as(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(kind || ':' || status || ':' || case when urgent then 'U' else '-' end || ':' || raised_by_name || ':' || case when can_act then 'act' else 'view' end, ' | ' order by (status = 'resolved'), urgent desc, raised_at desc, alert_id)
                   from public.security_alerts(p_venue, p_night)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.tasks_as(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(title || ':' || status || ':' || coalesce(assigned_to_name, 'anyone') || case when can_manage then ':mgr' else '' end, ' | ' order by (status <> 'open'), created_at desc, task_id)
                   from public.security_tasks(p_venue, p_night)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.incidents_as(p_user uuid, p_email text, p_venue uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(kind || ':' || status || ':' || reported_by_name || ':' || note_count || case when can_review then ':review' else '' end, ' | ' order by created_at desc, incident_id desc)
                   from public.security_incidents(p_venue)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000004d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000004d2';
  sec_1 constant uuid := '00000000-0000-0000-0000-0000000004d3';
  sec_2 constant uuid := '00000000-0000-0000-0000-0000000004d4';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000004d5';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000004d6';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000004d7';
  sec_b constant uuid := '00000000-0000-0000-0000-0000000004d8';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000004d9';
  rando constant uuid := '00000000-0000-0000-0000-0000000004da';
  night date := current_date;
  org uuid; venue_a uuid; venue_b uuid;
  r text; a1 uuid; a2 uuid; a3 uuid; a4 uuid; t1 uuid; t2 uuid; t3 uuid; i1 uuid; i2 uuid; n int; d jsonb;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@sec.example'), (mgr_a, 'mgra@sec.example'), (sec_1, 'sec1@sec.example'), (sec_2, 'sec2@sec.example'), (srv_1, 'srv1@sec.example'),
    (srv_2, 'srv2@sec.example'), (ver_a, 'vera@sec.example'), (sec_b, 'secb@sec.example'), (mgr_b, 'mgrb@sec.example'), (rando, 'rando@sec.example');
  insert into public.profiles (id, name, email) values
    (owner_u, 'Olly Owner', 'owner@sec.example'), (mgr_a, 'Mia Manager', 'mgra@sec.example'), (sec_1, 'Sid Security', 'sec1@sec.example'),
    (sec_2, 'Sue Security', 'sec2@sec.example'), (srv_1, 'Sam Server', 'srv1@sec.example'), (srv_2, 'Bea Server', 'srv2@sec.example'),
    (ver_a, 'Vera Verifier', 'vera@sec.example'), (mgr_b, 'Max Manager', 'mgrb@sec.example');

  perform tests.login(owner_u, 'owner@sec.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@sec.example', org, 'mgra@sec.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@sec.example', org, 'mgrb@sec.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@sec.example', org, 'sec1@sec.example', 'security', venue_a, sec_1);
  perform tests.join_as(mgr_a, 'mgra@sec.example', org, 'sec2@sec.example', 'security', venue_a, sec_2);
  perform tests.join_as(mgr_a, 'mgra@sec.example', org, 'srv1@sec.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@sec.example', org, 'srv2@sec.example', 'server', venue_a, srv_2);
  perform tests.join_as(mgr_a, 'mgra@sec.example', org, 'vera@sec.example', 'verifier', venue_a, ver_a);
  perform tests.join_as(mgr_b, 'mgrb@sec.example', org, 'secb@sec.example', 'security', venue_b, sec_b);
  perform tests.logout();

  ---------------------------------------------------------------- raising an alert
  r := tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'fight', true, 'Terrace, near the bar', 'two men shouting')::text$q$, venue_a, night));
  perform tests.assert_true('a server raises an alert', r not like 'ERROR%');
  a1 := r::uuid;
  perform tests.assert_true('security raises one', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'medical', false, 'Dance floor')::text$q$, venue_a, night)) not like 'ERROR%');
  a2 := tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_raise_alert(%L, %L, 'crowd', false, 'Main door', 'queue is blocking the pavement')::text$q$, venue_a, night))::uuid;
  perform tests.assert_true('the owner raises one', tests.run_as(owner_u, 'owner@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Car park')::text$q$, venue_a, night)) not like 'ERROR%');
  perform tests.assert_eq('a verifier cannot raise one', tests.run_as(ver_a, 'vera@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Bar')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot raise one here', tests.run_as(mgr_b, 'mgrb@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Bar')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.run_as(rando, 'rando@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Bar')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('no club is not allowed', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(null, %L, 'other', false, 'Bar')::text$q$, night)), 'ERROR: not allowed');
  perform tests.assert_eq('no night', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, null, 'other', false, 'Bar')::text$q$, venue_a)), 'ERROR: choose a night');
  perform tests.assert_eq('a night long ago', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Bar')::text$q$, venue_a, night - 30)), 'ERROR: that is not a current night');
  perform tests.assert_eq('a kind that does not exist', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'party', false, 'Bar')::text$q$, venue_a, night)), 'ERROR: choose what kind of alert this is');
  perform tests.assert_eq('no kind', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, null, false, 'Bar')::text$q$, venue_a, night)), 'ERROR: choose what kind of alert this is');
  perform tests.assert_eq('no location', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, ' ')::text$q$, venue_a, night)), 'ERROR: say where it is');
  perform tests.assert_eq('a one-letter location', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'x')::text$q$, venue_a, night)), 'ERROR: say where it is');
  perform tests.assert_eq('a very long location', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, %L)::text$q$, venue_a, night, repeat('x', 201))), 'ERROR: keep the location to 200 characters or fewer');
  perform tests.assert_eq('very long details', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Bar', %L)::text$q$, venue_a, night, repeat('x', 1001))), 'ERROR: keep the details to 1000 characters or fewer');

  ---------------------------------------------------------------- who sees which alerts
  perform tests.assert_eq('security sees all four, the urgent one first, and can act', tests.alerts_as(sec_1, 'sec1@sec.example', venue_a, night),
    'fight:open:U:Sam Server:act | other:open:-:Olly Owner:act | crowd:open:-:Mia Manager:act | medical:open:-:Sid Security:act');
  perform tests.assert_eq('the manager and the owner see the same', tests.alerts_as(mgr_a, 'mgra@sec.example', venue_a, night) = tests.alerts_as(owner_u, 'owner@sec.example', venue_a, night), true);
  perform tests.assert_eq('a server sees only their own, and cannot act', tests.alerts_as(srv_1, 'srv1@sec.example', venue_a, night), 'fight:open:U:Sam Server:view');
  perform tests.assert_eq('...another server sees none of it', tests.alerts_as(srv_2, 'srv2@sec.example', venue_a, night), '(none)');
  perform tests.assert_eq('a verifier cannot list', tests.alerts_as(ver_a, 'vera@sec.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('security of another club cannot', tests.alerts_as(sec_b, 'secb@sec.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('...and sees nothing of Club A at Club B', tests.alerts_as(sec_b, 'secb@sec.example', venue_b, night), '(none)');
  perform tests.assert_eq('another night is empty', tests.alerts_as(sec_1, 'sec1@sec.example', venue_a, night - 1), '(none)');
  perform tests.assert_eq('a stranger cannot list', tests.alerts_as(rando, 'rando@sec.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('a night must be chosen', tests.run_as(sec_1, 'sec1@sec.example', format($q$select count(*)::text from public.security_alerts(%L, null)$q$, venue_a)), 'ERROR: choose a night');

  ---------------------------------------------------------------- taking an alert
  perform tests.assert_eq('a server cannot take one', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, a1)), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier cannot', tests.run_as(ver_a, 'vera@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, a1)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s security cannot', tests.run_as(sec_b, 'secb@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, a1)), 'ERROR: not allowed');
  perform tests.assert_eq('an alert that does not exist', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, gen_random_uuid())), 'ERROR: not allowed');
  perform tests.assert_eq('something that is not a step', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'delete')::text$q$, a1)), 'ERROR: choose what to do with this alert');
  perform tests.assert_eq('no step', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, null)::text$q$, a1)), 'ERROR: choose what to do with this alert');
  perform tests.assert_eq('a long note', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge', %L)::text$q$, a1, repeat('x', 501))), 'ERROR: keep the note to 500 characters or fewer');
  perform tests.assert_eq('respond or resolve before taking it', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'respond')::text$q$, a1)) || ' / ' || tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'resolve', 'done')::text$q$, a1)),
    'ERROR: take the alert first / ERROR: take the alert first');
  perform tests.assert_eq('security takes it', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, a1)), '{"status": "acknowledged", "changed": true}');
  perform tests.assert_eq('the same person tapping again changes nothing', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, a1)), '{"status": "acknowledged", "by_name": "Sid Security", "changed": false}');
  perform tests.assert_eq('someone else is told who has it', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, a1)), '{"status": "acknowledged", "by_name": "Sid Security", "changed": false}');
  perform tests.assert_eq('it shows as taken, by whom', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select acknowledged_by_name || ':' || status from public.security_alerts(%L, %L) where alert_id = %L$q$, venue_a, night, a1)), 'Sid Security:acknowledged');

  perform tests.assert_eq('responding', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'respond')::text$q$, a1)), '{"status": "responding", "changed": true}');
  perform tests.assert_eq('...twice changes nothing', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'respond')::text$q$, a1)), '{"status": "responding", "changed": false}');

  ---------------------------------------------------------------- resolving
  perform tests.assert_eq('only the one who took it, or a manager, resolves', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_alert_act(%L, 'resolve', 'sorted')::text$q$, a1)), 'ERROR: only the person who took this alert, or a manager, can resolve it');
  perform tests.assert_eq('resolving needs to say what was done', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'resolve')::text$q$, a1)) || ' / ' || tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'resolve', 'ok')::text$q$, a1)),
    'ERROR: say what was done / ERROR: say what was done');
  perform tests.assert_eq('the holder resolves it', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'resolve', 'Separated them, one left')::text$q$, a1)), '{"status": "resolved", "changed": true}');
  perform tests.assert_eq('a resolved alert is final', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'respond')::text$q$, a1)) || ' / ' || tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_alert_act(%L, 'resolve', 'again')::text$q$, a1)),
    'ERROR: this alert is already resolved / ERROR: this alert is already resolved');
  perform tests.assert_eq('...it sinks below the open ones, with who resolved it', tests.alerts_as(sec_1, 'sec1@sec.example', venue_a, night),
    'other:open:-:Olly Owner:act | crowd:open:-:Mia Manager:act | medical:open:-:Sid Security:act | fight:resolved:U:Sam Server:act');
  perform tests.assert_eq('the server who raised it sees it resolved', tests.alerts_as(srv_1, 'srv1@sec.example', venue_a, night), 'fight:resolved:U:Sam Server:view');
  perform tests.assert_eq('a manager resolves one someone else took', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, a2)) || ' ' || tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_alert_act(%L, 'resolve', 'Moved the queue inside')::text$q$, a2)),
    '{"status": "acknowledged", "changed": true} {"status": "resolved", "changed": true}');

  ---------------------------------------------------------------- escalating
  a3 := tests.run_as(srv_2, 'srv2@sec.example', format($q$select public.security_raise_alert(%L, %L, 'theft', true, 'Cloakroom', 'a bag is missing')::text$q$, venue_a, night))::uuid;
  perform tests.assert_eq('escalating needs a reason', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'escalate')::text$q$, a3)), 'ERROR: say why this needs a manager');
  perform tests.assert_eq('security escalates one nobody has taken yet', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'escalate', 'Police may be needed')::text$q$, a3)), '{"status": "escalated", "changed": true}');
  perform tests.assert_eq('...again changes nothing', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_alert_act(%L, 'escalate', 'again please')::text$q$, a3)), '{"status": "escalated", "changed": false}');
  perform tests.assert_eq('taking an escalated alert says who escalated it', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, a3)), '{"status": "escalated", "by_name": "Sid Security", "changed": false}');
  perform tests.assert_eq('nobody responds to an escalated one', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'respond')::text$q$, a3)), 'ERROR: this alert was escalated to a manager');
  perform tests.assert_eq('security does not resolve an escalated alert', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_alert_act(%L, 'resolve', 'handled it')::text$q$, a3)), 'ERROR: this alert was escalated: a manager resolves it');
  perform tests.assert_eq('the manager sees it as escalated, with the reason shown', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select status || ':' || escalated_by_name || ':' || escalation_note from public.security_alerts(%L, %L) where alert_id = %L$q$, venue_a, night, a3)), 'escalated:Sid Security:Police may be needed');
  perform tests.assert_eq('the manager resolves it', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_alert_act(%L, 'resolve', 'Spoke to the guest, bag found')::text$q$, a3)), '{"status": "resolved", "changed": true}');
  a4 := tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'intoxicated', false, 'VIP booth 3')::text$q$, venue_a, night))::uuid;
  perform tests.assert_eq('a taken alert can be escalated by the holder', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_alert_act(%L, 'acknowledge')::text$q$, a4)) || ' ' || tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_alert_act(%L, 'escalate', 'Guest is refusing to leave')::text$q$, a4)),
    '{"status": "acknowledged", "changed": true} {"status": "escalated", "changed": true}');

  ---------------------------------------------------------------- raising too many
  perform tests.logout();
  delete from public.site_security_alerts where raised_by = srv_2;
  for n in 1..10 loop
    perform tests.run_as(srv_2, 'srv2@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Bar %s')::text$q$, venue_a, night, n));
  end loop;
  perform tests.assert_eq('the 11th alert in ten minutes is slowed', tests.run_as(srv_2, 'srv2@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Bar')::text$q$, venue_a, night)), 'ERROR: slow down: you have raised several alerts in the last few minutes');
  perform tests.assert_true('...and someone else is not slowed by it', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Bar')::text$q$, venue_a, night)) not like 'ERROR%');

  ---------------------------------------------------------------- tasks
  r := tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_create_task(%L, %L, 'Check the fire exits', 'Both side doors', %L)::text$q$, venue_a, night, sec_1));
  perform tests.assert_true('a manager gives a task to a member of security', r not like 'ERROR%');
  t1 := r::uuid;
  t2 := tests.run_as(owner_u, 'owner@sec.example', format($q$select public.security_create_task(%L, %L, 'Walk the car park at 2am')::text$q$, venue_a, night))::uuid;
  perform tests.assert_eq('a task cannot go to a server', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_create_task(%L, %L, 'Watch the bar', null, %L)::text$q$, venue_a, night, srv_1)), 'ERROR: a task can only be given to someone on the security team of this club');
  perform tests.assert_eq('...nor to security of another club', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_create_task(%L, %L, 'Watch the bar', null, %L)::text$q$, venue_a, night, sec_b)), 'ERROR: a task can only be given to someone on the security team of this club');
  perform tests.assert_eq('security cannot give tasks', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_create_task(%L, %L, 'Watch the bar')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a server', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_create_task(%L, %L, 'Watch the bar')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s manager', tests.run_as(mgr_b, 'mgrb@sec.example', format($q$select public.security_create_task(%L, %L, 'Watch the bar')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('a task needs a title', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_create_task(%L, %L, 'x')::text$q$, venue_a, night)), 'ERROR: say what the task is');
  perform tests.assert_eq('...a short one', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_create_task(%L, %L, %L)::text$q$, venue_a, night, repeat('x', 121))), 'ERROR: keep the title to 120 characters or fewer');
  perform tests.assert_eq('...and short details', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_create_task(%L, %L, 'Check', %L)::text$q$, venue_a, night, repeat('x', 501))), 'ERROR: keep the details to 500 characters or fewer');
  perform tests.assert_eq('a current night', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_create_task(%L, %L, 'Check it')::text$q$, venue_a, night + 9)), 'ERROR: that is not a current night');

  perform tests.assert_eq('the manager sees both tasks', tests.tasks_as(mgr_a, 'mgra@sec.example', venue_a, night), 'Walk the car park at 2am:open:anyone:mgr | Check the fire exits:open:Sid Security:mgr');
  perform tests.assert_eq('the person it was given to sees theirs and the open one', tests.tasks_as(sec_1, 'sec1@sec.example', venue_a, night), 'Walk the car park at 2am:open:anyone | Check the fire exits:open:Sid Security');
  perform tests.assert_eq('another security member sees only the open one', tests.tasks_as(sec_2, 'sec2@sec.example', venue_a, night), 'Walk the car park at 2am:open:anyone');
  perform tests.assert_eq('a server cannot list tasks', tests.tasks_as(srv_1, 'srv1@sec.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s security', tests.tasks_as(sec_b, 'secb@sec.example', venue_a, night), 'ERROR: not allowed');

  perform tests.assert_eq('security takes the open task', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_task_act(%L, 'claim')::text$q$, t2)), '{"status": "open", "changed": true}');
  perform tests.assert_eq('...taking it again changes nothing', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_task_act(%L, 'claim')::text$q$, t2)), '{"status": "open", "changed": false}');
  perform tests.assert_eq('someone else cannot touch it now', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_task_act(%L, 'claim')::text$q$, t2)) || ' / ' || tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_task_act(%L, 'done')::text$q$, t2)), 'ERROR: not allowed / ERROR: not allowed');
  perform tests.assert_eq('a task already given to someone cannot be taken by another', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_task_act(%L, 'claim')::text$q$, t1)), 'ERROR: this task is already given to someone');
  t3 := tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_create_task(%L, %L, 'Lock the cellar')::text$q$, venue_a, night))::uuid;
  perform tests.assert_eq('...nor an unassigned one', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_task_act(%L, 'claim')::text$q$, t3)), 'ERROR: only the security team takes tasks');
  perform tests.assert_eq('a task is finished by its person', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_task_act(%L, 'done', 'Both clear')::text$q$, t1)), '{"status": "done", "changed": true}');
  perform tests.assert_eq('...finishing again changes nothing', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_task_act(%L, 'done')::text$q$, t1)), '{"status": "done", "changed": false}');
  perform tests.assert_eq('finishing an open one nobody has takes it for oneself', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_task_act(%L, 'done')::text$q$, t3)) || ' ' || tests.tasks_as(mgr_a, 'mgra@sec.example', venue_a, night),
    '{"status": "done", "changed": true} Walk the car park at 2am:open:Sue Security:mgr | Lock the cellar:done:Sid Security:mgr | Check the fire exits:done:Sid Security:mgr');
  perform tests.assert_eq('security cannot cancel', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_task_act(%L, 'cancel')::text$q$, t2)), 'ERROR: only a manager or the owner cancels a task');
  perform tests.assert_eq('a manager cancels', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_task_act(%L, 'cancel', 'Not needed tonight')::text$q$, t2)), '{"status": "cancelled", "changed": true}');
  perform tests.assert_eq('...and a cancelled task cannot then be finished', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_task_act(%L, 'done')::text$q$, t2)), '{"status": "cancelled", "changed": false}');
  perform tests.assert_eq('a step that does not exist', tests.run_as(sec_2, 'sec2@sec.example', format($q$select public.security_task_act(%L, 'snooze')::text$q$, t1)), 'ERROR: choose what to do with this task');
  perform tests.assert_eq('a server cannot act on tasks', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_task_act(%L, 'done')::text$q$, t1)), 'ERROR: not allowed');
  perform tests.assert_eq('a task that does not exist', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_task_act(%L, 'done')::text$q$, gen_random_uuid())), 'ERROR: not allowed');

  ---------------------------------------------------------------- incidents
  r := tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now() - interval '20 minutes', 'Terrace', 'Two guests fought near the bar; one had a cut lip.', 'Separated them, first aid given')::text$q$, venue_a, night));
  perform tests.assert_true('security reports an incident', r not like 'ERROR%');
  i1 := r::uuid;
  i2 := tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_report_incident(%L, %L, 'property', now() - interval '1 hour', 'Cloakroom', 'A coat rail was broken by a crowd at closing.')::text$q$, venue_a, night))::uuid;
  perform tests.assert_eq('a server cannot report one', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now(), 'Bar', 'Something happened at the bar tonight.')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a verifier', tests.run_as(ver_a, 'vera@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now(), 'Bar', 'Something happened at the bar tonight.')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor security of another club', tests.run_as(sec_b, 'secb@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now(), 'Bar', 'Something happened at the bar tonight.')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('a kind that does not exist', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_report_incident(%L, %L, 'riot', now(), 'Bar', 'Something happened at the bar tonight.')::text$q$, venue_a, night)), 'ERROR: choose what kind of incident this is');
  perform tests.assert_eq('it must say when', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', null, 'Bar', 'Something happened at the bar tonight.')::text$q$, venue_a, night)), 'ERROR: say when it happened');
  perform tests.assert_eq('...not in the future', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now() + interval '1 hour', 'Bar', 'Something happened at the bar tonight.')::text$q$, venue_a, night)), 'ERROR: an incident cannot have happened in the future');
  perform tests.assert_eq('...nor long ago', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now() - interval '4 days', 'Bar', 'Something happened at the bar tonight.')::text$q$, venue_a, night)), 'ERROR: an incident more than 3 days old cannot be reported here');
  perform tests.assert_eq('it must say where', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now(), '', 'Something happened at the bar tonight.')::text$q$, venue_a, night)), 'ERROR: say where it happened');
  perform tests.assert_eq('...and describe it', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now(), 'Bar', 'short')::text$q$, venue_a, night)), 'ERROR: describe what happened (at least 10 characters)');
  perform tests.assert_eq('...but not at endless length', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now(), 'Bar', %L)::text$q$, venue_a, night, repeat('x', 2001))), 'ERROR: keep the details to 2000 characters or fewer');
  perform tests.assert_eq('what was done is limited too', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_report_incident(%L, %L, 'fight', now(), 'Bar', 'Something happened at the bar tonight.', %L)::text$q$, venue_a, night, repeat('x', 1001))), 'ERROR: keep what was done to 1000 characters or fewer');

  perform tests.assert_eq('security sees both reports and cannot review', tests.incidents_as(sec_1, 'sec1@sec.example', venue_a), 'property:submitted:Mia Manager:0 | fight:submitted:Sid Security:0');
  perform tests.assert_eq('the manager can review the one they did not write', tests.incidents_as(mgr_a, 'mgra@sec.example', venue_a), 'property:submitted:Mia Manager:0 | fight:submitted:Sid Security:0:review');
  perform tests.assert_eq('a server cannot list them', tests.incidents_as(srv_1, 'srv1@sec.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s security', tests.incidents_as(sec_b, 'secb@sec.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('paging: one at a time', tests.run_as(sec_1, 'sec1@sec.example', format($q$select count(*)::text from public.security_incidents(%L, 1)$q$, venue_a)), '1');

  perform tests.assert_true('a note is added by security', tests.run_as(sec_1, 'sec1@sec.example', format($q$select (public.security_incident_note(%L, 'Ambulance was not needed'))::text$q$, i1)) not like 'ERROR%');
  perform tests.assert_true('...and by the manager', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select (public.security_incident_note(%L, 'Spoke to both guests, they will not return tonight'))::text$q$, i1)) not like 'ERROR%');
  perform tests.assert_eq('an empty note', tests.run_as(sec_1, 'sec1@sec.example', format($q$select (public.security_incident_note(%L, '  '))::text$q$, i1)), 'ERROR: write the note first');
  perform tests.assert_eq('a long note', tests.run_as(sec_1, 'sec1@sec.example', format($q$select (public.security_incident_note(%L, %L))::text$q$, i1, repeat('x', 1001))), 'ERROR: keep a note to 1000 characters or fewer');
  perform tests.assert_eq('a server cannot add one', tests.run_as(srv_1, 'srv1@sec.example', format($q$select (public.security_incident_note(%L, 'I saw it'))::text$q$, i1)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s security', tests.run_as(sec_b, 'secb@sec.example', format($q$select (public.security_incident_note(%L, 'I saw it'))::text$q$, i1)), 'ERROR: not allowed');
  perform tests.assert_eq('the report with its notes in order, no emails', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select (public.security_incident_detail(%L) -> 'notes' -> 0 ->> 'author_name') || ' / ' || (public.security_incident_detail(%L) -> 'notes' -> 1 ->> 'author_name') || ' / ' || (public.security_incident_detail(%L) ->> 'kind')$q$, i1, i1, i1)),
    'Sid Security / Mia Manager / fight');
  perform tests.assert_eq('a stranger cannot read a report', tests.run_as(rando, 'rando@sec.example', format($q$select public.security_incident_detail(%L)::text$q$, i1)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a server', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_incident_detail(%L)::text$q$, i1)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a report that does not exist', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_incident_detail(%L)::text$q$, gen_random_uuid())), 'ERROR: not allowed');
  perform tests.assert_eq('the list counts the notes', tests.incidents_as(sec_1, 'sec1@sec.example', venue_a), 'property:submitted:Mia Manager:0 | fight:submitted:Sid Security:2');

  perform tests.assert_eq('security cannot review', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_review_incident(%L)::text$q$, i2)), 'ERROR: not allowed');
  perform tests.assert_eq('a manager cannot review their own report', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_review_incident(%L)::text$q$, i2)), 'ERROR: you wrote this report, so someone else has to review it');
  perform tests.assert_eq('the owner reviews the manager''s report', tests.run_as(owner_u, 'owner@sec.example', format($q$select public.security_review_incident(%L, 'Coat rail replaced')::text$q$, i2)), '');
  perform tests.assert_eq('a report is reviewed once', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_review_incident(%L)::text$q$, i2)), 'ERROR: this report was already reviewed');
  perform tests.assert_eq('a long review note', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_review_incident(%L, %L)::text$q$, i1, repeat('x', 501))), 'ERROR: keep the note to 500 characters or fewer');
  perform tests.assert_eq('the manager reviews security''s report', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_review_incident(%L)::text$q$, i1)), '');
  perform tests.assert_eq('the list shows who reviewed', tests.run_as(sec_1, 'sec1@sec.example', format($q$select string_agg(status || ':' || coalesce(reviewed_by_name, '-'), ' | ' order by created_at desc, incident_id desc) from public.security_incidents(%L)$q$, venue_a)), 'reviewed:Olly Owner | reviewed:Mia Manager');

  ---------------------------------------------------------------- reports are kept
  perform tests.logout();
  perform tests.assert_raises('a club with incident reports cannot be deleted', format('delete from public.site_venues where id = %L', venue_a), 'violates foreign key constraint');
  perform tests.assert_raises('a report cannot be deleted while it has notes', format('delete from public.site_security_incidents where id = %L', i1), 'violates foreign key constraint');
  perform tests.login(sec_1, 'sec1@sec.example');
  perform tests.assert_raises('security cannot rewrite a report', format($q$update public.site_security_incidents set details = 'nothing happened' where id = %L$q$, i1), 'permission denied');
  perform tests.assert_raises('...or delete one', format('delete from public.site_security_incidents where id = %L', i1), 'permission denied');
  perform tests.assert_raises('...or edit a note', 'update public.site_security_incident_notes set body = ''x''', 'permission denied');
  perform tests.assert_raises('...or read the alerts directly', 'select * from public.site_security_alerts', 'permission denied');
  perform tests.assert_raises('...or the tasks', 'select * from public.site_security_tasks', 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the night at a glance
  d := tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_summary(%L, %L)::text$q$, venue_a, night))::jsonb;
  perform tests.assert_eq('summary: alerts not yet resolved', d ->> 'alerts_unresolved', '14');
  perform tests.assert_eq('summary: alerts nobody has taken', d ->> 'alerts_waiting', '13');
  perform tests.assert_eq('summary: urgent ones', d ->> 'alerts_urgent', '0');
  perform tests.assert_eq('summary: escalated ones', d ->> 'alerts_escalated', '1');
  perform tests.assert_eq('summary: open tasks', d ->> 'tasks_open', '0');
  perform tests.assert_eq('summary: reports still to review', d ->> 'incidents_to_review', '0');
  perform tests.assert_eq('security sees the same summary', tests.run_as(sec_1, 'sec1@sec.example', format($q$select public.security_summary(%L, %L)::text$q$, venue_a, night))::jsonb = d, true);
  perform tests.assert_eq('a server does not', tests.run_as(srv_1, 'srv1@sec.example', format($q$select public.security_summary(%L, %L)::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('a night must be chosen', tests.run_as(mgr_a, 'mgra@sec.example', format($q$select public.security_summary(%L, null)::text$q$, venue_a)), 'ERROR: choose a night');

  ---------------------------------------------------------------- security sees nothing about money
  perform tests.assert_eq('no cash position', tests.run_as(sec_1, 'sec1@sec.example', format($q$select count(*)::text from public.desk_cash_position(%L, %L)$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('no flagged payments', tests.run_as(sec_1, 'sec1@sec.example', format($q$select count(*)::text from public.desk_list_flags(%L)$q$, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('no handovers to receive', tests.run_as(sec_1, 'sec1@sec.example', format($q$select count(*)::text from public.desk_list_handovers(%L, %L)$q$, venue_a, night)), 'ERROR: not allowed');

  ---------------------------------------------------------------- the log
  perform tests.logout();
  perform tests.assert_true('every step is in the audit log, attributed',
    (select count(*) from public.audit_log where action like 'security.%' and actor_id is not null) >= 30);
  perform tests.assert_eq('...including who took an alert',
    (select count(*) from public.audit_log where action = 'security.alert_acknowledge' and actor_id = sec_1 and entity_id = a1::text)::int, 1);

  ---------------------------------------------------------------- closed to the outside
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot list alerts', format('select * from public.security_alerts(%L, %L)', venue_a, night), 'permission denied');
  perform tests.assert_raises('...or raise one', format($q$select public.security_raise_alert(%L, %L, 'other', false, 'Bar')$q$, venue_a, night), 'permission denied');
  perform tests.logout();
  perform tests.login(sec_1, 'sec1@sec.example');
  perform tests.assert_raises('the internal role check cannot be called', format($q$select public.security_has_role(%L, %L, 'security')$q$, sec_2, venue_a), 'permission denied');
  perform tests.logout();
end $$;

rollback;
