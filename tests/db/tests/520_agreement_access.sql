-- "Your Venue Access" and the organizer's Sales (20261117100000_agreement_access.sql). What matters: only the CLUB's owner or manager allows or withdraws one of the six things, and only once the
-- agreement is active (never the organizer, another club, or a stranger); nothing is shared unless it is allowed AND the agreement is in force (a declined or cancelled agreement shares nothing whatever
-- rows exist); the database says which things it can supply (three) and the other three are recorded but never shown as connected; the organizer always sees their OWN paid tickets, exact, with
-- refunds told apart and money not added across currencies; a club's tables for the event's business night (after-midnight starts included) only when allowed, with no guest name; another club's data,
-- another business's event, the club itself and event door staff are refused; and reading changes nothing.
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
create function tests.grant_to(p_user uuid, p_email text, p_agreement uuid, p_key text, p_allowed boolean) returns text language sql as $$
  select tests.try(p_user, p_email, format('select public.set_agreement_grant(%L, %L, %L)::text', p_agreement, p_key, p_allowed)) $$;
create function tests.sales(p_user uuid, p_email text, p_event uuid) returns jsonb language plpgsql as $$
declare j jsonb;
begin
  perform tests.login(p_user, p_email);
  j := public.organizer_event_sales(p_event);
  perform tests.logout();
  return j;
exception when others then
  perform tests.logout();
  return jsonb_build_object('error', sqlerrm);
end $$;
create function tests.gdata(j jsonb, p_agreement uuid, p_key text) returns jsonb language sql as $$
  select g -> 'data' from jsonb_array_elements(j -> 'venues') v, jsonb_array_elements(v -> 'grants') g where v ->> 'agreement_id' = p_agreement::text and g ->> 'key' = p_key $$;
create function tests.gflag(j jsonb, p_agreement uuid, p_key text) returns text language sql as $$
  select (g ->> 'allowed') || '/' || (g ->> 'available') from jsonb_array_elements(j -> 'venues') v, jsonb_array_elements(v -> 'grants') g where v ->> 'agreement_id' = p_agreement::text and g ->> 'key' = p_key $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int, p_paid int, p_guests int default 2) returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', p_guests, p_total, p_paid, 'paid', upper(replace(p_name, ' ', '-')))
  returning id $$;

do $$
declare
  org_u constant uuid := '00000000-0000-0000-0000-00000000e0d1';
  org_staff constant uuid := '00000000-0000-0000-0000-00000000e0d2';
  other_u constant uuid := '00000000-0000-0000-0000-00000000e0d3';
  club_owner constant uuid := '00000000-0000-0000-0000-00000000e0d4';
  club_mgr constant uuid := '00000000-0000-0000-0000-00000000e0d5';
  mgr_b constant uuid := '00000000-0000-0000-0000-00000000e0d6';
  door_e constant uuid := '00000000-0000-0000-0000-00000000e0d7';
  rando constant uuid := '00000000-0000-0000-0000-00000000e0d8';
  org uuid; other_org uuid; club_org uuid; venue_a uuid; venue_b uuid; type_a uuid; type_b uuid; slot_a uuid; slot_late uuid; slot_b uuid;
  ev uuid; ev_late uuid; ev_req uuid; ev_other uuid; general uuid; vip uuid; ag uuid; ag_b uuid; ag_req uuid; ag_late uuid;
  night date := current_date + 60;
  j jsonb; n1 bigint; n2 bigint; n3 bigint; n4 bigint;
begin
  insert into auth.users (id, email) values (org_u, 'org@access.example'), (org_staff, 'staff@access.example'), (other_u, 'other@access.example'), (club_owner, 'owner@access.example'),
    (club_mgr, 'mgr@access.example'), (mgr_b, 'mgrb@access.example'), (door_e, 'door@access.example'), (rando, 'rando@access.example');

  perform tests.login(org_u, 'org@access.example');
  org := public.create_organization('Night Events', 'organizer');
  perform tests.login(other_u, 'other@access.example');
  other_org := public.create_organization('Other Events', 'organizer');
  perform tests.login(club_owner, 'owner@access.example');
  club_org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(club_org, 'Club A');
  venue_b := public.create_org_venue(club_org, 'Club B');
  perform tests.logout();
  perform tests.join_as(club_owner, 'owner@access.example', club_org, 'mgr@access.example', 'manager', venue_a, club_mgr);
  perform tests.join_as(club_owner, 'owner@access.example', club_org, 'mgrb@access.example', 'manager', venue_b, mgr_b);
  insert into public.site_memberships (org_id, user_id, role) values (org, org_staff, 'organizer');

  -- Night One is at Club A at 22:00 local; Late Night starts at 01:00 the next morning, which is still the same business night.
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, venue_id, capacity)
    values ('Night One', 'x', 'Club A', (night::timestamp + interval '22 hours') at time zone 'America/Toronto', (night::timestamp + interval '28 hours') at time zone 'America/Toronto', 'published', org, venue_a, 400) returning id into ev;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, venue_id)
    values ('Late Night', 'x', 'Club A', ((night + 1)::timestamp + interval '1 hour') at time zone 'America/Toronto', ((night + 1)::timestamp + interval '5 hours') at time zone 'America/Toronto', 'published', org, venue_a) returning id into ev_late;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Not Yet', 'x', 'TBD', now() + interval '20 days', now() + interval '20 days 5 hours', 'draft', org) returning id into ev_req;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Other Night', 'x', 'Elsewhere', now() + interval '3 days', now() + interval '3 days 6 hours', 'published', other_org) returning id into ev_other;
  insert into public.site_memberships (org_id, user_id, role, event_id) values (org, door_e, 'door', ev);

  -- Agreements: Night One at Club A is ACTIVE (capacity 250 agreed); at Club B it is still being negotiated; Not Yet has only been asked for; Late Night at Club A is active too.
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, current_version, active_version, requested_by) values (ev, venue_a, org, 'active', 1, 1, org_u) returning id into ag;
  insert into public.site_agreement_versions (agreement_id, version, terms, proposed_by, proposed_by_side, organizer_accepted_by, organizer_accepted_at, venue_accepted_by, venue_accepted_at)
    values (ag, 1, '{"capacity": 250}'::jsonb, org_u, 'organizer', org_u, now(), club_mgr, now());
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, current_version, requested_by) values (ev, venue_b, org, 'negotiating', 1, org_u) returning id into ag_b;
  insert into public.site_agreement_versions (agreement_id, version, terms, proposed_by, proposed_by_side, organizer_accepted_by, organizer_accepted_at) values (ag_b, 1, '{"capacity": 100}'::jsonb, org_u, 'organizer', org_u, now());
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, current_version, requested_by) values (ev_req, venue_a, org, 'requested', 0, org_u) returning id into ag_req;
  insert into public.site_agreements (event_id, venue_id, organizer_org_id, status, current_version, active_version, requested_by) values (ev_late, venue_a, org, 'active', 1, 1, org_u) returning id into ag_late;
  insert into public.site_agreement_versions (agreement_id, version, terms, proposed_by, proposed_by_side, organizer_accepted_by, organizer_accepted_at, venue_accepted_by, venue_accepted_at)
    values (ag_late, 1, '{}'::jsonb, org_u, 'organizer', org_u, now(), club_mgr, now());

  -- Tickets of Night One: 6 sold (2 checked in), one unpaid, one refunded.
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev, 'General', 3000, 500) returning id into general;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev, 'VIP', 9000, 50) returning id into vip;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, checked_in_at) values
    (ev, general, 'Ada Lovelace', 'ada@secret.example', 2, 6000, 'paid', 'T-ADA', now() - interval '1 hour'),
    (ev, general, 'Bob Barlow', 'bob@secret.example', 1, 3000, 'paid', 'T-BOB', null),
    (ev, vip, 'Cleo Crown', 'cleo@secret.example', 3, 27000, 'paid', 'T-CLEO', null),
    (ev, general, 'Unpaid Una', 'una@secret.example', 4, 12000, 'pending', 'T-UNA', null),
    (ev, general, 'Refunded Rae', 'rae@secret.example', 1, 3000, 'refunded', 'T-RAE', null);

  -- Club A's tables for the business night (one is after midnight), a booking for the next night, and Club B's table that night.
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 8, 0, 0, 9) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 8, 0, 0, 9) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 0, '01:00', 'After midnight') returning id into slot_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;
  perform tests.mkbooking(venue_a, type_a, slot_a, night, 'Ada Table', 10000, 10000, 2);
  perform tests.mkbooking(venue_a, type_a, slot_a, night, 'Zed Table', 6000, 3800, 3);
  perform tests.mkbooking(venue_a, type_a, slot_late, night + 1, 'Late Table', 2000, 2000, 4);
  perform tests.mkbooking(venue_a, type_a, slot_a, night + 1, 'Next Night', 9999, 9999, 2);
  perform tests.mkbooking(venue_b, type_b, slot_b, night, 'Other Club', 7777, 7777, 2);

  ---------------------------------------------------------------- the database says what it can supply
  perform tests.assert_eq('there are six things, in the brief''s order', array_to_string(public.agreement_grant_keys(), ','), 'bar_sales,ticket_checkins,capacity,table_sales,chat,settlement');
  perform tests.assert_eq('three can be shown today and three cannot', (select string_agg(k || '=' || public.agreement_grant_available(k)::text, ',' order by ord) from unnest(public.agreement_grant_keys()) with ordinality t(k, ord)),
    'bar_sales=false,ticket_checkins=true,capacity=true,table_sales=true,chat=false,settlement=false');
  perform tests.assert_eq('nothing is shared until a club allows it: no grant rows', (select count(*) from public.site_agreement_grants), 0::bigint);

  ---------------------------------------------------------------- who may allow or withdraw
  perform tests.assert_eq('the organizer cannot allow anything on the club''s behalf', tests.grant_to(org_u, 'org@access.example', ag, 'table_sales', true), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another person at the organizer''s business', tests.grant_to(org_staff, 'staff@access.example', ag, 'table_sales', true), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.grant_to(mgr_b, 'mgrb@access.example', ag, 'table_sales', true), 'ERROR: not allowed');
  perform tests.assert_eq('event door staff cannot', tests.grant_to(door_e, 'door@access.example', ag, 'table_sales', true), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.grant_to(rando, 'rando@access.example', ag, 'table_sales', true), 'ERROR: not allowed');
  perform tests.assert_eq('an agreement that does not exist', tests.grant_to(club_mgr, 'mgr@access.example', gen_random_uuid(), 'table_sales', true), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format('select public.set_agreement_grant(%L, %L, true)', ag, 'table_sales'), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('nothing was allowed by any of that', (select count(*) from public.site_agreement_grants), 0::bigint);

  perform tests.assert_eq('a thing that is not on the list', tests.grant_to(club_mgr, 'mgr@access.example', ag, 'the_cash_drawer', true), 'ERROR: choose one of the things a club can share');
  perform tests.assert_eq('yes or no is required', tests.grant_to(club_mgr, 'mgr@access.example', ag, 'table_sales', null), 'ERROR: say whether to share it, yes or no');
  perform tests.assert_eq('an agreement still being negotiated shares nothing yet', tests.grant_to(club_owner, 'owner@access.example', ag_b, 'table_sales', true), 'ERROR: the agreement has to be active before you can share anything under it');
  perform tests.assert_eq('...nor one that was only asked for', tests.grant_to(club_mgr, 'mgr@access.example', ag_req, 'table_sales', true), 'ERROR: the agreement has to be active before you can share anything under it');
  perform tests.assert_eq('the club''s manager allows table sales', tests.grant_to(club_mgr, 'mgr@access.example', ag, 'table_sales', true), 'true');
  perform tests.assert_eq('allowing it again changes nothing', tests.grant_to(club_mgr, 'mgr@access.example', ag, 'table_sales', true), 'false');
  perform tests.assert_eq('the club''s owner allows the capacity', tests.grant_to(club_owner, 'owner@access.example', ag, 'capacity', true), 'true');
  perform tests.assert_eq('withdrawing what was not allowed changes nothing', tests.grant_to(club_mgr, 'mgr@access.example', ag, 'ticket_checkins', false), 'false');
  perform tests.assert_eq('the change is attributed to the person, the thing and the event', (select count(*) from public.audit_log where action = 'agreement.access_allowed' and entity_id = ag::text and details ->> 'grant' = 'table_sales' and actor_email = 'mgr@access.example'
    and details ->> 'event_id' = ev::text), 1::bigint);
  n1 := (select count(*) from public.audit_log where action in ('agreement.access_allowed', 'agreement.access_withdrawn'));
  perform tests.grant_to(club_mgr, 'mgr@access.example', ag, 'table_sales', true);
  perform tests.assert_eq('a repeat writes no second entry', (select count(*) from public.audit_log where action in ('agreement.access_allowed', 'agreement.access_withdrawn')), n1);

  ---------------------------------------------------------------- reading one agreement's six things
  j := tests.try(club_mgr, 'mgr@access.example', format('select public.agreement_grants(%L)::text', ag))::jsonb;
  perform tests.assert_eq('the club sees the six, what is allowed, what exists, who allowed it, and that it may change them', concat_ws('/', j ->> 'in_force', j ->> 'can_change', j ->> 'side',
    (select string_agg((g ->> 'key') || ':' || (g ->> 'allowed') || ':' || (g ->> 'available'), ',' order by ord) from jsonb_array_elements(j -> 'grants') with ordinality t(g, ord))),
    'true/true/venue/bar_sales:false:false,ticket_checkins:false:true,capacity:true:true,table_sales:true:true,chat:false:false,settlement:false:false');
  perform tests.assert_eq('...and who allowed table sales', (select g ->> 'granted_by_name' from jsonb_array_elements(j -> 'grants') g where g ->> 'key' = 'table_sales'), 'Staff member');
  j := tests.try(org_u, 'org@access.example', format('select public.agreement_grants(%L)::text', ag))::jsonb;
  perform tests.assert_eq('the organizer sees the same list but cannot change it, and not who allowed it', concat_ws('/', j ->> 'side', j ->> 'can_change', (select count(*) from jsonb_array_elements(j -> 'grants') g where g ->> 'allowed' = 'true'),
    (select count(*) from jsonb_array_elements(j -> 'grants') g where g ? 'granted_by_name' and g ->> 'granted_by_name' is not null)), 'organizer/false/2/0');
  perform tests.assert_eq('another club cannot read it', tests.try(mgr_b, 'mgrb@access.example', format('select public.agreement_grants(%L)::text', ag)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.try(rando, 'rando@access.example', format('select public.agreement_grants(%L)::text', ag)), 'ERROR: not allowed');
  perform tests.assert_eq('the other business cannot', tests.try(other_u, 'other@access.example', format('select public.agreement_grants(%L)::text', ag)), 'ERROR: not allowed');

  ---------------------------------------------------------------- the organizer's "Your Venue Access" panel
  perform tests.assert_eq('every open agreement of the business in the function''s own order: newest event first, and for one event the club asked last first', tests.try(org_u, 'org@access.example', format($q$select string_agg(x.event_title || '@' || x.venue_name || ':' || x.status || ':' || x.in_force::text, ' | ') from (select * from public.organizer_venue_access(%L)) x$q$, org)),
    'Late Night@Club A:active:true | Night One@Club B:negotiating:false | Night One@Club A:active:true | Not Yet@Club A:requested:false');
  perform tests.assert_eq('for an active agreement: what the club has allowed and what exists', tests.try(org_staff, 'staff@access.example', format($q$select string_agg((g ->> 'key') || ':' || (g ->> 'allowed') || ':' || (g ->> 'available'), ',') from public.organizer_venue_access(%L) a, jsonb_array_elements(a.grants) g where a.agreement_id = %L$q$, org, ag)),
    'bar_sales:false:false,ticket_checkins:false:true,capacity:true:true,table_sales:true:true,chat:false:false,settlement:false:false');
  perform tests.assert_eq('for an agreement not in force, nothing is allowed', tests.try(org_u, 'org@access.example', format($q$select count(*)::text from public.organizer_venue_access(%L) a, jsonb_array_elements(a.grants) g where a.agreement_id = %L and g ->> 'allowed' = 'true'$q$, org, ag_b)), '0');
  update public.site_agreements set status = 'declined', closed_by = club_mgr, closed_at = now(), closed_reason = 'not this time' where id = ag_req;
  perform tests.assert_eq('a declined agreement is not listed', tests.try(org_u, 'org@access.example', format($q$select count(*)::text from public.organizer_venue_access(%L) where agreement_id = %L$q$, org, ag_req)), '0');
  update public.site_agreements set status = 'requested', closed_by = null, closed_at = null, closed_reason = null where id = ag_req;
  perform tests.assert_eq('the club cannot open the organizer''s panel', tests.try(club_owner, 'owner@access.example', format('select count(*)::text from public.organizer_venue_access(%L)', org)), 'ERROR: not allowed');
  perform tests.assert_eq('another business sees none of it', tests.try(other_u, 'other@access.example', format('select count(*)::text from public.organizer_venue_access(%L)', other_org)), '0');
  perform tests.assert_eq('...and cannot ask for this business''s', tests.try(other_u, 'other@access.example', format('select count(*)::text from public.organizer_venue_access(%L)', org)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.try(rando, 'rando@access.example', format('select count(*)::text from public.organizer_venue_access(%L)', org)), 'ERROR: not allowed');
  perform tests.assert_eq('no business', tests.try(org_u, 'org@access.example', 'select count(*)::text from public.organizer_venue_access(null)'), 'ERROR: not allowed');

  ---------------------------------------------------------------- the organizer's own tickets, always
  j := tests.sales(org_u, 'org@access.example', ev);
  perform tests.assert_eq('paid orders, tickets, check-ins, refunds and money, exact', concat_ws('/', j #>> '{tickets,orders}', j #>> '{tickets,tickets_sold}', j #>> '{tickets,checked_in}', j #>> '{tickets,refunded_orders}', j #>> '{tickets,refunded_cents}', j #>> '{tickets,gross_cents}', j #>> '{tickets,currency}', j #>> '{tickets,currency_mixed}'),
    '3/6/2/1/3000/36000/CAD/false');
  perform tests.assert_eq('by tier', (select string_agg((t ->> 'tier') || ':' || (t ->> 'sold') || ':' || (t ->> 'checked_in') || ':' || (t ->> 'gross_cents') || ':' || (t ->> 'price_cents') || ':' || (t ->> 'capacity'), ' | ' order by t ->> 'tier') from jsonb_array_elements(j -> 'tickets' -> 'by_tier') t),
    'General:3:2:9000:3000:500 | VIP:3:0:27000:9000:50');
  perform tests.assert_eq('the event is named', concat_ws('/', j #>> '{event,title}', j #>> '{event,venue_name}', j #>> '{event,status}', j #>> '{event,capacity}'), 'Night One/Club A/published/400');
  perform tests.assert_eq('a second person at the business sees the same', tests.sales(org_staff, 'staff@access.example', ev) #>> '{tickets,gross_cents}', '36000');
  perform tests.assert_eq('no guest name, e-mail, phone or ticket code is in it', (j::text ~* '(secret\.example|Ada Lovelace|Cleo|T-ADA|Unpaid)')::text, 'false');

  ---------------------------------------------------------------- the club's data only when allowed
  perform tests.assert_eq('two clubs are named for the event: the active agreement and the one being negotiated', (select string_agg(v ->> 'venue_name' || ':' || (v ->> 'status') || ':' || (v ->> 'in_force'), ' | ' order by v ->> 'venue_name') from jsonb_array_elements(j -> 'venues') v),
    'Club A:active:true | Club B:negotiating:false');
  perform tests.assert_eq('table sales: Club A''s tables of the night (the after-midnight one included, the next night''s and Club B''s not), money and guests, no names', tests.gdata(j, ag, 'table_sales')::text,
    jsonb_build_object('night', night, 'tables', 3, 'guests', 9, 'currency_mixed', false, 'currency', 'CAD', 'booked_cents', 18000, 'paid_cents', 15800)::text);
  perform tests.assert_eq('capacity: the agreed 250 against tickets sold and checked in', tests.gdata(j, ag, 'capacity')::text, jsonb_build_object('agreed', 250, 'tickets_sold', 6, 'checked_in', 2)::text);
  perform tests.assert_eq('check-ins are not allowed yet: allowed false, exists, and no data', tests.gflag(j, ag, 'ticket_checkins') || '/' || coalesce(tests.gdata(j, ag, 'ticket_checkins')::text, 'null'), 'false/true/null');
  perform tests.assert_eq('the three that do not exist yet say so', tests.gflag(j, ag, 'bar_sales') || ',' || tests.gflag(j, ag, 'chat') || ',' || tests.gflag(j, ag, 'settlement'), 'false/false,false/false,false/false');
  insert into public.site_agreement_grants (agreement_id, grant_key, granted_by) values (ag_b, 'table_sales', club_owner), (ag_b, 'capacity', club_owner);
  j := tests.sales(org_u, 'org@access.example', ev);
  perform tests.assert_eq('the club being negotiated shares nothing', (select count(*) from jsonb_array_elements(j -> 'venues') v, jsonb_array_elements(v -> 'grants') g where v ->> 'agreement_id' = ag_b::text and (g ->> 'allowed' = 'true' or g ->> 'data' is not null)), 0::bigint);
  perform tests.assert_eq('the organizer cannot see how the club''s other nights or the next night did: the figures are for this night only', (tests.gdata(j, ag, 'table_sales') ->> 'night'), night::text);

  perform tests.grant_to(club_mgr, 'mgr@access.example', ag, 'ticket_checkins', true);
  j := tests.sales(org_u, 'org@access.example', ev);
  perform tests.assert_eq('check-ins once allowed: the door''s count and the last check-in', concat_ws('/', tests.gdata(j, ag, 'ticket_checkins') ->> 'checked_in', tests.gdata(j, ag, 'ticket_checkins') ->> 'tickets_sold', ((tests.gdata(j, ag, 'ticket_checkins') ->> 'last_check_in_at') is not null)::text), '2/6/true');
  perform tests.grant_to(club_mgr, 'mgr@access.example', ag, 'bar_sales', true);
  perform tests.grant_to(club_mgr, 'mgr@access.example', ag, 'chat', true);
  perform tests.grant_to(club_mgr, 'mgr@access.example', ag, 'settlement', true);
  j := tests.sales(org_u, 'org@access.example', ev);
  perform tests.assert_eq('bar sales, chat and settlement can be allowed but still have nothing to show: allowed, not available, no data', tests.gflag(j, ag, 'bar_sales') || ',' || tests.gflag(j, ag, 'chat') || ',' || tests.gflag(j, ag, 'settlement')
    || ',' || coalesce(tests.gdata(j, ag, 'bar_sales')::text, 'null'), 'true/false,true/false,true/false,null');
  perform tests.assert_eq('the organizer''s panel shows the same', tests.try(org_u, 'org@access.example', format($q$select string_agg((g ->> 'key') || ':' || (g ->> 'allowed'), ',') from public.organizer_venue_access(%L) a, jsonb_array_elements(a.grants) g where a.agreement_id = %L$q$, org, ag)),
    'bar_sales:true,ticket_checkins:true,capacity:true,table_sales:true,chat:true,settlement:true');

  perform tests.assert_eq('withdrawing stops the sharing at once', tests.grant_to(club_mgr, 'mgr@access.example', ag, 'table_sales', false), 'true');
  j := tests.sales(org_u, 'org@access.example', ev);
  perform tests.assert_eq('...table sales are gone from the answer', tests.gflag(j, ag, 'table_sales') || '/' || coalesce(tests.gdata(j, ag, 'table_sales')::text, 'null'), 'false/true/null');
  perform tests.assert_eq('...the others stay', coalesce(tests.gdata(j, ag, 'capacity')::text, 'null') <> 'null', true);
  perform tests.grant_to(club_mgr, 'mgr@access.example', ag, 'table_sales', true);

  ---------------------------------------------------------------- an agreement that ends shares nothing
  update public.site_agreements set status = 'cancelled', closed_by = org_u, closed_at = now(), closed_reason = 'we changed plans' where id = ag;
  j := tests.sales(org_u, 'org@access.example', ev);
  perform tests.assert_eq('a cancelled agreement shares nothing, whatever rows exist', (select count(*) from public.site_agreement_grants where agreement_id = ag), 6::bigint);
  perform tests.assert_eq('...it is not even listed for the event, and the organizer''s tickets are still there', concat_ws('/', (select count(*) from jsonb_array_elements(j -> 'venues') v where v ->> 'agreement_id' = ag::text), j #>> '{tickets,gross_cents}'), '0/36000');
  perform tests.assert_eq('...and the club cannot allow anything under it', tests.grant_to(club_mgr, 'mgr@access.example', ag, 'chat', false), 'ERROR: the agreement has to be active before you can share anything under it');
  j := tests.try(club_mgr, 'mgr@access.example', format('select public.agreement_grants(%L)::text', ag))::jsonb;
  perform tests.assert_eq('...and reading it says nothing is in force and nothing allowed', concat_ws('/', j ->> 'in_force', j ->> 'can_change', (select count(*) from jsonb_array_elements(j -> 'grants') g where g ->> 'allowed' = 'true')), 'false/false/0');
  update public.site_agreements set status = 'changes_pending' , closed_by = null, closed_at = null, closed_reason = null where id = ag;
  j := tests.sales(org_u, 'org@access.example', ev);
  perform tests.assert_eq('a newer version waiting for both acceptances leaves the old terms and the sharing in force', tests.gflag(j, ag, 'table_sales') || '/' || (tests.gdata(j, ag, 'capacity') ->> 'agreed'), 'true/true/250');
  -- ...with a newer version proposed (capacity 300) that only one side has accepted: the agreed 250 stays until both have.
  insert into public.site_agreement_versions (agreement_id, version, terms, proposed_by, proposed_by_side, organizer_accepted_by, organizer_accepted_at) values (ag, 2, '{"capacity": 300}'::jsonb, org_u, 'organizer', org_u, now());
  update public.site_agreements set current_version = 2 where id = ag;
  perform tests.assert_eq('the terms in force are the accepted version, not the newest', (tests.gdata(tests.sales(org_u, 'org@access.example', ev), ag, 'capacity') ->> 'agreed'), '250');
  delete from public.site_agreement_versions where agreement_id = ag and version = 2;
  update public.site_agreements set current_version = 1 where id = ag;
  update public.site_agreements set status = 'active' where id = ag;

  ---------------------------------------------------------------- the business night of an event that starts after midnight
  perform tests.grant_to(club_mgr, 'mgr@access.example', ag_late, 'table_sales', true);
  j := tests.sales(org_u, 'org@access.example', ev_late);
  perform tests.assert_eq('an event at 01:00 belongs to the night before: the same three tables', (tests.gdata(j, ag_late, 'table_sales') ->> 'night') || '/' || (tests.gdata(j, ag_late, 'table_sales') ->> 'tables'), night::text || '/3');
  perform tests.assert_eq('an event with no tickets is zeros, not an error', concat_ws('/', j #>> '{tickets,orders}', j #>> '{tickets,gross_cents}', jsonb_array_length(j -> 'tickets' -> 'by_tier')), '0/0/0');
  perform tests.assert_eq('capacity is not shown until it is allowed', coalesce(tests.gdata(tests.sales(org_u, 'org@access.example', ev_late), ag_late, 'capacity')::text, 'null'), 'null');
  perform tests.grant_to(club_mgr, 'mgr@access.example', ag_late, 'capacity', true);
  perform tests.assert_eq('...agreed is null', (tests.gdata(tests.sales(org_u, 'org@access.example', ev_late), ag_late, 'capacity') -> 'agreed')::text, 'null');
  j := tests.sales(org_u, 'org@access.example', ev_req);
  perform tests.assert_eq('an event whose agreement was only asked for has its tickets and a club that shares nothing', concat_ws('/', jsonb_array_length(j -> 'venues'), (j -> 'venues' -> 0 ->> 'in_force'), j #>> '{tickets,orders}'), '1/false/0');

  ---------------------------------------------------------------- more than one currency: no gross
  update public.site_orders set currency = 'usd' where ticket_code = 'T-CLEO';
  j := tests.sales(org_u, 'org@access.example', ev);
  perform tests.assert_eq('mixed currencies: no total, but each tier says its own', concat_ws('/', j #>> '{tickets,currency_mixed}', coalesce(j #>> '{tickets,gross_cents}', 'null'), coalesce(j #>> '{tickets,currency}', 'null'), j #>> '{tickets,tickets_sold}'), 'true/null/null/6');
  update public.site_orders set currency = 'cad' where ticket_code = 'T-CLEO';
  update public.site_table_bookings set currency = 'usd' where customer_name = 'Zed Table';
  j := tests.sales(org_u, 'org@access.example', ev);
  perform tests.assert_eq('table sales in two currencies: counts yes, money no', concat_ws('/', tests.gdata(j, ag, 'table_sales') ->> 'tables', tests.gdata(j, ag, 'table_sales') ->> 'currency_mixed', coalesce(tests.gdata(j, ag, 'table_sales') ->> 'booked_cents', 'null')), '3/true/null');
  update public.site_table_bookings set currency = 'cad' where customer_name = 'Zed Table';

  ---------------------------------------------------------------- who may read the sales
  perform tests.assert_eq('the club the event is at cannot', tests.sales(club_owner, 'owner@access.example', ev) ->> 'error', 'not allowed');
  perform tests.assert_eq('the club''s manager cannot', tests.sales(club_mgr, 'mgr@access.example', ev) ->> 'error', 'not allowed');
  perform tests.assert_eq('event door staff cannot', tests.sales(door_e, 'door@access.example', ev) ->> 'error', 'not allowed');
  perform tests.assert_eq('another business cannot', tests.sales(other_u, 'other@access.example', ev) ->> 'error', 'not allowed');
  perform tests.assert_eq('a stranger cannot', tests.sales(rando, 'rando@access.example', ev) ->> 'error', 'not allowed');
  perform tests.assert_eq('an event of another business', tests.sales(org_u, 'org@access.example', ev_other) ->> 'error', 'not allowed');
  perform tests.assert_eq('no event', tests.sales(org_u, 'org@access.example', null) ->> 'error', 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format('select public.organizer_event_sales(%L)', ev), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- reading changes nothing
  select count(*) into n1 from public.site_agreement_grants;
  select count(*) into n2 from public.site_orders;
  select count(*) into n3 from public.site_table_bookings;
  select count(*) into n4 from public.audit_log;
  perform tests.sales(org_u, 'org@access.example', ev);
  perform tests.try(org_u, 'org@access.example', format('select count(*)::text from public.organizer_venue_access(%L)', org));
  perform tests.try(club_mgr, 'mgr@access.example', format('select public.agreement_grants(%L)::text', ag));
  perform tests.assert_true('the same rows after reading', (select count(*) from public.site_agreement_grants) = n1 and (select count(*) from public.site_orders) = n2
    and (select count(*) from public.site_table_bookings) = n3 and (select count(*) from public.audit_log) = n4);
  perform tests.login(org_u, 'org@access.example');
  perform tests.assert_raises('the grants table cannot be touched from the app', 'select * from public.site_agreement_grants', 'permission denied');
  perform tests.logout();
end $$;

rollback;
