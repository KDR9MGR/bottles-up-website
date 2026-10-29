-- The guest's bottle sign for the staff (20261114100000_booking_sign_text.sql). What matters: the club's manager or owner and the server who has the table read it (trimmed), a
-- booking with no sign, or only spaces, gives nothing; everyone else is refused (another server, a verifier, the door, another club's manager, a stranger, a visitor, a booking
-- that does not exist); and the function reads and changes nothing else.
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
create function tests.sign(p_user uuid, p_email text, p_booking uuid) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  r := public.desk_booking_sign(p_booking);
  perform tests.logout();
  return coalesce(r, '(none)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000008e1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000008e2';
  srv_own constant uuid := '00000000-0000-0000-0000-0000000008e3';
  srv_other constant uuid := '00000000-0000-0000-0000-0000000008e4';
  ver constant uuid := '00000000-0000-0000-0000-0000000008e5';
  door constant uuid := '00000000-0000-0000-0000-0000000008e6';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000008e7';
  rando constant uuid := '00000000-0000-0000-0000-0000000008e8';
  d constant date := current_date + 2;
  org uuid; venue_a uuid; venue_b uuid; t uuid; s uuid; b_sign uuid; b_none uuid; b_blank uuid; m_own uuid;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@sign.example'), (mgr_a, 'mgra@sign.example'), (srv_own, 'own@sign.example'), (srv_other, 'other@sign.example'),
    (ver, 'ver@sign.example'), (door, 'door@sign.example'), (mgr_b, 'mgrb@sign.example'), (rando, 'rando@sign.example');
  perform tests.login(owner_u, 'owner@sign.example');
  org := public.create_organization('Sign Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@sign.example', org, 'mgra@sign.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@sign.example', org, 'mgrb@sign.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@sign.example', org, 'own@sign.example', 'server', venue_a, srv_own);
  perform tests.join_as(mgr_a, 'mgra@sign.example', org, 'other@sign.example', 'server', venue_a, srv_other);
  perform tests.join_as(mgr_a, 'mgra@sign.example', org, 'ver@sign.example', 'verifier', venue_a, ver);
  perform tests.join_as(mgr_a, 'mgra@sign.example', org, 'door@sign.example', 'door', venue_a, door);
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 6, 0, 10000, 5) returning id into t;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from d)::int, '21:00') returning id into s;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code, bottle_sign_text)
    values (venue_a, t, s, d, 'Has Sign', 'sign@sign.example', 4, 10000, 'paid', 'SG0001', '  Happy Birthday  ') returning id into b_sign;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (venue_a, t, s, d, 'No Sign', 'none@sign.example', 4, 10000, 'paid', 'SG0002') returning id into b_none;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code, bottle_sign_text)
    values (venue_a, t, s, d, 'Blank Sign', 'blank@sign.example', 4, 10000, 'paid', 'SG0003', '   ') returning id into b_blank;
  select m.id into m_own from public.site_memberships m where m.user_id = srv_own and m.role = 'server';
  insert into public.site_booking_servers (booking_id, membership_id, assigned_by) values (b_sign, m_own, mgr_a), (b_none, m_own, mgr_a);

  perform tests.assert_eq('the club''s manager reads the sign, trimmed', tests.sign(mgr_a, 'mgra@sign.example', b_sign), 'Happy Birthday');
  perform tests.assert_eq('the owner does too', tests.sign(owner_u, 'owner@sign.example', b_sign), 'Happy Birthday');
  perform tests.assert_eq('the server who has the table does', tests.sign(srv_own, 'own@sign.example', b_sign), 'Happy Birthday');
  perform tests.assert_eq('a booking with no sign gives nothing', tests.sign(mgr_a, 'mgra@sign.example', b_none), '(none)');
  perform tests.assert_eq('...to its server as well', tests.sign(srv_own, 'own@sign.example', b_none), '(none)');
  perform tests.assert_eq('a sign of only spaces is nothing', tests.sign(mgr_a, 'mgra@sign.example', b_blank), '(none)');
  perform tests.assert_eq('a server who does not have the table is refused', tests.sign(srv_other, 'other@sign.example', b_sign), 'ERROR: not allowed');
  perform tests.assert_eq('...and so is the same server for a table nobody gave them', tests.sign(srv_own, 'own@sign.example', b_blank), 'ERROR: not allowed');
  perform tests.assert_eq('the payment verifier is refused (they see money, not service)', tests.sign(ver, 'ver@sign.example', b_sign), 'ERROR: not allowed');
  perform tests.assert_eq('the door is refused', tests.sign(door, 'door@sign.example', b_sign), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager is refused', tests.sign(mgr_b, 'mgrb@sign.example', b_sign), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger is refused', tests.sign(rando, 'rando@sign.example', b_sign), 'ERROR: not allowed');
  perform tests.assert_eq('a booking that does not exist is refused like any other the person cannot reach', tests.sign(mgr_a, 'mgra@sign.example', gen_random_uuid()), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call it', format('select public.desk_booking_sign(%L)', b_sign), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('nothing was changed: the stored sign still has its spaces', (select bottle_sign_text from public.site_table_bookings where id = b_sign), '  Happy Birthday  ');
  perform tests.assert_true('it runs with its owner''s rights and a fixed search path, and only signed-in people may call it',
    (select p.prosecdef and p.provolatile = 's' and coalesce(p.proconfig::text, '') like '%search_path=public%' from pg_proc p where p.proname = 'desk_booking_sign' and p.pronamespace = 'public'::regnamespace)
    and has_function_privilege('authenticated', 'public.desk_booking_sign(uuid)', 'execute') and not has_function_privilege('anon', 'public.desk_booking_sign(uuid)', 'execute'));
end $$;

rollback;
