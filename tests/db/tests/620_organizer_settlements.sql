-- Organizer settlement records (20261122120000_organizer_settlements.sql). What matters: a settlement exists only for an ACTIVE agreement with a share of bar sales; the club's manager or owner enters
-- the eligible sales and the share is worked out from the accepted terms (copied, so a later change cannot move it); the manager reviews, only the OWNER approves and records the payment, and the
-- payment must be exactly the approved amount; the organizer can read, acknowledge or QUESTION it but never change a figure, a status or a payment; any change after a review or an approval sends it
-- back to estimated; a paid settlement is final; every step is in a history; and nothing here moves money or touches BottlesUp's own payouts.
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
-- one value out of the detail
create function tests.dj(p_user uuid, p_email text, p_ag uuid, variadic p_path text[]) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce(public.settlement_detail(p_ag) #>> p_path, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
-- what the caller can do, as a sorted list of the things that are true
create function tests.can(p_user uuid, p_email text, p_ag uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(k, ',' order by k) from jsonb_each_text(public.settlement_detail(p_ag) -> 'can') as e(k, v) where v = 'true'), '(nothing)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.lv(p_user uuid, p_email text, p_venue uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(event_title || ':' || coalesce(status, '-') || ':' || coalesce(bar_percent::text, '-') || ':' || coalesce(payable_cents::text, '-'), ' | ' order by event_title) from public.settlements_for_venue(p_venue)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.lo(p_user uuid, p_email text, p_org uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(event_title || ':' || coalesce(status, '-') || ':' || coalesce(payable_cents::text, '-'), ' | ' order by event_title) from public.settlements_for_organizer(p_org)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.logrows(p_ag uuid) returns text language sql security definer as $$
  select coalesce(string_agg(l.side || ':' || l.action || ':' || coalesce(l.from_status, '-') || '>' || coalesce(l.to_status, '-'), ' | ' order by l.at, l.id), '(none)')
    from public.site_settlement_log l join public.site_settlements s on s.id = l.settlement_id where s.agreement_id = p_ag $$;

do $$
declare
  vowner constant uuid := '00000000-0000-0000-0000-0000000009e1';
  vmgr constant uuid := '00000000-0000-0000-0000-0000000009e2';
  vmgr_b constant uuid := '00000000-0000-0000-0000-0000000009e3';
  vsrv constant uuid := '00000000-0000-0000-0000-0000000009e4';
  oorg constant uuid := '00000000-0000-0000-0000-0000000009e5';
  ostaff constant uuid := '00000000-0000-0000-0000-0000000009e6';
  rival constant uuid := '00000000-0000-0000-0000-0000000009e7';
  rando constant uuid := '00000000-0000-0000-0000-0000000009e8';
  vorg uuid; oorg_id uuid; rival_org uuid; venue_a uuid; venue_b uuid;
  ev1 uuid; ev2 uuid; ev3 uuid; ev4 uuid; ev5 uuid; ev6 uuid; ag1 uuid; ag2 uuid; ag3 uuid; ag4 uuid; ag5 uuid; ag6 uuid; s1 uuid; s4 uuid; s5 uuid; r text;
  payouts_before bigint;
  terms1 constant text := '{"capacity":400,"ticket_ownership":"organizer","bar_percent":10,"threshold_cents":500000,"formula":"above_threshold","eligible_revenue":"bar sales net of tax","refunds":"deducted","taxes_tips_fees":"excluded","settlement_timing":"within 7 days"}';
  terms_nobar constant text := '{"capacity":300,"bar_percent":0}';
begin
  insert into auth.users (id, email) values
    (vowner, 'vowner@st.example'), (vmgr, 'vmgr@st.example'), (vmgr_b, 'vmgrb@st.example'), (vsrv, 'vsrv@st.example'), (oorg, 'org@st.example'), (ostaff, 'ostaff@st.example'), (rival, 'rival@st.example'), (rando, 'rando@st.example');
  insert into public.profiles (id, name, email) values (vowner, 'Olly Owner', 'vowner@st.example'), (vmgr, 'Mia Manager', 'vmgr@st.example'), (oorg, 'Olive Organizer', 'org@st.example'), (ostaff, 'Sam Staff', 'ostaff@st.example');

  perform tests.login(vowner, 'vowner@st.example');
  vorg := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(vorg, 'Club A');
  venue_b := public.create_org_venue(vorg, 'Club B');
  perform tests.join_as(vowner, 'vowner@st.example', vorg, 'vmgr@st.example', 'manager', venue_a, vmgr);
  perform tests.join_as(vowner, 'vowner@st.example', vorg, 'vmgrb@st.example', 'manager', venue_b, vmgr_b);
  perform tests.join_as(vmgr, 'vmgr@st.example', vorg, 'vsrv@st.example', 'server', venue_a, vsrv);
  perform tests.login(oorg, 'org@st.example');
  oorg_id := public.create_organization('Night Events', 'organizer');
  perform tests.login(rival, 'rival@st.example');
  rival_org := public.create_organization('Rival Events', 'organizer');
  perform tests.logout();
  insert into public.site_memberships (org_id, user_id, role) values (oorg_id, ostaff, 'organizer');
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night One', 'x', 'Somewhere', now() + interval '10 days', now() + interval '10 days 6 hours', 'draft', oorg_id) returning id into ev1;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Two', 'x', 'Somewhere', now() + interval '20 days', now() + interval '20 days 6 hours', 'draft', oorg_id) returning id into ev2;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Three', 'x', 'Somewhere', now() + interval '30 days', now() + interval '30 days 6 hours', 'draft', oorg_id) returning id into ev3;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Five', 'x', 'Somewhere', now() + interval '50 days', now() + interval '50 days 6 hours', 'draft', oorg_id) returning id into ev5;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Six', 'x', 'Somewhere', now() + interval '60 days', now() + interval '60 days 6 hours', 'draft', oorg_id) returning id into ev6;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Four', 'x', 'Somewhere', now() + interval '40 days', now() + interval '40 days 6 hours', 'draft', oorg_id) returning id into ev4;

  -- Night One (10 percent above 5000): active.  Night Two: active but with no share of bar sales.  Night Three: only requested.  Night Four: active like Night One.
  ag1 := tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev1, venue_a))::uuid;
  perform tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'ten percent')::text$q$, ag1, terms1));
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag1));
  ag2 := tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev2, venue_a))::uuid;
  perform tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_propose(%L, %L::jsonb)::text$q$, ag2, terms_nobar));
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag2));
  ag3 := tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev3, venue_a))::uuid;
  ag4 := tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev4, venue_a))::uuid;
  perform tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'ten percent')::text$q$, ag4, terms1));
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag4));
  perform tests.logout();
  perform tests.assert_eq('the agreements are as the test needs them (two active with a share, one active without, one only requested)',
    (select string_agg(status, ',' order by event_id = ev1 desc, event_id = ev2 desc, event_id = ev3 desc) from public.site_agreements where id in (ag1, ag2, ag3, ag4)), 'active,active,requested,active');
  select count(*) into payouts_before from public.site_payout_items;

  ---------------------------------------------------------------- the lists
  perform tests.assert_eq('the club''s manager sees the agreements that have a share of bar sales to settle: not the one without a share, not the one only requested',
    tests.lv(vmgr, 'vmgr@st.example', venue_a), 'Night Four:-:10:- | Night One:-:10:-');
  perform tests.assert_eq('the owner sees the same', tests.lv(vowner, 'vowner@st.example', venue_a), 'Night Four:-:10:- | Night One:-:10:-');
  perform tests.assert_eq('the organizer sees theirs', tests.lo(oorg, 'org@st.example', oorg_id), 'Night Four:-:- | Night One:-:-');
  perform tests.assert_eq('a second person at the organizer''s business sees them too', tests.lo(ostaff, 'ostaff@st.example', oorg_id), 'Night Four:-:- | Night One:-:-');
  perform tests.assert_eq('another club''s manager cannot read club A''s', tests.lv(vmgr_b, 'vmgrb@st.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot', tests.lv(vsrv, 'vsrv@st.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('a rival organizer cannot read another business''s', tests.lo(rival, 'rival@st.example', oorg_id), 'ERROR: not allowed');
  perform tests.assert_eq('...and sees nothing of theirs that is not there', tests.lo(rival, 'rival@st.example', rival_org), '(none)');
  perform tests.assert_eq('the club''s manager cannot use the organizer''s list', tests.lo(vmgr, 'vmgr@st.example', oorg_id), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.lv(rando, 'rando@st.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager sees only their own club''s list, which has none of club A''s', tests.lv(vmgr_b, 'vmgrb@st.example', venue_b), '(none)');
  perform tests.assert_eq('no club at all', tests.lv(vmgr, 'vmgr@st.example', null), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the club''s list', format($q$select * from public.settlements_for_venue(%L)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...nor the organizer''s', format($q$select * from public.settlements_for_organizer(%L)$q$, oorg_id), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('a call with no signed-in person is told to sign in', format($q$select * from public.settlements_for_venue(%L)$q$, venue_a), 'not authenticated');
  perform tests.logout();

  ---------------------------------------------------------------- before anything is entered
  perform tests.assert_eq('the detail of an agreement with no settlement yet shows the terms and no settlement', tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement'), 'null');
  perform tests.assert_eq('...the terms that apply', tests.dj(vmgr, 'vmgr@st.example', ag1, 'terms', 'bar_percent') || '/' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'terms', 'threshold_cents') || '/' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'terms', 'formula'), '10/500000/above_threshold');
  perform tests.assert_eq('...and the club can enter the sales, and nothing else', tests.can(vmgr, 'vmgr@st.example', ag1), 'save_sales');
  perform tests.assert_eq('the organizer can do nothing yet', tests.can(oorg, 'org@st.example', ag1), '(nothing)');
  perform tests.assert_eq('the organizer''s side is "organizer", the club''s is "venue"', tests.dj(oorg, 'org@st.example', ag1, 'side') || '/' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'side'), 'organizer/venue');
  perform tests.assert_eq('an agreement with no share of bar sales cannot be settled', tests.dj(vmgr, 'vmgr@st.example', ag2, 'has_share') || ' ' || tests.can(vmgr, 'vmgr@st.example', ag2), 'false (nothing)');
  perform tests.assert_eq('one that is not active cannot be settled', tests.can(vmgr, 'vmgr@st.example', ag3), '(nothing)');
  perform tests.assert_eq('a stranger cannot read the detail', tests.dj(rando, 'rando@st.example', ag1, 'side'), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.dj(vmgr_b, 'vmgrb@st.example', ag1, 'side'), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot', tests.dj(vsrv, 'vsrv@st.example', ag1, 'side'), 'ERROR: not allowed');
  perform tests.assert_eq('a rival organizer cannot', tests.dj(rival, 'rival@st.example', ag1, 'side'), 'ERROR: not allowed');
  perform tests.assert_eq('an agreement that does not exist looks the same', tests.dj(vmgr, 'vmgr@st.example', gen_random_uuid(), 'side'), 'ERROR: not allowed');

  ---------------------------------------------------------------- entering the sales
  perform tests.assert_eq('the organizer cannot enter the club''s sales', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Fri')::text$q$, ag1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a server', tests.run_as(vsrv, 'vsrv@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Fri')::text$q$, ag1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor another club''s manager', tests.run_as(vmgr_b, 'vmgrb@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Fri')::text$q$, ag1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a rival', tests.run_as(rival, 'rival@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Fri')::text$q$, ag1)), 'ERROR: not allowed');
  perform tests.assert_eq('an amount below zero is refused', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, -1, 'Closing report of Fri')::text$q$, ag1)), 'ERROR: enter the eligible bar sales as an amount of 0 or more');
  perform tests.assert_eq('no amount is refused', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, null, 'Closing report of Fri')::text$q$, ag1)), 'ERROR: enter the eligible bar sales as an amount of 0 or more');
  perform tests.assert_eq('an absurd amount is refused', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 100000000001, 'Closing report of Fri')::text$q$, ag1)), 'ERROR: enter the eligible bar sales as an amount of 0 or more');
  perform tests.assert_eq('where the figure comes from has to be said', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, '  ')::text$q$, ag1)), 'ERROR: say where the figure comes from (3 to 300 characters)');
  perform tests.assert_eq('...and not at length', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, %L)::text$q$, ag1, repeat('x', 301))), 'ERROR: say where the figure comes from (3 to 300 characters)');
  perform tests.assert_eq('...nor in two characters', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'ab')::text$q$, ag1)), 'ERROR: say where the figure comes from (3 to 300 characters)');
  perform tests.assert_eq('an agreement with no share of bar sales is refused', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Fri')::text$q$, ag2)), 'ERROR: this agreement has no share of bar sales to settle');
  perform tests.assert_eq('an agreement that is not active is refused', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Fri')::text$q$, ag3)), 'ERROR: this agreement is not active, so there is nothing to settle yet');
  perform tests.assert_eq('one that does not exist', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Fri')::text$q$, gen_random_uuid())), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot enter sales', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Fri')$q$, ag1), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('nothing was written by all the refusals', (select count(*) from public.site_settlements)::int, 0);

  r := tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Fri 14 Nov, reviewed')::text$q$, ag1));
  perform tests.assert_true('the club''s manager starts the settlement', r not like 'ERROR%');
  s1 := r::uuid;
  perform tests.assert_eq('it is estimated, the share worked out from the accepted terms: 10 percent of the 3000 above the threshold of 5000', tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'status') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'base_cents') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'share_cents') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'payable_cents'), 'estimated 300000 30000 30000');
  perform tests.assert_eq('...it says who entered it and where the figure comes from', tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'entered_by_name') || ' / ' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'sales_note'), 'Mia Manager / Closing report of Fri 14 Nov, reviewed');
  perform tests.assert_eq('...in Canadian dollars', tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'currency'), 'cad');
  perform tests.assert_eq('the list now shows it', tests.lv(vmgr, 'vmgr@st.example', venue_a), 'Night Four:-:10:- | Night One:estimated:10:30000');
  perform tests.assert_eq('the organizer''s list too', tests.lo(oorg, 'org@st.example', oorg_id), 'Night Four:-:- | Night One:estimated:30000');
  perform tests.assert_eq('the manager can change the sales, adjust, review', tests.can(vmgr, 'vmgr@st.example', ag1), 'adjust,review,save_sales');
  perform tests.assert_eq('the owner can too, but not yet approve or pay', tests.can(vowner, 'vowner@st.example', ag1), 'adjust,review,save_sales');
  perform tests.assert_eq('the organizer can only ask a question', tests.can(oorg, 'org@st.example', ag1), 'question');
  perform tests.assert_eq('the organizer sees the same figures', tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'share_cents') || ' ' || tests.dj(oorg, 'org@st.example', ag1, 'terms', 'eligible_revenue'), '30000 bar sales net of tax');
  perform tests.assert_eq('a second start for the same agreement is the same settlement, changed', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_save_sales(%L, 900000, 'Corrected closing report')::text$q$, ag1)), s1::text);
  perform tests.assert_eq('...with the new share (10 percent of 4000)', tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'share_cents') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'entered_by_name'), '40000 Olly Owner');
  perform tests.assert_eq('sales below the threshold are a share of nothing, not an error', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 400000, 'Quiet night')::text$q$, ag1)) = s1::text and tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'share_cents') = '0', true);
  perform tests.assert_eq('...and back', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 900000, 'Corrected closing report')::text$q$, ag1)) = s1::text and tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'share_cents') = '40000', true);
  perform tests.logout();
  perform tests.assert_eq('there is one settlement per agreement', (select count(*) from public.site_settlements where agreement_id = ag1)::int, 1);

  ---------------------------------------------------------------- adjustments
  perform tests.assert_eq('the organizer cannot adjust', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_adjust(%L, -5000, 'Refund of Fri')::text$q$, s1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a server, another club or a rival', tests.run_as(vsrv, 'vsrv@st.example', format($q$select public.settlement_adjust(%L, -5000, 'Refund of Fri')::text$q$, s1)) || ' ' || tests.run_as(vmgr_b, 'vmgrb@st.example', format($q$select public.settlement_adjust(%L, -5000, 'Refund of Fri')::text$q$, s1)) || ' ' || tests.run_as(rival, 'rival@st.example', format($q$select public.settlement_adjust(%L, -5000, 'Refund of Fri')::text$q$, s1)), 'ERROR: not allowed ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('a change of nothing is refused', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, 0, 'Refund of Fri')::text$q$, s1)), 'ERROR: enter the change as a plus or minus amount (not 0)');
  perform tests.assert_eq('...and no amount', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, null, 'Refund of Fri')::text$q$, s1)), 'ERROR: enter the change as a plus or minus amount (not 0)');
  perform tests.assert_eq('a reason has to be given', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, -5000, 'x')::text$q$, s1)), 'ERROR: say why the amount is changing (3 to 300 characters)');
  perform tests.assert_eq('the amount owed cannot go below zero', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, -40001, 'Too much')::text$q$, s1)), 'ERROR: the amount owed cannot go below zero');
  perform tests.assert_eq('a refund of 50 comes off: 40000 - 5000', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, -5000, 'Refund of Fri bottle')::text$q$, s1)), '35000');
  perform tests.assert_eq('...with its note', tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'adjustment_cents') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'adjustment_note') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'payable_cents'), '-5000 Refund of Fri bottle 35000');
  perform tests.assert_eq('a second adjustment adds to the first', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, 1000, 'Tip share corrected')::text$q$, s1)), '36000');
  perform tests.assert_eq('...and takes it back', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, -1000, 'Tip share was right')::text$q$, s1)), '35000');

  ---------------------------------------------------------------- review and approval
  perform tests.assert_eq('the organizer cannot review', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_review(%L)$q$, s1)), 'ERROR: not allowed');
  perform tests.assert_eq('the owner cannot approve one that has not been reviewed', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_approve(%L)$q$, s1)), 'ERROR: only a reviewed settlement can be approved');
  perform tests.assert_eq('the manager reviews it', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_review(%L)$q$, s1)), 'reviewed');
  perform tests.assert_eq('...who reviewed it is kept', tests.dj(vowner, 'vowner@st.example', ag1, 'settlement', 'reviewed_by_name'), 'Mia Manager');
  perform tests.assert_eq('it cannot be reviewed twice', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_review(%L)$q$, s1)), 'ERROR: only an estimated settlement can be reviewed');
  perform tests.assert_eq('the manager cannot approve: only the owner', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_approve(%L)$q$, s1)), 'ERROR: not allowed');
  perform tests.assert_eq('the owner can now approve, and the manager still adjusts or changes the sales', tests.can(vowner, 'vowner@st.example', ag1) || ' / ' || tests.can(vmgr, 'vmgr@st.example', ag1), 'adjust,approve,save_sales / adjust,save_sales');
  perform tests.assert_eq('changing the sales after a review sends it back to estimated and clears the review', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 900000, 'Corrected closing report')::text$q$, ag1)) = s1::text and tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'status') = 'estimated' and tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'reviewed_by_name') = 'null', true);
  perform tests.assert_eq('the adjustment is kept when the sales are saved again', tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'payable_cents'), '35000');
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_review(%L)$q$, s1));
  perform tests.assert_eq('adjusting a reviewed settlement sends it back to estimated too', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, 500, 'Rounding')::text$q$, s1)) || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'status'), '35500 estimated');
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, -500, 'Rounding back')::text$q$, s1));
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_review(%L)$q$, s1));
  perform tests.assert_eq('the owner approves', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_approve(%L)$q$, s1)), 'approved');
  perform tests.assert_eq('...who approved it is kept', tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'approved_by_name'), 'Olly Owner');
  perform tests.assert_eq('it cannot be approved twice', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_approve(%L)$q$, s1)), 'ERROR: only a reviewed settlement can be approved');
  perform tests.assert_eq('once approved, the sales cannot be changed', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 1000000, 'Another report')::text$q$, ag1)), 'ERROR: this settlement has been approved: adjust the amount to change it');
  perform tests.assert_eq('the owner can record the payment; the manager cannot; the organizer can acknowledge or question', tests.can(vowner, 'vowner@st.example', ag1) || ' / ' || tests.can(vmgr, 'vmgr@st.example', ag1) || ' / ' || tests.can(oorg, 'org@st.example', ag1), 'adjust,record_payment / adjust / acknowledge,question');
  perform tests.assert_eq('adjusting an approved settlement sends it back to estimated and clears the approval', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, 500, 'Late correction')::text$q$, s1)) = '35500' and tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'status') = 'estimated' and tests.dj(vmgr, 'vmgr@st.example', ag1, 'settlement', 'approved_by_name') = 'null', true);
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, -500, 'Late correction undone')::text$q$, s1));
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_review(%L)$q$, s1));
  perform tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_approve(%L)$q$, s1));

  ---------------------------------------------------------------- recording the payment
  perform tests.assert_eq('the manager cannot record a payment', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_record_payment(%L, 35000, current_date, 'TRF-1001')$q$, s1)), 'ERROR: not allowed');
  perform tests.assert_eq('the organizer cannot mark their own payout paid', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_record_payment(%L, 35000, current_date, 'TRF-1001')$q$, s1)), 'ERROR: not allowed');
  perform tests.assert_eq('a rival cannot', tests.run_as(rival, 'rival@st.example', format($q$select public.settlement_record_payment(%L, 35000, current_date, 'TRF-1001')$q$, s1)), 'ERROR: not allowed');
  perform tests.assert_eq('the amount has to be exactly what was approved', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, 34000, current_date, 'TRF-1001')$q$, s1)), 'ERROR: the amount has to be exactly what was approved: 35000');
  perform tests.assert_eq('...more is no better', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, 36000, current_date, 'TRF-1001')$q$, s1)), 'ERROR: the amount has to be exactly what was approved: 35000');
  perform tests.assert_eq('...and no amount', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, null, current_date, 'TRF-1001')$q$, s1)), 'ERROR: the amount has to be exactly what was approved: 35000');
  perform tests.assert_eq('a date in the future is refused', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, 35000, current_date + 5, 'TRF-1001')$q$, s1)), 'ERROR: choose the date it was paid (not in the future)');
  perform tests.assert_eq('...and no date', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, 35000, null, 'TRF-1001')$q$, s1)), 'ERROR: choose the date it was paid (not in the future)');
  perform tests.assert_eq('a reference is needed', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, 35000, current_date, ' ')$q$, s1)), 'ERROR: enter a reference for the payment (3 to 120 characters)');
  perform tests.assert_eq('...of a sensible length', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, 35000, current_date, %L)$q$, s1, repeat('r', 121))), 'ERROR: enter a reference for the payment (3 to 120 characters)');
  perform tests.assert_eq('the evidence note is short', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, 35000, current_date, 'TRF-1001', %L)$q$, s1, repeat('e', 301))), 'ERROR: keep the evidence note to 300 characters or fewer');
  perform tests.assert_eq('nothing was recorded by the refusals', tests.dj(vowner, 'vowner@st.example', ag1, 'settlement', 'status'), 'approved');
  perform tests.assert_eq('the owner records the payment made outside BottlesUp', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, 35000, current_date, 'TRF-1001', 'Bank transfer confirmation, screenshot kept')$q$, s1)), 'paid');
  perform tests.assert_eq('it says paid, in whose hands the record was, and labels it a recorded external payment', tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'status') || ' / ' || tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'payment_label') || ' / ' || tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'paid_recorded_by_name'), 'paid / Recorded external payment / Olly Owner');
  perform tests.assert_eq('...with the amount, the reference and the evidence', tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'paid_amount_cents') || ' ' || tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'payment_reference') || ' ' || tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'payment_evidence'), '35000 TRF-1001 Bank transfer confirmation, screenshot kept');
  perform tests.assert_eq('a paid settlement is final: nothing but the organizer''s acknowledgement is left to do', tests.can(vowner, 'vowner@st.example', ag1) || ' / ' || tests.can(vmgr, 'vmgr@st.example', ag1) || ' / ' || tests.can(oorg, 'org@st.example', ag1), '(nothing) / (nothing) / acknowledge');
  perform tests.assert_eq('it cannot be recorded twice', tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_record_payment(%L, 35000, current_date, 'TRF-1002')$q$, s1)), 'ERROR: only an approved settlement can have its payment recorded');
  perform tests.assert_eq('no adjustment after payment', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, -100, 'Later refund')::text$q$, s1)), 'ERROR: this settlement has been paid: adjustments after payment are not recorded yet');
  perform tests.assert_eq('no change of the sales after payment', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 1000000, 'Another report')::text$q$, ag1)), 'ERROR: this settlement has been paid');
  perform tests.assert_eq('no question after payment', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_question(%L, 'Why is it this much?')$q$, s1)), 'ERROR: this settlement has been paid');
  perform tests.assert_eq('the organizer acknowledges it, once', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_acknowledge(%L)::text$q$, s1)) || ' ' || tests.run_as(ostaff, 'ostaff@st.example', format($q$select public.settlement_acknowledge(%L)::text$q$, s1)), 'true false');
  perform tests.assert_eq('...and it says who and when', tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'organizer_ack_by_name') || ' ' || (tests.dj(oorg, 'org@st.example', ag1, 'settlement', 'organizer_ack_at') <> 'null')::text, 'Olive Organizer true');
  perform tests.assert_eq('nothing left to do for anyone', tests.can(oorg, 'org@st.example', ag1), '(nothing)');

  ---------------------------------------------------------------- the history
  perform tests.assert_eq('every step of the first settlement is in the history, in order, with the side that took it',
    tests.logrows(ag1),
    'venue:sales_saved:->estimated | venue:sales_saved:estimated>estimated | venue:sales_saved:estimated>estimated | venue:sales_saved:estimated>estimated | venue:adjusted:estimated>estimated | venue:adjusted:estimated>estimated | venue:adjusted:estimated>estimated | venue:reviewed:estimated>reviewed | venue:sales_saved:reviewed>estimated | venue:reviewed:estimated>reviewed | venue:adjusted:reviewed>estimated | venue:adjusted:estimated>estimated | venue:reviewed:estimated>reviewed | venue:approved:reviewed>approved | venue:adjusted:approved>estimated | venue:adjusted:estimated>estimated | venue:reviewed:estimated>reviewed | venue:approved:reviewed>approved | venue:payment_recorded:approved>paid | organizer:acknowledged:paid>paid');
  perform tests.assert_eq('the detail shows the history newest first, with who did it, and "by me"', tests.dj(vowner, 'vowner@st.example', ag1, 'log', '1', 'action') || ' ' || tests.dj(vowner, 'vowner@st.example', ag1, 'log', '1', 'by_name') || ' ' || tests.dj(vowner, 'vowner@st.example', ag1, 'log', '1', 'by_me') || ' / ' || tests.dj(vowner, 'vowner@st.example', ag1, 'log', '0', 'action') || ' ' || tests.dj(vowner, 'vowner@st.example', ag1, 'log', '0', 'by_me'),
    'payment_recorded Olly Owner true / acknowledged false');
  perform tests.assert_eq('the payment line in the history says it was recorded, not made', tests.dj(oorg, 'org@st.example', ag1, 'log', '1', 'note'), 'Recorded external payment: TRF-1001');

  ---------------------------------------------------------------- the organizer questions, and the club answers (second settlement)
  s4 := tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 700000, 'Closing report of Sat')::text$q$, ag4))::uuid;
  perform tests.assert_eq('the second settlement starts estimated: 10 percent of the 2000 above the threshold', tests.dj(vmgr, 'vmgr@st.example', ag4, 'settlement', 'status') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag4, 'settlement', 'share_cents'), 'estimated 20000');
  perform tests.assert_eq('there is nothing to acknowledge until it is approved', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_acknowledge(%L)::text$q$, s4)), 'ERROR: there is nothing to acknowledge until it has been approved');
  perform tests.assert_eq('a rival cannot acknowledge', tests.run_as(rival, 'rival@st.example', format($q$select public.settlement_acknowledge(%L)::text$q$, s4)), 'ERROR: not allowed');

  -- the terms are copied: a renegotiation does not move a settlement that is being worked on, until the sales are saved again
  perform tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'We would like 20 percent')::text$q$, ag4, replace(terms1, '"bar_percent":10', '"bar_percent":20')));
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.agreement_accept(%L, 2)::text$q$, ag4));
  perform tests.assert_eq('the settlement keeps the terms it was worked out with (version 1, 10 percent, 20000)', tests.dj(vmgr, 'vmgr@st.example', ag4, 'agreement_version') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag4, 'terms', 'bar_percent') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag4, 'settlement', 'share_cents'), '1 10 20000');
  perform tests.assert_eq('saving the sales again takes the terms now in force (version 2, 20 percent, 40000)', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 700000, 'Closing report of Sat')::text$q$, ag4)) = s4::text
    and tests.dj(vmgr, 'vmgr@st.example', ag4, 'agreement_version') = '2' and tests.dj(vmgr, 'vmgr@st.example', ag4, 'terms', 'bar_percent') = '20' and tests.dj(vmgr, 'vmgr@st.example', ag4, 'settlement', 'share_cents') = '40000', true);

  perform tests.assert_eq('a question needs a reason', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_question(%L, 'why')$q$, s4)), 'ERROR: say what you are asking (5 to 500 characters)');
  perform tests.assert_eq('...and not at length', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_question(%L, %L)$q$, s4, repeat('q', 501))), 'ERROR: say what you are asking (5 to 500 characters)');
  perform tests.assert_eq('the club''s manager cannot ask on the organizer''s behalf', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_question(%L, 'Is this right?')$q$, s4)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a rival, a server or a stranger', tests.run_as(rival, 'rival@st.example', format($q$select public.settlement_question(%L, 'Is this right?')$q$, s4)) || ' ' || tests.run_as(vsrv, 'vsrv@st.example', format($q$select public.settlement_question(%L, 'Is this right?')$q$, s4)) || ' ' || tests.run_as(rando, 'rando@st.example', format($q$select public.settlement_question(%L, 'Is this right?')$q$, s4)), 'ERROR: not allowed ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('the organizer questions the figure', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_question(%L, 'Our records show more bar sales than this')$q$, s4)), 'disputed');
  perform tests.assert_eq('...the reason is kept and shown to both sides', tests.dj(vmgr, 'vmgr@st.example', ag4, 'settlement', 'disputed_reason') || ' / ' || tests.dj(oorg, 'org@st.example', ag4, 'settlement', 'disputed_reason'), 'Our records show more bar sales than this / Our records show more bar sales than this');
  perform tests.assert_eq('while a question is open nobody can review, approve or change the sales', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_review(%L)$q$, s4)) || ' | ' || tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'New report')::text$q$, ag4)),
    'ERROR: only an estimated settlement can be reviewed | ERROR: the organizer has asked a question: answer it first');
  perform tests.assert_eq('a second question is refused while one is open', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_question(%L, 'Another thing to ask')$q$, s4)), 'ERROR: a question is already open');
  perform tests.assert_eq('the club can answer it or adjust; the organizer can do nothing', tests.can(vmgr, 'vmgr@st.example', ag4) || ' / ' || tests.can(oorg, 'org@st.example', ag4), 'adjust,resolve / (nothing)');
  perform tests.assert_eq('an adjustment while the question is open keeps it open', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_adjust(%L, 1000, 'Agreed to add a late sale')::text$q$, s4)) || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag4, 'settlement', 'status'), '41000 disputed');
  perform tests.assert_eq('the organizer cannot answer their own question', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_resolve(%L, 'Fine as it is')$q$, s4)), 'ERROR: not allowed');
  perform tests.assert_eq('the answer has to be written', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_resolve(%L, ' ')$q$, s4)), 'ERROR: write your answer (3 to 500 characters)');
  perform tests.assert_eq('the club answers, and the settlement goes back to estimated', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_resolve(%L, 'Added the late sale you pointed out')$q$, s4)) || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag4, 'settlement', 'status') || ' ' || tests.dj(vmgr, 'vmgr@st.example', ag4, 'settlement', 'disputed_reason'), 'estimated estimated null');
  perform tests.assert_eq('there is then no open question', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_resolve(%L, 'Again')$q$, s4)), 'ERROR: there is no open question');
  perform tests.assert_eq('the organizer cannot approve, review, adjust, enter sales or resolve', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_approve(%L)$q$, s4)) || ' ' || tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_review(%L)$q$, s4)) || ' ' || tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_adjust(%L, 10, 'Please')::text$q$, s4)) || ' ' || tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_save_sales(%L, 1, 'Please')::text$q$, ag4)),
    'ERROR: not allowed ERROR: not allowed ERROR: not allowed ERROR: not allowed');
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_review(%L)$q$, s4));
  perform tests.run_as(vowner, 'vowner@st.example', format($q$select public.settlement_approve(%L)$q$, s4));
  perform tests.assert_eq('the organizer acknowledges the approved settlement', tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_acknowledge(%L)::text$q$, s4)), 'true');
  perform tests.assert_eq('...and may still question it before it is paid, which clears the acknowledgement, the review and the approval',
    tests.run_as(oorg, 'org@st.example', format($q$select public.settlement_question(%L, 'We now think the late sales are missing too')$q$, s4)) || ' ' || tests.dj(oorg, 'org@st.example', ag4, 'settlement', 'organizer_ack_at') || ' ' || tests.dj(oorg, 'org@st.example', ag4, 'settlement', 'approved_by_name') || ' ' || tests.dj(oorg, 'org@st.example', ag4, 'settlement', 'reviewed_by_name'),
    'disputed null null null');
  perform tests.assert_eq('the second settlement''s history names who asked and who answered', tests.logrows(ag4),
    'venue:sales_saved:->estimated | venue:sales_saved:estimated>estimated | organizer:questioned:estimated>disputed | venue:adjusted:disputed>disputed | venue:resolved:disputed>estimated | venue:reviewed:estimated>reviewed | venue:approved:reviewed>approved | organizer:acknowledged:approved>approved | organizer:questioned:approved>disputed');

  ---------------------------------------------------------------- an agreement that ends
  ag5 := tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev5, venue_a))::uuid;
  perform tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'ten percent')::text$q$, ag5, terms1));
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag5));
  ag6 := tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev6, venue_a))::uuid;
  perform tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'ten percent')::text$q$, ag6, terms1));
  perform tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag6));
  perform tests.assert_eq('two more active agreements are listed, waiting for their sales', tests.lv(vmgr, 'vmgr@st.example', venue_a) like '%Night Five:-:10:-%' and tests.lv(vmgr, 'vmgr@st.example', venue_a) like '%Night Six:-:10:-%', true);
  s5 := tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Sun')::text$q$, ag5))::uuid;
  perform tests.assert_true('the organizer ends both agreements', tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_close(%L, 'The event moved to another club')::text$q$, ag5)) not like 'ERROR%'
    and tests.run_as(oorg, 'org@st.example', format($q$select public.agreement_close(%L, 'The event moved to another club')::text$q$, ag6)) not like 'ERROR%');
  perform tests.assert_eq('an ended agreement with no settlement drops out of both lists', (tests.lv(vmgr, 'vmgr@st.example', venue_a) like '%Night Six%')::text || ' ' || (tests.lo(oorg, 'org@st.example', oorg_id) like '%Night Six%')::text, 'false false');
  perform tests.assert_eq('...and one that already has a settlement stays', tests.lv(vmgr, 'vmgr@st.example', venue_a) like '%Night Five:estimated:10:30000%', true);
  perform tests.assert_eq('sales cannot be entered or changed for an ended agreement', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 800000, 'Closing report of Sun')::text$q$, ag6)) || ' | ' || tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_save_sales(%L, 900000, 'Corrected report')::text$q$, ag5)),
    'ERROR: this agreement is not active, so there is nothing to settle yet | ERROR: this agreement is not active, so there is nothing to settle yet');
  perform tests.assert_eq('the settlement that exists can still be adjusted and reviewed, but its sales are fixed', tests.can(vmgr, 'vmgr@st.example', ag5), 'adjust,review');
  perform tests.assert_eq('...and carried through', tests.run_as(vmgr, 'vmgr@st.example', format($q$select public.settlement_review(%L)$q$, s5)), 'reviewed');

  ---------------------------------------------------------------- nothing else moves, and the tables are closed
  perform tests.logout();
  perform tests.assert_eq('BottlesUp''s own payout items were not touched', (select count(*) from public.site_payout_items), payouts_before);
  perform tests.assert_eq('there is one settlement per agreement, three in all', (select count(*) from public.site_settlements)::int, 3);
  perform tests.login(vmgr, 'vmgr@st.example');
  perform tests.assert_raises('a signed-in person cannot read the settlements table', 'select * from public.site_settlements', 'permission denied');
  perform tests.assert_raises('...nor the history', 'select * from public.site_settlement_log', 'permission denied');
  perform tests.assert_raises('...nor change a settlement directly', format($q$update public.site_settlements set status = 'paid' where id = %L$q$, s1), 'permission denied');
  perform tests.assert_raises('...nor write history', format($q$insert into public.site_settlement_log (settlement_id, side, action) values (%L, 'venue', 'approved')$q$, s1), 'permission denied');
  perform tests.assert_raises('...nor call the internal history writer', format($q$select public.settlement_log_add(%L, 'venue', 'approved', null, null, null, null)$q$, s1), 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the table', 'select * from public.site_settlements', 'permission denied');
  perform tests.logout();
  perform tests.assert_true('the database refuses a paid settlement without its payment, a disputed one without its reason, and an adjustment without a note',
    (select count(*) = 3 from pg_constraint c where c.conrelid = 'public.site_settlements'::regclass and c.conname in ('site_settlements_paid_check', 'site_settlements_disputed_check', 'site_settlements_adjustment_needs_note')));
  perform tests.assert_raises('...a paid settlement without a reference', format($q$update public.site_settlements set status = 'paid' where id = %L$q$, s4), 'site_settlements_paid_check');
  perform tests.assert_raises('...an amount owed below zero', format($q$update public.site_settlements set adjustment_cents = -99999999 where id = %L$q$, s4), 'site_settlements_payable_check');
  perform tests.assert_true('every function runs with its owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%') from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname in ('settlements_for_venue', 'settlements_for_organizer', 'settlement_detail', 'settlement_save_sales', 'settlement_adjust', 'settlement_review', 'settlement_approve', 'settlement_record_payment', 'settlement_question', 'settlement_resolve', 'settlement_acknowledge', 'settlement_log_add')));
  perform tests.assert_true('visitors cannot run any of the eleven, signed-in people and the service role can (each function decides who may)',
    (select bool_and(not has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('service_role', p.oid, 'execute')) from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname in ('settlements_for_venue', 'settlements_for_organizer', 'settlement_detail', 'settlement_save_sales', 'settlement_adjust', 'settlement_review', 'settlement_approve', 'settlement_record_payment', 'settlement_question', 'settlement_resolve', 'settlement_acknowledge')));
  perform tests.assert_true('the internal helpers cannot be called by anyone signed in',
    not has_function_privilege('authenticated', 'public.settlement_log_add(uuid, text, text, text, text, bigint, text)', 'execute') and not has_function_privilege('authenticated', 'public.settlement_base(jsonb, bigint)', 'execute'));
end $$;

rollback;
