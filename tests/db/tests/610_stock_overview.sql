-- Stock overview (20261122110000_stock_overview.sql). What matters: only the club's owner and manager can read it; it counts a bottle as sold only on a confirmed booking's paid or due-at-venue
-- line that was not cancelled; "reserved" is sold and not handed over, "handed over" counts a Delivered line in full and a part delivery by its delivered quantity, and reserved plus
-- handed over is everything sold; "available" is the counted stock minus everything sold and never below 0 (nothing for a bottle nobody counted); the "most sold" figure follows the period asked
-- for; another club's bottles never show; and nothing at all is changed by reading it.
begin;

create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_status text default 'paid') returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, 1000, 0, p_status, upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkbottle(p_venue uuid, p_name text, p_stock int default null) returns uuid language sql security definer as $$
  insert into public.site_bottles (venue_id, name, size, category, price_cents, stock_quantity, is_available, is_sold_out, sort_order)
  values (p_venue, p_name, '750ml', 'Spirits', 1000, p_stock, true, false, 0) returning id $$;
create function tests.mkline(p_booking uuid, p_bottle uuid, p_qty int, p_pay text default 'paid', p_served boolean default false, p_delivered int default 0, p_cancelled boolean default false, p_age interval default '0') returns uuid language sql security definer as $$
  insert into public.site_table_booking_bottles (booking_id, bottle_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, payment_status, service_status, delivered_quantity, cancelled_at, created_at)
  values (p_booking, p_bottle, 'x', '750ml', 1000, p_qty, 1000 * p_qty, p_pay, case when p_served then 'served' else 'awaiting_prep' end, p_delivered, case when p_cancelled then now() end, now() - p_age) returning id $$;

create function tests.ov(p_user uuid, p_email text, p_venue uuid, p_from timestamptz default null, p_to timestamptz default null) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce(array_to_string(array(
    select o.name || ' ' || coalesce(o.on_hand::text, '-') || '/' || o.reserved || '/' || o.handed_over || '/' || coalesce(o.available::text, '-') || '/' || o.sold || case when o.is_low then ' LOW' else '' end
      from public.stock_overview(p_venue, p_from, p_to) o), ' | '), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.snapshot() returns text language sql security definer as $$
  select md5(
    coalesce((select string_agg(b.id::text || ':' || coalesce(b.stock_quantity::text, '-') || ':' || b.is_sold_out::text, ',' order by b.id) from public.site_bottles b), '') || '|' ||
    coalesce((select string_agg(l.id::text || ':' || l.quantity || ':' || l.delivered_quantity || ':' || l.service_status || ':' || l.payment_status || ':' || coalesce(l.cancelled_at::text, '-'), ',' order by l.id) from public.site_table_booking_bottles l), '') || '|' ||
    (select count(*)::text from public.site_stock_movements)) $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000f1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000000f2';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000f3';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000f4';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000000f5';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000000f6';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000000f8';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_r uuid; tok text;
  type_a uuid; type_b uuid; slot_eve uuid; slot_b uuid;
  b_ada uuid; b_zed uuid; b_pend uuid; b_gone uuid; b_bea uuid;
  patron uuid; goose uuid; hen uuid; zero uuid; rum uuid; vodka_b uuid;
  night date := current_date + 10;
  before_snap text;
  r record;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@so.example'), (mgr_a, 'mgra@so.example'), (rival_u, 'rival@so2.example'), (door_a, 'doora@so.example'), (mgr_b, 'mgrb@so.example'), (srv_1, 'srv1@so.example'), (ver_a, 'vera@so.example')
    on conflict do nothing;

  perform tests.login(owner_u, 'owner@so.example');
  org := public.create_organization('Overview Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@so2.example');
  org2 := public.create_organization('Rival Overview Co', 'venue_owner');
  venue_r := public.create_org_venue(org2, 'Rival Club');

  perform tests.login(owner_u, 'owner@so.example');
  select i.token into tok from public.invite_member(org, 'mgra@so.example', 'manager', venue_a) i;
  perform tests.login(mgr_a, 'mgra@so.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@so.example');
  select i.token into tok from public.invite_member(org, 'mgrb@so.example', 'manager', venue_b) i;
  perform tests.login(mgr_b, 'mgrb@so.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@so.example');
  select i.token into tok from public.invite_member(org, 'srv1@so.example', 'server', venue_a) i;
  perform tests.login(srv_1, 'srv1@so.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@so.example');
  select i.token into tok from public.invite_member(org, 'doora@so.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@so.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@so.example');
  select i.token into tok from public.invite_member(org, 'vera@so.example', 'verifier', venue_a) i;
  perform tests.login(ver_a, 'vera@so.example'); perform public.accept_invitation(tok);

  perform tests.logout();
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 5) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 5) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;

  b_ada := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Ada Evening');
  b_zed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Zed Evening');
  b_pend := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Pending Pat', 'pending');
  b_gone := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Gone Gil', 'cancelled');
  b_bea := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bea Clubb');

  patron := tests.mkbottle(venue_a, 'Patron', 10);
  goose := tests.mkbottle(venue_a, 'Grey Goose', null);
  hen := tests.mkbottle(venue_a, 'Hennessy', 2);
  zero := tests.mkbottle(venue_a, 'Zero Gin', 0);
  rum := tests.mkbottle(venue_a, 'Rum Runner', 20);
  vodka_b := tests.mkbottle(venue_b, 'Other Club Vodka', 7);
  insert into public.site_stock_thresholds (bottle_id, venue_id, low_threshold, set_by) values (patron, venue_a, 5, owner_u), (hen, venue_a, 3, owner_u), (zero, venue_a, 0, owner_u);

  -- Patron: 3 delivered in full + 2 of which 1 is delivered + 1 due at the club + 2 ordered 40 days ago (not handed over)    -> sold 8, handed over 4, reserved 4
  perform tests.mkline(b_ada, patron, 3, 'paid', true);
  perform tests.mkline(b_zed, patron, 2, 'paid', false, 1);
  perform tests.mkline(b_ada, patron, 1, 'due_at_venue');
  perform tests.mkline(b_zed, patron, 2, 'paid', false, 0, false, interval '40 days');
  -- Patron, NOT sold: still being paid online, on a booking that is not confirmed, on a cancelled booking, and a cancelled line
  perform tests.mkline(b_ada, patron, 5, 'pending_payment');
  perform tests.mkline(b_pend, patron, 4, 'paid');
  perform tests.mkline(b_gone, patron, 7, 'paid');
  perform tests.mkline(b_zed, patron, 2, 'paid', false, 0, true);
  -- the others
  perform tests.mkline(b_ada, goose, 2);
  perform tests.mkline(b_ada, hen, 5);
  perform tests.mkline(b_bea, vodka_b, 3);

  ---------------------------------------------------------------- the figures
  perform tests.assert_eq('every bottle of the club, with on hand / reserved / handed over / available / sold (last 30 days)',
    tests.ov(mgr_a, 'mgra@so.example', venue_a),
    'Grey Goose -/2/0/-/2 | Hennessy 2/5/0/0/5 LOW | Patron 10/4/4/2/6 | Rum Runner 20/0/0/20/0 | Zero Gin 0/0/0/0/0 LOW');
  perform tests.assert_eq('the business''s owner reads the same', tests.ov(owner_u, 'owner@so.example', venue_a),
    'Grey Goose -/2/0/-/2 | Hennessy 2/5/0/0/5 LOW | Patron 10/4/4/2/6 | Rum Runner 20/0/0/20/0 | Zero Gin 0/0/0/0/0 LOW');
  perform tests.assert_eq('the other club shows only its own bottle', tests.ov(mgr_b, 'mgrb@so.example', venue_b), 'Other Club Vodka 7/3/0/4/3');
  perform tests.login(mgr_a, 'mgra@so.example');
  perform tests.assert_eq('reserved plus handed over is everything sold (Patron: 4 + 4 of 8, the 40-day-old line included)',
    (select o.reserved + o.handed_over from public.stock_overview(venue_a, now() - interval '60 days') o where o.bottle_id = patron), 8);
  perform tests.logout();

  perform tests.assert_eq('a bottle nobody counted has no on hand and no available figure, but its sales still show', tests.ov(mgr_a, 'mgra@so.example', venue_a) like '%Grey Goose -/2/0/-/2 |%', true);
  perform tests.assert_eq('a bottle below its low level is marked, and so is one exactly at its level (Zero Gin: 0 on hand, low at 0)',
    tests.ov(mgr_a, 'mgra@so.example', venue_a) like '%Hennessy 2/5/0/0/5 LOW |%' and tests.ov(mgr_a, 'mgra@so.example', venue_a) like '%Zero Gin 0/0/0/0/0 LOW', true);
  perform tests.assert_eq('a bottle above its level is not (Patron: 10 on hand, low at 5), nor one with no level (Rum Runner)',
    tests.ov(mgr_a, 'mgra@so.example', venue_a) like '%Patron 10/4/4/2/6 | Rum Runner 20/0/0/20/0 |%', true);
  perform tests.assert_eq('available never goes below zero (Hennessy: 5 sold of 2 on hand)', tests.ov(mgr_a, 'mgra@so.example', venue_a) like '%Hennessy 2/5/0/0/5 %', true);

  -- A line that says more were delivered than were ordered (bad data) never makes handed over exceed what was sold. Undone again straight after.
  begin
    perform tests.mkline(b_ada, rum, 2, 'paid', false, 5);
    perform tests.assert_eq('handed over is capped at what was ordered', tests.ov(mgr_a, 'mgra@so.example', venue_a) like '%Rum Runner 20/0/2/18/2 |%', true);
    raise exception 'undo the extra line';
  exception when others then
    if sqlerrm <> 'undo the extra line' then raise; end if;
  end;
  perform tests.logout();

  ---------------------------------------------------------------- the period only moves "sold"
  perform tests.assert_eq('a longer period adds the old line to Patron''s "sold" and nothing else',
    tests.ov(mgr_a, 'mgra@so.example', venue_a, now() - interval '60 days'),
    'Grey Goose -/2/0/-/2 | Hennessy 2/5/0/0/5 LOW | Patron 10/4/4/2/8 | Rum Runner 20/0/0/20/0 | Zero Gin 0/0/0/0/0 LOW');
  perform tests.assert_eq('a window around the old line only', tests.ov(mgr_a, 'mgra@so.example', venue_a, now() - interval '45 days', now() - interval '35 days'),
    'Grey Goose -/2/0/-/0 | Hennessy 2/5/0/0/0 LOW | Patron 10/4/4/2/2 | Rum Runner 20/0/0/20/0 | Zero Gin 0/0/0/0/0 LOW');
  perform tests.assert_eq('a window before anything was sold: nothing sold, the stock figures unchanged', tests.ov(mgr_a, 'mgra@so.example', venue_a, now() - interval '2 days', now() - interval '1 day'),
    'Grey Goose -/2/0/-/0 | Hennessy 2/5/0/0/0 LOW | Patron 10/4/4/2/0 | Rum Runner 20/0/0/20/0 | Zero Gin 0/0/0/0/0 LOW');
  perform tests.assert_eq('a period that ends before it starts is refused', tests.ov(mgr_a, 'mgra@so.example', venue_a, now(), now() - interval '1 day'), 'ERROR: the period has to end after it starts');
  perform tests.assert_eq('...and so is one of no length', tests.ov(mgr_a, 'mgra@so.example', venue_a, now() - interval '1 day', now() - interval '1 day'), 'ERROR: the period has to end after it starts');
  perform tests.assert_eq('a period longer than a year is refused', tests.ov(mgr_a, 'mgra@so.example', venue_a, now() - interval '400 days'), 'ERROR: choose a period of a year or less');
  perform tests.assert_eq('a year exactly is fine', tests.ov(mgr_a, 'mgra@so.example', venue_a, now() - interval '366 days') like 'Grey Goose%', true);

  ---------------------------------------------------------------- the live menu says the same, except for a cancelled line
  perform tests.login(mgr_a, 'mgra@so.example');
  perform tests.assert_eq('the menu''s "left" and the overview''s "available" agree where nothing was cancelled (Hennessy, Grey Goose, Rum Runner, Zero Gin)',
    (select string_agg(m.name || ':' || coalesce(m.left_count::text, '-'), ',' order by m.name) from public.desk_bottle_menu(b_ada) m where m.name <> 'Patron'),
    'Grey Goose:-,Hennessy:0,Rum Runner:20,Zero Gin:0');
  perform tests.assert_eq('...and a cancelled line releases its reservation here but not in the menu (Patron: 2 here, 0 there; see the header)',
    (select m.left_count from public.desk_bottle_menu(b_ada) m where m.name = 'Patron'), 0);
  perform tests.logout();

  ---------------------------------------------------------------- who may read it
  perform tests.assert_eq('a server may not', tests.ov(srv_1, 'srv1@so.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('door staff may not', tests.ov(door_a, 'doora@so.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier may not', tests.ov(ver_a, 'vera@so.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('the manager of another club may not', tests.ov(mgr_b, 'mgrb@so.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('a rival business may not', tests.ov(rival_u, 'rival@so2.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('no club at all is not allowed either', tests.ov(mgr_a, 'mgra@so.example', null), 'ERROR: not allowed');
  perform tests.assert_eq('a club that does not exist looks the same as one that is not yours', tests.ov(mgr_a, 'mgra@so.example', gen_random_uuid()), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor is refused outright', format($q$select * from public.stock_overview(%L)$q$, venue_a), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('a call with no signed-in person (the service role) is told to sign in', format($q$select * from public.stock_overview(%L)$q$, venue_a), 'not authenticated');
  perform tests.logout();

  ---------------------------------------------------------------- reading it changes nothing
  before_snap := tests.snapshot();
  perform tests.ov(mgr_a, 'mgra@so.example', venue_a);
  perform tests.ov(owner_u, 'owner@so.example', venue_a, now() - interval '90 days');
  perform tests.ov(srv_1, 'srv1@so.example', venue_a);
  perform tests.logout();
  perform tests.assert_eq('no stock, bottle line or movement changed', tests.snapshot(), before_snap);

  ---------------------------------------------------------------- the function itself
  perform tests.assert_true('it runs with its owner''s rights and a fixed search path',
    (select p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%' from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'stock_overview'));
  perform tests.assert_true('visitors cannot run it, signed-in people and the service role can (the function itself decides)',
    not has_function_privilege('anon', 'public.stock_overview(uuid, timestamptz, timestamptz)', 'execute')
    and has_function_privilege('authenticated', 'public.stock_overview(uuid, timestamptz, timestamptz)', 'execute')
    and has_function_privilege('service_role', 'public.stock_overview(uuid, timestamptz, timestamptz)', 'execute'));
end $$;

rollback;
