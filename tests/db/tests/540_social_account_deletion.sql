-- Deleting an account, across the whole social stack. One person (and their professional profile) has something in EVERY table the social migrations made: a profile, usernames,
-- follows and blocks both ways, posts with media and tags, likes, saves, comments and a reply, a Members Only list, story views, reviews and a reply, conversations and messages,
-- notifications as the actor and as the recipient, notification choices, reports as the reporter and as the person reported, caption requests and the rules they accepted. Then the
-- account is deleted the way the delete-account function does it (the profile row, then the sign-in). Afterwards NOTHING that names them is left, anywhere: the test finds every
-- foreign key into the person from the social tables by asking the database (so a table added later without a rule is caught), and counts. What other people made stays.
-- The files in storage are not the database's to delete: the delete-account function removes them (see supabase/functions/delete-account).
begin;

-- How many rows of a table name any of these ids in a column.
create function pg_temp.count_in(p_tbl text, p_col text, p_ids uuid[]) returns bigint language plpgsql as $f$
declare k bigint;
begin
  execute format('select count(*) from public.%I where %I = any ($1)', p_tbl, p_col) into k using p_ids;
  return k;
end $f$;

do $$
declare
  ann constant uuid := '00000000-0000-0000-0000-0000000009a1';
  bob constant uuid := '00000000-0000-0000-0000-0000000009a2';
  cy constant uuid := '00000000-0000-0000-0000-0000000009a3';
  olly constant uuid := '00000000-0000-0000-0000-0000000009a4';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  a_e constant text := 'ann@gone.example'; b_e constant text := 'bob@gone.example'; c_e constant text := 'cy@gone.example'; o_e constant text := 'olly@gone.example';
  hr_a uuid; hr_b uuid; p_club uuid; p_bobdj uuid; rq_a uuid; rq_b uuid; q_a uuid; q_b uuid; pbk_a uuid; pbk_b uuid;
  t_s uuid; slot_s uuid; bk_s1 uuid; bk_s2 uuid; sp_s1 uuid; sp_s2 uuid;
  p_ann uuid; p_dj uuid; p_bob uuid; p_cy uuid; post_a uuid; post_b uuid; story_b uuid; cm_a uuid; cm_b uuid; rv_a uuid; rv_b uuid; conv uuid; grp uuid; org uuid; va uuid;
  social constant text[] := array[
    'site_profiles', 'site_handles', 'site_follows', 'site_blocks', 'site_posts', 'site_post_media', 'site_post_tags', 'site_post_likes', 'site_post_saves', 'site_comments',
    'site_member_lists', 'site_story_views', 'site_banned_terms', 'site_community_rules', 'site_rules_acceptance', 'site_ai_caption_uses', 'site_reviews', 'site_review_replies',
    'site_dm_conversations', 'site_dm_members', 'site_dm_messages', 'site_notifications', 'site_notification_opt_outs', 'site_reports', 'site_feature_flags', 'site_splits', 'site_split_shares',
    'site_pro_settings', 'site_pro_services', 'site_pro_busy', 'site_pro_requests', 'site_pro_quotes', 'site_pro_bookings', 'site_pro_payments', 'site_pro_disputes', 'site_pro_payouts',
    'site_profile_team', 'site_hires', 'site_hire_offers', 'site_hire_items', 'site_hire_bookings', 'site_chat_links'];
  -- made by BottlesUp staff, not by her: nothing of hers is expected in them
  staff_only constant text[] := array['site_community_rules', 'site_feature_flags', 'site_banned_terms', 'site_pro_settings', 'site_pro_quotes', 'site_pro_payments'];
  r record; t record; n bigint; ids uuid[]; before_total bigint := 0;
begin
  insert into auth.users (id, email) values (ann, a_e), (bob, b_e), (cy, c_e), (olly, o_e);
  insert into public.profiles (id, name, email) values (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (cy, 'Cy Rus', c_e), (olly, 'Olly Owner', o_e);
  perform tests.login(admin_u, 'admin@test.example');
  perform public.cms_set_feature('social', true); perform public.cms_set_feature('inbox', true); perform public.cms_set_feature('reviews', true); perform public.cms_set_feature('ai_captions', true);
  perform public.cms_publish_rules('Be kind to people. No spam. No hate. Respect each other.');
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'annie', 'Toronto'); perform public.profile_save_personal('public');
  perform public.profile_create_business('dj', 'DJ Ann', 'djann'); perform public.rules_accept(2); perform public.ai_caption_begin();
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bob', 'Toronto'); perform public.profile_save_personal('public'); perform public.rules_accept(2);
  perform public.profile_create_business('dj', 'DJ Bob', 'djbob');
  perform tests.login(cy, c_e); perform public.save_my_profile('Cy Rus', 'cyrus', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(olly, o_e); perform public.save_my_profile('Olly Owner', 'olly', 'Toronto'); perform public.profile_save_personal('public');
  org := public.create_organization('Club Co', 'venue_owner'); va := public.create_org_venue(org, 'Club A');
  perform public.profile_create_business('venue', 'Club A', 'cluba', null, null, null, va);
  perform tests.logout();
  select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal'; select id into p_dj from public.site_profiles where handle = 'djann';
  select id into p_bob from public.site_profiles where user_id = bob and kind = 'personal'; select id into p_cy from public.site_profiles where user_id = cy and kind = 'personal';
  select id into p_club from public.site_profiles where handle = 'cluba'; select id into p_bobdj from public.site_profiles where handle = 'djbob';

  -- follows both ways, from both of her profiles; blocks both ways
  insert into public.site_follows (follower, followed) values (p_ann, p_bob), (p_bob, p_ann), (p_dj, p_bob), (p_bob, p_dj);
  insert into public.site_blocks (blocker, blocked, blocker_key, blocked_key)
    values (p_ann, p_cy, public.profile_key(p_ann), public.profile_key(p_cy)), (p_cy, p_dj, public.profile_key(p_cy), public.profile_key(p_dj));
  -- posts, media, tags, likes, saves, comments and a reply, a story and who saw it, a Members Only list each way
  insert into public.site_posts (author, kind, caption) values (p_ann, 'post', 'ann post') returning id into post_a;
  insert into public.site_posts (author, kind, caption) values (p_bob, 'post', 'bob post') returning id into post_b;
  insert into public.site_posts (author, kind, caption, expires_at) values (p_bob, 'story', 'bob story', now() + interval '1 day') returning id into story_b;
  insert into public.site_post_media (post, position, media_type, storage_path) values (post_a, 0, 'image', p_ann::text || '/gone.jpg');
  insert into public.site_post_tags (post, profile_id) values (post_a, p_bob), (post_b, p_ann);
  insert into public.site_post_likes (post, profile) values (post_a, p_bob), (post_b, p_ann);
  insert into public.site_post_saves (post, profile) values (post_a, p_bob), (post_b, p_ann);
  insert into public.site_comments (post, author, body) values (post_b, p_ann, 'ann comment') returning id into cm_a;
  insert into public.site_comments (post, author, body) values (post_a, p_bob, 'bob comment') returning id into cm_b;
  insert into public.site_comments (post, author, body, reply_to) values (post_b, p_dj, 'dj reply', cm_a);
  insert into public.site_story_views (story, viewer) values (story_b, p_ann);
  insert into public.site_member_lists (owner, member) values (p_ann, p_bob), (p_bob, p_ann);
  -- reviews of the club and a reply
  insert into public.site_reviews (kind, venue_id, author, rating, body) values ('venue', va, p_ann, 5, 'ann review') returning id into rv_a;
  insert into public.site_reviews (kind, venue_id, author, rating, body) values ('venue', va, p_bob, 4, 'bob review') returning id into rv_b;
  insert into public.site_review_replies (review, author, body) values (rv_b, p_ann, 'ann reply to bob');
  -- a conversation of two and a group of three; messages from both
  insert into public.site_dm_conversations (kind, pair_key) values ('direct', 'ann:bob') returning id into conv;
  insert into public.site_dm_members (conversation, profile) values (conv, p_ann), (conv, p_bob);
  insert into public.site_dm_messages (conversation, sender, kind, body) values (conv, p_ann, 'text', 'ann says'), (conv, p_bob, 'text', 'bob says');
  insert into public.site_dm_conversations (kind, title, created_by) values ('group', 'Crew', p_ann) returning id into grp;
  insert into public.site_dm_members (conversation, profile, role) values (grp, p_ann, 'admin'), (grp, p_bob, 'member'), (grp, p_cy, 'member');
  insert into public.site_dm_messages (conversation, sender, kind, body) values (grp, p_ann, 'text', 'ann in the group'), (grp, p_bob, 'text', 'bob in the group');
  -- splitting a table's bill, both ways: she asks bob to pay a share of her table, and bob asks her to pay a share of his
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (va, 'Booth', 6, 0, 10000, 50) returning id into t_s;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (va, 5, '22:00') returning id into slot_s;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_s, slot_s, current_date + 3, 'Ann', a_e, 2, 20000, 5000, 'paid', 'GONE-1') returning id into bk_s1;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_s, slot_s, current_date + 3, 'Bob', b_e, 2, 20000, 5000, 'paid', 'GONE-2') returning id into bk_s2;
  insert into public.site_splits (booking_id, host, deadline) values (bk_s1, ann, now() + interval '1 day') returning id into sp_s1;
  insert into public.site_splits (booking_id, host, deadline) values (bk_s2, bob, now() + interval '1 day') returning id into sp_s2;
  insert into public.site_split_shares (split_id, payer, amount_cents) values (sp_s1, p_bob, 3000), (sp_s2, p_ann, 3000);
  -- hiring professionals, both ways: her DJ profile sells and is hired by bob, and she hires through the same table; a booking, a dispute, a payout she was paid
  insert into public.site_pro_services (profile, title) values (p_dj, 'Fixture set');
  insert into public.site_pro_busy (profile, day) values (p_dj, current_date + 400);
  insert into public.site_pro_requests (client, provider, event_date, message) values (bob, p_dj, current_date + 30, 'Please come to our night') returning id into rq_a;
  insert into public.site_pro_requests (client, provider, event_date, message) values (ann, p_dj, current_date + 31, 'Please come to my night') returning id into rq_b;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) values (rq_a, 100000, 30000, current_date + 20, 'Four hours of music and lights', now() + interval '3 days') returning id into q_a;
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until) values (rq_b, 100000, 30000, current_date + 20, 'Four hours of music and lights', now() + interval '3 days') returning id into q_b;
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by)
    values (q_a, rq_a, bob, p_dj, 'Fixture set', current_date + 30, 100000, 30000, current_date + 20, 500, 7, now() + interval '1 day') returning id into pbk_a;
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by)
    values (q_b, rq_b, ann, p_dj, 'Fixture set', current_date + 31, 100000, 30000, current_date + 20, 500, 7, now() + interval '1 day') returning id into pbk_b;
  insert into public.site_pro_disputes (booking, opened_by, reason) values (pbk_b, ann, 'It did not go as agreed at all');
  insert into public.site_pro_payouts (booking, provider, gross_cents, commission_cents, net_cents, status, reference, paid_at, paid_by)
    values (pbk_a, p_dj, 30000, 1500, 28500, 'paid', 'etransfer 1', now(), ann);
  update public.site_pro_settings set updated_by = ann where id = 1;
  -- teams, hiring a venue, the workspace and the chats, both ways: bob is on her DJ profile's team and she is on his; she asked the club for a night and bob did too
  insert into public.site_profile_team (profile, member, role, permissions, status, invited_by) values (p_dj, bob, 'manager', '{bookings,content,finance}', 'active', ann), (p_bobdj, ann, 'booking_agent', '{bookings}', 'active', bob);
  insert into public.site_hires (organizer, venue_profile, requested_by, event_date, event_type) values (p_dj, p_club, ann, current_date + 60, 'Her night') returning id into hr_a;
  insert into public.site_hires (organizer, venue_profile, requested_by, event_date, event_type) values (p_bobdj, p_club, bob, current_date + 61, 'His night') returning id into hr_b;
  insert into public.site_hire_offers (hire, rental_cents, deposit_cents, control, valid_until) values (hr_a, 100000, 20000, 'venue', now() + interval '3 days'), (hr_b, 100000, 20000, 'venue', now() + interval '3 days');
  insert into public.site_hire_items (hire, kind, title, side, created_by) values (hr_a, 'task', 'Her task', 'organizer', ann), (hr_b, 'task', 'His task', 'organizer', bob);
  insert into public.site_hire_bookings (hire, booking, attached_by) values (hr_a, pbk_a, ann);
  insert into public.site_chat_links (conversation, kind, ref) values (grp, 'team', p_dj);
  -- notifications both ways, choices, reports both ways and one about her DJ profile
  insert into public.site_notifications (recipient, kind, actor, post, dedupe_key) values (p_bob, 'like', p_ann, post_b, 'k1'), (p_ann, 'comment', p_bob, post_a, 'k2');
  insert into public.site_notification_opt_outs (profile, kind) values (p_ann, 'tag'), (p_dj, 'follow');
  insert into public.site_reports (reporter, kind, target, target_profile, reason) values (p_ann, 'post', post_b, p_bob, 'spam'), (p_bob, 'post', post_a, p_ann, 'spam'), (p_cy, 'profile', p_dj, p_dj, 'other');

  -- every foreign key from a social table into a person, found by asking the database
  create temp table refs on commit drop as
  select replace(c.conrelid::regclass::text, 'public.', '') as tbl, a.attname::text as col, replace(c.confrelid::regclass::text, 'public.', '') as points_at
    from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
   where c.contype = 'f' and replace(c.conrelid::regclass::text, 'public.', '') = any (social)
     and c.confrelid in ('public.site_profiles'::regclass, 'auth.users'::regclass, 'public.profiles'::regclass);
  perform tests.assert_true('the database has foreign keys from the social tables into people, so this test is looking at something', (select count(*) from refs) >= 25);

  for r in select * from refs order by tbl, col loop
    ids := case when r.points_at = 'site_profiles' then array[p_ann, p_dj] else array[ann] end;
    before_total := before_total + pg_temp.count_in(r.tbl, r.col, ids);
  end loop;
  perform tests.assert_true('she has rows naming her before (' || before_total || ')', before_total >= 40);
  -- the fixture touches every table that a person can have something in
  for t in select distinct tbl from refs where tbl <> all (staff_only) order by tbl loop
    n := 0;
    for r in select * from refs rr where rr.tbl = t.tbl loop
      ids := case when r.points_at = 'site_profiles' then array[p_ann, p_dj] else array[ann] end;
      n := n + pg_temp.count_in(r.tbl, r.col, ids);
    end loop;
    perform tests.assert_true('the fixture covers ' || t.tbl, n > 0);
  end loop;

  -- delete the account the way the function does
  delete from public.profiles where id = ann;
  delete from auth.users where id = ann;

  for r in select * from refs order by tbl, col loop
    ids := case when r.points_at = 'site_profiles' then array[p_ann, p_dj] else array[ann] end;
    perform tests.assert_eq('nothing in ' || r.tbl || '.' || r.col || ' names her any more', pg_temp.count_in(r.tbl, r.col, ids)::int, 0);
  end loop;
  perform tests.assert_eq('her profiles are gone, both of them', (select count(*) from public.site_profiles where id in (p_ann, p_dj))::int, 0);
  perform tests.assert_eq('...and her usernames are free again', (select count(*) from public.site_handles where handle in ('annie', 'djann'))::int, 0);
  perform tests.assert_eq('...her post, with its media row and tags', (select count(*) from public.site_posts where id = post_a)::int + (select count(*) from public.site_post_media where post = post_a)::int + (select count(*) from public.site_post_tags where post = post_a)::int, 0);
  perform tests.assert_eq('...the comment bob made on her post, with her post', (select count(*) from public.site_comments where id = cm_b)::int, 0);
  perform tests.assert_eq('...her comment on bob''s post, and her DJ profile''s reply to it', (select count(*) from public.site_comments where post = post_b)::int, 0);
  perform tests.assert_eq('...her review, and the reply she wrote', (select count(*) from public.site_reviews where id = rv_a)::int + (select count(*) from public.site_review_replies where review = rv_b)::int, 0);
  perform tests.assert_eq('...her Members Only list and the entry about her on bob''s', (select count(*) from public.site_member_lists)::int, 0);
  perform tests.assert_eq('...her messages, but not what the others said', (select count(*) from public.site_dm_messages where conversation in (conv, grp) and sender = p_bob)::int, 2);
  perform tests.assert_eq('...her split goes without a host (the table is still there), and the share she was asked for has nobody on it', (select count(*) from public.site_splits where id = sp_s1 and host is null)::int + (select count(*) from public.site_split_shares where split_id = sp_s2 and payer is null)::int, 2);
  perform tests.assert_eq('...what she sold and was hired for stays as a record, with nobody on it: the two bookings, the payout and the dispute', (select count(*) from public.site_pro_bookings where client is null or provider is null)::int + (select count(*) from public.site_pro_payouts where provider is null and paid_by is null)::int + (select count(*) from public.site_pro_disputes where opened_by is null)::int, 4);
  perform tests.assert_eq('...the night she asked the club for stays as a record for the club, with nobody on it, and its offer, task and attached booking with it', (select count(*) from public.site_hires where id = hr_a and organizer is null and requested_by is null)::int + (select count(*) from public.site_hire_offers where hire = hr_a)::int + (select count(*) from public.site_hire_items where hire = hr_a and created_by is null)::int + (select count(*) from public.site_hire_bookings where hire = hr_a)::int, 4);
  perform tests.assert_eq('...bob''s night is untouched', (select count(*) from public.site_hires where id = hr_b and organizer = p_bobdj and requested_by = bob)::int, 1);
  perform tests.assert_eq('...his team has lost her, and her team has gone with her profile', (select count(*) from public.site_profile_team where member = ann or profile = p_dj)::int, 0);
  perform tests.assert_eq('...and the team chat stays for the people still in it (its link only names a profile that is gone)', (select count(*) from public.site_chat_links where kind = 'team' and ref = p_dj)::int + (select count(*) from public.site_dm_conversations where id = grp)::int, 2);
  perform tests.assert_eq('what other people made stays: bob''s post, his story and his review', (select count(*) from public.site_posts where id in (post_b, story_b))::int + (select count(*) from public.site_reviews where id = rv_b)::int, 3);
  perform tests.assert_eq('...the group, with its other two people', (select count(*) from public.site_dm_members where conversation = grp)::int, 2);
  perform tests.assert_eq('...a report she made stays for BottlesUp to read, without her', (select count(*) from public.site_reports where kind = 'post' and target = post_b and reporter is null)::int, 1);
  perform tests.assert_eq('...a report about her, with no profile left to act on', (select count(*) from public.site_reports where target = post_a and target_profile is null)::int, 1);
  perform tests.assert_eq('...and one cy made about her DJ profile', (select count(*) from public.site_reports where kind = 'profile' and target_profile is null)::int, 1);
  perform tests.assert_eq('the rules she accepted and her caption requests are gone', (select count(*) from public.site_rules_acceptance where user_id = ann)::int + (select count(*) from public.site_ai_caption_uses where user_id = ann)::int, 0);
  perform tests.assert_eq('her notification choices, and the notifications about her, are gone', (select count(*) from public.site_notification_opt_outs where profile in (p_ann, p_dj))::int + (select count(*) from public.site_notifications where actor in (p_ann, p_dj) or recipient in (p_ann, p_dj))::int, 0);

  -- and the database's own audit of what could refuse a deletion finds nothing (the same check as supabase/audit/18_account_deletion_blockers.sql)
  perform tests.assert_eq('no foreign key anywhere refuses an account deletion', (
    with recursive gone(rel) as (
      select 'auth.users'::regclass
      union
      select c.conrelid from pg_constraint c join gone on c.confrelid = gone.rel where c.contype = 'f' and c.confdeltype = 'c'
    )
    select count(*) from pg_constraint c join gone on c.confrelid = gone.rel where c.contype = 'f' and c.confdeltype in ('a', 'r')
  )::int, 0);
end $$;

rollback;
