-- Bottle orders at a table. What matters most: only the staff of THAT club reach its orders; a server reaches only the tables they were
-- given; an order moves along one step at a time without ever being written twice; a delivered item stays delivered unless a manager
-- says otherwise; an item to be paid at the venue is not handed over until it has been paid; closed-out, cancelled and still-unpaid
-- items cannot be touched; and every move is attributed. (The production-only columns come from tests/db/prod_shapes.)
begin;

create function tests.set_as(p_user uuid, p_email text, p_line uuid, p_status text)
returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return case when public.desk_set_service_status(p_line, p_status) then 'changed' else 'same' end;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.line_status(p_id uuid) returns text language sql security definer as $$ select service_status from public.site_table_booking_bottles where id = p_id $$;
create function tests.audit_count(p_prefix text, p_entity uuid) returns int language sql security definer as $$
  select count(*)::int from public.audit_log where action like p_prefix || '%' and entity_id = p_entity::text $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int default 1000, p_paid int default 0, p_status text default 'paid') returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, p_total, p_paid, p_status, upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkline(p_booking uuid, p_name text, p_pay text default 'paid', p_svc text default 'awaiting_prep', p_age interval default interval '0', p_qty int default 1, p_price int default 5000)
returns uuid language sql security definer as $$
  insert into public.site_table_booking_bottles (booking_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, payment_status, service_status, created_at)
  values (p_booking, p_name, '750ml', p_price, p_qty, p_price * p_qty, p_pay, p_svc, now() - p_age)
  returning id $$;
create function tests.names(p_names text[]) returns text language sql immutable as $$ select array_to_string(p_names, ',') $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000000d2';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000d3';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000d4';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000000d5';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000000d6';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000000d7';
  srv_b constant uuid := '00000000-0000-0000-0000-0000000000d8';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000000d9';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; tok text; r record; n int; res text;
  type_a uuid; type_b uuid; slot_eve uuid; slot_late uuid; slot_b uuid;
  m_s1 uuid; m_s2 uuid; m_sb uuid;
  b_ada uuid; b_zed uuid; b_open uuid; b_bea uuid; b_pend uuid; b_closed uuid; b_late uuid; b_next uuid; b_gone uuid;
  l1 uuid; l2 uuid; l3 uuid; l4 uuid; z1 uuid; z2 uuid; o1 uuid; bb1 uuid; p1 uuid; c1 uuid; late1 uuid; next1 uuid; tx uuid;
  night date := current_date + 10;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@club.example'), (mgr_a, 'mgra@club.example'), (rival_u, 'rival@club2.example'), (door_a, 'doora@club.example'),
    (mgr_b, 'mgrb@club.example'), (srv_1, 'srv1@club.example'), (srv_2, 'srv2@club.example'), (srv_b, 'srvb@club.example'),
    (ver_a, 'vera@club.example');

  ---------------------------------------------------------------- set up: two clubs of one business, a rival, staff
  perform tests.login(owner_u, 'owner@club.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@club2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  perform public.create_org_venue(org2, 'Rival Club');

  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'mgra@club.example', 'manager', venue_a) i;
  perform tests.login(mgr_a, 'mgra@club.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'mgrb@club.example', 'manager', venue_b) i;
  perform tests.login(mgr_b, 'mgrb@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@club.example');
  select i.token into tok from public.invite_member(org, 'srv1@club.example', 'server', venue_a) i;
  perform tests.login(srv_1, 'srv1@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@club.example');
  select i.token into tok from public.invite_member(org, 'srv2@club.example', 'server', venue_a) i;
  perform tests.login(srv_2, 'srv2@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@club.example');
  select i.token into tok from public.invite_member(org, 'doora@club.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@club.example');
  select i.token into tok from public.invite_member(org, 'vera@club.example', 'verifier', venue_a) i;
  perform tests.login(ver_a, 'vera@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_b, 'mgrb@club.example');
  select i.token into tok from public.invite_member(org, 'srvb@club.example', 'server', venue_b) i;
  perform tests.login(srv_b, 'srvb@club.example'); perform public.accept_invitation(tok);

  perform tests.logout();
  select id into m_s1 from public.site_memberships where user_id = srv_1 and role = 'server';
  select id into m_s2 from public.site_memberships where user_id = srv_2 and role = 'server';
  select id into m_sb from public.site_memberships where user_id = srv_b and role = 'server';

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 5) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 5) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 0, '01:00', 'After midnight') returning id into slot_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;

  -- Ada's table is srv_1's (a balance of 4000 is still due), Zed's is srv_2's, Olga's is nobody's.
  b_ada := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Ada Evening', 10000, 6000);
  b_zed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Zed Evening', 8000, 8000);
  b_open := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Open Olga');
  b_bea := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bea Clubb');
  b_pend := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Pending Pat', 1000, 0, 'pending');
  b_closed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Closed Cleo');
  b_late := tests.mkbooking(venue_a, type_a, slot_late, night + 1, 'Late Lena');
  b_next := tests.mkbooking(venue_a, type_a, slot_eve, night + 1, 'Next Nina');
  b_gone := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Gone Gil', 1000, 0, 'cancelled');
  update public.site_table_bookings set checked_in_at = now() - interval '1 hour' where id = b_ada;
  update public.site_table_bookings set reconciled_at = now() where id = b_closed;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_ada, m_s1);
  perform public.assign_booking_server(b_zed, m_s2);
  perform public.assign_booking_server(b_closed, m_s1);
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform public.assign_booking_server(b_bea, m_sb);
  perform tests.logout();

  l1 := tests.mkline(b_ada, 'Patron', 'paid', 'awaiting_prep', interval '60 minutes');
  l2 := tests.mkline(b_ada, 'Grey Goose', 'due_at_venue', 'awaiting_prep', interval '30 minutes');
  l3 := tests.mkline(b_ada, 'Hennessy', 'paid', 'awaiting_prep', interval '45 minutes');
  update public.site_table_booking_bottles set cancelled_at = now(), cancellation_reason = 'guest changed their mind' where id = l3;
  l4 := tests.mkline(b_ada, 'Dom Perignon', 'pending_payment', 'awaiting_prep', interval '5 minutes');
  z1 := tests.mkline(b_zed, 'Don Julio', 'paid', 'preparing', interval '90 minutes');
  z2 := tests.mkline(b_zed, 'Belvedere', 'paid', 'served', interval '120 minutes');
  o1 := tests.mkline(b_open, 'Moet', 'paid', 'awaiting_prep', interval '10 minutes');
  bb1 := tests.mkline(b_bea, 'Casamigos', 'paid', 'awaiting_prep');
  p1 := tests.mkline(b_pend, 'Smirnoff', 'paid', 'awaiting_prep');
  c1 := tests.mkline(b_closed, 'Jameson', 'paid', 'awaiting_prep');
  late1 := tests.mkline(b_late, 'Late Bottle', 'paid', 'awaiting_prep');
  next1 := tests.mkline(b_next, 'Next Bottle', 'paid', 'awaiting_prep');
  tx := tests.mkline(b_gone, 'Gone Bottle', 'paid', 'awaiting_prep');

  ---------------------------------------------------------------- the manager's list of a night
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('the manager sees the live orders of the night, oldest unfinished first, delivered last',
    tests.names(array(select d.bottle_name from public.desk_orders(venue_a, night) d)), 'Don Julio,Patron,Grey Goose,Moet,Late Bottle,Belvedere'::text);
  perform tests.assert_eq('...not a cancelled line, one still being paid online, a table that was closed out, another club''s, a pending or cancelled booking''s, or another night''s',
    (select count(*) from public.desk_orders(venue_a, night) d where d.bottle_name in ('Hennessy', 'Dom Perignon', 'Jameson', 'Casamigos', 'Smirnoff', 'Gone Bottle', 'Next Bottle'))::int, 0);
  select * into r from public.desk_orders(venue_a, night) d where d.line_id = l2;
  perform tests.assert_eq('a line carries its booking, guest, table and money state', r.confirmation_code || '|' || r.customer_name || '|' || r.table_name || '|' || r.guest_count || '|' || r.bottle_name || '|' || r.size || '|' || r.quantity || '|' || r.line_total_cents || '|' || r.payment_status || '|' || r.service_status,
    'ADA-EVENING|Ada Evening|VIP booth|2|Grey Goose|750ml|1|5000|due_at_venue|awaiting_prep'::text);
  perform tests.assert_eq('...the balance still due at the table and whether the guests have arrived', r.balance_due_cents::text || '|' || (r.checked_in_at is not null)::text, '4000|true'::text);
  perform tests.assert_eq('...and whose table it is', r.server_membership_id::text || '|' || r.server_is_me::text, m_s1::text || '|false');
  perform tests.assert_eq('a table nobody was given has no server', (select d.server_membership_id from public.desk_orders(venue_a, night) d where d.line_id = o1), null::uuid);
  perform tests.assert_eq('a booking in the after-midnight slot belongs to the night before', (select count(*) from public.desk_orders(venue_a, night) d where d.line_id = late1)::int, 1);
  perform tests.assert_eq('...and not to the calendar day it is on', (select count(*) from public.desk_orders(venue_a, night + 1) d where d.line_id = late1)::int, 0);
  perform tests.assert_eq('an evening booking belongs to its own date', (select count(*) from public.desk_orders(venue_a, night + 1) d where d.line_id = next1)::int, 1);
  perform tests.assert_eq('a night with nothing is an empty list', (select count(*) from public.desk_orders(venue_a, night + 40))::int, 0);
  perform tests.assert_raises('no night chosen', format($q$select * from public.desk_orders(%L, null)$q$, venue_a), 'choose a night');

  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the owner sees the same club-wide list', (select count(*) from public.desk_orders(venue_a, night))::int, 6);

  ---------------------------------------------------------------- a server's list
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_eq('a server sees only the lines of the tables they were given',
    tests.names(array(select d.bottle_name from public.desk_orders(venue_a, night) d)), 'Patron,Grey Goose'::text);
  perform tests.assert_eq('...and knows they are theirs', (select bool_and(d.server_is_me) from public.desk_orders(venue_a, night) d), true);
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_eq('the other server sees theirs', tests.names(array(select d.bottle_name from public.desk_orders(venue_a, night) d)), 'Don Julio,Belvedere'::text);

  ---------------------------------------------------------------- who may not read a club's orders
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff cannot', format($q$select * from public.desk_orders(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(ver_a, 'vera@club.example');
  perform tests.assert_raises('a verifier cannot', format($q$select * from public.desk_orders(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('a manager of the other club cannot', format($q$select * from public.desk_orders(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(srv_b, 'srvb@club.example');
  perform tests.assert_raises('a server of the other club cannot', format($q$select * from public.desk_orders(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(rival_u, 'rival@club2.example');
  perform tests.assert_raises('a rival owner cannot', format($q$select * from public.desk_orders(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(rando, null);
  perform tests.assert_raises('a signed-in person with no role cannot', format($q$select * from public.desk_orders(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format($q$select * from public.desk_orders(%L, %L)$q$, venue_a, night), 'permission denied');

  ---------------------------------------------------------------- when a server's access ends, or the table changes hands
  perform tests.logout();
  update public.site_memberships set access_end_at = now() - interval '1 minute' where id = m_s1;
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_raises('a server whose access ended gets nothing', format($q$select * from public.desk_orders(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.logout();
  update public.site_memberships set access_end_at = null where id = m_s1;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_ada, m_s2);
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_eq('when a table is given to someone else its orders leave the first server', tests.names(array(select d.bottle_name from public.desk_orders(venue_a, night) d)), ''::text);
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_eq('...and arrive with the new one', (select count(*) from public.desk_orders(venue_a, night) d where d.line_id in (l1, l2))::int, 2);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_ada, m_s1);

  ---------------------------------------------------------------- one table's lines
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_eq('a table''s sheet lists every line including a cancelled one, but not one still being paid online',
    tests.names(array(select d.bottle_name from public.desk_booking_orders(b_ada) d)), 'Patron,Hennessy,Grey Goose'::text);
  select * into r from public.desk_booking_orders(b_ada) d where d.line_id = l3;
  perform tests.assert_eq('...a cancelled line says why', (r.cancelled_at is not null)::text || '|' || r.cancellation_reason, 'true|guest changed their mind'::text);
  perform tests.assert_raises('a server cannot open another server''s table', format($q$select * from public.desk_booking_orders(%L)$q$, b_zed), 'not allowed');
  perform tests.assert_raises('...or a table nobody has', format($q$select * from public.desk_booking_orders(%L)$q$, b_open), 'not allowed');
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('the manager can open any table of the club', (select count(*) from public.desk_booking_orders(b_open))::int, 1);
  perform tests.login(ver_a, 'vera@club.example');
  perform tests.assert_raises('a verifier does not see orders', format($q$select * from public.desk_booking_orders(%L)$q$, b_ada), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('...nor does the other club''s manager', format($q$select * from public.desk_booking_orders(%L)$q$, b_ada), 'not allowed');
  perform tests.assert_raises('a booking that does not exist gets the same answer', format($q$select * from public.desk_booking_orders(%L)$q$, gen_random_uuid()), 'not allowed');

  ---------------------------------------------------------------- moving an order along: who may
  res := tests.set_as(srv_1, 'srv1@club.example', l1, 'preparing');
  perform tests.assert_eq('the server whose table it is can move an order', res, 'changed');
  perform tests.assert_eq('...it is now preparing', tests.line_status(l1), 'preparing');
  perform tests.logout();
  select * into r from public.audit_log where action = 'table_booking.bottle_service_status_updated' and entity_id = l1::text;
  perform tests.assert_eq('...and recorded: who, what, from and to, at which club', r.actor_id::text || '|' || r.actor_email || '|' || r.entity_type || '|' || (r.details ->> 'old_status') || '|' || (r.details ->> 'new_status') || '|' || (r.details ->> 'venue_id') || '|' || (r.details ->> 'booking_id'),
    srv_1::text || '|srv1@club.example|site_table_booking_bottles|awaiting_prep|preparing|' || venue_a::text || '|' || b_ada::text);
  perform tests.assert_eq('a repeated tap changes nothing', tests.set_as(srv_1, 'srv1@club.example', l1, 'preparing'), 'same');
  perform tests.logout();
  perform tests.assert_eq('...and records nothing more', tests.audit_count('table_booking.bottle_service_status_updated', l1), 1);
  perform tests.assert_eq('a colleague arriving second to the same move is told it is already so', tests.set_as(mgr_a, 'mgra@club.example', l1, 'preparing'), 'same');

  perform tests.assert_eq('another server cannot move it', tests.set_as(srv_2, 'srv2@club.example', l1, 'ready'), 'ERROR: not allowed');
  perform tests.assert_eq('the other club''s manager cannot', tests.set_as(mgr_b, 'mgrb@club.example', l1, 'ready'), 'ERROR: not allowed');
  perform tests.assert_eq('the other club''s server cannot', tests.set_as(srv_b, 'srvb@club.example', l1, 'ready'), 'ERROR: not allowed');
  perform tests.assert_eq('door staff cannot', tests.set_as(door_a, 'doora@club.example', l1, 'ready'), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier cannot', tests.set_as(ver_a, 'vera@club.example', l1, 'ready'), 'ERROR: not allowed');
  perform tests.assert_eq('a rival owner cannot', tests.set_as(rival_u, 'rival@club2.example', l1, 'ready'), 'ERROR: not allowed');
  perform tests.assert_eq('a signed-in person with no role cannot', tests.set_as(rando, null, l1, 'ready'), 'ERROR: not allowed');
  perform tests.assert_eq('a line that does not exist gets the same answer', tests.set_as(mgr_a, 'mgra@club.example', gen_random_uuid(), 'ready'), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot move a table nobody was given', tests.set_as(srv_1, 'srv1@club.example', o1, 'ready'), 'ERROR: not allowed');
  perform tests.assert_eq('...the manager can', tests.set_as(mgr_a, 'mgra@club.example', o1, 'ready'), 'changed');
  perform tests.assert_eq('the owner can too', tests.set_as(owner_u, 'owner@club.example', o1, 'picked_up'), 'changed');
  perform tests.logout();
  perform tests.assert_eq('none of those refusals moved anything', tests.line_status(l1), 'preparing');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format($q$select public.desk_set_service_status(%L, 'ready')$q$, l1), 'permission denied');

  ---------------------------------------------------------------- moving an order along: what is allowed
  perform tests.assert_eq('a status that does not exist', tests.set_as(mgr_a, 'mgra@club.example', l1, 'cooking'), 'ERROR: invalid status');
  perform tests.assert_eq('no status', tests.set_as(mgr_a, 'mgra@club.example', l1, null), 'ERROR: invalid status');
  perform tests.assert_eq('a cancelled line cannot be moved', tests.set_as(mgr_a, 'mgra@club.example', l3, 'ready'), 'ERROR: this item was cancelled');
  perform tests.assert_eq('a line still being paid online cannot', tests.set_as(mgr_a, 'mgra@club.example', l4, 'ready'), 'ERROR: payment not yet verified for this item');
  perform tests.assert_eq('a line of a booking that is not paid cannot', tests.set_as(mgr_a, 'mgra@club.example', p1, 'ready'), 'ERROR: only a paid booking has orders to serve');
  perform tests.assert_eq('...nor one of a cancelled booking', tests.set_as(mgr_a, 'mgra@club.example', tx, 'ready'), 'ERROR: only a paid booking has orders to serve');
  perform tests.assert_eq('a table that was closed out cannot be changed', tests.set_as(mgr_a, 'mgra@club.example', c1, 'ready'), 'ERROR: this table has already been closed out');
  perform tests.assert_eq('...not even by its server', tests.set_as(srv_1, 'srv1@club.example', c1, 'ready'), 'ERROR: this table has already been closed out');
  perform tests.logout();
  perform tests.assert_eq('...and nothing moved', tests.line_status(c1) || '|' || tests.line_status(l3) || '|' || tests.line_status(l4) || '|' || tests.line_status(p1), 'awaiting_prep|awaiting_prep|awaiting_prep|awaiting_prep'::text);

  perform tests.assert_eq('an order can go through every step', tests.set_as(srv_1, 'srv1@club.example', l1, 'ready') || '/' || tests.set_as(srv_1, 'srv1@club.example', l1, 'picked_up') || '/' || tests.set_as(srv_1, 'srv1@club.example', l1, 'served'), 'changed/changed/changed'::text);
  perform tests.assert_eq('...a prepaid item can be delivered while the table still owes', tests.line_status(l1), 'served');
  perform tests.assert_eq('a server cannot take a delivered item back', tests.set_as(srv_1, 'srv1@club.example', l1, 'preparing'), 'ERROR: a delivered item can only be changed by a manager');
  perform tests.assert_eq('...saying delivered again is still just a repeat', tests.set_as(srv_1, 'srv1@club.example', l1, 'served'), 'same');
  perform tests.assert_eq('a manager can', tests.set_as(mgr_a, 'mgra@club.example', l1, 'preparing'), 'changed');
  perform tests.logout();
  select * into r from public.audit_log where action = 'table_booking.bottle_service_status_updated' and entity_id = l1::text and details ->> 'new_status' = 'preparing' and actor_id = mgr_a;
  perform tests.assert_eq('...and the history keeps where it came from', r.details ->> 'old_status', 'served');
  perform tests.assert_eq('each real move left exactly one entry', tests.audit_count('table_booking.bottle_service_status_updated', l1), 5);

  ---------------------------------------------------------------- an item to be paid at the venue
  perform tests.assert_eq('it cannot be delivered while the table has a balance', tests.set_as(srv_1, 'srv1@club.example', l2, 'served'), 'ERROR: cannot mark delivered - this table still has a balance due at the venue');
  perform tests.logout();
  update public.site_table_bookings set amount_paid_cents = amount_total_cents where id = b_ada;
  perform tests.assert_eq('...nor with the balance gone but no payment on record', tests.set_as(srv_1, 'srv1@club.example', l2, 'served'), 'ERROR: cannot mark delivered - no payment has been recorded for this table');
  perform tests.logout();
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, missing_receipt_reason)
    values (b_ada, 5000, 5000, 'cash', 'printer broken');
  perform tests.assert_eq('...it can once a payment is on record (a receipt, or the manager''s reason for none)', tests.set_as(srv_1, 'srv1@club.example', l2, 'served'), 'changed');
  perform tests.logout();
  perform tests.assert_eq('earlier steps never need the money', tests.set_as(srv_2, 'srv2@club.example', z1, 'ready'), 'changed');

  ---------------------------------------------------------------- the table itself, the helpers, hygiene
  perform tests.login(owner_u, 'owner@club.example');
  update public.site_table_booking_bottles set service_status = 'ready' where id = l1;
  get diagnostics n = row_count;
  perform tests.assert_eq('writing a bottle line directly changes nothing (row level security)', n, 0);
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_eq('a server can ask how they stand towards their own table', public.desk_booking_level(b_ada), 'server');
  perform tests.assert_eq('...and towards another''s: nothing', public.desk_booking_level(b_zed), null::text);
  perform tests.assert_eq('...and towards one that does not exist: nothing', public.desk_booking_level(gen_random_uuid()), null::text);
  perform tests.assert_eq('...and towards none at all: nothing', public.desk_booking_level(null), null::text);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('the manager stands as manager', public.desk_booking_level(b_zed), 'manager');
  perform tests.login(ver_a, 'vera@club.example');
  perform tests.assert_eq('a verifier stands as verifier', public.desk_booking_level(b_zed), 'verifier');
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_eq('door staff stand as nothing', public.desk_booking_level(b_zed), null::text);
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot ask', format($q$select public.desk_booking_level(%L)$q$, b_zed), 'permission denied');

  perform tests.logout();
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname in ('desk_booking_level', 'desk_orders', 'desk_booking_orders', 'desk_set_service_status')
      and p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%';
  perform tests.assert_eq('all four functions run with their owner''s rights and pin their search path', n, 4);

  ---------------------------------------------------------------- a very busy night is cut off, not returned whole
  insert into public.site_table_booking_bottles (booking_id, bottle_name, unit_price_cents, quantity, line_total_cents, payment_status, service_status)
    select b_open, 'Bulk ' || g, 1000, 1, 1000, 'paid', 'awaiting_prep' from generate_series(1, 1001) g;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('more than a thousand lines come back as the first thousand', (select count(*) from public.desk_orders(venue_a, night))::int, 1000);
end $$;

rollback;
