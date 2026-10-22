-- Refund policy and refund requests (20261023100000_refund_policy_and_requests.sql). What matters:
--   * only the club's owner or manager sets the policy and decides requests (not a server, the door, another club's manager, a stranger or a visitor); guests read a PUBLISHED
--     venue's policy before they pay; BottlesUp admins see everything and nobody else does;
--   * a policy is valid or refused with a plain sentence (more notice never gets less back); the percent for a given notice is exact at the boundaries; every booking carries the
--     policy it was made under and a later change never rewrites it;
--   * a request is for money that was actually paid and is still there, one open request per booking; a guest proves the booking with its code and e-mail and learns nothing otherwise;
--   * an approval is never for more than what is left, never online without an online payment, and needs a reason when it is more than the policy suggests; a decision is made once;
--   * a refund paid back at the club is recorded with evidence, once, and lowers what the booking has taken in the same step; an online one is claimed by one processor only;
--   * the closed tables cannot be read or written by the app; every refusal is a plain sentence and changes nothing.
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
-- a time slot whose arrival (in Toronto, where every venue is for now) is p_hours from now, and a booking at it
create function tests.mkslot(p_venue uuid, p_hours numeric, out slot uuid, out arrival_date date) language plpgsql security definer as $$
declare ts timestamp := (now() at time zone 'America/Toronto') + make_interval(secs => round(p_hours * 3600)::int);
begin
  ts := date_trunc('minute', ts);
  arrival_date := ts::date;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (p_venue, extract(dow from ts)::int, ts::time) returning id into slot;
end $$;
create function tests.mkb(p_venue uuid, p_type uuid, p_slot uuid, p_date date, p_name text, p_deposit int, p_paid int, p_status text default 'paid', p_intent text default null, p_checked_in boolean default false)
  returns uuid language sql security definer as $$
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, amount_paid_cents, status,
                                          confirmation_code, stripe_payment_intent_id, checked_in_at)
  values (p_venue, p_type, p_slot, p_date, p_name, lower(replace(p_name, ' ', '')) || '@rf.example', 2, p_deposit, p_deposit, p_paid, p_status,
          'RF-' || upper(replace(p_name, ' ', '')), p_intent, case when p_checked_in then now() end)
  returning id $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-000000000ad1';
  mgr_a constant uuid := '00000000-0000-0000-0000-000000000ad2';
  srv constant uuid := '00000000-0000-0000-0000-000000000ad3';
  door constant uuid := '00000000-0000-0000-0000-000000000ad5';
  mgr_b constant uuid := '00000000-0000-0000-0000-000000000ad6';
  rando constant uuid := '00000000-0000-0000-0000-000000000ad7';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';  -- a BottlesUp admin (cms_admins, from the fixtures)
  org uuid; venue_a uuid; venue_b uuid; t_a uuid; t_b uuid; slot_far uuid; slot_mid uuid; slot_near uuid; slot_past uuid; slot_b uuid; d_far date; d_mid date; d_near date; d_past date; d_b date;
  b_pre uuid; b_far uuid; b_mid uuid; b_near uuid; b_in uuid; b_part uuid; b_pend uuid; b_none uuid; b_other uuid; b_online uuid; b_cancelled uuid; b_big uuid;
  r1 uuid; r2 uuid; r3 uuid; rq uuid; refund uuid; j jsonb; n int; r text; k record; who text;
  others text[] := array['srv@rf.example', 'door@rf.example', 'mgrb@rf.example', 'rando@rf.example'];
begin
  insert into auth.users (id, email) values (owner_u, 'owner@rf.example'), (mgr_a, 'mgra@rf.example'), (srv, 'srv@rf.example'), (door, 'door@rf.example'), (mgr_b, 'mgrb@rf.example'), (rando, 'rando@rf.example');
  perform tests.login(owner_u, 'owner@rf.example');
  org := public.create_organization('Refund Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@rf.example', org, 'mgra@rf.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@rf.example', org, 'mgrb@rf.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@rf.example', org, 'srv@rf.example', 'server', venue_a, srv);
  perform tests.join_as(mgr_a, 'mgra@rf.example', org, 'door@rf.example', 'door', venue_a, door);
  update public.site_venues set status = 'published' where id = venue_a;   -- Club B stays unpublished
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 6, 0, 10000, 50) returning id into t_a;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_b, 'Terrace', 4, 0, 1000, 50) returning id into t_b;
  select slot, arrival_date into slot_far, d_far from tests.mkslot(venue_a, 120);
  select slot, arrival_date into slot_mid, d_mid from tests.mkslot(venue_a, 27);   -- 3 hours above the 24-hour rule: reading the clock in the wrong time zone (UTC, 4 to 5 hours off) would drop it under the rule
  select slot, arrival_date into slot_near, d_near from tests.mkslot(venue_a, 10);
  select slot, arrival_date into slot_past, d_past from tests.mkslot(venue_a, -2);
  select slot, arrival_date into slot_b, d_b from tests.mkslot(venue_b, 120);

  ---------------------------------------------------------------- 1. the percent for a notice, exact at the boundaries (pure)
  perform tests.assert_eq('a long notice gets the top rule', public.refund_policy_percent('[{"hours":48,"percent":100},{"hours":24,"percent":50}]'::jsonb, 200), 100);
  perform tests.assert_eq('exactly 48 hours is enough for the top rule', public.refund_policy_percent('[{"hours":48,"percent":100},{"hours":24,"percent":50}]'::jsonb, 48), 100);
  perform tests.assert_eq('a minute short of it gets the next', public.refund_policy_percent('[{"hours":48,"percent":100},{"hours":24,"percent":50}]'::jsonb, 47.98), 50);
  perform tests.assert_eq('exactly 24 hours gets the second', public.refund_policy_percent('[{"hours":48,"percent":100},{"hours":24,"percent":50}]'::jsonb, 24), 50);
  perform tests.assert_eq('less than that gets nothing', public.refund_policy_percent('[{"hours":48,"percent":100},{"hours":24,"percent":50}]'::jsonb, 23.9), 0);
  perform tests.assert_eq('...and after arrival too', public.refund_policy_percent('[{"hours":48,"percent":100},{"hours":24,"percent":50}]'::jsonb, -3), 0);
  perform tests.assert_eq('the order the rules are given in does not matter', public.refund_policy_percent('[{"hours":24,"percent":50},{"hours":48,"percent":100}]'::jsonb, 30), 50);
  perform tests.assert_eq('an empty policy refunds nothing', public.refund_policy_percent('[]'::jsonb, 500), 0);
  perform tests.assert_eq('so does a missing one', public.refund_policy_percent(null, 500), 0);
  perform tests.assert_eq('a rule for 0 hours means any time before arrival', public.refund_policy_percent('[{"hours":0,"percent":25}]'::jsonb, 0.5), 25);
  perform tests.assert_eq('...but not after it', public.refund_policy_percent('[{"hours":0,"percent":25}]'::jsonb, -0.5), 0);

  ---------------------------------------------------------------- 2. the policy: who, what is valid, what it says
  perform tests.assert_eq('a venue that never set a policy says so', tests.try(mgr_a, 'mgra@rf.example', format($q$select (select has_policy::text || ':' || lines[1] from public.venue_refund_policy(%L))$q$, venue_a)),
    'false:This venue has not set a refund policy: refunds are decided by the venue.');
  foreach who in array others loop
    perform tests.assert_eq('the policy is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select count(*)::text from public.venue_refund_policy(%L)$q$, venue_a)), 'ERROR: not allowed');
    perform tests.assert_eq('...and so is changing it, for ' || who, tests.try((select id from auth.users where email = who), who, format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[]}'::jsonb))::text$q$, venue_a)), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot change a policy', format($q$select public.save_venue_refund_policy(%L, '{"tiers":[]}'::jsonb)$q$, venue_a), 'permission denied');
  perform tests.logout();

  perform tests.assert_eq('the first save needs the rules', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"note":"x"}'::jsonb))::text$q$, venue_a)), 'ERROR: set the refund rules (an empty list means the deposit is not refundable)');
  perform tests.assert_eq('more than 6 rules is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":1,"percent":1},{"hours":2,"percent":2},{"hours":3,"percent":3},{"hours":4,"percent":4},{"hours":5,"percent":5},{"hours":6,"percent":6},{"hours":7,"percent":7}]}'::jsonb))::text$q$, venue_a)), 'ERROR: a refund policy can have 6 rules at most');
  perform tests.assert_eq('the same hours twice is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":24,"percent":50},{"hours":24,"percent":30}]}'::jsonb))::text$q$, venue_a)), 'ERROR: two refund rules cannot have the same hours of notice');
  perform tests.assert_eq('more notice getting less back is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":48,"percent":50},{"hours":24,"percent":100}]}'::jsonb))::text$q$, venue_a)), 'ERROR: giving more notice cannot get less back: a rule with fewer hours cannot refund a larger percent');
  perform tests.assert_eq('hours above 90 days are refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":2161,"percent":100}]}'::jsonb))::text$q$, venue_a)), 'ERROR: the hours of notice must be between 0 and 2160');
  perform tests.assert_eq('negative hours are refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":-1,"percent":100}]}'::jsonb))::text$q$, venue_a)), 'ERROR: the hours of notice must be between 0 and 2160');
  perform tests.assert_eq('a percent above 100 is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":24,"percent":101}]}'::jsonb))::text$q$, venue_a)), 'ERROR: the percent refunded must be between 0 and 100');
  perform tests.assert_eq('a fraction is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":24.5,"percent":100}]}'::jsonb))::text$q$, venue_a)), 'ERROR: the hours of notice must be a whole number');
  perform tests.assert_eq('a rule without its percent is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":24}]}'::jsonb))::text$q$, venue_a)), 'ERROR: each refund rule needs the hours of notice and the percent refunded');
  perform tests.assert_eq('a rule with a stray key is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":24,"percent":50,"fee":5}]}'::jsonb))::text$q$, venue_a)), 'ERROR: unknown field: fee');
  perform tests.assert_eq('rules that are not a list are refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":"all"}'::jsonb))::text$q$, venue_a)), 'ERROR: the refund rules must be a list');
  perform tests.assert_eq('an unknown field is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[],"fee":5}'::jsonb))::text$q$, venue_a)), 'ERROR: unknown field: fee');
  perform tests.assert_eq('a long note is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, jsonb_build_object('tiers', '[]'::jsonb, 'note', repeat('x', 301))))::text$q$, venue_a)), 'ERROR: the note must be 300 characters or fewer');
  perform tests.assert_eq('"no refund after arrival" must be true or false', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[],"no_refund_after_check_in":"yes"}'::jsonb))::text$q$, venue_a)), 'ERROR: no refund after arrival must be true or false');
  perform tests.assert_eq('none of those saved anything', (select count(*)::int from public.site_refund_policies), 0);

  r := tests.try(mgr_a, 'mgra@rf.example', format($q$select public.save_venue_refund_policy(%L, '{"tiers":[{"hours":24,"percent":50},{"hours":48,"percent":100}],"note":"Ask us at the door if something went wrong."}'::jsonb)::text$q$, venue_a));
  perform tests.assert_eq('the manager sets the policy: the lines are in order, most notice first', r,
    '{"Cancel at least 2 days before you arrive: the whole deposit is refunded.","Cancel at least 1 day before you arrive: 50% of the deposit is refunded.","Later than that: no refund.","Once the guests have arrived there is no refund.","Ask us at the door if something went wrong."}');
  perform tests.assert_eq('...it is stored in that order, as whole numbers', (select tiers::text from public.site_refund_policies where venue_id = venue_a), '[{"hours": 48, "percent": 100}, {"hours": 24, "percent": 50}]');
  perform tests.assert_eq('...and logged with before and after', (select count(*)::int from public.audit_log where action = 'venue.refund_policy_saved' and entity_id = venue_a::text and actor_id = mgr_a), 1);
  perform tests.assert_eq('saving the same again changes and logs nothing', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":48,"percent":100},{"hours":24,"percent":50}],"note":"Ask us at the door if something went wrong."}'::jsonb))::text$q$, venue_a)), '5');
  perform tests.assert_eq('...really nothing logged', (select count(*)::int from public.audit_log where action = 'venue.refund_policy_saved' and entity_id = venue_a::text), 1);
  perform tests.assert_eq('a later save of only the note keeps the rules', tests.try(owner_u, 'owner@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"note":"Message us first."}'::jsonb))::text$q$, venue_a)), '5');
  perform tests.assert_eq('...they are still there', (select jsonb_array_length(tiers)::text || ':' || note from public.site_refund_policies where venue_id = venue_a), '2:Message us first.');
  perform tests.assert_eq('the owner''s change is attributed to the owner', (select updated_by from public.site_refund_policies where venue_id = venue_a), owner_u);
  perform tests.assert_eq('a note can be removed (null)', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"note":null}'::jsonb))::text$q$, venue_a)), '4');
  perform tests.assert_eq('a rule for any time before arrival reads that way, with hours spoken plainly', tests.try(mgr_a, 'mgra@rf.example', format($q$select (public.save_venue_refund_policy(%L, '{"tiers":[{"hours":36,"percent":100},{"hours":1,"percent":25},{"hours":0,"percent":10}],"no_refund_after_check_in":false}'::jsonb))::text$q$, venue_a)),
    '{"Cancel at least 36 hours before you arrive: the whole deposit is refunded.","Cancel at least 1 hour before you arrive: 25% of the deposit is refunded.","Cancel any time before you arrive: 10% of the deposit is refunded."}');
  perform tests.assert_eq('an empty list says the deposit is not refundable', tests.try(mgr_a, 'mgra@rf.example', format($q$select (public.save_venue_refund_policy(%L, '{"tiers":[],"no_refund_after_check_in":true}'::jsonb))::text$q$, venue_a)), '{"The deposit is not refundable.","Once the guests have arrived there is no refund."}');
  perform tests.assert_eq('...and a save that does not mention the flag keeps it as it was', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":6,"percent":20}]}'::jsonb))::text$q$, venue_a)), '3');
  perform tests.assert_eq('...a rule of 0 percent reads "no refund"', tests.try(mgr_a, 'mgra@rf.example', format($q$select (public.save_venue_refund_policy(%L, '{"tiers":[{"hours":12,"percent":0}],"no_refund_after_check_in":true}'::jsonb))::text$q$, venue_a)),
    '{"Cancel at least 12 hours before you arrive: no refund.","Later than that: no refund.","Once the guests have arrived there is no refund."}');
  -- the policy the rest of the test uses
  perform tests.assert_eq('the real policy for the rest of the test', tests.try(mgr_a, 'mgra@rf.example', format($q$select cardinality(public.save_venue_refund_policy(%L, '{"tiers":[{"hours":48,"percent":100},{"hours":24,"percent":50}],"no_refund_after_check_in":true,"note":null}'::jsonb))::text$q$, venue_a)), '4');

  ---------------------------------------------------------------- 3. guests read it before they pay
  perform tests.login_anon();
  perform tests.assert_eq('a visitor reads a published venue''s policy', (select has_policy::text || ':' || cardinality(lines)::text from public.public_venue_refund_policy(venue_a)), 'true:4');
  perform tests.assert_eq('...an unpublished venue answers nothing', (select count(*)::int from public.public_venue_refund_policy(venue_b)), 0);
  perform tests.assert_eq('...nor does an unknown one', (select count(*)::int from public.public_venue_refund_policy(gen_random_uuid())), 0);
  perform tests.logout();
  update public.site_venues set status = 'published' where id = venue_b;
  perform tests.login_anon();
  perform tests.assert_eq('a published venue with no policy says the venue decides', (select has_policy::text || ':' || lines[1] from public.public_venue_refund_policy(venue_b)), 'false:This venue has not set a refund policy: refunds are decided by the venue.');
  perform tests.logout();
  update public.site_venues set status = 'draft' where id = venue_b;

  ---------------------------------------------------------------- 4. every booking carries the policy it was made under
  b_pre := tests.mkb(venue_b, t_b, slot_b, d_b, 'Before Policy', 1000, 1000);
  perform tests.assert_eq('a booking at a venue with no policy carries none', (select refund_policy is null from public.site_table_bookings where id = b_pre), true);
  b_far := tests.mkb(venue_a, t_a, slot_far, d_far, 'Far Away', 10000, 10000);
  b_mid := tests.mkb(venue_a, t_a, slot_mid, d_mid, 'Mid Range', 10000, 10000);
  b_near := tests.mkb(venue_a, t_a, slot_near, d_near, 'Close By', 10000, 10000);
  b_in := tests.mkb(venue_a, t_a, slot_past, d_past, 'Already In', 10000, 10000, 'paid', null, true);
  b_part := tests.mkb(venue_a, t_a, slot_far, d_far, 'Part Paid', 10000, 5000);
  b_pend := tests.mkb(venue_a, t_a, slot_far, d_far, 'Still Pending', 10000, 0, 'pending');
  b_none := tests.mkb(venue_a, t_a, slot_far, d_far, 'Nothing Paid', 10000, 0);
  b_online := tests.mkb(venue_a, t_a, slot_far, d_far, 'Online Payer', 10000, 10000, 'paid', 'pi_test_123');
  b_cancelled := tests.mkb(venue_a, t_a, slot_far, d_far, 'Cancelled One', 10000, 10000, 'cancelled');
  b_big := tests.mkb(venue_a, t_a, slot_far, d_far, 'Big Spender', 6000, 20000);
  b_other := tests.mkb(venue_b, t_b, slot_b, d_b, 'Other Club', 1000, 1000);
  perform tests.assert_eq('a booking made now carries the venue''s policy', (select refund_policy::text from public.site_table_bookings where id = b_far),
    '{"note": null, "tiers": [{"hours": 48, "percent": 100}, {"hours": 24, "percent": 50}], "no_refund_after_check_in": true}');
  update public.site_refund_policies set tiers = '[{"hours":1,"percent":10}]' where venue_id = venue_a;
  perform tests.assert_eq('...and a change of policy later does not touch it', (select jsonb_array_length(refund_policy -> 'tiers') from public.site_table_bookings where id = b_far), 2);
  perform tests.assert_eq('the earlier booking made without a policy is unchanged too', (select refund_policy is null from public.site_table_bookings where id = b_pre), true);
  update public.site_refund_policies set tiers = '[{"hours":48,"percent":100},{"hours":24,"percent":50}]' where venue_id = venue_a;
  perform tests.login_service();
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status)
    values (venue_a, t_a, slot_far, d_far, 'Edge Eve', 'eve@rf.example', 2, 10000, 'pending') returning id into r1;
  perform tests.logout();
  perform tests.assert_eq('a booking made by the website''s server (the service role) carries it too', (select (refund_policy -> 'tiers' -> 0 ->> 'hours') from public.site_table_bookings where id = r1), '48');
  delete from public.site_table_bookings where id = r1;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, refund_policy)
    values (venue_a, t_a, slot_far, d_far, 'Given Gia', 'gia@rf.example', 2, 10000, 'paid', '{"tiers":[{"hours":1,"percent":100}],"no_refund_after_check_in":false,"note":"given"}'::jsonb) returning id into r1;
  perform tests.assert_eq('a policy given with the booking is kept as given, not overwritten by the venue''s', (select refund_policy ->> 'note' from public.site_table_bookings where id = r1), 'given');
  delete from public.site_table_bookings where id = r1;
  perform tests.assert_eq('the earlier snapshots (deposit terms, included admissions) still work', (select (deposit_terms ->> 'recipient') from public.site_table_bookings where id = b_far), 'venue');

  ---------------------------------------------------------------- 5. what the booking's own policy says now
  perform tests.assert_eq('a booking made 5 days ahead: 100 percent, the whole deposit, nothing used yet', tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_far)) - 'hours_to_arrival' - 'policy_lines' - 'why',
    '{"status": "paid", "percent": 100, "checked_in": false, "paid_cents": 10000, "paid_online": false, "deposit_cents": 10000, "available_cents": 10000, "suggested_cents": 10000, "open_request_id": null}'::jsonb);
  perform tests.assert_eq('...27 hours ahead (3 above the second rule): half', (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_mid)) ->> 'percent') || ':' || (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_mid)) ->> 'suggested_cents'), '50:5000');
  perform tests.assert_eq('...10 hours ahead: nothing, and it says why', (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_near)) ->> 'percent') || ':' || (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_near)) ->> 'why'),
    '0:The notice given is shorter than the policy allows a refund for.');
  perform tests.assert_eq('...guests who have arrived: nothing, and it says why', (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_in)) ->> 'suggested_cents') || ':' || (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_in)) ->> 'why'),
    '0:The guests have already arrived, and the policy gives no refund after that.');
  perform tests.assert_eq('...a booking with no policy: no percent, the venue decides', (tests.runj(mgr_b, 'mgrb@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_pre)) -> 'percent')::text || ':' || (tests.runj(mgr_b, 'mgrb@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_pre)) ->> 'suggested_cents'), 'null:0');
  perform tests.assert_eq('the suggestion cannot be more than what was paid (paid 5000 of a 10000 deposit)', (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_part)) ->> 'suggested_cents'), '5000');
  perform tests.assert_eq('a booking paid online says so', (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_online)) ->> 'paid_online'), 'true');
  perform tests.assert_eq('the policy applies to the deposit, not to bottles paid on top (paid 20000, deposit 6000)', (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_big)) ->> 'suggested_cents') || ':' || (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_big)) ->> 'available_cents'), '6000:20000');
  perform tests.assert_eq('the options carry the policy in words', jsonb_array_length(tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_far)) -> 'policy_lines'), 4);
  foreach who in array others loop
    perform tests.assert_eq('the options are refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_refund_options(%L)::text$q$, b_far)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('another club''s booking is "not allowed"', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)::text$q$, b_other)), 'ERROR: not allowed');

  ---------------------------------------------------------------- 5b. the terms a booking was made under, for its page
  perform tests.assert_eq('the manager reads the terms of a booking: deposit terms, included admissions, the policy in words', (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_booking_terms(%L)$q$, b_far)) - 'refund_policy_lines'),
    '{"deposit_cents": 10000, "deposit_terms": {"default": true, "purpose": "reservation_fee", "venue_pct": 100, "recipient": "venue"}, "refund_policy_set": true, "included_admissions": null}'::jsonb);
  perform tests.assert_eq('...the policy lines are the ones the booking carries, not the venue''s current ones', jsonb_array_length(tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_booking_terms(%L) -> 'refund_policy_lines'$q$, b_far))), 4);
  perform tests.assert_eq('a booking made before any policy says the venue decides', (tests.runj(mgr_b, 'mgrb@rf.example', format($q$select public.desk_booking_terms(%L)$q$, b_pre)) -> 'refund_policy_lines' ->> 0), 'This venue has not set a refund policy: refunds are decided by the venue.');
  foreach who in array others loop
    perform tests.assert_eq('the terms are refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_booking_terms(%L)::text$q$, b_far)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('another club''s booking is "not allowed"', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_booking_terms(%L)::text$q$, b_other)), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read them', format($q$select public.desk_booking_terms(%L)$q$, b_far), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- 6. a member of staff records a request
  r1 := (tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, ' Guest was ill ')::text$q$, b_far)))::uuid;
  select * into k from public.site_refund_requests where id = r1;
  perform tests.assert_eq('the request is open, from staff, with the tidy reason, the policy''s percent and suggestion', k.status || ':' || k.requested_by_kind || ':' || k.reason || ':' || k.policy_percent || ':' || k.suggested_cents || ':' || (k.requested_by = mgr_a)::text, 'requested:staff:Guest was ill:100:10000:true');
  perform tests.assert_eq('...and it is logged', (select count(*)::int from public.audit_log where action = 'refund.requested' and entity_id = r1::text), 1);
  perform tests.assert_eq('the options now point at the open request', (tests.runj(mgr_a, 'mgra@rf.example', format($q$select public.desk_refund_options(%L)$q$, b_far)) ->> 'open_request_id'), r1::text);
  perform tests.assert_eq('a second request for the same booking is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Asking again')::text$q$, b_far)), 'ERROR: a refund request for this booking is already open');
  perform tests.assert_eq('a reason is needed', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'x')::text$q$, b_mid)), 'ERROR: give a reason of 3 to 500 characters');
  perform tests.assert_eq('...and not a novel', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, %L)::text$q$, b_mid, repeat('x', 501))), 'ERROR: give a reason of 3 to 500 characters');
  perform tests.assert_eq('an unpaid (pending) booking cannot be refunded', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Nothing to give back')::text$q$, b_pend)), 'ERROR: only a confirmed or cancelled booking can be refunded');
  perform tests.assert_eq('a booking that took no money has nothing to refund', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Nothing to give back')::text$q$, b_none)), 'ERROR: nothing is left to refund on this booking');
  perform tests.assert_eq('a cancelled booking that was paid can be refunded', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Booking was cancelled')::text$q$, b_cancelled)) ~ '^[0-9a-f-]{36}$', true);
  foreach who in array others loop
    perform tests.assert_eq('a request is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_request_refund(%L, 'No right')::text$q$, b_mid)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('another club''s booking is "not allowed"', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Not mine')::text$q$, b_other)), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot record a request as staff', format($q$select public.desk_request_refund(%L, 'No right')$q$, b_mid), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- 7. a guest asks, with the code and the e-mail
  perform tests.login_anon();
  perform tests.assert_eq('a guest with the code and the e-mail (any capitals) asks', (select public.guest_request_refund(' rf-closeby ', 'CLOSEBY@RF.EXAMPLE', 'I cannot come tonight')), 'Your request has been sent to the venue. They will look at it and update you.');
  perform tests.assert_eq('a wrong code learns nothing', tests.try(rando, 'rando@rf.example', $q$select public.guest_request_refund('RF-NOPE', 'closeby@rf.example', 'Please')$q$), 'ERROR: we could not find a booking with that code and e-mail');
  perform tests.logout();
  perform tests.assert_eq('...the same for a wrong e-mail', tests.try(rando, 'rando@rf.example', $q$select public.guest_request_refund('RF-CLOSEBY', 'someone@else.example', 'Please')$q$), 'ERROR: we could not find a booking with that code and e-mail');
  perform tests.assert_eq('...and for nothing at all', tests.try(rando, 'rando@rf.example', $q$select public.guest_request_refund('', '', 'Please')$q$), 'ERROR: we could not find a booking with that code and e-mail');
  perform tests.assert_eq('a second ask is told the venue is looking at it', tests.try(rando, 'rando@rf.example', $q$select public.guest_request_refund('RF-CLOSEBY', 'closeby@rf.example', 'Please')$q$), 'ERROR: you have already asked for a refund on this booking: the venue is looking at it');
  perform tests.assert_eq('a few words of reason are needed', tests.try(rando, 'rando@rf.example', $q$select public.guest_request_refund('RF-MIDRANGE', 'midrange@rf.example', 'x')$q$), 'ERROR: tell us why in a few words (up to 500 characters)');
  perform tests.assert_eq('a booking that took no money cannot be refunded', tests.try(rando, 'rando@rf.example', $q$select public.guest_request_refund('RF-NOTHINGPAID', 'nothingpaid@rf.example', 'Please')$q$), 'ERROR: there is nothing paid on this booking to refund');
  perform tests.assert_eq('the guest''s request is stored as theirs, with the policy''s answer for 10 hours of notice', (select requested_by_kind || ':' || policy_percent || ':' || suggested_cents || ':' || coalesce(requested_by::text, 'visitor') from public.site_refund_requests where booking_id = b_near), 'guest:0:0:visitor');
  perform tests.assert_eq('...and logged', (select count(*)::int from public.audit_log where action = 'refund.requested' and details ->> 'by' = 'guest' and details ->> 'booking_id' = b_near::text), 1);

  ---------------------------------------------------------------- 8. the list the manager sees
  perform tests.assert_eq('the manager''s list: the two open requests first, the staff one included', tests.try(mgr_a, 'mgra@rf.example', format($q$select (select string_agg(confirmation_code || '=' || status, ',' order by confirmation_code) from public.desk_refund_requests(%L, 'requested'))$q$, venue_a)),
    'RF-CANCELLEDONE=requested,RF-CLOSEBY=requested,RF-FARAWAY=requested');
  perform tests.assert_eq('...another club sees none of them', tests.try(mgr_b, 'mgrb@rf.example', format($q$select count(*)::text from public.desk_refund_requests(%L)$q$, venue_b)), '0');
  perform tests.assert_eq('...a status that does not exist is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select count(*)::text from public.desk_refund_requests(%L, 'maybe')$q$, venue_a)), 'ERROR: unknown status');
  foreach who in array others loop
    perform tests.assert_eq('the list is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select count(*)::text from public.desk_refund_requests(%L)$q$, venue_a)), 'ERROR: not allowed');
  end loop;
  r2 := (select id from public.site_refund_requests where booking_id = b_near);
  rq := (select id from public.site_refund_requests where booking_id = b_cancelled);

  ---------------------------------------------------------------- 9. deciding
  perform tests.assert_eq('declining needs a reason', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, false, null, null, ' ')$q$, r2)), 'ERROR: say why the refund is declined, so the guest can be told');
  perform tests.assert_eq('approve or decline must be chosen', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, null, null, null, 'x')$q$, r2)), 'ERROR: approve or decline');
  foreach who in array others loop
    perform tests.assert_eq('deciding is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_decide_refund(%L, false, null, null, 'No right')$q$, r2)), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot decide', format($q$select public.desk_decide_refund(%L, false, null, null, 'No right')$q$, r2), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('an unknown request is "not allowed"', tests.try(mgr_a, 'mgra@rf.example', $q$select public.desk_decide_refund(gen_random_uuid(), false, null, null, 'No such')$q$), 'ERROR: not allowed');
  perform tests.assert_eq('the manager declines the late request with a reason', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, false, null, null, ' Too close to the night ')$q$, r2)), 'declined');
  select * into k from public.site_refund_requests where id = r2;
  perform tests.assert_eq('...stored with who, when and why', k.status || ':' || (k.decided_by = mgr_a)::text || ':' || (k.decided_at is not null)::text || ':' || k.decision_note, 'declined:true:true:Too close to the night');
  perform tests.assert_eq('a request is decided once', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 100, 'club', 'again')$q$, r2)), 'ERROR: this request has already been decided');
  perform tests.assert_eq('a new request can be made for the booking after a decline', left(tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Asking again after the decline')::text$q$, b_near)), 1) <> 'E', true);
  delete from public.site_refund_requests where booking_id = b_near and status = 'requested';

  perform tests.assert_eq('approval needs a method', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 10000, null, null)$q$, r1)), 'ERROR: choose how it is paid back: online, or at the club');
  perform tests.assert_eq('...a real one', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 10000, 'cheque', null)$q$, r1)), 'ERROR: choose how it is paid back: online, or at the club');
  perform tests.assert_eq('an amount is needed', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, null, 'club', null)$q$, r1)), 'ERROR: how much is refunded?');
  perform tests.assert_eq('...at least a cent', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 0, 'club', null)$q$, r1)), 'ERROR: how much is refunded?');
  perform tests.assert_eq('never more than is left', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 10001, 'club', 'too much')$q$, r1)), 'ERROR: only 100.00 can still be refunded on this booking');
  perform tests.assert_eq('online needs an online payment', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 10000, 'online', null)$q$, r1)), 'ERROR: there is no online payment on this booking to return; record a refund made at the club instead');
  rq := (tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Guest wants it all back')::text$q$, b_mid)))::uuid;
  perform tests.assert_eq('more than the policy suggests needs a reason (27 hours of notice: the policy gives half, 50.00)', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 6000, 'club', null)$q$, rq)),
    'ERROR: this is more than the refund policy suggests (50.00): say why');
  perform tests.assert_eq('...a one-word reason is not enough', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 6000, 'club', 'ok')$q$, rq)), 'ERROR: this is more than the refund policy suggests (50.00): say why');
  perform tests.assert_eq('...the suggested amount itself needs none', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 5000, 'club', null)$q$, rq)), 'approved');
  perform tests.assert_eq('nothing was decided by any of those', (select status from public.site_refund_requests where id = r1), 'requested');
  perform tests.assert_eq('the manager approves the whole deposit at the club (what the policy says)', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 10000, 'club', null)$q$, r1)), 'approved');
  select * into k from public.site_refund_requests where id = r1;
  perform tests.assert_eq('...stored as approved with the amount, the method and who decided', k.status || ':' || k.approved_cents || ':' || k.method || ':' || (k.decided_by = mgr_a)::text, 'approved:10000:club:true');
  perform tests.assert_eq('...and logged', (select count(*)::int from public.audit_log where action = 'refund.approved' and entity_id = r1::text), 1);
  perform tests.assert_eq('what can still be refunded on that booking is now zero (it is claimed)', public.booking_refundable_cents(b_far), 0);

  ---------------------------------------------------------------- 10. paying it back at the club
  perform tests.assert_eq('the evidence is needed', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, null, null)::text$q$, r1)), 'ERROR: add the terminal or receipt reference, or a photo of the receipt, as evidence');
  foreach who in array others loop
    perform tests.assert_eq('recording it is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_complete_club_refund(%L, 'ref-1', null)::text$q$, r1)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('a declined request cannot be recorded', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, 'ref-1', null)::text$q$, r2)), 'ERROR: only an approved refund that is paid back at the club can be recorded here');
  perform tests.assert_eq('a receipt photo filed under another booking is refused', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, 'TERM-8841', %L)::text$q$, r1, gen_random_uuid()::text || '/refund-1.jpg')), 'ERROR: the receipt photo does not belong to this booking');
  perform tests.assert_eq('...so is one that is not under any booking, or climbs out of the folder', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, 'TERM-8841', 'receipts/refund-1.jpg')::text$q$, r1)) || '|' || tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, 'TERM-8841', %L)::text$q$, r1, b_far::text || '/../x/y.jpg')), 'ERROR: the receipt photo does not belong to this booking|ERROR: the receipt photo does not belong to this booking');
  perform tests.assert_eq('...and a path that is far too long', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, null, %L)::text$q$, r1, b_far::text || '/' || repeat('x', 300))), 'ERROR: the receipt photo does not belong to this booking');
  perform tests.assert_eq('nothing was recorded by those', (select count(*)::int from public.site_table_booking_refunds where booking_id = b_far), 0);
  refund := (tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, ' TERM-8841 ', %L)::text$q$, r1, b_far::text || '/refund-1.jpg')))::uuid;
  select * into k from public.site_table_booking_refunds where id = refund;
  perform tests.assert_eq('the refund record says what, how, why, with the evidence and who', k.refund_type || ':' || k.amount_cents || ':' || k.reason || ':' || k.pos_reference || ':' || k.receipt_photo_path || ':' || (k.recorded_by = mgr_a)::text, 'club:10000:Guest was ill:TERM-8841:' || b_far::text || '/refund-1.jpg:true');
  perform tests.assert_eq('the booking has taken in that much less', (select amount_paid_cents from public.site_table_bookings where id = b_far), 0);
  perform tests.assert_eq('the request is completed and points at the record', (select status || ':' || (refund_id = refund)::text || ':' || (completed_at is not null)::text from public.site_refund_requests where id = r1), 'completed:true:true');
  perform tests.assert_eq('the manager''s list now carries the reference and the receipt photo of the paid-back refund', tests.try(mgr_a, 'mgra@rf.example', format($q$select (select refund_reference || '|' || refund_receipt_path from public.desk_refund_requests(%L, 'completed') where request_id = %L)$q$, venue_a, r1)), 'TERM-8841|' || b_far::text || '/refund-1.jpg');
  perform tests.assert_eq('recording it again changes nothing and gives the same record', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, 'TERM-8841', null)::text$q$, r1)), refund::text);
  perform tests.assert_eq('...really no second record', (select count(*)::int from public.site_table_booking_refunds where booking_id = b_far), 1);
  perform tests.assert_eq('...and the money was not taken twice', (select amount_paid_cents from public.site_table_bookings where id = b_far), 0);
  perform tests.assert_eq('nothing is left to refund on that booking now', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Once more')::text$q$, b_far)), 'ERROR: nothing is left to refund on this booking');

  -- a part refund leaves the rest refundable, and a new request can follow
  r3 := (tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Guest wants part back')::text$q$, b_big)))::uuid;
  perform tests.assert_eq('more than the policy suggests, with a reason, is allowed (suggestion 60.00, asked for 90.00)', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 9000, 'club', ' Bottles were not served ')$q$, r3)), 'approved');
  perform tests.assert_eq('...and the reason is kept', (select decision_note from public.site_refund_requests where id = r3), 'Bottles were not served');
  perform tests.assert_true('...and recorded with a cash note as the evidence', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, 'CASH-1', null)::text$q$, r3)) ~ '^[0-9a-f-]{36}$');
  perform tests.assert_eq('the booking took 200.00 and gave back 90.00: 110.00 is left', (select amount_paid_cents from public.site_table_bookings where id = b_big), 11000);
  perform tests.assert_eq('a new request is allowed for what is left', left(tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'The rest too')::text$q$, b_big)), 5) <> 'ERROR', true);

  ---------------------------------------------------------------- 11. online refunds: one processor, one claim
  r1 := (tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Event cancelled by us')::text$q$, b_online)))::uuid;
  perform tests.assert_eq('the manager approves an online refund', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 10000, 'online', null)$q$, r1)), 'approved');
  perform tests.assert_eq('an online refund is not recorded as a club one', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_complete_club_refund(%L, 'ref', null)::text$q$, r1)), 'ERROR: only an approved refund that is paid back at the club can be recorded here');
  perform tests.assert_eq('a manager cannot claim it for processing', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.refund_request_begin(%L)::text$q$, r1)), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot either', tests.try(rando, 'rando@rf.example', format($q$select public.refund_request_begin(%L)::text$q$, r1)), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('...nor a visitor', format($q$select public.refund_request_begin(%L)$q$, r1), 'permission denied');
  perform tests.logout();
  j := tests.runj(admin_u, 'admin@test.example', format($q$select public.refund_request_begin(%L)$q$, r1));
  perform tests.assert_eq('a BottlesUp admin claims it: it says what to return', (j ->> 'amount_cents') || ':' || (j ->> 'booking_id'), '10000:' || b_online::text);
  perform tests.assert_eq('...and it is now being processed', (select status from public.site_refund_requests where id = r1), 'processing');
  perform tests.assert_eq('a second claim is refused, so the money cannot be returned twice', tests.try(admin_u, 'admin@test.example', format($q$select public.refund_request_begin(%L)::text$q$, r1)), 'ERROR: this refund is not an approved online refund waiting to be processed');
  perform tests.assert_eq('while it is being processed the money is still claimed: nothing more can be refunded on that booking', public.booking_refundable_cents(b_online), 0);
  perform tests.assert_eq('a finished club refund cannot be claimed as online', tests.try(admin_u, 'admin@test.example', format($q$select public.refund_request_begin(%L)::text$q$, r3)), 'ERROR: this refund is not an approved online refund waiting to be processed');
  b_cancelled := tests.mkb(venue_a, t_a, slot_far, d_far, 'Club Payer', 10000, 10000);
  r2 := (tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Paid at the club, returned at the club')::text$q$, b_cancelled)))::uuid;
  perform tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 10000, 'club', null)$q$, r2));
  perform tests.assert_eq('an approved club refund that is still waiting cannot be claimed as an online one either', tests.try(admin_u, 'admin@test.example', format($q$select public.refund_request_begin(%L)::text$q$, r2)), 'ERROR: this refund is not an approved online refund waiting to be processed');
  perform tests.assert_eq('...it is still approved, untouched', (select status from public.site_refund_requests where id = r2), 'approved');
  perform tests.assert_eq('only an admin finishes it', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.refund_request_finish(%L, null, true, null)$q$, r1)), 'ERROR: not allowed');
  refund := gen_random_uuid();
  insert into public.site_table_booking_refunds (id, booking_id, refund_type, amount_cents, reason, stripe_refund_id) values (refund, b_online, 'online', 10000, 'Event cancelled by us', 're_test_1');
  perform tests.assert_eq('finishing records it as completed with the refund', tests.try(admin_u, 'admin@test.example', format($q$select public.refund_request_finish(%L, %L, true, null)$q$, r1, refund)), 'completed');
  perform tests.assert_eq('...linked to the record', (select (refund_id = refund)::text || ':' || (completed_at is not null)::text from public.site_refund_requests where id = r1), 'true:true');
  perform tests.assert_eq('finishing again changes nothing and says how it ended', tests.try(admin_u, 'admin@test.example', format($q$select public.refund_request_finish(%L, null, false, 'late failure')$q$, r1)), 'completed');
  b_online := tests.mkb(venue_a, t_a, slot_far, d_far, 'Second Payer', 10000, 10000, 'paid', 'pi_test_456');
  r1 := (tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Double booked')::text$q$, b_online)))::uuid;
  perform tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_decide_refund(%L, true, 4000, 'online', 'Part back')$q$, r1));
  perform tests.login_service();
  perform public.refund_request_begin(r1);   -- the edge function's own key (the service role) may claim a refund too
  perform tests.logout();
  perform tests.assert_eq('when the payment provider fails it ends as failed, with the note', tests.try(admin_u, 'admin@test.example', format($q$select public.refund_request_finish(%L, null, false, ' Stripe: charge already refunded ')$q$, r1)), 'failed');
  perform tests.assert_eq('...the note is kept and the booking still holds its money', (select failure_note from public.site_refund_requests where id = r1) || ':' || (select amount_paid_cents from public.site_table_bookings where id = b_online), 'Stripe: charge already refunded:10000');
  perform tests.assert_eq('...and a new request is allowed after a failure', left(tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_request_refund(%L, 'Trying again')::text$q$, b_online)), 5) <> 'ERROR', true);
  perform tests.assert_eq('a request that is not being processed cannot be finished', tests.try(admin_u, 'admin@test.example', format($q$select public.refund_request_finish(%L, null, true, null)$q$, (select id from public.site_refund_requests where booking_id = b_online and status = 'requested'))), 'ERROR: this refund is not being processed');

  ---------------------------------------------------------------- 12. the CMS views, for BottlesUp admins only
  perform tests.assert_eq('an admin sees the requests of every club', tests.try(admin_u, 'admin@test.example', $q$select count(*)::text from public.cms_refund_requests()$q$)::int >= 5, true);
  perform tests.assert_eq('...with the guest''s e-mail', tests.try(admin_u, 'admin@test.example', $q$select (select guest_email from public.cms_refund_requests() where confirmation_code = 'RF-CLOSEBY')$q$), 'closeby@rf.example');
  perform tests.assert_eq('...filtered by status', tests.try(admin_u, 'admin@test.example', $q$select (select count(*) from public.cms_refund_requests('failed'))::text$q$), '1');
  perform tests.assert_eq('a status that does not exist is refused', tests.try(admin_u, 'admin@test.example', $q$select count(*)::text from public.cms_refund_requests('maybe')$q$), 'ERROR: unknown status');
  perform tests.assert_eq('the policies of every venue are listed, with the ones that never set one', tests.try(admin_u, 'admin@test.example', $q$select (select string_agg(venue_name || '=' || has_policy::text, ',' order by venue_name) from public.cms_refund_policies())$q$), 'Club A=true,Club B=false');
  foreach who in array others || array['mgra@rf.example', 'owner@rf.example'] loop
    perform tests.assert_eq('the CMS list is refused to ' || who, tests.try((select id from auth.users where email = who), who, $q$select count(*)::text from public.cms_refund_requests()$q$), 'ERROR: not allowed');
    perform tests.assert_eq('...and so are the CMS policies, for ' || who, tests.try((select id from auth.users where email = who), who, $q$select count(*)::text from public.cms_refund_policies()$q$), 'ERROR: not allowed');
  end loop;
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read the CMS list', $q$select * from public.cms_refund_requests()$q$, 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- 13. cancelling a booking (the check the edge function asks)
  perform tests.assert_eq('a manager may cancel a booking of their club', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_may_cancel_booking(%L)::text$q$, b_mid)), 'true');
  perform tests.assert_eq('the owner too', tests.try(owner_u, 'owner@rf.example', format($q$select public.desk_may_cancel_booking(%L)::text$q$, b_mid)), 'true');
  foreach who in array others loop
    perform tests.assert_eq('cancelling is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.desk_may_cancel_booking(%L)::text$q$, b_mid)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('another club''s booking is "not allowed"', tests.try(mgr_a, 'mgra@rf.example', format($q$select public.desk_may_cancel_booking(%L)::text$q$, b_other)), 'ERROR: not allowed');

  ---------------------------------------------------------------- 14. the table itself: a state that does not make sense is refused, and the app cannot reach the tables
  perform tests.assert_raises('an approved request must say how much and how', format($q$update public.site_refund_requests set status = 'approved' where id = %L$q$, (select id from public.site_refund_requests where status = 'requested' limit 1)), 'violates check constraint');
  perform tests.assert_raises('a declined request must say why', format($q$update public.site_refund_requests set status = 'declined', decided_at = now() where id = %L$q$, (select id from public.site_refund_requests where status = 'requested' limit 1)), 'violates check constraint');
  perform tests.assert_raises('two open requests for one booking cannot exist', format($q$insert into public.site_refund_requests (booking_id, venue_id, requested_by_kind, reason) select booking_id, venue_id, 'staff', 'Duplicate' from public.site_refund_requests where status = 'requested' limit 1$q$), 'duplicate key');
  perform tests.assert_true('every new function runs with its owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('venue_refund_policy', 'save_venue_refund_policy', 'public_venue_refund_policy', 'desk_refund_options', 'desk_request_refund', 'guest_request_refund',
        'desk_refund_requests', 'desk_decide_refund', 'desk_complete_club_refund', 'desk_may_cancel_booking', 'desk_booking_terms', 'refund_request_begin', 'refund_request_finish', 'cms_refund_requests', 'cms_refund_policies',
        'booking_hours_to_arrival', 'booking_refundable_cents', 'booking_refund_suggestion', 'site_table_bookings_snapshot_terms')));
  perform tests.assert_true('the two tables have row level security on', (select bool_and(relrowsecurity) from pg_class where oid in ('public.site_refund_policies'::regclass, 'public.site_refund_requests'::regclass)));
  perform tests.login(mgr_a, 'mgra@rf.example');
  perform tests.assert_raises('the app cannot read the requests directly', $q$select * from public.site_refund_requests$q$, 'permission denied');
  perform tests.assert_raises('...nor the policies', $q$select * from public.site_refund_policies$q$, 'permission denied');
  perform tests.assert_raises('...nor forge a request', format($q$insert into public.site_refund_requests (booking_id, venue_id, requested_by_kind, reason) values (%L, %L, 'staff', 'forged')$q$, b_mid, venue_a), 'permission denied');
  perform tests.assert_raises('the internal helpers are not callable by the app', format($q$select public.booking_refundable_cents(%L)$q$, b_mid), 'permission denied');
  perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read them either', $q$select * from public.site_refund_requests$q$, 'permission denied');
  perform tests.logout();
end $$;

rollback;
