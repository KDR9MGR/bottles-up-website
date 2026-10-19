-- Where an organizer's events stand (20261020120000_org_event_states.sql). What matters: only the organizer of THAT business reads it; the state
-- follows the event (published and not ended = live, ended after its end or 12 hours after its start when it has no end), the club connection (asked and
-- not agreed = awaiting approval, agreed and the business verified = ready to publish), and the blockers say exactly what is missing; a published event
-- has none; another business's events never appear.
begin;

create function tests.list_states(p_user uuid, p_email text, p_org uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(t.title || ':' || s.state || ':' || coalesce(nullif(array_to_string(s.blockers, '+'), ''), '-') || ':' || coalesce(s.agreement_status, '-') || ':' || coalesce(s.venue_name, '-'), ' | ' order by t.title)
                     from public.list_org_event_states(p_org) s join public.site_events t on t.id = s.event_id), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  org_u constant uuid := '00000000-0000-0000-0000-0000000004d1';      -- the organizer
  other_u constant uuid := '00000000-0000-0000-0000-0000000004d2';    -- another business's organizer
  vowner constant uuid := '00000000-0000-0000-0000-0000000004d3';
  rando constant uuid := '00000000-0000-0000-0000-0000000004d4';
  org uuid; org2 uuid; vorg uuid; venue uuid; venue2 uuid; e_two uuid; e_two_wait uuid; e_two_declined uuid; e_plain uuid; e_wait uuid; e_changes_first uuid; e_active uuid; e_active_changes uuid; e_declined uuid;
  e_live uuid; e_ended uuid; e_noend_ended uuid; e_noend_live uuid; e_other uuid; ag uuid; txt text;
begin
  insert into auth.users (id, email) values (org_u, 'org@st.example'), (other_u, 'other@st.example'), (vowner, 'vowner@st.example'), (rando, 'rando@st.example');
  perform tests.login(vowner, 'vowner@st.example');
  vorg := public.create_organization('Club Co', 'venue_owner');
  venue := public.create_org_venue(vorg, 'Club A');
  venue2 := public.create_org_venue(vorg, 'Club B');
  perform tests.login(org_u, 'org@st.example');
  org := public.create_organization('Night Events', 'organizer');
  perform tests.login(other_u, 'other@st.example');
  org2 := public.create_organization('Other Events', 'organizer');
  perform tests.logout();

  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Plain draft', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_plain;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Asked a club', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_wait;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Changes before first terms', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_changes_first;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Club agreed', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_active;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Club agreed, changes asked', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_active_changes;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Club declined', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_declined;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Live one', 'd', 'tbc', now() - interval '2 hours', now() + interval '6 hours', 'published', org) returning id into e_live;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Ended one', 'd', 'tbc', now() - interval '2 days', now() - interval '1 day', 'published', org) returning id into e_ended;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('No end, long ago', 'd', 'tbc', now() - interval '13 hours', null, 'published', org) returning id into e_noend_ended;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('No end, just started', 'd', 'tbc', now() - interval '1 hour', null, 'published', org) returning id into e_noend_live;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Someone else''s', 'd', 'tbc', now() + interval '3 days', now() + interval '4 days', 'draft', org2) returning id into e_other;

  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Asked two clubs', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_two;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Asked two clubs, none agreed', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_two_wait;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Two clubs declined', 'd', 'tbc', now() + interval '10 days', now() + interval '11 days', 'draft', org) returning id into e_two_declined;
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, current_version, active_version, requested_at) values (e_two, venue, org, 'active', org_u, 1, 1, now() - interval '2 days');
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, requested_at) values (e_two, venue2, org, 'requested', org_u, now() - interval '1 day');
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, requested_at) values (e_two_wait, venue, org, 'requested', org_u, now() - interval '2 days');
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, requested_at) values (e_two_wait, venue2, org, 'negotiating', org_u, now() - interval '1 day');
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, closed_by, closed_at, closed_reason) values (e_two_declined, venue, org, 'declined', org_u, vowner, now() - interval '2 days', 'no');
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, closed_by, closed_at, closed_reason) values (e_two_declined, venue2, org, 'declined', org_u, vowner, now() - interval '1 day', 'no');
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by) values (e_wait, venue, org, 'requested', org_u);
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, current_version) values (e_changes_first, venue, org, 'changes_pending', org_u, 1);
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, current_version, active_version) values (e_active, venue, org, 'active', org_u, 1, 1);
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, current_version, active_version) values (e_active_changes, venue, org, 'changes_pending', org_u, 2, 1);
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by, closed_by, closed_at, closed_reason) values (e_declined, venue, org, 'declined', org_u, vowner, now(), 'date taken');

  ---------------------------------------------------------------- who may ask
  perform tests.login(other_u, 'other@st.example');
  perform tests.assert_raises('another business''s organizer cannot read this business''s events', format($q$select * from public.list_org_event_states(%L)$q$, org), 'not allowed');
  perform tests.login(vowner, 'vowner@st.example');
  perform tests.assert_raises('a venue owner is not an organizer', format($q$select * from public.list_org_event_states(%L)$q$, org), 'not allowed');
  perform tests.login(rando, 'rando@st.example');
  perform tests.assert_raises('a person with no role cannot', format($q$select * from public.list_org_event_states(%L)$q$, org), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call it', format($q$select * from public.list_org_event_states(%L)$q$, org), 'permission denied');
  perform tests.login(org_u, 'org@st.example');
  perform tests.assert_raises('a business that is not an organizer business is refused', format($q$select * from public.list_org_event_states(%L)$q$, vorg), 'not allowed');

  ---------------------------------------------------------------- exactly this business's events (checked on the function itself: the test's join below is limited by row level security)
  perform tests.login(org_u, 'org@st.example');
  perform tests.assert_eq('the answer is exactly this business''s 13 events, none of another business''s', (select count(*) from public.list_org_event_states(org))::int, 13);
  perform tests.assert_eq('...and none belongs to the other business', (select count(*) from public.list_org_event_states(org) s where s.event_id = e_other)::int, 0);

  ---------------------------------------------------------------- an unverified business
  txt := tests.list_states(org_u, 'org@st.example', org);
  perform tests.assert_true('a draft with no club asked is a draft, blocked by verification and by having no club', txt like '%Plain draft:draft:business_verification+venue_request:-:-%');
  perform tests.assert_true('asked a club and waiting: awaiting venue approval, with the approval and the verification as blockers', txt like '%Asked a club:awaiting_venue_approval:business_verification+venue_approval:requested:Club A%');
  perform tests.assert_true('first terms not agreed yet while changes are pending: still awaiting approval', txt like '%Changes before first terms:awaiting_venue_approval:business_verification+venue_approval:changes_pending:Club A%');
  perform tests.assert_true('a club that agreed, but the business is not verified: still a draft, blocked only by verification', txt like '%Club agreed:draft:business_verification:active:Club A%');
  perform tests.assert_true('a declined club: a draft, with the decline named', txt like '%Club declined:draft:business_verification+venue_declined:declined:Club A%');
  perform tests.assert_true('a published event that is running is live, with nothing blocking it', txt like '%Live one:live:-:-:-%');
  perform tests.assert_true('a published event whose end has passed is ended', txt like '%Ended one:ended:-:-:-%');
  perform tests.assert_true('a published event with no end is live for 12 hours...', txt like '%No end, just started:live:-%');
  perform tests.assert_true('...and ended after that', txt like '%No end, long ago:ended:-%');
  perform tests.assert_true('another business''s event does not appear', txt not like '%Someone else%');

  ---------------------------------------------------------------- once the business is verified
  perform tests.logout();
  update public.site_verifications set state = 'verified' where org_id = org;
  txt := tests.list_states(org_u, 'org@st.example', org);
  perform tests.assert_true('verified and a club agreed: ready to publish, nothing blocking', txt like '%Club agreed:ready_to_publish:-:active:Club A%');
  perform tests.assert_true('an agreed club with changes asked on top of an agreed version is still ready', txt like '%Club agreed, changes asked:ready_to_publish:-:changes_pending:Club A%');
  perform tests.assert_true('verified but no club asked: draft, blocked only by having no club', txt like '%Plain draft:draft:venue_request:-:-%');
  perform tests.assert_true('verified and waiting for the club: awaiting approval, only the approval blocks', txt like '%Asked a club:awaiting_venue_approval:venue_approval:requested:Club A%');
  perform tests.assert_true('verified and declined: a draft, only the decline blocks', txt like '%Club declined:draft:venue_declined:declined:Club A%');

  perform tests.assert_true('an event asked of two clubs follows the one that agreed, not the later request', txt like '%Asked two clubs:ready_to_publish:-:active:Club A%');
  perform tests.assert_true('asked of two clubs with none agreed: the most recent request counts', txt like '%Asked two clubs, none agreed:awaiting_venue_approval:venue_approval:negotiating:Club B%');
  perform tests.assert_true('declined by two clubs: the most recent decline is named', txt like '%Two clubs declined:draft:venue_declined:declined:Club B%');

  ---------------------------------------------------------------- a request that was cancelled, and a new one made
  perform tests.logout();
  update public.site_agreements set status = 'cancelled', closed_by = org_u, closed_at = now(), closed_reason = 'changed plan' where event_id = e_wait;
  txt := tests.list_states(org_u, 'org@st.example', org);
  perform tests.assert_true('a cancelled request is shown like a declined one', txt like '%Asked a club:draft:venue_declined:cancelled:Club A%');
  perform tests.logout();
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, requested_by) values (e_wait, venue, org, 'requested', org_u);
  txt := tests.list_states(org_u, 'org@st.example', org);
  perform tests.assert_true('a new request after a cancelled one is what counts', txt like '%Asked a club:awaiting_venue_approval:venue_approval:requested:Club A%');

  ---------------------------------------------------------------- how it is declared
  perform tests.assert_true('it is read only, runs with its owner''s rights and a fixed search path',
    (select p.provolatile = 's' and p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%' from pg_proc p where p.proname = 'list_org_event_states'));
end $$;

rollback;
