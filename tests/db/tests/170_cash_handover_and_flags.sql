-- Cash handed in at the end of a night, and payments flagged for a manager. What matters most: cash held is worked out from the recorded
-- payments (cash, and the cash parts of a split; not cards; only that business night, only that club); a person hands in at most what they
-- hold and never the same cash twice; a server sees only their own cash, while the manager, owner and verifier of THAT club see all of it;
-- someone else counts what was handed in, a difference is kept and explained, and nothing is acknowledged twice; a payment has one open
-- flag at a time, nobody flags their own entry, only a manager or owner resolves; and every step is attributed.
-- (The production-only payments table comes from tests/db/prod_shapes.)
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int default 1000) returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, p_total, 0, 'paid', upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkcash(p_booking uuid, p_paid int, p_method text, p_by uuid, p_split jsonb default null) returns uuid language sql security definer as $$
  insert into public.site_table_booking_club_payments (booking_id, billed_amount_cents, amount_paid_cents, payment_method, split_breakdown, recorded_by, missing_receipt_reason)
  values (p_booking, p_paid, p_paid, p_method, p_split, p_by, 'seeded')
  returning id $$;
create function tests.pos(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(concat_ws(':', collector_name, case when is_me then 'me' else 'other' end, collected_cents, handed_in_cents, held_cents), ' | ' order by collector_name)
                   from public.desk_cash_position(p_venue, p_night)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.submit(p_user uuid, p_email text, p_venue uuid, p_night date, p_amount int, p_note text default null) returns text language plpgsql as $$
declare id uuid;
begin
  perform tests.login(p_user, p_email);
  id := public.desk_submit_handover(p_venue, p_night, p_amount, p_note);
  return 'ok:' || id::text;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.handovers(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(concat_ws(':', collector_name, claimed_cents, status, coalesce(counted_cents::text, '-'), coalesce(difference_cents::text, '-')), ' | ' order by submitted_at, claimed_cents)
                   from public.desk_list_handovers(p_venue, p_night)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.receive(p_user uuid, p_email text, p_handover uuid, p_counted int, p_note text default null) returns text language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  r := public.desk_receive_handover(p_handover, p_counted, p_note);
  return 'ok:' || (r ->> 'difference_cents');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.flag(p_user uuid, p_email text, p_payment uuid, p_reason text) returns text language plpgsql as $$
declare id uuid;
begin
  perform tests.login(p_user, p_email);
  id := public.desk_flag_payment(p_payment, p_reason);
  return 'ok:' || id::text;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.resolve(p_user uuid, p_email text, p_flag uuid, p_resolution text, p_note text default null) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  perform public.desk_resolve_flag(p_flag, p_resolution, p_note);
  return 'ok';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.flags(p_user uuid, p_email text, p_venue uuid, p_status text default 'open') returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(concat_ws(':', customer_name, status, coalesce(resolution, '-'), raised_by_name, coalesce(resolved_by_name, '-')), ' | ' order by raised_at, customer_name)
                   from public.desk_list_flags(p_venue, p_status)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.audit_count(p_prefix text, p_entity uuid) returns int language sql security definer as $$
  select count(*)::int from public.audit_log where action like p_prefix || '%' and entity_id = p_entity::text $$;
create function tests.sub(p_text text) returns text language sql immutable as $$ select substr(p_text, 1, 6) $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000001d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000001d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000001d3';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000001d4';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000001d5';
  door_a constant uuid := '00000000-0000-0000-0000-0000000001d6';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000001d7';
  ver_b constant uuid := '00000000-0000-0000-0000-0000000001d8';
  srv_b constant uuid := '00000000-0000-0000-0000-0000000001d9';
  rando constant uuid := '00000000-0000-0000-0000-0000000001da';
  org uuid; venue_a uuid; venue_b uuid; type_a uuid; type_b uuid; slot_eve uuid; slot_late uuid; slot_b uuid;
  b1 uuid; b2 uuid; b_late uuid; b_other uuid; b_b uuid;
  p1 uuid; p2 uuid; p3 uuid; p4 uuid; p5 uuid; p8 uuid; p_other uuid; p_b uuid;
  h1 uuid; h2 uuid; h3 uuid; h4 uuid; f1 uuid; f2 uuid; f3 uuid; txt text; n int;
  night date := current_date + 20;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@cash.example'), (mgr_a, 'mgra@cash.example'), (srv_1, 'srv1@cash.example'), (srv_2, 'srv2@cash.example'),
    (ver_a, 'vera@cash.example'), (door_a, 'doora@cash.example'), (mgr_b, 'mgrb@cash.example'), (ver_b, 'verb@cash.example'),
    (srv_b, 'srvb@cash.example'), (rando, 'rando@cash.example');
  -- srv_2 has no profile on purpose: the name falls back to "Staff member".
  insert into public.profiles (id, name, email) values (srv_1, 'Sam Server', 'srv1@cash.example'), (mgr_a, 'Mia Manager', 'mgra@cash.example'), (ver_a, 'Vera Verifier', 'vera@cash.example');

  ---------------------------------------------------------------- set up: a business with two clubs, staff in each
  perform tests.login(owner_u, 'owner@cash.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@cash.example', org, 'mgra@cash.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@cash.example', org, 'mgrb@cash.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@cash.example', org, 'srv1@cash.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@cash.example', org, 'srv2@cash.example', 'server', venue_a, srv_2);
  perform tests.join_as(mgr_a, 'mgra@cash.example', org, 'vera@cash.example', 'verifier', venue_a, ver_a);
  perform tests.join_as(mgr_a, 'mgra@cash.example', org, 'doora@cash.example', 'door', venue_a, door_a);
  perform tests.join_as(mgr_b, 'mgrb@cash.example', org, 'verb@cash.example', 'verifier', venue_b, ver_b);
  perform tests.join_as(mgr_b, 'mgrb@cash.example', org, 'srvb@cash.example', 'server', venue_b, srv_b);
  perform tests.logout();

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 9) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 9) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 0, '01:00', 'After midnight') returning id into slot_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;

  b1 := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Ada Evening');
  b2 := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Zed Evening');
  b_late := tests.mkbooking(venue_a, type_a, slot_late, night + 1, 'Late Lena');     -- 01:00 the next calendar day: still tonight's business night
  b_other := tests.mkbooking(venue_a, type_a, slot_eve, night + 3, 'Other Olga');   -- another night
  b_b := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bee Bee');                 -- another club
  p1 := tests.mkcash(b1, 5000, 'cash', srv_1);
  p2 := tests.mkcash(b2, 2500, 'cash', srv_1);
  p3 := tests.mkcash(b1, 4000, 'debit', srv_1);
  p4 := tests.mkcash(b2, 1500, 'split', srv_2, '[{"method":"cash","cents":1000},{"method":"credit","cents":500}]'::jsonb);
  p5 := tests.mkcash(b_late, 300, 'cash', srv_1);
  p_other := tests.mkcash(b_other, 9999, 'cash', srv_1);
  p_b := tests.mkcash(b_b, 7000, 'cash', mgr_b);
  p8 := tests.mkcash(b2, 2000, 'cash', mgr_a);

  ---------------------------------------------------------------- cash held is worked out from the payments
  perform tests.assert_eq('a server holds the cash they recorded that night: cash and the cash part of a split count, a card does not, the after-midnight booking is tonight, another night and another club do not',
    tests.pos(srv_1, 'srv1@cash.example', venue_a, night), 'Sam Server:me:7800:0:7800');
  perform tests.assert_eq('a server sees only their own line, and a person with no profile is "Staff member"',
    tests.pos(srv_2, 'srv2@cash.example', venue_a, night), 'Staff member:me:1000:0:1000');
  perform tests.assert_eq('the manager sees everyone''s cash at the club',
    tests.pos(mgr_a, 'mgra@cash.example', venue_a, night), 'Mia Manager:me:2000:0:2000 | Sam Server:other:7800:0:7800 | Staff member:other:1000:0:1000');
  perform tests.assert_eq('the verifier sees everyone''s cash at the club',
    tests.pos(ver_a, 'vera@cash.example', venue_a, night), 'Mia Manager:other:2000:0:2000 | Sam Server:other:7800:0:7800 | Staff member:other:1000:0:1000');
  perform tests.assert_eq('the owner sees everyone''s cash at the club',
    tests.pos(owner_u, 'owner@cash.example', venue_a, night), 'Mia Manager:other:2000:0:2000 | Sam Server:other:7800:0:7800 | Staff member:other:1000:0:1000');
  perform tests.assert_eq('another club''s cash is its own: its manager sees it as theirs',
    tests.pos(mgr_b, 'mgrb@cash.example', venue_b, night), 'Staff member:me:7000:0:7000');
  perform tests.assert_eq('...and its verifier sees the same line as somebody else''s, and nothing of club A',
    tests.pos(ver_b, 'verb@cash.example', venue_b, night), 'Staff member:other:7000:0:7000');
  perform tests.assert_eq('another club''s manager cannot look at this club', tests.pos(mgr_b, 'mgrb@cash.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('door staff cannot see cash', tests.pos(door_a, 'doora@cash.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.pos(rando, 'rando@cash.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('a night is required', tests.pos(srv_1, 'srv1@cash.example', venue_a, null), 'ERROR: choose a night');
  perform tests.assert_eq('a quiet night has no lines', tests.pos(srv_1, 'srv1@cash.example', venue_a, night + 8), '(none)');

  ---------------------------------------------------------------- handing in
  perform tests.assert_eq('nothing is handed in for nothing', tests.submit(srv_1, 'srv1@cash.example', venue_a, night, 0), 'ERROR: enter the amount you are handing over');
  perform tests.assert_eq('...or for a negative amount', tests.submit(srv_1, 'srv1@cash.example', venue_a, night, -5), 'ERROR: enter the amount you are handing over');
  perform tests.assert_eq('...or for no amount', tests.submit(srv_1, 'srv1@cash.example', venue_a, night, null), 'ERROR: enter the amount you are handing over');
  perform tests.assert_eq('a person cannot hand in more than they hold', tests.submit(srv_1, 'srv1@cash.example', venue_a, night, 7801), 'ERROR: you only hold 78.00 for this night');
  perform tests.assert_eq('...nor a note that is too long', tests.submit(srv_1, 'srv1@cash.example', venue_a, night, 100, repeat('x', 301)), 'ERROR: keep the note to 300 characters or fewer');
  perform tests.assert_eq('a person with no cash cannot hand any in', tests.submit(ver_a, 'vera@cash.example', venue_a, night, 100), 'ERROR: you are not holding any cash for this night');
  perform tests.assert_eq('...nor can a server from another club', tests.submit(srv_b, 'srvb@cash.example', venue_a, night, 100), 'ERROR: not allowed');
  perform tests.assert_eq('...nor door staff', tests.submit(door_a, 'doora@cash.example', venue_a, night, 100), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a stranger', tests.submit(rando, 'rando@cash.example', venue_a, night, 100), 'ERROR: not allowed');
  txt := tests.submit(srv_1, 'srv1@cash.example', venue_a, night, 3000, 'first part');
  perform tests.assert_true('part of the cash can be handed in', txt like 'ok:%');
  h1 := substr(txt, 4)::uuid;
  perform tests.assert_eq('what is held drops by what was handed in', tests.pos(srv_1, 'srv1@cash.example', venue_a, night), 'Sam Server:me:7800:3000:4800');
  perform tests.assert_eq('...and no more than the rest can follow', tests.submit(srv_1, 'srv1@cash.example', venue_a, night, 4801), 'ERROR: you only hold 48.00 for this night');
  txt := tests.submit(srv_1, 'srv1@cash.example', venue_a, night, 4800);
  perform tests.assert_true('the rest can be handed in', txt like 'ok:%');
  h2 := substr(txt, 4)::uuid;
  perform tests.assert_eq('with everything handed in nothing is held', tests.pos(srv_1, 'srv1@cash.example', venue_a, night), 'Sam Server:me:7800:7800:0');
  perform tests.assert_eq('...and a third handover finds nothing to hand in', tests.submit(srv_1, 'srv1@cash.example', venue_a, night, 1), 'ERROR: you are not holding any cash for this night');
  perform tests.assert_eq('a server sees their own handovers, oldest first', tests.handovers(srv_1, 'srv1@cash.example', venue_a, night),
    'Sam Server:3000:submitted:-:- | Sam Server:4800:submitted:-:-');
  perform tests.assert_eq('...another server sees none of them', tests.handovers(srv_2, 'srv2@cash.example', venue_a, night), '(none)');
  perform tests.assert_eq('...the verifier sees them', tests.handovers(ver_a, 'vera@cash.example', venue_a, night), 'Sam Server:3000:submitted:-:- | Sam Server:4800:submitted:-:-');
  perform tests.assert_eq('...and another club''s verifier cannot', tests.handovers(ver_b, 'verb@cash.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('...nor can door staff', tests.handovers(door_a, 'doora@cash.example', venue_a, night), 'ERROR: not allowed');

  txt := tests.submit(mgr_a, 'mgra@cash.example', venue_a, night, 2000);
  perform tests.assert_true('a manager can hand in cash they collected', txt like 'ok:%');
  h3 := substr(txt, 4)::uuid;

  ---------------------------------------------------------------- acknowledging
  perform tests.assert_eq('you cannot count your own handover', tests.receive(mgr_a, 'mgra@cash.example', h3, 2000), 'ERROR: you handed this in, so someone else has to count it');
  perform tests.assert_eq('a server cannot acknowledge a handover', tests.receive(srv_2, 'srv2@cash.example', h1, 3000), 'ERROR: not allowed');
  perform tests.assert_eq('...nor can another club''s verifier', tests.receive(ver_b, 'verb@cash.example', h1, 3000), 'ERROR: not allowed');
  perform tests.assert_eq('...nor door staff', tests.receive(door_a, 'doora@cash.example', h1, 3000), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a handover that does not exist', tests.receive(ver_a, 'vera@cash.example', gen_random_uuid(), 3000), 'ERROR: not allowed');
  perform tests.assert_eq('an amount is required', tests.receive(ver_a, 'vera@cash.example', h1, null), 'ERROR: enter the amount you counted');
  perform tests.assert_eq('...and it cannot be negative', tests.receive(ver_a, 'vera@cash.example', h1, -1), 'ERROR: enter the amount you counted');
  perform tests.assert_eq('a shortage needs a reason', tests.receive(ver_a, 'vera@cash.example', h1, 2900), 'ERROR: the amount counted differs from the amount handed in: say why');
  perform tests.assert_eq('...a too-short reason is not one', tests.receive(ver_a, 'vera@cash.example', h1, 2900, 'x'), 'ERROR: the amount counted differs from the amount handed in: say why');
  perform tests.assert_eq('the shortage is kept as it is, with its reason', tests.receive(ver_a, 'vera@cash.example', h1, 2900, 'a note was torn'), 'ok:-100');
  perform tests.assert_eq('an acknowledged handover cannot be acknowledged again', tests.receive(ver_a, 'vera@cash.example', h1, 3000), 'ERROR: this handover was already acknowledged');
  perform tests.assert_eq('...not even by the manager', tests.receive(mgr_a, 'mgra@cash.example', h1, 2900, 'again'), 'ERROR: this handover was already acknowledged');
  perform tests.assert_eq('a matching count needs no reason', tests.receive(ver_a, 'vera@cash.example', h3, 2000), 'ok:0');
  perform tests.assert_eq('an overage is kept too', tests.receive(mgr_a, 'mgra@cash.example', h2, 4900, 'tip jar mixed in'), 'ok:100');
  perform tests.assert_eq('the list shows what was counted and the differences', tests.handovers(ver_a, 'vera@cash.example', venue_a, night),
    'Mia Manager:2000:acknowledged:2000:0 | Sam Server:3000:acknowledged:2900:-100 | Sam Server:4800:acknowledged:4900:100');  -- (one test transaction = one timestamp, so the helper orders by amount)
  perform tests.assert_eq('what was handed in is not changed by the count', tests.pos(ver_a, 'vera@cash.example', venue_a, night),
    'Mia Manager:other:2000:2000:0 | Sam Server:other:7800:7800:0 | Staff member:other:1000:0:1000');

  ---------------------------------------------------------------- flagged payments
  perform tests.assert_eq('a verifier flags a payment with a reason', substr(tests.flag(ver_a, 'vera@cash.example', p3, 'the till says 38.00'), 1, 3), 'ok:');
  perform tests.logout();
  select f.id into f1 from public.site_payment_flags f where f.payment_id = p3 and f.status = 'open';
  perform tests.assert_eq('a payment that is already flagged cannot be flagged again', tests.flag(mgr_a, 'mgra@cash.example', p3, 'second opinion'), 'ERROR: this payment is already flagged');
  perform tests.assert_eq('a reason is required', tests.flag(ver_a, 'vera@cash.example', p1, ''), 'ERROR: say what is wrong with this payment');
  perform tests.assert_eq('...and it has to say something', tests.flag(ver_a, 'vera@cash.example', p1, 'x'), 'ERROR: say what is wrong with this payment');
  perform tests.assert_eq('...and not too much', tests.flag(ver_a, 'vera@cash.example', p1, repeat('x', 501)), 'ERROR: keep the reason to 500 characters or fewer');
  perform tests.assert_eq('nobody flags their own entry', tests.flag(mgr_a, 'mgra@cash.example', p8, 'my own'), 'ERROR: you recorded this payment, so someone else has to flag it');
  perform tests.assert_eq('a server cannot flag', tests.flag(srv_2, 'srv2@cash.example', p1, 'no'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor can door staff', tests.flag(door_a, 'doora@cash.example', p1, 'no'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s verifier', tests.flag(ver_b, 'verb@cash.example', p1, 'no'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor can a payment that does not exist be flagged', tests.flag(ver_a, 'vera@cash.example', gen_random_uuid(), 'no'), 'ERROR: not allowed');
  perform tests.assert_eq('the verifier sees the open flag', tests.flags(ver_a, 'vera@cash.example', venue_a), 'Ada Evening:open:-:Vera Verifier:-');
  perform tests.assert_eq('...and so does the manager', tests.flags(mgr_a, 'mgra@cash.example', venue_a), 'Ada Evening:open:-:Vera Verifier:-');
  perform tests.assert_eq('a server does not', tests.flags(srv_1, 'srv1@cash.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager does not', tests.flags(mgr_b, 'mgrb@cash.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('...and their own club has none', tests.flags(mgr_b, 'mgrb@cash.example', venue_b), '(none)');
  perform tests.assert_eq('a status has to be open or resolved', tests.flags(ver_a, 'vera@cash.example', venue_a, 'done'), 'ERROR: choose open or resolved');
  perform tests.assert_eq('nothing is resolved yet', tests.flags(ver_a, 'vera@cash.example', venue_a, 'resolved'), '(none)');

  perform tests.assert_eq('a verifier cannot resolve a flag', tests.resolve(ver_a, 'vera@cash.example', f1, 'confirmed_ok'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a server', tests.resolve(srv_1, 'srv1@cash.example', f1, 'confirmed_ok'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s manager', tests.resolve(mgr_b, 'mgrb@cash.example', f1, 'confirmed_ok'), 'ERROR: not allowed');
  perform tests.assert_eq('an outcome is required', tests.resolve(mgr_a, 'mgra@cash.example', f1, null), 'ERROR: choose how it was resolved');
  perform tests.assert_eq('...and it must be a known one', tests.resolve(mgr_a, 'mgra@cash.example', f1, 'ignored'), 'ERROR: choose how it was resolved');
  perform tests.assert_eq('a correction needs a note', tests.resolve(mgr_a, 'mgra@cash.example', f1, 'corrected'), 'ERROR: say what was done');
  perform tests.assert_eq('the manager resolves it with what was done', tests.resolve(mgr_a, 'mgra@cash.example', f1, 'corrected', 'amount fixed to 38.00'), 'ok');
  perform tests.assert_eq('a resolved flag cannot be resolved again', tests.resolve(owner_u, 'owner@cash.example', f1, 'confirmed_ok'), 'ERROR: this flag was already resolved');
  perform tests.assert_eq('the open list is empty again', tests.flags(ver_a, 'vera@cash.example', venue_a), '(none)');
  perform tests.assert_eq('the resolved list says who did what', tests.flags(ver_a, 'vera@cash.example', venue_a, 'resolved'), 'Ada Evening:resolved:corrected:Vera Verifier:Mia Manager');
  perform tests.assert_eq('a payment can be flagged again once its flag is resolved', substr(tests.flag(mgr_a, 'mgra@cash.example', p3, 'still looks off'), 1, 3), 'ok:');
  perform tests.logout();
  select f.id into f2 from public.site_payment_flags f where f.payment_id = p3 and f.status = 'open';
  perform tests.assert_eq('"confirmed ok" needs no note, and the owner may resolve', tests.resolve(owner_u, 'owner@cash.example', f2, 'confirmed_ok'), 'ok');

  ---------------------------------------------------------------- the verifier's summary
  perform tests.login(ver_a, 'vera@cash.example');
  perform public.desk_flag_payment(p4, 'split does not add up');
  perform tests.assert_eq('the summary counts the night''s payments (not another night or club)',
    (select concat_ws('|', payments_recorded, payments_checked, payments_to_check, payments_disputed, checked_by_me, flags_open, flags_resolved, handovers_waiting, handovers_acknowledged, cash_difference_cents)
     from public.desk_verifier_summary(venue_a, night)), '6|0|6|0|0|1|2|0|3|0');
  perform tests.logout();
  perform tests.login(srv_1, 'srv1@cash.example');
  perform tests.assert_raises('a server cannot read the summary', format($q$select * from public.desk_verifier_summary(%L, %L)$q$, venue_a, night), 'not allowed');
  perform tests.logout();

  ---------------------------------------------------------------- attribution
  perform tests.assert_eq('each handover submitted is in the audit log', (select count(*) from public.audit_log where action = 'cash.handover_submitted' and entity_id in (h1::text, h2::text, h3::text))::int, 3);
  perform tests.assert_eq('each handover acknowledged is in the audit log, with the difference', (select count(*) from public.audit_log where action = 'cash.handover_received' and entity_id = h1::text and details ->> 'difference_cents' = '-100')::int, 1);
  perform tests.assert_eq('flags and their resolution are in the audit log', (select count(*) from public.audit_log where action in ('payment.flagged', 'payment.flag_resolved'))::int, 5);  -- three flagged, two resolved

  ---------------------------------------------------------------- a correction replaces the payment it corrects
  declare
    b_fix uuid; pc1 uuid; pc2 uuid; pc3 uuid; pc4 uuid;
  begin
    b_fix := tests.mkbooking(venue_a, type_a, slot_eve, night + 15, 'Correction Cora');
    pc1 := tests.mkcash(b_fix, 3000, 'cash', srv_1);
    pc2 := tests.mkcash(b_fix, 2500, 'cash', srv_1);
    update public.site_table_booking_club_payments set corrects_payment_id = pc1 where id = pc2;
    perform tests.assert_eq('a corrected payment counts once, as the correction',
      tests.pos(srv_1, 'srv1@cash.example', venue_a, night + 15), 'Sam Server:me:2500:0:2500');
    perform tests.logout();
    pc3 := tests.mkcash(b_fix, 1000, 'cash', srv_2);
    pc4 := tests.mkcash(b_fix, 800, 'cash', mgr_a);
    update public.site_table_booking_club_payments set corrects_payment_id = pc3 where id = pc4;
    perform tests.assert_eq('...even when someone else recorded the correction: the cash moves to them, and the first person no longer holds it',
      tests.pos(mgr_a, 'mgra@cash.example', venue_a, night + 15), 'Mia Manager:me:800:0:800 | Sam Server:other:2500:0:2500');
  end;

  ---------------------------------------------------------------- closed to clients
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot read the cash position', format($q$select * from public.desk_cash_position(%L, %L)$q$, venue_a, night), 'permission denied');
  perform tests.assert_raises('...or hand anything in', format($q$select public.desk_submit_handover(%L, %L, 100)$q$, venue_a, night), 'permission denied');
  perform tests.logout();
  perform tests.login(srv_1, 'srv1@cash.example');
  perform tests.assert_raises('the tables cannot be read directly', 'select * from public.site_cash_handovers', 'permission denied');
  perform tests.assert_raises('...or the flags', 'select * from public.site_payment_flags', 'permission denied');
  perform tests.assert_raises('the internal cash helper cannot be called', format($q$select * from public.desk_cash_rows(%L, %L)$q$, venue_a, night), 'permission denied');
  perform tests.logout();
end $$;

rollback;
