-- After-midnight availability (20260925100000_after_midnight_availability.sql, live in production since 2026-09-25).
-- The rule: a table booked for an arrival time before 06:00 is stored under the day the guest ARRIVES (the day after the night they clicked),
-- so the picker, which asks about the NIGHT, has to look one day later for such a slot. If it did not, a table that is already booked would
-- show as free and be sold twice. Evening slots must keep looking at the clicked day, and only a PAID booking blocks a table.
-- booking_night() (20261011100000) is the inverse of this rule, so the two are checked against each other at the end.
begin;

do $$
declare
  venue uuid; other_venue uuid; t_booth uuid; t_sofa uuid; slot_eve uuid; slot_late uuid; slot_edge uuid; slot_six uuid; other_slot_late uuid;
  night date := date '2031-03-08';           -- the night the guest clicks (a Saturday)
  arrival date := date '2031-03-09';         -- the day a 1:00 AM guest actually arrives
  fn_def boolean; fn_sec boolean;

  -- the tables the picker would show as taken for (venue, night, slot)
  taken uuid[];
begin
  perform tests.logout();
  insert into public.site_venues (name) values ('Late Club') returning id into venue;
  insert into public.site_venues (name) values ('Other Club') returning id into other_venue;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue, 'Booth', 8, 0, 0, 1) returning id into t_booth;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue, 'Sofa', 6, 0, 0, 1) returning id into t_sofa;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue, 6, '22:00') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue, 6, '01:00') returning id into slot_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue, 6, '05:59') returning id into slot_edge;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue, 6, '06:00') returning id into slot_six;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (other_venue, 6, '01:00') returning id into other_slot_late;

  perform tests.assert_eq('the fixture night is a Saturday and the arrival a Sunday', extract(dow from night)::int * 10 + extract(dow from arrival)::int, 60);

  -- a paid 1:00 AM booking: stored under the ARRIVAL day (Sunday), for the Saturday night
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, t_booth, slot_late, arrival, 'Una Late', 'una@test.example', 2, 1000, 'paid', 'AM-LATE1');

  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_late) x;
  perform tests.assert_eq('asking about the Saturday NIGHT and the 1:00 AM slot shows the booth taken', taken, array[t_booth]);
  perform tests.assert_true('...and not the other table', not (t_sofa = any (taken)));

  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, arrival, slot_late) x;
  perform tests.assert_eq('asking about the Sunday NIGHT and the same 1:00 AM slot shows nothing (that is a different party)', taken, '{}'::uuid[]);

  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_eve) x;
  perform tests.assert_eq('the evening slot of that Saturday is not blocked by the 1:00 AM booking', taken, '{}'::uuid[]);

  -- a paid evening booking is stored under the day the guest clicked
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, t_sofa, slot_eve, night, 'Eve Early', 'eve@test.example', 2, 1000, 'paid', 'AM-EVE1');
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_eve) x;
  perform tests.assert_eq('an evening booking blocks its table on the clicked night', taken, array[t_sofa]);
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, arrival, slot_eve) x;
  perform tests.assert_eq('...and only on that night (an evening slot does NOT look a day later)', taken, '{}'::uuid[]);
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_late) x;
  perform tests.assert_eq('...and does not block the same night''s 1:00 AM slot', taken, array[t_booth]);

  -- the edge of the rule: 05:59 rolls the date forward, 06:00 does not
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, t_booth, slot_edge, arrival, 'Edie Edge', 'edie@test.example', 2, 1000, 'paid', 'AM-EDGE1');
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_edge) x;
  perform tests.assert_eq('a 5:59 AM slot is after midnight: the booth is taken for the Saturday night', taken, array[t_booth]);
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, t_booth, slot_six, night, 'Sam Six', 'sam@test.example', 2, 1000, 'paid', 'AM-SIX1');
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_six) x;
  perform tests.assert_eq('a 6:00 AM slot is NOT after midnight: it looks at the clicked day itself', taken, array[t_booth]);
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, arrival, slot_six) x;
  perform tests.assert_eq('...and not a day later', taken, '{}'::uuid[]);

  -- only a paid booking takes a table for good; a checkout in progress HOLDS it for 10 minutes (20261021100000), then lets go
  update public.site_table_bookings set status = 'pending' where confirmation_code = 'AM-LATE1';
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_late) x;
  perform tests.assert_eq('a checkout started just now holds the 1:00 AM table', taken, array[t_booth]);
  update public.site_table_bookings set created_at = now() - interval '11 minutes' where confirmation_code = 'AM-LATE1';
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_late) x;
  perform tests.assert_eq('a booking that has been waiting for payment longer than the hold does not block the 1:00 AM table', taken, '{}'::uuid[]);
  update public.site_table_bookings set status = 'cancelled' where confirmation_code = 'AM-LATE1';
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_late) x;
  perform tests.assert_eq('...nor does a cancelled one', taken, '{}'::uuid[]);
  update public.site_table_bookings set status = 'paid' where confirmation_code = 'AM-LATE1';

  -- other venues and other slots never leak in
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(other_venue, night, other_slot_late) x;
  perform tests.assert_eq('another venue''s 1:00 AM slot is not affected', taken, '{}'::uuid[]);
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, other_slot_late) x;
  perform tests.assert_eq('a slot that belongs to another venue never matches this venue''s bookings', taken, '{}'::uuid[]);
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, gen_random_uuid()) x;
  perform tests.assert_eq('an unknown slot shows nothing taken', taken, '{}'::uuid[]);

  -- one row per table even with several bookings
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue, t_booth, slot_late, arrival, 'Una Again', 'una2@test.example', 2, 1000, 'paid', 'AM-LATE2');
  perform tests.assert_eq('two bookings of one table type list that type once', (select count(*) from public.get_unavailable_table_types(venue, night, slot_late))::int, 1);

  -- who can ask: the public booking page asks, so visitors must be able to
  perform tests.login_anon();
  select coalesce(array_agg(x), '{}') into taken from public.get_unavailable_table_types(venue, night, slot_late) x;
  perform tests.assert_eq('a visitor (the public booking page) gets the same answer', taken, array[t_booth]);
  perform tests.logout();

  -- the inverse rule: the night a stored booking belongs to is booking_date - 1 for an after-midnight slot
  perform tests.assert_eq('booking_night() puts the stored 1:00 AM booking back on the Saturday night',
    public.booking_night(arrival, time '01:00'), night);
  perform tests.assert_eq('...and leaves an evening booking where it is', public.booking_night(night, time '22:00'), night);

  select p.prosecdef, coalesce(p.proconfig::text, '') like '%search_path=public%' into fn_sec, fn_def
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'get_unavailable_table_types';
  perform tests.assert_true('the function runs with its owner''s rights (visitors cannot read bookings) and a fixed search path', fn_sec and fn_def);
  perform tests.assert_true('...and visitors can still call it', has_function_privilege('anon', 'public.get_unavailable_table_types(uuid, date, uuid)', 'execute'));
end $$;

rollback;
