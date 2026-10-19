-- Venue payment settings (20261020100000_venue_payment_rules.sql): the owner or manager of THIS venue reads them and changes the bottle payment mode, and
-- nothing else. What matters: nobody else can read or change them, only the three modes are accepted, a change is recorded, bookings that already
-- exist keep the terms they were made under, and "the deposit is credited against the bottle bill" cannot be changed from here.
begin;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000000d2';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000d3';
  door_a constant uuid := '00000000-0000-0000-0000-0000000000d4';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000000d5';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_r uuid; tok text; r record; n int; res text;
  ttype uuid; slot uuid; booking uuid;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@club.example'), (mgr_a, 'mgra@club.example'), (rival_u, 'rival@club2.example'), (door_a, 'doora@club.example'), (mgr_b, 'mgrb@club.example');
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

  -- a booking made under the venue's CURRENT terms (pay ahead, deposit not credited)
  perform tests.logout();
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 6, 0, 10000, 3) returning id into ttype;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue_a, 6, '22:00') returning id into slot;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, bottle_payment_choice, deposit_cents)
    values (venue_a, ttype, slot, current_date + 20, 'Hana', 'hana@test.example', 4, 10000, 'paid', 'pay_ahead', 10000) returning id into booking;

  ---------------------------------------------------------------- reading
  perform tests.login(owner_u, 'owner@club.example');
  select * into r from public.venue_payment_rules(venue_a);
  perform tests.assert_eq('the owner reads the bottle payment mode', r.bottle_payment_mode, 'pay_ahead');
  perform tests.assert_eq('...and whether the deposit is credited against the bottle bill', r.deposit_is_credit, false);
  perform tests.login(mgr_a, 'mgra@club.example');
  perform tests.assert_eq('the manager of that club reads them too', (select count(*) from public.venue_payment_rules(venue_a))::int, 1);
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('the manager of ANOTHER club of the same business cannot read them', format($q$select * from public.venue_payment_rules(%L)$q$, venue_a), 'not allowed');
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff cannot read them', format($q$select * from public.venue_payment_rules(%L)$q$, venue_a), 'not allowed');
  perform tests.login(rival_u, 'rival@club2.example');
  perform tests.assert_raises('a rival owner cannot read them', format($q$select * from public.venue_payment_rules(%L)$q$, venue_a), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call the read', format($q$select * from public.venue_payment_rules(%L)$q$, venue_a), 'permission denied');
  perform tests.assert_raises('...nor the save', format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":"both"}')$q$, venue_a), 'permission denied');

  ---------------------------------------------------------------- who may change
  perform tests.login(rival_u, 'rival@club2.example');
  perform tests.assert_raises('a rival owner cannot change them', format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":"both"}')$q$, venue_a), 'not allowed');
  perform tests.login(door_a, 'doora@club.example');
  perform tests.assert_raises('door staff cannot change them', format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":"both"}')$q$, venue_a), 'not allowed');
  perform tests.login(mgr_b, 'mgrb@club.example');
  perform tests.assert_raises('the manager of another club cannot change them', format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":"both"}')$q$, venue_a), 'not allowed');
  perform tests.logout();
  perform tests.assert_eq('nothing was changed by any of those', (select bottle_payment_mode from public.site_venues where id = venue_a), 'pay_ahead');

  ---------------------------------------------------------------- changing
  perform tests.login(mgr_a, 'mgra@club.example');
  res := public.save_venue_payment_rules(venue_a, '{"bottle_payment_mode":"pay_at_club"}');
  perform tests.assert_eq('a manager changes the mode and is told what it is now', res, 'pay_at_club');
  perform tests.login(owner_u, 'owner@club.example');
  res := public.save_venue_payment_rules(venue_a, '{"bottle_payment_mode":"both"}');
  perform tests.assert_eq('so does the owner', res, 'both');
  perform tests.assert_eq('...and the read agrees', (select bottle_payment_mode from public.venue_payment_rules(venue_a)), 'both');
  res := public.save_venue_payment_rules(venue_a, '{"bottle_payment_mode":" pay_ahead "}');
  perform tests.assert_eq('a value with stray spaces is understood', res, 'pay_ahead');
  perform tests.logout();
  select count(*) into n from public.audit_log where action = 'venue.payment_rules_saved' and (details ->> 'venue_id')::uuid = venue_a;
  perform tests.assert_eq('each real change is in the audit log', n, 3);
  perform tests.assert_eq('...with who and from what to what', (select details ->> 'bottle_payment_mode_from' || '>' || (details ->> 'bottle_payment_mode_to') from public.audit_log where action = 'venue.payment_rules_saved' and details ->> 'bottle_payment_mode_to' = 'pay_at_club'), 'pay_ahead>pay_at_club');
  perform tests.login(owner_u, 'owner@club.example');
  res := public.save_venue_payment_rules(venue_a, '{"bottle_payment_mode":"pay_ahead"}');
  perform tests.logout();
  select count(*) into n from public.audit_log where action = 'venue.payment_rules_saved' and (details ->> 'venue_id')::uuid = venue_a;
  perform tests.assert_eq('saving the same value again is not a change and is not logged', n, 3);
  perform tests.assert_eq('another club of the business was not touched', (select bottle_payment_mode from public.site_venues where id = venue_b), 'pay_ahead');

  ---------------------------------------------------------------- what is accepted
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('an unknown mode is refused', format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":"on_credit"}')$q$, venue_a), 'pay ahead, pay at the venue, or the customer chooses');
  perform tests.assert_raises('a missing mode is refused', format($q$select public.save_venue_payment_rules(%L, '{}')$q$, venue_a), 'choose how bottles are paid');
  perform tests.assert_raises('a null mode is refused', format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":null}')$q$, venue_a), 'choose how bottles are paid');
  perform tests.assert_raises('a mode that is not text is refused', format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":1}')$q$, venue_a), 'must be text');
  perform tests.assert_raises('no details at all is refused', format($q$select public.save_venue_payment_rules(%L, null)$q$, venue_a), 'details must be an object');
  perform tests.assert_raises('a list instead of an object is refused', format($q$select public.save_venue_payment_rules(%L, '[]')$q$, venue_a), 'details must be an object');
  perform tests.assert_raises('another field is refused', format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":"both","status":"published"}')$q$, venue_a), 'unknown field');
  perform tests.assert_raises('the venue''s tax rate cannot be set from here', format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":"both","tax_rate_bps":0}')$q$, venue_a), 'unknown field');
  perform tests.assert_raises('an unknown venue is refused as not allowed', $q$select public.save_venue_payment_rules(gen_random_uuid(), '{"bottle_payment_mode":"both"}')$q$, 'not allowed');

  ---------------------------------------------------------------- the deposit credit stays out of reach, with a reason
  perform tests.assert_raises('changing whether the deposit is credited is refused, saying why',
    format($q$select public.save_venue_payment_rules(%L, '{"deposit_is_credit":true}')$q$, venue_a), 'bookings that already exist are worked out with it');
  perform tests.assert_raises('...even together with a valid mode',
    format($q$select public.save_venue_payment_rules(%L, '{"bottle_payment_mode":"both","deposit_is_credit":true}')$q$, venue_a), 'ask the BottlesUp team');
  perform tests.logout();
  perform tests.assert_eq('...and nothing was changed', (select deposit_is_credit from public.site_venues where id = venue_a), false);
  perform tests.assert_eq('...not even the valid mode that came with it', (select bottle_payment_mode from public.site_venues where id = venue_a), 'pay_ahead');

  ---------------------------------------------------------------- bookings that exist keep their terms
  perform tests.login(owner_u, 'owner@club.example');
  perform public.save_venue_payment_rules(venue_a, '{"bottle_payment_mode":"pay_at_club"}');
  perform tests.logout();
  perform tests.assert_eq('only the club that was changed changed (another club of the same business still has its own mode)', (select bottle_payment_mode from public.site_venues where id = venue_b), 'pay_ahead');
  update public.site_venues set deposit_is_credit = true where id = venue_a;
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_eq('the read reports a deposit that is credited against the bottle bill as such', (select deposit_is_credit from public.venue_payment_rules(venue_a)), true);
  perform tests.logout();
  perform tests.assert_eq('an existing booking keeps the way its bottles were to be paid', (select bottle_payment_choice from public.site_table_bookings where id = booking), 'pay_ahead');
  perform tests.assert_eq('...and its deposit', (select deposit_cents from public.site_table_bookings where id = booking), 10000);

  ---------------------------------------------------------------- how the functions are declared
  perform tests.assert_true('both run with their owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('venue_payment_rules', 'save_venue_payment_rules')));
end $$;

rollback;
