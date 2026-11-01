-- A deposit that is a combination (20261120100000_deposit_combination.sql). What matters: only the club's owner or manager of THAT club saves one; the three shares are whole percents that add up
-- to exactly 100 with at least two above 0, so no money is credited twice or left over; the credit share agrees with BottlesUp's credit switch both ways; the recipient rules are the
-- single purposes' rules; the terms are stored where every new booking copies them from and a booking that exists is never rewritten; saving the same again changes and logs nothing; the
-- single-purpose function still works and replaces a combination; every refusal is a plain sentence and changes nothing.
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
  return coalesce(r, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.save(p_user uuid, p_email text, p_venue uuid, p_json text) returns text language sql as $$
  select tests.try(p_user, p_email, format('select public.save_venue_deposit_combination(%L, %L::jsonb)::text', p_venue, p_json))
$$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-00000000f0d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-00000000f0d2';
  mgr_b constant uuid := '00000000-0000-0000-0000-00000000f0d3';
  srv_a constant uuid := '00000000-0000-0000-0000-00000000f0d4';
  other_owner constant uuid := '00000000-0000-0000-0000-00000000f0d5';
  rando constant uuid := '00000000-0000-0000-0000-00000000f0d6';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; venue_x uuid; t_a uuid; slot_a uuid; b1 uuid; b2 uuid;
  good constant text := '{"recipient":"venue","reservation_fee_pct":30,"minimum_spend_credit_pct":50,"admission_pct":20}';
  n_logs bigint;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@comb.example'), (mgr_a, 'mgra@comb.example'), (mgr_b, 'mgrb@comb.example'), (srv_a, 'srva@comb.example'),
    (other_owner, 'other@comb.example'), (rando, 'rando@comb.example');
  perform tests.login(owner_u, 'owner@comb.example');
  org := public.create_organization('Comb Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(other_owner, 'other@comb.example');
  org2 := public.create_organization('Other Co', 'venue_owner');
  venue_x := public.create_org_venue(org2, 'Other Club');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@comb.example', org, 'mgra@comb.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@comb.example', org, 'mgrb@comb.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(owner_u, 'owner@comb.example', org, 'srva@comb.example', 'server', venue_a, srv_a);

  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 8, 100000, 20000, 9) returning id into t_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label) values (venue_a, 6, '21:00', 'Evening') returning id into slot_a;
  -- BottlesUp's switch: club A credits the deposit toward the bottle bill, club B does not
  update public.site_venues set deposit_is_credit = true where id = venue_a;
  update public.site_venues set deposit_is_credit = false where id = venue_b;

  -- ---------------------------------------------------------------- who
  perform tests.assert_eq('the club''s manager saves a combination', tests.save(mgr_a, 'mgra@comb.example', venue_a, good),
    '{"parts": {"admission_pct": 20, "reservation_fee_pct": 30, "minimum_spend_credit_pct": 50}, "purpose": "combination", "recipient": "venue", "venue_pct": 100}');
  perform tests.assert_eq('and it is stored on the club, where new bookings copy it from', (select deposit_terms ->> 'purpose' from public.site_venues where id = venue_a), 'combination');
  perform tests.assert_eq('the owner can too (a different split)', tests.save(owner_u, 'owner@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":0,"minimum_spend_credit_pct":60,"admission_pct":40}') like '%"admission_pct": 40%', true);
  perform tests.assert_eq('another club''s manager cannot', tests.save(mgr_b, 'mgrb@comb.example', venue_a, good), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot', tests.save(srv_a, 'srva@comb.example', venue_a, good), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.save(rando, 'rando@comb.example', venue_a, good), 'ERROR: not allowed');
  perform tests.assert_eq('another business''s owner cannot', tests.save(other_owner, 'other@comb.example', venue_a, good), 'ERROR: not allowed');
  perform tests.assert_eq('nor can the manager of one club change another club of the same business', tests.save(mgr_a, 'mgra@comb.example', venue_b, '{"recipient":"venue","reservation_fee_pct":50,"minimum_spend_credit_pct":0,"admission_pct":50}'), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot call it', format($q$select public.save_venue_deposit_combination(%L, %L::jsonb)$q$, venue_a, good), 'permission denied');
  perform tests.logout();

  -- ---------------------------------------------------------------- the three shares
  perform tests.assert_eq('they have to add up to 100 (here 90)', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":30,"minimum_spend_credit_pct":40,"admission_pct":20}'),
    'ERROR: the three shares have to add up to 100 percent (they add up to 90 percent)');
  perform tests.assert_eq('...or 110', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":50,"minimum_spend_credit_pct":50,"admission_pct":10}'),
    'ERROR: the three shares have to add up to 100 percent (they add up to 110 percent)');
  perform tests.assert_eq('a share for each of the three has to be given', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":50,"minimum_spend_credit_pct":50}'),
    'ERROR: give a share for each of the three: the reservation fee, the minimum spend credit and admission (0 for none)');
  perform tests.assert_eq('no negative share', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":-10,"minimum_spend_credit_pct":60,"admission_pct":50}') like 'ERROR:%', true);
  perform tests.assert_eq('no share over 100', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":0,"minimum_spend_credit_pct":150,"admission_pct":-50}') like 'ERROR:%', true);
  perform tests.assert_eq('whole percents only', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":33.3,"minimum_spend_credit_pct":33.3,"admission_pct":33.4}') like 'ERROR:%', true);
  perform tests.assert_eq('a combination needs at least two parts', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":0,"minimum_spend_credit_pct":100,"admission_pct":0}'),
    'ERROR: a combination needs at least two of the three shares above 0; for a single purpose choose it on its own');
  perform tests.assert_eq('an unknown field is refused, not ignored', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":30,"minimum_spend_credit_pct":50,"admission_pct":20,"tip_pct":5}') like 'ERROR:%', true);

  -- ---------------------------------------------------------------- the credit switch, both ways
  perform tests.assert_eq('a credit share needs the credit switched on for the club (club B has it off)', tests.save(mgr_b, 'mgrb@comb.example', venue_b, good),
    'ERROR: part of the deposit would be a credit toward the bottle bill, but that is not switched on for this venue; give the credit share as 0, or ask the BottlesUp team to switch the credit on');
  perform tests.assert_true('...club B can combine a fee with admission instead', tests.save(mgr_b, 'mgrb@comb.example', venue_b, '{"recipient":"venue","reservation_fee_pct":50,"minimum_spend_credit_pct":0,"admission_pct":50}') not like 'ERROR%');
  perform tests.assert_eq('with the switch on, a combination with no credit share is refused (club A)', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":50,"minimum_spend_credit_pct":0,"admission_pct":50}'),
    'ERROR: the deposit is credited toward the bottle bill at this venue, so a combination needs a credit share above 0; ask the BottlesUp team if that should change');

  -- ---------------------------------------------------------------- who receives it (the single purposes' rules)
  perform tests.assert_eq('the organizer receiving everything means the venue''s share is 0', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"organizer","venue_pct":0,"reservation_fee_pct":30,"minimum_spend_credit_pct":50,"admission_pct":20}') like '%"venue_pct": 0%', true);
  perform tests.assert_eq('...and not any other share', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"organizer","venue_pct":40,"reservation_fee_pct":30,"minimum_spend_credit_pct":50,"admission_pct":20}'),
    'ERROR: when the organizer receives the deposit the venue''s share is 0 percent');
  perform tests.assert_eq('the venue keeping it means 100', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","venue_pct":60,"reservation_fee_pct":30,"minimum_spend_credit_pct":50,"admission_pct":20}'),
    'ERROR: when the venue keeps the deposit its share is 100 percent');
  perform tests.assert_eq('a split gives the venue 70', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"split","venue_pct":70,"reservation_fee_pct":30,"minimum_spend_credit_pct":50,"admission_pct":20}') like '%"venue_pct": 70%', true);
  perform tests.assert_eq('a split needs the venue''s share', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"split","reservation_fee_pct":30,"minimum_spend_credit_pct":50,"admission_pct":20}'),
    'ERROR: for a split give the venue''s share between 1 and 99 percent (the organizer gets the rest, so the two add up to 100)');
  perform tests.assert_eq('a recipient has to be chosen', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"reservation_fee_pct":30,"minimum_spend_credit_pct":50,"admission_pct":20}'),
    'ERROR: choose who receives the deposit: the venue, the approved organizer, or a split');
  perform tests.assert_eq('...a real one', tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"everyone","reservation_fee_pct":30,"minimum_spend_credit_pct":50,"admission_pct":20}'),
    'ERROR: choose who receives the deposit: the venue, the approved organizer, or a split');

  -- ---------------------------------------------------------------- bookings carry the terms they were made under
  perform tests.save(mgr_a, 'mgra@comb.example', venue_a, good);
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status)
    values (venue_a, t_a, slot_a, current_date + 40, 'Combo Cai', 'cai@comb.example', 4, 20000, 20000, 'paid') returning id into b1;
  perform tests.assert_eq('a booking made now carries the combination, parts and all', (select deposit_terms::text from public.site_table_bookings where id = b1),
    '{"parts": {"admission_pct": 20, "reservation_fee_pct": 30, "minimum_spend_credit_pct": 50}, "purpose": "combination", "recipient": "venue", "venue_pct": 100}');
  perform tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","reservation_fee_pct":10,"minimum_spend_credit_pct":80,"admission_pct":10}');
  perform tests.assert_eq('changing the shares later does NOT rewrite the booking made under the old ones', (select deposit_terms #>> '{parts,minimum_spend_credit_pct}' from public.site_table_bookings where id = b1), '50');
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, deposit_cents, status)
    values (venue_a, t_a, slot_a, current_date + 41, 'Later Lou', 'lou@comb.example', 4, 20000, 20000, 'paid') returning id into b2;
  perform tests.assert_eq('...but the next booking carries the new shares', (select deposit_terms #>> '{parts,minimum_spend_credit_pct}' from public.site_table_bookings where id = b2), '80');

  -- ---------------------------------------------------------------- saving the same again; the log; the single purposes
  select count(*) into n_logs from public.audit_log where action = 'venue.deposit_terms_saved' and entity_id = venue_a::text;
  perform tests.save(mgr_a, 'mgra@comb.example', venue_a, '{"recipient":"venue","venue_pct":100,"reservation_fee_pct":10,"minimum_spend_credit_pct":80,"admission_pct":10}');
  perform tests.assert_eq('saving the same again logs nothing', (select count(*) from public.audit_log where action = 'venue.deposit_terms_saved' and entity_id = venue_a::text), n_logs);
  perform tests.assert_true('a change is logged with before and after', exists (select 1 from public.audit_log where action = 'venue.deposit_terms_saved' and entity_id = venue_a::text and actor_id = mgr_a
    and details #>> '{to,purpose}' = 'combination' and details #>> '{from,purpose}' = 'combination'));
  perform tests.assert_eq('a single purpose can still be chosen, and it replaces the combination', tests.try(mgr_a, 'mgra@comb.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"minimum_spend_credit"}'::jsonb)::text$q$, venue_a)),
    '{"purpose": "minimum_spend_credit", "recipient": "venue", "venue_pct": 100}');
  perform tests.assert_eq('the single-purpose function does not accept "combination" as a purpose', tests.try(mgr_a, 'mgra@comb.example', format($q$select public.save_venue_deposit_terms(%L, '{"recipient":"venue","purpose":"combination"}'::jsonb)::text$q$, venue_a)),
    'ERROR: choose what the deposit is for: a reservation fee, a credit toward the minimum spend, or admission');
  perform tests.assert_eq('the terms read back as stored', tests.try(mgr_a, 'mgra@comb.example', format($q$select terms ->> 'purpose' from public.venue_deposit_terms(%L)$q$, venue_a)), 'minimum_spend_credit');
end $$;

rollback;
