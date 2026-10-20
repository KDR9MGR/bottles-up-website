-- Discounts and complimentary bottles given by the club's own people (20261024100000_staff_discounts_and_complimentary.sql). What matters:
--   * until the OWNER sets limits, nobody but the owner can give a discount or a free bottle; only the owner sets them, and they make sense (a manager's limit is never below a server's);
--   * within their own limit a server or manager gives it at once; above it, it WAITS for someone with the authority (a manager within the manager's limit and pool, the owner for
--     anything); nobody approves their own; a decision is made once; every step names who did it;
--   * a discount lowers what the table owes, never by more than it owes or than the bottles come to, never twice on one table unless the owner allows it, and it can be taken back;
--   * a free bottle is a real bottle line at no charge, counts in stock, is served like any other, and is allowed per server per night and from a pool per night for the managers;
--   * only the people of THAT club (the owner, a manager, the table's own server) can reach a table's concessions; every refusal is a plain sentence and changes nothing.
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
create function tests.runj(p_user uuid, p_email text, p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into r;
  perform tests.logout();
  return r;
end $$;
-- a confirmed table with bottles worth p_bottles on it (one line), a total, what is paid, and optionally the server it is given to
create function tests.mktable(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_total int, p_paid int, p_bottles int, p_server uuid default null, p_status text default 'paid') returns uuid language plpgsql security definer as $$
declare v_id uuid; m uuid;
begin
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@cn.example', 2, p_total, p_paid, p_status, 'CN-' || upper(replace(p_name, ' ', ''))) returning id into v_id;
  if p_bottles > 0 then
    insert into public.site_table_booking_bottles (booking_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, payment_status, service_status)
    values (v_id, 'House bottles', '750ml', p_bottles, 1, p_bottles, 'paid', 'awaiting_prep');
  end if;
  if p_server is not null then
    select mm.id into m from public.site_memberships mm where mm.user_id = p_server and mm.role = 'server' and mm.venue_id = p_venue and mm.status = 'active';
    insert into public.site_booking_servers (booking_id, membership_id, assigned_by) values (v_id, m, p_server);
  end if;
  return v_id;
end $$;
create function tests.mkbottle(p_venue uuid, p_name text, p_price int, p_stock int default null, p_available boolean default true, p_sold_out boolean default false) returns uuid language sql security definer as $$
  insert into public.site_bottles (venue_id, name, size, category, price_cents, stock_quantity, is_available, is_sold_out) values (p_venue, p_name, '750ml', 'Spirits', p_price, p_stock, p_available, p_sold_out) returning id $$;
create function tests.total(p_booking uuid) returns text language sql security definer as $$
  select amount_total_cents || '/' || staff_discount_cents from public.site_table_bookings where id = p_booking $$;
create function tests.status_of(p_id uuid) returns text language sql security definer as $$ select status from public.site_concessions where id = p_id $$;
create function tests.disc(p_user uuid, p_email text, p_booking uuid, p_kind text, p_value int, p_reason text default 'Regular guest') returns text language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  r := public.desk_request_discount(p_booking, p_kind, p_value, p_reason);
  perform tests.logout();
  return (r ->> 'status') || ':' || (r ->> 'amount_cents') || ':' || (r ->> 'percent');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.free(p_user uuid, p_email text, p_booking uuid, p_bottle uuid, p_qty int, p_reason text default 'Birthday table') returns text language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  r := public.desk_request_free_bottle(p_booking, p_bottle, p_qty, p_reason);
  perform tests.logout();
  return (r ->> 'status') || ':' || (r ->> 'value_cents');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.decide(p_user uuid, p_email text, p_id uuid, p_approve boolean, p_note text default null) returns text language sql as $$
  select tests.try(p_user, p_email, format($q$select public.desk_decide_concession(%L, %L, %L)$q$, p_id, p_approve, p_note)) $$;
create function tests.pending_text(p_user uuid, p_email text, p_venue uuid) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  select coalesce(string_agg(confirmation_code || ' ' || kind || ' ' || coalesce(percent::text, '-') || '% ' || amount_cents || ' by ' || requested_role || ' decide=' || can_decide::text, ' | ' order by created_at, concession_id), '(none)') into r from public.desk_pending_concessions(p_venue);
  perform tests.logout();
  return r;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-000000000bd1';
  mgr_a constant uuid := '00000000-0000-0000-0000-000000000bd2';
  mgr_a2 constant uuid := '00000000-0000-0000-0000-000000000bd3';
  srv_1 constant uuid := '00000000-0000-0000-0000-000000000bd4';
  srv_2 constant uuid := '00000000-0000-0000-0000-000000000bd5';
  door constant uuid := '00000000-0000-0000-0000-000000000bd6';
  mgr_b constant uuid := '00000000-0000-0000-0000-000000000bd7';
  rando constant uuid := '00000000-0000-0000-0000-000000000bd8';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  org uuid; venue_a uuid; venue_b uuid; t_a uuid; t_b uuid; s_a uuid; s_b uuid; night date := current_date;
  b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; b6 uuid; b7 uuid; b_zero uuid; b_pend uuid; b_closed uuid; b_b uuid; b_free uuid; b_free2 uuid; b_next uuid; b_stock uuid; b_owner uuid; s_next uuid;
  bt_vodka uuid; bt_patron uuid; bt_sold uuid; bt_off uuid; bt_b uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid; c5 uuid; r text; j jsonb; n int; who text; k record;
  others text[] := array['srv2@cn.example', 'door@cn.example', 'mgrb@cn.example', 'rando@cn.example'];
begin
  insert into auth.users (id, email) values (owner_u, 'owner@cn.example'), (mgr_a, 'mgra@cn.example'), (mgr_a2, 'mgra2@cn.example'), (srv_1, 'srv1@cn.example'), (srv_2, 'srv2@cn.example'),
    (door, 'door@cn.example'), (mgr_b, 'mgrb@cn.example'), (rando, 'rando@cn.example');
  perform tests.login(owner_u, 'owner@cn.example');
  org := public.create_organization('Concession Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@cn.example', org, 'mgra@cn.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@cn.example', org, 'mgra2@cn.example', 'manager', venue_a, mgr_a2);
  perform tests.join_as(owner_u, 'owner@cn.example', org, 'mgrb@cn.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@cn.example', org, 'srv1@cn.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@cn.example', org, 'srv2@cn.example', 'server', venue_a, srv_2);
  perform tests.join_as(mgr_a, 'mgra@cn.example', org, 'door@cn.example', 'door', venue_a, door);
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 6, 0, 0, 50) returning id into t_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 0, 50) returning id into t_b;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from night)::int, '21:00') returning id into s_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, extract(dow from night + 1)::int, '21:00') returning id into s_next;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_b, extract(dow from night)::int, '21:00') returning id into s_b;

  b1 := tests.mktable(venue_a, t_a, s_a, night, 'Table One', 20000, 5000, 10000, srv_1);
  b2 := tests.mktable(venue_a, t_a, s_a, night, 'Table Two', 20000, 5000, 10000, srv_1);
  b3 := tests.mktable(venue_a, t_a, s_a, night, 'Table Three', 20000, 5000, 10000, srv_1);
  b4 := tests.mktable(venue_a, t_a, s_a, night, 'Table Four', 20000, 5000, 10000, srv_1);
  b5 := tests.mktable(venue_a, t_a, s_a, night, 'Table Five', 8000, 0, 8000, srv_1);
  b6 := tests.mktable(venue_a, t_a, s_a, night, 'Table Six', 3000, 3000, 3000, srv_1);
  b7 := tests.mktable(venue_a, t_a, s_a, night, 'Table Seven', 20000, 5000, 10000, srv_1);
  b_zero := tests.mktable(venue_a, t_a, s_a, night, 'No Bottles', 5000, 0, 0, srv_1);
  b_pend := tests.mktable(venue_a, t_a, s_a, night, 'Not Paid', 5000, 0, 5000, srv_1, 'pending');
  b_closed := tests.mktable(venue_a, t_a, s_a, night, 'Closed Out', 5000, 0, 5000, srv_1);
  update public.site_table_bookings set reconciled_at = now() where id = b_closed;
  b_b := tests.mktable(venue_b, t_b, s_b, night, 'Other Club', 5000, 0, 5000);
  b_free := tests.mktable(venue_a, t_a, s_a, night, 'Free Table', 5000, 0, 5000, srv_1);
  b_free2 := tests.mktable(venue_a, t_a, s_a, night, 'Free Table Two', 5000, 0, 5000, srv_1);
  b_stock := tests.mktable(venue_a, t_a, s_a, night, 'Stock Table', 5000, 0, 5000, srv_1);
  b_next := tests.mktable(venue_a, t_a, s_next, night + 1, 'Tomorrow Table', 5000, 0, 5000, srv_1);
  b_owner := tests.mktable(venue_a, t_a, s_a, night, 'Owner Table', 20000, 0, 10000, srv_1);
  bt_vodka := tests.mkbottle(venue_a, 'Vodka', 3000);
  bt_patron := tests.mkbottle(venue_a, 'Patron', 5000, 5);
  bt_sold := tests.mkbottle(venue_a, 'Sold out', 4000, null, true, true);
  bt_off := tests.mkbottle(venue_a, 'Not offered', 4000, null, false, false);
  bt_b := tests.mkbottle(venue_b, 'Other club bottle', 1000);

  ---------------------------------------------------------------- 1. until the owner sets limits, nobody else can give anything
  perform tests.assert_eq('a server is told the owner has not set limits', tests.disc(srv_1, 'srv1@cn.example', b1, 'percent', 5), 'ERROR: discounts are not set up for this club yet: the owner sets the limits first');
  perform tests.assert_eq('...and so is a manager', tests.disc(mgr_a, 'mgra@cn.example', b1, 'percent', 5), 'ERROR: discounts are not set up for this club yet: the owner sets the limits first');
  perform tests.assert_eq('...and for a free bottle', tests.free(srv_1, 'srv1@cn.example', b1, bt_vodka, 1), 'ERROR: free bottles are not set up for this club yet: the owner sets the limits first');
  perform tests.assert_eq('...nothing changed', tests.total(b1), '20000/0');
  perform tests.assert_eq('the owner needs no limit: 5 percent is applied at once', tests.disc(owner_u, 'owner@cn.example', b_owner, 'percent', 5), 'applied:500:5');
  perform tests.assert_eq('...it lowers what the table owes', tests.total(b_owner), '19500/500');

  ---------------------------------------------------------------- 2. the owner sets the limits
  foreach who in array array['mgra@cn.example', 'srv1@cn.example', 'door@cn.example', 'mgrb@cn.example', 'rando@cn.example'] loop
    perform tests.assert_eq('setting limits is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.save_venue_discount_limits(%L, '{"server_max_percent":10}'::jsonb)::text$q$, venue_a)), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot set limits', format($q$select public.save_venue_discount_limits(%L, '{"server_max_percent":10}'::jsonb)$q$, venue_a), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('a server limit above the manager''s is refused', tests.try(owner_u, 'owner@cn.example', format($q$select public.save_venue_discount_limits(%L, '{"server_max_percent":40,"manager_max_percent":30}'::jsonb)::text$q$, venue_a)), 'ERROR: a server cannot be allowed a bigger discount than a manager');
  perform tests.assert_eq('...and more free bottles than the managers'' pool', tests.try(owner_u, 'owner@cn.example', format($q$select public.save_venue_discount_limits(%L, '{"server_free_bottles_per_night":5,"manager_free_bottles_per_night":3}'::jsonb)::text$q$, venue_a)), 'ERROR: a server cannot be allowed more free bottles a night than the managers'' pool');
  perform tests.assert_eq('a percent above 100 is refused', tests.try(owner_u, 'owner@cn.example', format($q$select public.save_venue_discount_limits(%L, '{"manager_max_percent":101}'::jsonb)::text$q$, venue_a)), 'ERROR: the manager''s discount limit must be between 0 and 100');
  perform tests.assert_eq('a fraction is refused', tests.try(owner_u, 'owner@cn.example', format($q$select public.save_venue_discount_limits(%L, '{"server_max_percent":2.5}'::jsonb)::text$q$, venue_a)), 'ERROR: the server''s discount limit must be a whole number');
  perform tests.assert_eq('stacking must be true or false', tests.try(owner_u, 'owner@cn.example', format($q$select public.save_venue_discount_limits(%L, '{"allow_stacking":"yes"}'::jsonb)::text$q$, venue_a)), 'ERROR: allow discounts to combine must be true or false');
  perform tests.assert_eq('an unknown field is refused', tests.try(owner_u, 'owner@cn.example', format($q$select public.save_venue_discount_limits(%L, '{"tip":1}'::jsonb)::text$q$, venue_a)), 'ERROR: unknown field: tip');
  perform tests.assert_eq('none of those saved anything', (select count(*)::int from public.site_discount_limits), 0);
  perform tests.assert_eq('the owner sets the limits (a server 10 percent and 1 free bottle a night; a manager 30 percent and 3; no stacking)',
    tests.try(owner_u, 'owner@cn.example', format($q$select public.save_venue_discount_limits(%L, '{"server_max_percent":10,"manager_max_percent":30,"server_free_bottles_per_night":1,"manager_free_bottles_per_night":3}'::jsonb)::text$q$, venue_a)),
    '{"allow_stacking": false, "server_max_percent": 10, "manager_max_percent": 30, "server_free_bottles_per_night": 1, "manager_free_bottles_per_night": 3}');
  perform tests.assert_eq('...logged with before and after', (select count(*)::int from public.audit_log where action = 'venue.discount_limits_saved' and entity_id = venue_a::text and actor_id = owner_u), 1);
  perform tests.assert_eq('saving the same again changes and logs nothing', tests.try(owner_u, 'owner@cn.example', format($q$select (public.save_venue_discount_limits(%L, '{"server_max_percent":10}'::jsonb) ->> 'manager_max_percent')$q$, venue_a)), '30');
  perform tests.assert_eq('...really nothing logged', (select count(*)::int from public.audit_log where action = 'venue.discount_limits_saved' and entity_id = venue_a::text), 1);
  perform tests.assert_eq('the manager reads them', tests.try(mgr_a, 'mgra@cn.example', format($q$select (select server_max_percent || '/' || manager_max_percent || '/' || server_free_bottles_per_night || '/' || manager_free_bottles_per_night || '/' || allow_stacking from public.venue_discount_limits(%L))$q$, venue_a)), '10/30/1/3/false');
  perform tests.assert_eq('a server does not (the table call tells them what they may do)', tests.try(srv_1, 'srv1@cn.example', format($q$select count(*)::text from public.venue_discount_limits(%L)$q$, venue_a)), 'ERROR: not allowed');
  perform tests.assert_eq('another club has none set', tests.try(owner_u, 'owner@cn.example', format($q$select (select has_limits::text from public.venue_discount_limits(%L))$q$, venue_b)), 'false');

  ---------------------------------------------------------------- 3. what a person may do on this table
  perform tests.assert_eq('a server sees their limits and nothing used', (tests.runj(srv_1, 'srv1@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b1)) - 'bottle_subtotal_cents' - 'balance_due_cents'),
    '{"role": "server", "max_percent": 10, "limits_set": true, "allow_stacking": false, "discounted_cents": 0, "free_bottles_used": 0, "free_bottles_allowed": 1}'::jsonb);
  perform tests.assert_eq('...and the table''s figures', (tests.runj(srv_1, 'srv1@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b1)) ->> 'bottle_subtotal_cents') || '/' || (tests.runj(srv_1, 'srv1@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b1)) ->> 'balance_due_cents'), '10000/15000');
  perform tests.assert_eq('a manager sees theirs', (tests.runj(mgr_a, 'mgra@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b1)) ->> 'role') || ':' || (tests.runj(mgr_a, 'mgra@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b1)) ->> 'max_percent'), 'manager:30');
  perform tests.assert_eq('the owner has no limit', (tests.runj(owner_u, 'owner@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b1)) ->> 'role') || ':' || (tests.runj(owner_u, 'owner@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b1)) ->> 'max_percent'), 'owner:100');
  foreach who in array others loop
    perform tests.assert_eq('the table''s limits are refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_concession_limits(%L)::text$q$, b1)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('the owner has no limit even at a club that has set none (limits_set is true for the owner)', (tests.runj(owner_u, 'owner@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b_b)) ->> 'limits_set'), 'true');

  ---------------------------------------------------------------- 4. a discount within the person's own limit is applied at once
  perform tests.assert_eq('a server gives 10 percent of the table''s bottles (10000): 1000, applied', tests.disc(srv_1, 'srv1@cn.example', b1, 'percent', 10), 'applied:1000:10');
  perform tests.assert_eq('...the table owes that much less, and the discount is recorded', tests.total(b1), '19000/1000');
  c1 := (select id from public.site_concessions where booking_id = b1);
  perform tests.assert_eq('...who gave it, in what role, that nobody had to approve it, and the night', (select requested_by = srv_1 and requested_role = 'server' and decided_by is null and status = 'applied' and business_night = night from public.site_concessions where id = c1), true);
  perform tests.assert_eq('...and it is logged', (select count(*)::int from public.audit_log where action = 'concession.applied' and entity_id = c1::text and actor_id = srv_1), 1);
  perform tests.assert_eq('a second discount on the same table is refused while discounts do not combine', tests.disc(srv_1, 'srv1@cn.example', b1, 'percent', 5), 'ERROR: this table already has a discount: discounts do not combine at this club');
  perform tests.assert_eq('...also for the manager', tests.disc(mgr_a, 'mgra@cn.example', b1, 'percent', 5), 'ERROR: this table already has a discount: discounts do not combine at this club');
  perform tests.assert_eq('...nothing changed', tests.total(b1), '19000/1000');
  foreach who in array others loop
    perform tests.assert_eq('a discount is refused to ' || who, tests.disc((select id from auth.users where email = who), who, b2, 'percent', 5), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot ask for a discount', format($q$select public.desk_request_discount(%L, 'percent', 5, 'No right at all')$q$, b2), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('a server of another table cannot', tests.disc(srv_2, 'srv2@cn.example', b2, 'percent', 5), 'ERROR: not allowed');
  perform tests.assert_eq('a manager''s own limit applies: 30 percent of 10000 is applied', tests.disc(mgr_a, 'mgra@cn.example', b2, 'percent', 30), 'applied:3000:30');
  perform tests.assert_eq('...and the table', tests.total(b2), '17000/3000');
  perform tests.assert_eq('an amount is turned into the percent it is, rounded up: 2500 of 10000 is 25', tests.disc(mgr_a, 'mgra@cn.example', b3, 'amount', 2500), 'applied:2500:25');
  perform tests.assert_eq('a server asking for 1001 of 10000 (10.01 percent, more than their 10) must wait', tests.disc(srv_1, 'srv1@cn.example', b4, 'amount', 1001), 'pending:1001:11');
  perform tests.assert_eq('...and nothing changed on the table while it waits', tests.total(b4), '20000/0');

  ---------------------------------------------------------------- 5. above the limit: waiting, and who may decide
  c1 := (select id from public.site_concessions where booking_id = b4);
  perform tests.assert_eq('the manager sees it waiting, and may decide it (it is within their 30 percent, and not theirs)', tests.pending_text(mgr_a, 'mgra@cn.example', venue_a), 'CN-TABLEFOUR discount -% 1001 by server decide=true');
  perform tests.assert_eq('the owner may decide it too', tests.pending_text(owner_u, 'owner@cn.example', venue_a), 'CN-TABLEFOUR discount -% 1001 by server decide=true');
  perform tests.assert_eq('a server cannot see what waits', tests.pending_text(srv_1, 'srv1@cn.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.pending_text(mgr_b, 'mgrb@cn.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('the person who asked cannot approve their own', tests.decide(srv_1, 'srv1@cn.example', c1, true), 'ERROR: not allowed');
  perform tests.assert_eq('a second manager approves it', tests.decide(mgr_a2, 'mgra2@cn.example', c1, true, ' Good regulars '), 'applied');
  perform tests.assert_eq('...the table owes that much less', tests.total(b4), '18999/1001');
  select * into k from public.site_concessions where id = c1;
  perform tests.assert_eq('...and the record says who approved, in what role, with the note', (k.decided_by = mgr_a2)::text || ':' || k.decided_role || ':' || k.decision_note || ':' || k.status, 'true:manager:Good regulars:applied');
  perform tests.assert_eq('a request is decided once', tests.decide(owner_u, 'owner@cn.example', c1, false, 'Changed my mind'), 'ERROR: this request has already been decided');
  perform tests.assert_eq('nothing waits any more', tests.pending_text(mgr_a, 'mgra@cn.example', venue_a), '(none)');

  -- more than a manager may approve: the owner decides
  perform tests.assert_eq('a server asks for 50 percent of table five''s 8000 bottles', tests.disc(srv_1, 'srv1@cn.example', b5, 'percent', 50), 'pending:4000:50');
  c3 := (select id from public.site_concessions where booking_id = b5);
  perform tests.assert_eq('a manager sees it but may not decide it', tests.pending_text(mgr_a, 'mgra@cn.example', venue_a), 'CN-TABLEFIVE discount 50% 4000 by server decide=false');
  perform tests.assert_eq('...and is told the owner decides', tests.decide(mgr_a, 'mgra@cn.example', c3, true), 'ERROR: this is more than a manager may approve: the owner decides');
  perform tests.assert_eq('the owner may', tests.pending_text(owner_u, 'owner@cn.example', venue_a), 'CN-TABLEFIVE discount 50% 4000 by server decide=true');
  perform tests.assert_eq('declining needs a reason', tests.decide(owner_u, 'owner@cn.example', c3, false), 'ERROR: say why it is declined, so the person can be told');
  perform tests.assert_eq('the owner declines it with a reason', tests.decide(owner_u, 'owner@cn.example', c3, false, ' Too generous tonight '), 'declined');
  perform tests.assert_eq('...nothing changed on the table', tests.total(b5), '8000/0');
  perform tests.assert_eq('...the decision is recorded', (select status || ':' || decided_role || ':' || decision_note from public.site_concessions where id = c3), 'declined:owner:Too generous tonight');
  perform tests.assert_eq('a declined discount frees the table for another request', tests.disc(srv_1, 'srv1@cn.example', b5, 'percent', 10), 'applied:800:10');
  -- a manager's own request above their limit waits for the owner, and cannot be approved by the same manager or another one
  perform tests.assert_eq('a manager asks for 40 percent of table seven''s 10000: above their 30', tests.disc(mgr_a, 'mgra@cn.example', b7, 'percent', 40), 'pending:4000:40');
  c4 := (select id from public.site_concessions where booking_id = b7);
  perform tests.assert_eq('they cannot approve their own', tests.decide(mgr_a, 'mgra@cn.example', c4, true), 'ERROR: you cannot approve your own request: another manager or the owner decides');
  perform tests.assert_eq('another manager cannot either (it is above a manager''s limit)', tests.decide(mgr_a2, 'mgra2@cn.example', c4, true), 'ERROR: this is more than a manager may approve: the owner decides');
  perform tests.assert_eq('the owner approves it', tests.decide(owner_u, 'owner@cn.example', c4, true), 'applied');
  perform tests.assert_eq('...and the table', tests.total(b7), '16000/4000');
  perform tests.assert_eq('the CMS list names the owner as the approver', tests.try(admin_u, 'admin@test.example', format($q$select (select decided_role from public.cms_concessions('applied') where concession_id = %L)$q$, c4)), 'owner');

  ---------------------------------------------------------------- 6. what a discount can never be
  perform tests.assert_eq('more than the table still owes (3000 owed, nothing left after the 3000 paid)', tests.disc(owner_u, 'owner@cn.example', b6, 'percent', 10), 'ERROR: a discount of 3.00 is more than this table still owes (0.00)');
  perform tests.assert_eq('more than the bottles come to', tests.disc(mgr_a, 'mgra@cn.example', b_free, 'amount', 5001), 'ERROR: a discount cannot be more than the table''s bottles (50.00)');
  perform tests.assert_eq('a table with no bottles has nothing to discount', tests.disc(mgr_a, 'mgra@cn.example', b_zero, 'percent', 5), 'ERROR: there are no bottles on this table to discount');
  perform tests.assert_eq('a kind must be chosen', tests.disc(mgr_a, 'mgra@cn.example', b_free, 'fixed', 5), 'ERROR: choose a percent or an amount');
  perform tests.assert_eq('a percent between 1 and 100', tests.disc(mgr_a, 'mgra@cn.example', b_free, 'percent', 0), 'ERROR: a percent discount is between 1 and 100');
  perform tests.assert_eq('...not above', tests.disc(mgr_a, 'mgra@cn.example', b_free, 'percent', 101), 'ERROR: a percent discount is between 1 and 100');
  perform tests.assert_eq('an amount of at least a cent', tests.disc(mgr_a, 'mgra@cn.example', b_free, 'amount', 0), 'ERROR: how much is the discount?');
  perform tests.assert_eq('a reason of a few words', tests.disc(mgr_a, 'mgra@cn.example', b_free, 'percent', 5, 'x'), 'ERROR: give a reason of 3 to 300 characters');
  perform tests.assert_eq('only a confirmed booking', tests.disc(mgr_a, 'mgra@cn.example', b_pend, 'percent', 5), 'ERROR: only a confirmed booking can have a discount or a free bottle');
  perform tests.assert_eq('not a table that has been closed out', tests.disc(mgr_a, 'mgra@cn.example', b_closed, 'percent', 5), 'ERROR: this table has already been closed out');
  perform tests.assert_eq('another club''s table is "not allowed" for this club''s manager', tests.disc(mgr_a, 'mgra@cn.example', b_b, 'percent', 5), 'ERROR: not allowed');
  perform tests.assert_eq('...but the owner of both clubs may, with no limits set at that club', tests.disc(owner_u, 'owner@cn.example', b_b, 'percent', 5), 'applied:250:5');
  insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, report) values (venue_a, night, 'closed', owner_u, now(), '{}'::jsonb);
  perform tests.assert_eq('nothing can be given on a closed night', tests.disc(mgr_a, 'mgra@cn.example', b_free, 'percent', 5), 'ERROR: this night has been closed, so nothing can be given on it');
  delete from public.site_night_closes where venue_id = venue_a;

  ---------------------------------------------------------------- 7. taking a discount back
  c1 := (select id from public.site_concessions where booking_id = b2);
  perform tests.assert_eq('a server cannot take a discount back', tests.try(srv_1, 'srv1@cn.example', format($q$select public.desk_void_concession(%L, 'Changed my mind')$q$, c1)), 'ERROR: not allowed');
  perform tests.assert_eq('a reason is needed', tests.try(mgr_a, 'mgra@cn.example', format($q$select public.desk_void_concession(%L, ' ')$q$, c1)), 'ERROR: say why it is taken back');
  perform tests.assert_eq('a manager takes it back', tests.try(mgr_a, 'mgra@cn.example', format($q$select public.desk_void_concession(%L, 'Guest paid in full')$q$, c1)), 'voided');
  perform tests.assert_eq('...what the table owes goes back up, and the discount stops counting', tests.total(b2), '20000/0');
  perform tests.assert_eq('...taking it back twice changes nothing', tests.try(mgr_a, 'mgra@cn.example', format($q$select public.desk_void_concession(%L, 'Again')$q$, c1)), 'voided');
  perform tests.assert_eq('...really nothing changed', tests.total(b2), '20000/0');
  perform tests.assert_eq('a declined or waiting one cannot be taken back', tests.try(mgr_a, 'mgra@cn.example', format($q$select public.desk_void_concession(%L, 'Not applied')$q$, c3)), 'ERROR: only something that has been applied can be taken back');
  perform tests.assert_eq('after it is taken back a new discount can be given (the old one no longer counts)', tests.disc(srv_1, 'srv1@cn.example', b2, 'percent', 5), 'applied:500:5');
  update public.site_table_bookings set reconciled_at = now() where id = b7;
  perform tests.assert_eq('a table that is closed out cannot have a discount taken back', tests.try(mgr_a, 'mgra@cn.example', format($q$select public.desk_void_concession(%L, 'Too late')$q$, c4)), 'ERROR: this table has already been closed out');
  update public.site_table_bookings set reconciled_at = null where id = b7;

  ---------------------------------------------------------------- 8. when the owner allows discounts to combine
  perform tests.try(owner_u, 'owner@cn.example', format($q$select public.save_venue_discount_limits(%L, '{"allow_stacking":true}'::jsonb)::text$q$, venue_a));
  perform tests.assert_eq('a second discount on a table is now allowed', tests.disc(mgr_a, 'mgra@cn.example', b3, 'percent', 5), 'applied:500:5');
  perform tests.assert_eq('...and both count', tests.total(b3), '17000/3000');
  perform tests.try(owner_u, 'owner@cn.example', format($q$select public.save_venue_discount_limits(%L, '{"allow_stacking":false}'::jsonb)::text$q$, venue_a));

  ---------------------------------------------------------------- 9. free bottles
  r := tests.free(srv_1, 'srv1@cn.example', b_free, bt_vodka, 1);
  perform tests.assert_eq('a server gives their one free bottle: applied, worth 30.00', r, 'applied:3000');
  perform tests.assert_eq('...it is a real bottle line at no charge, still to be prepared', (select bottle_name || ':' || line_total_cents || ':' || payment_status || ':' || service_status || ':' || is_addon::text || ':' || quantity from public.site_table_booking_bottles where booking_id = b_free and unit_price_cents = 0), 'Vodka:0:paid:awaiting_prep:true:1');
  perform tests.assert_eq('...the table owes the same', tests.total(b_free), '5000/0');
  perform tests.assert_eq('...the free bottle is recorded with its value, who and when', (select kind || ':' || amount_cents || ':' || quantity || ':' || requested_role || ':' || (line_id is not null)::text || ':' || status from public.site_concessions where booking_id = b_free), 'free_bottle:3000:1:server:true:applied');
  perform tests.assert_eq('the server has used their allowance tonight', (tests.runj(srv_1, 'srv1@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b_free)) ->> 'free_bottles_used'), '1');
  perform tests.assert_eq('a second free bottle from the same server must wait for a manager', tests.free(srv_1, 'srv1@cn.example', b_free2, bt_vodka, 1), 'pending:3000');
  c2 := (select id from public.site_concessions where booking_id = b_free2);
  perform tests.assert_eq('...the manager sees it and may decide it (the pool has 3, none used)', tests.pending_text(mgr_a, 'mgra@cn.example', venue_a), 'CN-FREETABLETWO free_bottle -% 3000 by server decide=true');
  perform tests.assert_eq('...nothing was added to the table yet', (select count(*)::int from public.site_table_booking_bottles where booking_id = b_free2 and unit_price_cents = 0), 0);
  perform tests.assert_eq('the manager approves it', tests.decide(mgr_a, 'mgra@cn.example', c2, true), 'applied');
  perform tests.assert_eq('...now the bottle is on the table', (select count(*)::int from public.site_table_booking_bottles where booking_id = b_free2 and unit_price_cents = 0), 1);
  perform tests.assert_eq('...it came out of the managers'' pool, not the server''s own allowance', (tests.runj(mgr_a, 'mgra@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b_free)) ->> 'free_bottles_used') || '/' || (tests.runj(srv_1, 'srv1@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b_free)) ->> 'free_bottles_used'), '1/1');
  perform tests.assert_eq('a manager gives 2 more from the pool (1 used of 3): applied', tests.free(mgr_a, 'mgra@cn.example', b_stock, bt_vodka, 2), 'applied:6000');
  perform tests.assert_eq('one more would pass the pool (3 used of 3, then 4): it waits', tests.free(mgr_a2, 'mgra2@cn.example', b_stock, bt_vodka, 1), 'pending:3000');
  c5 := (select id from public.site_concessions where booking_id = b_stock and status = 'pending');
  perform tests.assert_eq('the manager who did not ask is told the pool is used up', tests.decide(mgr_a, 'mgra@cn.example', c5, true), 'ERROR: this is more than the managers'' free bottles for the night: the owner decides');
  perform tests.assert_eq('the pending list says a manager cannot decide it', tests.pending_text(mgr_a, 'mgra@cn.example', venue_a), 'CN-STOCKTABLE free_bottle -% 3000 by manager decide=false');
  perform tests.assert_eq('the owner approves it (the owner''s are not counted in the pool)', tests.decide(owner_u, 'owner@cn.example', c5, true), 'applied');
  perform tests.assert_eq('...the pool is still 3 used, not 4', (tests.runj(mgr_a, 'mgra@cn.example', format($q$select public.desk_concession_limits(%L)$q$, b_stock)) ->> 'free_bottles_used'), '3');

  perform tests.assert_eq('a free bottle on another night starts with a fresh allowance', tests.free(srv_1, 'srv1@cn.example', b_next, bt_vodka, 1), 'applied:3000');
  perform tests.assert_eq('a bottle that is sold out is refused', tests.free(owner_u, 'owner@cn.example', b_free, bt_sold, 1), 'ERROR: that bottle is not available right now');
  perform tests.assert_eq('a bottle the club does not offer is refused', tests.free(owner_u, 'owner@cn.example', b_free, bt_off, 1), 'ERROR: that bottle is not available right now');
  perform tests.assert_eq('another club''s bottle is not found', tests.free(owner_u, 'owner@cn.example', b_free, bt_b, 1), 'ERROR: bottle not found');
  perform tests.assert_eq('at least one', tests.free(owner_u, 'owner@cn.example', b_free, bt_vodka, 0), 'ERROR: how many bottles?');
  perform tests.assert_eq('...not a hundred and one', tests.free(owner_u, 'owner@cn.example', b_free, bt_vodka, 101), 'ERROR: how many bottles?');
  perform tests.assert_eq('a reason of a few words', tests.free(owner_u, 'owner@cn.example', b_free, bt_vodka, 1, 'x'), 'ERROR: give a reason of 3 to 300 characters');
  perform tests.assert_eq('only a confirmed booking', tests.free(owner_u, 'owner@cn.example', b_pend, bt_vodka, 1), 'ERROR: only a confirmed booking can have a discount or a free bottle');
  perform tests.assert_eq('not a closed-out table', tests.free(owner_u, 'owner@cn.example', b_closed, bt_vodka, 1), 'ERROR: this table has already been closed out');
  foreach who in array others loop
    perform tests.assert_eq('a free bottle is refused to ' || who, tests.free((select id from auth.users where email = who), who, b_free, bt_vodka, 1), 'ERROR: not allowed');
  end loop;
  -- stock: 5 Patron in stock; five already on paid bookings' lines? none yet by bottle id. Free bottles count like any other.
  perform tests.assert_eq('the owner gives 4 of the 5 Patron in stock', tests.free(owner_u, 'owner@cn.example', b_owner, bt_patron, 4), 'applied:20000');
  perform tests.assert_eq('...only 1 is left, so 2 is refused', tests.free(owner_u, 'owner@cn.example', b_free2, bt_patron, 2), 'ERROR: only 1 of that bottle are left');
  perform tests.assert_eq('...and 1 is fine', tests.free(owner_u, 'owner@cn.example', b_free2, bt_patron, 1), 'applied:5000');
  perform tests.assert_eq('...then none is left', tests.free(owner_u, 'owner@cn.example', b_free2, bt_patron, 1), 'ERROR: only 0 of that bottle are left');

  -- taking a free bottle back
  c3 := (select id from public.site_concessions where booking_id = b_free and kind = 'free_bottle');
  update public.site_table_booking_bottles set service_status = 'served' where booking_id = b_free and unit_price_cents = 0;
  perform tests.assert_eq('a free bottle that has been served cannot be taken back', tests.try(mgr_a, 'mgra@cn.example', format($q$select public.desk_void_concession(%L, 'Wrong table')$q$, c3)), 'ERROR: that bottle has already been served, so it cannot be taken back');
  update public.site_table_booking_bottles set service_status = 'awaiting_prep' where booking_id = b_free and unit_price_cents = 0;
  perform tests.assert_eq('one that has not is cancelled and recorded as taken back', tests.try(mgr_a, 'mgra@cn.example', format($q$select public.desk_void_concession(%L, 'Wrong table')$q$, c3)), 'voided');
  perform tests.assert_eq('...the line is cancelled with the reason', (select (cancelled_at is not null)::text || ':' || cancellation_reason from public.site_table_booking_bottles where booking_id = b_free and unit_price_cents = 0), 'true:Free bottle taken back: Wrong table');
  perform tests.assert_eq('...and a bottle that was taken back no longer counts against the server, so they may give one now', tests.free(srv_1, 'srv1@cn.example', b_free, bt_vodka, 1), 'applied:3000');

  ---------------------------------------------------------------- 10. the table's own list, and the CMS
  perform tests.assert_eq('the table''s list shows what was given, in order, with who and the status', tests.try(mgr_a, 'mgra@cn.example', format($q$select (select string_agg(kind || ':' || status || ':' || requested_role || ':' || coalesce(decided_by_name, '-'), ' | ' order by created_at, concession_id) from public.desk_booking_concessions(%L))$q$, b_free2)),
    'free_bottle:applied:server:Staff member | free_bottle:applied:owner:-');
  perform tests.assert_eq('the table''s own server can read it', tests.try(srv_1, 'srv1@cn.example', format($q$select count(*)::text from public.desk_booking_concessions(%L)$q$, b_free2)), '2');
  foreach who in array others loop
    perform tests.assert_eq('the table''s list is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select count(*)::text from public.desk_booking_concessions(%L)$q$, b_free2)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('a BottlesUp admin sees every club''s concessions', tests.try(admin_u, 'admin@test.example', $q$select (select count(*) from public.cms_concessions())::text$q$)::int > 10, true);
  perform tests.assert_eq('...and can filter them', tests.try(admin_u, 'admin@test.example', $q$select (select count(*) from public.cms_concessions('declined'))::text$q$), '1');
  perform tests.assert_eq('...a status that does not exist is refused', tests.try(admin_u, 'admin@test.example', $q$select count(*)::text from public.cms_concessions('maybe')$q$), 'ERROR: unknown status');
  perform tests.assert_eq('...and the limits of every club', tests.try(admin_u, 'admin@test.example', $q$select (select string_agg(venue_name || '=' || has_limits::text || '/' || manager_max_percent, ',' order by venue_name) from public.cms_discount_limits())$q$), 'Club A=true/30,Club B=false/0');
  foreach who in array array['mgra@cn.example', 'owner@cn.example', 'srv1@cn.example', 'rando@cn.example'] loop
    perform tests.assert_eq('the CMS views are refused to ' || who, tests.try((select id from auth.users where email = who), who, $q$select count(*)::text from public.cms_concessions()$q$) || '|' || tests.try((select id from auth.users where email = who), who, $q$select count(*)::text from public.cms_discount_limits()$q$), 'ERROR: not allowed|ERROR: not allowed');
  end loop;

  ---------------------------------------------------------------- 11. declarations and the closed tables
  perform tests.assert_true('every new function runs with its owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('venue_discount_limits', 'save_venue_discount_limits', 'desk_concession_limits', 'desk_request_discount', 'desk_request_free_bottle', 'desk_pending_concessions',
        'desk_decide_concession', 'desk_void_concession', 'desk_booking_concessions', 'cms_concessions', 'cms_discount_limits', 'concession_role', 'concession_base_cents', 'concession_server_used',
        'concession_pool_used', 'concession_booking_check', 'concession_apply')));
  perform tests.assert_true('the two tables have row level security on', (select bool_and(relrowsecurity) from pg_class where oid in ('public.site_discount_limits'::regclass, 'public.site_concessions'::regclass)));
  perform tests.login(mgr_a, 'mgra@cn.example');
  update public.site_table_bookings set staff_discount_cents = 5000, amount_total_cents = 1 where id = b1;   -- row level security lets this change no row
  perform tests.logout();
  perform tests.assert_eq('a discount cannot be written straight into a booking by the app (nothing changed)', tests.total(b1), '19000/1000');
  perform tests.login(mgr_a, 'mgra@cn.example');
  perform tests.assert_raises('the app cannot read the concessions directly', $q$select * from public.site_concessions$q$, 'permission denied');
  perform tests.assert_raises('...nor the limits', $q$select * from public.site_discount_limits$q$, 'permission denied');
  perform tests.assert_raises('...nor forge a concession', format($q$insert into public.site_concessions (venue_id, booking_id, kind, amount_cents, reason, requested_by, requested_role, status, business_night) values (%L, %L, 'discount', 100, 'forged', %L, 'manager', 'applied', current_date)$q$, venue_a, b1, mgr_a), 'permission denied');
  perform tests.assert_raises('the internal helpers are not callable by the app', format($q$select public.concession_apply(%L)$q$, c1), 'permission denied');
  perform tests.logout();
  perform tests.assert_raises('a free-bottle record must be a bottle with a count, and a discount must not be', format($q$insert into public.site_concessions (venue_id, booking_id, kind, amount_cents, quantity, reason, requested_by, requested_role, status, business_night) values (%L, %L, 'discount', 100, 2, 'odd', %L, 'manager', 'applied', current_date)$q$, venue_a, b1, mgr_a), 'violates check constraint');
end $$;

rollback;
