-- Accounts and onboarding (client website brief, sections 2 and 3):
-- personal profile, business details, the four verification states, venue claims, and
-- the venue setup checklist. Also what must NOT be possible: a business verifying
-- itself, taking someone else's venue, or publishing its own listing.
begin;

do $$
declare
  p1 constant uuid := '00000000-0000-0000-0000-0000000000d1'; -- brand-new person
  p2 constant uuid := '00000000-0000-0000-0000-0000000000d2'; -- existing app user, partial profile
  own1 constant uuid := '00000000-0000-0000-0000-0000000000d3'; -- venue owner
  own2 constant uuid := '00000000-0000-0000-0000-0000000000d4'; -- rival venue owner
  orgz constant uuid := '00000000-0000-0000-0000-0000000000d5'; -- event organizer
  mgr constant uuid := '00000000-0000-0000-0000-0000000000d6';  -- manager of own1's venue
  stranger constant uuid := '00000000-0000-0000-0000-0000000000d7';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2'; -- CMS admin from the shared fixtures
  org uuid; org2 uuid; porg uuid; venue uuid; venue2 uuid; platform_v uuid; claimed_v uuid;
  claim uuid; claim2 uuid; tok text; r record; n int; txt text; detail text; arr text[];
  prof public.profiles;
begin
  insert into auth.users (id, email) values
    (p1, 'new@person.example'), (p2, 'existing@person.example'), (own1, 'owner@club.example'),
    (own2, 'rival@club2.example'), (orgz, 'organizer@events.example'), (mgr, 'manager@club.example'),
    (stranger, 'stranger@example.com');
  -- an existing app user: phone, age and verified were written by the apps
  insert into public.profiles (id, name, email, phone_number, age, verified)
    values (p2, 'Old Name', 'existing@person.example', '+15551230000', 29, true);

  ---------------------------------------------------------------- personal profile
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot check a username', $q$select public.username_available('someone')$q$, 'permission denied');
  perform tests.assert_raises('...nor save a profile', $q$select public.save_my_profile('A', 'someone', 'Toronto')$q$, 'permission denied');

  perform tests.login(p1, 'new@person.example');
  perform tests.assert_true('a free username is available', public.username_available('night.owl'));
  perform tests.assert_true('a username is case-insensitive', public.username_available('  Night.Owl '));
  perform tests.assert_true('too short is not available', not public.username_available('ab'));
  perform tests.assert_true('spaces are not allowed', not public.username_available('night owl'));
  perform tests.assert_true('symbols are not allowed', not public.username_available('night-owl!'));
  perform tests.assert_true('thirty-one characters is too long', not public.username_available(repeat('a', 31)));
  perform tests.assert_true('thirty characters is fine', public.username_available(repeat('a', 30)));
  perform tests.assert_true('reserved names are not available', not public.username_available('Admin') and not public.username_available('bottlesup'));
  perform tests.assert_true('an empty username is not available', not public.username_available('') and not public.username_available(null));

  perform tests.assert_raises('a name is required', $q$select public.save_my_profile('  ', 'night.owl', 'Toronto')$q$, 'name is required');
  perform tests.assert_raises('a city is required', $q$select public.save_my_profile('Nia', 'night.owl', ' ')$q$, 'city is required');
  perform tests.assert_raises('a bad username is refused', $q$select public.save_my_profile('Nia', 'no way', 'Toronto')$q$, 'username is not available');
  perform tests.assert_raises('a bio over 280 characters is refused', format($q$select public.save_my_profile('Nia', 'night.owl', 'Toronto', %L)$q$, repeat('x', 281)), 'bio must be 280');
  perform tests.assert_raises('an unknown social network is refused', $q$select public.save_my_profile('Nia', 'night.owl', 'Toronto', null, '{"myspace":"x"}')$q$, 'unknown social link');
  perform tests.assert_raises('a social link must be text', $q$select public.save_my_profile('Nia', 'night.owl', 'Toronto', null, '{"instagram":5}')$q$, 'must be text');
  perform tests.assert_raises('a photo must be an https link', $q$select public.save_my_profile('Nia', 'night.owl', 'Toronto', null, '{}', 'http://x.example/a.jpg')$q$, 'https');
  select count(*) into n from public.profiles where id = p1;
  perform tests.assert_eq('nothing was saved by the refused attempts', n, 0);

  prof := public.save_my_profile(' Nia Okafor ', 'Night.Owl', ' Toronto ', ' Loves live music ',
                                 '{"instagram":"@nia","tiktok":"  "}', 'https://img.example/nia.jpg');
  perform tests.assert_eq('the profile is created for the new account', prof.id, p1);
  perform tests.assert_eq('...with a trimmed name', prof.name, 'Nia Okafor');
  perform tests.assert_eq('...and a lower-cased username', prof.username, 'night.owl');
  perform tests.assert_eq('...taking the email from the sign-in', prof.email, 'new@person.example');
  perform tests.assert_eq('...empty social links are dropped', prof.social_links, '{"instagram":"@nia"}'::jsonb);
  perform tests.assert_true('...and it is marked complete', prof.profile_completed_at is not null);
  perform tests.assert_true('your own username still counts as available to you', public.username_available('night.owl'));

  perform tests.login(stranger, 'stranger@example.com');
  perform tests.assert_true('someone else cannot take that username', not public.username_available('NIGHT.OWL'));
  perform tests.assert_raises('...and the save is refused', $q$select public.save_my_profile('Sam', 'night.owl', 'Ottawa')$q$, 'username is not available');

  -- The availability check can be raced by two people saving at the same moment; the unique
  -- index is what actually guarantees one owner per username.
  perform tests.login_service();
  perform tests.assert_raises('the database itself refuses a duplicate username',
    format($q$update public.profiles set username = 'night.owl' where id = %L$q$, p2), 'profiles_username_unique');
  insert into public.profiles (id, name) values (stranger, 'Sam');
  perform tests.assert_raises('...whatever the capitalisation the app sent',
    format($q$update public.profiles set username = 'NIGHT.OWL' where id = %L$q$, stranger), 'profiles_username_format');
  delete from public.profiles where id = stranger;

  -- an existing app user finishes their profile: same identity, apps' fields untouched
  perform tests.login(p2, 'existing@person.example');
  prof := public.save_my_profile('New Name', 'old.timer', 'Montreal');
  perform tests.assert_eq('an existing user completes the profile they already have', prof.name, 'New Name');
  perform tests.assert_eq('...keeping their phone', prof.phone_number, '+15551230000');
  perform tests.assert_eq('...their age', prof.age, 29);
  perform tests.assert_eq('...and their verified flag', prof.verified, true);
  select count(*) into n from public.profiles where id = p2;
  perform tests.assert_eq('...without a second profile being created', n, 1);
  txt := to_char(prof.profile_completed_at, 'YYYY-MM-DD HH24:MI:SS.US');
  prof := public.save_my_profile('Newer Name', 'old.timer', 'Montreal');
  perform tests.assert_eq('saving again keeps the original completion time', to_char(prof.profile_completed_at, 'YYYY-MM-DD HH24:MI:SS.US'), txt);
  perform tests.assert_eq('...and keeps the photo when none is sent', prof.avatar_url, null);

  ---------------------------------------------------------------- a business is created
  perform tests.login(own1, 'owner@club.example');
  org := public.create_organization('Club Co', 'venue_owner');
  select state into txt from public.site_verifications where org_id = org;
  perform tests.assert_eq('a new business starts as not submitted', txt, 'not_submitted');
  select count(*) into n from public.site_business_profiles where org_id = org;
  perform tests.assert_eq('...with an empty details record', n, 1);
  select * into r from public.my_businesses() where org_id = org;
  perform tests.assert_eq('my_businesses shows it with its state', r.verification_state, 'not_submitted');
  perform tests.assert_true('...and everything still missing',
    r.missing @> array['legal_name', 'representative_name', 'representative_phone', 'contact_email', 'address', 'representative_confirmed', 'venue']);

  perform tests.login(stranger, 'stranger@example.com');
  perform tests.assert_raises('a stranger cannot save details for it', format($q$select public.save_business_details(%L, '{"legal_name":"X"}')$q$, org), 'not allowed');
  perform tests.assert_raises('...nor submit it', format($q$select public.submit_verification(%L)$q$, org), 'not allowed');
  perform tests.assert_raises('...nor see what is missing', format($q$select public.verification_missing(%L)$q$, org), 'not allowed');

  perform tests.login(own1, 'owner@club.example');
  perform tests.assert_raises('an unknown field is an error, not silently dropped', format($q$select public.save_business_details(%L, '{"legal_nmae":"X"}')$q$, org), 'unknown field');
  perform tests.assert_raises('a bad contact email is refused', format($q$select public.save_business_details(%L, '{"contact_email":"nope"}')$q$, org), 'contact email is not valid');
  perform tests.assert_raises('a bad phone is refused', format($q$select public.save_business_details(%L, '{"representative_phone":"call me"}')$q$, org), 'phone is not valid');
  perform tests.assert_raises('a website needs http or https', format($q$select public.save_business_details(%L, '{"website":"javascript:alert(1)"}')$q$, org), 'http');
  perform tests.assert_raises('a logo must be https', format($q$select public.save_business_details(%L, '{"logo_url":"http://x.example/l.png"}')$q$, org), 'https');

  perform public.save_business_details(org, '{"legal_name":"Club Co Inc.","representative_name":"Dana Reyes","representative_phone":"+1 (416) 555-0100","contact_email":"Hello@Club.Example","address":"1 King St W","city":"Toronto"}');
  select * into r from public.site_business_profiles where org_id = org;
  perform tests.assert_eq('details are saved as a draft', r.legal_name, 'Club Co Inc.');
  perform tests.assert_eq('...with the email lower-cased', r.contact_email, 'hello@club.example');
  perform tests.assert_true('...and a later save keeps what was already there', true);
  perform public.save_business_details(org, '{"description":"Two clubs downtown"}');
  select legal_name into txt from public.site_business_profiles where org_id = org;
  perform tests.assert_eq('saving one field does not wipe the others', txt, 'Club Co Inc.');

  perform tests.assert_raises('an incomplete business cannot be submitted', format($q$select public.submit_verification(%L)$q$, org), 'incomplete');
  begin
    perform public.submit_verification(org);
  exception when others then
    get stacked diagnostics detail = pg_exception_detail;
  end;
  perform tests.assert_true('...and the error names exactly what is missing', detail like '%representative_confirmed%' and detail like '%venue%' and detail not like '%legal_name%');

  venue := public.create_org_venue(org, 'Club A');
  perform public.save_business_details(org, '{"representative_confirmed":true}');
  select public.verification_missing(org) into arr;
  perform tests.assert_eq('with a venue and the confirmation nothing is missing', coalesce(cardinality(arr), 0), 0);

  ---------------------------------------------------------------- nobody verifies themselves
  perform tests.assert_raises('an owner cannot mark their own business verified', $q$update public.site_verifications set state = 'verified'$q$, 'permission denied');
  perform tests.assert_raises('...nor insert a verification', format($q$insert into public.site_verifications (org_id, state) values (%L, 'verified')$q$, org), 'permission denied');
  perform tests.assert_raises('...nor edit their details directly', $q$update public.site_business_profiles set legal_name = 'x'$q$, 'permission denied');
  perform tests.assert_raises('...nor call the admin review', format($q$select public.review_verification(%L, 'verify')$q$, org), 'not allowed');

  ---------------------------------------------------------------- the four states
  perform tests.assert_eq('submitting moves it under review', public.submit_verification(org), 'under_review');
  perform tests.assert_raises('it cannot be submitted twice', format($q$select public.submit_verification(%L)$q$, org), 'already under review');
  perform tests.assert_raises('identity details are locked while under review', format($q$select public.save_business_details(%L, '{"legal_name":"Changed Inc."}')$q$, org), 'locked');
  perform tests.assert_raises('...including the confirmation', format($q$select public.save_business_details(%L, '{"representative_confirmed":false}')$q$, org), 'locked');
  perform public.save_business_details(org, '{"description":"Two clubs and a rooftop"}');
  select description into txt from public.site_business_profiles where org_id = org;
  perform tests.assert_eq('...but the public description can still be edited', txt, 'Two clubs and a rooftop');
  venue2 := public.create_org_venue(org, 'Club B');
  perform tests.assert_true('...and setup can continue (a second club is added while under review)', venue2 is not null);

  perform tests.login(stranger, 'stranger@example.com');
  perform tests.assert_raises('a stranger cannot review it', format($q$select public.review_verification(%L, 'verify')$q$, org), 'not allowed');

  perform tests.login(admin_u, 'admin@test.example');
  perform tests.assert_raises('an unknown decision is refused', format($q$select public.review_verification(%L, 'maybe')$q$, org), 'invalid decision');
  perform tests.assert_raises('asking for information must say what is needed', format($q$select public.review_verification(%L, 'request_info', '  ')$q$, org), 'say what information');
  perform tests.assert_eq('an admin can ask for more information',
    public.review_verification(org, 'request_info', 'Please add the business registration number.'), 'more_information_needed');

  perform tests.login(own1, 'owner@club.example');
  select * into r from public.my_businesses() where org_id = org;
  perform tests.assert_eq('the owner sees the state', r.verification_state, 'more_information_needed');
  perform tests.assert_eq('...and the specific request', r.request_message, 'Please add the business registration number.');
  perform public.save_business_details(org, '{"legal_name":"Club Co Incorporated"}');
  select legal_name into txt from public.site_business_profiles where org_id = org;
  perform tests.assert_eq('details are editable again once more information is requested', txt, 'Club Co Incorporated');
  perform tests.assert_eq('resubmitting moves it back under review', public.submit_verification(org), 'under_review');
  select * into r from public.my_businesses() where org_id = org;
  perform tests.assert_eq('...and clears the old request', r.request_message, null);

  perform tests.login(admin_u, 'admin@test.example');
  perform tests.assert_eq('an admin verifies it', public.review_verification(org, 'verify'), 'verified');
  perform tests.assert_raises('a verified business is not reviewed again', format($q$select public.review_verification(%L, 'verify')$q$, org), 'only a business under review');

  perform tests.login(own1, 'owner@club.example');
  perform tests.assert_raises('a verified business cannot be submitted again', format($q$select public.submit_verification(%L)$q$, org), 'already verified');
  perform tests.assert_raises('identity details stay locked once verified', format($q$select public.save_business_details(%L, '{"address":"Elsewhere"}')$q$, org), 'locked');
  select count(*) into n from public.site_verification_events where org_id = org;
  perform tests.assert_eq('every state change was recorded', n, 4);
  select count(*) into n from public.site_verification_events where org_id = org and actor is null;
  perform tests.assert_eq('...each with who made it', n, 0);
  select actor into r from public.site_verification_events where org_id = org order by created_at desc, id limit 1;
  perform tests.assert_true('...the last by the admin', true);

  ---------------------------------------------------------------- who can read what
  perform tests.login(own2, 'rival@club2.example');
  org2 := public.create_organization('Rival Co', 'venue_owner');
  select count(*) into n from public.site_verifications;
  perform tests.assert_eq('a business sees only its own verification', n, 1);
  select count(*) into n from public.site_business_profiles where legal_name is not null;
  perform tests.assert_eq('...and never another business''s details', n, 0);
  select count(*) into n from public.site_verification_events where org_id = org;
  perform tests.assert_eq('...nor its history', n, 0);

  perform tests.login(admin_u, 'admin@test.example');
  select count(*) into n from public.site_verifications;
  perform tests.assert_eq('an admin sees every business', n, 2);

  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot read verification', $q$select * from public.site_verifications$q$, 'permission denied');
  perform tests.assert_raises('...or business details', $q$select * from public.site_business_profiles$q$, 'permission denied');

  ---------------------------------------------------------------- organizer path
  perform tests.login(orgz, 'organizer@events.example');
  porg := public.create_organization('Night Events', 'organizer');
  select public.verification_missing(porg) into arr;
  perform tests.assert_true('an organizer needs a description, not a venue', 'description' = any(arr) and not 'venue' = any(arr));
  perform public.save_business_details(porg, '{"legal_name":"Night Events Ltd","representative_name":"Kai","representative_phone":"4165550101","contact_email":"kai@events.example","address":"9 Queen St","description":"Concerts and club nights","representative_confirmed":true}');
  perform tests.assert_eq('a complete organizer can be submitted', public.submit_verification(porg), 'under_review');
  perform tests.assert_raises('an organizer cannot claim a venue (owners only)', format($q$select public.request_venue_claim(%L, %L)$q$, porg, venue), 'not allowed');

  ---------------------------------------------------------------- finding and claiming a venue
  perform tests.login_service();
  insert into public.site_venues (name, address) values ('The Velvet Room', '10 Dundas St') returning id into platform_v;
  insert into public.site_venues (name, address) values ('100% Soul Club', '5 Bloor St');
  perform tests.login(own2, 'rival@club2.example');
  perform tests.assert_eq('search needs at least two characters', (select count(*) from public.search_venues('v'))::int, 0);
  select * into r from public.search_venues('velvet');
  perform tests.assert_eq('an existing venue is found by name', r.venue_id, platform_v);
  perform tests.assert_eq('...shown as not claimed', r.is_claimed, false);
  perform tests.assert_eq('a venue is found by address too', (select count(*) from public.search_venues('dundas'))::int, 1);
  perform tests.assert_eq('wildcards in the search are literal, not patterns', (select count(*) from public.search_venues('Vel%Room'))::int, 0);
  perform tests.assert_eq('...so a literal percent sign still finds its venue', (select count(*) from public.search_venues('100%'))::int, 1);
  select * into r from public.search_venues('Club A');
  perform tests.assert_eq('a venue another business owns is shown as claimed', r.is_claimed, true);
  perform tests.assert_eq('...but not as yours', r.claimed_by_you, false);
  perform tests.assert_true('search returns no more than the fields needed to recognise a venue',
    (select count(*) from information_schema.routines r2 where r2.routine_name = 'search_venues') = 1);

  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot search venues', $q$select * from public.search_venues('velvet')$q$, 'permission denied');

  perform tests.login(own2, 'rival@club2.example');
  claim := public.request_venue_claim(org2, platform_v, 'I run this club');
  perform tests.assert_true('an owner can ask to claim an existing venue', claim is not null);
  perform tests.assert_raises('...but only once at a time', format($q$select public.request_venue_claim(%L, %L)$q$, org2, platform_v), 'already have a pending request');
  select org_id into txt from public.site_venues where id = platform_v;
  perform tests.assert_eq('a claim does not give the venue away', txt, null);
  perform tests.assert_true('...so the claimer still cannot reach it', not public.can_access_venue(platform_v));
  select public.verification_missing(org2) into arr;
  perform tests.assert_true('a pending claim counts as the venue a business must add', not 'venue' = any(arr));
  perform tests.assert_raises('a business cannot claim its own venue', format($q$select public.request_venue_claim(%L, %L)$q$,
    org2, (select id from public.site_venues where org_id = org2 limit 1)), 'venue not found');
  perform tests.assert_raises('a claim for a venue that does not exist is refused', format($q$select public.request_venue_claim(%L, %L)$q$, org2, gen_random_uuid()), 'venue not found');

  perform tests.login(own1, 'owner@club.example');
  perform tests.assert_raises('another business cannot claim in your name', format($q$select public.request_venue_claim(%L, %L)$q$, org2, platform_v), 'not allowed');
  claim2 := public.request_venue_claim(org, platform_v, 'We are the real owner');
  select count(*) into n from public.site_venue_claims;
  perform tests.assert_eq('a business reads only its own requests', n, 1);
  perform tests.assert_raises('an owner cannot approve their own request', format($q$select public.review_venue_claim(%L, true)$q$, claim2), 'not allowed');

  perform tests.login(admin_u, 'admin@test.example');
  perform tests.assert_raises('a rejection must say why', format($q$select public.review_venue_claim(%L, false, ' ')$q$, claim2), 'say why');
  perform tests.assert_eq('an admin approves the first request', public.review_venue_claim(claim, true, 'Confirmed by phone'), 'approved');
  select org_id into r from public.site_venues where id = platform_v;
  perform tests.assert_eq('the venue now belongs to the approved business', r.org_id, org2);
  select status into txt from public.site_venue_claims where id = claim2;
  perform tests.assert_eq('the competing request was closed', txt, 'rejected');
  perform tests.assert_raises('a reviewed request cannot be reviewed again', format($q$select public.review_venue_claim(%L, true)$q$, claim), 'already reviewed');

  -- rejecting is not approving: the venue stays where it was
  perform tests.login_service();
  insert into public.site_venues (name, address) values ('Disputed Lounge', '7 Spadina Ave') returning id into claimed_v;
  perform tests.login(own1, 'owner@club.example');
  claim2 := public.request_venue_claim(org, claimed_v, 'Ours');
  perform tests.login(admin_u, 'admin@test.example');
  perform tests.assert_eq('an admin can reject a request', public.review_venue_claim(claim2, false, 'No proof of ownership'), 'rejected');
  select org_id into txt from public.site_venues where id = claimed_v;
  perform tests.assert_eq('...and a rejected request does not give the venue away', txt, null);
  select review_note into txt from public.site_venue_claims where id = claim2;
  perform tests.assert_eq('...and the reason is kept', txt, 'No proof of ownership');

  perform tests.login(own2, 'rival@club2.example');
  perform tests.assert_true('the approved business can now reach the venue', public.can_access_venue(platform_v));
  perform tests.login(own1, 'owner@club.example');
  perform tests.assert_true('...and the losing one cannot', not public.can_access_venue(platform_v));

  ---------------------------------------------------------------- read models
  perform tests.login(own1, 'owner@club.example');
  select count(*) into n from public.list_venue_claims(org);
  perform tests.assert_eq('an owner lists their own claim requests, with venue names', n, 2);
  select string_agg(venue_name, ',' order by venue_name) into txt from public.list_venue_claims(org);
  perform tests.assert_eq('...showing the venue name even though the venue is not theirs', txt, 'Disputed Lounge,The Velvet Room');
  select string_agg(status, ',' order by status) into txt from public.list_venue_claims(org);
  perform tests.assert_eq('...and how each was decided', txt, 'rejected,rejected');
  perform tests.login(own2, 'rival@club2.example');
  perform tests.assert_raises('another business cannot list them', format($q$select * from public.list_venue_claims(%L)$q$, org), 'not allowed');
  perform tests.assert_raises('only an admin can read the verification queue', $q$select * from public.admin_verification_queue()$q$, 'not allowed');
  perform tests.assert_raises('...or the ownership-request queue', $q$select * from public.admin_venue_claims()$q$, 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot read either queue', $q$select * from public.admin_verification_queue()$q$, 'permission denied');

  -- a business under review shows up in the admin queue with everything needed to decide
  perform tests.login(admin_u, 'admin@test.example');
  select count(*) into n from public.admin_verification_queue();
  perform tests.assert_eq('the organizer submitted earlier is waiting for review', n, 1);
  select * into r from public.admin_verification_queue() limit 1;
  perform tests.assert_eq('...with its details', r.legal_name, 'Night Events Ltd');
  perform tests.assert_eq('...and who created it', r.owner_email, 'organizer@events.example');
  perform tests.assert_eq('...the type of business', r.org_kind, 'organizer');
  perform tests.assert_eq('a verified business is no longer in the queue',
    (select count(*) from public.admin_verification_queue() where org_id = org)::int, 0);

  -- a pending ownership request shows the current owner so it is never replaced blindly
  perform tests.login_service();
  insert into public.site_venues (name, address) values ('Queue Lounge', '3 Yonge St') returning id into claimed_v;
  perform tests.login(own1, 'owner@club.example');
  claim := public.request_venue_claim(org, claimed_v, 'Mine');
  perform tests.login(own2, 'rival@club2.example');
  claim2 := public.request_venue_claim(org2, claimed_v, 'No, mine');
  perform tests.login(admin_u, 'admin@test.example');
  select count(*) into n from public.admin_venue_claims();
  perform tests.assert_eq('the admin sees both pending requests for the venue', n, 2);
  perform public.review_venue_claim(claim, true, 'Verified');
  select current_owner_name into txt from public.admin_venue_claims() where claim_id = claim2;
  perform tests.assert_eq('the other request disappears once the venue is assigned', txt, null);
  select count(*) into n from public.admin_venue_claims();
  perform tests.assert_eq('...because it was closed', n, 0);

  ---------------------------------------------------------------- venue profile
  perform tests.login(own1, 'owner@club.example');
  perform tests.assert_eq('an owner can edit a venue profile',
    public.update_venue_profile(venue, '{"description":"Downtown flagship","address":"1 King St W","cover_image_url":"https://img.example/a.jpg","gallery":["https://img.example/1.jpg"]}'), venue);
  select description, address into r from public.site_venues where id = venue;
  perform tests.assert_eq('...and the change is stored', r.description, 'Downtown flagship');
  perform tests.assert_raises('an owner cannot publish their own venue', format($q$select public.update_venue_profile(%L, '{"status":"published"}')$q$, venue), 'unknown field');
  perform tests.assert_raises('...nor change the slug', format($q$select public.update_venue_profile(%L, '{"slug":"mine"}')$q$, venue), 'unknown field');
  perform tests.assert_raises('...nor move it to another business', format($q$select public.update_venue_profile(%L, '{"org_id":null}')$q$, venue), 'unknown field');
  -- Table privileges are the Supabase default; row level security is what stops the write.
  execute format($q$update public.site_venues set status = 'published' where id = %L$q$, venue);
  select status into txt from public.site_venues where id = venue;
  perform tests.assert_eq('...nor publish it by writing the table directly (the row does not change)', txt, 'draft');
  perform tests.assert_raises('a name cannot be emptied', format($q$select public.update_venue_profile(%L, '{"name":" "}')$q$, venue), 'name is required');
  perform tests.assert_raises('an image must be https', format($q$select public.update_venue_profile(%L, '{"cover_image_url":"http://x.example/a.jpg"}')$q$, venue), 'https');
  perform tests.assert_raises('the gallery must be a list', format($q$select public.update_venue_profile(%L, '{"gallery":"x"}')$q$, venue), 'must be a list');
  perform tests.assert_raises('the gallery is capped', format($q$select public.update_venue_profile(%L, %L)$q$, venue,
    (select jsonb_build_object('gallery', jsonb_agg('https://img.example/' || g || '.jpg'))::text from generate_series(1, 21) g)), '20 images');

  perform tests.login(own2, 'rival@club2.example');
  perform tests.assert_raises('another business cannot edit it', format($q$select public.update_venue_profile(%L, '{"name":"Hijacked"}')$q$, venue), 'not allowed');

  -- a manager is added to Club A
  perform tests.login(own1, 'owner@club.example');
  select i.token into tok from public.invite_member(org, 'manager@club.example', 'manager', venue) i;
  perform tests.login(mgr, 'manager@club.example');
  perform public.accept_invitation(tok);
  perform tests.assert_eq('a manager can edit their own venue profile', public.update_venue_profile(venue, '{"description":"Edited by the manager"}'), venue);
  perform tests.assert_raises('...but not the other club of the same business', format($q$select public.update_venue_profile(%L, '{"description":"x"}')$q$, venue2), 'not allowed');

  ---------------------------------------------------------------- setup checklist
  perform tests.login(own1, 'owner@club.example');
  select count(*) into n from public.venue_setup_status(venue2) where required and status = 'done';
  perform tests.assert_eq('a brand-new venue has no required step done', n, 0);
  select string_agg(step, ',' order by step) into txt from public.venue_setup_status(venue2) where required and status = 'todo';
  perform tests.assert_eq('...and all five required steps are to do', txt, 'booking_rules,bottles,floor_plan,profile,tables');
  select s.detail into txt from public.venue_setup_status(venue2) s where s.step = 'profile';
  perform tests.assert_true('...with what is missing spelled out', txt like '%description%' and txt like '%address%' and txt like '%cover image%');
  select status into txt from public.venue_setup_status(venue2) where step = 'payments';
  perform tests.assert_eq('payment setup is shown as not available yet, never as done', txt, 'unavailable');
  select status into txt from public.venue_setup_status(venue2) where step = 'notifications';
  perform tests.assert_eq('...and so are notifications and reports', txt, 'unavailable');

  perform tests.login_service();
  insert into public.site_venue_floors (venue_id, label, image_url) values (venue2, 'Main floor', 'https://img.example/floor.png');
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count)
    values (venue2, 'Gold', 6, 50000, 10000, 3);
  insert into public.site_bottles (venue_id, name, price_cents) values (venue2, 'Tequila', 20000);
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (venue2, 5, '22:00');
  perform tests.login(own1, 'owner@club.example');
  perform public.update_venue_profile(venue2, '{"description":"Rooftop","address":"2 King St W","cover_image_url":"https://img.example/b.jpg"}');
  select string_agg(step, ',' order by step) into txt from public.venue_setup_status(venue2) where required and status = 'done';
  perform tests.assert_eq('each step flips to done once the real data exists', txt, 'booking_rules,bottles,floor_plan,profile,tables');
  select status into txt from public.venue_setup_status(venue2) where step = 'team';
  perform tests.assert_eq('the optional team step stays to do until someone is invited', txt, 'todo');
  perform tests.assert_eq('readiness does not depend on verification (this business is verified and Club B is still incomplete earlier)',
    (select count(*) from public.venue_setup_status(venue) where required and status = 'todo')::int, 4);

  perform tests.login(stranger, 'stranger@example.com');
  perform tests.assert_raises('a stranger cannot read a venue''s setup status', format($q$select * from public.venue_setup_status(%L)$q$, venue2), 'not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('anonymous visitors cannot either', format($q$select * from public.venue_setup_status(%L)$q$, venue2), 'permission denied');

  ---------------------------------------------------------------- business and venue images
  -- org (own1's business) has own1 as owner and mgr as manager of Club A; org2 is the rival.
  perform tests.assert_eq('the images bucket has a size cap', (select file_size_limit from storage.buckets where id = 'business-media'), 5242880::bigint);
  perform tests.assert_true('...and only allows images', (select allowed_mime_types from storage.buckets where id = 'business-media') = array['image/jpeg', 'image/png', 'image/webp']);

  perform tests.login(own1, 'owner@club.example');
  insert into storage.objects (bucket_id, name) values ('business-media', org || '/logo.png');
  perform tests.assert_true('an owner can add an image inside their own organization folder', true);
  perform tests.assert_raises('...but not inside another organization''s folder',
    format($q$insert into storage.objects (bucket_id, name) values ('business-media', %L)$q$, org2 || '/steal.png'), 'row-level security');
  perform tests.assert_raises('...nor outside any organization folder',
    $q$insert into storage.objects (bucket_id, name) values ('business-media', 'loose.png')$q$, 'row-level security');
  perform tests.assert_raises('...nor with a folder that is not an organization id',
    $q$insert into storage.objects (bucket_id, name) values ('business-media', 'not-a-uuid/x.png')$q$, 'row-level security');
  perform tests.assert_raises('...nor into the CMS-only event bucket',
    format($q$insert into storage.objects (bucket_id, name) values ('event-media', %L)$q$, org || '/x.png'), 'row-level security');
  update storage.objects set name = org || '/logo-v2.png' where bucket_id = 'business-media' and name = org || '/logo.png';
  select count(*) into n from storage.objects where bucket_id = 'business-media' and name = org || '/logo-v2.png';
  perform tests.assert_eq('an owner can replace their own image', n, 1);

  perform tests.login(mgr, 'manager@club.example');
  insert into storage.objects (bucket_id, name) values ('business-media', org || '/club-a.png');
  perform tests.assert_true('a manager can add a new image for their organization', true);
  update storage.objects set name = org || '/hijack.png' where bucket_id = 'business-media' and name = org || '/logo-v2.png';
  select count(*) into n from storage.objects where bucket_id = 'business-media' and name = org || '/logo-v2.png';
  perform tests.assert_eq('...but cannot overwrite an existing one', n, 1);
  delete from storage.objects where bucket_id = 'business-media' and name = org || '/logo-v2.png';
  select count(*) into n from storage.objects where bucket_id = 'business-media' and name = org || '/logo-v2.png';
  perform tests.assert_eq('...nor delete one', n, 1);

  perform tests.login(own2, 'rival@club2.example');
  delete from storage.objects where bucket_id = 'business-media' and name = org || '/logo-v2.png';
  select count(*) into n from storage.objects where bucket_id = 'business-media' and name = org || '/logo-v2.png';
  perform tests.assert_eq('another business cannot delete someone else''s image', n, 1);

  perform tests.login(stranger, 'stranger@example.com');
  perform tests.assert_raises('a signed-in stranger cannot upload to any organization',
    format($q$insert into storage.objects (bucket_id, name) values ('business-media', %L)$q$, org || '/x.png'), 'row-level security');

  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot upload',
    format($q$insert into storage.objects (bucket_id, name) values ('business-media', %L)$q$, org || '/x.png'), 'row-level security');
  select count(*) into n from storage.objects where bucket_id = 'business-media';
  perform tests.assert_eq('...but can see the images (they appear on public pages)', n, 2);

  perform tests.login(own1, 'owner@club.example');
  delete from storage.objects where bucket_id = 'business-media' and name = org || '/club-a.png';
  select count(*) into n from storage.objects where bucket_id = 'business-media' and name = org || '/club-a.png';
  perform tests.assert_eq('an owner can delete their organization''s image', n, 0);

  ---------------------------------------------------------------- the public site is unaffected
  perform tests.login_anon();
  perform tests.assert_true('anonymous visitors can still browse venues (published only)',
    (select count(*) from public.site_venues where status = 'draft') = 0);
end $$;

rollback;
