-- Splitting the bill. What matters most: only the person who booked can split (and only a confirmed booking with something left to pay); shares can never add up to more than what
-- is left; a friend sees the venue, the night, the host's first name and their own amount and nothing else; a payment is applied to the booking once however often Stripe says it;
-- anything that cannot be applied (the table was settled at the club in the meantime, the split was cancelled, the amount is not the share's) is paid back in full; cancelling a split,
-- cancelling the booking or deleting the host's account all end in a refund; nothing is open to clients except through the functions.
begin;

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
-- The same, as the website's service role.
create function tests.svc(p_expr text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login_service();
  execute 'select (' || p_expr || ')::text' into r;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.svcf(p_expr text, p_path text[]) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login_service();
  execute 'select (' || p_expr || ') #>> $1' into r using p_path;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  ann constant uuid := '00000000-0000-0000-0000-0000000008a1';   -- books the table, splits it
  bob constant uuid := '00000000-0000-0000-0000-0000000008a2';   -- friends
  cy constant uuid := '00000000-0000-0000-0000-0000000008a3';
  dee constant uuid := '00000000-0000-0000-0000-0000000008a4';
  eve constant uuid := '00000000-0000-0000-0000-0000000008a5';
  gus constant uuid := '00000000-0000-0000-0000-0000000008a6';   -- suspended
  olly constant uuid := '00000000-0000-0000-0000-0000000008a7';  -- owns the club
  ned constant uuid := '00000000-0000-0000-0000-0000000008a8';   -- nobody in particular
  hal constant uuid := '00000000-0000-0000-0000-0000000008a9';   -- a friend the hosts block
  a_e constant text := 'Ann@Split.example'; b_e constant text := 'bob@split.example'; c_e constant text := 'cy@split.example'; d_e constant text := 'dee@split.example';
  e_e constant text := 'eve@split.example'; g_e constant text := 'gus@split.example'; o_e constant text := 'olly@split.example'; n_e constant text := 'ned@split.example';
  h_e constant text := 'hal@split.example';
  p_ann uuid; p_bob uuid; p_cy uuid; p_dee uuid; p_eve uuid; p_gus uuid; p_olly uuid; p_club uuid; p_hal uuid; p_bob_dj uuid;
  bo5 uuid; bo6 uuid; bo7 uuid; bo8 uuid; bk6 uuid; sho5 uuid; sho6 uuid; sho7 uuid; so5 uuid; so6 uuid; so7 uuid; v_local timestamp; v_slot2 uuid;
  org uuid; va uuid; t_a uuid; slot uuid;
  bk uuid; bk_pend uuid; bk_full uuid; bk_bob uuid; bk_soon uuid; bk_past uuid; bk2 uuid; bk3 uuid;
  sp uuid; sp2 uuid; sh_bob uuid; sh_cy uuid; sh_dee uuid; sh_eve uuid;
  bo1 uuid; bo2 uuid; bo3 uuid; bo4 uuid; bk4 uuid; bk5 uuid; so1 uuid; so2 uuid; so3 uuid; so4 uuid; sho1 uuid; sho2 uuid; sho3 uuid; sho4 uuid; v_h numeric;
  v_cur text; v_deadline timestamptz := now() + interval '2 days';
  r text; n int;
begin
  insert into auth.users (id, email) values (ann, a_e), (bob, b_e), (cy, c_e), (dee, d_e), (eve, e_e), (gus, g_e), (olly, o_e), (ned, n_e), (hal, h_e);
  insert into public.profiles (id, name, email) values (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (cy, 'Cy Rus', c_e), (dee, 'Dee Dee', d_e), (eve, 'Eve Ng', e_e), (gus, 'Gus Gone', g_e), (olly, 'Olly Owner', o_e), (ned, 'Ned Nobody', n_e), (hal, 'Hal Hall', h_e);
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('social', true); perform tests.logout();
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bobsplit', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(cy, c_e); perform public.save_my_profile('Cy Rus', 'cysplit', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(dee, d_e); perform public.save_my_profile('Dee Dee', 'deesplit', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(eve, e_e); perform public.save_my_profile('Eve Ng', 'evesplit', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(gus, g_e); perform public.save_my_profile('Gus Gone', 'gussplit', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'annsplit', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(olly, o_e); perform public.save_my_profile('Olly Owner', 'ollysplit', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(hal, h_e); perform public.save_my_profile('Hal Hall', 'halsplit', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(bob, b_e); perform public.profile_create_business('dj', 'DJ Bob', 'djbobsplit');
  perform tests.logout();
  select id into p_hal from public.site_profiles where user_id = hal and kind = 'personal';
  select id into p_bob_dj from public.site_profiles where user_id = bob and kind = 'business';
  select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal'; select id into p_bob from public.site_profiles where user_id = bob and kind = 'personal';
  select id into p_cy from public.site_profiles where user_id = cy and kind = 'personal'; select id into p_dee from public.site_profiles where user_id = dee and kind = 'personal';
  select id into p_eve from public.site_profiles where user_id = eve and kind = 'personal'; select id into p_gus from public.site_profiles where user_id = gus and kind = 'personal';
  select id into p_olly from public.site_profiles where user_id = olly and kind = 'personal';
  update public.site_profiles set status = 'suspended' where id = p_gus;

  perform tests.login(olly, o_e);
  org := public.create_organization('Split Club Co', 'venue_owner');
  va := public.create_org_venue(org, 'Split Club');
  perform tests.logout();
  update public.site_venues set status = 'published' where id = va;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (va, 'Booth', 8, 0, 10000, 50) returning id into t_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (va, 5, '22:00') returning id into slot;
  perform tests.q(olly, o_e, format($q$public.profile_create_business('venue', 'Split Club', 'splitclub', null, null, null, %L)$q$, va));
  -- ann's table: 300.00 in all, 100.00 paid online, 200.00 left for the club
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ann', 'ANN@split.example', 6, 30000, 10000, 'paid', 'SPLIT-AAA') returning id into bk;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ann', a_e, 2, 10000, 'pending', 'SPLIT-PEND') returning id into bk_pend;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ann', a_e, 2, 20000, 20000, 'paid', 'SPLIT-FULL') returning id into bk_full;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Bob', b_e, 2, 20000, 5000, 'paid', 'SPLIT-BOB') returning id into bk_bob;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 1, 'Ann', a_e, 2, 20000, 5000, 'paid', 'SPLIT-SOON') returning id into bk_soon;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date - 3, 'Ann', a_e, 2, 20000, 5000, 'paid', 'SPLIT-PAST') returning id into bk_past;
  select currency into v_cur from public.site_table_bookings where id = bk;

  ---------------------------------------------------------------- the switch, and who may start
  perform tests.assert_eq('splitting is off at first', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":5000}]', p_bob), v_deadline)), 'ERROR: Splitting the bill is not open yet.');
  perform tests.assert_eq('...and so is looking at a friend''s requests', tests.q(bob, b_e, 'public.split_my_shares()'), 'ERROR: Splitting the bill is not open yet.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('split_payments', true); perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot split', format($q$select public.split_create(%L, '[]'::jsonb, now())$q$, bk), 'permission denied');
  perform tests.assert_raises('a visitor cannot read a friend''s requests', $q$select public.split_my_shares()$q$, 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('someone else''s booking', tests.q(bob, b_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":5000}]', p_cy), v_deadline)), 'ERROR: This booking is not yours.');
  perform tests.assert_eq('a booking that does not exist says the same', tests.q(ann, a_e, format($q$public.split_create(%L, '[]'::jsonb, %L)$q$, gen_random_uuid(), v_deadline)), 'ERROR: This booking is not yours.');
  perform tests.assert_eq('a booking still awaiting payment', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk_pend, format('[{"payer":"%s","amount_cents":5000}]', p_bob), v_deadline)), 'ERROR: Only a confirmed booking can be split.');
  perform tests.assert_eq('a table that is paid in full has nothing to split', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk_full, format('[{"payer":"%s","amount_cents":5000}]', p_bob), v_deadline)), 'ERROR: Nothing is left to pay on this booking.');
  perform tests.assert_eq('a night that is over', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk_past, format('[{"payer":"%s","amount_cents":5000}]', p_bob), v_deadline)), 'ERROR: This booking is over.');

  ---------------------------------------------------------------- the deadline
  perform tests.assert_eq('no deadline', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, null)$q$, bk, format('[{"payer":"%s","amount_cents":5000}]', p_bob))), 'ERROR: Choose a deadline at least an hour from now.');
  perform tests.assert_eq('a deadline in half an hour', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":5000}]', p_bob), now() + interval '30 minutes')), 'ERROR: Choose a deadline at least an hour from now.');
  perform tests.assert_eq('a deadline a month away', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":5000}]', p_bob), now() + interval '30 days')), 'ERROR: Choose a deadline within 14 days.');
  perform tests.assert_eq('a deadline long after the night', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk_soon, format('[{"payer":"%s","amount_cents":5000}]', p_bob), now() + interval '13 days')), 'ERROR: The deadline cannot be after the booking is over.');

  ---------------------------------------------------------------- the shares
  perform tests.assert_eq('no friends', tests.q(ann, a_e, format($q$public.split_create(%L, '[]'::jsonb, %L)$q$, bk, v_deadline)), 'ERROR: Choose at least one friend.');
  perform tests.assert_eq('not a list', tests.q(ann, a_e, format($q$public.split_create(%L, '{"payer":"x"}'::jsonb, %L)$q$, bk, v_deadline)), 'ERROR: Choose at least one friend.');
  perform tests.assert_eq('too many friends', tests.q(ann, a_e, format($q$public.split_create(%L, (select jsonb_agg(jsonb_build_object('payer', %L, 'amount_cents', 500)) from generate_series(1, 21)), %L)$q$, bk, p_bob, v_deadline)), 'ERROR: A split can have up to 20 friends.');
  perform tests.assert_eq('a share with no friend', tests.q(ann, a_e, format($q$public.split_create(%L, '[{"amount_cents":5000}]'::jsonb, %L)$q$, bk, v_deadline)), 'ERROR: Each share needs a friend and an amount.');
  perform tests.assert_eq('a share with no amount', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s"}]', p_bob), v_deadline)), 'ERROR: Each share needs a friend and an amount.');
  perform tests.assert_eq('an amount that is text', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":"5000"}]', p_bob), v_deadline)), 'ERROR: Each share needs a friend and an amount.');
  perform tests.assert_eq('an amount with a fraction of a cent', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":5000.5}]', p_bob), v_deadline)), 'ERROR: Each amount must be a whole number of cents.');
  perform tests.assert_eq('a negative amount', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":-100}]', p_bob), v_deadline)), 'ERROR: Each amount must be a whole number of cents.');
  perform tests.assert_eq('under five dollars', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":499}]', p_bob), v_deadline)), 'ERROR: The smallest share is 5.00.');
  perform tests.assert_eq('exactly five dollars is fine to ask for (the failure below is the total)', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":500},{"payer":"%s","amount_cents":500001}]', p_bob, p_cy), v_deadline)), 'ERROR: The largest share is 5,000.00.');
  perform tests.assert_eq('the same friend twice', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":1000},{"payer":"%s","amount_cents":1000}]', p_bob, p_bob), v_deadline)), 'ERROR: Each friend can be asked once.');
  perform tests.assert_eq('a profile that does not exist', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":1000}]', gen_random_uuid()), v_deadline)), 'ERROR: One of the people you chose is not available.');
  perform tests.assert_eq('a suspended person', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":1000}]', p_gus), v_deadline)), 'ERROR: One of the people you chose is not available.');
  perform tests.assert_eq('a venue''s profile is not a person', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":1000}]', (select s.id from public.site_profiles s where s.venue_id = va)), v_deadline)), 'ERROR: One of the people you chose is not available.');
  perform tests.assert_eq('the host herself', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":1000}]', p_ann), v_deadline)), 'ERROR: You do not need to ask yourself: your part is what is left at the club.');
  perform tests.login(eve, e_e); perform public.block_set(p_eve, p_ann, true); perform tests.logout();
  perform tests.assert_eq('someone who blocked the host', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":1000}]', p_eve), v_deadline)), 'ERROR: One of the people you chose is not available.');
  perform tests.assert_eq('a business profile is not a person to ask', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":1000}]', p_bob_dj), v_deadline)), 'ERROR: One of the people you chose is not available.');
  perform tests.login(ann, a_e); perform public.block_set(p_ann, p_hal, true); perform tests.logout();
  perform tests.assert_eq('someone the host blocked', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":1000}]', p_hal), v_deadline)), 'ERROR: One of the people you chose is not available.');
  perform tests.assert_eq('...nothing was left behind by the refusals', (select count(*) from public.site_splits where booking_id = bk)::int, 0);
  perform tests.assert_eq('more than what is left (200.00 is left)', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":15000},{"payer":"%s","amount_cents":5001}]', p_bob, p_cy), v_deadline)),
    format('ERROR: The shares add up to more than what is left to pay on this booking (%s 200.00).', upper(v_cur)));
  perform tests.assert_eq('...and still nothing was left behind', (select count(*) from public.site_splits where booking_id = bk)::int + (select count(*) from public.site_split_shares)::int, 0);

  ---------------------------------------------------------------- a split
  sp := (tests.f(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":5000},{"payer":"%s","amount_cents":5000},{"payer":"%s","amount_cents":3000}]', p_bob, p_cy, p_dee), v_deadline), '{id}'))::uuid;
  perform tests.assert_true('it was made', sp is not null);
  perform tests.assert_eq('...with the deadline the host chose', (tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{deadline}'))::timestamptz, v_deadline);
  perform tests.assert_eq('the host''s view: open', tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{state}'), 'open');
  perform tests.assert_eq('...with 130.00 outstanding and nothing collected', tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{outstanding_cents}') || '/' || tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{collected_cents}'), '13000/0');
  perform tests.assert_eq('...and the balance still 200.00', tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{balance_cents}'), '20000');
  perform tests.assert_eq('...three shares, none paid', (select string_agg(x ->> 'status', ',') from jsonb_array_elements(tests.q(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk))::jsonb -> 'shares') x), 'unpaid,unpaid,unpaid');
  perform tests.assert_eq('only the host sees the split', tests.q(bob, b_e, format($q$public.split_for_booking(%L)$q$, bk)), 'ERROR: This booking is not yours.');
  perform tests.assert_eq('a booking with no split gives nothing', tests.q(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk_soon)), '(null)');
  perform tests.assert_eq('a second split while one is open', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":1000}]', p_eve), v_deadline)), 'ERROR: This booking already has a split: cancel it before making a new one.');
  select s.id into sh_bob from public.site_split_shares s where s.split_id = sp and s.payer = p_bob;
  select s.id into sh_cy from public.site_split_shares s where s.split_id = sp and s.payer = p_cy;
  select s.id into sh_dee from public.site_split_shares s where s.split_id = sp and s.payer = p_dee;

  ---------------------------------------------------------------- what a friend sees
  perform tests.assert_eq('bob has one request', tests.q(bob, b_e, 'jsonb_array_length(public.split_my_shares())'), '1');
  perform tests.assert_eq('...from Ann, at the club, for 50.00, unpaid', tests.f(bob, b_e, 'public.split_my_shares() -> 0', '{host}') || '/' || tests.f(bob, b_e, 'public.split_my_shares() -> 0', '{venue}') || '/' || tests.f(bob, b_e, 'public.split_my_shares() -> 0', '{amount_cents}') || '/' || tests.f(bob, b_e, 'public.split_my_shares() -> 0', '{state}'), 'Ann/Split Club/5000/unpaid');
  perform tests.assert_eq('...and only those fields: no code, no total, no other shares', (select string_agg(k, ',' order by k) from jsonb_object_keys(tests.q(bob, b_e, 'public.split_my_shares() -> 0')::jsonb) k), 'amount_cents,booking_date,currency,deadline,host,id,paid_at,start_time,state,venue');
  perform tests.assert_eq('someone not asked sees nothing', tests.q(ned, n_e, 'public.split_my_shares()'), '[]');
  perform tests.assert_eq('...and cannot ask about a share', tests.q(ned, n_e, format($q$public.split_share_status(%L)$q$, sh_bob)), 'ERROR: This request is not available.');
  perform tests.assert_eq('...nor can another friend', tests.q(cy, c_e, format($q$public.split_share_status(%L)$q$, sh_bob)), 'ERROR: This request is not available.');
  perform tests.assert_eq('...nor turn it down for him', tests.q(ned, n_e, format($q$public.split_share_decline(%L)$q$, sh_bob)), 'ERROR: This request is not available.');
  perform tests.assert_eq('bob can', tests.f(bob, b_e, format($q$public.split_share_status(%L)$q$, sh_bob), '{state}'), 'unpaid');
  perform tests.assert_eq('begin says what to charge', tests.f(bob, b_e, format($q$public.split_share_begin(%L)$q$, sh_bob), '{amount_cents}') || '/' || tests.f(bob, b_e, format($q$public.split_share_begin(%L)$q$, sh_bob), '{venue}'), '5000/Split Club');
  perform tests.assert_eq('...and not for someone else''s share', tests.q(cy, c_e, format($q$public.split_share_begin(%L)$q$, sh_bob)), 'ERROR: This request is not available.');

  ---------------------------------------------------------------- the website's functions are the website's alone
  perform tests.login(bob, b_e);
  perform tests.assert_raises('a signed-in person cannot attach a payment', format($q$select public.split_share_attach(%L, 'cs_x', now())$q$, sh_bob), 'permission denied');
  perform tests.assert_raises('...nor say a payment arrived', $q$select public.split_share_paid('cs_x', 'pi_x', 5000)$q$, 'permission denied');
  perform tests.assert_raises('...nor list refunds', $q$select * from public.split_refunds_due()$q$, 'permission denied');
  perform tests.assert_raises('...nor record one', format($q$select public.split_share_refunded(%L, 're_x', 100)$q$, sh_bob), 'permission denied');
  perform tests.assert_raises('...nor read the tables', $q$select * from public.site_split_shares$q$, 'permission denied');
  perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the tables', $q$select * from public.site_splits$q$, 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- paying
  perform tests.assert_eq('attach a payment page for bob', tests.svc(format($q$public.split_share_attach(%L, 'cs_bob', now() + interval '31 minutes')$q$, sh_bob)), '');
  perform tests.assert_eq('...it is pending now', tests.f(bob, b_e, format($q$public.split_share_status(%L)$q$, sh_bob), '{state}'), 'pending');
  perform tests.assert_eq('...and asking to pay again hands back the same page', tests.f(bob, b_e, format($q$public.split_share_begin(%L)$q$, sh_bob), '{pending_session}'), 'cs_bob');
  perform tests.assert_eq('a different share cannot reuse the session id', tests.svc(format($q$public.split_share_attach(%L, 'cs_bob', now() + interval '31 minutes')$q$, sh_cy)), 'ERROR: duplicate key value violates unique constraint "site_split_shares_stripe_session_id_key"');
  update public.site_split_shares set pending_until = now() - interval '1 minute' where id = sh_bob;
  perform tests.assert_eq('a payment page that lapsed leaves the share unpaid and payable again', tests.f(bob, b_e, format($q$public.split_share_status(%L)$q$, sh_bob), '{state}') || '/' || coalesce(tests.f(bob, b_e, format($q$public.split_share_begin(%L)$q$, sh_bob), '{pending_session}'), 'x'), 'unpaid/(null)');
  update public.site_split_shares set pending_until = now() + interval '20 minutes' where id = sh_bob;
  perform tests.assert_eq('a session nobody knows', tests.svcf($q$public.split_share_paid('cs_nobody', 'pi_n', 5000)$q$, '{result}'), 'unknown');
  r := tests.svc($q$public.split_share_paid('cs_bob', 'pi_bob', 5000)$q$);
  perform tests.assert_eq('bob pays 50.00: it counts, all of it, with nothing to pay back', (r::jsonb ->> 'result') || '/' || (r::jsonb ->> 'applied_cents') || '/' || (r::jsonb ->> 'refund_cents'), 'applied/5000/0');
  perform tests.assert_eq('...the booking has been paid 150.00 now', (select amount_paid_cents from public.site_table_bookings where id = bk), 15000);
  perform tests.assert_eq('...his share is paid', tests.f(bob, b_e, format($q$public.split_share_status(%L)$q$, sh_bob), '{state}'), 'paid');
  perform tests.assert_eq('...the host sees 50.00 collected and 80.00 outstanding', tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{collected_cents}') || '/' || tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{outstanding_cents}') || '/' || tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{balance_cents}'), '5000/8000/15000');
  r := tests.svcf($q$public.split_share_paid('cs_bob', 'pi_bob', 5000)$q$, '{result}');
  perform tests.assert_eq('Stripe saying it again changes nothing', r || '/' || (select amount_paid_cents from public.site_table_bookings where id = bk), 'already/15000');
  perform tests.assert_eq('a share that is paid cannot be paid again', tests.q(bob, b_e, format($q$public.split_share_begin(%L)$q$, sh_bob)), 'ERROR: You already paid this.');
  perform tests.assert_eq('...nor turned down', tests.q(bob, b_e, format($q$public.split_share_decline(%L)$q$, sh_bob)), 'ERROR: This request can no longer be turned down.');
  perform tests.assert_eq('nothing is due back', (select count(*) from public.site_split_shares where refund_due_cents > 0)::int, 0);

  ---------------------------------------------------------------- what cannot be applied is paid back
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_cy', now() + interval '31 minutes')$q$, sh_cy));
  r := tests.svcf($q$public.split_share_paid('cs_cy', 'pi_cy', 4000)$q$, '{result}');
  perform tests.assert_eq('cy is charged an amount that is not her share: all of it is to be paid back, none applied', r || '/' || (select amount_paid_cents from public.site_table_bookings where id = bk) || '/' || (select refund_due_cents from public.site_split_shares where id = sh_cy), 'refund/15000/4000');
  perform tests.assert_eq('...it shows as being paid back', tests.f(cy, c_e, format($q$public.split_share_status(%L)$q$, sh_cy), '{state}'), 'refunding');
  perform tests.assert_eq('...and is on the list of refunds', tests.svc($q$(select string_agg(r.cents::text || '@' || r.stripe_payment_intent_id, ',') from public.split_refunds_due() r)$q$), '4000@pi_cy');
  r := tests.svcf(format($q$public.split_share_refunded(%L, 're_cy', 4000)$q$, sh_cy), '{result}');
  perform tests.assert_eq('the refund is recorded once per Stripe refund', r || '/' || tests.svcf(format($q$public.split_share_refunded(%L, 're_cy', 4000)$q$, sh_cy), '{result}'), 'refunded/already');
  perform tests.assert_eq('...nothing was taken off the booking (nothing had been put on)', (select amount_paid_cents from public.site_table_bookings where id = bk), 15000);
  perform tests.assert_eq('...cy sees it was paid back', tests.f(cy, c_e, format($q$public.split_share_status(%L)$q$, sh_cy), '{state}'), 'refunded');
  perform tests.assert_eq('...and the list is empty again', tests.svc($q$(select count(*) from public.split_refunds_due())$q$), '0');

  -- the table is settled at the club while dee's page is open: only 20.00 is left, her share is 30.00
  update public.site_table_bookings set amount_paid_cents = 28000 where id = bk;
  perform tests.assert_eq('dee cannot start paying a share bigger than what is left', tests.q(dee, d_e, format($q$public.split_share_begin(%L)$q$, sh_dee)), 'ERROR: The rest of this table has been paid in the meantime, so there is nothing left for you to pay.');
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_dee', now() + interval '31 minutes')$q$, sh_dee));
  r := tests.svc($q$public.split_share_paid('cs_dee', 'pi_dee', 3000)$q$);
  perform tests.assert_eq('but if she already paid on the open page, the answer says 20.00 is applied and 10.00 is to be paid back', (r::jsonb ->> 'result') || '/' || (r::jsonb ->> 'applied_cents') || '/' || (r::jsonb ->> 'refund_cents'), 'applied/2000/1000');
  perform tests.assert_eq('...the booking is full, her share kept 20.00 and 10.00 is due back', (select amount_paid_cents from public.site_table_bookings where id = bk) || '/' || (select applied_cents from public.site_split_shares where id = sh_dee) || '/' || (select refund_due_cents from public.site_split_shares where id = sh_dee), '30000/2000/1000');
  perform tests.assert_eq('...the booking is never paid beyond its total', (select amount_paid_cents <= amount_total_cents from public.site_table_bookings where id = bk), true);
  r := tests.svcf(format($q$public.split_share_refunded(%L, 're_dee', 1000)$q$, sh_dee), '{refunded_cents}');
  perform tests.assert_eq('...the surplus is paid back, and nothing comes off the booking for it', r || '/' || (select amount_paid_cents from public.site_table_bookings where id = bk), '1000/30000');

  ---------------------------------------------------------------- the host cancels
  perform tests.assert_eq('a stranger cannot cancel', tests.q(ned, n_e, format($q$public.split_cancel(%L)$q$, sp)), 'ERROR: This split is not available.');
  perform tests.assert_eq('a friend cannot cancel', tests.q(bob, b_e, format($q$public.split_cancel(%L)$q$, sp)), 'ERROR: This split is not available.');
  perform tests.assert_eq('the host cancels', tests.f(ann, a_e, format($q$public.split_cancel(%L)$q$, sp), '{state}'), 'cancelled');
  perform tests.assert_eq('...bob and dee, who paid, are to be paid back in full (cy was already)', (select refund_due_cents from public.site_split_shares where id = sh_bob) || '/' || (select refund_due_cents from public.site_split_shares where id = sh_dee) || '/' || (select refund_due_cents from public.site_split_shares where id = sh_cy), '5000/3000/4000');
  perform tests.assert_eq('...they can see it is on its way', tests.f(bob, b_e, format($q$public.split_share_status(%L)$q$, sh_bob), '{state}'), 'refunding');
  perform tests.assert_eq('cancelling twice', tests.q(ann, a_e, format($q$public.split_cancel(%L)$q$, sp)), 'ERROR: This split is already cancelled.');
  perform tests.assert_eq('the refunds due are bob''s 50.00 and dee''s 20.00 (she was paid 10.00 back already)', tests.svc($q$(select string_agg(r.cents::text, ',' order by r.cents desc) from public.split_refunds_due() r)$q$), '5000,2000');
  r := tests.svcf(format($q$public.split_share_refunded(%L, 're_bob', 5000)$q$, sh_bob), '{taken_off_booking_cents}');
  perform tests.assert_eq('bob''s refund comes off the booking: 300.00 less 50.00', r || '/' || (select amount_paid_cents from public.site_table_bookings where id = bk), '5000/25000');
  perform tests.assert_eq('a refund of a different size than due only takes what is due', tests.svcf(format($q$public.split_share_refunded(%L, 're_dee2', 9999)$q$, sh_dee), '{refunded_cents}'), '3000');
  perform tests.assert_eq('...and a refund that is not due does nothing', tests.svcf(format($q$public.split_share_refunded(%L, 're_dee3', 100)$q$, sh_dee), '{result}'), 'nothing_due');
  perform tests.assert_eq('...everyone has been paid back, so the 70.00 the shares had covered is owed at the club again', (select amount_total_cents - amount_paid_cents from public.site_table_bookings where id = bk), 7000);
  perform tests.assert_eq('...and the cancelled split shows nothing collected any more', tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{collected_cents}'), '0');
  perform tests.assert_eq('a refund id and an amount are needed', tests.svc(format($q$public.split_share_refunded(%L, '', 100)$q$, sh_dee)), 'ERROR: a refund id and an amount are needed');
  perform tests.assert_eq('the host can make a new split now', tests.f(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk, format('[{"payer":"%s","amount_cents":5000}]', p_bob), v_deadline), '{state}'), 'open');
  perform tests.assert_eq('...and the history shows the new one first', tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk), '{state}'), 'open');

  ---------------------------------------------------------------- the booking itself is cancelled by the venue
  select s.id into sp2 from public.site_splits s where s.booking_id = bk and s.status = 'open';
  select s.id into sh_bob from public.site_split_shares s where s.split_id = sp2;
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_bob2', now() + interval '31 minutes')$q$, sh_bob));
  perform tests.svc($q$public.split_share_paid('cs_bob2', 'pi_bob2', 5000)$q$);
  perform tests.assert_eq('bob paid again, on the new split: 230.00 + 50.00', (select amount_paid_cents from public.site_table_bookings where id = bk), 28000);
  update public.site_table_bookings set status = 'cancelled' where id = bk;
  perform tests.assert_eq('the venue cancels the booking: bob''s request reads as cancelled money coming back', tests.f(bob, b_e, format($q$public.split_share_status(%L)$q$, sh_bob), '{state}'), 'paid');
  perform tests.assert_eq('...the next look at refunds marks it due', tests.svc($q$(select string_agg(r.cents::text, ',') from public.split_refunds_due() r)$q$), '5000');
  perform tests.assert_eq('...bob sees it is being paid back', tests.f(bob, b_e, format($q$public.split_share_status(%L)$q$, sh_bob), '{state}'), 'refunding');
  r := tests.svcf(format($q$public.split_share_refunded(%L, 're_bob2', 5000)$q$, sh_bob), '{taken_off_booking_cents}');
  perform tests.assert_eq('...paying it back leaves a cancelled booking''s numbers alone', r || '/' || (select amount_paid_cents from public.site_table_bookings where id = bk), '0/28000');
  perform tests.assert_eq('a cancelled booking''s split cannot be started or cancelled by a payment', tests.q(bob, b_e, format($q$public.split_share_begin(%L)$q$, sh_bob)), 'ERROR: You already paid this.');

  ---------------------------------------------------------------- a payment that arrives after the split ended
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ann', a_e, 2, 20000, 5000, 'paid', 'SPLIT-TWO') returning id into bk2;
  sp := (tests.f(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk2, format('[{"payer":"%s","amount_cents":4000},{"payer":"%s","amount_cents":4000}]', p_bob, p_cy), v_deadline), '{id}'))::uuid;
  select s.id into sh_bob from public.site_split_shares s where s.split_id = sp and s.payer = p_bob;
  select s.id into sh_cy from public.site_split_shares s where s.split_id = sp and s.payer = p_cy;
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_late', now() + interval '31 minutes')$q$, sh_bob));
  perform tests.f(ann, a_e, format($q$public.split_cancel(%L)$q$, sp), '{state}');
  perform tests.assert_eq('cancelling releases every request nobody paid, the one with a page open as well', (select string_agg(status, ',' order by status) from public.site_split_shares where split_id = sp), 'void,void');
  perform tests.assert_eq('the host cancelled while bob''s page was open: bob''s request is cancelled', tests.f(bob, b_e, format($q$public.split_share_status(%L)$q$, sh_bob), '{state}'), 'cancelled');
  r := tests.svcf($q$public.split_share_paid('cs_late', 'pi_late', 4000)$q$, '{result}');
  perform tests.assert_eq('...if he pays anyway, all of it is to be paid back and nothing is applied', r || '/' || (select amount_paid_cents from public.site_table_bookings where id = bk2) || '/' || (select refund_due_cents from public.site_split_shares where id = sh_bob), 'refund/5000/4000');
  perform tests.assert_eq('...and cannot start a payment on a cancelled request', tests.q(cy, c_e, format($q$public.split_share_begin(%L)$q$, sh_cy)), 'ERROR: This request was cancelled.');
  perform tests.assert_eq('...and a cancelled request can no longer be turned down', tests.q(cy, c_e, format($q$public.split_share_decline(%L)$q$, sh_cy)), 'ERROR: This request can no longer be turned down.');

  ---------------------------------------------------------------- declining, the deadline, blocking
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ann', a_e, 2, 20000, 0, 'paid', 'SPLIT-THREE') returning id into bk3;
  sp := (tests.f(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk3, format('[{"payer":"%s","amount_cents":3000},{"payer":"%s","amount_cents":3000},{"payer":"%s","amount_cents":3000}]', p_bob, p_cy, p_dee), v_deadline), '{id}'))::uuid;
  select s.id into sh_bob from public.site_split_shares s where s.split_id = sp and s.payer = p_bob;
  select s.id into sh_cy from public.site_split_shares s where s.split_id = sp and s.payer = p_cy;
  select s.id into sh_dee from public.site_split_shares s where s.split_id = sp and s.payer = p_dee;
  perform tests.assert_eq('bob turns his down', tests.f(bob, b_e, format($q$public.split_share_decline(%L)$q$, sh_bob), '{state}'), 'declined');
  perform tests.assert_eq('...he cannot pay it after that', tests.q(bob, b_e, format($q$public.split_share_begin(%L)$q$, sh_bob)), 'ERROR: You turned this request down.');
  perform tests.assert_eq('...the host sees it declined and the other two waiting', (select string_agg(x ->> 'status', ',' order by x ->> 'status') from jsonb_array_elements(tests.q(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk3))::jsonb -> 'shares') x), 'declined,unpaid,unpaid');
  update public.site_splits set deadline = now() - interval '1 minute' where id = sp;
  perform tests.assert_eq('after the deadline cy''s request has lapsed', tests.f(cy, c_e, format($q$public.split_share_status(%L)$q$, sh_cy), '{state}'), 'expired');
  perform tests.assert_eq('...she cannot pay it', tests.q(cy, c_e, format($q$public.split_share_begin(%L)$q$, sh_cy)), 'ERROR: The time to pay this has passed. Ask the host to send a new request.');
  perform tests.assert_eq('...the host sees the split as expired, with nothing outstanding', tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk3), '{state}') || '/' || tests.f(ann, a_e, format($q$public.split_for_booking(%L)$q$, bk3), '{outstanding_cents}'), 'expired/0');
  perform tests.assert_eq('...and a lapsed request can be turned down to tidy the list', tests.f(cy, c_e, format($q$public.split_share_decline(%L)$q$, sh_cy), '{state}'), 'declined');
  update public.site_splits set deadline = now() + interval '2 days' where id = sp;
  perform tests.login(dee, d_e); perform public.block_set(p_dee, p_ann, true); perform tests.logout();
  perform tests.assert_eq('dee blocks Ann: the request disappears from her list', tests.q(dee, d_e, 'public.split_my_shares()'), '[]');
  perform tests.assert_eq('...and cannot be paid', tests.q(dee, d_e, format($q$public.split_share_begin(%L)$q$, sh_dee)), 'ERROR: This request is not available.');

  ---------------------------------------------------------------- a refund being looked at
  insert into public.site_refund_requests (booking_id, venue_id, requested_by_kind, requested_by, reason) values (bk_soon, va, 'guest', ann, 'we cannot come');
  perform tests.assert_eq('a booking with a refund request open cannot be split', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk_soon, format('[{"payer":"%s","amount_cents":1000}]', p_cy), now() + interval '2 hours')), 'ERROR: A refund is being looked at on this booking, so it cannot be split now.');
  update public.site_refund_requests set status = 'approved', decided_at = now(), approved_cents = 1000, method = 'online' where booking_id = bk_soon;
  perform tests.assert_eq('...an approved one as well', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk_soon, format('[{"payer":"%s","amount_cents":1000}]', p_cy), now() + interval '2 hours')), 'ERROR: A refund is being looked at on this booking, so it cannot be split now.');
  update public.site_refund_requests set status = 'processing' where booking_id = bk_soon;
  perform tests.assert_eq('...and one being paid out', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk_soon, format('[{"payer":"%s","amount_cents":1000}]', p_cy), now() + interval '2 hours')), 'ERROR: A refund is being looked at on this booking, so it cannot be split now.');

  ---------------------------------------------------------------- the edges of each rule, with a second host (olly)
  -- three of olly's tables owe 200.00 each: one for a night far away, one for tomorrow night, one for the usual night; a fourth is used last
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 20, 'Olly', 'OLLY@split.example', 2, 20000, 0, 'paid', 'SPLIT-O1') returning id into bo1;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 1, 'Olly', o_e, 2, 20000, 0, 'paid', 'SPLIT-O2') returning id into bo2;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Olly', o_e, 2, 20000, 0, 'paid', 'SPLIT-O3') returning id into bo3;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Olly', o_e, 2, 20000, 0, 'paid', 'SPLIT-O4') returning id into bo4;
  perform tests.assert_eq('a deadline a day too far', tests.q(olly, o_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo1, format('[{"payer":"%s","amount_cents":1000}]', p_bob), now() + interval '14 days 1 hour')), 'ERROR: Choose a deadline within 14 days.');
  perform tests.assert_eq('one cent over what is left', tests.q(olly, o_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo1, format('[{"payer":"%s","amount_cents":10000},{"payer":"%s","amount_cents":10001}]', p_bob, p_dee), now() + interval '13 days')),
    format('ERROR: The shares add up to more than what is left to pay on this booking (%s 200.00).', upper(v_cur)));
  perform tests.assert_eq('the largest share is allowed by the rules on size (the total is what stops it)', tests.q(olly, o_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo3, format('[{"payer":"%s","amount_cents":500000}]', p_bob), v_deadline)),
    format('ERROR: The shares add up to more than what is left to pay on this booking (%s 200.00).', upper(v_cur)));
  perform tests.assert_eq('twenty friends is the most (the same one twenty times is the refusal here)', tests.q(olly, o_e, format($q$public.split_create(%L, (select jsonb_agg(jsonb_build_object('payer', %L, 'amount_cents', 500)) from generate_series(1, 20)), %L)$q$, bo3, p_bob, v_deadline)), 'ERROR: Each friend can be asked once.');
  so1 := (tests.f(olly, o_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo1, format('[{"payer":"%s","amount_cents":10000},{"payer":"%s","amount_cents":10000}]', p_bob, p_dee), now() + interval '13 days 23 hours'), '{id}'))::uuid;
  perform tests.assert_true('the whole balance, to the cent, and a deadline just under 14 days are allowed', so1 is not null);
  select s.id into sho1 from public.site_split_shares s where s.split_id = so1 and s.payer = p_bob;
  update public.site_table_bookings set booking_date = current_date - 3 where id = bo1;
  perform tests.assert_eq('once the night is over the split cannot be cancelled here', tests.q(olly, o_e, format($q$public.split_cancel(%L)$q$, so1)), 'ERROR: This booking is over, so the split can no longer be cancelled here. Ask the venue.');
  perform tests.assert_eq('a recent share is on the friend''s list', tests.q(bob, b_e, format($q$(select count(*) from jsonb_array_elements(public.split_my_shares()) x where x ->> 'id' = %L)$q$, sho1)), '1');
  update public.site_split_shares set created_at = now() - interval '61 days' where id = sho1;
  perform tests.assert_eq('...one older than 60 days drops off it', tests.q(bob, b_e, format($q$(select count(*) from jsonb_array_elements(public.split_my_shares()) x where x ->> 'id' = %L)$q$, sho1)), '0');
  update public.site_split_shares set created_at = now() - interval '59 days' where id = sho1;
  perform tests.assert_eq('...and one from 59 days ago is still there', tests.q(bob, b_e, format($q$(select count(*) from jsonb_array_elements(public.split_my_shares()) x where x ->> 'id' = %L)$q$, sho1)), '1');

  -- the last hour before the booking is over
  v_h := public.booking_hours_to_arrival(bo2);
  perform tests.assert_eq('a deadline half an hour after the booking is over', tests.q(olly, o_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo2, format('[{"payer":"%s","amount_cents":3000}]', p_dee), now() + make_interval(secs => (v_h + 12.5) * 3600))), 'ERROR: The deadline cannot be after the booking is over.');
  so2 := (tests.f(olly, o_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo2, format('[{"payer":"%s","amount_cents":3000}]', p_dee), now() + make_interval(secs => (v_h + 11.5) * 3600)), '{id}'))::uuid;
  perform tests.assert_true('...and half an hour before it is over is fine', so2 is not null);
  select s.id into sho2 from public.site_split_shares s where s.split_id = so2;
  update public.site_table_bookings set amount_paid_cents = 17000 where id = bo2;
  perform tests.assert_eq('dee can pay when exactly her share is left', tests.f(dee, d_e, format($q$public.split_share_begin(%L)$q$, sho2), '{amount_cents}'), '3000');
  update public.site_table_bookings set amount_paid_cents = 17001 where id = bo2;
  perform tests.assert_eq('...and cannot when a cent less is', tests.q(dee, d_e, format($q$public.split_share_begin(%L)$q$, sho2)), 'ERROR: The rest of this table has been paid in the meantime, so there is nothing left for you to pay.');
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_o2', now() + interval '31 minutes')$q$, sho2));
  perform tests.assert_eq('an amount of nothing is not a payment', tests.svc($q$public.split_share_paid('cs_o2', 'pi_o2', 0)$q$), 'ERROR: an amount is needed');
  update public.site_table_bookings set status = 'cancelled' where id = bo2;
  perform tests.assert_eq('the venue cancels the booking while dee''s page is open: her request reads as cancelled', tests.f(dee, d_e, format($q$public.split_share_status(%L)$q$, sho2), '{state}'), 'cancelled');
  perform tests.assert_eq('...and she cannot start another payment', tests.q(dee, d_e, format($q$public.split_share_begin(%L)$q$, sho2)), 'ERROR: This request was cancelled.');
  perform tests.assert_eq('a payment that arrives after the venue cancelled the booking is not applied', tests.svcf($q$public.split_share_paid('cs_o2', 'pi_o2', 3000)$q$, '{result}'), 'refund');
  perform tests.assert_eq('...and the booking''s numbers did not move', (select amount_paid_cents from public.site_table_bookings where id = bo2), 17001);
  perform tests.assert_eq('a share that is paid cannot have a payment page attached', tests.svc(format($q$public.split_share_attach(%L, 'cs_again', now() + interval '31 minutes')$q$, sho2)), 'ERROR: this share cannot be paid now');
  perform tests.assert_eq('...and a payment page needs a session', tests.svc(format($q$public.split_share_attach(%L, ' ', now() + interval '31 minutes')$q$, sho2)), 'ERROR: a Stripe session is needed');

  -- a split everyone has paid is complete; a fifth of the minimum is the smallest share
  so3 := (tests.f(olly, o_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo3, format('[{"payer":"%s","amount_cents":500}]', p_bob), now() + interval '61 minutes'), '{id}'))::uuid;
  perform tests.assert_true('an hour and a minute is enough notice, and 5.00 is a share', so3 is not null);
  select s.id into sho3 from public.site_split_shares s where s.split_id = so3;
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_o3', now() + interval '31 minutes')$q$, sho3));
  perform tests.svc($q$public.split_share_paid('cs_o3', 'pi_o3', 500)$q$);
  perform tests.assert_eq('with every share paid the split is complete', tests.f(olly, o_e, format($q$public.split_for_booking(%L)$q$, bo3), '{state}'), 'complete');

  -- a share of a booking that has been refunded by the venue is paid back too
  update public.site_table_bookings set status = 'refunded' where id = bo3;
  perform tests.assert_eq('a refunded booking: the friend''s 5.00 is due back', tests.svc(format($q$(select string_agg(r.cents::text, ',') from public.split_refunds_due() r where r.share_id = %L)$q$, sho3)), '500');

  -- olly asks hal, then blocks him: the request disappears from his list and cannot be paid
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Olly', o_e, 2, 20000, 0, 'paid', 'SPLIT-O5') returning id into bo5;
  so5 := (tests.f(olly, o_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo5, format('[{"payer":"%s","amount_cents":2000}]', p_hal), v_deadline), '{id}'))::uuid;
  select s.id into sho5 from public.site_split_shares s where s.split_id = so5;
  perform tests.assert_eq('hal has a request', tests.q(hal, h_e, 'jsonb_array_length(public.split_my_shares())'), '1');
  perform tests.login(olly, o_e); perform public.block_set(p_olly, p_hal, true); perform tests.logout();
  perform tests.assert_eq('...olly blocks hal: it is gone from his list', tests.q(hal, h_e, 'public.split_my_shares()'), '[]');
  perform tests.assert_eq('...and he cannot pay it', tests.q(hal, h_e, format($q$public.split_share_begin(%L)$q$, sho5)), 'ERROR: This request is not available.');

  -- a third host (ned) for the money edges, so that nobody hits the limit of five splits a day
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ned', n_e, 2, 20000, 0, 'paid', 'SPLIT-N6') returning id into bo6;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ned', n_e, 2, 20000, 0, 'paid', 'SPLIT-N8') returning id into bo7;
  -- a table that someone over-paid at the club: a share paid afterwards is not applied at all and the table is left as it is
  so6 := (tests.f(ned, n_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo6, format('[{"payer":"%s","amount_cents":3000}]', p_bob), v_deadline), '{id}'))::uuid;
  select s.id into sho6 from public.site_split_shares s where s.split_id = so6;
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_n6', now() + interval '31 minutes')$q$, sho6));
  update public.site_table_bookings set amount_paid_cents = 20500 where id = bo6;
  r := tests.svc($q$public.split_share_paid('cs_n6', 'pi_n6', 3000)$q$);
  perform tests.assert_eq('a table over-paid at the club: none of the share is applied, all of it is due back', (r::jsonb ->> 'result') || '/' || (r::jsonb ->> 'applied_cents') || '/' || (r::jsonb ->> 'refund_cents') || '/' || (select amount_paid_cents from public.site_table_bookings where id = bo6), 'applied/0/3000/20500');
  -- a share with a surplus (the club took money while the page was open), and then the booking is cancelled: ALL of it is due, not only the surplus
  so7 := (tests.f(ned, n_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo7, format('[{"payer":"%s","amount_cents":3000}]', p_bob), v_deadline), '{id}'))::uuid;
  select s.id into sho7 from public.site_split_shares s where s.split_id = so7;
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_n7', now() + interval '31 minutes')$q$, sho7));
  update public.site_table_bookings set amount_paid_cents = 18000 where id = bo7;
  perform tests.svc($q$public.split_share_paid('cs_n7', 'pi_n7', 3000)$q$);
  perform tests.assert_eq('only the surplus (10.00) is due while the booking stands', tests.svc(format($q$(select string_agg(r.cents::text, ',') from public.split_refunds_due() r where r.share_id = %L)$q$, sho7)), '1000');
  update public.site_table_bookings set status = 'cancelled' where id = bo7;
  perform tests.assert_eq('...once the booking is cancelled the whole 30.00 is due', tests.svc(format($q$(select string_agg(r.cents::text, ',') from public.split_refunds_due() r where r.share_id = %L)$q$, sho7)), '3000');

  -- an arrival five hours ago: the night is not over yet, so a split can still be made
  v_local := (now() at time zone public.venue_timezone(va)) - interval '5 hours';
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (va, 2, v_local::time) returning id into v_slot2;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, v_slot2, v_local::date, 'Ned', n_e, 2, 20000, 0, 'paid', 'SPLIT-LATE') returning id into bo8;
  perform tests.assert_eq('five hours after the arrival the night is still on', tests.f(ned, n_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo8, format('[{"payer":"%s","amount_cents":2000}]', p_dee), now() + interval '2 hours'), '{state}'), 'open');

  -- the host goes while a payment page is open
  so4 := (tests.f(olly, o_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bo4, format('[{"payer":"%s","amount_cents":4000}]', p_bob), v_deadline), '{id}'))::uuid;
  select s.id into sho4 from public.site_split_shares s where s.split_id = so4;
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_o4', now() + interval '31 minutes')$q$, sho4));
  delete from auth.users where id = olly;
  perform tests.assert_eq('the host''s account went while bob''s page was open: his money is to be paid back, none of it applied', tests.svcf($q$public.split_share_paid('cs_o4', 'pi_o4', 4000)$q$, '{result}'), 'refund');
  perform tests.assert_eq('...the table has not been paid anything', (select amount_paid_cents from public.site_table_bookings where id = bo4), 0);

  ---------------------------------------------------------------- the host's account is deleted
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ned', n_e, 2, 20000, 0, 'paid', 'SPLIT-NED') returning id into bk_bob;
  perform tests.login(ned, n_e); perform public.save_my_profile('Ned Nobody', 'nedsplit', 'Toronto'); perform public.profile_save_personal('public'); perform tests.logout();
  sp2 := (tests.f(ned, n_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk_bob, format('[{"payer":"%s","amount_cents":2500}]', p_cy), v_deadline), '{id}'))::uuid;
  select s.id into sh_cy from public.site_split_shares s where s.split_id = sp2;
  perform tests.svc(format($q$public.split_share_attach(%L, 'cs_ned', now() + interval '31 minutes')$q$, sh_cy));
  perform tests.svc($q$public.split_share_paid('cs_ned', 'pi_ned', 2500)$q$);
  delete from auth.users where id = ned;
  perform tests.assert_eq('the host''s account is deleted: the split stays, without the host', (select host is null from public.site_splits where id = sp2), true);
  perform tests.assert_eq('...the friend''s money is to be paid back', tests.svc($q$(select string_agg(r.cents::text, ',') from public.split_refunds_due() r where r.split_id = $q$ || quote_literal(sp2) || $q$)$q$), '2500');
  perform tests.assert_eq('...and a friend''s deleted account leaves the share without a name', (select count(*) from public.site_split_shares where split_id = sp2 and payer is not null)::int, 1);
  delete from auth.users where id = cy;
  perform tests.assert_eq('...cy''s account is deleted: her share stays as a record with nobody on it', (select count(*) from public.site_split_shares where id = sh_cy and payer is null)::int, 1);

  ---------------------------------------------------------------- the limit on splits a day
  -- ann has made four splits today; the very first one is moved to two days ago, so it no longer counts: she can make two more and the next is refused
  update public.site_splits set created_at = now() - interval '2 days' where id = (select x.id from public.site_splits x where x.host = ann order by x.created_at limit 1);
  -- (and the next one is an hour old, which still counts: a split made inside this one transaction is always newer than "now", so only an older one tells a day from a second)
  update public.site_splits set created_at = now() - interval '1 hour' where id = (select x.id from public.site_splits x where x.host = ann and x.created_at > now() - interval '1 day' order by x.created_at limit 1);
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ann', a_e, 2, 20000, 0, 'paid', 'SPLIT-FOUR') returning id into bk4;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ann', a_e, 2, 20000, 0, 'paid', 'SPLIT-FIVE') returning id into bk5;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 3, 'Ann', a_e, 2, 20000, 0, 'paid', 'SPLIT-SIX') returning id into bk6;
  perform tests.assert_eq('three splits in the last day: a fourth is allowed', tests.f(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk4, format('[{"payer":"%s","amount_cents":1000}]', p_bob), v_deadline), '{state}'), 'open');
  perform tests.assert_eq('...and a fifth', tests.f(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk5, format('[{"payer":"%s","amount_cents":1000}]', p_bob), v_deadline), '{state}'), 'open');
  perform tests.assert_eq('five splits in a day is the limit', tests.q(ann, a_e, format($q$public.split_create(%L, %L::jsonb, %L)$q$, bk6, format('[{"payer":"%s","amount_cents":1000}]', p_bob), v_deadline)), 'ERROR: You have made a lot of splits today. Try again tomorrow.');
end $$;

rollback;
