-- Venue linking and event agreements. What matters most: only the organizer of an event asks a club; the club's manager/owner answer; terms
-- are versions that are never edited; each side accepts the LATEST version and an old one cannot be accepted; the two acceptances come from two
-- different people even if one business is on both sides; a share of bar sales cannot be agreed without a threshold, a formula, eligible
-- revenue, refunds and taxes/tips/fees spelled out; "above the threshold" and "all sales once reached" give different amounts; each side sees only
-- agreements it is party to; agreements are kept and every step is attributed.
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
create function tests.list_for_venue(p_user uuid, p_email text, p_venue uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(event_title || ':' || status || ':v' || current_version || ':' || coalesce(waiting_on, '-'), ' | ' order by event_title) from public.agreement_list(p_venue, null)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.list_for_org(p_user uuid, p_email text, p_org uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(event_title || ':' || status || ':v' || current_version || ':' || coalesce(waiting_on, '-'), ' | ' order by event_title) from public.agreement_list(null, p_org)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  vowner constant uuid := '00000000-0000-0000-0000-0000000009d1';
  vmgr constant uuid := '00000000-0000-0000-0000-0000000009d2';
  vmgr_b constant uuid := '00000000-0000-0000-0000-0000000009d3';
  vsrv constant uuid := '00000000-0000-0000-0000-0000000009d4';
  oorg constant uuid := '00000000-0000-0000-0000-0000000009d5';  -- the organizer's business (organizer role)
  ostaff constant uuid := '00000000-0000-0000-0000-0000000009d6';
  both_u constant uuid := '00000000-0000-0000-0000-0000000009d7';  -- owns a club AND runs events: on both sides
  rando constant uuid := '00000000-0000-0000-0000-0000000009d8';
  vorg uuid; oorg_id uuid; both_org uuid; venue_a uuid; venue_b uuid; venue_c uuid; ev1 uuid; ev2 uuid; ev_both uuid; ag uuid; ag2 uuid; ag_both uuid; r text; j jsonb; n int;
  terms1 constant text := '{"starts":"21:00","ends":"03:00","rooms":"Main room","capacity":400,"ticket_ownership":"organizer","bar_percent":10,"threshold_cents":500000,"formula":"above_threshold","eligible_revenue":"bar sales net of tax","refunds":"deducted","taxes_tips_fees":"excluded"}';
begin
  insert into auth.users (id, email) values
    (vowner, 'vowner@agr.example'), (vmgr, 'vmgr@agr.example'), (vmgr_b, 'vmgrb@agr.example'), (vsrv, 'vsrv@agr.example'), (oorg, 'org@agr.example'),
    (ostaff, 'ostaff@agr.example'), (both_u, 'both@agr.example'), (rando, 'rando@agr.example');
  insert into public.profiles (id, name, email) values (vmgr, 'Mia Manager', 'vmgr@agr.example'), (oorg, 'Olive Organizer', 'org@agr.example'), (vowner, 'Olly Owner', 'vowner@agr.example');

  perform tests.login(vowner, 'vowner@agr.example');
  vorg := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(vorg, 'Club A');
  venue_b := public.create_org_venue(vorg, 'Club B');
  perform tests.join_as(vowner, 'vowner@agr.example', vorg, 'vmgr@agr.example', 'manager', venue_a, vmgr);
  perform tests.join_as(vowner, 'vowner@agr.example', vorg, 'vmgrb@agr.example', 'manager', venue_b, vmgr_b);
  perform tests.join_as(vmgr, 'vmgr@agr.example', vorg, 'vsrv@agr.example', 'server', venue_a, vsrv);
  perform tests.login(oorg, 'org@agr.example');
  oorg_id := public.create_organization('Night Events', 'organizer');
  perform tests.login(both_u, 'both@agr.example');
  both_org := public.create_organization('Both Co', 'venue_owner');
  venue_c := public.create_org_venue(both_org, 'Club C');
  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night One', 'x', 'Somewhere', now() + interval '10 days', now() + interval '10 days 6 hours', 'draft', oorg_id) returning id into ev1;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Night Two', 'x', 'Somewhere', now() + interval '20 days', now() + interval '20 days 6 hours', 'draft', oorg_id) returning id into ev2;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Both Night', 'x', 'Somewhere', now() + interval '12 days', now() + interval '12 days 6 hours', 'draft', both_org) returning id into ev_both;
  -- a second person at the organizer business
  insert into public.site_memberships (org_id, user_id, role) values (oorg_id, ostaff, 'organizer');

  ---------------------------------------------------------------- asking for a link
  r := tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_request(%L, %L, 'Friday 24th, around 400 guests')::text$q$, ev1, venue_a));
  perform tests.assert_true('the organizer asks a club to host an event', r not like 'ERROR%');
  ag := r::uuid;
  perform tests.assert_eq('a second request for the same event and club is refused', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev1, venue_a)), 'ERROR: this event already has an agreement with that club');
  perform tests.assert_true('...but the same event can ask another club', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev1, venue_b)) not like 'ERROR%');
  perform tests.assert_eq('a club''s manager cannot ask for someone else''s event', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev1, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.run_as(rando, 'rando@agr.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev2, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('a long message is refused', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_request(%L, %L, %L)::text$q$, ev2, venue_a, repeat('x', 501))), 'ERROR: keep the message to 500 characters or fewer');
  perform tests.assert_eq('a club that does not exist', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev2, gen_random_uuid())), 'ERROR: choose a club');

  ---------------------------------------------------------------- who sees what
  perform tests.assert_eq('the club''s manager sees the request, waiting on the club', tests.list_for_venue(vmgr, 'vmgr@agr.example', venue_a), 'Night One:requested:v0:venue');
  perform tests.assert_eq('the owner of the club sees it too', tests.list_for_venue(vowner, 'vowner@agr.example', venue_a), 'Night One:requested:v0:venue');
  perform tests.assert_eq('the organizer sees their request', tests.list_for_org(oorg, 'org@agr.example', oorg_id), 'Night One:requested:v0:venue | Night One:requested:v0:venue');
  perform tests.assert_eq('a second person at the organizer business sees it', tests.list_for_org(ostaff, 'ostaff@agr.example', oorg_id) like 'Night One:%', true);
  perform tests.assert_eq('another club''s manager sees nothing of club A', tests.list_for_venue(vmgr_b, 'vmgrb@agr.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('...their own club has only its own request', tests.list_for_venue(vmgr_b, 'vmgrb@agr.example', venue_b), 'Night One:requested:v0:venue');
  perform tests.assert_eq('a server sees none', tests.list_for_venue(vsrv, 'vsrv@agr.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('the club''s people cannot read the organizer''s list', tests.list_for_org(vmgr, 'vmgr@agr.example', oorg_id), 'ERROR: not allowed');
  perform tests.assert_eq('the organizer cannot read a club''s list', tests.list_for_venue(oorg, 'org@agr.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('one scope at a time', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select count(*)::text from public.agreement_list(%L, %L)$q$, venue_a, oorg_id)), 'ERROR: choose a club or a business');
  perform tests.assert_eq('a stranger cannot read an agreement', tests.run_as(rando, 'rando@agr.example', format($q$select public.agreement_detail(%L)::text$q$, ag)), 'ERROR: not allowed');
  perform tests.assert_eq('another club cannot read it', tests.run_as(vmgr_b, 'vmgrb@agr.example', format($q$select public.agreement_detail(%L)::text$q$, ag)), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot', tests.run_as(vsrv, 'vsrv@agr.example', format($q$select public.agreement_detail(%L)::text$q$, ag)), 'ERROR: not allowed');

  ---------------------------------------------------------------- nothing to accept before something is proposed
  perform tests.assert_eq('there is nothing to accept yet', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag)), 'ERROR: nothing has been proposed yet');

  ---------------------------------------------------------------- the terms are checked
  perform tests.assert_eq('terms that are not terms', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{}')::text$q$, ag)), 'ERROR: propose at least one term');
  perform tests.assert_eq('a term that does not exist', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"free_drinks":true}')::text$q$, ag)), 'ERROR: unknown field: free_drinks');
  perform tests.assert_eq('a share of sales needs a threshold', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"bar_percent":10}')::text$q$, ag)), 'ERROR: a share of bar sales needs a threshold (0 if it applies from the first sale)');
  perform tests.assert_eq('...and a formula', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"bar_percent":10,"threshold_cents":0}')::text$q$, ag)), 'ERROR: say whether the share is of sales ABOVE the threshold or of ALL sales once it is reached');
  perform tests.assert_eq('...and which revenue counts', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"bar_percent":10,"threshold_cents":0,"formula":"above_threshold"}')::text$q$, ag)), 'ERROR: say which revenue counts towards the share');
  perform tests.assert_eq('...and how refunds are treated', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"bar_percent":10,"threshold_cents":0,"formula":"above_threshold","eligible_revenue":"bar"}')::text$q$, ag)), 'ERROR: say how refunds are treated');
  perform tests.assert_eq('...and taxes, tips and fees', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"bar_percent":10,"threshold_cents":0,"formula":"above_threshold","eligible_revenue":"bar","refunds":"deducted"}')::text$q$, ag)), 'ERROR: say how taxes, tips and fees are treated');
  perform tests.assert_eq('a formula that is neither', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"bar_percent":10,"threshold_cents":0,"formula":"whatever"}')::text$q$, ag)), 'ERROR: formula must be above_threshold or all_once_reached');
  perform tests.assert_eq('a percentage over 100', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"bar_percent":101}')::text$q$, ag)), 'ERROR: bar percentage must be between 0 and 100');
  perform tests.assert_eq('...with three decimals', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"bar_percent":10.123}')::text$q$, ag)), 'ERROR: bar percentage can have at most two decimals');
  perform tests.assert_eq('a time that is not a time', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"starts":"9pm"}')::text$q$, ag)), 'ERROR: start time must be a time like 21:00');
  perform tests.assert_eq('a ticket owner that does not exist', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"ticket_ownership":"nobody"}')::text$q$, ag)), 'ERROR: ticket ownership must be organizer, venue or shared');
  perform tests.assert_eq('a capacity of nothing', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"capacity":0}')::text$q$, ag)), 'ERROR: capacity must be between 1 and 100000');
  perform tests.assert_eq('a share of nothing needs none of that', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, '{"bar_percent":0,"capacity":300}')::text$q$, ag)) , '1');
  perform tests.assert_eq('a stranger, a server and another club cannot propose', tests.run_as(rando, 'rando@agr.example', format($q$select public.agreement_propose(%L, '{"capacity":300}')::text$q$, ag))
    || ' ' || tests.run_as(vsrv, 'vsrv@agr.example', format($q$select public.agreement_propose(%L, '{"capacity":300}')::text$q$, ag)) || ' ' || tests.run_as(vmgr_b, 'vmgrb@agr.example', format($q$select public.agreement_propose(%L, '{"capacity":300}')::text$q$, ag)),
    'ERROR: not allowed ERROR: not allowed ERROR: not allowed');

  ---------------------------------------------------------------- negotiation: version 2 from the organizer replaces version 1
  perform tests.assert_eq('the organizer counters with full terms: version 2', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'We would like 10 percent of bar sales above 5000')::text$q$, ag, terms1)), '2');
  perform tests.assert_eq('the agreement is being negotiated, waiting on the club', tests.list_for_venue(vmgr, 'vmgr@agr.example', venue_a), 'Night One:negotiating:v2:venue');
  perform tests.assert_eq('the club cannot accept the old version', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_accept(%L, 1)::text$q$, ag)), 'ERROR: that version was replaced: read the latest one');
  perform tests.assert_eq('the organizer cannot accept their own proposal again', tests.run_as(oorg, 'org@agr.example', format($q$select (public.agreement_accept(%L, 2)) ->> 'changed'$q$, ag)), 'false');
  perform tests.assert_eq('the detail shows both versions, the latest first, with who proposed and accepted', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select (d -> 'versions' -> 0 ->> 'version') || ' ' || (d -> 'versions' -> 0 ->> 'proposed_by_name') || ' ' || (d -> 'versions' -> 0 ->> 'organizer_accepted_by_name') || ' ' || coalesce(d -> 'versions' -> 0 ->> 'venue_accepted_at', 'not yet') || ' ' || jsonb_array_length(d -> 'versions') from (select public.agreement_detail(%L) d) x$q$, ag)),
    '2 Olive Organizer Olive Organizer not yet 2');
  perform tests.assert_eq('the club can accept, and the organizer cannot accept for them', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select (d ->> 'can_accept') || ' ' || (d ->> 'side') from (select public.agreement_detail(%L) d) x$q$, ag)) || ' / ' || tests.run_as(oorg, 'org@agr.example', format($q$select (d ->> 'can_accept') || ' ' || (d ->> 'side') from (select public.agreement_detail(%L) d) x$q$, ag)),
    'true venue / false organizer');
  perform tests.assert_eq('the club asks questions', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_note(%L, 'Can we move the threshold to 6000?')::text$q$, ag)) like '%-%-%', true);
  perform tests.assert_eq('...and the organizer reads and answers', tests.run_as(oorg, 'org@agr.example', format($q$select (d -> 'notes' -> 0 ->> 'author_name') || ':' || (d -> 'notes' -> 0 ->> 'side') || ':' || (d -> 'notes' -> 0 ->> 'is_mine') from (select public.agreement_detail(%L) d) x$q$, ag)), 'Mia Manager:venue:false');
  perform tests.assert_eq('an empty note is refused', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_note(%L, ' ')::text$q$, ag)), 'ERROR: write the note first');
  perform tests.assert_eq('a stranger cannot join the discussion', tests.run_as(rando, 'rando@agr.example', format($q$select public.agreement_note(%L, 'hello')::text$q$, ag)), 'ERROR: not allowed');

  ---------------------------------------------------------------- the club counters: version 3 (threshold 6000)
  perform tests.assert_eq('the club proposes version 3', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'Threshold 6000 please')::text$q$, ag, replace(terms1, '500000', '600000'))), '3');
  perform tests.assert_eq('the organizer cannot now accept version 2', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_accept(%L, 2)::text$q$, ag)), 'ERROR: that version was replaced: read the latest one');
  perform tests.assert_eq('the earlier versions are kept as they were', tests.run_as(oorg, 'org@agr.example', format($q$select ((d -> 'versions' -> 1 -> 'terms' ->> 'threshold_cents') || '/' || (d -> 'versions' -> 0 -> 'terms' ->> 'threshold_cents')) from (select public.agreement_detail(%L) d) x$q$, ag)), '500000/600000');
  perform tests.assert_eq('the organizer accepts version 3: it is active', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_accept(%L, 3)::text$q$, ag)), '{"status": "active", "changed": true, "version": 3}');
  perform tests.assert_eq('...both are recorded, by two different people', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select ((d -> 'versions' -> 0 ->> 'organizer_accepted_by_name') || '/' || (d -> 'versions' -> 0 ->> 'venue_accepted_by_name') || '/' || (d -> 'versions' -> 0 ->> 'is_active')) from (select public.agreement_detail(%L) d) x$q$, ag)), 'Olive Organizer/Mia Manager/true');
  perform tests.assert_eq('the list shows it active', tests.list_for_venue(vmgr, 'vmgr@agr.example', venue_a), 'Night One:active:v3:-');
  perform tests.assert_eq('accepting again changes nothing', tests.run_as(oorg, 'org@agr.example', format($q$select (public.agreement_accept(%L, 3)) ->> 'changed'$q$, ag)), 'false');

  ---------------------------------------------------------------- changing an active agreement
  perform tests.assert_eq('a change to an active agreement is a new version; the old one stays in force', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_propose(%L, %L::jsonb, 'Capacity 350')::text$q$, ag, replace(replace(terms1, '500000', '600000'), '400', '350'))), '4');
  perform tests.assert_eq('...it is waiting on the organizer, and version 3 is still the active one', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select (status || ' ' || coalesce(waiting_on, '-') || ' ' || active_version || ' ' || current_version) from public.agreement_list(%L, null)$q$, venue_a)), 'changes_pending organizer 3 4');
  perform tests.assert_eq('the organizer accepts the change: version 4 is active', tests.run_as(ostaff, 'ostaff@agr.example', format($q$select (public.agreement_accept(%L, 4)) ->> 'version'$q$, ag)), '4');

  ---------------------------------------------------------------- the sample calculation
  j := '{"bar_percent":10,"threshold_cents":500000,"formula":"above_threshold"}'::jsonb;
  perform tests.assert_eq('10% of sales ABOVE the threshold: on 800,000 that is 30,000', public.agreement_sample(j, 800000), 30000::bigint);
  perform tests.assert_eq('...nothing below it', public.agreement_sample(j, 400000), 0::bigint);
  perform tests.assert_eq('10% of ALL sales once the threshold is reached: on 800,000 that is 80,000', public.agreement_sample(j || '{"formula":"all_once_reached"}', 800000), 80000::bigint);
  perform tests.assert_eq('...nothing if it is not reached', public.agreement_sample(j || '{"formula":"all_once_reached"}', 499999), 0::bigint);
  perform tests.assert_eq('...and all of it exactly at the threshold', public.agreement_sample(j || '{"formula":"all_once_reached"}', 500000), 50000::bigint);
  perform tests.assert_eq('a share of nothing is nothing', public.agreement_sample('{"formula":"above_threshold"}', 800000), 0::bigint);
  perform tests.assert_eq('pennies round to the nearest cent', public.agreement_sample('{"bar_percent":12.5,"threshold_cents":0,"formula":"above_threshold"}', 1001), 125::bigint);
  perform tests.assert_eq('no sales, no share', public.agreement_sample(j, null), 0::bigint);

  ---------------------------------------------------------------- two different people, even on both sides
  r := tests.run_as(both_u, 'both@agr.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev_both, venue_c));
  ag_both := r::uuid;
  perform tests.assert_eq('a business on both sides proposes as the organizer', tests.run_as(both_u, 'both@agr.example', format($q$select public.agreement_propose(%L, '{"capacity":200}')::text$q$, ag_both)), '1');
  perform tests.assert_eq('...and cannot then accept as the club', tests.run_as(both_u, 'both@agr.example', format($q$select public.agreement_accept(%L, 1, 'venue')::text$q$, ag_both)), 'ERROR: the other side has to accept this: it cannot be the same person');
  perform tests.assert_eq('...nothing is active', tests.run_as(both_u, 'both@agr.example', format($q$select (d ->> 'status') || ' ' || (d ->> 'can_accept') from (select public.agreement_detail(%L, 'venue') d) x$q$, ag_both)), 'negotiating false');
  perform tests.assert_eq('they are not offered the accept button as the club either', tests.run_as(both_u, 'both@agr.example', format($q$select (d ->> 'side') from (select public.agreement_detail(%L, 'venue') d) x$q$, ag_both)), 'venue');

  ---------------------------------------------------------------- declining and withdrawing
  ag2 := tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev2, venue_a))::uuid;
  perform tests.assert_eq('the club needs a reason to decline', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_close(%L, ' ')::text$q$, ag2)), 'ERROR: say why');
  perform tests.assert_eq('the club declines a request', tests.run_as(vmgr, 'vmgr@agr.example', format($q$select public.agreement_close(%L, 'We are closed that night')::text$q$, ag2)), '');
  perform tests.assert_eq('...it is declined, with the reason', tests.run_as(oorg, 'org@agr.example', format($q$select (d ->> 'status') || ': ' || (d ->> 'closed_reason') from (select public.agreement_detail(%L) d) x$q$, ag2)), 'declined: We are closed that night');
  perform tests.assert_eq('a closed agreement takes no proposal, no acceptance and no second close', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_propose(%L, '{"capacity":100}')::text$q$, ag2)) || ' / '
    || tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_close(%L, 'again')::text$q$, ag2)), 'ERROR: this agreement is closed / ERROR: this agreement is already closed');
  perform tests.assert_true('...the organizer can ask again afterwards', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_request(%L, %L)::text$q$, ev2, venue_a)) not like 'ERROR%');
  perform tests.assert_eq('an active agreement can be withdrawn, with a reason; it is then cancelled', tests.run_as(oorg, 'org@agr.example', format($q$select public.agreement_close(%L, 'The event is cancelled')::text$q$, ag)) || ' ' || tests.run_as(vmgr, 'vmgr@agr.example', format($q$select (d ->> 'status') from (select public.agreement_detail(%L) d) x$q$, ag)), ' cancelled');
  perform tests.assert_eq('a stranger cannot close', tests.run_as(rando, 'rando@agr.example', format($q$select public.agreement_close(%L, 'nope nope')::text$q$, ag_both)), 'ERROR: not allowed');

  ---------------------------------------------------------------- kept, logged, closed
  perform tests.logout();
  perform tests.assert_raises('an event with an agreement cannot be deleted', format('delete from public.site_events where id = %L', ev1), 'violates foreign key constraint');
  perform tests.assert_raises('...nor a club', format('delete from public.site_venues where id = %L', venue_a), 'violates foreign key constraint');
  perform tests.assert_eq('every version is kept, whatever happened to the agreement', (select count(*) from public.site_agreement_versions where agreement_id = ag)::int, 4);
  perform tests.assert_true('every step is attributed', (select count(*) from public.audit_log where action like 'agreement.%' and actor_id is not null) >= 12);
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot ask', format($q$select public.agreement_request(%L, %L)$q$, ev1, venue_a), 'permission denied');
  perform tests.logout();
  perform tests.login(vmgr, 'vmgr@agr.example');
  perform tests.assert_raises('the tables cannot be read directly', 'select * from public.site_agreements', 'permission denied');
  perform tests.assert_raises('...nor the versions', 'select * from public.site_agreement_versions', 'permission denied');
  perform tests.assert_raises('the internal checks cannot be called', 'select public.agreement_check_terms(''{}'')', 'permission denied');
  perform tests.logout();
end $$;

rollback;
