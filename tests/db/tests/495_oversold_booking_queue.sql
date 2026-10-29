-- A table paid for after it went to someone else (20261113100000_oversold_booking_queue.sql). What matters: the flag opens a conflict only for a PAID booking that makes
-- the paid bookings plus the held or unavailable tables more than the club has (the first guest is never flagged, a cancelled or pending booking never counts, an ended or
-- released hold does not count, another date, time or kind of table is separate); asking again changes nothing; only the service role can ask; only the club's own manager
-- or owner can list or close one (not a server, the door, another club's manager, a stranger or a visitor); closing one checks the facts (moved only if it no longer
-- overbooks, refunded only if refunded or cancelled), needs a few words, can be done once, and is logged; and the table cannot be read or written directly.
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
-- ask the flag as the service role
create function tests.flag(p_booking uuid) returns text language plpgsql as $$
declare r boolean;
begin
  perform tests.login_service();
  r := public.site_flag_oversold_booking(p_booking);
  perform tests.logout();
  return r::text;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.as_user(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
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
create function tests.resolve(p_user uuid, p_email text, p_conflict uuid, p_how text, p_note text) returns text language plpgsql as $$
begin
  return tests.as_user(p_user, p_email, format($q$select public.desk_resolve_booking_conflict(%L, %L, %L)::text$q$, p_conflict, p_how, p_note));
end $$;
create function tests.listed(p_user uuid, p_email text, p_venue uuid, p_all boolean default false) returns text language plpgsql as $$
declare n int;
begin
  perform tests.login(p_user, p_email);
  select count(*)::int into n from public.desk_booking_conflicts(p_venue, p_all);
  perform tests.logout();
  return n::text;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000008c1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000008c2';
  srv constant uuid := '00000000-0000-0000-0000-0000000008c3';
  door constant uuid := '00000000-0000-0000-0000-0000000008c4';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000008c5';
  rando constant uuid := '00000000-0000-0000-0000-0000000008c6';
  d constant date := current_date + 4;
  org uuid; venue_a uuid; venue_b uuid; t_one uuid; t_two uuid; t_spare uuid; s_eve uuid; s_late uuid;
  b1 uuid; b2 uuid; b3 uuid; c1 uuid; blk uuid; j record;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@conf.example'), (mgr_a, 'mgra@conf.example'), (srv, 'srv@conf.example'), (door, 'door@conf.example'),
    (mgr_b, 'mgrb@conf.example'), (rando, 'rando@conf.example');
  perform tests.login(owner_u, 'owner@conf.example');
  org := public.create_organization('Conflict Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@conf.example', org, 'mgra@conf.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@conf.example', org, 'mgrb@conf.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@conf.example', org, 'srv@conf.example', 'server', venue_a, srv);
  perform tests.join_as(mgr_a, 'mgra@conf.example', org, 'door@conf.example', 'door', venue_a, door);
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Last booth', 6, 0, 10000, 1) returning id into t_one;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Pair of tables', 4, 0, 5000, 2) returning id into t_two;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Spare table', 4, 0, 5000, 3) returning id into t_spare;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from d)::int, '21:00') returning id into s_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from d)::int, '23:00') returning id into s_late;

  ---------------------------------------------------------------- the first guest is never flagged, the late payer is
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, customer_phone, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code, confirmation_sent_at)
    values (venue_a, t_one, s_eve, d, 'First Guest', 'first@conf.example', '+1 555 0111', 4, 10000, 10000, 'paid', 'CF0001', now() - interval '20 minutes') returning id into b1;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, customer_phone, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (venue_a, t_one, s_eve, d, 'Late Payer', 'late@conf.example', '+1 555 0122', 2, 10000, 10000, 'paid', 'CF0002') returning id into b2;
  perform tests.assert_eq('the first guest to pay is not flagged', tests.flag(b1), 'false');
  perform tests.assert_eq('...and nothing is written for them', (select count(*)::int from public.site_booking_conflicts where booking_id = b1), 0);
  perform tests.assert_eq('a guest who has already been sent their confirmation is never flagged afterwards, even when the totals now say two for one', tests.flag(b1), 'false');
  perform tests.assert_eq('the guest whose payment made it two for one table is flagged', tests.flag(b2), 'true');
  select * into j from public.site_booking_conflicts where booking_id = b2;
  perform tests.assert_eq('the conflict says what was found',
    concat_ws('|', j.venue_id = venue_a, j.table_type_id = t_one, j.time_slot_id = s_eve, j.booking_date = d, j.kind, j.status, j.paid_count, j.inventory_count, j.resolution is null, j.resolved_at is null),
    't|t|t|t|oversold|open|2|1|t|t');
  c1 := j.id;
  perform tests.assert_eq('asking again gives the same answer', tests.flag(b2), 'true');
  perform tests.assert_eq('...and still one conflict', (select count(*)::int from public.site_booking_conflicts where booking_id = b2), 1);
  perform tests.assert_eq('a booking that does not exist is not flagged', tests.flag(gen_random_uuid()), 'false');
  update public.site_table_bookings set confirmation_sent_at = now() where id = b2;
  perform tests.assert_eq('once a conflict is open it stays open and is still reported, even if a confirmation went out by hand', tests.flag(b2), 'true');
  update public.site_table_bookings set confirmation_sent_at = null where id = b2;
  update public.site_table_bookings set confirmation_sent_at = null where id = b1;
  delete from public.site_booking_conflicts;
  perform tests.assert_eq('an earlier payer who has not been confirmed yet is flagged along with the later one (the manager sees both; the safe way round)', tests.flag(b1), 'true');
  delete from public.site_booking_conflicts;
  update public.site_table_bookings set confirmation_sent_at = now() - interval '20 minutes' where id = b1;
  perform tests.flag(b2);
  select id into c1 from public.site_booking_conflicts where booking_id = b2;

  ---------------------------------------------------------------- what does not count
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_two, s_eve, d, 'Still Paying', 'paying@conf.example', 2, 5000, 'pending') returning id into b3;
  perform tests.assert_eq('a booking still waiting for payment is never flagged', tests.flag(b3), 'false');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code, confirmation_sent_at)
    values (venue_a, t_two, s_eve, d, 'Two A', 'twoa@conf.example', 2, 5000, 'paid', 'CF0003', now()), (venue_a, t_two, s_eve, d, 'Two B', 'twob@conf.example', 2, 5000, 'paid', 'CF0004', now());
  update public.site_table_bookings set status = 'paid', confirmation_code = 'CF0005' where id = b3;
  perform tests.assert_eq('the third paid booking of a kind with two tables is flagged', tests.flag(b3), 'true');
  update public.site_table_bookings set status = 'cancelled' where customer_email = 'twoa@conf.example';
  delete from public.site_booking_conflicts where booking_id = b3;
  perform tests.assert_eq('a cancelled booking does not count, so the third is fine', tests.flag(b3), 'false');
  update public.site_table_bookings set status = 'refunded' where customer_email = 'twob@conf.example';
  perform tests.assert_eq('...nor a refunded one', tests.flag(b3), 'false');
  update public.site_table_bookings set status = 'paid' where customer_email in ('twoa@conf.example', 'twob@conf.example');
  perform tests.assert_eq('paid again, it counts once more', tests.flag(b3), 'true');
  delete from public.site_booking_conflicts where booking_id = b3;
  update public.site_table_bookings set status = 'refunded' where customer_email in ('twoa@conf.example', 'twob@conf.example');

  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code, confirmation_sent_at)
    values (venue_a, t_spare, s_eve, d, 'Spare 1', 's1@conf.example', 2, 5000, 'paid', 'CF0006', now()), (venue_a, t_spare, s_eve, d, 'Spare 2', 's2@conf.example', 2, 5000, 'paid', 'CF0007', now()), (venue_a, t_spare, s_eve, d, 'Spare 3', 's3@conf.example', 2, 5000, 'paid', 'CF0008', null);
  perform tests.assert_eq('three bookings for three tables are fine', tests.flag((select id from public.site_table_bookings where customer_email = 's3@conf.example')), 'false');
  insert into public.site_table_blocks (venue_id, table_type_id, time_slot_id, booking_date, kind, quantity, reason, created_by, expires_at)
    values (venue_a, t_spare, s_eve, d, 'held', 1, 'Held for the owner', mgr_a, now() + interval '1 hour') returning id into blk;
  perform tests.assert_eq('a table a manager is holding counts: three paid and one held is one too many', tests.flag((select id from public.site_table_bookings where customer_email = 's3@conf.example')), 'true');
  delete from public.site_booking_conflicts where booking_id = (select id from public.site_table_bookings where customer_email = 's3@conf.example');
  update public.site_table_blocks set released_at = now(), released_by = mgr_a where id = blk;
  perform tests.assert_eq('a released hold does not count', tests.flag((select id from public.site_table_bookings where customer_email = 's3@conf.example')), 'false');
  update public.site_table_blocks set released_at = null, released_by = null, expires_at = now() - interval '1 minute' where id = blk;
  perform tests.assert_eq('a hold that has ended does not count', tests.flag((select id from public.site_table_bookings where customer_email = 's3@conf.example')), 'false');
  delete from public.site_table_blocks where id = blk;
  insert into public.site_table_blocks (venue_id, table_type_id, time_slot_id, booking_date, kind, quantity, reason, created_by)
    values (venue_a, t_spare, s_eve, d, 'unavailable', 1, 'Booth being repaired', mgr_a);
  perform tests.assert_eq('a table taken out of use counts', tests.flag((select id from public.site_table_bookings where customer_email = 's3@conf.example')), 'true');
  delete from public.site_booking_conflicts where booking_id = (select id from public.site_table_bookings where customer_email = 's3@conf.example');
  delete from public.site_table_blocks where venue_id = venue_a;

  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue_a, t_one, s_late, d, 'Other Time', 'othertime@conf.example', 2, 10000, 'paid', 'CF0009') returning id into b3;
  perform tests.assert_eq('the same booth at another arrival time is free', tests.flag(b3), 'false');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue_a, t_one, s_eve, d + 7, 'Other Day', 'otherday@conf.example', 2, 10000, 'paid', 'CF0010') returning id into b3;
  perform tests.assert_eq('...and on another date', tests.flag(b3), 'false');

  ---------------------------------------------------------------- who may ask
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot ask', format('select public.site_flag_oversold_booking(%L)', b2), 'permission denied');
  perform tests.logout();
  perform tests.login(mgr_a, 'mgra@conf.example');
  perform tests.assert_raises('not even the club''s manager can ask (only the payment fulfilment does)', format('select public.site_flag_oversold_booking(%L)', b2), 'permission denied');
  perform tests.assert_raises('the table cannot be read directly', 'select * from public.site_booking_conflicts', 'permission denied');
  perform tests.assert_raises('...or written', format('update public.site_booking_conflicts set status = ''resolved'' where id = %L', c1), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the club's list
  perform tests.assert_eq('the manager sees the open conflicts of their club', tests.listed(mgr_a, 'mgra@conf.example', venue_a), '1');
  perform tests.assert_eq('the owner does too', tests.listed(owner_u, 'owner@conf.example', venue_a), '1');
  perform tests.login(mgr_a, 'mgra@conf.example');
  select * into j from public.desk_booking_conflicts(venue_a);
  perform tests.assert_eq('each row has what the manager needs to call the guest and settle it',
    concat_ws('|', j.conflict_id = c1, j.booking_id = b2, j.confirmation_code, j.customer_name, j.customer_email, j.customer_phone, j.table_name, j.arrival_date = d, j.arrival_time, j.guest_count,
      j.amount_paid_cents, j.currency, j.tables_counted, j.tables_available, j.status),
    't|t|CF0002|Late Payer|late@conf.example|+1 555 0122|Last booth|t|21:00:00|2|10000|cad|2|1|open');
  perform tests.logout();
  perform tests.assert_eq('a server cannot', tests.listed(srv, 'srv@conf.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('the door cannot', tests.listed(door, 'door@conf.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.listed(mgr_b, 'mgrb@conf.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.listed(rando, 'rando@conf.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('another club has none of its own', tests.listed(mgr_b, 'mgrb@conf.example', venue_b), '0');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format('select * from public.desk_booking_conflicts(%L)', venue_a), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- closing one: the words and who
  perform tests.assert_eq('a server cannot close one', tests.resolve(srv, 'srv@conf.example', c1, 'kept', 'The club found a table'), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.resolve(mgr_b, 'mgrb@conf.example', c1, 'kept', 'The club found a table'), 'ERROR: not allowed');
  perform tests.assert_eq('one that does not exist is "not allowed" like any other the person cannot reach', tests.resolve(mgr_a, 'mgra@conf.example', gen_random_uuid(), 'kept', 'The club found a table'), 'ERROR: not allowed');
  perform tests.assert_eq('an unknown way of settling it is refused', tests.resolve(mgr_a, 'mgra@conf.example', c1, 'ignored', 'The club found a table'), 'ERROR: say how it was settled: moved, refunded or kept');
  perform tests.assert_eq('so is none', tests.resolve(mgr_a, 'mgra@conf.example', c1, null, 'The club found a table'), 'ERROR: say how it was settled: moved, refunded or kept');
  perform tests.assert_eq('a note is needed', tests.resolve(mgr_a, 'mgra@conf.example', c1, 'kept', null), 'ERROR: say what was done, in a few words');
  perform tests.assert_eq('...a blank one too', tests.resolve(mgr_a, 'mgra@conf.example', c1, 'kept', '   '), 'ERROR: say what was done, in a few words');
  perform tests.assert_eq('...and two letters are not enough', tests.resolve(mgr_a, 'mgra@conf.example', c1, 'kept', 'ok'), 'ERROR: say what was done, in a few words');
  perform tests.assert_eq('...nor 501 characters', tests.resolve(mgr_a, 'mgra@conf.example', c1, 'kept', repeat('x', 501)), 'ERROR: keep the note to 500 characters or fewer');
  perform tests.assert_eq('none of those closed it', (select status from public.site_booking_conflicts where id = c1), 'open');

  ---------------------------------------------------------------- closing one: the facts
  perform tests.assert_eq('"moved" is refused while the booking still overbooks its table', tests.resolve(mgr_a, 'mgra@conf.example', c1, 'moved', 'Moved to the terrace'), 'ERROR: that table is still double-booked: move the booking to another table first');
  perform tests.assert_eq('"refunded" is refused while the booking is still paid', tests.resolve(mgr_a, 'mgra@conf.example', c1, 'refunded', 'Paid back'), 'ERROR: refund or cancel the booking first');
  update public.site_table_bookings set table_type_id = t_spare where id = b2;     -- what desk_move_booking does: the booking is on another kind of table
  update public.site_table_bookings set status = 'refunded' where customer_email = 's3@conf.example';
  perform tests.assert_eq('"moved" is accepted once the booking sits on a table with room', tests.resolve(mgr_a, 'mgra@conf.example', c1, 'moved', '  Moved to a spare table, guest told  '), 'ok');
  select * into j from public.site_booking_conflicts where id = c1;
  perform tests.assert_eq('it records how, who and when',
    concat_ws('|', j.status, j.resolution, j.resolution_note, j.resolved_by = mgr_a, j.resolved_at is not null), 'resolved|moved|Moved to a spare table, guest told|t|t');
  perform tests.assert_eq('it was logged', (select count(*)::int from public.audit_log where action = 'booking.conflict_resolved' and entity_id = c1::text and actor_id = mgr_a), 1);
  perform tests.assert_eq('it cannot be closed twice', tests.resolve(mgr_a, 'mgra@conf.example', c1, 'kept', 'Closed again'), 'ERROR: this has already been dealt with');
  perform tests.assert_eq('asking the flag again about a closed one says no', tests.flag(b2), 'false');
  perform tests.assert_eq('the open list is empty now', tests.listed(mgr_a, 'mgra@conf.example', venue_a), '0');
  perform tests.assert_eq('...and the full list still shows it', tests.listed(mgr_a, 'mgra@conf.example', venue_a, true), '1');

  update public.site_table_bookings set table_type_id = t_one where id = b2;
  update public.site_table_bookings set status = 'paid', confirmation_code = 'CF0011' where customer_email = 'twoa@conf.example';
  delete from public.site_booking_conflicts;
  perform tests.assert_eq('flagged again for the refund case', tests.flag(b2), 'true');
  update public.site_table_bookings set status = 'cancelled' where id = b2;
  perform tests.assert_eq('"refunded" is accepted for a cancelled booking', tests.resolve(mgr_a, 'mgra@conf.example', (select id from public.site_booking_conflicts where booking_id = b2), 'refunded', 'Cancelled and paid back'), 'ok');
  update public.site_table_bookings set status = 'paid' where id = b2;
  delete from public.site_booking_conflicts;
  perform tests.flag(b2);
  perform tests.assert_eq('"kept" needs no proof: the club found the table',
    tests.resolve(owner_u, 'owner@conf.example', (select id from public.site_booking_conflicts where booking_id = b2), 'kept', 'The club opened another booth'), 'ok');
  perform tests.assert_eq('...and the owner may close one', (select resolution from public.site_booking_conflicts where booking_id = b2), 'kept');

  ---------------------------------------------------------------- how the table is built
  perform tests.assert_raises('an open conflict cannot carry a resolution', format($q$insert into public.site_booking_conflicts (booking_id, venue_id, table_type_id, time_slot_id, booking_date, paid_count, inventory_count, resolution, resolution_note)
    values (%L, %L, %L, %L, %L, 2, 1, 'kept', 'a note')$q$, b1, venue_a, t_one, s_eve, d), 'site_booking_conflicts_state_check');
  perform tests.assert_true('deleting a person who closed one leaves the conflict in place (the person goes, the record stays)',
    (select confdeltype = 'n' from pg_constraint where conrelid = 'public.site_booking_conflicts'::regclass and contype = 'f' and conkey = array[(select attnum from pg_attribute where attrelid = 'public.site_booking_conflicts'::regclass and attname = 'resolved_by')]));
  perform tests.assert_true('the three functions run with their owner''s rights and a fixed search path',
    (select count(*) = 3 and bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('site_flag_oversold_booking', 'desk_booking_conflicts', 'desk_resolve_booking_conflict')));
  perform tests.assert_true('row level security is on and no one has a grant on the table',
    (select relrowsecurity from pg_class where oid = 'public.site_booking_conflicts'::regclass)
    and not has_table_privilege('anon', 'public.site_booking_conflicts', 'select') and not has_table_privilege('authenticated', 'public.site_booking_conflicts', 'select'));
  perform tests.assert_true('the club''s functions are for signed-in people, the flag for the service role only',
    has_function_privilege('authenticated', 'public.desk_booking_conflicts(uuid,boolean)', 'execute') and not has_function_privilege('anon', 'public.desk_booking_conflicts(uuid,boolean)', 'execute')
    and has_function_privilege('authenticated', 'public.desk_resolve_booking_conflict(uuid,text,text)', 'execute') and not has_function_privilege('anon', 'public.desk_resolve_booking_conflict(uuid,text,text)', 'execute')
    and has_function_privilege('service_role', 'public.site_flag_oversold_booking(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.site_flag_oversold_booking(uuid)', 'execute') and not has_function_privilege('anon', 'public.site_flag_oversold_booking(uuid)', 'execute'));
end $$;

rollback;
