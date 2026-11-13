-- Teams, venue hire and the event workspace. What matters most: only the owner of a professional's profile manages its team and revoking ends access at once; a role carries only its
-- own kind of work (bookings, content, finance); a request to a venue is not a booking until the venue confirms, one hire is confirmed per venue per day, an offer is exactly what the
-- group agrees to; the workspace shows each side only what it should (the venue never sees what a professional is paid); the chats follow the people; every table is closed.
begin;

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

-- Runs an internal helper as a person (the claims only, no role change: the app cannot call these).
create function tests.i(p_user uuid, p_email text, p_expr text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'email', p_email)::text, true);
  execute 'select (' || p_expr || ')::text' into r;
  perform tests.logout();
  return coalesce(r, '(null)');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  adm constant text := 'admin@test.example';
  dee constant uuid := '00000000-0000-0000-0000-0000000008b1';    -- the DJ, who owns a professional profile
  ann constant uuid := '00000000-0000-0000-0000-0000000008b2';    -- a booking agent
  bob constant uuid := '00000000-0000-0000-0000-0000000008b3';    -- a content manager
  cy constant uuid := '00000000-0000-0000-0000-0000000008b4';     -- door staff
  zed constant uuid := '00000000-0000-0000-0000-0000000008b5';    -- an outsider, later a manager
  gus constant uuid := '00000000-0000-0000-0000-0000000008b6';    -- runs the event group
  olly constant uuid := '00000000-0000-0000-0000-0000000008b7';   -- runs the club
  pat constant uuid := '00000000-0000-0000-0000-0000000008b8';    -- runs a second club and another event group
  d_e constant text := 'dee@hire.example'; a_e constant text := 'ann@hire.example'; b_e constant text := 'bob@hire.example'; c_e constant text := 'cy@hire.example';
  z_e constant text := 'zed@hire.example'; g_e constant text := 'gus@hire.example'; o_e constant text := 'olly@hire.example'; p_e constant text := 'pat@hire.example';
  p_dee uuid; p_ann uuid; p_bob uuid; p_cy uuid; p_zed uuid; p_gus uuid; p_olly uuid; p_pat uuid;
  p_dj uuid; p_dj2 uuid; p_grp uuid; p_club uuid; p_club2 uuid; p_grp2 uuid; p_ogrp uuid;
  org_g uuid; org_o uuid; org_p uuid; va uuid; vb uuid; vc uuid;
  t_ann uuid; t_bob uuid; t_cy uuid; t_zed uuid; t_ann2 uuid;
  h1 uuid; h2 uuid; h3 uuid; h4 uuid; h5 uuid; h6 uuid; hx uuid; hq uuid; hy uuid; hz uuid; t_pat uuid; t_fin uuid; t_x uuid; ev5 uuid; ev6 uuid; ev7 uuid; ev8 uuid; ev9 uuid; ev10 uuid; ev11 uuid; ev12 uuid; p_nop uuid;
  nop constant uuid := '00000000-0000-0000-0000-0000000008b9'; n_e constant text := 'nop@hire.example';
  ev1 uuid; ev2 uuid; ev3 uuid; ev4 uuid; conv uuid;
  rq uuid; q1 uuid; bk uuid; bk2 uuid; bk3 uuid; it1 uuid; it2 uuid;
  d1 date := current_date + 30;
  r text; n int; j jsonb;
begin
  insert into auth.users (id, email) values (dee, d_e), (ann, a_e), (bob, b_e), (cy, c_e), (zed, z_e), (gus, g_e), (olly, o_e), (pat, p_e), (nop, n_e);
  insert into public.profiles (id, name, email) values (dee, 'Dee Dee', d_e), (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (cy, 'Cy Rus', c_e), (zed, 'Zed Zed', z_e),
    (gus, 'Gus Group', g_e), (olly, 'Olly Owner', o_e), (pat, 'Pat Pro', p_e), (nop, 'No Profile', n_e);
  perform tests.login(admin_u, adm); perform public.cms_set_feature('social', true); perform public.cms_publish_rules('Be kind to people. No spam. No hate. Respect each other.'); perform tests.logout();
  perform tests.login(dee, d_e); perform public.save_my_profile('Dee Dee', 'deeteam', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform public.profile_create_business('dj', 'DJ Dee', 'djdeeteam');
  perform public.profile_create_business('photographer', 'Dee Photos', 'deephototeam');
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'annteam', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bobteam', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(cy, c_e); perform public.save_my_profile('Cy Rus', 'cyteam', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(zed, z_e); perform public.save_my_profile('Zed Zed', 'zedteam', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform tests.login(gus, g_e); perform public.save_my_profile('Gus Group', 'gusteam', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  org_g := public.create_organization('Eonics Co', 'organizer');
  perform public.profile_create_business('event_group', 'EONICS', 'eonicsgrp', null, null, org_g);
  perform tests.login(olly, o_e); perform public.save_my_profile('Olly Owner', 'ollyteam', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  org_o := public.create_organization('Hire Club Co', 'venue_owner'); va := public.create_org_venue(org_o, 'Hire Club'); vb := public.create_org_venue(org_o, 'Hire Club Annex');
  perform public.profile_create_business('venue', 'Hire Club', 'hireclub', null, null, null, va);
  perform public.profile_create_business('venue', 'Hire Club Annex', 'hireannex', null, null, null, vb);
  perform public.profile_create_business('event_group', 'Olly Nights', 'ollynights', null, null, org_o);
  perform tests.login(pat, p_e); perform public.save_my_profile('Pat Pro', 'patteam', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  org_p := public.create_organization('Pat Co', 'venue_owner'); vc := public.create_org_venue(org_p, 'Pat Club');
  perform public.profile_create_business('venue', 'Pat Club', 'patclub', null, null, null, vc);
  perform public.profile_create_business('promoter', 'Pat Promos', 'patpromos');
  perform tests.login(nop, n_e); perform public.save_my_profile('No Profile', 'noprofteam', 'Toronto');
  perform tests.logout();
  select id into p_dee from public.site_profiles where user_id = dee and kind = 'personal'; select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal';
  select id into p_bob from public.site_profiles where user_id = bob and kind = 'personal'; select id into p_cy from public.site_profiles where user_id = cy and kind = 'personal';
  select id into p_zed from public.site_profiles where user_id = zed and kind = 'personal'; select id into p_gus from public.site_profiles where user_id = gus and kind = 'personal';
  select id into p_olly from public.site_profiles where user_id = olly and kind = 'personal'; select id into p_pat from public.site_profiles where user_id = pat and kind = 'personal';
  select id into p_dj from public.site_profiles where handle = 'djdeeteam'; select id into p_dj2 from public.site_profiles where handle = 'deephototeam';
  select id into p_grp from public.site_profiles where handle = 'eonicsgrp'; select id into p_club from public.site_profiles where handle = 'hireclub';
  select id into p_club2 from public.site_profiles where handle = 'hireannex'; select id into p_ogrp from public.site_profiles where handle = 'ollynights';
  select id into p_grp2 from public.site_profiles where handle = 'patpromos';

  ---------------------------------------------------------------- the switches
  perform tests.assert_eq('teams are off at first', tests.q(dee, d_e, format($q$public.team_invite(%L, 'annteam', 'booking_agent')$q$, p_dj)), 'ERROR: Teams are not open yet.');
  perform tests.assert_eq('...and so is hosting', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', null, null, null, null, null, null)$q$, p_grp, p_club, d1)), 'ERROR: Hosting events at venues is not open yet.');
  perform tests.login(admin_u, adm); perform public.cms_set_feature('marketplace', true); perform tests.logout();
  perform tests.assert_eq('teams open with either switch', tests.q(dee, d_e, format($q$public.team_list(%L) ->> 'can_manage'$q$, p_dj)), 'true');
  perform tests.login(admin_u, adm); perform public.cms_set_feature('venue_hire', true); perform public.cms_set_feature('inbox', true); perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot invite', format($q$select public.team_invite(%L, 'annteam', 'booking_agent')$q$, p_dj), 'permission denied');
  perform tests.assert_raises('...or ask a venue', format($q$select public.hire_workspace(%L, %L)$q$, p_grp, p_club), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- inviting
  perform tests.assert_eq('only the owner invites: not a stranger', tests.q(ann, a_e, format($q$public.team_invite(%L, 'zedteam', 'booking_agent')$q$, p_dj)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...a personal profile has no team', tests.q(dee, d_e, format($q$public.team_invite(%L, 'annteam', 'booking_agent')$q$, p_dee)), 'ERROR: Only a professional''s own profile has a team here. A venue or event group is run from BottlesUp Business.');
  perform tests.assert_eq('...nor does a venue', tests.q(olly, o_e, format($q$public.team_invite(%L, 'annteam', 'booking_agent')$q$, p_club)), 'ERROR: Only a professional''s own profile has a team here. A venue or event group is run from BottlesUp Business.');
  perform tests.assert_eq('...nor does an event group', tests.q(gus, g_e, format($q$public.team_invite(%L, 'annteam', 'booking_agent')$q$, p_grp)), 'ERROR: Only a professional''s own profile has a team here. A venue or event group is run from BottlesUp Business.');
  perform tests.assert_eq('a role must be one of ours', tests.q(dee, d_e, format($q$public.team_invite(%L, 'annteam', 'boss')$q$, p_dj)), 'ERROR: Choose a role.');
  perform tests.assert_eq('...no role at all', tests.q(dee, d_e, format($q$public.team_invite(%L, 'annteam', null)$q$, p_dj)), 'ERROR: Choose a role.');
  perform tests.assert_eq('a custom role needs something to do', tests.q(dee, d_e, format($q$public.team_invite(%L, 'annteam', 'custom')$q$, p_dj)), 'ERROR: Choose at least one thing a custom role may do.');
  perform tests.assert_eq('...an empty pick is nothing', tests.q(dee, d_e, format($q$public.team_invite(%L, 'annteam', 'custom', '{}')$q$, p_dj)), 'ERROR: Choose at least one thing a custom role may do.');
  perform tests.assert_eq('...and only from the three kinds', tests.q(dee, d_e, format($q$public.team_invite(%L, 'annteam', 'custom', array['bookings', 'owner'])$q$, p_dj)), 'ERROR: Choose from bookings, content and finance.');
  perform tests.assert_eq('nobody has that username', tests.q(dee, d_e, format($q$public.team_invite(%L, 'nobodyhere', 'booking_agent')$q$, p_dj)), 'ERROR: No one has that username.');
  perform tests.assert_eq('...nor someone with no profile of their own yet', tests.q(dee, d_e, format($q$public.team_invite(%L, 'noprofteam', 'booking_agent')$q$, p_dj)), 'ERROR: No one has that username.');
  perform tests.assert_eq('...you cannot invite yourself', tests.q(dee, d_e, format($q$public.team_invite(%L, 'deeteam', 'booking_agent')$q$, p_dj)), 'ERROR: You own this profile already.');
  perform tests.login(bob, b_e); perform public.block_set(p_bob, p_dj, true); perform tests.logout();
  perform tests.assert_eq('...nor someone who blocked the profile (they are not found)', tests.q(dee, d_e, format($q$public.team_invite(%L, 'bobteam', 'content_manager')$q$, p_dj)), 'ERROR: No one has that username.');
  perform tests.login(bob, b_e); perform public.block_set(p_bob, p_dj, false); perform tests.logout();

  t_ann := (tests.f(dee, d_e, format($q$public.team_invite(%L, '@AnnTeam', 'booking_agent')$q$, p_dj), '{id}'))::uuid;
  perform tests.assert_true('Ann was invited (the @ and capitals do not matter)', t_ann is not null);
  perform tests.assert_eq('...as a booking agent: bookings only', (select permissions::text from public.site_profile_team where id = t_ann), '{bookings}');
  perform tests.assert_eq('...and waiting for her answer', (select status from public.site_profile_team where id = t_ann), 'invited');
  perform tests.assert_eq('...asked by the owner', (select invited_by from public.site_profile_team where id = t_ann), dee);
  perform tests.assert_eq('the same person cannot be asked twice', tests.q(dee, d_e, format($q$public.team_invite(%L, 'annteam', 'manager')$q$, p_dj)), 'ERROR: That person is already on the team or has been asked.');
  perform tests.assert_eq('an invitation is not access yet', tests.i(ann, a_e, format($q$public.profile_is_mine(%L)$q$, p_dj)), 'false');
  perform tests.assert_eq('...she cannot act as the profile', tests.q(ann, a_e, format($q$public.pro_service_save(%L, null, 'DJ set', null, null, null)$q$, p_dj)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('she sees the invitation', tests.q(ann, a_e, $q$jsonb_array_length(public.team_invitations_mine())$q$), '1');
  perform tests.assert_eq('...with the profile and the role', tests.f(ann, a_e, $q$public.team_invitations_mine() -> 0$q$, '{role}'), 'booking_agent');
  perform tests.assert_eq('...and nobody else sees it', tests.q(zed, z_e, $q$jsonb_array_length(public.team_invitations_mine())$q$), '0');
  perform tests.assert_eq('someone else cannot answer it', tests.q(zed, z_e, format($q$public.team_answer(%L, true)$q$, t_ann)), 'ERROR: This invitation is not available.');
  perform tests.assert_eq('...not even the owner', tests.q(dee, d_e, format($q$public.team_answer(%L, true)$q$, t_ann)), 'ERROR: This invitation is not available.');
  perform tests.assert_eq('an answer must be yes or no', tests.q(ann, a_e, format($q$public.team_answer(%L, null)$q$, t_ann)), 'ERROR: Say yes or no.');
  perform tests.assert_eq('she accepts', tests.f(ann, a_e, format($q$public.team_answer(%L, true)$q$, t_ann), '{status}'), 'active');
  perform tests.assert_eq('...a second answer is refused', tests.q(ann, a_e, format($q$public.team_answer(%L, false)$q$, t_ann)), 'ERROR: This invitation has already been answered.');
  perform tests.assert_eq('she no longer has an invitation', tests.q(ann, a_e, $q$jsonb_array_length(public.team_invitations_mine())$q$), '0');

  ---------------------------------------------------------------- what a role may do
  perform tests.assert_eq('a member acts as the profile', tests.i(ann, a_e, format($q$public.profile_is_mine(%L)$q$, p_dj)), 'true');
  perform tests.assert_eq('...it is in the list of profiles she may act as', tests.i(ann, a_e, format($q$%L::uuid in (select public.profile_my_ids())$q$, p_dj)), 'true');
  perform tests.assert_eq('...the other profile of the owner is not', tests.i(ann, a_e, format($q$public.profile_is_mine(%L)$q$, p_dj2)), 'false');
  perform tests.assert_eq('a booking agent does bookings: a service', tests.f(ann, a_e, format($q$public.pro_service_save(%L, null, 'Club night', null, null, null)$q$, p_dj), '{title}'), 'Club night');
  perform tests.assert_eq('...but not content: no posts', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'hello', 'public', '[]'::jsonb)$q$, p_dj)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...nor the profile''s own details', tests.q(ann, a_e, format($q$public.profile_update_business(%L, 'Renamed')$q$, p_dj)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('she can follow as the profile (anyone on the team can)', tests.f(ann, a_e, format($q$public.follow_set(%L, %L, true)$q$, p_dj, p_zed), '{status}'), 'active');
  perform tests.assert_eq('her access summary: bookings only', tests.q(ann, a_e, format($q$public.team_my_access(%L)$q$, p_dj)), '{"owner": false, "permissions": ["bookings"]}');
  perform tests.assert_eq('the owner''s: everything', tests.q(dee, d_e, format($q$public.team_my_access(%L)$q$, p_dj)), '{"owner": true, "permissions": ["bookings", "content", "finance"]}');
  perform tests.assert_eq('a stranger has no summary', tests.q(zed, z_e, format($q$public.team_my_access(%L)$q$, p_dj)), 'ERROR: You cannot act as this profile.');

  t_bob := (tests.f(dee, d_e, format($q$public.team_invite(%L, 'bobteam', 'content_manager')$q$, p_dj), '{id}'))::uuid;
  perform tests.assert_eq('a content manager has content only', (select permissions::text from public.site_profile_team where id = t_bob), '{content}');
  perform tests.assert_eq('...who has to accept first: no access yet', tests.i(bob, b_e, format($q$public.profile_has_permission(%L, 'content')$q$, p_dj)), 'false');
  perform tests.assert_eq('...then accepts', tests.f(bob, b_e, format($q$public.team_answer(%L, true)$q$, t_bob), '{status}'), 'active');
  perform tests.assert_true('...and the time of the answer is kept', (select answered_at is not null from public.site_profile_team where id = t_bob));
  perform tests.assert_eq('...an active member cannot be asked again', tests.q(dee, d_e, format($q$public.team_invite(%L, 'bobteam', 'manager')$q$, p_dj)), 'ERROR: That person is already on the team or has been asked.');
  perform tests.assert_eq('...and edits the profile', tests.f(bob, b_e, format($q$public.profile_update_business(%L, 'DJ Dee Team')$q$, p_dj), '{display_name}'), 'DJ Dee Team');
  perform tests.assert_eq('...but cannot sell: no services', tests.q(bob, b_e, format($q$public.pro_service_save(%L, null, 'Not mine to make', null, null, null)$q$, p_dj)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...nor see its requests', tests.q(bob, b_e, format($q$public.pro_requests_for(%L)$q$, p_dj)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...nor set days off', tests.q(bob, b_e, format($q$public.pro_busy_set(%L, current_date + 40, true)$q$, p_dj)), 'ERROR: Your role on this profile does not allow this.');

  t_cy := (tests.f(dee, d_e, format($q$public.team_invite(%L, 'cyteam', 'door_staff')$q$, p_dj), '{id}'))::uuid;
  perform tests.q(cy, c_e, format($q$public.team_answer(%L, true)$q$, t_cy));
  perform tests.assert_eq('door staff carry no kind of work', (select permissions::text from public.site_profile_team where id = t_cy), '{}');
  perform tests.assert_eq('...but act as the profile', tests.i(cy, c_e, format($q$public.profile_is_mine(%L)$q$, p_dj)), 'true');
  perform tests.assert_eq('...and cannot do bookings', tests.q(cy, c_e, format($q$public.pro_busy_set(%L, current_date + 40, true)$q$, p_dj)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or content', tests.q(cy, c_e, format($q$public.profile_update_business(%L, 'Renamed')$q$, p_dj)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...and their summary is empty', tests.q(cy, c_e, format($q$public.team_my_access(%L)$q$, p_dj)), '{"owner": false, "permissions": []}');

  t_zed := (tests.f(dee, d_e, format($q$public.team_invite(%L, 'zedteam', 'custom', array['finance', 'bookings', 'finance'])$q$, p_dj), '{id}'))::uuid;
  perform tests.assert_eq('a custom role is the pick, once each, in order', (select permissions::text from public.site_profile_team where id = t_zed), '{bookings,finance}');
  perform tests.q(zed, z_e, format($q$public.team_answer(%L, true)$q$, t_zed));
  perform tests.assert_eq('...and carries exactly that', tests.q(zed, z_e, format($q$public.team_my_access(%L)$q$, p_dj)), '{"owner": false, "permissions": ["bookings", "finance"]}');

  ---------------------------------------------------------------- the owner alone manages
  perform tests.assert_eq('a member cannot invite', tests.q(ann, a_e, format($q$public.team_invite(%L, 'gusteam', 'booking_agent')$q$, p_dj)), 'ERROR: Only the owner of the profile manages its team.');
  perform tests.assert_eq('...or revoke', tests.q(ann, a_e, format($q$public.team_revoke(%L, %L)$q$, p_dj, t_bob)), 'ERROR: Only the owner of the profile manages its team.');
  perform tests.assert_eq('...or change a role', tests.q(zed, z_e, format($q$public.team_set_role(%L, %L, 'manager')$q$, p_dj, t_ann)), 'ERROR: Only the owner of the profile manages its team.');
  perform tests.assert_eq('the list shows the people on the team', tests.q(ann, a_e, format($q$jsonb_array_length(public.team_list(%L) -> 'members')$q$, p_dj)), '4');
  perform tests.assert_eq('...but only the owner may manage', tests.q(ann, a_e, format($q$public.team_list(%L) ->> 'can_manage'$q$, p_dj)), 'false');
  perform tests.assert_eq('...the owner may', tests.q(dee, d_e, format($q$public.team_list(%L) ->> 'can_manage'$q$, p_dj)), 'true');
  perform tests.assert_eq('...and it names the owner', tests.q(ann, a_e, format($q$public.team_list(%L) #>> '{owner,name}'$q$, p_dj)), 'Dee Dee');
  perform tests.assert_eq('a stranger sees no team', tests.q(gus, g_e, format($q$public.team_list(%L)$q$, p_dj)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a venue has none to list', tests.q(olly, o_e, format($q$public.team_list(%L)$q$, p_club)), 'ERROR: Only a professional''s own profile has a team here. A venue or event group is run from BottlesUp Business.');
  perform tests.assert_eq('a role is changed in place', tests.f(dee, d_e, format($q$public.team_set_role(%L, %L, 'manager')$q$, p_dj, t_ann), '{role}'), 'manager');
  perform tests.assert_eq('...with its permissions', (select permissions::text from public.site_profile_team where id = t_ann), '{bookings,content,finance}');
  perform tests.assert_eq('...and she can now post-level things (content)', tests.i(ann, a_e, format($q$public.profile_has_permission(%L, 'content')$q$, p_dj)), 'true');
  perform tests.assert_eq('a bad role is refused', tests.q(dee, d_e, format($q$public.team_set_role(%L, %L, 'god')$q$, p_dj, t_ann)), 'ERROR: Choose a role.');
  perform tests.assert_eq('...a custom one with nothing too', tests.q(dee, d_e, format($q$public.team_set_role(%L, %L, 'custom', '{}')$q$, p_dj, t_ann)), 'ERROR: Choose at least one thing a custom role may do.');
  perform tests.assert_eq('...a member of another profile is not found', tests.q(dee, d_e, format($q$public.team_set_role(%L, %L, 'manager')$q$, p_dj2, t_bob)), 'ERROR: This team member is not available.');
  perform tests.assert_eq('...nor revoked through it', tests.q(dee, d_e, format($q$public.team_revoke(%L, %L)$q$, p_dj2, t_bob)), 'ERROR: This team member is not available.');
  perform tests.assert_eq('...an unknown one is not found', tests.q(dee, d_e, format($q$public.team_revoke(%L, gen_random_uuid())$q$, p_dj)), 'ERROR: This team member is not available.');

  ---------------------------------------------------------------- limits
  insert into auth.users (id, email) select gen_random_uuid(), 'fixture' || g || '@hire.example' from generate_series(1, 16) g;
  insert into public.site_profile_team (profile, member, role, permissions, status) select p_dj, u.id, 'door_staff', '{}', 'invited' from auth.users u where u.email like 'fixture%@hire.example';
  perform tests.assert_eq('twenty on the team is the limit', tests.q(dee, d_e, format($q$public.team_invite(%L, 'gusteam', 'booking_agent')$q$, p_dj)), 'ERROR: A team can have up to 20 people.');
  delete from public.site_profile_team where member in (select id from auth.users where email like 'fixture%@hire.example');
  delete from auth.users where email like 'fixture%@hire.example';

  ---------------------------------------------------------------- the team chat
  select l.conversation into conv from public.site_chat_links l where l.kind = 'team' and l.ref = p_dj;
  perform tests.assert_true('there is a team chat', conv is not null);
  perform tests.assert_eq('...of the owner and every member who accepted, as people', (select count(*) from public.site_dm_members m where m.conversation = conv and m.status = 'active' and m.profile in (p_dee, p_ann, p_bob, p_cy, p_zed))::int, 5);
  perform tests.assert_eq('...run by the owner, as a person', (select m.role from public.site_dm_members m where m.conversation = conv and m.profile = p_dee), 'admin');
  perform tests.assert_eq('...an ordinary group conversation', (select kind || '/' || title from public.site_dm_conversations where id = conv), 'group/Team: DJ Dee');
  perform tests.assert_eq('a member can write in it', tests.f(ann, a_e, format($q$public.dm_send(%L, %L, 'Team, the gig is on')$q$, p_ann, conv), '{body}'), 'Team, the gig is on');
  perform tests.assert_eq('...and the list gives its address', tests.q(ann, a_e, format($q$public.team_list(%L) ->> 'chat'$q$, p_dj)), conv::text);
  perform tests.assert_eq('...and the profile to open it as', tests.q(ann, a_e, format($q$public.team_list(%L) ->> 'chat_profile'$q$, p_dj)), p_ann::text);

  ---------------------------------------------------------------- requests only the right role sees
  perform tests.login(zed, z_e); perform tests.logout();
  perform tests.assert_eq('a customer asks the DJ', tests.f(gus, g_e, format($q$public.pro_request_create(%L, null, %L, null, null, null, 'Need a DJ for a night', null)$q$, p_dj, d1), '{status}'), 'requested');
  select id into rq from public.site_pro_requests where provider = p_dj and client = gus;
  perform tests.assert_eq('a booking agent sees it', tests.f(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq), '{status}'), 'requested');
  perform tests.assert_eq('...and a custom role with bookings does', tests.f(zed, z_e, format($q$public.pro_request_get(%L)$q$, rq), '{status}'), 'requested');
  perform tests.assert_eq('...but a content manager does not', tests.q(bob, b_e, format($q$public.pro_request_get(%L)$q$, rq)), 'ERROR: This request is not available.');
  perform tests.assert_eq('...nor does door staff', tests.q(cy, c_e, format($q$public.pro_request_get(%L)$q$, rq)), 'ERROR: This request is not available.');
  perform tests.assert_eq('a content manager cannot quote', tests.q(bob, b_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours of music', 5)$q$, p_dj, rq, d1 - 3)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('a booking agent can', tests.f(ann, a_e, format($q$public.pro_quote_send(%L, %L, 100000, 30000, %L, 'Four hours of music', 5)$q$, p_dj, rq, d1 - 3), '{status}'), 'quoted');

  ---------------------------------------------------------------- revoking, leaving, asking again
  perform tests.assert_eq('revoking is for the owner and works at once', tests.f(dee, d_e, format($q$public.team_revoke(%L, %L)$q$, p_dj, t_ann), '{status}'), 'revoked');
  perform tests.assert_eq('...she is out of the profile that moment', tests.i(ann, a_e, format($q$public.profile_is_mine(%L)$q$, p_dj)), 'false');
  perform tests.assert_eq('...out of the list of profiles she may act as', tests.i(ann, a_e, format($q$%L::uuid in (select public.profile_my_ids())$q$, p_dj)), 'false');
  perform tests.assert_eq('...out of its requests', tests.q(ann, a_e, format($q$public.pro_request_get(%L)$q$, rq)), 'ERROR: This request is not available.');
  perform tests.assert_eq('...out of its services', tests.q(ann, a_e, format($q$public.pro_service_save(%L, null, 'Still here', null, null, null)$q$, p_dj)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...and out of the team chat', (select m.status from public.site_dm_members m where m.conversation = conv and m.profile = p_ann), 'left');
  perform tests.assert_eq('...she cannot write there any more', tests.q(ann, a_e, format($q$public.dm_send(%L, %L, 'Still here?')$q$, p_ann, conv)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('revoking twice is refused', tests.q(dee, d_e, format($q$public.team_revoke(%L, %L)$q$, p_dj, t_ann)), 'ERROR: This person is not on the team.');
  perform tests.assert_eq('a revoked person cannot answer again', tests.q(ann, a_e, format($q$public.team_answer(%L, true)$q$, t_ann)), 'ERROR: This invitation has already been answered.');
  perform tests.assert_eq('...and the list no longer shows her', tests.q(dee, d_e, format($q$jsonb_array_length(public.team_list(%L) -> 'members')$q$, p_dj)), '3');
  t_ann2 := (tests.f(dee, d_e, format($q$public.team_invite(%L, 'annteam', 'content_manager')$q$, p_dj), '{id}'))::uuid;
  perform tests.assert_eq('she can be asked again, in the same place', t_ann2::text, t_ann::text);
  perform tests.assert_true('...with no answer on record yet', (select answered_at is null from public.site_profile_team where id = t_ann));
  perform tests.assert_eq('...with the new role and waiting again', (select role || '/' || status || '/' || permissions::text from public.site_profile_team where id = t_ann), 'content_manager/invited/{content}');
  perform tests.assert_eq('she declines', tests.f(ann, a_e, format($q$public.team_answer(%L, false)$q$, t_ann), '{status}'), 'declined');
  perform tests.assert_eq('...and has no access', tests.i(ann, a_e, format($q$public.profile_is_mine(%L)$q$, p_dj)), 'false');
  perform tests.assert_eq('a person leaves on their own', tests.f(zed, z_e, format($q$public.team_leave(%L)$q$, t_zed), '{status}'), 'left');
  perform tests.assert_eq('...and is out at once', tests.i(zed, z_e, format($q$public.profile_is_mine(%L)$q$, p_dj)), 'false');
  perform tests.assert_eq('...and out of the chat', (select m.status from public.site_dm_members m where m.conversation = conv and m.profile = p_zed), 'left');
  perform tests.assert_eq('...leaving twice is refused', tests.q(zed, z_e, format($q$public.team_leave(%L)$q$, t_zed)), 'ERROR: You are not on this team.');
  perform tests.assert_eq('...someone else''s membership cannot be left', tests.q(zed, z_e, format($q$public.team_leave(%L)$q$, t_bob)), 'ERROR: This team is not available.');
  perform tests.assert_eq('the audit log has every step', (select count(*) from public.audit_log where action like 'team.%')::int, 13);

  ---------------------------------------------------------------- venue hire: asking
  perform tests.assert_eq('only a group or promoter asks: not a DJ', tests.q(dee, d_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', null, null, null, null, null, null)$q$, p_dj, p_club, d1)), 'ERROR: Only an event group or a promoter can ask a venue to host an event.');
  perform tests.assert_eq('...and only as a profile you run', tests.q(zed, z_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', null, null, null, null, null, null)$q$, p_grp, p_club, d1)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...of a venue', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', null, null, null, null, null, null)$q$, p_grp, p_dj, d1)), 'ERROR: This venue is not available.');
  perform tests.assert_eq('...not your own venue', tests.q(olly, o_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', null, null, null, null, null, null)$q$, p_ogrp, p_club, d1)), 'ERROR: You cannot ask your own venue.');
  perform tests.assert_eq('a day today or past', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, current_date, null, 'Themed night', null, null, null, null, null, null)$q$, p_grp, p_club)), 'ERROR: Choose a date between tomorrow and two years from now.');
  perform tests.assert_eq('...a day too far', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, current_date + 731, null, 'Themed night', null, null, null, null, null, null)$q$, p_grp, p_club)), 'ERROR: Choose a date between tomorrow and two years from now.');
  perform tests.assert_eq('...a kind of event that is too short', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'x', null, null, null, null, null, null)$q$, p_grp, p_club, d1)), 'ERROR: Say what kind of event it is in 2 to 80 characters.');
  perform tests.assert_eq('...hours that are too long', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, %L, 'Themed night', null, null, null, null, null, null)$q$, p_grp, p_club, d1, repeat('x', 61))), 'ERROR: Keep the hours to 60 characters.');
  perform tests.assert_eq('...an attendance of zero', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', 0, null, null, null, null, null)$q$, p_grp, p_club, d1)), 'ERROR: Choose an expected attendance between 1 and 100,000.');
  perform tests.assert_eq('...a space that is too long', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', 100, %L, null, null, null, null)$q$, p_grp, p_club, d1, repeat('x', 161))), 'ERROR: Keep the space to 160 characters.');
  perform tests.assert_eq('...equipment that is too long', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', 100, null, %L, null, null, null)$q$, p_grp, p_club, d1, repeat('x', 301))), 'ERROR: Keep the equipment to 300 characters.');
  perform tests.assert_eq('...staffing that is too long', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', 100, null, null, %L, null, null)$q$, p_grp, p_club, d1, repeat('x', 301))), 'ERROR: Keep the staffing to 300 characters.');
  perform tests.assert_eq('...a budget out of range', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', 100, null, null, null, -1, null)$q$, p_grp, p_club, d1)), 'ERROR: Choose a budget between 0 and 1,000,000.00.');
  perform tests.assert_eq('...requests that are too long', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', 100, null, null, null, null, %L)$q$, p_grp, p_club, d1, repeat('x', 1001))), 'ERROR: Keep the special requests to 1000 characters.');
  perform tests.login(admin_u, adm); perform public.cms_set_banned_term('forbiddenword', true); perform tests.logout();
  perform tests.assert_eq('...banned words', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'A forbiddenword night', 100, null, null, null, null, null)$q$, p_grp, p_club, d1)), 'ERROR: That wording is not allowed here.');
  perform tests.login(gus, g_e); perform public.block_set(p_grp, p_club, true); perform tests.logout();
  perform tests.assert_eq('...a venue you blocked', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Themed night', null, null, null, null, null, null)$q$, p_grp, p_club, d1)), 'ERROR: This venue is not available.');
  perform tests.login(gus, g_e); perform public.block_set(p_grp, p_club, false); perform tests.logout();

  j := tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, '9pm to 3am', ' Themed night ', 400, 'Main room', 'Own DJ booth', 'Two bartenders', 500000, 'Please keep the lights low')$q$, p_grp, p_club, d1))::jsonb;
  h1 := (j ->> 'id')::uuid;
  perform tests.assert_true('a hire was asked for', h1 is not null);
  perform tests.assert_eq('...it is only a request', j ->> 'state', 'requested');
  perform tests.assert_eq('...with what was asked, trimmed', (j ->> 'event_type') || '/' || (j ->> 'hours') || '/' || (j ->> 'attendance') || '/' || (j ->> 'budget_cents'), 'Themed night/9pm to 3am/400/500000');
  perform tests.assert_eq('...the group sees who is asking as a profile only', j #>> '{organizer,display_name}', 'EONICS');
  perform tests.assert_true('...and not a person: the asker is private to the venue', j -> 'requested_by' = 'null'::jsonb);
  perform tests.assert_eq('one open request per venue per day', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Another night', null, null, null, null, null, null)$q$, p_grp, p_club, d1)), 'ERROR: You already have a request open with this venue for that day.');
  perform tests.assert_eq('...but another venue is another request', tests.f(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Another night', null, null, null, null, null, null)$q$, p_grp, p_club2, d1), '{state}'), 'requested');
  perform tests.assert_eq('the hire chat has the group and the venue', (select count(*) from public.site_chat_links l join public.site_dm_members m on m.conversation = l.conversation where l.kind = 'hire' and l.ref = h1 and m.status = 'active' and m.profile in (p_grp, p_club))::int, 2);
  perform tests.assert_eq('...the group, which asked, runs it', (select m.role from public.site_chat_links l join public.site_dm_members m on m.conversation = l.conversation where l.kind = 'hire' and l.ref = h1 and m.profile = p_grp), 'admin');
  perform tests.assert_eq('...and the venue is a member', (select m.role from public.site_chat_links l join public.site_dm_members m on m.conversation = l.conversation where l.kind = 'hire' and l.ref = h1 and m.profile = p_club), 'member');
  perform tests.assert_eq('five requests a day is the limit', (select count(*) from public.site_hires where organizer = p_grp)::int, 2);
  for n in 1..3 loop
    perform tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Night %s', null, null, null, null, null, null)$q$, p_grp, p_club, d1 + 10 + n, n));
  end loop;
  perform tests.assert_eq('the sixth in a day is refused', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Night six', null, null, null, null, null, null)$q$, p_grp, p_club, d1 + 20)), 'ERROR: You have sent a lot of requests today. Try again tomorrow.');
  update public.site_hires set created_at = created_at - interval '2 days' where organizer = p_grp and event_date > d1;
  delete from public.site_hires where organizer = p_grp and event_date > d1 and event_date <> d1;
  delete from public.site_hires where organizer = p_grp and venue_profile = p_club2;

  ---------------------------------------------------------------- the venue sees it, and only the venue answers
  perform tests.assert_eq('the venue sees the request, and who sent it', tests.f(olly, o_e, format($q$public.hire_get(%L, %L)$q$, p_club, h1), '{requested_by,name}'), 'Gus Group');
  perform tests.assert_eq('...in its list', tests.q(olly, o_e, format($q$jsonb_array_length(public.hires_for(%L))$q$, p_club)), '1');
  perform tests.assert_eq('the group sees it in its own list', tests.q(gus, g_e, format($q$jsonb_array_length(public.hires_mine(%L))$q$, p_grp)), '1');
  perform tests.assert_eq('another venue sees none of it', tests.q(olly, o_e, format($q$jsonb_array_length(public.hires_for(%L))$q$, p_club2)), '0');
  perform tests.assert_eq('...and cannot open it', tests.q(olly, o_e, format($q$public.hire_get(%L, %L)$q$, p_club2, h1)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('a stranger cannot open it as the group', tests.q(zed, z_e, format($q$public.hire_get(%L, %L)$q$, p_grp, h1)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...and a group cannot list a venue''s requests', tests.q(gus, g_e, format($q$public.hires_for(%L)$q$, p_grp)), 'ERROR: Only a venue profile has hire requests.');
  perform tests.assert_eq('...and a venue has no asks of its own', tests.q(olly, o_e, format($q$public.hires_mine(%L)$q$, p_club)), '[]');
  perform tests.assert_eq('the group cannot make the offer', tests.q(gus, g_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 0, 'venue', null, null, null, null, 7)$q$, p_grp, h1)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...nor a different venue', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club2, h1)), 'ERROR: This hire is not available.');

  ---------------------------------------------------------------- the offer
  perform tests.assert_eq('a rental cost out of range', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, -1, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club, h1)), 'ERROR: Choose a rental cost between 0 and 1,000,000.00.');
  perform tests.assert_eq('...a deposit above the rental cost', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 500001, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club, h1)), 'ERROR: The deposit cannot be more than the rental cost.');
  perform tests.assert_eq('...a negative deposit', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, -1, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club, h1)), 'ERROR: The deposit cannot be more than the rental cost.');
  perform tests.assert_eq('...a minimum sales figure out of range', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, -1, 0, 'venue', null, null, null, null, 7)$q$, p_club, h1)), 'ERROR: Choose a minimum sales figure between 0 and 1,000,000.00.');
  perform tests.assert_eq('...a bar share over a hundred percent', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 10001, 'venue', null, null, null, null, 7)$q$, p_club, h1)), 'ERROR: Choose a bar share between 0% and 100%.');
  perform tests.assert_eq('...nobody in control', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 2000, 'nobody', null, null, null, null, 7)$q$, p_club, h1)), 'ERROR: Say who controls tickets and tables.');
  perform tests.assert_eq('...staffing that is too long', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 2000, 'venue', %L, null, null, null, 7)$q$, p_club, h1, repeat('x', 301))), 'ERROR: Keep the staffing to 300 characters.');
  perform tests.assert_eq('...equipment that is too long', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 2000, 'venue', null, %L, null, null, 7)$q$, p_club, h1, repeat('x', 301))), 'ERROR: Keep the equipment to 300 characters.');
  perform tests.assert_eq('...cancellation terms that are too long', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 2000, 'venue', null, null, %L, null, 7)$q$, p_club, h1, repeat('x', 601))), 'ERROR: Keep the cancellation terms to 600 characters.');
  perform tests.assert_eq('...notes that are too long', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 2000, 'venue', null, null, null, %L, 7)$q$, p_club, h1, repeat('x', 1001))), 'ERROR: Keep the notes to 1000 characters.');
  perform tests.assert_eq('...no days to accept', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 2000, 'venue', null, null, null, null, 0)$q$, p_club, h1)), 'ERROR: An offer can stay open for 1 to 14 days.');
  perform tests.assert_eq('...too many days', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 2000, 'venue', null, null, null, null, 15)$q$, p_club, h1)), 'ERROR: An offer can stay open for 1 to 14 days.');
  perform tests.assert_eq('...banned words', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 500000, 100000, 0, 2000, 'venue', null, null, 'No forbiddenword refunds', null, 7)$q$, p_club, h1)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('the venue offers', tests.f(olly, o_e, format($q$public.hire_offer_send(%L, %L, 450000, 100000, 300000, 2000, 'shared', 'Two bartenders included', 'House sound', 'Lose the deposit within 14 days', 'Bring your own door staff', 7)$q$, p_club, h1), '{state}'), 'offered');
  perform tests.assert_eq('...the group sees the terms as sent', tests.q(gus, g_e, format($q$public.hire_get(%L, %L) #>> '{offer,rental_cents}'$q$, p_grp, h1)), '450000');
  perform tests.assert_eq('...with the bar share and who controls', tests.q(gus, g_e, format($q$(public.hire_get(%L, %L) #>> '{offer,bar_share_bps}') || '/' || (public.hire_get(%L, %L) #>> '{offer,control}')$q$, p_grp, h1, p_grp, h1)), '2000/shared');
  perform tests.assert_eq('a new offer replaces the old: one is live', tests.f(olly, o_e, format($q$public.hire_offer_send(%L, %L, 400000, 100000, 300000, 2000, 'shared', null, null, null, null, 7)$q$, p_club, h1), '{offer,rental_cents}'), '400000');
  perform tests.assert_eq('...the old one is withdrawn', (select count(*) from public.site_hire_offers where hire = h1 and status = 'withdrawn')::int, 1);
  perform tests.assert_eq('...and only one is sent', (select count(*) from public.site_hire_offers where hire = h1 and status = 'sent')::int, 1);
  perform tests.assert_eq('the group turns the offer down: back to waiting', tests.f(gus, g_e, format($q$public.hire_offer_decline(%L, %L)$q$, p_grp, h1), '{state}'), 'requested');
  perform tests.assert_eq('...the offer is called declined', (select count(*) from public.site_hire_offers where hire = h1 and status = 'declined')::int, 1);
  perform tests.assert_eq('...and there is nothing left to turn down', tests.q(gus, g_e, format($q$public.hire_offer_decline(%L, %L)$q$, p_grp, h1)), 'ERROR: There is no offer to turn down.');
  perform tests.assert_eq('the venue offers again', tests.f(olly, o_e, format($q$public.hire_offer_send(%L, %L, 400000, 100000, 300000, 2000, 'shared', null, null, null, null, 7)$q$, p_club, h1), '{state}'), 'offered');
  perform tests.assert_eq('...and takes it back', tests.f(olly, o_e, format($q$public.hire_offer_withdraw(%L, %L)$q$, p_club, h1), '{state}'), 'requested');
  perform tests.assert_eq('...and no offer is left live', (select count(*) from public.site_hire_offers where hire = h1 and status = 'sent')::int, 0);
  perform tests.assert_eq('...twice is refused', tests.q(olly, o_e, format($q$public.hire_offer_withdraw(%L, %L)$q$, p_club, h1)), 'ERROR: There is no offer to withdraw.');
  perform tests.assert_eq('nothing can be agreed without an offer', tests.q(gus, g_e, format($q$public.hire_agree(%L, %L)$q$, p_grp, h1)), 'ERROR: There is no offer to agree to.');
  perform tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 400000, 100000, 300000, 2000, 'shared', null, null, null, null, 7)$q$, p_club, h1));
  update public.site_hire_offers set valid_until = now() - interval '1 minute' where hire = h1 and status = 'sent';
  perform tests.assert_eq('an offer that ran out is said to have', tests.q(gus, g_e, format($q$public.hire_get(%L, %L) ->> 'state'$q$, p_grp, h1)), 'offer_expired');
  perform tests.assert_eq('...and cannot be agreed', tests.q(gus, g_e, format($q$public.hire_agree(%L, %L)$q$, p_grp, h1)), 'ERROR: This offer has expired. Ask the venue for a new one.');
  perform tests.assert_eq('...the venue makes a fresh one', tests.f(olly, o_e, format($q$public.hire_offer_send(%L, %L, 400000, 100000, 300000, 2000, 'shared', null, null, null, null, 3)$q$, p_club, h1), '{state}'), 'offered');

  ---------------------------------------------------------------- agreeing and confirming
  perform tests.assert_eq('nothing is booked yet: the venue cannot confirm an offer', tests.q(olly, o_e, format($q$public.hire_confirm(%L, %L)$q$, p_club, h1)), 'ERROR: This hire is not waiting for your confirmation.');
  perform tests.assert_eq('the venue cannot agree for the group', tests.q(olly, o_e, format($q$public.hire_agree(%L, %L)$q$, p_club, h1)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('a stranger cannot agree', tests.q(zed, z_e, format($q$public.hire_agree(%L, %L)$q$, p_grp, h1)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('the group agrees', tests.f(gus, g_e, format($q$public.hire_agree(%L, %L)$q$, p_grp, h1), '{state}'), 'agreed');
  perform tests.assert_eq('...the offer is accepted as it stood', (select status || '/' || rental_cents from public.site_hire_offers where hire = h1 and status = 'accepted'), 'accepted/400000');
  perform tests.assert_eq('...agreeing is not confirming: the date is not booked', tests.q(olly, o_e, format($q$public.hire_get(%L, %L) ->> 'state'$q$, p_club, h1)), 'agreed');
  perform tests.assert_eq('...and it cannot be agreed twice', tests.q(gus, g_e, format($q$public.hire_agree(%L, %L)$q$, p_grp, h1)), 'ERROR: There is no offer to agree to.');
  perform tests.assert_eq('the group cannot confirm for the venue', tests.q(gus, g_e, format($q$public.hire_confirm(%L, %L)$q$, p_grp, h1)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('the workspace is open once it is agreed', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) ->> 'open'$q$, p_grp, h1)), 'true');
  perform tests.assert_eq('...and says the venue has not confirmed', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) -> 'pending' ->> 0$q$, p_grp, h1)), 'The venue has not confirmed the date yet.');
  perform tests.assert_eq('the venue confirms', tests.f(olly, o_e, format($q$public.hire_confirm(%L, %L)$q$, p_club, h1), '{state}'), 'confirmed');
  perform tests.assert_true('...and the time is recorded', (select confirmed_at is not null from public.site_hires where id = h1));
  perform tests.assert_eq('...the event chat has the group and the venue', (select count(*) from public.site_chat_links l join public.site_dm_members m on m.conversation = l.conversation where l.kind = 'event' and l.ref = h1 and m.status = 'active' and m.profile in (p_grp, p_club))::int, 2);
  perform tests.assert_eq('...confirming twice is refused', tests.q(olly, o_e, format($q$public.hire_confirm(%L, %L)$q$, p_club, h1)), 'ERROR: This hire is not waiting for your confirmation.');

  -- A second group for the same venue and day: cannot even be asked, and cannot be agreed if it was asked before.
  perform tests.assert_eq('a day the venue has confirmed cannot be asked for', tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night', null, null, null, null, null, null)$q$, p_grp2, p_club, d1)), 'ERROR: This venue is already booked for a hire that day.');
  perform tests.assert_eq('a promoter asks for another day', tests.f(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night', 200, null, null, null, null, null)$q$, p_grp2, p_club, d1 + 1), '{state}'), 'requested');
  select id into h2 from public.site_hires where organizer = p_grp2;
  perform tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club, h2));
  update public.site_hires set event_date = d1 where id = h2;
  perform tests.assert_eq('...it was asked for before, but the day is taken: cannot be agreed', tests.q(pat, p_e, format($q$public.hire_agree(%L, %L)$q$, p_grp2, h2)), 'ERROR: This venue is already booked for a hire that day.');
  update public.site_hires set event_date = d1 + 1 where id = h2;
  perform tests.assert_eq('...the database holds one confirmed hire per venue per day', (select count(*) from pg_indexes where indexname = 'site_hires_one_confirmed')::int, 1);

  ---------------------------------------------------------------- the workspace
  perform tests.assert_eq('a tasks need a title', tests.q(gus, g_e, format($q$public.hire_item_add(%L, %L, 'task', 'x', null, null)$q$, p_grp, h1)), 'ERROR: Give it a title of 2 to 120 characters.');
  perform tests.assert_eq('...and a kind', tests.q(gus, g_e, format($q$public.hire_item_add(%L, %L, 'note', 'Check the lights', null, null)$q$, p_grp, h1)), 'ERROR: Choose a task or a schedule item.');
  perform tests.assert_eq('...a schedule item needs a time', tests.q(gus, g_e, format($q$public.hire_item_add(%L, %L, 'schedule', 'Doors open', null, null)$q$, p_grp, h1)), 'ERROR: Say what time it is.');
  perform tests.assert_eq('...a due date in the past', tests.q(gus, g_e, format($q$public.hire_item_add(%L, %L, 'task', 'Send the lineup', null, current_date - 1)$q$, p_grp, h1)), 'ERROR: Choose a due date from today to two years from now.');
  perform tests.assert_eq('...banned words', tests.q(gus, g_e, format($q$public.hire_item_add(%L, %L, 'task', 'A forbiddenword task', null, null)$q$, p_grp, h1)), 'ERROR: That wording is not allowed here.');
  it1 := (tests.f(gus, g_e, format($q$public.hire_item_add(%L, %L, 'task', 'Send the lineup', null, current_date + 5)$q$, p_grp, h1), '{id}'))::uuid;
  it2 := (tests.f(olly, o_e, format($q$public.hire_item_add(%L, %L, 'schedule', 'Doors open', '21:00', null)$q$, p_club, h1), '{id}'))::uuid;
  perform tests.assert_true('both sides add to the workspace', it1 is not null and it2 is not null);
  perform tests.assert_eq('...each item says who added it', (select string_agg(side, ',' order by side) from public.site_hire_items where hire = h1), 'organizer,venue');
  perform tests.assert_eq('a stranger cannot add', tests.q(zed, z_e, format($q$public.hire_item_add(%L, %L, 'task', 'Sneak in', null, null)$q$, p_grp, h1)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...another venue neither', tests.q(olly, o_e, format($q$public.hire_item_add(%L, %L, 'task', 'Sneak in', null, null)$q$, p_club2, h1)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('a task is ticked off', tests.f(olly, o_e, format($q$public.hire_item_set(%L, %L, null, true)$q$, p_club, it1), '{done}'), 'true');
  perform tests.assert_eq('...and renamed', tests.f(gus, g_e, format($q$public.hire_item_set(%L, %L, 'Send the final lineup', null)$q$, p_grp, it1), '{title}'), 'Send the final lineup');
  perform tests.assert_eq('...which leaves it done', (select done from public.site_hire_items where id = it1), true);
  perform tests.assert_eq('...a bad title is refused', tests.q(gus, g_e, format($q$public.hire_item_set(%L, %L, 'x', null)$q$, p_grp, it1)), 'ERROR: Give it a title of 2 to 120 characters.');
  perform tests.assert_eq('...an outsider cannot touch it', tests.q(olly, o_e, format($q$public.hire_item_set(%L, %L, 'Mine now', null)$q$, p_club2, it1)), 'ERROR: This item is not available.');
  perform tests.assert_eq('the items come with the schedule first', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) -> 'items' -> 0 ->> 'title'$q$, p_grp, h1)), 'Doors open');
  perform tests.assert_eq('...with times as HH:MM', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) -> 'items' -> 0 ->> 'at_time'$q$, p_grp, h1)), '21:00');
  perform tests.assert_eq('a workspace holds sixty items', (select count(*) from public.site_hire_items where hire = h1)::int, 2);
  insert into public.site_hire_items (hire, kind, title, side) select h1, 'task', 'Filler task ' || g, 'venue' from generate_series(1, 58) g;
  perform tests.assert_eq('...and no more', tests.q(gus, g_e, format($q$public.hire_item_add(%L, %L, 'task', 'One too many', null, null)$q$, p_grp, h1)), 'ERROR: A workspace holds up to 60 items.');
  delete from public.site_hire_items where title like 'Filler task%';
  perform tests.q(olly, o_e, format($q$public.hire_item_remove(%L, %L)$q$, p_club, it2));
  perform tests.assert_eq('an item is removed by either side', (select count(*) from public.site_hire_items where id = it2)::int, 0);
  perform tests.assert_eq('...an outsider cannot remove', tests.q(zed, z_e, format($q$public.hire_item_remove(%L, %L)$q$, p_grp, it1)), 'ERROR: You cannot act as this profile.');

  ---------------------------------------------------------------- the lineup: professionals attached to the hire
  insert into public.site_pro_requests (client, provider, event_date, message) values (gus, p_dj, d1, 'Please play at our night') returning id into rq;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) values (rq, 100000, 30000, d1 - 5, 'Four hours of music and lights', now() + interval '3 days') returning id into q1;
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by)
    values (q1, rq, gus, p_dj, 'DJ set', d1, 100000, 30000, d1 - 5, 500, 7, now() + interval '1 day') returning id into bk;
  perform tests.assert_eq('a professional booking is attached', tests.f(gus, g_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp, h1, bk), '{attached}'), 'true');
  perform tests.assert_eq('...only once', tests.q(gus, g_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp, h1, bk)), 'ERROR: This booking is already attached to a hire.');
  perform tests.assert_eq('...the professional joins the event chat', (select m.status from public.site_chat_links l join public.site_dm_members m on m.conversation = l.conversation where l.kind = 'event' and l.ref = h1 and m.profile = p_dj), 'active');
  perform tests.assert_eq('someone else''s booking cannot be attached', tests.q(pat, p_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp2, h1, bk)), 'ERROR: This hire is not available.');
  insert into public.site_pro_requests (client, provider, event_date, message) values (zed, p_dj2, d1, 'Please take photos') returning id into rq;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) values (rq, 60000, 20000, d1 - 5, 'Photos for the whole night', now() + interval '3 days') returning id into q1;
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by)
    values (q1, rq, zed, p_dj2, 'Photos', d1, 60000, 20000, d1 - 5, 500, 7, now() + interval '1 day') returning id into bk2;
  perform tests.assert_eq('...a booking made by somebody else is not the group''s to attach', tests.q(gus, g_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp, h1, bk2)), 'ERROR: This booking is not available.');
  insert into public.site_pro_requests (client, provider, event_date, message) values (gus, p_dj2, d1 + 3, 'Please take photos another day') returning id into rq;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) values (rq, 60000, 20000, d1 - 2, 'Photos for the whole night', now() + interval '3 days') returning id into q1;
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by)
    values (q1, rq, gus, p_dj2, 'Photos later', d1 + 3, 60000, 20000, d1 - 2, 500, 7, now() + interval '1 day') returning id into bk3;
  perform tests.assert_eq('...nor one for another day', tests.q(gus, g_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp, h1, bk3)), 'ERROR: This booking is for a different day.');
  perform tests.assert_eq('the workspace lists the lineup...', tests.q(gus, g_e, format($q$jsonb_array_length(public.hire_workspace(%L, %L) -> 'bookings')$q$, p_grp, h1)), '1');
  perform tests.assert_eq('...as not confirmed while the deposit is unpaid', tests.q(olly, o_e, format($q$public.hire_workspace(%L, %L) #>> '{bookings,0,confirmed}'$q$, p_club, h1)), 'false');
  perform tests.assert_eq('...and says so in what is pending', tests.q(olly, o_e, format($q$public.hire_workspace(%L, %L) -> 'pending' ->> 0$q$, p_club, h1)), 'No public event is linked yet.');
  perform tests.assert_true('...and the venue sees no money of the professional', not (tests.q(olly, o_e, format($q$public.hire_workspace(%L, %L) #> '{bookings,0}'$q$, p_club, h1))::jsonb ?| array['total_cents', 'deposit_cents', 'paid_cents', 'net_cents']));
  perform tests.assert_eq('...the professional is named', tests.q(olly, o_e, format($q$public.hire_workspace(%L, %L) #>> '{bookings,0,provider,display_name}'$q$, p_club, h1)), 'DJ Dee Team');
  update public.site_pro_bookings set status = 'active', paid_cents = deposit_cents where id = bk;
  perform tests.assert_eq('once the deposit is in it is confirmed', tests.q(olly, o_e, format($q$public.hire_workspace(%L, %L) #>> '{bookings,0,confirmed}'$q$, p_club, h1)), 'true');
  perform tests.assert_eq('a professional is taken off', tests.q(gus, g_e, format($q$public.hire_detach_booking(%L, %L, %L)$q$, p_grp, h1, bk)), '');
  perform tests.assert_eq('...and leaves the event chat', (select m.status from public.site_chat_links l join public.site_dm_members m on m.conversation = l.conversation where l.kind = 'event' and l.ref = h1 and m.profile = p_dj), 'left');
  perform tests.assert_eq('...taking off twice is refused', tests.q(gus, g_e, format($q$public.hire_detach_booking(%L, %L, %L)$q$, p_grp, h1, bk)), 'ERROR: This booking is not attached.');
  perform tests.assert_eq('...and the venue cannot attach', tests.q(olly, o_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_club, h1, bk)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('attached again after being taken off', tests.f(gus, g_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp, h1, bk), '{attached}'), 'true');
  perform tests.assert_eq('...and back in the chat', (select m.status from public.site_chat_links l join public.site_dm_members m on m.conversation = l.conversation where l.kind = 'event' and l.ref = h1 and m.profile = p_dj), 'active');

  ---------------------------------------------------------------- linking the public event
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Themed night', 'Eonics at Hire Club', 'Hire Club', (d1 + time '21:00') at time zone 'UTC', org_g, va, 'published') returning id into ev1;
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Other org night', 'Not Eonics', 'Hire Club', (d1 + time '21:00') at time zone 'UTC', org_p, va, 'published') returning id into ev2;
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Eonics elsewhere', 'Wrong venue', 'Annex', (d1 + time '21:00') at time zone 'UTC', org_g, vb, 'published') returning id into ev3;
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Eonics next month', 'Wrong day', 'Hire Club', ((d1 + 10) + time '21:00') at time zone 'UTC', org_g, va, 'published') returning id into ev4;
  insert into public.site_ticket_tiers (event_id, name, price_cents, capacity, sold_count) values (ev1, 'General', 3000, 300, 120), (ev1, 'VIP', 8000, 50, 10);
  perform tests.assert_eq('the group is offered its own events near the day, at this venue', tests.q(gus, g_e, format($q$(select string_agg(x ->> 'title', ',' order by x ->> 'title') from jsonb_array_elements(public.hire_events_linkable(%L, %L)) x)$q$, p_grp, h1)), 'Themed night');
  perform tests.assert_eq('...the venue is not offered them', tests.q(olly, o_e, format($q$public.hire_events_linkable(%L, %L)$q$, p_club, h1)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...nor to a stranger', tests.q(zed, z_e, format($q$public.hire_events_linkable(%L, %L)$q$, p_grp, h1)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('an event of another business cannot be linked', tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, h1, ev2)), 'ERROR: You can only link an event your own business runs.');
  perform tests.assert_eq('...nor one at another venue', tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, h1, ev3)), 'ERROR: That event is at another venue.');
  perform tests.assert_eq('...nor one on another day', tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, h1, ev4)), 'ERROR: That event is on a different day.');
  perform tests.assert_eq('...nor one that does not exist', tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, gen_random_uuid())$q$, p_grp, h1)), 'ERROR: You can only link an event your own business runs.');
  perform tests.assert_eq('the venue cannot link', tests.q(olly, o_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_club, h1, ev1)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('the group links its own event', tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, %L) ->> 'event_id'$q$, p_grp, h1, ev1)), ev1::text);
  perform tests.assert_eq('the workspace shows the event and its ticket numbers to both sides', tests.q(olly, o_e, format($q$(public.hire_workspace(%L, %L) #>> '{event,tickets_sold}') || '/' || (public.hire_workspace(%L, %L) #>> '{event,tickets_capacity}')$q$, p_club, h1, p_club, h1)), '130/350');
  perform tests.assert_eq('...and the title', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) #>> '{event,title}'$q$, p_grp, h1)), 'Themed night');
  perform tests.assert_eq('...so "no event linked" is no longer pending', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) -> 'pending' ->> 0$q$, p_grp, h1)), 'DJ Dee Team has not been paid for yet.');
  update public.site_pro_bookings set paid_cents = total_cents where id = bk;
  perform tests.assert_eq('an event linked to a live hire is no longer offered for another', (select count(*) from public.site_hires where event_id = ev1)::int, 1);
  perform tests.assert_eq('the group unlinks it', tests.q(gus, g_e, format($q$public.hire_unlink_event(%L, %L) ->> 'event_id'$q$, p_grp, h1)), '(null)');
  perform tests.assert_eq('...the event itself is untouched', (select count(*) from public.site_events where id = ev1)::int, 1);
  perform tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, h1, ev1));

  ---------------------------------------------------------------- the chats
  perform tests.assert_eq('the workspace names the hire chat', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) ->> 'hire_chat'$q$, p_grp, h1)), (select l.conversation::text from public.site_chat_links l where l.kind = 'hire' and l.ref = h1));
  perform tests.assert_eq('...and the event chat', tests.q(olly, o_e, format($q$public.hire_workspace(%L, %L) ->> 'event_chat'$q$, p_club, h1)), (select l.conversation::text from public.site_chat_links l where l.kind = 'event' and l.ref = h1));
  perform tests.assert_eq('the group writes to the venue in the hire chat', tests.f(gus, g_e, format($q$public.dm_send(%L, %L, 'Can we load in at 4?')$q$, p_grp, (select l.conversation from public.site_chat_links l where l.kind = 'hire' and l.ref = h1)), '{body}'), 'Can we load in at 4?');
  perform tests.assert_eq('...and the venue reads it as the venue', tests.q(olly, o_e, format($q$jsonb_array_length(public.dm_messages(%L, %L))$q$, p_club, (select l.conversation from public.site_chat_links l where l.kind = 'hire' and l.ref = h1))), '1');
  perform tests.assert_eq('a stranger reads nothing of it', tests.q(zed, z_e, format($q$public.dm_messages(%L, %L)$q$, p_zed, (select l.conversation from public.site_chat_links l where l.kind = 'hire' and l.ref = h1))), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('the DJ writes in the event chat as the profile', tests.f(dee, d_e, format($q$public.dm_send(%L, %L, 'Sound check at 6')$q$, p_dj, (select l.conversation from public.site_chat_links l where l.kind = 'event' and l.ref = h1)), '{body}'), 'Sound check at 6');
  perform tests.assert_eq('...but the DJ is not in the hire chat', tests.q(dee, d_e, format($q$public.dm_messages(%L, %L)$q$, p_dj, (select l.conversation from public.site_chat_links l where l.kind = 'hire' and l.ref = h1))), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...and the team chat is separate from both', (select count(distinct conversation) from public.site_chat_links where ref in (h1, p_dj))::int, 3);

  ---------------------------------------------------------------- declining, withdrawing, cancelling, lapsing
  update public.site_hires set event_date = d1 + 40 where id = h2;
  perform tests.assert_eq('a venue declines with a note', tests.f(olly, o_e, format($q$public.hire_decline(%L, %L, 'Booked out that weekend')$q$, p_club, h2), '{state}'), 'declined');
  perform tests.assert_eq('...the group reads the note', tests.q(pat, p_e, format($q$public.hire_get(%L, %L) ->> 'decline_note'$q$, p_grp2, h2)), 'Booked out that weekend');
  perform tests.assert_eq('...and a declined request cannot be offered', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club, h2)), 'ERROR: This request is no longer open.');
  perform tests.assert_eq('...nor declined again', tests.q(olly, o_e, format($q$public.hire_decline(%L, %L, null)$q$, p_club, h2)), 'ERROR: This request is no longer open.');
  perform tests.assert_eq('the group withdraws a request', tests.f(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night two', null, null, null, null, null, null)$q$, p_grp2, p_club2, d1 + 40), '{state}'), 'requested');
  select id into h3 from public.site_hires where organizer = p_grp2 and venue_profile = p_club2;
  perform tests.assert_eq('a note that is too long is refused', tests.q(olly, o_e, format($q$public.hire_decline(%L, %L, %L)$q$, p_club2, h3, repeat('x', 301))), 'ERROR: Keep the note to 300 characters.');
  perform tests.assert_eq('...and so is a banned word in it', tests.q(olly, o_e, format($q$public.hire_decline(%L, %L, 'A forbiddenword note')$q$, p_club2, h3)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('...it is withdrawn', tests.f(pat, p_e, format($q$public.hire_withdraw(%L, %L)$q$, p_grp2, h3), '{state}'), 'withdrawn');
  perform tests.assert_eq('...twice is refused', tests.q(pat, p_e, format($q$public.hire_withdraw(%L, %L)$q$, p_grp2, h3)), 'ERROR: This request is no longer open.');
  perform tests.assert_eq('a request cannot be cancelled: it is withdrawn or declined', tests.q(pat, p_e, format($q$public.hire_cancel(%L, %L, 'Changed my mind')$q$, p_grp2, h3)), 'ERROR: Only an agreed or confirmed hire can be cancelled.');
  perform tests.assert_eq('the venue cannot cancel the group''s hire as another venue', tests.q(olly, o_e, format($q$public.hire_cancel(%L, %L, 'No')$q$, p_club2, h1)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('a reason that is too long is refused', tests.q(gus, g_e, format($q$public.hire_cancel(%L, %L, %L)$q$, p_grp, h1, repeat('x', 301))), 'ERROR: Keep the reason to 300 characters.');
  perform tests.assert_eq('the group cancels a confirmed hire', tests.f(gus, g_e, format($q$public.hire_cancel(%L, %L, ' Headliner dropped out ')$q$, p_grp, h1), '{state}'), 'cancelled');
  perform tests.assert_eq('...who cancelled and why', (select cancelled_by || '/' || cancel_reason from public.site_hires where id = h1), 'organizer/Headliner dropped out');
  perform tests.assert_eq('...and the day is free again', tests.f(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night three', null, null, null, null, null, null)$q$, p_grp2, p_club, d1), '{state}'), 'requested');
  select id into h4 from public.site_hires where organizer = p_grp2 and venue_profile = p_club and event_date = d1;
  perform tests.assert_eq('...cancelling again is refused', tests.q(gus, g_e, format($q$public.hire_cancel(%L, %L, null)$q$, p_grp, h1)), 'ERROR: Only an agreed or confirmed hire can be cancelled.');
  perform tests.assert_eq('a cancelled hire closes its workspace', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) ->> 'open'$q$, p_grp, h1)), 'false');
  perform tests.assert_eq('...nothing can be added', tests.q(gus, g_e, format($q$public.hire_item_add(%L, %L, 'task', 'Too late now', null, null)$q$, p_grp, h1)), 'ERROR: The workspace opens once the hire is agreed.');
  perform tests.assert_eq('...a professional cannot be attached', tests.q(gus, g_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp, h1, bk)), 'ERROR: Attach professionals once the venue has confirmed the date.');

  -- The venue cancels one it confirmed; a hire on its day can no longer be cancelled; a request whose day came has lapsed.
  perform tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club, h4));
  perform tests.q(pat, p_e, format($q$public.hire_agree(%L, %L)$q$, p_grp2, h4));
  perform tests.q(olly, o_e, format($q$public.hire_confirm(%L, %L)$q$, p_club, h4));
  perform tests.assert_eq('the venue cancels a confirmed hire', tests.f(olly, o_e, format($q$public.hire_cancel(%L, %L, 'Flood in the cellar')$q$, p_club, h4), '{cancelled_by}'), 'venue');
  perform tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night four', null, null, null, null, null, null)$q$, p_grp2, p_club, d1 + 2));
  select id into h5 from public.site_hires where organizer = p_grp2 and venue_profile = p_club and event_date = d1 + 2;
  perform tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club, h5));
  perform tests.q(pat, p_e, format($q$public.hire_agree(%L, %L)$q$, p_grp2, h5));
  update public.site_hires set event_date = current_date where id = h5;
  perform tests.assert_eq('an agreed hire whose day has come is lapsed', tests.q(pat, p_e, format($q$public.hire_get(%L, %L) ->> 'state'$q$, p_grp2, h5)), 'lapsed');
  perform tests.assert_eq('...cannot be confirmed', tests.q(olly, o_e, format($q$public.hire_confirm(%L, %L)$q$, p_club, h5)), 'ERROR: This hire is not waiting for your confirmation.');
  perform tests.assert_eq('...nor cancelled', tests.q(pat, p_e, format($q$public.hire_cancel(%L, %L, null)$q$, p_grp2, h5)), 'ERROR: The date has come: this hire can no longer be cancelled.');
  update public.site_hires set event_date = current_date - 1, status = 'confirmed' where id = h5;
  perform tests.assert_eq('a confirmed hire whose day has passed is completed', tests.q(pat, p_e, format($q$public.hire_get(%L, %L) ->> 'state'$q$, p_grp2, h5)), 'completed');
  perform tests.assert_eq('...and its workspace is closed', tests.q(pat, p_e, format($q$public.hire_workspace(%L, %L) ->> 'open'$q$, p_grp2, h5)), 'false');


  ---------------------------------------------------------------- more on teams
  perform tests.assert_eq('a finance assistant carries finance only', tests.f(dee, d_e, format($q$public.team_invite(%L, 'annteam', 'finance_assistant')$q$, p_dj2), '{permissions}'), '["finance"]');
  t_fin := (select id from public.site_profile_team where profile = p_dj2 and member = ann);
  perform tests.assert_eq('...an invitation can be taken back before it is answered', tests.f(dee, d_e, format($q$public.team_revoke(%L, %L)$q$, p_dj2, t_fin), '{status}'), 'revoked');
  t_fin := (tests.f(dee, d_e, format($q$public.team_invite(%L, 'cyteam', 'booking_agent')$q$, p_dj2), '{id}'))::uuid;
  perform tests.assert_eq('the list shows the ones still waiting too', tests.q(dee, d_e, format($q$public.team_list(%L) -> 'members' -> 0 ->> 'status'$q$, p_dj2)), 'invited');
  perform tests.assert_eq('a custom role is checked when the role is changed', tests.q(dee, d_e, format($q$public.team_set_role(%L, %L, 'custom', array['bookings', 'owner'])$q$, p_dj2, t_fin)), 'ERROR: Choose from bookings, content and finance.');
  perform tests.q(cy, c_e, format($q$public.team_answer(%L, false)$q$, t_fin));
  perform tests.assert_eq('...a role cannot be changed for someone who is not on the team', tests.q(dee, d_e, format($q$public.team_set_role(%L, %L, 'manager')$q$, p_dj2, t_fin)), 'ERROR: This person is not on the team.');
  t_fin := (tests.f(dee, d_e, format($q$public.team_invite(%L, 'cyteam', 'content_manager')$q$, p_dj2), '{id}'))::uuid;
  update public.site_profiles set status = 'suspended' where id = p_dj2;
  perform tests.assert_eq('an invitation to a suspended profile is not shown', tests.q(cy, c_e, $q$jsonb_array_length(public.team_invitations_mine())$q$), '0');
  update public.site_profiles set status = 'active' where id = p_dj2;
  perform tests.assert_eq('...and is shown again when it is back', tests.q(cy, c_e, $q$jsonb_array_length(public.team_invitations_mine())$q$), '1');
  perform tests.assert_eq('the audit log names every kind of step', (select string_agg(distinct action, ',' order by action) from public.audit_log where action like 'team.%'), 'team.accepted,team.declined,team.invited,team.left,team.revoked,team.role_changed');

  -- a promoter's own profile has a team too: door staff there cannot do the group's work
  t_pat := (tests.f(pat, p_e, format($q$public.team_invite(%L, 'cyteam', 'door_staff')$q$, p_grp2), '{id}'))::uuid;
  perform tests.q(cy, c_e, format($q$public.team_answer(%L, true)$q$, t_pat));
  perform tests.assert_eq('door staff on a promoter act as it', tests.i(cy, c_e, format($q$public.profile_is_mine(%L)$q$, p_grp2)), 'true');
  perform tests.assert_eq('...but cannot ask a venue', tests.q(cy, c_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night', null, null, null, null, null, null)$q$, p_grp2, p_club, d1 + 90)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or list its hires', tests.q(cy, c_e, format($q$public.hires_mine(%L)$q$, p_grp2)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or turn an offer down', tests.q(cy, c_e, format($q$public.hire_offer_decline(%L, %L)$q$, p_grp2, h5)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or agree', tests.q(cy, c_e, format($q$public.hire_agree(%L, %L)$q$, p_grp2, h5)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or withdraw', tests.q(cy, c_e, format($q$public.hire_withdraw(%L, %L)$q$, p_grp2, h5)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or attach a professional', tests.q(cy, c_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp2, h5, bk)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or take one off', tests.q(cy, c_e, format($q$public.hire_detach_booking(%L, %L, %L)$q$, p_grp2, h5, bk)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or link an event', tests.q(cy, c_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp2, h5, ev1)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or unlink it', tests.q(cy, c_e, format($q$public.hire_unlink_event(%L, %L)$q$, p_grp2, h5)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...or list the events', tests.q(cy, c_e, format($q$public.hire_events_linkable(%L, %L)$q$, p_grp2, h5)), 'ERROR: Your role on this profile does not allow this.');
  perform tests.assert_eq('...and a hire of the promoter is not theirs to open', tests.q(cy, c_e, format($q$public.hire_get(%L, %L)$q$, p_grp2, h5)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...nor its workspace', tests.q(cy, c_e, format($q$public.hire_workspace(%L, %L)$q$, p_grp2, h5)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('the owner of the promoter can', tests.f(pat, p_e, format($q$public.hire_get(%L, %L)$q$, p_grp2, h5), '{state}'), 'completed');

  ---------------------------------------------------------------- more on asking, with a fresh group
  update public.site_hires set created_at = created_at - interval '2 days' where organizer in (p_grp, p_grp2);
  delete from public.site_rules_acceptance where user_id = pat;
  perform tests.assert_eq('asking needs the community rules accepted', tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night', null, null, null, null, null, null)$q$, p_grp2, p_club, d1 + 90)), 'ERROR: Read and accept the community rules first.');
  perform tests.login(pat, p_e); perform public.rules_accept(2); perform tests.logout();
  update public.site_profiles set status = 'suspended' where id = p_club;
  perform tests.assert_eq('...a suspended venue cannot be asked', tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night', null, null, null, null, null, null)$q$, p_grp2, p_club, d1 + 90)), 'ERROR: This venue is not available.');
  update public.site_profiles set status = 'active' where id = p_club;
  perform tests.assert_eq('...banned words in the special requests', tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night', null, null, null, null, null, 'No forbiddenword please')$q$, p_grp2, p_club, d1 + 90)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('...a kind of event of 81 characters', tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, %L, null, null, null, null, null, null)$q$, p_grp2, p_club, d1 + 90, repeat('x', 81))), 'ERROR: Say what kind of event it is in 2 to 80 characters.');
  perform tests.assert_eq('...an attendance of 100,001', tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night', 100001, null, null, null, null, null)$q$, p_grp2, p_club, d1 + 90)), 'ERROR: Choose an expected attendance between 1 and 100,000.');
  perform tests.assert_eq('...a budget of 1,000,000.01', tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Promo night', 100000, null, null, null, 100000001, null)$q$, p_grp2, p_club, d1 + 90)), 'ERROR: Choose a budget between 0 and 1,000,000.00.');
  perform tests.assert_eq('the biggest attendance and budget are fine', tests.f(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, %L, 100000, null, null, null, 100000000, null)$q$, p_grp2, p_club2, d1 + 90, repeat('y', 80)), '{state}'), 'requested');
  select id into hx from public.site_hires where organizer = p_grp2 and event_date = d1 + 90;
  perform tests.assert_eq('a long kind of event keeps the chat title short', (select length(c.title) from public.site_dm_conversations c join public.site_chat_links l on l.conversation = c.id where l.kind = 'hire' and l.ref = hx) <= 60, true);

  ---------------------------------------------------------------- more on offers, with that request at the annex (run by olly)
  perform tests.assert_eq('a stranger who runs another venue cannot offer', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club, hx)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...nor confirm a date', tests.q(zed, z_e, format($q$public.hire_confirm(%L, %L)$q$, p_club2, hx)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...nor list the requests', tests.q(zed, z_e, format($q$public.hires_for(%L)$q$, p_club2)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a person who acts as nothing here is told so', tests.q(zed, z_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club2, hx)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a rental cost of 1,000,000.01', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000001, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club2, hx)), 'ERROR: Choose a rental cost between 0 and 1,000,000.00.');
  perform tests.assert_eq('...minimum sales of 1,000,000.01', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000000, 0, 100000001, 0, 'venue', null, null, null, null, 7)$q$, p_club2, hx)), 'ERROR: Choose a minimum sales figure between 0 and 1,000,000.00.');
  perform tests.assert_eq('...a bar share below nothing', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, -1, 'venue', null, null, null, null, 7)$q$, p_club2, hx)), 'ERROR: Choose a bar share between 0% and 100%.');
  perform tests.assert_eq('the biggest offer is fine, and open for the days asked', tests.f(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000000, 100000000, 100000000, 10000, 'organizer', null, null, null, null, 3)$q$, p_club2, hx), '{state}'), 'offered');
  perform tests.assert_true('...it stays open exactly that long', (select valid_until = now() + interval '3 days' from public.site_hire_offers where hire = hx and status = 'sent'));
  perform tests.assert_eq('a stranger at another venue cannot take the offer back', tests.q(olly, o_e, format($q$public.hire_offer_withdraw(%L, %L)$q$, p_club, hx)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...nor decline the request', tests.q(olly, o_e, format($q$public.hire_decline(%L, %L, null)$q$, p_club, hx)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...nor can a different group turn the offer down', tests.q(gus, g_e, format($q$public.hire_offer_decline(%L, %L)$q$, p_grp, hx)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...or withdraw the request', tests.q(gus, g_e, format($q$public.hire_withdraw(%L, %L)$q$, p_grp, hx)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...or agree', tests.q(gus, g_e, format($q$public.hire_agree(%L, %L)$q$, p_grp, hx)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...or open its workspace', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L)$q$, p_grp, hx)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('a stranger who runs another venue cannot open its workspace either', tests.q(olly, o_e, format($q$public.hire_workspace(%L, %L)$q$, p_club, hx)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('the workspace tells each side what is pending: the group has an offer', tests.q(pat, p_e, format($q$public.hire_workspace(%L, %L) -> 'pending' ->> 0$q$, p_grp2, hx)), 'There is an offer waiting for your answer.');
  perform tests.assert_eq('...the venue is waiting for the group', tests.q(olly, o_e, format($q$public.hire_workspace(%L, %L) -> 'pending' ->> 0$q$, p_club2, hx)), 'Waiting for the group to answer your offer.');
  perform tests.assert_eq('the group withdraws an offered request', tests.f(pat, p_e, format($q$public.hire_withdraw(%L, %L)$q$, p_grp2, hx), '{state}'), 'withdrawn');
  perform tests.assert_eq('...and the offer with it', (select count(*) from public.site_hire_offers where hire = hx and status = 'sent')::int, 0);
  perform tests.assert_eq('...it is called withdrawn', (select status from public.site_hire_offers where hire = hx), 'withdrawn');
  update public.site_hires set created_at = created_at - interval '2 days' where organizer in (p_grp, p_grp2);

  -- a request nobody has answered yet
  perform tests.assert_eq('a group asks the annex', tests.f(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Another night', null, null, null, null, null, null)$q$, p_grp, p_club2, d1 + 91), '{state}'), 'requested');
  select id into hy from public.site_hires where organizer = p_grp and event_date = d1 + 91;
  perform tests.assert_eq('...the venue is told it waits for an offer', tests.q(olly, o_e, format($q$public.hire_workspace(%L, %L) -> 'pending' ->> 0$q$, p_club2, hy)), 'This request is waiting for your offer.');
  perform tests.assert_eq('...the group is told it waits for one', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) -> 'pending' ->> 0$q$, p_grp, hy)), 'Waiting for the venue to make an offer.');
  perform tests.assert_eq('...the workspace is not open yet', tests.q(gus, g_e, format($q$public.hire_workspace(%L, %L) ->> 'open'$q$, p_grp, hy)), 'false');
  perform tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 20000, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club2, hy));
  perform tests.assert_eq('the venue declines an offered request', tests.f(olly, o_e, format($q$public.hire_decline(%L, %L, null)$q$, p_club2, hy), '{state}'), 'declined');
  perform tests.assert_eq('...and the offer is withdrawn', (select status from public.site_hire_offers where hire = hy), 'withdrawn');
  perform tests.assert_eq('a request whose day has come cannot be answered with an offer', tests.f(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Another night', null, null, null, null, null, null)$q$, p_grp, p_club2, d1 + 92), '{state}'), 'requested');
  select id into hz from public.site_hires where organizer = p_grp and event_date = d1 + 92;
  update public.site_hires set event_date = current_date where id = hz;
  perform tests.assert_eq('...it is lapsed, and the venue cannot offer', tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club2, hz)), 'ERROR: This request is no longer open.');
  update public.site_hires set event_date = d1 + 92 where id = hz;
  perform tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club2, hz));
  update public.site_hires set event_date = current_date where id = hz;
  perform tests.assert_eq('an offer cannot be agreed on the day', tests.q(gus, g_e, format($q$public.hire_agree(%L, %L)$q$, p_grp, hz)), 'ERROR: There is no offer to agree to.');
  perform tests.assert_eq('a confirmed hire is not completed on its own day', (select public.hire_state(hz)), 'lapsed');
  update public.site_hires set status = 'confirmed' where id = hz;
  perform tests.assert_eq('...it is only confirmed', (select public.hire_state(hz)), 'confirmed');
  perform tests.assert_eq('...and its workspace is open that day', (select public.hire_workspace_open(hz)), true);
  update public.site_hires set event_date = current_date - 1 where id = hz;
  perform tests.assert_eq('...and done the day after', (select public.hire_state(hz)), 'completed');
  perform tests.assert_eq('a past hire''s workspace is closed', (select public.hire_workspace_open(hz)), false);
  perform tests.assert_eq('...and an offer that ran out says so', (select public.hire_offer_json(o.id) ->> 'status' from public.site_hire_offers o where o.hire = h1 and o.status = 'accepted'), 'accepted');
  update public.site_hire_offers set valid_until = now() - interval '1 minute', status = 'sent' where hire = hy;
  perform tests.assert_eq('...an offer past its time reads expired', (select public.hire_offer_json(o.id) ->> 'status' from public.site_hire_offers o where o.hire = hy), 'expired');

  ---------------------------------------------------------------- two groups, one day
  update public.site_hires set created_at = created_at - interval '2 days' where organizer in (p_grp, p_grp2);
  perform tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, %L, null, null, null, null, null, null)$q$, p_grp, p_club2, d1 + 100, repeat('z', 80)));
  perform tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Night B', null, null, null, null, null, null)$q$, p_grp2, p_club2, d1 + 100));
  select id into hq from public.site_hires where organizer = p_grp and event_date = d1 + 100;
  select id into hx from public.site_hires where organizer = p_grp2 and event_date = d1 + 100;
  perform tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club2, hq));
  perform tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club2, hx));
  perform tests.assert_eq('both agree before the venue confirms either', tests.f(gus, g_e, format($q$public.hire_agree(%L, %L)$q$, p_grp, hq), '{state}') || '/' || tests.f(pat, p_e, format($q$public.hire_agree(%L, %L)$q$, p_grp2, hx), '{state}'), 'agreed/agreed');
  perform tests.assert_eq('the venue confirms the first', tests.f(olly, o_e, format($q$public.hire_confirm(%L, %L)$q$, p_club2, hq), '{state}'), 'confirmed');
  perform tests.assert_eq('...its event chat title is cut to fit', (select length(c.title) from public.site_dm_conversations c join public.site_chat_links l on l.conversation = c.id where l.kind = 'event' and l.ref = hq), 60);
  perform tests.assert_eq('...and then cannot confirm the second for the same day', tests.q(olly, o_e, format($q$public.hire_confirm(%L, %L)$q$, p_club2, hx)), 'ERROR: This venue is already booked for a hire that day.');
  perform tests.assert_eq('a group with an agreed request cannot ask again for that day', tests.q(pat, p_e, format($q$public.hire_request(%L, %L, %L, null, 'Night C', null, null, null, null, null, null)$q$, p_grp2, p_club2, d1 + 100)), 'ERROR: This venue is already booked for a hire that day.');
  perform tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Night D', null, null, null, null, null, null)$q$, p_grp, p_club, d1 + 101));
  select id into hy from public.site_hires where organizer = p_grp and event_date = d1 + 101;
  perform tests.q(olly, o_e, format($q$public.hire_offer_send(%L, %L, 100000, 0, 0, 0, 'venue', null, null, null, null, 7)$q$, p_club, hy));
  perform tests.q(gus, g_e, format($q$public.hire_agree(%L, %L)$q$, p_grp, hy));
  perform tests.assert_eq('a group with an agreed request cannot ask again for that day (the same venue, still agreed)', tests.q(gus, g_e, format($q$public.hire_request(%L, %L, %L, null, 'Night E', null, null, null, null, null, null)$q$, p_grp, p_club, d1 + 101)), 'ERROR: You already have a request open with this venue for that day.');
  perform tests.assert_eq('an agreed request is cancelled with a reason that is checked', tests.q(gus, g_e, format($q$public.hire_cancel(%L, %L, 'a forbiddenword reason')$q$, p_grp, hy)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('...and then cancelled', tests.f(gus, g_e, format($q$public.hire_cancel(%L, %L, null)$q$, p_grp, hy), '{state}'), 'cancelled');
  perform tests.assert_eq('the audit log names every kind of step in hiring a venue', (select string_agg(distinct action, ',' order by action) from public.audit_log where action like 'hire.%'), 'hire.agreed,hire.cancelled,hire.confirmed,hire.declined,hire.event_linked,hire.offered,hire.requested');

  ---------------------------------------------------------------- the lineup, its limits
  perform tests.assert_eq('a confirmed hire whose day has passed takes no professionals', tests.q(pat, p_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp2, h5, bk)), 'ERROR: Attach professionals once the venue has confirmed the date.');
  insert into public.site_pro_requests (client, provider, event_date, message) values (gus, p_dj, d1 + 100, 'Please play a late set') returning id into rq;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) values (rq, 60000, 20000, d1 + 90, 'A late set of music', now() + interval '3 days') returning id into q1;
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by, status, cancelled_at, cancelled_by)
    values (q1, rq, gus, p_dj, 'Cancelled set', d1 + 100, 60000, 20000, d1 + 90, 500, 7, now() + interval '1 day', 'cancelled', now(), 'client') returning id into bk2;
  perform tests.assert_eq('a cancelled booking cannot be attached', tests.q(gus, g_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp, hq, bk2)), 'ERROR: This booking is not active.');
  insert into public.site_pro_requests (client, provider, event_date, message) values (gus, p_dj2, d1 + 100, 'Please take late photos') returning id into rq;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) values (rq, 60000, 20000, d1 + 90, 'Late photos for the night', now() + interval '3 days') returning id into q1;
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by)
    values (q1, rq, gus, p_dj2, 'Lapsed photos', d1 + 100, 60000, 20000, d1 + 90, 500, 7, now() - interval '1 hour') returning id into bk3;
  perform tests.assert_eq('...nor one whose deposit time ran out', tests.q(gus, g_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp, hq, bk3)), 'ERROR: This booking is not active.');
  insert into public.site_pro_requests (client, provider, event_date, message) select gus, p_dj, d1 + 100, 'Fixture ask ' || g from generate_series(1, 30) g;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) select r.id, 60000, 20000, d1 + 90, 'Fixture scope for the night', now() + interval '3 days' from public.site_pro_requests r where r.message like 'Fixture ask %';
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by, status, cancelled_at, cancelled_by)
    select q.id, q.request, gus, p_dj, 'Fixture booking', d1 + 100, 60000, 20000, d1 + 90, 500, 7, now() + interval '1 day', 'cancelled', now(), 'client' from public.site_pro_quotes q join public.site_pro_requests r on r.id = q.request where r.message like 'Fixture ask %';
  insert into public.site_hire_bookings (hire, booking, attached_by) select hq, b.id, gus from public.site_pro_bookings b where b.title = 'Fixture booking';
  insert into public.site_pro_requests (client, provider, event_date, message) values (gus, p_dj2, d1 + 100, 'Please take the real photos') returning id into rq;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) values (rq, 60000, 20000, d1 + 90, 'Real photos for the night', now() + interval '3 days') returning id into q1;
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by)
    values (q1, rq, gus, p_dj2, 'Real photos', d1 + 100, 60000, 20000, d1 + 90, 500, 7, now() + interval '1 day') returning id into bk3;
  perform tests.assert_eq('a hire holds thirty professionals', tests.q(gus, g_e, format($q$public.hire_attach_booking(%L, %L, %L)$q$, p_grp, hq, bk3)), 'ERROR: A hire holds up to 30 professionals.');
  delete from public.site_hire_bookings where hire = hq;

  ---------------------------------------------------------------- the workspace, pending and counted
  perform tests.assert_eq('...a due date more than two years away is refused', tests.q(gus, g_e, format($q$public.hire_item_add(%L, %L, 'task', 'First task', null, current_date + 731)$q$, p_grp, hq)), 'ERROR: Choose a due date from today to two years from now.');
  perform tests.assert_eq('...a title of 121 characters is refused', tests.q(gus, g_e, format($q$public.hire_item_add(%L, %L, 'task', %L, null, null)$q$, p_grp, hq, repeat('t', 121))), 'ERROR: Give it a title of 2 to 120 characters.');
  it1 := (tests.f(gus, g_e, format($q$public.hire_item_add(%L, %L, 'task', 'First task', null, null)$q$, p_grp, hq), '{id}'))::uuid;
  it2 := (tests.f(olly, o_e, format($q$public.hire_item_add(%L, %L, 'task', 'Second task', null, null)$q$, p_club2, hq), '{id}'))::uuid;
  perform tests.assert_eq('...two of them', tests.q(gus, g_e, format($q$(select string_agg(x, '|') from jsonb_array_elements_text(public.hire_workspace(%L, %L) -> 'pending') x where x like '%%open task%%')$q$, p_grp, hq)), '2 open tasks.');
  perform tests.q(gus, g_e, format($q$public.hire_item_set(%L, %L, null, true)$q$, p_grp, it1));
  perform tests.assert_eq('...a ticked-off one is not counted', tests.q(gus, g_e, format($q$(select string_agg(x, '|') from jsonb_array_elements_text(public.hire_workspace(%L, %L) -> 'pending') x where x like '%%open task%%')$q$, p_grp, hq)), '1 open task.');
  perform tests.assert_eq('a banned word in a new title is refused', tests.q(gus, g_e, format($q$public.hire_item_set(%L, %L, 'a forbiddenword title', null)$q$, p_grp, it1)), 'ERROR: That wording is not allowed here.');
  perform tests.assert_eq('a stranger at another venue cannot remove an item', tests.q(olly, o_e, format($q$public.hire_item_remove(%L, %L)$q$, p_club, it2)), 'ERROR: This item is not available.');
  perform tests.assert_eq('...nor tick one', tests.q(olly, o_e, format($q$public.hire_item_set(%L, %L, null, true)$q$, p_club, it2)), 'ERROR: This item is not available.');
  perform tests.assert_eq('an unknown item is not found', tests.q(gus, g_e, format($q$public.hire_item_remove(%L, gen_random_uuid())$q$, p_grp)), 'ERROR: This item is not available.');
  update public.site_hires set status = 'cancelled' where id = hq;
  perform tests.assert_eq('a cancelled hire''s items can no longer be changed', tests.q(gus, g_e, format($q$public.hire_item_set(%L, %L, null, true)$q$, p_grp, it2)), 'ERROR: The workspace opens once the hire is agreed.');
  update public.site_hires set status = 'confirmed' where id = hq;

  ---------------------------------------------------------------- the events that could be linked, and linking
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Draft night', 'Not out yet', 'Annex', ((d1 + 100) + time '21:00') at time zone 'UTC', org_g, vb, 'draft') returning id into ev5;
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Venue not set', 'No venue yet', 'TBA', ((d1 + 100) + time '21:00') at time zone 'UTC', org_g, null, 'published') returning id into ev6;
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Day before', 'The night before', 'Annex', ((d1 + 99) + time '21:00') at time zone 'UTC', org_g, vb, 'published') returning id into ev7;
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Day after', 'The night after', 'Annex', ((d1 + 101) + time '21:00') at time zone 'UTC', org_g, vb, 'published') returning id into ev8;
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Two days off', 'Too far from the day', 'Annex', ((d1 + 102) + time '21:00') at time zone 'UTC', org_g, vb, 'published') returning id into ev9;
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Nobody''s night', 'No business behind it', 'Annex', ((d1 + 100) + time '21:00') at time zone 'UTC', null, vb, 'published') returning id into ev10;
  -- 02:00 UTC on the third day is 10pm on the second at the club (Toronto): the day is the club's, not the database's
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Late night', 'Ends after midnight in London', 'Annex', ((d1 + 102) + time '02:00') at time zone 'UTC', org_g, vb, 'published') returning id into ev11;
  insert into public.site_events (title, description, venue_name, start_date, org_id, venue_id, status) values ('Two days before', 'Too far from the day', 'Annex', ((d1 + 98) + time '21:00') at time zone 'UTC', org_g, vb, 'published') returning id into ev12;
  perform tests.assert_eq('the events offered are the group''s own published ones, at the annex or nowhere yet, within a day', tests.q(gus, g_e, format($q$(select string_agg(x ->> 'title', ',' order by x ->> 'title') from jsonb_array_elements(public.hire_events_linkable(%L, %L)) x)$q$, p_grp, hq)), 'Day after,Day before,Late night,Venue not set');
  perform tests.assert_eq('an event on the day before can be linked', tests.f(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, hq, ev7), '{event_id}'), ev7::text);
  perform tests.assert_eq('...and one on the day after', tests.f(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, hq, ev8), '{event_id}'), ev8::text);
  perform tests.assert_eq('...a late night counts on the club''s day', tests.f(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, hq, ev11), '{event_id}'), ev11::text);
  perform tests.assert_eq('...two days before cannot', tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, hq, ev12)), 'ERROR: That event is on a different day.');
  perform tests.assert_eq('...two days off cannot', tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, hq, ev9)), 'ERROR: That event is on a different day.');
  perform tests.assert_eq('...an event with no venue yet can', tests.f(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, hq, ev6), '{event_id}'), ev6::text);
  perform tests.assert_eq('...an event no business runs cannot', tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, hq, ev10)), 'ERROR: You can only link an event your own business runs.');
  perform tests.assert_eq('...what is linked is still offered for this hire', tests.q(gus, g_e, format($q$(select count(*) from jsonb_array_elements(public.hire_events_linkable(%L, %L)) x where x ->> 'id' = %L)$q$, p_grp, hq, ev6)), '1');
  update public.site_hires set status = 'agreed', event_id = ev8 where id = hy;
  perform tests.assert_eq('an event kept by another agreed hire is not offered again', tests.q(gus, g_e, format($q$(select count(*) from jsonb_array_elements(public.hire_events_linkable(%L, %L)) x where x ->> 'id' = %L)$q$, p_grp, hq, ev8)), '0');
  update public.site_hires set status = 'confirmed' where id = hy;
  perform tests.assert_eq('...nor one kept by a confirmed hire', tests.q(gus, g_e, format($q$(select count(*) from jsonb_array_elements(public.hire_events_linkable(%L, %L)) x where x ->> 'id' = %L)$q$, p_grp, hq, ev8)), '0');
  update public.site_hires set status = 'cancelled' where id = hy;
  perform tests.assert_eq('...but one a cancelled hire let go is offered again', tests.q(gus, g_e, format($q$(select count(*) from jsonb_array_elements(public.hire_events_linkable(%L, %L)) x where x ->> 'id' = %L)$q$, p_grp, hq, ev8)), '1');
  update public.site_hires set status = 'agreed' where id = hq;
  perform tests.assert_eq('an event cannot be linked before the venue confirms', tests.q(gus, g_e, format($q$public.hire_link_event(%L, %L, %L)$q$, p_grp, hq, ev7)), 'ERROR: Link an event once the venue has confirmed the date.');
  update public.site_hires set status = 'confirmed' where id = hq;
  perform tests.assert_eq('a stranger at another venue cannot unlink it', tests.q(olly, o_e, format($q$public.hire_unlink_event(%L, %L)$q$, p_club, hq)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('...nor detach a booking', tests.q(olly, o_e, format($q$public.hire_detach_booking(%L, %L, %L)$q$, p_club, hq, bk3)), 'ERROR: This hire is not available.');
  perform tests.assert_eq('events linked to another live hire are not offered again', tests.q(gus, g_e, format($q$(select count(*) from jsonb_array_elements(public.hire_events_linkable(%L, %L)) x where x ->> 'id' = %L)$q$, p_grp, h1, ev1)), '1');
  update public.site_hires set status = 'confirmed', event_id = ev1 where id = h1;
  perform tests.assert_eq('...an event already linked to a confirmed hire is taken', tests.q(gus, g_e, format($q$(select count(*) from jsonb_array_elements(public.hire_events_linkable(%L, %L)) x where x ->> 'id' = %L)$q$, p_grp, hq, ev1)), '0');

  ---------------------------------------------------------------- every table is closed
  perform tests.login(gus, g_e);
  perform tests.assert_raises('no table can be read', 'select * from public.site_hires', 'permission denied');
  perform tests.assert_raises('...or the offers', 'select * from public.site_hire_offers', 'permission denied');
  perform tests.assert_raises('...or the items', 'select * from public.site_hire_items', 'permission denied');
  perform tests.assert_raises('...or the attached bookings', 'select * from public.site_hire_bookings', 'permission denied');
  perform tests.assert_raises('...or the chat links', 'select * from public.site_chat_links', 'permission denied');
  perform tests.assert_raises('...or the teams', 'select * from public.site_profile_team', 'permission denied');
  perform tests.assert_raises('...or written to', 'insert into public.site_profile_team (profile, member, role) values (gen_random_uuid(), gen_random_uuid(), ''manager'')', 'permission denied');
  perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot list the invitations', 'select public.team_invitations_mine()', 'permission denied');
  perform tests.logout();
  perform tests.login(gus, g_e);
  perform tests.assert_raises('the helpers are not callable', format($q$select public.chat_link_join(gen_random_uuid(), %L)$q$, p_grp), 'permission denied');
  perform tests.assert_raises('...nor the check that teams are open', 'select public.team_require_on()', 'permission denied');
  perform tests.assert_raises('...nor which side of a hire a profile is', format($q$select public.hire_side(%L, %L)$q$, p_grp, h1), 'permission denied');
  perform tests.assert_raises('...nor the state of a hire', format($q$select public.hire_state(%L)$q$, h1), 'permission denied');
  perform tests.logout();
end $$;

rollback;
