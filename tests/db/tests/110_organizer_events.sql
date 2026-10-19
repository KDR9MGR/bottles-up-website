-- Organizer events (client feedback, 10 Oct 2026: "Event organizer page needs a create event"). What matters most: only an
-- organizer of THIS business can read or write its events; an organizer can never publish, reassign or reach another
-- business's event; a published event is out of reach; every field is validated; and every change is attributed.
begin;

do $$
declare
  org_u constant uuid := '00000000-0000-0000-0000-0000000000f1';   -- organizer of Night Events
  org2_u constant uuid := '00000000-0000-0000-0000-0000000000f2';  -- organizer of Other Events
  owner_u constant uuid := '00000000-0000-0000-0000-0000000000f3'; -- a venue owner
  stranger constant uuid := '00000000-0000-0000-0000-0000000000f4';
  orgA uuid; orgB uuid; orgC uuid; evc uuid; ownerOrg uuid; ev uuid; ev2 uuid; evb uuid; ev_pub uuid; ev_order uuid; platform_ev uuid; tier uuid;
  r record; n int; txt text; ts timestamptz;
  long_title text := repeat('x', 121);
begin
  insert into auth.users (id, email) values
    (org_u, 'organizer@night.example'), (org2_u, 'organizer@other.example'), (owner_u, 'owner@club.example'), (stranger, 'stranger@example.com');

  perform tests.login(org_u, 'organizer@night.example');
  orgA := public.create_organization('Night Events', 'organizer');
  perform tests.login(org2_u, 'organizer@other.example');
  orgB := public.create_organization('Other Events', 'organizer');
  perform tests.login(owner_u, 'owner@club.example');
  ownerOrg := public.create_organization('Club Co', 'venue_owner');
  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, status)
    values ('Platform night', 'Made in the CMS', 'The Club', '2031-05-01T22:00:00Z', 'published') returning id into platform_ev;

  ---------------------------------------------------------------- who may use these functions
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot list events', format($q$select * from public.list_org_events(%L)$q$, orgA), 'permission denied');
  perform tests.assert_raises('...nor save one', format($q$select public.save_org_event(%L, null, '{}')$q$, orgA), 'permission denied');
  perform tests.assert_raises('...nor remove one', format($q$select public.remove_org_event(%L, %L)$q$, orgA, platform_ev), 'permission denied');
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform tests.assert_raises('a token with no user is told to sign in', format($q$select * from public.list_org_events(%L)$q$, orgA), 'not authenticated');
  perform tests.login(stranger, 'stranger@example.com');
  perform tests.assert_raises('a person with no business cannot list another business''s events', format($q$select * from public.list_org_events(%L)$q$, orgA), 'not allowed');
  perform tests.assert_raises('...nor create one', format($q$select public.save_org_event(%L, null, '{"title":"x","description":"x","venue_name":"x","start_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'not allowed');
  perform tests.login(org2_u, 'organizer@other.example');
  perform tests.assert_raises('an organizer of another business cannot list this one''s events', format($q$select * from public.list_org_events(%L)$q$, orgA), 'not allowed');
  perform tests.assert_raises('...nor create one for it', format($q$select public.save_org_event(%L, null, '{"title":"x","description":"x","venue_name":"x","start_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'not allowed');
  perform tests.login(owner_u, 'owner@club.example');
  perform tests.assert_raises('a venue owner cannot use the organizer functions on its own business', format($q$select * from public.list_org_events(%L)$q$, ownerOrg), 'not allowed');
  perform tests.assert_raises('...nor on an organizer''s', format($q$select public.save_org_event(%L, null, '{"title":"x","description":"x","venue_name":"x","start_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'not allowed');
  perform tests.assert_raises('no business at all is refused', $q$select * from public.list_org_events(null)$q$, 'not allowed');
  perform tests.assert_raises('a business that does not exist is refused', format($q$select * from public.list_org_events(%L)$q$, gen_random_uuid()), 'not allowed');

  ---------------------------------------------------------------- creating a draft
  perform tests.login(org_u, 'organizer@night.example');
  perform tests.assert_eq('a new organizer has no events', (select count(*) from public.list_org_events(orgA))::int, 0);
  ev := public.save_org_event(orgA, null, '{"title":"  Rooftop Party ","description":"Dancing under the stars","venue_name":"The Roof","address":"1 King St W","start_date":"2031-10-24T22:00:00Z","end_date":"2031-10-25T04:00:00Z","category":"Party","capacity":250,"cover_image_url":"https://img.example/roof.jpg"}');
  perform tests.assert_true('an organizer can create an event', ev is not null);
  perform tests.logout();
  select * into r from public.site_events where id = ev;
  perform tests.assert_eq('it is a draft', r.status, 'draft');
  perform tests.assert_eq('...owned by the organizer''s business', r.org_id, orgA);
  perform tests.assert_eq('...with the text trimmed', r.title, 'Rooftop Party');
  perform tests.assert_eq('...the organizer block shows the business name', r.organizer_name, 'Night Events');
  perform tests.assert_eq('...and not marked verified', r.organizer_verified, false);
  perform tests.assert_eq('...the start is exactly what was sent', r.start_date, '2031-10-24T22:00:00Z'::timestamptz);
  perform tests.assert_eq('...and the end', r.end_date, '2031-10-25T04:00:00Z'::timestamptz);
  perform tests.assert_eq('...capacity, category, address, cover', r.capacity::text || '|' || r.category || '|' || r.address || '|' || r.cover_image_url, '250|Party|1 King St W|https://img.example/roof.jpg');
  perform tests.assert_true('...and it got a slug', r.slug is not null and r.slug <> '');

  select * into r from public.audit_log where action = 'org_event.created' and entity_id = ev::text;
  perform tests.assert_eq('creating is recorded with who did it', r.actor_id::text || '|' || r.actor_email, org_u::text || '|organizer@night.example');
  perform tests.assert_eq('...and for which business', r.details ->> 'org_id', orgA::text);

  ---------------------------------------------------------------- a draft is private
  perform tests.login_anon();
  perform tests.assert_eq('the public cannot see a draft', (select count(*) from public.site_events where id = ev)::int, 0);
  perform tests.login(stranger, 'stranger@example.com');
  perform tests.assert_eq('...nor a stranger', (select count(*) from public.site_events where id = ev)::int, 0);
  perform tests.assert_eq('...but a published event is public', (select count(*) from public.site_events where id = platform_ev)::int, 1);

  ---------------------------------------------------------------- what is required, and what is refused
  perform tests.login(org_u, 'organizer@night.example');
  perform tests.assert_raises('a title is required', format($q$select public.save_org_event(%L, null, '{"description":"d","venue_name":"v","start_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'title is required');
  perform tests.assert_raises('...a blank one too', format($q$select public.save_org_event(%L, null, '{"title":"   ","description":"d","venue_name":"v","start_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'title is required');
  perform tests.assert_raises('a description is required', format($q$select public.save_org_event(%L, null, '{"title":"t","venue_name":"v","start_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'description is required');
  perform tests.assert_raises('a venue name is required', format($q$select public.save_org_event(%L, null, '{"title":"t","description":"d","start_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'venue name is required');
  perform tests.assert_raises('a start date is required', format($q$select public.save_org_event(%L, null, '{"title":"t","description":"d","venue_name":"v"}')$q$, orgA), 'start date is required');
  perform tests.assert_raises('a null start date is the same as none', format($q$select public.save_org_event(%L, null, '{"title":"t","description":"d","venue_name":"v","start_date":null}')$q$, orgA), 'start date is required');

  perform tests.assert_raises('an organizer cannot publish by sending a status', format($q$select public.save_org_event(%L, null, '{"title":"t","description":"d","venue_name":"v","start_date":"2031-01-01T20:00:00Z","status":"published"}')$q$, orgA), 'unknown field: status');
  perform tests.assert_raises('...nor move an event to another business', format($q$select public.save_org_event(%L, %L, jsonb_build_object('org_id', %L::text))$q$, orgA, ev, orgB), 'unknown field: org_id');
  perform tests.assert_raises('...nor choose the slug', format($q$select public.save_org_event(%L, %L, '{"slug":"mine"}')$q$, orgA, ev), 'unknown field: slug');
  perform tests.assert_raises('...nor mark itself verified', format($q$select public.save_org_event(%L, %L, '{"organizer_verified":true}')$q$, orgA, ev), 'unknown field: organizer_verified');
  perform tests.assert_raises('...nor set the venue link', format($q$select public.save_org_event(%L, %L, '{"venue_id":null}')$q$, orgA, ev), 'unknown field: venue_id');
  perform tests.assert_raises('details must be an object', format($q$select public.save_org_event(%L, null, '[]')$q$, orgA), 'details must be an object');
  perform tests.assert_raises('...and not missing', format($q$select public.save_org_event(%L, null, null)$q$, orgA), 'details must be an object');

  perform tests.assert_raises('a title of 121 characters is too long', format($q$select public.save_org_event(%L, null, jsonb_build_object('title', %L::text, 'description', 'd', 'venue_name', 'v', 'start_date', '2031-01-01T20:00:00Z'))$q$, orgA, long_title), 'title must be 120 characters or fewer');
  perform tests.assert_true('...120 is fine', public.save_org_event(orgA, null, jsonb_build_object('title', repeat('x', 120), 'description', 'd', 'venue_name', 'v', 'start_date', '2031-01-01T20:00:00Z')) is not null);
  perform tests.assert_raises('a description over 5000 characters is too long', format($q$select public.save_org_event(%L, null, jsonb_build_object('title', 't', 'description', %L::text, 'venue_name', 'v', 'start_date', '2031-01-01T20:00:00Z'))$q$, orgA, repeat('x', 5001)), 'description must be 5000 characters or fewer');
  perform tests.assert_raises('a venue name over 120 is too long', format($q$select public.save_org_event(%L, null, jsonb_build_object('title', 't', 'description', 'd', 'venue_name', %L::text, 'start_date', '2031-01-01T20:00:00Z'))$q$, orgA, long_title), 'venue name must be 120 characters or fewer');
  perform tests.assert_raises('an address over 200 is too long', format($q$select public.save_org_event(%L, null, jsonb_build_object('title', 't', 'description', 'd', 'venue_name', 'v', 'start_date', '2031-01-01T20:00:00Z', 'address', %L::text))$q$, orgA, repeat('x', 201)), 'address must be 200 characters or fewer');
  perform tests.assert_raises('a category over 40 is too long', format($q$select public.save_org_event(%L, null, jsonb_build_object('title', 't', 'description', 'd', 'venue_name', 'v', 'start_date', '2031-01-01T20:00:00Z', 'category', %L::text))$q$, orgA, repeat('x', 41)), 'category must be 40 characters or fewer');
  perform tests.assert_raises('text must be text', format($q$select public.save_org_event(%L, null, '{"title":5,"description":"d","venue_name":"v","start_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'title must be text');

  perform tests.assert_raises('a negative capacity is refused', format($q$select public.save_org_event(%L, %L, '{"capacity":-1}')$q$, orgA, ev), 'capacity must be between 0 and 100000');
  perform tests.assert_raises('...so is one over 100000', format($q$select public.save_org_event(%L, %L, '{"capacity":100001}')$q$, orgA, ev), 'capacity must be between 0 and 100000');
  perform tests.assert_raises('...a fraction', format($q$select public.save_org_event(%L, %L, '{"capacity":1.5}')$q$, orgA, ev), 'capacity must be a whole number');
  perform tests.assert_raises('...and a number written as text', format($q$select public.save_org_event(%L, %L, '{"capacity":"12"}')$q$, orgA, ev), 'capacity must be a whole number');
  perform tests.assert_true('zero and 100000 are allowed', public.save_org_event(orgA, ev, '{"capacity":0}') = ev and public.save_org_event(orgA, ev, '{"capacity":100000}') = ev);
  perform tests.assert_raises('a cover image must be https', format($q$select public.save_org_event(%L, %L, '{"cover_image_url":"http://x.example/a.jpg"}')$q$, orgA, ev), 'cover image must be an https link');
  perform tests.assert_raises('...and a link', format($q$select public.save_org_event(%L, %L, '{"cover_image_url":"not a link"}')$q$, orgA, ev), 'cover image must be an https link');

  perform tests.assert_raises('a date without a time is refused', format($q$select public.save_org_event(%L, %L, '{"start_date":"2031-10-24"}')$q$, orgA, ev), 'date and time with its time zone');
  perform tests.assert_raises('...so is a time without a time zone (the database would guess)', format($q$select public.save_org_event(%L, %L, '{"start_date":"2031-10-24T22:00:00"}')$q$, orgA, ev), 'time zone');
  perform tests.assert_raises('...words', format($q$select public.save_org_event(%L, %L, '{"start_date":"tomorrow night"}')$q$, orgA, ev), 'date and time with its time zone');
  perform tests.assert_raises('...a date that does not exist', format($q$select public.save_org_event(%L, %L, '{"start_date":"2031-02-30T22:00:00Z"}')$q$, orgA, ev), 'not a real date and time');
  perform tests.assert_raises('...a number', format($q$select public.save_org_event(%L, %L, '{"start_date":20311024}')$q$, orgA, ev), 'must be a date and time');
  perform tests.assert_true('an offset instead of Z is understood', public.save_org_event(orgA, ev, '{"start_date":"2031-10-24T18:00:00-04:00"}') = ev);
  select start_date into ts from public.site_events where id = ev;
  perform tests.assert_eq('...and means the same instant', ts, '2031-10-24T22:00:00Z'::timestamptz);
  perform tests.assert_raises('an end before the start is refused', format($q$select public.save_org_event(%L, %L, '{"end_date":"2031-10-24T21:00:00Z"}')$q$, orgA, ev), 'the end must be after the start');
  perform tests.assert_raises('...so is an end equal to it', format($q$select public.save_org_event(%L, %L, '{"end_date":"2031-10-24T22:00:00Z"}')$q$, orgA, ev), 'the end must be after the start');
  perform tests.assert_raises('moving the start past the saved end is refused too', format($q$select public.save_org_event(%L, %L, '{"start_date":"2031-10-26T22:00:00Z"}')$q$, orgA, ev), 'the end must be after the start');
  perform tests.assert_raises('on creation too', format($q$select public.save_org_event(%L, null, '{"title":"t","description":"d","venue_name":"v","start_date":"2031-01-02T20:00:00Z","end_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'the end must be after the start');
  perform tests.assert_raises('...and an end equal to the start on creation', format($q$select public.save_org_event(%L, null, '{"title":"t","description":"d","venue_name":"v","start_date":"2031-01-01T20:00:00Z","end_date":"2031-01-01T20:00:00Z"}')$q$, orgA), 'the end must be after the start');
  perform tests.logout();
  perform tests.assert_eq('none of the refused attempts changed the event', (select title || '|' || capacity::text from public.site_events where id = ev), 'Rooftop Party|100000');

  ---------------------------------------------------------------- changing only what is sent
  perform tests.login(org_u, 'organizer@night.example');
  perform public.save_org_event(orgA, ev, '{"capacity":250}');
  perform public.save_org_event(orgA, ev, '{"title":"Rooftop Party II"}');
  perform tests.logout();
  select * into r from public.site_events where id = ev;
  perform tests.assert_eq('a change to the title keeps everything else', r.title || '|' || r.venue_name || '|' || r.address || '|' || r.category || '|' || r.capacity::text || '|' || r.cover_image_url, 'Rooftop Party II|The Roof|1 King St W|Party|250|https://img.example/roof.jpg');
  perform tests.assert_true('...and the dates', r.start_date = '2031-10-24T22:00:00Z'::timestamptz and r.end_date = '2031-10-25T04:00:00Z'::timestamptz);
  perform tests.assert_eq('...and it is still a draft of the same business', r.status || '|' || r.org_id::text, 'draft|' || orgA::text);
  perform tests.login(org_u, 'organizer@night.example');
  perform public.save_org_event(orgA, ev, '{"address":"","category":null,"end_date":null,"cover_image_url":null,"capacity":null}');
  perform tests.logout();
  select * into r from public.site_events where id = ev;
  perform tests.assert_true('optional fields can be cleared (blank or null)', r.address is null and r.category is null and r.end_date is null and r.cover_image_url is null and r.capacity is null);
  perform tests.login(org_u, 'organizer@night.example');
  perform tests.assert_raises('a required field cannot be cleared', format($q$select public.save_org_event(%L, %L, '{"title":""}')$q$, orgA, ev), 'title is required');
  perform tests.assert_raises('...nor the start', format($q$select public.save_org_event(%L, %L, '{"start_date":null}')$q$, orgA, ev), 'start date is required');
  perform tests.assert_eq('the organizer sees the change', (select title from public.list_org_events(orgA) where event_id = ev), 'Rooftop Party II');
  perform tests.logout();  -- the audit log is the admin's to read; count it as the database owner
  select count(*) into n from public.audit_log where action = 'org_event.updated' and entity_id = ev::text;
  perform tests.assert_eq('every successful change is recorded and no refused attempt is', n, 6);

  ---------------------------------------------------------------- another business's events are unreachable
  perform tests.login(org2_u, 'organizer@other.example');
  evb := public.save_org_event(orgB, null, '{"title":"Other night","description":"d","venue_name":"Elsewhere","start_date":"2031-03-01T20:00:00Z"}');
  perform tests.assert_raises('an organizer cannot change another business''s event by naming its own business', format($q$select public.save_org_event(%L, %L, '{"title":"Hijacked"}')$q$, orgB, ev), 'event not found');
  perform tests.assert_raises('...nor remove it', format($q$select public.remove_org_event(%L, %L)$q$, orgB, ev), 'event not found');
  perform tests.assert_raises('...nor an event that does not exist', format($q$select public.save_org_event(%L, %L, '{"title":"x"}')$q$, orgB, gen_random_uuid()), 'event not found');
  perform tests.assert_raises('...nor a platform event', format($q$select public.save_org_event(%L, %L, '{"title":"x"}')$q$, orgB, platform_ev), 'event not found');
  perform tests.assert_raises('...nor remove one', format($q$select public.remove_org_event(%L, %L)$q$, orgB, platform_ev), 'event not found');
  perform tests.assert_eq('each business lists only its own events', (select count(*) from public.list_org_events(orgB))::int, 1);
  perform tests.login(org_u, 'organizer@night.example');
  perform tests.assert_eq('...the other''s', (select count(*) from public.list_org_events(orgA) where event_id = evb)::int, 0);
  perform tests.logout();
  perform tests.assert_eq('the other business''s event is untouched', (select title from public.site_events where id = evb), 'Other night');
  perform tests.assert_eq('...and so is the platform''s', (select title from public.site_events where id = platform_ev), 'Platform night');

  ---------------------------------------------------------------- listing
  perform tests.login(org_u, 'organizer@night.example');
  ev2 := public.save_org_event(orgA, null, '{"title":"Later party","description":"d","venue_name":"v","start_date":"2032-01-10T22:00:00Z"}');
  perform tests.logout();
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev, 'General', 2500, 100) returning id into tier;
  perform tests.login(org_u, 'organizer@night.example');
  -- WITH ORDINALITY numbers the rows in the order the function returned them, so this tests the function's own ordering.
  select string_agg(l.title, ',' order by l.ord) into txt
    from public.list_org_events(orgA) with ordinality as l(event_id, title, description, venue_name, address, start_date, end_date, category, capacity, cover_image_url, status, ticket_tier_count, ord)
    where l.title in ('Rooftop Party II', 'Later party');
  perform tests.assert_eq('the latest event is listed first', txt, 'Later party,Rooftop Party II');
  perform tests.assert_eq('ticket tiers are counted', (select ticket_tier_count from public.list_org_events(orgA) where event_id = ev), 1);
  perform tests.assert_eq('...an event with none says 0', (select ticket_tier_count from public.list_org_events(orgA) where event_id = ev2), 0);
  perform tests.assert_eq('a draft is listed as a draft', (select status from public.list_org_events(orgA) where event_id = ev2), 'draft');

  ---------------------------------------------------------------- a published event is out of reach
  perform tests.logout();
  ev_pub := ev2;
  update public.site_events set status = 'published' where id = ev_pub;
  perform tests.login(org_u, 'organizer@night.example');
  perform tests.assert_eq('a published event is listed as published', (select status from public.list_org_events(orgA) where event_id = ev_pub), 'published');
  perform tests.assert_raises('an organizer cannot change a published event', format($q$select public.save_org_event(%L, %L, '{"title":"Changed after sales"}')$q$, orgA, ev_pub), 'published, so only BottlesUp can change it');
  perform tests.assert_raises('...nor remove it', format($q$select public.remove_org_event(%L, %L)$q$, orgA, ev_pub), 'published, so only BottlesUp can remove it');
  perform tests.logout();
  perform tests.assert_eq('it is unchanged', (select title from public.site_events where id = ev_pub), 'Later party');

  ---------------------------------------------------------------- removing a draft
  perform tests.login(org_u, 'organizer@night.example');
  perform public.remove_org_event(orgA, ev);
  perform tests.logout();
  perform tests.assert_eq('a draft can be removed', (select count(*) from public.site_events where id = ev)::int, 0);
  perform tests.assert_eq('...with its ticket tiers', (select count(*) from public.site_ticket_tiers where id = tier)::int, 0);
  perform tests.assert_eq('...and it is recorded, with the title', (select details ->> 'title' from public.audit_log where action = 'org_event.removed' and entity_id = ev::text), 'Rooftop Party II');

  perform tests.login(org_u, 'organizer@night.example');
  ev_order := public.save_org_event(orgA, null, '{"title":"Has an order","description":"d","venue_name":"v","start_date":"2032-02-10T22:00:00Z"}');
  perform tests.logout();
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity) values (ev_order, 'General', 2000, 10) returning id into tier;
  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, quantity, amount_total_cents) values (ev_order, tier, 'Ada', 'ada@test.example', 1, 2000);
  perform tests.login(org_u, 'organizer@night.example');
  perform tests.assert_raises('a draft that already has an order cannot be removed', format($q$select public.remove_org_event(%L, %L)$q$, orgA, ev_order), 'already has orders');
  perform tests.logout();
  perform tests.assert_eq('...it and its order are still there', (select count(*) from public.site_events where id = ev_order)::int + (select count(*) from public.site_orders where event_id = ev_order)::int, 2);

  ---------------------------------------------------------------- a limit per business
  insert into public.site_events (title, description, venue_name, start_date, status, org_id)
    select 'Filler ' || g, 'd', 'v', '2033-01-01T20:00:00Z', 'draft', orgB from generate_series(1, 199) g;
  perform tests.login(org2_u, 'organizer@other.example');
  perform tests.assert_eq('a business is at 200 events', (select count(*) from public.list_org_events(orgB))::int, 200);
  perform tests.assert_raises('the 201st is refused', format($q$select public.save_org_event(%L, null, '{"title":"One too many","description":"d","venue_name":"v","start_date":"2033-02-01T20:00:00Z"}')$q$, orgB), '200 events at most');
  perform tests.assert_true('...but an existing one can still be changed', public.save_org_event(orgB, evb, '{"title":"Still editable"}') = evb);
  perform public.remove_org_event(orgB, evb);
  perform tests.assert_true('...and removing one makes room', public.save_org_event(orgB, null, '{"title":"Fits now","description":"d","venue_name":"v","start_date":"2033-02-01T20:00:00Z"}') is not null);

  ---------------------------------------------------------------- cancelling a business added by mistake (cancel_business)
  perform tests.login(stranger, 'stranger@example.com');
  orgC := public.create_organization('Mistake Events', 'organizer');
  evc := public.save_org_event(orgC, null, '{"title":"Draft made by mistake","description":"d","venue_name":"v","start_date":"2033-05-01T20:00:00Z"}');
  perform public.save_org_event(orgC, null, '{"title":"Second draft","description":"d","venue_name":"v","start_date":"2033-06-01T20:00:00Z"}');
  perform tests.logout();
  update public.site_events set status = 'published' where id = evc;
  perform tests.login(stranger, 'stranger@example.com');
  perform tests.assert_raises('an organizer whose event was published cannot cancel the business', format($q$select public.cancel_business(%L)$q$, orgC), 'published event');
  perform tests.logout();
  update public.site_events set status = 'draft' where id = evc;
  perform tests.login(stranger, 'stranger@example.com');
  perform public.cancel_business(orgC);
  perform tests.logout();
  perform tests.assert_eq('with only drafts, cancelling removes the business and the drafts made through save_org_event', (select count(*) from public.site_organizations where id = orgC)::int + (select count(*) from public.site_events where org_id = orgC or id = evc)::int, 0);

  ---------------------------------------------------------------- the audit trail cannot be forged and has no anonymous entries
  perform tests.login(org2_u, 'organizer@other.example');
  perform tests.assert_raises('the app cannot write an audit entry itself', format($q$select public.org_event_log('org_event.forged', %L, %L)$q$, platform_ev, orgB), 'permission denied');
  perform tests.assert_raises('...nor use the internal validators', $q$select public.org_event_text('{}', 'title', 'title', 5, false)$q$, 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('the forged entry was not written', (select count(*) from public.audit_log where action = 'org_event.forged')::int, 0);
  perform tests.assert_eq('no entry is anonymous', (select count(*) from public.audit_log where action like 'org_event.%' and (actor_id is null or actor_email = 'unknown'))::int, 0);
end $$;

rollback;
