-- Payout settings and ledger (20261025100000_payout_settings_and_ledger.sql). What matters:
--   * only BottlesUp admins change the settings, overrides, accounts and the ledger, and only they see all of it; an owner or organizer reads ONLY their own business, read-only;
--   * the percentage is not set until an admin chooses it, and no payout can be worked out before that;
--   * eligible money is what a booking took in ONLINE (not what the club recorded at the club), less BottlesUp's own customer fee, for a paid booking whose night is past the waiting days
--     and that no payout has taken; cash and the club's own card machine are never paid out again; a booking is in ONE payout at a time, and a cancelled payout frees its bookings;
--   * a payout is Paid only with a transfer reference, and never changes after it is Paid; an account is never stored as a full number;
--   * every refusal is a plain sentence and changes nothing; the tables cannot be read or written by the app.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
  perform tests.logout();
end $$;
-- the payout functions count days in Toronto, so the test does too (the scratch database may be in another time zone)
create function tests.today() returns date language sql stable as $$ select (now() at time zone 'America/Toronto')::date $$;
create function tests.try(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into r;
  perform tests.logout();
  return case when r is null or r = '' then 'ok' else r end;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.runj(p_user uuid, p_email text, p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into r;
  perform tests.logout();
  return r;
end $$;
-- a paid booking: the night (days from today), what it took, the club's own recorded payment (cash), BottlesUp's customer fee, and whether it was paid online
create function tests.mkpaid(p_venue uuid, p_type uuid, p_slot uuid, p_days_ago int, p_name text, p_paid int, p_fee int, p_club int default 0, p_online boolean default true, p_status text default 'paid') returns uuid language plpgsql security definer as $$
declare v_id uuid;
begin
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, bottlesup_fee_cents,
                                          status, confirmation_code, stripe_payment_intent_id)
  values (p_venue, p_type, p_slot, tests.today() - p_days_ago, p_name, lower(replace(p_name, ' ', '')) || '@po.example', 2, p_paid, p_paid, p_fee, p_status, 'PO-' || upper(replace(p_name, ' ', '')),
          case when p_online then 'pi_' || replace(p_name, ' ', '') end) returning id into v_id;
  if p_club > 0 then
    insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, missing_receipt_reason) values (v_id, p_club, p_club, 'cash', 'recorded at the club');
  end if;
  return v_id;
end $$;
create function tests.eligible_text(p_org uuid, p_days int default 40) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login('00000000-0000-0000-0000-0000000000a2', 'admin@test.example');
  select coalesce(string_agg(org_name || ' ' || bookings || ' bookings gross=' || gross_cents || ' commission=' || commission_cents || ' net=' || net_cents, ' | ' order by org_name), '(none)') into r
    from public.cms_payout_eligible(tests.today() - p_days, tests.today()) where org_id = p_org;
  perform tests.logout();
  return coalesce(r, '(none)');
end $$;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  owner_a constant uuid := '00000000-0000-0000-0000-000000000cd1';
  owner_b constant uuid := '00000000-0000-0000-0000-000000000cd2';
  mgr_a constant uuid := '00000000-0000-0000-0000-000000000cd3';
  org_u constant uuid := '00000000-0000-0000-0000-000000000cd4';
  rando constant uuid := '00000000-0000-0000-0000-000000000cd5';
  owner_c constant uuid := '00000000-0000-0000-0000-000000000cd6';
  org_c uuid; venue_c uuid; t_c uuid; s_c uuid; c_odd uuid; c_item uuid;
  org_a uuid; org_b uuid; org_o uuid; venue_a uuid; venue_b uuid; t_a uuid; t_b uuid; s_a uuid; s_b uuid;
  ba1 uuid; ba2 uuid; ba3 uuid; ba4 uuid; ba5 uuid; ba6 uuid; ba7 uuid; bb1 uuid; bb2 uuid;
  i1 uuid; i2 uuid; i3 uuid; j jsonb; r text; k record; n int;
  everyone text[] := array['owner_a@po.example', 'mgra@po.example', 'org@po.example', 'rando@po.example'];
  who text;
begin
  insert into auth.users (id, email) values (owner_a, 'owner_a@po.example'), (owner_b, 'owner_b@po.example'), (mgr_a, 'mgra@po.example'), (org_u, 'org@po.example'), (rando, 'rando@po.example'), (owner_c, 'owner_c@po.example');
  perform tests.login(owner_a, 'owner_a@po.example');
  org_a := public.create_organization('Payout Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org_a, 'Club A');
  perform tests.login(owner_b, 'owner_b@po.example');
  org_b := public.create_organization('Other Club Co', 'venue_owner');
  venue_b := public.create_org_venue(org_b, 'Club B');
  perform tests.login(owner_c, 'owner_c@po.example');
  org_c := public.create_organization('Third Club Co', 'venue_owner');
  venue_c := public.create_org_venue(org_c, 'Club C');
  perform tests.login(org_u, 'org@po.example');
  org_o := public.create_organization('Night Events', 'organizer');
  perform tests.logout();
  perform tests.join_as(owner_a, 'owner_a@po.example', org_a, 'mgra@po.example', 'manager', venue_a, mgr_a);
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 6, 0, 0, 100) returning id into t_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 100) returning id into t_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, 1, '21:00') returning id into s_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_b, 1, '21:00') returning id into s_b;
  ba1 := tests.mkpaid(venue_a, t_a, s_a, 10, 'Eligible One', 10000, 500);
  ba2 := tests.mkpaid(venue_a, t_a, s_a, 10, 'Part At Club', 8000, 0, 3000);
  ba3 := tests.mkpaid(venue_a, t_a, s_a, 0, 'Tonight Booking', 7000, 0);
  ba4 := tests.mkpaid(venue_a, t_a, s_a, 3, 'Past The Hold', 4000, 200);
  ba5 := tests.mkpaid(venue_a, t_a, s_a, 10, 'Club Only', 6000, 0, 0, false);
  ba6 := tests.mkpaid(venue_a, t_a, s_a, 10, 'Still Pending', 5000, 0, 0, true, 'pending');
  ba7 := tests.mkpaid(venue_a, t_a, s_a, 10, 'Fully Refunded', 0, 0);
  bb1 := tests.mkpaid(venue_b, t_b, s_b, 10, 'Other Eligible', 20000, 0);
  bb2 := tests.mkpaid(venue_b, t_b, s_b, 0, 'Other Tonight', 1000, 0);
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_c, 'Lounge', 4, 0, 0, 100) returning id into t_c;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_c, 1, '21:00') returning id into s_c;
  c_odd := tests.mkpaid(venue_c, t_c, s_c, 10, 'Odd Amount', 12345, 0);
  perform tests.mkpaid(venue_c, t_c, s_c, 10, 'Round Amount', 20000, 0);

  ---------------------------------------------------------------- 1. the settings: only BottlesUp admins, and valid ones
  perform tests.assert_eq('the settings start as manual transfer, Wednesday, 2 days, no percentage chosen', tests.try(admin_u, 'admin@test.example', $q$select (select payout_method || '/' || payout_weekday || '/' || hold_days || '/' || commission_bps || '/' || commission_set from public.cms_payout_settings())$q$), 'manual_transfer/3/2/0/false');
  foreach who in array everyone || array['owner_b@po.example'] loop
    perform tests.assert_eq('the settings are refused to ' || who, tests.try((select id from auth.users where email = who), who, $q$select count(*)::text from public.cms_payout_settings()$q$), 'ERROR: not allowed');
    perform tests.assert_eq('...and so is changing them, for ' || who, tests.try((select id from auth.users where email = who), who, $q$select public.cms_save_payout_settings('{"commission_bps":1000}'::jsonb)::text$q$), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot change them', $q$select public.cms_save_payout_settings('{"commission_bps":1000}'::jsonb)$q$, 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('a percentage above 100 is refused', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"commission_bps":10001}'::jsonb)::text$q$), 'ERROR: BottlesUp''s percentage (in hundredths of a percent) must be between 0 and 10000');
  perform tests.assert_eq('a weekday must be 0 to 6', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"payout_weekday":7}'::jsonb)::text$q$), 'ERROR: the payout weekday must be between 0 and 6');
  perform tests.assert_eq('the waiting days at most 30', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"hold_days":31}'::jsonb)::text$q$), 'ERROR: the days money waits after the night must be between 0 and 30');
  perform tests.assert_eq('a fraction is refused', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"hold_days":1.5}'::jsonb)::text$q$), 'ERROR: the days money waits after the night must be a whole number');
  perform tests.assert_eq('an unknown field is refused', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"method":"stripe"}'::jsonb)::text$q$), 'ERROR: unknown field: method');
  perform tests.assert_eq('changing the weekday does not choose a percentage', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"payout_weekday":1}'::jsonb)::text$q$), '{"hold_days": 2, "commission_bps": 0, "payout_weekday": 1}');
  perform tests.assert_eq('...it is still not set', (select commission_set from public.site_payout_settings), false);
  perform tests.assert_eq('no payout can be worked out before the percentage is chosen', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today())::text$q$, org_a)), 'ERROR: choose BottlesUp''s percentage first (in the payout settings), so the payout can be worked out');
  perform tests.assert_eq('the admin chooses 10 percent', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"commission_bps":1000}'::jsonb)::text$q$), '{"hold_days": 2, "commission_bps": 1000, "payout_weekday": 1}');
  perform tests.assert_eq('...and now it is set, by that admin', (select commission_set::text || ':' || (updated_by = admin_u)::text from public.site_payout_settings), 'true:true');
  perform tests.assert_eq('...logged with before and after', (select count(*)::int from public.audit_log where action = 'payout.settings_saved' and actor_id = admin_u), 2);
  perform tests.assert_eq('saving the same again changes and logs nothing', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"commission_bps":1000}'::jsonb)::text$q$), '{"hold_days": 2, "commission_bps": 1000, "payout_weekday": 1}');
  perform tests.assert_eq('...really nothing logged', (select count(*)::int from public.audit_log where action = 'payout.settings_saved'), 2);
  perform tests.assert_eq('a percentage of 0 chosen on purpose also counts as set', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"commission_bps":0}'::jsonb)::text$q$) like '%"commission_bps": 0%', true);
  perform tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_settings('{"commission_bps":1000}'::jsonb)::text$q$);

  ---------------------------------------------------------------- 2. what is eligible: online money, past the waiting days, not already taken
  perform tests.assert_eq('Club A: three bookings: 95.00 (100.00 less the customer fee 5.00), 50.00 (80.00 online less 30.00 recorded at the club), and 38.00 (past the 2 days); 10 percent kept',
    tests.eligible_text(org_a), 'Payout Club Co 3 bookings gross=18300 commission=1830 net=16470');
  perform tests.assert_eq('Club B: its one booking from 10 days ago (tonight''s is inside the waiting days)', tests.eligible_text(org_b), 'Other Club Co 1 bookings gross=20000 commission=2000 net=18000');
  perform tests.assert_eq('a business with nothing eligible is not listed', tests.eligible_text(org_o), '(none)');
  perform tests.assert_eq('the period limits what is counted: only the last 5 days takes in the booking from 3 days ago', tests.eligible_text(org_a, 5), 'Payout Club Co 1 bookings gross=3800 commission=380 net=3420');
  perform tests.assert_eq('a period must be sensible', tests.try(admin_u, 'admin@test.example', $q$select count(*)::text from public.cms_payout_eligible(tests.today(), tests.today() - 1)$q$), 'ERROR: choose the first and the last night');
  perform tests.assert_eq('...and not more than a year', tests.try(admin_u, 'admin@test.example', $q$select count(*)::text from public.cms_payout_eligible(tests.today() - 400, tests.today())$q$), 'ERROR: choose a period of a year at most');
  foreach who in array everyone loop
    perform tests.assert_eq('the eligible list is refused to ' || who, tests.try((select id from auth.users where email = who), who, $q$select count(*)::text from public.cms_payout_eligible(tests.today() - 5, tests.today())$q$), 'ERROR: not allowed');
  end loop;

  ---------------------------------------------------------------- 3. a business's own arrangement
  perform tests.assert_eq('a different percentage and no waiting days for Club B', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_override(%L, '{"commission_bps":500,"hold_days":0,"payout_weekday":5,"note":"Agreed 5 percent"}'::jsonb)::text$q$, org_b)),
    '{"note": "Agreed 5 percent", "hold_days": 0, "commission_bps": 500, "payout_weekday": 5}');
  perform tests.assert_eq('...now its eligible money includes tonight''s booking, with 5 percent kept', tests.eligible_text(org_b), 'Other Club Co 2 bookings gross=21000 commission=1050 net=19950');
  perform tests.assert_eq('...Club A is untouched', tests.eligible_text(org_a), 'Payout Club Co 3 bookings gross=18300 commission=1830 net=16470');
  perform tests.assert_eq('the overrides are listed with the business', tests.try(admin_u, 'admin@test.example', $q$select (select string_agg(org_name || ':' || commission_bps, ',') from public.cms_payout_overrides())$q$), 'Other Club Co:500');
  perform tests.assert_eq('a part of an override is removed by sending null', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_override(%L, '{"hold_days":null}'::jsonb)::text$q$, org_b)), '{"note": "Agreed 5 percent", "hold_days": null, "commission_bps": 500, "payout_weekday": 5}');
  perform tests.assert_eq('...so the waiting days are the platform''s again', tests.eligible_text(org_b), 'Other Club Co 1 bookings gross=20000 commission=1000 net=19000');
  perform tests.assert_eq('an override with nothing left is removed', tests.try(admin_u, 'admin@test.example', format($q$select coalesce(public.cms_save_payout_override(%L, '{"commission_bps":null,"payout_weekday":null}'::jsonb)::text, 'removed')$q$, org_b)), 'removed');
  perform tests.assert_eq('...and the business is back on the platform''s settings', tests.eligible_text(org_b), 'Other Club Co 1 bookings gross=20000 commission=2000 net=18000');
  perform tests.assert_eq('a business that does not exist is refused', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_override(gen_random_uuid(), '{"commission_bps":5}'::jsonb)::text$q$), 'ERROR: business not found');
  perform tests.assert_eq('an override percentage is checked as well', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_override(%L, '{"commission_bps":10001}'::jsonb)::text$q$, org_b)), 'ERROR: BottlesUp''s percentage (in hundredths of a percent) must be between 0 and 10000');
  foreach who in array everyone loop
    perform tests.assert_eq('overrides are refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.cms_save_payout_override(%L, '{"commission_bps":5}'::jsonb)::text$q$, org_b)), 'ERROR: not allowed');
  end loop;

  ---------------------------------------------------------------- 4. the account: a status and masked details, never a full number
  perform tests.assert_eq('every business is listed, incomplete until BottlesUp says otherwise', tests.try(admin_u, 'admin@test.example', $q$select (select string_agg(org_name || '=' || status, ',' order by org_name) from public.cms_payout_accounts())$q$),
    'Night Events=incomplete,Other Club Co=incomplete,Payout Club Co=incomplete,Third Club Co=incomplete');
  perform tests.assert_eq('"ready" needs an account holder and the last digits', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_account(%L, '{"status":"ready"}'::jsonb)$q$, org_a)), 'ERROR: an account is only ready once it has an account holder and the last digits of the account');
  perform tests.assert_eq('"action required" needs to say what', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_account(%L, '{"status":"action_required"}'::jsonb)$q$, org_a)), 'ERROR: say what action is needed, so the business can be told');
  perform tests.assert_eq('a full account number is refused', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_account(%L, '{"masked_account":"123456789012"}'::jsonb)$q$, org_a)), 'ERROR: never enter a full account number: only the last few digits, for example •••• 1234');
  perform tests.assert_eq('...even with spaces around the digits it is only the run of digits that counts (7 or more in a row)', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_account(%L, '{"masked_account":"acct 1234567"}'::jsonb)$q$, org_a)), 'ERROR: never enter a full account number: only the last few digits, for example •••• 1234');
  perform tests.assert_eq('a status that does not exist is refused', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_account(%L, '{"status":"verified"}'::jsonb)$q$, org_a)), 'ERROR: the status must be incomplete, under review, ready or action required');
  perform tests.assert_eq('a business that does not exist is refused', tests.try(admin_u, 'admin@test.example', $q$select public.cms_save_payout_account(gen_random_uuid(), '{"status":"under_review"}'::jsonb)$q$), 'ERROR: business not found');
  perform tests.assert_eq('under review is fine on its own', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_account(%L, '{"status":"under_review"}'::jsonb)$q$, org_a)), 'under_review');
  perform tests.assert_eq('ready, with the holder and the last digits', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_account(%L, '{"status":"ready","account_holder":"Payout Club Co Inc.","masked_account":"•••• 4821"}'::jsonb)$q$, org_a)), 'ready');
  perform tests.assert_eq('...stored, by that admin', (select status || ':' || account_holder || ':' || masked_account || ':' || (updated_by = admin_u)::text from public.site_payout_accounts where org_id = org_a), 'ready:Payout Club Co Inc.:•••• 4821:true');
  perform tests.assert_eq('...and both changes are logged (under review, then ready)', (select count(*)::int from public.audit_log where action = 'payout.account_saved' and entity_id = org_a::text and actor_id = admin_u), 2);
  foreach who in array everyone loop
    perform tests.assert_eq('accounts are refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.cms_save_payout_account(%L, '{"status":"ready"}'::jsonb)$q$, org_a)), 'ERROR: not allowed');
  end loop;

  ---------------------------------------------------------------- 5. a payout item
  perform tests.assert_eq('nothing eligible, nothing to pay (a business with no online bookings)', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today())::text$q$, org_o)), 'ERROR: nothing is eligible for that period: no paid online bookings past the waiting days that are not already in a payout');
  foreach who in array everyone loop
    perform tests.assert_eq('creating a payout is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today())::text$q$, org_a)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('an adjustment needs a reason', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today(), -500, null)::text$q$, org_a)), 'ERROR: say what the adjustment is for');
  perform tests.assert_eq('an adjustment cannot take the payout below zero', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today(), -17000, 'Chargeback')::text$q$, org_a)), 'ERROR: the adjustment is more than the payout comes to');
  perform tests.assert_eq('a period must be sensible', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today(), tests.today() - 1)::text$q$, org_a)), 'ERROR: choose the first and the last night');
  perform tests.assert_eq('a business that does not exist is refused', tests.try(admin_u, 'admin@test.example', $q$select public.cms_create_payout_item(gen_random_uuid(), tests.today() - 40, tests.today())::text$q$), 'ERROR: business not found');
  i1 := (tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today(), -300, ' Chargeback on one booking ')::text$q$, org_a)))::uuid;
  select * into k from public.site_payout_items where id = i1;
  perform tests.assert_eq('the item says what it is made of: gross, the percentage, the commission, the adjustment, the net', k.gross_cents || ':' || k.commission_bps || ':' || k.commission_cents || ':' || k.adjustments_cents || ':' || k.net_cents || ':' || k.adjustment_note, '18300:1000:1830:-300:16170:Chargeback on one booking');
  perform tests.assert_eq('...pending, expected on the next payout day (Monday), made by that admin', k.status || ':' || (k.expected_on = public.payout_next_date(1))::text || ':' || (k.created_by = admin_u)::text, 'pending:true:true');
  perform tests.assert_eq('...taking the three bookings it was made from', (select count(*)::int from public.site_payout_item_bookings where item_id = i1), 3);
  perform tests.assert_eq('...each with what it contributed', (select string_agg(amount_cents::text, ',' order by amount_cents) from public.site_payout_item_bookings where item_id = i1), '3800,5000,9500');
  perform tests.assert_eq('...and it is logged', (select count(*)::int from public.audit_log where action = 'payout.item_created' and entity_id = i1::text and actor_id = admin_u), 1);
  perform tests.assert_eq('nothing is eligible any more for the same period (a booking is in ONE payout)', tests.eligible_text(org_a), '(none)');
  perform tests.assert_eq('...and a second payout for it is refused', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today())::text$q$, org_a)), 'ERROR: nothing is eligible for that period: no paid online bookings past the waiting days that are not already in a payout');
  perform tests.assert_eq('the list shows it, with how many bookings', tests.try(admin_u, 'admin@test.example', format($q$select (select org_name || ':' || status || ':' || bookings || ':' || net_cents from public.cms_payout_items(null, %L))$q$, org_a)), 'Payout Club Co:pending:3:16170');
  perform tests.assert_eq('...filtered by status', tests.try(admin_u, 'admin@test.example', $q$select (select count(*) from public.cms_payout_items('paid'))::text$q$), '0');
  perform tests.assert_eq('...a status that does not exist is refused', tests.try(admin_u, 'admin@test.example', $q$select count(*)::text from public.cms_payout_items('maybe')$q$), 'ERROR: unknown status');
  foreach who in array everyone loop
    perform tests.assert_eq('the list is refused to ' || who, tests.try((select id from auth.users where email = who), who, $q$select count(*)::text from public.cms_payout_items()$q$), 'ERROR: not allowed');
  end loop;

  ---------------------------------------------------------------- 6. its life: pending, processing, paid (with a reference) or failed or cancelled
  perform tests.assert_eq('a status must be one a person can choose', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'pending')$q$, i1)), 'ERROR: choose processing, paid, failed or cancelled');
  perform tests.assert_eq('a payout that does not exist', tests.try(admin_u, 'admin@test.example', $q$select public.cms_set_payout_item_status(gen_random_uuid(), 'processing')$q$), 'ERROR: payout not found');
  foreach who in array everyone loop
    perform tests.assert_eq('changing a payout is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.cms_set_payout_item_status(%L, 'processing')$q$, i1)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('it becomes processing', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'processing')$q$, i1)), 'processing');
  perform tests.assert_eq('...saying it again changes nothing', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'processing')$q$, i1)), 'processing');
  perform tests.assert_eq('paid needs a transfer reference', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'paid')$q$, i1)), 'ERROR: enter the transfer reference: a payout is not paid until a transfer was made');
  perform tests.assert_eq('...a real one, not two letters', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'paid', 'ab')$q$, i1)), 'ERROR: enter the transfer reference: a payout is not paid until a transfer was made');
  perform tests.assert_eq('failed needs a reason', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'failed')$q$, i1)), 'ERROR: say why the payout failed');
  perform tests.assert_eq('it can fail, with the reason kept', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'failed', null, ' Bank returned the transfer ')$q$, i1)), 'failed');
  perform tests.assert_eq('...stored', (select status || ':' || failure_note from public.site_payout_items where id = i1), 'failed:Bank returned the transfer');
  perform tests.assert_eq('a failed payout can be tried again as paid, with the reference', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'paid', ' ETR-20261026-001 ')$q$, i1)), 'paid');
  select * into k from public.site_payout_items where id = i1;
  perform tests.assert_eq('...paid carries the reference and when, and clears the failure', k.status || ':' || k.reference || ':' || (k.paid_at is not null)::text || ':' || coalesce(k.failure_note, 'none'), 'paid:ETR-20261026-001:true:none');
  perform tests.assert_eq('a paid payout can never be changed', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'cancelled')$q$, i1)), 'ERROR: a payout that is paid cannot be changed');
  perform tests.assert_eq('...nor cancelled to free its bookings: they stay taken', (select count(*)::int from public.site_payout_item_bookings where item_id = i1), 3);
  perform tests.assert_eq('only a pending payout is marked processing', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'processing')$q$, i1)), 'ERROR: a payout that is paid cannot be changed');
  perform tests.assert_eq('each step is logged', (select count(*)::int from public.audit_log where entity_id = i1::text and action in ('payout.item_processing', 'payout.item_failed', 'payout.item_paid')), 3);
  perform tests.assert_raises('the table itself will not call something paid without a reference', format($q$update public.site_payout_items set reference = null where id = %L$q$, i1), 'violates check constraint');
  perform tests.assert_raises('...nor have a net that does not add up', format($q$update public.site_payout_items set net_cents = 1 where id = %L$q$, i1), 'violates check constraint');

  -- a payout that is cancelled gives its bookings back
  i2 := (tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today())::text$q$, org_b)))::uuid;
  perform tests.assert_eq('Club B''s payout is made (20000, 10 percent kept)', (select net_cents from public.site_payout_items where id = i2), 18000);
  perform tests.assert_eq('...it is cancelled', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'cancelled')$q$, i2)), 'cancelled');
  perform tests.assert_eq('...its bookings are free again', tests.eligible_text(org_b), 'Other Club Co 1 bookings gross=20000 commission=2000 net=18000');
  perform tests.assert_eq('...a cancelled payout cannot be changed', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'paid', 'REF-123')$q$, i2)), 'ERROR: a payout that is cancelled cannot be changed');
  i3 := (tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today())::text$q$, org_b)))::uuid;
  perform tests.assert_eq('...and a new payout takes them again', (select count(*)::int from public.site_payout_item_bookings where item_id = i3), 1);
  perform tests.assert_raises('the same booking cannot be put into two payouts even by a mistake (the table itself refuses)', format($q$insert into public.site_payout_item_bookings (item_id, booking_id, amount_cents) values (%L, %L, 1)$q$, i3, ba1), 'duplicate key');

  ---------------------------------------------------------------- 6b. rounding, a percentage that is not a round number, a period, an override that keeps what it was not told to change, and a retry after failing
  perform tests.assert_eq('the payout day is a week away when today is that day (never "today")', public.payout_next_date(extract(dow from tests.today())::int), tests.today() + 7);
  perform tests.assert_eq('...and the next day when it is tomorrow', public.payout_next_date((extract(dow from tests.today())::int + 1) % 7), tests.today() + 1);
  perform tests.assert_eq('a business gets its own 3.45 percent', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_override(%L, '{"commission_bps":345,"payout_weekday":2,"hold_days":1}'::jsonb)::text$q$, org_c)), '{"note": null, "hold_days": 1, "commission_bps": 345, "payout_weekday": 2}');
  perform tests.assert_eq('a later change of the note alone keeps the percentage, the weekday and the waiting days', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_override(%L, '{"note":"Agreed by phone"}'::jsonb)::text$q$, org_c)), '{"note": "Agreed by phone", "hold_days": 1, "commission_bps": 345, "payout_weekday": 2}');
  perform tests.assert_eq('the commission is rounded to the nearest cent in the preview (32345 x 3.45% = 1115.9 -> 1116)', tests.eligible_text(org_c), 'Third Club Co 2 bookings gross=32345 commission=1116 net=31229');
  perform tests.assert_eq('a period of more than a year is refused when making a payout too', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 400, tests.today())::text$q$, org_c)), 'ERROR: choose a period of a year at most');
  c_item := (tests.try(admin_u, 'admin@test.example', format($q$select public.cms_create_payout_item(%L, tests.today() - 40, tests.today())::text$q$, org_c)))::uuid;
  perform tests.assert_eq('...and the payout is rounded the same way, with the business''s own weekday for the expected date', (select commission_cents || ':' || net_cents || ':' || (expected_on = public.payout_next_date(2))::text from public.site_payout_items where id = c_item), '1116:31229:true');
  perform tests.assert_eq('a pending payout can fail', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'failed', null, 'Wrong bank details')$q$, c_item)), 'failed');
  perform tests.assert_eq('a failed payout is not "processing" again: only a pending one is', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_set_payout_item_status(%L, 'processing')$q$, c_item)), 'ERROR: only a pending payout can be marked as processing');
  perform tests.assert_eq('a masked account with only the last digits is accepted', tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_account(%L, '{"masked_account":"ok 1234"}'::jsonb)$q$, org_c)), 'incomplete');
  perform tests.assert_raises('the table itself refuses an account number that is not masked, even when written past the function', format($q$insert into public.site_payout_accounts (org_id, masked_account) values (%L, 'full 98765432') on conflict (org_id) do update set masked_account = excluded.masked_account$q$, org_c), 'violates check constraint');

  ---------------------------------------------------------------- 7. what an owner or organizer sees of their own business
  j := tests.runj(owner_a, 'owner_a@po.example', format($q$select public.my_payouts(%L)$q$, org_a));
  perform tests.assert_eq('the owner sees the account with the masked number', (j -> 'account'), '{"note": null, "status": "ready", "masked_account": "•••• 4821", "account_holder": "Payout Club Co Inc."}'::jsonb);
  perform tests.assert_eq('...the settings that apply, read-only', (j -> 'settings' ->> 'commission_bps') || ':' || (j -> 'settings' ->> 'payout_weekday') || ':' || (j -> 'settings' ->> 'hold_days') || ':' || (j -> 'settings' ->> 'payout_method') || ':' || (j -> 'settings' ->> 'own_arrangement'), '1000:1:2:manual_transfer:false');
  perform tests.assert_eq('...the next payout day', (j -> 'settings' ->> 'next_payout_on')::date, public.payout_next_date(1));
  perform tests.assert_eq('...the payout that was paid, with its reference', (j -> 'items' -> 0 ->> 'status') || ':' || (j -> 'items' -> 0 ->> 'reference') || ':' || (j -> 'items' -> 0 ->> 'net_cents'), 'paid:ETR-20261026-001:16170');
  perform tests.assert_eq('...and what is waiting (nothing: everything eligible is in that payout)', (j -> 'waiting' ->> 'bookings') || ':' || (j -> 'waiting' ->> 'gross_cents'), '0:0');
  perform tests.assert_eq('...the payout''s bookings are not shown, nor any other business''s', (j -> 'items')::text not like '%Other%', true);
  perform tests.assert_eq('a cancelled payout is not shown', jsonb_array_length(tests.runj(owner_b, 'owner_b@po.example', format($q$select public.my_payouts(%L) -> 'items'$q$, org_b))), 1);
  perform tests.assert_eq('another business sees its own: the account is incomplete and the percentage is its own arrangement', (tests.runj(owner_b, 'owner_b@po.example', format($q$select public.my_payouts(%L)$q$, org_b)) -> 'account' ->> 'status'), 'incomplete');
  perform tests.assert_eq('an owner cannot read another business', tests.try(owner_a, 'owner_a@po.example', format($q$select public.my_payouts(%L)::text$q$, org_b)), 'ERROR: not allowed');
  perform tests.assert_eq('a manager does not see the business''s payouts (they are the owner''s)', tests.try(mgr_a, 'mgra@po.example', format($q$select public.my_payouts(%L)::text$q$, org_a)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger does not', tests.try(rando, 'rando@po.example', format($q$select public.my_payouts(%L)::text$q$, org_a)), 'ERROR: not allowed');
  perform tests.assert_eq('an organizer sees their own business: no table money, an incomplete account', (tests.runj(org_u, 'org@po.example', format($q$select public.my_payouts(%L)$q$, org_o)) ->> 'org_kind') || ':' || (tests.runj(org_u, 'org@po.example', format($q$select public.my_payouts(%L)$q$, org_o)) -> 'waiting')::text || ':' || (tests.runj(org_u, 'org@po.example', format($q$select public.my_payouts(%L)$q$, org_o)) -> 'account' ->> 'status'), 'organizer:null:incomplete');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select public.my_payouts(%L)$q$, org_a), 'permission denied');
  perform tests.logout();
  update public.site_payout_settings set commission_set = false, commission_bps = 0 where id = 1;
  perform tests.assert_eq('until BottlesUp has chosen its percentage, the owner is not shown a made-up one', (tests.runj(owner_a, 'owner_a@po.example', format($q$select public.my_payouts(%L)$q$, org_a)) -> 'settings' -> 'commission_bps')::text, 'null');
  update public.site_payout_settings set commission_set = true, commission_bps = 1000 where id = 1;
  perform tests.assert_eq('an arrangement of their own is shown as such', (tests.runj(owner_b, 'owner_b@po.example', format($q$select public.my_payouts(%L)$q$, org_b)) -> 'settings' ->> 'own_arrangement'), 'false');
  perform tests.try(admin_u, 'admin@test.example', format($q$select public.cms_save_payout_override(%L, '{"commission_bps":500}'::jsonb)::text$q$, org_b));
  perform tests.assert_eq('...after an override', (tests.runj(owner_b, 'owner_b@po.example', format($q$select public.my_payouts(%L)$q$, org_b)) -> 'settings' ->> 'own_arrangement') || ':' || (tests.runj(owner_b, 'owner_b@po.example', format($q$select public.my_payouts(%L)$q$, org_b)) -> 'settings' ->> 'commission_bps'), 'true:500');

  ---------------------------------------------------------------- 8. declarations and the closed tables
  perform tests.assert_true('every new function runs with its owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('cms_payout_settings', 'cms_save_payout_settings', 'cms_payout_overrides', 'cms_save_payout_override', 'cms_payout_accounts', 'cms_save_payout_account',
        'cms_payout_eligible', 'cms_create_payout_item', 'cms_set_payout_item_status', 'cms_payout_items', 'my_payouts', 'payout_effective', 'payout_eligible_bookings')));
  perform tests.assert_true('the five tables have row level security on', (select bool_and(relrowsecurity) from pg_class where oid in ('public.site_payout_settings'::regclass, 'public.site_payout_overrides'::regclass,
    'public.site_payout_accounts'::regclass, 'public.site_payout_items'::regclass, 'public.site_payout_item_bookings'::regclass)));
  perform tests.login(owner_a, 'owner_a@po.example');
  perform tests.assert_raises('the app cannot read the settings directly', $q$select * from public.site_payout_settings$q$, 'permission denied');
  perform tests.assert_raises('...nor the payout items', $q$select * from public.site_payout_items$q$, 'permission denied');
  perform tests.assert_raises('...nor the accounts', $q$select * from public.site_payout_accounts$q$, 'permission denied');
  perform tests.assert_raises('...nor change the percentage', $q$update public.site_payout_settings set commission_bps = 0$q$, 'permission denied');
  perform tests.assert_raises('the internal helpers are not callable by the app', format($q$select * from public.payout_effective(%L)$q$, org_a), 'permission denied');
  perform tests.logout();
end $$;

rollback;
