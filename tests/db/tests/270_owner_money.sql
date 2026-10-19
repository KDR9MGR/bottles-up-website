-- The owner's Money tab. What matters most: only the OWNER of the business reads its totals (a manager does not, nor another business, nor a
-- stranger); one row per club, only that club's money, only the nights asked for (the after-midnight booking belongs to the night before);
-- a correction replaces the payment it corrects; cash and card are split (a split payment's cash part is cash); counted shortages and
-- overages, open flags and closed nights are counted; the range is bounded.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int, p_paid int) returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, p_total, p_paid, 'paid', upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkpay(p_booking uuid, p_paid int, p_method text, p_by uuid, p_split jsonb default null) returns uuid language sql security definer as $$
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, split_breakdown, recorded_by, missing_receipt_reason)
  values (p_booking, p_paid, p_paid, p_method, p_split, p_by, 'seeded') returning id $$;
create function tests.money(p_user uuid, p_email text, p_org uuid, p_from date, p_to date) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(concat_ws('/', venue_name, tables, guests, booked_cents, paid_cents, balance_cents, cash_cents, card_cents, shortage_cents, overage_cents, flags_open, nights_closed), ' | ' order by venue_name)
                   from public.owner_money(p_org, p_from, p_to)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-00000000b0d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-00000000b0d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-00000000b0d3';
  other_owner constant uuid := '00000000-0000-0000-0000-00000000b0d4';
  rando constant uuid := '00000000-0000-0000-0000-00000000b0d5';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_x uuid; type_a uuid; type_b uuid; type_x uuid; slot_a uuid; slot_late uuid; slot_b uuid; slot_x uuid;
  b1 uuid; b2 uuid; b_late uuid; b_out uuid; b_b uuid; b_x uuid; p_orig uuid; p_corr uuid; p_card uuid; p_flag uuid;
  night date := current_date + 40;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@money.example'), (mgr_a, 'mgra@money.example'), (srv_1, 'srv1@money.example'), (other_owner, 'other@money.example'), (rando, 'rando@money.example');

  perform tests.login(owner_u, 'owner@money.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@money.example', org, 'mgra@money.example', 'manager', venue_a, mgr_a);
  perform tests.login(other_owner, 'other@money.example');
  org2 := public.create_organization('Other Co', 'venue_owner');
  venue_x := public.create_org_venue(org2, 'Other Club');
  perform tests.logout();

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 9) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 8, 0, 0, 9) returning id into type_b;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_x, 'Booth', 8, 0, 0, 9) returning id into type_x;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 0, '01:00', 'After midnight') returning id into slot_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_x, 6, '21:00', 'Evening') returning id into slot_x;
  b1 := tests.mkbooking(venue_a, type_a, slot_a, night, 'Ada Evening', 10000, 10000);
  b2 := tests.mkbooking(venue_a, type_a, slot_a, night + 1, 'Zed Evening', 6000, 3800);
  b_late := tests.mkbooking(venue_a, type_a, slot_late, night + 2, 'Late Lena', 2000, 2000);      -- 01:00 on night+2 = the night of night+1
  b_out := tests.mkbooking(venue_a, type_a, slot_a, night + 10, 'Far Away', 9999, 9999);           -- outside the range asked for
  b_b := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bee Bee', 5000, 5000);
  b_x := tests.mkbooking(venue_x, type_x, slot_x, night, 'Other Olga', 7777, 7777);                 -- another business
  p_orig := tests.mkpay(b1, 7000, 'cash', srv_1);
  p_corr := tests.mkpay(b1, 6000, 'cash', srv_1);
  p_card := tests.mkpay(b1, 4000, 'debit', srv_1);
  p_flag := tests.mkpay(b2, 3800, 'split', srv_1, '[{"method":"cash","cents":1000},{"method":"credit","cents":2800}]'::jsonb);
  update public.site_table_booking_club_payments set corrects_payment_id = p_orig where id = p_corr;
  perform tests.mkpay(b_b, 5000, 'cash', mgr_a);
  perform tests.mkpay(b_x, 7777, 'cash', other_owner);
  insert into public.site_payment_flags (payment_id, venue_id, raised_by, reason) values (p_card, venue_a, mgr_a, 'slip does not match');
  insert into public.site_payment_flags (payment_id, venue_id, raised_by, reason, status, resolved_by, resolved_at, resolution) values (p_flag, venue_a, mgr_a, 'checked', 'resolved', mgr_a, now(), 'confirmed_ok');
  insert into public.site_cash_handovers (venue_id, business_night, from_user, claimed_cents, status, received_by, received_at, counted_cents) values
    (venue_a, night, srv_1, 6000, 'acknowledged', mgr_a, now(), 5900), (venue_a, night + 1, srv_1, 1000, 'acknowledged', mgr_a, now(), 1200), (venue_a, night + 10, srv_1, 100, 'acknowledged', mgr_a, now(), 0),
    (venue_a, night, mgr_a, 500, 'submitted', null, null, null);
  insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, report) values (venue_a, night, 'closed', mgr_a, now(), '{}');
  insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, report, reopened_by, reopened_at, reopen_reason)
    values (venue_a, night + 1, 'reopened', mgr_a, now(), '{}', owner_u, now(), 'we forgot to count the float');

  ---------------------------------------------------------------- the figures, per club
  perform tests.assert_eq('three nights: Club A has 3 tables (the after-midnight one counts for the night before), club B 1',
    tests.money(owner_u, 'owner@money.example', org, night, night + 2),
    'Club A/3/6/18000/15800/2200/7000/6800/100/200/1/1 | Club B/1/2/5000/5000/0/5000/0/0/0/0/0');
  perform tests.assert_eq('only the nights asked for', tests.money(owner_u, 'owner@money.example', org, night, night), 'Club A/1/2/10000/10000/0/6000/4000/100/0/1/1 | Club B/1/2/5000/5000/0/5000/0/0/0/0/0');
  perform tests.assert_eq('a quiet stretch is zeros, one row per club', tests.money(owner_u, 'owner@money.example', org, night + 20, night + 25), 'Club A/0/0/0/0/0/0/0/0/0/0/0 | Club B/0/0/0/0/0/0/0/0/0/0/0');
  perform tests.assert_eq('the far-away booking and its handover only show when their night is asked for', tests.money(owner_u, 'owner@money.example', org, night + 10, night + 10), 'Club A/1/2/9999/9999/0/0/0/100/0/0/0 | Club B/0/0/0/0/0/0/0/0/0/0/0');

  ---------------------------------------------------------------- who may ask
  perform tests.assert_eq('a manager does not see the business''s totals', tests.money(mgr_a, 'mgra@money.example', org, night, night + 2), 'ERROR: not allowed');
  perform tests.assert_eq('a server does not', tests.money(srv_1, 'srv1@money.example', org, night, night + 2), 'ERROR: not allowed');
  perform tests.assert_eq('another business''s owner does not', tests.money(other_owner, 'other@money.example', org, night, night + 2), 'ERROR: not allowed');
  perform tests.assert_eq('...and sees only their own club', tests.money(other_owner, 'other@money.example', org2, night, night + 2), 'Other Club/1/2/7777/7777/0/7777/0/0/0/0/0');
  perform tests.assert_eq('a stranger does not', tests.money(rando, 'rando@money.example', org, night, night + 2), 'ERROR: not allowed');
  perform tests.assert_eq('no business', tests.money(owner_u, 'owner@money.example', null, night, night + 2), 'ERROR: not allowed');

  ---------------------------------------------------------------- the range
  perform tests.assert_eq('no nights chosen', tests.money(owner_u, 'owner@money.example', org, null, night), 'ERROR: choose the nights');
  perform tests.assert_eq('a range that runs backwards', tests.money(owner_u, 'owner@money.example', org, night + 3, night), 'ERROR: the last night is before the first');
  perform tests.assert_eq('62 nights is the most', tests.money(owner_u, 'owner@money.example', org, night, night + 62), 'ERROR: choose at most 62 nights');
  perform tests.assert_true('...62 is fine', tests.money(owner_u, 'owner@money.example', org, night, night + 61) not like 'ERROR%');

  ---------------------------------------------------------------- closed
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format('select * from public.owner_money(%L, %L, %L)', org, night, night), 'permission denied');
  perform tests.logout();
end $$;

rollback;
