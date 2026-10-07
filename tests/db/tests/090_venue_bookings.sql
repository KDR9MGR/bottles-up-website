-- The owner's read-only view of table bookings. What matters most: only the owner or a manager of THIS venue can read its
-- bookings, one venue's bookings never appear under another, a booking lands on the right business night (a 1:00 AM table
-- belongs to the night before), and the answer is bounded.
begin;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000000d2';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000d3';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000d4';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000000d5';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_r uuid; tok text; r record; n int; txt text; b_dummy boolean;
  type_a uuid; type_b uuid; slot_eve uuid; slot_late uuid; slot_0559 uuid; slot_0600 uuid; slot_b uuid;
  night date := current_date + 10;  -- a Saturday night, say
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@club.example'), (mgr_a, 'mgra@club.example'), (rival_u, 'rival@club2.example'),
    (door_a, 'doora@club.example'), (mgr_b, 'mgrb@club.example');

  ---------------------------------------------------------------- set up: two clubs of one business, a rival, staff
  perform tests.login(owner_u, 'owner@club.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@club2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  venue_r := public.create_org_venue(org2, 'Rival Club');
  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'mgra@club.example', 'manager', venue_a) i;
  perform tests.login(mgr_a, 'mgra@club.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'mgrb@club.example', 'manager', venue_b) i;
  perform tests.login(mgr_b, 'mgrb@club.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'doora@club.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@club.example'); perform public.accept_invitation(tok);

  -- Production allows a 'cancelled' booking status (the CMS and the generated types both use it); the committed constraint does not
  -- list it. Drop it for this test only (rolled back with everything else) so a cancelled booking can be shown.
  perform tests.logout();
  alter table public.site_table_bookings drop constraint site_table_bookings_status_check;

  -- Tables, arrival times (an evening one, an after-midnight one, and the two either side of the 06:00 line), and bookings.
  perform tests.logout();
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 5) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 5) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 0, '01:00', 'Late') returning id into slot_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, 0, '05:59') returning id into slot_0559;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, 0, '06:00') returning id into slot_0600;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_b, 6, '21:00') returning id into slot_b;

  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, customer_phone, guest_count, amount_total_cents, deposit_cents, status, confirmation_code, created_at) values
    (venue_a, type_a, slot_late, night + 1, 'Cleo Late',   'cleo@test.example', '+15550001', 3, 30000, 5000, 'paid',    'CODE-LATE', now() - interval '3 days'),   -- after midnight: belongs to the night BEFORE its stored date
    (venue_a, type_a, slot_eve,  night,     'Zed Evening', 'zed@test.example',  null,        2, 20000, 0, 'paid',       'CODE-ZED',  now() - interval '2 days'),   -- inserted before Ada on purpose: the order must come from the name, not from insertion
    (venue_a, type_a, slot_eve,  night,     'Ada Evening', 'ada@test.example',  '+15550002', 4, 40000, 10000, 'paid',   'CODE-ADA',  now() - interval '2 days'),
    (venue_a, type_a, slot_eve,  night + 1, 'Next Night',  'next@test.example', null,        6, 60000, 0, 'pending',    null,        now() - interval '1 days'),
    (venue_a, type_a, slot_0559, night + 1, 'Almost Six',  'six@test.example',  null,        2, 1000,  0, 'refunded',   null,        now()),            -- 05:59 on night+1 = night's tail
    (venue_a, type_a, slot_0600, night + 1, 'Six Sharp',   'six2@test.example', null,        2, 1000,  0, 'cancelled',  null,        now()),            -- 06:00 on night+1 = night+1 itself
    (venue_a, type_a, slot_eve,  night + 40, 'Far Away',   'far@test.example',  null,        2, 1000,  0, 'paid',       null,        now()),
    (venue_b, type_b, slot_b,    night,     'Bea Clubb',   'bea@test.example',  null,        2, 1000,  0, 'paid',       'CODE-BEA',  now());

  ---------------------------------------------------------------- who may read
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the owner reads a night of their own club', (select count(*) from public.list_venue_bookings(venue_a, night, night))::int, 4);
  perform tests.assert_eq('...and their other club separately', (select count(*) from public.list_venue_bookings(venue_b, night, night))::int, 1);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('a manager of the club reads it too', (select count(*) from public.list_venue_bookings(venue_a, night, night))::int, 4);
  perform tests.assert_raises('...but not the business''s other club', format($q$select * from public.list_venue_bookings(%L, %L, %L)$q$, venue_b, night, night), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('a manager of the other club cannot read Club A', format($q$select * from public.list_venue_bookings(%L, %L, %L)$q$, venue_a, night, night), 'not allowed');
  perform tests.login(rival_u, 'rival@club2.example');
  perform tests.assert_raises('a rival owner cannot', format($q$select * from public.list_venue_bookings(%L, %L, %L)$q$, venue_a, night, night), 'not allowed');
  perform tests.assert_eq('...and sees nothing under their own venue either', (select count(*) from public.list_venue_bookings(venue_r, night, night))::int, 0);
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff of the club cannot (they scan, they do not browse every guest''s contact details)', format($q$select * from public.list_venue_bookings(%L, %L, %L)$q$, venue_a, night, night), 'not allowed');
  perform tests.login(rando);
  perform tests.assert_raises('a signed-in person with no role cannot', format($q$select * from public.list_venue_bookings(%L, %L, %L)$q$, venue_a, night, night), 'not allowed');
  perform tests.assert_raises('a venue that does not exist is refused', format($q$select * from public.list_venue_bookings(%L, %L, %L)$q$, gen_random_uuid(), night, night), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format($q$select * from public.list_venue_bookings(%L, %L, %L)$q$, venue_a, night, night), 'permission denied');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the bookings table itself stays closed to an owner (this function is the only way in)', (select count(*) from public.site_table_bookings where venue_id = venue_a)::int, 0);

  ---------------------------------------------------------------- one venue never shows another's bookings
  select string_agg(customer_name, ',' order by customer_name) into txt from public.list_venue_bookings(venue_a, night - 5, night + 5);
  perform tests.assert_eq('Club A lists none of Club B''s guests', position('Bea' in txt), 0);
  select string_agg(customer_name, ',' order by customer_name) into txt from public.list_venue_bookings(venue_b, night - 5, night + 5);
  perform tests.assert_eq('...and Club B lists only its own', txt, 'Bea Clubb');

  ---------------------------------------------------------------- the business night
  select string_agg(customer_name, ',' order by customer_name) into txt from public.list_venue_bookings(venue_a, night, night);
  perform tests.assert_eq('a night holds its evening guests and the after-midnight tail stored under the next date, down to 05:59',
    txt, 'Ada Evening,Almost Six,Cleo Late,Zed Evening');
  select string_agg(customer_name, ',' order by customer_name) into txt from public.list_venue_bookings(venue_a, night + 1, night + 1);
  perform tests.assert_eq('06:00 belongs to the next night itself, together with that night''s own evening booking', txt, 'Next Night,Six Sharp');
  select string_agg(night_date::text, ',') into txt from public.list_venue_bookings(venue_a, night, night) where customer_name = 'Cleo Late';
  perform tests.assert_eq('the row says which night it belongs to, not the calendar date it is stored under', txt, night::text);
  perform tests.assert_eq('the stored date is not what a range filters on: night + 1 does not list Cleo', (select count(*) from public.list_venue_bookings(venue_a, night + 1, night + 1) where customer_name = 'Cleo Late')::int, 0);
  perform tests.assert_eq('a range includes both ends', (select count(*) from public.list_venue_bookings(venue_a, night, night + 1))::int, 6);
  perform tests.assert_eq('...and excludes what is outside it', (select count(*) from public.list_venue_bookings(venue_a, night + 2, night + 30))::int, 0);
  perform tests.assert_eq('a booking 40 nights on is found when the range reaches it', (select count(*) from public.list_venue_bookings(venue_a, night + 40, night + 40))::int, 1);
  perform tests.assert_eq('the night before the first booking does not list the evening guests', (select count(*) from public.list_venue_bookings(venue_a, night - 1, night - 1))::int, 0);
  perform tests.assert_eq('the booking_night rule itself: 05:59 is the night before', public.booking_night('2026-10-11', '05:59:59'), '2026-10-10'::date);
  perform tests.assert_eq('...06:00 is the same date', public.booking_night('2026-10-11', '06:00:00'), '2026-10-11'::date);
  perform tests.assert_eq('...midnight is the night before', public.booking_night('2026-03-01', '00:00:00'), '2026-02-28'::date);
  perform tests.assert_eq('...and across a year end', public.booking_night('2027-01-01', '01:30:00'), '2026-12-31'::date);
  perform tests.assert_eq('...an evening slot is its own date', public.booking_night('2026-10-10', '23:59:59'), '2026-10-10'::date);

  ---------------------------------------------------------------- the order, and what each row carries
  select string_agg(customer_name, ',' order by ord) into txt from (select customer_name, row_number() over () ord from public.list_venue_bookings(venue_a, night, night)) x;
  perform tests.assert_eq('a night lists the evening first (by name within a time), then the after-midnight tail, earliest first', txt, 'Ada Evening,Zed Evening,Cleo Late,Almost Six');
  select string_agg(customer_name, ',' order by ord) into txt from (select customer_name, row_number() over () ord from public.list_venue_bookings(venue_a, night, night + 1)) x;
  perform tests.assert_eq('over several nights, the earlier night comes first whatever the times', txt, 'Ada Evening,Zed Evening,Cleo Late,Almost Six,Six Sharp,Next Night');
  select * into r from public.list_venue_bookings(venue_a, night, night) where customer_name = 'Ada Evening';
  perform tests.assert_eq('a row carries the table and arrival time names', r.table_name || '|' || r.slot_label || '|' || r.start_time, 'VIP booth|Evening|21:00:00');
  perform tests.assert_eq('...the party and what was booked', r.guest_count || '|' || r.amount_total_cents || '|' || r.deposit_cents, '4|40000|10000');
  perform tests.assert_eq('...the contact details the venue needs to reach the guest', r.customer_email || '|' || r.customer_phone, 'ada@test.example|+15550002');
  perform tests.assert_eq('...the confirmation code, so staff can find the booking', r.confirmation_code, 'CODE-ADA');
  perform tests.assert_true('...and not checked in yet', r.checked_in_at is null);
  perform tests.assert_eq('the status is shown as stored: paid', (select status from public.list_venue_bookings(venue_a, night, night) where customer_name = 'Ada Evening'), 'paid');
  perform tests.assert_eq('...refunded', (select status from public.list_venue_bookings(venue_a, night, night) where customer_name = 'Almost Six'), 'refunded');
  perform tests.assert_eq('...pending', (select status from public.list_venue_bookings(venue_a, night + 1, night + 1) where customer_name = 'Next Night'), 'pending');
  perform tests.assert_eq('...and cancelled, even though the committed schema does not list that value', (select status from public.list_venue_bookings(venue_a, night + 1, night + 1) where customer_name = 'Six Sharp'), 'cancelled');

  perform tests.logout();
  update public.site_table_bookings set checked_in_at = now() where confirmation_code = 'CODE-ADA';
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_true('a checked-in guest is marked so', (select checked_in_at is not null from public.list_venue_bookings(venue_a, night, night) where customer_name = 'Ada Evening'));

  ---------------------------------------------------------------- bounded answers
  perform tests.assert_raises('an end before the start is refused', format($q$select * from public.list_venue_bookings(%L, %L, %L)$q$, venue_a, night, night - 1), 'before the start');
  perform tests.assert_raises('no start date is refused', format($q$select * from public.list_venue_bookings(%L, null, %L)$q$, venue_a, night), 'choose a start');
  perform tests.assert_raises('no end date is refused', format($q$select * from public.list_venue_bookings(%L, %L, null)$q$, venue_a, night), 'choose a start');
  perform tests.assert_eq('93 nights is allowed', (select count(*) from public.list_venue_bookings(venue_a, night, night + 92))::int, 7);
  perform tests.assert_raises('94 nights is not', format($q$select * from public.list_venue_bookings(%L, %L, %L)$q$, venue_a, night, night + 93), 'at most 93 nights');
  perform tests.assert_raises('years of history cannot be asked for at once', format($q$select * from public.list_venue_bookings(%L, '2020-01-01', '2026-12-31')$q$, venue_a), 'at most 93 nights');

  perform tests.logout();
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    select venue_a, type_a, slot_eve, night + 20, 'Crowd ' || g, 'crowd' || g || '@test.example', 2, 100, 'paid' from generate_series(1, 1005) g;
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('a night with more than 1000 bookings returns the first 1000, not all of them', (select count(*) from public.list_venue_bookings(venue_a, night + 20, night + 20))::int, 1000);

  ---------------------------------------------------------------- hygiene
  perform tests.logout();
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname in ('booking_night', 'list_venue_bookings') and coalesce(p.proconfig::text, '') like '%search_path=public%';
  perform tests.assert_eq('both functions pin their search path', n, 2);
  select p.prosecdef into b_dummy from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'list_venue_bookings';
  perform tests.assert_true('the reader runs with its owner''s rights, after checking the caller', b_dummy);
end $$;

rollback;
