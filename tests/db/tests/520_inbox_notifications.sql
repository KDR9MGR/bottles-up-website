-- Inbox and notifications. What matters most: who may read or write a conversation is worked out from the profile's CURRENT standing (revoke a venue manager and they are out
-- at once); a person you do not follow writes to your Requests, three messages and then they wait; a blocked pair cannot write; a shared post shows only to people who may see it
-- and a booking card never carries the code or the money; a retried send is one message and a flood is slowed; notifications are written once, never for oneself, never across a
-- block, and a tag never tells someone about a post they cannot see.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
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
-- Send as a person and return the message's body (or its id with p_id), or 'ERROR: ...'.
create function tests.say(p_user uuid, p_email text, p_actor uuid, p_conv uuid, p_body text, p_key text default null) returns text language plpgsql as $$
begin
  return tests.f(p_user, p_email, format($q$public.dm_send(%L, %L, %L, %L)$q$, p_actor, p_conv, p_body, p_key), '{id}');
end $$;

do $$
declare
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  ann constant uuid := '00000000-0000-0000-0000-0000000007a1';
  bob constant uuid := '00000000-0000-0000-0000-0000000007a2';
  cy constant uuid := '00000000-0000-0000-0000-0000000007a3';
  dee constant uuid := '00000000-0000-0000-0000-0000000007a4';
  olly constant uuid := '00000000-0000-0000-0000-0000000007a5';   -- owns Club A
  mia constant uuid := '00000000-0000-0000-0000-0000000007a6';    -- manages Club A
  rando constant uuid := '00000000-0000-0000-0000-0000000007a7';
  a_e constant text := 'Ann@Inbox.example'; b_e constant text := 'bob@inbox.example'; c_e constant text := 'cy@inbox.example'; d_e constant text := 'dee@inbox.example';
  o_e constant text := 'olly@inbox.example'; m_e constant text := 'mia@inbox.example'; r_e constant text := 'rando@inbox.example';
  p_ann uuid; p_bob uuid; p_cy uuid; p_dee uuid; p_olly uuid; p_rando uuid; p_clubA uuid;
  org uuid; va uuid; vb uuid; t_a uuid; slot uuid; ev uuid; ev_draft uuid; bk uuid; bk_pending uuid; bk_other uuid;
  c1 uuid; c2 uuid; c3 uuid; cg uuid; cb uuid; post1 uuid; post_f uuid; cm1 uuid; txt text; n int; m1 text; m2 text;
begin
  insert into auth.users (id, email) values (ann, a_e), (bob, b_e), (cy, c_e), (dee, d_e), (olly, o_e), (mia, m_e), (rando, r_e);
  insert into public.profiles (id, name, email) values (ann, 'Ann Lee', a_e), (bob, 'Bob Ray', b_e), (cy, 'Cy Rus', c_e), (dee, 'Dee Dee', d_e), (olly, 'Olly Owner', o_e), (mia, 'Mia Manager', m_e), (rando, 'Rae Random', r_e);
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('social', true); perform tests.logout();
  perform tests.login(ann, a_e); perform public.save_my_profile('Ann Lee', 'ann', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(bob, b_e); perform public.save_my_profile('Bob Ray', 'bob', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(cy, c_e); perform public.save_my_profile('Cy Rus', 'cyrus', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(dee, d_e); perform public.save_my_profile('Dee Dee', 'dee', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(olly, o_e); perform public.save_my_profile('Olly Owner', 'olly', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(mia, m_e); perform public.save_my_profile('Mia Manager', 'mia', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.login(rando, r_e); perform public.save_my_profile('Rae Random', 'rae', 'Toronto'); perform public.profile_save_personal('public');
  perform tests.logout();
  select id into p_ann from public.site_profiles where user_id = ann and kind = 'personal'; select id into p_bob from public.site_profiles where user_id = bob and kind = 'personal';
  select id into p_cy from public.site_profiles where user_id = cy and kind = 'personal'; select id into p_dee from public.site_profiles where user_id = dee and kind = 'personal';
  select id into p_olly from public.site_profiles where user_id = olly and kind = 'personal'; select id into p_rando from public.site_profiles where user_id = rando and kind = 'personal';

  perform tests.login(olly, o_e);
  org := public.create_organization('Club Co', 'venue_owner');
  va := public.create_org_venue(org, 'Club A'); vb := public.create_org_venue(org, 'Club B');
  perform tests.join_as(olly, o_e, org, m_e, 'manager', va, mia);
  perform tests.logout();
  update public.site_venues set status = 'published' where id = va;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Friday Night', 'x', 'Club A', now() + interval '3 days', now() + interval '3 days 6 hours', 'published', org) returning id into ev;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id) values ('Secret Night', 'x', 'Club A', now() + interval '5 days', now() + interval '5 days 6 hours', 'draft', org) returning id into ev_draft;
  insert into public.site_table_types (venue_id, name, max_guests, min_spend_cents, deposit_cents, inventory_count) values (va, 'Booth', 6, 0, 10000, 50) returning id into t_a;
  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time) values (va, 5, '22:00') returning id into slot;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, amount_paid_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 4, 'Ann', 'ANN@inbox.example', 4, 25000, 25000, 'paid', 'SECRET-CODE-1') returning id into bk;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (va, t_a, slot, current_date + 4, 'Ann', a_e, 2, 10000, 'pending', 'PENDING-1') returning id into bk_pending;
  insert into public.site_table_bookings (venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, guest_count, amount_total_cents, status, confirmation_code)
    values (vb, t_a, slot, current_date + 4, 'Bob', b_e, 2, 10000, 'paid', 'BOB-CODE-1') returning id into bk_other;
  perform tests.q(olly, o_e, format($q$public.profile_create_business('venue', 'Club A', 'clubaclub', null, null, null, %L)$q$, va));
  select id into p_clubA from public.site_profiles where venue_id = va;

  ---------------------------------------------------------------- the switches and the rules
  perform tests.assert_eq('messages are off at first', tests.q(ann, a_e, format($q$public.dm_start_direct(%L, %L)$q$, p_ann, p_bob)), 'ERROR: Messages are not open yet.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('inbox', true); perform tests.logout();
  perform tests.assert_eq('starting a conversation with yourself', tests.q(ann, a_e, format($q$public.dm_start_direct(%L, %L)$q$, p_ann, p_ann)), 'ERROR: You cannot message your own profile.');
  perform tests.assert_eq('...a profile that does not exist', tests.q(ann, a_e, format($q$public.dm_start_direct(%L, %L)$q$, p_ann, gen_random_uuid())), 'ERROR: This profile isn''t available.');
  perform tests.assert_eq('someone else''s profile cannot be used', tests.q(bob, b_e, format($q$public.dm_start_direct(%L, %L)$q$, p_ann, p_cy)), 'ERROR: You cannot act as this profile.');
  c1 := (tests.f(ann, a_e, format($q$public.dm_start_direct(%L, %L)$q$, p_ann, p_bob), '{id}'))::uuid;
  perform tests.assert_eq('a conversation is one per pair, whoever starts it', tests.f(bob, b_e, format($q$public.dm_start_direct(%L, %L)$q$, p_bob, p_ann), '{id}'), c1::text);
  perform tests.assert_eq('...and asking twice gives the same one', tests.f(ann, a_e, format($q$public.dm_start_direct(%L, %L)$q$, p_ann, p_bob), '{id}'), c1::text);
  perform tests.assert_eq('nobody writes before accepting the community rules', tests.say(ann, a_e, p_ann, c1, 'hello'), 'ERROR: Read and accept the community rules first.');
  perform tests.q(ann, a_e, 'public.rules_accept(1)'); perform tests.q(bob, b_e, 'public.rules_accept(1)'); perform tests.q(cy, c_e, 'public.rules_accept(1)'); perform tests.q(dee, d_e, 'public.rules_accept(1)');
  perform tests.q(olly, o_e, 'public.rules_accept(1)'); perform tests.q(mia, m_e, 'public.rules_accept(1)'); perform tests.q(rando, r_e, 'public.rules_accept(1)');

  ---------------------------------------------------------------- requests: someone you do not follow
  perform tests.assert_eq('bob does not follow ann, so ann''s first message waits in his requests', tests.say(ann, a_e, p_ann, c1, 'Hi Bob'), tests.f(ann, a_e, format($q$public.dm_messages(%L, %L) -> 0$q$, p_ann, c1), '{id}'));
  perform tests.assert_eq('the writer has it in her main inbox', tests.names(ann, a_e, format($q$public.dm_inbox(%L)$q$, p_ann)), c1::text);
  perform tests.assert_eq('...the other person has it under requests, not in the main box', tests.names(bob, b_e, format($q$public.dm_inbox(%L)$q$, p_bob)) || '|' || tests.names(bob, b_e, format($q$public.dm_inbox(%L, 'requests')$q$, p_bob)), '(none)|' || c1::text);
  perform tests.assert_eq('a request is counted for the badge', tests.f(bob, b_e, format($q$public.dm_unread(%L)$q$, p_bob), '{requests}'), '1');
  perform tests.assert_eq('...and can be read before answering', tests.f(bob, b_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_bob, c1), '{body}'), 'Hi Bob');
  perform tests.say(ann, a_e, p_ann, c1, 'Second'); perform tests.say(ann, a_e, p_ann, c1, 'Third');
  perform tests.assert_eq('three messages are all a request gets', tests.say(ann, a_e, p_ann, c1, 'Fourth'), 'ERROR: Wait for them to reply before sending more.');
  perform tests.assert_eq('replying accepts, and the request is gone from requests', tests.say(bob, b_e, p_bob, c1, 'Hey Ann') like '%-%', true);
  perform tests.assert_eq('...it is in his main inbox now', tests.names(bob, b_e, format($q$public.dm_inbox(%L)$q$, p_bob)), c1::text);
  perform tests.assert_eq('...and the writer can go on', tests.say(ann, a_e, p_ann, c1, 'Fourth, now fine') like '%-%', true);
  -- someone who follows the writer gets it straight into the inbox
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, true)$q$, p_cy, p_ann));
  c2 := (tests.f(ann, a_e, format($q$public.dm_start_direct(%L, %L)$q$, p_ann, p_cy), '{id}'))::uuid;
  perform tests.assert_eq('someone who follows you gets your message in the main inbox', tests.names(cy, c_e, format($q$public.dm_inbox(%L)$q$, p_cy)), c2::text);
  insert into public.site_dm_messages (conversation, sender, kind, body) select c2, p_ann, 'text', 'burst ' || g from generate_series(1, 29) g;
  perform tests.assert_eq('with 29 messages in the minute the 30th is allowed', tests.say(ann, a_e, p_ann, c2, 'thirtieth') like '%-%', true);
  perform tests.assert_eq('...and the 31st is slowed', tests.say(ann, a_e, p_ann, c2, 'thirty-first'), 'ERROR: You are sending messages too fast. Wait a moment.');
  delete from public.site_dm_messages where conversation = c2;
  -- declining
  c3 := (tests.f(dee, d_e, format($q$public.dm_start_direct(%L, %L)$q$, p_dee, p_bob), '{id}'))::uuid;
  perform tests.say(dee, d_e, p_dee, c3, 'Hi');
  perform tests.assert_eq('a request can be declined', tests.f(bob, b_e, format($q$public.dm_answer_request(%L, %L, false)$q$, p_bob, c3), '{accepted}'), 'false');
  perform tests.assert_eq('...it disappears for him', tests.names(bob, b_e, format($q$public.dm_inbox(%L, 'requests')$q$, p_bob)), '(none)');
  perform tests.assert_eq('...and he can no longer read it', tests.q(bob, b_e, format($q$public.dm_messages(%L, %L)$q$, p_bob, c3)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...the writer is not told, and can still send within the limit', tests.say(dee, d_e, p_dee, c3, 'Hello?') like '%-%', true);
  perform tests.assert_eq('there is nothing to answer in an ordinary conversation', tests.q(bob, b_e, format($q$public.dm_answer_request(%L, %L, true)$q$, p_bob, c1)), 'ERROR: There is no request here.');
  perform tests.assert_eq('a made-up answer is refused', tests.q(bob, b_e, format($q$public.dm_answer_request(%L, %L, null)$q$, p_bob, c1)), 'ERROR: Choose accept or decline.');

  ---------------------------------------------------------------- who may read and write
  perform tests.assert_eq('a stranger cannot read a conversation', tests.q(rando, r_e, format($q$public.dm_messages(%L, %L)$q$, p_rando, c1)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...or write to it', tests.say(rando, r_e, p_rando, c1, 'hi'), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...nor read it as someone else', tests.q(rando, r_e, format($q$public.dm_messages(%L, %L)$q$, p_ann, c1)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('a stranger cannot mark a conversation read', tests.q(rando, r_e, format($q$public.dm_mark_read(%L, %L)$q$, p_rando, c1)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...mute it', tests.q(rando, r_e, format($q$public.dm_mute(%L, %L, true)$q$, p_rando, c1)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...or see who is in it', tests.q(rando, r_e, format($q$public.dm_people(%L, %L)$q$, p_rando, c1)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('an empty message is refused', tests.say(ann, a_e, p_ann, c1, '   '), 'ERROR: Write something first.');
  perform tests.assert_eq('2001 characters are refused', tests.say(ann, a_e, p_ann, c1, repeat('a', 2001)), 'ERROR: A message can be 2000 characters at most.');
  perform tests.assert_eq('2000 are fine', tests.say(ann, a_e, p_ann, c1, repeat('a', 2000)) like '%-%', true);
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_banned_term('badword', true); perform tests.logout();
  perform tests.assert_eq('a banned word is refused', tests.say(ann, a_e, p_ann, c1, 'you BADWORD'), 'ERROR: That text goes against our community rules.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('inbox', false); perform tests.logout();
  perform tests.assert_eq('with messages switched off nothing is sent, in a conversation that exists', tests.say(ann, a_e, p_ann, c1, 'hi'), 'ERROR: Messages are not open yet.');
  perform tests.login(admin_u, 'admin@test.example'); perform public.cms_set_feature('inbox', true); perform tests.logout();
  perform tests.assert_eq('a person cannot message their own business profile', tests.q(olly, o_e, format($q$public.dm_start_direct(%L, %L)$q$, p_olly, p_clubA)), 'ERROR: You cannot message your own profile.');
  m1 := tests.say(ann, a_e, p_ann, c1, 'once only', 'key-1');
  m2 := tests.say(ann, a_e, p_ann, c1, 'once only', 'key-1');
  perform tests.assert_eq('a retried send with the same key is one message', m1, m2);
  perform tests.logout();
  perform tests.assert_eq('...one row', (select count(*) from public.site_dm_messages where client_key = 'key-1')::int, 1);
  insert into public.site_dm_messages (conversation, sender, kind, body) select c1, p_ann, 'text', 'flood ' || g from generate_series(1, 30) g;
  perform tests.assert_eq('30 messages in a minute is the limit', tests.say(ann, a_e, p_ann, c1, 'one more'), 'ERROR: You are sending messages too fast. Wait a moment.');
  perform tests.assert_eq('...the other person is not slowed', tests.say(bob, b_e, p_bob, c1, 'fine') like '%-%', true);
  delete from public.site_dm_messages where body like 'flood %';
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, true)$q$, p_ann, p_bob));
  perform tests.assert_eq('a blocked pair cannot write', tests.say(bob, b_e, p_bob, c1, 'hi'), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...the conversation is gone from both inboxes', tests.names(ann, a_e, format($q$public.dm_inbox(%L)$q$, p_ann)) like '%' || c1::text || '%', false);
  perform tests.assert_eq('...and cannot be started again', tests.q(bob, b_e, format($q$public.dm_start_direct(%L, %L)$q$, p_bob, p_ann)), 'ERROR: This profile isn''t available.');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, false)$q$, p_ann, p_bob));
  perform tests.assert_eq('unblocking brings it back', tests.names(ann, a_e, format($q$public.dm_inbox(%L)$q$, p_ann)) like '%' || c1::text || '%', true);

  ---------------------------------------------------------------- sharing
  insert into public.site_posts (author, kind, caption, audience) values (p_ann, 'post', 'public post', 'public') returning id into post1;
  insert into public.site_posts (author, kind, caption, audience) values (p_ann, 'post', 'followers post', 'followers') returning id into post_f;
  insert into public.site_post_media (post, position, media_type, storage_path) values (post1, 0, 'image', p_ann::text || '/a.jpg'), (post_f, 0, 'image', p_ann::text || '/b.jpg');
  perform tests.assert_eq('a post can be shared', tests.f(ann, a_e, format($q$public.dm_send(%L, %L, 'look', null, 'post', %L)$q$, p_ann, c1, post1), '{kind}'), 'post');
  perform tests.assert_eq('...it shows to the one it was sent to, as the post', tests.f(bob, b_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_bob, c1), '{ref,post,caption}'), 'public post');
  perform tests.assert_eq('...with the note', tests.f(bob, b_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_bob, c1), '{body}'), 'look');
  perform tests.assert_eq('a post you cannot see cannot be shared', tests.q(bob, b_e, format($q$public.dm_send(%L, %L, null, null, 'post', %L)$q$, p_bob, c1, post_f)), 'ERROR: You cannot share that post.');
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann));
  perform tests.assert_eq('...once you follow, you can', tests.f(bob, b_e, format($q$public.dm_send(%L, %L, null, null, 'post', %L)$q$, p_bob, c1, post_f), '{kind}'), 'post');
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, false)$q$, p_bob, p_ann));
  perform tests.assert_eq('a shared post the reader may no longer see is shown as unavailable', tests.f(bob, b_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_bob, c1), '{ref,available}'), 'false');
  perform tests.assert_eq('...without any of its words', tests.f(bob, b_e, format($q$(public.dm_messages(%L, %L)) -> 0 -> 'ref'$q$, p_bob, c1), '{post}'), '(null)');
  perform tests.assert_eq('an event can be shared', tests.f(ann, a_e, format($q$public.dm_send(%L, %L, null, null, 'event', %L)$q$, p_ann, c1, ev), '{ref,title}'), 'Friday Night');
  perform tests.assert_eq('...a draft cannot', tests.q(ann, a_e, format($q$public.dm_send(%L, %L, null, null, 'event', %L)$q$, p_ann, c1, ev_draft)), 'ERROR: You cannot share that event.');
  perform tests.assert_eq('a venue can be shared', tests.f(ann, a_e, format($q$public.dm_send(%L, %L, null, null, 'venue', %L)$q$, p_ann, c1, va), '{ref,name}'), 'Club A');
  m1 := tests.f(ann, a_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_ann, c1), '{id}');
  perform tests.q(ann, a_e, format($q$public.dm_delete_message(%L, %L)$q$, p_ann, m1::uuid));
  perform tests.assert_eq('a share that was taken back shows nothing of what it shared', tests.f(bob, b_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_bob, c1), '{ref}'), '(null)');
  update public.site_events set status = 'draft' where id = ev;
  perform tests.assert_eq('an event shared earlier that is taken down shows as unavailable', (select (public.dm_ref_card(p_bob, 'event', ev)) ->> 'available'), 'false');
  update public.site_events set status = 'published' where id = ev;
  perform tests.assert_eq('...an unpublished one cannot', tests.q(ann, a_e, format($q$public.dm_send(%L, %L, null, null, 'venue', %L)$q$, p_ann, c1, vb)), 'ERROR: You cannot share that venue.');
  perform tests.assert_eq('a booking cannot be sent into an ordinary conversation', tests.q(ann, a_e, format($q$public.dm_send(%L, %L, null, null, 'booking', %L)$q$, p_ann, c1, bk)), 'ERROR: A booking can only be shared in its own conversation.');
  perform tests.assert_eq('a made-up kind is refused', tests.q(ann, a_e, format($q$public.dm_send(%L, %L, 'x', null, 'gif', %L)$q$, p_ann, c1, ev)), 'ERROR: You cannot send that.');
  perform tests.assert_eq('a share without what it shares is refused', tests.q(ann, a_e, format($q$public.dm_send(%L, %L, 'x', null, 'event', null)$q$, p_ann, c1)), 'ERROR: You cannot send that.');

  ---------------------------------------------------------------- a conversation about a booking
  perform tests.assert_eq('a business profile cannot start a booking conversation', tests.q(olly, o_e, format($q$public.dm_start_booking(%L, %L)$q$, p_clubA, bk)), 'ERROR: Only a person''s own profile can message about a booking.');
  perform tests.assert_eq('only the person the booking was made for can start it', tests.q(bob, b_e, format($q$public.dm_start_booking(%L, %L)$q$, p_bob, bk)), 'ERROR: You can only message about a booking you made.');
  perform tests.assert_eq('...a booking that was never paid cannot', tests.q(ann, a_e, format($q$public.dm_start_booking(%L, %L)$q$, p_ann, bk_pending)), 'ERROR: You can only message about a booking you made.');
  perform tests.assert_eq('...a venue that has no profile yet is said so', tests.q(bob, b_e, format($q$public.dm_start_booking(%L, %L)$q$, p_bob, bk_other)), 'ERROR: This venue has not set up messages yet.');
  cb := (tests.f(ann, a_e, format($q$public.dm_start_booking(%L, %L)$q$, p_ann, bk), '{id}'))::uuid;
  perform tests.assert_eq('the customer starts it (the e-mail matches whatever its case)', cb is not null, true);
  perform tests.assert_eq('...once per booking', tests.f(ann, a_e, format($q$public.dm_start_booking(%L, %L)$q$, p_ann, bk), '{id}'), cb::text);
  perform tests.assert_eq('the first message is the booking, as a safe card', tests.f(ann, a_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_ann, cb), '{ref,venue}'), 'Club A');
  perform tests.assert_eq('...which has the venue, night, table, party size and status', tests.q(ann, a_e, format($q$(select string_agg(k, ',' order by k) from jsonb_object_keys((public.dm_messages(%L, %L)) -> 0 -> 'ref') k)$q$, p_ann, cb)), 'available,guests,id,night,status,table,venue');
  perform tests.assert_eq('...and never the confirmation code or any money', tests.q(ann, a_e, format($q$(public.dm_messages(%L, %L))::text like '%%SECRET-CODE%%' or (public.dm_messages(%L, %L))::text like '%%25000%%'$q$, p_ann, cb, p_ann, cb)), 'false');
  perform tests.assert_eq('the venue''s manager reads it as the venue', tests.names(mia, m_e, format($q$public.dm_inbox(%L)$q$, p_clubA)), cb::text);
  perform tests.assert_eq('...and answers', tests.say(mia, m_e, p_clubA, cb, 'See you Friday!') like '%-%', true);
  perform tests.assert_eq('the customer sees the answer from the venue', tests.f(ann, a_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_ann, cb), '{sender,handle}'), 'clubaclub');
  perform tests.assert_eq('a stranger cannot read it', tests.q(rando, r_e, format($q$public.dm_messages(%L, %L)$q$, p_rando, cb)), 'ERROR: This conversation isn''t available.');
  perform tests.logout();
  update public.site_memberships set status = 'revoked' where user_id = mia and org_id = org;
  perform tests.assert_eq('a revoked manager is out at once', tests.q(mia, m_e, format($q$public.dm_messages(%L, %L)$q$, p_clubA, cb)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('the owner still reads it', tests.names(olly, o_e, format($q$public.dm_inbox(%L)$q$, p_clubA)), cb::text);

  ---------------------------------------------------------------- groups
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann));
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, true)$q$, p_cy, p_ann));
  cg := (tests.f(ann, a_e, format($q$public.dm_start_group(%L, '  Friday crew ', array[%L, %L, %L]::uuid[])$q$, p_ann, p_bob, p_cy, p_dee), '{id}'))::uuid;
  perform tests.assert_eq('a group is made', tests.f(ann, a_e, format($q$(public.dm_inbox(%L)) -> 0$q$, p_ann), '{title}') is not null, true);
  perform tests.assert_eq('...with a name and its people', tests.f(ann, a_e, format($q$(select e from jsonb_array_elements(public.dm_inbox(%L)) e where e ->> 'id' = %L)$q$, p_ann, cg), '{title}'), 'Friday crew');
  perform tests.assert_eq('...the creator is its admin', tests.q(ann, a_e, format($q$(select e ->> 'role' from jsonb_array_elements(public.dm_people(%L, %L)) e where e ->> 'handle' = 'ann')$q$, p_ann, cg)), 'admin');
  perform tests.assert_eq('people who follow the creator are in; others get a request', tests.q(ann, a_e, format($q$(select string_agg((e ->> 'handle') || ':' || (e ->> 'status'), ',' order by e ->> 'handle') from jsonb_array_elements(public.dm_people(%L, %L)) e)$q$, p_ann, cg)), 'ann:active,bob:active,cyrus:active,dee:request');
  perform tests.assert_eq('dee has it under requests', tests.names(dee, d_e, format($q$public.dm_inbox(%L, 'requests')$q$, p_dee)), cg::text);
  perform tests.assert_eq('a group needs a name', tests.q(ann, a_e, format($q$public.dm_start_group(%L, '  ', array[%L]::uuid[])$q$, p_ann, p_bob)), 'ERROR: Give the group a name (60 characters at most).');
  perform tests.assert_eq('...and someone to add', tests.q(ann, a_e, format($q$public.dm_start_group(%L, 'Solo', '{}')$q$, p_ann)), 'ERROR: Choose at least one person to add.');
  perform tests.assert_eq('...and not yourself alone', tests.q(ann, a_e, format($q$public.dm_start_group(%L, 'Solo', array[%L]::uuid[])$q$, p_ann, p_ann)), 'ERROR: Choose at least one person to add.');
  perform tests.assert_eq('a banned word in the name is refused', tests.q(ann, a_e, format($q$public.dm_start_group(%L, 'badword club', array[%L]::uuid[])$q$, p_ann, p_bob)), 'ERROR: That text goes against our community rules.');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, true)$q$, p_ann, p_olly));
  perform tests.assert_eq('a person who is blocked cannot be put in a group', tests.q(ann, a_e, format($q$public.dm_start_group(%L, 'No', array[%L]::uuid[])$q$, p_ann, p_olly)), 'ERROR: One of those profiles isn''t available.');
  perform tests.assert_eq('...nor one that does not exist', tests.q(ann, a_e, format($q$public.dm_start_group(%L, 'No', array[%L]::uuid[])$q$, p_ann, gen_random_uuid())), 'ERROR: One of those profiles isn''t available.');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, false)$q$, p_ann, p_olly));
  perform tests.q(dee, d_e, format($q$public.follow_set(%L, %L, true)$q$, p_dee, p_olly));
  perform tests.say(ann, a_e, p_ann, cg, 'Welcome all');
  perform tests.say(bob, b_e, p_bob, cg, 'Hi!');
  perform tests.assert_eq('a member sees what was said', tests.names(cy, c_e, format($q$public.dm_messages(%L, %L)$q$, p_cy, cg), 'body'), 'Hi!,Welcome all');
  perform tests.assert_eq('only an admin adds people', tests.q(bob, b_e, format($q$public.dm_group_add(%L, %L, %L)$q$, p_bob, cg, p_rando)), 'ERROR: Only a group''s admin can add people.');
  perform pg_sleep(0.01);
  perform tests.assert_eq('an admin adds someone', tests.f(ann, a_e, format($q$public.dm_group_add(%L, %L, %L)$q$, p_ann, cg, p_rando), '{members}'), '5');
  perform tests.q(rando, r_e, format($q$public.follow_set(%L, %L, true)$q$, p_rando, p_ann));
  perform tests.assert_eq('a person added later does not see what was said before', tests.q(rando, r_e, format($q$jsonb_array_length(public.dm_messages(%L, %L))$q$, p_rando, cg)), '0');
  perform tests.say(ann, a_e, p_ann, cg, 'After rando joined');
  perform tests.assert_eq('...but sees what is said after', tests.names(rando, r_e, format($q$public.dm_messages(%L, %L)$q$, p_rando, cg), 'body'), 'After rando joined');
  perform tests.assert_eq('only an admin removes people', tests.q(bob, b_e, format($q$public.dm_group_remove(%L, %L, %L)$q$, p_bob, cg, p_cy)), 'ERROR: Only a group''s admin can remove people.');
  perform tests.assert_eq('adding someone who is already in changes nothing', tests.f(ann, a_e, format($q$public.dm_group_add(%L, %L, %L)$q$, p_ann, cg, p_rando), '{members}'), '5');
  perform tests.assert_eq('...and they still see what they saw', tests.names(rando, r_e, format($q$public.dm_messages(%L, %L)$q$, p_rando, cg), 'body'), 'After rando joined');
  perform tests.assert_eq('an admin removes someone', tests.f(ann, a_e, format($q$public.dm_group_remove(%L, %L, %L)$q$, p_ann, cg, p_cy), '{members}'), '4');
  perform tests.assert_eq('...who can then neither read nor write', tests.q(cy, c_e, format($q$public.dm_messages(%L, %L)$q$, p_cy, cg)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('nobody removes themselves that way', tests.q(ann, a_e, format($q$public.dm_group_remove(%L, %L, %L)$q$, p_ann, cg, p_ann)), 'ERROR: Use Leave to leave a group yourself.');
  perform tests.assert_eq('an admin renames it', tests.f(ann, a_e, format($q$public.dm_group_rename(%L, %L, 'Saturday crew')$q$, p_ann, cg), '{title}'), 'Saturday crew');
  perform tests.assert_eq('...a member cannot', tests.q(bob, b_e, format($q$public.dm_group_rename(%L, %L, 'Mine now')$q$, p_bob, cg)), 'ERROR: Only a group''s admin can rename it.');
  perform tests.assert_eq('a banned word in a new name is refused', tests.q(ann, a_e, format($q$public.dm_group_rename(%L, %L, 'badword crew')$q$, p_ann, cg)), 'ERROR: That text goes against our community rules.');
  perform tests.assert_eq('a direct conversation cannot be left', tests.q(ann, a_e, format($q$public.dm_leave(%L, %L)$q$, p_ann, c1)), 'ERROR: You can only leave a group.');
  perform tests.assert_eq('a group is left', tests.f(ann, a_e, format($q$public.dm_leave(%L, %L)$q$, p_ann, cg), '{left}'), 'true');
  perform tests.assert_eq('...the earliest member who stays takes over as admin', tests.q(bob, b_e, format($q$(select e ->> 'handle' from jsonb_array_elements(public.dm_people(%L, %L)) e where e ->> 'role' = 'admin')$q$, p_bob, cg)), 'bob');
  perform tests.assert_eq('...and she is out', tests.q(ann, a_e, format($q$public.dm_messages(%L, %L)$q$, p_ann, cg)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('someone who left can be added back by the new admin, and joins as a member', tests.f(bob, b_e, format($q$public.dm_group_add(%L, %L, %L)$q$, p_bob, cg, p_ann), '{members}'), '4');
  perform tests.assert_eq('...not as an admin again', tests.q(bob, b_e, format($q$(select e ->> 'role' from jsonb_array_elements(public.dm_people(%L, %L)) e where e ->> 'handle' = 'ann')$q$, p_bob, cg)), 'member');
  perform tests.assert_eq('...and she is in again, as a request because she does not follow bob', tests.q(bob, b_e, format($q$(select e ->> 'status' from jsonb_array_elements(public.dm_people(%L, %L)) e where e ->> 'handle' = 'ann')$q$, p_bob, cg)), 'request');
  perform tests.login(dee, d_e); perform public.profile_save_personal('private'); perform tests.logout();
  perform tests.q(olly, o_e, format($q$public.follow_set(%L, %L, true)$q$, p_olly, p_dee));
  perform tests.assert_eq('someone whose request to follow is still waiting does not count as a follower', tests.q(dee, d_e, format($q$(select e ->> 'status' from jsonb_array_elements(public.dm_people(%L, %L)) e where e ->> 'handle' = 'olly')$q$, p_dee, (tests.f(dee, d_e, format($q$public.dm_start_group(%L, 'Dee crew', array[%L]::uuid[])$q$, p_dee, p_olly), '{id}'))::uuid)), 'request');
  insert into auth.users (id, email) select ('00000000-0000-0000-0007-' || lpad(g::text, 12, '0'))::uuid, 'g' || g || '@inbox.example' from generate_series(1, 50) g;
  insert into public.site_profiles (kind, user_id) select 'personal', ('00000000-0000-0000-0007-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 50) g;
  perform tests.assert_eq('a group has 50 people at most (creation)', tests.q(bob, b_e, format($q$public.dm_start_group(%L, 'Huge', %L::uuid[])$q$, p_bob, (select array_agg(id) from (select id from public.site_profiles where user_id::text like '00000000-0000-0000-0007-%%' limit 50) x))), 'ERROR: A group can have 50 people at most.');
  perform tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_cy));
  perform tests.assert_eq('a person who is blocked cannot be added', tests.q(bob, b_e, format($q$public.dm_group_add(%L, %L, %L)$q$, p_bob, cg, p_cy)), 'ERROR: This profile isn''t available.');
  perform tests.q(bob, b_e, format($q$public.block_set(%L, %L, false)$q$, p_bob, p_cy));
  insert into public.site_dm_members (conversation, profile, status) select cg, id, 'active' from public.site_profiles where user_id::text like '00000000-0000-0000-0007-%' limit 46;
  perform tests.assert_eq('...and when adding the 51st', tests.q(bob, b_e, format($q$public.dm_group_add(%L, %L, %L)$q$, p_bob, cg, p_cy)), 'ERROR: A group can have 50 people at most.');
  delete from auth.users where email like 'g%@inbox.example';

  ---------------------------------------------------------------- unread, read, mute, remove
  c1 := (tests.f(ann, a_e, format($q$public.dm_start_direct(%L, %L)$q$, p_ann, p_bob), '{id}'))::uuid;
  perform tests.q(bob, b_e, format($q$public.dm_mark_read(%L, %L)$q$, p_bob, c1));
  perform tests.say(ann, a_e, p_ann, c1, 'unread one'); perform tests.say(ann, a_e, p_ann, c1, 'unread two');
  perform tests.assert_eq('unread counts what others wrote since you looked', tests.q(bob, b_e, format($q$(select e ->> 'unread' from jsonb_array_elements(public.dm_inbox(%L)) e where e ->> 'id' = %L)$q$, p_bob, c1)), '2');
  perform tests.assert_eq('...not your own', tests.q(ann, a_e, format($q$(select e ->> 'unread' from jsonb_array_elements(public.dm_inbox(%L)) e where e ->> 'id' = %L)$q$, p_ann, c1)), '0');
  n := tests.f(bob, b_e, format($q$public.dm_unread(%L)$q$, p_bob), '{conversations}')::int;
  perform tests.assert_eq('the badge counts conversations with something new', n >= 1, true);
  perform tests.assert_eq('muting', tests.f(bob, b_e, format($q$public.dm_mute(%L, %L, true)$q$, p_bob, c1), '{muted}'), 'true');
  perform tests.assert_eq('...takes it out of the badge', tests.f(bob, b_e, format($q$public.dm_unread(%L)$q$, p_bob), '{conversations}')::int, n - 1);
  perform tests.assert_eq('...but not out of the inbox', tests.names(bob, b_e, format($q$public.dm_inbox(%L)$q$, p_bob)) like '%' || c1::text || '%', true);
  perform tests.q(bob, b_e, format($q$public.dm_mute(%L, %L, false)$q$, p_bob, c1));
  perform tests.assert_eq('a made-up mute answer is refused', tests.q(bob, b_e, format($q$public.dm_mute(%L, %L, null)$q$, p_bob, c1)), 'ERROR: Choose mute or unmute.');
  perform tests.q(bob, b_e, format($q$public.dm_mark_read(%L, %L)$q$, p_bob, c1));
  perform tests.assert_eq('looking clears it', tests.q(bob, b_e, format($q$(select e ->> 'unread' from jsonb_array_elements(public.dm_inbox(%L)) e where e ->> 'id' = %L)$q$, p_bob, c1)), '0');
  m1 := tests.say(ann, a_e, p_ann, c1, 'a mistake');
  perform tests.assert_eq('someone else cannot remove your message', tests.q(bob, b_e, format($q$public.dm_delete_message(%L, %L)$q$, p_bob, m1::uuid)), 'ERROR: You can only remove your own messages.');
  perform tests.assert_eq('you can take yours back', tests.f(ann, a_e, format($q$public.dm_delete_message(%L, %L)$q$, p_ann, m1::uuid), '{removed}'), 'true');
  perform tests.assert_eq('...it stays in the list as removed, without its words', tests.f(bob, b_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_bob, c1), '{removed}') || '/' || tests.f(bob, b_e, format($q$(public.dm_messages(%L, %L)) -> 0$q$, p_bob, c1), '{body}'), 'true/(null)');
  perform tests.assert_eq('...and is not counted as unread', tests.q(bob, b_e, format($q$(select e ->> 'unread' from jsonb_array_elements(public.dm_inbox(%L)) e where e ->> 'id' = %L)$q$, p_bob, c1)), '0');
  perform tests.assert_eq('the inbox shows the latest message, newest conversation first', tests.names(ann, a_e, format($q$public.dm_inbox(%L, 'main', 1)$q$, p_ann)) = c1::text, true);
  perform tests.say(ann, a_e, p_ann, c2, 'latest in c2');
  txt := tests.names(ann, a_e, format($q$public.dm_inbox(%L)$q$, p_ann));
  perform tests.assert_eq('the conversation with the newest message comes first', split_part(txt, ',', 1), c2::text);
  perform tests.assert_eq('a page of one', tests.names(ann, a_e, format($q$public.dm_inbox(%L, 'main', 1)$q$, p_ann)), c2::text);
  perform tests.assert_eq('the next page starts after the last one seen', tests.names(ann, a_e, format($q$public.dm_inbox(%L, 'main', 1, %L::timestamptz, %L)$q$, p_ann,
    tests.f(ann, a_e, format($q$(public.dm_inbox(%L, 'main', 1)) -> 0$q$, p_ann), '{last_message_at}'), tests.f(ann, a_e, format($q$(public.dm_inbox(%L, 'main', 1)) -> 0$q$, p_ann), '{id}')::uuid)) like split_part(txt, ',', 2) || '%', true);
  perform tests.assert_eq('in a booking conversation only the venue''s reply is new to the customer, not her own booking card', tests.q(ann, a_e, format($q$(select e ->> 'unread' from jsonb_array_elements(public.dm_inbox(%L)) e where e ->> 'id' = %L)$q$, p_ann, cb)), '1');
  perform tests.assert_eq('one conversation can be read on its own, with its title', tests.f(bob, b_e, format($q$public.dm_conversation(%L, %L)$q$, p_bob, cg), '{title}'), 'Saturday crew');
  perform tests.assert_eq('...only by someone in it', tests.q(rando, r_e, format($q$public.dm_conversation(%L, %L)$q$, p_rando, c1)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...and it says the same as the inbox does', tests.f(bob, b_e, format($q$public.dm_conversation(%L, %L)$q$, p_bob, c1), '{member_count}'), '2');
  perform tests.assert_eq('a made-up box is refused', tests.q(ann, a_e, format($q$public.dm_inbox(%L, 'archive')$q$, p_ann)), 'ERROR: Choose main or requests.');
  txt := tests.names(ann, a_e, format($q$public.dm_messages(%L, %L, 5)$q$, p_ann, c1), 'id');
  perform tests.assert_eq('the next page of messages starts after the last one seen', tests.names(ann, a_e, format($q$public.dm_messages(%L, %L, 1, %L::timestamptz, %L)$q$, p_ann, c1,
    tests.f(ann, a_e, format($q$(public.dm_messages(%L, %L, 1)) -> 0$q$, p_ann, c1), '{created_at}'), tests.f(ann, a_e, format($q$(public.dm_messages(%L, %L, 1)) -> 0$q$, p_ann, c1), '{id}')::uuid), 'id'), split_part(txt, ',', 2));
  perform tests.assert_eq('messages page, newest first', tests.names(ann, a_e, format($q$public.dm_messages(%L, %L, 2)$q$, p_ann, c1), 'removed'), 'true,false');

  ---------------------------------------------------------------- notifications
  delete from public.site_notifications;
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, false)$q$, p_cy, p_ann));
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, true)$q$, p_cy, p_ann));
  perform tests.assert_eq('a follow notifies the one followed', tests.names(ann, a_e, format($q$public.notifications_list(%L)$q$, p_ann), 'kind'), 'follow');
  perform tests.assert_eq('...showing who and whether you follow them back', tests.f(ann, a_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_ann), '{actor,handle}') || '/' || tests.f(ann, a_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_ann), '{follows_back}'), 'cyrus/false');
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, false)$q$, p_cy, p_ann));
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, true)$q$, p_cy, p_ann));
  perform tests.assert_eq('following again after unfollowing is not a second notification', (select count(*) from public.site_notifications where recipient = p_ann and kind = 'follow' and actor = p_cy)::int, 1);
  perform tests.login(dee, d_e); perform public.profile_save_personal('private'); perform tests.logout();
  perform tests.q(rando, r_e, format($q$public.follow_set(%L, %L, true)$q$, p_rando, p_dee));
  perform tests.assert_eq('a request to follow a private profile', tests.names(dee, d_e, format($q$public.notifications_list(%L)$q$, p_dee), 'kind'), 'follow_request');
  perform tests.q(dee, d_e, format($q$public.follow_respond(%L, %L, 'accept')$q$, p_dee, p_rando));
  perform tests.assert_eq('accepting tells the one who asked', tests.names(rando, r_e, format($q$public.notifications_list(%L)$q$, p_rando), 'kind'), 'follow_accepted');
  perform tests.assert_eq('...and who accepted', tests.f(rando, r_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_rando), '{actor,handle}'), 'dee');

  perform tests.q(ann, a_e, format($q$public.notifications_read(%L)$q$, p_ann));
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, false)$q$, p_cy, p_ann));
  perform tests.q(cy, c_e, format($q$public.follow_set(%L, %L, true)$q$, p_cy, p_ann));
  perform tests.assert_eq('the same follow again does not make the old notification unread again', tests.q(ann, a_e, format($q$public.notifications_unread(%L)$q$, p_ann)), '0');
  insert into public.site_post_likes (post, profile) values (post1, p_cy);
  perform tests.assert_eq('a like notifies the author, with the post', tests.f(ann, a_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_ann), '{kind}') || '/' || tests.f(ann, a_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_ann), '{post,caption}'), 'like/public post');
  insert into public.site_post_likes (post, profile) values (post1, p_ann);
  perform tests.assert_eq('liking your own post tells nobody', (select count(*) from public.site_notifications where actor = p_ann and kind = 'like')::int, 0);
  insert into public.site_posts (author, kind, caption, audience, expires_at) values (p_ann, 'story', 'a story', 'public', now() + interval '1 day');
  insert into public.site_post_likes (post, profile) select id, p_bob from public.site_posts where caption = 'a story';
  perform tests.assert_eq('liking a story does not notify', (select count(*) from public.site_notifications where kind = 'like' and post in (select id from public.site_posts where caption = 'a story'))::int, 0);
  insert into public.site_comments (post, author, body) values (post1, p_bob, 'Great!') returning id into cm1;
  perform tests.assert_eq('a comment notifies the author, with its words', tests.f(ann, a_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_ann), '{kind}') || '/' || tests.f(ann, a_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_ann), '{comment_body}'), 'comment/Great!');
  insert into public.site_comments (post, author, reply_to, body) values (post1, p_cy, cm1, 'Agreed');
  perform tests.assert_eq('a reply notifies the writer of the comment', tests.names(bob, b_e, format($q$public.notifications_list(%L)$q$, p_bob), 'kind'), 'reply');
  insert into public.site_comments (post, author, body) values (post1, p_ann, 'Thanks all');
  perform tests.assert_eq('commenting on your own post tells nobody', (select count(*) from public.site_notifications where actor = p_ann and kind = 'comment')::int, 0);
  insert into public.site_post_tags (post, profile_id) values (post1, p_dee);
  perform tests.assert_eq('a tag notifies the tagged profile (who may see the post)', tests.names(dee, d_e, format($q$public.notifications_list(%L)$q$, p_dee), 'kind'), 'tag,follow_request');
  insert into public.site_posts (author, kind, caption, audience) values (p_ann, 'post', 'members only', 'members');
  insert into public.site_post_tags (post, profile_id) select id, p_rando from public.site_posts where caption = 'members only';
  perform tests.assert_eq('a profile that cannot see the post is not told it was tagged', tests.names(rando, r_e, format($q$public.notifications_list(%L)$q$, p_rando), 'kind'), 'follow_accepted');
  insert into public.site_post_tags (post, event_id) values (post1, ev);
  perform tests.assert_eq('tagging an event or a venue makes no notification', (select count(*) from public.site_notifications where kind = 'tag')::int, 1);
  update public.site_posts set audience = 'followers' where id = post1;
  perform tests.assert_eq('a notification about a post the reader may no longer see carries no post', tests.f(dee, d_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_dee), '{post}'), '(null)');
  update public.site_posts set audience = 'public' where id = post1;
  perform tests.assert_eq('the unread count (the follow was read earlier)', tests.q(ann, a_e, format($q$public.notifications_unread(%L)$q$, p_ann)), '2');
  perform tests.assert_eq('newest first', tests.names(ann, a_e, format($q$public.notifications_list(%L)$q$, p_ann), 'kind'), 'comment,like,follow');
  perform tests.assert_eq('a page of two', tests.names(ann, a_e, format($q$public.notifications_list(%L, 2)$q$, p_ann), 'kind'), 'comment,like');
  perform tests.assert_eq('the next page starts after the last one seen', tests.names(ann, a_e, format($q$public.notifications_list(%L, 2, %L::timestamptz, %L)$q$, p_ann,
    tests.f(ann, a_e, format($q$(public.notifications_list(%L, 2)) -> 1$q$, p_ann), '{created_at}'), tests.f(ann, a_e, format($q$(public.notifications_list(%L, 2)) -> 1$q$, p_ann), '{id}')::uuid), 'kind'), 'follow');
  insert into public.site_comments (post, author, body) values (post1, p_cy, 'older');
  perform pg_sleep(0.01);
  txt := (select max(created_at)::text from public.site_notifications where recipient = p_ann);
  perform pg_sleep(0.01);
  insert into public.site_comments (post, author, body) values (post1, p_rando, 'newer');
  perform tests.assert_eq('reading up to a moment leaves the newer ones unread', tests.q(ann, a_e, format($q$public.notifications_read(%L, %L::timestamptz) ->> 'unread'$q$, p_ann, txt)), '1');
  perform tests.assert_eq('marking read', tests.q(ann, a_e, format($q$public.notifications_read(%L) ->> 'unread'$q$, p_ann)), '0');
  perform tests.assert_eq('...they stay in the list, marked read', tests.f(ann, a_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_ann), '{read}'), 'true');
  insert into public.site_comments (post, author, body) values (post1, p_dee, 'to be blocked');
  perform tests.assert_eq('one unread from dee', tests.q(ann, a_e, format($q$public.notifications_unread(%L)$q$, p_ann)), '1');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, true)$q$, p_ann, p_dee));
  perform tests.assert_eq('blocking her takes it out of the count', tests.q(ann, a_e, format($q$public.notifications_unread(%L)$q$, p_ann)), '0');
  perform tests.q(ann, a_e, format($q$public.block_set(%L, %L, false)$q$, p_ann, p_dee));
  perform tests.q(ann, a_e, format($q$public.notifications_read(%L)$q$, p_ann));
  perform tests.q(bob, b_e, format($q$public.block_set(%L, %L, true)$q$, p_bob, p_ann));
  insert into public.site_post_likes (post, profile) values (post1, p_bob);
  perform tests.assert_eq('nothing is written across a block', (select count(*) from public.site_notifications where recipient = p_ann and actor = p_bob and kind = 'like')::int, 0);
  perform tests.assert_eq('...and the earlier ones from the blocked person are hidden', tests.names(ann, a_e, format($q$public.notifications_list(%L)$q$, p_ann), 'kind'), 'comment,comment,comment,like,follow');
  perform tests.q(bob, b_e, format($q$public.block_set(%L, %L, false)$q$, p_bob, p_ann));
  update public.site_profiles set status = 'suspended' where id = p_cy;
  perform tests.assert_eq('a suspended person''s notifications are hidden (the others stay)', tests.names(ann, a_e, format($q$public.notifications_list(%L)$q$, p_ann), 'kind'), 'comment,comment,comment');
  perform tests.assert_eq('...and not counted', tests.q(ann, a_e, format($q$public.notifications_unread(%L)$q$, p_ann)), '0');
  update public.site_profiles set status = 'active' where id = p_cy;
  update public.site_profiles set status = 'suspended' where id = p_dee;
  insert into public.site_post_likes (post, profile) values (post_f, p_dee);
  update public.site_profiles set status = 'active' where id = p_dee;
  insert into public.site_posts (author, kind, caption, audience) values (p_dee, 'post', 'dee post', 'public');
  update public.site_profiles set status = 'suspended' where id = p_dee;
  insert into public.site_post_likes (post, profile) select id, p_ann from public.site_posts where caption = 'dee post';
  perform tests.assert_eq('nothing is written for a suspended profile', (select count(*) from public.site_notifications where recipient = p_dee and kind = 'like')::int, 0);
  update public.site_profiles set status = 'active' where id = p_dee;
  -- a business's notifications are read through the business
  insert into public.site_reviews (kind, venue_id, author, rating) values ('venue', va, p_rando, 4);
  insert into public.site_review_replies (review, author, body) select r.id, p_clubA, 'Thanks' from public.site_reviews r where r.author = p_rando and r.venue_id = va;
  perform tests.assert_eq('a venue''s answer to a review notifies its writer', tests.f(rando, r_e, format($q$(public.notifications_list(%L)) -> 0$q$, p_rando), '{kind}'), 'review_reply');
  perform tests.assert_eq('only the one it is for reads its notifications', tests.q(rando, r_e, format($q$public.notifications_list(%L)$q$, p_ann)), 'ERROR: You cannot act as this profile.');
  insert into public.site_notifications (recipient, kind, actor, dedupe_key, created_at) values (p_ann, 'follow', p_olly, 'old-unread', now() - interval '100 days');
  update public.site_notifications set read_at = now() - interval '100 days', created_at = now() - interval '100 days' where recipient = p_ann and dedupe_key <> 'old-unread';
  perform tests.assert_eq('old read notifications are purged by the service, not by the app', public.notifications_purge(90) >= 1, true);
  perform tests.assert_eq('...an old one that was never read is kept', (select count(*) from public.site_notifications where dedupe_key = 'old-unread')::int, 1);
  perform tests.login(ann, a_e);
  perform tests.assert_raises('the app cannot purge', $q$select public.notifications_purge(90)$q$, 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- the rest of the surface
  perform tests.login(bob, b_e);
  perform tests.assert_raises('the member check cannot be called by the app', format($q$select public.dm_is_member(%L, %L)$q$, p_bob, c1), 'permission denied');
  perform tests.assert_raises('...nor the card builders', format($q$select public.dm_message_card(%L, %L)$q$, p_bob, gen_random_uuid()), 'permission denied');
  perform tests.assert_raises('...nor the row builder', format($q$select public.dm_conversation_json(%L, %L)$q$, p_bob, c1), 'permission denied');
  perform tests.assert_raises('...nor the notifier', format($q$select public.notify_profile(%L, 'like', %L)$q$, p_bob, p_ann), 'permission denied');
  perform tests.assert_raises('...nor the reference card', format($q$select public.dm_ref_card(%L, 'booking', %L)$q$, p_bob, bk), 'permission denied');
  perform tests.assert_raises('the conversations table cannot be read', $q$select * from public.site_dm_conversations$q$, 'permission denied');
  perform tests.assert_raises('...nor the messages', $q$select * from public.site_dm_messages$q$, 'permission denied');
  perform tests.assert_raises('...nor the members', $q$select * from public.site_dm_members$q$, 'permission denied');
  perform tests.assert_raises('...nor the notifications', $q$select * from public.site_notifications$q$, 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor has no inbox', format($q$select public.dm_inbox(%L)$q$, p_bob), 'permission denied');
  perform tests.assert_raises('...or notifications', format($q$select public.notifications_list(%L)$q$, p_bob), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- a one-to-one conversation with a suspended person is gone
  perform tests.q(dee, d_e, format($q$public.follow_set(%L, %L, true)$q$, p_dee, p_cy));
  c1 := (tests.f(cy, c_e, format($q$public.dm_start_direct(%L, %L)$q$, p_cy, p_dee), '{id}'))::uuid;
  perform tests.say(cy, c_e, p_cy, c1, 'are you there');
  n := (tests.f(dee, d_e, format($q$public.dm_unread(%L)$q$, p_dee), '{conversations}'))::int;
  perform tests.assert_eq('before: dee has the conversation, can read it, and it counts as new', tests.names(dee, d_e, format($q$public.dm_inbox(%L)$q$, p_dee)) like '%' || c1::text || '%' and tests.f(dee, d_e, format($q$public.dm_conversation(%L, %L)$q$, p_dee, c1), '{id}') = c1::text and n >= 1, true);
  cg := (tests.f(dee, d_e, format($q$public.dm_start_group(%L, 'Crew', array[%L, %L]::uuid[])$q$, p_dee, p_cy, p_bob), '{id}'))::uuid;
  update public.site_profiles set status = 'suspended' where id = p_cy;
  perform tests.assert_eq('after cy is suspended it is not in the inbox', tests.names(dee, d_e, format($q$public.dm_inbox(%L)$q$, p_dee)) like '%' || c1::text || '%', false);
  perform tests.assert_eq('...it is no longer counted as new', (tests.f(dee, d_e, format($q$public.dm_unread(%L)$q$, p_dee), '{conversations}'))::int, n - 1);
  perform tests.assert_eq('...it cannot be read by its address', tests.q(dee, d_e, format($q$public.dm_messages(%L, %L)$q$, p_dee, c1)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...nor its head', tests.q(dee, d_e, format($q$public.dm_conversation(%L, %L)$q$, p_dee, c1)), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('...nor written to', tests.say(dee, d_e, p_dee, c1, 'hello?'), 'ERROR: This conversation isn''t available.');
  perform tests.assert_eq('a group that person is in goes on without them', tests.f(dee, d_e, format($q$public.dm_conversation(%L, %L)$q$, p_dee, cg), '{id}'), cg::text);
  update public.site_profiles set status = 'active' where id = p_cy;
  perform tests.assert_eq('once restored it is all back', tests.names(dee, d_e, format($q$public.dm_inbox(%L)$q$, p_dee)) like '%' || c1::text || '%' and tests.f(dee, d_e, format($q$public.dm_conversation(%L, %L)$q$, p_dee, c1), '{id}') = c1::text, true);
  -- and a request from a suspended person is not counted
  c2 := (tests.f(olly, o_e, format($q$public.dm_start_direct(%L, %L)$q$, p_olly, p_rando), '{id}'))::uuid;
  perform tests.say(olly, o_e, p_olly, c2, 'hello stranger');
  n := (tests.f(rando, r_e, format($q$public.dm_unread(%L)$q$, p_rando), '{requests}'))::int;
  perform tests.assert_eq('a request waiting is counted', n >= 1, true);
  update public.site_profiles set status = 'suspended' where id = p_olly;
  perform tests.assert_eq('...and is not counted once the writer is suspended', (tests.f(rando, r_e, format($q$public.dm_unread(%L)$q$, p_rando), '{requests}'))::int, n - 1);
  update public.site_profiles set status = 'active' where id = p_olly;

  ---------------------------------------------------------------- choosing what to be told about
  insert into public.site_posts (author, kind, caption, audience) values (p_ann, 'post', 'pref one', 'public') returning id into post_f;
  perform tests.assert_eq('every kind is on to begin with', tests.q(ann, a_e, format($q$(select count(*) from jsonb_each_text(public.notification_prefs(%L)) where value = 'true')$q$, p_ann)), '8');
  perform tests.assert_eq('switching likes off says so', tests.f(ann, a_e, format($q$public.notification_prefs_set(%L, array['like'], false)$q$, p_ann), '{like}'), 'false');
  perform tests.assert_eq('...and the others are still on', tests.q(ann, a_e, format($q$(select count(*) from jsonb_each_text(public.notification_prefs(%L)) where value = 'true')$q$, p_ann)), '7');
  n := (select count(*) from public.site_notifications where recipient = p_ann and kind = 'like');
  insert into public.site_post_likes (post, profile) values (post_f, p_bob);
  perform tests.assert_eq('a like is no longer written for her', (select count(*) from public.site_notifications where recipient = p_ann and kind = 'like')::int, n);
  insert into public.site_comments (post, author, body) values (post_f, p_bob, 'still told about this');
  perform tests.assert_eq('...but a comment still is', (select count(*) from public.site_notifications where recipient = p_ann and kind = 'comment' and comment in (select id from public.site_comments where body = 'still told about this'))::int, 1);
  perform tests.assert_eq('what was written before stays in her list', (select count(*) from public.site_notifications where recipient = p_ann and kind = 'like')::int, n);
  insert into public.site_posts (author, kind, caption, audience) values (p_bob, 'post', 'bobs pref post', 'public') returning id into post_f;
  insert into public.site_post_likes (post, profile) values (post_f, p_cy);
  perform tests.assert_eq('someone else is still told of a like while she has them off', (select count(*) from public.site_notifications where recipient = p_bob and kind = 'like' and post = post_f)::int, 1);
  perform tests.assert_eq('it is her own choice: bob''s are untouched', tests.f(bob, b_e, format($q$public.notification_prefs(%L)$q$, p_bob), '{like}'), 'true');
  perform tests.q(bob, b_e, format($q$public.notification_prefs_set(%L, array['like'], false)$q$, p_bob));
  perform tests.assert_eq('switching it back on', tests.f(ann, a_e, format($q$public.notification_prefs_set(%L, array['like'], true)$q$, p_ann), '{like}'), 'true');
  perform tests.assert_eq('...does not touch what bob chose', tests.f(bob, b_e, format($q$public.notification_prefs(%L)$q$, p_bob), '{like}'), 'false');
  perform tests.q(bob, b_e, format($q$public.notification_prefs_set(%L, array['like'], true)$q$, p_bob));
  perform tests.q(bob, b_e, format($q$public.notification_prefs_set(%L, array['tag'], false)$q$, p_bob));
  insert into public.site_posts (author, kind, caption, audience) values (p_ann, 'post', 'pref two', 'public') returning id into post_f;
  insert into public.site_post_likes (post, profile) values (post_f, p_bob);
  perform tests.assert_eq('...and likes are written again', (select count(*) from public.site_notifications where recipient = p_ann and kind = 'like')::int, n + 1);
  perform tests.assert_eq('several kinds at once', tests.f(ann, a_e, format($q$public.notification_prefs_set(%L, array['follow', 'follow_request', 'follow_accepted'], false)$q$, p_ann), '{follow_request}'), 'false');
  n := (select count(*) from public.site_notifications where recipient = p_ann and kind = 'follow');
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, false)$q$, p_bob, p_ann));
  perform tests.q(bob, b_e, format($q$public.follow_set(%L, %L, true)$q$, p_bob, p_ann));
  perform tests.assert_eq('...a new follow is not written', (select count(*) from public.site_notifications where recipient = p_ann and kind = 'follow')::int, n);
  perform tests.q(ann, a_e, format($q$public.notification_prefs_set(%L, array['follow', 'follow_request', 'follow_accepted'], true)$q$, p_ann));
  perform tests.assert_eq('a choice must name something real', tests.q(ann, a_e, format($q$public.notification_prefs_set(%L, array['like', 'poke'], false)$q$, p_ann)), 'ERROR: Choose what to change.');
  perform tests.assert_eq('...at least one', tests.q(ann, a_e, format($q$public.notification_prefs_set(%L, array[]::text[], false)$q$, p_ann)), 'ERROR: Choose what to change.');
  perform tests.assert_eq('...not nothing at all', tests.q(ann, a_e, format($q$public.notification_prefs_set(%L, null, false)$q$, p_ann)), 'ERROR: Choose what to change.');
  perform tests.assert_eq('...and no more than there are', tests.q(ann, a_e, format($q$public.notification_prefs_set(%L, array['follow', 'follow_request', 'follow_accepted', 'like', 'comment', 'reply', 'tag', 'review_reply', 'like'], false)$q$, p_ann)), 'ERROR: Choose what to change.');
  perform tests.assert_eq('...and on or off', tests.q(ann, a_e, format($q$public.notification_prefs_set(%L, array['like'], null)$q$, p_ann)), 'ERROR: Choose on or off.');
  perform tests.assert_eq('only as a profile you can act as', tests.q(bob, b_e, format($q$public.notification_prefs_set(%L, array['like'], false)$q$, p_ann)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...checked before anything else', tests.q(bob, b_e, format($q$public.notification_prefs_set(%L, array['poke'], false)$q$, p_ann)), 'ERROR: You cannot act as this profile.');
  perform tests.assert_eq('...to read them too', tests.q(bob, b_e, format($q$public.notification_prefs(%L)$q$, p_ann)), 'ERROR: You cannot act as this profile.');
  perform tests.login(bob, b_e);
  perform tests.assert_raises('the table of choices is closed', $q$select * from public.site_notification_opt_outs$q$, 'permission denied');
  perform tests.logout();
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot choose', format($q$select public.notification_prefs_set(%L, array['like'], false)$q$, p_ann), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- deleting an account
  perform tests.assert_eq('bob has chosen something before his account goes', (select count(*) from public.site_notification_opt_outs where profile = p_bob)::int, 1);
  delete from auth.users where id = bob;
  perform tests.assert_eq('deleting an account removes what that profile chose', (select count(*) from public.site_notification_opt_outs where profile = p_bob)::int, 0);
  perform tests.assert_eq('deleting an account removes her messages, memberships and notifications', (select count(*) from public.site_dm_messages where sender = p_bob)::int + (select count(*) from public.site_dm_members where profile = p_bob)::int + (select count(*) from public.site_notifications where recipient = p_bob or actor = p_bob)::int, 0);
  perform tests.assert_eq('a conversation survives for the people who remain', (select count(*) from public.site_dm_conversations where id = cg)::int, 1);
  delete from public.site_table_bookings where id = bk;
  perform tests.assert_eq('deleting a booking removes its conversation', (select count(*) from public.site_dm_conversations where id = cb)::int, 0);
end $$;

rollback;
