-- Each venue's own time zone (20261027100000_venue_time_zone.sql). What matters: every venue that exists keeps reading as America/Toronto; only the venue's owner or manager can
-- set it (not a server, the door, another club's manager, a stranger or a visitor); only a place name the database knows is accepted (no abbreviations, no fixed offsets, nothing
-- odd); an empty zone puts the default back; the change is logged; one club's zone never changes another's; and the refund policy counts the hours before arrival in the club's own zone.
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
create function tests.zone(p_venue uuid) returns text language sql security definer as $$ select public.venue_timezone(p_venue) $$;
create function tests.stored(p_venue uuid) returns text language sql security definer as $$ select coalesce(time_zone, '(none)') from public.site_venues where id = p_venue $$;
-- hours to arrival of a booking whose slot is the given wall-clock time on the given date
create function tests.hours_for(p_venue uuid, p_type uuid, p_date date, p_time time) returns numeric language plpgsql security definer as $$
declare slot uuid; b uuid;
begin
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (p_venue, extract(dow from p_date)::int, p_time) returning id into slot;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
  values (p_venue, p_type, slot, p_date, 'Zone Guest', 'zone@tz.example', 2, 1000, 'paid', 'TZ-' || substr(md5(random()::text), 1, 6)) returning id into b;
  return public.booking_hours_to_arrival(b);
end $$;
create function tests.log_count(p_venue uuid) returns int language sql security definer as $$
  select count(*)::int from public.audit_log where action = 'venue_setup.time_zone_saved' and entity_id = p_venue::text $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-000000000be1';
  mgr_a constant uuid := '00000000-0000-0000-0000-000000000be2';
  srv constant uuid := '00000000-0000-0000-0000-000000000be3';
  door constant uuid := '00000000-0000-0000-0000-000000000be4';
  mgr_b constant uuid := '00000000-0000-0000-0000-000000000be5';
  rando constant uuid := '00000000-0000-0000-0000-000000000be6';
  org uuid; venue_a uuid; venue_b uuid; t_a uuid; r text; tomorrow date := (now() at time zone 'America/Toronto')::date + 5;
  toronto numeric; vancouver numeric; london numeric; others text[] := array['srv@tz.example', 'door@tz.example', 'mgrb@tz.example', 'rando@tz.example'];
  who text;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@tz.example'), (mgr_a, 'mgra@tz.example'), (srv, 'srv@tz.example'), (door, 'door@tz.example'), (mgr_b, 'mgrb@tz.example'), (rando, 'rando@tz.example');
  perform tests.login(owner_u, 'owner@tz.example');
  org := public.create_organization('Zone Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.logout();
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue_a, 'Booth', 6, 0, 10000, 50) returning id into t_a;
  perform tests.join_as(owner_u, 'owner@tz.example', org, 'mgra@tz.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@tz.example', org, 'mgrb@tz.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@tz.example', org, 'srv@tz.example', 'server', venue_a, srv);
  perform tests.join_as(mgr_a, 'mgra@tz.example', org, 'door@tz.example', 'door', venue_a, door);

  ---------------------------------------------------------------- nothing changes until someone sets it
  perform tests.assert_eq('a venue that never set a zone is read as Toronto', tests.zone(venue_a), 'America/Toronto');
  perform tests.assert_eq('...and nothing is stored for it', tests.stored(venue_a), '(none)');
  perform tests.assert_eq('a venue that does not exist is read as the default too', tests.zone(gen_random_uuid()), 'America/Toronto');
  toronto := tests.hours_for(venue_a, t_a, tomorrow, '20:00');

  ---------------------------------------------------------------- who may
  perform tests.assert_eq('the manager sets it and is told the zone now in force', tests.try(mgr_a, 'mgra@tz.example', format($q$select public.save_venue_time_zone(%L, 'America/Vancouver')$q$, venue_a)), 'America/Vancouver');
  perform tests.assert_eq('...it is stored', tests.stored(venue_a), 'America/Vancouver');
  perform tests.assert_eq('...and it is the one read', tests.zone(venue_a), 'America/Vancouver');
  perform tests.assert_eq('the owner may change it', tests.try(owner_u, 'owner@tz.example', format($q$select public.save_venue_time_zone(%L, 'America/Edmonton')$q$, venue_a)), 'America/Edmonton');
  foreach who in array others loop
    perform tests.assert_eq('the zone is refused to ' || who, tests.try((select id from auth.users where email = who), who, format($q$select public.save_venue_time_zone(%L, 'America/Halifax')$q$, venue_a)), 'ERROR: not allowed');
  end loop;
  perform tests.assert_eq('another club''s manager cannot, in particular', tests.try(mgr_b, 'mgrb@tz.example', format($q$select public.save_venue_time_zone(%L, 'America/Halifax')$q$, venue_a)), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select public.save_venue_time_zone(%L, 'America/Halifax')$q$, venue_a), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('nothing was changed by any refusal', tests.zone(venue_a), 'America/Edmonton');
  perform tests.assert_eq('another club is not touched by the first club''s change', tests.zone(venue_b), 'America/Toronto');

  ---------------------------------------------------------------- what is accepted
  foreach who in array array['America/Vancouver', 'America/St_Johns', 'Europe/London', 'America/Argentina/Buenos_Aires', 'Asia/Kolkata'] loop
    perform tests.assert_eq('a real place name is accepted: ' || who, tests.try(mgr_a, 'mgra@tz.example', format($q$select public.save_venue_time_zone(%L, %L)$q$, venue_a, who)), who);
  end loop;
  foreach who in array array['EST', 'UTC', 'GMT+5', 'Toronto', 'America/Not_A_Place', 'Europe/', '/America/Toronto', 'America/Toronto; drop table x', 'America//Toronto', 'a/b c'] loop
    perform tests.assert_eq('refused: ' || who, tests.try(mgr_a, 'mgra@tz.example', format($q$select public.save_venue_time_zone(%L, %L)$q$, venue_a, who)), 'ERROR: that time zone is not one the system knows (use a place name such as America/Toronto)');
  end loop;
  perform tests.assert_eq('a refused zone changed nothing', tests.zone(venue_a), 'Asia/Kolkata');
  perform tests.assert_eq('blanks around a good name are ignored', tests.try(mgr_a, 'mgra@tz.example', format($q$select public.save_venue_time_zone(%L, '  America/Toronto ')$q$, venue_a)), 'America/Toronto');
  perform tests.assert_eq('a venue that does not exist is refused like any other the person cannot reach', tests.try(owner_u, 'owner@tz.example', format($q$select public.save_venue_time_zone(%L, 'America/Toronto')$q$, gen_random_uuid())), 'ERROR: not allowed');

  ---------------------------------------------------------------- the default comes back
  perform tests.assert_eq('an empty zone puts the default back', tests.try(mgr_a, 'mgra@tz.example', format($q$select public.save_venue_time_zone(%L, '')$q$, venue_a)), 'America/Toronto');
  perform tests.assert_eq('...nothing is stored again', tests.stored(venue_a), '(none)');
  perform tests.assert_eq('so does null', tests.try(mgr_a, 'mgra@tz.example', format($q$select public.save_venue_time_zone(%L, null)$q$, venue_a)), 'America/Toronto');

  ---------------------------------------------------------------- the refund policy counts the hours in the club's own zone
  perform tests.assert_eq('the same wall-clock arrival, Toronto: the baseline', round(tests.hours_for(venue_a, t_a, tomorrow, '20:00'), 2), round(toronto, 2));
  -- Los Angeles, not Vancouver: the US and Canada change their clocks on the same days, so the difference is always 3 hours. British Columbia is moving to permanent UTC-07
  -- from 1 Nov 2026 (tzdata 2026b), so a newer time-zone database makes Vancouver only 2 hours behind Toronto from that day: this test failed in CI because of it.
  perform tests.try(mgr_a, 'mgra@tz.example', format($q$select public.save_venue_time_zone(%L, 'America/Los_Angeles')$q$, venue_a));
  vancouver := tests.hours_for(venue_a, t_a, tomorrow, '20:00');
  perform tests.assert_eq('8 pm in Los Angeles is 3 hours later than 8 pm in Toronto', round(vancouver - toronto, 1), 3.0);
  perform tests.try(mgr_a, 'mgra@tz.example', format($q$select public.save_venue_time_zone(%L, 'Europe/London')$q$, venue_a));
  london := tests.hours_for(venue_a, t_a, tomorrow, '20:00');
  perform tests.assert_eq('8 pm in London is 4 or 5 hours EARLIER than 8 pm in Toronto (the clocks change on different days)', round(toronto - london) in (4, 5), true);

  ---------------------------------------------------------------- the change is on record
  perform tests.assert_eq('every accepted change was logged, and no refused one (12 saves: manager, owner, five place names, trimmed name, empty, null, Los Angeles, London)', tests.log_count(venue_a), 12);
  perform tests.assert_eq('...and nothing was logged for the other club', tests.log_count(venue_b), 0);

  ---------------------------------------------------------------- the grants
  perform tests.assert_true('visitors cannot call it, and signed-in people can',
    not has_function_privilege('anon', 'public.save_venue_time_zone(uuid,text)', 'execute') and has_function_privilege('authenticated', 'public.save_venue_time_zone(uuid,text)', 'execute'));
  perform tests.assert_true('the reader stays internal', not has_function_privilege('authenticated', 'public.venue_timezone(uuid)', 'execute') and not has_function_privilege('anon', 'public.venue_timezone(uuid)', 'execute'));
end $$;

rollback;
