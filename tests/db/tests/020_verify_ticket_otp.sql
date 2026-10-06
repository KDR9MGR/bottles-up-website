-- verify_ticket_otp(): the entry-code step for non-transferable tickets.
-- Staff read the 6-digit code from the customer's phone; 3 wrong tries lock it.
begin;

do $$
declare
  staff constant uuid := '00000000-0000-0000-0000-0000000000a1';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  e1 constant uuid := '00000000-0000-0000-0000-0000000000e1';
  b2 constant uuid := '00000000-0000-0000-0000-0000000000b2';
  r record;
  o record;
  c record;
  n int;
begin
  -- Four non-transferable paid orders, each with its own scenario.
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, is_non_transferable) values
    (e1, b2, 'Otp Happy',  'happy@test.example',  1, 9000, 'paid', 'V-HAPPY',  true),
    (e1, b2, 'Otp Wrong',  'wrong@test.example',  1, 9000, 'paid', 'V-WRONG',  true),
    (e1, b2, 'Otp Late',   'late@test.example',   1, 9000, 'paid', 'V-LATE',   true),
    (e1, b2, 'Otp None',   'none@test.example',   1, 9000, 'paid', 'V-NONE',   true);

  -- Real bcrypt hash of 123456, exactly how the request-ticket-otp function stores it.
  insert into public.ticket_otp_codes (order_id, code_hash, sent_to_email, expires_at)
  select id, crypt('123456', gen_salt('bf', 4)), customer_email, now() + interval '5 minutes'
  from public.site_orders where ticket_code in ('V-HAPPY', 'V-WRONG');
  insert into public.ticket_otp_codes (order_id, code_hash, sent_to_email, expires_at)
  select id, crypt('123456', gen_salt('bf', 4)), customer_email, now() - interval '1 minute'
  from public.site_orders where ticket_code = 'V-LATE';

  ---------------------------------------------------------------- who may verify
  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot verify codes', $q$select * from public.verify_ticket_otp('V-HAPPY', '123456')$q$, 'not authorized');
  perform tests.login(rando, 'rando@test.example');
  perform tests.assert_raises('a user with no staff role cannot verify codes', $q$select * from public.verify_ticket_otp('V-HAPPY', '123456')$q$, 'not authorized');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code = 'V-HAPPY' and checked_in_at is not null;
  perform tests.assert_eq('...and the refused attempts admitted nobody', n, 0);

  ---------------------------------------------------------------- happy path
  perform tests.login(staff);
  select * into r from public.verify_ticket_otp('V-HAPPY', '123456');
  perform tests.assert_eq('the right code admits the ticket', r.result, 'ok');
  perform tests.assert_eq('...returning the customer', r.customer_name, 'Otp Happy');
  perform tests.logout();
  select checked_in_at, checked_in_by, access_code_verified into o from public.site_orders where ticket_code = 'V-HAPPY';
  perform tests.assert_true('the order is checked in', o.checked_in_at is not null);
  perform tests.assert_eq('...by the staff member who verified it', o.checked_in_by, staff);
  perform tests.assert_true('...and marked access-code-verified', o.access_code_verified);
  select status, verified_by into c from public.ticket_otp_codes where order_id = (select id from public.site_orders where ticket_code = 'V-HAPPY');
  perform tests.assert_eq('the code is now burned (status verified)', c.status, 'verified');
  perform tests.assert_eq('...with the verifier recorded', c.verified_by, staff);

  perform tests.login(staff);
  select * into r from public.verify_ticket_otp('V-HAPPY', '123456');
  perform tests.assert_eq('using the same code again cannot admit a second person', r.result, 'already_checked_in');

  ---------------------------------------------------------------- wrong codes lock out after three
  select * into r from public.verify_ticket_otp('V-WRONG', '000000');
  perform tests.assert_eq('a wrong code is code_incorrect', r.result, 'code_incorrect');
  perform tests.assert_eq('...with 2 attempts left', r.attempts_remaining, 2);
  select * into r from public.verify_ticket_otp('V-WRONG', '111111');
  perform tests.assert_eq('a second wrong code: 1 attempt left', r.attempts_remaining, 1);
  select * into r from public.verify_ticket_otp('V-WRONG', '222222');
  perform tests.assert_eq('a third wrong code: 0 attempts left', r.attempts_remaining, 0);
  select * into r from public.verify_ticket_otp('V-WRONG', '123456');
  perform tests.assert_eq('after three failures even the CORRECT code is refused (lockout)', r.result, 'code_expired');
  perform tests.logout();
  select checked_in_at into o from public.site_orders where ticket_code = 'V-WRONG';
  perform tests.assert_true('...and the locked-out ticket was not admitted', o.checked_in_at is null);
  select status into c from public.ticket_otp_codes where order_id = (select id from public.site_orders where ticket_code = 'V-WRONG');
  perform tests.assert_eq('the locked code is marked expired', c.status, 'expired');

  ---------------------------------------------------------------- time limit
  perform tests.login(staff);
  select * into r from public.verify_ticket_otp('V-LATE', '123456');
  perform tests.assert_eq('a code past its 5-minute life is code_expired, even if correct', r.result, 'code_expired');
  perform tests.logout();
  select checked_in_at into o from public.site_orders where ticket_code = 'V-LATE';
  perform tests.assert_true('...and does not admit', o.checked_in_at is null);

  ---------------------------------------------------------------- no code requested / other states
  perform tests.login(staff);
  select * into r from public.verify_ticket_otp('V-NONE', '123456');
  perform tests.assert_eq('no code was ever requested for this ticket', r.result, 'no_code_requested');
  select * into r from public.verify_ticket_otp('NO-SUCH-CODE', '123456');
  perform tests.assert_eq('an unknown ticket is not_found', r.result, 'not_found');
  perform tests.logout();
  update public.site_orders set status = 'pending' where ticket_code = 'V-NONE';
  perform tests.login(staff);
  select * into r from public.verify_ticket_otp('V-NONE', '123456');
  perform tests.assert_eq('an unpaid ticket is not_paid', r.result, 'not_paid');

  ---------------------------------------------------------------- one ticket's code cannot unlock another
  perform tests.logout();
  update public.site_orders set status = 'paid' where ticket_code = 'V-NONE';
  perform tests.login(staff);
  select * into r from public.verify_ticket_otp('V-NONE', '123456'); -- V-HAPPY's code, V-NONE's ticket
  perform tests.assert_eq('a code issued for a different ticket does not work here', r.result, 'no_code_requested');

  ---------------------------------------------------------------- audit trail
  perform tests.logout();
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'V-WRONG' and result = 'code_incorrect';
  perform tests.assert_eq('each wrong attempt is logged', n, 3);
  select count(*) into n from public.scan_attempts where ticket_code_attempted = 'V-HAPPY' and result = 'ok' and scanned_by = staff;
  perform tests.assert_eq('the successful verification is logged', n, 1);
end $$;

rollback;
