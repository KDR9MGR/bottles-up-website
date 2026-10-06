-- Who can read or change orders, staff, codes and ticket counts, as seen by the
-- three kinds of caller PostgREST produces: anon, a signed-in user, an admin.
begin;

do $$
declare
  staff constant uuid := '00000000-0000-0000-0000-0000000000a1';
  admin constant uuid := '00000000-0000-0000-0000-0000000000a2';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  cust  constant uuid := '00000000-0000-0000-0000-0000000000a4';
  b1 constant uuid := '00000000-0000-0000-0000-0000000000b1';
  n int;
  total_orders int;
  before_sold int;
  after_sold int;
begin
  select count(*) into total_orders from public.site_orders;

  ---------------------------------------------------------------- orders: reading
  perform tests.login_anon();
  select count(*) into n from public.site_orders;
  perform tests.assert_eq('an anonymous visitor sees NO orders (customer names and emails)', n, 0);

  perform tests.login(rando, 'rando@test.example');
  select count(*) into n from public.site_orders;
  perform tests.assert_eq('a signed-in stranger sees no orders', n, 0);

  perform tests.login(cust, 'customer@test.example');
  select count(*) into n from public.site_orders;
  perform tests.assert_eq('a customer sees exactly their own order (matched by verified email)', n, 1);
  select count(*) into n from public.site_orders where customer_email <> 'customer@test.example';
  perform tests.assert_eq('...and none of anyone else''s', n, 0);

  perform tests.login(admin, 'admin@test.example');
  select count(*) into n from public.site_orders;
  perform tests.assert_eq('a CMS admin sees every order', n, total_orders);

  ---------------------------------------------------------------- orders: changing (the "mark myself paid" attack)
  perform tests.login(cust, 'customer@test.example');
  update public.site_orders set status = 'paid' where ticket_code = 'T-PENDING';
  perform tests.assert_raises('a customer cannot create an order directly',
    $q$insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status)
       values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b1', 'X', 'customer@test.example', 1, 0, 'paid')$q$,
    'row-level security');
  update public.site_orders set status = 'refunded', amount_total_cents = 0 where customer_email = 'customer@test.example';
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code = 'T-PAID' and status = 'paid' and amount_total_cents = 10000;
  perform tests.assert_eq('a customer cannot edit their own order (status, amount)', n, 1);
  select count(*) into n from public.site_orders where ticket_code = 'T-PENDING' and status = 'pending';
  perform tests.assert_eq('...and cannot mark someone else''s pending order paid', n, 1);

  perform tests.login_anon();
  update public.site_orders set status = 'paid';
  perform tests.assert_raises('an anonymous visitor cannot create orders', $q$insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents) values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b1', 'X', 'x@x', 1, 0)$q$, 'row-level security');
  perform tests.logout();
  select count(*) into n from public.site_orders where status = 'paid';
  perform tests.assert_eq('an anonymous visitor cannot mark anything paid', n,
    (select count(*)::int from public.site_orders where ticket_code in ('T-PAID','T-PAID2','T-ENDED','T-STALE','T-LIVE','T-NT','T-NT-OK','C-1')));

  ---------------------------------------------------------------- scan log, one-time codes, staff list
  insert into public.scan_attempts (ticket_code_attempted, result, scanned_by) values ('T-PAID', 'ok', staff);
  insert into public.ticket_otp_codes (order_id, code_hash, sent_to_email)
    select id, 'hash-that-must-not-leak', customer_email from public.site_orders where ticket_code = 'T-NT';

  perform tests.login(rando, 'rando@test.example');
  select count(*) into n from public.scan_attempts;
  perform tests.assert_eq('a stranger cannot read the scan log', n, 0);
  select count(*) into n from public.ticket_otp_codes;
  perform tests.assert_eq('a stranger cannot read one-time code hashes', n, 0);
  select count(*) into n from public.door_staff;
  perform tests.assert_eq('a stranger cannot read the staff list', n, 0);

  perform tests.login_anon();
  select count(*) into n from public.ticket_otp_codes;
  perform tests.assert_eq('an anonymous visitor cannot read one-time code hashes', n, 0);

  perform tests.login(staff);
  select count(*) into n from public.door_staff;
  perform tests.assert_eq('door staff can read only their own staff row', n, 1);
  select count(*) into n from public.scan_attempts;
  perform tests.assert_eq('door staff cannot browse the scan log (only admins)', n, 0);

  perform tests.login(admin);
  select count(*) into n from public.scan_attempts;
  perform tests.assert_true('an admin can read the scan log', n >= 1);
  select count(*) into n from public.ticket_otp_codes;
  perform tests.assert_true('an admin can read one-time codes for support', n >= 1);

  ---------------------------------------------------------------- the sold counter
  -- increment_tier_sold is a plain (not security definer) function that
  -- everyone may EXECUTE. It is safe only because RLS blocks the UPDATE it
  -- performs. If someone later makes it SECURITY DEFINER, anyone could sell out
  -- any event. These tests catch that.
  perform tests.logout();
  select sold_count into before_sold from public.site_ticket_tiers where id = b1;

  perform tests.login_anon();
  perform public.increment_tier_sold(b1, 50);
  perform tests.login(rando, 'rando@test.example');
  perform public.increment_tier_sold(b1, 50);
  perform tests.logout();
  select sold_count into after_sold from public.site_ticket_tiers where id = b1;
  perform tests.assert_eq('anonymous and ordinary users cannot change a tier''s sold count', after_sold, before_sold);

  perform tests.login_service();
  perform public.increment_tier_sold(b1, 2);
  perform tests.logout();
  select sold_count into after_sold from public.site_ticket_tiers where id = b1;
  perform tests.assert_eq('the service role (used by the webhook) can', after_sold, before_sold + 2);
end $$;

rollback;
