-- Social profiles. What matters most: usernames are ONE list for people and businesses (nobody can take a name twice, not even at the same moment);
-- who may act as a business profile is worked out from their CURRENT role (revoke a manager and they are out at once); a private profile shows its header
-- and counts but keeps its people and content for approved followers; a follow of a private profile waits as a request; blocking hides two profiles
-- from each other both ways, removes the follows, and never says it was a block; following is slowed; the internal checks cannot be called; deleting
-- an account removes its profiles, follows and names.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
-- Does profile_my_ids() list exactly the profiles profile_is_mine() accepts, for this person?
create function tests.same_mine(p_user uuid, p_email text, p_all uuid[]) returns boolean language plpgsql as $$
declare ok boolean;
begin
  -- The claims only (no role change), because the check being compared is internal and the app cannot call it.
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'email', p_email)::text, true);
  select not exists (select 1 from unnest(p_all) a(id) where (a.id in (select public.profile_my_ids())) is distinct from public.profile_is_mine(a.id)) into ok;
  perform tests.logout();
  return ok;
end $$;
-- Runs one expression as a person and returns it as text, or 'ERROR: <sentence>'.
create function tests.q(p_user uuid, p_email text, p_expr text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute 'select (' || p_expr || ')::text' into r;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
-- One value out of a json answer: tests.f(user, email, 'public.profile_get(...)', '{relation,follow}').
create function tests.f(p_user uuid, p_email text, p_expr text, p_path text[]) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute 'select (' || p_expr || ') #>> $1' into r using p_path;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
-- The handles of a json list, in order.
create function tests.hs(p_user uuid, p_email text, p_expr text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute 'select coalesce(string_agg(e ->> ''handle'', '','' order by ord), ''(none)'') from jsonb_array_elements(' || p_expr || ') with ordinality as t(e, ord)' into r;
  perform tests.logout();
  return r;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  ann constant uuid := '00000000-0000-0000-0000-0000000004a1';
  bob constant uuid := '00000000-0000-0000-0000-0000000004a2';
  cy constant uuid := '00000000-0000-0000-0000-0000000004a3';
  owner_u constant uuid := '00000000-0000-0000-0000-0000000004a4';
  mgr constant uuid := '00000000-0000-0000-0000-0000000004a5';
  mgr2 constant uuid := '00000000-0000-0000-0000-0000000004a6';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  rando constant uuid := '00000000-0000-0000-0000-0000000004a7';   -- signed in, never finished a profile
  org_u constant uuid := '00000000-0000-0000-0000-0000000004a8';
  a_e constant text := 'ann@soc.example';
  b_e constant text := 'bob@soc.example';
  c_e constant text := 'cy@soc.example';
  o_e constant text := 'owner@soc.example';
  m_e constant text := 'mgr@soc.example';
  m2_e constant text := 'mgr2@soc.example';
  r_e constant text := 'rando@soc.example';
  g_e constant text := 'org@soc.example';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid;
  p_ann uuid; p_bob uuid; p_cy uuid; p_owner uuid; p_mgr uuid; p_mgr2 uuid; p_org uuid;
  p_dj uuid; p_cybiz uuid; p_va uuid; p_vb uuid; p_group uuid; p_bar uuid;
  t1 timestamptz; t2 timestamptz;
  txt text; n int; i int;
begin
  insert into auth.users (id, email) values
    (ann, a_e), (bob, b_e), (cy, c_e), (owner_u, o_e), (mgr, m_e), (mgr2, m2_e), (rando, r_e), (org_u, g_e);
  insert into public.profiles (id, name, email) values
    (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (cy, 'Cy Rus', c_e), (owner_u, 'Olly Owner', o_e), (mgr, 'Mia Manager', m_e),
    (mgr2, 'Max Manager', m2_e), (rando, 'Rae Random', r_e), (org_u, 'Olive Organizer', g_e);

  ---------------------------------------------------------------- usernames
  perform tests.assert_eq('a visitor cannot ask if a name is free', tests.q(ann, a_e, $q$public.handle_available('zed')$q$), 'true');
  perform tests.login_anon();
  perform tests.assert_raises('...when signed out', $q$select public.handle_available('zed')$q$, 'permission denied');
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'ann', 'Toronto');
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bob', 'Toronto');
  perform tests.login(cy, c_e); perform public.save_my_profile('Cy Rus', 'cyrus', 'Toronto');
  perform tests.login(owner_u, o_e); perform public.save_my_profile('Olly Owner', 'olly.owner', 'Toronto');
  perform tests.login(mgr, m_e); perform public.save_my_profile('Mia Manager', 'mia.mgr', 'Toronto');
  perform tests.login(mgr2, m2_e); perform public.save_my_profile('Max Manager', 'mgr.two', 'Toronto');
  perform tests.login(org_u, g_e); perform public.save_my_profile('Olive Organizer', 'olive.org', 'Toronto');
  perform tests.logout();
  perform tests.assert_eq('a saved username goes on the one list', (select handle from public.site_handles where profile_id = ann), 'ann');
  perform tests.assert_eq('...every one of them, and the two people who had a username before this feature', (select count(*) from public.site_handles)::int, 9);
  perform tests.assert_eq('a username that existed before is on the list', (select handle from public.site_handles where profile_id = '00000000-0000-0000-0000-0000000004f1'), 'preexisting.one');

  perform tests.assert_eq('a free name is free', tests.q(bob, b_e, $q$public.handle_available('new.name')$q$), 'true');
  perform tests.assert_eq('a taken name is not', tests.q(bob, b_e, $q$public.handle_available('ann')$q$), 'false');
  perform tests.assert_eq('...whatever its case', tests.q(bob, b_e, $q$public.handle_available('  ANN ')$q$), 'false');
  perform tests.assert_eq('one''s own name counts as free to oneself', tests.q(ann, a_e, $q$public.handle_available('ann')$q$), 'true');
  perform tests.assert_eq('a reserved name is not free', tests.q(bob, b_e, $q$public.handle_available('support')$q$), 'false');
  perform tests.assert_eq('...the brand name too', tests.q(bob, b_e, $q$public.handle_available('bottlesup')$q$), 'false');
  perform tests.assert_eq('...and the names of the app''s own screens', tests.q(bob, b_e, $q$public.handle_available('explore')$q$), 'false');
  perform tests.assert_eq('too short is not free', tests.q(bob, b_e, $q$public.handle_available('ab')$q$), 'false');
  perform tests.assert_eq('a space is not allowed', tests.q(bob, b_e, $q$public.handle_available('bad name')$q$), 'false');
  perform tests.assert_eq('nothing is not allowed', tests.q(bob, b_e, $q$public.handle_available(null)$q$), 'false');

  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'annie', 'Toronto'); perform tests.logout();
  perform tests.assert_eq('renaming moves the name on the list', (select handle from public.site_handles where profile_id = ann), 'annie');
  perform tests.assert_eq('...and frees the old one', tests.q(bob, b_e, $q$public.handle_available('ann')$q$), 'true');
  perform tests.assert_eq('...and takes the new one', tests.q(bob, b_e, $q$public.handle_available('annie')$q$), 'false');

  ---------------------------------------------------------------- personal profiles
  perform tests.assert_eq('while social is switched off nothing social can be created',
    tests.q(ann, a_e, $q$public.profile_save_personal('public')$q$), 'ERROR: Profiles are not open yet.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('social', true); perform tests.logout();
  perform tests.assert_eq('someone who has not finished their profile cannot make a social one',
    tests.q(rando, r_e, $q$public.profile_save_personal('public')$q$), 'ERROR: Finish your name and username first.');
  perform tests.assert_eq('a made-up privacy is refused', tests.q(ann, a_e, $q$public.profile_save_personal('maybe')$q$), 'ERROR: Choose public or private.');
  perform tests.assert_eq('a first save creates it', tests.f(ann, a_e, $q$public.profile_save_personal('public', array['Music ', ' music', 'Dance floor'])$q$, '{kind}'), 'personal');
  perform tests.assert_eq('interests are tidied: lower case, no duplicates',
    tests.f(ann, a_e, $q$public.profile_save_personal('public', array['Music ', ' music', 'Dance floor'])$q$, '{interests}'), '["music", "dance floor"]');
  perform tests.assert_eq('a second save changes it, not adds another', tests.f(ann, a_e, $q$public.profile_save_personal('public', array['Music'])$q$, '{interests}'), '["music"]');
  perform tests.logout();
  perform tests.assert_eq('...one row per person', (select count(*) from public.site_profiles where user_id = ann)::int, 1);
  perform tests.assert_eq('11 interests are refused', tests.q(ann, a_e, $q$public.profile_save_personal('public', array['aa','bb','cc','dd','ee','ff','gg','hh','ii','jj','kk'])$q$), 'ERROR: Choose up to 10 interests.');
  perform tests.assert_eq('a one-letter interest is refused', tests.q(ann, a_e, $q$public.profile_save_personal('public', array['x'])$q$), 'ERROR: An interest must be 2 to 30 characters.');
  perform tests.assert_eq('the card shows the name, username and city from the person''s own profile',
    tests.q(ann, a_e, $q$(select (c ->> 'display_name') || '/' || (c ->> 'handle') || '/' || (c ->> 'city') from (select public.profile_my_profiles() -> 0 as c) x)$q$), 'Ann Lee/annie/Toronto');

  perform tests.login(bob, b_e); perform public.profile_save_personal('public'); 
  perform tests.login(cy, c_e); perform public.profile_save_personal('private');
  perform tests.login(owner_u, o_e); perform public.profile_save_personal('public');
  perform tests.login(mgr, m_e); perform public.profile_save_personal('public');
  perform tests.login(mgr2, m2_e); perform public.profile_save_personal('public');
  perform tests.login(org_u, g_e); perform public.profile_save_personal('public');
  perform tests.logout();
  select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal';
  select id into p_bob from public.site_profiles where user_id = bob and kind = 'personal';
  select id into p_cy from public.site_profiles where user_id = cy and kind = 'personal';
  select id into p_owner from public.site_profiles where user_id = owner_u and kind = 'personal';
  select id into p_mgr from public.site_profiles where user_id = mgr and kind = 'personal';
  select id into p_mgr2 from public.site_profiles where user_id = mgr2 and kind = 'personal';
  select id into p_org from public.site_profiles where user_id = org_u and kind = 'personal';

  ---------------------------------------------------------------- the business world
  perform tests.login(owner_u, o_e);
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, o_e, org, m_e, 'manager', venue_a, mgr);
  perform tests.join_as(owner_u, o_e, org, m2_e, 'manager', venue_b, mgr2);
  perform tests.login(org_u, g_e); org2 := public.create_organization('Events Co', 'organizer'); perform tests.logout();

  ---------------------------------------------------------------- business profiles
  perform tests.assert_eq('a professional makes a profile', tests.f(ann, a_e, $q$public.profile_create_business('dj', 'DJ Ann', 'djann', 'House and disco', 'Toronto')$q$, '{category}'), 'dj');
  select id into p_dj from public.site_profiles where handle = 'djann';
  perform tests.assert_eq('...it is public and unverified', tests.q(ann, a_e, format($q$(public.profile_get(%L, null, %L)) ->> 'privacy' || '/' || ((public.profile_get(%L, null, %L)) ->> 'verified')$q$, p_ann, p_dj, p_ann, p_dj)), 'public/false');
  perform tests.assert_eq('its username goes on the one list', (select count(*) from public.site_handles where business_id = p_dj)::int, 1);
  perform tests.assert_eq('a taken business name is refused', tests.q(bob, b_e, $q$public.profile_create_business('dj', 'Other', 'djann')$q$), 'ERROR: That username is not available.');
  perform tests.assert_eq('a person''s name is refused for a business', tests.q(bob, b_e, $q$public.profile_create_business('dj', 'Other', 'annie')$q$), 'ERROR: That username is not available.');
  perform tests.assert_eq('a person cannot take a business''s name', tests.q(cy, c_e, $q$public.save_my_profile('Cy Rus', 'djann', 'Toronto')$q$), 'ERROR: username is not available');
  perform tests.assert_eq('...so the name is still the business''s alone', (select count(*) from public.site_handles where handle = 'djann' and business_id is not null)::int, 1);
  begin
    update public.profiles set username = 'djann' where id = cy;
    raise exception 'FAIL - the list let a person take a business name';
  exception when unique_violation then
    perform tests.assert_true('a direct rename onto a business name is refused by the list', true);
  end;
  perform tests.assert_eq('a username that existed before the feature cannot be taken by a business', tests.q(ann, a_e, $q$public.profile_create_business('dj', 'Early', 'preexisting.one')$q$), 'ERROR: That username is not available.');
  perform tests.assert_eq('a bad category is refused', tests.q(bob, b_e, $q$public.profile_create_business('wizard', 'Other', 'wizzy')$q$), 'ERROR: Choose what kind of profile this is.');
  perform tests.assert_eq('a missing name is refused', tests.q(bob, b_e, $q$public.profile_create_business('dj', '  ', 'wizzy')$q$), 'ERROR: The name is required (100 characters at most).');
  perform tests.assert_eq('a photo must be https', tests.q(bob, b_e, $q$public.profile_create_business('dj', 'X', 'wizzy', null, null, null, null, 'http://x.example/a.png')$q$), 'ERROR: The photo must be an https link.');
  perform tests.assert_eq('someone with no profile of their own cannot', tests.q(rando, r_e, $q$public.profile_create_business('dj', 'X', 'wizzy')$q$), 'ERROR: Finish your own profile first.');
  perform tests.assert_eq('a professional profile does not go with a venue business', tests.q(ann, a_e, format($q$public.profile_create_business('dj', 'X', 'wizzy', null, null, %L)$q$, org)), 'ERROR: This kind of profile does not belong to a venue business.');
  for i in 2..5 loop
    perform tests.q(ann, a_e, format($q$public.profile_create_business('dj', 'DJ %s', 'djann%s')$q$, i, i));
  end loop;
  perform tests.assert_eq('...up to five', tests.q(ann, a_e, $q$public.profile_create_business('dj', 'DJ 6', 'djann6')$q$), 'ERROR: You can have up to 5 business profiles.');

  perform tests.assert_eq('a venue''s owner makes its profile', tests.f(owner_u, o_e, format($q$public.profile_create_business('venue', 'Club A', 'clubaclub', 'The best club', 'Toronto', null, %L)$q$, venue_a), '{category}'), 'venue');
  select id into p_va from public.site_profiles where venue_id = venue_a;
  perform tests.assert_eq('a venue profile belongs to the business, not to one login', (select (user_id is null and org_id = org)::text from public.site_profiles where id = p_va), 'true');
  perform tests.assert_eq('a second profile for the same venue is refused', tests.q(owner_u, o_e, format($q$public.profile_create_business('venue', 'Club A 2', 'clubaclub2', null, null, null, %L)$q$, venue_a)), 'ERROR: This venue already has a profile.');
  perform tests.assert_eq('...and the refused name was not kept', tests.q(bob, b_e, $q$public.handle_available('clubaclub2')$q$), 'true');
  perform tests.assert_eq('a manager of another club cannot make this club''s profile', tests.q(mgr, m_e, format($q$public.profile_create_business('venue', 'Club B', 'clubbclub', null, null, null, %L)$q$, venue_b)), 'ERROR: You can only create a profile for a venue you own or manage.');
  perform tests.assert_eq('a stranger cannot', tests.q(rando, r_e, format($q$public.profile_create_business('venue', 'Club B', 'clubbclub', null, null, null, %L)$q$, venue_b)), 'ERROR: Finish your own profile first.');
  perform tests.assert_eq('a signed-in person with no role at the club cannot', tests.q(bob, b_e, format($q$public.profile_create_business('venue', 'Club B', 'clubbclub', null, null, null, %L)$q$, venue_b)), 'ERROR: You can only create a profile for a venue you own or manage.');
  perform tests.assert_eq('a venue profile needs a venue', tests.q(owner_u, o_e, $q$public.profile_create_business('venue', 'Club', 'clubzclub')$q$), 'ERROR: Choose the venue.');
  perform tests.assert_eq('the manager of that club may make its profile', tests.f(mgr2, m2_e, format($q$public.profile_create_business('venue', 'Club B', 'clubbclub', null, null, null, %L)$q$, venue_b), '{handle}'), 'clubbclub');
  select id into p_vb from public.site_profiles where venue_id = venue_b;

  perform tests.assert_eq('an organizer makes the event group of their business', tests.f(org_u, g_e, format($q$public.profile_create_business('event_group', 'Night Crew', 'nightcrew', null, null, %L)$q$, org2), '{category}'), 'event_group');
  select id into p_group from public.site_profiles where org_id = org2;
  perform tests.assert_eq('only one per business', tests.q(org_u, g_e, format($q$public.profile_create_business('event_group', 'Night Crew 2', 'nightcrew2', null, null, %L)$q$, org2)), 'ERROR: This business already has an event group profile.');
  perform tests.assert_eq('someone outside the business cannot', tests.q(ann, a_e, format($q$public.profile_create_business('event_group', 'Night Crew 3', 'nightcrew3', null, null, %L)$q$, org2)), 'ERROR: You can only create a profile for a business you own or organize for.');

  ---------------------------------------------------------------- who may act as a business profile
  perform tests.assert_eq('a person has their own profile and nothing else when they have no business',
    tests.hs(bob, b_e, 'public.profile_my_profiles()'), 'bob');
  perform tests.assert_eq('the owner of the business acts as each of its venues and themselves', tests.hs(owner_u, o_e, 'public.profile_my_profiles()'), 'olly.owner,clubaclub,clubbclub');
  perform tests.assert_eq('the venue''s manager acts as that venue', tests.hs(mgr, m_e, 'public.profile_my_profiles()'), 'mia.mgr,clubaclub');
  perform tests.assert_eq('...the other club''s manager as the other club', tests.hs(mgr2, m2_e, 'public.profile_my_profiles()'), 'mgr.two,clubbclub');
  perform tests.logout();
  perform tests.assert_true('the fast list of who someone may act as says what the single check says, for everyone',
    (select bool_and(tests.same_mine(u.id, u.email, (select array_agg(s.id) from public.site_profiles s))) from auth.users u where u.id in (ann, bob, cy, owner_u, mgr, mgr2, rando, org_u)));
  perform tests.assert_eq('a professional has all their profiles, own first', tests.hs(ann, a_e, 'public.profile_my_profiles()'), 'annie,djann,djann2,djann3,djann4,djann5');
  perform tests.assert_eq('an organizer acts as their group', tests.hs(org_u, g_e, 'public.profile_my_profiles()'), 'olive.org,nightcrew');

  perform tests.assert_eq('the manager edits the venue profile', tests.f(mgr, m_e, format($q$public.profile_update_business(%L, 'Club A Toronto', 'Open Fri and Sat', 'Toronto', 'https://x.example/a.png', 'https://x.example/c.png', '{"instagram":"clubaclub"}')$q$, p_va), '{display_name}'), 'Club A Toronto');
  perform tests.assert_eq('a photo left out is kept', tests.f(mgr, m_e, format($q$public.profile_update_business(%L, 'Club A Toronto', 'Open Fri and Sat', 'Toronto')$q$, p_va), '{avatar_url}'), 'https://x.example/a.png');
  perform tests.assert_eq('an empty photo is removed', tests.f(mgr, m_e, format($q$public.profile_update_business(%L, 'Club A Toronto', 'Open Fri and Sat', 'Toronto', '')$q$, p_va), '{avatar_url}'), '(null)');
  perform tests.assert_eq('someone with no role cannot edit it', tests.q(bob, b_e, format($q$public.profile_update_business(%L, 'Hacked')$q$, p_va)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('the other club''s manager cannot either', tests.q(mgr2, m2_e, format($q$public.profile_update_business(%L, 'Hacked')$q$, p_va)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a personal profile is edited elsewhere', tests.q(ann, a_e, format($q$public.profile_update_business(%L, 'Hacked')$q$, p_ann)), 'ERROR: Edit your own details in your profile settings.');
  perform tests.assert_eq('a missing name is refused', tests.q(mgr, m_e, format($q$public.profile_update_business(%L, '')$q$, p_va)), 'ERROR: The name is required (100 characters at most).');

  perform tests.logout();
  update public.site_memberships set status = 'revoked' where user_id = mgr and org_id = org;
  perform tests.assert_eq('a revoked manager cannot edit the venue profile any more', tests.q(mgr, m_e, format($q$public.profile_update_business(%L, 'Still me')$q$, p_va)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...and no longer sees it among theirs', tests.hs(mgr, m_e, 'public.profile_my_profiles()'), 'mia.mgr');
  perform tests.assert_eq('...nor can they act as it to follow', tests.q(mgr, m_e, format($q$public.follow_set(%L, %L, true)$q$, p_va, p_bob)), 'ERROR: You cannot act as this profile.');

  ---------------------------------------------------------------- seeing profiles
  perform tests.assert_eq('a profile by username', tests.f(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob), '{id}'), p_ann::text);
  perform tests.assert_eq('...in any case', tests.f(bob, b_e, format($q$public.profile_get(%L, ' ANNIE ')$q$, p_bob), '{id}'), p_ann::text);
  perform tests.assert_eq('a business by username', tests.f(bob, b_e, format($q$public.profile_get(%L, 'clubaclub')$q$, p_bob), '{id}'), p_va::text);
  perform tests.assert_eq('by id', tests.f(bob, b_e, format($q$public.profile_get(%L, null, %L)$q$, p_bob, p_cy), '{handle}'), 'cyrus');
  perform tests.assert_eq('a public profile shows its content', tests.f(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob), '{can_see_content}'), 'true');
  perform tests.assert_eq('a private profile shows its header but not its content', tests.f(bob, b_e, format($q$public.profile_get(%L, 'cyrus')$q$, p_bob), '{display_name}') || '/' || tests.f(bob, b_e, format($q$public.profile_get(%L, 'cyrus')$q$, p_bob), '{can_see_content}'), 'Cy Rus/false');
  perform tests.assert_eq('nobody''s email or interests leak to others', tests.f(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob), '{interests}'), '[]');
  perform tests.assert_eq('...but you see your own interests', tests.f(ann, a_e, format($q$public.profile_get(%L, 'annie')$q$, p_ann), '{interests}'), '["music"]');
  perform tests.assert_eq('a profile that does not exist', tests.q(bob, b_e, format($q$public.profile_get(%L, 'nobody.here')$q$, p_bob)), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('...with no name or id at all', tests.q(bob, b_e, format($q$public.profile_get(%L)$q$, p_bob)), 'ERROR: Say which profile.');
  perform tests.assert_eq('someone else''s profile cannot be used as one''s own', tests.q(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_ann)), 'ERROR: You cannot act as this profile.');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot look at profiles', format($q$select public.profile_get(%L, 'annie')$q$, p_bob), 'permission denied');

  ---------------------------------------------------------------- search
  perform tests.assert_eq('search finds a username by its start', tests.hs(bob, b_e, format($q$public.profile_search(%L, 'ann')$q$, p_bob)), 'annie');
  perform tests.assert_eq('...and a name by its start', tests.hs(bob, b_e, format($q$public.profile_search(%L, 'dj')$q$, p_bob)), 'djann2,djann3,djann4,djann5,djann');
  perform tests.assert_eq('it never returns the searcher''s own profile', tests.hs(ann, a_e, format($q$public.profile_search(%L, 'ann')$q$, p_ann)), '(none)');
  perform tests.login(bob, b_e);
  perform public.profile_create_business('other', 'A Bar', 'a_bar'); perform public.profile_create_business('other', 'Ax Bar', 'axbar');
  perform tests.assert_eq('an underscore is a letter, not a wildcard', tests.hs(bob, b_e, format($q$public.profile_search(%L, 'a_')$q$, p_bob)), 'a_bar');
  perform tests.assert_eq('a percent sign matches nothing', tests.hs(bob, b_e, format($q$public.profile_search(%L, 'a%%')$q$, p_bob)), '(none)');
  perform tests.assert_eq('one letter is too little', tests.q(bob, b_e, format($q$public.profile_search(%L, 'a')$q$, p_bob)), 'ERROR: Type at least 2 letters.');
  perform tests.assert_eq('a private profile can be found (header only)', tests.hs(bob, b_e, format($q$public.profile_search(%L, 'cy')$q$, p_bob)), 'cyrus');
  perform tests.assert_eq('a limit of zero still returns one', tests.q(bob, b_e, format($q$jsonb_array_length(public.profile_search(%L, 'dj', 0))$q$, p_bob)), '1');
  perform tests.assert_eq('the limit is respected', tests.q(bob, b_e, format($q$jsonb_array_length(public.profile_search(%L, 'dj', 2))$q$, p_bob)), '2');
  perform tests.logout();
  update public.site_profiles set status = 'suspended' where id = p_dj;
  perform tests.assert_eq('a suspended profile cannot be found', tests.hs(bob, b_e, format($q$public.profile_search(%L, 'dj')$q$, p_bob)), 'djann2,djann3,djann4,djann5');
  perform tests.assert_eq('...or opened', tests.q(bob, b_e, format($q$public.profile_get(%L, 'djann')$q$, p_bob)), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('...nor can it be followed', tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_dj)), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('...nor acted as by its owner', tests.q(ann, a_e, format($q$public.follow_set(%L, %L, true)$q$, p_dj, p_bob)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...but its owner still sees it, marked', tests.q(ann, a_e, $q$(select string_agg(e ->> 'handle' || ':' || (e ->> 'status'), ',' order by ord) from jsonb_array_elements(public.profile_my_profiles()) with ordinality t(e, ord) where e ->> 'handle' = 'djann')$q$), 'djann:suspended');
  update public.site_profiles set status = 'active' where id = p_dj;
  perform tests.assert_eq('and it is back once restored', tests.hs(bob, b_e, format($q$public.profile_search(%L, 'djann')$q$, p_bob)), 'djann,djann2,djann3,djann4,djann5');
  select id into p_bar from public.site_profiles where handle = 'a_bar';

  ---------------------------------------------------------------- following
  perform tests.assert_eq('following a public profile is immediate', tests.f(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann), '{relation,follow}'), 'active');
  perform tests.assert_eq('...it counts', tests.f(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob), '{followers}'), '1');
  perform tests.assert_eq('...and counts for the follower', tests.f(bob, b_e, format($q$public.profile_get(%L, 'bob')$q$, p_bob), '{following}'), '1');
  perform tests.assert_eq('the other side sees that they follow back', tests.f(ann, a_e, format($q$public.profile_get(%L, 'bob')$q$, p_ann), '{relation,follows_me}'), 'true');
  perform tests.assert_eq('following twice is the same as once', tests.f(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann), '{followers}'), '1');
  perform tests.assert_eq('unfollowing', tests.f(bob, b_e, format($q$public.follow_set(%L, %L, false)$q$, p_bob, p_ann), '{relation,follow}'), 'none');
  perform tests.assert_eq('...takes the count back', tests.f(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob), '{followers}'), '0');
  perform tests.assert_eq('you cannot follow yourself', tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_bob)), 'ERROR: You cannot follow your own profile.');
  perform tests.assert_eq('...nor your own other profile', tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_bar)), 'ERROR: You cannot follow your own profile.');
  perform tests.assert_eq('a business can follow', tests.f(ann, a_e, format($q$public.follow_set(%L, %L, true)$q$, p_dj, p_va), '{relation,follow}'), 'active');

  perform tests.assert_eq('following a private profile is a request', tests.f(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_cy), '{relation,follow}'), 'pending');
  perform tests.assert_eq('...it does not count as a follower yet', tests.f(bob, b_e, format($q$public.profile_get(%L, 'cyrus')$q$, p_bob), '{followers}'), '0');
  perform tests.assert_eq('...and gives no access to content', tests.f(bob, b_e, format($q$public.profile_get(%L, 'cyrus')$q$, p_bob), '{can_see_content}'), 'false');
  perform tests.assert_eq('...nor to the list of people', tests.q(bob, b_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_bob, p_cy)), 'ERROR: Follow this profile to see its people.');
  perform tests.assert_eq('a business profile of the same person can see their private profile', tests.f(cy, c_e, $q$public.profile_create_business('other', 'Cy Biz', 'cybiz')$q$, '{kind}'), 'business');
  select id into p_cybiz from public.site_profiles where handle = 'cybiz';
  perform tests.assert_eq('...and its people, because it is theirs', tests.q(cy, c_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_cybiz, p_cy)), '[]');
  perform tests.assert_eq('...but another person''s business is not allowed to', tests.q(bob, b_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_bob, p_cy)), 'ERROR: Follow this profile to see its people.');
  perform tests.assert_eq('the owner sees who is waiting', tests.hs(cy, c_e, format($q$public.follow_requests(%L)$q$, p_cy)), 'bob');
  perform tests.assert_eq('nobody else does', tests.q(bob, b_e, format($q$public.follow_requests(%L)$q$, p_cy)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('only the owner can answer', tests.q(bob, b_e, format($q$public.follow_respond(%L, %L, 'accept')$q$, p_bob, p_bob)), 'ERROR: There is no request from this profile.');
  perform tests.assert_eq('...someone else answering as the owner is refused', tests.q(ann, a_e, format($q$public.follow_respond(%L, %L, 'accept')$q$, p_cy, p_bob)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('accepting', tests.f(cy, c_e, format($q$public.follow_respond(%L, %L, 'accept')$q$, p_cy, p_bob), '{followers}'), '1');
  perform tests.assert_eq('...opens the content', tests.f(bob, b_e, format($q$public.profile_get(%L, 'cyrus')$q$, p_bob), '{can_see_content}'), 'true');
  perform tests.assert_eq('...and the list of people', tests.hs(bob, b_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_bob, p_cy)), 'bob');
  perform tests.assert_eq('accepting twice is refused', tests.q(cy, c_e, format($q$public.follow_respond(%L, %L, 'accept')$q$, p_cy, p_bob)), 'ERROR: There is no request from this profile.');
  perform tests.assert_eq('removing a follower', tests.f(cy, c_e, format($q$public.follow_respond(%L, %L, 'remove')$q$, p_cy, p_bob), '{followers}'), '0');
  perform tests.assert_eq('...closes the content again', tests.f(bob, b_e, format($q$public.profile_get(%L, 'cyrus')$q$, p_bob), '{can_see_content}'), 'false');
  perform tests.assert_eq('a made-up answer is refused', tests.q(cy, c_e, format($q$public.follow_respond(%L, %L, 'maybe')$q$, p_cy, p_bob)), 'ERROR: Choose accept, decline or remove.');
  perform tests.f(ann, a_e, format($q$public.follow_set(%L, %L, true)$q$, p_ann, p_cy), '{id}');
  perform tests.assert_eq('a request that is waiting is not in the list of followers', tests.hs(cy, c_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_cy, p_cy)), '(none)');
  perform tests.assert_eq('declining', tests.f(cy, c_e, format($q$public.follow_respond(%L, %L, 'decline')$q$, p_cy, p_ann), '{requests}'), '0');
  perform tests.assert_eq('...leaves no trace', tests.f(ann, a_e, format($q$public.profile_get(%L, 'cyrus')$q$, p_ann), '{relation,follow}'), 'none');
  perform tests.f(ann, a_e, format($q$public.follow_set(%L, %L, true)$q$, p_ann, p_cy), '{id}');
  perform tests.f(cy, c_e, $q$public.profile_save_personal('public')$q$, '{id}');
  perform tests.assert_eq('turning a profile public accepts the waiting requests', tests.f(ann, a_e, format($q$public.profile_get(%L, 'cyrus')$q$, p_ann), '{relation,follow}'), 'active');
  perform tests.f(cy, c_e, $q$public.profile_save_personal('private')$q$, '{id}');
  perform tests.assert_eq('turning it private again keeps the people who already follow', tests.f(ann, a_e, format($q$public.profile_get(%L, 'cyrus')$q$, p_ann), '{relation,follow}'), 'active');

  -- lists, newest first, in pages
  perform pg_sleep(0.01); perform tests.f(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann), '{id}');
  perform pg_sleep(0.01); perform tests.f(cy, c_e, format($q$public.follow_set(%L, %L, true)$q$, p_cy, p_ann), '{id}');
  perform pg_sleep(0.01); perform tests.f(owner_u, o_e, format($q$public.follow_set(%L, %L, true)$q$, p_owner, p_ann), '{id}');
  perform tests.assert_eq('followers, newest first', tests.hs(mgr, m_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_mgr, p_ann)), 'olly.owner,cyrus,bob');
  perform tests.assert_eq('a page of two', tests.hs(mgr, m_e, format($q$public.follow_list(%L, %L, 'followers', 2)$q$, p_mgr, p_ann)), 'olly.owner,cyrus');
  t1 := tests.f(mgr, m_e, format($q$public.follow_list(%L, %L, 'followers', 2) -> 1$q$, p_mgr, p_ann), '{followed_at}')::timestamptz;
  perform tests.assert_eq('the next page starts after the last one seen', tests.hs(mgr, m_e, format($q$public.follow_list(%L, %L, 'followers', 2, %L)$q$, p_mgr, p_ann, t1)), 'bob');
  perform tests.assert_eq('following list', tests.hs(bob, b_e, format($q$public.follow_list(%L, %L, 'following')$q$, p_bob, p_bob)), 'annie');
  perform tests.assert_eq('a bad kind is refused', tests.q(bob, b_e, format($q$public.follow_list(%L, %L, 'friends')$q$, p_bob, p_ann)), 'ERROR: Choose followers or following.');
  perform tests.assert_eq('the owner of a private profile sees its list without following themselves', tests.hs(ann, a_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_ann, p_ann)), 'olly.owner,cyrus,bob');

  -- following is slowed
  perform tests.logout();
  insert into auth.users (id, email) select ('00000000-0000-0000-0001-' || lpad(g::text, 12, '0'))::uuid, 'dummy' || g || '@soc.example' from generate_series(1, 200) g;
  insert into public.site_profiles (kind, user_id, privacy) select 'personal', ('00000000-0000-0000-0001-' || lpad(g::text, 12, '0'))::uuid, 'public' from generate_series(1, 200) g;
  insert into public.site_follows (follower, followed) select p_mgr2, s.id from public.site_profiles s where s.user_id::text like '00000000-0000-0000-0001-%';
  perform tests.assert_eq('after 200 follows in an hour the next is slowed', tests.q(mgr2, m2_e, format($q$public.follow_set(%L, %L, true)$q$, p_mgr2, p_ann)), 'ERROR: You are following people too quickly. Try again later.');
  perform tests.assert_eq('...but unfollowing is not', tests.f(mgr2, m2_e, format($q$public.follow_set(%L, %L, false)$q$, p_mgr2, p_ann), '{relation,follow}'), 'none');
  perform tests.assert_eq('...and other people are not slowed', tests.f(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_va), '{relation,follow}'), 'active');
  delete from auth.users where email like 'dummy%@soc.example';

  ---------------------------------------------------------------- blocking
  perform tests.f(ann, a_e, format($q$public.follow_set(%L, %L, true)$q$, p_ann, p_bob), '{id}');
  perform tests.f(ann, a_e, format($q$public.follow_set(%L, %L, true)$q$, p_ann, p_cy), '{id}');
  perform tests.f(ann, a_e, format($q$public.follow_set(%L, %L, true)$q$, p_ann, p_va), '{id}');
  perform tests.assert_eq('before the block bob sees annie among the club''s followers', tests.hs(bob, b_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_bob, p_va)) like '%annie%', true);
  perform tests.assert_eq('bob and annie follow each other', tests.f(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob), '{relation,follow}') || '/' || tests.f(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob), '{relation,follows_me}'), 'active/true');
  perform tests.assert_eq('blocking', tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_ann)), '{"blocked": true}');
  perform tests.assert_eq('...the follows between them are gone', (select count(*) from public.site_follows where (follower = p_bob and followed = p_ann) or (follower = p_ann and followed = p_bob))::int, 0);
  perform tests.assert_eq('...but other follows are not touched', (select count(*) from public.site_follows where follower = p_ann and followed = p_cy)::int, 1);
  perform tests.assert_eq('the blocker no longer finds the blocked', tests.hs(bob, b_e, format($q$public.profile_search(%L, 'ann')$q$, p_bob)), '(none)');
  perform tests.assert_eq('the blocked no longer finds the blocker', tests.hs(ann, a_e, format($q$public.profile_search(%L, 'bob')$q$, p_ann)), '(none)');
  perform tests.assert_eq('the blocker cannot open them', tests.q(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob)), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('the blocked cannot open the blocker, with the same sentence as for a profile that does not exist', tests.q(ann, a_e, format($q$public.profile_get(%L, 'bob')$q$, p_ann)), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('the blocked cannot follow', tests.q(ann, a_e, format($q$public.follow_set(%L, %L, true)$q$, p_ann, p_bob)), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('...nor can the blocker', tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann)), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('a profile bob blocked disappears from a list of somebody else''s followers too', tests.hs(bob, b_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_bob, p_va)) like '%annie%', false);
  perform tests.assert_eq('...while the club''s other followers are still there', tests.hs(bob, b_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_bob, p_va)), 'bob,djann');
  perform tests.assert_eq('the blocked is not shown in the blocker''s view of a list', tests.hs(owner_u, o_e, format($q$public.follow_list(%L, %L, 'followers')$q$, p_owner, p_ann)), 'olly.owner,cyrus');
  perform tests.assert_eq('...and the blocker''s own following list does not show the blocked (only the club bob still follows)', tests.hs(bob, b_e, format($q$public.follow_list(%L, %L, 'following')$q$, p_bob, p_bob)), 'clubaclub');
  perform tests.assert_eq('the blocker can list who they blocked', tests.hs(bob, b_e, format($q$public.block_list(%L)$q$, p_bob)), 'annie');
  perform tests.assert_eq('...and the blocked person cannot see that they were', tests.hs(ann, a_e, format($q$public.block_list(%L)$q$, p_ann)), '(none)');
  perform tests.assert_eq('blocking twice is the same as once', tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_ann)), '{"blocked": true}');
  perform tests.assert_eq('you cannot block yourself', tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_bob)), 'ERROR: You cannot block your own profile.');
  perform tests.assert_eq('...nor your own other profile', tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_bar)), 'ERROR: You cannot block your own profile.');
  perform tests.assert_eq('someone else''s profile cannot block as you', tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_cy, p_ann)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a profile that does not exist cannot be blocked', tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, gen_random_uuid())), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('unblocking', tests.q(bob, b_e, format($q$public.block_set(%L, %L, false)$q$, p_bob, p_ann)), '{"blocked": false}');
  perform tests.assert_eq('...makes them visible again', tests.hs(bob, b_e, format($q$public.profile_search(%L, 'ann')$q$, p_bob)), 'annie');
  perform tests.assert_eq('...but does not bring the follows back', tests.f(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob), '{relation,follow}'), 'none');
  perform tests.f(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_cy), '{id}');
  perform tests.f(cy, c_e, $q$public.profile_save_personal('private')$q$, '{id}');
  perform tests.logout();
  update public.site_follows set status = 'pending' where follower = p_bob and followed = p_cy;
  perform tests.q(cy, c_e, format($q$public.block_set(%L, %L, true)$q$, p_cy, p_bob));
  perform tests.logout();
  perform tests.assert_eq('blocking someone who has asked to follow clears the request', (select count(*) from public.site_follows where follower = p_bob and followed = p_cy)::int, 0);

  ---------------------------------------------------------------- the rest of the surface
  perform tests.login(bob, b_e);
  perform tests.assert_raises('the access check cannot be called by the app', format($q$select public.profile_can_act_as(%L)$q$, p_ann), 'permission denied');
  perform tests.assert_raises('...nor the list of who one may act as', $q$select public.profile_my_ids()$q$, 'permission denied');
  perform tests.assert_raises('...nor the card builder', format($q$select public.profile_card(%L, %L)$q$, p_bob, p_ann), 'permission denied');
  perform tests.assert_raises('...nor the block check', format($q$select public.profile_blocked_between(%L, %L)$q$, p_bob, p_ann), 'permission denied');
  perform tests.assert_raises('...nor the content check', format($q$select public.profile_content_visible(%L, %L)$q$, p_bob, p_ann), 'permission denied');
  perform tests.assert_raises('...nor the trigger function', $q$select public.site_handles_follow_profile()$q$, 'permission denied');
  perform tests.assert_raises('the profiles table cannot be read', $q$select * from public.site_profiles$q$, 'permission denied');
  perform tests.assert_raises('...nor the follows', $q$select * from public.site_follows$q$, 'permission denied');
  perform tests.assert_raises('...nor the blocks', $q$select * from public.site_blocks$q$, 'permission denied');
  perform tests.assert_raises('...nor the list of names', $q$select * from public.site_handles$q$, 'permission denied');
  perform tests.assert_raises('...nor written', $q$insert into public.site_follows (follower, followed) values (gen_random_uuid(), gen_random_uuid())$q$, 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- switched off again
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('social', false); perform tests.logout();
  perform tests.assert_eq('with social switched off a new follow is refused', tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_owner)), 'ERROR: Profiles are not open yet.');
  perform tests.assert_eq('...and a new business profile', tests.q(bob, b_e, $q$public.profile_create_business('dj', 'Again', 'bobagain')$q$), 'ERROR: Profiles are not open yet.');
  perform tests.assert_eq('...and a change to the profile', tests.q(bob, b_e, $q$public.profile_save_personal('private')$q$), 'ERROR: Profiles are not open yet.');
  perform tests.assert_eq('but unfollowing still works', tests.f(bob, b_e, format($q$public.follow_set(%L, %L, false)$q$, p_bob, p_va), '{relation,follow}'), 'none');
  perform tests.assert_eq('...and so does blocking', tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_owner)), '{"blocked": true}');
  perform tests.assert_eq('...and looking', tests.f(bob, b_e, format($q$public.profile_get(%L, 'clubaclub')$q$, p_bob), '{handle}'), 'clubaclub');

  ---------------------------------------------------------------- deleting an account
  perform tests.assert_true('annie has profiles, follows and names before', (select count(*) from public.site_profiles where user_id = ann) = 6 and (select count(*) from public.site_follows where follower = p_ann or followed = p_ann) > 0);
  delete from auth.users where id = ann;
  perform tests.assert_eq('deleting the account removes all their profiles', (select count(*) from public.site_profiles where user_id = ann)::int, 0);
  perform tests.assert_eq('...their follows, in both directions', (select count(*) from public.site_follows where follower in (p_ann, p_dj) or followed in (p_ann, p_dj))::int, 0);
  perform tests.assert_eq('...and their names', (select count(*) from public.site_handles where handle in ('annie', 'djann', 'djann2'))::int, 0);
  perform tests.assert_eq('...which are free again', tests.q(bob, b_e, $q$public.handle_available('annie')$q$), 'true');
  perform tests.assert_eq('other people''s profiles are untouched', (select count(*) from public.site_profiles where id in (p_bob, p_cy, p_va))::int, 3);
end $$;

rollback;
