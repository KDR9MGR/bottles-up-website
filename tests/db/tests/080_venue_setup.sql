-- Owner venue setup: arrival times, floors, table types and the bottle menu, written by owners and managers through their own
-- functions. What matters most: only people with a role at THIS venue can write, a row id from another venue is never
-- reachable, nothing outside the whitelist can be set, and things bookings depend on cannot be deleted from under them.
begin;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000000d2';  -- manager of Club A only
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000d3';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000d4';  -- door staff at Club A
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000000d5';  -- manager of Club B only
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_r uuid;
  tok text; r record; n int; txt text;
  slot_a uuid; slot_b uuid; slot_x uuid; floor_a uuid; floor_b uuid; floor_x uuid;
  type_a uuid; type_b uuid; type_x uuid; type_booked uuid; bottle_a uuid; bottle_b uuid; bottle_x uuid;
  booking uuid; long_label text := repeat('x', 61);
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@club.example'), (mgr_a, 'mgra@club.example'), (rival_u, 'rival@club2.example'),
    (door_a, 'doora@club.example'), (mgr_b, 'mgrb@club.example');

  ---------------------------------------------------------------- set up: a business with two clubs, a rival, staff
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
  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'doora@club.example', 'door', venue_a) i;
  perform tests.login(door_a, 'doora@club.example'); perform public.accept_invitation(tok);

  ---------------------------------------------------------------- the setup checklist starts empty
  perform tests.login(owner_u, 'owner@club.example');
  select string_agg(step, ',' order by step) into txt from public.venue_setup_status(venue_a) where status = 'todo' and required;
  perform tests.assert_eq('a new venue has every setup step still to do', txt, 'booking_rules,bottles,floor_plan,profile,tables');
  perform tests.assert_eq('nothing is listed yet: arrival times', (select count(*) from public.list_venue_time_slots(venue_a))::int, 0);
  perform tests.assert_eq('floors', (select count(*) from public.list_venue_floors(venue_a))::int, 0);
  perform tests.assert_eq('table types', (select count(*) from public.list_venue_table_types(venue_a))::int, 0);
  perform tests.assert_eq('bottles', (select count(*) from public.list_venue_bottles(venue_a))::int, 0);

  ---------------------------------------------------------------- who may write: nobody without a role at THIS venue
  perform tests.login(rival_u, 'rival@club2.example');
  perform tests.assert_raises('a rival owner cannot list another business''s arrival times', format($q$select * from public.list_venue_time_slots(%L)$q$, venue_a), 'not allowed');
  perform tests.assert_raises('...nor add one', format($q$select public.add_venue_time_slot(%L, 5, '21:00')$q$, venue_a), 'not allowed');
  perform tests.assert_raises('...nor list floors', format($q$select * from public.list_venue_floors(%L)$q$, venue_a), 'not allowed');
  perform tests.assert_raises('...nor add a floor', format($q$select public.save_venue_floor(%L, null, 'Main', 'https://x.example/a.png')$q$, venue_a), 'not allowed');
  perform tests.assert_raises('...nor list table types', format($q$select * from public.list_venue_table_types(%L)$q$, venue_a), 'not allowed');
  perform tests.assert_raises('...nor add one', format($q$select public.save_venue_table_type(%L, null, '{"name":"VIP","max_guests":6,"inventory_count":2}')$q$, venue_a), 'not allowed');
  perform tests.assert_raises('...nor list bottles', format($q$select * from public.list_venue_bottles(%L)$q$, venue_a), 'not allowed');
  perform tests.assert_raises('...nor add one', format($q$select public.save_venue_bottle(%L, null, '{"name":"Vodka","price_cents":9000}')$q$, venue_a), 'not allowed');
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff of the club cannot set it up', format($q$select public.add_venue_time_slot(%L, 5, '21:00')$q$, venue_a), 'not allowed');
  perform tests.assert_raises('...nor change the menu', format($q$select public.save_venue_bottle(%L, null, '{"name":"Vodka","price_cents":9000}')$q$, venue_a), 'not allowed');
  perform tests.login(rando);
  perform tests.assert_raises('a signed-in person with no role cannot', format($q$select public.add_venue_time_slot(%L, 5, '21:00')$q$, venue_a), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('a manager of Club B cannot touch Club A', format($q$select public.add_venue_time_slot(%L, 5, '21:00')$q$, venue_a), 'not allowed');
  perform tests.assert_raises('...nor read its table types', format($q$select * from public.list_venue_table_types(%L)$q$, venue_a), 'not allowed');
  perform tests.assert_raises('a venue that does not exist is refused', format($q$select public.add_venue_time_slot(%L, 5, '21:00')$q$, gen_random_uuid()), 'not allowed');
  perform tests.assert_raises('and so is no venue at all', $q$select public.add_venue_time_slot(null, 5, '21:00')$q$, 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot write', format($q$select public.add_venue_time_slot(%L, 5, '21:00')$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...nor read', format($q$select * from public.list_venue_bottles(%L)$q$, venue_a), 'permission denied');

  -- A signed-in role whose token carries no user at all.
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform tests.assert_raises('a token with no user is told to sign in', format($q$select public.add_venue_time_slot(%L, 5, '21:00')$q$, venue_a), 'not authenticated');
  perform tests.assert_raises('...also when reading', format($q$select * from public.list_venue_floors(%L)$q$, venue_a), 'not authenticated');
  perform tests.logout();

  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('the internal audit writer cannot be called by a signed-in person (it would forge attribution)',
    format($q$select public.venue_setup_log('venue_setup.forged', 'site_bottles', null, %L)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('nor the permission helper', format($q$select public.require_venue_editor(%L)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('nor the field parsers', $q$select public.setup_int('{"a":1}', 'a', 'a', 0, 5)$q$, 'permission denied');

  ---------------------------------------------------------------- hygiene: every one of these functions pins its search path
  perform tests.logout();
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname in (
      'require_venue_editor', 'venue_setup_log', 'setup_only_keys', 'setup_int', 'setup_text', 'setup_url', 'setup_bool',
      'list_venue_time_slots', 'add_venue_time_slot', 'remove_venue_time_slot', 'list_venue_floors', 'save_venue_floor', 'remove_venue_floor',
      'list_venue_table_types', 'save_venue_table_type', 'remove_venue_table_type', 'list_venue_bottles', 'save_venue_bottle', 'remove_venue_bottle');
  perform tests.assert_eq('all 19 functions exist', n, 19);
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname in (
      'require_venue_editor', 'venue_setup_log', 'setup_only_keys', 'setup_int', 'setup_text', 'setup_url', 'setup_bool',
      'list_venue_time_slots', 'add_venue_time_slot', 'remove_venue_time_slot', 'list_venue_floors', 'save_venue_floor', 'remove_venue_floor',
      'list_venue_table_types', 'save_venue_table_type', 'remove_venue_table_type', 'list_venue_bottles', 'save_venue_bottle', 'remove_venue_bottle')
      and not (coalesce(p.proconfig::text, '') like '%search_path=public%');
  perform tests.assert_eq('...each with search_path fixed to public (a definer function without it can be hijacked)', n, 0);
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname like any (array['%venue_time_slot%', '%venue_floor%', '%venue_table_type%', '%venue_bottle%', 'require_venue_editor', 'venue_setup_log'])
      and not p.prosecdef;
  perform tests.assert_eq('...and every function that touches the venue tables runs with its owner''s rights, checked by the permission function', n, 0);

  ---------------------------------------------------------------- the tables themselves stay closed to direct writes
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('an owner cannot write a table type straight to the table', format(
    $q$insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (%L, 'Sneaky', 4, 0, 0, 1)$q$, venue_a), 'row-level security');
  perform tests.assert_raises('nor a bottle', format($q$insert into public.site_bottles (venue_id, name, price_cents) values (%L, 'Sneaky', 1)$q$, venue_a), 'row-level security');

  ---------------------------------------------------------------- arrival times
  perform tests.login(owner_u, 'owner@club.example');
  slot_a := public.add_venue_time_slot(venue_a, 5, '22:00', 'Late');
  perform public.add_venue_time_slot(venue_a, 5, '20:30');
  perform public.add_venue_time_slot(venue_a, 0, '21:00', '   ');
  select string_agg(day_of_week || '@' || substr(start_time::text, 1, 5), ',' order by day_of_week, start_time) into txt from public.list_venue_time_slots(venue_a);
  perform tests.assert_eq('arrival times list in day then time order', txt, '0@21:00,5@20:30,5@22:00');
  select label into txt from public.list_venue_time_slots(venue_a) where day_of_week = 0;
  perform tests.assert_true('a blank label is stored as none', txt is null);
  select label into txt from public.list_venue_time_slots(venue_a) where day_of_week = 5 and start_time = '22:00';
  perform tests.assert_eq('a label is kept', txt, 'Late');
  perform tests.assert_raises('the same day and time cannot be added twice', format($q$select public.add_venue_time_slot(%L, 5, '22:00')$q$, venue_a), 'already added');
  perform tests.assert_raises('...also with a different label', format($q$select public.add_venue_time_slot(%L, 5, '22:00', 'Another name')$q$, venue_a), 'already added');
  perform tests.assert_raises('day 7 is not a day', format($q$select public.add_venue_time_slot(%L, 7, '22:00')$q$, venue_a), 'between 0');
  perform tests.assert_raises('nor day -1', format($q$select public.add_venue_time_slot(%L, -1, '22:00')$q$, venue_a), 'between 0');
  perform tests.assert_raises('nor no day', format($q$select public.add_venue_time_slot(%L, null, '22:00')$q$, venue_a), 'between 0');
  perform tests.assert_raises('a time is required', format($q$select public.add_venue_time_slot(%L, 3, null)$q$, venue_a), 'arrival time is required');
  perform tests.assert_raises('a very long label is refused', format($q$select public.add_venue_time_slot(%L, 3, '21:00', %L)$q$, venue_a, long_label), '60 characters');
  perform tests.assert_eq('the refused attempts added nothing', (select count(*) from public.list_venue_time_slots(venue_a))::int, 3);

  perform tests.login(mgr_a, 'mgra@club.example');
  slot_x := public.add_venue_time_slot(venue_a, 6, '23:00');
  perform tests.assert_true('a manager of the club can add one', slot_x is not null);
  perform tests.assert_eq('...and list them', (select count(*) from public.list_venue_time_slots(venue_a))::int, 4);

  perform tests.login(mgr_b, 'mgrb@club.example');
  slot_b := public.add_venue_time_slot(venue_b, 1, '19:00');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the owner sees only the one club''s times when asking for it', (select count(*) from public.list_venue_time_slots(venue_b))::int, 1);
  perform tests.assert_raises('removing Club B''s time by asking through Club A finds nothing', format($q$select public.remove_venue_time_slot(%L, %L)$q$, venue_a, slot_b), 'not found');
  perform tests.assert_eq('...and Club B''s time is still there', (select count(*) from public.list_venue_time_slots(venue_b))::int, 1);
  perform tests.assert_raises('removing a time that does not exist finds nothing', format($q$select public.remove_venue_time_slot(%L, %L)$q$, venue_a, gen_random_uuid()), 'not found');

  -- A time that has a booking cannot be removed.
  perform tests.logout();
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booked type', 4, 0, 0, 1) returning id into type_booked;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents)
    values (venue_a, type_booked, slot_a, current_date + 3, 'Ada', 'ada@test.example', 2, 1000) returning id into booking;
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('an arrival time with a booking cannot be removed', format($q$select public.remove_venue_time_slot(%L, %L)$q$, venue_a, slot_a), 'has bookings');
  perform tests.assert_eq('...it is still listed, with its booking counted', (select booking_count from public.list_venue_time_slots(venue_a) where slot_id = slot_a)::int, 1);
  perform public.remove_venue_time_slot(venue_a, slot_x);
  perform tests.assert_eq('an unused one can be removed', (select count(*) from public.list_venue_time_slots(venue_a))::int, 3);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.remove_venue_time_slot(venue_a, (select s.slot_id from public.list_venue_time_slots(venue_a) s where s.day_of_week = 0));
  perform tests.assert_eq('a manager can remove one too', (select count(*) from public.list_venue_time_slots(venue_a))::int, 2);

  perform tests.logout();
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time)
    select venue_a, i % 7, time '01:00' + (i / 7) * interval '1 minute' from generate_series(0, 147) i;
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the venue is now at its 150 arrival times', (select count(*) from public.list_venue_time_slots(venue_a))::int, 150);
  perform tests.assert_raises('a 151st is refused', format($q$select public.add_venue_time_slot(%L, 4, '03:07')$q$, venue_a), '150 arrival times at most');

  ---------------------------------------------------------------- floors
  floor_a := public.save_venue_floor(venue_a, null, '  Main room ', 'https://img.example/main.png');
  perform tests.assert_eq('a floor is added with a trimmed name', (select label from public.list_venue_floors(venue_a) where floor_id = floor_a), 'Main room');
  perform tests.assert_eq('...and the first one is first', (select sort_order from public.list_venue_floors(venue_a) where floor_id = floor_a), 0);
  perform public.save_venue_floor(venue_a, null, 'Terrace', 'https://img.example/terrace.png');
  perform tests.assert_eq('the next one goes after it', (select sort_order from public.list_venue_floors(venue_a) where label = 'Terrace'), 1);
  perform tests.assert_raises('a floor needs a name', format($q$select public.save_venue_floor(%L, null, '  ', 'https://img.example/x.png')$q$, venue_a), 'floor name is required');
  perform tests.assert_raises('...and an image', format($q$select public.save_venue_floor(%L, null, 'Roof', null)$q$, venue_a), 'image is required');
  perform tests.assert_raises('an image must be https', format($q$select public.save_venue_floor(%L, null, 'Roof', 'http://img.example/x.png')$q$, venue_a), 'https link');
  perform tests.assert_raises('a script address is not an image', format($q$select public.save_venue_floor(%L, null, 'Roof', 'javascript:alert(1)')$q$, venue_a), 'https link');
  perform tests.assert_raises('an image address with a space is refused', format($q$select public.save_venue_floor(%L, null, 'Roof', 'https://img.example/a b.png')$q$, venue_a), 'https link');
  perform tests.assert_raises('a very long floor name is refused', format($q$select public.save_venue_floor(%L, null, %L, 'https://img.example/x.png')$q$, venue_a, long_label), '60 characters');
  perform tests.assert_raises('an out-of-range order is refused', format($q$select public.save_venue_floor(%L, null, 'Roof', 'https://img.example/x.png', 10001)$q$, venue_a), 'between 0 and 10000');
  perform public.save_venue_floor(venue_a, floor_a, 'Main hall', 'https://img.example/main2.png', 5);
  select label, image_url, sort_order into r from public.list_venue_floors(venue_a) where floor_id = floor_a;
  perform tests.assert_eq('a floor can be renamed and its image replaced', r.label || '|' || r.image_url || '|' || r.sort_order, 'Main hall|https://img.example/main2.png|5');
  perform public.save_venue_floor(venue_a, floor_a, 'Main hall', 'https://img.example/main2.png');
  perform tests.assert_eq('saving without an order keeps the order', (select sort_order from public.list_venue_floors(venue_a) where floor_id = floor_a), 5);

  perform tests.login(mgr_b, 'mgrb@club.example');
  floor_b := public.save_venue_floor(venue_b, null, 'B floor', 'https://img.example/b.png');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('Club B''s floor cannot be edited by naming it under Club A', format($q$select public.save_venue_floor(%L, %L, 'Hijacked', 'https://img.example/h.png')$q$, venue_a, floor_b), 'floor not found');
  perform tests.assert_eq('...it is unchanged', (select label from public.list_venue_floors(venue_b) where floor_id = floor_b), 'B floor');
  perform tests.assert_raises('nor removed that way', format($q$select public.remove_venue_floor(%L, %L)$q$, venue_a, floor_b), 'floor not found');
  perform tests.assert_eq('...it is still there', (select count(*) from public.list_venue_floors(venue_b))::int, 1);

  -- Tables on a floor become unplaced when the floor goes. The CMS places them; we set that up directly.
  perform tests.logout();
  update public.site_table_types set floor_id = floor_a, pos_x = 10, pos_y = 20, width = 5, height = 5 where id = type_booked;
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('a floor counts the table types placed on it', (select table_count from public.list_venue_floors(venue_a) where floor_id = floor_a)::int, 1);
  perform public.remove_venue_floor(venue_a, floor_a);
  perform tests.logout();
  select coalesce(floor_id::text, 'null') || '|' || coalesce(pos_x::text, 'null') || '|' || coalesce(width::text, 'null') into txt from public.site_table_types where id = type_booked;
  perform tests.assert_eq('removing a floor unplaces its tables instead of leaving a position on nothing', txt, 'null|null|null');
  perform tests.assert_true('...but keeps the table type itself', exists (select 1 from public.site_table_types where id = type_booked));
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('removing a floor twice says so', format($q$select public.remove_venue_floor(%L, %L)$q$, venue_a, floor_a), 'floor not found');

  perform tests.logout();
  insert into public.site_venue_floors (venue_id, label, image_url) select venue_a, 'F' || g, 'https://img.example/f.png' from generate_series(1, 8) g;
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the venue now has 9 floors', (select count(*) from public.list_venue_floors(venue_a))::int, 9);
  perform public.save_venue_floor(venue_a, null, 'Tenth', 'https://img.example/t.png');
  perform tests.assert_raises('an 11th floor is refused', format($q$select public.save_venue_floor(%L, null, 'Eleventh', 'https://img.example/e.png')$q$, venue_a), '10 floors at most');

  ---------------------------------------------------------------- table types
  type_a := public.save_venue_table_type(venue_a, null, '{"name":"  VIP Booth ","max_guests":6,"inventory_count":3}');
  select * into r from public.list_venue_table_types(venue_a) where type_id = type_a;
  perform tests.assert_eq('a minimal table type gets the CMS defaults', r.name || '|' || r.max_guests || '|' || r.inventory_count || '|' || r.min_spend_cents || '|' || r.deposit_cents || '|' || r.pricing_mode || '|' || r.is_featured,
    'VIP Booth|6|3|0|0|flat|false');
  perform tests.assert_true('...no minimum guests, image, badge or hourly rate', r.min_guests is null and r.image_url is null and r.badge_label is null and r.hourly_rate_cents is null and r.min_hours is null);
  perform tests.assert_true('...and it is not placed on any floor', r.floor_id is null);
  perform tests.assert_eq('the list now holds the earlier booked type and the new one', (select count(*) from public.list_venue_table_types(venue_a))::int, 2);

  type_b := public.save_venue_table_type(venue_a, null, '{
    "name":"Dance floor table","description":"Next to the DJ","max_guests":8,"min_guests":4,"min_spend_cents":150000,"deposit_cents":50000,
    "inventory_count":5,"image_url":"https://img.example/t.png","badge_label":"Popular","is_featured":true,"pricing_mode":"hourly",
    "hourly_rate_cents":20000,"min_hours":2}');
  select * into r from public.list_venue_table_types(venue_a) where type_id = type_b;
  perform tests.assert_eq('every field the CMS writes can be set (money)', r.min_spend_cents || '|' || r.deposit_cents || '|' || r.hourly_rate_cents || '|' || r.min_hours, '150000|50000|20000|2');
  perform tests.assert_eq('...and the rest', r.description || '|' || r.min_guests || '|' || r.image_url || '|' || r.badge_label || '|' || r.is_featured || '|' || r.pricing_mode, 'Next to the DJ|4|https://img.example/t.png|Popular|true|hourly');
  perform tests.assert_true('new table types go to the end of the list', (select sort_order from public.list_venue_table_types(venue_a) where type_id = type_b) > (select sort_order from public.list_venue_table_types(venue_a) where type_id = type_a));
  perform tests.assert_eq('the booking-protected type from earlier is listed with its booking count', (select booking_count from public.list_venue_table_types(venue_a) where type_id = type_booked)::int, 1);

  perform tests.assert_raises('a name is required', format($q$select public.save_venue_table_type(%L, null, '{"max_guests":4,"inventory_count":1}')$q$, venue_a), 'table name is required');
  perform tests.assert_raises('...not just spaces', format($q$select public.save_venue_table_type(%L, null, '{"name":"   ","max_guests":4,"inventory_count":1}')$q$, venue_a), 'table name is required');
  perform tests.assert_raises('maximum guests is required', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","inventory_count":1}')$q$, venue_a), 'maximum guests is required');
  perform tests.assert_raises('...and at least 1', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":0,"inventory_count":1}')$q$, venue_a), 'between 1 and 100');
  perform tests.assert_raises('...and at most 100', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":101,"inventory_count":1}')$q$, venue_a), 'between 1 and 100');
  perform tests.assert_raises('the number of tables is required', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4}')$q$, venue_a), 'number of tables is required');
  perform tests.assert_raises('...and cannot be negative', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":-1}')$q$, venue_a), 'between 0 and 500');
  perform tests.assert_raises('a negative deposit is refused', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"deposit_cents":-5}')$q$, venue_a), 'between 0');
  perform tests.assert_raises('a negative minimum spend is refused', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"min_spend_cents":-5}')$q$, venue_a), 'between 0');
  perform tests.assert_raises('an absurd amount is refused', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"min_spend_cents":100000001}')$q$, venue_a), 'between 0');
  perform tests.assert_raises('money must be whole cents (a decimal)', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"min_spend_cents":10.5}')$q$, venue_a), 'whole number');
  perform tests.assert_raises('...or a number, not text', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":"4","inventory_count":1}')$q$, venue_a), 'whole number');
  perform tests.assert_raises('...not a huge number', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":99999999999,"inventory_count":1}')$q$, venue_a), 'whole number');
  perform tests.assert_raises('minimum guests cannot exceed maximum', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"min_guests":5,"inventory_count":1}')$q$, venue_a), 'minimum guests cannot be more');
  perform tests.assert_raises('an unknown pricing mode is refused', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"pricing_mode":"free"}')$q$, venue_a), 'flat or hourly');
  perform tests.assert_raises('hourly pricing needs a rate', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"pricing_mode":"hourly"}')$q$, venue_a), 'hourly rate is required');
  perform tests.assert_raises('...above zero', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"pricing_mode":"hourly","hourly_rate_cents":0}')$q$, venue_a), 'hourly rate is required');
  perform tests.assert_raises('minimum hours has limits', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"pricing_mode":"hourly","hourly_rate_cents":100,"min_hours":25}')$q$, venue_a), 'between 1 and 24');
  perform tests.assert_raises('an image must be https', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"image_url":"ftp://x.example/a.png"}')$q$, venue_a), 'https link');
  perform tests.assert_raises('featured must be true or false', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"is_featured":"yes"}')$q$, venue_a), 'true or false');
  perform tests.assert_raises('a long description is refused', format($q$select public.save_venue_table_type(%L, null, %L::jsonb)$q$, venue_a, json_build_object('name', 'X', 'max_guests', 4, 'inventory_count', 1, 'description', repeat('d', 2001))::text), '2000 characters');
  perform tests.assert_raises('details must be an object', format($q$select public.save_venue_table_type(%L, null, '[1]')$q$, venue_a), 'must be an object');
  perform tests.assert_raises('...not nothing', format($q$select public.save_venue_table_type(%L, null, null)$q$, venue_a), 'must be an object');
  perform tests.assert_raises('the venue cannot be chosen inside the details', format($q$select public.save_venue_table_type(%L, null, %L::jsonb)$q$, venue_a, json_build_object('name', 'X', 'max_guests', 4, 'inventory_count', 1, 'venue_id', venue_r)::text), 'unknown field: venue_id');
  perform tests.assert_raises('a floor position cannot be set here', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"pos_x":5}')$q$, venue_a), 'unknown field: pos_x');
  perform tests.assert_raises('nor a floor', format($q$select public.save_venue_table_type(%L, null, %L::jsonb)$q$, venue_a, json_build_object('name', 'X', 'max_guests', 4, 'inventory_count', 1, 'floor_id', floor_b)::text), 'unknown field: floor_id');
  perform tests.assert_raises('nor the currency', format($q$select public.save_venue_table_type(%L, null, '{"name":"X","max_guests":4,"inventory_count":1,"currency":"usd"}')$q$, venue_a), 'unknown field: currency');
  perform tests.assert_raises('nor an id', format($q$select public.save_venue_table_type(%L, null, %L::jsonb)$q$, venue_a, json_build_object('id', gen_random_uuid(), 'name', 'X', 'max_guests', 4, 'inventory_count', 1)::text), 'unknown field: id');
  perform tests.assert_eq('none of the refused attempts added a table type', (select count(*) from public.list_venue_table_types(venue_a))::int, 3);

  -- Editing sends only what changed; everything else stays.
  perform public.save_venue_table_type(venue_a, type_b, '{"name":"Dance floor VIP"}');
  select * into r from public.list_venue_table_types(venue_a) where type_id = type_b;
  perform tests.assert_eq('a rename leaves price, rules and photo alone', r.name || '|' || r.min_spend_cents || '|' || r.hourly_rate_cents || '|' || r.max_guests || '|' || r.image_url || '|' || r.pricing_mode, 'Dance floor VIP|150000|20000|8|https://img.example/t.png|hourly');
  perform public.save_venue_table_type(venue_a, type_b, '{"pricing_mode":"flat"}');
  select * into r from public.list_venue_table_types(venue_a) where type_id = type_b;
  perform tests.assert_true('switching to flat pricing clears the hourly rate and minimum hours (as the CMS does)', r.pricing_mode = 'flat' and r.hourly_rate_cents is null and r.min_hours is null);
  perform tests.assert_raises('switching back to hourly without a rate is refused', format($q$select public.save_venue_table_type(%L, %L, '{"pricing_mode":"hourly"}')$q$, venue_a, type_b), 'hourly rate is required');
  perform public.save_venue_table_type(venue_a, type_b, '{"pricing_mode":"hourly","hourly_rate_cents":15000}');
  perform tests.assert_eq('hourly without minimum hours defaults to one hour', (select min_hours from public.list_venue_table_types(venue_a) where type_id = type_b), 1);
  perform public.save_venue_table_type(venue_a, type_b, '{"min_guests":null,"description":null,"badge_label":"","image_url":null}');
  select * into r from public.list_venue_table_types(venue_a) where type_id = type_b;
  perform tests.assert_true('null or blank clears the optional fields', r.min_guests is null and r.description is null and r.badge_label is null and r.image_url is null);
  perform tests.assert_raises('a minimum above the maximum is refused on an edit too', format($q$select public.save_venue_table_type(%L, %L, '{"min_guests":6,"max_guests":3}')$q$, venue_a, type_b), 'minimum guests cannot be more');
  perform public.save_venue_table_type(venue_a, type_b, '{"min_guests":4}');
  perform tests.assert_raises('lowering only the maximum below the saved minimum is refused', format($q$select public.save_venue_table_type(%L, %L, '{"max_guests":3}')$q$, venue_a, type_b), 'minimum guests cannot be more');
  perform tests.assert_raises('a required field cannot be nulled', format($q$select public.save_venue_table_type(%L, %L, '{"name":null}')$q$, venue_a, type_b), 'table name is required');
  perform tests.assert_raises('...nor the maximum guests', format($q$select public.save_venue_table_type(%L, %L, '{"max_guests":null}')$q$, venue_a, type_b), 'maximum guests is required');
  perform public.save_venue_table_type(venue_a, type_b, '{"inventory_count":0}');
  perform tests.assert_eq('zero tables is allowed (it means none to book)', (select inventory_count from public.list_venue_table_types(venue_a) where type_id = type_b), 0);

  -- An edit never moves a table the CMS placed on a floor.
  perform tests.logout();
  update public.site_table_types set floor_id = (select id from public.site_venue_floors where venue_id = venue_a limit 1), pos_x = 33, pos_y = 44, width = 6, height = 7 where id = type_a;
  perform tests.login(owner_u, 'owner@club.example');
  perform public.save_venue_table_type(venue_a, type_a, '{"name":"VIP Booth 1","min_spend_cents":90000}');
  perform tests.logout();
  select pos_x || '|' || pos_y || '|' || width || '|' || height || '|' || (floor_id is not null)::text into txt from public.site_table_types where id = type_a;
  perform tests.assert_eq('editing a table type leaves its place on the floor plan alone', txt, '33|44|6|7|true');
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.save_venue_table_type(venue_a, type_a, '{"deposit_cents":10000}');
  perform tests.assert_eq('a manager can edit one', (select deposit_cents from public.list_venue_table_types(venue_a) where type_id = type_a), 10000);

  -- The business's other club, and tampering with ids.
  perform tests.login(mgr_b, 'mgrb@club.example');
  type_x := public.save_venue_table_type(venue_b, null, '{"name":"B booth","max_guests":4,"inventory_count":2}');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('Club B''s table type cannot be edited by naming it under Club A', format($q$select public.save_venue_table_type(%L, %L, '{"name":"Hijacked"}')$q$, venue_a, type_x), 'table type not found');
  perform tests.assert_raises('nor removed that way', format($q$select public.remove_venue_table_type(%L, %L)$q$, venue_a, type_x), 'table type not found');
  perform tests.assert_eq('...Club B''s table type is unchanged', (select name from public.list_venue_table_types(venue_b) where type_id = type_x), 'B booth');
  perform tests.login(rival_u, 'rival@club2.example');
  perform tests.assert_raises('a rival cannot edit it through their own venue', format($q$select public.save_venue_table_type(%L, %L, '{"name":"Hijacked"}')$q$, venue_r, type_x), 'table type not found');

  -- A table type with bookings cannot be removed.
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('a table type with a booking cannot be removed', format($q$select public.remove_venue_table_type(%L, %L)$q$, venue_a, type_booked), 'has bookings');
  perform tests.assert_true('...and is still there', exists (select 1 from public.list_venue_table_types(venue_a) where name = 'Booked type'));
  perform public.remove_venue_table_type(venue_a, type_b);
  perform tests.assert_true('an unused one can be removed', not exists (select 1 from public.list_venue_table_types(venue_a) where type_id = type_b));
  perform tests.assert_raises('removing it again says so', format($q$select public.remove_venue_table_type(%L, %L)$q$, venue_a, type_b), 'table type not found');

  perform tests.logout();
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count)
    select venue_a, 'T' || g, 2, 0, 0, 1 from generate_series(1, 48) g;
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the venue is at its 50 table types', (select count(*) from public.list_venue_table_types(venue_a))::int, 50);
  perform tests.assert_raises('a 51st is refused', format($q$select public.save_venue_table_type(%L, null, '{"name":"Too many","max_guests":2,"inventory_count":1}')$q$, venue_a), '50 table types at most');
  perform tests.assert_true('...but existing ones can still be edited', public.save_venue_table_type(venue_a, type_a, '{"name":"VIP Booth 1"}') = type_a);

  ---------------------------------------------------------------- bottle menu
  bottle_a := public.save_venue_bottle(venue_a, null, '{"name":" Grey Goose ","price_cents":19500}');
  select * into r from public.list_venue_bottles(venue_a) where bottle_id = bottle_a;
  perform tests.assert_eq('a minimal bottle is available, in stock and priced', r.name || '|' || r.price_cents || '|' || r.is_available || '|' || r.is_sold_out, 'Grey Goose|19500|true|false');
  perform tests.assert_true('...with no size, category, photo or stock count', r.size is null and r.category is null and r.image_url is null and r.stock_quantity is null);
  bottle_b := public.save_venue_bottle(venue_a, null, '{"name":"Don Julio 1942","size":"750ml","description":"Tequila","price_cents":60000,"category":"Tequila",
    "image_url":"https://img.example/dj.png","is_available":true,"is_sold_out":false,"stock_quantity":12}');
  select * into r from public.list_venue_bottles(venue_a) where bottle_id = bottle_b;
  perform tests.assert_eq('every field the CMS writes can be set', r.size || '|' || r.description || '|' || r.category || '|' || r.image_url || '|' || r.stock_quantity, '750ml|Tequila|Tequila|https://img.example/dj.png|12');
  perform tests.assert_true('new bottles go to the end', (select sort_order from public.list_venue_bottles(venue_a) where bottle_id = bottle_b) > (select sort_order from public.list_venue_bottles(venue_a) where bottle_id = bottle_a));
  perform tests.assert_true('a bottle may be free (the table minimum can cover it)', public.save_venue_bottle(venue_a, null, '{"name":"Water","price_cents":0}') is not null);

  perform tests.assert_raises('a bottle needs a name', format($q$select public.save_venue_bottle(%L, null, '{"price_cents":100}')$q$, venue_a), 'bottle name is required');
  perform tests.assert_raises('...and a price', format($q$select public.save_venue_bottle(%L, null, '{"name":"X"}')$q$, venue_a), 'price is required');
  perform tests.assert_raises('a negative price is refused', format($q$select public.save_venue_bottle(%L, null, '{"name":"X","price_cents":-1}')$q$, venue_a), 'between 0');
  perform tests.assert_raises('a price in decimals is refused', format($q$select public.save_venue_bottle(%L, null, '{"name":"X","price_cents":19.5}')$q$, venue_a), 'whole number');
  perform tests.assert_raises('an absurd price is refused', format($q$select public.save_venue_bottle(%L, null, '{"name":"X","price_cents":10000001}')$q$, venue_a), 'between 0');
  perform tests.assert_raises('negative stock is refused', format($q$select public.save_venue_bottle(%L, null, '{"name":"X","price_cents":1,"stock_quantity":-1}')$q$, venue_a), 'between 0');
  perform tests.assert_raises('available must be true or false', format($q$select public.save_venue_bottle(%L, null, '{"name":"X","price_cents":1,"is_available":1}')$q$, venue_a), 'true or false');
  perform tests.assert_raises('an unknown field is refused', format($q$select public.save_venue_bottle(%L, null, '{"name":"X","price_cents":1,"currency":"usd"}')$q$, venue_a), 'unknown field: currency');
  perform tests.assert_raises('...including the venue', format($q$select public.save_venue_bottle(%L, null, %L::jsonb)$q$, venue_a, json_build_object('name', 'X', 'price_cents', 1, 'venue_id', venue_r)::text), 'unknown field: venue_id');
  perform tests.assert_raises('an image must be https', format($q$select public.save_venue_bottle(%L, null, '{"name":"X","price_cents":1,"image_url":"http://x.example/a.png"}')$q$, venue_a), 'https link');
  perform tests.assert_eq('the refused attempts added nothing', (select count(*) from public.list_venue_bottles(venue_a))::int, 3);

  perform public.save_venue_bottle(venue_a, bottle_b, '{"is_sold_out":true}');
  select * into r from public.list_venue_bottles(venue_a) where bottle_id = bottle_b;
  perform tests.assert_true('marking a bottle sold out changes only that', r.is_sold_out and r.price_cents = 60000 and r.stock_quantity = 12 and r.name = 'Don Julio 1942' and r.is_available);
  perform public.save_venue_bottle(venue_a, bottle_b, '{"is_sold_out":false,"price_cents":62000,"stock_quantity":null,"size":""}');
  select * into r from public.list_venue_bottles(venue_a) where bottle_id = bottle_b;
  perform tests.assert_true('price, stock and size change; null or blank clears the optional ones', r.price_cents = 62000 and r.stock_quantity is null and r.size is null and not r.is_sold_out);
  perform tests.assert_raises('a required field cannot be nulled', format($q$select public.save_venue_bottle(%L, %L, '{"price_cents":null}')$q$, venue_a, bottle_b), 'price is required');
  perform tests.login(mgr_a, 'mgra@club.example');
  perform public.save_venue_bottle(venue_a, bottle_a, '{"is_available":false}');
  perform tests.assert_true('a manager can take a bottle off the menu', not (select is_available from public.list_venue_bottles(venue_a) where bottle_id = bottle_a));

  perform tests.login(mgr_b, 'mgrb@club.example');
  bottle_x := public.save_venue_bottle(venue_b, null, '{"name":"B vodka","price_cents":8000}');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('Club B''s bottle cannot be edited by naming it under Club A', format($q$select public.save_venue_bottle(%L, %L, '{"name":"Hijacked"}')$q$, venue_a, bottle_x), 'bottle not found');
  perform tests.assert_raises('nor removed that way', format($q$select public.remove_venue_bottle(%L, %L)$q$, venue_a, bottle_x), 'bottle not found');
  perform tests.assert_eq('...it is unchanged', (select name from public.list_venue_bottles(venue_b) where bottle_id = bottle_x), 'B vodka');

  -- A past order keeps its own copy of the bottle.
  perform tests.logout();
  insert into public.site_table_booking_bottles (booking_id, bottle_id, bottle_name, size, unit_price_cents, quantity, line_total_cents)
    values (booking, bottle_b, 'Don Julio 1942', '750ml', 60000, 1, 60000);
  perform tests.login(owner_u, 'owner@club.example');
  perform public.remove_venue_bottle(venue_a, bottle_b);
  perform tests.assert_true('a bottle can be removed', not exists (select 1 from public.list_venue_bottles(venue_a) where bottle_id = bottle_b));
  perform tests.logout();
  select bottle_name || '|' || unit_price_cents || '|' || coalesce(bottle_id::text, 'null') into txt from public.site_table_booking_bottles where booking_id = booking;
  perform tests.assert_eq('...and the past order still shows the name and price it was bought at', txt, 'Don Julio 1942|60000|null');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('removing it again says so', format($q$select public.remove_venue_bottle(%L, %L)$q$, venue_a, bottle_b), 'bottle not found');

  perform tests.logout();
  insert into public.site_bottles (venue_id, name, price_cents) select venue_a, 'B' || g, 100 from generate_series(1, 298) g;
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the venue is at its 300 bottles', (select count(*) from public.list_venue_bottles(venue_a))::int, 300);
  perform tests.assert_raises('a 301st is refused', format($q$select public.save_venue_bottle(%L, null, '{"name":"Too many","price_cents":1}')$q$, venue_a), '300 bottles at most');

  ---------------------------------------------------------------- the checklist follows what now exists
  perform tests.login(mgr_b, 'mgrb@club.example');
  select string_agg(step, ',' order by step) into txt from public.venue_setup_status(venue_b) where status = 'done' and required;
  perform tests.assert_eq('Club B now has a floor plan, tables, bottles and arrival times', txt, 'booking_rules,bottles,floor_plan,tables');

  ---------------------------------------------------------------- the public site sees it only once the venue is live
  perform tests.login_anon();
  perform tests.assert_eq('guests see no table types of a draft venue', (select count(*) from public.site_table_types where venue_id = venue_b)::int, 0);
  perform tests.assert_eq('...nor its bottles', (select count(*) from public.site_bottles where venue_id = venue_b)::int, 0);
  perform tests.assert_eq('...nor its arrival times', (select count(*) from public.site_venue_time_slots where venue_id = venue_b)::int, 0);
  perform tests.assert_eq('...nor its floors', (select count(*) from public.site_venue_floors where venue_id = venue_b)::int, 0);
  perform tests.logout();
  update public.site_venues set status = 'published' where id = venue_b;
  perform tests.login_anon();
  perform tests.assert_eq('once the venue is published, guests see its table types', (select count(*) from public.site_table_types where venue_id = venue_b)::int, 1);
  perform tests.assert_eq('...its bottles', (select count(*) from public.site_bottles where venue_id = venue_b)::int, 1);
  perform tests.assert_eq('...its arrival times', (select count(*) from public.site_venue_time_slots where venue_id = venue_b)::int, 1);
  perform tests.assert_eq('...and its floors', (select count(*) from public.site_venue_floors where venue_id = venue_b)::int, 1);

  ---------------------------------------------------------------- attribution
  perform tests.login(admin_u, 'admin@test.example');
  perform tests.assert_true('every change is in the audit log', (select count(*) from public.audit_log where action like 'venue_setup.%') > 20);
  select actor_id::text as actor_id, actor_email, details ->> 'venue_id' as venue into r from public.audit_log where action = 'venue_setup.bottle_added' and entity_id = bottle_x::text;
  perform tests.assert_eq('a change names who made it', r.actor_id || '|' || r.actor_email, mgr_b::text || '|mgrb@club.example');
  perform tests.assert_eq('...and which venue', r.venue, venue_b::text);
  select count(*) into n from public.audit_log where action = 'venue_setup.table_type_removed' and entity_id = type_b::text;
  perform tests.assert_eq('removals are recorded', n, 1);
  select count(*) into n from public.audit_log where action = 'venue_setup.forged';
  perform tests.assert_eq('the forged entry was not written', n, 0);
  select count(*) into n from public.audit_log where action like 'venue_setup.%' and (actor_id is null or actor_email = 'unknown');
  perform tests.assert_eq('no entry is anonymous', n, 0);
  perform tests.logout();
end $$;

rollback;
