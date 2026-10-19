-- Adding bottles to a table (20261020150000_add_bottles_checks.sql). The money is done by the edge function add-table-booking-bottles; what matters here is WHO may add
-- (the club's manager or owner, or the server the table was given to, and nobody else), WHEN (a confirmed table that is not closed out, on a night that is not closed),
-- that every refusal is a plain sentence, and that the menu a person sees is only this club's available bottles with the right number left.
begin;

create function tests.may_add(p_user uuid, p_email text, p_booking uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return case when public.desk_may_add_bottles(p_booking) then 'yes' else 'no' end;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.menu_names(p_user uuid, p_email text, p_booking uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return array_to_string(array(select m.name from public.desk_bottle_menu(p_booking) m), ',');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_status text default 'paid') returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, 1000, 0, p_status, upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkbottle(p_venue uuid, p_name text, p_price int, p_stock int default null, p_available boolean default true, p_sold_out boolean default false, p_sort int default 0) returns uuid language sql security definer as $$
  insert into public.site_bottles (venue_id, name, size, category, price_cents, stock_quantity, is_available, is_sold_out, sort_order)
  values (p_venue, p_name, '750ml', 'Spirits', p_price, p_stock, p_available, p_sold_out, p_sort) returning id $$;
create function tests.mkline(p_booking uuid, p_bottle uuid, p_qty int, p_pay text) returns uuid language sql security definer as $$
  insert into public.site_table_booking_bottles (booking_id, bottle_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, payment_status)
  values (p_booking, p_bottle, 'x', '750ml', 1000, p_qty, 1000 * p_qty, p_pay) returning id $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000e1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000000e2';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000e3';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000e4';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000000e5';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000000e6';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000000e7';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000000e8';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; tok text;
  type_a uuid; type_b uuid; slot_eve uuid; slot_late uuid; slot_b uuid; m_s1 uuid;
  b_ada uuid; b_zed uuid; b_pend uuid; b_gone uuid; b_closed uuid; b_late uuid; b_bea uuid;
  patron uuid; goose uuid; rum uuid; gin uuid; hen uuid; vodka_b uuid; zero uuid;
  night date := current_date + 10;
  r record;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@ab.example'), (mgr_a, 'mgra@ab.example'), (rival_u, 'rival@ab2.example'), (door_a, 'doora@ab.example'),
    (mgr_b, 'mgrb@ab.example'), (srv_1, 'srv1@ab.example'), (srv_2, 'srv2@ab.example'), (ver_a, 'vera@ab.example'), (rando, 'rando@test.example')
    on conflict do nothing;

  perform tests.login(owner_u, 'owner@ab.example');
  org := public.create_organization('Bottle Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@ab2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  perform public.create_org_venue(org2, 'Rival Club');

  perform tests.login(owner_u, 'owner@ab.example');
  select i.token into tok from public.invite_member(org, 'mgra@ab.example', 'manager', venue_a) i;
  perform tests.login(mgr_a, 'mgra@ab.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@ab.example');
  select i.token into tok from public.invite_member(org, 'mgrb@ab.example', 'manager', venue_b) i;
  perform tests.login(mgr_b, 'mgrb@ab.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@ab.example');
  select i.token into tok from public.invite_member(org, 'srv1@ab.example', 'server', venue_a) i;
  perform tests.login(srv_1, 'srv1@ab.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@ab.example');
  select i.token into tok from public.invite_member(org, 'srv2@ab.example', 'server', venue_a) i;
  perform tests.login(srv_2, 'srv2@ab.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@ab.example');
  select i.token into tok from public.invite_member(org, 'doora@ab.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@ab.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@ab.example');
  select i.token into tok from public.invite_member(org, 'vera@ab.example', 'verifier', venue_a) i;
  perform tests.login(ver_a, 'vera@ab.example'); perform public.accept_invitation(tok);

  perform tests.logout();
  select id into m_s1 from public.site_memberships where user_id = srv_1 and role = 'server';
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 5) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 5) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 0, '01:00', 'After midnight') returning id into slot_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;

  b_ada := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Ada Evening');
  b_zed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Zed Evening');
  b_pend := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Pending Pat', 'pending');
  b_gone := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Gone Gil', 'cancelled');
  b_closed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Closed Cleo');
  b_late := tests.mkbooking(venue_a, type_a, slot_late, night + 1, 'Late Lena');
  b_bea := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bea Clubb');
  update public.site_table_bookings set reconciled_at = now() where id = b_closed;
  perform tests.login(mgr_a, 'mgra@ab.example');
  perform public.assign_booking_server(b_ada, m_s1);
  perform tests.logout();

  ---------------------------------------------------------------- who may add bottles
  perform tests.assert_eq('the club''s manager may', tests.may_add(mgr_a, 'mgra@ab.example', b_ada), 'yes');
  perform tests.assert_eq('the business''s owner may', tests.may_add(owner_u, 'owner@ab.example', b_ada), 'yes');
  perform tests.assert_eq('the server the table was given to may', tests.may_add(srv_1, 'srv1@ab.example', b_ada), 'yes');
  perform tests.assert_eq('a manager may on a table nobody was given to', tests.may_add(mgr_a, 'mgra@ab.example', b_zed), 'yes');
  perform tests.assert_eq('another server of the same club may not (it is not their table)', tests.may_add(srv_2, 'srv2@ab.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('...nor on a table nobody was given to', tests.may_add(srv_1, 'srv1@ab.example', b_zed), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier may not', tests.may_add(ver_a, 'vera@ab.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('door staff may not', tests.may_add(door_a, 'doora@ab.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('the manager of another club of the same business may not', tests.may_add(mgr_b, 'mgrb@ab.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('a rival business may not', tests.may_add(rival_u, 'rival@ab2.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger may not', tests.may_add(rando, 'rando@test.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('a booking that does not exist looks the same as one that is not yours', tests.may_add(mgr_a, 'mgra@ab.example', gen_random_uuid()), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor is refused outright', format($q$select public.desk_may_add_bottles(%L)$q$, b_ada), 'permission denied');
  perform tests.assert_raises('...also for the menu', format($q$select * from public.desk_bottle_menu(%L)$q$, b_ada), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('a call with no signed-in person (the service role) is told to sign in', format($q$select public.desk_may_add_bottles(%L)$q$, b_ada), 'not authenticated');
  perform tests.logout();

  ---------------------------------------------------------------- when
  perform tests.assert_eq('a pending booking cannot have bottles added', tests.may_add(mgr_a, 'mgra@ab.example', b_pend), 'ERROR: only a confirmed booking can have bottles added');
  perform tests.assert_eq('...nor a cancelled one', tests.may_add(mgr_a, 'mgra@ab.example', b_gone), 'ERROR: only a confirmed booking can have bottles added');
  perform tests.assert_eq('a table that was closed out cannot', tests.may_add(mgr_a, 'mgra@ab.example', b_closed), 'ERROR: this table has already been closed out');
  perform tests.assert_eq('a booking after midnight is on the night before: that night is open', tests.may_add(mgr_a, 'mgra@ab.example', b_late), 'yes');
  perform tests.logout();
  insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, report) values (venue_a, night, 'closed', mgr_a, now(), '{}'::jsonb);
  perform tests.assert_eq('once the night is closed no bottles can be added to its tables', tests.may_add(mgr_a, 'mgra@ab.example', b_ada), 'ERROR: this night has been closed, so no bottles can be added');
  perform tests.assert_eq('...also for the server', tests.may_add(srv_1, 'srv1@ab.example', b_ada), 'ERROR: this night has been closed, so no bottles can be added');
  perform tests.assert_eq('...the after-midnight booking belongs to that night too (its night is the one before the calendar day)', tests.may_add(mgr_a, 'mgra@ab.example', b_late), 'ERROR: this night has been closed, so no bottles can be added');
  perform tests.assert_eq('...another club''s table the same night is not affected', tests.may_add(mgr_b, 'mgrb@ab.example', b_bea), 'yes');
  perform tests.logout();
  update public.site_night_closes set status = 'reopened', reopened_by = owner_u, reopened_at = now() where venue_id = venue_a and business_night = night;
  perform tests.assert_eq('a reopened night takes bottles again', tests.may_add(mgr_a, 'mgra@ab.example', b_ada), 'yes');

  ---------------------------------------------------------------- the menu
  perform tests.logout();
  patron := tests.mkbottle(venue_a, 'Patron', 25000, 10, true, false, 2);
  goose := tests.mkbottle(venue_a, 'Grey Goose', 18000, null, true, false, 1);
  rum := tests.mkbottle(venue_a, 'Sold Out Rum', 9000, 5, true, true, 0);
  gin := tests.mkbottle(venue_a, 'Hidden Gin', 7000, null, false, false, 0);
  hen := tests.mkbottle(venue_a, 'Hennessy', 30000, 2, true, false, 3);
  zero := tests.mkbottle(venue_a, 'Aardvark Absinthe', 12000, null, true, false, 3);
  vodka_b := tests.mkbottle(venue_b, 'Other Club Vodka', 5000, null, true, false, 0);
  -- committed lines: Patron 3 paid + 2 due at the club on confirmed bookings count; 5 still being paid online and 4 on a cancelled booking do not; Hennessy is over-committed
  perform tests.mkline(b_ada, patron, 3, 'paid');
  perform tests.mkline(b_zed, patron, 2, 'due_at_venue');
  perform tests.mkline(b_ada, patron, 5, 'pending_payment');
  perform tests.mkline(b_gone, patron, 4, 'paid');
  perform tests.mkline(b_zed, hen, 3, 'paid');

  perform tests.assert_eq('the menu is this club''s bottles that are on sale, in the club''s order (sort order, then name), nothing sold out, hidden or from another club',
    tests.menu_names(mgr_a, 'mgra@ab.example', b_ada), 'Grey Goose,Patron,Aardvark Absinthe,Hennessy');
  perform tests.login(mgr_a, 'mgra@ab.example');
  select * into r from public.desk_bottle_menu(b_ada) m where m.bottle_id = patron;
  perform tests.assert_eq('a bottle carries its name, size, category and price', r.name || '|' || r.size || '|' || r.category || '|' || r.price_cents, 'Patron|750ml|Spirits|25000');
  perform tests.assert_eq('stock left counts what is on confirmed bookings, paid or due at the club (3 + 2 of 10)', r.left_count, 5);
  perform tests.assert_eq('...not what is still being paid online, nor what is on a cancelled booking', (select count(*) from public.desk_bottle_menu(b_ada) m where m.bottle_id = patron and m.left_count = 5)::int, 1);
  perform tests.assert_eq('stock left never goes below zero', (select m.left_count from public.desk_bottle_menu(b_ada) m where m.bottle_id = hen), 0);
  perform tests.assert_eq('a bottle the club does not count has no number', (select m.left_count from public.desk_bottle_menu(b_ada) m where m.bottle_id = goose), null::int);
  perform tests.assert_eq('the other club''s menu is its own', tests.menu_names(mgr_b, 'mgrb@ab.example', b_bea), 'Other Club Vodka');
  perform tests.assert_eq('the server of the table can read the menu', tests.menu_names(srv_1, 'srv1@ab.example', b_ada), 'Grey Goose,Patron,Aardvark Absinthe,Hennessy');
  perform tests.assert_eq('another server cannot read the menu of a table that is not theirs', tests.menu_names(srv_2, 'srv2@ab.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier cannot read the menu', tests.menu_names(ver_a, 'vera@ab.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('a rival cannot read it through another club''s booking', tests.menu_names(rival_u, 'rival@ab2.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('no menu for a closed-out table', tests.menu_names(mgr_a, 'mgra@ab.example', b_closed), 'ERROR: this table has already been closed out');
  perform tests.assert_eq('no menu for a pending booking', tests.menu_names(mgr_a, 'mgra@ab.example', b_pend), 'ERROR: only a confirmed booking can have bottles added');
  perform tests.logout();
  update public.site_night_closes set status = 'closed', reopened_by = null, reopened_at = null where venue_id = venue_a and business_night = night;
  perform tests.assert_eq('no menu on a closed night', tests.menu_names(mgr_a, 'mgra@ab.example', b_ada), 'ERROR: this night has been closed, so no bottles can be added');

  ---------------------------------------------------------------- nothing is written, and the functions are closed to visitors
  perform tests.logout();
  perform tests.assert_eq('nothing was added to any table by any of this', (select count(*) from public.site_table_booking_bottles)::int, 5);
  perform tests.assert_true('both functions run with their owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('desk_may_add_bottles', 'desk_bottle_menu')));
  perform tests.assert_true('visitors cannot run either', not has_function_privilege('anon', 'public.desk_may_add_bottles(uuid)', 'execute') and not has_function_privilege('anon', 'public.desk_bottle_menu(uuid)', 'execute'));
  perform tests.assert_true('signed-in people can (the function itself decides)', has_function_privilege('authenticated', 'public.desk_may_add_bottles(uuid)', 'execute') and has_function_privilege('authenticated', 'public.desk_bottle_menu(uuid)', 'execute'));
end $$;

rollback;
