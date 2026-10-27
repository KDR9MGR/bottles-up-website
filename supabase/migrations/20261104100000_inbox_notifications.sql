-- Inbox and notifications (customer app completion plan, M4; client plan page 5 and 17).
--
--   * CONVERSATIONS between profiles: direct, group, and about a booking (the customer and the venue's own profile, with a safe card of the booking). A member is a PROFILE, so
--     a business conversation is read by whoever may act as that business RIGHT NOW (revoke a manager and they are out at once), exactly as the staff chat works.
--   * MESSAGE REQUESTS: someone who is not followed by the person they write to lands in that person's Requests box. The writer may send three messages before an answer; replying
--     accepts. Declining hides the conversation quietly (the writer is not told). A blocked pair cannot write to each other.
--   * A MESSAGE is text (1 to 2000 characters) or a shared post, event, venue or booking with an optional note. A shared post shows only to people who may see it; a booking card
--     shows the venue, the night, the table and the party size and NEVER the confirmation code or any payment. At most 30 messages a minute from one profile to one conversation, and
--     a retried send with the same client key is one message. Sending needs the community rules accepted and the `inbox` switch on; text goes through the banned-terms check.
--   * NOTIFICATIONS in the app: someone followed, asked to follow, accepted your request, liked or commented on your post, replied to your comment, tagged you, answered your review.
--     Written by triggers on those events (never for yourself, never between a blocked pair, a tag only when the tagged profile can see the post); a notification is read through the
--     profile it is for, so a business's team sees the business's. Push delivery is a separate step that needs the owner's Firebase account.
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.site_dm_conversations (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('direct', 'group', 'booking')),
  title text check (title is null or char_length(btrim(title)) between 1 and 60),
  pair_key text,
  booking_id uuid references public.site_table_bookings (id) on delete cascade,
  created_by uuid references public.site_profiles (id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  last_message_at timestamptz not null default clock_timestamp(),
  constraint site_dm_shape check (
    (kind = 'direct' and pair_key is not null and booking_id is null and title is null)
    or (kind = 'group' and title is not null and pair_key is null and booking_id is null)
    or (kind = 'booking' and booking_id is not null and pair_key is null)
  )
);
create unique index site_dm_one_direct on public.site_dm_conversations (pair_key) where kind = 'direct';
create unique index site_dm_one_per_booking on public.site_dm_conversations (booking_id) where kind = 'booking';

create table public.site_dm_members (
  conversation uuid not null references public.site_dm_conversations (id) on delete cascade,
  profile uuid not null references public.site_profiles (id) on delete cascade,
  role text not null default 'member' check (role in ('member', 'admin')),
  status text not null default 'active' check (status in ('active', 'request', 'left')),
  joined_at timestamptz not null default clock_timestamp(),
  last_read_at timestamptz not null default clock_timestamp(),
  muted boolean not null default false,
  primary key (conversation, profile)
);
create index site_dm_members_profile_idx on public.site_dm_members (profile, status);

create table public.site_dm_messages (
  id uuid primary key default gen_random_uuid(),
  conversation uuid not null references public.site_dm_conversations (id) on delete cascade,
  sender uuid not null references public.site_profiles (id) on delete cascade,
  kind text not null check (kind in ('text', 'post', 'event', 'venue', 'booking')),
  body text check (body is null or char_length(btrim(body)) between 1 and 2000),
  ref_id uuid,
  client_key text check (client_key is null or char_length(client_key) <= 64),
  -- The moment it was written, so "unread" and a page ordered by it have no ties.
  created_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz,
  constraint site_dm_message_shape check ((kind = 'text' and body is not null and ref_id is null) or (kind <> 'text' and ref_id is not null))
);
create index site_dm_messages_conversation_idx on public.site_dm_messages (conversation, created_at desc, id desc);
create unique index site_dm_messages_client_key_idx on public.site_dm_messages (conversation, sender, client_key) where client_key is not null;

create table public.site_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient uuid not null references public.site_profiles (id) on delete cascade,
  kind text not null check (kind in ('follow', 'follow_request', 'follow_accepted', 'like', 'comment', 'reply', 'tag', 'review_reply')),
  actor uuid not null references public.site_profiles (id) on delete cascade,
  post uuid references public.site_posts (id) on delete cascade,
  comment uuid references public.site_comments (id) on delete cascade,
  review uuid references public.site_reviews (id) on delete cascade,
  dedupe_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  read_at timestamptz,
  unique (recipient, dedupe_key)
);
create index site_notifications_recipient_idx on public.site_notifications (recipient, created_at desc, id desc);
create index site_notifications_unread_idx on public.site_notifications (recipient) where read_at is null;

alter table public.site_dm_conversations enable row level security;
alter table public.site_dm_members enable row level security;
alter table public.site_dm_messages enable row level security;
alter table public.site_notifications enable row level security;
revoke all on table public.site_dm_conversations, public.site_dm_members, public.site_dm_messages, public.site_notifications from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
-- Is this profile a member of the conversation who has not left, and may the caller act as it?
create function public.dm_is_member(p_actor uuid, p_conversation uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.profile_can_act_as(p_actor)
     and exists (select 1 from public.site_dm_members m where m.conversation = p_conversation and m.profile = p_actor and m.status in ('active', 'request'))
$$;

-- How a new member is received: straight into the inbox when they follow the person adding them, otherwise as a request.
create function public.dm_new_member_status(p_inviter uuid, p_member uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when exists (select 1 from public.site_follows f where f.follower = p_member and f.followed = p_inviter and f.status = 'active') then 'active' else 'request' end
$$;

-- What a message refers to, as the viewer may see it. A post only if the viewer may see it; a booking only a safe summary (never the code, never money).
create function public.dm_ref_card(p_viewer uuid, p_kind text, p_ref uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_kind = 'post' then
    if p_ref is not null and public.post_visible(p_viewer, p_ref) then return jsonb_build_object('available', true, 'post', public.post_card(p_viewer, p_ref)); end if;
    return jsonb_build_object('available', false);
  elsif p_kind = 'event' then
    return coalesce((select jsonb_build_object('available', true, 'id', e.id, 'title', e.title, 'starts_at', e.start_date, 'venue_name', e.venue_name)
                     from public.site_events e where e.id = p_ref and e.status = 'published'), jsonb_build_object('available', false));
  elsif p_kind = 'venue' then
    return coalesce((select jsonb_build_object('available', true, 'id', v.id, 'name', v.name, 'address', v.address)
                     from public.site_venues v where v.id = p_ref and v.status = 'published'), jsonb_build_object('available', false));
  elsif p_kind = 'booking' then
    return coalesce((select jsonb_build_object('available', true, 'id', b.id, 'venue', v.name, 'night', b.booking_date, 'table', t.name, 'guests', b.guest_count, 'status', b.status)
                     from public.site_table_bookings b
                     join public.site_venues v on v.id = b.venue_id
                     left join public.site_table_types t on t.id = b.table_type_id
                     where b.id = p_ref), jsonb_build_object('available', false));
  end if;
  return null;
end;
$$;

-- One message as the app shows it. A removed message keeps its place but loses its words.
create function public.dm_message_card(p_viewer uuid, p_message uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', m.id,
    'conversation', m.conversation,
    'kind', m.kind,
    'body', case when m.deleted_at is null then m.body end,
    'removed', m.deleted_at is not null,
    'created_at', m.created_at,
    'sender', public.profile_mini(m.sender),
    'is_mine', public.profile_is_mine(m.sender),
    'ref', case when m.deleted_at is null and m.kind <> 'text' then public.dm_ref_card(p_viewer, m.kind, m.ref_id) end
  )
  from public.site_dm_messages m
  where m.id = p_message
$$;

-- Put a notification in a profile's list once. Never for oneself, never across a block.
create function public.notify_profile(p_recipient uuid, p_kind text, p_actor uuid, p_post uuid default null, p_comment uuid default null, p_review uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_recipient is null or p_actor is null or p_recipient = p_actor then return; end if;
  if public.profile_blocked_between(p_recipient, p_actor) then return; end if;
  if not exists (select 1 from public.site_profiles s where s.id = p_recipient and s.status = 'active') then return; end if;
  insert into public.site_notifications (recipient, kind, actor, post, comment, review, dedupe_key)
  values (p_recipient, p_kind, p_actor, p_post, p_comment, p_review,
          p_kind || ':' || p_actor::text || ':' || coalesce(p_post::text, '') || ':' || coalesce(p_comment::text, '') || ':' || coalesce(p_review::text, ''))
  on conflict (recipient, dedupe_key) do nothing;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Triggers that write notifications
-- ---------------------------------------------------------------------------
create function public.notify_on_follow()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.notify_profile(new.followed, case new.status when 'active' then 'follow' else 'follow_request' end, new.follower);
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'active' then
    perform public.notify_profile(new.follower, 'follow_accepted', new.followed);
  end if;
  return new;
end;
$$;
create trigger site_follows_notify after insert or update of status on public.site_follows for each row execute function public.notify_on_follow();

create function public.notify_on_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.notify_profile((select p.author from public.site_posts p where p.id = new.post and p.kind <> 'story'), 'like', new.profile, new.post);
  return new;
end;
$$;
create trigger site_post_likes_notify after insert on public.site_post_likes for each row execute function public.notify_on_like();

create function public.notify_on_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.reply_to is null then
    perform public.notify_profile((select p.author from public.site_posts p where p.id = new.post), 'comment', new.author, new.post, new.id);
  else
    perform public.notify_profile((select c.author from public.site_comments c where c.id = new.reply_to), 'reply', new.author, new.post, new.id);
  end if;
  return new;
end;
$$;
create trigger site_comments_notify after insert on public.site_comments for each row execute function public.notify_on_comment();

create function public.notify_on_tag()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
begin
  if new.profile_id is null then return new; end if;
  select p.author into v_author from public.site_posts p where p.id = new.post;
  -- A tagged profile that could not see the post is not told about it.
  if public.post_visible(new.profile_id, new.post) then
    perform public.notify_profile(new.profile_id, 'tag', v_author, new.post);
  end if;
  return new;
end;
$$;
create trigger site_post_tags_notify after insert on public.site_post_tags for each row execute function public.notify_on_tag();

create function public.notify_on_review_reply()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.notify_profile((select r.author from public.site_reviews r where r.id = new.review), 'review_reply', new.author, null, null, new.review);
  return new;
end;
$$;
create trigger site_review_replies_notify after insert on public.site_review_replies for each row execute function public.notify_on_review_reply();

-- ---------------------------------------------------------------------------
-- 4. Starting a conversation
-- ---------------------------------------------------------------------------
create function public.dm_require_inbox()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.feature_enabled('social') or not public.feature_enabled('inbox') then raise exception 'Messages are not open yet.'; end if;
end;
$$;

-- A direct conversation with one profile: the one that exists, or a new one (a request when they do not follow you).
create function public.dm_start_direct(p_actor uuid, p_other uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_id uuid;
begin
  perform public.profile_require_actor(p_actor);
  perform public.dm_require_inbox();
  if p_other is null or p_other = p_actor or public.profile_is_mine(p_other) then raise exception 'You cannot message your own profile.'; end if;
  if not public.profile_visible(p_actor, p_other) then raise exception 'This profile isn''t available.'; end if;
  v_key := least(p_actor::text, p_other::text) || ':' || greatest(p_actor::text, p_other::text);
  select c.id into v_id from public.site_dm_conversations c where c.kind = 'direct' and c.pair_key = v_key;
  if v_id is null then
    begin
      insert into public.site_dm_conversations (kind, pair_key, created_by) values ('direct', v_key, p_actor) returning id into v_id;
      insert into public.site_dm_members (conversation, profile, status) values (v_id, p_actor, 'active');
      insert into public.site_dm_members (conversation, profile, status) values (v_id, p_other, public.dm_new_member_status(p_actor, p_other));
    exception when unique_violation then
      select c.id into v_id from public.site_dm_conversations c where c.kind = 'direct' and c.pair_key = v_key;
    end;
  end if;
  -- Writing again to someone who had left a conversation does not bring it back for them.
  update public.site_dm_members set status = 'active' where conversation = v_id and profile = p_actor and status = 'left';
  return jsonb_build_object('id', v_id);
end;
$$;

-- A group: a name and up to 49 other profiles (each one who follows you joins; the rest get a request).
create function public.dm_start_group(p_actor uuid, p_title text, p_members uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text := btrim(coalesce(p_title, ''));
  v_members uuid[];
  v_id uuid;
  v_m uuid;
begin
  perform public.profile_require_actor(p_actor);
  perform public.dm_require_inbox();
  if char_length(v_title) < 1 or char_length(v_title) > 60 then raise exception 'Give the group a name (60 characters at most).'; end if;
  if not public.social_text_ok(v_title) then raise exception 'That text goes against our community rules.'; end if;
  select coalesce(array_agg(distinct x), '{}') into v_members from unnest(coalesce(p_members, '{}')) x where x is not null and x <> p_actor;
  if cardinality(v_members) < 1 then raise exception 'Choose at least one person to add.'; end if;
  if cardinality(v_members) > 49 then raise exception 'A group can have 50 people at most.'; end if;
  foreach v_m in array v_members loop
    if public.profile_is_mine(v_m) or not public.profile_visible(p_actor, v_m) then raise exception 'One of those profiles isn''t available.'; end if;
  end loop;
  insert into public.site_dm_conversations (kind, title, created_by) values ('group', v_title, p_actor) returning id into v_id;
  insert into public.site_dm_members (conversation, profile, role, status) values (v_id, p_actor, 'admin', 'active');
  foreach v_m in array v_members loop
    insert into public.site_dm_members (conversation, profile, status) values (v_id, v_m, public.dm_new_member_status(p_actor, v_m));
  end loop;
  return jsonb_build_object('id', v_id);
end;
$$;

create function public.dm_group_add(p_actor uuid, p_conversation uuid, p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  perform public.dm_require_inbox();
  if not exists (select 1 from public.site_dm_conversations c join public.site_dm_members m on m.conversation = c.id
                 where c.id = p_conversation and c.kind = 'group' and m.profile = p_actor and m.role = 'admin' and m.status = 'active') then
    raise exception 'Only a group''s admin can add people.';
  end if;
  if p_member is null or public.profile_is_mine(p_member) or not public.profile_visible(p_actor, p_member) then raise exception 'This profile isn''t available.'; end if;
  if (select count(*) from public.site_dm_members m where m.conversation = p_conversation and m.status <> 'left') >= 50 then raise exception 'A group can have 50 people at most.'; end if;
  insert into public.site_dm_members (conversation, profile, status) values (p_conversation, p_member, public.dm_new_member_status(p_actor, p_member))
  on conflict (conversation, profile) do update set status = excluded.status, joined_at = clock_timestamp(), last_read_at = clock_timestamp() where public.site_dm_members.status = 'left';
  return jsonb_build_object('members', (select count(*) from public.site_dm_members m where m.conversation = p_conversation and m.status <> 'left'));
end;
$$;

create function public.dm_group_remove(p_actor uuid, p_conversation uuid, p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if not exists (select 1 from public.site_dm_conversations c join public.site_dm_members m on m.conversation = c.id
                 where c.id = p_conversation and c.kind = 'group' and m.profile = p_actor and m.role = 'admin' and m.status = 'active') then
    raise exception 'Only a group''s admin can remove people.';
  end if;
  if p_member = p_actor or public.profile_is_mine(p_member) then raise exception 'Use Leave to leave a group yourself.'; end if;
  update public.site_dm_members set status = 'left' where conversation = p_conversation and profile = p_member and status <> 'left';
  return jsonb_build_object('members', (select count(*) from public.site_dm_members m where m.conversation = p_conversation and m.status <> 'left'));
end;
$$;

create function public.dm_group_rename(p_actor uuid, p_conversation uuid, p_title text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text := btrim(coalesce(p_title, ''));
begin
  perform public.profile_require_actor(p_actor);
  if not exists (select 1 from public.site_dm_conversations c join public.site_dm_members m on m.conversation = c.id
                 where c.id = p_conversation and c.kind = 'group' and m.profile = p_actor and m.role = 'admin' and m.status = 'active') then
    raise exception 'Only a group''s admin can rename it.';
  end if;
  if char_length(v_title) < 1 or char_length(v_title) > 60 then raise exception 'Give the group a name (60 characters at most).'; end if;
  if not public.social_text_ok(v_title) then raise exception 'That text goes against our community rules.'; end if;
  update public.site_dm_conversations set title = v_title where id = p_conversation;
  return jsonb_build_object('title', v_title);
end;
$$;

-- Leave a group. When the last admin leaves, the member who joined first takes over.
create function public.dm_leave(p_actor uuid, p_conversation uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next uuid;
begin
  perform public.profile_require_actor(p_actor);
  if not exists (select 1 from public.site_dm_conversations c where c.id = p_conversation and c.kind = 'group') then raise exception 'You can only leave a group.'; end if;
  update public.site_dm_members set status = 'left', role = 'member' where conversation = p_conversation and profile = p_actor and status <> 'left';
  if not exists (select 1 from public.site_dm_members m where m.conversation = p_conversation and m.role = 'admin' and m.status = 'active') then
    select m.profile into v_next from public.site_dm_members m where m.conversation = p_conversation and m.status = 'active' order by m.joined_at, m.profile limit 1;
    if v_next is not null then update public.site_dm_members set role = 'admin' where conversation = p_conversation and profile = v_next; end if;
  end if;
  return jsonb_build_object('left', true);
end;
$$;

-- A conversation between the customer and the venue about their booking. Only the person the booking was made for (matched by e-mail) can start it.
create function public.dm_start_booking(p_actor uuid, p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_venue_profile uuid;
  v_id uuid;
begin
  perform public.profile_require_actor(p_actor);
  perform public.dm_require_inbox();
  if exists (select 1 from public.site_profiles s where s.id = p_actor and s.kind = 'business') then raise exception 'Only a person''s own profile can message about a booking.'; end if;
  select b.venue_id into v_venue from public.site_table_bookings b
  where b.id = p_booking and b.status = 'paid' and lower(b.customer_email) = lower(coalesce(auth.email(), '')) and coalesce(auth.email(), '') <> '';
  if v_venue is null then raise exception 'You can only message about a booking you made.'; end if;
  select s.id into v_venue_profile from public.site_profiles s where s.venue_id = v_venue and s.status = 'active';
  if v_venue_profile is null then raise exception 'This venue has not set up messages yet.'; end if;
  select c.id into v_id from public.site_dm_conversations c where c.kind = 'booking' and c.booking_id = p_booking;
  if v_id is null then
    begin
      insert into public.site_dm_conversations (kind, booking_id, created_by) values ('booking', p_booking, p_actor) returning id into v_id;
      insert into public.site_dm_members (conversation, profile, status) values (v_id, p_actor, 'active'), (v_id, v_venue_profile, 'active');
      insert into public.site_dm_messages (conversation, sender, kind, ref_id) values (v_id, p_actor, 'booking', p_booking);
    exception when unique_violation then
      select c.id into v_id from public.site_dm_conversations c where c.kind = 'booking' and c.booking_id = p_booking;
    end;
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Sending, reading, and the inbox
-- ---------------------------------------------------------------------------
-- Send a message: p_ref_kind / p_ref_id share a post, event, venue or booking (p_body is then an optional note).
create function public.dm_send(p_actor uuid, p_conversation uuid, p_body text default null, p_client_key text default null, p_ref_kind text default null, p_ref_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_kind text := coalesce(nullif(lower(btrim(coalesce(p_ref_kind, ''))), ''), 'text');
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
  v_conv public.site_dm_conversations;
  v_my_status text;
  v_other_status text;
  v_id uuid;
begin
  perform public.profile_require_actor(p_actor);
  perform public.social_require_rules();
  perform public.dm_require_inbox();
  select * into v_conv from public.site_dm_conversations where id = p_conversation;
  if not found or not public.dm_is_member(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;
  select m.status into v_my_status from public.site_dm_members m where m.conversation = p_conversation and m.profile = p_actor;
  if v_conv.kind = 'direct' and exists (
    select 1 from public.site_dm_members m where m.conversation = p_conversation and m.profile <> p_actor and public.profile_blocked_between(p_actor, m.profile)
  ) then
    raise exception 'This conversation isn''t available.';
  end if;

  -- a retried send is the same message
  if p_client_key is not null then
    select m.id into v_id from public.site_dm_messages m where m.conversation = p_conversation and m.sender = p_actor and m.client_key = p_client_key;
    if v_id is not null then return public.dm_message_card(p_actor, v_id); end if;
  end if;

  if v_kind not in ('text', 'post', 'event', 'venue', 'booking') then raise exception 'You cannot send that.'; end if;
  if v_kind = 'text' then
    if v_body is null then raise exception 'Write something first.'; end if;
  else
    if p_ref_id is null then raise exception 'You cannot send that.'; end if;
    if v_kind = 'post' and not public.post_visible(p_actor, p_ref_id) then raise exception 'You cannot share that post.'; end if;
    if v_kind = 'event' and not exists (select 1 from public.site_events e where e.id = p_ref_id and e.status = 'published') then raise exception 'You cannot share that event.'; end if;
    if v_kind = 'venue' and not exists (select 1 from public.site_venues v where v.id = p_ref_id and v.status = 'published') then raise exception 'You cannot share that venue.'; end if;
    if v_kind = 'booking' and not (v_conv.kind = 'booking' and v_conv.booking_id = p_ref_id) then raise exception 'A booking can only be shared in its own conversation.'; end if;
  end if;
  if v_body is not null and char_length(v_body) > (case when v_kind = 'text' then 2000 else 500 end) then
    raise exception 'A message can be % characters at most.', case when v_kind = 'text' then 2000 else 500 end;
  end if;
  if not public.social_text_ok(v_body) then raise exception 'That text goes against our community rules.'; end if;
  if (select count(*) from public.site_dm_messages m where m.sender = p_actor and m.conversation = p_conversation and m.created_at > now() - interval '1 minute') >= 30 then
    raise exception 'You are sending messages too fast. Wait a moment.';
  end if;
  -- Until the person you wrote to answers, three messages are all they get.
  if v_conv.kind = 'direct' and v_my_status = 'active' then
    select m.status into v_other_status from public.site_dm_members m where m.conversation = p_conversation and m.profile <> p_actor;
    if v_other_status <> 'active' and (select count(*) from public.site_dm_messages m where m.conversation = p_conversation and m.sender = p_actor) >= 3 then
      raise exception 'Wait for them to reply before sending more.';
    end if;
  end if;

  insert into public.site_dm_messages (conversation, sender, kind, body, ref_id, client_key)
  values (p_conversation, p_actor, v_kind, v_body, case when v_kind = 'text' then null else p_ref_id end, p_client_key)
  returning id into v_id;
  update public.site_dm_conversations set last_message_at = clock_timestamp() where id = p_conversation;
  -- Replying to a request accepts it; the sender has read what they wrote.
  update public.site_dm_members set status = 'active', last_read_at = clock_timestamp() where conversation = p_conversation and profile = p_actor;
  return public.dm_message_card(p_actor, v_id);
end;
$$;

-- A page of messages, newest first. p_before / p_before_id are the created_at and id of the last message seen.
create function public.dm_messages(p_actor uuid, p_conversation uuid, p_limit int default 30, p_before timestamptz default null, p_before_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 30), 1), 50);
begin
  perform public.profile_require_actor(p_actor);
  if not public.dm_is_member(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;
  return coalesce((
    select jsonb_agg(public.dm_message_card(p_actor, x.id) order by x.created_at desc, x.id desc)
    from (
      select m.id, m.created_at
      from public.site_dm_messages m
      where m.conversation = p_conversation
        and (p_before is null or (m.created_at, m.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
        -- a person who joined a group later does not see what was said before they joined
        and m.created_at >= (select mm.joined_at from public.site_dm_members mm where mm.conversation = p_conversation and mm.profile = p_actor)
      order by m.created_at desc, m.id desc
      limit v_limit
    ) x
  ), '[]'::jsonb);
end;
$$;

-- The inbox: p_box 'main' (conversations you are in) or 'requests' (people you do not follow, waiting). Newest activity first.
create function public.dm_inbox(p_actor uuid, p_box text default 'main', p_limit int default 30, p_before timestamptz default null, p_before_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_box text := lower(btrim(coalesce(p_box, '')));
  v_limit int := least(greatest(coalesce(p_limit, 30), 1), 50);
begin
  perform public.profile_require_actor(p_actor);
  if v_box not in ('main', 'requests') then raise exception 'Choose main or requests.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', x.id,
      'kind', x.kind,
      'title', x.title,
      'booking_id', x.booking_id,
      'status', x.status,
      'muted', x.muted,
      'last_message_at', x.last_message_at,
      'member_count', (select count(*) from public.site_dm_members mm where mm.conversation = x.id and mm.status <> 'left'),
      'others', coalesce((select jsonb_agg(public.profile_mini(o.profile) order by o.joined_at)
                          from (select mm.profile, mm.joined_at from public.site_dm_members mm
                                where mm.conversation = x.id and mm.profile <> p_actor and mm.status <> 'left' order by mm.joined_at limit 3) o), '[]'::jsonb),
      'last', (select jsonb_build_object('kind', lm.kind, 'body', case when lm.deleted_at is null then left(lm.body, 120) end, 'removed', lm.deleted_at is not null,
                                         'created_at', lm.created_at, 'sender', public.profile_mini(lm.sender), 'is_mine', public.profile_is_mine(lm.sender))
               from public.site_dm_messages lm where lm.conversation = x.id order by lm.created_at desc, lm.id desc limit 1),
      'unread', (select count(*) from public.site_dm_messages um
                 where um.conversation = x.id and um.deleted_at is null and um.sender <> p_actor and um.created_at > x.last_read_at
                   and um.created_at >= x.joined_at)
    ) order by x.last_message_at desc, x.id desc)
    from (
      select c.id, c.kind, c.title, c.booking_id, c.last_message_at, m.status, m.muted, m.last_read_at, m.joined_at
      from public.site_dm_members m
      join public.site_dm_conversations c on c.id = m.conversation
      where m.profile = p_actor
        and ((v_box = 'main' and m.status = 'active') or (v_box = 'requests' and m.status = 'request'))
        and (p_before is null or (c.last_message_at, c.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
        and not (c.kind = 'direct' and exists (select 1 from public.site_dm_members o where o.conversation = c.id and o.profile <> p_actor and public.profile_blocked_between(p_actor, o.profile)))
      order by c.last_message_at desc, c.id desc
      limit v_limit
    ) x
  ), '[]'::jsonb);
end;
$$;

create function public.dm_mark_read(p_actor uuid, p_conversation uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if not public.dm_is_member(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;
  update public.site_dm_members set last_read_at = clock_timestamp() where conversation = p_conversation and profile = p_actor;
  return jsonb_build_object('read', true);
end;
$$;

create function public.dm_mute(p_actor uuid, p_conversation uuid, p_muted boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if p_muted is null then raise exception 'Choose mute or unmute.'; end if;
  if not public.dm_is_member(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;
  update public.site_dm_members set muted = p_muted where conversation = p_conversation and profile = p_actor;
  return jsonb_build_object('muted', p_muted);
end;
$$;

-- Accept a request, or decline it (the conversation just disappears for you; the other person is not told).
create function public.dm_answer_request(p_actor uuid, p_conversation uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if p_accept is null then raise exception 'Choose accept or decline.'; end if;
  if not exists (select 1 from public.site_dm_members m where m.conversation = p_conversation and m.profile = p_actor and m.status = 'request') then
    raise exception 'There is no request here.';
  end if;
  update public.site_dm_members set status = case when p_accept then 'active' else 'left' end, last_read_at = clock_timestamp() where conversation = p_conversation and profile = p_actor;
  return jsonb_build_object('accepted', p_accept);
end;
$$;

-- Take back a message you sent. It stays in the list as "removed".
create function public.dm_delete_message(p_actor uuid, p_message uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender uuid;
  v_conv uuid;
begin
  perform public.profile_require_actor(p_actor);
  select m.sender, m.conversation into v_sender, v_conv from public.site_dm_messages m where m.id = p_message;
  if v_sender is null or v_sender <> p_actor or not public.dm_is_member(p_actor, v_conv) then raise exception 'You can only remove your own messages.'; end if;
  update public.site_dm_messages set deleted_at = coalesce(deleted_at, clock_timestamp()) where id = p_message;
  return jsonb_build_object('removed', true);
end;
$$;

-- The people in a conversation (for the group's page), with who is an admin and who has not accepted yet.
create function public.dm_people(p_actor uuid, p_conversation uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if not public.dm_is_member(p_actor, p_conversation) then raise exception 'This conversation isn''t available.'; end if;
  return coalesce((
    select jsonb_agg(public.profile_mini(m.profile) || jsonb_build_object('role', m.role, 'status', m.status) order by m.joined_at, m.profile)
    from public.site_dm_members m where m.conversation = p_conversation and m.status <> 'left'
  ), '[]'::jsonb);
end;
$$;

-- How many conversations have something new, and how many requests are waiting, for the badge on the Inbox tab. A muted conversation does not count.
create function public.dm_unread(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  return jsonb_build_object(
    'conversations', (select count(*) from public.site_dm_members m
                      where m.profile = p_actor and m.status = 'active' and not m.muted
                        and exists (select 1 from public.site_dm_messages um where um.conversation = m.conversation and um.deleted_at is null and um.sender <> p_actor
                                    and um.created_at > m.last_read_at and um.created_at >= m.joined_at)),
    'requests', (select count(*) from public.site_dm_members m where m.profile = p_actor and m.status = 'request')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Reading notifications
-- ---------------------------------------------------------------------------
create function public.notifications_list(p_actor uuid, p_limit int default 30, p_before timestamptz default null, p_before_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 30), 1), 50);
begin
  perform public.profile_require_actor(p_actor);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id,
      'kind', n.kind,
      'created_at', n.created_at,
      'read', n.read_at is not null,
      'actor', public.profile_mini(n.actor),
      'post', case when n.post is not null and public.post_visible(p_actor, n.post) then public.post_card(p_actor, n.post) end,
      'comment_body', (select left(c.body, 140) from public.site_comments c where c.id = n.comment and c.status = 'active'),
      'review_id', n.review,
      'follows_back', n.kind = 'follow' and exists (select 1 from public.site_follows f where f.follower = p_actor and f.followed = n.actor and f.status = 'active')
    ) order by n.created_at desc, n.id desc)
    from (
      select x.*
      from public.site_notifications x
      join public.site_profiles s on s.id = x.actor and s.status = 'active'
      where x.recipient = p_actor
        and (p_before is null or (x.created_at, x.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
        and not public.profile_blocked_between(p_actor, x.actor)
      order by x.created_at desc, x.id desc
      limit v_limit
    ) n
  ), '[]'::jsonb);
end;
$$;

create function public.notifications_unread(p_actor uuid)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  return (select count(*) from public.site_notifications n join public.site_profiles s on s.id = n.actor and s.status = 'active'
          where n.recipient = p_actor and n.read_at is null and not public.profile_blocked_between(p_actor, n.actor));
end;
$$;

-- Mark everything up to a moment (or everything) as read.
create function public.notifications_read(p_actor uuid, p_up_to timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  update public.site_notifications set read_at = clock_timestamp() where recipient = p_actor and read_at is null and (p_up_to is null or created_at <= p_up_to);
  return jsonb_build_object('unread', public.notifications_unread(p_actor));
end;
$$;

-- Old read notifications are deleted by a scheduled job running as the service role (nothing in the database runs it on a timer yet).
create function public.notifications_purge(p_days int default 90)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  delete from public.site_notifications where read_at is not null and created_at < now() - make_interval(days => greatest(coalesce(p_days, 90), 7));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.dm_is_member(uuid, uuid), public.dm_new_member_status(uuid, uuid), public.dm_ref_card(uuid, text, uuid), public.dm_message_card(uuid, uuid),
  public.notify_profile(uuid, text, uuid, uuid, uuid, uuid), public.notify_on_follow(), public.notify_on_like(), public.notify_on_comment(), public.notify_on_tag(),
  public.notify_on_review_reply(), public.dm_require_inbox(),
  public.dm_start_direct(uuid, uuid), public.dm_start_group(uuid, text, uuid[]), public.dm_group_add(uuid, uuid, uuid), public.dm_group_remove(uuid, uuid, uuid),
  public.dm_group_rename(uuid, uuid, text), public.dm_leave(uuid, uuid), public.dm_start_booking(uuid, uuid),
  public.dm_send(uuid, uuid, text, text, text, uuid), public.dm_messages(uuid, uuid, int, timestamptz, uuid), public.dm_inbox(uuid, text, int, timestamptz, uuid),
  public.dm_mark_read(uuid, uuid), public.dm_mute(uuid, uuid, boolean), public.dm_answer_request(uuid, uuid, boolean), public.dm_delete_message(uuid, uuid),
  public.dm_people(uuid, uuid), public.dm_unread(uuid),
  public.notifications_list(uuid, int, timestamptz, uuid), public.notifications_unread(uuid), public.notifications_read(uuid, timestamptz), public.notifications_purge(int)
from public, anon, authenticated;
grant execute on function
  public.dm_start_direct(uuid, uuid), public.dm_start_group(uuid, text, uuid[]), public.dm_group_add(uuid, uuid, uuid), public.dm_group_remove(uuid, uuid, uuid),
  public.dm_group_rename(uuid, uuid, text), public.dm_leave(uuid, uuid), public.dm_start_booking(uuid, uuid),
  public.dm_send(uuid, uuid, text, text, text, uuid), public.dm_messages(uuid, uuid, int, timestamptz, uuid), public.dm_inbox(uuid, text, int, timestamptz, uuid),
  public.dm_mark_read(uuid, uuid), public.dm_mute(uuid, uuid, boolean), public.dm_answer_request(uuid, uuid, boolean), public.dm_delete_message(uuid, uuid),
  public.dm_people(uuid, uuid), public.dm_unread(uuid),
  public.notifications_list(uuid, int, timestamptz, uuid), public.notifications_unread(uuid), public.notifications_read(uuid, timestamptz)
to authenticated, service_role;
grant execute on function public.notifications_purge(int) to service_role;
