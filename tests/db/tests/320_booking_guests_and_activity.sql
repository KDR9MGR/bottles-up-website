-- A booking's Guests and Activity (20261020110000_booking_guests_and_activity.sql). What matters most: only the people who may see a booking see
-- it (the club's manager or owner; for Guests also the server who was given the table), never another club, another server or the door; no e-mail
-- address or phone ever comes out; the activity is the booking's own history (its payments, bottle lines, flags, seating and every scan) and nobody
-- else's, newest first; and the guest allowance follows the same rule the guest ticket function uses.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.guests_as(p_user uuid, p_email text, p_booking uuid) returns jsonb language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return public.desk_booking_guests(p_booking);
end $$;
create function tests.activity_text(p_user uuid, p_email text, p_booking uuid, p_limit int default 100) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(action || ':' || actor, ' | ' order by at desc, action) from public.desk_booking_activity(p_booking, p_limit)), '(none)');
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000003d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000003d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000003d3';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000003d4';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000003d5';
  door_a constant uuid := '00000000-0000-0000-0000-0000000003d6';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000003d7';
  rando constant uuid := '00000000-0000-0000-0000-0000000003d8';
  org uuid; venue_a uuid; venue_b uuid; type_a uuid; slot uuid; m_s1 uuid;
  b1 uuid; b2 uuid; pay1 uuid; pay2 uuid; line1 uuid; line2 uuid; flag1 uuid; g1 uuid; g2 uuid; g3 uuid;
  j jsonb; txt text; n int; base timestamptz := now() - interval '3 hours';
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@act.example'), (mgr_a, 'mgra@act.example'), (srv_1, 'srv1@act.example'), (srv_2, 'srv2@act.example'),
    (ver_a, 'vera@act.example'), (door_a, 'doora@act.example'), (mgr_b, 'mgrb@act.example'), (rando, 'rando@act.example');
  insert into public.profiles (id, name, email) values (srv_1, 'Sam Server', 'srv1@act.example'), (mgr_a, 'Mia Manager', 'mgra@act.example'), (door_a, '  ', 'doora@act.example');

  perform tests.login(owner_u, 'owner@act.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@act.example', org, 'mgra@act.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@act.example', org, 'mgrb@act.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@act.example', org, 'srv1@act.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@act.example', org, 'srv2@act.example', 'server', venue_a, srv_2);
  perform tests.join_as(mgr_a, 'mgra@act.example', org, 'vera@act.example', 'verifier', venue_a, ver_a);
  perform tests.join_as(mgr_a, 'mgra@act.example', org, 'doora@act.example', 'door', venue_a, door_a);
  perform tests.logout();
  select id into m_s1 from public.site_memberships where user_id = srv_1 and role = 'server';

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 6, 0, 0, 9) returning id into type_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, 6, '21:00') returning id into slot;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, customer_phone, guest_count, amount_total_cents, status, confirmation_code)
    values (venue_a, type_a, slot, current_date + 10, 'Hana Holder', 'hana@act.example', '+1 555 0100', 4, 20000, 'paid', 'ACT001') returning id into b1;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue_a, type_a, slot, current_date + 10, 'Other Olga', 'olga@act.example', 2, 5000, 'paid', 'ACT002') returning id into b2;

  perform tests.login(mgr_a, 'mgra@act.example');
  perform public.assign_booking_server(b1, m_s1);
  perform tests.logout();

  -- guests: three tickets, one e-mailed, one already in
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code, created_at) values (b1, 'Gia Guest', 'gia@act.example', 'GT-ACT00001', base) returning id into g1;
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code, ticket_sent_at, checked_in_at, created_at) values (b1, 'Gus Guest', 'gus@act.example', 'GT-ACT00002', now(), now(), base + interval '1 minute') returning id into g2;
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code, created_at) values (b1, 'Gwen Guest', 'gwen@act.example', 'GT-ACT00003', base + interval '2 minutes') returning id into g3;
  update public.site_table_bookings set checked_in_at = now() where id = b1;

  ---------------------------------------------------------------- Guests: who may see them
  j := tests.guests_as(mgr_a, 'mgra@act.example', b1);
  perform tests.assert_eq('the manager sees the holder', j ->> 'holder_name', 'Hana Holder');
  perform tests.assert_eq('...and the party size the booking was made for', (j ->> 'party_size')::int, 4);
  perform tests.assert_eq('...and the table''s guest limit', (j ->> 'max_guests')::int, 6);
  perform tests.assert_eq('...and the table', j ->> 'table_name', 'VIP booth');
  perform tests.assert_true('...and whether the holder is in', (j ->> 'holder_checked_in_at') is not null);
  perform tests.assert_eq('...and the guests in the order they were invited', (select string_agg(x ->> 'name', ',' order by ord) from jsonb_array_elements(j -> 'guests') with ordinality as t(x, ord)), 'Gia Guest,Gus Guest,Gwen Guest');
  perform tests.assert_eq('...how many were invited', (j ->> 'guests_issued')::int, 3);
  perform tests.assert_eq('...how many are in', (j ->> 'guests_in')::int, 1);
  perform tests.assert_eq('...and how many more can be invited (the limit of 6, less the holder and the 3 invited)', (j ->> 'guests_left')::int, 2);
  perform tests.assert_eq('a guest says whether their ticket was e-mailed', (select (x ->> 'ticket_sent') from jsonb_array_elements(j -> 'guests') x where x ->> 'name' = 'Gus Guest'), 'true');
  perform tests.assert_eq('...and whether it was not', (select (x ->> 'ticket_sent') from jsonb_array_elements(j -> 'guests') x where x ->> 'name' = 'Gia Guest'), 'false');
  perform tests.assert_true('NO e-mail address or phone number is in the answer', j::text not like '%@%' and j::text not like '%555%');
  perform tests.assert_true('...and no guest code either', j::text not like '%GT-ACT%');
  perform tests.assert_eq('the owner sees it too', (tests.guests_as(owner_u, 'owner@act.example', b1) ->> 'holder_name'), 'Hana Holder');
  perform tests.assert_eq('the server who was given the table sees it', (tests.guests_as(srv_1, 'srv1@act.example', b1) ->> 'guests_issued')::int, 3);
  perform tests.login(srv_2, 'srv2@act.example');
  perform tests.assert_raises('another server of the same club does not', format($q$select public.desk_booking_guests(%L)$q$, b1), 'not allowed');
  perform tests.login(ver_a, 'vera@act.example');
  perform tests.assert_raises('the payment verifier does not', format($q$select public.desk_booking_guests(%L)$q$, b1), 'not allowed');
  perform tests.login(door_a, 'doora@act.example');
  perform tests.assert_raises('the door does not', format($q$select public.desk_booking_guests(%L)$q$, b1), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@act.example');
  perform tests.assert_raises('the manager of another club does not', format($q$select public.desk_booking_guests(%L)$q$, b1), 'not allowed');
  perform tests.login(rando, 'rando@act.example');
  perform tests.assert_raises('a person with no role does not', format($q$select public.desk_booking_guests(%L)$q$, b1), 'not allowed');
  perform tests.login(mgr_a, 'mgra@act.example');
  perform tests.assert_raises('a booking that does not exist is "not allowed", not "not found"', $q$select public.desk_booking_guests(gen_random_uuid())$q$, 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call it', format($q$select public.desk_booking_guests(%L)$q$, b1), 'permission denied');

  ---------------------------------------------------------------- Guests: the allowance
  perform tests.logout();
  perform tests.assert_eq('a booking with no guests invited has the whole limit to invite, less the holder', (tests.guests_as(mgr_a, 'mgra@act.example', b2) ->> 'guests_left')::int, 5);
  perform tests.assert_eq('...and an empty list, not null', jsonb_array_length(tests.guests_as(mgr_a, 'mgra@act.example', b2) -> 'guests'), 0);
  perform tests.logout();
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code) select b1, 'Extra ' || gs.i, 'x' || gs.i || '@act.example', 'GT-ACTX' || gs.i from generate_series(1, 4) as gs(i);
  perform tests.assert_eq('when more were invited than the limit allows, none are left (never negative)', (tests.guests_as(mgr_a, 'mgra@act.example', b1) ->> 'guests_left')::int, 0);

  ---------------------------------------------------------------- Activity: set up a history for b1 and one entry for b2
  perform tests.logout();
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, recorded_by) values (b1, 10000, 10000, 'cash', srv_1) returning id into pay1;
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, recorded_by) values (b2, 5000, 5000, 'cash', srv_1) returning id into pay2;
  insert into public.site_table_booking_bottles (booking_id, bottle_name, unit_price_cents, quantity, line_total_cents) values (b1, 'Grey Goose', 9000, 1, 9000) returning id into line1;
  insert into public.site_table_booking_bottles (booking_id, bottle_name, unit_price_cents, quantity, line_total_cents) values (b2, 'Patron', 9000, 1, 9000) returning id into line2;
  insert into public.site_payment_flags (payment_id, venue_id, raised_by, reason) values (pay1, venue_a, mgr_a, 'receipt looks cropped') returning id into flag1;
  delete from public.audit_log;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details, created_at) values
    (srv_1, 'srv1@act.example', 'table_booking.club_payment_recorded', 'site_table_bookings', b1::text, jsonb_build_object('venue_id', venue_a, 'payment_id', pay1, 'recorded_as', 'server', 'amount_paid_cents', 10000, 'billed_amount_cents', 10000, 'payment_method', 'cash', 'pos_reference', 'SECRET-POS'), base),
    (srv_1, 'srv1@act.example', 'table_booking.bottle_service_status_updated', 'site_table_booking_bottles', line1::text, jsonb_build_object('venue_id', venue_a, 'booking_id', b1, 'old_status', 'awaiting_prep', 'new_status', 'preparing'), base + interval '10 minutes'),
    (mgr_a, 'mgra@act.example', 'table_booking.club_payment_manager_verified', 'site_table_booking_club_payments', pay1::text, jsonb_build_object('venue_id', venue_a), base + interval '20 minutes'),
    (mgr_a, 'mgra@act.example', 'payment.flagged', 'site_payment_flags', flag1::text, jsonb_build_object('venue_id', venue_a, 'payment_id', pay1), base + interval '30 minutes'),
    (door_a, 'doora@act.example', 'booking.estimate_set', 'site_table_bookings', b1::text, jsonb_build_object('venue_id', venue_a, 'from_minutes', 10, 'to_minutes', 25, 'to_user', srv_1), base + interval '40 minutes'),
    (null, 'unknown', 'table_booking.resent', 'site_table_bookings', b1::text, '{}'::jsonb, base + interval '50 minutes'),
    -- other bookings' history, which must never appear on b1
    (srv_1, 'srv1@act.example', 'table_booking.club_payment_recorded', 'site_table_bookings', b2::text, jsonb_build_object('amount_paid_cents', 5000), base + interval '5 minutes'),
    (srv_1, 'srv1@act.example', 'table_booking.bottle_service_status_updated', 'site_table_booking_bottles', line2::text, jsonb_build_object('new_status', 'served'), base + interval '6 minutes'),
    (mgr_a, 'mgra@act.example', 'table_booking.club_payment_manager_verified', 'site_table_booking_club_payments', pay2::text, '{}'::jsonb, base + interval '7 minutes');
  insert into public.scan_attempts (ticket_code_attempted, result, booking_id, guest_ticket_id, scanned_by, created_at) values
    ('ACT001', 'ok', b1, null, door_a, base + interval '60 minutes'),
    ('GT-ACT00001', 'ok', b1, g1, door_a, base + interval '70 minutes'),
    ('GT-ACT00001', 'already_checked_in', b1, g1, door_a, base + interval '80 minutes'),
    ('ACT002', 'ok', b2, null, door_a, base + interval '65 minutes'),
    ('NOPE', 'not_found', null, null, door_a, base + interval '66 minutes');

  ---------------------------------------------------------------- Activity: the history
  txt := tests.activity_text(mgr_a, 'mgra@act.example', b1);
  perform tests.assert_eq('the manager sees the booking''s own history, newest first, naming staff by profile name',
    txt,
    'scan.already_checked_in:Staff member | scan.ok:Staff member | scan.ok:Staff member | table_booking.resent:Staff member | booking.estimate_set:Staff member | payment.flagged:Mia Manager | table_booking.club_payment_manager_verified:Mia Manager | table_booking.bottle_service_status_updated:Sam Server | table_booking.club_payment_recorded:Sam Server');
  perform tests.assert_true('a staff member with a blank profile name, or none, is "Staff member" (never an e-mail)', txt not like '%@%' and txt not like '%unknown%');
  perform tests.assert_eq('the owner sees it too', (select count(*)::int from (select tests.login(owner_u, 'owner@act.example')) x, public.desk_booking_activity(b1)), 9);
  perform tests.login(mgr_a, 'mgra@act.example');
  perform tests.assert_eq('a payment recorded for the booking carries the amount and method but not the till reference', (select (details ->> 'amount_paid_cents') || ',' || (details ->> 'payment_method') || ',' || coalesce(details ->> 'pos_reference', 'none') from public.desk_booking_activity(b1) where action = 'table_booking.club_payment_recorded'), '10000,cash,none');
  perform tests.assert_eq('a bottle line move says from what to what', (select (details ->> 'old_status') || '>' || (details ->> 'new_status') from public.desk_booking_activity(b1) where action = 'table_booking.bottle_service_status_updated'), 'awaiting_prep>preparing');
  perform tests.assert_eq('an estimate change says from what to what, and not who it was for', (select (details ->> 'from_minutes') || '>' || (details ->> 'to_minutes') || ':' || coalesce(details ->> 'to_user', 'no user') from public.desk_booking_activity(b1) where action = 'booking.estimate_set'), '10>25:no user');
  perform tests.assert_true('no activity row carries the club''s id or any key outside the list', (select bool_and(not (details ? 'venue_id') and not (details ? 'payment_id')) from public.desk_booking_activity(b1)));
  perform tests.assert_eq('a scan says whether it was a guest', (select string_agg(details ->> 'guest', ',' order by at) from public.desk_booking_activity(b1) where kind = 'scan'), 'false,true,true');
  perform tests.assert_eq('another booking has only its own history', tests.activity_text(mgr_a, 'mgra@act.example', b2), 'scan.ok:Staff member | table_booking.club_payment_manager_verified:Mia Manager | table_booking.bottle_service_status_updated:Sam Server | table_booking.club_payment_recorded:Sam Server');

  ---------------------------------------------------------------- Activity: how many, and who may
  perform tests.login(mgr_a, 'mgra@act.example');
  perform tests.assert_eq('a limit of 3 returns the 3 newest', (select count(*)::int from public.desk_booking_activity(b1, 3)), 3);
  perform tests.assert_eq('...which are the newest', (select string_agg(action, ',' order by at desc) from public.desk_booking_activity(b1, 3)), 'scan.already_checked_in,scan.ok,scan.ok');
  perform tests.assert_eq('a limit of 0 still returns one (never none by accident)', (select count(*)::int from public.desk_booking_activity(b1, 0)), 1);
  perform tests.assert_eq('no limit means up to 100', (select count(*)::int from public.desk_booking_activity(b1, null)), 9);
  perform tests.login(srv_1, 'srv1@act.example');
  perform tests.assert_raises('even the server of the table cannot read the activity', format($q$select * from public.desk_booking_activity(%L)$q$, b1), 'not allowed');
  perform tests.login(ver_a, 'vera@act.example');
  perform tests.assert_raises('the payment verifier cannot', format($q$select * from public.desk_booking_activity(%L)$q$, b1), 'not allowed');
  perform tests.login(door_a, 'doora@act.example');
  perform tests.assert_raises('the door cannot', format($q$select * from public.desk_booking_activity(%L)$q$, b1), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@act.example');
  perform tests.assert_raises('the manager of another club cannot', format($q$select * from public.desk_booking_activity(%L)$q$, b1), 'not allowed');
  perform tests.login(rando, 'rando@act.example');
  perform tests.assert_raises('a person with no role cannot', format($q$select * from public.desk_booking_activity(%L)$q$, b1), 'not allowed');
  perform tests.login(mgr_a, 'mgra@act.example');
  perform tests.assert_raises('a booking that does not exist is "not allowed"', $q$select * from public.desk_booking_activity(gen_random_uuid())$q$, 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call it', format($q$select * from public.desk_booking_activity(%L)$q$, b1), 'permission denied');

  ---------------------------------------------------------------- how they are declared
  perform tests.assert_true('both are read only, run with their owner''s rights and a fixed search path',
    (select bool_and(p.provolatile = 's' and p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('desk_booking_guests', 'desk_booking_activity')));
end $$;

rollback;
