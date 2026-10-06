-- checkin_ticket(): what the door scanner calls for every QR code.
-- It is SECURITY DEFINER and executable by everyone, so its own first line
-- ("not authorized") is the only thing between the public and check-in.
begin;

do $$
declare
  staff constant uuid := '00000000-0000-0000-0000-0000000000a1';
  admin constant uuid := '00000000-0000-0000-0000-0000000000a2';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  cust  constant uuid := '00000000-0000-0000-0000-0000000000a4';
  r record;
  o record;
  n int;
  arr text[];
begin
  ---------------------------------------------------------------- who may scan
  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot scan', $q$select * from public.checkin_ticket('T-PAID')$q$, 'not authorized');

  perform tests.login(rando, 'rando@test.example');
  perform tests.assert_raises('a signed-in user with no staff role cannot scan', $q$select * from public.checkin_ticket('T-PAID')$q$, 'not authorized');

  perform tests.login(cust, 'customer@test.example');
  perform tests.assert_raises('a customer cannot check in their OWN ticket', $q$select * from public.checkin_ticket('T-PAID')$q$, 'not authorized');

  perform tests.logout();
  select checked_in_at into o from public.site_orders where ticket_code = 'T-PAID';
  perform tests.assert_true('...and the refused attempts changed nothing', o.checked_in_at is null);

  ---------------------------------------------------------------- admitting
  perform tests.login(staff);
  select * into r from public.checkin_ticket('T-PAID');
  perform tests.assert_eq('door staff: first scan of a paid ticket admits', r.result, 'ok');
  perform tests.assert_eq('returns the customer name', r.customer_name, 'Ada Lovelace');
  perform tests.assert_eq('returns the event title', r.event_title, 'Future Night');
  perform tests.assert_eq('returns the ticket tier', r.tier_name, 'General');
  perform tests.assert_eq('returns the quantity admitted', r.quantity, 2);

  perform tests.logout();
  select checked_in_at, checked_in_by into o from public.site_orders where ticket_code = 'T-PAID';
  perform tests.assert_true('the order is stamped as checked in', o.checked_in_at is not null);
  perform tests.assert_eq('the order records WHO checked it in', o.checked_in_by, staff);

  ---------------------------------------------------------------- the same ticket twice
  perform tests.login(staff);
  select * into r from public.checkin_ticket('T-PAID');
  perform tests.assert_eq('scanning the same ticket again says already_checked_in', r.result, 'already_checked_in');
  perform tests.assert_eq('...and still shows who it belongs to', r.customer_name, 'Ada Lovelace');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code = 'T-PAID' and checked_in_by = staff and checked_in_at is not null;
  perform tests.assert_eq('...without overwriting the first check-in', n, 1);

  ---------------------------------------------------------------- an admin may scan too
  perform tests.login(admin);
  select * into r from public.checkin_ticket('T-PAID2');
  perform tests.assert_eq('a CMS admin can scan as well', r.result, 'ok');
  perform tests.logout();
  select checked_in_by into o from public.site_orders where ticket_code = 'T-PAID2';
  perform tests.assert_eq('...and is recorded as the scanner', o.checked_in_by, admin);

  ---------------------------------------------------------------- tickets that must not get in
  perform tests.login(staff);
  select * into r from public.checkin_ticket('NO-SUCH-CODE');
  perform tests.assert_eq('an unknown code is not_found', r.result, 'not_found');
  perform tests.assert_true('...and reveals no customer details', r.customer_name is null and r.event_title is null);

  select * into r from public.checkin_ticket('T-PENDING');
  perform tests.assert_eq('an unpaid (pending) order is not_paid', r.result, 'not_paid');
  select * into r from public.checkin_ticket('T-FAILED');
  perform tests.assert_eq('a failed payment is not_paid', r.result, 'not_paid');
  select * into r from public.checkin_ticket('T-REFUNDED');
  perform tests.assert_eq('a refunded ticket is not_paid', r.result, 'not_paid');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code in ('T-PENDING', 'T-FAILED', 'T-REFUNDED') and checked_in_at is not null;
  perform tests.assert_eq('...none of them were checked in', n, 0);

  ---------------------------------------------------------------- expiry
  perform tests.login(staff);
  select array_agg(result) into arr from public.checkin_ticket('T-ENDED');
  perform tests.assert_eq('a ticket for an event that has ended is expired', arr[1], 'expired');
  select array_agg(result) into arr from public.checkin_ticket('T-STALE');
  perform tests.assert_eq('no end time: the event counts as over 12 hours after it started', arr[1], 'expired');
  -- Regression: checkin_ticket() used RETURN QUERY for 'expired' without RETURNing, so it carried on into the admit
  -- code and the scan returned two rows (expired, ok). Fixed by 20260830120000_fix_checkin_ticket_early_returns.sql.
  perform tests.assert_eq('a scan of an expired ticket returns exactly one result', cardinality(arr), 1);
  select * into r from public.checkin_ticket('T-LIVE');
  perform tests.assert_eq('no end time, started 1 hour ago: still valid', r.result, 'ok');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code in ('T-ENDED', 'T-STALE') and checked_in_at is not null;
  perform tests.assert_eq('an expired ticket is NOT marked as checked in', n, 0);

  ---------------------------------------------------------------- order of the checks
  perform tests.login(staff);
  select * into r from public.checkin_ticket('T-UNPAID-ENDED');
  perform tests.assert_eq('unpaid is reported before expired', r.result, 'not_paid');
  perform tests.logout();
  update public.site_orders set checked_in_at = now() - interval '1 hour' where ticket_code = 'T-ENDED';
  perform tests.login(staff);
  select * into r from public.checkin_ticket('T-ENDED');
  perform tests.assert_eq('already-checked-in is reported before expired', r.result, 'already_checked_in');

  ---------------------------------------------------------------- non-transferable tickets
  select array_agg(result) into arr from public.checkin_ticket('T-NT');
  perform tests.assert_eq('a non-transferable ticket asks for the entry code first', arr[1], 'code_required');
  -- Regression (same cause as above): 'code_required' used to fall through into the admit code.
  perform tests.assert_eq('...and the scan returns exactly one result', cardinality(arr), 1);
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code = 'T-NT' and checked_in_at is not null;
  perform tests.assert_eq('...and is NOT admitted by the scan alone (the entry-code step cannot be skipped)', n, 0);
  perform tests.login(staff);
  select * into r from public.checkin_ticket('T-NT-OK');
  perform tests.assert_eq('once its code is verified, a non-transferable ticket is admitted', r.result, 'ok');

  ---------------------------------------------------------------- audit trail
  perform tests.logout();
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'T-PAID' and result = 'ok' and scanned_by = staff;
  perform tests.assert_eq('the successful scan is logged with who scanned', n, 1);
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'T-PAID' and result = 'already_checked_in';
  perform tests.assert_eq('the repeat scan is logged too', n, 1);
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'NO-SUCH-CODE' and result = 'not_found' and order_id is null;
  perform tests.assert_eq('an unknown code is logged with no order', n, 1);
  select count(*) into n from public.scan_attempts where ticket_code_attempted in ('T-PENDING', 'T-FAILED', 'T-REFUNDED') and result = 'not_paid';
  perform tests.assert_eq('every rejected scan is logged', n, 3);
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'T-PAID' and scanned_by in (rando, cust);
  perform tests.assert_eq('refused (unauthorized) attempts leave no scan record', n, 0);
  select count(*) into n from public.scan_attempts where ticket_code_attempted in ('T-ENDED', 'T-STALE', 'T-NT') and result = 'ok';
  perform tests.assert_eq('a refused scan is not ALSO logged as an admitted one', n, 0);
end $$;

rollback;
