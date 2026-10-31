-- The owner's consolidated nightly report. What matters most: only the OWNER of the business reads it (a manager, a server, another business's owner, a stranger and a visitor
-- are refused); each club comes with its own report, FINAL from the figures kept at the close and PRELIMINARY (live) otherwise, a reopened night is preliminary again; the totals
-- are exactly the sum of the clubs asked (a booking is counted once, after-midnight bookings belong to the night before, another business is never in it); more than one
-- currency means NO total; and asking changes nothing.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int, p_paid int, p_guests int default 2) returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', p_guests, p_total, p_paid, 'paid', upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkpay(p_booking uuid, p_paid int, p_method text, p_by uuid) returns uuid language sql security definer as $$
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, recorded_by, missing_receipt_reason)
  values (p_booking, p_paid, p_paid, p_method, p_by, 'seeded') returning id $$;
create function tests.orep(p_user uuid, p_email text, p_org uuid, p_night date) returns jsonb language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return public.owner_night_report(p_org, p_night);
end $$;
create function tests.orep_err(p_user uuid, p_email text, p_org uuid, p_night date) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  perform public.owner_night_report(p_org, p_night);
  return 'no error';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-00000000c0d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-00000000c0d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-00000000c0d3';
  other_owner constant uuid := '00000000-0000-0000-0000-00000000c0d4';
  rando constant uuid := '00000000-0000-0000-0000-00000000c0d5';
  mgr_x constant uuid := '00000000-0000-0000-0000-00000000c0d6';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_c uuid; venue_x uuid;
  type_a uuid; type_b uuid; type_x uuid; slot_a uuid; slot_b uuid; slot_b_late uuid; slot_x uuid;
  b_a1 uuid; b_b1 uuid; b_x uuid; b_b_late uuid; b_b_next uuid;
  night date := current_date + 50;
  r jsonb;
  n_closes bigint; n_bookings bigint; n_pays bigint;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@night.example'), (mgr_a, 'mgra@night.example'), (srv_1, 'srv1@night.example'), (other_owner, 'other@night.example'), (rando, 'rando@night.example'), (mgr_x, 'mgrx@night.example');

  perform tests.login(owner_u, 'owner@night.example');
  org := public.create_organization('Night Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  venue_c := public.create_org_venue(org, 'Club C (quiet)');
  perform tests.join_as(owner_u, 'owner@night.example', org, 'mgra@night.example', 'manager', venue_a, mgr_a);
  perform tests.login(other_owner, 'other@night.example');
  org2 := public.create_organization('Other Co', 'venue_owner');
  venue_x := public.create_org_venue(org2, 'Other Club');
  perform tests.logout();
  perform tests.join_as(other_owner, 'other@night.example', org2, 'mgrx@night.example', 'manager', venue_x, mgr_x);
  perform tests.logout();

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 9) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 8, 0, 0, 9) returning id into type_b;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_x, 'Booth', 8, 0, 0, 9) returning id into type_x;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 0, '01:00', 'After midnight') returning id into slot_b_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_x, 6, '21:00', 'Evening') returning id into slot_x;

  b_a1 := tests.mkbooking(venue_a, type_a, slot_a, night, 'Ada Evening', 10000, 10000);        -- Club A: closed, so its report is the kept snapshot, not this
  b_b1 := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bee Bee', 5000, 5000);               -- Club B: live
  b_b_late := tests.mkbooking(venue_b, type_b, slot_b_late, night + 1, 'Late Lena', 2000, 1500, 3); -- 01:00 on night+1 = the night of `night`
  b_b_next := tests.mkbooking(venue_b, type_b, slot_b, night + 1, 'Next Nia', 4000, 4000);      -- the NEXT night: not in this report
  b_x := tests.mkbooking(venue_x, type_x, slot_x, night, 'Other Olga', 7777, 7777);              -- another business
  perform tests.mkpay(b_a1, 6000, 'cash', srv_1);
  perform tests.mkpay(b_b1, 5000, 'debit', srv_1);
  perform tests.mkpay(b_x, 7777, 'cash', other_owner);
  update public.site_table_bookings set currency = 'usd' where id = b_x;                          -- the other business sells in dollars of another kind

  -- Club A closed the night: its report is the figures kept at the close (9 tables, nothing like the live 1), with one exception excused.
  insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, exceptions, exceptions_note, report) values
    (venue_a, night, 'closed', mgr_a, now(), '[{"key":"payments_unchecked","label":"payments waiting to be checked","count":3}]'::jsonb, 'counting tomorrow morning',
     jsonb_build_object('venue_name', 'Club A', 'business_night', night, 'generated_at', now(),
       'bookings', jsonb_build_object('count', 9, 'guests', 18, 'seated', 4, 'total_cents', 90000, 'paid_cents', 80000, 'balance_cents', 10000, 'discount_cents', 500),
       'payments', jsonb_build_object('count', 3, 'collected_cents', 1234, 'cash_cents', 1000, 'debit_cents', 100, 'credit_cents', 134, 'split_card_cents', 50, 'unverified', 1, 'disputed', 0, 'no_receipt', 2, 'corrections', 0),
       'cash', jsonb_build_object('handovers', 1, 'claimed_cents', 1000, 'counted_cents', 900, 'shortage_cents', 100, 'overage_cents', 0, 'waiting', 0, 'held_cents', 0),
       'flags', jsonb_build_object('raised', 2, 'open', 1, 'resolved', 1, 'by_resolution', '{}'::jsonb)));
  -- Club C had its night closed and then reopened: preliminary again.
  insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, report, reopened_by, reopened_at, reopen_reason)
    values (venue_c, night, 'reopened', mgr_a, now(), '{}', owner_u, now(), 'we forgot to count the float');

  ---------------------------------------------------------------- the report
  r := tests.orep(owner_u, 'owner@night.example', org, night);
  perform tests.assert_eq('three clubs come back, in name order', (select string_agg(e ->> 'venue_name', ' | ' order by ord) from jsonb_array_elements(r -> 'venues') with ordinality as t(e, ord)), 'Club A | Club B | Club C (quiet)');
  perform tests.assert_eq('the night and the business are named', concat_ws('/', r ->> 'org_name', r ->> 'business_night'), concat_ws('/', 'Night Co', night::text));
  perform tests.assert_eq('Club A is FINAL, from the figures kept at the close (9 tables, not the live 1)', concat_ws('/', r #>> '{venues,0,report,final}', r #>> '{venues,0,report,bookings,count}'), 'true/9');
  perform tests.assert_eq('Club B is PRELIMINARY and live: the evening booking and the after-midnight one, not the next night''s', concat_ws('/', r #>> '{venues,1,report,final}', r #>> '{venues,1,report,bookings,count}', r #>> '{venues,1,report,bookings,guests}', r #>> '{venues,1,report,bookings,total_cents}'), 'false/2/5/7000');
  perform tests.assert_eq('Club C, closed then reopened, is preliminary again and empty', concat_ws('/', r #>> '{venues,2,report,final}', r #>> '{venues,2,report,bookings,count}'), 'false/0');
  perform tests.assert_eq('how many clubs are final is stated', concat_ws('/', r ->> 'venues_final', r ->> 'venues_total'), '1/3');
  perform tests.assert_eq('the owner sees each club''s full view', (select string_agg(distinct e #>> '{report,view}', ',') from jsonb_array_elements(r -> 'venues') e), 'full');
  perform tests.assert_eq('a closed club carries what was excused', concat_ws('/', r #>> '{venues,0,report,exceptions,0,count}', r #>> '{venues,0,report,exceptions_note}'), '3/counting tomorrow morning');

  ---------------------------------------------------------------- the totals
  perform tests.assert_eq('tables, guests and seated are the clubs'' figures added (9 + 2, 18 + 5, 4 + 0)', concat_ws('/', r #>> '{totals,tables}', r #>> '{totals,guests}', r #>> '{totals,seated}'), '11/23/4');
  perform tests.assert_eq('booked, paid, balance and discounts add up (90000 + 7000, 80000 + 6500, 10000 + 500)', concat_ws('/', r #>> '{totals,booked_cents}', r #>> '{totals,paid_cents}', r #>> '{totals,balance_cents}', r #>> '{totals,discount_cents}'), '97000/86500/10500/500');
  perform tests.assert_eq('collected, cash and card add up (Club B''s 5000 debit and Club A''s 100 + 134 + 50 are card)', concat_ws('/', r #>> '{totals,collected_cents}', r #>> '{totals,cash_cents}', r #>> '{totals,card_cents}'), '6234/1000/5284');
  perform tests.assert_eq('payment exceptions add up', concat_ws('/', r #>> '{totals,unverified}', r #>> '{totals,disputed}', r #>> '{totals,no_receipt}'), '2/0/3');
  perform tests.assert_eq('cash shortages add up and open flags are counted', concat_ws('/', r #>> '{totals,cash_counted_cents}', r #>> '{totals,shortage_cents}', r #>> '{totals,flags_open}'), '900/100/1');
  perform tests.assert_eq('a night closed with exceptions is counted', r #>> '{totals,closed_with_exceptions}', '1');
  perform tests.assert_eq('one currency: the total carries its label', concat_ws('/', r ->> 'currency', r ->> 'currency_mixed', r #>> '{currencies,0}'), 'CAD/false/cad');
  perform tests.assert_true('the totals have every key the app reads', (r -> 'totals') ?& array['tables', 'guests', 'seated', 'booked_cents', 'paid_cents', 'balance_cents', 'discount_cents', 'payments', 'collected_cents', 'cash_cents', 'card_cents',
    'unverified', 'disputed', 'no_receipt', 'bottle_lines', 'bottle_value_cents', 'bottles_served', 'cash_counted_cents', 'shortage_cents', 'overage_cents', 'held_cents', 'flags_open', 'requests_open', 'alerts_unresolved', 'closed_with_exceptions']);
  perform tests.assert_eq('each club says its own currencies: A and B sold in one, quiet C in none', concat_ws('/', r #>> '{venues,0,currencies}', r #>> '{venues,1,currencies}', r #>> '{venues,2,currencies}'), '["cad"]/["cad"]/[]');
  perform tests.assert_eq('another business''s booking is nowhere in it', (select count(*) from jsonb_array_elements(r -> 'venues') e where e ->> 'venue_name' = 'Other Club'), 0::bigint);

  r := tests.orep(owner_u, 'owner@night.example', org, night + 30);
  perform tests.assert_eq('a quiet night is zeros, all three clubs preliminary', concat_ws('/', r #>> '{totals,tables}', r #>> '{totals,booked_cents}', r ->> 'venues_final', r ->> 'venues_total', r ->> 'currency'), '0/0/0/3/CAD');

  ---------------------------------------------------------------- more than one currency: no total
  perform tests.logout();
  update public.site_table_bookings set currency = 'usd' where id = b_b1;
  r := tests.orep(owner_u, 'owner@night.example', org, night);
  perform tests.assert_eq('two currencies: no total, no single label, both listed', concat_ws('/', coalesce(r ->> 'totals', 'null'), coalesce(r ->> 'currency', 'null'), r ->> 'currency_mixed', r #>> '{currencies,0}', r #>> '{currencies,1}'), 'null/null/true/cad/usd');
  perform tests.assert_eq('...each club still says which currencies it sold in', concat_ws('/', r #>> '{venues,0,currencies}', r #>> '{venues,1,currencies}'), '["cad"]/["cad", "usd"]');
  perform tests.assert_eq('...but every club''s own report is still there', concat_ws('/', jsonb_array_length(r -> 'venues'), r #>> '{venues,1,report,bookings,count}'), '3/2');
  perform tests.logout();
  update public.site_table_bookings set currency = 'cad' where id = b_b1;

  ---------------------------------------------------------------- who may ask
  perform tests.assert_eq('a manager does not (their club''s report is theirs alone)', tests.orep_err(mgr_a, 'mgra@night.example', org, night), 'ERROR: not allowed');
  perform tests.assert_eq('the only manager of a one-club business does not either (the owner''s report is not the manager''s)', tests.orep_err(mgr_x, 'mgrx@night.example', org2, night), 'ERROR: not allowed');
  perform tests.assert_eq('a server does not', tests.orep_err(srv_1, 'srv1@night.example', org, night), 'ERROR: not allowed');
  perform tests.assert_eq('another business''s owner does not', tests.orep_err(other_owner, 'other@night.example', org, night), 'ERROR: not allowed');
  perform tests.assert_eq('...and sees only their own club, in its own currency', concat_ws('/', tests.orep(other_owner, 'other@night.example', org2, night) #>> '{totals,booked_cents}', tests.orep(other_owner, 'other@night.example', org2, night) ->> 'currency'), '7777/USD');
  perform tests.assert_eq('a stranger does not', tests.orep_err(rando, 'rando@night.example', org, night), 'ERROR: not allowed');
  perform tests.assert_eq('no business', tests.orep_err(owner_u, 'owner@night.example', null, night), 'ERROR: not allowed');
  perform tests.assert_eq('no night chosen', tests.orep_err(owner_u, 'owner@night.example', org, null), 'ERROR: choose a night');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call it', format('select public.owner_night_report(%L, %L)', org, night), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- asking changes nothing
  select count(*) into n_closes from public.site_night_closes;
  select count(*) into n_bookings from public.site_table_bookings;
  select count(*) into n_pays from public.site_table_booking_club_payments;
  perform tests.orep(owner_u, 'owner@night.example', org, night);
  perform tests.orep(owner_u, 'owner@night.example', org, night + 1);
  perform tests.logout();
  perform tests.assert_true('it is read-only: the same rows after asking twice', (select count(*) from public.site_night_closes) = n_closes
    and (select count(*) from public.site_table_bookings) = n_bookings and (select count(*) from public.site_table_booking_club_payments) = n_pays);
end $$;

rollback;
