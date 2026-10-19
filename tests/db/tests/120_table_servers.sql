-- Giving a booking to a server, and a server's own list. What matters most: only the owner or a manager of THAT club can give a
-- booking to someone; only a paid booking, and only to an active server of the same club; a server sees only the bookings given to
-- them (never another server's, never the guest's email or phone); every change is attributed; nothing reaches the table directly.
begin;

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
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_r uuid; tok text; r record; n int; txt text; cols text;
  type_a uuid; type_b uuid; slot_eve uuid; slot_late uuid; slot_b uuid;
  m_s1 uuid; m_s2 uuid; m_sb uuid; m_s3 uuid; m_door uuid; m_mgr uuid; m_owner uuid; shift_old uuid;
  b_ada uuid; b_zed uuid; b_cleo uuid; b_next uuid; b_pend uuid; b_ref uuid; b_fail uuid; b_canc uuid; b_bea uuid;
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
  venue_r := public.create_org_venue(org2, 'Rival Club');

  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'mgra@club.example', 'manager', venue_a) i;
  perform tests.login(mgr_a, 'mgra@club.example'); perform public.accept_invitation(tok);
  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'mgrb@club.example', 'manager', venue_b) i;
  perform tests.login(mgr_b, 'mgrb@club.example'); perform public.accept_invitation(tok);
  -- Club A's manager invites the servers and the door person of their own club.
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

  -- Production allows a 'cancelled' booking status; the committed constraint does not list it. Drop it for this test only.
  alter table public.site_table_bookings drop constraint site_table_bookings_status_check;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'VIP booth', 8, 0, 0, 5) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 5) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 0, '01:00', 'Late') returning id into slot_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;

  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, customer_phone, guest_count, amount_total_cents, status, confirmation_code)
    values (venue_a, type_a, slot_eve, night, 'Ada Evening', 'ada@test.example', '+15550002', 4, 40000, 'paid', 'CODE-ADA') returning id into b_ada;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue_a, type_a, slot_eve, night, 'Zed Evening', 'zed@test.example', 2, 20000, 'paid', 'CODE-ZED') returning id into b_zed;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue_a, type_a, slot_late, night + 1, 'Cleo Late', 'cleo@test.example', 3, 30000, 'paid', 'CODE-LATE') returning id into b_cleo;   -- stored under the next date, belongs to `night`
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue_a, type_a, slot_eve, night + 1, 'Next Night', 'next@test.example', 6, 60000, 'paid', 'CODE-NEXT') returning id into b_next;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, type_a, slot_eve, night, 'Pending Pat', 'pat@test.example', 2, 1000, 'pending') returning id into b_pend;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, type_a, slot_eve, night, 'Refunded Rae', 'rae@test.example', 2, 1000, 'refunded') returning id into b_ref;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, type_a, slot_eve, night, 'Failed Fay', 'fay@test.example', 2, 1000, 'failed') returning id into b_fail;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, type_a, slot_eve, night, 'Cancelled Cal', 'cal@test.example', 2, 1000, 'cancelled') returning id into b_canc;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_b, type_b, slot_b, night, 'Bea Clubb', 'bea@test.example', 2, 1000, 'paid') returning id into b_bea;

  ---------------------------------------------------------------- who may give a booking to a server
  perform tests.login(owner_u, 'owner@club.example');
  perform public.assign_booking_server(b_ada, m_s1);
  perform tests.assert_eq('the owner can give a booking to a server of their club', (select membership_id from public.list_venue_booking_servers(venue_a, night, night) where booking_id = b_ada), m_s1);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_zed, m_s1);
  perform tests.assert_eq('the manager of the club can too', (select count(*) from public.list_venue_booking_servers(venue_a, night, night))::int, 2);

  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('a manager of the other club cannot', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_s1), 'not allowed');
  perform tests.assert_raises('...not even for a booking at their own club given to the other club''s server', format($q$select public.assign_booking_server(%L, %L)$q$, b_bea, m_s1), 'not a server at this club');
  perform tests.login(rival_u, 'rival@club2.example');
  perform tests.assert_raises('a rival owner cannot', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_s1), 'not allowed');
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_raises('a server cannot give out bookings, not even to themselves', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_s1), 'not allowed');
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff cannot', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_s1), 'not allowed');
  perform tests.login(rando);
  perform tests.assert_raises('a signed-in person with no role cannot', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_s1), 'not allowed');
  perform tests.assert_raises('a booking that does not exist gets the same answer as one that is not yours (no way to probe ids)', format($q$select public.assign_booking_server(%L, %L)$q$, gen_random_uuid(), m_s1), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_s1), 'permission denied');

  ---------------------------------------------------------------- which booking, which person
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_raises('no booking chosen', format($q$select public.assign_booking_server(null, %L)$q$, m_s1), 'choose a booking');
  perform tests.assert_raises('no server chosen', format($q$select public.assign_booking_server(%L, null)$q$, b_next), 'choose a booking');
  perform tests.assert_raises('a pending booking cannot be given to a server (it is not confirmed)', format($q$select public.assign_booking_server(%L, %L)$q$, b_pend, m_s1), 'only a paid booking');
  perform tests.assert_raises('a refunded one cannot', format($q$select public.assign_booking_server(%L, %L)$q$, b_ref, m_s1), 'only a paid booking');
  perform tests.assert_raises('a failed one cannot', format($q$select public.assign_booking_server(%L, %L)$q$, b_fail, m_s1), 'only a paid booking');
  perform tests.assert_raises('a cancelled one cannot', format($q$select public.assign_booking_server(%L, %L)$q$, b_canc, m_s1), 'only a paid booking');
  perform tests.assert_raises('door staff are not servers', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_door), 'not a server at this club');
  perform tests.assert_raises('a manager is not a server', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_mgr), 'not a server at this club');
  perform tests.assert_raises('the owner''s own membership is not a server', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_owner), 'not a server at this club');
  perform tests.assert_raises('another club''s server is refused', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_sb), 'not a server at this club');
  perform tests.assert_raises('a membership that does not exist is refused', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, gen_random_uuid()), 'not a server at this club');
  perform tests.assert_eq('none of those refusals left an assignment behind', (select count(*) from public.list_venue_booking_servers(venue_a, night, night + 1))::int, 2);

  -- A server whose access was taken away, whose window ended, or whose shift is over.
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.revoke_membership(m_s3);
  perform tests.assert_raises('a server whose access was revoked cannot be given a booking', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_s3), 'no longer has access');
  perform tests.logout();
  update public.site_memberships set access_end_at = now() - interval '1 minute', access_start_at = now() - interval '1 day' where id = m_s2;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_raises('...nor one whose access window has ended', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_s2), 'no longer has access');
  perform tests.logout();
  update public.site_memberships set access_end_at = now() + interval '1 day' where id = m_s2;
  perform tests.login(mgr_a, 'mgra@club.example');
  shift_old := public.create_shift(venue_a, 'Old shift', now() - interval '3 hours', now() - interval '1 hour');
  perform tests.logout();
  update public.site_memberships set shift_id = shift_old, access_end_at = null, access_start_at = null where id = m_s2;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_raises('...nor one whose shift is over', format($q$select public.assign_booking_server(%L, %L)$q$, b_next, m_s2), 'no longer has access');
  perform tests.logout();
  update public.site_memberships set shift_id = null, access_start_at = now() + interval '2 hours', access_end_at = now() + interval '9 hours' where id = m_s2;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_next, m_s2);
  perform tests.assert_eq('a server whose shift has not started yet CAN be given tonight''s tables ahead of time', (select membership_id from public.list_venue_booking_servers(venue_a, night + 1, night + 1) where booking_id = b_next), m_s2);
  perform public.unassign_booking_server(b_next);

  ---------------------------------------------------------------- reassigning, taking away, and the record of it
  perform tests.logout();
  update public.site_memberships set access_start_at = null, access_end_at = null where id = m_s2;
  perform tests.login(owner_u, 'owner@club.example');
  perform public.unassign_booking_server(b_ada); perform public.unassign_booking_server(b_zed);   -- start from nothing
  perform tests.logout();
  delete from public.audit_log where action like 'booking.server_%';

  perform tests.login(owner_u, 'owner@club.example');
  perform public.assign_booking_server(b_ada, m_s1);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_ada, m_s2);   -- changes hands
  perform public.assign_booking_server(b_ada, m_s2);   -- the same again: nothing to do
  perform tests.assert_eq('a booking has one server: reassigning replaces, it does not add', (select count(*) from public.list_venue_booking_servers(venue_a, night, night) where booking_id = b_ada)::int, 1);
  perform tests.assert_eq('...and it is the new one', (select membership_id from public.list_venue_booking_servers(venue_a, night, night) where booking_id = b_ada), m_s2);
  perform tests.logout();
  perform tests.assert_eq('the link records who handed it over', (select assigned_by from public.site_booking_servers where booking_id = b_ada), mgr_a);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.unassign_booking_server(b_ada);
  perform public.unassign_booking_server(b_ada);       -- nobody left: nothing to do
  perform tests.assert_eq('taking the server away leaves the booking with nobody', (select count(*) from public.list_venue_booking_servers(venue_a, night, night))::int, 0);

  perform tests.logout();
  perform tests.assert_eq('exactly three entries were recorded: given, handed over, taken away (repeats record nothing)', (select count(*) from public.audit_log where action like 'booking.server_%')::int, 3);
  perform tests.assert_eq('...one of each kind, all about this booking', (select string_agg(action, ',' order by action) from public.audit_log where action like 'booking.server_%' and entity_id = b_ada::text), 'booking.server_assigned,booking.server_reassigned,booking.server_removed');
  select * into r from public.audit_log where action = 'booking.server_assigned' and entity_id = b_ada::text;
  perform tests.assert_eq('the first names who did it', r.actor_id::text || '|' || r.actor_email, owner_u::text || '|owner@club.example');
  perform tests.assert_eq('...and what it concerned', r.entity_type || '|' || (r.details ->> 'to_membership') || '|' || (r.details ->> 'to_user') || '|' || coalesce(r.details ->> 'from_membership', 'none'), 'site_table_bookings|' || m_s1 || '|' || srv_1 || '|none');
  select * into r from public.audit_log where action = 'booking.server_reassigned' and entity_id = b_ada::text;
  perform tests.assert_eq('a handover names the manager and both servers', r.actor_email || '|' || (r.details ->> 'from_membership') || '|' || (r.details ->> 'to_membership'), 'mgra@club.example|' || m_s1 || '|' || m_s2);
  select * into r from public.audit_log where action = 'booking.server_removed' and entity_id = b_ada::text;
  perform tests.assert_eq('taking away names who and from whom', r.actor_email || '|' || (r.details ->> 'from_membership'), 'mgra@club.example|' || m_s2);

  ---------------------------------------------------------------- a server's own list
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.assign_booking_server(b_ada, m_s1);
  perform public.assign_booking_server(b_zed, m_s2);
  perform public.assign_booking_server(b_cleo, m_s1);   -- 01:00 on night + 1: belongs to `night`
  perform public.assign_booking_server(b_next, m_s1);   -- the next night's evening

  perform tests.login(srv_1, 'srv1@club.example');
  select string_agg(customer_name, ',' order by ord) into txt from (select customer_name, row_number() over () ord from public.my_assigned_tables(night)) x;
  perform tests.assert_eq('a server sees their own tables for the night, the evening first and the after-midnight tail after it', txt, 'Ada Evening,Cleo Late');
  perform tests.assert_eq('...not the other server''s table', (select count(*) from public.my_assigned_tables(night) where customer_name = 'Zed Evening')::int, 0);
  select string_agg(customer_name, ',') into txt from public.my_assigned_tables(night + 1);
  perform tests.assert_eq('the next night is its own list', txt, 'Next Night');
  perform tests.assert_eq('a night with nothing is an empty list, not an error', (select count(*) from public.my_assigned_tables(night + 5))::int, 0);
  select * into r from public.my_assigned_tables(night) where customer_name = 'Ada Evening';
  perform tests.assert_eq('a row carries the table, arrival and party', r.table_name || '|' || r.slot_label || '|' || r.start_time || '|' || r.guest_count || '|' || r.venue_name || '|' || r.night_date, 'VIP booth|Evening|21:00:00|4|Club A|' || night);
  perform tests.assert_eq('...and the code staff use to find the booking', r.confirmation_code, 'CODE-ADA');
  perform tests.assert_true('...and whether the guest has arrived', r.checked_in_at is null);
  select string_agg(column_name, ',' order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'public' and table_name = 'site_table_bookings' and column_name in ('customer_email', 'customer_phone');
  perform tests.assert_true('(the booking does hold contact details, so the next check means something)', cols is not null);
  perform tests.assert_eq('the list does not carry the guest''s email or phone', (select count(*) from jsonb_object_keys((select to_jsonb(t) from public.my_assigned_tables(night) t limit 1)) k where k in ('customer_email', 'customer_phone', 'email', 'phone'))::int, 0);
  perform tests.assert_raises('no night chosen', $q$select * from public.my_assigned_tables(null)$q$, 'choose a night');

  perform tests.logout();
  update public.site_table_bookings set checked_in_at = now() where id = b_ada;
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_true('a guest who has arrived shows as arrived', (select checked_in_at is not null from public.my_assigned_tables(night) where customer_name = 'Ada Evening'));

  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_eq('the other server sees only theirs', (select string_agg(customer_name, ',') from public.my_assigned_tables(night)), 'Zed Evening');
  perform tests.login(srv_b, 'srvb@club.example');
  perform tests.assert_eq('a server of the other club sees nothing of Club A', (select count(*) from public.my_assigned_tables(night))::int, 0);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('a manager has no tables of their own (they see the club through the bookings list)', (select count(*) from public.my_assigned_tables(night))::int, 0);
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_eq('door staff have no tables', (select count(*) from public.my_assigned_tables(night))::int, 0);
  perform tests.login(rando);
  perform tests.assert_eq('a signed-in person with no role has none', (select count(*) from public.my_assigned_tables(night))::int, 0);
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot ask', format($q$select * from public.my_assigned_tables(%L)$q$, night), 'permission denied');

  -- A booking that stops being paid drops off the server's list; a server whose access ends sees nothing.
  perform tests.logout();
  update public.site_table_bookings set status = 'refunded' where id = b_cleo;
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_eq('a booking refunded after it was given out drops off the list', (select string_agg(customer_name, ',') from public.my_assigned_tables(night)), 'Ada Evening');
  perform tests.logout();
  update public.site_table_bookings set status = 'paid' where id = b_cleo;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.revoke_membership(m_s1);
  perform tests.login(srv_1, 'srv1@club.example');
  perform tests.assert_eq('a server whose access was revoked sees nothing, though the rows still exist', (select count(*) from public.my_assigned_tables(night))::int, 0);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('the manager sees that the bookings are held by someone who cannot serve them', (select count(*) from public.list_venue_booking_servers(venue_a, night, night + 1) where membership_id = m_s1 and not server_available)::int, 3);
  perform tests.assert_eq('...and that the other server can', (select count(*) from public.list_venue_booking_servers(venue_a, night, night + 1) where membership_id = m_s2 and server_available)::int, 1);
  perform tests.logout();
  update public.site_memberships set access_start_at = now() - interval '2 days', access_end_at = now() - interval '1 minute' where id = m_s2;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('a server whose access window has ended shows as unavailable', (select count(*) from public.list_venue_booking_servers(venue_a, night, night + 1) where membership_id = m_s2 and not server_available)::int, 1);
  perform tests.logout();
  update public.site_memberships set access_start_at = null, access_end_at = null, shift_id = shift_old where id = m_s2;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('...and so does one whose shift is over', (select count(*) from public.list_venue_booking_servers(venue_a, night, night + 1) where membership_id = m_s2 and not server_available)::int, 1);
  perform tests.logout();
  update public.site_memberships set shift_id = null where id = m_s2;
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('...and one with a current window and no shift is available again', (select count(*) from public.list_venue_booking_servers(venue_a, night, night + 1) where membership_id = m_s2 and server_available)::int, 1);
  perform public.assign_booking_server(b_ada, m_s2);
  perform tests.assert_eq('a booking held by a revoked server can be given to someone else', (select membership_id from public.list_venue_booking_servers(venue_a, night, night) where booking_id = b_ada), m_s2);

  ---------------------------------------------------------------- the manager's list of who has what
  perform tests.assert_eq('the list is per club and per night: Club A, the night', (select count(*) from public.list_venue_booking_servers(venue_a, night, night))::int, 3);
  perform tests.assert_eq('...the after-midnight booking is counted under the night it belongs to, not its stored date', (select count(*) from public.list_venue_booking_servers(venue_a, night + 1, night + 1) where booking_id = b_cleo)::int, 0);
  perform tests.assert_eq('...and the next night', (select count(*) from public.list_venue_booking_servers(venue_a, night + 1, night + 1))::int, 1);
  perform tests.assert_raises('an end before the start is refused', format($q$select * from public.list_venue_booking_servers(%L, %L, %L)$q$, venue_a, night, night - 1), 'before the start');
  perform tests.assert_raises('no start date is refused', format($q$select * from public.list_venue_booking_servers(%L, null, %L)$q$, venue_a, night), 'choose a start');
  perform tests.assert_eq('93 nights is allowed', (select count(*) from public.list_venue_booking_servers(venue_a, night, night + 92))::int, 4);
  perform tests.assert_raises('94 nights is not', format($q$select * from public.list_venue_booking_servers(%L, %L, %L)$q$, venue_a, night, night + 93), 'at most 93 nights');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('a manager of the other club cannot read Club A''s assignments', format($q$select * from public.list_venue_booking_servers(%L, %L, %L)$q$, venue_a, night, night), 'not allowed');
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_raises('a server cannot read the club''s assignments (they would learn the others'' identities)', format($q$select * from public.list_venue_booking_servers(%L, %L, %L)$q$, venue_a, night, night), 'not allowed');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('Club B has none of Club A''s', (select count(*) from public.list_venue_booking_servers(venue_b, night - 5, night + 5))::int, 0);

  ---------------------------------------------------------------- taking away needs the same standing as giving
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('a manager of the other club cannot take a server away', format($q$select public.unassign_booking_server(%L)$q$, b_ada), 'not allowed');
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_raises('a server cannot drop a table by taking themselves off it', format($q$select public.unassign_booking_server(%L)$q$, b_ada), 'not allowed');
  perform tests.assert_raises('an unknown booking is refused the same way', format($q$select public.unassign_booking_server(%L)$q$, gen_random_uuid()), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot take one away', format($q$select public.unassign_booking_server(%L)$q$, b_ada), 'permission denied');

  ---------------------------------------------------------------- bounded answers
  perform tests.logout();
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    select venue_a, type_a, slot_eve, night + 30, 'Crowd ' || g, 'crowd' || g || '@test.example', 2, 1000, 'paid' from generate_series(1, 1005) g;
  insert into public.site_booking_servers (booking_id, membership_id, assigned_by)
    select b.id, m_s2, mgr_a from public.site_table_bookings b where b.customer_name like 'Crowd %';
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('a night with more than 1000 assignments returns the first 1000, not all of them', (select count(*) from public.list_venue_booking_servers(venue_a, night + 30, night + 30))::int, 1000);
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_eq('a server''s list is bounded too: 300 tables at most', (select count(*) from public.my_assigned_tables(night + 30))::int, 300);

  ---------------------------------------------------------------- the table itself, and the internal helpers
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('the owner cannot read the link table directly (the functions are the only way in)', $q$select count(*) from public.site_booking_servers$q$, 'permission denied');
  perform tests.assert_raises('...nor write it', format($q$insert into public.site_booking_servers (booking_id, membership_id, assigned_by) values (%L, %L, %L)$q$, b_next, m_s2, owner_u), 'permission denied');
  perform tests.assert_raises('the audit writer is not callable by a signed-in person (they could forge entries)', $q$select public.desk_log('booking.server_assigned', 'site_table_bookings', gen_random_uuid())$q$, 'permission denied');
  perform tests.assert_raises('the booking-to-club lookup is internal too', format($q$select public.booking_venue(%L)$q$, b_ada), 'permission denied');
  perform tests.login(srv_2, 'srv2@club.example');
  perform tests.assert_raises('a server cannot read the link table either', $q$select count(*) from public.site_booking_servers$q$, 'permission denied');

  ---------------------------------------------------------------- when things are deleted
  perform tests.logout();
  delete from public.site_table_bookings where id = b_zed;
  perform tests.assert_eq('deleting a booking removes its assignment', (select count(*) from public.site_booking_servers where booking_id = b_zed)::int, 0);
  update public.site_invitations set membership_id = null where membership_id = m_s2;   -- the accepted invitation points at it
  delete from public.site_memberships where id = m_s2;
  perform tests.assert_eq('deleting a membership removes the assignments it held', (select count(*) from public.site_booking_servers where membership_id = m_s2)::int, 0);

  ---------------------------------------------------------------- hygiene
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname in ('desk_log', 'booking_venue', 'assign_booking_server', 'unassign_booking_server', 'list_venue_booking_servers', 'my_assigned_tables')
      and p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%';
  perform tests.assert_eq('all six functions run with their owner''s rights and pin their search path', n, 6);
  perform tests.assert_eq('the link table has row level security on', (select relrowsecurity from pg_class where oid = 'public.site_booking_servers'::regclass), true);
end $$;

rollback;
