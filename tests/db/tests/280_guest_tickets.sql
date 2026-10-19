-- Guest tickets for table bookings (20260923100000_guest_tickets_and_checkin_fix.sql, live in production since 2026-09-23).
-- What matters most: the door admits the BOOKING HOLDER and each GUEST separately (a guest checking in never checks in the
-- holder or another guest), a table-booking code works at the door at all (it answered "not found" from 2026-08-21 until this
-- change), an event ticket still works, nothing is admitted that should be refused, and the guest list is closed: only a CMS admin
-- can read it and nobody can write it through the API.
-- Dates are only ever clearly in the past or clearly in the future, so this does not depend on the time of day it runs.
begin;

do $$
declare
  staff constant uuid := '00000000-0000-0000-0000-0000000000a1';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  cust constant uuid := '00000000-0000-0000-0000-0000000000a4';
  venue uuid; ttype uuid; slot_eve uuid; slot_late uuid;
  b_ok uuid; b_exp uuid; b_pend uuid; b_late uuid;
  g1 uuid; g2 uuid; g_exp uuid; g_pend uuid;
  r record; n int; j jsonb; t timestamptz; fn_def boolean; fn_sec boolean;
begin
  perform tests.logout();
  insert into public.site_venues (name) values ('Test Club') returning id into venue;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count)
    values (venue, 'VIP booth', 10, 0, 0, 5) returning id into ttype;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue, 6, '22:00') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue, 6, '01:00') returning id into slot_late;

  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, ttype, slot_eve, current_date + 30, 'Hana Holder', 'hana@test.example', 4, 10000, 'paid', 'BT-HOLD1') returning id into b_ok;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, ttype, slot_eve, current_date - 30, 'Old Owen', 'owen@test.example', 4, 10000, 'paid', 'BT-EXP1') returning id into b_exp;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, ttype, slot_eve, current_date + 30, 'Pia Pending', 'pia@test.example', 4, 10000, 'pending', 'BT-PEND1') returning id into b_pend;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, ttype, slot_late, current_date + 31, 'Lou Late', 'lou@test.example', 2, 5000, 'paid', 'BT-LATE1') returning id into b_late;

  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code) values (b_ok, 'Gia Guest', 'gia@test.example', 'GT-AAAA1111') returning id into g1;
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code, ticket_sent_at) values (b_ok, 'Gus Guest', 'gus@test.example', 'GT-BBBB2222', now()) returning id into g2;
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code) values (b_exp, 'Ex Guest', 'ex@test.example', 'GT-EXPX3333') returning id into g_exp;
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code) values (b_pend, 'Pen Guest', 'pen@test.example', 'GT-PEND4444') returning id into g_pend;

  -- a paid bottle line (shown at the door) and one still waiting for the customer's payment (not shown)
  insert into public.site_table_booking_bottles (booking_id, bottle_name, unit_price_cents, quantity, line_total_cents, payment_status)
    values (b_ok, 'Visible Vodka', 5000, 1, 5000, 'paid'), (b_ok, 'Hidden Gin', 4000, 1, 4000, 'pending_payment');

  ---------------------------------------------------------------- the table and its rows
  perform tests.assert_true('guest_tickets has row level security on',
    (select c.relrowsecurity from pg_class c where c.oid = 'public.guest_tickets'::regclass));
  select count(*) into n from pg_policies where schemaname = 'public' and tablename = 'guest_tickets';
  perform tests.assert_eq('guest_tickets has exactly one policy (admins read)', n, 1);
  perform tests.assert_eq('...and it is a select policy', (select cmd from pg_policies where schemaname = 'public' and tablename = 'guest_tickets'), 'SELECT');

  perform tests.login(admin_u, 'admin@test.example');
  perform tests.assert_eq('a CMS admin reads every guest ticket', (select count(*) from public.guest_tickets)::int, 4);
  perform tests.login(staff, 'staff@test.example');
  perform tests.assert_eq('door staff cannot read the guest list directly (they use the check-in functions)', (select count(*) from public.guest_tickets)::int, 0);
  perform tests.login(cust, 'customer@test.example');
  perform tests.assert_eq('a customer cannot read the guest list', (select count(*) from public.guest_tickets)::int, 0);
  perform tests.login(rando, 'rando@test.example');
  perform tests.assert_eq('a signed-in person with no role cannot read it', (select count(*) from public.guest_tickets)::int, 0);
  perform tests.login_anon();
  perform tests.assert_eq('a visitor cannot read it', (select count(*) from public.guest_tickets)::int, 0);

  perform tests.login(rando, 'rando@test.example');
  perform tests.assert_raises('a signed-in person cannot add a guest ticket',
    format($q$insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code) values (%L, 'X', 'x@test.example', 'GT-HACK0001')$q$, b_ok), 'row-level security');
  perform tests.login(admin_u, 'admin@test.example');
  perform tests.assert_raises('...and not even an admin can add one through the API (only the edge function can)',
    format($q$insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code) values (%L, 'X', 'x@test.example', 'GT-HACK0002')$q$, b_ok), 'row-level security');
  update public.guest_tickets set guest_name = 'Changed', checked_in_at = now() where id = g1;
  get diagnostics n = row_count;
  perform tests.assert_eq('an admin cannot change one either: the update touches no row', n, 0);
  delete from public.guest_tickets where id = g1;
  get diagnostics n = row_count;
  perform tests.assert_eq('...or delete one', n, 0);

  perform tests.login_service();
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code) values (b_late, 'Late Guest', 'late@test.example', 'GT-LATE5555');
  perform tests.assert_true('the service role (the edge function) can add a guest ticket', true);
  perform tests.logout();
  perform tests.assert_raises('a guest code is unique across all bookings',
    format($q$insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code) values (%L, 'Dup', 'dup@test.example', 'GT-AAAA1111')$q$, b_late), 'duplicate key');
  perform tests.assert_raises('a guest must belong to a booking that exists',
    $q$insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code) values (gen_random_uuid(), 'Nobody', 'n@test.example', 'GT-NONE0001')$q$, 'violates foreign key');
  delete from public.guest_tickets where guest_code = 'GT-LATE5555';
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, ttype, slot_eve, current_date + 40, 'Temp Tia', 'tia@test.example', 2, 1000, 'paid', 'BT-TEMP1');
  insert into public.guest_tickets (booking_id, guest_name, guest_email, guest_code)
    select id, 'Temp Guest', 'tg@test.example', 'GT-TEMP6666' from public.site_table_bookings where confirmation_code = 'BT-TEMP1';
  delete from public.site_table_bookings where confirmation_code = 'BT-TEMP1';
  perform tests.assert_eq('deleting an unscanned booking takes its guest tickets with it', (select count(*) from public.guest_tickets where guest_code = 'GT-TEMP6666')::int, 0);

  ---------------------------------------------------------------- the door: who may scan
  perform tests.login(rando, 'rando@test.example');
  perform tests.assert_raises('a signed-in person with no staff role cannot scan a guest ticket', $q$select * from public.checkin_ticket('GT-AAAA1111')$q$, 'not authorized');
  perform tests.assert_raises('...nor look a booking up', $q$select public.lookup_table_booking_for_checkin('BT-HOLD1')$q$, 'not authorized');
  perform tests.login(cust, 'customer@test.example');
  perform tests.assert_raises('a customer cannot scan their own booking', $q$select * from public.checkin_ticket('BT-HOLD1')$q$, 'not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot scan', $q$select * from public.checkin_ticket('GT-AAAA1111')$q$, 'not authorized');
  perform tests.assert_raises('a visitor cannot call the lookup at all (closed to visitors, not just refused inside)', $q$select public.lookup_table_booking_for_checkin('BT-HOLD1')$q$, 'permission denied');

  ---------------------------------------------------------------- the door: lookups (read only, nothing is checked in by looking)
  perform tests.login(staff, 'staff@test.example');
  j := public.lookup_table_booking_for_checkin('BT-HOLD1');
  perform tests.assert_eq('looking up a holder code finds the booking', j ->> 'found', 'true');
  perform tests.assert_eq('...as the holder', j ->> 'scanned_entity', 'holder');
  perform tests.assert_eq('...naming the holder', j ->> 'scanned_name', 'Hana Holder');
  perform tests.assert_eq('...echoing the code that was scanned', j ->> 'scanned_code', 'BT-HOLD1');
  perform tests.assert_eq('...with no guest picked out', j ->> 'scanned_guest_id', null);
  perform tests.assert_eq('...listing the whole guest roster', jsonb_array_length(j -> 'guests'), 2);
  perform tests.assert_eq('...with the table type''s capacity', (j ->> 'max_guests')::int, 10);
  perform tests.assert_eq('...and the arrival time of the slot', j ->> 'start_time', '22:00:00');
  perform tests.assert_eq('...showing the paid bottle line and not the one still waiting for payment', (select string_agg(x ->> 'bottle_name', ',') from jsonb_array_elements(j -> 'bottles') x), 'Visible Vodka');

  j := public.lookup_table_booking_for_checkin('GT-AAAA1111');
  perform tests.assert_eq('looking up a guest code finds the same booking', j ->> 'confirmation_code', 'BT-HOLD1');
  perform tests.assert_eq('...as a guest', j ->> 'scanned_entity', 'guest');
  perform tests.assert_eq('...naming that guest, not the holder', j ->> 'scanned_name', 'Gia Guest');
  perform tests.assert_eq('...with that guest picked out', j ->> 'scanned_guest_id', g1::text);
  perform tests.assert_eq('...who has not checked in', j ->> 'scanned_checked_in_at', null);
  perform tests.assert_eq('...while the booking''s own customer is still the holder', j ->> 'customer_name', 'Hana Holder');
  perform tests.assert_eq('an unknown code finds nothing', public.lookup_table_booking_for_checkin('GT-NOPE0000') ->> 'found', 'false');
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  perform tests.assert_eq('looking things up checked nobody in',
    ((select count(*) from public.site_table_bookings where id = b_ok and checked_in_at is not null) + (select count(*) from public.guest_tickets where checked_in_at is not null))::int, 0);
  perform tests.login(staff, 'staff@test.example');

  ---------------------------------------------------------------- the door: an event ticket still works
  select * into r from public.checkin_ticket('T-PAID');
  perform tests.assert_eq('an event ticket is still admitted', r.result, 'ok');
  perform tests.assert_eq('...and answers with the buyer''s name', r.customer_name, 'Ada Lovelace');
  select * into r from public.checkin_ticket('T-PAID');
  perform tests.assert_eq('...and only once', r.result, 'already_checked_in');
  select * into r from public.checkin_ticket('T-NT');
  perform tests.assert_eq('a non-transferable event ticket still asks for its entry code first', r.result, 'code_required');
  select * into r from public.checkin_ticket('T-PENDING');
  perform tests.assert_eq('an unpaid event ticket is still refused', r.result, 'not_paid');
  select * into r from public.checkin_ticket('T-ENDED');
  perform tests.assert_eq('a ticket for an event that has ended is still refused as expired', r.result, 'expired');
  select * into r from public.checkin_ticket('T-NT-OK');
  perform tests.assert_eq('a non-transferable ticket whose entry code was already verified is admitted', r.result, 'ok');
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  select count(*) into n from public.site_orders where ticket_code in ('T-NT', 'T-PENDING', 'T-ENDED') and checked_in_at is not null;
  perform tests.assert_eq('...and neither it, the unpaid ticket nor the expired one was admitted by those scans', n, 0);
  perform tests.login(staff, 'staff@test.example');

  ---------------------------------------------------------------- the door: the booking holder (this answered "not found" from 2026-08-21)
  select * into r from public.checkin_ticket('BT-HOLD1');
  perform tests.assert_eq('a table booking''s confirmation code is admitted', r.result, 'ok');
  perform tests.assert_eq('...naming the holder', r.customer_name, 'Hana Holder');
  perform tests.assert_eq('...with the venue, date and time as the context', r.event_title, 'Test Club - ' || to_char(current_date + 30, 'FMMon DD') || ' 10:00 PM');
  perform tests.assert_eq('...the table type as the item', r.tier_name, 'VIP booth');
  perform tests.assert_eq('...and the booking''s party size', r.quantity, 4);
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  perform tests.assert_true('the booking is marked checked in by the person who scanned', (select checked_in_at is not null and checked_in_by = staff from public.site_table_bookings where id = b_ok));
  perform tests.assert_eq('...and NO guest was checked in by the holder''s scan', (select count(*) from public.guest_tickets where checked_in_at is not null)::int, 0);
  perform tests.login(staff, 'staff@test.example');
  select * into r from public.checkin_ticket('BT-HOLD1');
  perform tests.assert_eq('a second scan of the holder says already checked in', r.result, 'already_checked_in');
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'BT-HOLD1' and booking_id = b_ok and guest_ticket_id is null and order_id is null and scanned_by = staff;
  perform tests.assert_eq('both holder scans are on the trail, against the booking and no guest', n, 2);
  perform tests.login(staff, 'staff@test.example');

  ---------------------------------------------------------------- the door: each guest, separately
  select * into r from public.checkin_ticket('GT-AAAA1111');
  perform tests.assert_eq('a guest ticket is admitted', r.result, 'ok');
  perform tests.assert_eq('...naming the guest', r.customer_name, 'Gia Guest');
  perform tests.assert_eq('...with the booking''s venue, date and time', r.event_title, 'Test Club - ' || to_char(current_date + 30, 'FMMon DD') || ' 10:00 PM');
  perform tests.assert_eq('...and a party of one', r.quantity, 1);
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  perform tests.assert_true('that guest is checked in, by the person who scanned', (select checked_in_at is not null and checked_in_by = staff from public.guest_tickets where id = g1));
  perform tests.assert_true('the other guest is NOT checked in', (select checked_in_at is null from public.guest_tickets where id = g2));
  perform tests.assert_true('...and the holder''s own check-in time is untouched by a guest''s scan',
    (select checked_in_at is not null from public.site_table_bookings where id = b_ok));
  perform tests.login(staff, 'staff@test.example');
  select * into r from public.checkin_ticket('GT-AAAA1111');
  perform tests.assert_eq('the same guest twice says already checked in', r.result, 'already_checked_in');
  select * into r from public.checkin_ticket('GT-BBBB2222');
  perform tests.assert_eq('the second guest can still be admitted on their own', r.result, 'ok');
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  select count(*) into n from public.scan_attempts where guest_ticket_id = g1 and booking_id = b_ok and result = 'ok' and scanned_by = staff;
  perform tests.assert_eq('the trail names WHICH guest was scanned (one admit)', n, 1);
  select count(*) into n from public.scan_attempts where guest_ticket_id = g1;
  perform tests.assert_eq('...and the repeat scan is on it too', n, 2);
  perform tests.login(staff, 'staff@test.example');

  j := public.lookup_table_booking_for_checkin('GT-AAAA1111');
  perform tests.assert_true('the lookup now shows that guest as checked in', (j ->> 'scanned_checked_in_at') is not null);
  perform tests.assert_true('...and the roster shows both guests in', (select count(*) from jsonb_array_elements(j -> 'guests') x where x ->> 'checked_in_at' is not null) = 2);
  perform tests.assert_eq('...with each guest''s email, for the door to resend a ticket', (select string_agg(x ->> 'guest_email', ',' order by x ->> 'guest_email') from jsonb_array_elements(j -> 'guests') x), 'gia@test.example,gus@test.example');

  ---------------------------------------------------------------- the door: refusals
  select * into r from public.checkin_ticket('GT-EXPX3333');
  perform tests.assert_eq('a guest of a booking whose night is long past is refused as expired', r.result, 'expired');
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  perform tests.assert_true('...and is not checked in', (select checked_in_at is null from public.guest_tickets where id = g_exp));
  perform tests.login(staff, 'staff@test.example');
  select * into r from public.checkin_ticket('BT-EXP1');
  perform tests.assert_eq('so is the holder of that booking', r.result, 'expired');
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  perform tests.assert_true('...who is not checked in either', (select checked_in_at is null from public.site_table_bookings where id = b_exp));
  perform tests.login(staff, 'staff@test.example');
  select * into r from public.checkin_ticket('GT-PEND4444');
  perform tests.assert_eq('a guest of an unpaid booking is refused', r.result, 'not_paid');
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  perform tests.assert_true('...and is not checked in', (select checked_in_at is null from public.guest_tickets where id = g_pend));
  perform tests.login(staff, 'staff@test.example');
  select * into r from public.checkin_ticket('BT-PEND1');
  perform tests.assert_eq('so is the holder of an unpaid booking', r.result, 'not_paid');
  select * into r from public.checkin_ticket('GT-NOPE0000');
  perform tests.assert_eq('an unknown code is not found', r.result, 'not_found');
  perform tests.assert_true('...and says nothing about anyone', r.customer_name is null and r.event_title is null and r.quantity is null);
  perform tests.logout();  -- the door staff cannot read these tables directly; look as the owner
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'GT-NOPE0000' and result = 'not_found' and order_id is null and booking_id is null and guest_ticket_id is null;
  perform tests.assert_eq('...but the attempt is on the trail', n, 1);
  perform tests.login(staff, 'staff@test.example');
  select count(*) into n from (select * from public.checkin_ticket('GT-NOPE0000')) s;
  perform tests.assert_eq('a refusal answers with exactly one row (it never carries on into an admit)', n, 1);
  select count(*) into n from (select * from public.checkin_ticket('GT-AAAA1111')) s;
  perform tests.assert_eq('so does a scan that is admitted or repeated', n, 1);
  perform tests.logout();  -- the door staff cannot read the trail directly; look as the owner
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'GT-NOPE0000';
  perform tests.assert_eq('...and the two unknown-code scans left exactly two rows, both not_found (none of them an admit)', n, 2);
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'GT-NOPE0000' and result = 'not_found';
  perform tests.assert_eq('...every one of them not_found', n, 2);
  perform tests.login(staff, 'staff@test.example');

  ---------------------------------------------------------------- the trail keeps what it points at
  perform tests.logout();
  perform tests.assert_raises('a booking whose guest was scanned cannot be deleted from under the trail',
    format($q$delete from public.site_table_bookings where id = %L$q$, b_ok), 'violates foreign key');

  ---------------------------------------------------------------- how the two functions are declared
  select p.prosecdef, coalesce(p.proconfig::text, '') like '%search_path=public%' into fn_sec, fn_def
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'checkin_ticket';
  perform tests.assert_true('checkin_ticket runs with its owner''s rights and a fixed search path', fn_sec and fn_def);
  select p.prosecdef, coalesce(p.proconfig::text, '') like '%search_path=public%' into fn_sec, fn_def
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'lookup_table_booking_for_checkin';
  perform tests.assert_true('the lookup does too', fn_sec and fn_def);
  perform tests.assert_true('the lookup is closed to visitors and open to signed-in people',
    not has_function_privilege('anon', 'public.lookup_table_booking_for_checkin(text)', 'execute')
    and has_function_privilege('authenticated', 'public.lookup_table_booking_for_checkin(text)', 'execute'));
end $$;

rollback;
