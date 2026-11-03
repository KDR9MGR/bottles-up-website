-- Online table checkout takes the table in one step (20261111100000_atomic_table_checkout.sql). What matters: a free table is reserved as a PENDING booking
-- with every figure stored exactly as given (each money field has its own value here, so a swapped one shows); the last table goes to one guest and the second gets
-- "none" with nothing written; the count is the shared one (paid bookings, checkouts within the 10-minute hold, active holds and unavailable tables), an old pending
-- checkout, a released or ended hold and another date, time or table type do not block; the guest's own unfinished checkout does not block them; every refusal
-- is a plain sentence that writes nothing; and only the service role can call it. (The two-guests-at-once case is tests/db/concurrency_checkout.sh.)
begin;

create function tests.reserve(
  p_venue uuid, p_type uuid, p_slot uuid, p_arrival date, p_email text,
  p_name text default 'Guest', p_guests int default 3, p_hours int default 2, p_deposit int default 10000, p_bottles int default 25000, p_tax int default 4550,
  p_fee int default 1000, p_total int default 40550, p_choice text default 'pay_ahead', p_promo uuid default null, p_discount int default 500, p_sign text default null,
  p_currency text default 'cad'
) returns text language plpgsql as $$
declare v uuid;
begin
  perform tests.login_service();
  v := public.site_reserve_table_booking(p_venue, p_type, p_slot, p_arrival, p_name, p_email, '+1 555 0100', p_guests, p_hours, p_deposit, p_bottles, p_tax, p_fee, p_total,
    p_choice, p_currency, p_promo, p_discount, p_sign);
  perform tests.logout();
  return case when v is null then 'none' else 'id' end;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  u constant uuid := '00000000-0000-0000-0000-0000000008a1';
  promo constant uuid := '00000000-0000-0000-0000-0000000008a9';
  venue_a uuid; venue_b uuid; t_one uuid; t_two uuid; t_zero uuid; t_b uuid; s_a uuid; s_a2 uuid; s_b uuid;
  d constant date := current_date + 3;
  b uuid; k uuid; n int;
begin
  insert into auth.users (id, email) values (u, 'manager@reserve.example');
  insert into public.site_venues (name) values ('Reserve Club A') returning id into venue_a;
  insert into public.site_venues (name) values ('Reserve Club B') returning id into venue_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from d)::int, '21:00') returning id into s_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from d)::int, '23:00') returning id into s_a2;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_b, extract(dow from d)::int, '21:00') returning id into s_b;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Last booth', 6, 0, 10000, 1) returning id into t_one;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Pair of tables', 4, 0, 5000, 2) returning id into t_two;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Closed off', 4, 0, 5000, 0) returning id into t_zero;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Other club table', 4, 0, 5000, 1) returning id into t_b;

  ---------------------------------------------------------------- a free table is reserved, every figure as given
  perform tests.assert_eq('a free table is reserved', tests.reserve(venue_a, t_one, s_a, d, 'ann@reserve.example', 'Ann First', 3, 2, 10000, 25000, 4550, 1000, 40550, 'pay_at_club', promo, 500, 'Happy Birthday', 'usd'), 'id');
  select id into b from public.site_table_bookings where customer_email = 'ann@reserve.example';
  perform tests.assert_eq('it is stored as a pending booking with every figure as given',
    (select concat_ws('|', venue_id = venue_a, table_type_id = t_one, time_slot_id = s_a, booking_date = d, customer_name, customer_email, customer_phone, guest_count, hours,
        deposit_cents, bottle_subtotal_cents, tax_cents, bottlesup_fee_cents, amount_total_cents, bottle_payment_choice, currency, status, promo_code_id = promo, discount_cents, bottle_sign_text)
       from public.site_table_bookings where id = b),
    't|t|t|t|Ann First|ann@reserve.example|+1 555 0100|3|2|10000|25000|4550|1000|40550|pay_at_club|usd|pending|t|500|Happy Birthday');
  perform tests.assert_eq('no payment is recorded and no code is made until Stripe says so',
    (select amount_paid_cents::text || '/' || coalesce(confirmation_code, 'none') || '/' || coalesce(stripe_checkout_session_id, 'none') from public.site_table_bookings where id = b), '0/none/none');
  perform tests.assert_eq('the shared count sees it at once', public.site_table_taken_count(t_one, s_a, d, null), 1);

  ---------------------------------------------------------------- the last table goes to one guest
  perform tests.assert_eq('the second guest is told none is left', tests.reserve(venue_a, t_one, s_a, d, 'bob@reserve.example'), 'none');
  perform tests.assert_eq('...and nothing was written for them', (select count(*)::int from public.site_table_bookings where customer_email = 'bob@reserve.example'), 0);
  perform tests.assert_eq('...and the first guest still holds it', (select count(*)::int from public.site_table_bookings where venue_id = venue_a and table_type_id = t_one), 1);
  perform tests.assert_eq('the guest''s own unfinished checkout does not block them (a retry)', tests.reserve(venue_a, t_one, s_a, d, 'ANN@reserve.example'), 'id');

  ---------------------------------------------------------------- what counts as taken
  delete from public.site_table_bookings where venue_id = venue_a;
  perform tests.assert_eq('a free table again', tests.reserve(venue_a, t_one, s_a, d, 'cy@reserve.example'), 'id');
  select id into b from public.site_table_bookings where customer_email = 'cy@reserve.example';
  update public.site_table_bookings set created_at = now() - interval '9 minutes' where id = b;
  perform tests.assert_eq('a checkout started 9 minutes ago still holds the table', tests.reserve(venue_a, t_one, s_a, d, 'di@reserve.example'), 'none');
  update public.site_table_bookings set created_at = now() - interval '11 minutes' where id = b;
  perform tests.assert_eq('a checkout started 11 minutes ago does not', tests.reserve(venue_a, t_one, s_a, d, 'di@reserve.example'), 'id');
  delete from public.site_table_bookings where customer_email = 'di@reserve.example'; -- the checkout that just succeeded would hold the table itself
  update public.site_table_bookings set status = 'paid' where id = b;
  update public.site_table_bookings set created_at = now() - interval '2 days' where id = b;
  perform tests.assert_eq('a PAID booking holds the table however old it is', tests.reserve(venue_a, t_one, s_a, d, 'ed@reserve.example'), 'none');
  update public.site_table_bookings set status = 'failed' where id = b;
  perform tests.assert_eq('a failed booking does not', tests.reserve(venue_a, t_one, s_a, d, 'ed@reserve.example'), 'id');
  delete from public.site_table_bookings where venue_id = venue_a;

  insert into public.site_table_blocks (venue_id, table_type_id, time_slot_id, booking_date, kind, quantity, reason, created_by, expires_at)
    values (venue_a, t_one, s_a, d, 'held', 1, 'Held for the owner', u, now() + interval '1 hour') returning id into k;
  perform tests.assert_eq('a table a manager is holding cannot be reserved online', tests.reserve(venue_a, t_one, s_a, d, 'flo@reserve.example'), 'none');
  update public.site_table_blocks set released_at = now(), released_by = u where id = k;
  perform tests.assert_eq('...until it is released', tests.reserve(venue_a, t_one, s_a, d, 'flo@reserve.example'), 'id');
  delete from public.site_table_bookings where venue_id = venue_a;
  update public.site_table_blocks set released_at = null, released_by = null, expires_at = now() - interval '1 minute' where id = k;
  perform tests.assert_eq('a hold that has ended does not block', tests.reserve(venue_a, t_one, s_a, d, 'gus@reserve.example'), 'id');
  delete from public.site_table_bookings where venue_id = venue_a;
  delete from public.site_table_blocks where id = k;
  insert into public.site_table_blocks (venue_id, table_type_id, time_slot_id, booking_date, kind, quantity, reason, created_by)
    values (venue_a, t_one, s_a, d, 'unavailable', 1, 'Booth being repaired', u);
  perform tests.assert_eq('a table taken out of use cannot be reserved', tests.reserve(venue_a, t_one, s_a, d, 'hal@reserve.example'), 'none');
  delete from public.site_table_blocks where venue_id = venue_a;

  ---------------------------------------------------------------- how many there are
  perform tests.assert_eq('two tables of a kind: the first guest', tests.reserve(venue_a, t_two, s_a, d, 'i1@reserve.example'), 'id');
  perform tests.assert_eq('...the second guest', tests.reserve(venue_a, t_two, s_a, d, 'i2@reserve.example'), 'id');
  perform tests.assert_eq('...the third is told none is left', tests.reserve(venue_a, t_two, s_a, d, 'i3@reserve.example'), 'none');
  perform tests.assert_eq('a kind with no tables is never reserved', tests.reserve(venue_a, t_zero, s_a, d, 'j1@reserve.example'), 'none');

  ---------------------------------------------------------------- other dates, times, tables and clubs are separate
  perform tests.assert_eq('the last booth on another date is free', tests.reserve(venue_a, t_one, s_a, d + 7, 'k1@reserve.example'), 'id');
  perform tests.assert_eq('...at another arrival time', tests.reserve(venue_a, t_one, s_a2, d, 'k2@reserve.example'), 'id');
  perform tests.assert_eq('...and another club''s table', tests.reserve(venue_b, t_b, s_b, d, 'k3@reserve.example'), 'id');
  perform tests.assert_eq('the first date is still taken by the first of them', tests.reserve(venue_a, t_one, s_a, d + 7, 'k4@reserve.example'), 'none');

  ---------------------------------------------------------------- refusals say why and write nothing
  select count(*)::int into n from public.site_table_bookings;
  perform tests.assert_eq('another club''s table is not found', tests.reserve(venue_b, t_one, s_b, d, 'm1@reserve.example'), 'ERROR: table not found');
  perform tests.assert_eq('a table that does not exist is not found', tests.reserve(venue_a, gen_random_uuid(), s_a, d, 'm1@reserve.example'), 'ERROR: table not found');
  perform tests.assert_eq('another club''s arrival time is not found', tests.reserve(venue_a, t_two, s_b, d, 'm2@reserve.example'), 'ERROR: arrival time not found');
  perform tests.assert_eq('an arrival time that does not exist is not found', tests.reserve(venue_a, t_two, gen_random_uuid(), d, 'm2@reserve.example'), 'ERROR: arrival time not found');
  perform tests.assert_eq('an arrival date is needed', tests.reserve(venue_a, t_two, s_a, null, 'm3@reserve.example'), 'ERROR: an arrival date is needed');
  perform tests.assert_eq('an e-mail address is needed', tests.reserve(venue_a, t_two, s_a, d + 14, '   '), 'ERROR: an e-mail address is needed');
  perform tests.assert_eq('...a missing one too', tests.reserve(venue_a, t_two, s_a, d + 14, null), 'ERROR: an e-mail address is needed');
  perform tests.assert_eq('none of those wrote a booking', (select count(*)::int from public.site_table_bookings), n);

  ---------------------------------------------------------------- who may call it
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call it', format('select public.site_reserve_table_booking(%L, %L, %L, %L, ''x'', ''v@reserve.example'', null, 2, null, 1, 0, 0, 0, 1, ''pay_ahead'', ''cad'', null, 0, null)', venue_a, t_two, s_a, d + 20), 'permission denied');
  perform tests.logout();
  perform tests.login(u, 'manager@reserve.example');
  perform tests.assert_raises('a signed-in person cannot call it', format('select public.site_reserve_table_booking(%L, %L, %L, %L, ''x'', ''v@reserve.example'', null, 2, null, 1, 0, 0, 0, 1, ''pay_ahead'', ''cad'', null, 0, null)', venue_a, t_two, s_a, d + 20), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('so no booking came of it', (select count(*)::int from public.site_table_bookings where customer_email = 'v@reserve.example'), 0);
  perform tests.assert_true('it runs with its owner''s rights and a fixed search path',
    (select p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%' from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname = 'site_reserve_table_booking'));
end $$;

rollback;
