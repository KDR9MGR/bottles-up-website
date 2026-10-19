-- Cancelling a business added by mistake (client feedback, 10 Oct 2026). What matters most: only the business's own owner or
-- organizer can do it; only while it has NOT been verified; it never takes other people's access, a live venue, a published event
-- or anything with bookings or orders with it; what it deletes is exactly the business and its drafts; and it leaves a record.
begin;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000e1';
  stranger constant uuid := '00000000-0000-0000-0000-0000000000e2';
  mgr_u constant uuid := '00000000-0000-0000-0000-0000000000e3';
  org_u constant uuid := '00000000-0000-0000-0000-0000000000e4';  -- an event organizer
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  org uuid; keep uuid; org3 uuid; org4 uuid; org5 uuid; org6 uuid; org7 uuid; eorg uuid; eorg2 uuid;
  venue uuid; venue_keep uuid; venue3 uuid; venue6 uuid; venue7 uuid; ev uuid; tier uuid; tok text; mem uuid; r record; slot uuid; type_id uuid;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@eonics.example'), (stranger, 'stranger@example.com'), (mgr_u, 'mgr@eonics.example'), (org_u, 'organizer@events.example');

  ---------------------------------------------------------------- the mistake: a business, a draft venue, an unaccepted invitation
  perform tests.login(owner_u, 'owner@eonics.example');
  keep := public.create_organization('Real Club Co', 'venue_owner');
  venue_keep := public.create_org_venue(keep, 'Real Club');
  org := public.create_organization('Eonics Lounge', 'venue_owner');
  venue := public.create_org_venue(org, 'Eonics Lounge');
  perform public.invite_member(org, 'mgr@eonics.example', 'manager', venue);
  perform tests.assert_eq('two businesses before', (select count(*) from public.my_businesses())::int, 2);

  ---------------------------------------------------------------- who may cancel
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot cancel a business', format($q$select public.cancel_business(%L)$q$, org), 'permission denied');
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform tests.assert_raises('a token with no user is told to sign in', format($q$select public.cancel_business(%L)$q$, org), 'not authenticated');
  perform tests.login(stranger, 'stranger@example.com');
  perform tests.assert_raises('a stranger cannot cancel someone else''s business', format($q$select public.cancel_business(%L)$q$, org), 'not allowed');
  perform tests.assert_raises('...nor one that does not exist', format($q$select public.cancel_business(%L)$q$, gen_random_uuid()), 'not allowed');
  perform tests.assert_raises('...nor no business at all', $q$select public.cancel_business(null)$q$, 'not allowed');
  perform tests.logout();
  perform tests.assert_eq('nothing was removed by those attempts', (select count(*) from public.site_organizations where id = org)::int, 1);

  ---------------------------------------------------------------- cancelling it
  perform tests.login(owner_u, 'owner@eonics.example');
  perform public.cancel_business(org);
  perform tests.assert_eq('the owner has one business left', (select count(*) from public.my_businesses())::int, 1);
  perform tests.assert_eq('...the other one', (select org_name from public.my_businesses()), 'Real Club Co');
  perform tests.logout();
  perform tests.assert_eq('the business is gone', (select count(*) from public.site_organizations where id = org)::int, 0);
  perform tests.assert_eq('...with its details', (select count(*) from public.site_business_profiles where org_id = org)::int, 0);
  perform tests.assert_eq('...its verification', (select count(*) from public.site_verifications where org_id = org)::int, 0);
  perform tests.assert_eq('...its membership', (select count(*) from public.site_memberships where org_id = org)::int, 0);
  perform tests.assert_eq('...its unaccepted invitation', (select count(*) from public.site_invitations where org_id = org)::int, 0);
  perform tests.assert_eq('...and its draft venue', (select count(*) from public.site_venues where id = venue)::int, 0);
  perform tests.assert_eq('the other business keeps its venue', (select count(*) from public.site_venues where id = venue_keep and org_id = keep)::int, 1);
  perform tests.assert_eq('...and its membership', (select count(*) from public.site_memberships where org_id = keep and user_id = owner_u and status = 'active')::int, 1);

  select * into r from public.audit_log where action = 'business.cancelled' and entity_id = org::text;
  perform tests.assert_true('it is recorded', r.id is not null);
  perform tests.assert_eq('...with who did it', r.actor_id::text || '|' || r.actor_email, owner_u::text || '|owner@eonics.example');
  perform tests.assert_eq('...and what it was', r.details ->> 'name' || '|' || (r.details ->> 'kind') || '|' || (r.details ->> 'state') || '|' || (r.details ->> 'draft_venues'), 'Eonics Lounge|venue_owner|not_submitted|1');

  perform tests.login(owner_u, 'owner@eonics.example');
  perform tests.assert_raises('cancelling twice finds nothing to cancel', format($q$select public.cancel_business(%L)$q$, org), 'not allowed');

  ---------------------------------------------------------------- other people's access is never taken away
  org3 := public.create_organization('Team Co', 'venue_owner');
  venue3 := public.create_org_venue(org3, 'Team Club');
  select i.token into tok from public.invite_member(org3, 'mgr@eonics.example', 'manager', venue3) i;
  perform tests.login(mgr_u, 'mgr@eonics.example'); perform public.accept_invitation(tok);
  perform tests.assert_raises('a manager cannot cancel the business', format($q$select public.cancel_business(%L)$q$, org3), 'not allowed');
  perform tests.login(owner_u, 'owner@eonics.example');
  perform tests.assert_raises('a business with an active team member is not cancelled', format($q$select public.cancel_business(%L)$q$, org3), 'team members');
  perform tests.assert_eq('...it is still there', (select count(*) from public.site_organizations where id = org3)::int, 1);
  select m.id into mem from public.site_memberships m where m.org_id = org3 and m.user_id = mgr_u;
  perform public.revoke_membership(mem);
  perform public.cancel_business(org3);
  perform tests.logout();
  perform tests.assert_eq('once the team is removed it can be cancelled', (select count(*) from public.site_organizations where id = org3)::int, 0);
  perform tests.assert_eq('...and the removed member''s old record went with it', (select count(*) from public.site_memberships where org_id = org3)::int, 0);

  ---------------------------------------------------------------- only before verification
  perform tests.login(owner_u, 'owner@eonics.example');
  org4 := public.create_organization('Reviewed Co', 'venue_owner');
  perform public.create_org_venue(org4, 'Reviewed Club');
  perform public.save_business_details(org4, '{"legal_name":"Reviewed Inc.","representative_name":"Dana","representative_phone":"+1 (416) 555-0100","contact_email":"a@reviewed.example","address":"1 King St W","representative_confirmed":true}');
  perform public.submit_verification(org4);
  perform tests.assert_raises('a business under review cannot be cancelled here', format($q$select public.cancel_business(%L)$q$, org4), 'under review or verified');
  perform tests.assert_eq('...and is still there', (select count(*) from public.site_organizations where id = org4)::int, 1);
  perform tests.login(admin_u, 'admin@test.example');
  perform public.review_verification(org4, 'request_info', 'Please add the registration number.');
  perform tests.login(owner_u, 'owner@eonics.example');
  perform public.cancel_business(org4);
  perform tests.logout();
  perform tests.assert_eq('one sent back for more information can be cancelled', (select count(*) from public.site_organizations where id = org4)::int, 0);
  perform tests.assert_eq('...and the record says what state it was in', (select details ->> 'state' from public.audit_log where action = 'business.cancelled' and entity_id = org4::text), 'more_information_needed');

  perform tests.login(owner_u, 'owner@eonics.example');
  org5 := public.create_organization('Verified Co', 'venue_owner');
  perform public.create_org_venue(org5, 'Verified Club');
  perform public.save_business_details(org5, '{"legal_name":"Verified Inc.","representative_name":"Dana","representative_phone":"+1 (416) 555-0100","contact_email":"a@verified.example","address":"1 King St W","representative_confirmed":true}');
  perform public.submit_verification(org5);
  perform tests.login(admin_u, 'admin@test.example');
  perform public.review_verification(org5, 'verify');
  perform tests.login(owner_u, 'owner@eonics.example');
  perform tests.assert_raises('a verified business cannot be cancelled here', format($q$select public.cancel_business(%L)$q$, org5), 'under review or verified');
  perform tests.assert_eq('...and keeps its venue', (select count(*) from public.site_venues where org_id = org5)::int, 1);

  ---------------------------------------------------------------- never a live venue, and never a venue with bookings
  org6 := public.create_organization('Live Co', 'venue_owner');
  venue6 := public.create_org_venue(org6, 'Live Club');
  perform tests.logout();
  update public.site_venues set status = 'published' where id = venue6;
  perform tests.login(owner_u, 'owner@eonics.example');
  perform tests.assert_raises('a business with a live venue is not cancelled', format($q$select public.cancel_business(%L)$q$, org6), 'live venue');
  perform tests.assert_eq('...the venue is still live', (select count(*) from public.site_venues where id = venue6 and status = 'published')::int, 1);

  org7 := public.create_organization('Booked Co', 'venue_owner');
  venue7 := public.create_org_venue(org7, 'Booked Club');
  perform tests.logout();
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue7, 5, '21:00') returning id into slot;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (venue7, 'VIP', 4, 0, 0, 1) returning id into type_id;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents)
    values (venue7, type_id, slot, current_date + 3, 'Ada', 'ada@test.example', 2, 1000);
  perform tests.login(owner_u, 'owner@eonics.example');
  perform tests.assert_raises('a draft venue that already has a booking is not deleted from under it', format($q$select public.cancel_business(%L)$q$, org7), 'records attached');
  perform tests.logout();  -- read the tables as their owner: row level security hides bookings and the audit log from an owner
  perform tests.assert_eq('...the business is still there', (select count(*) from public.site_organizations where id = org7)::int, 1);
  perform tests.assert_eq('...and so is the booking', (select count(*) from public.site_table_bookings where venue_id = venue7)::int, 1);
  perform tests.assert_eq('...and nothing was recorded as cancelled', (select count(*) from public.audit_log where action = 'business.cancelled' and entity_id = org7::text)::int, 0);

  ---------------------------------------------------------------- an organizer: drafts go, published events and orders stop it
  perform tests.login(org_u, 'organizer@events.example');
  eorg := public.create_organization('Night Events', 'organizer');
  eorg2 := public.create_organization('Busy Events', 'organizer');
  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, status, org_id)
    values ('Draft party', 'Not live', 'Somewhere', now() + interval '30 days', 'draft', eorg) returning id into ev;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev, 'General', 2000, 100);
  perform tests.login(org_u, 'organizer@events.example');
  perform public.cancel_business(eorg);
  perform tests.logout();
  perform tests.assert_eq('an organizer can cancel its business', (select count(*) from public.site_organizations where id = eorg)::int, 0);
  perform tests.assert_eq('...its draft event goes with it', (select count(*) from public.site_events where id = ev)::int, 0);
  perform tests.assert_eq('...and that event''s ticket tiers', (select count(*) from public.site_ticket_tiers where event_id = ev)::int, 0);
  perform tests.assert_eq('...the record counts the draft events', (select details ->> 'draft_events' from public.audit_log where action = 'business.cancelled' and entity_id = eorg::text), '1');

  insert into public.site_events (title, description, venue_name, start_date, status, org_id)
    values ('Live party', 'On sale', 'Somewhere', now() + interval '30 days', 'published', eorg2) returning id into ev;
  perform tests.login(org_u, 'organizer@events.example');
  perform tests.assert_raises('a business with a published event is not cancelled', format($q$select public.cancel_business(%L)$q$, eorg2), 'published event');
  perform tests.logout();
  update public.site_events set status = 'draft' where id = ev;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev, 'General', 2000, 100) returning id into tier;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents)
    values (ev, tier, 'Ada', 'ada@test.example', 1, 2000);
  perform tests.login(org_u, 'organizer@events.example');
  perform tests.assert_raises('a draft event that already has an order is not deleted from under it', format($q$select public.cancel_business(%L)$q$, eorg2), 'records attached');
  perform tests.logout();
  perform tests.assert_eq('...the event and its order are still there', (select count(*) from public.site_orders where event_id = ev)::int, 1);
  perform tests.assert_eq('...and nothing was recorded as cancelled', (select count(*) from public.audit_log where action = 'business.cancelled' and entity_id = eorg2::text)::int, 0);

  ---------------------------------------------------------------- the audit trail has no anonymous entries
  perform tests.logout();
  perform tests.assert_eq('every cancellation names who did it', (select count(*) from public.audit_log where action = 'business.cancelled' and (actor_id is null or actor_email = 'unknown'))::int, 0);
  perform tests.login(owner_u, 'owner@eonics.example');
  perform tests.assert_raises('a signed-in owner cannot write a cancellation record by hand', $q$insert into public.audit_log (actor_id, actor_email, action, entity_type) values (null, 'x', 'business.cancelled', 'x')$q$, 'audit_log');
  perform tests.logout();
end $$;

rollback;
