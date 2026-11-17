-- Complimentary bottle offers with a claim link (20261123100000_complimentary_offers.sql). What matters: only the club's owner and manager (a manager only once the owner has set the free-bottle limits)
-- can make, place, accept, deliver or cancel an offer; the link's token exists only after the SERVICE ROLE issues it, only its hash is stored, and issuing again retires the old link; the claim shows
-- the venue, item and the club's table labels and never another guest; a claim is ONE claim; an offer is accepted through the existing free-bottle path (so the club's limits apply and the bottle line is
-- free, never a sale); an expired, cancelled or already-claimed link says so; and no visitor can call any of it.
begin;

create function tests.run_as(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.as_service(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login_service();
  execute p_sql into v;
  perform tests.logout();
  return coalesce(v, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.mkbooking(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_status text default 'paid') returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@test.example', 2, 1000, 0, p_status, upper(replace(p_name, ' ', '-')))
  returning id $$;
create function tests.mkbottle(p_venue uuid, p_name text, p_price int, p_available boolean default true, p_sold_out boolean default false) returns uuid language sql security definer as $$
  insert into public.site_bottles (venue_id, name, size, category, price_cents, stock_quantity, is_available, is_sold_out, sort_order)
  values (p_venue, p_name, '750ml', 'Spirits', p_price, null, p_available, p_sold_out, 0) returning id $$;
-- one value of the offer as the club's list gives it
create function tests.lst(p_user uuid, p_email text, p_venue uuid, p_offer uuid, p_col text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user, p_email);
  execute format('select (%s)::text from public.comp_offers_list(%L) o where o.offer_id = %L', p_col, p_venue, p_offer) into v;
  perform tests.logout();
  return coalesce(v, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.row_of(p_offer uuid, p_col text) returns text language plpgsql security definer as $$
declare v text;
begin
  execute format('select (%s)::text from public.site_comp_offers where id = %L', p_col, p_offer) into v;
  return coalesce(v, 'null');
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000009f1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000009f2';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000009f3';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000009f4';
  door_a constant uuid := '00000000-0000-0000-0000-0000000009f5';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000009f6';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; floor_a uuid; type_a uuid; type_a2 uuid; type_b uuid; slot_a uuid; slot_b uuid;
  b_ada uuid; b_zed uuid; b_unpaid uuid; b_other uuid; b_two uuid;
  patron uuid; gone uuid; hidden uuid; other_b uuid; vodka uuid;
  night date := current_date + 10;
  o1 uuid; o2 uuid; o3 uuid; o4 uuid; o5 uuid; tok1 text; tok1b text; tok3 text; tok4 text; tok5 text; r text; v jsonb; total_before int; ev uuid;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@co.example'), (mgr_a, 'mgra@co.example'), (mgr_b, 'mgrb@co.example'), (srv_1, 'srv1@co.example'), (door_a, 'doora@co.example'), (rival_u, 'rival@co2.example');
  insert into public.profiles (id, name, email) values (mgr_a, 'Mia Manager', 'mgra@co.example'), (owner_u, 'Olly Owner', 'owner@co.example');

  perform tests.login(owner_u, 'owner@co.example');
  org := public.create_organization('Offers Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@co.example', org, 'mgra@co.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@co.example', org, 'mgrb@co.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@co.example', org, 'srv1@co.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@co.example', org, 'doora@co.example', 'door', venue_a, door_a);
  perform tests.login(rival_u, 'rival@co2.example');
  org2 := public.create_organization('Rival Offers Co', 'venue_owner');
  perform tests.logout();

  insert into public.site_venue_floors (venue_id, label, image_url, sort_order) values (venue_a, 'Main floor', 'https://x.example/floor.png', 0) returning id into floor_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count, floor_id, pos_x, pos_y, width, height) values (venue_a, 'Booth 1', 8, 0, 0, 1, floor_a, 10, 20, 5, 5) returning id into type_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth 2', 6, 0, 0, 1) returning id into type_a2;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 1) returning id into type_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_b, 6, '21:00', 'Evening') returning id into slot_b;
  b_ada := tests.mkbooking(venue_a, type_a, slot_a, night, 'Ada Evening');
  b_zed := tests.mkbooking(venue_a, type_a, slot_a, night, 'Zed Evening');
  b_two := tests.mkbooking(venue_a, type_a2, slot_a, night, 'Tess Booth Two');
  b_unpaid := tests.mkbooking(venue_a, type_a, slot_a, night, 'Pending Pat', 'pending');
  b_other := tests.mkbooking(venue_b, type_b, slot_b, night, 'Other Club Ola');
  patron := tests.mkbottle(venue_a, 'Patron', 25000);
  gone := tests.mkbottle(venue_a, 'Unavailable Gin', 10000, false);
  hidden := tests.mkbottle(venue_a, 'Sold Out Rum', 10000, true, true);
  vodka := tests.mkbottle(venue_a, 'Vodka', 8000);
  other_b := tests.mkbottle(venue_b, 'Other Club Vodka', 8000);
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id) values ('Friday Night', 'x', 'Club A', now() + interval '10 days', now() + interval '10 days 6 hours', 'published', venue_a) returning id into ev;

  ---------------------------------------------------------------- who may make an offer
  perform tests.assert_eq('a server cannot', tests.run_as(srv_1, 'srv1@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: not allowed');
  perform tests.assert_eq('nor door staff', tests.run_as(door_a, 'doora@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: not allowed');
  perform tests.assert_eq('nor another club''s manager', tests.run_as(mgr_b, 'mgrb@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a rival', tests.run_as(rival_u, 'rival@co2.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: not allowed');
  perform tests.assert_eq('no club at all', tests.run_as(owner_u, 'owner@co.example', format($q$select public.comp_offer_create(null, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, patron)), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')$q$, venue_a, patron), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('a call with no signed-in person is told to sign in', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')$q$, venue_a, patron), 'not authenticated');
  perform tests.logout();
  perform tests.assert_eq('a manager needs the owner to set the free-bottle limits first', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, venue_a, patron)),
    'ERROR: free bottles are not set up for this club yet: the owner sets the limits first');

  ---------------------------------------------------------------- what an offer needs
  perform tests.assert_eq('the owner can make one without limits (they set them)', tests.run_as(owner_u, 'owner@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'First.Guest@X.example', 'Gina', 'Birthday table')::text$q$, venue_a, patron)) not like 'ERROR%', true);
  perform tests.logout();
  delete from public.site_comp_offers;
  perform tests.login(owner_u, 'owner@co.example');
  perform public.save_venue_discount_limits(venue_a, '{"server_max_percent":10,"manager_max_percent":30,"server_free_bottles_per_night":1,"manager_free_bottles_per_night":2}'::jsonb);
  perform tests.logout();
  perform tests.assert_eq('zero bottles', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 0, 'g@x.example', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: choose from 1 to 12 bottles');
  perform tests.assert_eq('thirteen bottles', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 13, 'g@x.example', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: choose from 1 to 12 bottles');
  perform tests.assert_eq('no quantity', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, null, 'g@x.example', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: choose from 1 to 12 bottles');
  perform tests.assert_eq('an e-mail address is needed', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'not-an-email', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: enter the e-mail address the link is for');
  perform tests.assert_eq('...not a blank one', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, '  ', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: enter the e-mail address the link is for');
  perform tests.assert_eq('...nor one with a space in it', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'a b@x.example', null, 'Birthday')::text$q$, venue_a, patron)), 'ERROR: enter the e-mail address the link is for');
  perform tests.assert_eq('...nor an enormous one', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, %L, null, 'Birthday')::text$q$, venue_a, patron, repeat('a', 250) || '@x.example')), 'ERROR: enter the e-mail address the link is for');
  perform tests.assert_eq('a name is short', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', %L, 'Birthday')::text$q$, venue_a, patron, repeat('n', 61))), 'ERROR: keep the name to 60 characters or fewer');
  perform tests.assert_eq('a reason has to be given', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'x')::text$q$, venue_a, patron)), 'ERROR: give a reason of 3 to 300 characters');
  perform tests.assert_eq('...and not at length', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, %L)::text$q$, venue_a, patron, repeat('r', 301))), 'ERROR: give a reason of 3 to 300 characters');
  perform tests.assert_eq('a sign is short and on one line', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday', %L)::text$q$, venue_a, patron, repeat('s', 41))) || ' | ' || tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday', %L)::text$q$, venue_a, patron, E'two\nlines')),
    'ERROR: keep the sign to 40 characters, on one line | ERROR: keep the sign to 40 characters, on one line');
  perform tests.assert_eq('a link lasts from 1 hour to 7 days', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday', null, null, 0)::text$q$, venue_a, patron)) || ' | ' || tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday', null, null, 169)::text$q$, venue_a, patron)) || ' | ' || tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday', null, null, null)::text$q$, venue_a, patron)),
    'ERROR: the link can last from 1 hour to 7 days | ERROR: the link can last from 1 hour to 7 days | ERROR: the link can last from 1 hour to 7 days');
  perform tests.assert_eq('a bottle that does not exist, or another club''s', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, venue_a, gen_random_uuid())) || ' | ' || tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, venue_a, other_b)),
    'ERROR: bottle not found | ERROR: bottle not found');
  perform tests.assert_eq('a bottle that is off the menu or sold out', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, venue_a, gone)) || ' | ' || tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday')::text$q$, venue_a, hidden)),
    'ERROR: that bottle is not available right now | ERROR: that bottle is not available right now');
  perform tests.assert_eq('an event that does not exist', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'g@x.example', null, 'Birthday', null, %L)::text$q$, venue_a, patron, gen_random_uuid())), 'ERROR: event not found');
  perform tests.assert_eq('nothing was made by all the refusals', (select count(*) from public.site_comp_offers)::int, 0);

  ---------------------------------------------------------------- making one
  r := tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 2, '  Gina.Guest@X.example ', 'Gina', 'Birthday table', 'Happy Birthday Gina', %L, 48)::text$q$, venue_a, patron, ev));
  perform tests.assert_true('the manager makes an offer', r not like 'ERROR%');
  o1 := r::uuid;
  perform tests.assert_eq('it starts approved, with the e-mail tidied, the value of the bottles, and who made it', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.status') || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.recipient_email') || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.value_cents') || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.created_by_name'),
    'approved gina.guest@x.example 50000 Mia Manager');
  perform tests.assert_eq('...approved by the same person, no link yet, and it lasts 48 hours', tests.row_of(o1, 'approved_by = created_by') || ' ' || tests.row_of(o1, 'token_hash is null') || ' ' || tests.row_of(o1, 'expires_at > now() + interval ''47 hours'' and expires_at < now() + interval ''49 hours'''), 'true true true');
  perform tests.assert_eq('the list says what can be done with it', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.actions'), '{set_location,cancel}');
  perform tests.assert_eq('a manager of another club, a server, door staff and a rival cannot read the list', tests.run_as(mgr_b, 'mgrb@co.example', format($q$select count(*)::text from public.comp_offers_list(%L)$q$, venue_a)) || ' | ' || tests.run_as(srv_1, 'srv1@co.example', format($q$select count(*)::text from public.comp_offers_list(%L)$q$, venue_a)) || ' | ' || tests.run_as(door_a, 'doora@co.example', format($q$select count(*)::text from public.comp_offers_list(%L)$q$, venue_a)) || ' | ' || tests.run_as(rival_u, 'rival@co2.example', format($q$select count(*)::text from public.comp_offers_list(%L)$q$, venue_a)),
    'ERROR: not allowed | ERROR: not allowed | ERROR: not allowed | ERROR: not allowed');
  perform tests.assert_eq('the owner reads it too, and another club''s list has none of it', tests.run_as(owner_u, 'owner@co.example', format($q$select count(*)::text from public.comp_offers_list(%L)$q$, venue_a)) || ' ' || tests.run_as(mgr_b, 'mgrb@co.example', format($q$select count(*)::text from public.comp_offers_list(%L)$q$, venue_b)), '1 0');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the list', format($q$select * from public.comp_offers_list(%L)$q$, venue_a), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the link: only the service role, only its hash is kept
  ---------------------------------------------------------------- the link: only the service role, only its hash is kept
  perform tests.assert_eq('a manager cannot make the link', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_issue_link(%L)$q$, o1)), 'ERROR: permission denied for function comp_offer_issue_link');
  perform tests.assert_eq('nor can the owner', tests.run_as(owner_u, 'owner@co.example', format($q$select public.comp_offer_issue_link(%L)$q$, o1)), 'ERROR: permission denied for function comp_offer_issue_link');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select public.comp_offer_issue_link(%L)$q$, o1), 'permission denied');
  perform tests.assert_raises('...nor read through a link', 'select public.comp_claim_view(''x'')', 'permission denied');
  perform tests.assert_raises('...nor submit through one', format($q$select public.comp_claim_submit('x', %L)$q$, type_a), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('a signed-in person cannot read through a link either', tests.run_as(mgr_a, 'mgra@co.example', 'select public.comp_claim_view(''x'')::text'), 'ERROR: permission denied for function comp_claim_view');
  tok1 := tests.as_service(format($q$select public.comp_offer_issue_link(%L)$q$, o1));
  perform tests.assert_true('the service role makes a link: a token of 64 characters', tok1 not like 'ERROR%' and char_length(tok1) = 64);
  perform tests.assert_eq('the offer is now sent', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.status'), 'sent');
  perform tests.assert_eq('only the hash of the token is kept, never the token', tests.row_of(o1, 'token_hash = encode(sha256(convert_to(' || quote_literal(tok1) || ', ''utf8'')), ''hex'')') || ' ' || tests.row_of(o1, 'token_hash <> ' || quote_literal(tok1)), 'true true');
  tok1b := tests.as_service(format($q$select public.comp_offer_issue_link(%L)$q$, o1));
  perform tests.assert_true('making the link again gives a different token', tok1b <> tok1 and char_length(tok1b) = 64);
  perform tests.assert_eq('...and the old link stops working', tests.as_service(format($q$select public.comp_claim_view(%L) ->> 'state'$q$, tok1)), 'not_found');
  perform tests.assert_eq('a made-up token, a short one and none are all "not found", the same answer', tests.as_service($q$select public.comp_claim_view('abc') ->> 'state'$q$) || ' ' || tests.as_service($q$select public.comp_claim_view(repeat('a', 64)) ->> 'state'$q$) || ' ' || tests.as_service($q$select public.comp_claim_view(null) ->> 'state'$q$), 'not_found not_found not_found');
  perform tests.assert_eq('making a link for an offer that does not exist', tests.as_service(format($q$select public.comp_offer_issue_link(%L)$q$, gen_random_uuid())), 'ERROR: not found');

  ---------------------------------------------------------------- the recipient opens the link
  v := tests.as_service(format($q$select public.comp_claim_view(%L)::text$q$, tok1b))::jsonb;
  perform tests.assert_eq('the claim shows the venue, the event, the item, the sign and the expiry', (v ->> 'state') || '/' || (v ->> 'venue_name') || '/' || (v ->> 'event_title') || '/' || (v ->> 'item') || '/' || (v ->> 'quantity') || '/' || (v ->> 'sign') || '/' || (v ->> 'recipient_name'), 'open/Club A/Friday Night/Patron/2/Happy Birthday Gina/Gina');
  perform tests.assert_eq('...and the club''s tables by their labels on its floor', (v -> 'tables' -> 0 ->> 'name') || ' ' || (v -> 'tables' -> 0 ->> 'pos_x') || ' ' || jsonb_array_length(v -> 'tables')::text || ' ' || (v -> 'floors' -> 0 ->> 'label'), 'Booth 1 10 2 Main floor');
  perform tests.assert_eq('...nothing of any guest or booking', (v::text like '%Ada Evening%' or v::text like '%Zed Evening%' or v::text like '%Pending Pat%' or v::text like '%Tess%' or v::text like '%@%' or v::text like '%EVENING%' or v::text like '%confirmation%' or v::text like '%Other Club%' or v::text like '%customer%'), false);
  perform tests.assert_eq('opening it moved the offer to "awaiting location", once', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.status') || ' ' || tests.row_of(o1, 'claimed_at is not null'), 'awaiting_location true');
  perform tests.assert_eq('opening it again changes nothing and creates nothing', tests.as_service(format($q$select public.comp_claim_view(%L) ->> 'state'$q$, tok1b)) || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.status') || ' ' || (select count(*) from public.site_concessions where bottle_id = patron)::text, 'open awaiting_location 0');

  ---------------------------------------------------------------- the recipient says where they are: one claim
  perform tests.assert_eq('another club''s table is refused', tests.as_service(format($q$select public.comp_claim_submit(%L, %L) ->> 'state'$q$, tok1b, type_b)), 'bad_table');
  perform tests.assert_eq('no table is refused', tests.as_service(format($q$select public.comp_claim_submit(%L, null) ->> 'state'$q$, tok1b)), 'bad_table');
  perform tests.assert_eq('a bad link is "not found"', tests.as_service(format($q$select public.comp_claim_submit('nope', %L) ->> 'state'$q$, type_a)), 'not_found');
  perform tests.assert_eq('nothing changed by the refusals', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.status'), 'awaiting_location');
  perform tests.assert_eq('the recipient chooses Booth 1', tests.as_service(format($q$select public.comp_claim_submit(%L, %L) ->> 'state'$q$, tok1b, type_a)), 'submitted');
  perform tests.assert_eq('the club sees where, and that the recipient chose it', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.status') || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.location_table_name') || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.location_set_by'), 'location_submitted Booth 1 recipient');
  perform tests.assert_eq('a second submission is "already claimed" and changes nothing (one claim only)', tests.as_service(format($q$select public.comp_claim_submit(%L, %L) ->> 'state'$q$, tok1b, type_a2)) || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.location_table_name'), 'claimed Booth 1');
  perform tests.assert_eq('opening the link now shows it is claimed, with no map', (tests.as_service(format($q$select public.comp_claim_view(%L)::text$q$, tok1b))::jsonb ->> 'state') || ' ' || (tests.as_service(format($q$select public.comp_claim_view(%L)::text$q$, tok1b))::jsonb ? 'tables')::text, 'claimed false');
  perform tests.assert_eq('the link cannot be made again for a claimed offer', tests.as_service(format($q$select public.comp_offer_issue_link(%L)$q$, o1)), 'ERROR: a link cannot be issued for an offer that is location submitted');

  ---------------------------------------------------------------- staff check and accept: it becomes a free bottle through the existing path
  perform tests.assert_eq('the list now offers accept, change of place and cancel', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.actions'), '{accept,set_location,cancel}');
  perform tests.assert_eq('the bookings at that table that night are offered, confirmed ones only', tests.run_as(mgr_a, 'mgra@co.example', format($q$select string_agg(guest_name || ':' || confirmation_code, ',' order by guest_name) from public.comp_offer_bookings(%L, %L)$q$, o1, night)), 'Ada Evening:ADA-EVENING,Zed Evening:ZED-EVENING');
  perform tests.assert_eq('...none for another night', tests.run_as(mgr_a, 'mgra@co.example', format($q$select count(*)::text from public.comp_offer_bookings(%L, %L)$q$, o1, night + 3)), '0');
  perform tests.assert_eq('...and nobody else can ask', tests.run_as(srv_1, 'srv1@co.example', format($q$select count(*)::text from public.comp_offer_bookings(%L, %L)$q$, o1, night)) || ' ' || tests.run_as(mgr_b, 'mgrb@co.example', format($q$select count(*)::text from public.comp_offer_bookings(%L, %L)$q$, o1, night)), 'ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('a server cannot accept', tests.run_as(srv_1, 'srv1@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o1, b_ada)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s booking is refused', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o1, b_other)), 'ERROR: not allowed');
  perform tests.assert_eq('a booking at a different table is refused', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o1, b_two)), 'ERROR: that booking is for a different table than the one chosen');
  perform tests.assert_eq('a booking that is not confirmed is refused by the free-bottle rules', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o1, b_unpaid)), 'ERROR: only a confirmed booking can have a discount or a free bottle');
  perform tests.logout();
  perform tests.assert_eq('nothing changed by the refusals', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.status') || ' ' || (select count(*) from public.site_concessions)::text, 'location_submitted 0');
  select b.amount_total_cents into total_before from public.site_table_bookings b where b.id = b_ada;
  v := tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o1, b_ada))::jsonb;
  perform tests.assert_eq('the manager accepts it within the club''s limits: the free bottle is applied', (v ->> 'status') || ' ' || (v ->> 'concession_status'), 'accepted applied');
  perform tests.assert_eq('the offer says which booking and which free bottle', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.status') || ' ' || (tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.booking_id') = b_ada::text)::text || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.concession_status'), 'accepted true applied');
  perform tests.logout();
  perform tests.assert_eq('the free bottle is a bottle line at no charge on that booking, two of them, and the booking''s total did not move',
    (select (count(*), sum(l.quantity), sum(l.line_total_cents))::text from public.site_table_booking_bottles l where l.booking_id = b_ada and l.bottle_id = patron) || ' ' || ((select b.amount_total_cents from public.site_table_bookings b where b.id = b_ada) = total_before)::text, '(1,2,0) true');
  perform tests.logout();
  perform tests.assert_eq('it is recorded as complimentary with its value, never as a sale', (select (c.kind, c.quantity, c.amount_cents, c.status, c.requested_role)::text from public.site_concessions c where c.id = (tests.row_of(o1, 'concession_id'))::uuid), '(free_bottle,2,50000,applied,manager)');
  perform tests.assert_eq('the list now offers only "mark delivered"', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.actions'), '{mark_delivered}');
  perform tests.assert_eq('it cannot be accepted twice', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o1, b_zed)), 'ERROR: this offer is accepted: it needs a place before it can be accepted');
  perform tests.assert_eq('its place can no longer be changed', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_set_location(%L, %L)$q$, o1, type_a2)), 'ERROR: this offer is accepted and its place can no longer be changed');
  perform tests.assert_eq('it cannot be cancelled as an offer: a free bottle exists', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_cancel(%L, 'Changed our minds')$q$, o1)), 'ERROR: a free bottle already exists for this offer: take it back on the free bottle');
  perform tests.assert_eq('a server cannot mark it delivered', tests.run_as(srv_1, 'srv1@co.example', format($q$select public.comp_offer_mark_delivered(%L)$q$, o1)), 'ERROR: not allowed');
  perform tests.assert_eq('the manager marks it delivered', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_mark_delivered(%L)$q$, o1)), 'delivered');
  perform tests.assert_eq('...once', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_mark_delivered(%L)$q$, o1)), 'ERROR: only an accepted offer can be marked delivered');
  perform tests.assert_eq('a delivered offer has nothing left to do', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.actions') || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.delivered_at is not null'), '{} true');

  ---------------------------------------------------------------- placing by hand when the link fails, and the club's limits at acceptance
  o2 := tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'second@x.example', null, 'Press guest')::text$q$, venue_a, vodka))::uuid;
  perform tests.assert_eq('the club''s tables are listed by label with their floor, for placing by hand', tests.run_as(mgr_a, 'mgra@co.example', format($q$select string_agg(name || ':' || coalesce(floor_label, '-'), ',' order by name) from public.comp_offer_tables(%L)$q$, venue_a)), 'Booth 1:Main floor,Booth 2:-');
  perform tests.assert_eq('...for the club''s own people only', tests.run_as(srv_1, 'srv1@co.example', format($q$select count(*)::text from public.comp_offer_tables(%L)$q$, venue_a)) || ' ' || tests.run_as(mgr_b, 'mgrb@co.example', format($q$select count(*)::text from public.comp_offer_tables(%L)$q$, venue_a)), 'ERROR: not allowed ERROR: not allowed');
  perform tests.assert_eq('a server cannot place a recipient', tests.run_as(srv_1, 'srv1@co.example', format($q$select public.comp_offer_set_location(%L, %L)$q$, o2, type_a)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s table is refused', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_set_location(%L, %L)$q$, o2, type_b)), 'ERROR: choose one of this club''s tables');
  perform tests.assert_eq('no table is refused', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_set_location(%L, null)$q$, o2)), 'ERROR: choose one of this club''s tables');
  perform tests.assert_eq('an offer that has no place cannot be accepted', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o2, b_zed)), 'ERROR: this offer is approved: it needs a place before it can be accepted');
  perform tests.assert_eq('staff place the recipient at Booth 1', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_set_location(%L, %L)$q$, o2, type_a)), 'location_submitted');
  perform tests.assert_eq('...it says that staff did', tests.lst(mgr_a, 'mgra@co.example', venue_a, o2, 'o.location_set_by') || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o2, 'o.location_table_name'), 'staff Booth 1');
  perform tests.assert_eq('staff can change their mind about the place before accepting', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_set_location(%L, %L)$q$, o2, type_a2)) || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o2, 'o.location_table_name'), 'location_submitted Booth 2');
  perform tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_set_location(%L, %L)$q$, o2, type_a));
  v := tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o2, b_zed))::jsonb;
  perform tests.assert_eq('the manager''s free-bottle pool is 2 a night and 2 are used: this one waits for the owner, as a free bottle at a table would', (v ->> 'status') || ' ' || (v ->> 'concession_status'), 'accepted pending');
  perform tests.assert_eq('the list shows the free bottle is pending', tests.lst(mgr_a, 'mgra@co.example', venue_a, o2, 'o.concession_status'), 'pending');

  ---------------------------------------------------------------- cancelling
  o3 := tests.run_as(owner_u, 'owner@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'third@x.example', null, 'Sponsor')::text$q$, venue_a, patron))::uuid;
  tok3 := tests.as_service(format($q$select public.comp_offer_issue_link(%L)$q$, o3));
  perform tests.assert_eq('a server cannot cancel', tests.run_as(srv_1, 'srv1@co.example', format($q$select public.comp_offer_cancel(%L, 'Not needed')$q$, o3)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.run_as(mgr_b, 'mgrb@co.example', format($q$select public.comp_offer_cancel(%L, 'Not needed')$q$, o3)), 'ERROR: not allowed');
  perform tests.assert_eq('a reason is needed', tests.run_as(owner_u, 'owner@co.example', format($q$select public.comp_offer_cancel(%L, 'x')$q$, o3)), 'ERROR: give a reason of 3 to 300 characters');
  perform tests.assert_eq('the owner cancels it', tests.run_as(owner_u, 'owner@co.example', format($q$select public.comp_offer_cancel(%L, 'The guest cannot come')$q$, o3)), 'cancelled');
  perform tests.assert_eq('...with its reason, and the link stops working', tests.row_of(o3, 'cancel_reason') || ' ' || tests.row_of(o3, 'token_hash is null') || ' ' || tests.as_service(format($q$select public.comp_claim_view(%L) ->> 'state'$q$, tok3)), 'The guest cannot come true not_found');
  perform tests.assert_eq('it cannot be cancelled twice, placed, or accepted', tests.run_as(owner_u, 'owner@co.example', format($q$select public.comp_offer_cancel(%L, 'Again please')$q$, o3)) || ' | ' || tests.run_as(owner_u, 'owner@co.example', format($q$select public.comp_offer_set_location(%L, %L)$q$, o3, type_a)) || ' | ' || tests.run_as(owner_u, 'owner@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o3, b_ada)),
    'ERROR: this offer is already cancelled | ERROR: this offer is cancelled and its place can no longer be changed | ERROR: this offer is cancelled: it needs a place before it can be accepted');
  perform tests.assert_eq('a cancelled offer has nothing left to do', tests.lst(owner_u, 'owner@co.example', venue_a, o3, 'o.actions') || ' ' || tests.lst(owner_u, 'owner@co.example', venue_a, o3, 'o.status'), '{} cancelled');

  ---------------------------------------------------------------- expiry
  o4 := tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'fourth@x.example', null, 'Late guest', null, null, 1)::text$q$, venue_a, patron))::uuid;
  tok4 := tests.as_service(format($q$select public.comp_offer_issue_link(%L)$q$, o4));
  perform tests.assert_eq('a link open now says open', tests.as_service(format($q$select public.comp_claim_view(%L) ->> 'state'$q$, tok4)), 'open');
  update public.site_comp_offers set expires_at = now() - interval '1 minute' where id = o4;
  perform tests.assert_eq('after its time it is EXPIRED, and the list says so with nothing to do', tests.lst(mgr_a, 'mgra@co.example', venue_a, o4, 'o.status') || ' ' || tests.lst(mgr_a, 'mgra@co.example', venue_a, o4, 'o.actions'), 'expired {}');
  perform tests.assert_eq('the link says expired, and so does a claim', tests.as_service(format($q$select public.comp_claim_view(%L) ->> 'state'$q$, tok4)) || ' ' || tests.as_service(format($q$select public.comp_claim_submit(%L, %L) ->> 'state'$q$, tok4, type_a)), 'expired expired');
  perform tests.assert_eq('nobody can place it, accept it or make a new link for it', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_set_location(%L, %L)$q$, o4, type_a)) || ' | ' || tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o4, b_ada)) || ' | ' || tests.as_service(format($q$select public.comp_offer_issue_link(%L)$q$, o4)),
    'ERROR: this offer has expired | ERROR: this offer has expired | ERROR: a link cannot be issued for an offer that is expired');
  perform tests.assert_eq('an expired offer can still be cancelled (to tidy the list)', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_cancel(%L, 'Never came')$q$, o4)), 'cancelled');
  perform tests.logout();
  update public.site_comp_offers set expires_at = now() - interval '1 day' where id = o1;
  perform tests.assert_eq('a delivered offer is not "expired" when its time has passed', tests.lst(mgr_a, 'mgra@co.example', venue_a, o1, 'o.status'), 'delivered');

  ---------------------------------------------------------------- a link opened before it was made "sent", and a manual path for a link that was never sent
  o5 := tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_create(%L, %L, 1, 'fifth@x.example', null, 'Guest of honour')::text$q$, venue_a, patron))::uuid;
  perform tests.assert_eq('an offer whose link was never made can still be placed by staff', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_set_location(%L, %L)$q$, o5, type_a)), 'location_submitted');
  perform tests.assert_eq('...and then it cannot be given a link: it has been placed', tests.as_service(format($q$select public.comp_offer_issue_link(%L)$q$, o5)), 'ERROR: a link cannot be issued for an offer that is location submitted');

  -- an offer that has been placed but not accepted still expires, and one whose bottle left the menu cannot be accepted
  perform tests.logout();
  update public.site_comp_offers set expires_at = now() - interval '1 minute' where id = o5;
  perform tests.assert_eq('a placed offer that was not accepted in time is expired too, and cannot be accepted', tests.lst(mgr_a, 'mgra@co.example', venue_a, o5, 'o.status') || ' | ' || tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o5, b_ada)), 'expired | ERROR: this offer has expired');
  perform tests.logout();
  update public.site_comp_offers set expires_at = now() + interval '1 hour', bottle_id = null where id = o5;
  perform tests.assert_eq('an offer whose bottle has left the menu cannot be accepted', tests.run_as(mgr_a, 'mgra@co.example', format($q$select public.comp_offer_accept(%L, %L)::text$q$, o5, b_ada)), 'ERROR: that bottle is no longer on the menu');

  ---------------------------------------------------------------- the table is closed, and the functions are what the migration says
  perform tests.login(mgr_a, 'mgra@co.example');
  perform tests.assert_raises('a signed-in person cannot read the table', 'select * from public.site_comp_offers', 'permission denied');
  perform tests.assert_raises('...nor change an offer', format($q$update public.site_comp_offers set status = 'delivered' where id = %L$q$, o2), 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read it', 'select * from public.site_comp_offers', 'permission denied');
  perform tests.logout();
  perform tests.assert_raises('the database refuses a cancelled offer without its reason', format($q$update public.site_comp_offers set status = 'cancelled', cancelled_at = now() where id = %L$q$, o5), 'site_comp_offers_cancelled_check');
  perform tests.assert_raises('...and an e-mail that is not one', format($q$update public.site_comp_offers set recipient_email = 'nope' where id = %L$q$, o5), 'recipient_email_check');
  perform tests.assert_true('every function runs with its owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%') from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('comp_offer_create', 'comp_offers_list', 'comp_offer_tables', 'comp_offer_set_location', 'comp_offer_bookings', 'comp_offer_accept', 'comp_offer_mark_delivered', 'comp_offer_cancel', 'comp_offer_issue_link', 'comp_claim_view', 'comp_claim_submit')));
  perform tests.assert_true('visitors cannot run any of them, signed-in people and the service role can run the eight staff functions',
    (select bool_and(not has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('service_role', p.oid, 'execute')) from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('comp_offer_create', 'comp_offers_list', 'comp_offer_tables', 'comp_offer_set_location', 'comp_offer_bookings', 'comp_offer_accept', 'comp_offer_mark_delivered', 'comp_offer_cancel')));
  perform tests.assert_true('only the service role can make a link or read and submit a claim',
    (select bool_and(not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('service_role', p.oid, 'execute')) from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('comp_offer_issue_link', 'comp_claim_view', 'comp_claim_submit')));
  perform tests.assert_true('the two helpers are not callable by anyone signed in',
    not has_function_privilege('authenticated', 'public.comp_offer_state(text, timestamptz)', 'execute') and not has_function_privilege('authenticated', 'public.comp_token_hash(text)', 'execute'));
end $$;

rollback;
