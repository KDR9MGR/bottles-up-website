-- Walk-in table booking (20261020140000_desk_walkin.sql). What matters: only the club's manager or owner books one (not a server, the door, another club's manager or a
-- stranger); the options say what is really left, with an after-midnight time counted under the next calendar day; the booking is confirmed with the deposit DUE (nothing
-- marked collected), the guest seated, a confirmation QUEUED and everything logged; the last table can be sold once; every refusal is a plain sentence and changes nothing;
-- and a closed night takes no new booking.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.walkin(p_user uuid, p_email text, p_venue uuid, p_night date, p_type uuid, p_slot uuid, p_guests int, p_hours int, p_name text, p_mail text, p_phone text, p_terms boolean default true) returns text language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  r := public.desk_create_walkin(p_venue, p_night, p_type, p_slot, p_guests, p_hours, p_name, p_mail, p_phone, p_terms);
  return 'ok:' || (r ->> 'confirmation_code') || ':' || (r ->> 'deposit_cents') || ':' || (r ->> 'arrival_date') || ':left=' || (r ->> 'tables_left');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.options_text(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  -- in the order the function gives them (arrival times in the order of the night, then the tables' own order)
  return coalesce((select string_agg(x, ' | ') from (select to_char(start_time, 'HH24:MI') || '/' || table_name || '=' || booked || 'of' || inventory || '(' || available || ')' as x from public.desk_walkin_options(p_venue, p_night)) o), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000006d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000006d2';
  srv constant uuid := '00000000-0000-0000-0000-0000000006d3';
  ver constant uuid := '00000000-0000-0000-0000-0000000006d4';
  door constant uuid := '00000000-0000-0000-0000-0000000006d5';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000006d6';
  rando constant uuid := '00000000-0000-0000-0000-0000000006d7';
  org uuid; venue_a uuid; venue_b uuid; t_booth uuid; t_pair uuid; t_hour uuid; t_b uuid; t_solo uuid; s_eve uuid; s_late uuid; s_other_day uuid; s_b uuid;
  night date := current_date;
  r text; n int; j record;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@wk.example'), (mgr_a, 'mgra@wk.example'), (srv, 'srv@wk.example'), (ver, 'ver@wk.example'),
    (door, 'door@wk.example'), (mgr_b, 'mgrb@wk.example'), (rando, 'rando@wk.example');
  perform tests.login(owner_u, 'owner@wk.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@wk.example', org, 'mgra@wk.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@wk.example', org, 'mgrb@wk.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@wk.example', org, 'srv@wk.example', 'server', venue_a, srv);
  perform tests.join_as(mgr_a, 'mgra@wk.example', org, 'ver@wk.example', 'verifier', venue_a, ver);
  perform tests.join_as(mgr_a, 'mgra@wk.example', org, 'door@wk.example', 'door', venue_a, door);
  perform tests.logout();

  insert into public.site_table_types (venue_id, name, max_guests, min_guests, min_spend_cents, deposit_cents, inventory_count, sort_order) values (venue_a, 'Booth', 6, null, 0, 10000, 1, 1) returning id into t_booth;
  insert into public.site_table_types (venue_id, name, max_guests, min_guests, min_spend_cents, deposit_cents, inventory_count, sort_order) values (venue_a, 'Pair table', 4, 2, 0, 2500, 3, 2) returning id into t_pair;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count, pricing_mode, hourly_rate_cents, min_hours, sort_order) values (venue_a, 'Hourly sofa', 8, 0, 0, 2, 'hourly', 4000, 2, 3) returning id into t_hour;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 1000, 5) returning id into t_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from night)::int, '21:00') returning id into s_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from night)::int, '01:00') returning id into s_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, (extract(dow from night)::int + 3) % 7, '21:00') returning id into s_other_day;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_b, extract(dow from night)::int, '21:00') returning id into s_b;

  ---------------------------------------------------------------- who may see the options and book
  perform tests.assert_eq('the manager sees every table type at every arrival time tonight, nothing booked yet',
    tests.options_text(mgr_a, 'mgra@wk.example', venue_a, night),
    '21:00/Booth=0of1(1) | 21:00/Pair table=0of3(3) | 21:00/Hourly sofa=0of2(2) | 01:00/Booth=0of1(1) | 01:00/Pair table=0of3(3) | 01:00/Hourly sofa=0of2(2)');
  perform tests.assert_eq('the owner sees them too', split_part(tests.options_text(owner_u, 'owner@wk.example', venue_a, night), ' | ', 1), '21:00/Booth=0of1(1)');
  perform tests.assert_eq('a server does not', tests.options_text(srv, 'srv@wk.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('the payment verifier does not', tests.options_text(ver, 'ver@wk.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('the door does not', tests.options_text(door, 'door@wk.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager does not', tests.options_text(mgr_b, 'mgrb@wk.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger does not', tests.options_text(rando, 'rando@wk.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('a night that is not current is refused', tests.options_text(mgr_a, 'mgra@wk.example', venue_a, night + 5), 'ERROR: that is not a current night');
  perform tests.assert_eq('another club''s own tables are its own', tests.options_text(mgr_b, 'mgrb@wk.example', venue_b, night), '21:00/Terrace=0of5(5)');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call the options', format($q$select * from public.desk_walkin_options(%L, current_date)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...nor book', format($q$select public.desk_create_walkin(%L, current_date, %L, %L, 2, null, 'Ann', 'a@x.example', null, true)$q$, venue_a, t_booth, s_eve), 'permission denied');

  perform tests.assert_eq('a server cannot book a walk-in', tests.walkin(srv, 'srv@wk.example', venue_a, night, t_booth, s_eve, 2, null, 'Ann Walker', 'ann@wk.example', null), 'ERROR: not allowed');
  perform tests.assert_eq('the door cannot', tests.walkin(door, 'door@wk.example', venue_a, night, t_booth, s_eve, 2, null, 'Ann Walker', 'ann@wk.example', null), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.walkin(mgr_b, 'mgrb@wk.example', venue_a, night, t_booth, s_eve, 2, null, 'Ann Walker', 'ann@wk.example', null), 'ERROR: not allowed');
  perform tests.logout();
  perform tests.assert_eq('nothing was booked by any of those', (select count(*)::int from public.site_table_bookings), 0);

  ---------------------------------------------------------------- the booking
  r := tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_booth, s_eve, 4, null, '  Ann Walker ', ' Ann@Walk.Example ', '+1 555 0101');
  perform tests.assert_true('the manager books the last booth for a guest who is here: a code, the deposit, tonight, none left', r ~ ('^ok:BT-[A-HJ-NP-Z2-9]{8}:10000:' || night::text || ':left=0$'));
  perform tests.logout();
  select * into j from public.site_table_bookings where customer_email = 'ann@walk.example';
  perform tests.assert_eq('the guest''s name is tidied', j.customer_name, 'Ann Walker');
  perform tests.assert_eq('...and the email lower-cased', j.customer_email, 'ann@walk.example');
  perform tests.assert_eq('the booking is confirmed', j.status, 'paid');
  perform tests.assert_eq('the deposit is the total', j.deposit_cents, j.amount_total_cents);
  perform tests.assert_eq('NOTHING is marked collected: the deposit is due at the club', j.amount_paid_cents, 0);
  perform tests.assert_eq('bottles are for the club to take (no bottles yet)', j.bottle_payment_choice || ':' || j.bottle_subtotal_cents, 'pay_at_club:0');
  perform tests.assert_true('the guest is in, by the person who booked', j.checked_in_at is not null and j.checked_in_by = mgr_a);
  perform tests.assert_eq('...and seated, with the reason', (select method || ':' || confirmation from public.site_booking_seating where booking_id = j.id), 'manual:Walk-in guest, seated when the booking was made');
  perform tests.assert_eq('a confirmation is QUEUED, not sent', (select count(*)::int from public.site_outbox where ref_id = j.id and kind = 'walkin_confirmation' and status = 'queued'), 1);
  perform tests.assert_eq('...carrying the code', (select payload ->> 'confirmation_code' from public.site_outbox where ref_id = j.id), j.confirmation_code);
  perform tests.assert_eq('the booking and who made it are logged', (select count(*)::int from public.audit_log where action = 'booking.walkin_created' and entity_id = j.id::text and actor_id = mgr_a), 1);
  perform tests.assert_eq('the phone is kept', j.customer_phone, '+1 555 0101');
  perform tests.assert_eq('the options now show the booth gone for that time', split_part(tests.options_text(mgr_a, 'mgra@wk.example', venue_a, night), ' | ', 1), '21:00/Booth=1of1(0)');
  perform tests.assert_eq('the last table cannot be sold twice', tests.walkin(owner_u, 'owner@wk.example', venue_a, night, t_booth, s_eve, 2, null, 'Bob Late', 'bob@walk.example', null), 'ERROR: no tables of this type are left for that time');
  perform tests.assert_eq('...and the refusal booked nothing', (select count(*)::int from public.site_table_bookings where customer_email = 'bob@walk.example'), 0);
  perform tests.assert_eq('the same guest cannot be booked twice for the same time (a repeated tap or a retry after a lost answer)', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, 'Ann Walker', 'ANN@walk.example', null), 'ERROR: this guest already has a booking for that time');
  perform tests.logout();
  perform tests.assert_eq('...and it booked nothing more', (select count(*)::int from public.site_table_bookings where customer_email = 'ann@walk.example'), 1);
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_hour, s_late, night + 1, 'Mixed Case', 'MiXed@Walk.Example', 2, 8000, 'paid');
  perform tests.assert_eq('...even when the earlier booking was made online with capital letters in the address', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_late, 2, null, 'Mixed Case', 'mixed@walk.example', null), 'ERROR: this guest already has a booking for that time');
  perform tests.logout();
  r := tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_booth, s_late, 2, null, 'Cy Latecomer', 'cy@walk.example', null);
  perform tests.assert_true('the same booth at the after-midnight time is a different booking, stored under the NEXT calendar day', r ~ ('^ok:BT-[A-HJ-NP-Z2-9]{8}:10000:' || (night + 1)::text || ':left=0$'));
  perform tests.assert_eq('...and the options count it under that night', split_part(tests.options_text(mgr_a, 'mgra@wk.example', venue_a, night), ' | ', 4), '01:00/Booth=1of1(0)');
  perform tests.assert_eq('an unpaid online booking does not take a table', (select count(*)::int from public.site_table_bookings where status <> 'paid'), 0);
  perform tests.logout();
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, created_at)
    values (venue_a, t_pair, s_eve, night, 'Pending Pat', 'pat@x.example', 2, 2500, 'pending', now() - interval '11 minutes');
  perform tests.assert_eq('...so a checkout that was abandoned more than 10 minutes ago (the hold) leaves the table available', split_part(split_part(tests.options_text(mgr_a, 'mgra@wk.example', venue_a, night), ' | ', 2), '=', 2), '0of3(3)');

  perform tests.logout();
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count, sort_order) values (venue_a, 'Solo table', 2, 0, 3000, 1, 4) returning id into t_solo;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, created_at)
    values (venue_a, t_solo, s_eve, night, 'Pending Pete', 'pete@x.example', 2, 3000, 'pending', now() - interval '11 minutes');
  perform tests.assert_true('a table that only has an abandoned unpaid online booking on it can still be given to a guest who is here', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_solo, s_eve, 2, null, 'Quin Solo', 'quin@walk.example', null) like 'ok:%');
  perform tests.logout();
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_booth, s_late, night + 1, 'Oversold Ollie', 'ollie@x.example', 2, 10000, 'paid');
  perform tests.assert_true('a table sold more than it has shows none left, never a negative number', tests.options_text(mgr_a, 'mgra@wk.example', venue_a, night) like '%01:00/Booth=2of1(0)%');

  ---------------------------------------------------------------- prices
  perform tests.assert_true('a pair table takes its own flat deposit', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, 'Dee Pair', 'dee@walk.example', null) ~ ':2500:');
  perform tests.assert_true('an hourly table is the rate times the hours', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_hour, s_eve, 6, 3, 'Eve Hours', 'eve@walk.example', null) ~ ':12000:');
  perform tests.logout();
  perform tests.assert_eq('...and the hours are kept', (select hours from public.site_table_bookings where customer_email = 'eve@walk.example'), 3);

  ---------------------------------------------------------------- refusals, each a plain sentence that changes nothing
  perform tests.assert_eq('the terms must be confirmed', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, 'Fay Terms', 'fay@walk.example', null, false), 'ERROR: confirm that the guest has been told the terms and agrees to them');
  perform tests.assert_eq('...not null either', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, 'Fay Terms', 'fay@walk.example', null, null), 'ERROR: confirm that the guest has been told the terms and agrees to them');
  perform tests.assert_eq('a name is needed', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, ' A ', 'a@walk.example', null), 'ERROR: the guest''s name needs 2 to 120 characters');
  perform tests.assert_eq('...not a null one', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, null, 'a@walk.example', null), 'ERROR: the guest''s name needs 2 to 120 characters');
  perform tests.assert_eq('an email is needed', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, 'Gus Mail', 'not an email', null), 'ERROR: enter a valid email address for the guest');
  perform tests.assert_eq('...with a domain', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, 'Gus Mail', 'gus@nowhere', null), 'ERROR: enter a valid email address for the guest');
  perform tests.assert_eq('a phone number is not too long', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, 'Hal Phone', 'hal@walk.example', repeat('9', 41)), 'ERROR: the phone number is too long');
  perform tests.assert_eq('at least one guest', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 0, null, 'Ivy Zero', 'ivy@walk.example', null), 'ERROR: how many guests?');
  perform tests.assert_eq('no more than the table seats', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 5, null, 'Jo Many', 'jo@walk.example', null), 'ERROR: this table seats up to 4 guests');
  perform tests.assert_eq('no fewer than the table needs', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 1, null, 'Kai One', 'kai@walk.example', null), 'ERROR: this table needs at least 2 guests');
  perform tests.assert_eq('an hourly table needs hours', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_hour, s_eve, 2, null, 'Lee Hours', 'lee@walk.example', null), 'ERROR: this table needs between 2 and 24 hours');
  perform tests.assert_eq('...at least the minimum', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_hour, s_eve, 2, 1, 'Lee Hours', 'lee@walk.example', null), 'ERROR: this table needs between 2 and 24 hours');
  perform tests.assert_eq('...and not more than a day', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_hour, s_eve, 2, 25, 'Lee Hours', 'lee@walk.example', null), 'ERROR: this table needs between 2 and 24 hours');
  perform tests.assert_eq('another club''s table is not found', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_b, s_eve, 2, null, 'Mo Other', 'mo@walk.example', null), 'ERROR: table not found');
  perform tests.assert_eq('another club''s time is not found', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_b, 2, null, 'Mo Other', 'mo@walk.example', null), 'ERROR: arrival time not found');
  perform tests.assert_eq('a time that is not offered that night', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_other_day, 2, null, 'Mo Day', 'mo@walk.example', null), 'ERROR: that arrival time is not offered on that night');
  perform tests.assert_eq('a night that is not current', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night + 5, t_pair, s_eve, 2, null, 'Nan Far', 'nan@walk.example', null), 'ERROR: that is not a current night');
  perform tests.logout();
  perform tests.assert_eq('none of those booked anything', (select count(*)::int from public.site_table_bookings where customer_email ~ '^(fay|gus|hal|ivy|jo|kai|lee|mo|nan|a)@'), 0);

  ---------------------------------------------------------------- a closed night
  insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, report) values (venue_a, night, 'closed', mgr_a, now(), '{}'::jsonb);
  perform tests.assert_eq('a closed night takes no new booking', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, 'Ola Late', 'ola@walk.example', null), 'ERROR: this night has been closed, so no new booking can be added');
  perform tests.logout();
  update public.site_night_closes set status = 'reopened', reopened_by = owner_u, reopened_at = now() where venue_id = venue_a and business_night = night;
  perform tests.assert_true('...until it is reopened', tests.walkin(mgr_a, 'mgra@wk.example', venue_a, night, t_pair, s_eve, 2, null, 'Ola Late', 'ola@walk.example', null) like 'ok:%');

  ---------------------------------------------------------------- codes and declarations
  perform tests.logout();
  perform tests.assert_eq('every confirmation code is different', (select count(distinct confirmation_code)::int from public.site_table_bookings), (select count(*)::int from public.site_table_bookings where confirmation_code is not null));
  perform tests.assert_true('both functions run with their owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname in ('desk_walkin_options', 'desk_create_walkin')));
end $$;

rollback;
