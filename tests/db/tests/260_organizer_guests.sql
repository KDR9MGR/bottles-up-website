-- The organizer's guest list. What matters most: only the business that owns the event reads it (not clubs, not event door staff, not other
-- businesses); only paid orders; a name, a ticket and a check-in time, never an email, phone or payment; the counts are exact however
-- long the list; search is literal; and nothing can be changed through it.
begin;

create function tests.run_as(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  org_u constant uuid := '00000000-0000-0000-0000-00000000a0d1';
  org_staff constant uuid := '00000000-0000-0000-0000-00000000a0d2';
  other_u constant uuid := '00000000-0000-0000-0000-00000000a0d3';
  club_owner constant uuid := '00000000-0000-0000-0000-00000000a0d4';
  door_e constant uuid := '00000000-0000-0000-0000-00000000a0d5';
  rando constant uuid := '00000000-0000-0000-0000-00000000a0d6';
  org uuid; other_org uuid; club_org uuid; venue uuid; ev uuid; ev_other uuid; general uuid; vip uuid; n int;
begin
  insert into auth.users (id, email) values
    (org_u, 'org@guests.example'), (org_staff, 'staff@guests.example'), (other_u, 'other@guests.example'), (club_owner, 'club@guests.example'),
    (door_e, 'door@guests.example'), (rando, 'rando@guests.example');

  perform tests.login(org_u, 'org@guests.example');
  org := public.create_organization('Night Events', 'organizer');
  perform tests.login(other_u, 'other@guests.example');
  other_org := public.create_organization('Other Events', 'organizer');
  perform tests.login(club_owner, 'club@guests.example');
  club_org := public.create_organization('Club Co', 'venue_owner');
  venue := public.create_org_venue(club_org, 'Club A');
  perform tests.logout();
  insert into public.site_memberships (org_id, user_id, role) values (org, org_staff, 'organizer');
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, venue_id)
    values ('Night One', 'x', 'Club A', now() + interval '3 days', now() + interval '3 days 6 hours', 'published', org, venue) returning id into ev;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Other Night', 'x', 'Elsewhere', now() + interval '3 days', now() + interval '3 days 6 hours', 'published', other_org) returning id into ev_other;
  insert into public.site_memberships (org_id, user_id, role, event_id) values (org, door_e, 'door', ev);
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev, 'General', 3000, 500) returning id into general;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev, 'VIP', 9000, 50) returning id into vip;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, checked_in_at, created_at) values
    (ev, general, 'Ada Lovelace', 'ada@secret.example', 2, 6000, 'paid', 'T-ADA', now(), now() - interval '3 hours'),
    (ev, general, 'Bob 100% Barlow', 'bob@secret.example', 1, 3000, 'paid', 'T-BOB', null, now() - interval '2 hours'),
    (ev, vip, 'Cleo Crown', 'cleo@secret.example', 3, 27000, 'paid', 'T-CLEO', null, now() - interval '1 hour'),
    (ev, general, 'Unpaid Una', 'una@secret.example', 4, 12000, 'pending', 'T-UNA', null, now()),
    (ev, general, 'Refunded Rae', 'rae@secret.example', 1, 3000, 'refunded', 'T-RAE', null, now());
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code)
    values (ev_other, (select id from public.site_ticket_tiers where event_id = ev limit 1), 'Other Person', 'o@secret.example', 1, 1, 'paid', 'T-OTHER');

  ---------------------------------------------------------------- the summary
  perform tests.assert_eq('the organizer sees the counts of paid tickets, exact', tests.run_as(org_u, 'org@guests.example', format($q$select (s ->> 'orders') || '/' || (s ->> 'tickets_sold') || '/' || (s ->> 'checked_in') from (select public.organizer_guest_summary(%L) s) x$q$, ev)), '3/6/2');
  perform tests.assert_eq('...by tier', tests.run_as(org_u, 'org@guests.example', format($q$select string_agg((t ->> 'tier') || ':' || (t ->> 'sold') || ':' || (t ->> 'checked_in'), ' | ' order by t ->> 'tier') from (select jsonb_array_elements(public.organizer_guest_summary(%L) -> 'by_tier') t) x$q$, ev)), 'General:3:2 | VIP:3:0');
  perform tests.assert_eq('a second person at the business sees the same', tests.run_as(org_staff, 'staff@guests.example', format($q$select (public.organizer_guest_summary(%L) ->> 'tickets_sold')$q$, ev)), '6');
  perform tests.assert_eq('another business cannot', tests.run_as(other_u, 'other@guests.example', format($q$select public.organizer_guest_summary(%L)::text$q$, ev)), 'ERROR: not allowed');
  perform tests.assert_eq('the club the event is at cannot', tests.run_as(club_owner, 'club@guests.example', format($q$select public.organizer_guest_summary(%L)::text$q$, ev)), 'ERROR: not allowed');
  perform tests.assert_eq('event door staff cannot', tests.run_as(door_e, 'door@guests.example', format($q$select public.organizer_guest_summary(%L)::text$q$, ev)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.run_as(rando, 'rando@guests.example', format($q$select public.organizer_guest_summary(%L)::text$q$, ev)), 'ERROR: not allowed');
  perform tests.assert_eq('no event', tests.run_as(org_u, 'org@guests.example', $q$select public.organizer_guest_summary(null)::text$q$), 'ERROR: not allowed');
  perform tests.assert_eq('an event of another business', tests.run_as(org_u, 'org@guests.example', format($q$select public.organizer_guest_summary(%L)::text$q$, ev_other)), 'ERROR: not allowed');

  ---------------------------------------------------------------- the list
  perform tests.assert_eq('paid orders only, newest first, with the ticket and the check-in', tests.run_as(org_u, 'org@guests.example', format($q$select string_agg(customer_name || ':' || tier_name || ':' || quantity || ':' || case when checked_in_at is null then 'out' else 'in' end, ' | ' order by created_at desc, order_id) from public.organizer_guests(%L)$q$, ev)),
    'Cleo Crown:VIP:3:out | Bob 100% Barlow:General:1:out | Ada Lovelace:General:2:in');
  perform tests.assert_eq('no email, phone or payment is in what comes back', (select count(*) from information_schema.columns where table_name = 'organizer_guests' and column_name in ('customer_email', 'phone', 'amount_total_cents'))::int, 0);
  perform tests.assert_eq('search by name', tests.run_as(org_staff, 'staff@guests.example', format($q$select string_agg(customer_name, ',') from public.organizer_guests(%L, 'cle')$q$, ev)), 'Cleo Crown');
  perform tests.assert_eq('...or by ticket code', tests.run_as(org_u, 'org@guests.example', format($q$select string_agg(customer_name, ',') from public.organizer_guests(%L, 't-bob')$q$, ev)), 'Bob 100% Barlow');
  perform tests.assert_eq('a percent sign in what was typed is just a character', tests.run_as(org_u, 'org@guests.example', format($q$select string_agg(customer_name, ',') from public.organizer_guests(%L, '100%%')$q$, ev)), 'Bob 100% Barlow');
  perform tests.assert_eq('...and matches nothing it should not', tests.run_as(org_u, 'org@guests.example', format($q$select count(*)::text from public.organizer_guests(%L, '%%%%')$q$, ev)), '0');
  perform tests.assert_eq('one character is too few to search', tests.run_as(org_u, 'org@guests.example', format($q$select count(*)::text from public.organizer_guests(%L, 'a')$q$, ev)), 'ERROR: type at least 2 characters to search');
  perform tests.assert_eq('someone not paid is not a guest', tests.run_as(org_u, 'org@guests.example', format($q$select count(*)::text from public.organizer_guests(%L, 'una')$q$, ev)), '0');
  perform tests.assert_eq('another business cannot list', tests.run_as(other_u, 'other@guests.example', format($q$select count(*)::text from public.organizer_guests(%L)$q$, ev)), 'ERROR: not allowed');
  perform tests.assert_eq('the club cannot list', tests.run_as(club_owner, 'club@guests.example', format($q$select count(*)::text from public.organizer_guests(%L)$q$, ev)), 'ERROR: not allowed');
  perform tests.assert_eq('event door staff cannot list', tests.run_as(door_e, 'door@guests.example', format($q$select count(*)::text from public.organizer_guests(%L)$q$, ev)), 'ERROR: not allowed');

  ---------------------------------------------------------------- long lists are cut, the counts are not
  perform tests.logout();
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code)
    select ev, general, 'Guest ' || g, 'g' || g || '@example.com', 1, 3000, 'paid', 'T-G' || g from generate_series(1, 150) g;
  perform tests.assert_eq('a list is at most 100', tests.run_as(org_u, 'org@guests.example', format($q$select count(*)::text from public.organizer_guests(%L)$q$, ev)), '100');
  perform tests.assert_eq('...a search at most 50', tests.run_as(org_u, 'org@guests.example', format($q$select count(*)::text from public.organizer_guests(%L, 'guest')$q$, ev)), '50');
  perform tests.assert_eq('...and the count is the real one', tests.run_as(org_u, 'org@guests.example', format($q$select (public.organizer_guest_summary(%L) ->> 'tickets_sold')$q$, ev)), '156');

  ---------------------------------------------------------------- closed
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format('select * from public.organizer_guests(%L)', ev), 'permission denied');
  perform tests.logout();
end $$;

rollback;
