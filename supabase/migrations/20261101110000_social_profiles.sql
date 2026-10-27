-- Social profiles (customer app completion plan, M1; client plan pages 3 and 4): one login can hold a personal profile and several business
-- profiles (a venue, an event group, a DJ, a photographer...), follow other profiles, ask to follow a private one, and block.
--
--   * A PERSONAL profile is one row per login. Its name, username, bio, city, picture and links stay where they already are (profiles, saved by
--     save_my_profile); this table adds what social needs: public or private, interests. A BUSINESS profile is its own row: a venue's (owned by the
--     venue's business, edited by its owner or that venue's manager), an event group's (optionally tied to an organizer business), or a professional's
--     (owned by one login). Business profiles are always public.
--   * USERNAMES are one list. The handle of a personal profile is profiles.username and of a business profile its own handle; site_handles keeps both in
--     ONE table with a primary key, so the two kinds can never take the same name, even at the same moment. Business handles do not change.
--   * WHO MAY ACT as a profile is worked out from the caller's CURRENT state on every call (the login, or the business role / venue manager role), not
--     from a stored list. Every function that does something takes the profile it is done AS (p_actor) and checks it. Revoke a manager and they are out
--     at once.
--   * PRIVATE profiles (personal only): anyone may see the header and the counts; the followers, following and (later) posts only the profile's owner
--     and approved followers see. A follow of a private profile waits as a request until the owner accepts. Turning a private profile public accepts
--     the waiting requests. Turning a public profile private keeps the people who follow already.
--   * BLOCKING hides two PEOPLE from each other both ways (search, profile page, lists), removes the follows between them and refuses a new one. The
--     refusal says "This profile isn't available." and so never tells someone they were blocked. A person is the login behind a personal profile and the
--     professional profiles it owns (a DJ's, a photographer's): blocking any of them blocks all of them, and unblocking any lifts it. A venue's or an event
--     group's profile is run by a team, so it is blocked, and blocks, on its own.
--   * Following is slowed: at most 200 new follows an hour from one profile.
--   * Everything that CREATES or CHANGES something social (a profile, a follow) refuses with "Profiles are not open yet." until BottlesUp switches the `social`
--     feature on (20261101100000), so a dark launch is dark on the server too, not only in the app. Reading, unfollowing and blocking always work.
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.site_profiles (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('personal', 'business')),
  -- Personal: the person. Business without a venue business behind it: the one login that owns it.
  user_id uuid references auth.users (id) on delete cascade,
  -- Business tied to a venue business (a venue's profile, or an organizer's event group).
  org_id uuid references public.site_organizations (id) on delete cascade,
  venue_id uuid references public.site_venues (id) on delete cascade,
  -- Business only; a personal profile's handle is profiles.username.
  handle text check (handle is null or handle ~ '^[a-z0-9._]{3,30}$'),
  display_name text check (display_name is null or char_length(btrim(display_name)) between 1 and 100),
  category text check (category in ('venue', 'event_group', 'dj', 'mc', 'artist', 'instrumentalist', 'photographer', 'videographer',
                                    'influencer', 'promoter', 'other')),
  bio text check (bio is null or char_length(bio) <= 280),
  city text check (city is null or char_length(city) <= 80),
  avatar_url text check (avatar_url is null or (avatar_url ~ '^https://' and char_length(avatar_url) <= 500)),
  cover_url text check (cover_url is null or (cover_url ~ '^https://' and char_length(cover_url) <= 500)),
  social_links jsonb not null default '{}'::jsonb check (jsonb_typeof(social_links) = 'object'),
  privacy text not null default 'public' check (privacy in ('public', 'private')),
  interests text[] not null default '{}' check (cardinality(interests) <= 10),
  status text not null default 'active' check (status in ('active', 'suspended')),
  -- The moment it was written, so a person's profiles list in the order they were made.
  created_at timestamptz not null default clock_timestamp(),
  constraint site_profiles_shape check (
    (kind = 'personal' and user_id is not null and org_id is null and venue_id is null
       and handle is null and display_name is null and category is null)
    or
    (kind = 'business' and handle is not null and display_name is not null and category is not null and privacy = 'public'
       and ((org_id is not null and user_id is null) or (org_id is null and user_id is not null and venue_id is null)))
  ),
  constraint site_profiles_venue_category check (kind = 'personal' or ((category = 'venue') = (venue_id is not null)))
);
create unique index site_profiles_one_personal on public.site_profiles (user_id) where kind = 'personal';
create unique index site_profiles_one_per_venue on public.site_profiles (venue_id) where venue_id is not null;
create unique index site_profiles_one_per_org_group on public.site_profiles (org_id) where org_id is not null and venue_id is null;
create index site_profiles_owner_idx on public.site_profiles (user_id) where user_id is not null;
create index site_profiles_org_idx on public.site_profiles (org_id) where org_id is not null;
create index site_profiles_handle_prefix on public.site_profiles (handle text_pattern_ops) where handle is not null;
create index site_profiles_name_prefix on public.site_profiles (lower(display_name) text_pattern_ops) where display_name is not null;

-- Search by the start of a name or username on the person's own record.
create index profiles_username_prefix_idx on public.profiles (username text_pattern_ops) where username is not null;
create index profiles_name_prefix_idx on public.profiles (lower(name) text_pattern_ops) where name is not null;

-- One list of usernames for both kinds.
create table public.site_handles (
  handle text primary key check (handle ~ '^[a-z0-9._]{3,30}$'),
  profile_id uuid unique references public.profiles (id) on delete cascade,
  business_id uuid unique references public.site_profiles (id) on delete cascade,
  constraint site_handles_one_owner check ((profile_id is null) <> (business_id is null))
);

create table public.site_follows (
  follower uuid not null references public.site_profiles (id) on delete cascade,
  followed uuid not null references public.site_profiles (id) on delete cascade,
  status text not null default 'active' check (status in ('active', 'pending')),
  -- The moment it was written, so a page of followers ordered by it has no ties.
  created_at timestamptz not null default clock_timestamp(),
  primary key (follower, followed),
  check (follower <> followed)
);
create index site_follows_followed_idx on public.site_follows (followed, status, created_at desc);
create index site_follows_follower_idx on public.site_follows (follower, status, created_at desc);

-- A block holds between PEOPLE, so switching to another of their profiles does not get round it. blocker_key / blocked_key say who each side is: the login behind a personal
-- or professional profile, or the profile itself for a venue's or an event group's (those are run by a team, not one person). See profile_key().
create table public.site_blocks (
  blocker uuid not null references public.site_profiles (id) on delete cascade,
  blocked uuid not null references public.site_profiles (id) on delete cascade,
  blocker_key uuid not null,
  blocked_key uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (blocker, blocked),
  check (blocker <> blocked),
  check (blocker_key <> blocked_key)
);
create index site_blocks_blocked_idx on public.site_blocks (blocked);
create index site_blocks_keys_idx on public.site_blocks (blocker_key, blocked_key);
create index site_blocks_blocked_key_idx on public.site_blocks (blocked_key);

alter table public.site_profiles enable row level security;
alter table public.site_handles enable row level security;
alter table public.site_follows enable row level security;
alter table public.site_blocks enable row level security;
revoke all on table public.site_profiles, public.site_handles, public.site_follows, public.site_blocks from public, anon, authenticated;

-- Every username already in use goes on the one list (the profiles table keeps them unique, so nothing can clash here), and from now on the
-- list follows profiles.username.
insert into public.site_handles (handle, profile_id) select p.username, p.id from public.profiles p where p.username is not null;

create function public.site_handles_follow_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.username is null then
    delete from public.site_handles where profile_id = new.id;
  else
    -- A business profile that already has the name makes this a unique violation, which save_my_profile reports as "username is not available".
    insert into public.site_handles (handle, profile_id) values (new.username, new.id)
    on conflict (profile_id) do update set handle = excluded.handle;
  end if;
  return new;
end;
$$;
create trigger site_handles_follow_profile
after insert or update of username on public.profiles
for each row execute function public.site_handles_follow_profile();

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
-- Names nobody may take: staff-sounding, brand and the app's own screens.
create function public.handle_reserved(p_handle text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_handle in (
    'admin', 'administrator', 'support', 'help', 'staff', 'bottlesup', 'bottles.up', 'bottles_up', 'bottlesupapp', 'official', 'root', 'system',
    'moderator', 'security', 'safety', 'team', 'press', 'billing', 'payments', 'payouts', 'null', 'undefined', 'api', 'www', 'explore', 'create',
    'inbox', 'home', 'settings', 'privacy', 'terms', 'venues', 'events', 'tickets', 'tables', 'jobs', 'awards', 'verified', 'about', 'contact', 'login',
    'logout', 'signup', 'search'
  )
$$;

-- Is the caller one of the people who may act as this profile (ignoring whether it is suspended)?
create function public.profile_is_mine(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.site_profiles p
    where p.id = p_profile
      and (
        p.user_id = auth.uid()
        or (p.org_id is not null and (
              public.is_org_member(p.org_id, array['owner', 'organizer'])
              or (p.venue_id is not null and public.can_access_venue(p.venue_id, array['manager']))
        ))
      )
  )
$$;

-- Every profile the caller may act as (suspended ones included), found through the indexes instead of by asking about every profile. Must say the same as profile_is_mine:
-- a test compares the two.
create function public.profile_my_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.id from public.site_profiles p where auth.uid() is not null and p.user_id = auth.uid()
  union
  select p.id
  from public.active_memberships() m
  join public.site_profiles p on p.org_id = m.org_id
  where m.role in ('owner', 'organizer') or (m.role = 'manager' and p.venue_id is not null and m.venue_id = p.venue_id)
$$;

-- ...and is that profile in good standing?
create function public.profile_can_act_as(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.profile_is_mine(p_profile)
     and exists (select 1 from public.site_profiles p where p.id = p_profile and p.status = 'active')
$$;

-- WHO a profile is, for blocking: the login behind a personal profile or a professional's business profile, the profile itself for a venue's or an event group's.
create function public.profile_key(p_profile uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(p.user_id, p.id) from public.site_profiles p where p.id = p_profile
$$;

-- Has either person blocked the other? (Any of a person's profiles counts as the person.)
create function public.profile_blocked_between(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.site_blocks b
    where (b.blocker_key = public.profile_key(p_a) and b.blocked_key = public.profile_key(p_b))
       or (b.blocker_key = public.profile_key(p_b) and b.blocked_key = public.profile_key(p_a))
  )
$$;

-- May the profile p_viewer (or nobody, when null) see that profile exists at all?
create function public.profile_visible(p_viewer uuid, p_target uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.site_profiles p where p.id = p_target and p.status = 'active')
     and (p_viewer is null or not public.profile_blocked_between(p_viewer, p_target))
$$;

-- May p_viewer see the followers, following and posts of p_target? Public: yes. Private: its owner and approved followers.
create function public.profile_content_visible(p_viewer uuid, p_target uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.profile_visible(p_viewer, p_target)
     and (
       exists (select 1 from public.site_profiles p where p.id = p_target and p.privacy = 'public')
       or public.profile_is_mine(p_target)
       or exists (select 1 from public.site_follows f where f.follower = p_viewer and f.followed = p_target and f.status = 'active')
     )
$$;

-- What the app shows about one profile, as seen by p_viewer. Does not check that the viewer may see it: the callers do.
create function public.profile_card(p_viewer uuid, p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p public.site_profiles;
  pr public.profiles;
  v_follow text := 'none';
  v_follows_me boolean := false;
  v_blocked boolean := false;
  v_mine boolean := public.profile_is_mine(p_id);
  v_content boolean;
begin
  select * into p from public.site_profiles where id = p_id;
  if not found then return null; end if;
  if p.kind = 'personal' then
    select * into pr from public.profiles where id = p.user_id;
  end if;

  if p_viewer is not null and p_viewer <> p_id then
    select f.status into v_follow from public.site_follows f where f.follower = p_viewer and f.followed = p_id;
    v_follow := coalesce(v_follow, 'none');
    v_follows_me := exists (select 1 from public.site_follows f where f.follower = p_id and f.followed = p_viewer and f.status = 'active');
    v_blocked := exists (select 1 from public.site_blocks b where b.blocker_key = public.profile_key(p_viewer) and b.blocked_key = public.profile_key(p_id));
  end if;
  v_content := p.privacy = 'public' or v_mine or v_follow = 'active';

  return jsonb_build_object(
    'id', p.id,
    'kind', p.kind,
    'handle', case p.kind when 'personal' then pr.username else p.handle end,
    'display_name', case p.kind when 'personal' then coalesce(nullif(btrim(pr.name), ''), pr.username) else p.display_name end,
    'category', p.category,
    'bio', case p.kind when 'personal' then pr.bio else p.bio end,
    'city', case p.kind when 'personal' then pr.city else p.city end,
    'avatar_url', case p.kind when 'personal' then pr.avatar_url else p.avatar_url end,
    'cover_url', p.cover_url,
    'social_links', case p.kind when 'personal' then pr.social_links else p.social_links end,
    'privacy', p.privacy,
    'status', p.status,
    'verified', p.org_id is not null and exists (select 1 from public.site_verifications v where v.org_id = p.org_id and v.state = 'verified'),
    'interests', case when v_mine then to_jsonb(p.interests) else '[]'::jsonb end,
    'followers', (select count(*) from public.site_follows f join public.site_profiles s on s.id = f.follower
                  where f.followed = p.id and f.status = 'active' and s.status = 'active'),
    'following', (select count(*) from public.site_follows f join public.site_profiles s on s.id = f.followed
                  where f.follower = p.id and f.status = 'active' and s.status = 'active'),
    'is_mine', v_mine,
    'relation', jsonb_build_object('follow', v_follow, 'follows_me', v_follows_me, 'blocked', v_blocked),
    'can_see_content', v_content
  );
end;
$$;

-- Every profile the caller may act as is checked here, with the same sentence.
create function public.profile_require_actor(p_actor uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_actor is null or not public.profile_can_act_as(p_actor) then
    raise exception 'You cannot act as this profile.';
  end if;
end;
$$;

create function public.profile_clean_interests(p_interests text[])
returns text[]
language plpgsql
immutable
set search_path = public
as $$
declare
  v_item text;
  v_out text[] := '{}';
begin
  if p_interests is null then return v_out; end if;
  foreach v_item in array p_interests loop
    v_item := lower(regexp_replace(btrim(coalesce(v_item, '')), '\s+', ' ', 'g'));
    if v_item = '' then continue; end if;
    if char_length(v_item) < 2 or char_length(v_item) > 30 then raise exception 'An interest must be 2 to 30 characters.'; end if;
    if not (v_item = any (v_out)) then v_out := v_out || v_item; end if;
  end loop;
  if cardinality(v_out) > 10 then raise exception 'Choose up to 10 interests.'; end if;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Usernames
-- ---------------------------------------------------------------------------
-- Can the caller take this username (for their own profile or a new business profile)? Their own current one counts as free.
create function public.handle_available(p_handle text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v text := lower(btrim(coalesce(p_handle, '')));
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if v !~ '^[a-z0-9._]{3,30}$' then return false; end if;
  if public.handle_reserved(v) then return false; end if;
  return not exists (select 1 from public.site_handles h where h.handle = v and h.profile_id is distinct from auth.uid());
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The caller's own profiles
-- ---------------------------------------------------------------------------
-- Create or update the caller's personal profile after they have saved their name and username (save_my_profile).
create function public.profile_save_personal(p_privacy text, p_interests text[] default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_privacy text := lower(btrim(coalesce(p_privacy, '')));
  v_interests text[] := public.profile_clean_interests(p_interests);
  v_before text;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  if not public.feature_enabled('social') then raise exception 'Profiles are not open yet.'; end if;
  if v_privacy not in ('public', 'private') then raise exception 'Choose public or private.'; end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.username is not null and p.profile_completed_at is not null) then
    raise exception 'Finish your name and username first.';
  end if;

  select s.privacy, s.id into v_before, v_id from public.site_profiles s where s.user_id = v_uid and s.kind = 'personal' for update;
  if not found then
    begin
      insert into public.site_profiles (kind, user_id, privacy, interests) values ('personal', v_uid, v_privacy, v_interests) returning id into v_id;
    exception when unique_violation then
      -- Two taps at once: the other one created it.
      select s.id into v_id from public.site_profiles s where s.user_id = v_uid and s.kind = 'personal';
      update public.site_profiles set privacy = v_privacy, interests = v_interests where id = v_id;
    end;
  else
    update public.site_profiles set privacy = v_privacy, interests = v_interests where id = v_id;
    if v_before = 'private' and v_privacy = 'public' then
      update public.site_follows set status = 'active' where followed = v_id and status = 'pending';
    end if;
  end if;
  return public.profile_card(v_id, v_id);
end;
$$;

-- A venue's profile, an event group's, or a professional's.
create function public.profile_create_business(
  p_category text,
  p_display_name text,
  p_handle text,
  p_bio text default null,
  p_city text default null,
  p_org uuid default null,
  p_venue uuid default null,
  p_avatar_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_category text := lower(btrim(coalesce(p_category, '')));
  v_name text := btrim(coalesce(p_display_name, ''));
  v_handle text := lower(btrim(coalesce(p_handle, '')));
  v_bio text := nullif(btrim(coalesce(p_bio, '')), '');
  v_city text := nullif(btrim(coalesce(p_city, '')), '');
  v_avatar text := nullif(btrim(coalesce(p_avatar_url, '')), '');
  v_org uuid;
  v_venue uuid;
  v_owner uuid;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  if not public.feature_enabled('social') then raise exception 'Profiles are not open yet.'; end if;
  if v_category not in ('venue', 'event_group', 'dj', 'mc', 'artist', 'instrumentalist', 'photographer', 'videographer', 'influencer', 'promoter', 'other') then
    raise exception 'Choose what kind of profile this is.';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 100 then raise exception 'The name is required (100 characters at most).'; end if;
  if v_bio is not null and char_length(v_bio) > 280 then raise exception 'The description must be 280 characters or fewer.'; end if;
  if v_city is not null and char_length(v_city) > 80 then raise exception 'The city must be 80 characters or fewer.'; end if;
  if v_avatar is not null and (v_avatar !~ '^https://' or char_length(v_avatar) > 500) then raise exception 'The photo must be an https link.'; end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.username is not null and p.profile_completed_at is not null) then
    raise exception 'Finish your own profile first.';
  end if;
  if not public.handle_available(v_handle) then raise exception 'That username is not available.'; end if;

  if v_category = 'venue' then
    if p_venue is null then raise exception 'Choose the venue.'; end if;
    if not public.can_access_venue(p_venue, array['owner', 'manager']) then
      raise exception 'You can only create a profile for a venue you own or manage.';
    end if;
    select v.org_id into v_org from public.site_venues v where v.id = p_venue;
    v_venue := p_venue;
  elsif v_category = 'event_group' and p_org is not null then
    if p_venue is not null then raise exception 'A venue only goes with a venue profile.'; end if;
    if not public.is_org_member(p_org, array['owner', 'organizer']) then
      raise exception 'You can only create a profile for a business you own or organize for.';
    end if;
    v_org := p_org;
  else
    if p_org is not null or p_venue is not null then raise exception 'This kind of profile does not belong to a venue business.'; end if;
    v_owner := v_uid;
    if (select count(*) from public.site_profiles s where s.user_id = v_uid and s.kind = 'business') >= 5 then
      raise exception 'You can have up to 5 business profiles.';
    end if;
  end if;

  begin
    insert into public.site_profiles (kind, user_id, org_id, venue_id, handle, display_name, category, bio, city, avatar_url)
    values ('business', v_owner, v_org, v_venue, v_handle, v_name, v_category, v_bio, v_city, v_avatar)
    returning id into v_id;
    insert into public.site_handles (handle, business_id) values (v_handle, v_id);
  exception when unique_violation then
    -- Another profile took the username, or this venue / business already has its profile.
    if v_venue is not null and exists (select 1 from public.site_profiles s where s.venue_id = v_venue) then
      raise exception 'This venue already has a profile.';
    elsif v_org is not null and v_venue is null and exists (select 1 from public.site_profiles s where s.org_id = v_org and s.venue_id is null) then
      raise exception 'This business already has an event group profile.';
    end if;
    raise exception 'That username is not available.';
  end;
  return public.profile_card(v_id, v_id);
end;
$$;

-- Edit a business profile. A photo or cover left out (null) stays; an empty one removes it.
create function public.profile_update_business(
  p_profile uuid,
  p_display_name text,
  p_bio text default null,
  p_city text default null,
  p_avatar_url text default null,
  p_cover_url text default null,
  p_social jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := btrim(coalesce(p_display_name, ''));
  v_bio text := nullif(btrim(coalesce(p_bio, '')), '');
  v_city text := nullif(btrim(coalesce(p_city, '')), '');
begin
  perform public.profile_require_actor(p_profile);
  if not exists (select 1 from public.site_profiles s where s.id = p_profile and s.kind = 'business') then
    raise exception 'Edit your own details in your profile settings.';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 100 then raise exception 'The name is required (100 characters at most).'; end if;
  if v_bio is not null and char_length(v_bio) > 280 then raise exception 'The description must be 280 characters or fewer.'; end if;
  if v_city is not null and char_length(v_city) > 80 then raise exception 'The city must be 80 characters or fewer.'; end if;
  if p_avatar_url is not null and btrim(p_avatar_url) <> '' and (btrim(p_avatar_url) !~ '^https://' or char_length(btrim(p_avatar_url)) > 500) then
    raise exception 'The photo must be an https link.';
  end if;
  if p_cover_url is not null and btrim(p_cover_url) <> '' and (btrim(p_cover_url) !~ '^https://' or char_length(btrim(p_cover_url)) > 500) then
    raise exception 'The cover must be an https link.';
  end if;

  update public.site_profiles s set
    display_name = v_name,
    bio = v_bio,
    city = v_city,
    avatar_url = case when p_avatar_url is null then s.avatar_url else nullif(btrim(p_avatar_url), '') end,
    cover_url = case when p_cover_url is null then s.cover_url else nullif(btrim(p_cover_url), '') end,
    social_links = public.clean_social_links(p_social)
  where s.id = p_profile;
  return public.profile_card(p_profile, p_profile);
end;
$$;

-- Every profile the caller may act as, their own first. Includes a suspended one, marked, so the owner can see why it is quiet.
create function public.profile_my_profiles()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  return coalesce((
    select jsonb_agg(public.profile_card(p.id, p.id) order by (p.kind = 'personal') desc, p.created_at, p.id)
    from public.site_profiles p
    where p.id in (select public.profile_my_ids())
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Finding and viewing profiles
-- ---------------------------------------------------------------------------
-- One profile by username (p_handle) or by id, as seen by p_actor.
create function public.profile_get(p_actor uuid, p_handle text default null, p_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid := p_id;
  v_handle text := lower(btrim(coalesce(p_handle, '')));
begin
  perform public.profile_require_actor(p_actor);
  if v_id is null then
    if v_handle = '' then raise exception 'Say which profile.'; end if;
    select s.id into v_id
    from public.site_profiles s
    left join public.profiles pr on pr.id = s.user_id and s.kind = 'personal'
    where (s.kind = 'business' and s.handle = v_handle) or (s.kind = 'personal' and pr.username = v_handle);
  end if;
  if v_id is null or not (public.profile_visible(p_actor, v_id) or public.profile_is_mine(v_id)) then
    raise exception 'This profile isn''t available.';
  end if;
  return public.profile_card(p_actor, v_id);
end;
$$;

-- People and businesses whose username or name starts with the text.
create function public.profile_search(p_actor uuid, p_query text, p_limit int default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := lower(btrim(coalesce(p_query, '')));
  v_like text;
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 30);
begin
  perform public.profile_require_actor(p_actor);
  if char_length(v_q) < 2 then raise exception 'Type at least 2 letters.'; end if;
  if char_length(v_q) > 40 then raise exception 'That search is too long.'; end if;
  v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  return coalesce((
    select jsonb_agg(public.profile_card(p_actor, m.id) order by m.exact desc, m.followers desc, m.sort_name, m.id)
    from (
      select s.id,
             (coalesce(s.handle, pr.username) = v_q) as exact,
             (select count(*) from public.site_follows f where f.followed = s.id and f.status = 'active') as followers,
             lower(coalesce(s.display_name, pr.name, pr.username)) as sort_name
      from (
        select b.id from public.site_profiles b
        where b.kind = 'business' and (b.handle like v_like or lower(b.display_name) like v_like)
        union
        select x.id from public.profiles u
        join public.site_profiles x on x.user_id = u.id and x.kind = 'personal'
        where u.username like v_like or lower(u.name) like v_like
      ) c
      join public.site_profiles s on s.id = c.id
      left join public.profiles pr on pr.id = s.user_id and s.kind = 'personal'
      where s.status = 'active'
        and s.id <> p_actor
        and not public.profile_blocked_between(p_actor, s.id)
      order by (coalesce(s.handle, pr.username) = v_q) desc, lower(coalesce(s.display_name, pr.name, pr.username))
      limit v_limit
    ) m
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Following
-- ---------------------------------------------------------------------------
-- Follow (or ask to follow, when the profile is private) and unfollow. Returns the target as the actor now sees it.
create function public.follow_set(p_actor uuid, p_target uuid, p_follow boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_private boolean;
begin
  perform public.profile_require_actor(p_actor);
  if p_target is null or p_follow is null then raise exception 'Say which profile.'; end if;
  if p_target = p_actor or public.profile_is_mine(p_target) then raise exception 'You cannot follow your own profile.'; end if;

  if p_follow then
    if not public.feature_enabled('social') then raise exception 'Profiles are not open yet.'; end if;
    if not public.profile_visible(p_actor, p_target) then raise exception 'This profile isn''t available.'; end if;
    if exists (select 1 from public.site_follows f where f.follower = p_actor and f.followed = p_target) then
      return public.profile_card(p_actor, p_target);
    end if;
    if (select count(*) from public.site_follows f where f.follower = p_actor and f.created_at > now() - interval '1 hour') >= 200 then
      raise exception 'You are following people too quickly. Try again later.';
    end if;
    select s.privacy = 'private' into v_private from public.site_profiles s where s.id = p_target;
    insert into public.site_follows (follower, followed, status)
    values (p_actor, p_target, case when v_private then 'pending' else 'active' end)
    on conflict do nothing;
  else
    delete from public.site_follows where follower = p_actor and followed = p_target;
  end if;
  return public.profile_card(p_actor, p_target);
end;
$$;

-- The owner of a private profile answers a request ('accept' or 'decline') or removes a follower ('remove').
create function public.follow_respond(p_actor uuid, p_other uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text := lower(btrim(coalesce(p_action, '')));
  n int;
begin
  perform public.profile_require_actor(p_actor);
  if p_other is null then raise exception 'Say which profile.'; end if;
  if v_action = 'accept' then
    update public.site_follows set status = 'active' where follower = p_other and followed = p_actor and status = 'pending';
    get diagnostics n = row_count;
    if n = 0 then raise exception 'There is no request from this profile.'; end if;
  elsif v_action = 'decline' then
    delete from public.site_follows where follower = p_other and followed = p_actor and status = 'pending';
    get diagnostics n = row_count;
    if n = 0 then raise exception 'There is no request from this profile.'; end if;
  elsif v_action = 'remove' then
    delete from public.site_follows where follower = p_other and followed = p_actor and status = 'active';
  else
    raise exception 'Choose accept, decline or remove.';
  end if;
  return jsonb_build_object(
    'followers', (select count(*) from public.site_follows f where f.followed = p_actor and f.status = 'active'),
    'requests', (select count(*) from public.site_follows f where f.followed = p_actor and f.status = 'pending')
  );
end;
$$;

-- Who is waiting for the actor to accept them, newest first.
create function public.follow_requests(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  return coalesce((
    select jsonb_agg(public.profile_card(p_actor, r.follower) || jsonb_build_object('requested_at', r.created_at) order by r.created_at desc)
    from (
      select f.follower, f.created_at
      from public.site_follows f
      join public.site_profiles s on s.id = f.follower and s.status = 'active'
      where f.followed = p_actor and f.status = 'pending' and not public.profile_blocked_between(p_actor, f.follower)
      order by f.created_at desc
      limit 100
    ) r
  ), '[]'::jsonb);
end;
$$;

-- A page of someone's followers (p_kind 'followers') or the profiles they follow ('following'), newest first. p_before is the 'followed_at' of the last row seen.
create function public.follow_list(p_actor uuid, p_profile uuid, p_kind text, p_limit int default 30, p_before timestamptz default null)
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
  if v_kind not in ('followers', 'following') then raise exception 'Choose followers or following.'; end if;
  if not (public.profile_visible(p_actor, p_profile) or public.profile_is_mine(p_profile)) then raise exception 'This profile isn''t available.'; end if;
  if not (public.profile_content_visible(p_actor, p_profile) or p_profile = p_actor) then
    raise exception 'Follow this profile to see its people.';
  end if;

  return coalesce((
    select jsonb_agg(public.profile_card(p_actor, r.other) || jsonb_build_object('followed_at', r.at) order by r.at desc)
    from (
      select case when v_kind = 'followers' then f.follower else f.followed end as other, f.created_at as at
      from public.site_follows f
      join public.site_profiles s on s.id = case when v_kind = 'followers' then f.follower else f.followed end and s.status = 'active'
      where f.status = 'active'
        and ((v_kind = 'followers' and f.followed = p_profile) or (v_kind = 'following' and f.follower = p_profile))
        and (p_before is null or f.created_at < p_before)
        and not public.profile_blocked_between(p_actor, s.id)
      order by f.created_at desc
      limit v_limit
    ) r
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Blocking
-- ---------------------------------------------------------------------------
create function public.block_set(p_actor uuid, p_target uuid, p_blocked boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ka uuid;
  v_kb uuid;
begin
  perform public.profile_require_actor(p_actor);
  if p_target is null or p_blocked is null then raise exception 'Say which profile.'; end if;
  if p_target = p_actor or public.profile_is_mine(p_target) then raise exception 'You cannot block your own profile.'; end if;
  if not exists (select 1 from public.site_profiles s where s.id = p_target) then raise exception 'This profile isn''t available.'; end if;

  v_ka := public.profile_key(p_actor);
  v_kb := public.profile_key(p_target);
  if p_blocked then
    insert into public.site_blocks (blocker, blocked, blocker_key, blocked_key) values (p_actor, p_target, v_ka, v_kb) on conflict do nothing;
    -- Every follow between the two PEOPLE goes, whichever of their profiles it was made with.
    delete from public.site_follows f
    where (f.follower in (select s.id from public.site_profiles s where s.id = v_ka or s.user_id = v_ka)
           and f.followed in (select s.id from public.site_profiles s where s.id = v_kb or s.user_id = v_kb))
       or (f.follower in (select s.id from public.site_profiles s where s.id = v_kb or s.user_id = v_kb)
           and f.followed in (select s.id from public.site_profiles s where s.id = v_ka or s.user_id = v_ka));
  else
    delete from public.site_blocks where blocker_key = v_ka and blocked_key = v_kb;
  end if;
  return jsonb_build_object('blocked', p_blocked);
end;
$$;

-- The profiles the actor has blocked, newest first (header only).
create function public.block_list(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  return coalesce((
    select jsonb_agg(public.profile_card(p_actor, b.blocked) || jsonb_build_object('blocked_at', b.created_at) order by b.created_at desc)
    from (
      -- One row for each blocked PERSON, whichever of the actor's profiles blocked them: the profile blocked first, so the list does not change when another of their profiles
      -- is blocked as well.
      select d.blocked, d.created_at
      from (select distinct on (x.blocked_key) x.blocked, x.created_at from public.site_blocks x
            where x.blocker_key = public.profile_key(p_actor) order by x.blocked_key, x.created_at) d
      order by d.created_at desc limit 200
    ) b
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.handle_reserved(text), public.profile_is_mine(uuid), public.profile_can_act_as(uuid), public.profile_key(uuid), public.profile_blocked_between(uuid, uuid),
  public.profile_visible(uuid, uuid), public.profile_content_visible(uuid, uuid), public.profile_card(uuid, uuid), public.profile_require_actor(uuid),
  public.profile_clean_interests(text[]), public.profile_my_ids(),
  public.site_handles_follow_profile(),
  public.handle_available(text), public.profile_save_personal(text, text[]),
  public.profile_create_business(text, text, text, text, text, uuid, uuid, text),
  public.profile_update_business(uuid, text, text, text, text, text, jsonb), public.profile_my_profiles(),
  public.profile_get(uuid, text, uuid), public.profile_search(uuid, text, int),
  public.follow_set(uuid, uuid, boolean), public.follow_respond(uuid, uuid, text), public.follow_requests(uuid),
  public.follow_list(uuid, uuid, text, int, timestamptz),
  public.block_set(uuid, uuid, boolean), public.block_list(uuid)
from public, anon, authenticated;
grant execute on function
  public.handle_available(text), public.profile_save_personal(text, text[]),
  public.profile_create_business(text, text, text, text, text, uuid, uuid, text),
  public.profile_update_business(uuid, text, text, text, text, text, jsonb), public.profile_my_profiles(),
  public.profile_get(uuid, text, uuid), public.profile_search(uuid, text, int),
  public.follow_set(uuid, uuid, boolean), public.follow_respond(uuid, uuid, text), public.follow_requests(uuid),
  public.follow_list(uuid, uuid, text, int, timestamptz),
  public.block_set(uuid, uuid, boolean), public.block_list(uuid)
to authenticated, service_role;
