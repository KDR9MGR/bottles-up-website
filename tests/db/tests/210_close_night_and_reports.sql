-- Preparing, closing and reporting a night. What matters most: only the manager and owner of THAT club tick the checklist and close the
-- night; closing lists everything still open and refuses unless that is acknowledged with a reason, and the exceptions are kept; a closed night
-- is closed once and only the owner reopens it, with a reason; the report is the same figures for everyone but filtered by role (the verifier
-- sees the money and nothing about security, security sees only security and no money), preliminary until the close and then FINAL, no longer
-- changing when the books move; a correction replaces the payment it corrects (counted once); clubs never see each other's figures.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.run_as(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int, p_paid int) returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, p_total, p_paid, 'paid', upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkpay(p_booking uuid, p_paid int, p_method text, p_by uuid, p_split jsonb default null) returns uuid language sql security definer as $$
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, split_breakdown, recorded_by, missing_receipt_reason)
  values (p_booking, p_paid, p_paid, p_method, p_split, p_by, 'seeded')
  returning id $$;
create function tests.keys(p_json text) returns text language sql immutable as $$
  select string_agg(k, ',' order by k) from jsonb_object_keys(p_json::jsonb) k $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000005d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000005d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000005d3';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000005d4';
  sec_1 constant uuid := '00000000-0000-0000-0000-0000000005d5';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000005d6';
  rando constant uuid := '00000000-0000-0000-0000-0000000005d7';
  night date := current_date;
  org uuid; venue_a uuid; venue_b uuid; type_a uuid; type_b uuid; slot_a uuid; slot_b uuid;
  b1 uuid; b2 uuid; b_b uuid; p1 uuid; p2 uuid; p3 uuid; p_orig uuid; p_corr uuid; p6 uuid; p_b uuid; flag1 uuid;
  r text; j jsonb; rep jsonb;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@night.example'), (mgr_a, 'mgra@night.example'), (srv_1, 'srv1@night.example'), (ver_a, 'vera@night.example'),
    (sec_1, 'sec1@night.example'), (mgr_b, 'mgrb@night.example'), (rando, 'rando@night.example');
  insert into public.profiles (id, name, email) values
    (owner_u, 'Olly Owner', 'owner@night.example'), (mgr_a, 'Mia Manager', 'mgra@night.example'), (srv_1, 'Sam Server', 'srv1@night.example'),
    (ver_a, 'Vera Verifier', 'vera@night.example'), (sec_1, 'Sid Security', 'sec1@night.example'), (mgr_b, 'Max Manager', 'mgrb@night.example');

  perform tests.login(owner_u, 'owner@night.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@night.example', org, 'mgra@night.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@night.example', org, 'mgrb@night.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@night.example', org, 'srv1@night.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@night.example', org, 'vera@night.example', 'verifier', venue_a, ver_a);
  perform tests.join_as(mgr_a, 'mgra@night.example', org, 'sec1@night.example', 'security', venue_a, sec_1);
  perform tests.logout();

  ---------------------------------------------------------------- a night of figures at Club A (and a little at Club B)
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 9) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 9) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;
  b1 := tests.mkbooking(venue_a, type_a, slot_a, night, 'Ada Evening', 10000, 10000);
  b2 := tests.mkbooking(venue_a, type_a, slot_a, night, 'Zed Evening', 6000, 3800);
  b_b := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bee Bee', 5000, 5000);
  p1 := tests.mkpay(b1, 6000, 'cash', srv_1);
  p2 := tests.mkpay(b1, 4000, 'debit', srv_1);
  p3 := tests.mkpay(b2, 2000, 'cash', srv_1);
  p_orig := tests.mkpay(b2, 500, 'credit', srv_1);
  p_corr := tests.mkpay(b2, 300, 'credit', srv_1);
  update public.site_table_booking_club_payments set corrects_payment_id = p_orig where id = p_corr;
  p6 := tests.mkpay(b2, 1500, 'cash', mgr_a);
  p_b := tests.mkpay(b_b, 5000, 'cash', mgr_b);
  update public.site_table_booking_club_payments set manager_verified_at = now(), manager_verified_by = mgr_a where id = p1;
  update public.site_table_booking_club_payments set customer_confirmation_status = 'disputed' where id = p6;
  insert into public.site_table_booking_bottles (booking_id, bottle_name, unit_price_cents, quantity, line_total_cents, payment_status, service_status) values
    (b1, 'Bottle A', 5000, 1, 5000, 'paid', 'served'), (b1, 'Bottle B', 3000, 1, 3000, 'paid', 'awaiting_prep'), (b2, 'Bottle D', 2000, 1, 2000, 'due_at_venue', 'preparing');
  insert into public.site_table_booking_bottles (booking_id, bottle_name, unit_price_cents, quantity, line_total_cents, payment_status, service_status, cancelled_at)
    values (b1, 'Bottle C', 1000, 1, 1000, 'paid', 'awaiting_prep', now());
  insert into public.site_service_requests (venue_id, booking_id, kind, source) values (venue_a, b1, 'assistance', 'staff');
  insert into public.site_service_requests (venue_id, booking_id, kind, source, status, closed_at) values (venue_a, b2, 'bill_request', 'staff', 'completed', now());
  insert into public.site_booking_seating (booking_id, seated_by, method) values (b1, srv_1, 'scan');
  insert into public.site_cash_handovers (venue_id, business_night, from_user, claimed_cents, status, received_by, received_at, counted_cents, receive_note)
    values (venue_a, night, srv_1, 8000, 'acknowledged', ver_a, now(), 7900, 'one note was torn');
  insert into public.site_payment_flags (payment_id, venue_id, raised_by, reason) values (p2, venue_a, ver_a, 'the card slip does not match') returning id into flag1;
  insert into public.site_payment_flags (payment_id, venue_id, raised_by, reason, status, resolved_by, resolved_at, resolution)
    values (p3, venue_a, ver_a, 'amount looked off', 'resolved', mgr_a, now(), 'confirmed_ok');
  insert into public.site_security_alerts (venue_id, business_night, kind, urgent, location, raised_by) values (venue_a, night, 'fight', true, 'Terrace', srv_1);
  insert into public.site_security_alerts (venue_id, business_night, kind, location, raised_by, status, resolved_by, resolved_at, acknowledged_by, acknowledged_at, resolution_note)
    values (venue_a, night, 'medical', 'Dance floor', srv_1, 'resolved', sec_1, now(), sec_1, now(), 'first aid given');
  insert into public.site_security_tasks (venue_id, business_night, title, created_by) values (venue_a, night, 'Check the fire exits', mgr_a);
  insert into public.site_security_incidents (venue_id, business_night, kind, occurred_at, location, details, reported_by)
    values (venue_a, night, 'fight', now() - interval '1 hour', 'Terrace', 'Two guests fought near the bar; one had a cut lip.', sec_1);

  ---------------------------------------------------------------- the checklist
  r := tests.run_as(mgr_a, 'mgra@night.example', format($q$select count(*)::text || ' ' || count(*) filter (where done)::text from public.night_checklist(%L, %L)$q$, venue_a, night));
  perform tests.assert_eq('nine items, none ticked', r, '9 0');
  perform tests.assert_eq('the manager ticks one', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_check(%L, %L, 'floor_ready', true)::text$q$, venue_a, night)), 'true');
  perform tests.assert_eq('ticking again changes nothing', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_check(%L, %L, 'floor_ready', true)::text$q$, venue_a, night)), 'false');
  perform tests.assert_eq('the item shows who ticked it', tests.run_as(owner_u, 'owner@night.example', format($q$select done_by_name from public.night_checklist(%L, %L) where item_key = 'floor_ready'$q$, venue_a, night)), 'Mia Manager');
  perform tests.assert_eq('unticking', tests.run_as(owner_u, 'owner@night.example', format($q$select public.night_check(%L, %L, 'floor_ready', false)::text$q$, venue_a, night)) || ' ' || tests.run_as(owner_u, 'owner@night.example', format($q$select public.night_check(%L, %L, 'floor_ready', false)::text$q$, venue_a, night)), 'true false');
  perform tests.assert_eq('a key that is not an item', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_check(%L, %L, 'make_tea', true)::text$q$, venue_a, night)), 'ERROR: choose a checklist item');
  perform tests.assert_eq('a server cannot tick', tests.run_as(srv_1, 'srv1@night.example', format($q$select public.night_check(%L, %L, 'floor_ready', true)::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor the verifier', tests.run_as(ver_a, 'vera@night.example', format($q$select public.night_check(%L, %L, 'floor_ready', true)::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s manager', tests.run_as(mgr_b, 'mgrb@night.example', format($q$select public.night_check(%L, %L, 'floor_ready', true)::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor can they read the checklist', tests.run_as(mgr_b, 'mgrb@night.example', format($q$select count(*)::text from public.night_checklist(%L, %L)$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('a night is required', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_check(%L, null, 'floor_ready', true)::text$q$, venue_a)), 'ERROR: choose a night');

  ---------------------------------------------------------------- what is still open
  j := tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_close_status(%L, %L)::text$q$, venue_a, night))::jsonb;
  perform tests.assert_eq('the night is open', j ->> 'status', 'open');
  perform tests.assert_eq('ten things are open, most important first', (select string_agg((e ->> 'key') || '=' || (e ->> 'count'), ' ') from jsonb_array_elements(j -> 'blockers') e),
    'payments_to_check=3 payments_disputed=1 flags_open=1 cash_held=1 orders_not_served=2 requests_open=1 balances_due=1 alerts_unresolved=1 tasks_open=1 incidents_to_review=1');
  perform tests.assert_eq('three closing items are not ticked', jsonb_array_length(j -> 'close_items_open'), 3);
  perform tests.assert_eq('a server cannot ask', tests.run_as(srv_1, 'srv1@night.example', format($q$select public.night_close_status(%L, %L)::text$q$, venue_a, night)), 'ERROR: not allowed');

  ---------------------------------------------------------------- the preliminary report, by role
  rep := tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_report(%L, %L)::text$q$, venue_a, night))::jsonb;
  perform tests.assert_eq('the manager sees everything', tests.keys(rep::text), 'bookings,bottles,business_night,cash,final,flags,generated_at,payments,security,service,venue_name,view');
  perform tests.assert_eq('...and it is preliminary', (rep ->> 'view') || ' ' || (rep ->> 'final'), 'full false');
  perform tests.assert_eq('bookings: two tables, four guests', (rep -> 'bookings' ->> 'count') || '/' || (rep -> 'bookings' ->> 'guests'), '2/4');
  perform tests.assert_eq('bookings: total, paid, balance, seated', concat_ws('/', rep -> 'bookings' ->> 'total_cents', rep -> 'bookings' ->> 'paid_cents', rep -> 'bookings' ->> 'balance_cents', rep -> 'bookings' ->> 'seated'), '16000/13800/2200/1');
  perform tests.assert_eq('payments: a correction replaces the payment it corrects (5 payments, not 6)', rep -> 'payments' ->> 'count', '5');
  perform tests.assert_eq('payments: collected, cash, debit, credit', concat_ws('/', rep -> 'payments' ->> 'collected_cents', rep -> 'payments' ->> 'cash_cents', rep -> 'payments' ->> 'debit_cents', rep -> 'payments' ->> 'credit_cents'), '13800/9500/4000/300');
  perform tests.assert_eq('payments: unverified, disputed, without receipt, corrections', concat_ws('/', rep -> 'payments' ->> 'unverified', rep -> 'payments' ->> 'disputed', rep -> 'payments' ->> 'no_receipt', rep -> 'payments' ->> 'corrections'), '4/1/5/1');
  perform tests.assert_eq('bottles: lines, value, served, in progress, awaiting, cancelled, due at the venue', concat_ws('/', rep -> 'bottles' ->> 'lines', rep -> 'bottles' ->> 'value_cents', rep -> 'bottles' ->> 'served', rep -> 'bottles' ->> 'in_progress', rep -> 'bottles' ->> 'awaiting', rep -> 'bottles' ->> 'cancelled', rep -> 'bottles' ->> 'due_at_venue'), '3/10000/1/1/1/1/1');
  perform tests.assert_eq('cash: handovers, claimed, counted, shortage, still held', concat_ws('/', rep -> 'cash' ->> 'handovers', rep -> 'cash' ->> 'claimed_cents', rep -> 'cash' ->> 'counted_cents', rep -> 'cash' ->> 'shortage_cents', rep -> 'cash' ->> 'held_cents'), '1/8000/7900/100/1500');
  perform tests.assert_eq('flags: raised, open, resolved, how', concat_ws('/', rep -> 'flags' ->> 'raised', rep -> 'flags' ->> 'open', rep -> 'flags' ->> 'resolved', rep -> 'flags' -> 'by_resolution' ->> 'confirmed_ok'), '2/1/1/1');
  perform tests.assert_eq('service: requests, open, completed', concat_ws('/', rep -> 'service' ->> 'total', rep -> 'service' ->> 'open', rep -> 'service' ->> 'completed'), '2/1/1');
  perform tests.assert_eq('security: alerts, urgent, unresolved, by kind', concat_ws('/', rep -> 'security' -> 'alerts' ->> 'total', rep -> 'security' -> 'alerts' ->> 'urgent', rep -> 'security' -> 'alerts' ->> 'unresolved', rep -> 'security' -> 'alerts' -> 'by_kind' ->> 'fight'), '2/1/1/1');
  perform tests.assert_eq('security: tasks and the incident list', concat_ws('/', rep -> 'security' -> 'tasks' ->> 'total', rep -> 'security' -> 'tasks' ->> 'open', rep -> 'security' -> 'incidents' -> 0 ->> 'kind', rep -> 'security' -> 'incidents' -> 0 ->> 'location'), '1/1/fight/Terrace');
  perform tests.assert_eq('the owner sees the same figures', tests.run_as(owner_u, 'owner@night.example', format($q$select (public.night_report(%L, %L) -> 'payments' ->> 'collected_cents')$q$, venue_a, night)), '13800');
  rep := tests.run_as(ver_a, 'vera@night.example', format($q$select public.night_report(%L, %L)::text$q$, venue_a, night))::jsonb;
  perform tests.assert_eq('the verifier sees the money and nothing about security, bottles or requests', tests.keys(rep::text), 'bookings,business_night,cash,final,flags,generated_at,payments,venue_name,view');
  perform tests.assert_eq('...as the finance view', rep ->> 'view', 'finance');
  rep := tests.run_as(sec_1, 'sec1@night.example', format($q$select public.night_report(%L, %L)::text$q$, venue_a, night))::jsonb;
  perform tests.assert_eq('security sees only the security section, no money', tests.keys(rep::text), 'business_night,final,generated_at,security,venue_name,view');
  perform tests.assert_eq('...as the security view', rep ->> 'view', 'security');
  perform tests.assert_eq('a server gets no report', tests.run_as(srv_1, 'srv1@night.example', format($q$select public.night_report(%L, %L)::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a stranger', tests.run_as(rando, 'rando@night.example', format($q$select public.night_report(%L, %L)::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s manager', tests.run_as(mgr_b, 'mgrb@night.example', format($q$select public.night_report(%L, %L)::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('Club B sees its own figures only', tests.run_as(mgr_b, 'mgrb@night.example', format($q$select concat_ws('/', public.night_report(%L, %L) -> 'bookings' ->> 'count', public.night_report(%L, %L) -> 'payments' ->> 'collected_cents', public.night_report(%L, %L) -> 'security' -> 'alerts' ->> 'total')$q$, venue_b, night, venue_b, night, venue_b, night)), '1/5000/0');

  ---------------------------------------------------------------- closing is refused while things are open
  r := tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.close_night(%L, %L)::text$q$, venue_a, night));
  perform tests.assert_true('the close lists what is open', r like 'ERROR: still open: 3 payments waiting to be checked, 1 payments disputed by the guest, %not ticked: Floor cleared and tables released%');
  perform tests.assert_eq('the same when asked to acknowledge nothing', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.close_night(%L, %L, false, 'because')::text$q$, venue_a, night)) like 'ERROR: still open:%', true);
  perform tests.assert_eq('acknowledging needs a reason', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.close_night(%L, %L, true)::text$q$, venue_a, night)), 'ERROR: say why you are closing with these still open (at least 10 characters)');
  perform tests.assert_eq('...a real one', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.close_night(%L, %L, true, 'too short')::text$q$, venue_a, night)), 'ERROR: say why you are closing with these still open (at least 10 characters)');
  perform tests.assert_eq('...and not a very long one', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.close_night(%L, %L, true, %L)::text$q$, venue_a, night, repeat('x', 501))), 'ERROR: keep the note to 500 characters or fewer');
  perform tests.assert_eq('a server cannot close the night', tests.run_as(srv_1, 'srv1@night.example', format($q$select public.close_night(%L, %L, true, 'closing it anyway now')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor security', tests.run_as(sec_1, 'sec1@night.example', format($q$select public.close_night(%L, %L, true, 'closing it anyway now')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s manager', tests.run_as(mgr_b, 'mgrb@night.example', format($q$select public.close_night(%L, %L, true, 'closing it anyway now')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('a night that has not started cannot be closed', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.close_night(%L, %L, true, 'closing it anyway now')::text$q$, venue_a, night + 3)), 'ERROR: a night that has not started cannot be closed');
  perform tests.assert_eq('nothing was closed by all that', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (public.night_close_status(%L, %L) ->> 'status')$q$, venue_a, night)), 'open');

  ---------------------------------------------------------------- closing with exceptions
  perform tests.assert_eq('the manager closes with exceptions and a reason: ten open things and three closing items', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (public.close_night(%L, %L, true, 'Owner agreed to chase the rest tomorrow')) ->> 'exceptions'$q$, venue_a, night)), '13');
  perform tests.assert_eq('the night is closed, by whom, with the exceptions kept', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (s ->> 'closed') || ' ' || (s ->> 'closed_by_name') || ' ' || jsonb_array_length(s -> 'exceptions') || ' ' || (s ->> 'exceptions_note') from (select public.night_close_status(%L, %L) s) x$q$, venue_a, night)),
    'true Mia Manager 13 Owner agreed to chase the rest tomorrow');
  perform tests.assert_eq('closing twice is refused', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.close_night(%L, %L, true, 'Owner agreed to chase the rest tomorrow')::text$q$, venue_a, night)), 'ERROR: this night is already closed');
  perform tests.assert_eq('...and so is the owner''s second try', tests.run_as(owner_u, 'owner@night.example', format($q$select public.close_night(%L, %L)::text$q$, venue_a, night)), 'ERROR: this night is already closed');
  perform tests.assert_eq('a closed night''s checklist is locked', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_check(%L, %L, 'floor_ready', true)::text$q$, venue_a, night)), 'ERROR: this night is closed: the owner has to reopen it first');
  perform tests.assert_eq('another night is untouched', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (public.night_close_status(%L, %L) ->> 'status')$q$, venue_a, night - 1)), 'open');

  ---------------------------------------------------------------- the final report does not move when the books do
  rep := tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_report(%L, %L)::text$q$, venue_a, night))::jsonb;
  perform tests.assert_eq('the report is final, with who closed it and the exceptions', concat_ws('/', rep ->> 'final', rep ->> 'closed_by_name', jsonb_array_length(rep -> 'exceptions')::text, rep ->> 'exceptions_note'), 'true/Mia Manager/13/Owner agreed to chase the rest tomorrow');
  perform tests.assert_eq('the verifier also sees the exceptions', tests.run_as(ver_a, 'vera@night.example', format($q$select jsonb_array_length(public.night_report(%L, %L) -> 'exceptions')::text$q$, venue_a, night)), '13');
  perform tests.assert_eq('security does not', tests.run_as(sec_1, 'sec1@night.example', format($q$select (public.night_report(%L, %L) ? 'exceptions')::text$q$, venue_a, night)), 'false');
  perform tests.assert_eq('...but sees that it is final', tests.run_as(sec_1, 'sec1@night.example', format($q$select (public.night_report(%L, %L) ->> 'final')$q$, venue_a, night)), 'true');
  perform tests.logout();
  perform tests.mkpay(b1, 99900, 'cash', srv_1);
  update public.site_security_alerts set status = 'resolved', resolved_by = sec_1, resolved_at = now(), acknowledged_by = sec_1, acknowledged_at = now(), resolution_note = 'later' where venue_id = venue_a and status = 'open';
  perform tests.assert_eq('money recorded after the close does not change the final report', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (public.night_report(%L, %L) -> 'payments' ->> 'collected_cents')$q$, venue_a, night)), '13800');
  perform tests.assert_eq('...nor does an alert resolved later', tests.run_as(sec_1, 'sec1@night.example', format($q$select (public.night_report(%L, %L) -> 'security' -> 'alerts' ->> 'unresolved')$q$, venue_a, night)), '1');
  perform tests.assert_eq('but the status shows what is open now', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (select e ->> 'count' from jsonb_array_elements(public.night_close_status(%L, %L) -> 'blockers') e where e ->> 'key' = 'alerts_unresolved')$q$, venue_a, night)), 'null');

  ---------------------------------------------------------------- reopening
  perform tests.assert_eq('a manager cannot reopen a night', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.reopen_night(%L, %L, 'we forgot to count the float')::text$q$, venue_a, night)), 'ERROR: not allowed');
  perform tests.assert_eq('the owner needs a reason', tests.run_as(owner_u, 'owner@night.example', format($q$select public.reopen_night(%L, %L, 'oops')::text$q$, venue_a, night)), 'ERROR: say why this night is being reopened (at least 10 characters)');
  perform tests.assert_eq('...a night that was never closed is not reopened', tests.run_as(owner_u, 'owner@night.example', format($q$select public.reopen_night(%L, %L, 'we forgot to count the float')::text$q$, venue_a, night - 1)), 'ERROR: this night is not closed');
  perform tests.assert_eq('the owner reopens it', tests.run_as(owner_u, 'owner@night.example', format($q$select public.reopen_night(%L, %L, 'we forgot to count the float')::text$q$, venue_a, night)), '');
  perform tests.assert_eq('...it is reopened, with the reason', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (s ->> 'status') || ' ' || (s ->> 'closed') || ' ' || (s ->> 'reopen_reason') from (select public.night_close_status(%L, %L) s) x$q$, venue_a, night)), 'reopened false we forgot to count the float');
  perform tests.assert_eq('...and the report is preliminary again, with the money recorded since', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (public.night_report(%L, %L) ->> 'final') || ' ' || (public.night_report(%L, %L) -> 'payments' ->> 'collected_cents')$q$, venue_a, night, venue_a, night)), 'false 113700');
  perform tests.assert_eq('it cannot be reopened twice', tests.run_as(owner_u, 'owner@night.example', format($q$select public.reopen_night(%L, %L, 'we forgot to count the float')::text$q$, venue_a, night)), 'ERROR: this night is not closed');
  perform tests.assert_eq('the checklist can be ticked again', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_check(%L, %L, 'floor_cleared', true)::text$q$, venue_a, night)), 'true');

  ---------------------------------------------------------------- a clean close needs no excuse
  perform tests.logout();
  update public.site_table_booking_club_payments set manager_verified_at = now(), customer_confirmation_status = 'pending', receipt_photo_path = 'x' where booking_id in (b1, b2);
  update public.site_payment_flags set status = 'resolved', resolved_by = mgr_a, resolved_at = now(), resolution = 'confirmed_ok' where id = flag1;
  update public.site_table_booking_bottles set service_status = 'served' where booking_id in (b1, b2);
  update public.site_service_requests set status = 'completed', closed_at = now() where status = 'new';
  update public.site_table_bookings set amount_paid_cents = amount_total_cents where id in (b1, b2);
  update public.site_security_tasks set status = 'done', closed_by = sec_1, closed_at = now() where status = 'open';
  update public.site_security_incidents set status = 'reviewed', reviewed_by = mgr_a, reviewed_at = now() where status = 'submitted';
  insert into public.site_cash_handovers (venue_id, business_night, from_user, claimed_cents, status, received_by, received_at, counted_cents)
    select venue_a, night, r.user_id, r.collected_cents - r.handed_in_cents, 'acknowledged', ver_a, now(), r.collected_cents - r.handed_in_cents
    from public.desk_cash_rows(venue_a, night) r where r.collected_cents - r.handed_in_cents > 0;
  perform tests.assert_eq('with everything dealt with, nothing is open except two closing items', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (s -> 'blockers')::text || ' ' || jsonb_array_length(s -> 'close_items_open') from (select public.night_close_status(%L, %L) s) x$q$, venue_a, night)), '[] 2');
  perform tests.assert_eq('an unticked closing item still stops it', tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.close_night(%L, %L)::text$q$, venue_a, night)), 'ERROR: still open: not ticked: Closing stock counted, not ticked: Cash counted and locked away. Deal with it, or close with exceptions and say why');
  perform tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_check(%L, %L, 'stock_counted', true)::text$q$, venue_a, night));
  perform tests.run_as(mgr_a, 'mgra@night.example', format($q$select public.night_check(%L, %L, 'cash_secured', true)::text$q$, venue_a, night));
  perform tests.assert_eq('then it closes with no exceptions and no reason asked for', tests.run_as(mgr_a, 'mgra@night.example', format($q$select (public.close_night(%L, %L, false, 'a note nobody needs')) ->> 'exceptions'$q$, venue_a, night)), '0');
  perform tests.assert_eq('...the note is not kept when there was nothing to excuse', tests.run_as(mgr_a, 'mgra@night.example', format($q$select coalesce(s ->> 'exceptions_note', 'none') || ' ' || jsonb_array_length(s -> 'exceptions') from (select public.night_close_status(%L, %L) s) x$q$, venue_a, night)), 'none 0');
  perform tests.logout();
  perform tests.assert_eq('it is the second close of that night', (select close_count from public.site_night_closes where venue_id = venue_a and business_night = night), 2);
  perform tests.assert_eq('the new final report has the settled figures', (select report -> 'payments' ->> 'collected_cents' from public.site_night_closes where venue_id = venue_a and business_night = night), '113700');

  ---------------------------------------------------------------- Club B closes on its own
  perform tests.assert_eq('club B''s manager closes club B with no checklist ticked, by acknowledging', tests.run_as(mgr_b, 'mgrb@night.example', format($q$select (public.close_night(%L, %L, true, 'new club, nothing set up yet')) ->> 'exceptions'$q$, venue_b, night)) is not null, true);
  perform tests.logout();
  perform tests.assert_eq('...and that did not touch club A', (select count(*) from public.site_night_closes where venue_id = venue_a)::int, 1);

  ---------------------------------------------------------------- kept, and logged
  perform tests.assert_raises('a club with closed nights cannot be deleted', format('delete from public.site_venues where id = %L', venue_a), 'violates foreign key constraint');
  perform tests.assert_eq('closing and reopening are in the audit log with who did it', (select count(*) from public.audit_log where action in ('night.closed', 'night.reopened') and entity_id = venue_a::text and actor_id in (mgr_a, owner_u))::int, 3);
  perform tests.assert_eq('the first close''s figures are kept in the log', (select count(*) from public.audit_log where action = 'night.closed' and entity_id = venue_a::text and details -> 'report' -> 'payments' ->> 'collected_cents' = '13800')::int, 1);

  ---------------------------------------------------------------- closed to clients
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot read a report', format('select public.night_report(%L, %L)', venue_a, night), 'permission denied');
  perform tests.assert_raises('...or close a night', format($q$select public.close_night(%L, %L, true, 'closing it anyway now')$q$, venue_a, night), 'permission denied');
  perform tests.logout();
  perform tests.login(mgr_a, 'mgra@night.example');
  perform tests.assert_raises('the tables cannot be read directly', 'select * from public.site_night_closes', 'permission denied');
  perform tests.assert_raises('...nor the ticks', 'select * from public.site_night_checks', 'permission denied');
  perform tests.assert_raises('the figures helper cannot be called', format('select public.night_report_data(%L, %L)', venue_a, night), 'permission denied');
  perform tests.assert_raises('...nor the list of open things', format('select public.night_blockers(%L, %L)', venue_a, night), 'permission denied');
  perform tests.logout();
end $$;

rollback;
