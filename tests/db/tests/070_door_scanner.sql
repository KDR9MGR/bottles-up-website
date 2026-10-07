-- The scoped door scanner: invited door staff can admit tickets for their own event or club and nothing else.
-- Mirrors the existing check-in and entry-code tests (010, 020) and adds the scoping and the abuse cases.
begin;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000f1';
  door_v constant uuid := '00000000-0000-0000-0000-0000000000f2'; -- door person for the whole of Club A
  door_e constant uuid := '00000000-0000-0000-0000-0000000000f3'; -- door person for one event only
  rival_u constant uuid := '00000000-0000-0000-0000-0000000000f4';
  rival_door constant uuid := '00000000-0000-0000-0000-0000000000f5';
  organizer_u constant uuid := '00000000-0000-0000-0000-0000000000f6';
  window_door constant uuid := '00000000-0000-0000-0000-0000000000f7'; -- a door person whose window will end
  legacy_staff constant uuid := '00000000-0000-0000-0000-0000000000a1'; -- existing door_staff from the shared fixtures
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  e1 constant uuid := '00000000-0000-0000-0000-0000000000e1'; -- Future Night
  e2 constant uuid := '00000000-0000-0000-0000-0000000000e2'; -- Ended Event
  e3 constant uuid := '00000000-0000-0000-0000-0000000000e3'; -- ended an hour ago (no end date)
  e4 constant uuid := '00000000-0000-0000-0000-0000000000e4'; -- live, no end date
  b1 constant uuid := '00000000-0000-0000-0000-0000000000b1';
  b2 constant uuid := '00000000-0000-0000-0000-0000000000b2';
  org uuid; org2 uuid; porg uuid; venue_a uuid; venue_b uuid; venue_r uuid;
  ev_b uuid; ev_r uuid; tier_b uuid; tier_r uuid;
  tok text; tok_e text; tok_r text; tok_w text; mid_v uuid; mid_e uuid; mid_r uuid; mid_w uuid;
  r record; n int; txt text;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@club.example'), (door_v, 'doorv@club.example'), (door_e, 'doore@events.example'),
    (rival_u, 'rival@club2.example'), (rival_door, 'doorr@club2.example'), (organizer_u, 'organizer@events.example'),
    (window_door, 'windowdoor@club.example');

  ---------------------------------------------------------------- set up: two businesses, linked events, door staff
  perform tests.login(owner_u, 'owner@club.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.login(rival_u, 'rival@club2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  venue_r := public.create_org_venue(org2, 'Rival Club');
  perform tests.login(organizer_u, 'organizer@events.example');
  porg := public.create_organization('Night Events', 'organizer');

  perform tests.logout();
  -- Future Night starts in two hours at Club A; the ended-an-hour-ago event and the long-ended one are also Club A's.
  update public.site_events set venue_id = venue_a, start_date = now() + interval '2 hours', end_date = now() + interval '10 hours' where id = e1;
  update public.site_events set venue_id = venue_a where id in (e2, e3);
  -- The live event belongs to the organizer, at no club.
  update public.site_events set org_id = porg where id = e4;
  -- An event at Club B, and one at the rival club, each with a paid ticket.
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id)
    values ('Club B Night', 'd', 'Club B', now() + interval '1 hour', now() + interval '9 hours', 'published', venue_b) returning id into ev_b;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, venue_id)
    values ('Rival Night', 'd', 'Rival Club', now() + interval '1 hour', now() + interval '9 hours', 'published', venue_r) returning id into ev_r;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_b, 'General', 5000, 50) returning id into tier_b;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_r, 'General', 5000, 50) returning id into tier_r;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code) values
    (ev_b, tier_b, 'Bea Club-B', 'bea@test.example', 1, 5000, 'paid', 'T-CLUB-B'),
    (ev_r, tier_r, 'Rex Rival', 'rex@test.example', 1, 5000, 'paid', 'T-RIVAL');

  perform tests.login(owner_u, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'doorv@club.example', 'door', venue_a) i;
  select i.token into tok_w from public.invite_member(org, 'windowdoor@club.example', 'door', venue_a) i;
  perform tests.login(organizer_u, 'organizer@events.example');
  select i.token into tok_e from public.invite_member(porg, 'doore@events.example', 'door', null, e4) i;
  perform tests.login(rival_u, 'rival@club2.example');
  select i.token into tok_r from public.invite_member(org2, 'doorr@club2.example', 'door', venue_r) i;
  perform tests.login(door_v, 'doorv@club.example');  perform public.accept_invitation(tok);
  perform tests.login(window_door, 'windowdoor@club.example'); perform public.accept_invitation(tok_w);
  perform tests.login(door_e, 'doore@events.example'); perform public.accept_invitation(tok_e);
  perform tests.login(rival_door, 'doorr@club2.example'); perform public.accept_invitation(tok_r);

  perform tests.logout();
  select id into mid_v from public.site_memberships where user_id = door_v;
  select id into mid_e from public.site_memberships where user_id = door_e;
  select id into mid_r from public.site_memberships where user_id = rival_door;
  select id into mid_w from public.site_memberships where user_id = window_door;

  ---------------------------------------------------------------- who counts as a door person
  perform tests.login(door_v);
  perform tests.assert_true('a door person for a club holds the door role', public.has_door_role());
  perform tests.login(door_e);
  perform tests.assert_true('so does a door person for one event', public.has_door_role());
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_true('an owner does not (the role is explicit)', not public.has_door_role());
  perform tests.login(legacy_staff);
  perform tests.assert_true('nor does existing door_staff, who keep their own pages', not public.has_door_role());
  perform tests.login(rando);
  perform tests.assert_true('nor does a signed-in person with no role', not public.has_door_role());
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot ask', 'select public.has_door_role()', 'permission denied');

  ---------------------------------------------------------------- what each door person may scan
  perform tests.login(door_v);
  perform tests.assert_true('a club door person may scan an event linked to their club', public.can_scan_event(e1));
  perform tests.assert_true('...also one that has already ended (the scan itself then says so)', public.can_scan_event(e2));
  perform tests.assert_true('...but not an event at another club of the same business', not public.can_scan_event(ev_b));
  perform tests.assert_true('...nor the organizer''s event, which is at no club', not public.can_scan_event(e4));
  perform tests.assert_true('...nor a rival''s event', not public.can_scan_event(ev_r));
  perform tests.assert_true('...nor an event that does not exist', not public.can_scan_event(gen_random_uuid()));
  perform tests.login(door_e);
  perform tests.assert_true('an event door person may scan their event', public.can_scan_event(e4));
  perform tests.assert_true('...and nothing else, even at a club they have no link to', not public.can_scan_event(e1) and not public.can_scan_event(ev_b));
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_true('an owner as such may not scan', not public.can_scan_event(e1));

  ---------------------------------------------------------------- tonight's events for a workspace
  perform tests.login(door_v);
  select count(*) into n from public.door_events(mid_v);
  perform tests.assert_eq('a club workspace lists the events running or just finished (not the long-ended one)', n, 2);
  select string_agg(title, ',' order by title) into txt from public.door_events(mid_v);
  perform tests.assert_eq('...Future Night and the one that ended an hour ago', txt, 'Future Night,No end, long ago');
  select scope into txt from public.door_events(mid_v) where title = 'Future Night';
  perform tests.assert_eq('...shown as covered through the club', txt, 'venue');
  select guests_expected into n from public.door_events(mid_v) where title = 'Future Night';
  perform tests.assert_eq('guests expected counts paid tickets by quantity, and ignores pending, failed and refunded', n, 6);
  select guests_admitted into n from public.door_events(mid_v) where title = 'Future Night';
  perform tests.assert_eq('...and nobody is admitted yet', n, 0);
  perform tests.login(door_e);
  select count(*) into n from public.door_events(mid_e);
  perform tests.assert_eq('an event door person sees their one event', n, 1);
  select scope into txt from public.door_events(mid_e);
  perform tests.assert_eq('...as assigned to it directly', txt, 'event');
  perform tests.assert_raises('a workspace that is not yours is refused', format($q$select * from public.door_events(%L)$q$, mid_v), 'not authorized');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('an owner cannot list door events', format($q$select * from public.door_events(%L)$q$, mid_v), 'not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot', format($q$select * from public.door_events(%L)$q$, mid_v), 'permission denied');

  ---------------------------------------------------------------- scanning: refused outright
  perform tests.login(rando);
  perform tests.assert_raises('a person with no door role cannot scan', $q$select * from public.door_scan_ticket('T-PAID')$q$, 'not authorized');
  perform tests.login(legacy_staff);
  perform tests.assert_raises('existing door_staff use their own scanner, not this one', $q$select * from public.door_scan_ticket('T-PAID')$q$, 'not authorized');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('an owner cannot scan', $q$select * from public.door_scan_ticket('T-PAID')$q$, 'not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot scan', $q$select * from public.door_scan_ticket('T-PAID')$q$, 'permission denied');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code = 'T-PAID' and checked_in_at is not null;
  perform tests.assert_eq('the refused attempts admitted nobody', n, 0);

  ---------------------------------------------------------------- scanning: the happy path and every outcome
  perform tests.login(door_v);
  select * into r from public.door_scan_ticket('T-PAID', e1);
  perform tests.assert_eq('a paid ticket for the selected event is admitted', r.result, 'ok');
  perform tests.assert_eq('...showing the guest', r.customer_name, 'Ada Lovelace');
  perform tests.assert_eq('...the tier', r.tier_name, 'General');
  perform tests.assert_eq('...the number of people', r.quantity, 2);
  perform tests.assert_eq('...and the event', r.event_title, 'Future Night');
  perform tests.logout();
  select checked_in_by into r from public.site_orders where ticket_code = 'T-PAID';
  perform tests.assert_eq('the order records who admitted it', r.checked_in_by, door_v);
  perform tests.login(door_v);
  select guests_admitted into n from public.door_events(mid_v) where title = 'Future Night';
  perform tests.assert_eq('the admitted count follows (two people on that ticket)', n, 2);

  select * into r from public.door_scan_ticket('T-PAID', e1);
  perform tests.assert_eq('the same ticket again is "already checked in"', r.result, 'already_checked_in');
  perform tests.logout();
  select count(*) into n from public.scan_attempts where order_id = (select id from public.site_orders where ticket_code = 'T-PAID') and result = 'ok';
  perform tests.assert_eq('...and it was admitted only once', n, 1);
  perform tests.login(door_v);

  select * into r from public.door_scan_ticket('  T-PAID2  ', null);
  perform tests.assert_eq('surrounding spaces are ignored, and no selected event is required', r.result, 'ok');
  select * into r from public.door_scan_ticket('T-PENDING', e1);
  perform tests.assert_eq('a pending order is not paid', r.result, 'not_paid');
  select * into r from public.door_scan_ticket('T-REFUNDED', e1);
  perform tests.assert_eq('a refunded order is not paid', r.result, 'not_paid');
  select * into r from public.door_scan_ticket('T-FAILED', e1);
  perform tests.assert_eq('a failed order is not paid', r.result, 'not_paid');
  select * into r from public.door_scan_ticket('NO-SUCH-TICKET', e1);
  perform tests.assert_eq('an unknown code is not found', r.result, 'not_found');
  perform tests.assert_true('...and says nothing else', r.customer_name is null and r.event_title is null);
  select * into r from public.door_scan_ticket(repeat('X', 500), e1);
  perform tests.assert_eq('an absurdly long code is simply not found', r.result, 'not_found');
  perform tests.logout();
  select max(length(ticket_code_attempted)) into n from public.scan_attempts where scanned_by = door_v;
  perform tests.assert_true('...and what is stored of it is capped', n <= 200);
  perform tests.login(door_v);

  -- The old function admitted these as well as refusing them (RETURN QUERY does not exit). These must not be admitted.
  select count(*) into n from public.door_scan_ticket('T-STALE', e3);
  perform tests.assert_eq('an ended event returns exactly one answer, not two', n, 1);
  select * into r from public.door_scan_ticket('T-STALE', e3);
  perform tests.assert_eq('a ticket for an event that has ended is expired', r.result, 'expired');
  select * into r from public.door_scan_ticket('T-ENDED', e2);
  perform tests.assert_eq('so is one from an event that ended days ago', r.result, 'expired');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code in ('T-STALE', 'T-ENDED') and checked_in_at is not null;
  perform tests.assert_eq('...and neither was admitted', n, 0);
  perform tests.login(door_v);

  select count(*) into n from public.door_scan_ticket('T-NT', e1);
  perform tests.assert_eq('a code-protected ticket returns exactly one answer', n, 1);
  select * into r from public.door_scan_ticket('T-NT', e1);
  perform tests.assert_eq('a non-transferable ticket asks for its entry code', r.result, 'code_required');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code = 'T-NT' and checked_in_at is not null;
  perform tests.assert_eq('...and is not admitted before the code is checked', n, 0);
  perform tests.login(door_v);
  select * into r from public.door_scan_ticket('T-NT-OK', e1);
  perform tests.assert_eq('one whose code was already verified is admitted', r.result, 'ok');

  ---------------------------------------------------------------- scanning: outside the person's scope
  select * into r from public.door_scan_ticket('T-CLUB-B', ev_b);
  perform tests.assert_eq('a ticket for another club of the same business is the wrong event', r.result, 'wrong_event');
  perform tests.assert_true('...revealing nothing about the guest or the event',
    r.customer_name is null and r.tier_name is null and r.quantity is null and r.event_title is null);
  select * into r from public.door_scan_ticket('T-RIVAL', null);
  perform tests.assert_eq('a rival business''s ticket is the wrong event', r.result, 'wrong_event');
  perform tests.assert_true('...revealing nothing', r.customer_name is null and r.event_title is null);
  select * into r from public.door_scan_ticket('C-1', e3);
  perform tests.assert_eq('a ticket for another of their own events, while a different event is selected, is the wrong event', r.result, 'wrong_event');
  perform tests.assert_eq('...and since they cover both events the answer names the ticket''s event, to help them', r.event_title, 'Future Night');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code in ('T-CLUB-B', 'T-RIVAL', 'C-1') and checked_in_at is not null;
  perform tests.assert_eq('none of those was admitted', n, 0);
  select count(*) into n from public.scan_attempts where result = 'wrong_event' and scanned_by = door_v;
  perform tests.assert_eq('each was logged against the person who scanned', n, 3);
  perform tests.login(door_v);

  perform tests.login(door_e);
  select * into r from public.door_scan_ticket('T-PAID2', e4);
  perform tests.assert_eq('an event door person cannot scan the club''s event', r.result, 'wrong_event');
  select * into r from public.door_scan_ticket('NOT-A-CODE');
  perform tests.assert_eq('...and an unknown code is just not found', r.result, 'not_found');
  select * into r from public.door_scan_ticket('T-LIVE', e4);
  perform tests.assert_eq('but they can admit a ticket for their own event', r.result, 'ok');
  perform tests.assert_eq('...which is shown by its event', r.event_title, 'No end, just started');

  perform tests.login(rival_door);
  select * into r from public.door_scan_ticket('T-LIVE', null);
  perform tests.assert_eq('a rival''s door person cannot scan this business''s tickets', r.result, 'wrong_event');
  perform tests.assert_true('...and learns nothing about the guest or the event', r.customer_name is null and r.event_title is null);
  select * into r from public.door_scan_ticket('T-RIVAL', null);
  perform tests.assert_eq('...but can scan their own club''s', r.result, 'ok');

  ---------------------------------------------------------------- access that has ended opens nothing
  perform tests.login(window_door);
  perform tests.assert_true('a door person inside their window can scan', public.has_door_role());
  perform tests.logout();
  update public.site_memberships set access_start_at = now() - interval '5 hours', access_end_at = now() - interval '1 hour' where id = mid_w;
  perform tests.login(window_door);
  perform tests.assert_true('once their window has ended they hold no door role', not public.has_door_role());
  perform tests.assert_raises('...cannot scan', $q$select * from public.door_scan_ticket('T-LIVE')$q$, 'not authorized');
  perform tests.assert_raises('...cannot enter a code', $q$select * from public.door_verify_ticket_code('T-NT', '123456')$q$, 'not authorized');
  perform tests.assert_raises('...and cannot list events', format($q$select * from public.door_events(%L)$q$, mid_w), 'not authorized');

  perform tests.login(rival_u, 'rival@club2.example');
  perform public.revoke_membership(mid_r);
  perform tests.login(rival_door);
  perform tests.assert_raises('a removed door person cannot scan', $q$select * from public.door_scan_ticket('T-RIVAL')$q$, 'not authorized');

  ---------------------------------------------------------------- the entry code for non-transferable tickets
  perform tests.logout();
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code, is_non_transferable) values
    (e1, b2, 'Otp Happy', 'happy@test.example', 1, 9000, 'paid', 'V-HAPPY', true),
    (e1, b2, 'Otp Wrong', 'wrong@test.example', 1, 9000, 'paid', 'V-WRONG', true),
    (e1, b2, 'Otp Late',  'late@test.example',  1, 9000, 'paid', 'V-LATE',  true),
    (e1, b2, 'Otp None',  'none@test.example',  1, 9000, 'paid', 'V-NONE',  true),
    (e1, b1, 'Otp Plain', 'plain@test.example', 1, 5000, 'paid', 'V-PLAIN', false),
    (e3, '00000000-0000-0000-0000-0000000000b4', 'Otp Stale', 'stale@test.example', 1, 5000, 'paid', 'V-STALE', true),
    (ev_b, tier_b, 'Otp ClubB', 'clubb@test.example', 1, 5000, 'paid', 'V-CLUB-B', true);
  insert into public.ticket_otp_codes (order_id, code_hash, sent_to_email, expires_at)
    select id, crypt('123456', gen_salt('bf', 4)), customer_email, now() + interval '5 minutes'
    from public.site_orders where ticket_code in ('V-HAPPY', 'V-WRONG', 'V-STALE', 'V-CLUB-B');
  insert into public.ticket_otp_codes (order_id, code_hash, sent_to_email, expires_at)
    select id, crypt('123456', gen_salt('bf', 4)), customer_email, now() - interval '1 minute'
    from public.site_orders where ticket_code = 'V-LATE';

  perform tests.login(rando);
  perform tests.assert_raises('a person with no door role cannot enter a code', $q$select * from public.door_verify_ticket_code('V-HAPPY', '123456')$q$, 'not authorized');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('an owner cannot', $q$select * from public.door_verify_ticket_code('V-HAPPY', '123456')$q$, 'not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot', $q$select * from public.door_verify_ticket_code('V-HAPPY', '123456')$q$, 'permission denied');

  perform tests.login(door_v);
  select * into r from public.door_verify_ticket_code('V-HAPPY', '123456', e1);
  perform tests.assert_eq('the right code admits the ticket', r.result, 'ok');
  perform tests.assert_eq('...showing the guest', r.customer_name, 'Otp Happy');
  perform tests.logout();
  select checked_in_by, access_code_verified into r from public.site_orders where ticket_code = 'V-HAPPY';
  perform tests.assert_eq('...recording who admitted them', r.checked_in_by, door_v);
  perform tests.assert_true('...and that the code was verified', r.access_code_verified);
  select verified_by into r from public.ticket_otp_codes where order_id = (select id from public.site_orders where ticket_code = 'V-HAPPY');
  perform tests.assert_eq('the code records who verified it', r.verified_by, door_v);
  perform tests.login(door_v);
  select * into r from public.door_verify_ticket_code('V-HAPPY', '123456', e1);
  perform tests.assert_eq('using it again finds the guest already admitted', r.result, 'already_checked_in');

  select * into r from public.door_verify_ticket_code('V-WRONG', '000000', e1);
  perform tests.assert_eq('a wrong code is refused', r.result, 'code_incorrect');
  perform tests.assert_eq('...with two tries left', r.attempts_remaining, 2);
  select * into r from public.door_verify_ticket_code('V-WRONG', '111111', e1);
  perform tests.assert_eq('...then one', r.attempts_remaining, 1);
  select * into r from public.door_verify_ticket_code('V-WRONG', '222222', e1);
  perform tests.assert_eq('...then none', r.attempts_remaining, 0);
  select * into r from public.door_verify_ticket_code('V-WRONG', '123456', e1);
  perform tests.assert_eq('after three wrong tries even the right code is locked out', r.result, 'code_expired');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code = 'V-WRONG' and checked_in_at is not null;
  perform tests.assert_eq('...and nobody was admitted', n, 0);
  perform tests.login(door_v);

  select * into r from public.door_verify_ticket_code('V-LATE', '123456', e1);
  perform tests.assert_eq('a code past its five minutes is expired', r.result, 'code_expired');
  select * into r from public.door_verify_ticket_code('V-NONE', '123456', e1);
  perform tests.assert_eq('a guest who never asked for a code has none', r.result, 'no_code_requested');
  select * into r from public.door_verify_ticket_code('V-PLAIN', '', e1);
  perform tests.assert_eq('an ordinary ticket needs no code and is admitted', r.result, 'ok');
  perform tests.logout();
  select count(*) into n from public.site_orders where ticket_code = 'V-PLAIN' and checked_in_at is not null;
  perform tests.assert_eq('...really admitted, not just reported as ok', n, 1);
  perform tests.login(door_v);

  select * into r from public.door_verify_ticket_code('V-STALE', '123456', e3);
  perform tests.assert_eq('a right code does not admit a guest of an event that has ended', r.result, 'expired');
  select * into r from public.door_verify_ticket_code('V-CLUB-B', '000000', null);
  perform tests.assert_eq('a ticket outside the person''s scope is the wrong event', r.result, 'wrong_event');
  select * into r from public.door_verify_ticket_code('V-NONE', '000000', e3);
  perform tests.assert_eq('so is one for another event than the one selected', r.result, 'wrong_event');
  perform tests.logout();
  select attempts into n from public.ticket_otp_codes where order_id = (select id from public.site_orders where ticket_code = 'V-CLUB-B');
  perform tests.assert_eq('a guess at a ticket you may not scan does not use up the guest''s tries', n, 0);
  select count(*) into n from public.site_orders where ticket_code in ('V-CLUB-B', 'V-STALE') and checked_in_at is not null;
  perform tests.assert_eq('...and none of those was admitted', n, 0);

  ---------------------------------------------------------------- finding a guest
  perform tests.login(door_v);
  select count(*) into n from public.door_guests(e1, 'ada');
  perform tests.assert_eq('a guest is found by name', n, 1);
  select * into r from public.door_guests(e1, 'LOVELACE');
  perform tests.assert_eq('...in any case', r.ticket_code, 'T-PAID');
  perform tests.assert_eq('...with the number of people', r.quantity, 2);
  perform tests.assert_true('...and whether they are already in', r.checked_in_at is not null);
  perform tests.assert_true('...an ordinary ticket needs no code', not r.needs_code);
  select count(*) into n from public.door_guests(e1, 'T-NT');
  perform tests.assert_eq('a guest is found by ticket code', n, 2);
  select needs_code into r from public.door_guests(e1, 'T-NT') where ticket_code = 'T-NT';
  perform tests.assert_true('an unverified non-transferable ticket is flagged as needing its code', r.needs_code);
  select count(*) into n from public.door_guests(e1, 'a');
  perform tests.assert_eq('one character is not enough to search', n, 0);
  select count(*) into n from public.door_guests(e1, null);
  perform tests.assert_eq('nor is nothing: this is a search, not a download of the guest list', n, 0);
  select count(*) into n from public.door_guests(e1, 'pending');
  perform tests.assert_eq('unpaid orders are never listed', n, 0);
  select count(*) into n from public.door_guests(e1, 'a%');
  perform tests.assert_eq('wildcards are literal characters', n, 0);
  perform tests.assert_true('no email or phone number is part of the answer',
    (select pg_get_function_result(oid) from pg_proc where proname = 'door_guests') not like '%email%'
    and (select pg_get_function_result(oid) from pg_proc where proname = 'door_guests') not like '%phone%');

  perform tests.logout();
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents, status, ticket_code)
    select e1, b1, 'Crowd ' || lpad(g::text, 2, '0'), 'crowd' || g || '@test.example', 1, 5000, 'paid', 'CROWD-' || g from generate_series(1, 60) g;
  perform tests.login(door_v);
  select count(*) into n from public.door_guests(e1, 'crowd');
  perform tests.assert_eq('a broad search returns at most fifty people', n, 50);

  perform tests.assert_raises('an event outside the person''s scope cannot be searched', format($q$select * from public.door_guests(%L, 'bea')$q$, ev_b), 'not allowed');
  perform tests.login(door_e);
  perform tests.assert_raises('an event door person cannot search the club''s event', format($q$select * from public.door_guests(%L, 'ada')$q$, e1), 'not allowed');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('an owner cannot search the door list', format($q$select * from public.door_guests(%L, 'ada')$q$, e1), 'not authorized');
  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot', format($q$select * from public.door_guests(%L, 'ada')$q$, e1), 'permission denied');

  ---------------------------------------------------------------- the older functions are unchanged and stay out of reach
  perform tests.login(legacy_staff);
  select * into r from public.checkin_ticket('T-PENDING');
  perform tests.assert_eq('existing door_staff still use the existing scanner as before', r.result, 'not_paid');
  perform tests.login(door_v);
  perform tests.assert_raises('a scoped door person cannot use the unscoped scanner to reach any event', $q$select * from public.checkin_ticket('T-CLUB-B')$q$, 'not authorized');
  perform tests.assert_raises('...nor the unscoped entry-code check', $q$select * from public.verify_ticket_otp('V-CLUB-B', '123456')$q$, 'not authorized');

  ---------------------------------------------------------------- the log
  perform tests.assert_eq('a door person cannot read the scan log directly', (select count(*) from public.scan_attempts)::int, 0);
  perform tests.login(admin_u, 'admin@test.example');
  select count(*) into n from public.scan_attempts where scanned_by = door_v;
  perform tests.assert_true('a platform admin sees what they scanned', n > 10);
  select count(*) into n from public.scan_attempts where result = 'wrong_event';
  perform tests.assert_true('...including the out-of-scope attempts', n >= 3);
  perform tests.logout();
  perform tests.assert_raises('the log only accepts known outcomes',
    format($q$insert into public.scan_attempts (ticket_code_attempted, result, scanned_by) values ('x', 'bogus', %L)$q$, door_v), 'scan_attempts_result_check');
end $$;

rollback;
