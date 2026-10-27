-- Posts, reels, stories, comments, likes, saves and Members Only (customer app completion plan, M2; client plan pages 4 and 5).
--
--   * WHO SEES A POST is worked out from the viewer's CURRENT standing on every read, never from a stored list of viewers:
--       public    - everyone the author's profile is visible to (a public profile: anyone; a private one: its approved followers);
--       followers - people who follow the author now;
--       members   - people on the author's Members Only list who ALSO follow the author now. Taking someone off the list, or their unfollowing, ends
--                   their access at once. Nobody is told either way, and a post a person cannot see is simply absent (no lock, no count).
--     The author, and anyone who may act as the author, always sees their own. A blocked pair sees nothing of each other. A story is also hidden 24 hours
--     after it was posted. A suspended author's content is hidden.
--   * MEDIA is in a PRIVATE bucket (`social-media`). A file is readable only through a signed address that storage hands out when the same visibility rule
--     says the caller (as any profile they may act as) can see the post it belongs to; guessing a path reaches nothing. Files are uploaded into the folder of
--     the profile posting (`<profile id>/<name>`), BEFORE the post is made; post_create then checks each file really exists, is an image or a video as said,
--     and is within the size limits: images 10 MB, videos 100 MB (the bucket itself refuses more). Video length (60 s) is as the phone reports it: nothing here
--     opens the file. A file that never got a post is listed by social_media_orphans() for a clean-up job; deleting a post returns the files to remove.
--   * RULES AND SAFETY come first: nobody posts or comments before accepting the community rules (the text is written by BottlesUp in the CMS, and publishing a new version makes everyone accept again), text is
--     checked against a list of banned terms BottlesUp keeps, posting is slowed (20 an hour), commenting is slowed (20 a minute), and stories, reels and Members
--     Only each refuse until their feature switch (20261101100000) is on.
--   * Counts (likes, comments) are counted when read, from rows that still belong to active profiles.
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. The private media bucket
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('social-media', 'social-media', false, 104857600, array['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'video/quicktime'])
on conflict (id) do nothing;

-- The profile a file path belongs to (`<profile id>/<name>`), or null when the path is not of that shape.
create function public.social_media_profile(p_name text)
returns uuid
language sql
immutable
set search_path = public
as $$
  select case when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9._-]{1,100}$' then split_part(p_name, '/', 1)::uuid end
$$;

-- May the caller put a file at this path? Only into the folder of a profile they may act as. (The storage policies call these two, so they are the only
-- ones callable by the app.)
create function public.social_media_can_add(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return auth.uid() is not null and public.social_media_profile(p_name) is not null and public.profile_can_act_as(public.social_media_profile(p_name));
end;
$$;

-- ...and may the caller read it? Their own uploads, and the files of any post one of their profiles can see. (Written as plpgsql so this can come before the tables.)
create function public.social_media_visible(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return false; end if;
  if public.social_media_profile(p_name) is not null and public.profile_can_act_as(public.social_media_profile(p_name)) then return true; end if;
  return exists (
    select 1
    from public.site_post_media m
    where (m.storage_path = p_name or m.poster_path = p_name)
      and exists (
        select 1
        from public.profile_my_ids() as me(id)
        join public.site_profiles sp on sp.id = me.id and sp.status = 'active'
        where public.post_visible(me.id, m.post)
      )
  );
end;
$$;

create policy "social media readable by those who may see the post" on storage.objects
  for select to authenticated
  using (bucket_id = 'social-media' and public.social_media_visible(name));
create policy "profiles add their own social media" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'social-media' and public.social_media_can_add(name));
create policy "profiles remove their own social media" on storage.objects
  for delete to authenticated
  using (bucket_id = 'social-media' and public.social_media_can_add(name));

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create table public.site_posts (
  id uuid primary key default gen_random_uuid(),
  author uuid not null references public.site_profiles (id) on delete cascade,
  kind text not null check (kind in ('post', 'reel', 'story')),
  caption text check (caption is null or char_length(caption) <= 2200),
  audience text not null default 'public' check (audience in ('public', 'followers', 'members')),
  comments_enabled boolean not null default true,
  status text not null default 'active' check (status in ('active', 'removed')),
  -- The moment it was written, so a page ordered by it has no ties.
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz,
  constraint site_posts_story_expiry check ((kind = 'story') = (expires_at is not null))
);
create index site_posts_author_idx on public.site_posts (author, created_at desc, id desc) where status = 'active';
create index site_posts_feed_idx on public.site_posts (created_at desc, id desc) where status = 'active' and kind in ('post', 'reel');
create index site_posts_story_idx on public.site_posts (expires_at) where kind = 'story';

create table public.site_post_media (
  id uuid primary key default gen_random_uuid(),
  post uuid not null references public.site_posts (id) on delete cascade,
  position smallint not null check (position between 0 and 9),
  media_type text not null check (media_type in ('image', 'video')),
  storage_path text not null unique check (char_length(storage_path) <= 200),
  poster_path text check (poster_path is null or char_length(poster_path) <= 200),
  width int check (width is null or width between 1 and 20000),
  height int check (height is null or height between 1 and 20000),
  duration_ms int check (duration_ms is null or duration_ms between 1 and 60000),
  bytes bigint check (bytes is null or bytes > 0),
  unique (post, position),
  constraint site_post_media_video_only check (media_type = 'video' or (poster_path is null and duration_ms is null))
);
create unique index site_post_media_poster_idx on public.site_post_media (poster_path) where poster_path is not null;

create table public.site_post_tags (
  id uuid primary key default gen_random_uuid(),
  post uuid not null references public.site_posts (id) on delete cascade,
  profile_id uuid references public.site_profiles (id) on delete cascade,
  event_id uuid references public.site_events (id) on delete cascade,
  venue_id uuid references public.site_venues (id) on delete cascade,
  check (num_nonnulls(profile_id, event_id, venue_id) = 1)
);
create unique index site_post_tags_profile_idx on public.site_post_tags (post, profile_id) where profile_id is not null;
create unique index site_post_tags_event_idx on public.site_post_tags (post, event_id) where event_id is not null;
create unique index site_post_tags_venue_idx on public.site_post_tags (post, venue_id) where venue_id is not null;
create index site_post_tags_target_idx on public.site_post_tags (profile_id) where profile_id is not null;

create table public.site_post_likes (
  post uuid not null references public.site_posts (id) on delete cascade,
  profile uuid not null references public.site_profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (post, profile)
);
create index site_post_likes_profile_idx on public.site_post_likes (profile, created_at desc);

create table public.site_post_saves (
  post uuid not null references public.site_posts (id) on delete cascade,
  profile uuid not null references public.site_profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (post, profile)
);
create index site_post_saves_profile_idx on public.site_post_saves (profile, created_at desc);

create table public.site_comments (
  id uuid primary key default gen_random_uuid(),
  post uuid not null references public.site_posts (id) on delete cascade,
  author uuid not null references public.site_profiles (id) on delete cascade,
  reply_to uuid references public.site_comments (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  status text not null default 'active' check (status in ('active', 'removed')),
  created_at timestamptz not null default clock_timestamp()
);
create index site_comments_post_idx on public.site_comments (post, created_at, id) where status = 'active';
create index site_comments_author_idx on public.site_comments (author, created_at desc);
create index site_comments_reply_idx on public.site_comments (reply_to) where reply_to is not null;

create table public.site_member_lists (
  owner uuid not null references public.site_profiles (id) on delete cascade,
  member uuid not null references public.site_profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (owner, member),
  check (owner <> member)
);
create index site_member_lists_member_idx on public.site_member_lists (member);

create table public.site_story_views (
  story uuid not null references public.site_posts (id) on delete cascade,
  viewer uuid not null references public.site_profiles (id) on delete cascade,
  viewed_at timestamptz not null default clock_timestamp(),
  primary key (story, viewer)
);

-- Words and phrases (letters, digits and spaces) that may not appear in a caption or a comment. BottlesUp keeps this list; it starts empty.
create table public.site_banned_terms (
  term text primary key check (term ~ '^[a-z0-9 ]{2,40}$')
);

-- The community rules, one row for each version BottlesUp has published (the text is written in the CMS). Until a first one is published the current version is 1 and
-- there is no text: the app shows its own draft. Publishing a new version makes everyone accept again before they post.
create table public.site_community_rules (
  version int primary key check (version >= 2),
  body text not null check (char_length(btrim(body)) between 20 and 8000),
  published_at timestamptz not null default now(),
  published_by uuid references auth.users (id) on delete set null
);

-- Each time a person asks for caption ideas (to keep it to a sensible number a day: every request costs BottlesUp money).
create table public.site_ai_caption_uses (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
create index site_ai_caption_uses_user_idx on public.site_ai_caption_uses (user_id, created_at desc);

-- Who has accepted which version of the community rules.
create table public.site_rules_acceptance (
  user_id uuid primary key references auth.users (id) on delete cascade,
  version int not null,
  accepted_at timestamptz not null default now()
);

alter table public.site_posts enable row level security;
alter table public.site_post_media enable row level security;
alter table public.site_post_tags enable row level security;
alter table public.site_post_likes enable row level security;
alter table public.site_post_saves enable row level security;
alter table public.site_comments enable row level security;
alter table public.site_member_lists enable row level security;
alter table public.site_story_views enable row level security;
alter table public.site_banned_terms enable row level security;
alter table public.site_community_rules enable row level security;
alter table public.site_ai_caption_uses enable row level security;
alter table public.site_rules_acceptance enable row level security;
revoke all on table
  public.site_posts, public.site_post_media, public.site_post_tags, public.site_post_likes, public.site_post_saves, public.site_comments,
  public.site_member_lists, public.site_story_views, public.site_banned_terms, public.site_community_rules, public.site_ai_caption_uses, public.site_rules_acceptance
from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
-- May the profile p_viewer see this post right now? (See the header for the rules.)
create function public.post_visible(p_viewer uuid, p_post uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.site_posts p
    join public.site_profiles a on a.id = p.author
    where p.id = p_post
      and p.status = 'active'
      and a.status = 'active'
      and (p.kind <> 'story' or p.expires_at > now())
      and (
        public.profile_is_mine(p.author)
        or (
          p_viewer is not null
          and not public.profile_blocked_between(p_viewer, p.author)
          and (
            (p.audience = 'public' and public.profile_content_visible(p_viewer, p.author))
            or (p.audience = 'followers'
                and exists (select 1 from public.site_follows f where f.follower = p_viewer and f.followed = p.author and f.status = 'active'))
            or (p.audience = 'members'
                and exists (select 1 from public.site_follows f where f.follower = p_viewer and f.followed = p.author and f.status = 'active')
                and exists (select 1 from public.site_member_lists l where l.owner = p.author and l.member = p_viewer))
          )
        )
      )
  )
$$;

-- A profile in a feed, comment or tag: enough to show a name, a picture and a tick.
create function public.profile_mini(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', p.id,
    'kind', p.kind,
    'handle', case p.kind when 'personal' then pr.username else p.handle end,
    'display_name', case p.kind when 'personal' then coalesce(nullif(btrim(pr.name), ''), pr.username) else p.display_name end,
    'category', p.category,
    'avatar_url', case p.kind when 'personal' then pr.avatar_url else p.avatar_url end,
    'verified', (public.profile_badge(p.id) ->> 'verified')::boolean,
    'rank', public.profile_badge(p.id) -> 'rank',
    'privacy', p.privacy
  )
  from public.site_profiles p
  left join public.profiles pr on pr.id = p.user_id and p.kind = 'personal'
  where p.id = p_id
$$;

-- One post as the app shows it, for the profile p_viewer. Does not check that the viewer may see it: the callers do.
create function public.post_card(p_viewer uuid, p_post uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p public.site_posts;
begin
  select * into p from public.site_posts where id = p_post;
  if not found then return null; end if;
  return jsonb_build_object(
    'id', p.id,
    'kind', p.kind,
    'caption', p.caption,
    'audience', p.audience,
    'comments_enabled', p.comments_enabled,
    'created_at', p.created_at,
    'expires_at', p.expires_at,
    'author', public.profile_mini(p.author),
    'media', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'position', m.position, 'type', m.media_type, 'path', m.storage_path, 'poster_path', m.poster_path,
        'width', m.width, 'height', m.height, 'duration_ms', m.duration_ms) order by m.position)
      from public.site_post_media m where m.post = p.id), '[]'::jsonb),
    'tags', coalesce((
      select jsonb_agg(t.tag order by t.ord)
      from (
        select row_number() over (order by x.id) as ord,
               case
                 when x.profile_id is not null then jsonb_build_object('kind', 'profile', 'id', x.profile_id, 'profile', public.profile_mini(x.profile_id))
                 when x.event_id is not null then jsonb_build_object('kind', 'event', 'id', x.event_id, 'name', e.title)
                 else jsonb_build_object('kind', 'venue', 'id', x.venue_id, 'name', v.name)
               end as tag
        from public.site_post_tags x
        left join public.site_events e on e.id = x.event_id and e.status = 'published'
        left join public.site_venues v on v.id = x.venue_id and v.status = 'published'
        where x.post = p.id
          and (
            (x.profile_id is not null and public.profile_visible(p_viewer, x.profile_id))
            or (x.event_id is not null and e.id is not null)
            or (x.venue_id is not null and v.id is not null)
          )
      ) t), '[]'::jsonb),
    'likes', (select count(*) from public.site_post_likes l join public.site_profiles s on s.id = l.profile and s.status = 'active' where l.post = p.id),
    'comments', (select count(*) from public.site_comments c join public.site_profiles s on s.id = c.author and s.status = 'active' where c.post = p.id and c.status = 'active'),
    'liked', p_viewer is not null and exists (select 1 from public.site_post_likes l where l.post = p.id and l.profile = p_viewer),
    'saved', p_viewer is not null and exists (select 1 from public.site_post_saves sv where sv.post = p.id and sv.profile = p_viewer),
    'is_mine', public.profile_is_mine(p.author)
  );
end;
$$;

-- The community rules: what version is current, and has the caller accepted it?
create function public.social_rules_version()
returns int
language sql
stable
security definer
set search_path = public
as $$ select coalesce((select max(r.version) from public.site_community_rules r), 1) $$;

create function public.social_require_rules()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.site_rules_acceptance a where a.user_id = auth.uid() and a.version >= public.social_rules_version()) then
    raise exception 'Read and accept the community rules first.';
  end if;
end;
$$;

-- Is this text free of every banned term?
create function public.social_text_ok(p_text text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1 from public.site_banned_terms t
    where lower(coalesce(p_text, '')) ~ ('(^|[^a-z0-9])' || t.term || '($|[^a-z0-9])')
  )
$$;

-- A number out of a json field that may hold anything.
create function public.social_json_int(p_value jsonb, p_key text)
returns int
language sql
immutable
set search_path = public
as $$
  select case when (p_value ->> p_key) ~ '^[0-9]{1,9}$' then (p_value ->> p_key)::int end
$$;

-- ---------------------------------------------------------------------------
-- 4. The community rules and the banned terms
-- ---------------------------------------------------------------------------
create function public.rules_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  return jsonb_build_object(
    'version', public.social_rules_version(),
    'accepted', exists (select 1 from public.site_rules_acceptance a where a.user_id = auth.uid() and a.version >= public.social_rules_version())
  );
end;
$$;

create function public.rules_accept(p_version int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_version is distinct from public.social_rules_version() then raise exception 'The community rules have changed. Read them again.'; end if;
  insert into public.site_rules_acceptance (user_id, version) values (auth.uid(), p_version)
  on conflict (user_id) do update set version = excluded.version, accepted_at = now();
  return public.rules_status();
end;
$$;

-- The rules as they stand: the version everyone must have accepted and the text (null until BottlesUp has published one). Anyone may read them, signed in or not.
create function public.rules_current()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'version', public.social_rules_version(),
    'body', (select r.body from public.site_community_rules r order by r.version desc limit 1)
  )
$$;

-- A BottlesUp admin publishes new rules. It becomes the next version, so everyone accepts again before they post, comment or send.
create function public.cms_publish_rules(p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_body text := btrim(coalesce(p_body, ''));
  v_version int;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;
  if char_length(v_body) < 20 or char_length(v_body) > 8000 then raise exception 'The rules need between 20 and 8000 characters.'; end if;
  v_version := public.social_rules_version() + 1;
  insert into public.site_community_rules (version, body, published_by) values (v_version, v_body, auth.uid());
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'rules_published', 'community_rules', v_version::text,
          jsonb_build_object('version', v_version, 'characters', char_length(v_body)));
  return public.rules_current();
end;
$$;

-- The edge function `suggest-caption` calls this AS the person, before it asks the model for anything: caption ideas must be switched on, the person must have accepted the
-- community rules, and at most 20 requests a day. One request is counted here; the function then calls the model. Answers how many are left today.
create function public.ai_caption_begin()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_used int;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not public.feature_enabled('social') or not public.feature_enabled('ai_captions') then raise exception 'Caption ideas are not open yet.'; end if;
  perform public.social_require_rules();
  select count(*) into v_used from public.site_ai_caption_uses u where u.user_id = auth.uid() and u.created_at > now() - interval '1 day';
  if v_used >= 20 then raise exception 'You have used all of today''s caption ideas. Try again tomorrow.'; end if;
  insert into public.site_ai_caption_uses (user_id) values (auth.uid());
  return jsonb_build_object('left', 19 - v_used);
end;
$$;

-- A BottlesUp admin adds or removes a banned term.
create function public.cms_set_banned_term(p_term text, p_banned boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_term text := lower(regexp_replace(btrim(coalesce(p_term, '')), '\s+', ' ', 'g'));
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;
  if v_term !~ '^[a-z0-9 ]{2,40}$' then raise exception 'A banned term is 2 to 40 letters, numbers or spaces.'; end if;
  if p_banned is null then raise exception 'Choose add or remove.'; end if;
  if p_banned then
    insert into public.site_banned_terms (term) values (v_term) on conflict do nothing;
  else
    delete from public.site_banned_terms where term = v_term;
  end if;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), case when p_banned then 'banned_term_added' else 'banned_term_removed' end, 'banned_term', v_term, '{}'::jsonb);
  return jsonb_build_object('terms', (select count(*) from public.site_banned_terms));
end;
$$;

create function public.cms_list_banned_terms()
returns table (term text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  return query select t.term from public.site_banned_terms t order by t.term;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Making, changing and removing a post
-- ---------------------------------------------------------------------------
-- Make a post, a reel or a story. p_media is a list of {path, type: 'image'|'video', width, height, duration_ms, poster_path}, every file already uploaded into
-- the posting profile's folder; p_tags a list of {kind: 'profile'|'event'|'venue', id}.
create function public.post_create(
  p_actor uuid,
  p_kind text,
  p_caption text,
  p_audience text,
  p_media jsonb,
  p_tags jsonb default '[]'::jsonb,
  p_comments_enabled boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_aud text := lower(btrim(coalesce(p_audience, '')));
  v_caption text := nullif(btrim(coalesce(p_caption, '')), '');
  v_post uuid;
  v_item jsonb;
  v_pos int := 0;
  v_type text;
  v_path text;
  v_poster text;
  v_size bigint;
  v_mime text;
  v_dur int;
  v_images int := 0;
  v_videos int := 0;
  v_tag jsonb;
  v_tag_kind text;
  v_tag_id uuid;
  v_tag_text text;
  v_seen text[] := '{}';
begin
  perform public.profile_require_permission(p_actor, 'content');
  perform public.social_require_rules();
  if v_kind not in ('post', 'reel', 'story') then raise exception 'Choose post, reel or story.'; end if;
  if not public.feature_enabled('social') then raise exception 'Posting is not open yet.'; end if;
  if v_kind = 'reel' and not public.feature_enabled('reels') then raise exception 'Reels are not open yet.'; end if;
  if v_kind = 'story' and not public.feature_enabled('stories') then raise exception 'Stories are not open yet.'; end if;
  if v_aud not in ('public', 'followers', 'members') then raise exception 'Choose who can see this.'; end if;
  if v_aud = 'members' and not public.feature_enabled('members_only') then raise exception 'Members Only is not open yet.'; end if;
  if p_comments_enabled is null then raise exception 'Choose whether people can comment.'; end if;
  if v_caption is not null and char_length(v_caption) > 2200 then raise exception 'The caption can be 2200 characters at most.'; end if;
  if not public.social_text_ok(v_caption) then raise exception 'That text goes against our community rules.'; end if;
  if (select count(*) from public.site_posts x where x.author = p_actor and x.created_at > now() - interval '1 hour') >= 20 then
    raise exception 'You are posting too quickly. Try again later.';
  end if;
  if p_media is null or jsonb_typeof(p_media) <> 'array' or jsonb_array_length(p_media) = 0 then raise exception 'Add a photo or a video.'; end if;
  if jsonb_array_length(p_media) > 10 then raise exception 'You can add up to 10 photos.'; end if;

  insert into public.site_posts (author, kind, caption, audience, comments_enabled, expires_at)
  values (p_actor, v_kind, v_caption, v_aud, p_comments_enabled, case when v_kind = 'story' then now() + interval '24 hours' end)
  returning id into v_post;

  for v_item in select e.value from jsonb_array_elements(p_media) e loop
    if jsonb_typeof(v_item) <> 'object' then raise exception 'Something is wrong with that photo or video.'; end if;
    v_type := v_item ->> 'type';
    v_path := v_item ->> 'path';
    v_poster := nullif(v_item ->> 'poster_path', '');
    if v_type not in ('image', 'video') or v_path is null then raise exception 'Something is wrong with that photo or video.'; end if;
    if public.social_media_profile(v_path) is distinct from p_actor then raise exception 'Something is wrong with that photo or video.'; end if;

    select (o.metadata ->> 'size')::bigint, o.metadata ->> 'mimetype' into v_size, v_mime
    from storage.objects o where o.bucket_id = 'social-media' and o.name = v_path;
    if not found then raise exception 'That photo or video did not finish uploading. Try again.'; end if;
    if v_type = 'image' then
      if v_mime is null or v_mime not like 'image/%' then raise exception 'Something is wrong with that photo.'; end if;
      if v_size is null or v_size > 10485760 then raise exception 'A photo can be 10 MB at most.'; end if;
      v_images := v_images + 1;
      v_dur := null;
      v_poster := null;
    else
      if v_mime is null or v_mime not like 'video/%' then raise exception 'Something is wrong with that video.'; end if;
      if v_size is null or v_size > 104857600 then raise exception 'A video can be 100 MB at most.'; end if;
      v_dur := public.social_json_int(v_item, 'duration_ms');
      if v_dur is null or v_dur < 1 or v_dur > 60000 then raise exception 'A video can be up to 60 seconds.'; end if;
      v_videos := v_videos + 1;
      if v_poster is not null then
        if public.social_media_profile(v_poster) is distinct from p_actor then raise exception 'Something is wrong with that video.'; end if;
        if not exists (
          select 1 from storage.objects o
          where o.bucket_id = 'social-media' and o.name = v_poster and o.metadata ->> 'mimetype' like 'image/%' and (o.metadata ->> 'size')::bigint <= 10485760
        ) then
          raise exception 'Something is wrong with that video.';
        end if;
      end if;
    end if;

    begin
      insert into public.site_post_media (post, position, media_type, storage_path, poster_path, width, height, duration_ms, bytes)
      values (v_post, v_pos, v_type, v_path, v_poster, public.social_json_int(v_item, 'width'), public.social_json_int(v_item, 'height'), v_dur, v_size);
    exception when unique_violation then
      raise exception 'That photo or video is already in a post.';
    when check_violation then
      raise exception 'Something is wrong with that photo or video.';
    end;
    v_pos := v_pos + 1;
  end loop;

  if v_kind = 'post' and (v_videos > 0 or v_images < 1) then raise exception 'A post is 1 to 10 photos. Use a reel for a video.'; end if;
  if v_kind = 'reel' and (v_videos <> 1 or v_images <> 0) then raise exception 'A reel is one video.'; end if;
  if v_kind = 'story' and v_images + v_videos <> 1 then raise exception 'A story is one photo or one video.'; end if;

  if p_tags is not null and jsonb_typeof(p_tags) <> 'array' then raise exception 'Something is wrong with the tags.'; end if;
  if jsonb_array_length(coalesce(p_tags, '[]'::jsonb)) > 10 then raise exception 'You can tag up to 10.'; end if;
  for v_tag in select e.value from jsonb_array_elements(coalesce(p_tags, '[]'::jsonb)) e loop
    if jsonb_typeof(v_tag) <> 'object' then raise exception 'Something is wrong with the tags.'; end if;
    v_tag_kind := v_tag ->> 'kind';
    v_tag_text := v_tag ->> 'id';
    if v_tag_kind not in ('profile', 'event', 'venue') or v_tag_text is null
       or v_tag_text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'Something is wrong with the tags.';
    end if;
    v_tag_id := v_tag_text::uuid;
    if (v_tag_kind || ':' || v_tag_text) = any (v_seen) then raise exception 'You tagged the same one twice.'; end if;
    v_seen := v_seen || (v_tag_kind || ':' || v_tag_text);
    if v_tag_kind = 'profile' then
      if v_tag_id = p_actor or public.profile_is_mine(v_tag_id) or not public.profile_visible(p_actor, v_tag_id) then raise exception 'You cannot tag that profile.'; end if;
      insert into public.site_post_tags (post, profile_id) values (v_post, v_tag_id);
    elsif v_tag_kind = 'event' then
      if not exists (select 1 from public.site_events e where e.id = v_tag_id and e.status = 'published') then raise exception 'You cannot tag that event.'; end if;
      insert into public.site_post_tags (post, event_id) values (v_post, v_tag_id);
    else
      if not exists (select 1 from public.site_venues v where v.id = v_tag_id and v.status = 'published') then raise exception 'You cannot tag that venue.'; end if;
      insert into public.site_post_tags (post, venue_id) values (v_post, v_tag_id);
    end if;
  end loop;

  return public.post_card(p_actor, v_post);
end;
$$;

-- Change the words, who can see it, or whether people can comment. The photos and tags stay.
create function public.post_edit(p_actor uuid, p_post uuid, p_caption text, p_audience text, p_comments_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
  v_aud text := lower(btrim(coalesce(p_audience, '')));
  v_caption text := nullif(btrim(coalesce(p_caption, '')), '');
begin
  perform public.profile_require_actor(p_actor);
  select p.author into v_author from public.site_posts p where p.id = p_post and p.status = 'active';
  if v_author is null or not public.profile_can_act_as(v_author) then raise exception 'You can only change your own posts.'; end if;
  if v_aud not in ('public', 'followers', 'members') then raise exception 'Choose who can see this.'; end if;
  if v_aud = 'members' and not public.feature_enabled('members_only') then raise exception 'Members Only is not open yet.'; end if;
  if p_comments_enabled is null then raise exception 'Choose whether people can comment.'; end if;
  if v_caption is not null and char_length(v_caption) > 2200 then raise exception 'The caption can be 2200 characters at most.'; end if;
  if not public.social_text_ok(v_caption) then raise exception 'That text goes against our community rules.'; end if;
  update public.site_posts set caption = v_caption, audience = v_aud, comments_enabled = p_comments_enabled where id = p_post;
  return public.post_card(p_actor, p_post);
end;
$$;

-- Delete a post. Answers the files that belonged to it, for the app to remove from storage.
create function public.post_delete(p_actor uuid, p_post uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
  v_paths jsonb;
begin
  perform public.profile_require_actor(p_actor);
  select p.author into v_author from public.site_posts p where p.id = p_post;
  if v_author is null or not public.profile_can_act_as(v_author) then raise exception 'You can only delete your own posts.'; end if;
  select coalesce(jsonb_agg(x.path), '[]'::jsonb) into v_paths
  from (
    select m.storage_path as path from public.site_post_media m where m.post = p_post
    union all
    select m.poster_path from public.site_post_media m where m.post = p_post and m.poster_path is not null
  ) x;
  delete from public.site_posts where id = p_post;
  return v_paths;
end;
$$;

-- One post, if the profile may see it.
create function public.post_get(p_actor uuid, p_post uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if p_post is null or not public.post_visible(p_actor, p_post) then raise exception 'This post isn''t available.'; end if;
  return public.post_card(p_actor, p_post);
end;
$$;

-- A tagged profile takes its own tag off a post.
create function public.post_untag(p_actor uuid, p_post uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  delete from public.site_post_tags where post = p_post and profile_id = p_actor;
  return jsonb_build_object('untagged', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Reading: a profile's posts, the home feed, reels, stories
-- ---------------------------------------------------------------------------
-- A profile's posts and reels (not stories) that p_actor may see, newest first, with how many there are. p_kind 'post' or 'reel' narrows it.
create function public.profile_posts(p_actor uuid, p_profile uuid, p_kind text default null, p_limit int default 30, p_before timestamptz default null, p_before_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_limit int := least(greatest(coalesce(p_limit, 30), 1), 50);
begin
  perform public.profile_require_actor(p_actor);
  if v_kind not in ('', 'post', 'reel') then raise exception 'Choose posts or reels.'; end if;
  if not (public.profile_visible(p_actor, p_profile) or public.profile_is_mine(p_profile)) then raise exception 'This profile isn''t available.'; end if;
  if not (public.profile_content_visible(p_actor, p_profile) or public.profile_is_mine(p_profile)) then raise exception 'Follow this profile to see its posts.'; end if;
  return jsonb_build_object(
    'total', (select count(*) from public.site_posts p
              where p.author = p_profile and p.kind in ('post', 'reel') and p.status = 'active' and (v_kind = '' or p.kind = v_kind) and public.post_visible(p_actor, p.id)),
    'items', coalesce((
      select jsonb_agg(public.post_card(p_actor, r.id) order by r.created_at desc, r.id desc)
      from (
        select p.id, p.created_at
        from public.site_posts p
        where p.author = p_profile and p.kind in ('post', 'reel') and p.status = 'active' and (v_kind = '' or p.kind = v_kind)
          and (p_before is null or (p.created_at, p.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
          and public.post_visible(p_actor, p.id)
        order by p.created_at desc, p.id desc
        limit v_limit
      ) r
    ), '[]'::jsonb)
  );
end;
$$;

-- The home feed: posts and reels from the profiles p_actor follows, and its own, newest first. Page with the created_at and id of the last one seen.
create function public.feed_home(p_actor uuid, p_limit int default 20, p_before timestamptz default null, p_before_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 40);
begin
  perform public.profile_require_actor(p_actor);
  return coalesce((
    select jsonb_agg(public.post_card(p_actor, r.id) order by r.created_at desc, r.id desc)
    from (
      select p.id, p.created_at
      from public.site_posts p
      where p.kind in ('post', 'reel') and p.status = 'active'
        and (p.author = p_actor or p.author in (select f.followed from public.site_follows f where f.follower = p_actor and f.status = 'active'))
        and (p_before is null or (p.created_at, p.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
        and public.post_visible(p_actor, p.id)
      order by p.created_at desc, p.id desc
      limit v_limit
    ) r
  ), '[]'::jsonb);
end;
$$;

-- A few popular public posts from profiles p_actor does not follow, from the last two weeks: more likes and comments first. No machine ranking beyond that.
create function public.feed_suggested(p_actor uuid, p_limit int default 10)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 10), 1), 20);
begin
  perform public.profile_require_actor(p_actor);
  return coalesce((
    select jsonb_agg(public.post_card(p_actor, r.id) order by r.score desc, r.created_at desc, r.id desc)
    from (
      select p.id, p.created_at,
             (select count(*) from public.site_post_likes l where l.post = p.id)
             + 2 * (select count(*) from public.site_comments c where c.post = p.id and c.status = 'active') as score
      from public.site_posts p
      where p.kind in ('post', 'reel') and p.status = 'active' and p.audience = 'public'
        and p.created_at > now() - interval '14 days'
        and p.author <> p_actor
        and not public.profile_is_mine(p.author)
        and p.author not in (select f.followed from public.site_follows f where f.follower = p_actor)
        and public.post_visible(p_actor, p.id)
      order by score desc, p.created_at desc, p.id desc
      limit v_limit
    ) r
  ), '[]'::jsonb);
end;
$$;

-- Reels from anyone p_actor may see, newest first, for the reels viewer.
create function public.feed_reels(p_actor uuid, p_limit int default 10, p_before timestamptz default null, p_before_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 10), 1), 20);
begin
  perform public.profile_require_actor(p_actor);
  return coalesce((
    select jsonb_agg(public.post_card(p_actor, r.id) order by r.created_at desc, r.id desc)
    from (
      select p.id, p.created_at
      from public.site_posts p
      where p.kind = 'reel' and p.status = 'active'
        and (p_before is null or (p.created_at, p.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
        and public.post_visible(p_actor, p.id)
      order by p.created_at desc, p.id desc
      limit v_limit
    ) r
  ), '[]'::jsonb);
end;
$$;

-- The row of stories: p_actor's own and those of the profiles it follows, with a story still up that it may see. Own first, then unseen, then newest.
-- members_only is true when any of them is for the author's Members Only list (the app draws the orange ring).
create function public.story_rail(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'profile', public.profile_mini(g.author), 'latest_at', g.latest, 'unseen', g.unseen, 'members_only', g.members_only, 'count', g.n, 'is_mine', g.author = p_actor)
           order by (g.author = p_actor) desc, g.unseen desc, g.latest desc, g.author)
    from (
      select s.author, max(s.created_at) as latest, count(*) as n,
             bool_or(s.audience = 'members') as members_only,
             bool_or(s.author <> p_actor and not exists (select 1 from public.site_story_views v where v.story = s.id and v.viewer = p_actor)) as unseen
      from public.site_posts s
      where s.kind = 'story' and s.status = 'active' and s.expires_at > now()
        and (s.author = p_actor or s.author in (select f.followed from public.site_follows f where f.follower = p_actor and f.status = 'active'))
        and public.post_visible(p_actor, s.id)
      group by s.author
      order by max(s.created_at) desc
      limit 60
    ) g
  ), '[]'::jsonb);
end;
$$;

-- One profile's stories that are up and that p_actor may see, oldest first (the order they are watched in).
create function public.stories_of(p_actor uuid, p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if not (public.profile_visible(p_actor, p_profile) or public.profile_is_mine(p_profile)) then raise exception 'This profile isn''t available.'; end if;
  return coalesce((
    select jsonb_agg(public.post_card(p_actor, r.id) || jsonb_build_object('seen', exists (select 1 from public.site_story_views v where v.story = r.id and v.viewer = p_actor))
                     order by r.created_at, r.id)
    from (
      select s.id, s.created_at from public.site_posts s
      where s.author = p_profile and s.kind = 'story' and s.status = 'active' and s.expires_at > now() and public.post_visible(p_actor, s.id)
      order by s.created_at, s.id
      limit 50
    ) r
  ), '[]'::jsonb);
end;
$$;

-- p_actor has watched a story. Nobody is told; this only turns the ring grey for them.
create function public.story_seen(p_actor uuid, p_story uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if not exists (select 1 from public.site_posts s where s.id = p_story and s.kind = 'story') or not public.post_visible(p_actor, p_story) then
    raise exception 'This story isn''t available.';
  end if;
  insert into public.site_story_views (story, viewer) values (p_story, p_actor) on conflict do nothing;
  return jsonb_build_object('seen', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Likes, saves and comments
-- ---------------------------------------------------------------------------
create function public.post_like(p_actor uuid, p_post uuid, p_liked boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if p_liked is null then raise exception 'Choose like or unlike.'; end if;
  if p_liked then
    if not public.feature_enabled('social') then raise exception 'Posting is not open yet.'; end if;
    if p_post is null or not public.post_visible(p_actor, p_post) then raise exception 'This post isn''t available.'; end if;
    insert into public.site_post_likes (post, profile) values (p_post, p_actor) on conflict do nothing;
  else
    delete from public.site_post_likes where post = p_post and profile = p_actor;
  end if;
  return jsonb_build_object(
    'liked', p_liked,
    'likes', (select count(*) from public.site_post_likes l join public.site_profiles s on s.id = l.profile and s.status = 'active' where l.post = p_post)
  );
end;
$$;

create function public.post_save(p_actor uuid, p_post uuid, p_saved boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if p_saved is null then raise exception 'Choose save or unsave.'; end if;
  if p_saved then
    if not public.feature_enabled('social') then raise exception 'Posting is not open yet.'; end if;
    if p_post is null or not public.post_visible(p_actor, p_post) then raise exception 'This post isn''t available.'; end if;
    insert into public.site_post_saves (post, profile) values (p_post, p_actor) on conflict do nothing;
  else
    delete from public.site_post_saves where post = p_post and profile = p_actor;
  end if;
  return jsonb_build_object('saved', p_saved);
end;
$$;

-- What p_actor saved, newest save first, that it can still see. p_before is the time of the last save seen.
create function public.saved_posts(p_actor uuid, p_limit int default 30, p_before timestamptz default null)
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
    select jsonb_agg(public.post_card(p_actor, r.post) || jsonb_build_object('saved_at', r.created_at) order by r.created_at desc, r.post desc)
    from (
      select sv.post, sv.created_at
      from public.site_post_saves sv
      where sv.profile = p_actor and (p_before is null or sv.created_at < p_before) and public.post_visible(p_actor, sv.post)
      order by sv.created_at desc, sv.post desc
      limit v_limit
    ) r
  ), '[]'::jsonb);
end;
$$;

-- One comment as the app shows it.
create function public.comment_card(p_viewer uuid, p_comment uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', c.id,
    'post', c.post,
    'reply_to', c.reply_to,
    'body', c.body,
    'created_at', c.created_at,
    'author', public.profile_mini(c.author),
    'replies', (select count(*) from public.site_comments r join public.site_profiles s on s.id = r.author and s.status = 'active'
                where r.reply_to = c.id and r.status = 'active' and not public.profile_blocked_between(p_viewer, r.author)),
    'is_mine', public.profile_is_mine(c.author),
    'can_delete', public.profile_is_mine(c.author) or public.profile_is_mine(p.author)
  )
  from public.site_comments c
  join public.site_posts p on p.id = c.post
  where c.id = p_comment
$$;

-- Add a comment (or a reply to a top-level comment) to a post p_actor can see.
create function public.comment_add(p_actor uuid, p_post uuid, p_body text, p_reply_to uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_body text := btrim(coalesce(p_body, ''));
  v_comments_on boolean;
  v_id uuid;
begin
  perform public.profile_require_actor(p_actor);
  perform public.social_require_rules();
  if not public.feature_enabled('social') then raise exception 'Posting is not open yet.'; end if;
  if p_post is null or not public.post_visible(p_actor, p_post) then raise exception 'This post isn''t available.'; end if;
  select s.comments_enabled into v_comments_on from public.site_posts s where s.id = p_post;
  if not v_comments_on then raise exception 'Comments are turned off for this post.'; end if;
  if char_length(v_body) < 1 then raise exception 'Write something first.'; end if;
  if char_length(v_body) > 1000 then raise exception 'A comment can be 1000 characters at most.'; end if;
  if not public.social_text_ok(v_body) then raise exception 'That text goes against our community rules.'; end if;
  if p_reply_to is not null and not exists (select 1 from public.site_comments c where c.id = p_reply_to and c.post = p_post and c.reply_to is null and c.status = 'active') then
    raise exception 'That comment is not there any more.';
  end if;
  if (select count(*) from public.site_comments c where c.author = p_actor and c.created_at > now() - interval '1 minute') >= 20 then
    raise exception 'You are commenting too quickly. Try again in a moment.';
  end if;
  insert into public.site_comments (post, author, reply_to, body) values (p_post, p_actor, p_reply_to, v_body) returning id into v_id;
  return public.comment_card(p_actor, v_id);
end;
$$;

-- A page of comments on a post, oldest first: the top-level ones, or the replies to p_parent. p_after is the created_at of the last one seen.
create function public.comment_list(p_actor uuid, p_post uuid, p_parent uuid default null, p_limit int default 30, p_after timestamptz default null)
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
  if p_post is null or not public.post_visible(p_actor, p_post) then raise exception 'This post isn''t available.'; end if;
  return coalesce((
    select jsonb_agg(public.comment_card(p_actor, r.id) order by r.created_at, r.id)
    from (
      select c.id, c.created_at
      from public.site_comments c
      join public.site_profiles s on s.id = c.author and s.status = 'active'
      where c.post = p_post and c.status = 'active'
        and ((p_parent is null and c.reply_to is null) or c.reply_to = p_parent)
        and (p_after is null or c.created_at > p_after)
        and not public.profile_blocked_between(p_actor, c.author)
      order by c.created_at, c.id
      limit v_limit
    ) r
  ), '[]'::jsonb);
end;
$$;

-- Delete a comment: its writer, or whoever may act as the post's author.
create function public.comment_delete(p_actor uuid, p_comment uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
  v_post_author uuid;
begin
  perform public.profile_require_actor(p_actor);
  select c.author, p.author into v_author, v_post_author
  from public.site_comments c join public.site_posts p on p.id = c.post where c.id = p_comment;
  if v_author is null or not (public.profile_can_act_as(v_author) or public.profile_can_act_as(v_post_author)) then
    raise exception 'You can only delete your own comments, or comments on your own posts.';
  end if;
  delete from public.site_comments where id = p_comment;
  return jsonb_build_object('deleted', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Members Only
-- ---------------------------------------------------------------------------
-- The people on p_actor's Members Only list, newest first. still_following is false for someone who has since unfollowed: they are on the list but see nothing.
create function public.members_list(p_actor uuid, p_limit int default 100, p_before timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 200);
begin
  perform public.profile_require_actor(p_actor);
  return coalesce((
    select jsonb_agg(public.profile_mini(r.member) || jsonb_build_object(
             'added_at', r.created_at,
             'still_following', exists (select 1 from public.site_follows f where f.follower = r.member and f.followed = p_actor and f.status = 'active'))
           order by r.created_at desc, r.member)
    from (
      select l.member, l.created_at
      from public.site_member_lists l
      join public.site_profiles s on s.id = l.member and s.status = 'active'
      where l.owner = p_actor and (p_before is null or l.created_at < p_before)
      order by l.created_at desc, l.member
      limit v_limit
    ) r
  ), '[]'::jsonb);
end;
$$;

-- Put someone on the list (they must follow p_actor already) or take them off.
create function public.members_set(p_actor uuid, p_member uuid, p_in boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if p_member is null or p_in is null then raise exception 'Say which profile.'; end if;
  if p_in then
    if not public.feature_enabled('members_only') then raise exception 'Members Only is not open yet.'; end if;
    if p_member = p_actor or public.profile_is_mine(p_member) then raise exception 'You cannot add your own profile.'; end if;
    if not public.profile_visible(p_actor, p_member) then raise exception 'This profile isn''t available.'; end if;
    if not exists (select 1 from public.site_follows f where f.follower = p_member and f.followed = p_actor and f.status = 'active') then
      raise exception 'They need to follow you first.';
    end if;
    if (select count(*) from public.site_member_lists l where l.owner = p_actor) >= 2000 and not exists (select 1 from public.site_member_lists l where l.owner = p_actor and l.member = p_member) then
      raise exception 'Your Members Only list is full (2000 people).';
    end if;
    insert into public.site_member_lists (owner, member) values (p_actor, p_member) on conflict do nothing;
  else
    delete from public.site_member_lists where owner = p_actor and member = p_member;
  end if;
  return jsonb_build_object('members', (select count(*) from public.site_member_lists l where l.owner = p_actor), 'is_member', p_in);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Clean-up
-- ---------------------------------------------------------------------------
-- Files in the bucket that no post uses and that are more than a day old (an upload whose post was never made). For a scheduled job running as the service
-- role, which removes them through the storage API (deleting the row alone would leave the file).
create function public.social_media_orphans()
returns table (name text)
language sql
stable
security definer
set search_path = public
as $$
  select o.name
  from storage.objects o
  where o.bucket_id = 'social-media'
    and o.created_at < now() - interval '1 day'
    and not exists (select 1 from public.site_post_media m where m.storage_path = o.name or m.poster_path = o.name)
$$;

-- ---------------------------------------------------------------------------
-- 10. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.social_media_profile(text), public.social_media_can_add(text), public.social_media_visible(text),
  public.post_visible(uuid, uuid), public.profile_mini(uuid), public.post_card(uuid, uuid), public.social_rules_version(), public.social_require_rules(),
  public.social_text_ok(text), public.social_json_int(jsonb, text), public.comment_card(uuid, uuid),
  public.rules_status(), public.rules_accept(int), public.rules_current(), public.cms_publish_rules(text), public.cms_set_banned_term(text, boolean), public.cms_list_banned_terms(), public.ai_caption_begin(),
  public.post_create(uuid, text, text, text, jsonb, jsonb, boolean), public.post_edit(uuid, uuid, text, text, boolean), public.post_delete(uuid, uuid),
  public.post_get(uuid, uuid), public.post_untag(uuid, uuid),
  public.profile_posts(uuid, uuid, text, int, timestamptz, uuid), public.feed_home(uuid, int, timestamptz, uuid), public.feed_suggested(uuid, int),
  public.feed_reels(uuid, int, timestamptz, uuid), public.story_rail(uuid), public.stories_of(uuid, uuid), public.story_seen(uuid, uuid),
  public.post_like(uuid, uuid, boolean), public.post_save(uuid, uuid, boolean), public.saved_posts(uuid, int, timestamptz),
  public.comment_add(uuid, uuid, text, uuid), public.comment_list(uuid, uuid, uuid, int, timestamptz), public.comment_delete(uuid, uuid),
  public.members_list(uuid, int, timestamptz), public.members_set(uuid, uuid, boolean), public.social_media_orphans()
from public, anon, authenticated;

-- The storage policies run as the person asking, so these two must be callable by them.
grant execute on function public.social_media_can_add(text), public.social_media_visible(text) to authenticated;

grant execute on function
  public.rules_status(), public.rules_accept(int), public.cms_publish_rules(text), public.cms_set_banned_term(text, boolean), public.cms_list_banned_terms(), public.ai_caption_begin(),
  public.post_create(uuid, text, text, text, jsonb, jsonb, boolean), public.post_edit(uuid, uuid, text, text, boolean), public.post_delete(uuid, uuid),
  public.post_get(uuid, uuid), public.post_untag(uuid, uuid),
  public.profile_posts(uuid, uuid, text, int, timestamptz, uuid), public.feed_home(uuid, int, timestamptz, uuid), public.feed_suggested(uuid, int),
  public.feed_reels(uuid, int, timestamptz, uuid), public.story_rail(uuid), public.stories_of(uuid, uuid), public.story_seen(uuid, uuid),
  public.post_like(uuid, uuid, boolean), public.post_save(uuid, uuid, boolean), public.saved_posts(uuid, int, timestamptz),
  public.comment_add(uuid, uuid, text, uuid), public.comment_list(uuid, uuid, uuid, int, timestamptz), public.comment_delete(uuid, uuid),
  public.members_list(uuid, int, timestamptz), public.members_set(uuid, uuid, boolean)
to authenticated, service_role;
grant execute on function public.social_media_orphans() to service_role;
-- The rules are public: a guest can read them before signing up.
grant execute on function public.rules_current() to anon, authenticated, service_role;
