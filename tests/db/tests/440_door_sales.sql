-- Door sales and the door's shift summary (20261026100000_door_sales.sql). What matters: only door staff who cover the event, and only while the event is on, can sell; the sale is paid, issued and
-- checked in ONCE with a ticket code in the website's format, the method (cash, or the club's own card machine with its receipt number) is recorded separately; the last tickets can never be sold
-- twice; the same sale sent twice is one sale; nothing is e-mailed or charged; the records stay with the person who sold after their access ends; the shift summary shows only that person's own
-- figures; and no older table, scanner or online order is changed by any of it.
begin;

-- the answer of a sale as one line: "<quantity>/<amount>/<left>/<repeated> <ticket code shape>" or the error
create function tests.sell(p_user uuid, p_event uuid, p_tier uuid, p_qty int, p_method text, p_name text, p_email text, p_phone text, p_ref text, p_key text) returns text language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user);
  r := public.door_sell_ticket(p_event, p_tier, p_qty, p_method, p_name, p_email, p_phone, p_ref, p_key);
  perform tests.logout();
  return (r ->> 'quantity') || '/' || (r ->> 'amount_cents') || '/' || (r ->> 'available') || '/' || (r ->> 'repeated') || ' ' || (r ->> 'tier_name');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.sale(p_user uuid, p_event uuid, p_tier uuid, p_qty int, p_method text, p_key text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user);
  r := public.door_sell_ticket(p_event, p_tier, p_qty, p_method, 'Test Guest', null, null, case when p_method = 'external_terminal' then 'REC-1234' end, p_key);
  perform tests.logout();
  return r;
end $$;
create function tests.opts(p_user uuid, p_event uuid) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user);
  v := (select string_agg(o.tier_name || ':' || o.price_cents || ':' || o.available, ',' order by o.price_cents, o.tier_name) from public.door_sale_options(p_event) o);
  perform tests.logout();
  return v;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.summary(p_user uuid, p_event uuid) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform tests.login(p_user);
  v := public.door_shift_summary(p_event);
  perform tests.logout();
  return v;
exception when others then
  perform tests.logout();
  return jsonb_build_object('error', sqlerrm);
end $$;
create function tests.order_of(p_code text) returns public.site_orders language sql security definer as $$ select * from public.site_orders where ticket_code = p_code $$;
create function tests.order_count(p_event uuid) returns int language sql security definer as $$ select count(*)::int from public.site_orders where event_id = p_event $$;
create function tests.sold(p_tier uuid) returns int language sql security definer as $$ select sold_count from public.site_ticket_tiers where id = p_tier $$;
create function tests.admitted(p_order uuid) returns int language sql security definer as $$ select coalesce(sum(guests), 0)::int from public.site_order_admissions where order_id = p_order $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000d1';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000d2';
  door_a2 constant uuid := '00000000-0000-0000-0000-0000000000d3';
  door_b constant uuid := '00000000-0000-0000-0000-0000000000d4';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000d5';
  rival_door constant uuid := '00000000-0000-0000-0000-0000000000d6';
  legacy_staff constant uuid := '00000000-0000-0000-0000-0000000000a1';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_r uuid; tok text;
  ev_a uuid; ev_a_soon uuid; ev_far uuid; ev_old uuid; ev_draft uuid; ev_b uuid; ev_r uuid; ev_noend uuid;
  t_gen uuid; t_vip uuid; t_full uuid; t_free uuid; t_gated uuid; t_soon uuid; t_far uuid; t_old uuid; t_draft uuid; t_b uuid; t_r uuid; t_noend uuid;
  r jsonb; o public.site_orders; code text; code2 text; txt text; n int; mem uuid; sold_before int;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@ds.example'), (door_a, 'doora@ds.example'), (door_a2, 'doora2@ds.example'), (door_b, 'doorb@ds.example'), (rival_u, 'rival@ds2.example'), (rival_door, 'doorr@ds2.example');

  perform tests.login(owner_u, 'owner@ds.example');
  org := public.create_organization('Door Sales Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@ds2.example');
  org2 := public.create_organization('Rival Sales Co', 'venue_owner');
  venue_r := public.create_org_venue(org2, 'Rival Club');

  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Tonight', 'd', 'Club A', now() + interval '1 hour', now() + interval '9 hours', 'published', venue_a) returning id into ev_a;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Tomorrow Morning', 'd', 'Club A', now() + interval '20 hours', now() + interval '28 hours', 'published', venue_a) returning id into ev_a_soon;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Next Week', 'd', 'Club A', now() + interval '3 days', now() + interval '3 days 8 hours', 'published', venue_a) returning id into ev_far;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Last Night', 'd', 'Club A', now() - interval '20 hours', now() - interval '10 hours', 'published', venue_a) returning id into ev_old;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Draft Night', 'd', 'Club A', now() + interval '1 hour', now() + interval '9 hours', 'draft', venue_a) returning id into ev_draft;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('No End Night', 'd', 'Club A', now() - interval '2 hours', null, 'published', venue_a) returning id into ev_noend;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Club B Night', 'd', 'Club B', now() + interval '1 hour', now() + interval '9 hours', 'published', venue_b) returning id into ev_b;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Rival Night', 'd', 'Rival Club', now() + interval '1 hour', now() + interval '9 hours', 'published', venue_r) returning id into ev_r;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_a, 'General', 5000, 10) returning id into t_gen;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_a, 'VIP', 12000, 3) returning id into t_vip;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity, sold_count) values (ev_a, 'Sold Out', 3000, 2, 2) returning id into t_full;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_a, 'Free Entry', 0, 5) returning id into t_free;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity, requires_access_code) values (ev_a, 'Invited Only', 8000, 5, true) returning id into t_gated;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_a_soon, 'General', 4000, 10) returning id into t_soon;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_far, 'General', 4000, 10) returning id into t_far;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_old, 'General', 4000, 10) returning id into t_old;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_draft, 'General', 4000, 10) returning id into t_draft;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_noend, 'General', 4000, 10) returning id into t_noend;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_b, 'General', 4000, 10) returning id into t_b;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_r, 'General', 4000, 10) returning id into t_r;
  -- an online order that already exists, and one that a door person will scan
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, stripe_checkout_session_id) values
    (ev_a, t_gen, 'Online Olivia', 'olivia@t.example', 2, 10000, 'paid', 'DS-ONLINE', 'cs_live_x1');
  update public.site_ticket_tiers set sold_count = 2 where id = t_gen;

  perform tests.login(owner_u, 'owner@ds.example');
  select i.token into tok from public.invite_member(org, 'doora@ds.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@ds.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@ds.example');
  select i.token into tok from public.invite_member(org, 'doora2@ds.example', 'door', venue_a) i;
  perform tests.login(door_a2, 'doora2@ds.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@ds.example');
  select i.token into tok from public.invite_member(org, 'doorb@ds.example', 'door', venue_b) i;
  perform tests.login(door_b, 'doorb@ds.example'); perform public.accept_invitation(tok);
  perform tests.login(rival_u, 'rival@ds2.example');
  select i.token into tok from public.invite_member(org2, 'doorr@ds2.example', 'door', venue_r) i;
  perform tests.login(rival_door, 'doorr@ds2.example'); perform public.accept_invitation(tok);
  perform tests.logout();

  ---------------------------------------------------------------- who may
  perform tests.assert_eq('the owner is not a door person', tests.sell(owner_u, ev_a, t_gen, 1, 'cash', 'Walk In', null, null, null, 'key-owner-0001'), 'ERROR: not authorized');
  perform tests.assert_eq('existing door_staff have their own pages, not door sales', tests.sell(legacy_staff, ev_a, t_gen, 1, 'cash', 'Walk In', null, null, null, 'key-legacy-0001'), 'ERROR: not authorized');
  perform tests.assert_eq('a door person of another club cannot sell for this club''s event', tests.sell(door_b, ev_a, t_gen, 1, 'cash', 'Walk In', null, null, null, 'key-clubb-00001'), 'ERROR: not authorized');
  perform tests.assert_eq('...nor a rival''s door person', tests.sell(rival_door, ev_a, t_gen, 1, 'cash', 'Walk In', null, null, null, 'key-rival-00001'), 'ERROR: not authorized');
  perform tests.assert_eq('a door person cannot sell for another club''s event either', tests.sell(door_a, ev_b, t_b, 1, 'cash', 'Walk In', null, null, null, 'key-evb-000001'), 'ERROR: not authorized');
  perform tests.assert_eq('...no event at all is refused', tests.sell(door_a, null, t_gen, 1, 'cash', 'Walk In', null, null, null, 'key-noev-000001'), 'ERROR: not authorized');
  perform tests.assert_eq('the options are refused to the owner', tests.opts(owner_u, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('...and to another club''s door person', tests.opts(door_b, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('the shift summary is refused to another club''s door person', tests.summary(door_b, ev_a) ->> 'error', 'not authorized');
  perform tests.assert_eq('...and to the owner', tests.summary(owner_u, ev_a) ->> 'error', 'not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot ask what can be sold', format($q$select * from public.door_sale_options(%L)$q$, ev_a), 'permission denied');
  perform tests.assert_raises('...nor sell', format($q$select public.door_sell_ticket(%L, %L, 1, 'cash', 'Walk In', null, null, null, 'key-anon-000001')$q$, ev_a, t_gen), 'permission denied');
  perform tests.assert_raises('...nor read a shift', format($q$select public.door_shift_summary(%L)$q$, ev_a), 'permission denied');
  perform tests.logout();
  perform tests.login(door_a);
  perform tests.assert_raises('the sale window check is internal, not callable by a signed-in user', format($q$select public.door_sale_window_open(%L)$q$, ev_a), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('nothing was sold by any of that', tests.order_count(ev_a), 1);

  ---------------------------------------------------------------- when the door may sell
  perform tests.assert_eq('tonight''s event is open for sale', tests.opts(door_a, ev_a) is not null and tests.opts(door_a, ev_a) not like 'ERROR%', true);
  perform tests.assert_eq('an event that starts within a day is open', tests.opts(door_a, ev_a_soon), 'General:4000:10');
  perform tests.assert_eq('an event that started with no end time is open for its first 12 hours', tests.opts(door_a, ev_noend), 'General:4000:10');
  perform tests.assert_eq('an event days away is not open yet', tests.opts(door_a, ev_far), 'ERROR: ticket sales at the door are not open for this event');
  perform tests.assert_eq('an event that ended 10 hours ago is closed', tests.opts(door_a, ev_old), 'ERROR: ticket sales at the door are not open for this event');
  perform tests.assert_eq('a draft event is closed', tests.opts(door_a, ev_draft), 'ERROR: ticket sales at the door are not open for this event');
  perform tests.assert_eq('selling for an event days away is refused', tests.sell(door_a, ev_far, t_far, 1, 'cash', 'Walk In', null, null, null, 'key-far-0000001'), 'ERROR: ticket sales at the door are not open for this event');
  perform tests.assert_eq('...also after it ended', tests.sell(door_a, ev_old, t_old, 1, 'cash', 'Walk In', null, null, null, 'key-old-0000001'), 'ERROR: ticket sales at the door are not open for this event');
  perform tests.assert_eq('...also a draft', tests.sell(door_a, ev_draft, t_draft, 1, 'cash', 'Walk In', null, null, null, 'key-draft-000001'), 'ERROR: ticket sales at the door are not open for this event');
  perform tests.assert_eq('...nothing was sold for them', tests.order_count(ev_far) + tests.order_count(ev_old) + tests.order_count(ev_draft), 0);

  ---------------------------------------------------------------- what can be sold
  perform tests.assert_eq('the ticket types with their price and what is left, cheapest first; the invited-only type is not offered', tests.opts(door_a, ev_a), 'Free Entry:0:5,Sold Out:3000:0,General:5000:8,VIP:12000:3');
  perform tests.assert_eq('a type that needs an access code online is not sold at the door', tests.sell(door_a, ev_a, t_gated, 1, 'cash', 'Walk In', null, null, null, 'key-gated-00001'), 'ERROR: that ticket type is not sold at the door');
  perform tests.assert_eq('another event''s type is not found', tests.sell(door_a, ev_a, t_b, 1, 'cash', 'Walk In', null, null, null, 'key-othertier-01'), 'ERROR: ticket type not found');
  perform tests.assert_eq('a type that does not exist is not found', tests.sell(door_a, ev_a, gen_random_uuid(), 1, 'cash', 'Walk In', null, null, null, 'key-notier-0001'), 'ERROR: ticket type not found');
  perform tests.assert_eq('...also no type at all', tests.sell(door_a, ev_a, null, 1, 'cash', 'Walk In', null, null, null, 'key-nulltier-01'), 'ERROR: ticket type not found');

  ---------------------------------------------------------------- what must be filled in
  perform tests.assert_eq('no payment method is refused', tests.sell(door_a, ev_a, t_gen, 1, null, 'Walk In', null, null, null, 'key-nomethod-01'), 'ERROR: choose how it was paid: cash, or the card terminal');
  perform tests.assert_eq('a method that is neither cash nor the club''s terminal is refused (BottlesUp takes no card here)', tests.sell(door_a, ev_a, t_gen, 1, 'card', 'Walk In', null, null, null, 'key-card-0000001'), 'ERROR: choose how it was paid: cash, or the card terminal');
  perform tests.assert_eq('the terminal needs its receipt number', tests.sell(door_a, ev_a, t_gen, 1, 'external_terminal', 'Walk In', null, null, null, 'key-noref-000001'), 'ERROR: add the terminal''s receipt number');
  perform tests.assert_eq('...not a blank one', tests.sell(door_a, ev_a, t_gen, 1, 'external_terminal', 'Walk In', null, null, '   ', 'key-blankref-001'), 'ERROR: add the terminal''s receipt number');
  perform tests.assert_eq('...nor one that is too short', tests.sell(door_a, ev_a, t_gen, 1, 'external_terminal', 'Walk In', null, null, 'ab', 'key-shortref-001'), 'ERROR: the receipt number needs 3 to 120 characters');
  perform tests.assert_eq('...nor a very long one', tests.sell(door_a, ev_a, t_gen, 1, 'external_terminal', 'Walk In', null, null, repeat('9', 121), 'key-longref-0001'), 'ERROR: the receipt number needs 3 to 120 characters');
  perform tests.assert_eq('the guest''s name is needed', tests.sell(door_a, ev_a, t_gen, 1, 'cash', '', null, null, null, 'key-noname-00001'), 'ERROR: the guest''s name needs 2 to 120 characters');
  perform tests.assert_eq('...and not one letter', tests.sell(door_a, ev_a, t_gen, 1, 'cash', 'X', null, null, null, 'key-oneletter-01'), 'ERROR: the guest''s name needs 2 to 120 characters');
  perform tests.assert_eq('...nor blanks', tests.sell(door_a, ev_a, t_gen, 1, 'cash', '    ', null, null, null, 'key-blankname-01'), 'ERROR: the guest''s name needs 2 to 120 characters');
  perform tests.assert_eq('an email that is not one is refused (leave it empty instead)', tests.sell(door_a, ev_a, t_gen, 1, 'cash', 'Walk In', 'not-an-email', null, null, 'key-badmail-0001'), 'ERROR: enter a valid email address, or leave it empty');
  perform tests.assert_eq('...also with a space in it', tests.sell(door_a, ev_a, t_gen, 1, 'cash', 'Walk In', 'a b@c.com', null, null, 'key-spacemail-01'), 'ERROR: enter a valid email address, or leave it empty');
  perform tests.assert_eq('a phone number that is too long is refused', tests.sell(door_a, ev_a, t_gen, 1, 'cash', 'Walk In', null, repeat('1', 41), null, 'key-longphone-01'), 'ERROR: the phone number is too long');
  perform tests.assert_eq('no tickets is refused', tests.sell(door_a, ev_a, t_gen, 0, 'cash', 'Walk In', null, null, null, 'key-zero-0000001'), 'ERROR: how many tickets? between 1 and 20');
  perform tests.assert_eq('...also a negative number', tests.sell(door_a, ev_a, t_gen, -1, 'cash', 'Walk In', null, null, null, 'key-negative-001'), 'ERROR: how many tickets? between 1 and 20');
  perform tests.assert_eq('...and more than twenty at once', tests.sell(door_a, ev_a, t_gen, 21, 'cash', 'Walk In', null, null, null, 'key-twentyone-01'), 'ERROR: how many tickets? between 1 and 20');
  perform tests.assert_eq('...and no number', tests.sell(door_a, ev_a, t_gen, null, 'cash', 'Walk In', null, null, null, 'key-nullqty-0001'), 'ERROR: how many tickets? between 1 and 20');
  perform tests.assert_eq('a sale needs its own key', tests.sell(door_a, ev_a, t_gen, 1, 'cash', 'Walk In', null, null, null, 'short'), 'ERROR: a sale needs its own key of 8 to 80 characters');
  perform tests.assert_eq('...also an empty one', tests.sell(door_a, ev_a, t_gen, 1, 'cash', 'Walk In', null, null, null, null), 'ERROR: a sale needs its own key of 8 to 80 characters');
  perform tests.assert_eq('nothing was sold and nothing was counted by any refusal', tests.order_count(ev_a) * 1000 + tests.sold(t_gen), 1000 + 2);

  ---------------------------------------------------------------- a cash sale
  perform tests.assert_eq('two General tickets for cash, with an email', tests.sell(door_a, ev_a, t_gen, 2, 'cash', '  Dana Door ', ' DANA@Example.com ', '+1 555 0100', null, 'key-dana-000001'), '2/10000/6/false General');
  select * into o from public.site_orders where customer_name = 'Dana Door';
  perform tests.assert_true('the order is paid, in the website''s ticket code format, and checked in at the same moment', o.status = 'paid' and o.ticket_code ~ '^BU-[A-HJ-NP-Z2-9]{8}$' and o.checked_in_at is not null);
  perform tests.assert_eq('...two guests, for the price of two', o.quantity * 100000 + o.amount_total_cents, 2 * 100000 + 10000);
  perform tests.assert_eq('...the name is trimmed and the email is stored lower case and trimmed', o.customer_name || '|' || o.customer_email, 'Dana Door|dana@example.com');
  perform tests.assert_eq('...with the phone', o.customer_phone, '+1 555 0100');
  perform tests.assert_true('...recorded as a door sale paid in cash, by the person who sold it, with no receipt number', o.sale_channel = 'door' and o.door_payment_method = 'cash' and o.door_reference is null and o.sold_by = door_a and o.checked_in_by = door_a);
  perform tests.assert_true('...no card payment was ever started for it', o.stripe_checkout_session_id is null and o.stripe_payment_intent_id is null and o.ticket_sent_at is null);
  perform tests.assert_eq('...both guests are recorded as in, by the seller', tests.admitted(o.id) * 10 + (select count(*) from public.site_order_admissions a where a.order_id = o.id and a.admitted_by = door_a)::int, 2 * 10 + 1);
  perform tests.assert_eq('the tier''s sold count went up by two', tests.sold(t_gen), 4);
  perform tests.assert_eq('the sale is in the audit log, without the guest''s email', (select count(*) from public.audit_log l where l.action = 'door.ticket_sold' and l.entity_id = o.id::text and l.details ->> 'method' = 'cash' and (l.details ->> 'has_email')::boolean and not l.details::text like '%dana@%')::int, 1);
  code := o.ticket_code;
  perform tests.login(door_a);
  select r.result into txt from public.door_admit_group(code, 1, ev_a) r;
  perform tests.assert_eq('scanning the ticket afterwards says it is already used (the door''s scanner sees it as fully in)', txt, 'already_checked_in');
  select result into txt from public.door_scan_ticket(code, ev_a);
  perform tests.assert_eq('...and so does the older scanner', txt, 'already_checked_in');
  perform tests.assert_eq('the door''s exact count of guests inside includes them (2 sold + 2 online not yet scanned = 2)', (select c.guests_admitted from public.door_admission_counts(array[ev_a]) c), 2);
  perform tests.logout();

  ---------------------------------------------------------------- without an email, with the club's own card machine, free entry
  perform tests.assert_eq('one VIP on the club''s own card machine with its receipt number, no email', tests.sell(door_a, ev_a, t_vip, 1, 'external_terminal', 'Victor Vip', '', null, ' TERM-8841 ', 'key-victor-00001'), '1/12000/2/false VIP');
  select * into o from public.site_orders where customer_name = 'Victor Vip';
  perform tests.assert_true('...recorded as the terminal with its number, the email stored empty (the column is required) and the phone empty', o.door_payment_method = 'external_terminal' and o.door_reference = 'TERM-8841' and o.customer_email = '' and o.customer_phone is null);
  perform tests.assert_eq('free entry is a sale of nothing, recorded', tests.sell(door_a, ev_a, t_free, 3, 'cash', 'Free Fran', null, null, null, 'key-fran-0000001'), '3/0/2/false Free Entry');
  perform tests.assert_eq('...it counts as three guests in', tests.admitted((select id from public.site_orders where customer_name = 'Free Fran')), 3);
  perform tests.assert_eq('a cash sale that carries a reference keeps it (a note is allowed)', tests.sell(door_a, ev_a, t_gen, 1, 'cash', 'Cash Carl', null, null, 'NOTE-77', 'key-carl-0000001'), '1/5000/5/false General');
  perform tests.assert_eq('...stored as given', (select door_reference from public.site_orders where customer_name = 'Cash Carl'), 'NOTE-77');

  ---------------------------------------------------------------- the last tickets
  perform tests.assert_eq('a sold-out type cannot be sold', tests.sell(door_a, ev_a, t_full, 1, 'cash', 'Too Late', null, null, null, 'key-full-0000001'), 'ERROR: only 0 of these tickets are left');
  perform tests.assert_eq('three VIP were for sale and one is sold: asking for three says two are left', tests.sell(door_a, ev_a, t_vip, 3, 'cash', 'Greedy Group', null, null, null, 'key-greedy-00001'), 'ERROR: only 2 of these tickets are left');
  perform tests.assert_eq('...nothing was sold or counted', tests.sold(t_vip) * 100 + (select count(*) from public.site_orders where customer_name = 'Greedy Group')::int, 100);
  perform tests.assert_eq('the last two can be sold', tests.sell(door_a2, ev_a, t_vip, 2, 'cash', 'Last Two', null, null, null, 'key-lasttwo-0001'), '2/24000/0/false VIP');
  perform tests.assert_eq('and then there is nothing left', tests.sell(door_a, ev_a, t_vip, 1, 'cash', 'After Last', null, null, null, 'key-afterlast-001'), 'ERROR: only 0 of these tickets are left');
  perform tests.assert_eq('...the count never goes above the capacity', tests.sold(t_vip), 3);
  perform tests.assert_eq('the options show it as gone', tests.opts(door_a, ev_a), 'Free Entry:0:2,Sold Out:3000:0,General:5000:5,VIP:12000:0');

  ---------------------------------------------------------------- the same sale sent twice
  r := tests.sale(door_a, ev_a, t_gen, 1, 'cash', 'key-repeat-00001');
  perform tests.assert_true('a new sale is not marked as repeated', (r ->> 'repeated')::boolean is false);
  sold_before := tests.sold(t_gen);
  n := tests.order_count(ev_a);
  perform tests.login(door_a);
  perform tests.assert_eq('the same key again returns the same order and ticket', (public.door_sell_ticket(ev_a, t_gen, 1, 'cash', 'Test Guest', null, null, null, 'key-repeat-00001')) ->> 'order_id', r ->> 'order_id');
  perform tests.assert_eq('...marked as repeated, with the same ticket code', (public.door_sell_ticket(ev_a, t_gen, 1, 'cash', 'Test Guest', null, null, null, 'key-repeat-00001')) ->> 'ticket_code' || '/true', (r ->> 'ticket_code') || '/true');
  perform tests.assert_true('...flagged as a repeat', ((public.door_sell_ticket(ev_a, t_gen, 1, 'cash', 'Test Guest', null, null, null, 'key-repeat-00001')) ->> 'repeated')::boolean);
  perform tests.logout();
  perform tests.assert_eq('...nothing new was made or counted', tests.order_count(ev_a) * 1000 + tests.sold(t_gen), n * 1000 + sold_before);
  perform tests.assert_eq('the same key with a different quantity is not the same sale', tests.sell(door_a, ev_a, t_gen, 2, 'cash', 'Test Guest', null, null, null, 'key-repeat-00001'), 'ERROR: that sale key was already used for a different sale');
  perform tests.assert_eq('...nor with a different ticket type', tests.sell(door_a, ev_a, t_free, 1, 'cash', 'Test Guest', null, null, null, 'key-repeat-00001'), 'ERROR: that sale key was already used for a different sale');
  perform tests.assert_eq('another person using the same key makes their own sale', tests.sell(door_a2, ev_a, t_gen, 1, 'cash', 'Second Hand', null, null, null, 'key-repeat-00001'), '1/5000/3/false General');
  perform tests.assert_eq('a retry after the tickets ran out still returns the sale that was made', tests.sell(door_a2, ev_a, t_vip, 2, 'cash', 'Last Two', null, null, null, 'key-lasttwo-0001'), '2/24000/0/true VIP');
  perform tests.assert_eq('...and so after a wrong method or name would have been refused', tests.sell(door_a2, ev_a, t_vip, 2, null, '', null, null, null, 'key-lasttwo-0001'), '2/24000/0/true VIP');

  ---------------------------------------------------------------- the shift summary: only your own
  r := tests.summary(door_a, ev_a);
  perform tests.assert_eq('the event is named', r ->> 'event_title', 'Tonight');
  perform tests.assert_eq('door A''s cash sales: Dana 2 General (10000), Fran 3 free (0), Carl 1 General (5000), the repeat-test ticket 1 (5000) = 4 sales, 7 tickets, 20000',
    (select (m ->> 'sales') || '/' || (m ->> 'tickets') || '/' || (m ->> 'amount_cents') from jsonb_array_elements(r -> 'sales') m where m ->> 'method' = 'cash'), '4/7/20000');
  perform tests.assert_eq('door A''s terminal sales are listed apart: 1 sale, 1 ticket, 12000', (select (m ->> 'sales') || '/' || (m ->> 'tickets') || '/' || (m ->> 'amount_cents') from jsonb_array_elements(r -> 'sales') m where m ->> 'method' = 'external_terminal'), '1/1/12000');
  perform tests.assert_eq('only the two methods are listed', jsonb_array_length(r -> 'sales'), 2);
  perform tests.assert_true('the time of the first and last sale are there', (r ->> 'first_sale_at') is not null and (r ->> 'last_sale_at') is not null and (r ->> 'first_sale_at') <= (r ->> 'last_sale_at'));
  perform tests.assert_eq('door A has not scanned any online ticket yet', (r ->> 'guests_admitted') || '/' || (r ->> 'scans_accepted'), '0/0');
  r := tests.summary(door_a2, ev_a);
  perform tests.assert_eq('door A2 sees only their own: Last Two (VIP 2, 24000) and Second Hand (1, 5000), both cash', (select (m ->> 'sales') || '/' || (m ->> 'tickets') || '/' || (m ->> 'amount_cents') from jsonb_array_elements(r -> 'sales') m where m ->> 'method' = 'cash'), '2/3/29000');
  perform tests.assert_eq('...and no terminal sales', (select count(*) from jsonb_array_elements(r -> 'sales') m where m ->> 'method' = 'external_terminal')::int, 0);
  perform tests.login(door_a2);
  select r2.result into txt from public.door_admit_group('DS-ONLINE', 1, ev_a) r2;
  perform tests.assert_eq('door A2 admits one of the two guests of an online order by scanning', txt, 'ok');
  perform tests.login(door_a);
  select r2.result into txt from public.door_admit_group('DS-ONLINE', 1, ev_a) r2;
  perform tests.assert_eq('door A admits the other', txt, 'ok');
  perform tests.logout();
  r := tests.summary(door_a, ev_a);
  perform tests.assert_eq('door A''s shift counts the one guest they scanned in, and that scan', (r ->> 'guests_admitted') || '/' || (r ->> 'scans_accepted'), '1/1');
  r := tests.summary(door_a2, ev_a);
  perform tests.assert_eq('...door A2''s counts their own one', (r ->> 'guests_admitted') || '/' || (r ->> 'scans_accepted'), '1/1');
  perform tests.assert_eq('a shift with nothing in it is empty, not an error (door A at the soon event)', tests.summary(door_a, ev_a_soon) ->> 'guests_admitted', '0');
  perform tests.assert_eq('...with no sales', jsonb_array_length(tests.summary(door_a, ev_a_soon) -> 'sales'), 0);
  perform tests.assert_true('...and no times', (tests.summary(door_a, ev_a_soon) -> 'first_sale_at') = 'null'::jsonb);
  perform tests.assert_eq('the summary can still be read for an event that has ended (the shift report after the night)', tests.summary(door_a, ev_old) ->> 'event_title', 'Last Night');

  ---------------------------------------------------------------- nothing else changed
  perform tests.assert_eq('the online order is untouched and still an online one', (select sale_channel || '/' || coalesce(door_payment_method, '-') || '/' || status from public.site_orders where ticket_code = 'DS-ONLINE'), 'online/-/paid');
  perform tests.logout();
  perform tests.assert_raises('an online order cannot be given a door payment method', $q$update public.site_orders set door_payment_method = 'cash' where ticket_code = 'DS-ONLINE'$q$, 'site_orders_door_sale_check');
  perform tests.assert_raises('...nor a seller', format($q$update public.site_orders set sold_by = %L where ticket_code = 'DS-ONLINE'$q$, door_a), 'site_orders_door_sale_check');
  perform tests.assert_raises('a door sale cannot exist without a payment method', $q$update public.site_orders set door_payment_method = null where customer_name = 'Dana Door'$q$, 'site_orders_door_sale_check');
  perform tests.assert_raises('...nor a terminal sale without its receipt number', $q$update public.site_orders set door_reference = null where customer_name = 'Victor Vip'$q$, 'site_orders_door_sale_check');
  perform tests.assert_raises('...nor a sale without its key', $q$update public.site_orders set door_client_key = null where customer_name = 'Dana Door'$q$, 'site_orders_door_sale_check');
  perform tests.assert_raises('only cash or the club''s terminal can be the method', $q$update public.site_orders set door_payment_method = 'card' where customer_name = 'Dana Door'$q$, 'check');
  perform tests.assert_raises('the same person cannot use one key for two sales, whatever the table says', format($q$insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, sale_channel, door_payment_method, sold_by, door_client_key) values (%L, %L, 'Dup', '', 1, 5000, 'paid', 'door', 'cash', %L, 'key-dana-000001')$q$, ev_a, t_gen, door_a), 'site_orders_door_sale_key');

  ---------------------------------------------------------------- after the access ends the records stay
  select m.id into mem from public.site_memberships m where m.user_id = door_a and m.role = 'door' and m.status = 'active';
  perform tests.login(owner_u, 'owner@ds.example');
  perform public.revoke_membership(mem);
  perform tests.assert_eq('a door person whose access ended can no longer sell', tests.sell(door_a, ev_a, t_gen, 1, 'cash', 'Too Late Tim', null, null, null, 'key-revoked-0001'), 'ERROR: not authorized');
  perform tests.assert_eq('...nor read what can be sold', tests.opts(door_a, ev_a), 'ERROR: not authorized');
  perform tests.assert_eq('...nor their old shift through the app', tests.summary(door_a, ev_a) ->> 'error', 'not authorized');
  perform tests.logout();
  perform tests.assert_eq('their sales are all still there, in their name', (select count(*) from public.site_orders where sold_by = door_a)::int, 5);
  perform tests.assert_eq('...and what they checked in is still attributed to them', (select count(*) from public.site_orders where checked_in_by = door_a)::int, 5);
  perform tests.assert_eq('the other door person is not affected', tests.sell(door_a2, ev_a, t_free, 1, 'cash', 'Still Open', null, null, null, 'key-stillopen-001'), '1/0/1/false Free Entry');

end
$$;

rollback;
