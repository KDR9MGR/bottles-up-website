-- Partial delivery of a bottle order (20261020160000_partial_delivery.sql). What matters: only the club's manager or owner and the server of THAT table can hand over
-- part of an order; the call carries the count the caller saw, so a repeated tap or a retry after a lost answer is refused and nothing is delivered twice; the last
-- bottles make the line Delivered and nothing can be added after; nothing is handed over before it is ready, cancelled, unpaid online or on a table that is closed out;
-- an item to be paid at the club is not handed over (not even in part) until the table is paid; every hand-over is attributed.
begin;

create function tests.part(p_user uuid, p_email text, p_line uuid, p_qty int, p_already int) returns text language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  r := public.desk_deliver_part(p_line, p_qty, p_already);
  return (r ->> 'delivered') || '/' || (r ->> 'quantity') || ' ' || (r ->> 'service_status');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.line_state(p_id uuid) returns text language sql security definer as $$
  select delivered_quantity || '/' || quantity || ' ' || service_status from public.site_table_booking_bottles where id = p_id $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int default 1000, p_paid int default 1000, p_status text default 'paid') returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, p_total, p_paid, p_status, upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkline(p_booking uuid, p_name text, p_qty int, p_pay text default 'paid', p_svc text default 'ready') returns uuid language sql security definer as $$
  insert into public.site_table_booking_bottles (booking_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, payment_status, service_status)
  values (p_booking, p_name, '750ml', 1000, p_qty, 1000 * p_qty, p_pay, p_svc) returning id $$;
create function tests.audit_count(p_prefix text, p_entity uuid) returns int language sql security definer as $$
  select count(*)::int from public.audit_log where action like p_prefix || '%' and entity_id = p_entity::text $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000f1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000000f2';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000f3';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000f4';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000000f5';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000000f6';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000000f7';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000000f8';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; tok text; r record; n int;
  type_a uuid; type_b uuid; slot_eve uuid; slot_b uuid; m_s1 uuid;
  b_ada uuid; b_zed uuid; b_pend uuid; b_closed uuid; b_bea uuid; b_due uuid;
  l_main uuid; l_more uuid; l_prep uuid; l_new uuid; l_served uuid; l_canc uuid; l_pend uuid; l_closed uuid; l_pendbk uuid; l_other uuid; l_zed uuid; l_due uuid; l_one uuid;
  night date := current_date + 10;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@pd.example'), (mgr_a, 'mgra@pd.example'), (rival_u, 'rival@pd2.example'), (door_a, 'doora@pd.example'),
    (mgr_b, 'mgrb@pd.example'), (srv_1, 'srv1@pd.example'), (srv_2, 'srv2@pd.example'), (ver_a, 'vera@pd.example'), (rando, 'rando@test.example')
    on conflict do nothing;

  perform tests.login(owner_u, 'owner@pd.example');
  org := public.create_organization('Delivery Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@pd2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  perform public.create_org_venue(org2, 'Rival Club');

  perform tests.login(owner_u, 'owner@pd.example');
  select i.token into tok from public.invite_member(org, 'mgra@pd.example', 'manager', venue_a) i;
  perform tests.login(mgr_a, 'mgra@pd.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@pd.example');
  select i.token into tok from public.invite_member(org, 'mgrb@pd.example', 'manager', venue_b) i;
  perform tests.login(mgr_b, 'mgrb@pd.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@pd.example');
  select i.token into tok from public.invite_member(org, 'srv1@pd.example', 'server', venue_a) i;
  perform tests.login(srv_1, 'srv1@pd.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@pd.example');
  select i.token into tok from public.invite_member(org, 'srv2@pd.example', 'server', venue_a) i;
  perform tests.login(srv_2, 'srv2@pd.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@pd.example');
  select i.token into tok from public.invite_member(org, 'doora@pd.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@pd.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@pd.example');
  select i.token into tok from public.invite_member(org, 'vera@pd.example', 'verifier', venue_a) i;
  perform tests.login(ver_a, 'vera@pd.example'); perform public.accept_invitation(tok);

  perform tests.logout();
  select id into m_s1 from public.site_memberships where user_id = srv_1 and role = 'server';
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 9) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 5) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;

  b_ada := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Ada Evening');
  b_zed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Zed Evening');
  b_pend := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Pending Pat', 1000, 0, 'pending');
  b_closed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Closed Cleo');
  b_bea := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bea Clubb');
  b_due := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Due Dora', 8000, 2000);
  update public.site_table_bookings set reconciled_at = now() where id = b_closed;
  perform tests.login(mgr_a, 'mgra@pd.example');
  perform public.assign_booking_server(b_ada, m_s1);
  perform public.assign_booking_server(b_due, m_s1);
  perform tests.logout();

  l_main := tests.mkline(b_ada, 'Patron', 5);
  l_more := tests.mkline(b_ada, 'Hennessy', 4, 'paid', 'picked_up');
  l_prep := tests.mkline(b_ada, 'Don Julio', 3, 'paid', 'preparing');
  l_new := tests.mkline(b_ada, 'Moet', 3, 'paid', 'awaiting_prep');
  l_served := tests.mkline(b_ada, 'Belvedere', 2, 'paid', 'served');
  l_canc := tests.mkline(b_ada, 'Cancelled Gin', 2);
  update public.site_table_booking_bottles set cancelled_at = now(), cancellation_reason = 'guest changed their mind' where id = l_canc;
  l_pend := tests.mkline(b_ada, 'Online Rum', 2, 'pending_payment');
  l_one := tests.mkline(b_ada, 'Single Malt', 1);
  l_closed := tests.mkline(b_closed, 'Jameson', 2);
  l_pendbk := tests.mkline(b_pend, 'Smirnoff', 2);
  l_other := tests.mkline(b_bea, 'Casamigos', 4);
  l_zed := tests.mkline(b_zed, 'Zed Whisky', 4);
  l_due := tests.mkline(b_due, 'Grey Goose', 3, 'due_at_venue', 'ready');

  perform tests.assert_eq('every existing line starts with nothing delivered', (select count(*) from public.site_table_booking_bottles where delivered_quantity <> 0)::int, 0);

  ---------------------------------------------------------------- who may
  perform tests.assert_eq('the server of the table hands over part of a ready line: it stays On the way', tests.part(srv_1, 'srv1@pd.example', l_main, 2, 0), '2/5 picked_up');
  perform tests.assert_eq('...and the line says so', tests.line_state(l_main), '2/5 picked_up');
  perform tests.assert_eq('the manager hands over more (they said 2 were delivered, and 2 were)', tests.part(mgr_a, 'mgra@pd.example', l_main, 1, 2), '3/5 picked_up');
  perform tests.assert_eq('the owner may too', tests.part(owner_u, 'owner@pd.example', l_main, 1, 3), '4/5 picked_up');
  perform tests.assert_eq('another server of the club may not (not their table)', tests.part(srv_2, 'srv2@pd.example', l_more, 1, 0), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier may not', tests.part(ver_a, 'vera@pd.example', l_more, 1, 0), 'ERROR: not allowed');
  perform tests.assert_eq('door staff may not', tests.part(door_a, 'doora@pd.example', l_more, 1, 0), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager may not', tests.part(mgr_b, 'mgrb@pd.example', l_more, 1, 0), 'ERROR: not allowed');
  perform tests.assert_eq('a rival business may not', tests.part(rival_u, 'rival@pd2.example', l_more, 1, 0), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger may not', tests.part(rando, 'rando@test.example', l_more, 1, 0), 'ERROR: not allowed');
  perform tests.assert_eq('a line that does not exist looks the same', tests.part(mgr_a, 'mgra@pd.example', gen_random_uuid(), 1, 0), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot reach a table that is nobody''s', tests.part(srv_1, 'srv1@pd.example', l_zed, 1, 0), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor is refused outright', format($q$select public.desk_deliver_part(%L, 1, 0)$q$, l_more), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('a call with no signed-in person is told to sign in', format($q$select public.desk_deliver_part(%L, 1, 0)$q$, l_more), 'not authenticated');
  perform tests.logout();
  perform tests.assert_eq('none of the refusals changed anything', tests.line_state(l_more), '0/4 picked_up');

  ---------------------------------------------------------------- repeated and stale calls
  perform tests.assert_eq('a repeated tap (the same call again) is refused: nothing is delivered twice', tests.part(srv_1, 'srv1@pd.example', l_main, 1, 3), 'ERROR: someone else has just changed this item, look at it again');
  perform tests.assert_eq('a call that thinks nothing was delivered yet, when something was, is refused', tests.part(srv_1, 'srv1@pd.example', l_main, 1, 0), 'ERROR: someone else has just changed this item, look at it again');
  perform tests.assert_eq('a call that thinks more was delivered than was is refused too', tests.part(srv_1, 'srv1@pd.example', l_main, 1, 9), 'ERROR: someone else has just changed this item, look at it again');
  perform tests.assert_eq('a call that does not say what was delivered so far is refused', tests.part(srv_1, 'srv1@pd.example', l_main, 1, null), 'ERROR: someone else has just changed this item, look at it again');
  perform tests.assert_eq('...none of it changed the count', tests.line_state(l_main), '4/5 picked_up');

  ---------------------------------------------------------------- how many
  perform tests.assert_eq('asking for more than is left names how many are left', tests.part(srv_1, 'srv1@pd.example', l_main, 2, 4), 'ERROR: only 1 of this item are left to deliver');
  perform tests.assert_eq('nothing is not a delivery', tests.part(srv_1, 'srv1@pd.example', l_more, 0, 0), 'ERROR: choose how many were delivered');
  perform tests.assert_eq('...nor a negative number', tests.part(srv_1, 'srv1@pd.example', l_more, -1, 0), 'ERROR: choose how many were delivered');
  perform tests.assert_eq('...nor no number', tests.part(srv_1, 'srv1@pd.example', l_more, null, 0), 'ERROR: choose how many were delivered');
  perform tests.assert_eq('the last bottles make the line Delivered', tests.part(srv_1, 'srv1@pd.example', l_main, 1, 4), '5/5 served');
  perform tests.assert_eq('a delivered line takes nothing more', tests.part(srv_1, 'srv1@pd.example', l_main, 1, 5), 'ERROR: this item has already been delivered');
  perform tests.assert_eq('...nor one that was marked delivered by hand', tests.part(mgr_a, 'mgra@pd.example', l_served, 1, 0), 'ERROR: this item has already been delivered');
  perform tests.assert_eq('a line of one is delivered whole', tests.part(srv_1, 'srv1@pd.example', l_one, 1, 0), '1/1 served');
  perform tests.assert_eq('a line On the way can be delivered all at once', tests.part(srv_1, 'srv1@pd.example', l_more, 4, 0), '4/4 served');

  ---------------------------------------------------------------- when
  perform tests.assert_eq('nothing is handed over while it is being prepared', tests.part(srv_1, 'srv1@pd.example', l_prep, 1, 0), 'ERROR: this item is not ready to be delivered yet');
  perform tests.assert_eq('...or not yet started', tests.part(srv_1, 'srv1@pd.example', l_new, 1, 0), 'ERROR: this item is not ready to be delivered yet');
  perform tests.assert_eq('a cancelled line cannot be delivered', tests.part(srv_1, 'srv1@pd.example', l_canc, 1, 0), 'ERROR: this item was cancelled');
  perform tests.assert_eq('a line still being paid online cannot', tests.part(srv_1, 'srv1@pd.example', l_pend, 1, 0), 'ERROR: payment not yet verified for this item');
  perform tests.assert_eq('a table that was closed out cannot', tests.part(mgr_a, 'mgra@pd.example', l_closed, 1, 0), 'ERROR: this table has already been closed out');
  perform tests.assert_eq('a booking that is not confirmed has nothing to deliver', tests.part(mgr_a, 'mgra@pd.example', l_pendbk, 1, 0), 'ERROR: only a paid booking has orders to serve');

  ---------------------------------------------------------------- an item to be paid at the club
  perform tests.assert_eq('it is not handed over, even in part, while the table has a balance', tests.part(srv_1, 'srv1@pd.example', l_due, 1, 0), 'ERROR: cannot mark delivered - this table still has a balance due at the venue');
  perform tests.logout();
  update public.site_table_bookings set amount_paid_cents = amount_total_cents where id = b_due;
  perform tests.assert_eq('...nor with the balance gone but no payment on record', tests.part(srv_1, 'srv1@pd.example', l_due, 1, 0), 'ERROR: cannot mark delivered - no payment has been recorded for this table');
  perform tests.logout();
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, missing_receipt_reason) values (b_due, 8000, 8000, 'cash', 'printer broken');
  perform tests.assert_eq('...it can once the table is paid and a payment is on record', tests.part(srv_1, 'srv1@pd.example', l_due, 2, 0), '2/3 picked_up');
  perform tests.assert_eq('...and the rest the same way', tests.part(srv_1, 'srv1@pd.example', l_due, 1, 2), '3/3 served');

  ---------------------------------------------------------------- the record
  perform tests.logout();
  select * into r from public.audit_log where action = 'table_booking.bottle_delivered_part' and entity_id = l_main::text and (details ->> 'delivered_total')::int = 2;
  perform tests.assert_eq('a hand-over is recorded with who did it and what it was', (r.details ->> 'delivered_now') || ' now, ' || (r.details ->> 'delivered_total') || ' of ' || (r.details ->> 'of') || ', ' || (r.details ->> 'old_status') || ' to ' || (r.details ->> 'new_status'), '2 now, 2 of 5, ready to picked_up');
  perform tests.assert_eq('...by the server', r.actor_id, srv_1);
  select * into r from public.audit_log where action = 'table_booking.bottle_delivered_part' and entity_id = l_main::text and (details ->> 'delivered_total')::int = 3;
  perform tests.assert_eq('the next hand-over records only what it added, with the new total', (r.details ->> 'delivered_now') || ' now, ' || (r.details ->> 'delivered_total') || ' of ' || (r.details ->> 'of') || ', ' || (r.details ->> 'old_status') || ' to ' || (r.details ->> 'new_status'), '1 now, 3 of 5, picked_up to picked_up');
  perform tests.assert_eq('...by the manager', r.actor_id, mgr_a);
  perform tests.assert_eq('each real hand-over left exactly one entry, refusals none', tests.audit_count('table_booking.bottle_delivered_part', l_main), 4);

  ---------------------------------------------------------------- reading the counts
  perform tests.login(mgr_a, 'mgra@pd.example');
  perform tests.assert_eq('the manager reads the delivered count of every line of a booking, not those still being paid online',
    (select count(*) from public.desk_booking_deliveries(b_ada))::int, 7);
  perform tests.assert_eq('...with the right counts', (select d.delivered_quantity from public.desk_booking_deliveries(b_ada) d where d.line_id = l_main), 5);
  perform tests.assert_eq('...a line nothing was delivered of shows 0', (select d.delivered_quantity from public.desk_booking_deliveries(b_ada) d where d.line_id = l_prep), 0);
  perform tests.assert_eq('...and a cancelled line is still listed (the order sheet shows it with its reason)', (select count(*) from public.desk_booking_deliveries(b_ada) d where d.line_id = l_canc)::int, 1);
  perform tests.assert_eq('...but a line still being paid online is not', (select count(*) from public.desk_booking_deliveries(b_ada) d where d.line_id = l_pend)::int, 0);
  perform tests.login(srv_1, 'srv1@pd.example');
  perform tests.assert_eq('the server of the table reads them', (select count(*) from public.desk_booking_deliveries(b_ada))::int, 7);
  perform tests.login(srv_2, 'srv2@pd.example');
  perform tests.assert_raises('another server of the club cannot', format($q$select * from public.desk_booking_deliveries(%L)$q$, b_ada), 'not allowed');
  perform tests.login(ver_a, 'vera@pd.example');
  perform tests.assert_raises('...a verifier', format($q$select * from public.desk_booking_deliveries(%L)$q$, b_ada), 'not allowed');
  perform tests.login(rival_u, 'rival@pd2.example');
  perform tests.assert_raises('...a rival', format($q$select * from public.desk_booking_deliveries(%L)$q$, b_ada), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('...a visitor', format($q$select * from public.desk_booking_deliveries(%L)$q$, b_ada), 'permission denied');

  ---------------------------------------------------------------- the existing way of moving a line is unchanged
  perform tests.login(mgr_a, 'mgra@pd.example');
  perform tests.assert_true('a manager can still mark a line Delivered by hand', public.desk_set_service_status(l_prep, 'served') is not null);
  perform tests.assert_eq('...and a line done that way shows Delivered with nothing counted, which the app reads as all of it', tests.line_state(l_prep), '0/3 served');

  ---------------------------------------------------------------- hygiene
  perform tests.logout();
  perform tests.login(owner_u, 'owner@pd.example');
  update public.site_table_booking_bottles set delivered_quantity = 0 where id = l_main;
  get diagnostics n = row_count;
  perform tests.assert_eq('writing a line directly changes nothing (row level security)', n, 0);
  perform tests.logout();
  perform tests.assert_true('the count cannot be negative', (select count(*) from pg_constraint c where c.conrelid = 'public.site_table_booking_bottles'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) like '%delivered_quantity >= 0%') = 1);
  perform tests.assert_true('both functions run with their owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('desk_deliver_part', 'desk_booking_deliveries')));
  perform tests.assert_true('visitors cannot run either',
    not has_function_privilege('anon', 'public.desk_deliver_part(uuid,int,int)', 'execute') and not has_function_privilege('anon', 'public.desk_booking_deliveries(uuid)', 'execute'));
end $$;

rollback;
