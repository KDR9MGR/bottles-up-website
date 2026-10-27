-- Safety and moderation. What matters most: a person can report only what they can SEE, once, never their own, and is never told what came of it; the queue and every
-- decision are for BottlesUp admins only and are written to the audit log; removing hides a thing from everyone, suspending hides the whole person (all their profiles) and
-- stops them acting, restoring undoes both; reporters are counted, never named; reporting needs no community rules; the report keeps what was said after it is deleted.
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
-- A field of every element of a json list, in order.
create function tests.names(p_user uuid, p_email text, p_expr text, p_field text default 'id') returns text language plpgsql as $$
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

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  ann constant uuid := '00000000-0000-0000-0000-0000000008a1';     -- writes things that get reported
  bob constant uuid := '00000000-0000-0000-0000-0000000008a2';     -- reports; follows ann
  cy constant uuid := '00000000-0000-0000-0000-0000000008a3';      -- reports; also writes a comment, a review and a message
  dee constant uuid := '00000000-0000-0000-0000-0000000008a4';     -- a private profile
  olly constant uuid := '00000000-0000-0000-0000-0000000008a5';    -- owns Club A
  newbie constant uuid := '00000000-0000-0000-0000-0000000008a6';  -- has not accepted the community rules
  a_e constant text := 'ann@safety.example'; b_e constant text := 'bob@safety.example'; c_e constant text := 'cy@safety.example'; d_e constant text := 'dee@safety.example';
  o_e constant text := 'olly@safety.example'; n_e constant text := 'newbie@safety.example'; adm constant text := 'admin@test.example';
  p_ann uuid; p_bob uuid; p_cy uuid; p_dee uuid; p_olly uuid; p_newbie uuid; p_dj uuid; p_club uuid;
  org uuid; va uuid; tgt uuid; post1 uuid; post_dee uuid; post_story uuid; post_cy uuid; cm1 uuid; rv1 uuid; conv uuid; msg1 uuid; msg2 uuid; r1 text; n int; lst text;
begin
  insert into auth.users (id, email) values (ann, a_e), (bob, b_e), (cy, c_e), (dee, d_e), (olly, o_e), (newbie, n_e);
  insert into public.profiles (id, name, email) values (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (cy, 'Cy Rus', c_e), (dee, 'Dee Dee', d_e), (olly, 'Olly Owner', o_e), (newbie, 'New Bie', n_e);
  perform tests.login(admin_u, adm); perform public.cms_set_feature('social', true); perform public.cms_set_feature('inbox', true); perform public.cms_set_feature('reviews', true); perform tests.logout();
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'annie', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bob', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(cy, c_e); perform public.save_my_profile('Cy Rus', 'cyrus', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(dee, d_e); perform public.save_my_profile('Dee Dee', 'dee', 'Toronto'); perform public.profile_save_personal('private');
  perform tests.login(olly, o_e); perform public.save_my_profile('Olly Owner', 'olly', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(newbie, n_e); perform public.save_my_profile('New Bie', 'newbie', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.logout();
  select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal'; select id into p_bob from public.site_profiles where user_id = bob and kind = 'personal';
  select id into p_cy from public.site_profiles where user_id = cy and kind = 'personal'; select id into p_dee from public.site_profiles where user_id = dee and kind = 'personal';
  select id into p_olly from public.site_profiles where user_id = olly and kind = 'personal'; select id into p_newbie from public.site_profiles where user_id = newbie and kind = 'personal';
  perform tests.q(ann, a_e, $q$public.profile_create_business('dj', 'DJ Ann', 'djann')$q$);
  select id into p_dj from public.site_profiles where handle = 'djann';
  perform tests.login(olly, o_e);
  org := public.create_organization('Club Co', 'venue_owner'); va := public.create_org_venue(org, 'Club A');
  perform tests.logout();
  perform tests.q(olly, o_e, format($q$public.profile_create_business('venue', 'Club A', 'clubaclub', null, null, null, %L)$q$, va));
  select id into p_club from public.site_profiles where venue_id = va;
  perform tests.q(ann, a_e, 'public.rules_accept(1)'); perform tests.q(bob, b_e, 'public.rules_accept(1)'); perform tests.q(cy, c_e, 'public.rules_accept(1)'); perform tests.q(dee, d_e, 'public.rules_accept(1)');
  perform tests.q(olly, o_e, 'public.rules_accept(1)');
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann));

  insert into public.site_posts (author, kind, caption, audience) values (p_ann, 'post', 'Buy my stuff now', 'public') returning id into post1;
  insert into public.site_posts (author, kind, caption, audience) values (p_dee, 'post', 'Private thoughts', 'followers') returning id into post_dee;
  insert into public.site_posts (author, kind, caption, audience, expires_at) values (p_ann, 'story', null, 'public', now() + interval '20 hours') returning id into post_story;
  insert into public.site_comments (post, author, body) values (post1, p_cy, 'you are awful') returning id into cm1;
  insert into public.site_reviews (kind, venue_id, author, rating, body) values ('venue', va, p_cy, 1, 'Worst night ever') returning id into rv1;
  conv := (tests.f(cy, c_e, format($q$public.dm_start_direct(%L, %L)$q$, p_cy, p_bob), '{id}'))::uuid;
  msg1 := (tests.f(cy, c_e, format($q$public.dm_send(%L, %L, 'you will regret this')$q$, p_cy, conv), '{id}'))::uuid;

  ---------------------------------------------------------------- reporting a post
  perform tests.assert_eq('a report is made, and it says it is new', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_bob, post1)) like '%"already": false%', true);
  perform tests.assert_eq('...it is kept with the reporter, what it is about, whose it is and what it said', (select r.reporter::text || '/' || r.kind || '/' || r.target_profile::text || '/' || r.excerpt || '/' || r.reason || '/' || r.status from public.site_reports r where r.target = post1),
    p_bob::text || '/post/' || p_ann::text || '/Buy my stuff now/spam/open');
  perform tests.assert_eq('the same report again is the same report, said back as already', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', %L, 'hate', 'second thoughts')$q$, p_bob, post1)) like '%"already": true%', true);
  perform tests.assert_eq('...nothing new is stored and the first reason stands', (select count(*)::text || '/' || min(reason) from public.site_reports where target = post1), '1/spam');
  perform tests.assert_eq('another person reporting it is a second report', tests.q(cy, c_e, format($q$public.report_create(%L, 'post', %L, 'scam', '  They want my money  ')$q$, p_cy, post1)) like '%"already": false%', true);
  perform tests.assert_eq('...with their words trimmed', (select details from public.site_reports where target = post1 and reporter = p_cy), 'They want my money');
  perform tests.assert_eq('blank words are kept as nothing', (select details is null from public.site_reports where target = post1 and reporter = p_bob), true);
  perform tests.assert_eq('you cannot report your own post', tests.q(ann, a_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_ann, post1)), 'ERROR: You can''t report your own profile or what you wrote.');
  perform tests.assert_eq('...nor from your other profile', tests.q(ann, a_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_dj, post1)), 'ERROR: You can''t report your own profile or what you wrote.');
  perform tests.assert_eq('a post you cannot see cannot be reported, in the same sentence as one that is not there', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_bob, post_dee)), 'ERROR: This isn''t available.');
  perform tests.assert_eq('...a made-up one', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', gen_random_uuid(), 'spam')$q$, p_bob)), 'ERROR: This isn''t available.');
  perform tests.assert_eq('...no target at all', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', null, 'spam')$q$, p_bob)), 'ERROR: This isn''t available.');
  perform tests.assert_eq('a story can be reported as a post (it keeps a note of what it is)', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', %L, 'sexual')$q$, p_bob, post_story)) like '%"already": false%', true);
  perform tests.assert_eq('...with no caption the excerpt says what it is', (select excerpt from public.site_reports where target = post_story), '(story with no caption)');
  perform tests.assert_eq('an unknown kind', tests.q(bob, b_e, format($q$public.report_create(%L, 'chat', %L, 'spam')$q$, p_bob, post1)), 'ERROR: Say what you are reporting.');
  perform tests.assert_eq('...no kind', tests.q(bob, b_e, format($q$public.report_create(%L, null, %L, 'spam')$q$, p_bob, post1)), 'ERROR: Say what you are reporting.');
  perform tests.assert_eq('an unknown reason', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', %L, 'boring')$q$, p_bob, post1)), 'ERROR: Choose a reason.');
  perform tests.assert_eq('...no reason', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', %L, null)$q$, p_bob, post1)), 'ERROR: Choose a reason.');
  perform tests.assert_eq('words over 500 characters', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', %L, 'spam', repeat('x', 501))$q$, p_bob, post_story)), 'ERROR: Keep it to 500 characters.');
  perform tests.assert_eq('someone else''s profile cannot report as you', tests.q(bob, b_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_cy, post1)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('reporting needs no community rules', tests.q(newbie, n_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_newbie, post1)) like '%"already": false%', true);
  perform tests.assert_eq('a blocked author''s post is gone from the reporter''s view, so it cannot be reported either', tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_ann)) || '/' || tests.q(bob, b_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_bob, post_story)), '{"blocked": true}/ERROR: This isn''t available.');
  perform tests.q(bob, b_e, format($q$public.block_set(%L, %L, false)$q$, p_bob, p_ann));
  perform tests.login(admin_u, adm); perform public.cms_set_feature('social', false); perform tests.logout();
  perform tests.assert_eq('with social switched off reporting is closed', tests.q(cy, c_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_cy, post_story)), 'ERROR: Reporting is not open yet.');
  perform tests.login(admin_u, adm); perform public.cms_set_feature('social', true); perform tests.logout();

  ---------------------------------------------------------------- reporting a comment, a profile, a message, a review
  perform tests.assert_eq('a comment', tests.q(bob, b_e, format($q$public.report_create(%L, 'comment', %L, 'harassment')$q$, p_bob, cm1)) like '%"already": false%', true);
  perform tests.assert_eq('...keeps what it said', (select excerpt || '/' || target_profile::text from public.site_reports where target = cm1), 'you are awful/' || p_cy::text);
  perform tests.assert_eq('...not your own comment', tests.q(cy, c_e, format($q$public.report_create(%L, 'comment', %L, 'spam')$q$, p_cy, cm1)), 'ERROR: You can''t report your own profile or what you wrote.');
  perform tests.assert_eq('...nor one on a post you cannot see', tests.q(bob, b_e, format($q$public.report_create(%L, 'comment', %L, 'spam')$q$, p_bob, (select id from public.site_comments where false union all select gen_random_uuid() limit 1))), 'ERROR: This isn''t available.');
  insert into public.site_comments (post, author, body) values (post_dee, p_dee, 'hidden words');
  perform tests.assert_eq('...nor one that is on a post of a private profile you do not follow', tests.q(bob, b_e, format($q$public.report_create(%L, 'comment', %L, 'spam')$q$, p_bob, (select id from public.site_comments where body = 'hidden words'))), 'ERROR: This isn''t available.');
  perform tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_cy));
  perform tests.assert_eq('...nor one by someone bob has blocked, even one he reported before (it is gone from his view)', tests.q(bob, b_e, format($q$public.report_create(%L, 'comment', %L, 'spam')$q$, p_bob, cm1)), 'ERROR: This isn''t available.');
  perform tests.assert_eq('...a review by someone he has blocked', tests.q(bob, b_e, format($q$public.report_create(%L, 'review', %L, 'spam')$q$, p_bob, rv1)), 'ERROR: This isn''t available.');
  perform tests.q(bob, b_e, format($q$public.block_set(%L, %L, false)$q$, p_bob, p_cy));
  perform tests.assert_eq('a profile', tests.q(bob, b_e, format($q$public.report_create(%L, 'profile', %L, 'impersonation')$q$, p_bob, p_cy)) like '%"already": false%', true);
  perform tests.assert_eq('...is kept with its name', (select excerpt || '/' || target_profile::text from public.site_reports where kind = 'profile' and target = p_cy), 'Cy Rus (@cyrus)/' || p_cy::text);
  perform tests.assert_eq('...not your own', tests.q(bob, b_e, format($q$public.report_create(%L, 'profile', %L, 'spam')$q$, p_bob, p_bob)), 'ERROR: You can''t report your own profile or what you wrote.');
  perform tests.assert_eq('...nor your other profile', tests.q(ann, a_e, format($q$public.report_create(%L, 'profile', %L, 'spam')$q$, p_ann, p_dj)), 'ERROR: You can''t report your own profile or what you wrote.');
  perform tests.assert_eq('...a business profile can be reported', tests.q(bob, b_e, format($q$public.report_create(%L, 'profile', %L, 'scam')$q$, p_bob, p_dj)) like '%"already": false%', true);
  perform tests.assert_eq('...words that are only spaces are a report with no words', tests.q(newbie, n_e, format($q$public.report_create(%L, 'profile', %L, 'scam', '    ')$q$, p_newbie, p_dj)) like '%"already": false%', true);
  perform tests.assert_eq('...and are stored as nothing', (select details is null from public.site_reports where reporter = p_newbie and target = p_dj), true);
  perform tests.assert_eq('...a venue''s profile too', tests.q(bob, b_e, format($q$public.report_create(%L, 'profile', %L, 'other')$q$, p_bob, p_club)) like '%"already": false%', true);
  perform tests.assert_eq('...one that does not exist', tests.q(bob, b_e, format($q$public.report_create(%L, 'profile', gen_random_uuid(), 'spam')$q$, p_bob)), 'ERROR: This isn''t available.');
  perform tests.assert_eq('a message in a conversation you are in', tests.q(bob, b_e, format($q$public.report_create(%L, 'message', %L, 'harassment', 'threat')$q$, p_bob, msg1)) like '%"already": false%', true);
  perform tests.assert_eq('...keeps what it said', (select excerpt || '/' || target_profile::text from public.site_reports where target = msg1), 'you will regret this/' || p_cy::text);
  perform tests.assert_eq('...not one in a conversation you are not in', tests.q(dee, d_e, format($q$public.report_create(%L, 'message', %L, 'spam')$q$, p_dee, msg1)), 'ERROR: This isn''t available.');
  perform tests.assert_eq('...not your own', tests.q(cy, c_e, format($q$public.report_create(%L, 'message', %L, 'spam')$q$, p_cy, msg1)), 'ERROR: You can''t report your own profile or what you wrote.');
  msg2 := (tests.f(cy, c_e, format($q$public.dm_send(%L, %L, 'look at this', null, 'post', %L)$q$, p_cy, conv, post1), '{id}'))::uuid;
  perform tests.assert_eq('...a shared post is reported as new', tests.q(bob, b_e, format($q$public.report_create(%L, 'message', %L, 'spam')$q$, p_bob, msg2)) like '%"already": false%', true);
  perform tests.assert_eq('...and kept as a shared post with its note', (select coalesce(excerpt, '(null)') from public.site_reports where target = msg2), '[shared post] look at this');
  perform tests.assert_eq('a removed message cannot be reported', tests.q(cy, c_e, format($q$public.dm_delete_message(%L, %L)$q$, p_cy, msg2)) || '/' || tests.q(bob, b_e, format($q$public.report_create(%L, 'message', %L, 'spam')$q$, p_bob, msg2)), '{"removed": true}/ERROR: This isn''t available.');
  perform tests.assert_eq('a review', tests.q(bob, b_e, format($q$public.report_create(%L, 'review', %L, 'other')$q$, p_bob, rv1)) like '%"already": false%', true);
  perform tests.assert_eq('...keeps what it said', (select excerpt from public.site_reports where target = rv1), 'Rating 1/5: Worst night ever');
  perform tests.assert_eq('...not your own', tests.q(cy, c_e, format($q$public.report_create(%L, 'review', %L, 'spam')$q$, p_cy, rv1)), 'ERROR: You can''t report your own profile or what you wrote.');
  update public.site_profiles set status = 'suspended' where id = p_dee;
  perform tests.assert_eq('a suspended profile cannot be reported, it is already gone', tests.q(bob, b_e, format($q$public.report_create(%L, 'profile', %L, 'spam')$q$, p_bob, p_dee)), 'ERROR: This isn''t available.');
  update public.site_profiles set status = 'active' where id = p_dee;

  ---------------------------------------------------------------- 20 reports a day
  insert into public.site_reports (reporter, kind, target, reason, created_at) select p_dee, 'profile', gen_random_uuid(), 'spam', now() - interval '2 hours' from generate_series(1, 19);
  perform tests.assert_eq('with 19 reports in a day the 20th is allowed', tests.q(dee, d_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_dee, post1)) like '%"already": false%', true);
  perform tests.assert_eq('...and then the next is slowed', tests.q(dee, d_e, format($q$public.report_create(%L, 'profile', %L, 'spam')$q$, p_dee, p_olly)), 'ERROR: You have sent a lot of reports today. Our team is looking at them.');
  perform tests.assert_eq('...but a report already made is still said back as made', tests.q(dee, d_e, format($q$public.report_create(%L, 'post', %L, 'spam')$q$, p_dee, post1)) like '%"already": true%', true);
  update public.site_reports set created_at = now() - interval '36 hours' where reporter = p_dee and kind = 'profile';
  perform tests.assert_eq('...reports older than a day do not count, even from yesterday', tests.q(dee, d_e, format($q$public.report_create(%L, 'profile', %L, 'spam')$q$, p_dee, p_olly)) like '%"already": false%', true);
  perform tests.assert_eq('...and nobody else is slowed', tests.q(cy, c_e, format($q$public.report_create(%L, 'profile', %L, 'spam')$q$, p_cy, p_olly)) like '%"already": false%', true);
  delete from public.site_reports where reporter = p_dee;

  ---------------------------------------------------------------- the tables and functions are closed
  perform tests.login(bob, b_e);
  perform tests.assert_raises('nobody reads the reports directly', $q$select * from public.site_reports$q$, 'permission denied');
  perform tests.assert_raises('...nor writes one', format($q$insert into public.site_reports (kind, target, reason) values ('post', %L, 'spam')$q$, post1), 'permission denied');
  perform tests.assert_raises('...nor lists the queue as a function', $q$select public.moderation_person_profiles(gen_random_uuid())$q$, 'permission denied');
  perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot report', format($q$select public.report_create(%L, 'post', %L, 'spam')$q$, p_bob, post1), 'permission denied');
  perform tests.assert_raises('...nor ask for the queue', $q$select public.cms_reports_list()$q$, 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the queue
  update public.site_reports set excerpt = 'changed since' where target = post1 and reporter = p_newbie;
  perform tests.assert_eq('a customer cannot read the queue', tests.q(bob, b_e, 'public.cms_reports_list()'), 'ERROR: Only a BottlesUp admin can see this.');
  perform tests.assert_eq('...an unknown filter', tests.q(admin_u, adm, $q$public.cms_reports_list('mine')$q$), 'ERROR: Choose open, actioned, dismissed or all.');
  perform tests.assert_eq('the queue groups reports by the thing reported, oldest first', tests.names(admin_u, adm, 'public.cms_reports_list()', 'kind'), 'post,post,comment,profile,profile,profile,message,message,review,profile');
  perform tests.assert_eq('...the post was reported three times by three people for three reasons', tests.f(admin_u, adm, 'public.cms_reports_list()', '{0,reports}') || '/' || tests.f(admin_u, adm, 'public.cms_reports_list()', '{0,reporters}') || '/' || tests.f(admin_u, adm, 'public.cms_reports_list()', '{0,reasons}'), '3/3/["scam", "spam"]');
  perform tests.assert_eq('...with what it said, whose it is, and how it stands now', tests.f(admin_u, adm, 'public.cms_reports_list()', '{0,excerpt}') || '/' || tests.f(admin_u, adm, 'public.cms_reports_list()', '{0,profile,handle}') || '/' || tests.f(admin_u, adm, 'public.cms_reports_list()', '{0,state}'), 'Buy my stuff now/annie/active');
  perform tests.assert_eq('...and the words reporters added (never who wrote them)', tests.f(admin_u, adm, 'public.cms_reports_list()', '{0,details}'), '["They want my money"]');
  lst := tests.q(admin_u, adm, $q$public.cms_reports_list('all', 100)$q$);
  perform tests.assert_eq('reporters are counted, never named', position(p_bob::text in lst) = 0 and position(p_newbie::text in lst) = 0 and position(bob::text in lst) = 0, true);
  perform tests.assert_eq('a limit and an offset page the queue', tests.names(admin_u, adm, $q$public.cms_reports_list('open', 2, 1)$q$, 'kind'), 'post,comment');
  -- the page size is capped, floored and defaulted; the details shown are capped; something that no longer exists says so
  insert into public.site_reports (reporter, kind, target, reason, details, created_at) select null, 'post', gen_random_uuid(), 'spam', 'detail ' || g, now() + interval '1 hour' from generate_series(1, 105) g;
  perform tests.assert_eq('a huge page is cut to 100, a zero page to 1, and no size means 50', tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_reports_list('open', 500))$q$) || '/' || tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_reports_list('open', 0))$q$) || '/' || tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_reports_list('open', null))$q$), '100/1/50');
  perform tests.assert_eq('a negative offset is the start', tests.names(admin_u, adm, $q$public.cms_reports_list('open', 2, -5)$q$, 'kind'), tests.names(admin_u, adm, $q$public.cms_reports_list('open', 2, 0)$q$, 'kind'));
  delete from public.site_reports where reporter is null;
  tgt := gen_random_uuid();
  insert into public.site_reports (reporter, kind, target, reason, details, created_at) select null, 'post', tgt, 'spam', 'detail ' || g, now() + interval '1 hour' + g * interval '1 second' from generate_series(1, 7) g;
  perform tests.assert_eq('only five of the reporters'' words are shown, the first five', tests.q(admin_u, adm, format($q$(select jsonb_array_length(e -> 'details')::text || '/' || (e -> 'details' ->> 0) || '/' || (e ->> 'reports') || '/' || (e ->> 'state') from jsonb_array_elements(public.cms_reports_list('open', 100)) e where e ->> 'target' = %L)$q$, tgt)), '5/detail 1/7/gone');
  delete from public.site_reports where reporter is null;
  perform tests.assert_eq('nothing handled yet', tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_reports_list('actioned'))$q$) || '/' || tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_reports_list('dismissed'))$q$), '0/0');

  ---------------------------------------------------------------- deciding
  perform tests.assert_eq('only a BottlesUp admin decides', tests.q(bob, b_e, format($q$public.cms_report_resolve('post', %L, 'dismiss')$q$, post1)), 'ERROR: Only a BottlesUp admin can change this.');
  perform tests.assert_eq('...an unknown action', tests.q(admin_u, adm, format($q$public.cms_report_resolve('post', %L, 'ban')$q$, post1)), 'ERROR: Choose dismiss, remove, suspend or restore.');
  perform tests.assert_eq('...an unknown kind', tests.q(admin_u, adm, format($q$public.cms_report_resolve('chat', %L, 'dismiss')$q$, post1)), 'ERROR: Say what was reported.');
  perform tests.assert_eq('...no target', tests.q(admin_u, adm, $q$public.cms_report_resolve('post', null, 'dismiss')$q$), 'ERROR: Say what was reported.');
  perform tests.assert_eq('...something nobody reported', tests.q(admin_u, adm, $q$public.cms_report_resolve('post', gen_random_uuid(), 'dismiss')$q$), 'ERROR: Nobody has reported this.');
  perform tests.assert_eq('...a note that is too long', tests.q(admin_u, adm, format($q$public.cms_report_resolve('post', %L, 'dismiss', repeat('n', 501))$q$, post1)), 'ERROR: Keep the note to 500 characters.');
  perform tests.assert_eq('dismissing the comment', tests.f(admin_u, adm, format($q$public.cms_report_resolve('comment', %L, 'dismiss', 'fine')$q$, cm1), '{handled}'), '1');
  perform tests.assert_eq('...it leaves the open queue', position('comment' in tests.names(admin_u, adm, 'public.cms_reports_list()', 'kind')) = 0, true);
  perform tests.assert_eq('...and is in the dismissed list with the note', tests.f(admin_u, adm, $q$public.cms_reports_list('dismissed')$q$, '{0,note}') || '/' || tests.f(admin_u, adm, $q$public.cms_reports_list('dismissed')$q$, '{0,action}'), 'fine/dismissed');
  perform tests.assert_eq('...and who decided is kept', (select count(*)::int from public.site_reports where target = cm1 and status = 'dismissed' and handled_by = admin_u and handled_at is not null), 1);
  perform tests.assert_eq('...the comment is still there', tests.f(bob, b_e, format($q$public.comment_list(%L, %L) -> 0$q$, p_bob, post1), '{body}'), 'you are awful');
  perform tests.assert_eq('...dismissing twice is refused', tests.q(admin_u, adm, format($q$public.cms_report_resolve('comment', %L, 'dismiss')$q$, cm1)), 'ERROR: These reports have already been handled.');
  perform tests.assert_eq('...and so is removing what was already decided', tests.q(admin_u, adm, format($q$public.cms_report_resolve('comment', %L, 'remove')$q$, cm1)), 'ERROR: These reports have already been handled.');
  perform tests.assert_eq('someone else reporting it later is a new open group, separate from the one dismissed', tests.q(newbie, n_e, format($q$public.report_create(%L, 'comment', %L, 'spam')$q$, p_newbie, cm1)) like '%"already": false%', true);
  perform tests.assert_eq('...with only its own reason', tests.q(admin_u, adm, format($q$(select (e -> 'reasons')::text from jsonb_array_elements(public.cms_reports_list('open', 100)) e where e ->> 'target' = %L)$q$, cm1)), '["spam"]');
  perform tests.assert_eq('...counted on its own', tests.q(admin_u, adm, format($q$(select e ->> 'reports' from jsonb_array_elements(public.cms_reports_list('open', 100)) e where e ->> 'target' = %L)$q$, cm1)), '1');
  perform tests.f(admin_u, adm, format($q$public.cms_report_resolve('comment', %L, 'dismiss', 'again')$q$, cm1), '{handled}');
  perform tests.assert_eq('...and dismissed on its own, so the list has two decisions about it', tests.q(admin_u, adm, format($q$(select count(*) from jsonb_array_elements(public.cms_reports_list('dismissed', 100)) e where e ->> 'target' = %L)$q$, cm1)), '2');
  delete from public.site_reports where reporter = p_newbie and target = cm1;
  perform tests.assert_eq('the same person reporting it again says already, nothing reopens', tests.q(bob, b_e, format($q$public.report_create(%L, 'comment', %L, 'harassment')$q$, p_bob, cm1)) like '%"already": true%', true);

  perform tests.assert_eq('removing the post', tests.f(admin_u, adm, format($q$public.cms_report_resolve('post', %L, 'remove', 'spam')$q$, post1), '{handled}'), '3');
  perform tests.assert_eq('...it is gone for the reporter, for everyone, and for the writer', tests.q(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1)) || '/' || tests.q(ann, a_e, format($q$public.post_get(%L, %L)$q$, p_ann, post1)), 'ERROR: This post isn''t available./ERROR: This post isn''t available.');
  perform tests.assert_eq('...the queue says so', tests.f(admin_u, adm, $q$public.cms_reports_list('actioned')$q$, '{0,state}') || '/' || tests.f(admin_u, adm, $q$public.cms_reports_list('actioned')$q$, '{0,action}') || '/' || tests.f(admin_u, adm, $q$public.cms_reports_list('actioned')$q$, '{0,reports}'), 'removed/removed/3');
  perform tests.assert_eq('...and the audit log', (select count(*)::int from public.audit_log where action = 'report_remove' and entity_id = post1::text and details ->> 'note' = 'spam'), 1);
  perform tests.assert_eq('restoring the post', tests.f(admin_u, adm, format($q$public.cms_report_resolve('post', %L, 'restore', 'mistake')$q$, post1), '{handled}'), '3');
  perform tests.assert_eq('...it is back', tests.f(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1), '{caption}'), 'Buy my stuff now');
  perform tests.assert_eq('...and the reports are marked restored, not actioned', (select string_agg(distinct status || ':' || action, ',') from public.site_reports where target = post1), 'dismissed:restored');
  perform tests.assert_eq('...which leaves nothing open for it', (select count(*)::int from public.site_reports where target = post1 and status = 'open'), 0);

  update public.site_reports set status = 'open', action = null, note = null, handled_at = null, handled_by = null where target = cm1;
  perform tests.assert_eq('removing a comment takes it out of the list', tests.f(admin_u, adm, format($q$public.cms_report_resolve('comment', %L, 'remove')$q$, cm1), '{handled}') || '/' || tests.names(bob, b_e, format($q$public.comment_list(%L, %L)$q$, p_bob, post1)), '1/(none)');
  perform tests.assert_eq('removing a message shows it as removed, and without its words', tests.f(admin_u, adm, format($q$public.cms_report_resolve('message', %L, 'remove')$q$, msg1), '{handled}') || '/' ||
    tests.q(bob, b_e, format($q$(select (e ->> 'removed') || '/' || coalesce(e ->> 'body', 'no words') from jsonb_array_elements(public.dm_messages(%L, %L)) e where e ->> 'id' = %L)$q$, p_bob, conv, msg1)), '1/true/no words');
  perform tests.assert_eq('removing a review takes it out of the list', tests.f(admin_u, adm, format($q$public.cms_report_resolve('review', %L, 'remove')$q$, rv1), '{handled}') || '/' || tests.names(bob, b_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items'$q$, p_bob, va)), '1/(none)');
  perform tests.assert_eq('the queue says what became of each thing', tests.q(admin_u, adm, $q$(select string_agg(e ->> 'kind' || ':' || (e ->> 'state'), ',' order by e ->> 'kind') from jsonb_array_elements(public.cms_reports_list('actioned', 100)) e)$q$), 'comment:removed,message:removed,review:removed');
  perform tests.assert_eq('a removed review cannot be reported', tests.q(newbie, n_e, format($q$public.report_create(%L, 'review', %L, 'spam')$q$, p_newbie, rv1)), 'ERROR: This isn''t available.');
  perform tests.assert_eq('...nor a removed comment', tests.q(newbie, n_e, format($q$public.report_create(%L, 'comment', %L, 'spam')$q$, p_newbie, cm1)), 'ERROR: This isn''t available.');
  perform tests.assert_eq('restoring the comment brings it back', tests.f(admin_u, adm, format($q$public.cms_report_resolve('comment', %L, 'restore')$q$, cm1), '{handled}') || '/' || tests.names(bob, b_e, format($q$public.comment_list(%L, %L)$q$, p_bob, post1), 'body'), '1/you are awful');
  perform tests.assert_eq('restoring the review brings it back', tests.f(admin_u, adm, format($q$public.cms_report_resolve('review', %L, 'restore')$q$, rv1), '{handled}') || '/' || tests.names(bob, b_e, format($q$(public.reviews_list(%L, 'venue', %L)) -> 'items'$q$, p_bob, va)), '1/' || rv1::text);
  perform tests.assert_eq('a profile is suspended, not removed', tests.q(admin_u, adm, format($q$public.cms_report_resolve('profile', %L, 'remove')$q$, p_cy)), 'ERROR: A profile is suspended, not removed.');

  ---------------------------------------------------------------- suspending a person
  update public.site_reports set status = 'open', action = null, note = null, handled_at = null, handled_by = null where target = post1 and reporter = p_bob;
  r1 := tests.f(admin_u, adm, format($q$public.cms_report_resolve('post', %L, 'suspend', 'repeat offender')$q$, post1), '{handled}');
  perform tests.assert_eq('suspending from a report on her post handles it and suspends every profile ann owns', r1 || '/' || (select count(*)::int from public.site_profiles where user_id = ann and status = 'suspended'), '1/2');
  perform tests.assert_eq('...her personal profile and her DJ profile', (select count(*)::int from public.site_profiles where user_id = ann and kind = 'personal' and status = 'suspended'), 1);
  perform tests.assert_eq('...other people''s profiles are untouched', (select count(*)::int from public.site_profiles where id in (p_bob, p_cy, p_dee, p_olly, p_club) and status = 'active'), 5);
  perform tests.assert_eq('she cannot act', tests.q(ann, a_e, format($q$public.post_like(%L, %L, true)$q$, p_ann, post1)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...nor as her DJ profile', tests.q(ann, a_e, format($q$public.post_like(%L, %L, true)$q$, p_dj, post1)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('she is gone from everyone else''s view', tests.q(bob, b_e, format($q$public.profile_get(%L, 'annie')$q$, p_bob)) || '/' || tests.q(bob, b_e, format($q$public.post_get(%L, %L)$q$, p_bob, post1)), 'ERROR: This profile isn''t available./ERROR: This post isn''t available.');
  perform tests.assert_eq('...her DJ profile too', tests.q(bob, b_e, format($q$public.profile_get(%L, 'djann')$q$, p_bob)), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('...the queue shows the profile as suspended', tests.f(admin_u, adm, $q$public.cms_reports_list('actioned')$q$, '{0,profile,status}'), 'suspended');
  perform tests.assert_eq('...she still has her login (her profiles list says so)', tests.f(ann, a_e, 'public.profile_my_profiles()', '{0,status}'), 'suspended');
  r1 := tests.f(admin_u, adm, format($q$public.cms_report_resolve('post', %L, 'restore', 'appeal upheld')$q$, post1), '{handled}');
  perform tests.assert_eq('restoring brings the whole person back', r1 || '/' || (select count(*)::int from public.site_profiles where user_id = ann and status = 'active'), '1/2');
  perform tests.assert_eq('...she can act again', tests.q(ann, a_e, format($q$public.post_like(%L, %L, true)$q$, p_ann, post1)) not like 'ERROR%', true);
  update public.site_reports set target_profile = null where target = post_story;
  perform tests.assert_eq('there must be a profile left to suspend', tests.q(admin_u, adm, format($q$public.cms_report_resolve('post', %L, 'suspend')$q$, post_story)), 'ERROR: There is no profile left to suspend.');
  r1 := tests.f(admin_u, adm, format($q$public.cms_report_resolve('profile', %L, 'suspend', 'fake venue')$q$, p_club), '{handled}');
  perform tests.assert_eq('a venue''s profile is suspended on its own, not the owner behind it', r1 || '/' || (select status from public.site_profiles where id = p_club) || '/' || (select status from public.site_profiles where id = p_olly), '1/suspended/active');
  perform tests.assert_eq('...and the queue shows a suspended profile as suspended', tests.q(admin_u, adm, $q$(select e ->> 'state' from jsonb_array_elements(public.cms_reports_list('actioned', 100)) e where e ->> 'kind' = 'profile')$q$), 'suspended');
  r1 := tests.f(admin_u, adm, format($q$public.cms_report_resolve('profile', %L, 'restore')$q$, p_club), '{handled}');
  perform tests.assert_eq('...and restored the same way', r1 || '/' || (select status from public.site_profiles where id = p_club), '1/active');
  perform tests.assert_eq('restoring the message brings its words back', tests.f(admin_u, adm, format($q$public.cms_report_resolve('message', %L, 'restore')$q$, msg1), '{handled}') || '/' ||
    tests.q(bob, b_e, format($q$(select e ->> 'body' from jsonb_array_elements(public.dm_messages(%L, %L)) e where e ->> 'id' = %L)$q$, p_bob, conv, msg1)), '1/you will regret this');

  ---------------------------------------------------------------- finding a profile and suspending it without a report
  perform tests.assert_eq('only an admin looks people up', tests.q(bob, b_e, $q$public.cms_find_profiles('ann')$q$), 'ERROR: Only a BottlesUp admin can see this.');
  perform tests.assert_eq('...two letters at least', tests.q(admin_u, adm, $q$public.cms_find_profiles('a')$q$), 'ERROR: Type at least 2 letters.');
  perform tests.assert_eq('...by username or name', tests.names(admin_u, adm, $q$public.cms_find_profiles('ann')$q$, 'handle'), 'annie');
  perform tests.assert_eq('...capital letters do not matter', tests.names(admin_u, adm, $q$public.cms_find_profiles('  ANN ')$q$, 'handle'), 'annie');
  perform tests.assert_eq('...a business profile by its username', tests.names(admin_u, adm, $q$public.cms_find_profiles('djann')$q$, 'handle'), 'djann');
  perform tests.assert_eq('...by the start of a name', tests.names(admin_u, adm, $q$public.cms_find_profiles('cy ')$q$, 'handle'), 'cyrus');
  perform tests.assert_eq('...a percent sign or an underscore is text, not a wildcard', tests.names(admin_u, adm, $q$public.cms_find_profiles('%%')$q$, 'handle') || '/' || tests.names(admin_u, adm, $q$public.cms_find_profiles('__')$q$, 'handle'), '(none)/(none)');
  perform tests.assert_eq('only an admin changes a profile''s standing', tests.q(bob, b_e, format($q$public.cms_profile_set_status(%L, true)$q$, p_cy)), 'ERROR: Only a BottlesUp admin can change this.');
  perform tests.assert_eq('...a profile that does not exist', tests.q(admin_u, adm, $q$public.cms_profile_set_status(gen_random_uuid(), true)$q$), 'ERROR: There is no such profile.');
  perform tests.assert_eq('...a note of 501 characters is too long', tests.q(admin_u, adm, format($q$public.cms_profile_set_status(%L, true, repeat('n', 501))$q$, p_cy)), 'ERROR: Keep the note to 500 characters.');
  perform tests.assert_eq('...500 is fine', tests.f(admin_u, adm, format($q$public.cms_profile_set_status(%L, false, repeat('n', 500))$q$, p_cy), '{suspended}'), 'false');
  perform tests.assert_eq('...a choice is needed', tests.q(admin_u, adm, format($q$public.cms_profile_set_status(%L, null)$q$, p_cy)), 'ERROR: Choose suspend or restore.');
  r1 := tests.f(admin_u, adm, format($q$public.cms_profile_set_status(%L, true, 'abuse')$q$, p_dj), '{profiles}');
  perform tests.assert_eq('suspending the person behind a DJ profile suspends her personal one too', r1 || '/' || (select count(*)::int from public.site_profiles where user_id = ann and status = 'suspended'), '2/2');
  insert into auth.users (id, email) select ('00000000-0000-0000-0002-' || lpad(g::text, 12, '0'))::uuid, 'qq' || g || '@safety.example' from generate_series(1, 25) g;
  insert into public.profiles (id, name, email, username) select ('00000000-0000-0000-0002-' || lpad(g::text, 12, '0'))::uuid, 'Queue Person ' || g, 'qq' || g || '@safety.example', 'qq' || lpad(g::text, 2, '0') from generate_series(1, 25) g;
  insert into public.site_profiles (kind, user_id, privacy) select 'personal', ('00000000-0000-0000-0002-' || lpad(g::text, 12, '0'))::uuid, 'public' from generate_series(1, 25) g;
  perform tests.assert_eq('a search shows at most 20 people', tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_find_profiles('qq'))$q$) || '/' || tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_find_profiles('queue person 1'))$q$) || '/' || tests.names(admin_u, adm, $q$public.cms_find_profiles('qq07')$q$, 'handle'), '20/11/qq07');
  delete from auth.users where email like 'qq%@safety.example';
  perform tests.assert_eq('...in the audit log', (select count(*)::int from public.audit_log where action = 'profile_suspended' and entity_id = p_dj::text and details ->> 'note' = 'abuse'), 1);
  r1 := tests.f(admin_u, adm, format($q$public.cms_profile_set_status(%L, false)$q$, p_ann), '{suspended}');
  perform tests.assert_eq('...and restoring, from either of her profiles', r1 || '/' || (select count(*)::int from public.site_profiles where user_id = ann and status = 'active'), 'false/2');
  perform tests.assert_eq('...also in the audit log', (select count(*)::int from public.audit_log where action = 'profile_restored' and entity_id = p_ann::text), 1);

  ---------------------------------------------------------------- what suspension and removal do across the app
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, true)$q$, p_cy, p_ann));
  insert into public.site_posts (author, kind, caption, audience) values (p_cy, 'post', 'cy post', 'public') returning id into post_cy;
  insert into public.site_comments (post, author, body) values (post_cy, p_ann, 'ann comment'), (post_cy, p_bob, 'bob comment');
  perform tests.assert_eq('before she is suspended both comments are listed', tests.names(bob, b_e, format($q$public.comment_list(%L, %L)$q$, p_bob, post_cy), 'body'), 'ann comment,bob comment');
  perform tests.f(admin_u, adm, format($q$public.cms_profile_set_status(%L, true)$q$, p_ann), '{profiles}');
  perform tests.assert_eq('a suspended person''s comments are not listed', tests.names(bob, b_e, format($q$public.comment_list(%L, %L)$q$, p_bob, post_cy), 'body'), 'bob comment');
  perform tests.assert_eq('...nor her posts reachable', tests.names(bob, b_e, format($q$public.comment_list(%L, %L)$q$, p_bob, post1), 'body'), 'ERROR: This post isn''t available.');
  perform tests.assert_eq('...she is not in search', tests.names(bob, b_e, format($q$public.profile_search(%L, 'annie')$q$, p_bob), 'handle'), '(none)');
  perform tests.assert_eq('...her posts are not in the home feed (only cy''s own is)', tests.names(cy, c_e, format($q$public.feed_home(%L)$q$, p_cy)), post_cy::text);
  perform tests.assert_eq('...nor her stories', tests.names(cy, c_e, format($q$public.story_rail(%L)$q$, p_cy)), '(none)');
  perform tests.assert_eq('...she cannot start a conversation', tests.q(ann, a_e, format($q$public.dm_start_direct(%L, %L)$q$, p_ann, p_bob)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...nobody can start one with her', tests.q(bob, b_e, format($q$public.dm_start_direct(%L, %L)$q$, p_bob, p_ann)), 'ERROR: This profile isn''t available.');
  perform tests.f(admin_u, adm, format($q$public.cms_profile_set_status(%L, false)$q$, p_ann), '{profiles}');

  ---------------------------------------------------------------- a conversation with a suspended person is gone
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_cy));
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, true)$q$, p_cy, p_bob));
  update public.site_dm_members set status = 'active' where conversation = conv;
  insert into public.site_dm_messages (conversation, sender, kind, body, created_at) values (conv, p_cy, 'text', 'unread one', clock_timestamp());
  perform tests.assert_eq('before: the conversation is in bob''s inbox, readable, and counted as new', tests.names(bob, b_e, format($q$public.dm_inbox(%L)$q$, p_bob)) || '/' || tests.f(bob, b_e, format($q$public.dm_unread(%L)$q$, p_bob), '{conversations}')
    || '/' || tests.f(bob, b_e, format($q$public.dm_conversation(%L, %L)$q$, p_bob, conv), '{id}'), conv::text || '/1/' || conv::text);
  perform tests.f(admin_u, adm, format($q$public.cms_profile_set_status(%L, true)$q$, p_cy), '{profiles}');
  perform tests.assert_eq('after cy is suspended it is not in the inbox', tests.names(bob, b_e, format($q$public.dm_inbox(%L)$q$, p_bob)), '(none)');
  perform tests.assert_eq('...not counted', tests.f(bob, b_e, format($q$public.dm_unread(%L)$q$, p_bob), '{conversations}'), '0');
  perform tests.assert_eq('...not readable by its address', tests.q(bob, b_e, format($q$public.dm_messages(%L, %L)$q$, p_bob, conv)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...its head either', tests.q(bob, b_e, format($q$public.dm_conversation(%L, %L)$q$, p_bob, conv)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...and nothing can be sent to it', tests.q(bob, b_e, format($q$public.dm_send(%L, %L, 'hello?')$q$, p_bob, conv)), 'ERROR: This conversation isn''t available.');
  perform tests.f(admin_u, adm, format($q$public.cms_profile_set_status(%L, false)$q$, p_cy), '{profiles}');
  perform tests.assert_eq('restored, it is all back', tests.names(bob, b_e, format($q$public.dm_inbox(%L)$q$, p_bob)), conv::text);

  ---------------------------------------------------------------- deleting a reporter's account keeps the report
  select count(*) into n from public.site_reports where reporter = p_bob;
  perform tests.assert_true('bob has made reports', n > 3);
  delete from auth.users where id = bob;
  perform tests.assert_eq('deleting the account keeps the reports, without the reporter', (select count(*)::int from public.site_reports where reporter is null and kind = 'post' and target = post_story), 1);
  perform tests.assert_eq('...and they still show in the queue', tests.q(admin_u, adm, $q$jsonb_array_length(public.cms_reports_list('all'))$q$)::int > 0, true);
  delete from auth.users where id = cy;
  perform tests.assert_eq('deleting the reported person''s account leaves the report, with no profile to act on', (select count(*)::int from public.site_reports where target_profile is null and kind = 'profile' and target <> p_cy) + (select count(*)::int from public.site_reports where kind = 'review' and target_profile is null), 1);
end $$;

rollback;
