-- The order stage "Accepted" (20261022100000_order_accepted_stage.sql). What matters: the stage exists and nothing else about the states changed (the five old values,
-- an invalid one is still refused); only the manager, owner or the table's own server accepts an order, the website's staff function accepts it for the website's staff;
-- accepting is for a NEW order only (a stale tap on one that has moved on is refused and moves nothing backwards); the old rules still hold for an accepted order (not
-- cancelled, paid or payable, table not closed out, not handed over in part before it is ready); an accepted order counts as IN PROGRESS on Tonight and in the night's
-- report and as nothing else; every change is attributed.
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
  return case when r is null or r = '' then 'ok' else r end;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.set_status(p_user uuid, p_email text, p_line uuid, p_status text) returns text language sql as $$
  select tests.try(p_user, p_email, format($q$select public.desk_set_service_status(%L, %L)::text$q$, p_line, p_status)) $$;
create function tests.state(p_line uuid) returns text language sql security definer as $$ select service_status from public.site_table_booking_bottles where id = p_line $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int default 1000, p_paid int default 1000) returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, p_total, p_paid, 'paid', upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkline(p_booking uuid, p_name text, p_qty int, p_pay text default 'paid', p_svc text default 'awaiting_prep') returns uuid language sql security definer as $$
  insert into public.site_table_booking_bottles (booking_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, payment_status, service_status)
  values (p_booking, p_name, '750ml', 1000, p_qty, 1000 * p_qty, p_pay, p_svc) returning id $$;
create function tests.tonight_text(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  select 'new=' || orders_new || ' progress=' || orders_in_progress || ' delivered=' || orders_delivered into r from public.desk_tonight(p_venue, p_night);
  perform tests.logout();
  return r;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000009d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000009d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000009d3';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000009d4';
  door_u constant uuid := '00000000-0000-0000-0000-0000000009d5';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000009d6';
  ver_u constant uuid := '00000000-0000-0000-0000-0000000009d7';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';  -- a BottlesUp admin (cms_admins, from the fixtures)
  staff_u constant uuid := '00000000-0000-0000-0000-0000000000a1';  -- a website door staff member (door_staff, from the fixtures)
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  org uuid; venue_a uuid; venue_b uuid; t_a uuid; t_b uuid; s_a uuid; s_b uuid; m_s1 uuid;
  b_one uuid; b_two uuid; b_closed uuid; b_b uuid;
  l_new uuid; l_new2 uuid; l_prep uuid; l_ready uuid; l_served uuid; l_canc uuid; l_pend uuid; l_due uuid; l_closed uuid; l_other uuid; l_x uuid;
  night date := current_date;
  r text; j jsonb; n int;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@ac.example'), (mgr_a, 'mgra@ac.example'), (srv_1, 'srv1@ac.example'), (srv_2, 'srv2@ac.example'),
    (door_u, 'door@ac.example'), (mgr_b, 'mgrb@ac.example'), (ver_u, 'ver@ac.example') on conflict do nothing;
  perform tests.login(owner_u, 'owner@ac.example');
  org := public.create_organization('Accept Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@ac.example', org, 'mgra@ac.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@ac.example', org, 'mgrb@ac.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@ac.example', org, 'srv1@ac.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@ac.example', org, 'srv2@ac.example', 'server', venue_a, srv_2);
  perform tests.join_as(mgr_a, 'mgra@ac.example', org, 'door@ac.example', 'door', venue_a, door_u);
  perform tests.join_as(mgr_a, 'mgra@ac.example', org, 'ver@ac.example', 'verifier', venue_a, ver_u);

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 6, 0, 0, 5) returning id into t_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 5) returning id into t_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from night)::int, '21:00') returning id into s_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_b, extract(dow from night)::int, '21:00') returning id into s_b;
  b_one := tests.mkbooking(venue_a, t_a, s_a, night, 'Table One');
  b_two := tests.mkbooking(venue_a, t_a, s_a, night, 'Table Two');
  b_closed := tests.mkbooking(venue_a, t_a, s_a, night, 'Closed Table');
  b_b := tests.mkbooking(venue_b, t_b, s_b, night, 'Other Club');
  select m.id into m_s1 from public.site_memberships m where m.user_id = srv_1 and m.role = 'server';
  insert into public.site_booking_servers (booking_id, membership_id, assigned_by) values (b_one, m_s1, mgr_a);   -- Table One is srv_1's; Table Two is nobody's
  l_new := tests.mkline(b_one, 'Patron', 1);
  l_new2 := tests.mkline(b_one, 'Grey Goose', 2);
  l_prep := tests.mkline(b_one, 'Don Julio', 1, 'paid', 'preparing');
  l_ready := tests.mkline(b_one, 'Moet', 2, 'paid', 'ready');
  l_served := tests.mkline(b_one, 'Belvedere', 1, 'paid', 'served');
  l_canc := tests.mkline(b_one, 'Cancelled one', 1);
  update public.site_table_booking_bottles set cancelled_at = now() where id = l_canc;
  l_pend := tests.mkline(b_one, 'Online pending', 1, 'pending_payment');
  l_due := tests.mkline(b_two, 'Pay at club', 1, 'due_at_venue');
  l_other := tests.mkline(b_b, 'Other club bottle', 1);
  l_closed := tests.mkline(b_closed, 'Closed table bottle', 1);
  update public.site_table_bookings set reconciled_at = now() where id = b_closed;

  ---------------------------------------------------------------- the stage exists, and nothing else about the states changed
  perform tests.assert_true('the check constraint allows the six values', (select pg_get_constraintdef(oid) from pg_constraint where conname = 'site_table_booking_bottles_service_status_check')
    like '%awaiting_prep%accepted%preparing%ready%picked_up%served%');
  perform tests.assert_raises('a value that is not a stage is still refused by the table itself', format($q$update public.site_table_booking_bottles set service_status = 'shipped' where id = %L$q$, l_new), 'violates check constraint');
  update public.site_table_booking_bottles set service_status = 'accepted' where id = l_new2;
  perform tests.assert_eq('the table stores an accepted line', tests.state(l_new2), 'accepted');
  update public.site_table_booking_bottles set service_status = 'awaiting_prep' where id = l_new2;

  ---------------------------------------------------------------- who may accept
  perform tests.assert_eq('the table''s own server accepts a new order: it changed', tests.set_status(srv_1, 'srv1@ac.example', l_new, 'accepted'), 'true');
  perform tests.assert_eq('...and the line is accepted', tests.state(l_new), 'accepted');
  perform tests.assert_eq('...attributed to the server with the old and new stage', (select details ->> 'old_status' || '>' || (details ->> 'new_status') from public.audit_log where entity_id = l_new::text and action = 'table_booking.bottle_service_status_updated' and actor_id = srv_1), 'awaiting_prep>accepted');
  perform tests.assert_eq('a repeated tap changes nothing and says so', tests.set_status(srv_1, 'srv1@ac.example', l_new, 'accepted'), 'false');
  perform tests.assert_eq('...and logs nothing more', (select count(*)::int from public.audit_log where entity_id = l_new::text and action = 'table_booking.bottle_service_status_updated'), 1);
  perform tests.assert_eq('the manager accepts any order at the club', tests.set_status(mgr_a, 'mgra@ac.example', l_new2, 'accepted'), 'true');
  perform tests.assert_eq('the owner too', tests.set_status(owner_u, 'owner@ac.example', l_due, 'accepted'), 'true');
  update public.site_table_booking_bottles set service_status = 'awaiting_prep' where id in (l_new2, l_due);
  perform tests.assert_eq('a server accepts only the tables given to them', tests.set_status(srv_2, 'srv2@ac.example', l_new2, 'accepted'), 'ERROR: not allowed');
  perform tests.assert_eq('the door does not', tests.set_status(door_u, 'door@ac.example', l_new2, 'accepted'), 'ERROR: not allowed');
  perform tests.assert_eq('the payment verifier does not', tests.set_status(ver_u, 'ver@ac.example', l_new2, 'accepted'), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager does not', tests.set_status(mgr_b, 'mgrb@ac.example', l_new2, 'accepted'), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger does not', tests.set_status(rando, 'rando@test.example', l_new2, 'accepted'), 'ERROR: not allowed');
  perform tests.assert_eq('...and none of those changed anything', tests.state(l_new2), 'awaiting_prep');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select public.desk_set_service_status(%L, 'accepted')$q$, l_new2), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- accepting is for a NEW order
  perform tests.assert_eq('an order that is already preparing is not moved back to accepted by a stale tap', tests.set_status(srv_1, 'srv1@ac.example', l_prep, 'accepted'), 'ERROR: this order has already been accepted or is further along');
  perform tests.assert_eq('...nor one that is ready', tests.set_status(mgr_a, 'mgra@ac.example', l_ready, 'accepted'), 'ERROR: this order has already been accepted or is further along');
  perform tests.assert_eq('...nor one that is delivered', tests.set_status(mgr_a, 'mgra@ac.example', l_served, 'accepted'), 'ERROR: this order has already been accepted or is further along');
  perform tests.assert_eq('...and nothing moved', tests.state(l_prep) || ',' || tests.state(l_ready) || ',' || tests.state(l_served), 'preparing,ready,served');

  ---------------------------------------------------------------- the stages go on from accepted, as before
  perform tests.assert_eq('accepted > preparing', tests.set_status(srv_1, 'srv1@ac.example', l_new, 'preparing'), 'true');
  perform tests.assert_eq('preparing > ready (ready to collect)', tests.set_status(srv_1, 'srv1@ac.example', l_new, 'ready'), 'true');
  perform tests.assert_eq('ready > on the way', tests.set_status(srv_1, 'srv1@ac.example', l_new, 'picked_up'), 'true');
  perform tests.assert_eq('on the way > delivered', tests.set_status(srv_1, 'srv1@ac.example', l_new, 'served'), 'true');
  perform tests.assert_eq('a server cannot take a delivered one back (unchanged rule)', tests.set_status(srv_1, 'srv1@ac.example', l_new, 'accepted'), 'ERROR: a delivered item can only be changed by a manager');
  perform tests.assert_eq('the manager can send an accepted order back to new (unchanged)', (select tests.set_status(mgr_a, 'mgra@ac.example', l_new2, 'accepted')), 'true');
  perform tests.assert_eq('...which still works', tests.set_status(mgr_a, 'mgra@ac.example', l_new2, 'awaiting_prep'), 'true');
  perform tests.assert_eq('an invalid stage is still refused by the function', tests.set_status(mgr_a, 'mgra@ac.example', l_new2, 'shipped'), 'ERROR: invalid status');
  perform tests.assert_eq('...and a missing one', tests.set_status(mgr_a, 'mgra@ac.example', l_new2, null), 'ERROR: invalid status');

  ---------------------------------------------------------------- the old rules still hold for an accepted order
  perform tests.assert_eq('a cancelled item cannot be accepted', tests.set_status(mgr_a, 'mgra@ac.example', l_canc, 'accepted'), 'ERROR: this item was cancelled');
  perform tests.assert_eq('an item whose online payment is not verified cannot be accepted', tests.set_status(mgr_a, 'mgra@ac.example', l_pend, 'accepted'), 'ERROR: payment not yet verified for this item');
  perform tests.assert_eq('a table that is closed out takes no change', tests.set_status(mgr_a, 'mgra@ac.example', l_closed, 'accepted'), 'ERROR: this table has already been closed out');
  perform tests.assert_eq('another club''s order is "not allowed"', tests.set_status(mgr_a, 'mgra@ac.example', l_other, 'accepted'), 'ERROR: not allowed');
  update public.site_table_bookings set amount_paid_cents = 0 where id = b_two;
  perform tests.assert_eq('an accepted pay-at-club order is not delivered while the table owes money (the unchanged rule)', tests.set_status(mgr_a, 'mgra@ac.example', l_due, 'accepted') || '/' ||
    tests.try(mgr_a, 'mgra@ac.example', format($q$select public.desk_set_service_status(%L, 'served')::text$q$, l_due)), 'true/ERROR: cannot mark delivered - this table still has a balance due at the venue');
  perform tests.assert_eq('an accepted order is not handed over in part before it is ready', tests.try(srv_1, 'srv1@ac.example', format($q$select public.desk_deliver_part(%L, 1, 0)::text$q$, l_new2)), 'ERROR: this item is not ready to be delivered yet');
  perform tests.set_status(mgr_a, 'mgra@ac.example', l_new2, 'accepted');
  perform tests.assert_eq('...nor an accepted one', tests.try(mgr_a, 'mgra@ac.example', format($q$select public.desk_deliver_part(%L, 1, 0)::text$q$, l_new2)), 'ERROR: this item is not ready to be delivered yet');

  ---------------------------------------------------------------- Tonight and the night's report count an accepted order as in progress, and only that
  -- Table One: l_new delivered; l_new2 accepted; l_prep preparing; l_ready ready; l_served delivered; l_canc cancelled and l_pend still unpaid online (neither is counted on Tonight)
  -- Table Two: l_due accepted. The closed table's line is still new (the night counts every paid table of the night).
  perform tests.assert_eq('Tonight: one new order, four in progress (two accepted, one preparing, one ready), two delivered', tests.tonight_text(mgr_a, 'mgra@ac.example', venue_a, night), 'new=1 progress=4 delivered=2');
  update public.site_table_booking_bottles set service_status = 'awaiting_prep' where id = l_due;
  perform tests.assert_eq('...and a new one is counted as new, not in progress', tests.tonight_text(mgr_a, 'mgra@ac.example', venue_a, night), 'new=2 progress=3 delivered=2');
  j := public.night_report_data(venue_a, night);   -- internal: the app reaches it through the close-night functions, so it is read here as the database owner
  perform tests.assert_eq('the night''s report: the same split (its "awaiting" also counts the line that is unpaid online, which Tonight leaves out)', (j -> 'bottles' ->> 'awaiting') || '/' || (j -> 'bottles' ->> 'in_progress') || '/' || (j -> 'bottles' ->> 'served'), '3/3/2');

  ---------------------------------------------------------------- the website's own staff function accepts the stage too
  perform tests.login(admin_u, 'admin@test.example');
  j := public.update_bottle_service_status(l_due, 'accepted');
  perform tests.logout();
  perform tests.assert_eq('a BottlesUp admin sets accepted from the website', j::text, '{"status": "accepted", "success": true}');
  perform tests.assert_eq('...and the line is accepted', tests.state(l_due), 'accepted');
  perform tests.assert_eq('website door staff can too', tests.try(staff_u, 'staff@test.example', format($q$select public.update_bottle_service_status(%L, 'preparing')::text$q$, l_due)), '{"status": "preparing", "success": true}');
  perform tests.assert_eq('an invalid stage is still refused there', tests.try(admin_u, 'admin@test.example', format($q$select public.update_bottle_service_status(%L, 'shipped')::text$q$, l_due)), 'ERROR: invalid status');
  perform tests.assert_eq('someone who is neither is not authorized', tests.try(rando, 'rando@test.example', format($q$select public.update_bottle_service_status(%L, 'accepted')::text$q$, l_due)), 'ERROR: not authorized');
  perform tests.assert_eq('the old unverified-payment rule still holds there', tests.try(admin_u, 'admin@test.example', format($q$select public.update_bottle_service_status(%L, 'accepted')::text$q$, l_pend)), 'ERROR: payment not yet verified for this item');

  ---------------------------------------------------------------- the lists the app reads still say what the line is
  perform tests.login(mgr_a, 'mgra@ac.example');
  perform tests.assert_eq('the orders list shows the new stage as it is stored', (select service_status from public.desk_orders(venue_a, night) o where o.line_id = l_new2), 'accepted');
  perform tests.assert_eq('a table''s own list too', (select service_status from public.desk_booking_orders(b_one) o where o.line_id = l_new2), 'accepted');
  perform tests.logout();

  perform tests.assert_true('every replaced function still runs with its owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('desk_set_service_status', 'desk_tonight', 'night_report_data', 'update_bottle_service_status')));
end $$;

rollback;
