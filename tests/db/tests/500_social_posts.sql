-- Posts, reels, stories, comments, likes, saves and Members Only. What matters most: who may see a post is worked out from the viewer's CURRENT standing
-- (follow someone or stop, go on or off a Members Only list, get blocked: the next read reflects it); a post a person may not see is absent, not locked; the
-- media files are as private as the posts; nobody posts before accepting the community rules or while the feature is off; limits and refusals say a plain
-- sentence; a retried like or save is one; deleting an account removes its posts, comments and lists.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
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
-- One value out of a json answer.
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
-- A named field of every element of a json list, in order, joined with commas.
create function tests.names(p_user uuid, p_email text, p_expr text, p_field text default 'caption') returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute 'select coalesce(string_agg(e ->> $1, '','' order by ord), ''(none)'') from jsonb_array_elements(' || p_expr || ') with ordinality as t(e, ord)' into r using p_field;
  perform tests.logout();
  return r;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
-- Puts a file in the bucket, as the app would before making a post. Returns its path.
create function tests.upload(p_profile uuid, p_name text, p_mime text default 'image/jpeg', p_size bigint default 200000, p_age interval default '0 seconds') returns text language plpgsql as $$
declare path text := p_profile::text || '/' || p_name;
begin
  perform tests.logout();
  insert into storage.objects (bucket_id, name, metadata, created_at) values ('social-media', path, jsonb_build_object('size', p_size, 'mimetype', p_mime), now() - p_age);
  return path;
end $$;
-- A one-photo post (or a one-video reel, or a story) by a profile, with a fresh file. Returns the post id, or 'ERROR: ...'.
create function tests.mk(p_user uuid, p_email text, p_actor uuid, p_kind text, p_aud text, p_caption text default 'hello', p_tags jsonb default '[]') returns text language plpgsql as $$
declare path text; media jsonb; id text;
begin
  path := tests.upload(p_actor, 'f' || replace(gen_random_uuid()::text, '-', '') || case when p_kind = 'reel' then '.mp4' else '.jpg' end,
                       case when p_kind = 'reel' then 'video/mp4' else 'image/jpeg' end);
  media := case when p_kind = 'reel'
                then jsonb_build_array(jsonb_build_object('path', path, 'type', 'video', 'duration_ms', 15000, 'width', 720, 'height', 1280))
                else jsonb_build_array(jsonb_build_object('path', path, 'type', 'image', 'width', 1080, 'height', 1350)) end;
  perform tests.login(p_user, p_email);
  id := (public.post_create(p_actor, p_kind, p_caption, p_aud, media, p_tags)) ->> 'id';
  perform tests.logout();
  return id;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  ann constant uuid := '00000000-0000-0000-0000-0000000005a1';   -- an author with a public profile
  bob constant uuid := '00000000-0000-0000-0000-0000000005a2';   -- follows ann
  cy constant uuid := '00000000-0000-0000-0000-0000000005a3';    -- follows nobody
  dee constant uuid := '00000000-0000-0000-0000-0000000005a4';   -- follows ann, gets blocked by her
  eve constant uuid := '00000000-0000-0000-0000-0000000005a5';   -- a private profile
  olly constant uuid := '00000000-0000-0000-0000-0000000005a6';  -- owns a club
  mia constant uuid := '00000000-0000-0000-0000-0000000005a7';   -- manages the club
  a_e constant text := 'ann@posts.example'; b_e constant text := 'bob@posts.example'; c_e constant text := 'cy@posts.example';
  d_e constant text := 'dee@posts.example'; e_e constant text := 'eve@posts.example'; o_e constant text := 'olly@posts.example'; m_e constant text := 'mia@posts.example';
  p_ann uuid; p_bob uuid; p_cy uuid; p_dee uuid; p_eve uuid; p_olly uuid; p_mia uuid; p_dj uuid; p_club uuid;
  org uuid; venue uuid; venue2 uuid; ev uuid; ev_draft uuid;
  path text; media jsonb; txt text; n int; c1 text; c2 text; c3 text;
  post1 text; post2 text; post3 text; post_f text; post_m text; reel1 text; story1 text; story_m text; post_eve text;
begin
  insert into auth.users (id, email) values (ann, a_e), (bob, b_e), (cy, c_e), (dee, d_e), (eve, e_e), (olly, o_e), (mia, m_e);
  insert into public.profiles (id, name, email) values
    (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (cy, 'Cy Rus', c_e), (dee, 'Dee Dee', d_e), (eve, 'Eve Ng', e_e), (olly, 'Olly Owner', o_e), (mia, 'Mia Manager', m_e);
  perform tests.login(admin_u, 'admin@test.example');
  perform public.cms_set_feature('social', true);
  perform tests.logout();
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'ann', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bob', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(cy, c_e); perform public.save_my_profile('Cy Rus', 'cyrus', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(dee, d_e); perform public.save_my_profile('Dee Dee', 'dee', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(eve, e_e); perform public.save_my_profile('Eve Ng', 'eve', 'Toronto'); perform public.profile_save_personal('private');
  perform tests.login(olly, o_e); perform public.save_my_profile('Olly Owner', 'olly', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(mia, m_e); perform public.save_my_profile('Mia Manager', 'mia', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.logout();
  select id into p_ann from public.site_profiles where user_id = ann; select id into p_bob from public.site_profiles where user_id = bob;
  select id into p_cy from public.site_profiles where user_id = cy; select id into p_dee from public.site_profiles where user_id = dee;
  select id into p_eve from public.site_profiles where user_id = eve; select id into p_olly from public.site_profiles where user_id = olly;
  select id into p_mia from public.site_profiles where user_id = mia;
  perform tests.q(ann, a_e, $q$public.profile_create_business('dj', 'DJ Ann', 'djann')$q$);
  select id into p_dj from public.site_profiles where handle = 'djann';

  -- a club with a published venue and event, a draft event, an unpublished venue
  perform tests.login(olly, o_e);
  org := public.create_organization('Club Co', 'venue_owner');
  venue := public.create_org_venue(org, 'Club A');
  venue2 := public.create_org_venue(org, 'Club B');
  perform tests.join_as(olly, o_e, org, m_e, 'manager', venue, mia);
  perform tests.logout();
  update public.site_venues set status = 'published' where id = venue;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Friday Night', 'x', 'Club A', now() + interval '3 days', now() + interval '3 days 6 hours', 'published', org) returning id into ev;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Secret Night', 'x', 'Club A', now() + interval '5 days', now() + interval '5 days 6 hours', 'draft', org) returning id into ev_draft;
  perform tests.q(olly, o_e, format($q$public.profile_create_business('venue', 'Club A', 'clubaclub', null, null, null, %L)$q$, venue));
  select id into p_club from public.site_profiles where venue_id = venue;

  -- bob and dee follow ann; bob follows eve (approved)
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann));
  perform tests.q(dee, d_e, format($q$public.follow_set(%L, %L, true)$q$, p_dee, p_ann));
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_eve));
  perform tests.q(eve, e_e, format($q$public.follow_respond(%L, %L, 'accept')$q$, p_eve, p_bob));

  ---------------------------------------------------------------- the community rules and the switches
  perform tests.assert_eq('the rules are not accepted at first', tests.f(ann, a_e, 'public.rules_status()', '{accepted}'), 'false');
  perform tests.assert_eq('...the current version is 1', tests.f(ann, a_e, 'public.rules_status()', '{version}'), '1');
  perform tests.assert_eq('nobody posts before accepting them', tests.mk(ann, a_e, p_ann, 'post', 'public'), 'ERROR: Read and accept the community rules first.');
  perform tests.assert_eq('nobody comments before accepting them either', tests.q(bob, b_e, format($q$public.comment_add(%L, %L, 'hi')$q$, p_bob, gen_random_uuid())), 'ERROR: Read and accept the community rules first.');
  perform tests.assert_eq('an old or made-up version is refused', tests.q(ann, a_e, 'public.rules_accept(7)'), 'ERROR: The community rules have changed. Read them again.');
  perform tests.assert_eq('accepting', tests.f(ann, a_e, 'public.rules_accept(1)', '{accepted}'), 'true');
  perform tests.assert_eq('...twice is the same as once', tests.f(ann, a_e, 'public.rules_accept(1)', '{accepted}'), 'true');
  perform tests.logout();
  perform tests.assert_eq('...one row', (select count(*) from public.site_rules_acceptance where user_id = ann)::int, 1);
  perform tests.q(bob, b_e, 'public.rules_accept(1)'); perform tests.q(cy, c_e, 'public.rules_accept(1)'); perform tests.q(dee, d_e, 'public.rules_accept(1)');
  perform tests.q(eve, e_e, 'public.rules_accept(1)'); perform tests.q(olly, o_e, 'public.rules_accept(1)'); perform tests.q(mia, m_e, 'public.rules_accept(1)');

  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('social', false); perform tests.logout();
  perform tests.assert_eq('with social off nothing can be posted', tests.mk(ann, a_e, p_ann, 'post', 'public'), 'ERROR: Posting is not open yet.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('social', true); perform tests.logout();
  perform tests.assert_eq('a reel is refused while reels are off', tests.mk(ann, a_e, p_ann, 'reel', 'public'), 'ERROR: Reels are not open yet.');
  perform tests.assert_eq('a story is refused while stories are off', tests.mk(ann, a_e, p_ann, 'story', 'public'), 'ERROR: Stories are not open yet.');
  perform tests.assert_eq('Members Only is refused while it is off', tests.mk(ann, a_e, p_ann, 'post', 'members'), 'ERROR: Members Only is not open yet.');
  perform tests.assert_eq('a plain post works with just social on', tests.f(ann, a_e, 'null::jsonb', '{x}'), '(null)');
  perform tests.login(admin_u, 'admin@test.example');
  perform public.cms_set_feature('reels', true); perform public.cms_set_feature('stories', true); perform public.cms_set_feature('members_only', true);
  perform tests.logout();

  ---------------------------------------------------------------- making a post: what is checked
  perform tests.assert_eq('a first photo post', tests.f(ann, a_e, format($q$public.post_create(%L, 'post', 'Friday vibes', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image', 'width', 1080, 'height', 1350)))$q$, p_ann, tests.upload(p_ann, 'first.jpg')), '{caption}'), 'Friday vibes');
  select id::text into post1 from public.site_posts where caption = 'Friday vibes';
  perform tests.assert_eq('its card has the author', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1::uuid), '{author,handle}'), 'ann');
  perform tests.assert_eq('...the photo with its path and size', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1::uuid), '{media,0,path}'), p_ann::text || '/first.jpg');
  perform tests.assert_eq('...and no likes yet', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1::uuid), '{likes}'), '0');

  perform tests.assert_eq('a post needs a photo', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', '[]'::jsonb)$q$, p_ann)), 'ERROR: Add a photo or a video.');
  perform tests.assert_eq('...and a list, not nothing', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', null)$q$, p_ann)), 'ERROR: Add a photo or a video.');
  perform tests.assert_eq('a made-up kind is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'video', 'x', 'public', '[]'::jsonb)$q$, p_ann)), 'ERROR: Choose post, reel or story.');
  perform tests.assert_eq('a made-up audience is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'friends', '[]'::jsonb)$q$, p_ann)), 'ERROR: Choose who can see this.');
  perform tests.assert_eq('a caption of 2201 characters is refused', tests.mk(ann, a_e, p_ann, 'post', 'public', repeat('a', 2201)), 'ERROR: The caption can be 2200 characters at most.');
  perform tests.assert_eq('...2200 is fine', (tests.mk(ann, a_e, p_ann, 'post', 'public', repeat('a', 2200))) ~ '^[0-9a-f-]{36}$', true);
  perform tests.assert_eq('you cannot post as someone else', tests.q(bob, b_e, format($q$public.post_create(%L, 'post', 'x', 'public', '[]'::jsonb)$q$, p_ann)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a missing sign-in is refused', tests.q(ann, a_e, format($q$public.post_create(null, 'post', 'x', 'public', '[]'::jsonb)$q$)), 'ERROR: You cannot act as this profile.');

  -- the files
  path := tests.upload(p_ann, 'big.jpg', 'image/jpeg', 10485761);
  perform tests.assert_eq('a photo over 10 MB is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image')))$q$, p_ann, path)), 'ERROR: A photo can be 10 MB at most.');
  path := tests.upload(p_ann, 'exact.jpg', 'image/jpeg', 10485760);
  perform tests.assert_eq('...exactly 10 MB is fine', tests.q(ann, a_e, format($q$(public.post_create(%L, 'post', 'x', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image')))) ->> 'kind'$q$, p_ann, path)), 'post');
  path := tests.upload(p_ann, 'doc.pdf', 'application/pdf', 1000);
  perform tests.assert_eq('a file that is not a photo is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image')))$q$, p_ann, path)), 'ERROR: Something is wrong with that photo.');
  perform tests.assert_eq('a file that was never uploaded is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image')))$q$, p_ann, p_ann::text || '/nothing.jpg')), 'ERROR: That photo or video did not finish uploading. Try again.');
  path := tests.upload(p_bob, 'bobs.jpg');
  perform tests.assert_eq('a file in someone else''s folder is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image')))$q$, p_ann, path)), 'ERROR: Something is wrong with that photo or video.');
  perform tests.assert_eq('a path that is not of the right shape is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', jsonb_build_array(jsonb_build_object('path', '../../etc/passwd', 'type', 'image')))$q$, p_ann)), 'ERROR: Something is wrong with that photo or video.');
  perform tests.assert_eq('a made-up media type is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'audio')))$q$, p_ann, tests.upload(p_ann, 'a.mp3'))), 'ERROR: Something is wrong with that photo or video.');
  perform tests.assert_eq('a file already in a post cannot be used again', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image')))$q$, p_ann, p_ann::text || '/first.jpg')), 'ERROR: That photo or video is already in a post.');
  perform tests.assert_eq('...and the failed attempt left no half-made post', (select count(*) from public.site_posts where caption = 'x')::int, 1);

  -- shapes: post 1 to 10 photos, reel one video, story one thing
  media := (select jsonb_agg(jsonb_build_object('path', tests.upload(p_ann, 'many' || g || '.jpg'), 'type', 'image')) from generate_series(1, 10) g);
  perform tests.assert_eq('ten photos make one post', tests.q(ann, a_e, format($q$jsonb_array_length((public.post_create(%L, 'post', 'ten', 'public', %L::jsonb)) -> 'media')$q$, p_ann, media)), '10');
  media := (select jsonb_agg(jsonb_build_object('path', tests.upload(p_ann, 'toomany' || g || '.jpg'), 'type', 'image')) from generate_series(1, 11) g);
  perform tests.assert_eq('eleven are too many', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'eleven', 'public', %L::jsonb)$q$, p_ann, media)), 'ERROR: You can add up to 10 photos.');
  select id::text into post3 from public.site_posts where caption = 'ten';
  perform tests.assert_eq('the photos keep their order', tests.q(ann, a_e, format($q$(select string_agg(m ->> 'path', ',' order by (m ->> 'position')::int) from jsonb_array_elements((public.post_get(%L, %L)) -> 'media') m)$q$, p_ann, post3::uuid)), (select string_agg(p_ann::text || '/many' || g || '.jpg', ',' order by g) from generate_series(1, 10) g));
  perform tests.assert_eq('a video does not go in a post', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'v', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 5000)))$q$, p_ann, tests.upload(p_ann, 'v1.mp4', 'video/mp4'))), 'ERROR: A post is 1 to 10 photos. Use a reel for a video.');
  perform tests.assert_eq('a reel is one video', tests.f(ann, a_e, format($q$public.post_create(%L, 'reel', 'my reel', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 59000, 'width', 720, 'height', 1280)))$q$, p_ann, tests.upload(p_ann, 'v2.mp4', 'video/mp4', 50000000)), '{media,0,duration_ms}'), '59000');
  perform tests.assert_eq('a reel of a photo is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'reel', 'r', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image')))$q$, p_ann, tests.upload(p_ann, 'p9.jpg'))), 'ERROR: A reel is one video.');
  perform tests.assert_eq('a reel of two videos is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'reel', 'r', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 5000), jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 5000)))$q$, p_ann, tests.upload(p_ann, 'two1.mp4', 'video/mp4'), tests.upload(p_ann, 'two2.mp4', 'video/mp4'))), 'ERROR: A reel is one video.');
  perform tests.assert_eq('...nor a video with a photo', tests.q(ann, a_e, format($q$public.post_create(%L, 'reel', 'r', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 5000), jsonb_build_object('path', %L, 'type', 'image')))$q$, p_ann, tests.upload(p_ann, 'mix1.mp4', 'video/mp4'), tests.upload(p_ann, 'mix1.jpg'))), 'ERROR: A reel is one video.');
  perform tests.assert_eq('a post with a photo and a video is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'post', 'x', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image'), jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 5000)))$q$, p_ann, tests.upload(p_ann, 'mix2.jpg'), tests.upload(p_ann, 'mix2.mp4', 'video/mp4'))), 'ERROR: A post is 1 to 10 photos. Use a reel for a video.');
  perform tests.assert_eq('a video must say how long it is', tests.q(ann, a_e, format($q$public.post_create(%L, 'reel', 'r', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video')))$q$, p_ann, tests.upload(p_ann, 'v3.mp4', 'video/mp4'))), 'ERROR: A video can be up to 60 seconds.');
  perform tests.assert_eq('...and at most 60 seconds', tests.q(ann, a_e, format($q$public.post_create(%L, 'reel', 'r', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 60001)))$q$, p_ann, tests.upload(p_ann, 'v4.mp4', 'video/mp4'))), 'ERROR: A video can be up to 60 seconds.');
  perform tests.assert_eq('a video over 100 MB is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'reel', 'r', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 5000)))$q$, p_ann, tests.upload(p_ann, 'v5.mp4', 'video/mp4', 104857601))), 'ERROR: A video can be 100 MB at most.');
  perform tests.assert_eq('a video that is really a photo is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'reel', 'r', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 5000)))$q$, p_ann, tests.upload(p_ann, 'v6.mp4', 'image/png'))), 'ERROR: Something is wrong with that video.');
  perform tests.assert_eq('a video may have a poster picture', tests.f(ann, a_e, format($q$public.post_create(%L, 'reel', 'with poster', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 5000, 'poster_path', %L)))$q$, p_ann, tests.upload(p_ann, 'v7.mp4', 'video/mp4'), tests.upload(p_ann, 'v7.jpg')), '{media,0,poster_path}'), p_ann::text || '/v7.jpg');
  perform tests.assert_eq('...which must be a picture of the same profile''s', tests.q(ann, a_e, format($q$public.post_create(%L, 'reel', 'r', 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'video', 'duration_ms', 5000, 'poster_path', %L)))$q$, p_ann, tests.upload(p_ann, 'v8.mp4', 'video/mp4'), tests.upload(p_bob, 'v8.jpg'))), 'ERROR: Something is wrong with that video.');
  perform tests.assert_eq('a story is one photo', tests.f(ann, a_e, format($q$public.post_create(%L, 'story', null, 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image')))$q$, p_ann, tests.upload(p_ann, 's1.jpg')), '{kind}'), 'story');
  perform tests.assert_eq('...that expires in a day', tests.f(ann, a_e, format($q$public.post_get(%L, %L)$q$, p_ann, (select id from public.site_posts where kind = 'story' order by created_at desc limit 1)), '{expires_at}') <> '(null)', true);
  perform tests.assert_eq('a story of two things is refused', tests.q(ann, a_e, format($q$public.post_create(%L, 'story', null, 'public', jsonb_build_array(jsonb_build_object('path', %L, 'type', 'image'), jsonb_build_object('path', %L, 'type', 'image')))$q$, p_ann, tests.upload(p_ann, 's2.jpg'), tests.upload(p_ann, 's3.jpg'))), 'ERROR: A story is one photo or one video.');

  -- tags
  post2 := tests.mk(ann, a_e, p_ann, 'post', 'public', 'tagged', jsonb_build_array(jsonb_build_object('kind', 'profile', 'id', p_bob), jsonb_build_object('kind', 'event', 'id', ev), jsonb_build_object('kind', 'venue', 'id', venue)));
  perform tests.assert_eq('a post can tag a person, an event and a venue', (post2 ~ '^[0-9a-f-]{36}$'), true);
  perform tests.assert_eq('...all three show on it', tests.q(cy, c_e, format($q$jsonb_array_length((public.post_get(%L, %L)) -> 'tags')$q$, p_cy, post2::uuid)), '3');
  perform tests.assert_eq('...the event by its title', tests.q(cy, c_e, format($q$(select t ->> 'name' from jsonb_array_elements((public.post_get(%L, %L)) -> 'tags') t where t ->> 'kind' = 'event')$q$, p_cy, post2::uuid)), 'Friday Night');
  update public.site_events set status = 'draft' where id = ev;
  perform tests.assert_eq('an event that is taken down disappears from the tags', tests.q(cy, c_e, format($q$jsonb_array_length((public.post_get(%L, %L)) -> 'tags')$q$, p_cy, post2::uuid)), '2');
  update public.site_events set status = 'published' where id = ev;
  perform tests.assert_eq('you cannot tag yourself', tests.mk(ann, a_e, p_ann, 'post', 'public', 'x', jsonb_build_array(jsonb_build_object('kind', 'profile', 'id', p_ann))), 'ERROR: You cannot tag that profile.');
  perform tests.assert_eq('...nor your own other profile', tests.mk(ann, a_e, p_ann, 'post', 'public', 'x', jsonb_build_array(jsonb_build_object('kind', 'profile', 'id', p_dj))), 'ERROR: You cannot tag that profile.');
  perform tests.assert_eq('a draft event cannot be tagged', tests.mk(ann, a_e, p_ann, 'post', 'public', 'x', jsonb_build_array(jsonb_build_object('kind', 'event', 'id', ev_draft))), 'ERROR: You cannot tag that event.');
  perform tests.assert_eq('an unpublished venue cannot be tagged', tests.mk(ann, a_e, p_ann, 'post', 'public', 'x', jsonb_build_array(jsonb_build_object('kind', 'venue', 'id', venue2))), 'ERROR: You cannot tag that venue.');
  perform tests.assert_eq('the same tag twice is refused', tests.mk(ann, a_e, p_ann, 'post', 'public', 'x', jsonb_build_array(jsonb_build_object('kind', 'event', 'id', ev), jsonb_build_object('kind', 'event', 'id', ev))), 'ERROR: You tagged the same one twice.');
  perform tests.assert_eq('a made-up tag is refused', tests.mk(ann, a_e, p_ann, 'post', 'public', 'x', jsonb_build_array(jsonb_build_object('kind', 'mood', 'id', ev))), 'ERROR: Something is wrong with the tags.');
  perform tests.assert_eq('a tag with no valid id is refused', tests.mk(ann, a_e, p_ann, 'post', 'public', 'x', jsonb_build_array(jsonb_build_object('kind', 'event', 'id', 'nope'))), 'ERROR: Something is wrong with the tags.');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, true)$q$, p_ann, p_dee));
  perform tests.assert_eq('someone you blocked cannot be tagged', tests.mk(ann, a_e, p_ann, 'post', 'public', 'x', jsonb_build_array(jsonb_build_object('kind', 'profile', 'id', p_dee))), 'ERROR: You cannot tag that profile.');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, false)$q$, p_ann, p_dee));
  perform tests.q(dee, d_e, format($q$public.follow_set(%L, %L, true)$q$, p_dee, p_ann));
  perform tests.assert_eq('eleven tags are too many', tests.mk(ann, a_e, p_ann, 'post', 'public', 'x', (select jsonb_agg(jsonb_build_object('kind', 'profile', 'id', gen_random_uuid())) from generate_series(1, 11))), 'ERROR: You can tag up to 10.');
  perform tests.assert_eq('a tagged profile can take its tag off', tests.f(bob, b_e, format($q$public.post_untag(%L, %L)$q$, p_bob, post2::uuid), '{untagged}'), 'true');
  perform tests.assert_eq('...and it is gone', tests.q(cy, c_e, format($q$jsonb_array_length((public.post_get(%L, %L)) -> 'tags')$q$, p_cy, post2::uuid)), '2');

  -- words and speed
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_banned_term('badword', true); perform tests.logout();
  perform tests.assert_eq('a banned word in a caption is refused', tests.mk(ann, a_e, p_ann, 'post', 'public', 'what a BADWORD this is'), 'ERROR: That text goes against our community rules.');
  perform tests.assert_eq('...but a longer word that contains it is not', (tests.mk(ann, a_e, p_ann, 'post', 'public', 'badwords are fine here') ~ '^[0-9a-f-]{36}$'), true);
  select count(*) into n from public.site_posts where author = p_ann and created_at > now() - interval '1 hour';
  insert into public.site_posts (author, kind, caption) select p_ann, 'post', 'filler' from generate_series(1, 19 - n);
  perform tests.assert_eq('with 19 posts in the hour the 20th is fine', (tests.mk(ann, a_e, p_ann, 'post', 'public', 'the twentieth') ~ '^[0-9a-f-]{36}$'), true);
  perform tests.assert_eq('...and the 21st is slowed with a plain sentence', tests.mk(ann, a_e, p_ann, 'post', 'public', 'one too many'), 'ERROR: You are posting too quickly. Try again later.');
  perform tests.assert_eq('...other people are not slowed', (tests.mk(bob, b_e, p_bob, 'post', 'public', 'bob posts') ~ '^[0-9a-f-]{36}$'), true);
  delete from public.site_posts where author in (p_ann, p_bob);

  ---------------------------------------------------------------- who sees a post
  post1 := tests.mk(ann, a_e, p_ann, 'post', 'public', 'p-public');
  post_f := tests.mk(ann, a_e, p_ann, 'post', 'followers', 'p-followers');
  post_m := tests.mk(ann, a_e, p_ann, 'post', 'members', 'p-members');
  reel1 := tests.mk(ann, a_e, p_ann, 'reel', 'public', 'p-reel');
  post_eve := tests.mk(eve, e_e, p_eve, 'post', 'public', 'p-eve');
  perform tests.assert_eq('the author sees all her own', tests.names(ann, a_e, format($q$jsonb_build_array(public.post_get(%L, %L), public.post_get(%L, %L), public.post_get(%L, %L))$q$, p_ann, post1::uuid, p_ann, post_f::uuid, p_ann, post_m::uuid)), 'p-public,p-followers,p-members');
  perform tests.assert_eq('a stranger sees the public post', tests.f(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post1::uuid), '{caption}'), 'p-public');
  perform tests.assert_eq('...and the public reel', tests.f(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, reel1::uuid), '{kind}'), 'reel');
  perform tests.assert_eq('...but not the post for followers', tests.q(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post_f::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...nor the Members Only one, which looks like any post that does not exist', tests.q(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post_m::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('a post that does not exist reads the same', tests.q(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, gen_random_uuid())), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('a follower sees the followers'' post', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_f::uuid), '{caption}'), 'p-followers');
  perform tests.assert_eq('...but not the Members Only one until put on the list', tests.q(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_m::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('adding a member who follows', tests.f(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_bob), '{members}'), '1');
  perform tests.assert_eq('...opens it at once', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_m::uuid), '{caption}'), 'p-members');
  perform tests.assert_eq('another follower who is not a member still cannot', tests.q(dee, d_e, format($q$public.post_get(%L, %L)$q$, p_dee, post_m::uuid)), 'ERROR: This post isn''t available.');
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, false)$q$, p_bob, p_ann));
  perform tests.assert_eq('a member who stops following loses the Members Only post', tests.q(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_m::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...and the followers'' one', tests.q(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_f::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...but still sees the public one', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1::uuid), '{caption}'), 'p-public');
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann));
  perform tests.assert_eq('following again brings both back (the list kept them)', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_m::uuid), '{caption}'), 'p-members');
  perform tests.q(ann, a_e, format($q$public.members_set(%L, %L, false)$q$, p_ann, p_bob));
  perform tests.assert_eq('taking a member off the list closes it at once', tests.q(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_m::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...and the followers'' post is still open to them', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_f::uuid), '{caption}'), 'p-followers');
  perform tests.q(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_bob));

  perform tests.assert_eq('a public post of a private profile is seen by its approved follower', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_eve::uuid), '{caption}'), 'p-eve');
  perform tests.assert_eq('...and not by anyone else', tests.q(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post_eve::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...even though its audience says public', (select audience from public.site_posts where id = post_eve::uuid), 'public');

  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, true)$q$, p_ann, p_dee));
  perform tests.assert_eq('someone who is blocked sees nothing of the blocker', tests.q(dee, d_e, format($q$public.post_get(%L, %L)$q$, p_dee, post1::uuid)), 'ERROR: This post isn''t available.');
  post3 := tests.mk(dee, d_e, p_dee, 'post', 'public', 'p-dee');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, false)$q$, p_ann, p_dee));
  perform tests.assert_eq('before the block ann sees what dee posted', tests.f(ann, a_e, format($q$public.post_get(%L, %L)$q$, p_ann, post3::uuid), '{caption}'), 'p-dee');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, true)$q$, p_ann, p_dee));
  perform tests.assert_eq('the blocker does not see the blocked one''s posts either', tests.q(ann, a_e, format($q$public.post_get(%L, %L)$q$, p_ann, post3::uuid)), 'ERROR: This post isn''t available.');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, false)$q$, p_ann, p_dee));
  perform tests.q(dee, d_e, format($q$public.follow_set(%L, %L, true)$q$, p_dee, p_ann));
  delete from public.site_posts where id = post3::uuid;

  update public.site_profiles set status = 'suspended' where id = p_ann;
  perform tests.assert_eq('a suspended author''s posts vanish for everyone else', tests.q(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post1::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...and a follower no longer sees her followers'' post either', tests.q(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_f::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...nor a member her Members Only one', tests.q(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post_m::uuid)), 'ERROR: This post isn''t available.');
  update public.site_profiles set status = 'active' where id = p_ann;
  update public.site_posts set status = 'removed' where id = post1::uuid;
  perform tests.assert_eq('a removed post vanishes, even for its author', tests.q(ann, a_e, format($q$public.post_get(%L, %L)$q$, p_ann, post1::uuid)), 'ERROR: This post isn''t available.');
  update public.site_posts set status = 'active' where id = post1::uuid;

  -- a business of the same person sees and shows the same
  post2 := tests.mk(ann, a_e, p_dj, 'post', 'public', 'p-dj');
  perform tests.assert_eq('a person posts as their business', tests.f(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post2::uuid), '{author,handle}'), 'djann');
  perform tests.assert_eq('...and sees it as their personal profile too', tests.f(ann, a_e, format($q$public.post_get(%L, %L)$q$, p_ann, post2::uuid), '{is_mine}'), 'true');
  perform tests.assert_eq('someone else''s profile is not theirs to post as', tests.mk(bob, b_e, p_dj, 'post', 'public'), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a club''s manager posts as the club', (tests.mk(mia, m_e, p_club, 'post', 'public', 'p-club') ~ '^[0-9a-f-]{36}$'), true);
  perform tests.assert_eq('...and so does its owner', (tests.mk(olly, o_e, p_club, 'post', 'followers', 'p-club-f') ~ '^[0-9a-f-]{36}$'), true);
  perform tests.logout();
  update public.site_memberships set status = 'revoked' where user_id = mia and org_id = org;
  perform tests.assert_eq('a revoked manager can no longer post as the club', tests.mk(mia, m_e, p_club, 'post', 'public', 'too late'), 'ERROR: You cannot act as this profile.');

  ---------------------------------------------------------------- stories
  story1 := tests.mk(ann, a_e, p_ann, 'story', 'public', 'story-public');
  story_m := tests.mk(ann, a_e, p_ann, 'story', 'members', 'story-members');
  perform tests.assert_eq('a stranger sees the public story only', tests.names(cy, c_e, format($q$public.stories_of(%L, %L)$q$, p_cy, p_ann)), 'story-public');
  perform tests.assert_eq('a member sees both, oldest first', tests.names(bob, b_e, format($q$public.stories_of(%L, %L)$q$, p_bob, p_ann)), 'story-public,story-members');
  perform tests.assert_eq('a follower who is not a member sees the public one', tests.names(dee, d_e, format($q$public.stories_of(%L, %L)$q$, p_dee, p_ann)), 'story-public');
  perform tests.assert_eq('the rail for a member shows ann, unseen, with the Members Only ring', tests.q(bob, b_e, format($q$(select (e -> 'profile' ->> 'handle') || '/' || (e ->> 'unseen') || '/' || (e ->> 'members_only') || '/' || (e ->> 'count') from jsonb_array_elements(public.story_rail(%L)) e)$q$, p_bob)), 'ann/true/true/2');
  perform tests.assert_eq('...for a follower who is not a member there is no ring', tests.q(dee, d_e, format($q$(select (e -> 'profile' ->> 'handle') || '/' || (e ->> 'members_only') || '/' || (e ->> 'count') from jsonb_array_elements(public.story_rail(%L)) e)$q$, p_dee)), 'ann/false/1');
  perform tests.assert_eq('...and someone who follows nobody has an empty rail', tests.q(cy, c_e, format($q$jsonb_array_length(public.story_rail(%L))$q$, p_cy)), '0');
  perform tests.assert_eq('the author''s own rail has her first, and it is hers', tests.q(ann, a_e, format($q$(select (e -> 'profile' ->> 'handle') || '/' || (e ->> 'is_mine') || '/' || (e ->> 'unseen') from jsonb_array_elements(public.story_rail(%L)) e)$q$, p_ann)), 'ann/true/false');
  perform tests.assert_eq('watching a story', tests.f(bob, b_e, format($q$public.story_seen(%L, %L)$q$, p_bob, story1::uuid), '{seen}'), 'true');
  perform tests.assert_eq('...watching it twice is the same', tests.f(bob, b_e, format($q$public.story_seen(%L, %L)$q$, p_bob, story1::uuid), '{seen}'), 'true');
  perform tests.assert_eq('the ring is still unseen while one story is unwatched', tests.q(bob, b_e, format($q$(select e ->> 'unseen' from jsonb_array_elements(public.story_rail(%L)) e)$q$, p_bob)), 'true');
  perform tests.q(bob, b_e, format($q$public.story_seen(%L, %L)$q$, p_bob, story_m::uuid));
  perform tests.assert_eq('...and goes grey when all are watched', tests.q(bob, b_e, format($q$(select e ->> 'unseen' from jsonb_array_elements(public.story_rail(%L)) e)$q$, p_bob)), 'false');
  perform tests.assert_eq('each story says whether it was seen', tests.q(bob, b_e, format($q$(select string_agg(e ->> 'seen', ',') from jsonb_array_elements(public.stories_of(%L, %L)) e)$q$, p_bob, p_ann)), 'true,true');
  perform tests.assert_eq('a story you may not see cannot be marked watched', tests.q(cy, c_e, format($q$public.story_seen(%L, %L)$q$, p_cy, story_m::uuid)), 'ERROR: This story isn''t available.');
  perform tests.assert_eq('only a story can be marked watched', tests.q(bob, b_e, format($q$public.story_seen(%L, %L)$q$, p_bob, post1::uuid)), 'ERROR: This story isn''t available.');
  perform tests.assert_eq('a story is not in the home feed', tests.names(bob, b_e, format($q$public.feed_home(%L, 40)$q$, p_bob)) like '%story%', false);
  perform tests.assert_eq('...nor on the profile grid', tests.names(bob, b_e, format($q$(public.profile_posts(%L, %L)) -> 'items'$q$, p_bob, p_ann)) like '%story%', false);
  perform tests.mk(dee, d_e, p_dee, 'story', 'public', 'story-dee');
  perform tests.assert_eq('in the rail one''s own story comes first, even when another has an unwatched one', tests.q(dee, d_e, format($q$(select string_agg(e -> 'profile' ->> 'handle', ',' order by ord) from jsonb_array_elements(public.story_rail(%L)) with ordinality t(e, ord))$q$, p_dee)), 'dee,ann');
  delete from public.site_posts where caption = 'story-dee';
  update public.site_posts set expires_at = now() - interval '1 minute' where id = story1::uuid;
  perform tests.assert_eq('an expired story cannot be opened by id, by a stranger', tests.q(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, story1::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...nor by its author', tests.q(ann, a_e, format($q$public.post_get(%L, %L)$q$, p_ann, story1::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('after 24 hours a story is gone, even for its author', tests.names(ann, a_e, format($q$public.stories_of(%L, %L)$q$, p_ann, p_ann)), 'story-members');
  perform tests.assert_eq('...and out of the rail count', tests.q(bob, b_e, format($q$(select e ->> 'count' from jsonb_array_elements(public.story_rail(%L)) e)$q$, p_bob)), '1');
  update public.site_posts set expires_at = now() - interval '1 minute' where id = story_m::uuid;
  perform tests.assert_eq('...and the rail is empty once none is left', tests.q(bob, b_e, format($q$jsonb_array_length(public.story_rail(%L))$q$, p_bob)), '0');
  delete from public.site_posts where kind = 'story';

  ---------------------------------------------------------------- the feeds and a profile's grid
  perform tests.assert_eq('bob''s home feed: whom he follows, newest first, only what he may see', tests.names(bob, b_e, format($q$public.feed_home(%L)$q$, p_bob)), 'p-eve,p-reel,p-members,p-followers,p-public');
  perform tests.assert_eq('dee follows ann and is not a member', tests.names(dee, d_e, format($q$public.feed_home(%L)$q$, p_dee)), 'p-reel,p-followers,p-public');
  perform tests.assert_eq('someone who follows nobody has an empty feed', tests.names(cy, c_e, format($q$public.feed_home(%L)$q$, p_cy)), '(none)');
  perform tests.assert_eq('ann sees her own posts as herself', tests.names(ann, a_e, format($q$public.feed_home(%L)$q$, p_ann)), 'p-reel,p-members,p-followers,p-public');
  perform tests.assert_eq('...and her business''s as the business', tests.names(ann, a_e, format($q$public.feed_home(%L)$q$, p_dj)), 'p-dj');
  perform tests.assert_eq('a page of two', tests.names(bob, b_e, format($q$public.feed_home(%L, 2)$q$, p_bob)), 'p-eve,p-reel');
  txt := tests.f(bob, b_e, format($q$public.feed_home(%L, 2)$q$, p_bob), '{1,created_at}');
  perform tests.assert_eq('the next page starts after the last one seen', tests.names(bob, b_e, format($q$public.feed_home(%L, 2, %L::timestamptz, %L)$q$, p_bob, txt, tests.f(bob, b_e, format($q$public.feed_home(%L, 2)$q$, p_bob), '{1,id}')::uuid)), 'p-members,p-followers');
  perform tests.assert_eq('the last page', tests.names(bob, b_e, format($q$public.feed_home(%L, 2, %L::timestamptz, %L)$q$, p_bob, tests.f(bob, b_e, format($q$public.feed_home(%L, 4)$q$, p_bob), '{3,created_at}'), tests.f(bob, b_e, format($q$public.feed_home(%L, 4)$q$, p_bob), '{3,id}')::uuid)), 'p-public');
  post3 := tests.mk(ann, a_e, p_ann, 'reel', 'followers', 'reel-followers');
  perform tests.assert_eq('a followers-only reel is in a follower''s reels', tests.names(bob, b_e, format($q$public.feed_reels(%L)$q$, p_bob)), 'reel-followers,p-reel');
  perform tests.assert_eq('...and not in a stranger''s', tests.names(cy, c_e, format($q$public.feed_reels(%L)$q$, p_cy)), 'p-reel');
  delete from public.site_posts where id = post3::uuid;
  perform tests.assert_eq('a limit of zero still returns one', tests.q(bob, b_e, format($q$jsonb_array_length(public.feed_home(%L, 0))$q$, p_bob)), '1');
  perform tests.login_anon();
  perform tests.assert_raises('...it is refused before anything is read', format($q$select public.feed_home(%L)$q$, p_bob), 'permission denied');
  perform tests.logout();

  perform tests.assert_eq('the profile grid shows what the viewer may see, newest first', tests.names(bob, b_e, format($q$(public.profile_posts(%L, %L)) -> 'items'$q$, p_bob, p_ann)), 'p-reel,p-members,p-followers,p-public');
  perform tests.assert_eq('...with how many', tests.f(bob, b_e, format($q$public.profile_posts(%L, %L)$q$, p_bob, p_ann), '{total}'), '4');
  perform tests.assert_eq('a stranger''s grid holds only what they may see', tests.names(cy, c_e, format($q$(public.profile_posts(%L, %L)) -> 'items'$q$, p_cy, p_ann)), 'p-reel,p-public');
  perform tests.assert_eq('a stranger sees fewer, and the count does not give the rest away', tests.f(cy, c_e, format($q$public.profile_posts(%L, %L)$q$, p_cy, p_ann), '{total}'), '2');
  perform tests.assert_eq('reels only', tests.names(bob, b_e, format($q$(public.profile_posts(%L, %L, 'reel')) -> 'items'$q$, p_bob, p_ann)), 'p-reel');
  perform tests.assert_eq('a made-up kind is refused', tests.q(bob, b_e, format($q$public.profile_posts(%L, %L, 'story')$q$, p_bob, p_ann)), 'ERROR: Choose posts or reels.');
  perform tests.assert_eq('a private profile keeps its grid for its followers', tests.q(cy, c_e, format($q$public.profile_posts(%L, %L)$q$, p_cy, p_eve)), 'ERROR: Follow this profile to see its posts.');
  perform tests.assert_eq('...and shows it to them', tests.names(bob, b_e, format($q$(public.profile_posts(%L, %L)) -> 'items'$q$, p_bob, p_eve)), 'p-eve');
  perform tests.assert_eq('a person''s own other profile can see their private grid', tests.names(eve, e_e, format($q$(public.profile_posts(%L, %L)) -> 'items'$q$, p_eve, p_eve)), 'p-eve');
  perform tests.assert_eq('a paged grid', tests.names(bob, b_e, format($q$(public.profile_posts(%L, %L, null, 2)) -> 'items'$q$, p_bob, p_ann)), 'p-reel,p-members');

  ---------------------------------------------------------------- likes
  perform tests.assert_eq('liking', tests.f(bob, b_e, format($q$public.post_like(%L, %L, true)$q$, p_bob, post1::uuid), '{likes}'), '1');
  perform tests.assert_eq('liking twice is one like', tests.f(bob, b_e, format($q$public.post_like(%L, %L, true)$q$, p_bob, post1::uuid), '{likes}'), '1');
  perform tests.assert_eq('the card says it is liked, for the one who liked it', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1::uuid), '{liked}'), 'true');
  perform tests.assert_eq('...and not for anyone else', tests.f(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post1::uuid), '{liked}'), 'false');
  perform tests.assert_eq('a second person raises the count', tests.f(cy, c_e, format($q$public.post_like(%L, %L, true)$q$, p_cy, post1::uuid), '{likes}'), '2');
  perform tests.assert_eq('unliking', tests.f(cy, c_e, format($q$public.post_like(%L, %L, false)$q$, p_cy, post1::uuid), '{likes}'), '1');
  perform tests.assert_eq('unliking what was not liked changes nothing', tests.f(cy, c_e, format($q$public.post_like(%L, %L, false)$q$, p_cy, post1::uuid), '{likes}'), '1');
  perform tests.assert_eq('a post you may not see cannot be liked', tests.q(cy, c_e, format($q$public.post_like(%L, %L, true)$q$, p_cy, post_f::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...nor can a made-up one', tests.q(cy, c_e, format($q$public.post_like(%L, %L, true)$q$, p_cy, gen_random_uuid())), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('a missing answer is refused', tests.q(cy, c_e, format($q$public.post_like(%L, %L, null)$q$, p_cy, post1::uuid)), 'ERROR: Choose like or unlike.');
  perform tests.q(dee, d_e, format($q$public.post_like(%L, %L, true)$q$, p_dee, post1::uuid));
  update public.site_profiles set status = 'suspended' where id = p_dee;
  perform tests.assert_eq('...it is not counted while the profile is suspended', tests.f(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post1::uuid), '{likes}'), '1');
  update public.site_profiles set status = 'active' where id = p_dee;

  ---------------------------------------------------------------- saves
  perform tests.assert_eq('saving', tests.f(bob, b_e, format($q$public.post_save(%L, %L, true)$q$, p_bob, post1::uuid), '{saved}'), 'true');
  perform pg_sleep(0.01);
  perform tests.q(bob, b_e, format($q$public.post_save(%L, %L, true)$q$, p_bob, post_m::uuid));
  perform tests.q(bob, b_e, format($q$public.post_save(%L, %L, true)$q$, p_bob, post1::uuid));
  perform tests.assert_eq('the saved list: newest save first, nothing twice', tests.names(bob, b_e, format($q$public.saved_posts(%L)$q$, p_bob)), 'p-members,p-public');
  perform tests.assert_eq('...and the card says it is saved', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1::uuid), '{saved}'), 'true');
  perform tests.assert_eq('a post you may not see cannot be saved', tests.q(cy, c_e, format($q$public.post_save(%L, %L, true)$q$, p_cy, post_f::uuid)), 'ERROR: This post isn''t available.');
  perform tests.q(ann, a_e, format($q$public.members_set(%L, %L, false)$q$, p_ann, p_bob));
  perform tests.assert_eq('a saved post drops out of the list when the person can no longer see it', tests.names(bob, b_e, format($q$public.saved_posts(%L)$q$, p_bob)), 'p-public');
  perform tests.q(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_bob));
  perform tests.assert_eq('...and returns when they can again', tests.names(bob, b_e, format($q$public.saved_posts(%L)$q$, p_bob)), 'p-members,p-public');
  perform tests.assert_eq('a page of saved posts', tests.names(bob, b_e, format($q$public.saved_posts(%L, 1)$q$, p_bob)), 'p-members');
  perform tests.assert_eq('unsaving', tests.f(bob, b_e, format($q$public.post_save(%L, %L, false)$q$, p_bob, post_m::uuid), '{saved}'), 'false');
  perform tests.assert_eq('...removes it from the list', tests.names(bob, b_e, format($q$public.saved_posts(%L)$q$, p_bob)), 'p-public');

  ---------------------------------------------------------------- comments
  perform tests.assert_eq('commenting', tests.f(bob, b_e, format($q$public.comment_add(%L, %L, '  Great night!  ')$q$, p_bob, post1::uuid), '{body}'), 'Great night!');
  select id::text into txt from public.site_comments where body = 'Great night!';
  perform tests.assert_eq('...it shows who wrote it', tests.f(cy, c_e, format($q$(public.comment_list(%L, %L)) -> 0$q$, p_cy, post1::uuid), '{author,handle}'), 'bob');
  perform tests.assert_eq('a reply to it', tests.f(cy, c_e, format($q$public.comment_add(%L, %L, 'Agreed', %L)$q$, p_cy, post1::uuid, txt::uuid), '{reply_to}'), txt);
  select id::text into c2 from public.site_comments where body = 'Agreed';
  perform tests.assert_eq('a reply to a reply is not allowed (one level only)', tests.q(dee, d_e, format($q$public.comment_add(%L, %L, 'me too', %L)$q$, p_dee, post1::uuid, c2::uuid)), 'ERROR: That comment is not there any more.');
  perform tests.assert_eq('a reply to a comment on another post is not allowed', tests.q(dee, d_e, format($q$public.comment_add(%L, %L, 'wrong post', %L)$q$, p_dee, post_f::uuid, txt::uuid)), 'ERROR: That comment is not there any more.');
  perform tests.assert_eq('the top-level list does not include replies', tests.names(cy, c_e, format($q$public.comment_list(%L, %L)$q$, p_cy, post1::uuid), 'body'), 'Great night!');
  perform tests.assert_eq('...and says how many replies it has', tests.f(cy, c_e, format($q$(public.comment_list(%L, %L)) -> 0$q$, p_cy, post1::uuid), '{replies}'), '1');
  perform tests.assert_eq('the replies of one comment', tests.names(cy, c_e, format($q$public.comment_list(%L, %L, %L)$q$, p_cy, post1::uuid, txt::uuid), 'body'), 'Agreed');
  perform tests.assert_eq('the card counts comments and replies', tests.f(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post1::uuid), '{comments}'), '2');
  perform tests.assert_eq('an empty comment is refused', tests.q(bob, b_e, format($q$public.comment_add(%L, %L, '   ')$q$, p_bob, post1::uuid)), 'ERROR: Write something first.');
  perform tests.assert_eq('1001 characters are refused', tests.q(bob, b_e, format($q$public.comment_add(%L, %L, %L)$q$, p_bob, post1::uuid, repeat('a', 1001))), 'ERROR: A comment can be 1000 characters at most.');
  perform tests.assert_eq('1000 are fine', tests.q(bob, b_e, format($q$length(public.comment_add(%L, %L, %L) ->> 'body')$q$, p_bob, post1::uuid, repeat('a', 1000))), '1000');
  perform tests.assert_eq('a banned word is refused in a comment too', tests.q(bob, b_e, format($q$public.comment_add(%L, %L, 'you badword')$q$, p_bob, post1::uuid)), 'ERROR: That text goes against our community rules.');
  perform tests.assert_eq('you cannot read comments where you cannot see the post', tests.q(cy, c_e, format($q$public.comment_list(%L, %L)$q$, p_cy, post_f::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('you cannot comment where you cannot see', tests.q(cy, c_e, format($q$public.comment_add(%L, %L, 'hi')$q$, p_cy, post_f::uuid)), 'ERROR: This post isn''t available.');
  delete from public.site_comments where body = repeat('a', 1000);

  -- paging, blocking, deleting
  perform pg_sleep(0.01); perform tests.q(dee, d_e, format($q$public.comment_add(%L, %L, 'third')$q$, p_dee, post1::uuid));
  perform pg_sleep(0.01); perform tests.q(cy, c_e, format($q$public.comment_add(%L, %L, 'fourth')$q$, p_cy, post1::uuid));
  perform tests.assert_eq('comments are oldest first', tests.names(ann, a_e, format($q$public.comment_list(%L, %L)$q$, p_ann, post1::uuid), 'body'), 'Great night!,third,fourth');
  perform tests.assert_eq('a page of two', tests.names(ann, a_e, format($q$public.comment_list(%L, %L, null, 2)$q$, p_ann, post1::uuid), 'body'), 'Great night!,third');
  perform tests.assert_eq('the next page starts after the last one seen', tests.names(ann, a_e, format($q$public.comment_list(%L, %L, null, 2, %L::timestamptz)$q$, p_ann, post1::uuid, tests.f(ann, a_e, format($q$(public.comment_list(%L, %L, null, 2)) -> 1$q$, p_ann, post1::uuid), '{created_at}')), 'body'), 'fourth');
  perform tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_dee));
  perform tests.assert_eq('a blocked person''s comments are hidden from the one who blocked them', tests.names(bob, b_e, format($q$public.comment_list(%L, %L)$q$, p_bob, post1::uuid), 'body'), 'Great night!,fourth');
  perform tests.q(bob, b_e, format($q$public.block_set(%L, %L, false)$q$, p_bob, p_dee));
  select id::text into c3 from public.site_comments where body = 'fourth';
  perform tests.assert_eq('someone else cannot delete a comment of yours', tests.q(bob, b_e, format($q$public.comment_delete(%L, %L)$q$, p_bob, c3::uuid)), 'ERROR: You can only delete your own comments, or comments on your own posts.');
  perform tests.assert_eq('the writer deletes their comment', tests.f(cy, c_e, format($q$public.comment_delete(%L, %L)$q$, p_cy, c3::uuid), '{deleted}'), 'true');
  select id::text into c3 from public.site_comments where body = 'third';
  perform tests.assert_eq('the owner of the post deletes a comment on it', tests.f(ann, a_e, format($q$public.comment_delete(%L, %L)$q$, p_ann, c3::uuid), '{deleted}'), 'true');
  perform tests.assert_eq('the card tells who may delete', tests.q(ann, a_e, format($q$(public.comment_list(%L, %L)) -> 0 ->> 'can_delete'$q$, p_ann, post1::uuid)), 'true');
  perform tests.assert_eq('...a stranger may not', tests.q(dee, d_e, format($q$(public.comment_list(%L, %L)) -> 0 ->> 'can_delete'$q$, p_dee, post1::uuid)), 'false');
  perform tests.assert_eq('deleting a comment takes its replies with it', tests.q(ann, a_e, format($q$public.comment_delete(%L, %L)$q$, p_ann, txt::uuid)), '{"deleted": true}');
  perform tests.logout();
  perform tests.assert_eq('...nothing is left', (select count(*) from public.site_comments where post = post1::uuid)::int, 0);
  perform tests.assert_eq('a made-up comment cannot be deleted', tests.q(ann, a_e, format($q$public.comment_delete(%L, %L)$q$, p_ann, gen_random_uuid())), 'ERROR: You can only delete your own comments, or comments on your own posts.');

  -- turned off, and too fast
  perform tests.assert_eq('the owner turns comments off', tests.f(ann, a_e, format($q$public.post_edit(%L, %L, 'p-public', 'public', false)$q$, p_ann, post1::uuid), '{comments_enabled}'), 'false');
  perform tests.assert_eq('...and no one can add one', tests.q(bob, b_e, format($q$public.comment_add(%L, %L, 'hello?')$q$, p_bob, post1::uuid)), 'ERROR: Comments are turned off for this post.');
  perform tests.q(ann, a_e, format($q$public.post_edit(%L, %L, 'p-public', 'public', true)$q$, p_ann, post1::uuid));
  insert into public.site_comments (post, author, body) select post1::uuid, p_bob, 'spam ' || g from generate_series(1, 20) g;
  perform tests.assert_eq('twenty comments in a minute is the limit', tests.q(bob, b_e, format($q$public.comment_add(%L, %L, 'one more')$q$, p_bob, post1::uuid)), 'ERROR: You are commenting too quickly. Try again in a moment.');
  perform tests.assert_eq('...and other people are not slowed', tests.f(cy, c_e, format($q$public.comment_add(%L, %L, 'fine')$q$, p_cy, post1::uuid), '{body}'), 'fine');
  delete from public.site_comments where post = post1::uuid;
  update public.site_profiles set status = 'suspended' where id = p_cy;
  insert into public.site_comments (post, author, body) values (post1::uuid, p_cy, 'by a suspended profile');
  perform tests.assert_eq('a suspended profile''s comment is not shown', tests.names(bob, b_e, format($q$public.comment_list(%L, %L)$q$, p_bob, post1::uuid), 'body'), '(none)');
  perform tests.assert_eq('...nor counted', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1::uuid), '{comments}'), '0');
  update public.site_profiles set status = 'active' where id = p_cy;
  delete from public.site_comments where post = post1::uuid;

  ---------------------------------------------------------------- suggested posts and reels
  perform tests.q(bob, b_e, format($q$public.post_like(%L, %L, true)$q$, p_bob, reel1::uuid));
  perform tests.q(dee, d_e, format($q$public.post_like(%L, %L, true)$q$, p_dee, reel1::uuid));
  perform tests.q(olly, o_e, format($q$public.post_like(%L, %L, true)$q$, p_olly, reel1::uuid));
  perform tests.q(bob, b_e, format($q$public.comment_add(%L, %L, 'nice')$q$, p_bob, post1::uuid));
  perform tests.assert_eq('suggestions for a stranger: public posts of people they do not follow, the most liked and commented first', tests.names(cy, c_e, format($q$public.feed_suggested(%L)$q$, p_cy)), 'p-public,p-reel,p-club,p-dj');
  -- p-public has 2 likes and 1 comment (a comment is worth two points) = 4; the reel has 3 likes = 3.
  perform tests.assert_eq('...never a post for followers, a Members Only one, or a private profile''s', tests.names(cy, c_e, format($q$public.feed_suggested(%L)$q$, p_cy)) ~ '(p-followers|p-members|p-eve)', false);
  perform tests.assert_eq('...nothing from people already followed', tests.names(bob, b_e, format($q$public.feed_suggested(%L)$q$, p_bob)), 'p-club,p-dj');
  perform tests.assert_eq('...nor one''s own', tests.names(ann, a_e, format($q$public.feed_suggested(%L)$q$, p_ann)), 'p-club');
  perform tests.assert_eq('a limit', tests.q(cy, c_e, format($q$jsonb_array_length(public.feed_suggested(%L, 1))$q$, p_cy)), '1');
  update public.site_posts set created_at = now() - interval '15 days' where id = reel1::uuid;
  perform tests.assert_eq('a post older than two weeks is no longer suggested', tests.names(cy, c_e, format($q$public.feed_suggested(%L)$q$, p_cy)) like '%p-reel%', false);
  update public.site_posts set created_at = now() where id = reel1::uuid;
  perform tests.assert_eq('the reels viewer shows reels one may see', tests.names(cy, c_e, format($q$public.feed_reels(%L)$q$, p_cy)), 'p-reel');
  perform tests.assert_eq('...and only reels', tests.names(bob, b_e, format($q$public.feed_reels(%L)$q$, p_bob)), 'p-reel');

  ---------------------------------------------------------------- the Members Only list
  perform tests.assert_eq('someone who does not follow cannot be added', tests.q(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_cy)), 'ERROR: They need to follow you first.');
  perform tests.assert_eq('...nor your own other profile', tests.q(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_dj)), 'ERROR: You cannot add your own profile.');
  perform tests.assert_eq('...nor yourself', tests.q(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_ann)), 'ERROR: You cannot add your own profile.');
  perform tests.assert_eq('adding a second member', tests.f(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_dee), '{members}'), '2');
  perform tests.assert_eq('adding the same person twice is the same', tests.f(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_dee), '{members}'), '2');
  perform tests.assert_eq('the list, newest first', tests.names(ann, a_e, format($q$public.members_list(%L)$q$, p_ann), 'handle'), 'dee,bob');
  perform tests.assert_eq('...everyone is still following', tests.q(ann, a_e, format($q$(select string_agg(e ->> 'still_following', ',') from jsonb_array_elements(public.members_list(%L)) e)$q$, p_ann)), 'true,true');
  perform tests.q(dee, d_e, format($q$public.follow_set(%L, %L, false)$q$, p_dee, p_ann));
  perform tests.assert_eq('a member who unfollowed stays on the list, marked', tests.q(ann, a_e, format($q$(select e ->> 'still_following' from jsonb_array_elements(public.members_list(%L)) e where e ->> 'handle' = 'dee')$q$, p_ann)), 'false');
  perform tests.q(dee, d_e, format($q$public.follow_set(%L, %L, true)$q$, p_dee, p_ann));
  perform tests.assert_eq('a page of the list', tests.names(ann, a_e, format($q$public.members_list(%L, 1)$q$, p_ann), 'handle'), 'dee');
  perform tests.assert_eq('only the owner of a list sees it', tests.q(bob, b_e, format($q$public.members_list(%L)$q$, p_ann)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...and as another profile one gets that profile''s own (empty) list', tests.q(ann, a_e, format($q$jsonb_array_length(public.members_list(%L))$q$, p_dj)), '0');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, true)$q$, p_ann, p_dee));
  perform tests.assert_eq('blocking someone also takes the follow, so they are no longer a member in effect', tests.q(ann, a_e, format($q$(select e ->> 'still_following' from jsonb_array_elements(public.members_list(%L)) e where e ->> 'handle' = 'dee')$q$, p_ann)), 'false');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, false)$q$, p_ann, p_dee));
  perform tests.q(dee, d_e, format($q$public.follow_set(%L, %L, true)$q$, p_dee, p_ann));
  perform tests.q(ann, a_e, format($q$public.members_set(%L, %L, false)$q$, p_ann, p_dee));
  perform tests.assert_eq('taking someone off', tests.f(ann, a_e, format($q$public.members_set(%L, %L, false)$q$, p_ann, p_dee), '{members}'), '1');

  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('members_only', false); perform tests.logout();
  perform tests.assert_eq('with Members Only off nobody is added', tests.q(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_dee)), 'ERROR: Members Only is not open yet.');
  perform tests.assert_eq('...but taking off still works', tests.f(ann, a_e, format($q$public.members_set(%L, %L, false)$q$, p_ann, p_dee), '{members}'), '1');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('members_only', true); perform tests.logout();

  insert into auth.users (id, email) select ('00000000-0000-0000-0002-' || lpad(g::text, 12, '0'))::uuid, 'filler' || g || '@posts.example' from generate_series(1, 2000) g;
  insert into public.site_profiles (kind, user_id) select 'personal', ('00000000-0000-0000-0002-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 2000) g;
  insert into public.site_member_lists (owner, member) select p_ann, s.id from public.site_profiles s where s.user_id::text like '00000000-0000-0000-0002-%' limit 1998;
  perform tests.assert_eq('the list holds 2000 at most: with 1999 on it the 2000th goes in', tests.f(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_dee), '{members}'), '2000');
  insert into public.site_follows (follower, followed)
    select s.id, p_ann from public.site_profiles s
    where s.user_id::text like '00000000-0000-0000-0002-%' and s.id not in (select member from public.site_member_lists where owner = p_ann) limit 1;
  perform tests.assert_eq('...the 2001st does not', tests.q(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann,
    (select s.id from public.site_profiles s where s.user_id::text like '00000000-0000-0000-0002-%' and s.id not in (select member from public.site_member_lists where owner = p_ann)
       and s.id in (select follower from public.site_follows where followed = p_ann) limit 1))), 'ERROR: Your Members Only list is full (2000 people).');
  perform tests.assert_eq('...yet adding someone already on it is fine', tests.f(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_dee), '{members}'), '2000');
  delete from auth.users where email like 'filler%@posts.example';
  perform tests.q(ann, a_e, format($q$public.members_set(%L, %L, false)$q$, p_ann, p_dee));

  ---------------------------------------------------------------- changing and deleting a post
  perform tests.assert_eq('the author changes the words and who sees it', tests.f(ann, a_e, format($q$public.post_edit(%L, %L, 'new words', 'followers', false)$q$, p_ann, post1::uuid), '{audience}'), 'followers');
  perform tests.assert_eq('...at once, for everyone', tests.q(cy, c_e, format($q$public.post_get(%L, %L)$q$, p_cy, post1::uuid)), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...and the new words show to those who can still see it', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1::uuid), '{caption}'), 'new words');
  perform tests.assert_eq('someone else cannot change it', tests.q(bob, b_e, format($q$public.post_edit(%L, %L, 'mine now', 'public', true)$q$, p_bob, post1::uuid)), 'ERROR: You can only change your own posts.');
  perform tests.assert_eq('a made-up audience is refused', tests.q(ann, a_e, format($q$public.post_edit(%L, %L, 'x', 'everyone', true)$q$, p_ann, post1::uuid)), 'ERROR: Choose who can see this.');
  perform tests.assert_eq('a banned word is refused in an edit', tests.q(ann, a_e, format($q$public.post_edit(%L, %L, 'badword', 'public', true)$q$, p_ann, post1::uuid)), 'ERROR: That text goes against our community rules.');
  perform tests.assert_eq('an emptied caption is allowed', tests.q(ann, a_e, format($q$(public.post_edit(%L, %L, '  ', 'public', true)) ->> 'caption'$q$, p_ann, post1::uuid)), '(null)');
  perform tests.q(ann, a_e, format($q$public.post_edit(%L, %L, 'p-public', 'public', true)$q$, p_ann, post1::uuid));
  select id::text into c1 from public.site_posts where caption = 'p-club';
  perform tests.assert_eq('the club''s owner changes the club''s post, as the owner', tests.f(olly, o_e, format($q$public.post_edit(%L, %L, 'club news', 'public', true)$q$, p_olly, c1::uuid), '{caption}'), 'club news');
  perform tests.assert_eq('a revoked manager cannot', tests.q(mia, m_e, format($q$public.post_edit(%L, %L, 'mine', 'public', true)$q$, p_mia, c1::uuid)), 'ERROR: You can only change your own posts.');

  media := jsonb_build_array(jsonb_build_object('path', tests.upload(p_ann, 'gone.mp4', 'video/mp4'), 'type', 'video', 'duration_ms', 8000, 'poster_path', tests.upload(p_ann, 'gone.jpg')));
  post3 := tests.f(ann, a_e, format($q$public.post_create(%L, 'reel', 'to delete', 'public', %L::jsonb)$q$, p_ann, media), '{id}');
  perform tests.q(bob, b_e, format($q$public.post_like(%L, %L, true)$q$, p_bob, post3::uuid));
  perform tests.q(bob, b_e, format($q$public.post_save(%L, %L, true)$q$, p_bob, post3::uuid));
  perform tests.q(bob, b_e, format($q$public.comment_add(%L, %L, 'bye')$q$, p_bob, post3::uuid));
  perform tests.assert_eq('someone else cannot delete it', tests.q(bob, b_e, format($q$public.post_delete(%L, %L)$q$, p_bob, post3::uuid)), 'ERROR: You can only delete your own posts.');
  perform tests.assert_eq('the author deletes it and is told which files to remove', tests.q(ann, a_e, format($q$(select string_agg(x, ',' order by x) from jsonb_array_elements_text(public.post_delete(%L, %L)) x)$q$, p_ann, post3::uuid)), p_ann::text || '/gone.jpg,' || p_ann::text || '/gone.mp4');
  perform tests.assert_eq('...it is gone with its likes, saves and comments', (select (select count(*) from public.site_posts where id = post3::uuid) + (select count(*) from public.site_post_likes where post = post3::uuid) + (select count(*) from public.site_post_saves where post = post3::uuid) + (select count(*) from public.site_comments where post = post3::uuid) + (select count(*) from public.site_post_media where post = post3::uuid))::int, 0);
  perform tests.assert_eq('deleting what is not there is refused', tests.q(ann, a_e, format($q$public.post_delete(%L, %L)$q$, p_ann, post3::uuid)), 'ERROR: You can only delete your own posts.');

  ---------------------------------------------------------------- the files are as private as the posts
  path := tests.upload(p_ann, 'private-check.jpg');
  perform tests.login(ann, a_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('an uploader can see their own file', n, 1);
  perform tests.login(bob, b_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('...nobody else can, until it is part of a post they may see', n, 0);
  perform tests.logout();
  select m.storage_path into path from public.site_post_media m where m.post = post1::uuid;
  perform tests.login(cy, c_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('a stranger can fetch the photo of a public post', n, 1);
  perform tests.login_anon();
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('...a signed-out visitor cannot', n, 0);
  perform tests.logout();
  select m.storage_path into path from public.site_post_media m where m.post = post_f::uuid;
  perform tests.login(cy, c_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('a stranger cannot fetch the photo of a followers'' post', n, 0);
  perform tests.login(bob, b_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('...a follower can', n, 1);
  perform tests.logout();
  select m.storage_path into path from public.site_post_media m where m.post = post_m::uuid;
  perform tests.login(dee, d_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('a follower who is not a member cannot fetch a Members Only photo', n, 0);
  perform tests.login(bob, b_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('...a member can', n, 1);
  perform tests.logout();
  perform tests.q(ann, a_e, format($q$public.members_set(%L, %L, false)$q$, p_ann, p_bob));
  perform tests.login(bob, b_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('taking the member off closes the file at once too', n, 0);
  perform tests.logout();
  perform tests.q(ann, a_e, format($q$public.members_set(%L, %L, true)$q$, p_ann, p_bob));
  perform tests.login(ann, a_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('the author always reads their own files', n, 1);
  perform tests.logout();
  select m.storage_path into path from public.site_post_media m where m.post = post2::uuid;
  perform tests.login(ann, a_e);
  select count(*) into n from storage.objects where name = path;
  perform tests.assert_eq('a person reads the files of their business profile''s posts', n, 1);

  -- writing and removing files
  perform tests.login(ann, a_e);
  insert into storage.objects (bucket_id, name, metadata) values ('social-media', p_ann::text || '/new-upload.jpg', '{"size": 10, "mimetype": "image/jpeg"}');
  perform tests.assert_true('a person can add a file to their own folder', true);
  insert into storage.objects (bucket_id, name, metadata) values ('social-media', p_dj::text || '/biz-upload.jpg', '{"size": 10, "mimetype": "image/jpeg"}');
  perform tests.assert_true('...and to the folder of their business profile', true);
  begin
    insert into storage.objects (bucket_id, name, metadata) values ('social-media', p_bob::text || '/sneaky.jpg', '{"size": 10, "mimetype": "image/jpeg"}');
    raise exception 'FAIL - a file went into someone else''s folder';
  exception when insufficient_privilege then
    perform tests.assert_true('a file cannot go into someone else''s folder', true);
  end;
  begin
    insert into storage.objects (bucket_id, name, metadata) values ('social-media', 'loose.jpg', '{"size": 10, "mimetype": "image/jpeg"}');
    raise exception 'FAIL - a file went in with no profile folder';
  exception when insufficient_privilege then
    perform tests.assert_true('...nor one with no profile folder at all', true);
  end;
  begin
    insert into storage.objects (bucket_id, name, metadata) values ('social-media', p_ann::text || '/deep/er.jpg', '{"size": 10, "mimetype": "image/jpeg"}');
    raise exception 'FAIL - a nested path went in';
  exception when insufficient_privilege then
    perform tests.assert_true('...nor a path of any other shape', true);
  end;
  delete from storage.objects where name = p_ann::text || '/new-upload.jpg';
  get diagnostics n = row_count;
  perform tests.assert_eq('a person removes their own file', n, 1);
  perform tests.login(bob, b_e);
  delete from storage.objects where name = p_ann::text || '/biz-upload.jpg' or name = p_dj::text || '/biz-upload.jpg';
  get diagnostics n = row_count;
  perform tests.assert_eq('...but not someone else''s', n, 0);
  perform tests.logout();
  select m.storage_path into path from public.site_post_media m where m.post = post1::uuid;
  perform tests.login(bob, b_e);
  delete from storage.objects where name = path;
  get diagnostics n = row_count;
  perform tests.assert_eq('...nor a file they can see but did not upload', n, 0);
  perform tests.logout();
  delete from storage.objects where name like p_ann::text || '/%' or name like p_dj::text || '/%' or name like p_bob::text || '/%' or name like p_eve::text || '/%' or name like p_dee::text || '/%' or name like p_club::text || '/%';
  media := jsonb_build_array(jsonb_build_object('path', tests.upload(p_ann, 'aged.mp4', 'video/mp4', 1000, interval '3 days'), 'type', 'video', 'duration_ms', 8000, 'poster_path', tests.upload(p_ann, 'aged.jpg', 'image/jpeg', 100, interval '3 days')));
  perform tests.f(ann, a_e, format($q$public.post_create(%L, 'reel', 'aged', 'public', %L::jsonb)$q$, p_ann, media), '{id}');
  perform tests.upload(p_ann, 'old-orphan.jpg', 'image/jpeg', 100, interval '3 days');
  perform tests.upload(p_ann, 'new-orphan.jpg', 'image/jpeg', 100, interval '1 hour');
  perform tests.assert_eq('the clean-up job finds an old file that no post uses', (select string_agg(name, ',') from public.social_media_orphans()), p_ann::text || '/old-orphan.jpg');
  perform tests.login(ann, a_e);
  perform tests.assert_raises('the app cannot list them', $q$select * from public.social_media_orphans()$q$, 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the banned-terms list
  perform tests.assert_eq('only an admin changes the list', tests.q(ann, a_e, $q$public.cms_set_banned_term('spamword', true)$q$), 'ERROR: Only a BottlesUp admin can change this.');
  perform tests.assert_eq('...or reads it', tests.q(ann, a_e, 'public.cms_list_banned_terms()'), 'ERROR: Only a BottlesUp admin can see this.');
  perform tests.assert_eq('a term is letters, digits and spaces', tests.q(admin_u, 'admin@test.example', $q$public.cms_set_banned_term('bad.word', true)$q$), 'ERROR: A banned term is 2 to 40 letters, numbers or spaces.');
  perform tests.assert_eq('...at least two', tests.q(admin_u, 'admin@test.example', $q$public.cms_set_banned_term('a', true)$q$), 'ERROR: A banned term is 2 to 40 letters, numbers or spaces.');
  perform tests.assert_eq('adding a term', tests.f(admin_u, 'admin@test.example', $q$public.cms_set_banned_term('  Spam   Phrase ', true)$q$, '{terms}'), '2');
  perform tests.assert_eq('...is kept tidy: lower case, single spaces', tests.q(admin_u, 'admin@test.example', $q$(select string_agg(term, ',' order by term) from public.cms_list_banned_terms())$q$), 'badword,spam phrase');
  perform tests.assert_eq('a phrase is matched as a phrase, in any case', tests.mk(ann, a_e, p_ann, 'post', 'public', 'Buy SPAM phrase now'), 'ERROR: That text goes against our community rules.');
  perform tests.assert_eq('...but not just one of its words', (tests.mk(ann, a_e, p_ann, 'post', 'public', 'phrase of the day, no spam here') ~ '^[0-9a-f-]{36}$'), true);
  perform tests.assert_eq('...and not inside a longer word', (tests.mk(ann, a_e, p_ann, 'post', 'public', 'a badwordy thing') ~ '^[0-9a-f-]{36}$'), true);
  perform tests.assert_eq('...but next to punctuation it is', tests.mk(ann, a_e, p_ann, 'post', 'public', 'oh, badword!'), 'ERROR: That text goes against our community rules.');
  perform tests.assert_eq('removing a term', tests.f(admin_u, 'admin@test.example', $q$public.cms_set_banned_term('badword', false)$q$, '{terms}'), '1');
  perform tests.assert_eq('...lets the text through', (tests.mk(ann, a_e, p_ann, 'post', 'public', 'oh, badword!') ~ '^[0-9a-f-]{36}$'), true);
  perform tests.assert_eq('a missing answer is refused', tests.q(admin_u, 'admin@test.example', $q$public.cms_set_banned_term('spam phrase', null)$q$), 'ERROR: Choose add or remove.');
  perform tests.assert_eq('each change is in the audit log', (select count(*) from public.audit_log where entity_type = 'banned_term')::int, 3);
  delete from public.site_posts where author = p_ann and caption in ('phrase of the day, no spam here', 'a badwordy thing', 'oh, badword!');

  ---------------------------------------------------------------- the rest of the surface
  perform tests.login(bob, b_e);
  perform tests.assert_raises('the visibility check cannot be called by the app', format($q$select public.post_visible(%L, %L)$q$, p_bob, post1::uuid), 'permission denied');
  perform tests.assert_raises('...nor the card builders', format($q$select public.post_card(%L, %L)$q$, p_bob, post1::uuid), 'permission denied');
  perform tests.assert_raises('...nor the profile one', format($q$select public.profile_mini(%L)$q$, p_ann), 'permission denied');
  perform tests.assert_raises('...nor the comment one', format($q$select public.comment_card(%L, %L)$q$, p_bob, gen_random_uuid()), 'permission denied');
  perform tests.assert_raises('...nor the text check', $q$select public.social_text_ok('hello')$q$, 'permission denied');
  perform tests.assert_raises('...nor the rules check', $q$select public.social_require_rules()$q$, 'permission denied');
  perform tests.assert_raises('the posts table cannot be read', $q$select * from public.site_posts$q$, 'permission denied');
  perform tests.assert_raises('...nor the media', $q$select * from public.site_post_media$q$, 'permission denied');
  perform tests.assert_raises('...nor the comments', $q$select * from public.site_comments$q$, 'permission denied');
  perform tests.assert_raises('...nor the likes', $q$select * from public.site_post_likes$q$, 'permission denied');
  perform tests.assert_raises('...nor the member lists', $q$select * from public.site_member_lists$q$, 'permission denied');
  perform tests.assert_raises('...nor the banned terms', $q$select * from public.site_banned_terms$q$, 'permission denied');
  perform tests.assert_raises('...nor written', format($q$insert into public.site_post_likes (post, profile) values (%L, %L)$q$, post1::uuid, p_bob), 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot read a post', format($q$select public.post_get(%L, %L)$q$, p_bob, post1::uuid), 'permission denied');
  perform tests.assert_raises('...nor the rules status', $q$select public.rules_status()$q$, 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- caption ideas (the gate before the model is asked)
  perform tests.assert_eq('caption ideas are off at first', tests.q(ann, a_e, 'public.ai_caption_begin()'), 'ERROR: Caption ideas are not open yet.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('ai_captions', true); perform tests.logout();
  perform tests.assert_eq('a visitor cannot ask', (select count(*) from public.site_ai_caption_uses)::int, 0);
  perform tests.login_anon();
  perform tests.assert_raises('...at all', $q$select public.ai_caption_begin()$q$, 'permission denied');
  perform tests.logout();
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000005f9', 'newcomer@posts.example');
  perform tests.assert_eq('someone who has not accepted the community rules cannot ask', tests.q('00000000-0000-0000-0000-0000000005f9', 'newcomer@posts.example', 'public.ai_caption_begin()'), 'ERROR: Read and accept the community rules first.');
  perform tests.assert_eq('the first request says how many are left', tests.f(ann, a_e, 'public.ai_caption_begin()', '{left}'), '19');
  perform tests.assert_eq('...and the next', tests.f(ann, a_e, 'public.ai_caption_begin()', '{left}'), '18');
  perform tests.assert_eq('each one is counted for the person', (select count(*) from public.site_ai_caption_uses where user_id = ann)::int, 2);
  insert into public.site_ai_caption_uses (user_id) select ann from generate_series(1, 17);
  update public.site_ai_caption_uses set created_at = now() - interval '10 hours' where id in (select id from public.site_ai_caption_uses where user_id = ann order by id limit 6);
  perform tests.assert_eq('the 20th of the day is allowed, with none left', tests.f(ann, a_e, 'public.ai_caption_begin()', '{left}'), '0');
  perform tests.assert_eq('the 21st is not', tests.q(ann, a_e, 'public.ai_caption_begin()'), 'ERROR: You have used all of today''s caption ideas. Try again tomorrow.');
  perform tests.assert_eq('...and is not counted', (select count(*) from public.site_ai_caption_uses where user_id = ann)::int, 20);
  perform tests.assert_eq('someone else is not slowed by it', tests.f(bob, b_e, 'public.ai_caption_begin()', '{left}'), '19');
  update public.site_ai_caption_uses set created_at = now() - interval '36 hours' where user_id = ann;
  perform tests.assert_eq('requests from yesterday do not count', tests.f(ann, a_e, 'public.ai_caption_begin()', '{left}'), '19');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('ai_captions', false); perform tests.logout();
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('ai_captions', true); perform public.cms_set_feature('social', false); perform tests.logout();
  perform tests.assert_eq('with the social switch off, caption ideas are closed too', tests.q(ann, a_e, 'public.ai_caption_begin()'), 'ERROR: Caption ideas are not open yet.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('social', true); perform public.cms_set_feature('ai_captions', false); perform tests.logout();
  perform tests.assert_eq('switched off again, it stops at once', tests.q(ann, a_e, 'public.ai_caption_begin()'), 'ERROR: Caption ideas are not open yet.');
  perform tests.login(bob, b_e);
  perform tests.assert_raises('the list of requests is closed', $q$select * from public.site_ai_caption_uses$q$, 'permission denied');
  perform tests.logout();
  delete from auth.users where id = '00000000-0000-0000-0000-0000000005f9';

  ---------------------------------------------------------------- the community rules text, from the CMS
  perform tests.login_anon();
  perform tests.assert_eq('before BottlesUp publishes anything the rules are version 1 with no text, and anyone may ask', (public.rules_current())::text, '{"body": null, "version": 1}');
  perform tests.assert_raises('...but the table itself is closed', $q$select * from public.site_community_rules$q$, 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('only a BottlesUp admin can publish rules', tests.q(ann, a_e, $q$public.cms_publish_rules('Be kind to people. No spam. No hate. Respect each other.')$q$), 'ERROR: Only a BottlesUp admin can change this.');
  perform tests.assert_eq('...not too short', tests.q(admin_u, 'admin@test.example', $q$public.cms_publish_rules('Be kind')$q$), 'ERROR: The rules need between 20 and 8000 characters.');
  perform tests.assert_eq('...nor empty', tests.q(admin_u, 'admin@test.example', $q$public.cms_publish_rules(null)$q$), 'ERROR: The rules need between 20 and 8000 characters.');
  perform tests.assert_eq('...nor too long', tests.q(admin_u, 'admin@test.example', $q$public.cms_publish_rules(repeat('a', 8001))$q$), 'ERROR: The rules need between 20 and 8000 characters.');
  perform tests.assert_eq('...19 characters is still too short', tests.q(admin_u, 'admin@test.example', $q$public.cms_publish_rules(repeat('a', 19))$q$), 'ERROR: The rules need between 20 and 8000 characters.');
  perform tests.assert_eq('...exactly 20 is the first version BottlesUp publishes (version 2: everyone accepts the real text, not the draft)', tests.f(admin_u, 'admin@test.example', $q$public.cms_publish_rules(repeat('a', 20))$q$, '{version}'), '2');
  perform tests.assert_eq('...exactly 8000 is fine, and is the next version', tests.f(admin_u, 'admin@test.example', $q$public.cms_publish_rules(repeat('a', 8000))$q$, '{version}'), '3');
  perform tests.assert_eq('publishing again makes the next version, and trims the text', tests.f(admin_u, 'admin@test.example', $q$public.cms_publish_rules('  Be kind to people. No spam. No hate.  ')$q$, '{version}'), '4');
  perform tests.assert_eq('...the text is what a person reads', tests.f(ann, a_e, 'public.rules_current()', '{body}'), 'Be kind to people. No spam. No hate.');
  perform tests.assert_eq('...and a visitor reads it too', (select (public.rules_current())->>'version'), '4');
  perform tests.assert_eq('...everyone must accept again', tests.f(ann, a_e, 'public.rules_status()', '{accepted}') || '/' || tests.f(ann, a_e, 'public.rules_status()', '{version}'), 'false/4');
  perform tests.assert_eq('...a comment waits for it', tests.q(ann, a_e, format($q$public.comment_add(%L, %L, 'after the rules changed')$q$, p_ann, post1::uuid)), 'ERROR: Read and accept the community rules first.');
  perform tests.assert_eq('...the old version can no longer be accepted', tests.q(ann, a_e, 'public.rules_accept(1)'), 'ERROR: The community rules have changed. Read them again.');
  perform tests.assert_eq('...the new one can', tests.f(ann, a_e, 'public.rules_accept(4)', '{accepted}'), 'true');
  perform tests.assert_eq('...and then the comment goes through', tests.f(ann, a_e, format($q$public.comment_add(%L, %L, 'after the rules changed')$q$, p_ann, post1::uuid), '{body}'), 'after the rules changed');
  perform tests.assert_eq('every version is kept', (select count(*) from public.site_community_rules)::int, 3);
  perform tests.assert_eq('...with who published it', (select count(*) from public.site_community_rules where published_by = admin_u)::int, 3);
  perform tests.assert_eq('...and each publication is in the audit log, with its version', (select string_agg(entity_id || ':' || (details ->> 'version') || ':' || (details ->> 'characters'), ',' order by entity_id) from public.audit_log where action = 'rules_published'), '2:2:20,3:3:8000,4:4:36');
  perform tests.q(bob, b_e, 'public.rules_accept(4)');

  ---------------------------------------------------------------- deleting an account
  select count(*) into n from public.site_posts where author = p_ann;
  perform tests.assert_true('ann has posts and a Members Only list before', n > 0 and (select count(*) from public.site_member_lists where owner = p_ann) > 0);
  perform tests.q(ann, a_e, format($q$public.comment_add(%L, %L, 'ann was here')$q$, p_ann, post_eve::uuid));
  perform tests.q(bob, b_e, format($q$public.comment_add(%L, %L, 'bob was here')$q$, p_bob, post1::uuid));
  perform tests.q(ann, a_e, format($q$public.post_like(%L, %L, true)$q$, p_ann, post_eve::uuid));
  delete from auth.users where id = ann;
  perform tests.assert_eq('deleting the account removes her posts', (select count(*) from public.site_posts where author in (p_ann, p_dj))::int, 0);
  perform tests.assert_eq('...their media rows', (select count(*) from public.site_post_media m where not exists (select 1 from public.site_posts p where p.id = m.post))::int, 0);
  perform tests.assert_eq('...her comments on other people''s posts', (select count(*) from public.site_comments where body = 'ann was here')::int, 0);
  perform tests.assert_eq('...her likes', (select count(*) from public.site_post_likes where profile = p_ann)::int, 0);
  perform tests.assert_eq('...her Members Only list', (select count(*) from public.site_member_lists where owner = p_ann or member = p_ann)::int, 0);
  perform tests.assert_eq('...and comments on her posts', (select count(*) from public.site_comments where body = 'bob was here')::int, 0);
  perform tests.assert_eq('other people''s posts are untouched', (select count(*) from public.site_posts where author in (p_eve, p_club))::int >= 2, true);
  perform tests.assert_eq('her files stay in storage for the clean-up job (the database cannot delete a file)', (select count(*) from storage.objects where name like p_ann::text || '/%')::int >= 2, true);
end $$;

rollback;
