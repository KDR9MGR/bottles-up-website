-- Venue facts, reviews and Explore. What matters most: only the venue's owner or manager changes its facts; a review needs a real visit (a paid booking on a night that
-- is over, or a paid ticket to a finished event, matched by e-mail), only a person writes one, only the venue's own profile answers; blocked and suspended people vanish from
-- what is shown; "hot" is counted from what really happened and gives away nobody's booking; the directory hides the blocked and suspended.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.q(p_user uuid, p_email text, p_expr text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute 'select (' || p_expr || ')::text' into r;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.f(p_user uuid, p_email text, p_expr text, p_path text[]) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute 'select (' || p_expr || ') #>> $1' into r using p_path;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
-- A field of every element of a json list, in order.
create function tests.names(p_user uuid, p_email text, p_expr text, p_field text default 'handle') returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute 'select coalesce(string_agg(e ->> $1, '','' order by ord), ''(none)'') from jsonb_array_elements(' || p_expr || ') with ordinality as t(e, ord)' into r using p_field;
  perform tests.logout();
  return r;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  ann constant uuid := '00000000-0000-0000-0000-0000000006a1';    -- went to Club A (a paid table, last week)
  bob constant uuid := '00000000-0000-0000-0000-0000000006a2';    -- went to a finished event at Club A (a ticket)
  cy constant uuid := '00000000-0000-0000-0000-0000000006a3';     -- booked but never paid
  dee constant uuid := '00000000-0000-0000-0000-0000000006a4';    -- booked a night that has not happened yet
  olly constant uuid := '00000000-0000-0000-0000-0000000006a5';   -- owns Club A and Club B
  mia constant uuid := '00000000-0000-0000-0000-0000000006a6';    -- manages Club A
  max constant uuid := '00000000-0000-0000-0000-0000000006a7';    -- manages Club B
  eve constant uuid := '00000000-0000-0000-0000-0000000006a8';    -- an organizer
  rando constant uuid := '00000000-0000-0000-0000-0000000006a9';
  a_e constant text := 'Ann@Rev.example'; b_e constant text := 'bob@rev.example'; c_e constant text := 'cy@rev.example'; d_e constant text := 'dee@rev.example';
  o_e constant text := 'olly@rev.example'; m_e constant text := 'mia@rev.example'; x_e constant text := 'max@rev.example'; e_e constant text := 'eve@rev.example'; r_e constant text := 'rando@rev.example';
  p_ann uuid; p_bob uuid; p_cy uuid; p_dee uuid; p_olly uuid; p_eve uuid; p_clubA uuid; p_clubB uuid; p_group uuid; p_dj uuid; p_photo uuid; p_other uuid;
  org uuid; org2 uuid; va uuid; vb uuid; vc uuid; e_past uuid; e_future uuid; e_far uuid; e_org2 uuid; t_a uuid; slot uuid; tier uuid;
  rv1 text; rv2 text; rv3 text; txt text; n int;
begin
  insert into auth.users (id, email) values (ann, a_e), (bob, b_e), (cy, c_e), (dee, d_e), (olly, o_e), (mia, m_e), (max, x_e), (eve, e_e), (rando, r_e);
  insert into public.profiles (id, name, email) values
    (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (cy, 'Cy Rus', c_e), (dee, 'Dee Dee', d_e), (olly, 'Olly Owner', o_e), (mia, 'Mia Manager', m_e), (max, 'Max Manager', x_e), (eve, 'Eve Organizer', e_e), (rando, 'Rae Random', r_e);
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('social', true); perform tests.logout();
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'ann', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bob', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(cy, c_e); perform public.save_my_profile('Cy Rus', 'cyrus', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(dee, d_e); perform public.save_my_profile('Dee Dee', 'dee', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(olly, o_e); perform public.save_my_profile('Olly Owner', 'olly', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(mia, m_e); perform public.save_my_profile('Mia Manager', 'mia', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(max, x_e); perform public.save_my_profile('Max Manager', 'max', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(eve, e_e); perform public.save_my_profile('Eve Organizer', 'eve', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(rando, r_e); perform public.save_my_profile('Rae Random', 'rae', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.logout();
  select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal'; select id into p_bob from public.site_profiles where user_id = bob and kind = 'personal';
  select id into p_cy from public.site_profiles where user_id = cy and kind = 'personal'; select id into p_dee from public.site_profiles where user_id = dee and kind = 'personal';
  select id into p_olly from public.site_profiles where user_id = olly and kind = 'personal'; select id into p_eve from public.site_profiles where user_id = eve and kind = 'personal';

  perform tests.login(olly, o_e);
  org := public.create_organization('Club Co', 'venue_owner');
  va := public.create_org_venue(org, 'Club A'); vb := public.create_org_venue(org, 'Club B'); vc := public.create_org_venue(org, 'Club C');
  perform tests.join_as(olly, o_e, org, m_e, 'manager', va, mia);
  perform tests.join_as(olly, o_e, org, x_e, 'manager', vb, max);
  perform tests.login(eve, e_e); org2 := public.create_organization('Events Co', 'organizer'); perform tests.logout();
  update public.site_venues set status = 'published' where id in (va, vb);
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, venue_id) values
    ('Past Night', 'x', 'Club A', now() - interval '10 days', now() - interval '10 days' + interval '6 hours', 'published', org, va) returning id into e_past;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id, venue_id) values
    ('Next Friday', 'x', 'Club A', now() + interval '3 days', now() + interval '3 days 6 hours', 'published', org, va) returning id into e_future;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values
    ('Far Away', 'x', 'Somewhere', now() + interval '30 days', now() + interval '30 days 6 hours', 'published', org) returning id into e_far;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values
    ('Organizer Night', 'x', 'Somewhere', now() - interval '5 days', now() - interval '5 days' + interval '6 hours', 'published', org2) returning id into e_org2;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (e_past, 'GA', 1000, 100) returning id into tier;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (va, 'Booth', 6, 0, 10000, 50) returning id into t_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (va, 5, '22:00') returning id into slot;

  -- who went where
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status) values
    (va, t_a, slot, current_date - 7, 'Ann', 'ANN@rev.example', 2, 10000, 'paid'),            -- a night that is over (the e-mail in capitals: still hers)
    (va, t_a, slot, current_date + 3, 'Dee', d_e, 2, 10000, 'paid'),                          -- a night still to come
    (va, t_a, slot, current_date - 7, 'Cy', c_e, 2, 10000, 'pending'),                        -- never paid
    (vb, (select id from public.site_table_types limit 1), slot, current_date - 2, 'Bob', b_e, 2, 10000, 'paid');
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code) values
    (e_past, tier, 'Bob', b_e, 1, 1000, 'paid', 'REV-BOB'),
    (e_past, tier, 'Cy', c_e, 1, 1000, 'pending', 'REV-CY');
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) select e_org2, 'GA', 1000, 100;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code)
    select e_org2, id, 'Ann', a_e, 1, 1000, 'paid', 'REV-ANN2' from public.site_ticket_tiers where event_id = e_org2;

  perform tests.q(olly, o_e, format($q$public.profile_create_business('venue', 'Club A', 'clubaclub', null, null, null, %L)$q$, va));
  perform tests.q(olly, o_e, format($q$public.profile_create_business('venue', 'Club B', 'clubbclub', null, null, null, %L)$q$, vb));
  perform tests.q(eve, e_e, format($q$public.profile_create_business('event_group', 'Night Crew', 'nightcrew', null, 'Toronto', %L)$q$, org2));
  select id into p_clubA from public.site_profiles where venue_id = va; select id into p_clubB from public.site_profiles where venue_id = vb; select id into p_group from public.site_profiles where org_id = org2 and venue_id is null;

  ---------------------------------------------------------------- venue facts
  perform tests.assert_eq('the owner sets the facts', tests.f(olly, o_e, format($q$public.save_venue_facts(%L, array['wifi', 'parking', 'wifi', 'coat_check'], '  Lot behind the club  ', 19, true, '1:30 AM', '6 PM to 11 PM', 'https://club.example/menu')$q$, va), '{amenities}'), '["coat_check", "parking", "wifi"]');
  perform tests.assert_eq('...kept as given: no repeats, sorted, text tidied', tests.q(olly, o_e, format($q$(public.save_venue_facts(%L, array['wifi'], ' Lot ', 19, true, ' 1:30 AM ', null, null)) ->> 'parking_info'$q$, va)), 'Lot');
  perform tests.assert_eq('the manager of that venue may too', tests.f(mia, m_e, format($q$public.save_venue_facts(%L, array['accessible'], null, 21, false, null, null, null)$q$, va), '{min_age}'), '21');
  perform tests.assert_eq('the manager of another venue may not', tests.q(max, x_e, format($q$public.save_venue_facts(%L, array['wifi'], null, 21, false, null, null, null)$q$, va)), 'ERROR: You can only change the details of a venue you own or manage.');
  perform tests.assert_eq('a stranger may not', tests.q(rando, r_e, format($q$public.save_venue_facts(%L, array['wifi'], null, 21, false, null, null, null)$q$, va)), 'ERROR: You can only change the details of a venue you own or manage.');
  perform tests.assert_eq('a feature we do not know is refused', tests.q(olly, o_e, format($q$public.save_venue_facts(%L, array['helipad'], null, 21, false, null, null, null)$q$, va)), 'ERROR: One of those features is not one we know.');
  perform tests.assert_eq('an age under 13 is refused', tests.q(olly, o_e, format($q$public.save_venue_facts(%L, '{}', null, 12, false, null, null, null)$q$, va)), 'ERROR: The minimum age must be between 13 and 25.');
  perform tests.assert_eq('an age over 25 is refused', tests.q(olly, o_e, format($q$public.save_venue_facts(%L, '{}', null, 26, false, null, null, null)$q$, va)), 'ERROR: The minimum age must be between 13 and 25.');
  perform tests.assert_eq('a menu link must be https', tests.q(olly, o_e, format($q$public.save_venue_facts(%L, '{}', null, null, false, null, null, 'http://club.example/menu')$q$, va)), 'ERROR: The menu link must start with https://.');
  perform tests.assert_eq('300 characters of parking note are fine', tests.q(olly, o_e, format($q$(public.save_venue_facts(%L, '{}', %L, null, false, null, null, null)) ->> 'parking_info'$q$, va, repeat('p', 300))), repeat('p', 300));
  perform tests.assert_eq('301 are not', tests.q(olly, o_e, format($q$public.save_venue_facts(%L, '{}', %L, null, false, null, null, null)$q$, va, repeat('p', 301))), 'ERROR: The parking note can be 300 characters at most.');
  perform tests.assert_eq('whether ID is required must be said', tests.q(olly, o_e, format($q$public.save_venue_facts(%L, '{}', null, null, null, null, null, null)$q$, va)), 'ERROR: Say whether ID is required.');
  perform tests.assert_eq('a long last-entry note is refused', tests.q(olly, o_e, format($q$public.save_venue_facts(%L, '{}', null, null, false, %L, null, null)$q$, va, repeat('x', 41))), 'ERROR: Last entry can be 40 characters at most.');
  perform tests.q(olly, o_e, format($q$public.save_venue_facts(%L, array['wifi', 'parking'], 'Lot', 19, true, '1:30 AM', null, 'https://club.example/menu')$q$, va));
  perform tests.assert_eq('a save is in the audit log', (select count(*) from public.audit_log where action = 'venue_facts_saved')::int >= 3, true);
  perform tests.login_anon();
  perform tests.assert_eq('anyone can read a published venue''s facts (they are columns of the venue)', (select amenities::text || '/' || min_age || '/' || id_required from public.site_venues where id = va), '{parking,wifi}/19/true');
  perform tests.assert_raises('a visitor cannot change them', format($q$select public.save_venue_facts(%L, '{}', null, null, false, null, null, null)$q$, va), 'permission denied');
  perform tests.logout();
  perform tests.q(olly, o_e, format($q$public.save_venue_facts(%L, '{}', '', null, false, '', '', '')$q$, va));
  perform tests.assert_eq('an empty field clears it', (select parking_info is null and last_entry is null and menu_url is null and min_age is null from public.site_venues where id = va), true);

  ---------------------------------------------------------------- who may review
  perform tests.assert_eq('reviews are off at first', tests.f(ann, a_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_ann, va), '{reason}'), 'Reviews are not open yet.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('reviews', true); perform tests.logout();
  perform tests.assert_eq('a paid table on a night that is over makes one eligible, whatever the case of the e-mail', tests.f(ann, a_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_ann, va), '{eligible}'), 'true');
  perform tests.assert_eq('a ticket to a finished event there counts for the venue', tests.f(bob, b_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_bob, va), '{eligible}'), 'true');
  perform tests.assert_eq('...and for the event', tests.f(bob, b_e, format($q$public.review_eligibility(%L, 'event', %L)$q$, p_bob, e_past), '{eligible}'), 'true');
  perform tests.assert_eq('a booking that was never paid does not', tests.f(cy, c_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_cy, va), '{eligible}'), 'false');
  perform tests.assert_eq('a ticket that was never paid does not', tests.f(cy, c_e, format($q$public.review_eligibility(%L, 'event', %L)$q$, p_cy, e_past), '{eligible}'), 'false');
  perform tests.assert_eq('a night still to come does not', tests.f(dee, d_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_dee, va), '{eligible}'), 'false');
  perform tests.assert_eq('...the reason is plain', tests.f(dee, d_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_dee, va), '{reason}'), 'You can review a venue after a night you booked there.');
  perform tests.assert_eq('nobody can review an event they have no ticket for', tests.f(ann, a_e, format($q$public.review_eligibility(%L, 'event', %L)$q$, p_ann, e_past), '{reason}'), 'You can review an event after you went to it.');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (va, t_a, slot, current_date, 'Rae', r_e, 2, 10000, 'paid');
  perform tests.assert_eq('a paid table for tonight is not yet a visit', tests.f(rando, r_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, (select id from public.site_profiles where user_id = rando), va), '{eligible}'), 'false');
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (e_future, 'GA', 1000, 10);
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code)
    select e_future, id, 'Dee', d_e, 1, 1000, 'paid', 'FUT-DEE' from public.site_ticket_tiers where event_id = e_future;
  perform tests.assert_eq('a paid ticket to an event that has not happened is not a visit', tests.f(dee, d_e, format($q$public.review_eligibility(%L, 'event', %L)$q$, p_dee, e_future), '{eligible}'), 'false');
  perform tests.assert_eq('...nor for the venue it will be at', tests.f(dee, d_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_dee, va), '{eligible}'), 'false');
  delete from public.site_table_bookings where customer_email = r_e;
  perform tests.assert_eq('a venue one never visited', tests.f(ann, a_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_ann, vb), '{eligible}'), 'false');
  perform tests.assert_eq('an event that has not happened', tests.f(ann, a_e, format($q$public.review_eligibility(%L, 'event', %L)$q$, p_ann, e_future), '{eligible}'), 'false');
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000006b0', null);
  insert into public.profiles (id, name) values ('00000000-0000-0000-0000-0000000006b0', 'Phone Only');
  perform tests.login('00000000-0000-0000-0000-0000000006b0', null); perform public.save_my_profile('Phone Only', 'phoneonly', 'Toronto'); perform public.profile_save_personal('public'); perform tests.logout();
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (va, t_a, slot, current_date - 9, 'No Email', '', 2, 10000, 'paid');
  perform tests.assert_eq('a phone-only account matches no booking, not even one saved with an empty e-mail', tests.f('00000000-0000-0000-0000-0000000006b0', null, format($q$public.review_eligibility(%L, 'venue', %L)$q$, (select id from public.site_profiles where user_id = '00000000-0000-0000-0000-0000000006b0'), va), '{eligible}'), 'false');
  delete from public.site_table_bookings where customer_email = '';
  perform tests.assert_eq('a business profile cannot review', tests.f(olly, o_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_clubA, va), '{reason}'), 'Only a person''s own profile can write a review.');
  perform tests.assert_eq('a made-up kind is refused', tests.q(ann, a_e, format($q$public.review_eligibility(%L, 'bar', %L)$q$, p_ann, va)), 'ERROR: Choose a venue or an event.');
  perform tests.assert_eq('someone else''s profile cannot be used', tests.q(bob, b_e, format($q$public.review_eligibility(%L, 'venue', %L)$q$, p_ann, va)), 'ERROR: You cannot act as this profile.');

  ---------------------------------------------------------------- writing one
  perform tests.assert_eq('a rating is 1 to 5', tests.q(ann, a_e, format($q$public.review_save(%L, 'venue', %L, 0, 'x')$q$, p_ann, va)), 'ERROR: Choose 1 to 5 stars.');
  perform tests.assert_eq('...not 6', tests.q(ann, a_e, format($q$public.review_save(%L, 'venue', %L, 6, 'x')$q$, p_ann, va)), 'ERROR: Choose 1 to 5 stars.');
  perform tests.assert_eq('...and not nothing', tests.q(ann, a_e, format($q$public.review_save(%L, 'venue', %L, null)$q$, p_ann, va)), 'ERROR: Choose 1 to 5 stars.');
  perform tests.assert_eq('1001 characters are refused', tests.q(ann, a_e, format($q$public.review_save(%L, 'venue', %L, 5, %L)$q$, p_ann, va, repeat('a', 1001))), 'ERROR: A review can be 1000 characters at most.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_banned_term('slur', true); perform tests.logout();
  perform tests.assert_eq('a banned word is refused', tests.q(ann, a_e, format($q$public.review_save(%L, 'venue', %L, 5, 'what a SLUR')$q$, p_ann, va)), 'ERROR: That text goes against our community rules.');
  perform tests.assert_eq('someone who was not there is told why', tests.q(dee, d_e, format($q$public.review_save(%L, 'venue', %L, 5, 'great')$q$, p_dee, va)), 'ERROR: You can review a venue after a night you booked there.');
  perform tests.assert_eq('a review is saved', tests.f(ann, a_e, format($q$public.review_save(%L, 'venue', %L, 4, '  Great night, slow bar.  ')$q$, p_ann, va), '{body}'), 'Great night, slow bar.');
  perform tests.assert_eq('...with her name on it', tests.f(bob, b_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items' -> 0$q$, p_bob, va), '{author,handle}'), 'ann');
  perform tests.assert_eq('writing again changes it, it does not add another', tests.f(ann, a_e, format($q$public.review_save(%L, 'venue', %L, 5, null)$q$, p_ann, va), '{rating}'), '5');
  perform tests.logout();
  perform tests.assert_eq('...one review', (select count(*) from public.site_reviews where author = p_ann and venue_id = va)::int, 1);
  perform tests.assert_eq('...with its body cleared', (select body is null from public.site_reviews where author = p_ann and venue_id = va), true);
  perform tests.q(ann, a_e, format($q$public.review_save(%L, 'venue', %L, 4, 'Great night, slow bar.')$q$, p_ann, va));
  perform pg_sleep(0.01); perform tests.q(bob, b_e, format($q$public.review_save(%L, 'venue', %L, 2, 'Too loud for me')$q$, p_bob, va));
  perform pg_sleep(0.01); perform tests.q(bob, b_e, format($q$public.review_save(%L, 'event', %L, 5, 'The best night')$q$, p_bob, e_past));

  -- the speed limit: ten new reviews in a day
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) select 'Old ' || g, 'x', 'Somewhere', now() - interval '20 days', now() - interval '19 days', 'published', org from generate_series(1, 11) g;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) select e.id, 'GA', 1000, 10 from public.site_events e where e.title like 'Old %';
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code)
    select t.event_id, t.id, 'Ann', a_e, 1, 1000, 'paid', 'OLD-' || row_number() over () from public.site_ticket_tiers t join public.site_events e on e.id = t.event_id where e.title like 'Old %';
  insert into public.site_reviews (kind, event_id, author, rating) select 'event', e.id, p_ann, 3 from public.site_events e where e.title like 'Old %' order by e.title limit 9;
  perform tests.assert_eq('with 9 reviews in the day, a 10th is allowed (she also has the venue one)', (select count(*) from public.site_reviews where author = p_ann and created_at > now() - interval '1 day')::int >= 10, true);
  perform tests.assert_eq('...an 11th new one is slowed', tests.q(ann, a_e, format($q$public.review_save(%L, 'event', %L, 3, 'x')$q$, p_ann, (select id from public.site_events where title = 'Old 9'))), 'ERROR: You are writing reviews too quickly. Try again later.');
  perform tests.assert_eq('...but changing an existing one is not', tests.f(ann, a_e, format($q$public.review_save(%L, 'venue', %L, 4, 'Great night, slow bar.')$q$, p_ann, va), '{rating}'), '4');
  delete from public.site_reviews where author = p_ann and event_id is not null;

  ---------------------------------------------------------------- reading them
  perform tests.assert_eq('the summary: how many, the average, how many of each star', tests.f(rando, r_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'summary'$q$, (select id from public.site_profiles where user_id = rando), va), '{}'), '{"count": 2, "stars": [0, 1, 0, 1, 0], "average": 3.0}');
  perform tests.assert_eq('newest first', tests.names(rando, r_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items'$q$, (select id from public.site_profiles where user_id = rando), va), 'rating'), '2,4');
  perform tests.assert_eq('a page of one', tests.names(bob, b_e, format($q$(public.reviews_list(%L, 'venue', %L, 1)) -> 'items'$q$, p_bob, va), 'rating'), '2');
  perform tests.assert_eq('the next page starts after the last one seen', tests.names(bob, b_e, format($q$(public.reviews_list(%L, 'venue', %L, 1, %L::timestamptz, %L)) -> 'items'$q$, p_bob, va,
    tests.f(bob, b_e, format($q$(public.reviews_list(%L, 'venue', %L, 1)) -> 'items' -> 0$q$, p_bob, va), '{created_at}'), tests.f(bob, b_e, format($q$(public.reviews_list(%L, 'venue', %L, 1)) -> 'items' -> 0$q$, p_bob, va), '{id}')::uuid), 'rating'), '4');
  perform tests.assert_eq('a review says whether it is yours', tests.f(ann, a_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items' -> 1$q$, p_ann, va), '{is_mine}'), 'true');
  perform tests.assert_eq('...and not whose else', tests.f(ann, a_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items' -> 0$q$, p_ann, va), '{is_mine}'), 'false');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, true)$q$, p_ann, p_bob));
  perform tests.assert_eq('a blocked person''s review is hidden from the one who blocked them', tests.names(ann, a_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items'$q$, p_ann, va), 'rating'), '4');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, false)$q$, p_ann, p_bob));
  update public.site_profiles set status = 'suspended' where id = p_bob;
  perform tests.assert_eq('a suspended person''s review is hidden and not counted', tests.q(cy, c_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'summary' ->> 'count'$q$, p_cy, va)), '1');
  perform tests.assert_eq('...in the list too', tests.names(cy, c_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items'$q$, p_cy, va), 'rating'), '4');
  perform tests.assert_eq('...and in the ratings of a list of venues', (select public.venue_ratings(array[va]) -> va::text ->> 'count'), '1');
  update public.site_profiles set status = 'active' where id = p_bob;
  update public.site_reviews set status = 'removed' where author = p_bob and venue_id = va;
  perform tests.assert_eq('a removed review is not shown or counted', tests.q(cy, c_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'summary' ->> 'count'$q$, p_cy, va)), '1');
  perform tests.assert_eq('...in the list either', tests.names(cy, c_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items'$q$, p_cy, va), 'rating'), '4');
  update public.site_reviews set status = 'active' where author = p_bob and venue_id = va;
  perform tests.assert_eq('the event''s reviews are its own', tests.names(cy, c_e, format($q$(public.reviews_list(%L, 'event', %L)) -> 'items'$q$, p_cy, e_past), 'rating'), '5');
  perform tests.assert_eq('a made-up kind is refused', tests.q(cy, c_e, format($q$public.reviews_list(%L, 'bar', %L)$q$, p_cy, va)), 'ERROR: Choose a venue or an event.');

  ---------------------------------------------------------------- answering
  select id::text into rv1 from public.site_reviews where author = p_ann and venue_id = va;
  select id::text into rv2 from public.site_reviews where author = p_bob and venue_id = va;
  select id::text into rv3 from public.site_reviews where author = p_bob and event_id = e_past;
  perform tests.assert_eq('the venue''s owner sees that they can reply', tests.f(olly, o_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items' -> 0$q$, p_clubA, va), '{can_reply}'), 'true');
  perform tests.assert_eq('...a reader does not', tests.f(cy, c_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items' -> 0$q$, p_cy, va), '{can_reply}'), 'false');
  perform tests.assert_eq('the venue replies', tests.f(olly, o_e, format($q$public.review_reply(%L, %L, 'Thanks Ann, we are adding bartenders.')$q$, p_clubA, rv1::uuid), '{reply,body}'), 'Thanks Ann, we are adding bartenders.');
  perform tests.assert_eq('...as the venue', tests.f(cy, c_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items' -> 1$q$, p_cy, va), '{reply,author,handle}'), 'clubaclub');
  perform tests.assert_eq('its manager may reply too, and it replaces the earlier reply', tests.f(mia, m_e, format($q$public.review_reply(%L, %L, 'Updated answer')$q$, p_clubA, rv1::uuid), '{reply,body}'), 'Updated answer');
  perform tests.logout();
  perform tests.assert_eq('...one reply per review', (select count(*) from public.site_review_replies where review = rv1::uuid)::int, 1);
  perform tests.assert_eq('another club cannot reply', tests.q(max, x_e, format($q$public.review_reply(%L, %L, 'hi')$q$, p_clubB, rv1::uuid)), 'ERROR: Only the venue or the organizer it is about can reply.');
  perform tests.assert_eq('a person cannot reply as the venue', tests.q(bob, b_e, format($q$public.review_reply(%L, %L, 'hi')$q$, p_bob, rv1::uuid)), 'ERROR: Only the venue or the organizer it is about can reply.');
  perform tests.assert_eq('a venue cannot answer a review of an event it did not run', tests.q(olly, o_e, format($q$public.review_reply(%L, %L, 'hi')$q$, p_clubA, rv3::uuid)), 'ERROR: Only the venue or the organizer it is about can reply.');
  perform tests.assert_eq('an empty reply is refused', tests.q(olly, o_e, format($q$public.review_reply(%L, %L, '  ')$q$, p_clubA, rv1::uuid)), 'ERROR: Write something first.');
  perform tests.assert_eq('a long reply is refused', tests.q(olly, o_e, format($q$public.review_reply(%L, %L, %L)$q$, p_clubA, rv1::uuid, repeat('a', 1001))), 'ERROR: A reply can be 1000 characters at most.');
  perform tests.assert_eq('a banned word is refused in a reply', tests.q(olly, o_e, format($q$public.review_reply(%L, %L, 'slur')$q$, p_clubA, rv1::uuid)), 'ERROR: That text goes against our community rules.');
  perform tests.logout();
  update public.site_memberships set status = 'revoked' where user_id = mia and org_id = org;
  perform tests.assert_eq('...once revoked, the manager is out at once', tests.q(mia, m_e, format($q$public.review_reply(%L, %L, 'late')$q$, p_clubA, rv1::uuid)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('the reply is removed', tests.f(olly, o_e, format($q$public.review_reply_delete(%L, %L)$q$, p_clubA, rv1::uuid), '{deleted}'), 'true');
  perform tests.assert_eq('...and the review shows none', tests.q(cy, c_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items' -> 1 -> 'reply'$q$, p_cy, va)), 'null');
  -- an event is answered by the organizer's group profile
  insert into public.site_reviews (kind, event_id, author, rating, body) values ('event', e_org2, p_ann, 5, 'Fun');
  select id::text into txt from public.site_reviews where event_id = e_org2;
  perform tests.assert_eq('the reviews of one event are not mixed with another''s', tests.names(cy, c_e, format($q$(public.reviews_list(%L, 'event', %L)) -> 'items'$q$, p_cy, e_past), 'rating'), '5');
  perform tests.assert_eq('...the other has its own', tests.names(cy, c_e, format($q$(public.reviews_list(%L, 'event', %L)) -> 'items'$q$, p_cy, e_org2), 'body'), 'Fun');
  begin
    insert into public.site_reviews (kind, venue_id, author, rating) values ('venue', va, p_ann, 1);
    raise exception 'FAIL - a second review of the same venue by the same person went in';
  exception when unique_violation then
    perform tests.assert_true('one review per person per venue, whatever the code does', true);
  end;
  perform tests.assert_eq('the organizer''s group profile answers a review of its event', tests.f(eve, e_e, format($q$public.review_reply(%L, %L, 'Thank you!')$q$, p_group, txt::uuid), '{reply,body}'), 'Thank you!');
  perform tests.assert_eq('a venue profile of another business cannot', tests.q(olly, o_e, format($q$public.review_reply(%L, %L, 'hi')$q$, p_clubB, txt::uuid)), 'ERROR: Only the venue or the organizer it is about can reply.');
  perform tests.login(rando, r_e); org := public.create_organization('Other Events', 'organizer'); perform public.profile_create_business('event_group', 'Other Crew', 'othercrew', null, null, org); perform tests.logout();
  select id into p_other from public.site_profiles where handle = 'othercrew';
  perform tests.assert_eq('another organizer''s group cannot answer a review of this event', tests.q(rando, r_e, format($q$public.review_reply(%L, %L, 'hi')$q$, p_other, txt::uuid)), 'ERROR: Only the venue or the organizer it is about can reply.');
  perform tests.assert_eq('a person cannot take a reply away', tests.q(bob, b_e, format($q$public.review_reply_delete(%L, %L)$q$, p_bob, txt::uuid)), 'ERROR: Only the venue or the organizer it is about can reply.');
  perform tests.assert_eq('...nor another business', tests.q(olly, o_e, format($q$public.review_reply_delete(%L, %L)$q$, p_clubB, txt::uuid)), 'ERROR: Only the venue or the organizer it is about can reply.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('reviews', false); perform tests.logout();
  perform tests.assert_eq('with reviews off nobody replies', tests.q(eve, e_e, format($q$public.review_reply(%L, %L, 'again')$q$, p_group, txt::uuid)), 'ERROR: Reviews are not open yet.');
  perform tests.assert_eq('...nor writes', tests.q(ann, a_e, format($q$public.review_save(%L, 'venue', %L, 4, 'x')$q$, p_ann, va)), 'ERROR: Reviews are not open yet.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('reviews', true); perform tests.logout();

  -- deleting
  perform tests.assert_eq('someone else cannot delete a review', tests.q(cy, c_e, format($q$public.review_delete(%L, %L)$q$, p_cy, rv2::uuid)), 'ERROR: You can only delete your own reviews.');
  perform tests.assert_eq('the author can', tests.f(bob, b_e, format($q$public.review_delete(%L, %L)$q$, p_bob, rv2::uuid), '{deleted}'), 'true');
  perform tests.assert_eq('...and it is gone from the count', tests.q(cy, c_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'summary' ->> 'count'$q$, p_cy, va)), '1');
  perform tests.assert_eq('the venue cannot delete a review', tests.q(olly, o_e, format($q$public.review_delete(%L, %L)$q$, p_clubA, rv1::uuid)), 'ERROR: You can only delete your own reviews.');

  ---------------------------------------------------------------- ratings for a list of venues
  perform tests.login_anon();
  perform tests.assert_eq('ratings for a list of venues, open to visitors', public.venue_ratings(array[va, vb]), jsonb_build_object(va::text, jsonb_build_object('count', 1, 'average', 4.0)));
  perform tests.logout();
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('reviews', false); perform tests.logout();
  perform tests.assert_eq('...nothing while reviews are off', public.venue_ratings(array[va, vb]), '{}'::jsonb);
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('reviews', true); perform tests.logout();
  perform tests.assert_eq('...and nothing for no venues', public.venue_ratings(null), '{}'::jsonb);

  ---------------------------------------------------------------- what's hot
  perform tests.q(ann, a_e, 'public.rules_accept(1)');
  insert into public.site_posts (author, kind, caption, audience) values (p_ann, 'post', 'tagged public', 'public');
  perform tests.assert_eq('the setup of tagged posts is in place', (select count(*) from public.site_posts where caption = 'tagged public')::int, 1);
  select id::text into txt from public.site_posts where caption = 'tagged public';
  insert into public.site_post_tags (post, venue_id) values (txt::uuid, va);
  insert into public.site_post_tags (post, event_id) values (txt::uuid, e_future);
  insert into public.site_posts (author, kind, caption, audience) values (p_ann, 'post', 'tagged followers', 'followers'), (p_ann, 'post', 'tagged removed', 'public');
  insert into public.site_posts (author, kind, caption, audience, expires_at) values (p_ann, 'story', 'tagged story', 'public', now() + interval '1 day');
  update public.site_posts set status = 'removed' where caption = 'tagged removed';
  insert into public.site_post_tags (post, venue_id) select id, va from public.site_posts where caption in ('tagged followers', 'tagged story', 'tagged removed');
  insert into public.site_posts (author, kind, caption, audience, created_at) values (p_ann, 'post', 'tagged old', 'public', now() - interval '20 days');
  insert into public.site_post_tags (post, venue_id) select id, va from public.site_posts where caption = 'tagged old';
  perform tests.login(eve, e_e); perform public.profile_save_personal('private'); perform tests.logout();
  insert into public.site_posts (author, kind, caption, audience) values (p_eve, 'post', 'tagged private author', 'public');
  insert into public.site_post_tags (post, venue_id) select id, va from public.site_posts where caption = 'tagged private author';
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, created_at)
    values (vb, t_a, slot, current_date - 25, 'Old', 'old@rev.example', 2, 10000, 'paid', now() - interval '20 days');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (vc, t_a, slot, current_date + 5, 'Draft Club Guest', 'dcg@rev.example', 2, 10000, 'paid');
  insert into public.site_venues (name, status, org_id) values ('Club D', 'published', org);
  insert into public.site_post_tags (post, event_id) select id, e_future from public.site_posts where caption = 'tagged followers';
  -- Club A: two paid bookings in the last 14 days (6) + two paid tickets to events there (2) + one public post (2) = 10. Club B: one paid booking (3).
  perform tests.assert_eq('the hottest venues, with their scores', public.explore_hot_venues(), jsonb_build_array(jsonb_build_object('id', va, 'score', 10), jsonb_build_object('id', vb, 'score', 3)));
  perform tests.assert_eq('a limit', jsonb_array_length(public.explore_hot_venues(1)), 1);
  perform tests.assert_eq('an unpublished venue is never listed', (public.explore_hot_venues()::text) like '%' || vc::text || '%', false);
  perform tests.login_anon();
  perform tests.assert_eq('visitors may ask', jsonb_array_length(public.explore_hot_venues()), 2);
  perform tests.assert_eq('...and see only an id and a score', (select string_agg(k, ',' order by k) from (select distinct jsonb_object_keys(e) k from jsonb_array_elements(public.explore_hot_venues()) e) x), 'id,score');
  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Draft Night', 'x', 'Club A', now() + interval '2 days', now() + interval '2 days 5 hours', 'draft', org);
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code)
    select e.id, t.id, 'Dee', d_e, 1, 1000, 'paid', 'DRAFT-1' from public.site_events e, public.site_ticket_tiers t where e.title = 'Draft Night' and t.event_id = e_future;
  -- Events: Next Friday starts within a week (3) + one paid ticket (2) + one public post (2) = 7; Far Away has one paid ticket (2).
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (e_far, 'GA', 1000, 10);
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code)
    select e_far, id, 'Dee', d_e, 1, 1000, 'paid', 'FAR-1' from public.site_ticket_tiers where event_id = e_far;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code)
    select e_far, id, 'Cy', c_e, 1, 1000, 'pending', 'FAR-PENDING' from public.site_ticket_tiers where event_id = e_far;
  -- (The shared fixtures hold one more upcoming event with sales of its own; it is left out of this comparison.)
  perform tests.assert_eq('the hottest events: upcoming only, with scores', (select jsonb_agg(e order by (e ->> 'score')::int desc) from jsonb_array_elements(public.explore_hot_events()) e where e ->> 'id' <> '00000000-0000-0000-0000-0000000000e1'),
    jsonb_build_array(jsonb_build_object('id', e_future, 'score', 7), jsonb_build_object('id', e_far, 'score', 2)));
  perform tests.assert_eq('...and the busiest comes first', public.explore_hot_events() -> 0 ->> 'id', '00000000-0000-0000-0000-0000000000e1');
  perform tests.assert_eq('a finished event is not listed', (public.explore_hot_events()::text) like '%' || e_past::text || '%', false);

  ---------------------------------------------------------------- professionals
  perform tests.q(ann, a_e, $q$public.profile_create_business('dj', 'DJ Ann', 'djann', null, 'Toronto')$q$);
  perform tests.q(bob, b_e, $q$public.profile_create_business('photographer', 'Bob Photo', 'bobphoto', null, 'Montreal')$q$);
  perform tests.q(cy, c_e, $q$public.profile_create_business('dj', 'Cy Spins', 'cyspins', null, 'Toronto')$q$);
  perform tests.q(dee, d_e, $q$public.profile_create_business('other', 'Dee Things', 'deethings', null, 'Toronto')$q$);
  select id into p_dj from public.site_profiles where handle = 'djann'; select id into p_photo from public.site_profiles where handle = 'bobphoto'; select id into p_other from public.site_profiles where handle = 'cyspins';
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_dj));
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, true)$q$, p_cy, p_dj));
  perform tests.q(dee, d_e, format($q$public.follow_set(%L, %L, true)$q$, p_dee, p_photo));
  perform tests.assert_eq('all professionals, best known first, then by name', tests.names(rando, r_e, format($q$public.explore_professionals(%L)$q$, (select id from public.site_profiles where user_id = rando))), 'djann,bobphoto,cyspins,deethings,nightcrew,othercrew');
  perform tests.assert_eq('a venue is not a professional', tests.names(rando, r_e, format($q$public.explore_professionals(%L)$q$, (select id from public.site_profiles where user_id = rando))) like '%club%', false);
  perform tests.assert_eq('by category', tests.names(rando, r_e, format($q$public.explore_professionals(%L, 'dj')$q$, (select id from public.site_profiles where user_id = rando))), 'djann,cyspins');
  perform tests.assert_eq('by city', tests.names(rando, r_e, format($q$public.explore_professionals(%L, null, 'mont')$q$, (select id from public.site_profiles where user_id = rando))), 'bobphoto');
  perform tests.assert_eq('by the start of a name or username', tests.names(rando, r_e, format($q$public.explore_professionals(%L, null, null, 'DJ')$q$, (select id from public.site_profiles where user_id = rando))), 'djann');
  perform tests.assert_eq('an underscore or percent sign is not a wildcard', tests.names(rando, r_e, format($q$public.explore_professionals(%L, null, null, '%%')$q$, (select id from public.site_profiles where user_id = rando))), '(none)');
  perform tests.assert_eq('venue is not a category to ask for', tests.q(rando, r_e, format($q$public.explore_professionals(%L, 'venue')$q$, (select id from public.site_profiles where user_id = rando))), 'ERROR: Choose a kind of professional from the list.');
  perform tests.assert_eq('a page', tests.names(rando, r_e, format($q$public.explore_professionals(%L, null, null, null, 2, 2)$q$, (select id from public.site_profiles where user_id = rando))), 'cyspins,deethings');
  perform tests.q(rando, r_e, format($q$public.block_set(%L, %L, true)$q$, (select id from public.site_profiles where user_id = rando), p_dj));
  perform tests.assert_eq('someone blocked is not in the directory for the one who blocked them', tests.names(rando, r_e, format($q$public.explore_professionals(%L, 'dj')$q$, (select id from public.site_profiles where user_id = rando))), 'cyspins');
  update public.site_profiles set status = 'suspended' where id = p_other;
  perform tests.assert_eq('...nor a suspended one', tests.names(rando, r_e, format($q$public.explore_professionals(%L, 'dj')$q$, (select id from public.site_profiles where user_id = rando))), '(none)');
  update public.site_profiles set status = 'active' where id = p_other;

  ---------------------------------------------------------------- the rest of the surface
  perform tests.login(bob, b_e);
  perform tests.assert_raises('the visit check cannot be called by the app', format($q$select public.review_visited('venue', %L)$q$, va), 'permission denied');
  perform tests.assert_raises('...nor the card builder', format($q$select public.review_card(%L, %L)$q$, p_bob, rv1::uuid), 'permission denied');
  perform tests.assert_raises('...nor the summary', format($q$select public.review_summary('venue', %L)$q$, va), 'permission denied');
  perform tests.assert_raises('...nor the reply check', format($q$select public.review_can_reply(%L, %L)$q$, p_bob, rv1::uuid), 'permission denied');
  perform tests.assert_raises('the reviews table cannot be read', $q$select * from public.site_reviews$q$, 'permission denied');
  perform tests.assert_raises('...nor the replies', $q$select * from public.site_review_replies$q$, 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read reviews', format($q$select public.reviews_list(%L, 'venue', %L)$q$, p_bob, va), 'permission denied');
  perform tests.assert_raises('...nor write one', format($q$select public.review_save(%L, 'venue', %L, 5)$q$, p_bob, va), 'permission denied');
  perform tests.assert_raises('...nor browse the directory', format($q$select public.explore_professionals(%L)$q$, p_bob), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- deleting
  delete from auth.users where id = ann;
  perform tests.assert_eq('deleting an account removes her reviews', (select count(*) from public.site_reviews where author = p_ann)::int, 0);
  perform tests.assert_eq('...and the replies to them', (select count(*) from public.site_review_replies r where not exists (select 1 from public.site_reviews x where x.id = r.review))::int, 0);
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Gone Soon', 'x', 'Somewhere', now() - interval '3 days', now() - interval '2 days', 'draft', org) returning id into e_far;
  insert into public.site_reviews (kind, event_id, author, rating) values ('event', e_far, p_bob, 3);
  delete from public.site_events where id = e_far;
  perform tests.assert_eq('deleting an event removes the reviews of it', (select count(*) from public.site_reviews where event_id = e_far)::int, 0);
  delete from public.site_table_bookings where venue_id = vc;
  delete from public.site_venues where id = vc;
  perform tests.assert_eq('deleting a venue goes through', (select count(*) from public.site_venues where id = vc)::int, 0);
end $$;

rollback;
