-- Adjustments after a settlement was paid (20261125100000_settlement_adjustments.sql; brief sections 25 and 26, scenario 23 "Refund after settlement: original records retained; refund and
-- settlement adjustment visible"). What matters: only a PAID settlement takes them, only the club's OWNER records, settles or waives, the manager can answer a question, the organizer can read,
-- acknowledge or question and nothing else; a refund or a chargeback is always a minus, the net amount owed never goes below zero, every step is in a history, and above all the ORIGINAL
-- settlement (its figures, its payment record, its history) is not changed by any of it. Record only: nothing here moves money.
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
-- a settlement taken all the way to PAID (the fixture; any refusal stops the test)
create function tests.pay(p_ag uuid, p_sales bigint, p_paid bigint, p_ref text, p_mgr uuid, p_mgr_email text, p_owner uuid, p_owner_email text, p_adj bigint default 0) returns uuid language plpgsql as $$
declare s text; r text;
begin
  s := tests.run_as(p_mgr, p_mgr_email, format($q$select public.settlement_save_sales(%L, %s, 'Closing report')::text$q$, p_ag, p_sales));
  if s like 'ERROR%' then raise exception 'fixture: %', s; end if;
  if p_adj <> 0 then
    r := tests.run_as(p_mgr, p_mgr_email, format($q$select public.settlement_adjust(%L, %s, 'Agreed tip share')::text$q$, s::uuid, p_adj));
    if r like 'ERROR%' then raise exception 'fixture: %', r; end if;
  end if;
  r := tests.run_as(p_mgr, p_mgr_email, format($q$select public.settlement_review(%L)$q$, s::uuid));
  if r like 'ERROR%' then raise exception 'fixture: %', r; end if;
  r := tests.run_as(p_owner, p_owner_email, format($q$select public.settlement_approve(%L)$q$, s::uuid));
  if r like 'ERROR%' then raise exception 'fixture: %', r; end if;
  r := tests.run_as(p_owner, p_owner_email, format($q$select public.settlement_record_payment(%L, %s, current_date, %L, 'Bank transfer')$q$, s::uuid, p_paid, p_ref));
  if r like 'ERROR%' then raise exception 'fixture: %', r; end if;
  return s::uuid;
end $$;
-- one value out of the adjustments payload
create function tests.aj(p_user uuid, p_email text, p_ag uuid, variadic p_path text[]) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce(public.settlement_adjustments(p_ag) #>> p_path, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
-- one value of one adjustment (looked up by its id)
create function tests.ij(p_user uuid, p_email text, p_ag uuid, p_id uuid, p_key text) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select i ->> p_key from jsonb_array_elements(public.settlement_adjustments(p_ag) -> 'items') i where i ->> 'id' = p_id::text), 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
-- what the caller can do about one adjustment, as a sorted list of the things that are true
create function tests.icn(p_user uuid, p_email text, p_ag uuid, p_id uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(k, ',' order by k) from jsonb_array_elements(public.settlement_adjustments(p_ag) -> 'items') i, jsonb_each_text(i -> 'can') as e(k, v)
                    where i ->> 'id' = p_id::text and v = 'true'), '(nothing)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
-- the figures at the top: paid / adjustments / net / still to the organizer / still to the club / count
create function tests.tot(p_user uuid, p_email text, p_ag uuid) returns text language plpgsql as $$
declare j jsonb;
begin
  perform tests.login(p_user, p_email);
  j := public.settlement_adjustments(p_ag);
  return (j ->> 'paid_amount_cents') || '/' || (j ->> 'adjustments_cents') || '/' || (j ->> 'net_cents') || '/' || (j ->> 'open_to_organizer_cents') || '/' || (j ->> 'open_to_club_cents') || '/' || (j ->> 'count');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.title_of(p_ag uuid) returns text language sql security definer as $$ select e.title from public.site_agreements a join public.site_events e on e.id = a.event_id where a.id = p_ag $$;
create function tests.flv(p_user uuid, p_email text, p_venue uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(tests.title_of(f.agreement_id) || ':' || f.adjustment_count || ':' || f.open_count || ':' || f.open_to_organizer_cents || ':' || f.open_to_club_cents, ' | ' order by tests.title_of(f.agreement_id))
                     from public.settlement_adjustment_flags_for_venue(p_venue) f), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.flo(p_user uuid, p_email text, p_org uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(tests.title_of(f.agreement_id) || ':' || f.adjustment_count || ':' || f.open_count || ':' || f.open_to_organizer_cents || ':' || f.open_to_club_cents, ' | ' order by tests.title_of(f.agreement_id))
                     from public.settlement_adjustment_flags_for_organizer(p_org) f), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.nlog() returns bigint language sql security definer as $$ select count(*) from public.site_settlement_log $$;
create function tests.first_adj(p_settlement uuid) returns uuid language sql security definer as $$
  select id from public.site_settlement_adjustments where settlement_id = p_settlement order by recorded_at, id limit 1 $$;
create function tests.alog(p_ag uuid) returns text language sql security definer as $$
  select coalesce(string_agg(l.side || ':' || l.action || ':' || coalesce(l.from_status, '-') || '>' || coalesce(l.to_status, '-'), ' | ' order by l.at, l.id), '(none)')
    from public.site_settlement_adjustment_log l join public.site_settlements s on s.id = l.settlement_id where s.agreement_id = p_ag $$;
-- the ORIGINAL settlement, as one fingerprint: the row, its history, and what the settlement screen reads
create function tests.original(p_ag uuid) returns text language sql security definer as $$
  select md5(coalesce((select to_jsonb(s)::text from public.site_settlements s where s.agreement_id = p_ag), '')
          || coalesce((select string_agg(to_jsonb(l)::text, ',' order by l.at, l.id) from public.site_settlement_log l join public.site_settlements s on s.id = l.settlement_id where s.agreement_id = p_ag), '')) $$;
create function tests.shown(p_user uuid, p_email text, p_ag uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return md5((public.settlement_detail(p_ag) -> 'settlement')::text || (public.settlement_detail(p_ag) -> 'log')::text || (public.settlement_detail(p_ag) -> 'terms')::text);
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  vowner constant uuid := '00000000-0000-0000-0000-0000000009f1';
  vmgr constant uuid := '00000000-0000-0000-0000-0000000009f2';
  vmgr_b constant uuid := '00000000-0000-0000-0000-0000000009f3';
  vsrv constant uuid := '00000000-0000-0000-0000-0000000009f4';
  oorg constant uuid := '00000000-0000-0000-0000-0000000009f5';
  ostaff constant uuid := '00000000-0000-0000-0000-0000000009f6';
  rival constant uuid := '00000000-0000-0000-0000-0000000009f7';
  rando constant uuid := '00000000-0000-0000-0000-0000000009f8';
  odoor constant uuid := '00000000-0000-0000-0000-0000000009fa';
  vowner2 constant uuid := '00000000-0000-0000-0000-0000000009f9';
  vorg uuid; vorg2 uuid; oorg_id uuid; rival_org uuid; venue_a uuid; venue_b uuid; venue_c uuid;
  ev1 uuid; ev2 uuid; ev3 uuid; ev4 uuid; ev5 uuid; ag1 uuid; ag2 uuid; ag3 uuid; ag4 uuid; ag5 uuid; s1 uuid; s2 uuid; s3 uuid; s4 uuid;
  a1 uuid; a2 uuid; a3 uuid; a4 uuid; a5 uuid; b1 uuid; r text; i int;
  fp_before text; shown_before text; shown_org_before text; log_rows_before bigint; payouts_before bigint; settlements_before bigint;
  terms1 constant text := '{"capacity":400,"ticket_ownership":"organizer","bar_percent":10,"threshold_cents":500000,"formula":"above_threshold","eligible_revenue":"bar sales net of tax","refunds":"deducted","taxes_tips_fees":"excluded","settlement_timing":"within 7 days"}';
begin
  insert into auth.users (id, email) values
    (vowner, 'vowner@sa.example'), (vmgr, 'vmgr@sa.example'), (vmgr_b, 'vmgrb@sa.example'), (vsrv, 'vsrv@sa.example'), (oorg, 'org@sa.example'), (ostaff, 'ostaff@sa.example'), (rival, 'rival@sa.example'),
    (rando, 'rando@sa.example'), (vowner2, 'vowner2@sa.example'), (odoor, 'odoor@sa.example');
  insert into public.profiles (id, name, email) values (vowner, 'Olly Owner', 'vowner@sa.example'), (vmgr, 'Mia Manager', 'vmgr@sa.example'), (oorg, 'Olive Organizer', 'org@sa.example'), (ostaff, 'Sam Staff', 'ostaff@sa.example'), (vowner2, 'Otto Other', 'vowner2@sa.example');

  perform tests.login(vowner, 'vowner@sa.example');
  vorg := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(vorg, 'Club A');
  venue_b := public.create_org_venue(vorg, 'Club B');
  perform tests.join_as(vowner, 'vowner@sa.example', vorg, 'vmgr@sa.example', 'manager', venue_a, vmgr);
  perform tests.join_as(vowner, 'vowner@sa.example', vorg, 'vmgrb@sa.example', 'manager', venue_b, vmgr_b);
  perform tests.join_as(vmgr, 'vmgr@sa.example', vorg, 'vsrv@sa.example', 'server', venue_a, vsrv);
  perform tests.login(vowner2, 'vowner2@sa.example');
  vorg2 := public.create_organization('Other Club Co', 'venue_owner');
  venue_c := public.create_org_venue(vorg2, 'Club C');
  perform tests.login(oorg, 'org@sa.example');
  oorg_id := public.create_organization('Night Events', 'organizer');
  perform tests.login(rival, 'rival@sa.example');
  rival_org := public.create_organization('Rival Events', 'organizer');
  perform tests.logout();
  insert into public.site_memberships (org_id, user_id, role) values (oorg_id, ostaff, 'organizer');
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night One', 'x', 'Somewhere', now() + interval '10 days', now() + interval '10 days 6 hours', 'draft', oorg_id) returning id into ev1;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Two', 'x', 'Somewhere', now() + interval '20 days', now() + interval '20 days 6 hours', 'draft', oorg_id) returning id into ev2;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Three', 'x', 'Somewhere', now() + interval '30 days', now() + interval '30 days 6 hours', 'draft', oorg_id) returning id into ev3;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Four', 'x', 'Somewhere', now() + interval '40 days', now() + interval '40 days 6 hours', 'draft', oorg_id) returning id into ev4;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Five', 'x', 'Somewhere', now() + interval '50 days', now() + interval '50 days 6 hours', 'draft', oorg_id) returning id into ev5;
  insert into public.site_memberships (org_id, user_id, role, event_id) values (oorg_id, odoor, 'door', ev1);

  -- five active agreements at 10 percent above 5000. Night One, Two and Three are taken all the way to PAID (paid 30000, 40500 (a share of 40000 and 500 agreed before payment) and 40000); Night Four is only estimated; Night Five has no settlement.
  ag1 := tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev1, venue_a))::uuid;
  ag2 := tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev2, venue_a))::uuid;
  ag3 := tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev3, venue_a))::uuid;
  ag4 := tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev4, venue_a))::uuid;
  ag5 := tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev5, venue_a))::uuid;
  perform tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'ten percent')::text$q$, ag1, terms1));
  perform tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'ten percent')::text$q$, ag2, terms1));
  perform tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'ten percent')::text$q$, ag3, terms1));
  perform tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'ten percent')::text$q$, ag4, terms1));
  perform tests.run_as(oorg, 'org@sa.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'ten percent')::text$q$, ag5, terms1));
  perform tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag1));
  perform tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag2));
  perform tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag3));
  perform tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag4));
  perform tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag5));
  s1 := tests.pay(ag1, 800000, 30000, 'TRF-1001', vmgr, 'vmgr@sa.example', vowner, 'vowner@sa.example');
  s2 := tests.pay(ag2, 900000, 40500, 'TRF-1002', vmgr, 'vmgr@sa.example', vowner, 'vowner@sa.example', 500);
  s3 := tests.pay(ag3, 900000, 40000, 'TRF-1003', vmgr, 'vmgr@sa.example', vowner, 'vowner@sa.example');
  s4 := tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report')::text$q$, ag4))::uuid;
  perform tests.logout();
  perform tests.assert_eq('the fixture is as the test needs it: three settlements paid, one estimated, one not started',
    (select string_agg(coalesce(s.status, '-'), ',' order by e.title) from public.site_agreements a join public.site_events e on e.id = a.event_id left join public.site_settlements s on s.agreement_id = a.id where a.id in (ag1, ag2, ag3, ag4, ag5)),
    '-,estimated,paid,paid,paid');
  select count(*) into payouts_before from public.site_payout_items;
  select count(*) into settlements_before from public.site_settlements;

  ---------------------------------------------------------------- reading before any adjustment
  perform tests.assert_eq('a paid settlement with no adjustments says so: it applies, there are none, the net is what was paid', tests.aj(vmgr, 'vmgr@sa.example', ag1, 'applies') || ' ' || tests.tot(vmgr, 'vmgr@sa.example', ag1), 'true 30000/0/30000/0/0/0');
  perform tests.assert_eq('...an empty list', tests.aj(vmgr, 'vmgr@sa.example', ag1, 'items'), '[]');
  perform tests.assert_eq('...in Canadian dollars, with the date it was paid', tests.aj(vmgr, 'vmgr@sa.example', ag1, 'currency') || ' ' || (tests.aj(vmgr, 'vmgr@sa.example', ag1, 'paid_on') = current_date::text)::text, 'cad true');
  perform tests.assert_eq('a settlement that is only estimated has nothing to adjust after payment', tests.aj(vmgr, 'vmgr@sa.example', ag4, 'applies') || ' ' || tests.aj(vmgr, 'vmgr@sa.example', ag4, 'items') || ' ' || tests.aj(vowner, 'vowner@sa.example', ag4, 'can', 'record'), 'false [] false');
  perform tests.assert_eq('an agreement with no settlement at all looks the same, with no settlement id', tests.aj(vmgr, 'vmgr@sa.example', ag5, 'applies') || ' ' || tests.aj(vmgr, 'vmgr@sa.example', ag5, 'settlement_id'), 'false null');
  perform tests.assert_eq('the owner may record one on a paid settlement, the manager and the organizer may not', tests.aj(vowner, 'vowner@sa.example', ag1, 'can', 'record') || ' ' || tests.aj(vmgr, 'vmgr@sa.example', ag1, 'can', 'record') || ' ' || tests.aj(oorg, 'org@sa.example', ag1, 'can', 'record'), 'true false false');
  perform tests.assert_eq('the sides are "venue" for the club and "organizer" for the organizer', tests.aj(vmgr, 'vmgr@sa.example', ag1, 'side') || '/' || tests.aj(oorg, 'org@sa.example', ag1, 'side') || '/' || tests.aj(ostaff, 'ostaff@sa.example', ag1, 'side'), 'venue/organizer/organizer');
  perform tests.assert_eq('a stranger cannot read them', tests.aj(rando, 'rando@sa.example', ag1, 'applies'), 'ERROR: not allowed');
  perform tests.assert_eq('nor a server', tests.aj(vsrv, 'vsrv@sa.example', ag1, 'applies'), 'ERROR: not allowed');
  perform tests.assert_eq('nor another club''s manager', tests.aj(vmgr_b, 'vmgrb@sa.example', ag1, 'applies'), 'ERROR: not allowed');
  perform tests.assert_eq('nor another club''s owner', tests.aj(vowner2, 'vowner2@sa.example', ag1, 'applies'), 'ERROR: not allowed');
  perform tests.assert_eq('nor a rival organizer', tests.aj(rival, 'rival@sa.example', ag1, 'applies'), 'ERROR: not allowed');
  perform tests.assert_eq('nor the organizer''s own door staff (only its owner and organizer people may)', tests.aj(odoor, 'odoor@sa.example', ag1, 'applies') || ' ' || tests.flo(odoor, 'odoor@sa.example', oorg_id), 'ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('an agreement that does not exist looks the same', tests.aj(vmgr, 'vmgr@sa.example', gen_random_uuid(), 'applies'), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read them', format($q$select public.settlement_adjustments(%L)$q$, ag1), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('a call with no signed-in person is told to sign in', format($q$select public.settlement_adjustments(%L)$q$, ag1), 'not authenticated');
  perform tests.logout();

  ---------------------------------------------------------------- who may record one, and what is refused
  perform tests.assert_eq('the club''s manager cannot record: only the owner', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, s1)), 'ERROR: not allowed');
  perform tests.assert_eq('the organizer cannot', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, s1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor the organizer''s other person', tests.run_as(ostaff, 'ostaff@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, s1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a server, another club''s manager, another club''s owner, a rival or a stranger',
    tests.run_as(vsrv, 'vsrv@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, s1)) || ' ' ||
    tests.run_as(vmgr_b, 'vmgrb@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, s1)) || ' ' ||
    tests.run_as(vowner2, 'vowner2@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, s1)) || ' ' ||
    tests.run_as(rival, 'rival@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, s1)) || ' ' ||
    tests.run_as(rando, 'rando@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, s1)),
    'ERROR: not allowed ERROR: not allowed ERROR: not allowed ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('a settlement that does not exist', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, gen_random_uuid())), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot record', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')$q$, s1), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('no signed-in person', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')$q$, s1), 'not authenticated');
  perform tests.logout();
  perform tests.assert_eq('a settlement that has not been paid takes none: until then the amount owed is adjusted', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle')::text$q$, s4)),
    'ERROR: only a settlement that has been paid takes adjustments after payment: until then, adjust the amount owed');
  perform tests.assert_eq('no kind is refused', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, null, -5000, 'Refund of a Friday bottle')::text$q$, s1)), 'ERROR: say what the adjustment is for: a refund, a chargeback or a correction');
  perform tests.assert_eq('...nor a kind that does not exist', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'gift', -5000, 'Refund of a Friday bottle')::text$q$, s1)), 'ERROR: say what the adjustment is for: a refund, a chargeback or a correction');
  perform tests.assert_eq('a change of nothing is refused', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', 0, 'Refund of a Friday bottle')::text$q$, s1)), 'ERROR: enter the change as a plus or minus amount (not 0)');
  perform tests.assert_eq('...and no amount', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', null, 'Refund of a Friday bottle')::text$q$, s1)), 'ERROR: enter the change as a plus or minus amount (not 0)');
  perform tests.assert_eq('...and an absurd amount', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'correction', 100000000001, 'Refund of a Friday bottle')::text$q$, s1)), 'ERROR: enter the change as a plus or minus amount (not 0)');
  perform tests.assert_eq('a refund is always a minus', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', 5000, 'Refund of a Friday bottle')::text$q$, s1)), 'ERROR: a refund or a chargeback takes money off what the organizer is owed: enter a minus amount (a correction can add)');
  perform tests.assert_eq('so is a chargeback', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'chargeback', 5000, 'Card chargeback')::text$q$, s1)), 'ERROR: a refund or a chargeback takes money off what the organizer is owed: enter a minus amount (a correction can add)');
  perform tests.assert_eq('a reason has to be given', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, '  ')::text$q$, s1)), 'ERROR: say why (3 to 300 characters)');
  perform tests.assert_eq('...of at least three characters', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'ab')::text$q$, s1)), 'ERROR: say why (3 to 300 characters)');
  perform tests.assert_eq('...and not at length', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, %L)::text$q$, s1, repeat('x', 301))), 'ERROR: say why (3 to 300 characters)');
  perform tests.assert_eq('a reference, if given, is 3 to 120 characters', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle', 'ab')::text$q$, s1)) || ' ' ||
    tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle', %L)::text$q$, s1, repeat('r', 121))),
    'ERROR: keep the reference to 3 to 120 characters ERROR: keep the reference to 3 to 120 characters');
  perform tests.assert_eq('nothing can take back more than was paid (30000)', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -30001, 'Refund of everything and more')::text$q$, s1)), 'ERROR: the adjustments cannot take back more than was paid');
  perform tests.assert_eq('nothing was written by all the refusals', (select count(*) from public.site_settlement_adjustments)::int, 0);
  perform tests.assert_eq('...nor logged', (select count(*) from public.site_settlement_adjustment_log)::int, 0);

  ---------------------------------------------------------------- the first one
  fp_before := tests.original(ag1);
  shown_before := tests.shown(vowner, 'vowner@sa.example', ag1);
  shown_org_before := tests.shown(oorg, 'org@sa.example', ag1);
  log_rows_before := tests.nlog();
  r := tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -5000, 'Refund of a Friday bottle', 'RF-2201')::text$q$, s1));
  perform tests.assert_true('the owner records a refund after payment', r not like 'ERROR%');
  a1 := r::uuid;
  perform tests.assert_eq('it is open, a minus, a refund, with its reason and reference', tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'status') || ' ' || tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'amount_cents') || ' ' || tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'kind') || ' / ' ||
    tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'reason') || ' / ' || tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'source_ref'), 'open -5000 refund / Refund of a Friday bottle / RF-2201');
  perform tests.assert_eq('...it says who recorded it, and which way the money is owed (the organizer was paid too much)', tests.ij(vmgr, 'vmgr@sa.example', ag1, a1, 'recorded_by_name') || ' ' || tests.ij(vmgr, 'vmgr@sa.example', ag1, a1, 'direction'), 'Olly Owner organizer_owes_club');
  perform tests.assert_eq('the figures at the top: paid 30000, adjustments -5000, net 25000, 5000 still to come back from the organizer, one adjustment', tests.tot(vowner, 'vowner@sa.example', ag1), '30000/-5000/25000/0/5000/1');
  perform tests.assert_eq('the manager and the organizer read the same figures', tests.tot(vmgr, 'vmgr@sa.example', ag1) || ' ' || tests.tot(oorg, 'org@sa.example', ag1) || ' ' || tests.tot(ostaff, 'ostaff@sa.example', ag1), '30000/-5000/25000/0/5000/1 30000/-5000/25000/0/5000/1 30000/-5000/25000/0/5000/1');
  perform tests.assert_eq('THE ORIGINAL IS UNCHANGED: the settlement row and its history are byte for byte what they were', tests.original(ag1), fp_before);
  perform tests.assert_eq('...and so is what the settlement screen reads (for the club and for the organizer)', tests.shown(vowner, 'vowner@sa.example', ag1) || tests.shown(oorg, 'org@sa.example', ag1), shown_before || shown_org_before);
  perform tests.assert_eq('...it still says paid, 30000, with its payment record', tests.run_as(vowner, 'vowner@sa.example', format($q$select (public.settlement_detail(%L) -> 'settlement' ->> 'status') || ' ' || (public.settlement_detail(%L) -> 'settlement' ->> 'paid_amount_cents') || ' ' || (public.settlement_detail(%L) -> 'settlement' ->> 'payment_reference')$q$, ag1, ag1, ag1)), 'paid 30000 TRF-1001');
  perform tests.assert_eq('...and nothing was added to the settlement''s own history', tests.nlog(), log_rows_before);
  perform tests.assert_eq('what each person can do about it: the owner may settle or waive; the manager nothing; the organizer may acknowledge or question',
    tests.icn(vowner, 'vowner@sa.example', ag1, a1) || ' / ' || tests.icn(vmgr, 'vmgr@sa.example', ag1, a1) || ' / ' || tests.icn(oorg, 'org@sa.example', ag1, a1), 'settle,waive / (nothing) / acknowledge,question');
  perform tests.assert_eq('the old way still refuses after payment (the amount owed is not changed behind the record)', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjust(%L, -100, 'Later refund')::text$q$, s1)), 'ERROR: this settlement has been paid: adjustments after payment are not recorded yet');

  ---------------------------------------------------------------- the organizer acknowledges, then questions, and the club answers
  perform tests.assert_eq('a stranger cannot acknowledge', tests.run_as(rando, 'rando@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a rival, a server, or the club''s manager or owner', tests.run_as(rival, 'rival@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1)) || ' ' || tests.run_as(vsrv, 'vsrv@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1))
    || ' ' || tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1)) || ' ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1)),
    'ERROR: not allowed ERROR: not allowed ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('nor the organizer''s door staff', tests.run_as(odoor, 'odoor@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1)) || ' ' || tests.run_as(odoor, 'odoor@sa.example', format($q$select public.settlement_adjustment_question(%L, 'Is this right?')$q$, a1)),
    'ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('one that does not exist', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, gen_random_uuid())), 'ERROR: not allowed');
  perform tests.assert_eq('the organizer acknowledges it, once', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1)) || ' ' || tests.run_as(ostaff, 'ostaff@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1)), 'true false');
  perform tests.assert_eq('...and it says who and when', tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'organizer_ack_by_name') || ' ' || (tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'organizer_ack_at') <> 'null')::text, 'Olive Organizer true');
  perform tests.assert_eq('having acknowledged, only a question is left for the organizer', tests.icn(oorg, 'org@sa.example', ag1, a1), 'question');
  perform tests.assert_eq('a question needs a reason', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_question(%L, 'why')$q$, a1)), 'ERROR: say what you are asking (5 to 500 characters)');
  perform tests.assert_eq('...and not at length', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_question(%L, %L)$q$, a1, repeat('q', 501))), 'ERROR: say what you are asking (5 to 500 characters)');
  perform tests.assert_eq('the club cannot ask on the organizer''s behalf', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_question(%L, 'Is this right?')$q$, a1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a rival, a server or a stranger', tests.run_as(rival, 'rival@sa.example', format($q$select public.settlement_adjustment_question(%L, 'Is this right?')$q$, a1)) || ' ' || tests.run_as(vsrv, 'vsrv@sa.example', format($q$select public.settlement_adjustment_question(%L, 'Is this right?')$q$, a1)) || ' ' ||
    tests.run_as(rando, 'rando@sa.example', format($q$select public.settlement_adjustment_question(%L, 'Is this right?')$q$, a1)), 'ERROR: not allowed ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('the organizer questions it', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_question(%L, 'Which bottle was refunded?')$q$, a1)), 'disputed');
  perform tests.assert_eq('...the reason is kept and shown to both sides', tests.ij(vmgr, 'vmgr@sa.example', ag1, a1, 'disputed_reason') || ' / ' || tests.ij(oorg, 'org@sa.example', ag1, a1, 'disputed_reason'), 'Which bottle was refunded? / Which bottle was refunded?');
  perform tests.assert_eq('...the acknowledgement is cleared', tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'organizer_ack_at'), 'null');
  perform tests.assert_eq('...it is still counted as open (a question does not close it): 5000 to come back, and the list says one open', tests.tot(vowner, 'vowner@sa.example', ag1) || ' ' || tests.flv(vmgr, 'vmgr@sa.example', venue_a), '30000/-5000/25000/0/5000/1 Night One:1:1:0:5000');
  perform tests.assert_eq('while a question is open the manager can answer; the owner can do nothing with it; the organizer can do nothing', tests.icn(vmgr, 'vmgr@sa.example', ag1, a1) || ' / ' || tests.icn(vowner, 'vowner@sa.example', ag1, a1) || ' / ' || tests.icn(oorg, 'org@sa.example', ag1, a1), 'answer / answer / (nothing)');
  perform tests.assert_eq('a second question is refused while one is open', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_question(%L, 'Another thing to ask')$q$, a1)), 'ERROR: a question is already open');
  perform tests.assert_eq('there is nothing to acknowledge while it is open', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1)), 'ERROR: there is nothing to acknowledge while a question is open');
  perform tests.assert_eq('it cannot be settled or waived until it is answered', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9001')$q$, a1)) || ' | ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_waive(%L, 'Not worth recovering')$q$, a1)),
    'ERROR: the organizer has asked a question: answer it first | ERROR: the organizer has asked a question: answer it first');
  perform tests.assert_eq('the organizer cannot answer their own question', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_answer(%L, 'Fine as it is')$q$, a1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a rival, a server, another club''s owner or a stranger', tests.run_as(rival, 'rival@sa.example', format($q$select public.settlement_adjustment_answer(%L, 'Fine as it is')$q$, a1)) || ' ' || tests.run_as(vsrv, 'vsrv@sa.example', format($q$select public.settlement_adjustment_answer(%L, 'Fine as it is')$q$, a1))
    || ' ' || tests.run_as(vowner2, 'vowner2@sa.example', format($q$select public.settlement_adjustment_answer(%L, 'Fine as it is')$q$, a1)) || ' ' || tests.run_as(rando, 'rando@sa.example', format($q$select public.settlement_adjustment_answer(%L, 'Fine as it is')$q$, a1)),
    'ERROR: not allowed ERROR: not allowed ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('the answer has to be written', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_answer(%L, ' ')$q$, a1)), 'ERROR: write your answer (3 to 500 characters)');
  perform tests.assert_eq('...of at least three characters', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_answer(%L, 'ab')$q$, a1)), 'ERROR: write your answer (3 to 500 characters)');
  perform tests.assert_eq('...and not at length', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_answer(%L, %L)$q$, a1, repeat('a', 501))), 'ERROR: write your answer (3 to 500 characters)');
  perform tests.assert_eq('the club''s manager answers, and it is open again, with no question left on it', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_answer(%L, 'A bottle of the house vodka, refunded on the night')::text$q$, a1)) || ' ' || tests.ij(vmgr, 'vmgr@sa.example', ag1, a1, 'status') || ' ' || tests.ij(vmgr, 'vmgr@sa.example', ag1, a1, 'disputed_reason'), 'open open null');
  perform tests.assert_eq('there is then no open question', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_answer(%L, 'Again')$q$, a1)), 'ERROR: there is no open question');
  perform tests.assert_eq('the organizer acknowledges again', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_acknowledge(%L)::text$q$, a1)), 'true');

  ---------------------------------------------------------------- the payment that settles it
  perform tests.assert_eq('the manager cannot record the payment', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9001')$q$, a1)), 'ERROR: not allowed');
  perform tests.assert_eq('the organizer cannot mark its own repayment paid', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9001')$q$, a1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a rival, a server, another club''s owner or a stranger', tests.run_as(rival, 'rival@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9001')$q$, a1)) || ' ' || tests.run_as(vsrv, 'vsrv@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9001')$q$, a1))
    || ' ' || tests.run_as(vowner2, 'vowner2@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9001')$q$, a1)) || ' ' || tests.run_as(rando, 'rando@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9001')$q$, a1)),
    'ERROR: not allowed ERROR: not allowed ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('the amount has to be exactly the adjustment', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 4999, current_date, 'RPY-9001')$q$, a1)) || ' | ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5001, current_date, 'RPY-9001')$q$, a1))
    || ' | ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, -5000, current_date, 'RPY-9001')$q$, a1)) || ' | ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, null, current_date, 'RPY-9001')$q$, a1)),
    'ERROR: the amount has to be exactly the adjustment: 5000 | ERROR: the amount has to be exactly the adjustment: 5000 | ERROR: the amount has to be exactly the adjustment: 5000 | ERROR: the amount has to be exactly the adjustment: 5000');
  perform tests.assert_eq('a date in the future is refused', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date + 5, 'RPY-9001')$q$, a1)), 'ERROR: choose the date it was paid (not in the future)');
  perform tests.assert_eq('...and no date', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, null, 'RPY-9001')$q$, a1)), 'ERROR: choose the date it was paid (not in the future)');
  perform tests.assert_eq('a reference is needed, of a sensible length', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, ' ')$q$, a1)) || ' | ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'ab')$q$, a1))
    || ' | ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, %L)$q$, a1, repeat('r', 121))),
    'ERROR: enter a reference for the payment (3 to 120 characters) | ERROR: enter a reference for the payment (3 to 120 characters) | ERROR: enter a reference for the payment (3 to 120 characters)');
  perform tests.assert_eq('the evidence note is short', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9001', %L)$q$, a1, repeat('e', 301))), 'ERROR: keep the evidence note to 300 characters or fewer');
  perform tests.assert_eq('nothing was recorded by the refusals', tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'status'), 'open');
  perform tests.assert_eq('the owner records the repayment that was made outside BottlesUp', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9001', 'Bank transfer back, screenshot kept')::text$q$, a1)), 'settled');
  perform tests.assert_eq('it says settled, labels it a recorded external payment, and keeps the amount, reference, evidence and who recorded it', tests.ij(oorg, 'org@sa.example', ag1, a1, 'status') || ' / ' || tests.ij(oorg, 'org@sa.example', ag1, a1, 'resolution_label') || ' / ' ||
    tests.ij(oorg, 'org@sa.example', ag1, a1, 'resolved_amount_cents') || ' ' || tests.ij(oorg, 'org@sa.example', ag1, a1, 'resolution_reference') || ' ' || tests.ij(oorg, 'org@sa.example', ag1, a1, 'resolution_note') || ' / ' || tests.ij(oorg, 'org@sa.example', ag1, a1, 'resolved_by_name'),
    'settled / Recorded external payment / 5000 RPY-9001 Bank transfer back, screenshot kept / Olly Owner');
  perform tests.assert_eq('...the date it was paid', (tests.ij(vowner, 'vowner@sa.example', ag1, a1, 'resolved_on') = current_date::text)::text, 'true');
  perform tests.assert_eq('a settled adjustment is final: nothing is left for the owner, the manager or the organizer', tests.icn(vowner, 'vowner@sa.example', ag1, a1) || ' / ' || tests.icn(vmgr, 'vmgr@sa.example', ag1, a1) || ' / ' || tests.icn(oorg, 'org@sa.example', ag1, a1), '(nothing) / (nothing) / (nothing)');
  perform tests.assert_eq('it cannot be settled twice, waived, or questioned', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 5000, current_date, 'RPY-9002')$q$, a1)) || ' | ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_waive(%L, 'Changed my mind')$q$, a1))
    || ' | ' || tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_question(%L, 'Is this settled?')$q$, a1)),
    'ERROR: this adjustment has already been dealt with | ERROR: this adjustment has already been dealt with | ERROR: this adjustment has already been dealt with');
  perform tests.assert_eq('the figures: the adjustment is still counted (net 25000) and nothing is left to come back', tests.tot(vowner, 'vowner@sa.example', ag1), '30000/-5000/25000/0/0/1');

  ---------------------------------------------------------------- waiving, and an amount owed to the organizer
  r := tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'chargeback', -2000, 'Card chargeback, Saturday', 'CB-77')::text$q$, s1));
  perform tests.assert_true('a chargeback is recorded', r not like 'ERROR%');
  a2 := r::uuid;
  perform tests.assert_eq('the manager cannot waive', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjustment_waive(%L, 'Not worth recovering')$q$, a2)), 'ERROR: not allowed');
  perform tests.assert_eq('nor the organizer', tests.run_as(oorg, 'org@sa.example', format($q$select public.settlement_adjustment_waive(%L, 'Not worth recovering')$q$, a2)), 'ERROR: not allowed');
  perform tests.assert_eq('a reason is needed', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_waive(%L, ' ')$q$, a2)) || ' | ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_waive(%L, %L)$q$, a2, repeat('w', 301))),
    'ERROR: say why it is not being recovered (3 to 300 characters) | ERROR: say why it is not being recovered (3 to 300 characters)');
  perform tests.assert_eq('the owner chooses not to recover it', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_waive(%L, 'Not worth recovering')$q$, a2)), 'waived');
  perform tests.assert_eq('it says "Not recovered", with the reason and who', tests.ij(oorg, 'org@sa.example', ag1, a2, 'status') || ' / ' || tests.ij(oorg, 'org@sa.example', ag1, a2, 'resolution_label') || ' / ' || tests.ij(oorg, 'org@sa.example', ag1, a2, 'resolution_note') || ' / ' || tests.ij(oorg, 'org@sa.example', ag1, a2, 'resolved_by_name'),
    'waived / Not recovered / Not worth recovering / Olly Owner');
  perform tests.assert_eq('the organizer can still acknowledge a waived one', tests.icn(oorg, 'org@sa.example', ag1, a2), 'acknowledge');
  perform tests.assert_eq('a waived adjustment is still counted in the net (the organizer was overpaid; the club chose not to recover it), but is nothing left to come back', tests.tot(vowner, 'vowner@sa.example', ag1), '30000/-7000/23000/0/0/2');
  perform tests.assert_eq('a waived adjustment is final too', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 2000, current_date, 'RPY-9002')$q$, a2)) || ' | ' || tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_waive(%L, 'Again')$q$, a2)),
    'ERROR: this adjustment has already been dealt with | ERROR: this adjustment has already been dealt with');
  r := tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'correction', 1500, 'A refunded bottle was a mistake: the chargeback was won')::text$q$, s1));
  perform tests.assert_true('a correction can add: the club now owes the organizer', r not like 'ERROR%');
  a3 := r::uuid;
  perform tests.assert_eq('it is owed TO the organizer', tests.ij(vowner, 'vowner@sa.example', ag1, a3, 'direction') || ' ' || tests.tot(vowner, 'vowner@sa.example', ag1), 'club_owes_organizer 30000/-5500/24500/1500/0/3');
  perform tests.assert_eq('the owner can only settle it: an amount owed to the organizer cannot be waived', tests.icn(vowner, 'vowner@sa.example', ag1, a3), 'settle');
  perform tests.assert_eq('...and the database says so', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_waive(%L, 'Not paying it')$q$, a3)), 'ERROR: an amount owed to the organizer cannot be waived: record the payment, or a correction if it was a mistake');
  perform tests.assert_eq('the owner records the payment to the organizer, exactly 1500', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 1500, current_date, 'PAY-5001')$q$, a3)), 'settled');
  perform tests.assert_eq('nothing is left to settle, net 24500', tests.tot(vowner, 'vowner@sa.example', ag1), '30000/-5500/24500/0/0/3');
  perform tests.assert_eq('the organizer can still acknowledge a settled one', tests.icn(oorg, 'org@sa.example', ag1, a3), 'acknowledge');
  r := tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'correction', -100, 'Rounding')::text$q$, s1));
  perform tests.assert_true('a correction can also take off', r not like 'ERROR%');
  a4 := r::uuid;
  r := tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'correction', 100, 'The rounding was right: undoing the last correction')::text$q$, s1));
  perform tests.assert_true('a mistake is put right by an opposite adjustment, never by editing', r not like 'ERROR%');
  a5 := r::uuid;
  perform tests.assert_eq('both are still open, kept apart: 100 each way, not netted to nothing', tests.tot(vowner, 'vowner@sa.example', ag1), '30000/-5500/24500/100/100/5');
  perform tests.assert_eq('the newest comes first in the list', tests.aj(vowner, 'vowner@sa.example', ag1, 'items', '0', 'id') || ' ' || tests.aj(vowner, 'vowner@sa.example', ag1, 'items', '4', 'id'), a5::text || ' ' || a1::text);
  perform tests.assert_eq('THE ORIGINAL IS STILL UNCHANGED after five adjustments, a question, an answer, a settlement, a waiver', tests.original(ag1) || tests.shown(vowner, 'vowner@sa.example', ag1) || tests.shown(oorg, 'org@sa.example', ag1), fp_before || shown_before || shown_org_before);
  perform tests.assert_eq('...and the settlement''s own history has nothing added', tests.nlog(), log_rows_before);

  ---------------------------------------------------------------- the lists
  perform tests.assert_eq('the club''s manager sees which agreements have adjustments, how many are open, and what is still to come in each direction', tests.flv(vmgr, 'vmgr@sa.example', venue_a), 'Night One:5:2:100:100');
  perform tests.assert_eq('the owner sees the same', tests.flv(vowner, 'vowner@sa.example', venue_a), 'Night One:5:2:100:100');
  perform tests.assert_eq('the organizer sees theirs', tests.flo(oorg, 'org@sa.example', oorg_id) || ' / ' || tests.flo(ostaff, 'ostaff@sa.example', oorg_id), 'Night One:5:2:100:100 / Night One:5:2:100:100');
  perform tests.assert_eq('a settlement with none is not in the list', (tests.flv(vmgr, 'vmgr@sa.example', venue_a) like '%Night Two%')::text, 'false');
  perform tests.assert_eq('another club''s manager sees only their own club''s, which has none', tests.flv(vmgr_b, 'vmgrb@sa.example', venue_b), '(none)');
  perform tests.assert_eq('...and cannot read club A''s', tests.flv(vmgr_b, 'vmgrb@sa.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('a server, a rival and a stranger cannot', tests.flv(vsrv, 'vsrv@sa.example', venue_a) || ' ' || tests.flv(rival, 'rival@sa.example', venue_a) || ' ' || tests.flv(rando, 'rando@sa.example', venue_a), 'ERROR: not allowed ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('a rival organizer cannot read another business''s', tests.flo(rival, 'rival@sa.example', oorg_id), 'ERROR: not allowed');
  perform tests.assert_eq('...and sees nothing of theirs that is not there', tests.flo(rival, 'rival@sa.example', rival_org), '(none)');
  perform tests.assert_eq('the club''s manager cannot use the organizer''s list, nor the organizer the club''s', tests.flo(vmgr, 'vmgr@sa.example', oorg_id) || ' ' || tests.flv(oorg, 'org@sa.example', venue_a), 'ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('no club, no business', tests.flv(vmgr, 'vmgr@sa.example', null) || ' ' || tests.flo(oorg, 'org@sa.example', null), 'ERROR: not allowed ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the club''s list', format($q$select * from public.settlement_adjustment_flags_for_venue(%L)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...nor the organizer''s', format($q$select * from public.settlement_adjustment_flags_for_organizer(%L)$q$, oorg_id), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('a call with no signed-in person is told to sign in', format($q$select * from public.settlement_adjustment_flags_for_venue(%L)$q$, venue_a), 'not authenticated');
  perform tests.logout();

  ---------------------------------------------------------------- the history
  perform tests.assert_eq('every step is in the history, in order, with the side that took it',
    tests.alog(ag1),
    'venue:recorded:->open | organizer:acknowledged:open>open | organizer:questioned:open>disputed | venue:answered:disputed>open | organizer:acknowledged:open>open | venue:settled:open>settled | venue:recorded:->open | venue:waived:open>waived | venue:recorded:->open | venue:settled:open>settled | venue:recorded:->open | venue:recorded:->open');
  perform tests.assert_eq('the detail shows the history newest first, with who did it and "by me"', tests.aj(vowner, 'vowner@sa.example', ag1, 'log', '0', 'action') || ' ' || tests.aj(vowner, 'vowner@sa.example', ag1, 'log', '0', 'by_name') || ' ' || tests.aj(vowner, 'vowner@sa.example', ag1, 'log', '0', 'by_me') || ' / ' ||
    tests.aj(oorg, 'org@sa.example', ag1, 'log', '0', 'by_me'), 'recorded Olly Owner true / false');
  perform tests.assert_eq('the oldest line is the first adjustment, with its amount and what it was for', tests.aj(vowner, 'vowner@sa.example', ag1, 'log', '11', 'action') || ' ' || tests.aj(vowner, 'vowner@sa.example', ag1, 'log', '11', 'amount_cents') || ' ' || tests.aj(vowner, 'vowner@sa.example', ag1, 'log', '11', 'note'),
    'recorded -5000 refund: Refund of a Friday bottle');
  perform tests.assert_eq('a payment line in the history says it was recorded, not made', tests.run_as(vowner, 'vowner@sa.example', format($q$select (select e ->> 'note' from jsonb_array_elements(public.settlement_adjustments(%L) -> 'log') e where e ->> 'action' = 'settled' and (e ->> 'amount_cents')::bigint = 5000)$q$, ag1)), 'Recorded external payment: RPY-9001');
  perform tests.assert_eq('the history names the question, then the answer', tests.run_as(vowner, 'vowner@sa.example', format($q$select (select string_agg(e ->> 'note', ' / ' order by e ->> 'at') from jsonb_array_elements(public.settlement_adjustments(%L) -> 'log') e where e ->> 'action' in ('questioned', 'answered'))$q$, ag1)),
    'Which bottle was refunded? / A bottle of the house vodka, refunded on the night');

  ---------------------------------------------------------------- the net can never go below zero
  perform tests.assert_eq('the amount PAID is what the figures start from (40500: a share of 40000 and 500 agreed before payment), not the share', tests.aj(vowner, 'vowner@sa.example', ag2, 'paid_amount_cents') || ' ' ||
    tests.run_as(vowner, 'vowner@sa.example', format($q$select (public.settlement_detail(%L) -> 'settlement' ->> 'share_cents')$q$, ag2)), '40500 40000');
  perform tests.assert_eq('on a settlement paid 40500, taking back all of it is allowed', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'chargeback', -40500, 'The whole night was charged back', 'CB-1')::text$q$, s2)) not like 'ERROR%', true);
  perform tests.assert_eq('...net 0', tests.tot(vowner, 'vowner@sa.example', ag2), '40500/-40500/0/0/40500/1');
  perform tests.assert_eq('...and not one cent more', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -1, 'One more cent')::text$q$, s2)), 'ERROR: the adjustments cannot take back more than was paid');
  perform tests.assert_eq('a correction that adds makes room again', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'correction', 1000, 'Part of the chargeback was reversed')::text$q$, s2)) not like 'ERROR%', true);
  perform tests.assert_eq('...and then 1000 may be taken off, not 1001', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -1001, 'Too much')::text$q$, s2)) || ' | ' || (tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -1000, 'Exactly the room there is')::text$q$, s2)) not like 'ERROR%')::text,
    'ERROR: the adjustments cannot take back more than was paid | true');
  perform tests.assert_eq('the other settlement is not affected by it', tests.tot(vowner, 'vowner@sa.example', ag3), '40000/0/40000/0/0/0');

  ---------------------------------------------------------------- at most 50 per settlement
  for i in 1..50 loop
    r := tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -1, %L)::text$q$, s3, 'Small refund ' || i));
    if r like 'ERROR%' then raise exception 'FAIL - adjustment % of 50 was refused: %', i, r; end if;
  end loop;
  perform tests.assert_eq('fifty are allowed, and the owner is then told no more can be recorded', tests.tot(vowner, 'vowner@sa.example', ag3) || ' ' || tests.aj(vowner, 'vowner@sa.example', ag3, 'can', 'record'), '40000/-50/39950/0/50/50 false');
  perform tests.assert_eq('the fifty-first is refused', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -1, 'One too many')::text$q$, s3)), 'ERROR: this settlement already has 50 adjustments after payment');
  b1 := tests.first_adj(s3);
  perform tests.assert_eq('...but settling one takes no room, so it still works at fifty, and the owner still cannot record another', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_settle(%L, 1, current_date, 'RPY-1')$q$, b1)) || ' ' || tests.aj(vowner, 'vowner@sa.example', ag3, 'can', 'record'), 'settled false');

  ---------------------------------------------------------------- an unpaid settlement still behaves as before, and the adjustments of one settlement are not another's
  perform tests.assert_eq('an estimated settlement can still be adjusted the old way', tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_adjust(%L, -500, 'Refund before payment')::text$q$, s4)), '29500');
  perform tests.assert_eq('...and has no adjustments after payment', tests.aj(vmgr, 'vmgr@sa.example', ag4, 'applies'), 'false');
  perform tests.run_as(vmgr, 'vmgr@sa.example', format($q$select public.settlement_review(%L)$q$, s4));
  perform tests.assert_eq('a reviewed settlement takes none either', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -100, 'Refund before payment')::text$q$, s4)),
    'ERROR: only a settlement that has been paid takes adjustments after payment: until then, adjust the amount owed');
  perform tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_approve(%L)$q$, s4));
  perform tests.assert_eq('nor does an approved one, waiting for its payment', tests.run_as(vowner, 'vowner@sa.example', format($q$select public.settlement_adjustment_record(%L, 'refund', -100, 'Refund before payment')::text$q$, s4)),
    'ERROR: only a settlement that has been paid takes adjustments after payment: until then, adjust the amount owed');
  perform tests.assert_eq('an adjustment cannot be used through another settlement''s agreement', tests.ij(vowner, 'vowner@sa.example', ag2, a1, 'status'), 'null');

  ---------------------------------------------------------------- nothing else moves, and the tables are closed
  perform tests.logout();
  perform tests.assert_eq('BottlesUp''s own payout items were not touched', (select count(*) from public.site_payout_items), payouts_before);
  perform tests.assert_eq('no settlement was added or removed', (select count(*) from public.site_settlements), settlements_before);
  perform tests.assert_eq('the three paid settlements are still paid, with their payment records', (select string_agg(status || ':' || paid_amount_cents, ',' order by paid_amount_cents, id) from public.site_settlements where id in (s1, s2, s3)), 'paid:30000,paid:40000,paid:40500');
  perform tests.login(vowner, 'vowner@sa.example');
  perform tests.assert_raises('a signed-in person cannot read the adjustments table', 'select * from public.site_settlement_adjustments', 'permission denied');
  perform tests.assert_raises('...nor the history', 'select * from public.site_settlement_adjustment_log', 'permission denied');
  perform tests.assert_raises('...nor write an adjustment directly', format($q$insert into public.site_settlement_adjustments (settlement_id, kind, amount_cents, reason) values (%L, 'refund', -1, 'Directly')$q$, s1), 'permission denied');
  perform tests.assert_raises('...nor change one', format($q$update public.site_settlement_adjustments set status = 'settled' where id = %L$q$, a4), 'permission denied');
  perform tests.assert_raises('...nor delete one', format($q$delete from public.site_settlement_adjustments where id = %L$q$, a4), 'permission denied');
  perform tests.assert_raises('...nor write history', format($q$insert into public.site_settlement_adjustment_log (settlement_id, adjustment_id, side, action) values (%L, %L, 'venue', 'settled')$q$, s1, a4), 'permission denied');
  perform tests.assert_raises('...nor call the internal history writer', format($q$select public.settlement_adjustment_log_add(%L, %L, 'venue', 'settled', null, null, null, null)$q$, a4, s1), 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the table', 'select * from public.site_settlement_adjustments', 'permission denied');
  perform tests.logout();
  perform tests.assert_true('the database itself refuses a refund that adds, a settled one without its payment, a waived one that was owed to the organizer, and a question without its reason',
    (select count(*) = 4 from pg_constraint c where c.conrelid = 'public.site_settlement_adjustments'::regclass and c.conname in ('site_settlement_adjustments_sign_check', 'site_settlement_adjustments_settled_check', 'site_settlement_adjustments_waived_check', 'site_settlement_adjustments_disputed_check')));
  perform tests.assert_raises('...a refund that adds', format($q$insert into public.site_settlement_adjustments (settlement_id, kind, amount_cents, reason) values (%L, 'refund', 5, 'Plus')$q$, s1), 'site_settlement_adjustments_sign_check');
  perform tests.assert_raises('...an amount of nothing', format($q$insert into public.site_settlement_adjustments (settlement_id, kind, amount_cents, reason) values (%L, 'correction', 0, 'Nothing')$q$, s1), 'site_settlement_adjustments_amount_cents_check');
  perform tests.assert_raises('...a status that does not exist', format($q$update public.site_settlement_adjustments set status = 'void' where id = %L$q$, a4), 'site_settlement_adjustments_status_check');
  perform tests.assert_raises('...a kind that does not exist', format($q$insert into public.site_settlement_adjustments (settlement_id, kind, amount_cents, reason) values (%L, 'gift', -5, 'Gift')$q$, s1), 'site_settlement_adjustments_kind_check');
  perform tests.assert_raises('...a settled one without its payment', format($q$update public.site_settlement_adjustments set status = 'settled' where id = %L$q$, a4), 'site_settlement_adjustments_settled_check');
  perform tests.assert_raises('...a settled one for the wrong amount', format($q$update public.site_settlement_adjustments set status = 'settled', resolved_amount_cents = 5, resolved_on = current_date, resolution_reference = 'RPY', resolved_at = now() where id = %L$q$, a4), 'site_settlement_adjustments_settled_check');
  perform tests.assert_raises('...a waived one that was owed to the organizer', format($q$update public.site_settlement_adjustments set status = 'waived', resolution_note = 'No', resolved_at = now() where id = %L$q$, a5), 'site_settlement_adjustments_waived_check');
  perform tests.assert_raises('...a question with no reason', format($q$update public.site_settlement_adjustments set status = 'disputed' where id = %L$q$, a4), 'site_settlement_adjustments_disputed_check');
  perform tests.assert_true('every function runs with its owner''s rights and a fixed search path',
    (select count(*) = 9 and bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%') from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname in ('settlement_adjustments', 'settlement_adjustment_flags_for_venue', 'settlement_adjustment_flags_for_organizer', 'settlement_adjustment_record', 'settlement_adjustment_question', 'settlement_adjustment_answer',
        'settlement_adjustment_acknowledge', 'settlement_adjustment_settle', 'settlement_adjustment_waive')));
  perform tests.assert_true('the internal history writer runs with its owner''s rights and a fixed search path too',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'settlement_adjustment_log_add'));
  perform tests.assert_true('visitors cannot run any of the nine, signed-in people and the service role can (each function decides who may)',
    (select count(*) = 9 and bool_and(not has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('service_role', p.oid, 'execute')) from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname in ('settlement_adjustments', 'settlement_adjustment_flags_for_venue', 'settlement_adjustment_flags_for_organizer', 'settlement_adjustment_record', 'settlement_adjustment_question', 'settlement_adjustment_answer',
        'settlement_adjustment_acknowledge', 'settlement_adjustment_settle', 'settlement_adjustment_waive')));
  perform tests.assert_true('the internal history writer cannot be called by anyone signed in',
    not has_function_privilege('authenticated', 'public.settlement_adjustment_log_add(uuid, uuid, text, text, text, text, bigint, text)', 'execute') and not has_function_privilege('anon', 'public.settlement_adjustment_log_add(uuid, uuid, text, text, text, text, bigint, text)', 'execute'));
end $$;

rollback;
