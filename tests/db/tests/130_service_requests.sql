-- Service requests. What matters most: only staff of THAT club can ask or act; a server sees and handles only their own tables'
-- requests (and those of tables nobody has); the first server to take a request owns it and nobody else can; repeated taps never make
-- a second request; escalating and cancelling need a reason; only a manager hands a request to someone else; nothing reaches the
-- table directly; and every change is attributed.
begin;

-- Test helpers, rolled back with everything else. act_as runs one action as a signed-in person and answers 'ok' or the error text.
create function tests.act_as(p_user uuid, p_email text, p_req uuid, p_action text, p_note text default null, p_assignee uuid default null)
returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  perform public.update_service_request(p_req, p_action, p_note, p_assignee);
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
create function tests.ask_as(p_user uuid, p_email text, p_booking uuid, p_kind text, p_note text default null)
returns text language plpgsql as $$
declare v uuid;
begin
  perform tests.login(p_user, p_email);
  v := public.create_service_request(p_booking, p_kind, p_note);
  return v::text;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.req_status(p_id uuid) returns text language sql security definer as $$ select status from public.site_service_requests where id = p_id $$;
create function tests.req_assigned(p_id uuid) returns uuid language sql security definer as $$ select assigned_membership_id from public.site_service_requests where id = p_id $$;
create function tests.req_note(p_id uuid) returns text language sql security definer as $$ select status_note from public.site_service_requests where id = p_id $$;
create function tests.req_flags(p_id uuid) returns text language sql security definer as $$
  select 'acknowledged=' || (acknowledged_at is not null) || ',closed=' || (closed_at is not null) from public.site_service_requests where id = p_id $$;
create function tests.audit_count(p_prefix text, p_entity uuid) returns int language sql security definer as $$
  select count(*)::int from public.audit_log where action like p_prefix || '%' and entity_id = p_entity::text $$;
create function tests.req_count(p_booking uuid, p_kind text) returns int language sql security definer as $$
  select count(*)::int from public.site_service_requests where booking_id = p_booking and kind = p_kind $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text) returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, 1000, 'paid', upper(replace(p_name, ' ', '-')))
  returning id $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000000d2';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000d3';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000d4';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000000d5';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000000d6';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000000d7';
  srv_b constant uuid := '00000000-0000-0000-0000-0000000000d8';
  srv_3 constant uuid := '00000000-0000-0000-0000-0000000000d9';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; tok text; r record; n int; txt text; res text; arr uuid[];
  type_a uuid; type_b uuid; slot_eve uuid; slot_b uuid;
  m_s1 uuid; m_s2 uuid; m_s3 uuid; m_sb uuid; m_door uuid; m_mgr uuid; m_owner uuid;
  b_ada uuid; b_zed uuid; b_open uuid; b_pend uuid; b_bea uuid; b_f uuid; b_g uuid; b_c uuid; b_d uuid; b_late uuid;
  q1 uuid; qa uuid; qt uuid; q2 uuid; q3 uuid; qo uuid; qf uuid; qg uuid; qc uuid; qd uuid; qx uuid; qy uuid; ql uuid; flags boolean[]; shift_old uuid;
  night date := current_date + 10;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@club.example'), (mgr_a, 'mgra@club.example'), (rival_u, 'rival@club2.example'), (door_a, 'doora@club.example'),
    (mgr_b, 'mgrb@club.example'), (srv_1, 'srv1@club.example'), (srv_2, 'srv2@club.example'), (srv_b, 'srvb@club.example'),
    (srv_3, 'srv3@club.example');

  ---------------------------------------------------------------- set up: two clubs of one business, a rival, staff
  perform tests.login(owner_u, 'owner@club.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@club2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  perform public.create_org_venue(org2, 'Rival Club');

  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'mgra@club.example', 'manager', venue_a) i;
  perform tests.login(mgr_a, 'mgra@club.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'mgrb@club.example', 'manager', venue_b) i;
  perform tests.login(mgr_b, 'mgrb@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@club.example');
  select i.token into tok from public.invite_member(org, 'srv1@club.example', 'server', venue_a) i;
  perform tests.login(srv_1, 'srv1@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@club.example');
  select i.token into tok from public.invite_member(org, 'srv2@club.example', 'server', venue_a) i;
  perform tests.login(srv_2, 'srv2@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@club.example');
  select i.token into tok from public.invite_member(org, 'srv3@club.example', 'server', venue_a) i;
  perform tests.login(srv_3, 'srv3@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_a, 'mgra@club.example');
  select i.token into tok from public.invite_member(org, 'doora@club.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@club.example'); perform public.accept_invitation(tok);
  perform tests.login(mgr_b, 'mgrb@club.example');
  select i.token into tok from public.invite_member(org, 'srvb@club.example', 'server', venue_b) i;
  perform tests.login(srv_b, 'srvb@club.example'); perform public.accept_invitation(tok);

  perform tests.logout();
  select id into m_s1 from public.site_memberships where user_id = srv_1 and role = 'server';
  select id into m_s2 from public.site_memberships where user_id = srv_2 and role = 'server';
  select id into m_s3 from public.site_memberships where user_id = srv_3 and role = 'server';
  select id into m_sb from public.site_memberships where user_id = srv_b and role = 'server';
  select id into m_door from public.site_memberships where user_id = door_a and role = 'door';
  select id into m_mgr from public.site_memberships where user_id = mgr_a and role = 'manager';
  select id into m_owner from public.site_memberships where user_id = owner_u and role = 'owner';

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 5) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 5) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;
  b_ada := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Ada Evening');
  b_zed := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Zed Evening');
  b_open := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Open Olga');
  b_bea := tests.mkbooking(venue_b, type_b, slot_b, night, 'Bea Clubb');
  b_f := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Flow Fred');
  b_g := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Hand Gus');
  b_c := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Cancel Cora');
  b_d := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Direct Dan');
  b_late := tests.mkbooking(venue_a, type_a, slot_eve, night, 'Late Lena');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, type_a, slot_eve, night, 'Pending Pat', 'pat@test.example', 2, 1000, 'pending') returning id into b_pend;
  -- Ada's table is srv_1's, Zed's and Dan's are srv_2's, Fred's and Gus's are srv_1's; Olga's and Cora's are nobody's.
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_ada, m_s1);
  perform public.assign_booking_server(b_zed, m_s2);
  perform public.assign_booking_server(b_f, m_s1);
  perform public.assign_booking_server(b_g, m_s1);
  perform public.assign_booking_server(b_d, m_s2);

  ---------------------------------------------------------------- asking: who may
  res := tests.ask_as(srv_1, 'srv1@club.example', b_ada, 'water_ice_mixers', '  ice and two limes  ');
  perform tests.assert_true('a server can ask for something for their own table', res not like 'ERROR%');
  q1 := res::uuid;
  perform tests.logout();
  perform tests.assert_eq('...it starts as New', tests.req_status(q1), 'new');
  perform tests.assert_eq('...goes to the table''s server', tests.req_assigned(q1), m_s1);
  perform tests.assert_eq('...and has not been taken or closed', tests.req_flags(q1), 'acknowledged=false,closed=false');
  select * into r from public.site_service_requests where id = q1;
  perform tests.assert_eq('...it records the venue, the booking, the kind, the source and who asked', r.venue_id::text || '|' || r.booking_id::text || '|' || r.kind || '|' || r.source || '|' || r.created_by::text, venue_a::text || '|' || b_ada::text || '|water_ice_mixers|staff|' || srv_1::text);
  perform tests.assert_eq('...the note is trimmed', r.note, 'ice and two limes');
  qa := tests.ask_as(srv_1, 'srv1@club.example', b_ada, 'assistance', '   ')::uuid;
  perform tests.logout();
  perform tests.assert_eq('a blank note is stored as no note', (select note from public.site_service_requests where id = qa), null);

  perform tests.assert_eq('a server cannot ask for another server''s table', tests.ask_as(srv_1, 'srv1@club.example', b_zed, 'assistance'), 'ERROR: this table belongs to another server');
  res := tests.ask_as(srv_1, 'srv1@club.example', b_open, 'bill_request');
  perform tests.assert_true('...but can for a table nobody has been given', res not like 'ERROR%');
  q2 := res::uuid;
  perform tests.assert_eq('...which goes to nobody yet', tests.req_assigned(q2), null);
  res := tests.ask_as(mgr_a, 'mgra@club.example', b_zed, 'table_issue', 'spilled drink');
  perform tests.assert_true('the manager can ask for any table of the club', res not like 'ERROR%');
  q3 := res::uuid;
  perform tests.assert_eq('...it goes to that table''s server', tests.req_assigned(q3), m_s2);
  res := tests.ask_as(owner_u, 'owner@club.example', b_zed, 'order_question');
  perform tests.assert_true('the owner can too', res not like 'ERROR%');
  qo := res::uuid;

  perform tests.assert_eq('door staff cannot', tests.ask_as(door_a, 'doora@club.example', b_ada, 'bill_request'), 'ERROR: not allowed');
  perform tests.assert_eq('a manager of the other club cannot', tests.ask_as(mgr_b, 'mgrb@club.example', b_ada, 'bill_request'), 'ERROR: not allowed');
  perform tests.assert_eq('a server of the other club cannot', tests.ask_as(srv_b, 'srvb@club.example', b_ada, 'bill_request'), 'ERROR: not allowed');
  perform tests.assert_eq('a rival owner cannot', tests.ask_as(rival_u, 'rival@club2.example', b_ada, 'bill_request'), 'ERROR: not allowed');
  perform tests.assert_eq('a signed-in person with no role cannot', tests.ask_as(rando, null, b_ada, 'bill_request'), 'ERROR: not allowed');
  perform tests.assert_eq('a booking that does not exist gets the same answer (no probing ids)', tests.ask_as(srv_1, 'srv1@club.example', gen_random_uuid(), 'assistance'), 'ERROR: not allowed');
  perform tests.logout();
  perform tests.assert_eq('...and none of those refusals left a request behind', (select count(*) from public.site_service_requests where kind = 'bill_request')::int, 1);
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format($q$select public.create_service_request(%L, 'assistance')$q$, b_ada), 'permission denied');

  perform tests.logout();
  perform tests.assert_eq('a pending booking cannot have requests', tests.ask_as(mgr_a, 'mgra@club.example', b_pend, 'assistance'), 'ERROR: only a paid booking can have service requests');
  perform tests.assert_eq('no kind chosen', tests.ask_as(mgr_a, 'mgra@club.example', b_ada, null), 'ERROR: choose what the table needs');
  perform tests.assert_eq('a kind that is not on the list', tests.ask_as(mgr_a, 'mgra@club.example', b_ada, 'champagne_tower'), 'ERROR: choose what the table needs');
  perform tests.assert_eq('a note of 301 characters is refused', tests.ask_as(mgr_a, 'mgra@club.example', b_ada, 'table_issue', repeat('x', 301)), 'ERROR: keep the note to 300 characters or fewer');
  res := tests.ask_as(mgr_a, 'mgra@club.example', b_ada, 'table_issue', repeat('x', 300));
  perform tests.assert_true('...300 is fine', res not like 'ERROR%');
  qt := res::uuid;

  ---------------------------------------------------------------- repeated taps are one request
  perform tests.assert_eq('asking again for the same thing while it is open returns the same request', tests.ask_as(srv_1, 'srv1@club.example', b_ada, 'water_ice_mixers'), q1::text);
  perform tests.assert_eq('...even when someone else asks', tests.ask_as(mgr_a, 'mgra@club.example', b_ada, 'water_ice_mixers', 'again'), q1::text);
  perform tests.assert_eq('...and only one is recorded', tests.req_count(b_ada, 'water_ice_mixers'), 1);
  perform tests.assert_eq('...the asking was recorded once', tests.audit_count('service_request.created', q1), 1);
  perform tests.logout();
  perform tests.assert_eq('...and the first note stands', (select note from public.site_service_requests where id = q1), 'ice and two limes');
  perform tests.assert_eq('a different thing for the same table is its own request', tests.req_count(b_ada, 'assistance'), 1);
  perform tests.logout();
  begin
    insert into public.site_service_requests (venue_id, booking_id, kind) values (venue_a, b_ada, 'water_ice_mixers');
    raise exception 'FAIL - the database allowed a second open request of the same kind';
  exception when unique_violation then
    raise notice 'ok - the database itself refuses a second open request of the same kind for a booking (two taps at once cannot both succeed)';
  end;
  begin
    update public.site_service_requests set status = 'completed' where id = q1;
    raise exception 'FAIL - a completed request without a closing time was allowed';
  exception when check_violation then
    raise notice 'ok - a request cannot be marked closed without a closing time';
  end;

  ---------------------------------------------------------------- reading: who sees what
  perform tests.login(srv_1, 'srv1@club.example');
  select string_agg(kind || '@' || confirmation_code, ',' order by kind, confirmation_code) into txt from public.list_service_requests(venue_a);
  perform tests.assert_eq('a server sees their own tables'' requests and those of a table nobody has', txt, 'assistance@ADA-EVENING,bill_request@OPEN-OLGA,table_issue@ADA-EVENING,water_ice_mixers@ADA-EVENING');
  perform tests.assert_eq('...and not the other server''s', (select count(*) from public.list_service_requests(venue_a) where confirmation_code = 'ZED-EVENING')::int, 0);
  perform tests.assert_eq('...they know which are theirs', (select count(*) from public.list_service_requests(venue_a) where assigned_to_me)::int, 3);
  perform tests.assert_eq('...and a request nobody has is not marked as theirs', (select assigned_to_me from public.list_service_requests(venue_a) where request_id = q2), false);
  select * into r from public.list_service_requests(venue_a) where request_id = q1;
  perform tests.assert_eq('a request carries the table, the guest, the party and the kind', r.table_name || '|' || r.customer_name || '|' || r.guest_count || '|' || r.kind || '|' || r.note || '|' || r.source || '|' || r.status, 'VIP booth|Ada Evening|2|water_ice_mixers|ice and two limes|staff|new');
  perform tests.assert_eq('...no guest email or phone', (select count(*) from jsonb_object_keys((select to_jsonb(t) from public.list_service_requests(venue_a) t limit 1)) k where k in ('customer_email', 'customer_phone', 'email', 'phone'))::int, 0);
  perform tests.login(srv_2, 'srv2@club.example');
  select string_agg(kind || '@' || confirmation_code, ',' order by kind, confirmation_code) into txt from public.list_service_requests(venue_a);
  perform tests.assert_eq('the other server sees theirs and the unclaimed one', txt, 'bill_request@OPEN-OLGA,order_question@ZED-EVENING,table_issue@ZED-EVENING');
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('the manager sees every request of the club', (select count(*) from public.list_service_requests(venue_a))::int, 6);
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the owner sees them too', (select count(*) from public.list_service_requests(venue_a))::int, 6);
  perform tests.assert_eq('...and none under their other club', (select count(*) from public.list_service_requests(venue_b))::int, 0);
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('a manager of the other club cannot read Club A''s', format($q$select * from public.list_service_requests(%L)$q$, venue_a), 'not allowed');
  perform tests.login(srv_b, 'srvb@club.example');
  perform tests.assert_raises('a server of the other club cannot', format($q$select * from public.list_service_requests(%L)$q$, venue_a), 'not allowed');
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff cannot', format($q$select * from public.list_service_requests(%L)$q$, venue_a), 'not allowed');
  perform tests.login(rando);
  perform tests.assert_raises('a signed-in person with no role cannot', format($q$select * from public.list_service_requests(%L)$q$, venue_a), 'not allowed');
  perform tests.assert_raises('a club that does not exist is refused', format($q$select * from public.list_service_requests(%L)$q$, gen_random_uuid()), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format($q$select * from public.list_service_requests(%L)$q$, venue_a), 'permission denied');

  -- The longest wait comes first.
  perform tests.logout();
  update public.site_service_requests set created_at = now() - interval '6 hours' where id = q2;
  update public.site_service_requests set created_at = now() - interval '5 hours' where id = q1;
  update public.site_service_requests set created_at = now() - interval '4 hours' where id = qa;
  update public.site_service_requests set created_at = now() - interval '3 hours' where id = qt;
  update public.site_service_requests set created_at = now() - interval '2 hours' where id = q3;
  update public.site_service_requests set created_at = now() - interval '1 hour' where id = qo;
  perform tests.login(mgr_a, 'mgra@club.example');
  select array_agg(request_id order by ord) into arr from (select request_id, row_number() over () ord from public.list_service_requests(venue_a)) x;
  perform tests.assert_eq('open requests are listed oldest first', arr, array[q2, q1, qa, qt, q3, qo]);

  ---------------------------------------------------------------- moving along: a server's own request
  qf := tests.ask_as(srv_1, 'srv1@club.example', b_f, 'order_question')::uuid;
  perform tests.assert_eq('another server cannot take a new request that belongs to a colleague', tests.act_as(srv_2, 'srv2@club.example', qf, 'acknowledge'), 'this request belongs to another server');
  perform tests.assert_eq('starting before acknowledging is refused', tests.act_as(srv_1, 'srv1@club.example', qf, 'start'), 'acknowledge the request first');
  perform tests.assert_eq('the server acknowledges', tests.act_as(srv_1, 'srv1@club.example', qf, 'acknowledge'), 'ok');
  perform tests.assert_eq('...it is Acknowledged, theirs, and the time is kept', tests.req_status(qf) || '|' || tests.req_flags(qf) || '|' || (tests.req_assigned(qf) = m_s1), 'acknowledged|acknowledged=true,closed=false|true');
  perform tests.assert_eq('acknowledging again is not an error', tests.act_as(srv_1, 'srv1@club.example', qf, 'acknowledge'), 'ok');
  perform tests.assert_eq('...and records nothing', tests.audit_count('service_request.acknowledged', qf), 1);
  perform tests.assert_eq('a colleague is told someone has it: acknowledge', tests.act_as(srv_2, 'srv2@club.example', qf, 'acknowledge'), 'someone else has already taken this request');
  perform tests.assert_eq('...complete', tests.act_as(srv_2, 'srv2@club.example', qf, 'complete'), 'someone else has already taken this request');
  perform tests.assert_eq('...cancel', tests.act_as(srv_2, 'srv2@club.example', qf, 'cancel', 'not mine'), 'someone else has already taken this request');
  perform tests.assert_eq('...escalate', tests.act_as(srv_2, 'srv2@club.example', qf, 'escalate', 'not mine'), 'someone else has already taken this request');
  perform tests.assert_eq('...and nothing changed', tests.req_status(qf), 'acknowledged');
  perform tests.assert_eq('the server starts it', tests.act_as(srv_1, 'srv1@club.example', qf, 'start'), 'ok');
  perform tests.assert_eq('...it is In progress', tests.req_status(qf), 'in_progress');
  perform tests.assert_eq('starting again is not an error and records nothing', tests.act_as(srv_1, 'srv1@club.example', qf, 'start') || tests.audit_count('service_request.started', qf), 'ok1');
  perform tests.assert_eq('acknowledging what they already have says so', tests.act_as(srv_1, 'srv1@club.example', qf, 'acknowledge'), 'you have already taken this request');
  perform tests.assert_eq('escalating needs a reason', tests.act_as(srv_1, 'srv1@club.example', qf, 'escalate'), 'say why you are passing this request to a manager');
  perform tests.assert_eq('...a blank one is no reason', tests.act_as(srv_1, 'srv1@club.example', qf, 'escalate', '   '), 'say why you are passing this request to a manager');
  perform tests.assert_eq('...and a note over 300 characters is refused', tests.act_as(srv_1, 'srv1@club.example', qf, 'escalate', repeat('y', 301)), 'keep the note to 300 characters or fewer');
  perform tests.assert_eq('the server passes it to a manager with a reason', tests.act_as(srv_1, 'srv1@club.example', qf, 'escalate', ' guest wants the owner '), 'ok');
  perform tests.assert_eq('...it is Escalated, with the reason (trimmed)', tests.req_status(qf) || '|' || tests.req_note(qf), 'escalated|guest wants the owner');
  perform tests.assert_eq('escalating again is not an error', tests.act_as(srv_1, 'srv1@club.example', qf, 'escalate', 'again'), 'ok');
  perform tests.assert_eq('once escalated the server cannot complete it', tests.act_as(srv_1, 'srv1@club.example', qf, 'complete'), 'this request was passed to a manager');
  perform tests.assert_eq('...cancel it', tests.act_as(srv_1, 'srv1@club.example', qf, 'cancel', 'x'), 'this request was passed to a manager');
  perform tests.assert_eq('...or take it back', tests.act_as(srv_1, 'srv1@club.example', qf, 'acknowledge'), 'this request was passed to a manager');
  perform tests.assert_eq('...or start it', tests.act_as(srv_1, 'srv1@club.example', qf, 'start'), 'this request was passed to a manager');
  perform tests.assert_eq('the manager takes it', tests.act_as(mgr_a, 'mgra@club.example', qf, 'acknowledge'), 'ok');
  perform tests.assert_eq('...it is Acknowledged and now the manager''s', tests.req_status(qf) || '|' || (tests.req_assigned(qf) = m_mgr), 'acknowledged|true');
  perform tests.assert_eq('the server who passed it up can no longer act on it', tests.act_as(srv_1, 'srv1@club.example', qf, 'complete'), 'someone else has already taken this request');
  perform tests.assert_eq('the manager completes it, with a remark', tests.act_as(mgr_a, 'mgra@club.example', qf, 'complete', 'sorted with the guest'), 'ok');
  perform tests.assert_eq('...it is Completed, closed, and keeps the remark', tests.req_status(qf) || '|' || tests.req_flags(qf) || '|' || tests.req_note(qf), 'completed|acknowledged=true,closed=true|sorted with the guest');
  perform tests.assert_eq('completing again is not an error', tests.act_as(mgr_a, 'mgra@club.example', qf, 'complete'), 'ok');
  perform tests.assert_eq('...but a closed request cannot be cancelled', tests.act_as(mgr_a, 'mgra@club.example', qf, 'cancel', 'oops'), 'this request is already closed');
  perform tests.assert_eq('...started', tests.act_as(mgr_a, 'mgra@club.example', qf, 'start'), 'this request is already closed');
  perform tests.assert_eq('...escalated', tests.act_as(mgr_a, 'mgra@club.example', qf, 'escalate', 'oops'), 'this request is already closed');
  perform tests.assert_eq('...or handed over', tests.act_as(mgr_a, 'mgra@club.example', qf, 'reassign', null, m_s2), 'this request is already closed');
  perform tests.assert_eq('the server who first had it hears the same', tests.act_as(srv_1, 'srv1@club.example', qf, 'complete'), 'this request is already closed');
  perform tests.assert_eq('the whole story was recorded: asked, taken, started, escalated, taken by the manager, completed', tests.audit_count('service_request.', qf), 6);
  perform tests.assert_eq('...completing has its own entry', tests.audit_count('service_request.completed', qf), 1);
  perform tests.logout();
  select * into r from public.audit_log where action = 'service_request.escalated' and entity_id = qf::text;
  perform tests.assert_eq('an entry names who did it and what changed', r.actor_email || '|' || (r.details ->> 'from_status') || '|' || (r.details ->> 'to_status') || '|' || (r.details ->> 'kind'), 'srv1@club.example|in_progress|escalated|order_question');
  perform tests.assert_eq('...the manager''s taking it over is attributed to the manager', (select string_agg(actor_email, ',' order by actor_email) from public.audit_log where action = 'service_request.acknowledged' and entity_id = qf::text), 'mgra@club.example,srv1@club.example');

  ---------------------------------------------------------------- moving along: a request nobody has
  perform tests.assert_eq('a server takes a request nobody has', tests.act_as(srv_1, 'srv1@club.example', q2, 'acknowledge'), 'ok');
  perform tests.assert_eq('...it becomes theirs', tests.req_assigned(q2) = m_s1, true);
  perform tests.assert_eq('a second server who tries next is told it is taken', tests.act_as(srv_2, 'srv2@club.example', q2, 'acknowledge'), 'someone else has already taken this request');
  perform tests.assert_eq('...and cannot finish it either', tests.act_as(srv_2, 'srv2@club.example', q2, 'complete'), 'someone else has already taken this request');
  perform tests.assert_eq('the one who took it finishes it', tests.act_as(srv_1, 'srv1@club.example', q2, 'complete'), 'ok');
  perform tests.assert_eq('completing a request nobody had takes it and closes it in one go', tests.act_as(srv_2, 'srv2@club.example', (select tests.ask_as(srv_2, 'srv2@club.example', b_open, 'assistance'))::uuid, 'complete'), 'ok');
  perform tests.logout();
  select * into r from public.site_service_requests where booking_id = b_open and kind = 'assistance';
  qy := r.id;
  perform tests.assert_eq('...it is Completed by that server, who is recorded as having taken it', r.status || '|' || (r.assigned_membership_id = m_s2) || '|' || (r.acknowledged_at is not null) || '|' || (r.closed_at is not null), 'completed|true|true|true');

  ---------------------------------------------------------------- cancelling
  qc := tests.ask_as(srv_1, 'srv1@club.example', b_c, 'table_issue')::uuid;
  perform tests.assert_eq('cancelling needs a reason', tests.act_as(srv_2, 'srv2@club.example', qc, 'cancel'), 'say why this request is being cancelled');
  perform tests.assert_eq('a server may cancel a request nobody has, with a reason', tests.act_as(srv_2, 'srv2@club.example', qc, 'cancel', 'guest left'), 'ok');
  perform tests.assert_eq('...it is Cancelled, closed, with the reason', tests.req_status(qc) || '|' || tests.req_flags(qc) || '|' || tests.req_note(qc), 'cancelled|acknowledged=false,closed=true|guest left');
  perform tests.assert_eq('cancelling again is not an error', tests.act_as(srv_2, 'srv2@club.example', qc, 'cancel', 'guest left'), 'ok');
  perform tests.assert_eq('...and a cancelled request cannot be completed', tests.act_as(srv_2, 'srv2@club.example', qc, 'complete'), 'this request is already closed');
  perform tests.assert_eq('...cancelling has its own entry', tests.audit_count('service_request.cancelled', qc), 1);
  perform tests.assert_true('once closed, the same thing can be asked for again as a new request', tests.ask_as(srv_1, 'srv1@club.example', b_c, 'table_issue') <> qc::text);

  -- A server who passes on a request nobody had owns that hand-over, so pressing the button twice is harmless.
  qx := tests.ask_as(srv_2, 'srv2@club.example', b_open, 'order_question')::uuid;
  perform tests.assert_eq('a server escalates a request nobody had', tests.act_as(srv_2, 'srv2@club.example', qx, 'escalate', 'wrong order on the table'), 'ok');
  perform tests.assert_eq('...it is theirs', tests.req_assigned(qx) = m_s2, true);
  perform tests.assert_eq('...pressing it again is not an error', tests.act_as(srv_2, 'srv2@club.example', qx, 'escalate', 'wrong order on the table'), 'ok');
  perform tests.assert_eq('...and records nothing new', tests.audit_count('service_request.escalated', qx), 1);

  ---------------------------------------------------------------- managers and owners may act on any request
  qd := tests.ask_as(srv_2, 'srv2@club.example', b_d, 'bill_request')::uuid;
  perform tests.assert_eq('a manager can take a request that is a server''s', tests.act_as(mgr_a, 'mgra@club.example', qd, 'acknowledge'), 'ok');
  perform tests.assert_eq('...and it becomes theirs', tests.req_assigned(qd) = m_mgr, true);
  perform tests.assert_eq('the owner can finish it', tests.act_as(owner_u, 'owner@club.example', qd, 'complete'), 'ok');
  perform tests.assert_eq('...and it stays with the manager who took it', tests.req_assigned(qd) = m_mgr, true);
  qx := tests.ask_as(owner_u, 'owner@club.example', b_d, 'water_ice_mixers')::uuid;   -- (qx is reused from here on)
  perform tests.assert_eq('the owner can complete a new one directly', tests.act_as(owner_u, 'owner@club.example', qx, 'complete'), 'ok');
  perform tests.assert_eq('...and it is recorded as the owner''s', tests.req_assigned(qx) = m_owner, true);

  -- A request made while a table had nobody follows the table when it is given to someone afterwards.
  ql := tests.ask_as(mgr_a, 'mgra@club.example', b_late, 'bill_request')::uuid;
  perform tests.assert_eq('a request on a table nobody has goes to nobody', tests.req_assigned(ql), null);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_late, m_s2);
  perform tests.assert_eq('...but once the table is given to a server, a colleague cannot take that request', tests.act_as(srv_1, 'srv1@club.example', ql, 'acknowledge'), 'this request belongs to another server');
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_eq('...and no longer sees it', (select count(*) from public.list_service_requests(venue_a) where request_id = ql)::int, 0);
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_eq('...while the table''s server does', (select count(*) from public.list_service_requests(venue_a) where request_id = ql)::int, 1);
  perform tests.assert_eq('...and can take it', tests.act_as(srv_2, 'srv2@club.example', ql, 'acknowledge'), 'ok');

  ---------------------------------------------------------------- handing a request to someone else
  qg := tests.ask_as(srv_1, 'srv1@club.example', b_g, 'assistance')::uuid;
  perform tests.act_as(srv_1, 'srv1@club.example', qg, 'acknowledge');
  perform tests.assert_eq('a server cannot hand a request on', tests.act_as(srv_1, 'srv1@club.example', qg, 'reassign', null, m_s2), 'only a manager can hand a request to someone else');
  perform tests.assert_eq('door staff are not who it can go to', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign', null, m_door), 'that person is not staff at this club');
  perform tests.assert_eq('...nor another club''s server', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign', null, m_sb), 'that person is not staff at this club');
  perform tests.assert_eq('...nor the owner''s own membership', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign', null, m_owner), 'that person is not staff at this club');
  perform tests.assert_eq('...nor someone who does not exist', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign', null, gen_random_uuid()), 'that person is not staff at this club');
  perform tests.assert_eq('...nor nobody', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign'), 'that person is not staff at this club');
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.revoke_membership(m_s3);
  perform tests.assert_eq('...nor a server whose access was taken away', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign', null, m_s3), 'that person no longer has access to this club');
  perform tests.logout();
  update public.site_memberships set access_start_at = now() - interval '2 days', access_end_at = now() - interval '1 minute' where id = m_s2;
  perform tests.assert_eq('...nor one whose access window has ended', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign', null, m_s2), 'that person no longer has access to this club');
  perform tests.logout();
  insert into public.site_shifts (venue_id, name, starts_at, ends_at) values (venue_a, 'Old shift', now() - interval '3 hours', now() - interval '1 hour') returning id into shift_old;
  update public.site_memberships set access_start_at = null, access_end_at = null, shift_id = shift_old where id = m_s2;
  perform tests.assert_eq('...nor one whose shift is over', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign', null, m_s2), 'that person no longer has access to this club');
  perform tests.logout();
  update public.site_memberships set shift_id = null where id = m_s2;
  perform tests.assert_eq('a manager hands it to another server', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign', null, m_s2), 'ok');
  perform tests.assert_eq('...it goes back to New, theirs, not yet taken', tests.req_status(qg) || '|' || (tests.req_assigned(qg) = m_s2) || '|' || tests.req_flags(qg), 'new|true|acknowledged=false,closed=false');
  perform tests.assert_eq('the first server can no longer act on it', tests.act_as(srv_1, 'srv1@club.example', qg, 'complete'), 'this request belongs to another server');
  perform tests.assert_eq('the new one takes it', tests.act_as(srv_2, 'srv2@club.example', qg, 'acknowledge'), 'ok');
  perform tests.assert_eq('a manager can hand it to a manager too', tests.act_as(mgr_a, 'mgra@club.example', qg, 'reassign', null, m_mgr), 'ok');
  perform tests.logout();
  select * into r from public.audit_log where action = 'service_request.reassigned' and entity_id = qg::text order by details ->> 'to_membership' limit 1;
  perform tests.assert_eq('a handover names the manager and who it went to', r.actor_email || '|' || (r.details ->> 'to_membership'), 'mgra@club.example|' || least(m_s2::text, m_mgr::text));
  perform tests.assert_eq('...two handovers were recorded', tests.audit_count('service_request.reassigned', qg), 2);

  ---------------------------------------------------------------- the rest of the refusals
  perform tests.assert_eq('an action that does not exist', tests.act_as(mgr_a, 'mgra@club.example', qo, 'explode'), 'unknown action');
  perform tests.assert_eq('no action', tests.act_as(mgr_a, 'mgra@club.example', qo, null), 'unknown action');
  perform tests.assert_eq('a request that does not exist', tests.act_as(mgr_a, 'mgra@club.example', gen_random_uuid(), 'acknowledge'), 'not allowed');
  perform tests.assert_eq('a manager of the other club gets the same answer as for one that does not exist', tests.act_as(mgr_b, 'mgrb@club.example', qo, 'acknowledge'), 'not allowed');
  perform tests.assert_eq('a server of the other club', tests.act_as(srv_b, 'srvb@club.example', qo, 'acknowledge'), 'not allowed');
  perform tests.assert_eq('door staff', tests.act_as(door_a, 'doora@club.example', qo, 'acknowledge'), 'not allowed');
  perform tests.assert_eq('a rival owner', tests.act_as(rival_u, 'rival@club2.example', qo, 'acknowledge'), 'not allowed');
  perform tests.assert_eq('a person with no role', tests.act_as(rando, null, qo, 'acknowledge'), 'not allowed');
  perform tests.assert_eq('...and nothing changed', tests.req_status(qo), 'new');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format($q$select public.update_service_request(%L, 'acknowledge')$q$, qo), 'permission denied');
  perform tests.assert_eq('a server whose access was taken away cannot act', tests.act_as(srv_3, 'srv3@club.example', qo, 'acknowledge'), 'not allowed');

  ---------------------------------------------------------------- the list again: closed requests, and the bounds
  perform tests.logout();
  update public.site_service_requests set closed_at = now() - interval '1 hour' where id = q2;
  update public.site_service_requests set closed_at = now() - interval '2 hours' where id = qf;
  update public.site_service_requests set closed_at = now() - interval '3 hours' where id = qd;
  update public.site_service_requests set closed_at = now() - interval '4 hours' where id = qx;
  update public.site_service_requests set closed_at = now() - interval '5 hours' where id = qy;
  update public.site_service_requests set closed_at = now() - interval '25 hours' where id = qc;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('closed requests are left out unless asked for', (select count(*) from public.list_service_requests(venue_a) where status in ('completed', 'cancelled'))::int, 0);
  perform tests.assert_eq('...and then shown for the last 24 hours only (the one closed 25 hours ago is not)', (select count(*) from public.list_service_requests(venue_a, true) where request_id = qc)::int, 0);
  perform tests.assert_eq('...the one closed 2 hours ago is', (select count(*) from public.list_service_requests(venue_a, true) where request_id = qf)::int, 1);
  select array_agg(status in ('completed', 'cancelled') order by ord) into flags from (select status, row_number() over () ord from public.list_service_requests(venue_a, true)) x;
  perform tests.assert_true('open requests come before closed ones', flags = array(select f from unnest(flags) f order by f));
  perform tests.assert_true('...and there are both kinds in that list, so the check means something', true = any (flags) and false = any (flags));
  select array_agg(request_id order by ord) into arr from (select request_id, row_number() over () ord from public.list_service_requests(venue_a, true) where status in ('completed', 'cancelled')) x;
  perform tests.assert_eq('closed requests are newest first', arr, array[q2, qf, qd, qx, qy]);
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_eq('a server is shown their own closed requests too', (select count(*) from public.list_service_requests(venue_a, true) where request_id = q2)::int, 1);
  perform tests.assert_eq('...but not one a manager took over', (select count(*) from public.list_service_requests(venue_a, true) where request_id = qf)::int, 0);
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_eq('...and a colleague does not see the other server''s closed one', (select count(*) from public.list_service_requests(venue_a, true) where request_id = q2)::int, 0);

  perform tests.logout();
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    select venue_a, type_a, slot_eve, night + 30, 'Crowd ' || g, 'crowd' || g || '@test.example', 2, 1000, 'paid' from generate_series(1, 305) g;
  insert into public.site_service_requests (venue_id, booking_id, kind)
    select venue_a, b.id, 'assistance' from public.site_table_bookings b where b.customer_name like 'Crowd %';
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('a club with hundreds of open requests returns the first 300, not all of them', (select count(*) from public.list_service_requests(venue_a))::int, 300);

  ---------------------------------------------------------------- the table itself, and the internal helpers
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('the owner cannot read the requests table directly', $q$select count(*) from public.site_service_requests$q$, 'permission denied');
  perform tests.assert_raises('...nor write it', format($q$insert into public.site_service_requests (venue_id, booking_id, kind) values (%L, %L, 'assistance')$q$, venue_a, b_pend), 'permission denied');
  perform tests.assert_raises('the club-level lookup is internal', format($q$select public.desk_level(%L)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...so is the membership lookup', format($q$select public.desk_membership(%L)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...and the availability check', format($q$select public.desk_staff_problem(%L, %L, array['server'])$q$, m_s1, venue_a), 'permission denied');

  ---------------------------------------------------------------- when things are deleted
  perform tests.logout();
  delete from public.site_table_bookings where id = b_ada;
  perform tests.assert_eq('deleting a booking removes its requests', (select count(*) from public.site_service_requests where booking_id = b_ada)::int, 0);
  update public.site_invitations set membership_id = null where membership_id = m_s2;
  delete from public.site_memberships where id = m_s2;
  perform tests.assert_true('deleting a person keeps their requests but leaves them with nobody', (select count(*) from public.site_service_requests where id = qo and assigned_membership_id is null) = 1);

  ---------------------------------------------------------------- hygiene
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname in ('desk_level', 'desk_membership', 'desk_staff_problem', 'create_service_request', 'list_service_requests', 'update_service_request')
      and p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%';
  perform tests.assert_eq('all six functions run with their owner''s rights and pin their search path', n, 6);
  perform tests.assert_eq('the requests table has row level security on', (select relrowsecurity from pg_class where oid = 'public.site_service_requests'::regclass), true);
end $$;

rollback;
