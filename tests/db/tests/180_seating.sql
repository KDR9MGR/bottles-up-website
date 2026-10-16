-- Seating a guest. What matters most: a server finds and seats only the tables given to them (another server's table, an unassigned one, an
-- unpaid booking and another club's all find nothing or are refused); a manager or owner of THAT club can do it for any; a name alone never
-- picks a booking by accident (at least 3 letters, characters typed are not wildcards, a manual seating needs the detail checked);
-- seating happens once and a second tap changes nothing and sends nothing; the estimate is set after seating, changed by the same people, and
-- only a real one is told to the guest; a manager can undo a mis-tap with a reason; the message to the guest is only ever QUEUED; and every
-- step is attributed. (The production-only tables come from tests/db/prod_shapes.)
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_code text, p_status text default 'paid') returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 3, 1000, 0, p_status, p_code)
  returning id $$;
create function tests.find(p_user uuid, p_email text, p_venue uuid, p_night date, p_q text) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(concat_ws(':', customer_name, confirmation_code, case when seated then 'seated' else 'waiting' end,
                                              case when is_mine then 'mine' else 'not-mine' end, case when can_seat then 'can' else 'cannot' end,
                                              coalesce(server_name, '-')), ' | ' order by customer_name)
                   from public.desk_find_booking(p_venue, p_night, p_q)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.seat(p_user uuid, p_email text, p_booking uuid, p_method text default 'scan', p_detail text default null, p_est int default null) returns text language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  r := public.desk_mark_seated(p_booking, p_method, p_detail, p_est);
  return 'ok:already=' || (r ->> 'already') || ':est=' || coalesce(r ->> 'estimate_minutes', '-');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.estimate(p_user uuid, p_email text, p_booking uuid, p_minutes int) returns text language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  r := public.desk_set_estimate(p_booking, p_minutes);
  return 'ok:changed=' || (r ->> 'changed') || ':est=' || coalesce(r ->> 'estimate_minutes', '-');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.unseat(p_user uuid, p_email text, p_booking uuid, p_reason text) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  perform public.desk_unseat(p_booking, p_reason);
  return 'ok';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.msgs(p_user uuid, p_email text, p_booking uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(kind || ':' || status, ' | ' order by created_at, kind) from public.desk_booking_messages(p_booking)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.queued(p_booking uuid, p_kind text) returns int language sql security definer as $$
  select count(*)::int from public.site_outbox where ref_id = p_booking and kind = p_kind and status = 'queued' $$;
create function tests.queued_estimate(p_booking uuid, p_kind text) returns text language sql security definer as $$
  select coalesce(payload ->> 'estimate_minutes', 'none') from public.site_outbox where ref_id = p_booking and kind = p_kind order by created_at limit 1 $$;
create function tests.state(p_booking uuid) returns text language sql security definer as $$
  select concat_ws('|', case when b.checked_in_at is not null then 'in' else 'out' end, coalesce(s.method, '-'), coalesce(s.estimate_minutes::text, '-'), coalesce(s.confirmation, '-'))
  from public.site_table_bookings b left join public.site_booking_seating s on s.booking_id = b.id where b.id = p_booking $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000002d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000002d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000002d3';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000002d4';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000002d5';
  door_a constant uuid := '00000000-0000-0000-0000-0000000002d6';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000002d7';
  rando constant uuid := '00000000-0000-0000-0000-0000000002d8';
  org uuid; venue_a uuid; venue_b uuid; type_a uuid; type_b uuid; slot_eve uuid; slot_late uuid; slot_b uuid;
  m_s1 uuid; m_s2 uuid;
  b_ada uuid; b_grace uuid; b_ann uuid; b_free uuid; b_pend uuid; b_late uuid; b_other uuid; b_b uuid; b_old uuid; b_wild uuid;
  txt text; n int;
  night date := current_date + 20;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@seat.example'), (mgr_a, 'mgra@seat.example'), (srv_1, 'srv1@seat.example'), (srv_2, 'srv2@seat.example'),
    (ver_a, 'vera@seat.example'), (door_a, 'doora@seat.example'), (mgr_b, 'mgrb@seat.example'), (rando, 'rando@seat.example');
  insert into public.profiles (id, name, email) values (srv_1, 'Sam Server', 'srv1@seat.example'), (srv_2, 'Bea Server', 'srv2@seat.example');

  perform tests.login(owner_u, 'owner@seat.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@seat.example', org, 'mgra@seat.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@seat.example', org, 'mgrb@seat.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@seat.example', org, 'srv1@seat.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@seat.example', org, 'srv2@seat.example', 'server', venue_a, srv_2);
  perform tests.join_as(mgr_a, 'mgra@seat.example', org, 'vera@seat.example', 'verifier', venue_a, ver_a);
  perform tests.join_as(mgr_a, 'mgra@seat.example', org, 'doora@seat.example', 'door', venue_a, door_a);
  perform tests.logout();
  select id into m_s1 from public.site_memberships where user_id = srv_1 and role = 'server';
  select id into m_s2 from public.site_memberships where user_id = srv_2 and role = 'server';

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 9) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 9) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 0, '01:00', 'After midnight') returning id into slot_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;

  b_ada := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Ada Lovelace', 'ADA111');
  b_grace := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Grace Hopper', 'GRC222');
  b_ann := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Ada Annan', 'ANN333');
  b_free := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Free Fred', 'FRD444');           -- nobody's table
  b_pend := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Pending Pat', 'PND555', 'pending');
  b_late := tests.mkbooking(venue_a, type_a, slot_late, night + 1, 'Late Lena', 'LTE666');        -- 01:00 next calendar day: tonight
  b_old := tests.mkbooking(venue_a, type_a, slot_eve, night + 3, 'Old Olga', 'OLD777');           -- another night
  b_wild := tests.mkbooking(venue_a, type_a, slot_eve, night, '100% Percy', 'WLD888');
  b_b := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bee Bee', 'BEE999');                    -- another club
  perform tests.login(mgr_a, 'mgra@seat.example');
  perform public.assign_booking_server(b_ada, m_s1);
  perform public.assign_booking_server(b_ann, m_s2);
  perform public.assign_booking_server(b_late, m_s1);
  perform public.assign_booking_server(b_grace, m_s2);
  perform tests.logout();

  ---------------------------------------------------------------- finding
  perform tests.assert_eq('a server finds their own table by its code, in any case',
    tests.find(srv_1, 'srv1@seat.example', venue_a, night, 'ada111'), 'Ada Lovelace:ADA111:waiting:mine:can:Sam Server');
  perform tests.assert_eq('...and by part of the name: only their own, not another server''s Ada',
    tests.find(srv_1, 'srv1@seat.example', venue_a, night, 'ada'), 'Ada Lovelace:ADA111:waiting:mine:can:Sam Server');
  perform tests.assert_eq('...another server''s table is not found even by its exact code',
    tests.find(srv_1, 'srv1@seat.example', venue_a, night, 'GRC222'), '(none)');
  perform tests.assert_eq('...nor is a table nobody has', tests.find(srv_1, 'srv1@seat.example', venue_a, night, 'FRD444'), '(none)');
  perform tests.assert_eq('...nor an unpaid booking', tests.find(srv_1, 'srv1@seat.example', venue_a, night, 'PND555'), '(none)');
  perform tests.assert_eq('...the after-midnight booking is tonight''s', tests.find(srv_1, 'srv1@seat.example', venue_a, night, 'Lena'), 'Late Lena:LTE666:waiting:mine:can:Sam Server');
  perform tests.assert_eq('...another night is not found', tests.find(srv_1, 'srv1@seat.example', venue_a, night, 'Olga'), '(none)');
  perform tests.assert_eq('the manager finds every paid booking of the night with a name match, and who has each',
    tests.find(mgr_a, 'mgra@seat.example', venue_a, night, 'ada'), 'Ada Annan:ANN333:waiting:not-mine:can:Bea Server | Ada Lovelace:ADA111:waiting:not-mine:can:Sam Server');
  perform tests.assert_eq('...including a table nobody has', tests.find(mgr_a, 'mgra@seat.example', venue_a, night, 'FRD444'), 'Free Fred:FRD444:waiting:not-mine:can:-');
  perform tests.assert_eq('the owner can too', tests.find(owner_u, 'owner@seat.example', venue_a, night, 'FRD444'), 'Free Fred:FRD444:waiting:not-mine:can:-');
  perform tests.assert_eq('a short query is refused', tests.find(srv_1, 'srv1@seat.example', venue_a, night, 'ad'), 'ERROR: type at least 3 letters of the name, or the booking code');
  perform tests.assert_eq('...and so is nothing', tests.find(srv_1, 'srv1@seat.example', venue_a, night, '   '), 'ERROR: type at least 3 letters of the name, or the booking code');
  perform tests.assert_eq('...and a very long one', tests.find(srv_1, 'srv1@seat.example', venue_a, night, repeat('a', 61)), 'ERROR: that is too long to be a name or a booking code');
  perform tests.assert_eq('a percent sign typed is a character, not "everything"', tests.find(mgr_a, 'mgra@seat.example', venue_a, night, '%%%'), '(none)');
  perform tests.assert_eq('...it finds a name that really has one', tests.find(mgr_a, 'mgra@seat.example', venue_a, night, '100%'), '100% Percy:WLD888:waiting:not-mine:can:-');
  perform tests.assert_eq('an underscore is a character too', tests.find(mgr_a, 'mgra@seat.example', venue_a, night, '___'), '(none)');
  perform tests.assert_eq('a night is required', tests.find(srv_1, 'srv1@seat.example', venue_a, null, 'ada111'), 'ERROR: choose a night');
  perform tests.assert_eq('another club''s manager cannot look', tests.find(mgr_b, 'mgrb@seat.example', venue_a, night, 'ada111'), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier cannot', tests.find(ver_a, 'vera@seat.example', venue_a, night, 'ada111'), 'ERROR: not allowed');
  perform tests.assert_eq('door staff cannot', tests.find(door_a, 'doora@seat.example', venue_a, night, 'ada111'), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.find(rando, 'rando@seat.example', venue_a, night, 'ada111'), 'ERROR: not allowed');

  ---------------------------------------------------------------- seating
  perform tests.assert_eq('nothing is seated before anyone does it', tests.state(b_ada), 'out|-|-|-');
  perform tests.assert_eq('a server cannot seat another server''s table', tests.seat(srv_1, 'srv1@seat.example', b_grace), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a table nobody has', tests.seat(srv_1, 'srv1@seat.example', b_free), 'ERROR: not allowed');
  perform tests.assert_eq('...a verifier cannot', tests.seat(ver_a, 'vera@seat.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('...door staff cannot', tests.seat(door_a, 'doora@seat.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('...another club''s manager cannot', tests.seat(mgr_b, 'mgrb@seat.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('...a stranger cannot', tests.seat(rando, 'rando@seat.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a booking that does not exist', tests.seat(srv_1, 'srv1@seat.example', gen_random_uuid()), 'ERROR: not allowed');
  perform tests.assert_eq('an unpaid booking cannot be seated', tests.seat(mgr_a, 'mgra@seat.example', b_pend), 'ERROR: only a paid booking can be seated');
  perform tests.assert_eq('a method has to be scan or manual', tests.seat(srv_1, 'srv1@seat.example', b_ada, 'telepathy'), 'ERROR: choose scan or manual');
  perform tests.assert_eq('a manual seating needs the detail that was checked', tests.seat(srv_1, 'srv1@seat.example', b_ada, 'manual'), 'ERROR: say what you checked with the guest');
  perform tests.assert_eq('...a few letters are not a detail', tests.seat(srv_1, 'srv1@seat.example', b_ada, 'manual', 'ok'), 'ERROR: say what you checked with the guest');
  perform tests.assert_eq('an estimate is between 1 and 480 minutes', tests.seat(srv_1, 'srv1@seat.example', b_ada, 'scan', null, 0), 'ERROR: the estimate is between 1 and 480 minutes');
  perform tests.assert_eq('...and not more', tests.seat(srv_1, 'srv1@seat.example', b_ada, 'scan', null, 481), 'ERROR: the estimate is between 1 and 480 minutes');
  perform tests.assert_eq('none of those refusals seated anyone', tests.state(b_ada), 'out|-|-|-');

  perform tests.assert_eq('the server seats their own table with a scan and an estimate', tests.seat(srv_1, 'srv1@seat.example', b_ada, 'scan', null, 25), 'ok:already=false:est=25');
  perform tests.assert_eq('...the booking is checked in and the seating is recorded', tests.state(b_ada), 'in|scan|25|-');
  perform tests.assert_eq('...one message to the guest is queued', tests.queued(b_ada, 'seated_ack'), 1);
  perform tests.assert_eq('a second tap changes nothing', tests.seat(srv_1, 'srv1@seat.example', b_ada, 'scan', null, 40), 'ok:already=true:est=25');
  perform tests.assert_eq('...and sends nothing again', tests.queued(b_ada, 'seated_ack'), 1);
  perform tests.assert_eq('...the manager''s tap on the same table changes nothing either', tests.seat(mgr_a, 'mgra@seat.example', b_ada), 'ok:already=true:est=25');
  perform tests.assert_eq('the manager seats a table nobody has, manually, with the detail', tests.seat(mgr_a, 'mgra@seat.example', b_free, 'manual', 'checked the guest''s email and last name'), 'ok:already=false:est=-');
  perform tests.assert_eq('...the detail is recorded', tests.state(b_free), 'in|manual|-|checked the guest''s email and last name');
  perform tests.assert_eq('...a seating without an estimate queues the acknowledgment without one', tests.queued_estimate(b_free, 'seated_ack'), 'none');
  perform tests.assert_eq('the owner can seat too', tests.seat(owner_u, 'owner@seat.example', b_late), 'ok:already=false:est=-');
  perform tests.logout();
  update public.site_table_bookings set checked_in_at = now(), checked_in_by = mgr_a where id = b_ann;   -- checked in on the old staff page
  perform tests.assert_eq('a booking already checked in on the old staff page counts as seated: no second seating', tests.seat(srv_2, 'srv2@seat.example', b_ann), 'ok:already=true:est=-');
  perform tests.assert_eq('...no message is sent for it', tests.queued(b_ann, 'seated_ack'), 0);
  perform tests.assert_eq('...and it is now on record as seated, so an estimate can follow', tests.state(b_ann), 'in|manual|-|checked in on the staff page');

  ---------------------------------------------------------------- the estimate
  perform tests.assert_eq('an estimate cannot be set before the guest is seated', tests.estimate(srv_2, 'srv2@seat.example', b_grace, 20), 'ERROR: seat the guest first');
  perform tests.assert_eq('the server changes their own estimate; the guest is told', tests.estimate(srv_1, 'srv1@seat.example', b_ada, 40), 'ok:changed=true:est=40');
  perform tests.assert_eq('...an update message is queued', tests.queued(b_ada, 'estimate_updated'), 1);
  perform tests.assert_eq('the same estimate again changes nothing and says nothing', tests.estimate(srv_1, 'srv1@seat.example', b_ada, 40), 'ok:changed=false:est=40');
  perform tests.assert_eq('...and nothing more is queued', tests.queued(b_ada, 'estimate_updated'), 1);
  perform tests.assert_eq('another server cannot change it', tests.estimate(srv_2, 'srv2@seat.example', b_ada, 10), 'ERROR: not allowed');
  perform tests.assert_eq('the manager can', tests.estimate(mgr_a, 'mgra@seat.example', b_ada, 55), 'ok:changed=true:est=55');
  perform tests.assert_eq('bounds hold here too', tests.estimate(mgr_a, 'mgra@seat.example', b_ada, 500), 'ERROR: the estimate is between 1 and 480 minutes');
  perform tests.assert_eq('clearing an estimate is allowed and tells the guest nothing', tests.estimate(mgr_a, 'mgra@seat.example', b_ada, null), 'ok:changed=true:est=-');
  perform tests.assert_eq('...and no message is queued for the clearing (two estimates were told, not three)', tests.queued(b_ada, 'estimate_updated'), 2);
  perform tests.assert_eq('a verifier cannot touch it', tests.estimate(ver_a, 'vera@seat.example', b_ada, 5), 'ERROR: not allowed');

  ---------------------------------------------------------------- undoing a mis-tap
  perform tests.assert_eq('a server cannot un-seat', tests.unseat(srv_1, 'srv1@seat.example', b_ada, 'wrong table'), 'ERROR: not allowed');
  perform tests.assert_eq('a manager needs a reason', tests.unseat(mgr_a, 'mgra@seat.example', b_ada, ''), 'ERROR: say why this guest is being un-seated');
  perform tests.assert_eq('...another club''s manager cannot', tests.unseat(mgr_b, 'mgrb@seat.example', b_ada, 'wrong table'), 'ERROR: not allowed');
  perform tests.assert_eq('a guest who is not seated cannot be un-seated', tests.unseat(mgr_a, 'mgra@seat.example', b_old, 'wrong table'), 'ERROR: this guest is not seated');
  perform tests.assert_eq('the manager un-seats with a reason', tests.unseat(mgr_a, 'mgra@seat.example', b_ada, 'tapped the wrong table'), 'ok');
  perform tests.assert_eq('...the table is back to waiting', tests.state(b_ada), 'out|-|-|-');
  perform tests.assert_eq('it can be seated again', tests.seat(srv_1, 'srv1@seat.example', b_ada, 'scan', null, 15), 'ok:already=false:est=15');
  perform tests.assert_eq('...which queues a new acknowledgment', tests.queued(b_ada, 'seated_ack'), 2);

  ---------------------------------------------------------------- what the guest was told
  -- (one test transaction = one timestamp, so the helper lists them by kind)
  perform tests.assert_eq('the server sees the messages about their table, all queued (nothing says sent)',
    tests.msgs(srv_1, 'srv1@seat.example', b_ada), 'estimate_updated:queued | estimate_updated:queued | seated_ack:queued | seated_ack:queued');
  perform tests.assert_eq('the manager sees them too', tests.msgs(mgr_a, 'mgra@seat.example', b_ada), 'estimate_updated:queued | estimate_updated:queued | seated_ack:queued | seated_ack:queued');
  perform tests.assert_eq('another server does not', tests.msgs(srv_2, 'srv2@seat.example', b_ada), 'ERROR: not allowed');
  perform tests.assert_eq('a verifier does not', tests.msgs(ver_a, 'vera@seat.example', b_ada), 'ERROR: not allowed');
  perform tests.logout();
  update public.site_outbox set status = 'failed', last_error = 'mailbox full', attempts = 1 where ref_id = b_ada and kind = 'estimate_updated';
  perform tests.assert_eq('a failed delivery shows as failed, not hidden', tests.msgs(srv_1, 'srv1@seat.example', b_ada), 'estimate_updated:failed | estimate_updated:failed | seated_ack:queued | seated_ack:queued');

  ---------------------------------------------------------------- attribution and closed doors
  perform tests.logout();
  perform tests.assert_eq('seating is in the audit log with who and how', (select count(*) from public.audit_log where action = 'booking.seated' and entity_id = b_ada::text and details ->> 'method' = 'scan')::int, 2);
  perform tests.assert_eq('estimates and un-seating are in it too', (select count(*) from public.audit_log where action in ('booking.estimate_set', 'booking.unseated') and entity_id = b_ada::text)::int, 4);  -- three estimates (40, 55, cleared) and one un-seat
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot seat', format($q$select public.desk_mark_seated(%L)$q$, b_ada), 'permission denied');
  perform tests.assert_raises('...or find', format($q$select * from public.desk_find_booking(%L, %L, 'ada111')$q$, venue_a, night), 'permission denied');
  perform tests.logout();
  perform tests.login(srv_1, 'srv1@seat.example');
  perform tests.assert_raises('the seating table is closed to clients', 'select * from public.site_booking_seating', 'permission denied');
  perform tests.assert_raises('...and so is the outbox', 'select * from public.site_outbox', 'permission denied');
  perform tests.assert_raises('...and nobody can queue a message by hand', format($q$select public.desk_enqueue('seated_ack', %L, %L)$q$, venue_a, b_ada), 'permission denied');
  perform tests.logout();
end $$;

rollback;
