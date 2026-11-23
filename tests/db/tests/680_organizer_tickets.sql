-- Organizers create their own tickets (20261128100000_organizer_tickets.sql; developer fix list 22 Nov, item 3). What matters: only the organizer of the business that owns the event can list, add, change
-- or remove its ticket types, and never another business's; every field is checked (name, price, capacity, the sale window); an event that has ended is closed to changes; once a type has SOLD its
-- price and name are fixed, capacity cannot go below what is sold, and it cannot be removed (an order of any kind, even an unpaid one, keeps it); drafts and published events follow the same rules;
-- the app cannot write the table directly; the public still reads the new columns on a published event; every change leaves a record.
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
create function tests.q(p_sql text) returns text language plpgsql security definer as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, 'null');
end $$;
create function tests.x(p_sql text) returns void language plpgsql security definer as $$ begin execute p_sql; end $$;
-- one ticket type as its owner (an organizer cannot read the tiers of a draft event directly)
create function tests.tier(p_id uuid) returns public.site_ticket_tiers language sql security definer as $$ select * from public.site_ticket_tiers where id = p_id $$;
-- every ticket type of an event in one line: name:price:capacity:sold
create function tests.tiers(p_event uuid) returns text language sql security definer as $$
  select coalesce(string_agg(t.name || ':' || t.price_cents || ':' || t.capacity || ':' || t.sold_count, ', ' order by t.name), '') from public.site_ticket_tiers t where t.event_id = p_event $$;

do $$
declare
  org_u constant uuid := '00000000-0000-0000-0000-0000000006c1';
  other_u constant uuid := '00000000-0000-0000-0000-0000000006c2';
  owner_u constant uuid := '00000000-0000-0000-0000-0000000006c3';
  mgr_u constant uuid := '00000000-0000-0000-0000-0000000006c4';
  stranger constant uuid := '00000000-0000-0000-0000-0000000006c5';
  org uuid; other_org uuid; club uuid; venue uuid;
  ev_draft uuid; ev_pub uuid; ev_old uuid; ev_other uuid;
  t1 uuid; t2 uuid; t3 uuid; tp uuid; tother uuid; tid uuid; r record; r2 text; n_audit int;
  d1 text := to_char(now() + interval '2 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  d2 text := to_char(now() + interval '4 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  d9 text := to_char(now() + interval '30 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  d_mid text := to_char(now() + interval '10 days 18 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  ev_end_s text; ev_multi uuid; ev_short uuid;
begin
  insert into auth.users (id, email) values
    (org_u, 'org@tix.example'), (other_u, 'other@tix.example'), (owner_u, 'owner@tix.example'), (mgr_u, 'mgr@tix.example'), (stranger, 'stranger@tix.example');

  perform tests.login(org_u, 'org@tix.example');
  org := public.create_organization('Tix Events', 'organizer');
  perform tests.login(other_u, 'other@tix.example');
  other_org := public.create_organization('Other Events', 'organizer');
  perform tests.login(owner_u, 'owner@tix.example');
  club := public.create_organization('Tix Club Co', 'venue_owner');
  venue := public.create_org_venue(club, 'Tix Club');
  perform tests.logout();

  -- the events: the organizer's draft 10 days from now (ends 11 days), its published one, a finished one, and another organizer's
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, organizer_name) values
    ('Draft night', 'd', 'Tix Club', now() + interval '10 days', now() + interval '11 days', 'draft', org, 'Tix Events') returning id into ev_draft;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, organizer_name) values
    ('Live night', 'd', 'Tix Club', now() + interval '20 days', null, 'published', org, 'Tix Events') returning id into ev_pub;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, organizer_name) values
    ('Old night', 'd', 'Tix Club', now() - interval '3 days', now() - interval '2 days', 'published', org, 'Tix Events') returning id into ev_old;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, organizer_name) values
    ('Other night', 'd', 'Tix Club', now() + interval '10 days', now() + interval '11 days', 'draft', other_org, 'Other Events') returning id into ev_other;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, organizer_name) values
    ('Multi day', 'd', 'Tix Club', now() - interval '20 hours', now() + interval '4 hours', 'published', org, 'Tix Events') returning id into ev_multi;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, organizer_name) values
    ('Short and over', 'd', 'Tix Club', now() - interval '5 hours', now() - interval '1 hour', 'published', org, 'Tix Events') returning id into ev_short;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_old, 'Old GA', 2000, 100) returning id into tid;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_other, 'Other GA', 3000, 50) returning id into tother;
  perform tests.assert_true('existing ticket types have no sale window (on sale as always)', (select sale_starts_at is null and sale_ends_at is null from public.site_ticket_tiers where id = tother));

  ---------------------------------------------------------------- who may use the functions
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot list', format($q$select * from public.list_org_tiers(%L, %L)$q$, org, ev_draft), 'permission denied');
  perform tests.assert_raises('...nor add', format($q$select public.save_org_tier(%L, %L, null, '{"name":"GA","price_cents":1000,"capacity":10}')$q$, org, ev_draft), 'permission denied');
  perform tests.assert_raises('...nor remove', format($q$select public.remove_org_tier(%L, %L)$q$, org, tother), 'permission denied');
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform tests.assert_raises('a token with no user is told to sign in', format($q$select * from public.list_org_tiers(%L, %L)$q$, org, ev_draft), 'not authenticated');
  perform tests.login(stranger, 'stranger@tix.example');
  perform tests.assert_raises('a stranger cannot list', format($q$select * from public.list_org_tiers(%L, %L)$q$, org, ev_draft), 'not allowed');
  perform tests.assert_raises('...nor add', format($q$select public.save_org_tier(%L, %L, null, '{"name":"GA","price_cents":1000,"capacity":10}')$q$, org, ev_draft), 'not allowed');
  perform tests.assert_raises('...nor remove', format($q$select public.remove_org_tier(%L, %L)$q$, org, tother), 'not allowed');
  perform tests.login(owner_u, 'owner@tix.example');
  perform tests.assert_raises('the owner of a venue business cannot make tickets for an organizer''s event', format($q$select public.save_org_tier(%L, %L, null, '{"name":"GA","price_cents":1000,"capacity":10}')$q$, club, ev_draft), 'not allowed');
  perform tests.assert_raises('...and cannot reach it through the organizer''s business either', format($q$select public.save_org_tier(%L, %L, null, '{"name":"GA","price_cents":1000,"capacity":10}')$q$, org, ev_draft), 'not allowed');
  perform tests.login(other_u, 'other@tix.example');
  perform tests.assert_raises('another organizer cannot list this business''s tickets', format($q$select * from public.list_org_tiers(%L, %L)$q$, org, ev_draft), 'not allowed');
  perform tests.assert_raises('...nor add to its event through their own business', format($q$select public.save_org_tier(%L, %L, null, '{"name":"GA","price_cents":1000,"capacity":10}')$q$, other_org, ev_draft), 'event not found');
  perform tests.assert_raises('...nor change a ticket type of its event', format($q$select public.save_org_tier(%L, %L, %L, '{"capacity":5}')$q$, other_org, ev_old, tid), 'event not found');
  perform tests.assert_raises('...nor remove a ticket type of another business''s event (it is not found for them)', format($q$select public.remove_org_tier(%L, %L)$q$, other_org, tid), 'ticket type not found');
  perform tests.login(org_u, 'org@tix.example');
  perform tests.assert_raises('the organizer cannot reach another business''s event through their own', format($q$select * from public.list_org_tiers(%L, %L)$q$, org, ev_other), 'event not found');
  perform tests.assert_raises('...nor add to it', format($q$select public.save_org_tier(%L, %L, null, '{"name":"GA","price_cents":1000,"capacity":10}')$q$, org, ev_other), 'event not found');
  perform tests.assert_raises('...nor change its ticket type', format($q$select public.save_org_tier(%L, %L, %L, '{"capacity":5}')$q$, org, ev_draft, tother), 'ticket type not found');
  perform tests.assert_raises('...nor remove it', format($q$select public.remove_org_tier(%L, %L)$q$, org, tother), 'ticket type not found');
  perform tests.assert_raises('a ticket type is looked up inside the event it was asked about', format($q$select public.save_org_tier(%L, %L, %L, '{"capacity":5}')$q$, org, ev_pub, tother), 'ticket type not found');
  perform tests.logout();
  perform tests.assert_eq('none of those changed anything', tests.tiers(ev_other), 'Other GA:3000:50:0');
  perform tests.assert_eq('...nor the organizer''s event', tests.tiers(ev_draft), '');

  ---------------------------------------------------------------- adding types to a draft
  perform tests.login(org_u, 'org@tix.example');
  t1 := public.save_org_tier(org, ev_draft, null, '{"name":"  General   Admission ","price_cents":2500,"capacity":200}');
  t2 := public.save_org_tier(org, ev_draft, null, jsonb_build_object('name', 'Early Bird', 'price_cents', 1500, 'capacity', 50, 'sale_starts_at', d1, 'sale_ends_at', d2));
  t3 := public.save_org_tier(org, ev_draft, null, '{"name":"Free Guest List","price_cents":0,"capacity":20}');
  perform tests.logout();
  perform tests.assert_eq('three types were added (the name is tidied of extra spaces at the ends, free is allowed)', tests.tiers(ev_draft), 'Early Bird:1500:50:0, Free Guest List:0:20:0, General Admission:2500:200:0');
  perform tests.assert_true('a type without dates has none', (select sale_starts_at is null and sale_ends_at is null from tests.tier(t1)));
  perform tests.assert_true('a type with dates has both', (select sale_starts_at is not null and sale_ends_at > sale_starts_at from tests.tier(t2)));
  perform tests.assert_eq('...in the currency of the business (CAD)', (select currency from tests.tier(t1)), 'cad');
  perform tests.login(org_u, 'org@tix.example');
  perform tests.assert_eq('the list gives them cheapest first', (select string_agg(name, ', ') from public.list_org_tiers(org, ev_draft)), 'Free Guest List, Early Bird, General Admission');
  perform tests.assert_eq('...with what has sold and whether anything is locked', (select string_agg(name || ':' || sold_count || ':' || has_sold || ':' || has_orders, ', ' order by name) from public.list_org_tiers(org, ev_draft)),
    'Early Bird:0:false:false, Free Guest List:0:false:false, General Admission:0:false:false');
  perform tests.logout();

  ---------------------------------------------------------------- what a new type must have
  perform tests.assert_eq('a name is required', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"price_cents":100,"capacity":5}')::text$q$, org, ev_draft)), 'ERROR: ticket name is required');
  perform tests.assert_eq('...not blank', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"   ","price_cents":100,"capacity":5}')::text$q$, org, ev_draft)), 'ERROR: ticket name is required');
  perform tests.assert_eq('...and at most 60 characters', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', repeat('x', 61), 'price_cents', 100, 'capacity', 5)::text)), 'ERROR: ticket name must be 60 characters or fewer');
  perform tests.assert_true('60 characters is fine', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', repeat('x', 60), 'price_cents', 100, 'capacity', 5)::text)) not like 'ERROR%');
  perform tests.assert_true('the largest price and capacity are fine', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"Max","price_cents":1000000,"capacity":100000}')::text$q$, org, ev_draft)) not like 'ERROR%');
  perform tests.assert_true('...and so is a capacity of one', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"Solo","price_cents":0,"capacity":1}')::text$q$, org, ev_draft)) not like 'ERROR%');
  perform tests.assert_eq('a price is required', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","capacity":5}')::text$q$, org, ev_draft)), 'ERROR: price is required');
  perform tests.assert_eq('...and so is a capacity', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","price_cents":100}')::text$q$, org, ev_draft)), 'ERROR: capacity is required');
  perform tests.assert_eq('a negative price is refused', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","price_cents":-1,"capacity":5}')::text$q$, org, ev_draft)), 'ERROR: price must be between 0 and 1000000');
  perform tests.assert_eq('...and one above 1,000,000 cents', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","price_cents":1000001,"capacity":5}')::text$q$, org, ev_draft)), 'ERROR: price must be between 0 and 1000000');
  perform tests.assert_eq('a price with cents in the fraction is refused', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","price_cents":10.5,"capacity":5}')::text$q$, org, ev_draft)), 'ERROR: price must be a whole number');
  perform tests.assert_eq('a price as text is refused', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","price_cents":"10","capacity":5}')::text$q$, org, ev_draft)), 'ERROR: price must be a whole number');
  perform tests.assert_eq('a capacity of zero is refused', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","price_cents":100,"capacity":0}')::text$q$, org, ev_draft)), 'ERROR: capacity must be between 1 and 100000');
  perform tests.assert_eq('...and one above 100,000', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","price_cents":100,"capacity":100001}')::text$q$, org, ev_draft)), 'ERROR: capacity must be between 1 and 100000');
  perform tests.assert_eq('a field the function does not know is refused (an organizer cannot set a code or a flag)', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","price_cents":100,"capacity":5,"requires_access_code":true}')::text$q$, org, ev_draft)), 'ERROR: unknown field: requires_access_code');
  perform tests.assert_eq('...nor the sold count', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"VIP","price_cents":100,"capacity":5,"sold_count":3}')::text$q$, org, ev_draft)), 'ERROR: unknown field: sold_count');
  perform tests.assert_eq('the same name twice in an event is refused, whatever the capitals', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"general admission","price_cents":100,"capacity":5}')::text$q$, org, ev_draft)), 'ERROR: this event already has a ticket type with that name');
  perform tests.assert_true('...but another event may use the name', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"General Admission","price_cents":100,"capacity":5}')::text$q$, org, ev_pub)) not like 'ERROR%');

  ---------------------------------------------------------------- the sale window
  perform tests.assert_eq('a time with no time zone is refused', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, '{"name":"W1","price_cents":100,"capacity":5,"sale_starts_at":"2030-01-01T10:00:00"}')::text$q$, org, ev_draft)), 'ERROR: sales start must be a date and time with its time zone');
  perform tests.assert_eq('sales must end after they start', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', 'W2', 'price_cents', 100, 'capacity', 5, 'sale_starts_at', d2, 'sale_ends_at', d1)::text)), 'ERROR: ticket sales must end after they start');
  perform tests.assert_eq('...not at the same moment', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', 'W3', 'price_cents', 100, 'capacity', 5, 'sale_starts_at', d1, 'sale_ends_at', d1)::text)), 'ERROR: ticket sales must end after they start');
  perform tests.assert_eq('sales cannot end after the event ends', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', 'W4', 'price_cents', 100, 'capacity', 5, 'sale_ends_at', d9)::text)), 'ERROR: ticket sales cannot end after the event ends');
  perform tests.assert_eq('sales cannot start once the event has ended', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', 'W5', 'price_cents', 100, 'capacity', 5, 'sale_starts_at', d9)::text)), 'ERROR: ticket sales cannot start once the event has ended');
  ev_end_s := (select to_char(end_date at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') from public.site_events where id = ev_draft);
  perform tests.assert_true('sales may end exactly when the event ends', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', 'Edge1', 'price_cents', 100, 'capacity', 5, 'sale_ends_at', ev_end_s)::text)) not like 'ERROR%');
  perform tests.assert_eq('...but may not start exactly when it ends', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', 'Edge2', 'price_cents', 100, 'capacity', 5, 'sale_starts_at', ev_end_s)::text)), 'ERROR: ticket sales cannot start once the event has ended');
  perform tests.assert_true('sales may run past the first 12 hours when the event has an end time (they end up to the event end, not 12 hours after its start)', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', 'Edge3', 'price_cents', 100, 'capacity', 5, 'sale_ends_at', d_mid)::text)) not like 'ERROR%');
  perform tests.assert_true('only an end, or only a start, is fine', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', 'W6', 'price_cents', 100, 'capacity', 5, 'sale_ends_at', d2)::text)) not like 'ERROR%');
  perform tests.assert_true('...and so is only a start', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, null, %L::jsonb)::text$q$, org, ev_draft, jsonb_build_object('name', 'W7', 'price_cents', 100, 'capacity', 5, 'sale_starts_at', d1)::text)) not like 'ERROR%');
  perform tests.assert_raises('the table''s own check refuses a window that ends before it starts, however it was written', format($q$select tests.x(%L)$q$, format($u$update public.site_ticket_tiers set sale_starts_at = now() + interval '2 days', sale_ends_at = now() + interval '1 day' where id = %L$u$, t1)), 'site_ticket_tiers_sale_window_check');
  perform tests.x(format($q$delete from public.site_ticket_tiers where event_id = %L and name in ('W6', 'W7', 'Max', 'Solo', 'Edge1', 'Edge2', 'Edge3', %L)$q$, ev_draft, repeat('x', 60)));

  ---------------------------------------------------------------- at most 20 types
  perform tests.login(org_u, 'org@tix.example');
  for i in 1..17 loop
    perform public.save_org_tier(org, ev_draft, null, jsonb_build_object('name', 'Type ' || i, 'price_cents', 100 + i, 'capacity', 5));
  end loop;
  perform tests.assert_eq('twenty types fit', (select count(*)::int from public.list_org_tiers(org, ev_draft)), 20);
  perform tests.assert_raises('the twenty-first is refused', format($q$select public.save_org_tier(%L, %L, null, '{"name":"One too many","price_cents":100,"capacity":5}')$q$, org, ev_draft), 'at most 20 ticket types');
  perform tests.logout();
  perform tests.x(format($q$delete from public.site_ticket_tiers where event_id = %L and name like 'Type %%'$q$, ev_draft));
  perform tests.assert_eq('(back to three)', tests.tiers(ev_draft), 'Early Bird:1500:50:0, Free Guest List:0:20:0, General Admission:2500:200:0');

  ---------------------------------------------------------------- changing a type that has not sold
  perform tests.login(org_u, 'org@tix.example');
  perform public.save_org_tier(org, ev_draft, t1, '{"price_cents":3000}');
  perform tests.assert_eq('only the field sent changes', tests.tiers(ev_draft), 'Early Bird:1500:50:0, Free Guest List:0:20:0, General Admission:3000:200:0');
  perform public.save_org_tier(org, ev_draft, t1, '{"name":"General","capacity":250}');
  perform tests.assert_eq('an unsold type can be renamed and have its capacity changed', tests.tiers(ev_draft), 'Early Bird:1500:50:0, Free Guest List:0:20:0, General:3000:250:0');
  perform public.save_org_tier(org, ev_draft, t2, jsonb_build_object('sale_starts_at', null, 'sale_ends_at', d1));
  perform tests.assert_true('a date can be cleared with null, and the other kept', (select sale_starts_at is null and sale_ends_at is not null from tests.tier(t2)));
  perform public.save_org_tier(org, ev_draft, t2, jsonb_build_object('sale_starts_at', d1, 'sale_ends_at', d2));
  perform tests.assert_raises('a change that makes the window end before it starts is refused', format($q$select public.save_org_tier(%L, %L, %L, %L::jsonb)$q$, org, ev_draft, t2, jsonb_build_object('sale_ends_at', to_char(now() + interval '1 day', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))::text), 'must end after they start');
  perform tests.assert_raises('a rename onto another type''s name is refused', format($q$select public.save_org_tier(%L, %L, %L, '{"name":"early bird"}')$q$, org, ev_draft, t1), 'already has a ticket type with that name');
  perform public.save_org_tier(org, ev_draft, t1, '{"name":"GENERAL"}');
  perform tests.assert_eq('...but a type may change its own capitals', (select name from tests.tier(t1)), 'GENERAL');
  perform public.save_org_tier(org, ev_draft, t1, '{"name":"General"}');
  perform tests.assert_eq('on a change too, a negative price is refused', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, %L, '{"price_cents":-1}')::text$q$, org, ev_draft, t1)), 'ERROR: price must be between 0 and 1000000');
  perform tests.assert_eq('...and one above 1,000,000 cents', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, %L, '{"price_cents":1000001}')::text$q$, org, ev_draft, t1)), 'ERROR: price must be between 0 and 1000000');
  perform tests.assert_eq('...a capacity of zero', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, %L, '{"capacity":0}')::text$q$, org, ev_draft, t1)), 'ERROR: capacity must be between 1 and 100000');
  perform tests.assert_eq('...and one above 100,000', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, %L, '{"capacity":100001}')::text$q$, org, ev_draft, t1)), 'ERROR: capacity must be between 1 and 100000');
  perform tests.assert_eq('a price sent as null is refused, not read as unchanged', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, %L, '{"price_cents":null}')::text$q$, org, ev_draft, t1)), 'ERROR: price is required');
  perform tests.assert_eq('...nor a capacity sent as null', tests.run_as(org_u, 'org@tix.example', format($q$select public.save_org_tier(%L, %L, %L, '{"capacity":null}')::text$q$, org, ev_draft, t1)), 'ERROR: capacity is required');
  perform public.save_org_tier(org, ev_draft, t1, '{"name":"  Gen   Two "}');
  perform tests.assert_eq('a changed name has its spaces tidied too', (select name from tests.tier(t1)), 'Gen Two');
  perform public.save_org_tier(org, ev_draft, t1, '{"name":"General"}');
  perform public.save_org_tier(org, ev_draft, t2, '{"capacity":55}');
  perform tests.assert_true('changing only the capacity keeps both sale dates', (select sale_starts_at is not null and sale_ends_at is not null and capacity = 55 from tests.tier(t2)));
  perform public.save_org_tier(org, ev_draft, t2, '{"capacity":50}');
  perform tests.assert_raises('an empty change list does nothing wrong, an unknown field is still refused', format($q$select public.save_org_tier(%L, %L, %L, '{"status":"x"}')$q$, org, ev_draft, t1), 'unknown field: status');
  perform tests.logout();

  ---------------------------------------------------------------- a type that has sold
  perform tests.x(format($q$update public.site_ticket_tiers set sold_count = 40 where id = %L$q$, t1));
  perform tests.login(org_u, 'org@tix.example');
  perform tests.assert_true('the list says it has sold (40 sold)', (select has_sold and sold_count = 40 from public.list_org_tiers(org, ev_draft) l where l.tier_id = t1));
  perform tests.assert_raises('its price can no longer be changed', format($q$select public.save_org_tier(%L, %L, %L, '{"price_cents":1}')$q$, org, ev_draft, t1), 'have been sold, so its price cannot be changed');
  perform tests.assert_raises('...nor its name', format($q$select public.save_org_tier(%L, %L, %L, '{"name":"Cheap"}')$q$, org, ev_draft, t1), 'have been sold, so its name cannot be changed');
  perform tests.assert_raises('...the capacity cannot go below what has sold', format($q$select public.save_org_tier(%L, %L, %L, '{"capacity":39}')$q$, org, ev_draft, t1), 'cannot be lower than the 40 tickets already sold');
  perform public.save_org_tier(org, ev_draft, t1, '{"capacity":40}');
  perform tests.assert_eq('...but may go down to exactly what has sold', (select capacity from tests.tier(t1)), 40);
  perform public.save_org_tier(org, ev_draft, t1, '{"capacity":500}');
  perform tests.assert_eq('...and may be raised', (select capacity from tests.tier(t1)), 500);
  perform public.save_org_tier(org, ev_draft, t1, jsonb_build_object('price_cents', 3000, 'name', 'General', 'capacity', 500));
  perform tests.assert_eq('saving the same price and name again is not a change (nothing refused, nothing moved)', (select price_cents from tests.tier(t1)), 3000);
  perform public.save_org_tier(org, ev_draft, t1, jsonb_build_object('sale_ends_at', d2));
  perform tests.assert_true('its sale dates can still be set (stop selling, extend)', (select sale_ends_at is not null from tests.tier(t1)));
  perform tests.assert_raises('it cannot be removed', format($q$select public.remove_org_tier(%L, %L)$q$, org, t1), 'bought or started to buy this ticket type, so it cannot be removed');
  perform tests.logout();
  perform tests.assert_eq('it is still there', tests.tiers(ev_draft), 'Early Bird:1500:50:0, Free Guest List:0:20:0, General:3000:500:40');

  -- sold through a paid order with the count not yet moved (the order is what buyers hold)
  perform tests.x(format($q$insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status) values (%L, %L, 'Pat', 'pat@x.example', 1, 1500, 'paid')$q$, ev_draft, t2));
  perform tests.login(org_u, 'org@tix.example');
  perform tests.assert_raises('a type with a PAID order is locked even if its count says nothing sold', format($q$select public.save_org_tier(%L, %L, %L, '{"price_cents":1}')$q$, org, ev_draft, t2), 'have been sold, so its price cannot be changed');
  perform tests.assert_raises('...and cannot be removed', format($q$select public.remove_org_tier(%L, %L)$q$, org, t2), 'cannot be removed');
  perform tests.logout();
  perform tests.x(format($q$update public.site_orders set status = 'refunded' where tier_id = %L$q$, t2));
  perform tests.login(org_u, 'org@tix.example');
  perform tests.assert_raises('a REFUNDED order still locks the price (the buyer held a ticket that said it)', format($q$select public.save_org_tier(%L, %L, %L, '{"price_cents":1}')$q$, org, ev_draft, t2), 'have been sold, so its price cannot be changed');
  perform tests.logout();
  perform tests.x(format($q$update public.site_orders set status = 'pending' where tier_id = %L$q$, t2));
  perform tests.login(org_u, 'org@tix.example');
  perform public.save_org_tier(org, ev_draft, t2, '{"price_cents":1400}');
  perform tests.assert_eq('a checkout that was only STARTED does not lock the price', (select price_cents from tests.tier(t2)), 1400);
  perform tests.assert_raises('...but it does keep the type from being removed (an order points at it)', format($q$select public.remove_org_tier(%L, %L)$q$, org, t2), 'cannot be removed');
  perform tests.assert_true('the list shows a started checkout as an order, not as a sale', (select not has_sold and has_orders and sold_count = 0 from public.list_org_tiers(org, ev_draft) l where l.tier_id = t2));
  perform tests.x(format($q$update public.site_ticket_tiers set requires_access_code = true where id = %L$q$, t2));
  perform tests.assert_true('...and says when a type needs an access code (set by BottlesUp in the CMS)', (select requires_access_code from public.list_org_tiers(org, ev_draft) l where l.tier_id = t2));
  perform tests.x(format($q$update public.site_ticket_tiers set requires_access_code = false where id = %L$q$, t2));
  perform tests.logout();
  perform tests.x(format($q$delete from public.site_orders where tier_id = %L$q$, t2));

  ---------------------------------------------------------------- removing
  perform tests.login(org_u, 'org@tix.example');
  perform public.remove_org_tier(org, t3);
  perform tests.logout();
  perform tests.assert_eq('an unsold type with no orders can be removed', tests.tiers(ev_draft), 'Early Bird:1400:50:0, General:3000:500:40');

  ---------------------------------------------------------------- a published event follows the same rules
  perform tests.login(org_u, 'org@tix.example');
  tp := public.save_org_tier(org, ev_pub, null, '{"name":"Late Release","price_cents":4000,"capacity":30}');
  perform tests.logout();
  perform tests.assert_true('a type can be added to a PUBLISHED event', tests.tiers(ev_pub) like '%Late Release:4000:30:0%');
  perform tests.login_anon();
  perform tests.assert_eq('an anonymous visitor reads the tier and its new columns on a published event', (select count(*)::int from public.site_ticket_tiers where id = tp and sale_starts_at is null and sale_ends_at is null), 1);
  perform tests.logout();
  perform tests.x(format($q$update public.site_ticket_tiers set sold_count = 7 where id = %L$q$, tp));
  perform tests.login(org_u, 'org@tix.example');
  perform tests.assert_raises('on a published event too, the price of a sold type is fixed', format($q$select public.save_org_tier(%L, %L, %L, '{"price_cents":1}')$q$, org, ev_pub, tp), 'have been sold');
  perform public.save_org_tier(org, ev_pub, tp, '{"capacity":60}');
  perform tests.assert_eq('...its capacity can be raised', (select capacity from tests.tier(tp)), 60);
  perform tests.assert_raises('...but not below what is sold', format($q$select public.save_org_tier(%L, %L, %L, '{"capacity":6}')$q$, org, ev_pub, tp), 'cannot be lower than the 7 tickets already sold');
  perform tests.assert_raises('...and it cannot be removed', format($q$select public.remove_org_tier(%L, %L)$q$, org, tp), 'cannot be removed');
  perform tests.logout();

  ---------------------------------------------------------------- an event that has ended
  perform tests.login(org_u, 'org@tix.example');
  perform tests.assert_raises('an ended event takes no new type', format($q$select public.save_org_tier(%L, %L, null, '{"name":"Late","price_cents":100,"capacity":5}')$q$, org, ev_old), 'this event has ended');
  perform tests.assert_raises('...no change', format($q$select public.save_org_tier(%L, %L, %L, '{"capacity":5}')$q$, org, ev_old, tid), 'this event has ended');
  perform tests.assert_raises('...no removal', format($q$select public.remove_org_tier(%L, %L)$q$, org, tid), 'this event has ended');
  perform tests.assert_raises('an event with an end time that has passed is over, even if it started less than 12 hours ago', format($q$select public.save_org_tier(%L, %L, null, '{"name":"Late","price_cents":100,"capacity":5}')$q$, org, ev_short), 'this event has ended');
  perform public.save_org_tier(org, ev_multi, null, '{"name":"Day two","price_cents":100,"capacity":5}');
  perform tests.assert_true('an event that started 20 hours ago but has not reached its end time is not over (the end time counts, not 12 hours after the start)', tests.tiers(ev_multi) like '%Day two:100:5:0%');
  perform tests.assert_eq('...but it can still be listed', (select count(*)::int from public.list_org_tiers(org, ev_old)), 1);
  perform tests.logout();
  -- the 12 hour rule when an event has no end time: started 13 hours ago is over, started 11 hours ago is not
  perform tests.x(format($q$update public.site_events set start_date = now() - interval '13 hours', end_date = null where id = %L$q$, ev_old));
  perform tests.login(org_u, 'org@tix.example');
  perform tests.assert_raises('an event with no end time is over 12 hours after it started', format($q$select public.save_org_tier(%L, %L, null, '{"name":"Late","price_cents":100,"capacity":5}')$q$, org, ev_old), 'this event has ended');
  perform tests.logout();
  perform tests.x(format($q$update public.site_events set start_date = now() - interval '11 hours' where id = %L$q$, ev_old));
  perform tests.login(org_u, 'org@tix.example');
  perform public.save_org_tier(org, ev_old, null, '{"name":"At the door","price_cents":100,"capacity":5}');
  perform tests.assert_true('...and not over 11 hours after it started', tests.tiers(ev_old) like '%At the door:100:5:0%');
  perform tests.logout();

  ---------------------------------------------------------------- the apps cannot write tickets directly; every change is recorded
  perform tests.login(org_u, 'org@tix.example');
  update public.site_ticket_tiers set price_cents = 1, capacity = 1 where id = t1;
  perform tests.assert_true('an organizer cannot change the table directly: the update touches nothing (no policy lets them)', (select price_cents = 3000 and capacity = 500 from tests.tier(t1)));
  delete from public.site_ticket_tiers where id = t1;
  perform tests.assert_true('...nor delete from it: the row is still there', (select id is not null from tests.tier(t1)));
  perform tests.assert_raises('...nor insert into it', format($q$insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (%L, 'Sneaky', 1, 1)$q$, ev_draft), 'row-level security');
  perform tests.assert_raises('the helpers cannot be called by the app', format($q$select public.org_tier_has_sold(%L)$q$, t1), 'permission denied');
  perform tests.logout();
  select count(*)::int into n_audit from public.audit_log where action = 'org_tier.created' and entity_id = ev_draft::text and actor_id = org_u;
  perform tests.assert_true('every added type was recorded with who did it', n_audit >= 4);
  perform tests.assert_eq('...and with what was added', (select count(*)::int from public.audit_log where action = 'org_tier.created' and details ->> 'name' = 'Early Bird' and (details ->> 'price_cents')::int = 1500 and (details ->> 'capacity')::int = 50 and details ->> 'tier' = t2::text), 1);
  perform tests.assert_true('changes were recorded with the new values', (select count(*) from public.audit_log where action = 'org_tier.updated' and details ->> 'tier' = t1::text and (details ->> 'price_cents')::int = 3000 and (details ->> 'capacity')::int = 500) >= 1);
  perform tests.assert_eq('a removal was recorded', (select count(*)::int from public.audit_log where action = 'org_tier.removed' and details ->> 'tier' = t3::text), 1);
end $$;

rollback;
