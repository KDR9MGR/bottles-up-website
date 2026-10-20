-- Floor plan placement, table states, moving a booking and deposit terms (20261021100000_floor_plan_and_table_states.sql). What matters:
--   * only the club's owner or manager places tables, blocks or reopens them, moves a booking and sets deposit terms (not a server, the door, another club's manager,
--     a stranger or a visitor), and only inside their own club;
--   * a placement is a box fully inside the floor image, stored as percentages like the website's editor; editing a table type never moves it;
--   * the ONE count behind every booking path: paid bookings, a checkout started in the last 10 minutes (the hold) and the manager's blocks; a checkout older than
--     that, an expired hold, a reopened block take nothing; tables that are already booked can never be blocked; the public picker, the walk-in options and the
--     walk-in booking all agree;
--   * a booking moves to another table only if the party fits and a table is really free, keeps what the guest agreed to pay, and leaves a record of who, when, why;
--   * deposit terms: only valid combinations (and agreeing with the venue's credit switch); every new booking carries a copy, and changing the venue's terms later
--     never rewrites a booking that exists;
--   * every refusal is a plain sentence and changes nothing; the closed tables cannot be read or written by the app.
-- Every helper below signs in, does its one thing and signs out, so direct table access in the body always runs as the database owner.
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
-- the result as text, or "ERROR: <sentence>"
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
-- the result as jsonb; an error fails the test
create function tests.runj(p_user uuid, p_email text, p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into r;
  perform tests.logout();
  return r;
end $$;
create function tests.states_text(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  select coalesce(string_agg(x, ' | '), '(none)') into r from (
    select to_char(start_time, 'HH24:MI') || '/' || table_name || '=' || booked || 'b' || occupied || 'o' || held || 'h' || unavailable || 'u' || available || 'a' as x
      from public.desk_table_states(p_venue, p_night)) s;
  perform tests.logout();
  return r;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
-- one named piece of the states text: tests.part(text, 2) is the second " | " piece
create function tests.part(p_text text, p_n int) returns text language sql immutable as $$ select split_part(p_text, ' | ', p_n) $$;
create function tests.blocks_text(p_user uuid, p_email text, p_venue uuid, p_night date) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  select coalesce(string_agg(table_name || ':' || kind || ':' || reason || ':' || made_by, ',' order by table_name, reason), '(none)') into r from public.desk_table_blocks(p_venue, p_night);
  perform tests.logout();
  return r;
end $$;
create function tests.moves_text(p_user uuid, p_email text, p_booking uuid) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  select coalesce(string_agg(from_table || '>' || to_table || ':' || reason || ':' || moved_by || ':' || coalesce(price_difference_cents::text, 'none'), ' | ' order by moved_at desc), '(none)') into r from public.desk_booking_moves(p_booking);
  perform tests.logout();
  return r;
end $$;
create function tests.activity_actions(p_user uuid, p_email text, p_booking uuid) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  select coalesce(string_agg(action, ',' order by action), '(none)') into r from public.desk_booking_activity(p_booking);
  perform tests.logout();
  return r;
end $$;
create function tests.layout_text(p_user uuid, p_email text, p_venue uuid) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  select string_agg(name || ':' || coalesce(left(floor_id::text, 4), 'unplaced') || ':' || coalesce(pos_x::text, '-') || ':' || coalesce(width::text, '-') || ':' || coalesce(included_admissions::text, '-'), ',' order by name) into r from public.list_venue_table_layout(p_venue);
  perform tests.logout();
  return r;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000007d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000007d2';
  srv constant uuid := '00000000-0000-0000-0000-0000000007d3';
  door constant uuid := '00000000-0000-0000-0000-0000000007d5';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000007d6';
  rando constant uuid := '00000000-0000-0000-0000-0000000007d7';
  org uuid; venue_a uuid; venue_b uuid; fl1 uuid; fl2 uuid; fl_b uuid;
  t_booth uuid; t_pair uuid; t_sofa uuid; t_b uuid; s_eve uuid; s_late uuid; s_other uuid; s_b uuid;
  night date := current_date;
  r text; j record; k record; v_block uuid; v_block2 uuid; b1 uuid; b2 uuid; b3 uuid; b4 uuid; b_pend uuid; b_b uuid; v_json jsonb; who text;
  others text[] := array['srv@fl.example', 'door@fl.example', 'mgrb@fl.example', 'rando@fl.example'];
begin
  insert into auth.users (id, email) values (owner_u, 'owner@fl.example'), (mgr_a, 'mgra@fl.example'), (srv, 'srv@fl.example'), (door, 'door@fl.example'),
    (mgr_b, 'mgrb@fl.example'), (rando, 'rando@fl.example');
  perform tests.login(owner_u, 'owner@fl.example');
  org := public.create_organization('Floor Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@fl.example', org, 'mgra@fl.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@fl.example', org, 'mgrb@fl.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@fl.example', org, 'srv@fl.example', 'server', venue_a, srv);
  perform tests.join_as(mgr_a, 'mgra@fl.example', org, 'door@fl.example', 'door', venue_a, door);

  insert into public.site_venue_floors (venue_id, label, image_url, sort_order) values (venue_a, 'Downstairs', 'https://img.example/a1.png', 0) returning id into fl1;
  insert into public.site_venue_floors (venue_id, label, image_url, sort_order) values (venue_a, 'Upstairs', 'https://img.example/a2.png', 1) returning id into fl2;
  insert into public.site_venue_floors (venue_id, label, image_url, sort_order) values (venue_b, 'Main', 'https://img.example/b1.png', 0) returning id into fl_b;
  insert into public.site_table_types (venue_id, name, max_guests, min_guests, min_spend_cents, deposit_cents, inventory_count, sort_order) values (venue_a, 'Booth', 6, null, 0, 10000, 1, 1) returning id into t_booth;
  insert into public.site_table_types (venue_id, name, max_guests, min_guests, min_spend_cents, deposit_cents, inventory_count, sort_order) values (venue_a, 'Pair table', 4, 2, 0, 2500, 3, 2) returning id into t_pair;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count, pricing_mode, hourly_rate_cents, min_hours, sort_order) values (venue_a, 'Sofa', 8, 0, 0, 2, 'hourly', 4000, 2, 3) returning id into t_sofa;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 1000, 5) returning id into t_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from night)::int, '21:00') returning id into s_eve;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from night)::int, '01:00') returning id into s_late;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, (extract(dow from night)::int + 3) % 7, '21:00') returning id into s_other;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_b, extract(dow from night)::int, '21:00') returning id into s_b;

  ---------------------------------------------------------------- 1. the layout: who sees it, who places tables
  perform tests.assert_eq('the manager sees every table type, none placed yet', tests.layout_text(mgr_a, 'mgra@fl.example', venue_a), 'Booth:unplaced:-:-:-,Pair table:unplaced:-:-:-,Sofa:unplaced:-:-:-');
  perform tests.assert_eq('the owner sees them too', tests.layout_text(owner_u, 'owner@fl.example', venue_a), 'Booth:unplaced:-:-:-,Pair table:unplaced:-:-:-,Sofa:unplaced:-:-:-');
  foreach who in array others loop
    perform tests.assert_eq('the layout is refused to ' || who, tests.layout_text((select id from auth.users where email = who), who, venue_a), 'ERROR: not allowed');
    perform tests.assert_eq('...and so is placing a table, for ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.place_venue_table(%L, %L, %L, 10, 10, 10, 10)::text$q$, venue_a, t_booth, fl1)), 'ERROR: not allowed');
    perform tests.assert_eq('...and removing one from the plan, for ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.unplace_venue_table(%L, %L)::text$q$, venue_a, t_booth)), 'ERROR: not allowed');
    perform tests.assert_eq('...and stating included admissions, for ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.set_table_included_admissions(%L, %L, 2)::text$q$, venue_a, t_booth)), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the layout', format($q$select * from public.list_venue_table_layout(%L)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...nor place a table', format($q$select public.place_venue_table(%L, %L, %L, 10, 10, 10, 10)$q$, venue_a, t_booth, fl1), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- 2. placing
  perform tests.assert_eq('the manager places the booth', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, %L, 10.126, 20, 15, 10.5)::text$q$, venue_a, t_booth, fl1)), 'ok');
  select * into j from public.site_table_types where id = t_booth;
  perform tests.assert_eq('the table is on the floor, as percentages kept to two decimals', j.floor_id::text || ':' || j.pos_x || ':' || j.pos_y || ':' || j.width || ':' || j.height, fl1::text || ':10.13:20.00:15.00:10.50');
  perform tests.assert_eq('the placement is logged against the manager', (select count(*)::int from public.audit_log where action = 'venue_setup.table_placed' and entity_id = t_booth::text and actor_id = mgr_a), 1);
  perform tests.assert_eq('the owner can move it to another floor, filling the whole image', tests.try(owner_u, 'owner@fl.example', format($q$select public.place_venue_table(%L, %L, %L, 0, 0, 100, 100)::text$q$, venue_a, t_booth, fl2)), 'ok');
  perform tests.assert_eq('...and the layout shows it', tests.layout_text(mgr_a, 'mgra@fl.example', venue_a) like 'Booth:' || left(fl2::text, 4) || ':0.00:100.00:-,%', true);
  perform tests.assert_eq('a table type edit (a rename) never moves it', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_table_type(%L, %L, '{"name":"Big booth"}'::jsonb)::text$q$, venue_a, t_booth)) like 'ERROR%', false);
  perform tests.assert_eq('...it is still on the same floor at the same place', (select name || ':' || floor_id::text || ':' || pos_x || ':' || height from public.site_table_types where id = t_booth), 'Big booth:' || fl2::text || ':0.00:100.00');
  update public.site_table_types set name = 'Booth' where id = t_booth;

  perform tests.assert_eq('another club''s floor is not found', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, %L, 10, 10, 10, 10)::text$q$, venue_a, t_pair, fl_b)), 'ERROR: floor not found');
  perform tests.assert_eq('another club''s table is not found', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, %L, 10, 10, 10, 10)::text$q$, venue_a, t_b, fl1)), 'ERROR: table type not found');
  perform tests.assert_eq('an unknown table is not found', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, gen_random_uuid(), %L, 10, 10, 10, 10)::text$q$, venue_a, fl1)), 'ERROR: table type not found');
  perform tests.assert_eq('a floor must be chosen', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, null, 10, 10, 10, 10)::text$q$, venue_a, t_pair)), 'ERROR: choose a floor and where the table goes');
  perform tests.assert_eq('so must the position', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, %L, null, 10, 10, 10)::text$q$, venue_a, t_pair, fl1)), 'ERROR: choose a floor and where the table goes');
  perform tests.assert_eq('a box off the right edge is refused', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, %L, 90, 10, 20, 10)::text$q$, venue_a, t_pair, fl1)), 'ERROR: the table must be at least 2 percent wide and high and fully inside the floor plan');
  perform tests.assert_eq('...and off the bottom', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, %L, 10, 95, 10, 10)::text$q$, venue_a, t_pair, fl1)), 'ERROR: the table must be at least 2 percent wide and high and fully inside the floor plan');
  perform tests.assert_eq('...and a negative start', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, %L, -1, 10, 10, 10)::text$q$, venue_a, t_pair, fl1)), 'ERROR: the table must be at least 2 percent wide and high and fully inside the floor plan');
  perform tests.assert_eq('...and one too small to tap', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, %L, 10, 10, 1, 10)::text$q$, venue_a, t_pair, fl1)), 'ERROR: the table must be at least 2 percent wide and high and fully inside the floor plan');
  perform tests.assert_eq('...and not a number at all', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.place_venue_table(%L, %L, %L, 'NaN'::numeric, 10, 10, 10)::text$q$, venue_a, t_pair, fl1)), 'ERROR: the table must be at least 2 percent wide and high and fully inside the floor plan');
  perform tests.assert_eq('none of those placed the pair table', (select floor_id from public.site_table_types where id = t_pair) is null, true);

  perform tests.assert_eq('a table can be taken off the plan', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.unplace_venue_table(%L, %L)::text$q$, venue_a, t_booth)), 'ok');
  perform tests.assert_eq('...completely', (select floor_id is null and pos_x is null and pos_y is null and width is null and height is null from public.site_table_types where id = t_booth), true);
  perform tests.assert_eq('taking off one that is not on it changes nothing and is allowed', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.unplace_venue_table(%L, %L)::text$q$, venue_a, t_booth)), 'ok');
  perform tests.assert_eq('another club''s table is not found', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.unplace_venue_table(%L, %L)::text$q$, venue_a, t_b)), 'ERROR: table type not found');

  ---------------------------------------------------------------- 3. included admissions
  perform tests.assert_eq('the manager states that a pair table includes 4 admissions (its whole seating)', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.set_table_included_admissions(%L, %L, 4)::text$q$, venue_a, t_pair)), 'ok');
  perform tests.assert_eq('...and it is kept', (select included_admissions from public.site_table_types where id = t_pair), 4);
  perform tests.assert_eq('more than the table seats is refused', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.set_table_included_admissions(%L, %L, 5)::text$q$, venue_a, t_pair)), 'ERROR: a booking cannot include more admissions (5) than the table seats (4)');
  perform tests.assert_eq('negative is refused', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.set_table_included_admissions(%L, %L, -1)::text$q$, venue_a, t_pair)), 'ERROR: included admissions must be between 0 and 100');
  perform tests.assert_eq('above 100 is refused', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.set_table_included_admissions(%L, %L, 101)::text$q$, venue_a, t_pair)), 'ERROR: included admissions must be between 0 and 100');
  perform tests.assert_eq('another club''s table is not found', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.set_table_included_admissions(%L, %L, 1)::text$q$, venue_a, t_b)), 'ERROR: table type not found');
  perform tests.assert_eq('zero is allowed: the table includes no admission', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.set_table_included_admissions(%L, %L, 0)::text$q$, venue_a, t_booth)), 'ok');
  perform tests.assert_eq('...and is not the same as not stated', (select included_admissions from public.site_table_types where id = t_booth), 0);
  perform tests.assert_eq('null clears it (not stated)', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.set_table_included_admissions(%L, %L, null)::text$q$, venue_a, t_booth)), 'ok');
  perform tests.assert_eq('...really null', (select included_admissions is null from public.site_table_types where id = t_booth), true);
  perform tests.assert_eq('the changes are logged', (select count(*)::int from public.audit_log where action = 'venue_setup.table_admissions_set' and actor_id = mgr_a), 3);

  ---------------------------------------------------------------- 4. table states: who may see them, and the arithmetic
  perform tests.assert_eq('the manager sees every table type at every arrival time tonight, all free',
    tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night),
    '21:00/Booth=0b0o0h0u1a | 21:00/Pair table=0b0o0h0u3a | 21:00/Sofa=0b0o0h0u2a | 01:00/Booth=0b0o0h0u1a | 01:00/Pair table=0b0o0h0u3a | 01:00/Sofa=0b0o0h0u2a');
  perform tests.assert_eq('the owner sees them too', tests.part(tests.states_text(owner_u, 'owner@fl.example', venue_a, night), 1), '21:00/Booth=0b0o0h0u1a');
  perform tests.assert_eq('a server does not', tests.states_text(srv, 'srv@fl.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('the door does not', tests.states_text(door, 'door@fl.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager does not', tests.states_text(mgr_b, 'mgrb@fl.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger does not', tests.states_text(rando, 'rando@fl.example', venue_a, night), 'ERROR: not allowed');
  perform tests.assert_eq('a night too far away cannot be shown', tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night + 61), 'ERROR: that night cannot be shown');
  perform tests.assert_eq('...nor one long past', tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night - 2), 'ERROR: that night cannot be shown');
  perform tests.assert_eq('...a night four weeks ahead can (a private event is planned in advance)', tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night + 28) like '%Booth=%', true);
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot see the states', format($q$select * from public.desk_table_states(%L, current_date)$q$, venue_a), 'permission denied');
  perform tests.logout();

  -- a seated walk-in is OCCUPIED; a paid booking nobody has seated is BOOKED; a checkout started a minute ago is HELD; one started 11 minutes ago takes nothing
  perform tests.assert_eq('a walk-in is booked at the desk', left(tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_create_walkin(%L, current_date, %L, %L, 2, null, 'Walk In', 'walk@fl.example', null, true)::text$q$, venue_a, t_pair, s_eve)), 2), '{"');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_pair, s_eve, night, 'Booked Bea', 'bea@fl.example', 2, 2500, 'paid') returning id into b1;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_sofa, s_eve, night, 'Paying Pat', 'pat@fl.example', 2, 8000, 'pending') returning id into b_pend;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, created_at)
    values (venue_a, t_sofa, s_eve, night, 'Stale Sam', 'sam@fl.example', 2, 8000, 'pending', now() - interval '11 minutes');
  perform tests.assert_eq('the pair table: one occupied (the walk-in), one booked, one left; the sofa: one held by a checkout in progress, the stale one takes nothing',
    tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 2) || ' | ' || tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 3),
    '21:00/Pair table=1b1o0h0u1a | 21:00/Sofa=0b0o1h0u1a');
  perform tests.assert_eq('the count behind every booking path agrees: pair table 2 taken, sofa 1 taken', public.site_table_taken_count(t_pair, s_eve, night) || ':' || public.site_table_taken_count(t_sofa, s_eve, night), '2:1');
  perform tests.assert_eq('...a guest retrying the same checkout does not block themselves', public.site_table_taken_count(t_sofa, s_eve, night, 'PAT@fl.example'), 0);
  perform tests.assert_eq('...another guest''s e-mail changes nothing', public.site_table_taken_count(t_sofa, s_eve, night, 'other@fl.example'), 1);
  perform tests.assert_eq('the hold lasts 10 minutes', public.site_checkout_hold(), interval '10 minutes');
  update public.site_table_bookings set created_at = now() - interval '11 minutes' where id = b_pend;
  perform tests.assert_eq('...and then the checkout stops holding the table', public.site_table_taken_count(t_sofa, s_eve, night), 0);
  perform tests.login(mgr_a, 'mgra@fl.example');
  perform tests.assert_raises('the count is not something the app can call', format($q$select public.site_table_taken_count(%L, %L, current_date)$q$, t_pair, s_eve), 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('...nor a visitor', format($q$select public.site_table_taken_count(%L, %L, current_date)$q$, t_pair, s_eve), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- 5. blocks: a hold and "unavailable"
  v_json := tests.runj(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'held', 1, ' VIP arriving late ', 30)$q$, venue_a, t_sofa, s_eve));
  v_block := (v_json ->> 'block_id')::uuid;
  perform tests.assert_eq('the manager holds a sofa for 30 minutes: one is left', (v_json ->> 'free_after')::int, 1);
  perform tests.assert_eq('the states show it held', tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 3), '21:00/Sofa=0b0o1h0u1a');
  select * into k from public.site_table_blocks where id = v_block;
  perform tests.assert_eq('the hold has a tidied reason, a maker and an end 30 minutes away', k.reason || ':' || (k.created_by = mgr_a)::text || ':' || (k.expires_at between now() + interval '29 minutes' and now() + interval '31 minutes')::text, 'VIP arriving late:true:true');
  perform tests.assert_eq('it is logged', (select count(*)::int from public.audit_log where action = 'table.held' and entity_id = v_block::text and actor_id = mgr_a), 1);
  perform tests.assert_eq('holding the second sofa too fills the type', (tests.runj(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'held', 1, 'Second hold', 15)$q$, venue_a, t_sofa, s_eve)) ->> 'free_after')::int, 0);
  perform tests.assert_eq('a third is refused with the real number', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'held', 1, 'Too many', 15)::text$q$, venue_a, t_sofa, s_eve)), 'ERROR: only 0 of these tables are free for that time; tables that are already booked or held cannot be blocked');
  perform tests.login_anon();
  perform tests.assert_eq('the public picker now greys the sofa (all its tables are held)', (select count(*)::int from public.get_unavailable_table_types(venue_a, night, s_eve) u where u = t_sofa), 1);
  perform tests.assert_eq('...and the pair table is not greyed (one of three is free)', (select count(*)::int from public.get_unavailable_table_types(venue_a, night, s_eve) u where u = t_pair), 0);
  perform tests.logout();
  perform tests.assert_eq('the walk-in options show the sofa with none left', tests.try(mgr_a, 'mgra@fl.example', format($q$select (select available from public.desk_walkin_options(%L, current_date) where table_name = 'Sofa' and start_time = '21:00')::text$q$, venue_a)), '0');
  perform tests.assert_eq('...and a walk-in cannot be given a held sofa', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_create_walkin(%L, current_date, %L, %L, 2, 2, 'Held Out', 'held@fl.example', null, true)::text$q$, venue_a, t_sofa, s_eve)), 'ERROR: no tables of this type are left for that time');
  perform tests.assert_eq('...it booked nothing', (select count(*)::int from public.site_table_bookings where customer_email = 'held@fl.example'), 0);
  -- a hold runs out by itself
  update public.site_table_blocks set expires_at = now() - interval '1 minute' where id = v_block;
  perform tests.assert_eq('an expired hold frees the table again without anyone reopening it (the second hold is still in force)', tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 3), '21:00/Sofa=0b0o1h0u1a');
  perform tests.assert_eq('...releasing a hold that has run out changes nothing and says so', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_release(%L)::text$q$, v_block)), 'false');
  perform tests.assert_eq('...it was not marked released (it simply ended)', (select released_at is null from public.site_table_blocks where id = v_block), true);
  perform tests.assert_eq('the shared count agrees: only the second hold still takes a sofa', public.site_table_taken_count(t_sofa, s_eve, night), 1);

  -- "unavailable" until reopened, never over booked tables
  perform tests.assert_eq('a booth that is free can be made unavailable (repair, private use)', (tests.runj(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'Booth being repaired', null)$q$, venue_a, t_booth, s_eve)) ->> 'free_after')::int, 0);
  v_block2 := (select id from public.site_table_blocks where reason = 'Booth being repaired');
  perform tests.assert_eq('the states show it unavailable', tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 1), '21:00/Booth=0b0o0h1u0a');
  perform tests.assert_eq('a walk-in cannot be given it', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_create_walkin(%L, current_date, %L, %L, 2, null, 'Blocked Out', 'blocked@fl.example', null, true)::text$q$, venue_a, t_booth, s_eve)), 'ERROR: no tables of this type are left for that time');
  perform tests.assert_eq('the active blocks are listed with who and why', tests.blocks_text(mgr_a, 'mgra@fl.example', venue_a, night), 'Booth:unavailable:Booth being repaired:Staff member,Sofa:held:Second hold:Staff member');
  perform tests.assert_eq('reopening it works', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_release(%L)::text$q$, v_block2)), 'true');
  perform tests.assert_eq('...a second tap changes nothing', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_release(%L)::text$q$, v_block2)), 'false');
  perform tests.assert_eq('...and the booth is free again', tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 1), '21:00/Booth=0b0o0h0u1a');
  perform tests.assert_eq('the release names who reopened it', (select released_by from public.site_table_blocks where id = v_block2), mgr_a);
  perform tests.assert_eq('the shared count agrees: the reopened booth takes nothing, so a walk-in can be given it', public.site_table_taken_count(t_booth, s_eve, night), 0);
  perform tests.assert_eq('...and the walk-in options say one is available', tests.try(mgr_a, 'mgra@fl.example', format($q$select (select available from public.desk_walkin_options(%L, current_date) where table_name = 'Booth' and start_time = '21:00')::text$q$, venue_a)), '1');
  perform tests.assert_eq('...and is logged', (select count(*)::int from public.audit_log where action = 'table.reopened' and entity_id = v_block2::text), 1);
  perform tests.assert_eq('the reopened block is no longer listed', tests.blocks_text(mgr_a, 'mgra@fl.example', venue_a, night), 'Sofa:held:Second hold:Staff member');

  -- a booked table can never be blocked
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_booth, s_late, night + 1, 'Late Booker', 'late@fl.example', 2, 10000, 'paid');
  perform tests.assert_eq('a table somebody has booked cannot be blocked', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'Taking it away', null)::text$q$, venue_a, t_booth, s_late)), 'ERROR: only 0 of these tables are free for that time; tables that are already booked or held cannot be blocked');
  perform tests.assert_eq('...the after-midnight booking is stored under the next calendar day and shows under tonight''s 01:00', tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 4), '01:00/Booth=1b0o0h0u0a');
  perform tests.assert_eq('a block at the after-midnight time is accepted', (tests.runj(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 2, 'Private party', null)$q$, venue_a, t_pair, s_late)) ->> 'free_after')::int, 1);
  perform tests.assert_eq('...and stored under the next calendar day', (select booking_date from public.site_table_blocks where reason = 'Private party'), night + 1);
  perform tests.assert_eq('...and shown under tonight', tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 5), '01:00/Pair table=0b0o0h2u1a');

  -- refusals
  foreach who in array others loop
    perform tests.assert_eq('blocking is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'No right', null)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: not allowed');
    perform tests.assert_eq('...and so is reopening, for ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_table_release(%L)::text$q$, v_block2)), 'ERROR: not allowed');
    perform tests.assert_eq('...and listing the blocks, for ' || who, tests.try((select id from auth.users where email = who), who, format($q$select count(*)::text from public.desk_table_blocks(%L, current_date)$q$, venue_a)), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot block', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'No right', null)$q$, venue_a, t_pair, s_eve), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('an unknown block is "not allowed", never "not found" (no probing)', tests.try(mgr_a, 'mgra@fl.example', $q$select public.desk_table_release(gen_random_uuid())::text$q$), 'ERROR: not allowed');
  perform tests.assert_eq('a kind must be chosen', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'maybe', 1, 'Some reason', null)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: choose hold or unavailable');
  perform tests.assert_eq('a reason is needed', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'no', null)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: give a reason of 3 to 200 characters');
  perform tests.assert_eq('...and not a novel', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, %L, null)::text$q$, venue_a, t_pair, s_eve, repeat('x', 201))), 'ERROR: give a reason of 3 to 200 characters');
  perform tests.assert_eq('at least one table', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 0, 'Some reason', null)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: how many tables?');
  perform tests.assert_eq('a hold needs a time', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'held', 1, 'Some reason', null)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: a hold lasts between 5 minutes and 24 hours');
  perform tests.assert_eq('...at least five minutes', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'held', 1, 'Some reason', 4)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: a hold lasts between 5 minutes and 24 hours');
  perform tests.assert_eq('...and not more than a day', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'held', 1, 'Some reason', 1441)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: a hold lasts between 5 minutes and 24 hours');
  perform tests.assert_eq('"unavailable" has no time limit', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'Some reason', 30)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: a table that is unavailable stays so until it is reopened, so it has no time limit');
  perform tests.assert_eq('another club''s table is not found', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'Some reason', null)::text$q$, venue_a, t_b, s_eve)), 'ERROR: table not found');
  perform tests.assert_eq('another club''s arrival time is not found', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'Some reason', null)::text$q$, venue_a, t_pair, s_b)), 'ERROR: arrival time not found');
  perform tests.assert_eq('a time that is not offered that night', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'Some reason', null)::text$q$, venue_a, t_pair, s_other)), 'ERROR: that arrival time is not offered on that night');
  perform tests.assert_eq('a night too far ahead', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date + 70, %L, %L, 'unavailable', 1, 'Some reason', null)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: that night cannot be changed');
  insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, report) values (venue_a, night, 'closed', mgr_a, now(), '{}'::jsonb);
  perform tests.assert_eq('a closed night''s tables cannot be changed', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'Some reason', null)::text$q$, venue_a, t_pair, s_eve)), 'ERROR: this night has been closed, so its tables cannot be changed');
  update public.site_night_closes set status = 'reopened', reopened_by = owner_u, reopened_at = now() where venue_id = venue_a and business_night = night;

  ---------------------------------------------------------------- 6. moving a booking
  delete from public.site_table_blocks;
  delete from public.site_table_bookings where customer_email in ('walk@fl.example', 'bea@fl.example', 'late@fl.example', 'pat@fl.example', 'sam@fl.example');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, amount_paid_cents, status)
    values (venue_a, t_pair, s_eve, night, 'Move Mia', 'mia@fl.example', 3, 2500, 2500, 2500, 'paid') returning id into b1;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status)
    values (venue_a, t_pair, s_eve, night, 'Big Bo', 'bo@fl.example', 7, 2500, 2500, 'paid') returning id into b2;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status)
    values (venue_a, t_booth, s_eve, night, 'Solo Sue', 'sue@fl.example', 1, 10000, 10000, 'paid') returning id into b3;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status)
    values (venue_a, t_pair, s_eve, night, 'Pending Pia', 'pia@fl.example', 2, 2500, 2500, 'pending') returning id into b_pend;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status)
    values (venue_b, t_b, s_b, night, 'Other Club', 'oc@fl.example', 2, 1000, 1000, 'paid') returning id into b_b;
  update public.site_table_bookings set created_at = now() - interval '1 hour' where id = b_pend;
  -- the guest's server stays assigned through a move
  insert into public.site_booking_servers (booking_id, membership_id, assigned_by) select b1, m.id, mgr_a from public.site_memberships m where m.user_id = srv and m.role = 'server' and m.status = 'active';

  foreach who in array others loop
    perform tests.assert_eq('moving is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_move_booking(%L, %L, 'No right to move')::text$q$, b1, t_booth)), 'ERROR: not allowed');
    perform tests.assert_eq('...and so is the move history, for ' || who, tests.try((select id from auth.users where email = who), who, format($q$select count(*)::text from public.desk_booking_moves(%L)$q$, b1)), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot move a booking', format($q$select public.desk_move_booking(%L, %L, 'No right to move')$q$, b1, t_booth), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('another club''s booking is "not allowed" for this manager', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'Not mine to move')::text$q$, b_b, t_booth)), 'ERROR: not allowed');
  perform tests.assert_eq('an unknown booking too', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(gen_random_uuid(), %L, 'Not there at all')::text$q$, t_booth)), 'ERROR: not allowed');
  perform tests.assert_eq('a reason is needed', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, ' x ')::text$q$, b1, t_booth)), 'ERROR: give a reason of 3 to 200 characters');
  perform tests.assert_eq('only a confirmed booking can be moved', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'Unpaid one')::text$q$, b_pend, t_booth)), 'ERROR: only a confirmed booking can be moved');
  perform tests.assert_eq('it cannot be moved to where it already is', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'Same place')::text$q$, b1, t_pair)), 'ERROR: the booking is already at that table');
  perform tests.assert_eq('another club''s table is not found', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'Wrong club')::text$q$, b1, t_b)), 'ERROR: table not found');
  perform tests.assert_eq('a party of 7 does not fit a booth that seats 6', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'Too big for it')::text$q$, b2, t_booth)), 'ERROR: that table seats up to 6 guests and this booking has 7');
  perform tests.assert_eq('a party of 1 does not fit a table that needs 2 or more', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'Too small')::text$q$, b3, t_pair)), 'ERROR: that table needs at least 2 guests and this booking has 1');

  -- a block takes the last table, so there is none to move into
  perform tests.runj(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'Sofa out of use', null)$q$, venue_a, t_sofa, s_eve));
  perform tests.runj(mgr_a, 'mgra@fl.example', format($q$select public.desk_table_block(%L, current_date, %L, %L, 'unavailable', 1, 'Other sofa out of use', null)$q$, venue_a, t_sofa, s_eve));
  perform tests.assert_eq('blocked tables are not free to move into', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'Into the blocked sofas')::text$q$, b1, t_sofa)), 'ERROR: no tables of that type are free for that time');
  delete from public.site_table_blocks;
  perform tests.assert_eq('the booth is taken (Solo Sue), so Mia cannot go in either', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'Booth is full')::text$q$, b1, t_booth)), 'ERROR: no tables of that type are free for that time');
  update public.site_table_bookings set status = 'cancelled' where id = b3;

  v_json := tests.runj(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, ' Guest wanted the booth ')$q$, b1, t_booth));
  perform tests.assert_eq('the manager moves the booking to the booth: from, to and the price difference are told', (v_json ->> 'from') || '>' || (v_json ->> 'to') || ':' || (v_json ->> 'price_difference_cents'), 'Pair table>Booth:7500');
  select * into j from public.site_table_bookings where id = b1;
  perform tests.assert_eq('the SAME booking is now at the booth', j.table_type_id, t_booth);
  perform tests.assert_eq('what the guest agreed to pay is untouched (the difference is only recorded)', j.amount_total_cents || ':' || j.deposit_cents || ':' || j.amount_paid_cents, '2500:2500:2500');
  perform tests.assert_eq('the status and the guest are untouched', j.status || ':' || j.customer_email, 'paid:mia@fl.example');
  perform tests.assert_eq('the guest''s server is still assigned', (select count(*)::int from public.site_booking_servers where booking_id = b1), 1);
  select * into k from public.site_booking_moves where booking_id = b1;
  perform tests.assert_eq('the record says who, from, to and why', k.moved_by::text || ':' || k.from_name || ':' || k.to_name || ':' || k.reason || ':' || k.price_difference_cents, mgr_a::text || ':Pair table:Booth:Guest wanted the booth:7500');
  perform tests.assert_eq('it is logged on the booking, so the Activity list can show it', (select count(*)::int from public.audit_log where action = 'booking.moved' and entity_id = b1::text and actor_id = mgr_a), 1);
  perform tests.assert_eq('...with the reason', (select details ->> 'reason' from public.audit_log where action = 'booking.moved' and entity_id = b1::text), 'Guest wanted the booth');
  perform tests.assert_eq('...and the existing Activity function lists it', tests.activity_actions(mgr_a, 'mgra@fl.example', b1) like '%booking.moved%', true);
  perform tests.assert_eq('the move history lists it with the manager''s name', tests.moves_text(mgr_a, 'mgra@fl.example', b1), 'Pair table>Booth:Guest wanted the booth:Staff member:7500');
  perform tests.assert_eq('the booth is now taken for that time, and the pair table has a free table again', tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 1) || ' | ' || tests.part(tests.states_text(mgr_a, 'mgra@fl.example', venue_a, night), 2), '21:00/Booth=1b0o0h0u0a | 21:00/Pair table=1b0o0h0u2a');
  perform tests.assert_eq('the last table cannot be taken twice: another booking cannot be moved into the full booth', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'Booth is full now')::text$q$, b2, t_booth)), 'ERROR: that table seats up to 6 guests and this booking has 7');
  perform tests.assert_eq('moving back works, and the difference is negative', tests.try(mgr_a, 'mgra@fl.example', format($q$select (public.desk_move_booking(%L, %L, 'Back again please')::jsonb ->> 'price_difference_cents')$q$, b1, t_pair)), '-7500');
  perform tests.assert_eq('two moves are two records, newest first', tests.moves_text(mgr_a, 'mgra@fl.example', b1), 'Booth>Pair table:Back again please:Staff member:-7500 | Pair table>Booth:Guest wanted the booth:Staff member:7500');
  perform tests.assert_eq('an hourly table has no price difference to record', tests.try(mgr_a, 'mgra@fl.example', format($q$select coalesce((public.desk_move_booking(%L, %L, 'To the sofa please')::jsonb ->> 'price_difference_cents'), 'none')$q$, b1, t_sofa)), 'none');
  perform tests.assert_eq('...and the booking really is on the sofa', (select table_type_id from public.site_table_bookings where id = b1), t_sofa);

  update public.site_night_closes set status = 'closed', reopened_by = null, reopened_at = null where venue_id = venue_a and business_night = night;
  perform tests.assert_eq('a closed night''s bookings cannot be moved', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.desk_move_booking(%L, %L, 'After closing')::text$q$, b1, t_pair)), 'ERROR: this night has been closed, so the booking cannot be moved');
  update public.site_night_closes set status = 'reopened', reopened_by = owner_u, reopened_at = now() where venue_id = venue_a and business_night = night;
  perform tests.assert_eq('...and can be again once reopened (by the owner)', tests.try(owner_u, 'owner@fl.example', format($q$select public.desk_move_booking(%L, %L, 'After reopening')::text$q$, b1, t_pair)) like 'ERROR%', false);

  ---------------------------------------------------------------- 7. deposit terms
  update public.site_venues set deposit_is_credit = false where id in (venue_a, venue_b);
  perform tests.assert_eq('a venue that never chose has no terms yet, and a credit switch', tests.try(mgr_a, 'mgra@fl.example', format($q$select (select terms is null from public.venue_deposit_terms(%L))::text || ':' || (select deposit_is_credit from public.venue_deposit_terms(%L))::text$q$, venue_a, venue_a)), 'true:false');
  foreach who in array others loop
    perform tests.assert_eq('the terms are refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select count(*)::text from public.venue_deposit_terms(%L)$q$, venue_a)), 'ERROR: not allowed');
    perform tests.assert_eq('...and so is changing them, for ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"reservation_fee"}'::jsonb)::text$q$, venue_a)), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"reservation_fee"}'::jsonb)$q$, venue_a), 'permission denied');
  perform tests.logout();

  -- a booking made before the venue chose anything carries the default and says so
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_pair, s_eve, night + 1, 'Default Dan', 'dan@fl.example', 2, 2500, 'paid') returning id into b4;
  perform tests.assert_eq('a venue that never chose: the booking says the venue keeps it, as a reservation fee, by default', (select deposit_terms::text from public.site_table_bookings where id = b4), '{"default": true, "purpose": "reservation_fee", "recipient": "venue", "venue_pct": 100}');
  perform tests.assert_eq('...and the table''s included admissions (4, set earlier) are copied', (select included_admissions from public.site_table_bookings where id = b4), 4);
  perform tests.assert_eq('...while "not stated" stays not stated (the booth)', (select included_admissions is null from public.site_table_bookings where id = b3), true);

  perform tests.assert_eq('the venue keeps the deposit as a reservation fee', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"reservation_fee"}'::jsonb)::text$q$, venue_a)), '{"purpose": "reservation_fee", "recipient": "venue", "venue_pct": 100}');
  perform tests.assert_eq('...it is stored', (select deposit_terms::text from public.site_venues where id = venue_a), '{"purpose": "reservation_fee", "recipient": "venue", "venue_pct": 100}');
  perform tests.assert_eq('...and logged with before and after', (select count(*)::int from public.audit_log where action = 'venue.deposit_terms_saved' and entity_id = venue_a::text and actor_id = mgr_a), 1);
  perform tests.assert_eq('saving the same again changes nothing', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","venue_pct":100,"purpose":"reservation_fee"}'::jsonb)::text$q$, venue_a)), '{"purpose": "reservation_fee", "recipient": "venue", "venue_pct": 100}');
  perform tests.assert_eq('...and logs nothing', (select count(*)::int from public.audit_log where action = 'venue.deposit_terms_saved' and entity_id = venue_a::text), 1);
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_pair, s_eve, night + 2, 'Venue Vic', 'vic@fl.example', 2, 2500, 'paid') returning id into b4;
  perform tests.assert_eq('a booking made now carries the venue''s chosen terms (no "default" mark)', (select deposit_terms::text from public.site_table_bookings where id = b4), '{"purpose": "reservation_fee", "recipient": "venue", "venue_pct": 100}');

  perform tests.assert_eq('a split gives the venue 70 and the organizer 30', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"split","venue_pct":70,"purpose":"admission"}'::jsonb)::text$q$, venue_a)), '{"purpose": "admission", "recipient": "split", "venue_pct": 70}');
  perform tests.assert_eq('changing the terms did NOT rewrite the booking made under the old ones', (select deposit_terms::text from public.site_table_bookings where id = b4), '{"purpose": "reservation_fee", "recipient": "venue", "venue_pct": 100}');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_pair, s_eve, night + 3, 'Split Sol', 'sol@fl.example', 2, 2500, 'paid') returning id into b4;
  perform tests.assert_eq('...but the next booking carries the new terms', (select deposit_terms::text from public.site_table_bookings where id = b4), '{"purpose": "admission", "recipient": "split", "venue_pct": 70}');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, deposit_terms, included_admissions)
    values (venue_a, t_pair, s_eve, night + 4, 'Given Gia', 'gia@fl.example', 2, 2500, 'paid', '{"recipient":"organizer","venue_pct":0,"purpose":"admission"}'::jsonb, 1) returning id into b4;
  perform tests.assert_eq('terms given with the booking are kept as given', (select deposit_terms::text || ':' || included_admissions from public.site_table_bookings where id = b4), '{"purpose": "admission", "recipient": "organizer", "venue_pct": 0}:1');
  perform tests.login_service();
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_pair, s_eve, night + 5, 'Edge Eve', 'eve@fl.example', 2, 2500, 'pending') returning id into b4;
  perform tests.logout();
  perform tests.assert_eq('a booking made by the website''s server (the service role) carries the terms too', (select deposit_terms ->> 'recipient' from public.site_table_bookings where id = b4), 'split');
  perform tests.assert_eq('a walk-in booked at the desk carries them as well', (select deposit_terms ->> 'purpose' from public.site_table_bookings where customer_email = 'dan@fl.example'), 'reservation_fee');

  perform tests.assert_eq('the organizer receiving everything means the venue''s share is 0', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"organizer","purpose":"admission"}'::jsonb)::text$q$, venue_a)), '{"purpose": "admission", "recipient": "organizer", "venue_pct": 0}');
  perform tests.assert_eq('a recipient must be chosen', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"purpose":"reservation_fee"}'::jsonb)::text$q$, venue_a)), 'ERROR: choose who receives the deposit: the venue, the approved organizer, or a split');
  perform tests.assert_eq('...a real one', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"everyone","purpose":"reservation_fee"}'::jsonb)::text$q$, venue_a)), 'ERROR: choose who receives the deposit: the venue, the approved organizer, or a split');
  perform tests.assert_eq('a purpose must be chosen', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue"}'::jsonb)::text$q$, venue_a)), 'ERROR: choose what the deposit is for: a reservation fee, a credit toward the minimum spend, or admission');
  perform tests.assert_eq('...a real one', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"tip"}'::jsonb)::text$q$, venue_a)), 'ERROR: choose what the deposit is for: a reservation fee, a credit toward the minimum spend, or admission');
  perform tests.assert_eq('a split needs the venue''s share', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"split","purpose":"admission"}'::jsonb)::text$q$, venue_a)), 'ERROR: for a split give the venue''s share between 1 and 99 percent (the organizer gets the rest, so the two add up to 100)');
  perform tests.assert_eq('...not 0', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"split","venue_pct":0,"purpose":"admission"}'::jsonb)::text$q$, venue_a)), 'ERROR: for a split give the venue''s share between 1 and 99 percent (the organizer gets the rest, so the two add up to 100)');
  perform tests.assert_eq('...not 100', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"split","venue_pct":100,"purpose":"admission"}'::jsonb)::text$q$, venue_a)), 'ERROR: for a split give the venue''s share between 1 and 99 percent (the organizer gets the rest, so the two add up to 100)');
  perform tests.assert_eq('...not 101 either', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"split","venue_pct":101,"purpose":"admission"}'::jsonb)::text$q$, venue_a)), 'ERROR: the venue''s share must be between 0 and 100');
  perform tests.assert_eq('the venue keeping it cannot also have a share other than 100', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","venue_pct":50,"purpose":"admission"}'::jsonb)::text$q$, venue_a)), 'ERROR: when the venue keeps the deposit its share is 100 percent');
  perform tests.assert_eq('the organizer receiving it cannot leave the venue a share', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"organizer","venue_pct":10,"purpose":"admission"}'::jsonb)::text$q$, venue_a)), 'ERROR: when the organizer receives the deposit the venue''s share is 0 percent');
  perform tests.assert_eq('an unknown field is refused', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"admission","tip":1}'::jsonb)::text$q$, venue_a)), 'ERROR: unknown field: tip');
  perform tests.assert_eq('the deposit cannot be a minimum spend credit while the venue''s credit switch is off', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"minimum_spend_credit"}'::jsonb)::text$q$, venue_a)), 'ERROR: the deposit is not credited toward the bottle bill at this venue, so it cannot be a minimum spend credit; choose reservation fee or admission, or ask the BottlesUp team to switch the credit on');
  update public.site_venues set deposit_is_credit = true where id = venue_a;
  perform tests.assert_eq('...and with the switch on it can', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"minimum_spend_credit"}'::jsonb)::text$q$, venue_a)), '{"purpose": "minimum_spend_credit", "recipient": "venue", "venue_pct": 100}');
  perform tests.assert_eq('...but then a reservation fee is refused, because the bottle bill credits the deposit', tests.try(mgr_a, 'mgra@fl.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"reservation_fee"}'::jsonb)::text$q$, venue_a)), 'ERROR: the deposit is credited toward the bottle bill at this venue, so its purpose is a minimum spend credit; ask the BottlesUp team if that should change');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_b, t_b, s_b, night + 9, 'Credit Cat', 'cat@fl.example', 2, 1000, 'paid') returning id into b4;
  perform tests.assert_eq('a venue with the credit switch off and no terms: its bookings say reservation fee', (select deposit_terms ->> 'purpose' from public.site_table_bookings where id = b4), 'reservation_fee');
  update public.site_venues set deposit_is_credit = true where id = venue_b;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_b, t_b, s_b, night + 10, 'Credit Cam', 'cam@fl.example', 2, 1000, 'paid') returning id into b4;
  perform tests.assert_eq('...and with it on: minimum spend credit', (select deposit_terms ->> 'purpose' from public.site_table_bookings where id = b4), 'minimum_spend_credit');

  ---------------------------------------------------------------- 8. declarations and the closed tables
  perform tests.assert_true('every new and replaced function runs with its owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('list_venue_table_layout', 'place_venue_table', 'unplace_venue_table', 'set_table_included_admissions', 'desk_table_states', 'desk_table_block',
        'desk_table_release', 'desk_table_blocks', 'desk_move_booking', 'desk_booking_moves', 'venue_deposit_terms', 'save_venue_deposit_terms', 'site_table_taken_count',
        'site_table_bookings_snapshot_terms', 'get_unavailable_table_types', 'desk_walkin_options', 'desk_create_walkin')));
  perform tests.assert_true('the blocks and moves tables have row level security on', (select bool_and(relrowsecurity) from pg_class where oid in ('public.site_table_blocks'::regclass, 'public.site_booking_moves'::regclass)));
  perform tests.login(mgr_a, 'mgra@fl.example');
  perform tests.assert_raises('the app cannot read the blocks table directly', $q$select * from public.site_table_blocks$q$, 'permission denied');
  perform tests.assert_raises('...nor write to it', format($q$insert into public.site_table_blocks (venue_id, table_type_id, time_slot_id, booking_date, kind, reason, created_by, expires_at) values (%L, %L, %L, current_date, 'held', 'forged', %L, now())$q$, venue_a, t_pair, s_eve, mgr_a), 'permission denied');
  perform tests.assert_raises('...nor read the moves', $q$select * from public.site_booking_moves$q$, 'permission denied');
  perform tests.assert_raises('...nor forge a move', format($q$insert into public.site_booking_moves (booking_id, venue_id, from_name, to_name, reason, moved_by) values (%L, %L, 'a', 'b', 'forged', %L)$q$, b1, venue_a, mgr_a), 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read them either', $q$select * from public.site_table_blocks$q$, 'permission denied');
  perform tests.logout();
end $$;

rollback;
