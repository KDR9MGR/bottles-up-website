-- Payments taken at the club and checked afterwards. What matters most: only the staff of THAT club (and for a server, only their own
-- table) can record or see a payment; a server cannot record one without a receipt photo, a manager only with a written reason; the
-- photo is tied to its booking; a repeated tap or a re-used receipt never becomes a second payment; nobody verifies their own entry or
-- verifies twice; the numbers the manager sees add up; and every step is attributed. (The production-only tables and columns come
-- from tests/db/prod_shapes.)
begin;

create function tests.rec(p_user uuid, p_email text, p_booking uuid, p_billed int, p_paid int, p_method text, p_args jsonb default '{}')
returns jsonb language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return public.desk_record_payment(
    p_booking, p_billed, p_paid, p_method,
    p_args -> 'split', p_args ->> 'pos', p_args ->> 'path', p_args ->> 'payer', p_args ->> 'email',
    coalesce((p_args ->> 'bottles')::int, 0), coalesce((p_args ->> 'discount')::int, 0), coalesce((p_args ->> 'tax')::int, 0), coalesce((p_args ->> 'tip')::int, 0),
    p_args ->> 'hash', p_args ->> 'device', p_args ->> 'reason');
exception when others then
  return jsonb_build_object('error', sqlerrm);
end $$;
create function tests.verify_as(p_user uuid, p_email text, p_payment uuid, p_note text default null)
returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  perform public.desk_verify_payment(p_payment, p_note);
  return 'ok';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.pay_count(p_booking uuid) returns int language sql security definer as $$ select count(*)::int from public.site_table_booking_club_payments where booking_id = p_booking $$;
create function tests.paid(p_booking uuid) returns int language sql security definer as $$ select amount_paid_cents from public.site_table_bookings where id = p_booking $$;
create function tests.verified(p_payment uuid) returns text language sql security definer as $$
  select coalesce(manager_verified_by::text, 'nobody') || '|' || coalesce(manager_verified_note, '-') from public.site_table_booking_club_payments where id = p_payment $$;
create function tests.audit_count(p_prefix text, p_entity uuid) returns int language sql security definer as $$
  select count(*)::int from public.audit_log where action like p_prefix || '%' and entity_id = p_entity::text $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int default 1000, p_paid int default 0, p_status text default 'paid') returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, p_total, p_paid, p_status, upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkline(p_booking uuid, p_name text, p_pay text default 'paid', p_svc text default 'awaiting_prep', p_cancelled boolean default false)
returns uuid language sql security definer as $$
  insert into public.site_table_booking_bottles (booking_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, payment_status, service_status, cancelled_at)
  values (p_booking, p_name, '750ml', 5000, 1, 5000, p_pay, p_svc, case when p_cancelled then now() end)
  returning id $$;
create function tests.mkpay(p_booking uuid, p_paid int, p_status text default 'pending', p_verified boolean default false, p_by uuid default null, p_age interval default interval '0') returns uuid language sql security definer as $$
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, customer_confirmation_status, recorded_by, recorded_at, manager_verified_at, missing_receipt_reason)
  values (p_booking, p_paid, p_paid, 'cash', p_status, p_by, now() - p_age, case when p_verified then now() end, 'seeded')
  returning id $$;
create function tests.put_receipt(p_user uuid, p_email text, p_name text) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  insert into storage.objects (bucket_id, name) values ('club-payment-receipts', p_name);
  return 'ok';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.see_receipts(p_user uuid, p_email text, p_prefix text) returns int language plpgsql as $$
declare n int;
begin
  perform tests.login(p_user, p_email);
  select count(*)::int into n from storage.objects o where o.bucket_id = 'club-payment-receipts' and o.name like p_prefix || '%';
  return n;
end $$;

create function tests.verification_of(p_booking uuid, p_payment uuid) returns text language sql as $$
  select p ->> 'verification' from jsonb_array_elements(public.desk_booking_money(p_booking) -> 'payments') p where p ->> 'id' = p_payment::text $$;
create function tests.ts_line(p_venue uuid, p_night date, p_booking uuid) returns text language sql as $$
  select concat_ws('|', balance_due_cents, items_open, items_delivered, payments_recorded, payments_unchecked, closed_out, closeout_requested)
  from public.desk_table_status(p_venue, p_night) where booking_id = p_booking $$;
create function tests.tonight_line(p_venue uuid, p_night date) returns text language sql as $$
  select concat_ws('|', tables, guests, arrived, without_server, with_balance, balance_due_cents, orders_new, orders_in_progress,
                   orders_delivered, payments_to_check, payments_disputed, closeouts_requested, requests_open)
  from public.desk_tonight(p_venue, p_night) $$;

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
  ver_b constant uuid := '00000000-0000-0000-0000-0000000000da';
  mgr_c constant uuid := '00000000-0000-0000-0000-0000000000db';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  hash_a constant text := repeat('a', 64);
  hash_b constant text := repeat('b', 64);
  hash_c constant text := repeat('c', 64);
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; tok text; r record; n int; res jsonb; txt text; v jsonb; arr uuid[];
  pay_9000 uuid; pay_111 uuid; req_z uuid;
  type_a uuid; type_b uuid; slot_eve uuid; slot_late uuid; slot_b uuid;
  m_s1 uuid; m_s2 uuid; m_sb uuid;
  b_ada uuid; b_zed uuid; b_open uuid; b_bea uuid; b_pend uuid; b_closed uuid; b_late uuid; b_next uuid;
  pay1 uuid; pay_dup uuid; pay_mgr uuid; pay_conf uuid; pay_disp uuid; pay_old uuid; pay_other uuid; pay_vermine uuid; pay_b uuid;
  night date := current_date + 10;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@club.example'), (mgr_a, 'mgra@club.example'), (rival_u, 'rival@club2.example'), (door_a, 'doora@club.example'),
    (mgr_b, 'mgrb@club.example'), (srv_1, 'srv1@club.example'), (srv_2, 'srv2@club.example'), (srv_b, 'srvb@club.example'),
    (ver_a, 'vera@club.example'), (ver_b, 'verb@club.example'), (mgr_c, 'mgrc@club.example');
  insert into public.profiles (id, name, email) values (srv_1, 'Sam Server', 'srv1@club.example'), (mgr_a, 'Mia Manager', 'mgra@club.example');

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
  select i.token into tok from public.invite_member(org, 'mgrc@club.example', 'manager', venue_a) i;
  perform tests.login(mgr_c, 'mgrc@club.example'); perform public.accept_invitation(tok);
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
  select i.token into tok from public.invite_member(org, 'verb@club.example', 'verifier', venue_b) i;
  perform tests.login(ver_b, 'verb@club.example'); perform public.accept_invitation(tok);
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

  b_ada := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Ada Evening', 10000, 2000);
  b_zed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Zed Evening', 8000, 0);
  b_open := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Open Olga', 1000, 0);
  b_bea := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bea Clubb', 5000, 0);
  b_pend := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Pending Pat', 1000, 0, 'pending');
  b_closed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Closed Cleo', 1000, 0);
  b_late := tests.mkbooking(venue_a, type_a, slot_late, night + 1, 'Late Lena', 3000, 3000);
  b_next := tests.mkbooking(venue_a, type_a, slot_eve, night + 1, 'Next Nina', 3000, 0);
  update public.site_table_bookings set reconciled_at = now() where id = b_closed;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_ada, m_s1);
  perform public.assign_booking_server(b_zed, m_s2);
  perform public.assign_booking_server(b_closed, m_s1);
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform public.assign_booking_server(b_bea, m_sb);
  perform tests.logout();

  ---------------------------------------------------------------- a server records a payment
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 3000, 3000, 'debit', '{}');
  perform tests.assert_eq('a server cannot record a payment without a receipt photo', res ->> 'error', 'a receipt photo is required');
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 3000, 3000, 'debit', jsonb_build_object('reason', 'printer broke'));
  perform tests.assert_eq('...a reason does not stand in for one', res ->> 'error', 'a receipt photo is required');
  perform tests.logout();
  perform tests.assert_eq('...and nothing was written', tests.pay_count(b_ada), 0);

  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 3500, 3000, 'debit', jsonb_build_object(
    'path', b_ada::text || '/r1.jpg', 'hash', hash_a, 'pos', '  POS-1001  ', 'device', 'device-7', 'payer', '  Ada L  ', 'email', 'ada@pay.example',
    'bottles', 2800, 'discount', 100, 'tax', 364, 'tip', 500));
  perform tests.assert_eq('a server records a payment for their own table', (res ->> 'success') || '|' || (res ->> 'duplicate'), 'true|false');
  pay1 := (res ->> 'payment_id')::uuid;
  perform tests.assert_eq('...the booking''s paid total goes up and the balance goes down', (res ->> 'new_amount_paid_cents') || '|' || (res ->> 'balance_due_cents'), '5000|5000'::text);
  perform tests.logout();
  select * into r from public.site_table_booking_club_payments where id = pay1;
  perform tests.assert_eq('...the row says who, how, how much, on what evidence',
    r.recorded_by::text || '|' || r.payment_method || '|' || r.billed_amount_cents || '|' || r.amount_paid_cents || '|' || r.pos_reference || '|' || r.receipt_photo_path || '|' || r.receipt_photo_hash || '|' || r.device_id,
    srv_1::text || '|debit|3500|3000|POS-1001|' || b_ada::text || '/r1.jpg|' || hash_a || '|device-7');
  perform tests.assert_eq('...the line items and the payer (trimmed)', r.bottle_subtotal_cents || '|' || r.discount_cents || '|' || r.tax_cents || '|' || r.gratuity_cents || '|' || r.payer_name || '|' || r.payer_email,
    '2800|100|364|500|Ada L|ada@pay.example'::text);
  perform tests.assert_eq('...it starts as pending and unchecked', r.customer_confirmation_status || '|' || coalesce(r.manager_verified_at::text, 'unchecked'), 'pending|unchecked'::text);
  perform tests.assert_eq('...a missing-receipt reason is not kept when there is a photo', r.missing_receipt_reason, null::text);
  select * into r from public.audit_log where action = 'table_booking.club_payment_recorded' and entity_id = b_ada::text;
  perform tests.assert_eq('...and recorded in the audit log: who, which club, which payment, as what',
    r.actor_id::text || '|' || r.actor_email || '|' || (r.details ->> 'venue_id') || '|' || (r.details ->> 'payment_id') || '|' || (r.details ->> 'recorded_as') || '|' || (r.details ->> 'new_amount_paid_cents'),
    srv_1::text || '|srv1@club.example|' || venue_a::text || '|' || pay1::text || '|server|5000');
  perform tests.assert_true('...the audit entry carries no email address of the guest', position('ada@pay.example' in r.details::text) = 0);

  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 3500, 3000, 'debit', jsonb_build_object('path', b_ada::text || '/r1.jpg', 'hash', hash_a, 'pos', 'POS-1001'));
  perform tests.assert_eq('the same receipt sent again (a repeated tap) is the same payment', (res ->> 'duplicate') || '|' || (res ->> 'payment_id'), 'true|' || pay1::text);
  perform tests.assert_eq('...with the balance as it stands', (res ->> 'new_amount_paid_cents') || '|' || (res ->> 'balance_due_cents'), '5000|5000'::text);
  perform tests.logout();
  perform tests.assert_eq('...and nothing was written twice', tests.pay_count(b_ada) || '|' || tests.paid(b_ada) || '|' || tests.audit_count('table_booking.club_payment_recorded', b_ada), '1|5000|1'::text);

  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 9000, 9000, 'cash', jsonb_build_object('path', b_ada::text || '/r2.jpg'));
  perform tests.assert_eq('a payment larger than the balance is recorded in full but the booking is never over-paid', (res ->> 'new_amount_paid_cents') || '|' || (res ->> 'balance_due_cents'), '10000|0'::text);
  perform tests.logout();
  perform tests.assert_eq('...the payment keeps what was really collected', (select amount_paid_cents from public.site_table_booking_club_payments where id = (res ->> 'payment_id')::uuid), 9000);

  ---------------------------------------------------------------- a manager records one
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 2000, 2000, 'cash', '{}');
  perform tests.assert_eq('a manager must give a reason when there is no receipt', res ->> 'error', 'a reason is required when recording without a receipt');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 2000, 2000, 'cash', jsonb_build_object('reason', '   '));
  perform tests.assert_eq('...a blank reason does not count', res ->> 'error', 'a reason is required when recording without a receipt');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 2000, 2000, 'cash', jsonb_build_object('reason', '  till printer is down  '));
  perform tests.assert_eq('...with one it is recorded', (res ->> 'success') || '|' || (res ->> 'duplicate') || '|' || (res ->> 'new_amount_paid_cents'), 'true|false|2000'::text);
  pay_mgr := (res ->> 'payment_id')::uuid;
  perform tests.logout();
  perform tests.assert_eq('...the reason is trimmed and kept, and there is no photo', (select missing_receipt_reason || '|' || coalesce(receipt_photo_path, 'none') from public.site_table_booking_club_payments where id = pay_mgr), 'till printer is down|none');
  select * into r from public.audit_log where action = 'table_booking.club_payment_recorded' and entity_id = b_zed::text;
  perform tests.assert_eq('...recorded as a manager', r.details ->> 'recorded_as', 'manager');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 2000, 2000, 'cash', jsonb_build_object('reason', 'till printer is down'));
  perform tests.assert_eq('the same entry again within a minute is a repeat, not a second payment', (res ->> 'duplicate') || '|' || (res ->> 'payment_id'), 'true|' || pay_mgr::text);
  perform tests.logout();
  update public.site_table_booking_club_payments set recorded_at = now() - interval '30 seconds' where id = pay_mgr;
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 2000, 2000, 'cash', jsonb_build_object('reason', 'till printer is down'));
  perform tests.assert_eq('...even half a minute later', (res ->> 'duplicate') || '|' || (res ->> 'payment_id'), 'true|' || pay_mgr::text);
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 2000, 2000, 'cash', jsonb_build_object('reason', 'a different reason'));
  perform tests.assert_eq('...but a different reason is a different payment', res ->> 'duplicate', 'false');
  perform tests.logout();
  update public.site_table_booking_club_payments set recorded_at = now() - interval '5 minutes' where id = pay_mgr;
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 2000, 2000, 'cash', jsonb_build_object('reason', 'till printer is down'));
  perform tests.assert_eq('...and so is the same entry once a minute has passed', res ->> 'duplicate', 'false');
  res := tests.rec(mgr_c, 'mgrc@club.example', b_zed, 2000, 2000, 'cash', jsonb_build_object('reason', 'till printer is down'));
  perform tests.assert_eq('...or by someone else', res ->> 'duplicate', 'false');
  res := tests.rec(owner_u, 'owner@club.example', b_open, 500, 500, 'cash', jsonb_build_object('reason', 'owner took it at the bar'));
  perform tests.assert_eq('the owner can record at any table of the club', (res ->> 'success') || '|' || (res ->> 'balance_due_cents'), 'true|500'::text);
  res := tests.rec(mgr_a, 'mgra@club.example', b_open, 100, 100, 'cash', jsonb_build_object('reason', 'tip jar', 'path', b_open::text || '/open1.jpg'));
  perform tests.assert_eq('...a table nobody was given, by the manager, with a photo', res ->> 'success', 'true');
  perform tests.logout();
  perform tests.assert_eq('...a reason sent along with a photo is not kept', (select coalesce(missing_receipt_reason, 'none') from public.site_table_booking_club_payments where id = (res ->> 'payment_id')::uuid), 'none');

  ---------------------------------------------------------------- who may not
  res := tests.rec(srv_2, 'srv2@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/x1.jpg'));
  perform tests.assert_eq('another server cannot', res ->> 'error', 'not allowed');
  res := tests.rec(srv_1, 'srv1@club.example', b_open, 100, 100, 'cash', jsonb_build_object('path', b_open::text || '/x2.jpg'));
  perform tests.assert_eq('a server cannot take payment for a table nobody was given', res ->> 'error', 'not allowed');
  res := tests.rec(mgr_b, 'mgrb@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('the other club''s manager cannot', res ->> 'error', 'not allowed');
  res := tests.rec(srv_b, 'srvb@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/x3.jpg'));
  perform tests.assert_eq('the other club''s server cannot', res ->> 'error', 'not allowed');
  res := tests.rec(door_a, 'doora@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/x4.jpg'));
  perform tests.assert_eq('door staff cannot', res ->> 'error', 'not allowed');
  res := tests.rec(ver_a, 'vera@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a verifier cannot record, only check', res ->> 'error', 'not allowed');
  res := tests.rec(rival_u, 'rival@club2.example', b_ada, 100, 100, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a rival owner cannot', res ->> 'error', 'not allowed');
  res := tests.rec(rando, null, b_ada, 100, 100, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a signed-in person with no role cannot', res ->> 'error', 'not allowed');
  res := tests.rec(mgr_a, 'mgra@club.example', gen_random_uuid(), 100, 100, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a booking that does not exist gets the same answer', res ->> 'error', 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format($q$select public.desk_record_payment(%L, 100, 100, 'cash')$q$, b_ada), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('none of those refusals left a payment behind', tests.pay_count(b_ada) || '|' || tests.pay_count(b_open), '2|2'::text);

  ---------------------------------------------------------------- what is checked
  res := tests.rec(mgr_a, 'mgra@club.example', b_pend, 100, 100, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a booking that is not confirmed cannot take a payment', res ->> 'error', 'only a confirmed booking can take a payment');
  res := tests.rec(mgr_a, 'mgra@club.example', b_closed, 100, 100, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a table that was closed out cannot', res ->> 'error', 'this table has already been closed out');
  res := tests.rec(srv_1, 'srv1@club.example', b_closed, 100, 100, 'cash', jsonb_build_object('path', b_closed::text || '/x.jpg'));
  perform tests.assert_eq('...not even by its server', res ->> 'error', 'this table has already been closed out');

  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'bitcoin', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a payment method that is not on the list', res ->> 'error', 'choose how it was paid');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, null, jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('no method', res ->> 'error', 'choose how it was paid');
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_raises('missing amounts', format($q$select public.desk_record_payment(%L, null, 100, 'cash', null, null, null, null, null, 0, 0, 0, 0, null, null, 'why')$q$, b_zed), 'enter the amounts');
  perform tests.assert_raises('a missing line-item amount', format($q$select public.desk_record_payment(%L, 100, 100, 'cash', null, null, null, null, null, null, 0, 0, 0, null, null, 'why')$q$, b_zed), 'enter the amounts');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, -1, 100, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a negative billed amount', res ->> 'error', 'amounts cannot be negative');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, -1, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a negative collected amount', res ->> 'error', 'amounts cannot be negative');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'cash', jsonb_build_object('reason', 'x', 'tip', -5));
  perform tests.assert_eq('a negative tip', res ->> 'error', 'amounts cannot be negative');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 0, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('nothing collected', res ->> 'error', 'enter the amount collected');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 10000001, 'cash', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('an amount above $100,000', res ->> 'error', 'that amount is too large');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'cash', jsonb_build_object('reason', 'x', 'tax', 10000001));
  perform tests.assert_eq('...in any field', res ->> 'error', 'that amount is too large');
  begin
    res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 10000000, 10000000, 'cash', jsonb_build_object('reason', 'exactly the limit', 'tip', 10000000, 'tax', 10000000));
    perform tests.assert_eq('exactly $100,000 is still accepted, in any field', res ->> 'success', 'true');
    raise exception 'undo' using errcode = 'UD001';
  exception when sqlstate 'UD001' then null;
  end;
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'split', jsonb_build_object('reason', 'x'));
  perform tests.assert_eq('a split payment must say how', res ->> 'error', 'say how the split was paid');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'split', jsonb_build_object('reason', 'x', 'split', '"half and half"'::jsonb));
  perform tests.assert_eq('...as a list or an object, not a bare word', res ->> 'error', 'say how the split was paid');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'split', jsonb_build_object('reason', 'x', 'split', jsonb_build_object('note', repeat('y', 2000))));
  perform tests.assert_eq('...and briefly', res ->> 'error', 'say how the split was paid');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 200, 200, 'split', jsonb_build_object('reason', 'split one', 'split', jsonb_build_array(jsonb_build_object('method', 'cash', 'cents', 100), jsonb_build_object('method', 'debit', 'cents', 100))));
  perform tests.assert_eq('a proper split is recorded', res ->> 'success', 'true');
  perform tests.logout();
  perform tests.assert_eq('...with its breakdown kept', (select jsonb_array_length(split_breakdown) from public.site_table_booking_club_payments where id = (res ->> 'payment_id')::uuid), 2);
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 210, 210, 'cash', jsonb_build_object('reason', 'not a split', 'split', jsonb_build_array(1)));
  perform tests.logout();
  perform tests.assert_eq('a breakdown sent with a cash payment is not kept', (select split_breakdown from public.site_table_booking_club_payments where id = (res ->> 'payment_id')::uuid), null::jsonb);

  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'cash', jsonb_build_object('reason', 'x', 'pos', repeat('9', 81)));
  perform tests.assert_eq('a receipt number that is too long', res ->> 'error', 'the receipt number is too long');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'cash', jsonb_build_object('reason', 'x', 'payer', repeat('n', 121)));
  perform tests.assert_eq('a payer name that is too long', res ->> 'error', 'the payer''s name is too long');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'cash', jsonb_build_object('reason', 'x', 'email', 'not an email'));
  perform tests.assert_eq('an email that is not one', res ->> 'error', 'that email address does not look right');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'cash', jsonb_build_object('reason', 'x', 'device', repeat('d', 101)));
  perform tests.assert_eq('a device id that is too long', res ->> 'error', 'the device id is too long');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'cash', jsonb_build_object('reason', repeat('r', 301)));
  perform tests.assert_eq('a reason of 301 characters', res ->> 'error', 'keep the reason to 300 characters or fewer');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 111, 111, 'cash', jsonb_build_object('reason', repeat('r', 300)));
  perform tests.assert_eq('...300 is fine', res ->> 'success', 'true');

  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_zed::text || '/r.jpg'));
  perform tests.assert_eq('a photo filed under another booking is refused', res ->> 'error', 'the receipt photo does not belong to this booking');
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', 'r.jpg'));
  perform tests.assert_eq('...so is one with no booking in its path', res ->> 'error', 'the receipt photo does not belong to this booking');
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/'));
  perform tests.assert_eq('...or one with no file name', res ->> 'error', 'the receipt photo does not belong to this booking');
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/../' || b_zed::text || '/r.jpg'));
  perform tests.assert_eq('...or one that climbs out of its folder', res ->> 'error', 'the receipt photo does not belong to this booking');
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/' || repeat('p', 300)));
  perform tests.assert_eq('...or an enormous one', res ->> 'error', 'the receipt photo does not belong to this booking');
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/h.jpg', 'hash', 'abc123'));
  perform tests.assert_eq('a photo hash that is not a SHA-256', res ->> 'error', 'the receipt photo could not be checked');
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/h2.jpg', 'hash', upper(hash_b)));
  perform tests.assert_eq('...it must be lower-case hex', res ->> 'error', 'the receipt photo could not be checked');
  perform tests.logout();
  perform tests.assert_eq('none of those wrote a payment', tests.pay_count(b_ada), 2);

  ---------------------------------------------------------------- re-used receipts
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/d1.jpg', 'pos', 'POS-1001'));
  perform tests.assert_eq('a till receipt number already recorded at the club is refused', res ->> 'error', 'this POS receipt number has already been recorded for another payment at this venue');
  res := tests.rec(mgr_a, 'mgra@club.example', b_zed, 100, 100, 'cash', jsonb_build_object('reason', 'x', 'pos', 'POS-1001'));
  perform tests.assert_eq('...even on another table', res ->> 'error', 'this POS receipt number has already been recorded for another payment at this venue');
  res := tests.rec(mgr_b, 'mgrb@club.example', b_bea, 100, 100, 'cash', jsonb_build_object('reason', 'x', 'pos', 'POS-1001'));
  perform tests.assert_eq('...but another club has its own till', res ->> 'success', 'true');
  res := tests.rec(srv_1, 'srv1@club.example', b_ada, 100, 100, 'cash', jsonb_build_object('path', b_ada::text || '/d2.jpg', 'hash', hash_a));
  perform tests.assert_eq('a receipt photo already used at the club is refused', res ->> 'error', 'this receipt photo has already been used for another payment at this venue');
  res := tests.rec(mgr_b, 'mgrb@club.example', b_bea, 100, 100, 'cash', jsonb_build_object('path', b_bea::text || '/d3.jpg', 'hash', hash_a));
  perform tests.assert_eq('...but not at another club', res ->> 'success', 'true');
  perform tests.logout();
  perform tests.assert_eq('the refused ones wrote nothing', tests.pay_count(b_ada), 2);

  ---------------------------------------------------------------- a table's money
  pay_conf := tests.mkpay(b_ada, 100, 'confirmed', false, null, interval '2 hours');
  pay_disp := tests.mkpay(b_ada, 100, 'disputed', false, null, interval '1 hour');
  select cp.id into pay_9000 from public.site_table_booking_club_payments cp where cp.booking_id = b_ada and cp.amount_paid_cents = 9000;
  update public.site_table_booking_club_payments set recorded_at = now() - interval '4 hours' where id = pay1;
  update public.site_table_booking_club_payments set recorded_at = now() - interval '3 hours' where id = pay_9000;
  perform tests.login(mgr_a, 'mgra@club.example');
  v := public.desk_booking_money(b_ada);
  perform tests.assert_eq('the manager sees what the table was charged, what was collected and what is due',
    (v ->> 'amount_total_cents') || '|' || (v ->> 'amount_paid_cents') || '|' || (v ->> 'balance_due_cents') || '|' || (v ->> 'level') || '|' || (v ->> 'table_name') || '|' || (v ->> 'confirmation_code') || '|' || (v ->> 'customer_name'),
    '10000|10000|0|manager|VIP booth|ADA-EVENING|Ada Evening');
  perform tests.assert_eq('...and every payment, oldest first', jsonb_array_length(v -> 'payments'), 4);
  perform tests.assert_eq('...a fresh one reads "verification pending"', (v -> 'payments' -> 0 ->> 'verification') || '|' || (v -> 'payments' -> 0 ->> 'recorded_by_me'), 'pending|false');
  perform tests.assert_eq('...a customer-confirmed one and a disputed one say so', (v -> 'payments' -> 2 ->> 'verification') || '|' || (v -> 'payments' -> 3 ->> 'verification'), 'customer_confirmed|disputed');
  perform tests.assert_eq('...with the photo path the receipt can be opened from', v -> 'payments' -> 0 ->> 'receipt_photo_path', b_ada::text || '/r1.jpg');
  perform tests.assert_true('...and never a guest''s email address', position('ada@pay.example' in v::text) = 0 and position('payer_email' in v::text) = 0);
  perform tests.assert_eq('...the payer''s name is there', v -> 'payments' -> 0 ->> 'payer_name', 'Ada L');
  perform tests.assert_eq('...not closed out and no closing asked for', (v ->> 'closed_out') || '|' || (v ->> 'closeout_requested'), 'false|false');
  perform tests.assert_eq('a table that was closed out says so', public.desk_booking_money(b_closed) ->> 'closed_out', 'true');
  perform tests.login(srv_1, 'srv1@club.example');
  v := public.desk_booking_money(b_ada);
  perform tests.assert_eq('the server whose table it is sees it, and which entries are theirs', (v ->> 'level') || '|' || (v -> 'payments' -> 0 ->> 'recorded_by_me') || '|' || (v -> 'payments' -> 1 ->> 'recorded_by_me') || '|' || (v -> 'payments' -> 2 ->> 'recorded_by_me'), 'server|true|true|false');
  perform tests.login(ver_a, 'vera@club.example');
  perform tests.assert_eq('a verifier sees it', public.desk_booking_money(b_ada) ->> 'level', 'verifier');
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_raises('another server does not', format($q$select public.desk_booking_money(%L)$q$, b_ada), 'not allowed');
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff do not', format($q$select public.desk_booking_money(%L)$q$, b_ada), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('the other club''s manager does not', format($q$select public.desk_booking_money(%L)$q$, b_ada), 'not allowed');
  perform tests.assert_raises('a booking that does not exist gets the same answer', format($q$select public.desk_booking_money(%L)$q$, gen_random_uuid()), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor does not', format($q$select public.desk_booking_money(%L)$q$, b_ada), 'permission denied');

  ---------------------------------------------------------------- the verifier's queue
  perform tests.logout();
  pay_old := tests.mkpay(b_zed, 700, 'pending', false, null, interval '5 hours');
  pay_other := tests.mkpay(b_bea, 800, 'pending');
  pay_b := tests.mkpay(b_ada, 900, 'pending', true);
  perform tests.login(ver_a, 'vera@club.example');
  select array_agg(q.payment_id order by q.n) into arr from (select d.payment_id, row_number() over () as n from public.desk_pending_verifications(venue_a) d) q;
  perform tests.assert_eq('a verifier is shown the disputed payment first', arr[1], pay_disp);
  perform tests.assert_eq('...then the unchecked ones, oldest first', arr[2], pay_old);
  perform tests.assert_eq('...every unchecked payment of the club, disputed or pending', array_length(arr, 1), 13);
  perform tests.assert_true('...not the other club''s, a customer-confirmed one or one already verified', not (pay_other = any (arr)) and not (pay_conf = any (arr)) and not (pay_b = any (arr)));
  select * into r from public.desk_pending_verifications(venue_a) d where d.payment_id = pay1;
  perform tests.assert_eq('a row carries the table, the guest, the money and the evidence',
    r.confirmation_code || '|' || r.customer_name || '|' || r.table_name || '|' || r.payment_method || '|' || r.billed_amount_cents || '|' || r.amount_paid_cents || '|' || r.pos_reference || '|' || r.receipt_photo_path || '|' || r.customer_confirmation_status,
    'ADA-EVENING|Ada Evening|VIP booth|debit|3500|3000|POS-1001|' || b_ada::text || '/r1.jpg|pending');
  perform tests.assert_eq('...who recorded it, by name', coalesce(r.recorded_by_name, '-') || '|' || r.recorded_by_me::text, 'Sam Server|false');
  perform tests.assert_eq('...a payment with no known recorder has no name', (select d.recorded_by_name from public.desk_pending_verifications(venue_a) d where d.payment_id = pay_old), null::text);
  perform tests.assert_eq('...the reason given for having no receipt', (select d.missing_receipt_reason from public.desk_pending_verifications(venue_a) d where d.payment_id = pay_mgr), 'till printer is down'::text);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('the manager''s own entries are marked as theirs', (select d.recorded_by_me::text || '|' || d.recorded_by_name from public.desk_pending_verifications(venue_a) d where d.payment_id = pay_mgr), 'true|Mia Manager');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the owner sees the queue too', (select count(*) from public.desk_pending_verifications(venue_a))::int, 13);
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_raises('a server does not', format($q$select * from public.desk_pending_verifications(%L)$q$, venue_a), 'not allowed');
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff do not', format($q$select * from public.desk_pending_verifications(%L)$q$, venue_a), 'not allowed');
  perform tests.login(ver_b, 'verb@club.example');
  perform tests.assert_raises('the other club''s verifier does not', format($q$select * from public.desk_pending_verifications(%L)$q$, venue_a), 'not allowed');
  perform tests.assert_eq('...but sees their own club''s', (select count(*) from public.desk_pending_verifications(venue_b))::int, 3);
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('the other club''s manager does not', format($q$select * from public.desk_pending_verifications(%L)$q$, venue_a), 'not allowed');
  perform tests.login(rando, null);
  perform tests.assert_raises('a signed-in person with no role does not', format($q$select * from public.desk_pending_verifications(%L)$q$, venue_a), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor does not', format($q$select * from public.desk_pending_verifications(%L)$q$, venue_a), 'permission denied');

  ---------------------------------------------------------------- the night at a glance
  perform tests.logout();
  update public.site_table_bookings set checked_in_at = now() where id = b_ada;
  update public.site_table_bookings set closeout_requested_at = now() where id in (b_zed, b_closed);
  perform tests.mkline(b_ada, 'Patron', 'paid', 'awaiting_prep');
  perform tests.mkline(b_ada, 'Grey Goose', 'due_at_venue', 'served');
  perform tests.mkline(b_ada, 'Hennessy', 'paid', 'awaiting_prep', true);
  perform tests.mkline(b_ada, 'Dom Perignon', 'pending_payment', 'awaiting_prep');
  perform tests.mkline(b_zed, 'Don Julio', 'paid', 'preparing');
  perform tests.mkline(b_zed, 'Belvedere', 'paid', 'served');
  perform tests.mkline(b_open, 'Moet', 'paid', 'awaiting_prep');
  perform tests.mkline(b_open, 'Ready one', 'paid', 'ready');
  perform tests.mkline(b_open, 'On the way', 'paid', 'picked_up');
  perform tests.mkline(b_next, 'Next Bottle', 'paid', 'ready');
  perform tests.login(srv_1, 'srv1@club.example');
  perform public.create_service_request(b_ada, 'assistance');
  perform tests.login(mgr_a, 'mgra@club.example');
  req_z := public.create_service_request(b_zed, 'table_issue', 'spill');
  perform tests.login(srv_2, 'srv2@club.example');
  perform public.update_service_request(req_z, 'acknowledge');
  perform public.update_service_request(req_z, 'escalate', 'need the manager');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform public.create_service_request(b_bea, 'assistance');
  perform tests.login(mgr_a, 'mgra@club.example');

  perform tests.assert_eq('the manager sees every confirmed booking of the night and no other', (select count(*) from public.desk_table_status(venue_a, night))::int, 5);
  perform tests.assert_eq('...a table with a paid-up bill, one item still to deliver, one delivered, payments recorded and some unchecked', tests.ts_line(venue_a, night, b_ada), '0|1|1|5|3|f|f');
  perform tests.assert_eq('...one with a closing requested (open requests count whether new, taken, started or escalated)', tests.ts_line(venue_a, night, b_zed), '0|1|1|8|8|f|t');
  perform tests.assert_eq('...one with a balance still due', tests.ts_line(venue_a, night, b_open), '400|3|0|2|2|f|f');
  perform tests.assert_eq('...one that was closed out', tests.ts_line(venue_a, night, b_closed), '1000|0|0|0|0|t|t');
  perform tests.assert_eq('...and a booking in the after-midnight slot is on the night before', tests.ts_line(venue_a, night, b_late), '0|0|0|0|0|f|f');
  perform tests.assert_eq('...not a pending booking or another club''s', (select count(*) from public.desk_table_status(venue_a, night) d where d.booking_id in (b_pend, b_bea))::int, 0);
  perform tests.assert_eq('the next night has its own', (select count(*) from public.desk_table_status(venue_a, night + 1))::int, 1);
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_eq('a server gets only the tables they were given', (select count(*) from public.desk_table_status(venue_a, night))::int, 2);
  perform tests.assert_eq('...their own state', tests.ts_line(venue_a, night, b_ada), '0|1|1|5|3|f|f');
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_eq('...and the other server theirs', (select count(*) from public.desk_table_status(venue_a, night))::int, 1);
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff get nothing', format($q$select * from public.desk_table_status(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(ver_a, 'vera@club.example');
  perform tests.assert_raises('a verifier gets nothing', format($q$select * from public.desk_table_status(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('the other club''s manager gets nothing', format($q$select * from public.desk_table_status(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_raises('no night chosen', format($q$select * from public.desk_table_status(%L, null)$q$, venue_a), 'choose a night');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor gets nothing', format($q$select * from public.desk_table_status(%L, %L)$q$, venue_a, night), 'permission denied');

  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('Tonight: tables, guests, arrived, without a server, with a balance and how much, items new / in progress / delivered, payments to check / disputed, closings asked for, open requests',
    tests.tonight_line(venue_a, night), '5|10|1|2|2|1400|2|3|2|12|1|1|2');
  perform tests.assert_eq('...another night counts its own tables and items, while the club-wide numbers stay the same', tests.tonight_line(venue_a, night + 1), '1|2|0|1|1|3000|0|1|0|12|1|1|2');
  perform tests.assert_eq('...a night with nothing', tests.tonight_line(venue_a, night + 40), '0|0|0|0|0|0|0|0|0|12|1|1|2');
  perform tests.assert_eq('...payments to check plus disputed is exactly the verifier''s queue', (select count(*) from public.desk_pending_verifications(venue_a))::int, 13);
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the owner sees the same', tests.tonight_line(venue_a, night), '5|10|1|2|2|1400|2|3|2|12|1|1|2');
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_raises('a server does not get the club''s numbers', format($q$select * from public.desk_tonight(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(ver_a, 'vera@club.example');
  perform tests.assert_raises('a verifier does not', format($q$select * from public.desk_tonight(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff do not', format($q$select * from public.desk_tonight(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('the other club''s manager does not', format($q$select * from public.desk_tonight(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_raises('no night chosen', format($q$select * from public.desk_tonight(%L, null)$q$, venue_a), 'choose a night');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor does not', format($q$select * from public.desk_tonight(%L, %L)$q$, venue_a, night), 'permission denied');

  ---------------------------------------------------------------- verifying
  perform tests.logout();
  select cp.id into pay_111 from public.site_table_booking_club_payments cp where cp.booking_id = b_zed and cp.amount_paid_cents = 111;
  perform tests.assert_eq('a verifier checks a payment someone else recorded', tests.verify_as(ver_a, 'vera@club.example', pay1, '  matches the till  '), 'ok');
  perform tests.logout();
  perform tests.assert_eq('...it is marked with who checked it and the note (trimmed)', tests.verified(pay1), ver_a::text || '|matches the till');
  select * into r from public.audit_log where action = 'table_booking.club_payment_manager_verified' and entity_id = pay1::text;
  perform tests.assert_eq('...and recorded: who, at which club, which booking, the note',
    r.actor_id::text || '|' || r.actor_email || '|' || r.entity_type || '|' || (r.details ->> 'venue_id') || '|' || (r.details ->> 'booking_id') || '|' || (r.details ->> 'note'),
    ver_a::text || '|vera@club.example|site_table_booking_club_payments|' || venue_a::text || '|' || b_ada::text || '|matches the till');
  perform tests.assert_eq('it cannot be verified a second time', tests.verify_as(ver_a, 'vera@club.example', pay1), 'ERROR: this payment was already verified');
  perform tests.assert_eq('...not by a manager either', tests.verify_as(mgr_a, 'mgra@club.example', pay1, 'overwrite'), 'ERROR: this payment was already verified');
  perform tests.logout();
  perform tests.assert_eq('...and the first verification stands', tests.verified(pay1), ver_a::text || '|matches the till');
  perform tests.assert_eq('...with one entry in the log', tests.audit_count('table_booking.club_payment_manager_verified', pay1), 1);

  perform tests.assert_eq('a manager cannot verify what they recorded themselves', tests.verify_as(mgr_a, 'mgra@club.example', pay_mgr), 'ERROR: you recorded this payment, so someone else has to verify it');
  perform tests.assert_eq('...another manager can', tests.verify_as(mgr_c, 'mgrc@club.example', pay_mgr), 'ok');
  perform tests.assert_eq('the owner can verify a server''s payment', tests.verify_as(owner_u, 'owner@club.example', pay_9000, null), 'ok');
  perform tests.logout();
  perform tests.assert_eq('...without a note', tests.verified(pay_9000), owner_u::text || '|-');
  perform tests.assert_eq('a payment nobody can name the recorder of can be verified', tests.verify_as(ver_a, 'vera@club.example', pay_old), 'ok');
  perform tests.assert_eq('the customer''s answer comes first: a confirmed payment', tests.verify_as(ver_a, 'vera@club.example', pay_conf), 'ERROR: the customer already responded to this payment');
  perform tests.assert_eq('...a disputed one', tests.verify_as(ver_a, 'vera@club.example', pay_disp), 'ERROR: the customer already responded to this payment');
  perform tests.assert_eq('a note of 301 characters', tests.verify_as(ver_a, 'vera@club.example', pay_111, repeat('n', 301)), 'ERROR: keep the note to 300 characters or fewer');
  perform tests.logout();
  perform tests.assert_eq('...left it unchecked', tests.verified(pay_111), 'nobody|-');

  perform tests.assert_eq('a server cannot verify', tests.verify_as(srv_1, 'srv1@club.example', pay_111), 'ERROR: not allowed');
  perform tests.assert_eq('door staff cannot', tests.verify_as(door_a, 'doora@club.example', pay_111), 'ERROR: not allowed');
  perform tests.assert_eq('the other club''s verifier cannot', tests.verify_as(ver_b, 'verb@club.example', pay_111), 'ERROR: not allowed');
  perform tests.assert_eq('the other club''s manager cannot', tests.verify_as(mgr_b, 'mgrb@club.example', pay_111), 'ERROR: not allowed');
  perform tests.assert_eq('a rival owner cannot', tests.verify_as(rival_u, 'rival@club2.example', pay_111), 'ERROR: not allowed');
  perform tests.assert_eq('a signed-in person with no role cannot', tests.verify_as(rando, null, pay_111), 'ERROR: not allowed');
  perform tests.assert_eq('a payment that does not exist gets the same answer', tests.verify_as(ver_a, 'vera@club.example', gen_random_uuid()), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format($q$select public.desk_verify_payment(%L)$q$, pay_111), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('none of those refusals verified anything', tests.verified(pay_111), 'nobody|-');

  perform tests.login(ver_a, 'vera@club.example');
  perform tests.assert_eq('checked payments leave the queue', (select count(*) from public.desk_pending_verifications(venue_a))::int, 9);
  perform tests.assert_true('...the right ones', not exists (select 1 from public.desk_pending_verifications(venue_a) d where d.payment_id in (pay1, pay_mgr, pay_9000, pay_old)));
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('...and Tonight''s count goes down with them', tests.tonight_line(venue_a, night), '5|10|1|2|2|1400|2|3|2|8|1|1|2');
  v := public.desk_booking_money(b_ada);
  perform tests.assert_eq('a checked payment reads "verified", with its note, in the table''s money', (v -> 'payments' -> 0 ->> 'verification') || '|' || (v -> 'payments' -> 0 ->> 'manager_verified_note'), 'verified|matches the till');

  perform tests.logout();
  update public.site_table_booking_club_payments set customer_confirmation_status = 'confirmed' where id = pay_b;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('a payment the venue checked and the customer then confirmed reads "verified"', tests.verification_of(b_ada, pay_b), 'verified');
  perform tests.assert_eq('...it is not in the queue', (select count(*) from public.desk_pending_verifications(venue_a) d where d.payment_id = pay_b)::int, 0);
  perform tests.logout();
  update public.site_table_booking_club_payments set customer_confirmation_status = 'disputed' where id = pay_b;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('when the customer then disputes it, it reads "disputed"', tests.verification_of(b_ada, pay_b), 'disputed');
  perform tests.assert_eq('...it comes back into the queue', (select count(*) from public.desk_pending_verifications(venue_a) d where d.payment_id = pay_b)::int, 1);
  perform tests.assert_eq('...is counted among the disputed ones on Tonight', tests.tonight_line(venue_a, night), '5|10|1|2|2|1400|2|3|2|8|2|1|2');
  perform tests.assert_eq('...and among the unchecked ones of its table', tests.ts_line(venue_a, night, b_ada), '0|1|1|5|2|f|f');
  perform tests.assert_eq('...and it cannot be verified again', tests.verify_as(ver_a, 'vera@club.example', pay_b), 'ERROR: this payment was already verified');

  ---------------------------------------------------------------- the receipt photos themselves
  perform tests.logout();
  perform tests.assert_eq('a server can file a receipt for their own table', tests.put_receipt(srv_1, 'srv1@club.example', b_ada::text || '/s1.jpg'), 'ok');
  perform tests.assert_eq('a manager can for any table of the club', tests.put_receipt(mgr_a, 'mgra@club.example', b_open::text || '/o1.jpg'), 'ok');
  perform tests.assert_true('another server cannot', tests.put_receipt(srv_2, 'srv2@club.example', b_ada::text || '/s2.jpg') like 'ERROR: new row violates row-level security%');
  perform tests.assert_true('a server cannot file one for a table nobody was given', tests.put_receipt(srv_1, 'srv1@club.example', b_open::text || '/s3.jpg') like 'ERROR: new row violates row-level security%');
  perform tests.assert_true('a verifier cannot add one, only look', tests.put_receipt(ver_a, 'vera@club.example', b_ada::text || '/v1.jpg') like 'ERROR: new row violates row-level security%');
  perform tests.assert_true('the other club''s manager cannot', tests.put_receipt(mgr_b, 'mgrb@club.example', b_ada::text || '/m1.jpg') like 'ERROR: new row violates row-level security%');
  perform tests.assert_true('door staff cannot', tests.put_receipt(door_a, 'doora@club.example', b_ada::text || '/d1.jpg') like 'ERROR: new row violates row-level security%');
  perform tests.assert_true('a photo with no booking in its path cannot be filed', tests.put_receipt(mgr_a, 'mgra@club.example', 'loose.jpg') like 'ERROR: new row violates row-level security%');
  perform tests.assert_true('...nor one with a made-up booking', tests.put_receipt(mgr_a, 'mgra@club.example', gen_random_uuid()::text || '/x.jpg') like 'ERROR: new row violates row-level security%');
  perform tests.logout();
  perform tests.assert_eq('only the two allowed photos are there', (select count(*) from storage.objects where bucket_id = 'club-payment-receipts')::int, 2);

  perform tests.assert_eq('the server who filed it can read it', tests.see_receipts(srv_1, 'srv1@club.example', b_ada::text), 1);
  perform tests.assert_eq('the manager can', tests.see_receipts(mgr_a, 'mgra@club.example', b_ada::text), 1);
  perform tests.assert_eq('a verifier can', tests.see_receipts(ver_a, 'vera@club.example', b_ada::text), 1);
  perform tests.assert_eq('the owner can', tests.see_receipts(owner_u, 'owner@club.example', b_ada::text), 1);
  perform tests.assert_eq('another server cannot', tests.see_receipts(srv_2, 'srv2@club.example', b_ada::text), 0);
  perform tests.assert_eq('the other club''s manager cannot', tests.see_receipts(mgr_b, 'mgrb@club.example', b_ada::text), 0);
  perform tests.assert_eq('the other club''s verifier cannot', tests.see_receipts(ver_b, 'verb@club.example', b_ada::text), 0);
  perform tests.assert_eq('door staff cannot', tests.see_receipts(door_a, 'doora@club.example', b_ada::text), 0);
  perform tests.assert_eq('a signed-in person with no role cannot', tests.see_receipts(rando, null, b_ada::text), 0);
  perform tests.assert_eq('a server cannot read a table nobody gave them', tests.see_receipts(srv_1, 'srv1@club.example', b_open::text), 0);
  perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_eq('an anonymous visitor cannot', (select count(*)::int from storage.objects where bucket_id = 'club-payment-receipts'), 0);

  ---------------------------------------------------------------- the helper, hygiene and the size of the queue
  perform tests.logout();
  perform tests.assert_eq('a receipt name starts with its booking', public.receipt_booking(b_ada::text || '/x.jpg'), b_ada);
  perform tests.assert_eq('...a name with no booking has none', public.receipt_booking('x.jpg'), null::uuid);
  perform tests.assert_eq('...nor a bare booking id with no file', public.receipt_booking(b_ada::text), null::uuid);
  perform tests.assert_eq('...nor a trailing slash', public.receipt_booking(b_ada::text || '/'), null::uuid);
  perform tests.assert_eq('...nor an upper-case one', public.receipt_booking(upper(b_ada::text) || '/x.jpg'), null::uuid);
  perform tests.assert_eq('...nor nothing', public.receipt_booking(null), null::uuid);

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname in ('desk_booking_money', 'desk_record_payment', 'desk_pending_verifications', 'desk_verify_payment', 'desk_table_status', 'desk_tonight')
      and p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%';
  perform tests.assert_eq('all six functions run with their owner''s rights and pin their search path', n, 6);

  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, missing_receipt_reason)
    select b_next, 100, 100, 'cash', 'bulk' from generate_series(1, 305);
  perform tests.login(ver_a, 'vera@club.example');
  perform tests.assert_eq('a very long queue is cut off at 300, not returned whole', (select count(*) from public.desk_pending_verifications(venue_a))::int, 300);

  perform tests.logout();
  perform tests.assert_raises('a payment can never be deleted', format($q$delete from public.site_table_booking_club_payments where id = %L$q$, pay1), 'can never be deleted');
end $$;

rollback;
