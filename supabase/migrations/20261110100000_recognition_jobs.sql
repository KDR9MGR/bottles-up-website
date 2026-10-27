-- Recognition and jobs (customer app completion plan, M10; the client's 15 Oct plan, "Verification ranks and awards" and "Jobs and opportunities").
--
--   * VERIFICATION is a check by BottlesUp staff that a person or a professional is who they say they are, and it is not for sale: a subscription never gives it (20261109100000).
--     A profile run by a business account is verified through that account in BottlesUp Business (as before). A person's own profile, or a professional's own profile, asks here with
--     a few words about themselves; BottlesUp decides in the CMS and can take it back. Nothing private (an ID document) goes through the app.
--   * RANKS are earned: Verified, then Elite, Icon, Legend, Global Icon and BottlesUp Immortal at the follower counts in site_rank_levels (the names, the counts, the colours and which
--     ranks may claim a plaque are the CMS's to change: the client's plan says they still need approval). A verified profile that has reached the next level ASKS for a review; BottlesUp
--     looks at whether the followers are genuine and either awards the rank or says why not (it can ask again for that level after 30 days). The badge shown next to a name is the
--     highest rank awarded; it never comes from payment. Switched on and off by the `ranks` switch.
--   * AWARDS are the ranks a profile holds, listed on the profile. A rank that has a plaque can claim one: the owner gives a delivery address (kept only for the parcel, wiped 90 days
--     after it arrives and at once if cancelled), BottlesUp marks it shipped with the carrier and tracking number, then delivered.
--   * JOBS are listings by a business profile (full-time, part-time, event shift, freelance, paid collaboration, promoter/ambassador): what it pays, what it needs, where, when and by
--     which day to apply. Applying is free and private: only the business sees who applied. The business shortlists, accepts or turns down, with a reply. Wages are not handled here,
--     and a gig that becomes a booked service goes through the hiring flow (20261107100000). Listings can be reported (20261105100000). Switched on and off by the `jobs` switch.
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, except profile_badge, which replaces the small version in 20261101110000
-- on purpose (that one only knew about business accounts).

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.site_rank_levels (
  key text primary key check (key ~ '^[a-z_]{3,20}$'),
  name text not null check (char_length(btrim(name)) between 2 and 40),
  min_followers bigint not null check (min_followers >= 0),
  sort int not null unique,
  colour text not null check (colour ~ '^#[0-9A-Fa-f]{6}$'),
  plaque boolean not null default false,
  active boolean not null default true
);
insert into public.site_rank_levels (key, name, min_followers, sort, colour, plaque) values
  ('verified', 'Verified', 0, 1, '#1D9BF0', false),
  ('elite', 'Elite', 100000, 2, '#2E9E5B', false),
  ('icon', 'Icon', 1000000, 3, '#7E57C2', true),
  ('legend', 'Legend', 10000000, 4, '#E67E22', true),
  ('global_icon', 'Global Icon', 50000000, 5, '#D4A017', true),
  ('immortal', 'BottlesUp Immortal', 100000000, 6, '#C62828', true);

create table public.site_profile_verifications (
  id uuid primary key default gen_random_uuid(),
  profile uuid not null references public.site_profiles (id) on delete cascade,
  state text not null default 'requested' check (state in ('requested', 'approved', 'rejected', 'revoked')),
  note text check (note is null or char_length(note) <= 500),
  reason text check (reason is null or char_length(reason) <= 300),
  decided_by uuid references auth.users (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  constraint site_profile_verifications_decided check ((state = 'requested') = (decided_at is null))
);
-- A profile has at most one request waiting and one approval standing.
create unique index site_profile_verifications_open on public.site_profile_verifications (profile) where state in ('requested', 'approved');
create index site_profile_verifications_state_idx on public.site_profile_verifications (state, created_at);

create table public.site_rank_reviews (
  id uuid primary key default gen_random_uuid(),
  profile uuid not null references public.site_profiles (id) on delete cascade,
  level text not null references public.site_rank_levels (key),
  -- The follower count when the profile asked.
  followers int not null check (followers >= 0),
  state text not null default 'pending' check (state in ('pending', 'approved', 'rejected')),
  reason text check (reason is null or char_length(reason) <= 300),
  decided_by uuid references auth.users (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  constraint site_rank_reviews_decided check ((state = 'pending') = (decided_at is null))
);
create unique index site_rank_reviews_pending on public.site_rank_reviews (profile) where state = 'pending';
create index site_rank_reviews_state_idx on public.site_rank_reviews (state, created_at);

create table public.site_awards (
  id uuid primary key default gen_random_uuid(),
  profile uuid not null references public.site_profiles (id) on delete cascade,
  level text not null references public.site_rank_levels (key),
  review uuid references public.site_rank_reviews (id) on delete set null,
  awarded_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz,
  revoked_reason text check (revoked_reason is null or char_length(revoked_reason) <= 300),
  constraint site_awards_revoked check ((revoked_at is null) = (revoked_reason is null))
);
create unique index site_awards_one_per_level on public.site_awards (profile, level) where revoked_at is null;
create index site_awards_profile_idx on public.site_awards (profile) where revoked_at is null;

create table public.site_plaques (
  id uuid primary key default gen_random_uuid(),
  award uuid not null unique references public.site_awards (id) on delete cascade,
  profile uuid not null references public.site_profiles (id) on delete cascade,
  state text not null default 'requested' check (state in ('requested', 'shipped', 'delivered', 'cancelled')),
  -- The delivery address: only for the parcel. Wiped (set to null) some time after it arrives or is cancelled.
  recipient text check (recipient is null or char_length(recipient) between 2 and 80),
  line1 text check (line1 is null or char_length(line1) between 3 and 120),
  line2 text check (line2 is null or char_length(line2) <= 120),
  city text check (city is null or char_length(city) between 2 and 80),
  region text check (region is null or char_length(region) <= 80),
  postal text check (postal is null or char_length(postal) between 2 and 20),
  country text check (country is null or char_length(country) between 2 and 60),
  phone text check (phone is null or char_length(phone) <= 30),
  carrier text check (carrier is null or char_length(carrier) between 2 and 60),
  tracking text check (tracking is null or char_length(tracking) between 3 and 80),
  shipped_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  address_wiped_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  constraint site_plaques_address check ((address_wiped_at is null) = (recipient is not null))
);
create index site_plaques_state_idx on public.site_plaques (state, created_at);

create table public.site_jobs (
  id uuid primary key default gen_random_uuid(),
  poster uuid not null references public.site_profiles (id) on delete cascade,
  title text not null check (char_length(title) between 5 and 120),
  kind text not null check (kind in ('full_time', 'part_time', 'event_shift', 'freelance', 'collaboration', 'ambassador')),
  description text not null check (char_length(description) between 20 and 4000),
  requirements text check (requirements is null or char_length(requirements) <= 2000),
  compensation text not null check (char_length(compensation) between 2 and 200),
  location text check (location is null or char_length(location) <= 120),
  remote boolean not null default false,
  schedule text check (schedule is null or char_length(schedule) <= 200),
  deadline date not null,
  status text not null default 'open' check (status in ('open', 'closed', 'filled', 'removed')),
  created_by uuid references auth.users (id) on delete set null,
  closed_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint site_jobs_where check (remote or location is not null)
);
create index site_jobs_open_idx on public.site_jobs (created_at desc, id desc) where status = 'open';
create index site_jobs_poster_idx on public.site_jobs (poster, created_at desc);

create table public.site_job_applications (
  id uuid primary key default gen_random_uuid(),
  job uuid not null references public.site_jobs (id) on delete cascade,
  applicant uuid not null references public.site_profiles (id) on delete cascade,
  message text not null check (char_length(message) between 20 and 2000),
  link text check (link is null or (link ~ '^https://[^[:space:]]+$' and char_length(link) <= 300)),
  state text not null default 'sent' check (state in ('sent', 'shortlisted', 'accepted', 'declined', 'withdrawn')),
  reply text check (reply is null or char_length(reply) <= 1000),
  decided_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (job, applicant)
);
create index site_job_applications_applicant_idx on public.site_job_applications (applicant, created_at desc);
create index site_job_applications_job_idx on public.site_job_applications (job, state);

alter table public.site_rank_levels enable row level security;
alter table public.site_profile_verifications enable row level security;
alter table public.site_rank_reviews enable row level security;
alter table public.site_awards enable row level security;
alter table public.site_plaques enable row level security;
alter table public.site_jobs enable row level security;
alter table public.site_job_applications enable row level security;
revoke all on table public.site_rank_levels, public.site_profile_verifications, public.site_rank_reviews, public.site_awards, public.site_plaques, public.site_jobs, public.site_job_applications
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
create function public.recognition_require(p_feature text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.feature_enabled(p_feature) then
    raise exception '%', case p_feature when 'ranks' then 'Verification and ranks are not open yet.' else 'Jobs are not open yet.' end;
  end if;
end;
$$;

-- People who follow a profile (active ones, from active profiles): the number a rank counts.
create function public.profile_followers(p_id uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.site_follows f join public.site_profiles s on s.id = f.follower where f.followed = p_id and f.status = 'active' and s.status = 'active'
$$;

-- The badge of a profile: verified (its business account is, or BottlesUp approved it) and the name of its rank: the highest one awarded, otherwise "verified".
create or replace function public.profile_badge(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'verified', v.verified,
    'rank', case when v.verified then coalesce(
      (select l.key from public.site_awards a join public.site_rank_levels l on l.key = a.level
        where a.profile = p_id and a.revoked_at is null and l.active and public.feature_enabled('ranks') order by l.sort desc limit 1), 'verified') end)
  from (
    select (exists (select 1 from public.site_profiles p where p.id = p_id and p.org_id is not null
                     and exists (select 1 from public.site_verifications x where x.org_id = p.org_id and x.state = 'verified'))
            or (public.feature_enabled('ranks') and exists (select 1 from public.site_profile_verifications w where w.profile = p_id and w.state = 'approved'))) as verified
  ) v
$$;

-- The level a verified profile could ask for now: the highest active one above its rank that its followers reach.
create function public.rank_target(p_profile uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select l.key from public.site_rank_levels l
   where l.active and l.key <> 'verified' and l.min_followers <= public.profile_followers(p_profile)
     and l.sort > coalesce((select c.sort from public.site_rank_levels c where c.key = (public.profile_badge(p_profile) ->> 'rank')), 0)
   order by l.sort desc limit 1
$$;

-- ---------------------------------------------------------------------------
-- 3. Verification
-- ---------------------------------------------------------------------------
-- Where a profile stands: verified (and how), and its latest request.
create function public.verification_status(p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_via text;
  v_org boolean;
  r public.site_profile_verifications;
begin
  perform public.recognition_require('ranks');
  if not public.profile_is_mine(p_profile) then raise exception 'This profile is not available.'; end if;
  select p.org_id is not null into v_org from public.site_profiles p where p.id = p_profile;
  v_via := case
    when v_org and (public.profile_badge(p_profile) ->> 'verified')::boolean then 'business'
    when exists (select 1 from public.site_profile_verifications w where w.profile = p_profile and w.state = 'approved') then 'review'
  end;
  select * into r from public.site_profile_verifications w where w.profile = p_profile order by w.created_at desc limit 1;
  return jsonb_build_object(
    'verified', v_via is not null,
    'via', v_via,
    'org_run', coalesce(v_org, false),
    'request', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'state', r.state, 'note', r.note, 'reason', r.reason, 'created_at', r.created_at, 'decided_at', r.decided_at,
      'retry_on', case when r.state in ('rejected', 'revoked') then (r.decided_at + interval '30 days')::date end) end);
end;
$$;

-- The owner asks to be verified, with a few words about themselves. BottlesUp decides in the CMS.
create function public.verification_request(p_profile uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  p public.site_profiles;
  r public.site_profile_verifications;
begin
  perform public.recognition_require('ranks');
  select * into p from public.site_profiles where id = p_profile;
  if not found or p.status <> 'active' or not public.profile_is_owner(p_profile) then raise exception 'Only the owner of an active profile can ask to be verified.'; end if;
  if p.org_id is not null then raise exception 'This profile is verified through its business account in BottlesUp Business.'; end if;
  if (public.profile_badge(p_profile) ->> 'verified')::boolean then raise exception 'This profile is already verified.'; end if;
  if v_note is not null and char_length(v_note) > 500 then raise exception 'Keep it to 500 characters.'; end if;
  if not public.social_text_ok(v_note) then raise exception 'That wording is not allowed here.'; end if;
  select * into r from public.site_profile_verifications w where w.profile = p_profile order by w.created_at desc limit 1;
  if found and r.state = 'requested' then raise exception 'Your request is already waiting for a decision.'; end if;
  if found and r.state in ('rejected', 'revoked') and r.decided_at > now() - interval '30 days' then
    raise exception 'You can ask again on %.', to_char((r.decided_at + interval '30 days')::date, 'YYYY-MM-DD');
  end if;
  insert into public.site_profile_verifications (profile, note) values (p_profile, v_note);
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'verification.requested', 'site_profiles', p_profile::text, '{}'::jsonb);
  return public.verification_status(p_profile);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Ranks and awards
-- ---------------------------------------------------------------------------
-- The ranks, lowest first: what the app shows when someone taps a badge.
create function public.rank_levels()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', l.key, 'name', l.name, 'min_followers', l.min_followers, 'colour', l.colour, 'plaque', l.plaque) order by l.sort), '[]'::jsonb)
    from public.site_rank_levels l where l.active
$$;

-- Where a profile the caller may act as stands: its rank, its followers, the level it could ask for, any review waiting or turned down lately.
create function public.rank_status(p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_verified boolean;
  v_target text;
  l public.site_rank_levels;
  pend public.site_rank_reviews;
  rej public.site_rank_reviews;
  v_can boolean;
begin
  perform public.recognition_require('ranks');
  if not public.profile_is_mine(p_profile) then raise exception 'This profile is not available.'; end if;
  v_verified := (public.profile_badge(p_profile) ->> 'verified')::boolean;
  v_target := case when v_verified then public.rank_target(p_profile) end;
  select * into l from public.site_rank_levels where key = v_target;
  select * into pend from public.site_rank_reviews x where x.profile = p_profile and x.state = 'pending';
  select * into rej from public.site_rank_reviews x where x.profile = p_profile and x.state = 'rejected' and x.level = v_target and x.decided_at > now() - interval '30 days' order by x.decided_at desc limit 1;
  v_can := v_target is not null and pend.id is null and rej.id is null;
  return jsonb_build_object(
    'verified', v_verified,
    'rank', public.profile_badge(p_profile) ->> 'rank',
    'followers', public.profile_followers(p_profile),
    'next', (select jsonb_build_object('key', n.key, 'name', n.name, 'min_followers', n.min_followers, 'colour', n.colour)
               from public.site_rank_levels n
              where n.active and n.key <> 'verified'
                and n.sort > coalesce((select c.sort from public.site_rank_levels c where c.key = (public.profile_badge(p_profile) ->> 'rank')), 0)
              order by n.sort limit 1),
    'target', case when l.key is null then null else jsonb_build_object('key', l.key, 'name', l.name, 'min_followers', l.min_followers, 'colour', l.colour) end,
    'can_request', v_can,
    'pending', case when pend.id is null then null else jsonb_build_object('id', pend.id, 'level', pend.level, 'created_at', pend.created_at) end,
    'rejected', case when rej.id is null then null else jsonb_build_object('level', rej.level, 'reason', rej.reason, 'retry_on', (rej.decided_at + interval '30 days')::date) end);
end;
$$;

-- The owner of a verified profile that has reached a level asks for it to be looked at.
create function public.rank_request(p_profile uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target text;
  pend public.site_rank_reviews;
  rej public.site_rank_reviews;
begin
  perform public.recognition_require('ranks');
  if not exists (select 1 from public.site_profiles p where p.id = p_profile and p.status = 'active') or not public.profile_is_owner(p_profile) then
    raise exception 'Only the owner of an active profile can ask for a rank.';
  end if;
  if not (public.profile_badge(p_profile) ->> 'verified')::boolean then raise exception 'Get verified first: ranks are for verified profiles.'; end if;
  v_target := public.rank_target(p_profile);
  if v_target is null then raise exception 'You have not reached the next level yet.'; end if;
  select * into pend from public.site_rank_reviews x where x.profile = p_profile and x.state = 'pending';
  if found then raise exception 'A review is already waiting for a decision.'; end if;
  select * into rej from public.site_rank_reviews x where x.profile = p_profile and x.state = 'rejected' and x.level = v_target and x.decided_at > now() - interval '30 days' order by x.decided_at desc limit 1;
  if found then raise exception 'We looked at this recently. You can ask again on %.', to_char((rej.decided_at + interval '30 days')::date, 'YYYY-MM-DD'); end if;
  insert into public.site_rank_reviews (profile, level, followers) values (p_profile, v_target, public.profile_followers(p_profile));
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'rank.requested', 'site_profiles', p_profile::text, jsonb_build_object('level', v_target));
  return public.rank_status(p_profile);
end;
$$;

-- The ranks a profile holds, for its page. Whoever can see the profile sees them; nothing for a profile that is not verified or when ranks are off.
create function public.awards_of(p_actor uuid, p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_actor(p_actor);
  if not public.feature_enabled('ranks') or not public.profile_visible(p_actor, p_profile) then return '[]'::jsonb; end if;
  if not (public.profile_badge(p_profile) ->> 'verified')::boolean then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', a.id, 'level', l.key, 'name', l.name, 'colour', l.colour, 'awarded_at', a.awarded_at, 'plaque', l.plaque) order by l.sort desc)
      from public.site_awards a join public.site_rank_levels l on l.key = a.level
     where a.profile = p_profile and a.revoked_at is null and l.active), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Plaques
-- ---------------------------------------------------------------------------
create function public.plaque_json(p_plaque uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', q.id, 'award', q.award, 'level', a.level, 'level_name', l.name, 'state', q.state,
    'recipient', q.recipient, 'line1', q.line1, 'line2', q.line2, 'city', q.city, 'region', q.region, 'postal', q.postal, 'country', q.country, 'phone', q.phone,
    'carrier', q.carrier, 'tracking', q.tracking, 'shipped_at', q.shipped_at, 'delivered_at', q.delivered_at, 'created_at', q.created_at, 'address_removed', q.address_wiped_at is not null)
  from public.site_plaques q join public.site_awards a on a.id = q.award join public.site_rank_levels l on l.key = a.level
  where q.id = p_plaque
$$;

-- The plaque requests of a profile the caller owns, newest first.
create function public.plaques_mine(p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.recognition_require('ranks');
  if not public.profile_is_owner(p_profile) then raise exception 'This profile is not available.'; end if;
  return coalesce((select jsonb_agg(public.plaque_json(q.id) order by q.created_at desc) from public.site_plaques q where q.profile = p_profile), '[]'::jsonb);
end;
$$;

-- The owner of an award whose rank has a plaque asks for one and gives the delivery address.
create function public.plaque_claim(p_award uuid, p_recipient text, p_line1 text, p_line2 text, p_city text, p_region text, p_postal text, p_country text, p_phone text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_awards;
  v_recipient text := btrim(coalesce(p_recipient, ''));
  v_line1 text := btrim(coalesce(p_line1, ''));
  v_line2 text := nullif(btrim(coalesce(p_line2, '')), '');
  v_city text := btrim(coalesce(p_city, ''));
  v_region text := nullif(btrim(coalesce(p_region, '')), '');
  v_postal text := btrim(coalesce(p_postal, ''));
  v_country text := btrim(coalesce(p_country, ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_id uuid;
begin
  perform public.recognition_require('ranks');
  select * into a from public.site_awards where id = p_award and revoked_at is null;
  if not found or not public.profile_is_owner(a.profile) then raise exception 'This award is not available.'; end if;
  if not exists (select 1 from public.site_rank_levels l where l.key = a.level and l.active and l.plaque) then raise exception 'This rank does not come with a plaque.'; end if;
  if exists (select 1 from public.site_plaques q where q.award = p_award and q.state <> 'cancelled') then raise exception 'A plaque has already been asked for.'; end if;
  if char_length(v_recipient) not between 2 and 80 then raise exception 'Write the name for the parcel (2 to 80 characters).'; end if;
  if char_length(v_line1) not between 3 and 120 then raise exception 'Write the street address (3 to 120 characters).'; end if;
  if v_line2 is not null and char_length(v_line2) > 120 then raise exception 'Keep the second address line to 120 characters.'; end if;
  if char_length(v_city) not between 2 and 80 then raise exception 'Write the city (2 to 80 characters).'; end if;
  if v_region is not null and char_length(v_region) > 80 then raise exception 'Keep the province or state to 80 characters.'; end if;
  if char_length(v_postal) not between 2 and 20 then raise exception 'Write the postal code (2 to 20 characters).'; end if;
  if char_length(v_country) not between 2 and 60 then raise exception 'Write the country (2 to 60 characters).'; end if;
  if v_phone is not null and char_length(v_phone) > 30 then raise exception 'Keep the phone number to 30 characters.'; end if;
  -- A cancelled request for the same award is replaced, not duplicated.
  delete from public.site_plaques where award = p_award and state = 'cancelled';
  insert into public.site_plaques (award, profile, recipient, line1, line2, city, region, postal, country, phone)
  values (p_award, a.profile, v_recipient, v_line1, v_line2, v_city, v_region, v_postal, v_country, v_phone) returning id into v_id;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'plaque.requested', 'site_plaques', v_id::text, jsonb_build_object('level', a.level));
  return public.plaque_json(v_id);
end;
$$;

-- The owner takes the request back while it has not been shipped: the address goes at once.
create function public.plaque_cancel(p_plaque uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.site_plaques;
begin
  perform public.recognition_require('ranks');
  select * into q from public.site_plaques where id = p_plaque for update;
  if not found or not public.profile_is_owner(q.profile) then raise exception 'This plaque is not available.'; end if;
  if q.state = 'cancelled' then raise exception 'This plaque was already cancelled.'; end if;
  if q.state <> 'requested' then raise exception 'It is already on its way, so it cannot be cancelled here.'; end if;
  update public.site_plaques
     set state = 'cancelled', cancelled_at = clock_timestamp(), address_wiped_at = clock_timestamp(),
         recipient = null, line1 = null, line2 = null, city = null, region = null, postal = null, country = null, phone = null
   where id = p_plaque;
  return public.plaque_json(p_plaque);
end;
$$;

-- The daily clean-up wipes the address of a plaque that arrived 90 days ago (a cancelled one lost its address when it was cancelled). Called by social_housekeeping.
create function public.plaque_addresses_wipe()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  update public.site_plaques
     set address_wiped_at = clock_timestamp(), recipient = null, line1 = null, line2 = null, city = null, region = null, postal = null, country = null, phone = null
   where address_wiped_at is null and delivered_at < now() - interval '90 days';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Jobs
-- ---------------------------------------------------------------------------
-- Can the caller (acting as p_actor) see this job? Not one that BottlesUp removed, not from a suspended or blocked profile.
create function public.job_visible(p_actor uuid, p_job uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.site_jobs j join public.site_profiles s on s.id = j.poster
     where j.id = p_job and j.status <> 'removed' and s.status = 'active' and not public.profile_blocked_between(p_actor, j.poster))
$$;

create function public.job_json(p_actor uuid, p_job uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', j.id, 'title', j.title, 'kind', j.kind, 'description', j.description, 'requirements', j.requirements, 'compensation', j.compensation,
    'location', j.location, 'remote', j.remote, 'schedule', j.schedule, 'deadline', j.deadline, 'status', j.status, 'created_at', j.created_at,
    'open', j.status = 'open' and j.deadline >= current_date,
    'poster', public.profile_mini(j.poster),
    'mine', public.profile_is_mine(j.poster),
    'applications', case when public.profile_has_permission(j.poster, 'bookings') then (select count(*) from public.site_job_applications a where a.job = j.id and a.state <> 'withdrawn') end,
    'waiting', case when public.profile_has_permission(j.poster, 'bookings') then (select count(*) from public.site_job_applications a where a.job = j.id and a.state = 'sent') end,
    'applied', (select jsonb_build_object('id', a.id, 'state', a.state) from public.site_job_applications a where a.job = j.id and a.applicant = p_actor))
  from public.site_jobs j where j.id = p_job
$$;

create function public.job_application_json(p_actor uuid, p_application uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', a.id, 'state', a.state, 'message', a.message, 'link', a.link, 'reply', a.reply, 'created_at', a.created_at, 'decided_at', a.decided_at,
    'applicant', public.profile_mini(a.applicant),
    'job', jsonb_build_object('id', j.id, 'title', j.title, 'kind', j.kind, 'status', j.status, 'deadline', j.deadline, 'open', j.status = 'open' and j.deadline >= current_date, 'poster', public.profile_mini(j.poster)))
  from public.site_job_applications a join public.site_jobs j on j.id = a.job where a.id = p_application
$$;

-- What a listing says, checked the same way when it is made and when it is changed.
create function public.job_check(p_title text, p_kind text, p_description text, p_requirements text, p_compensation text, p_location text, p_remote boolean, p_schedule text, p_deadline date)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if char_length(btrim(coalesce(p_title, ''))) not between 5 and 120 then raise exception 'Write a title of 5 to 120 characters.'; end if;
  if p_kind is null or p_kind not in ('full_time', 'part_time', 'event_shift', 'freelance', 'collaboration', 'ambassador') then raise exception 'Choose what kind of job it is.'; end if;
  if char_length(btrim(coalesce(p_description, ''))) not between 20 and 4000 then raise exception 'Describe the job in 20 to 4000 characters.'; end if;
  if char_length(btrim(coalesce(p_requirements, ''))) > 2000 then raise exception 'Keep the requirements to 2000 characters.'; end if;
  if char_length(btrim(coalesce(p_compensation, ''))) not between 2 and 200 then raise exception 'Say what it pays (2 to 200 characters).'; end if;
  if char_length(btrim(coalesce(p_location, ''))) > 120 then raise exception 'Keep the location to 120 characters.'; end if;
  if not coalesce(p_remote, false) and btrim(coalesce(p_location, '')) = '' then raise exception 'Say where it is, or that it can be done remotely.'; end if;
  if char_length(btrim(coalesce(p_schedule, ''))) > 200 then raise exception 'Keep the schedule to 200 characters.'; end if;
  if p_deadline is null or p_deadline < current_date or p_deadline > current_date + 365 then raise exception 'Choose a last day to apply, from today to a year away.'; end if;
  if not public.social_text_ok(concat_ws(' ', p_title, p_description, p_requirements, p_compensation, p_location, p_schedule)) then raise exception 'That wording is not allowed here.'; end if;
end;
$$;

create function public.job_create(p_actor uuid, p_title text, p_kind text, p_description text, p_requirements text, p_compensation text, p_location text, p_remote boolean, p_schedule text, p_deadline date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.recognition_require('jobs');
  perform public.social_require_rules();
  perform public.profile_require_permission(p_actor, 'bookings');
  if not exists (select 1 from public.site_profiles s where s.id = p_actor and s.kind = 'business') then raise exception 'Only a business profile can post a job.'; end if;
  perform public.job_check(p_title, p_kind, p_description, p_requirements, p_compensation, p_location, p_remote, p_schedule, p_deadline);
  if (select count(*) from public.site_jobs j where j.poster = p_actor and j.status = 'open') >= 20 then raise exception 'You have 20 open jobs. Close one first.'; end if;
  if (select count(*) from public.site_jobs j where j.poster = p_actor and j.created_at > now() - interval '1 day') >= 5 then raise exception 'You have posted a lot of jobs today. Try again tomorrow.'; end if;
  insert into public.site_jobs (poster, title, kind, description, requirements, compensation, location, remote, schedule, deadline, created_by)
  values (p_actor, btrim(p_title), p_kind, btrim(p_description), nullif(btrim(coalesce(p_requirements, '')), ''), btrim(p_compensation), nullif(btrim(coalesce(p_location, '')), ''),
          coalesce(p_remote, false), nullif(btrim(coalesce(p_schedule, '')), ''), p_deadline, auth.uid())
  returning id into v_id;
  return public.job_json(p_actor, v_id);
end;
$$;

create function public.job_update(p_actor uuid, p_job uuid, p_title text, p_kind text, p_description text, p_requirements text, p_compensation text, p_location text, p_remote boolean, p_schedule text, p_deadline date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  j public.site_jobs;
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_permission(p_actor, 'bookings');
  select * into j from public.site_jobs where id = p_job for update;
  if not found or j.poster <> p_actor then raise exception 'This job is not available.'; end if;
  if j.status <> 'open' then raise exception 'Only an open job can be changed.'; end if;
  perform public.job_check(p_title, p_kind, p_description, p_requirements, p_compensation, p_location, p_remote, p_schedule, p_deadline);
  update public.site_jobs
     set title = btrim(p_title), kind = p_kind, description = btrim(p_description), requirements = nullif(btrim(coalesce(p_requirements, '')), ''), compensation = btrim(p_compensation),
         location = nullif(btrim(coalesce(p_location, '')), ''), remote = coalesce(p_remote, false), schedule = nullif(btrim(coalesce(p_schedule, '')), ''), deadline = p_deadline,
         updated_at = clock_timestamp()
   where id = p_job;
  return public.job_json(p_actor, p_job);
end;
$$;

-- The business closes a listing: filled (someone was found) or just closed.
create function public.job_close(p_actor uuid, p_job uuid, p_filled boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  j public.site_jobs;
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_permission(p_actor, 'bookings');
  select * into j from public.site_jobs where id = p_job for update;
  if not found or j.poster <> p_actor then raise exception 'This job is not available.'; end if;
  if j.status <> 'open' then raise exception 'This job is already closed.'; end if;
  update public.site_jobs set status = case when coalesce(p_filled, false) then 'filled' else 'closed' end, closed_at = clock_timestamp(), updated_at = clock_timestamp() where id = p_job;
  return public.job_json(p_actor, p_job);
end;
$$;

create function public.job_get(p_actor uuid, p_job uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_actor(p_actor);
  if not public.job_visible(p_actor, p_job) then raise exception 'This job is not available.'; end if;
  return public.job_json(p_actor, p_job);
end;
$$;

-- Open jobs whose last day has not passed, newest first, for the profile the caller acts as.
create function public.jobs_list(p_actor uuid, p_kind text default null, p_query text default null, p_remote boolean default null, p_before timestamptz default null, p_before_id uuid default null, p_limit int default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_q text := nullif(btrim(coalesce(p_query, '')), '');
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_actor(p_actor);
  if v_q is not null then v_q := '%' || replace(replace(replace(left(v_q, 80), '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  return coalesce((
    select jsonb_agg(public.job_json(p_actor, x.id) order by x.created_at desc, x.id desc)
      from (
        select j.id, j.created_at
          from public.site_jobs j join public.site_profiles s on s.id = j.poster
         where j.status = 'open' and j.deadline >= current_date and s.status = 'active' and not public.profile_blocked_between(p_actor, j.poster)
           and (p_kind is null or j.kind = p_kind)
           and (p_remote is null or j.remote = p_remote)
           and (v_q is null or j.title ilike v_q or j.description ilike v_q or coalesce(j.location, '') ilike v_q)
           and (p_before is null or (j.created_at, j.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
         order by j.created_at desc, j.id desc
         limit v_limit
      ) x), '[]'::jsonb);
end;
$$;

-- The listings of a business profile the caller manages (all but the removed), newest first.
create function public.jobs_mine(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_permission(p_actor, 'bookings');
  return coalesce((select jsonb_agg(public.job_json(p_actor, j.id) order by j.created_at desc, j.id desc) from public.site_jobs j where j.poster = p_actor and j.status <> 'removed'), '[]'::jsonb);
end;
$$;

-- Applying is free and private. One application per profile per job; a withdrawn one can be sent again.
create function public.job_apply(p_actor uuid, p_job uuid, p_message text, p_link text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  j public.site_jobs;
  a public.site_job_applications;
  v_message text := btrim(coalesce(p_message, ''));
  v_link text := nullif(btrim(coalesce(p_link, '')), '');
  v_id uuid;
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_actor(p_actor);
  perform public.social_require_rules();
  select * into j from public.site_jobs where id = p_job for update;
  if not found or not public.job_visible(p_actor, p_job) then raise exception 'This job is not available.'; end if;
  if j.status <> 'open' or j.deadline < current_date then raise exception 'This job is not taking applications any more.'; end if;
  if public.profile_is_mine(j.poster) then raise exception 'You cannot apply to your own job.'; end if;
  if char_length(v_message) not between 20 and 2000 then raise exception 'Write a message of 20 to 2000 characters.'; end if;
  if v_link is not null and (char_length(v_link) > 300 or v_link !~ '^https://[^[:space:]]+$') then raise exception 'A link must start with https:// and be up to 300 characters.'; end if;
  if not public.social_text_ok(v_message) then raise exception 'That wording is not allowed here.'; end if;
  select * into a from public.site_job_applications x where x.job = p_job and x.applicant = p_actor for update;
  if a.id is not null and a.state <> 'withdrawn' then raise exception 'You have already applied.'; end if;
  if (select count(*) from public.site_job_applications x where x.applicant = p_actor and x.created_at > now() - interval '1 day') >= 20 then
    raise exception 'You have sent a lot of applications today. Try again tomorrow.';
  end if;
  if a.id is not null then
    update public.site_job_applications set state = 'sent', message = v_message, link = v_link, reply = null, decided_at = null, created_at = clock_timestamp(), updated_at = clock_timestamp() where id = a.id;
    v_id := a.id;
  else
    insert into public.site_job_applications (job, applicant, message, link) values (p_job, p_actor, v_message, v_link) returning id into v_id;
  end if;
  return public.job_application_json(p_actor, v_id);
end;
$$;

-- What the business has received for one listing (withdrawn ones are not shown), newest first.
create function public.job_applications(p_actor uuid, p_job uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_permission(p_actor, 'bookings');
  if not exists (select 1 from public.site_jobs j where j.id = p_job and j.poster = p_actor and j.status <> 'removed') then raise exception 'This job is not available.'; end if;
  return coalesce((select jsonb_agg(public.job_application_json(p_actor, a.id) order by a.created_at desc, a.id desc) from public.site_job_applications a where a.job = p_job and a.state <> 'withdrawn'), '[]'::jsonb);
end;
$$;

-- The business answers an application: shortlist it, accept it or turn it down, with an optional reply the applicant reads.
create function public.job_application_set(p_actor uuid, p_application uuid, p_state text, p_reply text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_job_applications;
  v_reply text := nullif(btrim(coalesce(p_reply, '')), '');
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_permission(p_actor, 'bookings');
  if p_state is null or p_state not in ('shortlisted', 'accepted', 'declined') then raise exception 'Choose shortlist, accept or decline.'; end if;
  if v_reply is not null and char_length(v_reply) > 1000 then raise exception 'Keep the reply to 1000 characters.'; end if;
  if not public.social_text_ok(v_reply) then raise exception 'That wording is not allowed here.'; end if;
  select x.* into a from public.site_job_applications x join public.site_jobs j on j.id = x.job where x.id = p_application and j.poster = p_actor and j.status <> 'removed' for update of x;
  if not found then raise exception 'This application is not available.'; end if;
  if a.state = 'withdrawn' then raise exception 'The applicant has taken this application back.'; end if;
  update public.site_job_applications set state = p_state, reply = v_reply, decided_at = clock_timestamp(), updated_at = clock_timestamp() where id = p_application;
  return public.job_application_json(p_actor, p_application);
end;
$$;

-- The applicant takes an application back.
create function public.job_application_withdraw(p_actor uuid, p_application uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_job_applications;
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_actor(p_actor);
  select * into a from public.site_job_applications where id = p_application and applicant = p_actor for update;
  if not found then raise exception 'This application is not available.'; end if;
  if a.state = 'withdrawn' then raise exception 'You already took this application back.'; end if;
  update public.site_job_applications set state = 'withdrawn', updated_at = clock_timestamp() where id = p_application;
  return public.job_application_json(p_actor, p_application);
end;
$$;

-- The applications a profile the caller acts as has sent, newest first.
create function public.job_applications_mine(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.recognition_require('jobs');
  perform public.profile_require_actor(p_actor);
  return coalesce((select jsonb_agg(public.job_application_json(p_actor, a.id) order by a.created_at desc, a.id desc)
                     from public.site_job_applications a join public.site_jobs j on j.id = a.job where a.applicant = p_actor and j.status <> 'removed'), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. The CMS (BottlesUp admins only)
-- ---------------------------------------------------------------------------
-- p_state is requested, approved, rejected, revoked or all.
create function public.cms_verifications(p_state text default 'requested')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  if p_state is null or p_state not in ('requested', 'approved', 'rejected', 'revoked', 'all') then raise exception 'Choose requested, approved, rejected, revoked or all.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', w.id, 'state', w.state, 'note', w.note, 'reason', w.reason, 'created_at', w.created_at, 'decided_at', w.decided_at,
                                        'profile', public.profile_mini(w.profile), 'followers', public.profile_followers(w.profile))
                     order by w.created_at desc, w.id desc)
      from (select * from public.site_profile_verifications x where p_state = 'all' or x.state = p_state order by x.created_at desc, x.id desc limit 100) w), '[]'::jsonb);
end;
$$;

create function public.cms_verification_decide(p_id uuid, p_decision text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  w public.site_profile_verifications;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_state text;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;
  if p_decision is null or p_decision not in ('approve', 'reject', 'revoke') then raise exception 'Choose approve, reject or revoke.'; end if;
  if p_decision <> 'approve' and (v_reason is null or char_length(v_reason) < 3) then raise exception 'Write the reason (at least 3 characters).'; end if;
  if v_reason is not null and char_length(v_reason) > 300 then raise exception 'Keep the reason to 300 characters.'; end if;
  select * into w from public.site_profile_verifications where id = p_id for update;
  if not found then raise exception 'There is no such request.'; end if;
  if p_decision = 'revoke' then
    if w.state <> 'approved' then raise exception 'Only an approved verification can be taken back.'; end if;
  elsif w.state <> 'requested' then raise exception 'This request has already been decided.';
  end if;
  v_state := case p_decision when 'approve' then 'approved' when 'reject' then 'rejected' else 'revoked' end;
  update public.site_profile_verifications set state = v_state, reason = v_reason, decided_by = auth.uid(), decided_at = clock_timestamp() where id = p_id;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'verification.' || v_state, 'site_profiles', w.profile::text, jsonb_build_object('reason', v_reason));
  return jsonb_build_object('id', p_id, 'state', v_state, 'profile', w.profile);
end;
$$;

create function public.cms_rank_levels()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('key', l.key, 'name', l.name, 'min_followers', l.min_followers, 'colour', l.colour, 'plaque', l.plaque, 'active', l.active) order by l.sort) from public.site_rank_levels l), '[]'::jsonb);
end;
$$;

-- Change a level: its name, the followers it needs (between its neighbours'), its colour, whether it comes with a plaque and whether it is in use. Verified keeps 0 followers and stays on.
create function public.cms_rank_level_set(p_key text, p_name text, p_min_followers bigint, p_colour text, p_plaque boolean, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l public.site_rank_levels;
  v_name text := btrim(coalesce(p_name, ''));
  v_prev bigint;
  v_next bigint;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;
  select * into l from public.site_rank_levels where key = p_key;
  if not found then raise exception 'There is no such rank.'; end if;
  if char_length(v_name) not between 2 and 40 then raise exception 'Write a name of 2 to 40 characters.'; end if;
  if p_colour is null or p_colour !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'Write the colour like #1D9BF0.'; end if;
  if p_plaque is null or p_active is null then raise exception 'Say whether it has a plaque and whether it is in use.'; end if;
  if l.key = 'verified' then
    if p_min_followers is distinct from 0 or not p_active or p_plaque then raise exception 'Verified needs no followers, is always in use and has no plaque.'; end if;
  else
    select max(x.min_followers) into v_prev from public.site_rank_levels x where x.sort < l.sort;
    select min(x.min_followers) into v_next from public.site_rank_levels x where x.sort > l.sort;
    if p_min_followers is null or p_min_followers <= coalesce(v_prev, 0) then raise exception 'It needs more followers than the rank below it (%).', coalesce(v_prev, 0); end if;
    if v_next is not null and p_min_followers >= v_next then raise exception 'It needs fewer followers than the rank above it (%).', v_next; end if;
  end if;
  update public.site_rank_levels set name = v_name, min_followers = p_min_followers, colour = upper(p_colour), plaque = p_plaque, active = p_active where key = p_key;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'rank.level_changed', 'site_rank_levels', p_key,
          jsonb_build_object('name', v_name, 'min_followers', p_min_followers, 'plaque', p_plaque, 'active', p_active));
  return (select jsonb_build_object('key', x.key, 'name', x.name, 'min_followers', x.min_followers, 'colour', x.colour, 'plaque', x.plaque, 'active', x.active) from public.site_rank_levels x where x.key = p_key);
end;
$$;

-- p_state is pending, approved, rejected or all.
create function public.cms_rank_reviews(p_state text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  if p_state is null or p_state not in ('pending', 'approved', 'rejected', 'all') then raise exception 'Choose pending, approved, rejected or all.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'state', r.state, 'level', r.level, 'level_name', (select l.name from public.site_rank_levels l where l.key = r.level), 'followers', r.followers,
                                        'followers_now', public.profile_followers(r.profile), 'reason', r.reason, 'created_at', r.created_at, 'decided_at', r.decided_at,
                                        'verified', (public.profile_badge(r.profile) ->> 'verified')::boolean, 'profile', public.profile_mini(r.profile))
                     order by r.created_at desc, r.id desc)
      from (select * from public.site_rank_reviews x where p_state = 'all' or x.state = p_state order by x.created_at desc, x.id desc limit 100) r), '[]'::jsonb);
end;
$$;

create function public.cms_rank_decide(p_review uuid, p_approve boolean, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_rank_reviews;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;
  if p_approve is null then raise exception 'Say whether to award the rank.'; end if;
  if not p_approve and (v_reason is null or char_length(v_reason) < 3) then raise exception 'Write the reason (at least 3 characters).'; end if;
  if v_reason is not null and char_length(v_reason) > 300 then raise exception 'Keep the reason to 300 characters.'; end if;
  select * into r from public.site_rank_reviews where id = p_review for update;
  if not found then raise exception 'There is no such review.'; end if;
  if r.state <> 'pending' then raise exception 'This review has already been decided.'; end if;
  if p_approve then
    if not (public.profile_badge(r.profile) ->> 'verified')::boolean then raise exception 'This profile is not verified now, so it cannot be given a rank.'; end if;
    insert into public.site_awards (profile, level, review) values (r.profile, r.level, r.id) on conflict (profile, level) where revoked_at is null do nothing;
  end if;
  update public.site_rank_reviews set state = case when p_approve then 'approved' else 'rejected' end, reason = v_reason, decided_by = auth.uid(), decided_at = clock_timestamp() where id = p_review;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), case when p_approve then 'rank.awarded' else 'rank.refused' end, 'site_profiles', r.profile::text,
          jsonb_build_object('level', r.level, 'followers', r.followers, 'reason', v_reason));
  return jsonb_build_object('id', p_review, 'state', case when p_approve then 'approved' else 'rejected' end, 'profile', r.profile, 'level', r.level);
end;
$$;

-- BottlesUp takes a rank back (followers that turned out not to be genuine, say). A plaque that has not been shipped is cancelled.
create function public.cms_award_revoke(p_award uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_awards;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 300 then raise exception 'Write the reason (3 to 300 characters).'; end if;
  select * into a from public.site_awards where id = p_award and revoked_at is null for update;
  if not found then raise exception 'There is no such award.'; end if;
  update public.site_awards set revoked_at = clock_timestamp(), revoked_reason = v_reason where id = p_award;
  update public.site_plaques
     set state = 'cancelled', cancelled_at = clock_timestamp(), address_wiped_at = clock_timestamp(),
         recipient = null, line1 = null, line2 = null, city = null, region = null, postal = null, country = null, phone = null
   where award = p_award and state = 'requested';
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'rank.revoked', 'site_profiles', a.profile::text, jsonb_build_object('level', a.level, 'reason', v_reason));
  return jsonb_build_object('id', p_award, 'profile', a.profile, 'level', a.level);
end;
$$;

-- The awards of every profile, newest first (for taking one back).
create function public.cms_awards(p_limit int default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', a.id, 'level', a.level, 'level_name', (select l.name from public.site_rank_levels l where l.key = a.level), 'awarded_at', a.awarded_at,
                                        'profile', public.profile_mini(a.profile), 'followers_now', public.profile_followers(a.profile))
                     order by a.awarded_at desc, a.id desc)
      from (select * from public.site_awards x where x.revoked_at is null order by x.awarded_at desc, x.id desc limit least(greatest(coalesce(p_limit, 50), 1), 100)) a), '[]'::jsonb);
end;
$$;

-- p_state is requested, shipped, delivered, cancelled or all. The address is shown here, to staff, because the parcel needs it.
create function public.cms_plaques(p_state text default 'requested')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  if p_state is null or p_state not in ('requested', 'shipped', 'delivered', 'cancelled', 'all') then raise exception 'Choose requested, shipped, delivered, cancelled or all.'; end if;
  return coalesce((
    select jsonb_agg(public.plaque_json(q.id) || jsonb_build_object('profile', public.profile_mini(q.profile)) order by q.created_at desc, q.id desc)
      from (select * from public.site_plaques x where p_state = 'all' or x.state = p_state order by x.created_at desc, x.id desc limit 100) q), '[]'::jsonb);
end;
$$;

create function public.cms_plaque_shipped(p_plaque uuid, p_carrier text, p_tracking text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.site_plaques;
  v_carrier text := btrim(coalesce(p_carrier, ''));
  v_tracking text := btrim(coalesce(p_tracking, ''));
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;
  if char_length(v_carrier) not between 2 and 60 then raise exception 'Write the carrier (2 to 60 characters).'; end if;
  if char_length(v_tracking) not between 3 and 80 then raise exception 'Write the tracking number (3 to 80 characters).'; end if;
  select * into q from public.site_plaques where id = p_plaque for update;
  if not found then raise exception 'There is no such plaque.'; end if;
  if q.state <> 'requested' then raise exception 'Only a plaque that was asked for can be marked as shipped.'; end if;
  update public.site_plaques set state = 'shipped', carrier = v_carrier, tracking = v_tracking, shipped_at = clock_timestamp() where id = p_plaque;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'plaque.shipped', 'site_plaques', p_plaque::text, jsonb_build_object('carrier', v_carrier, 'tracking', v_tracking));
  return public.plaque_json(p_plaque);
end;
$$;

create function public.cms_plaque_delivered(p_plaque uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.site_plaques;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;
  select * into q from public.site_plaques where id = p_plaque for update;
  if not found then raise exception 'There is no such plaque.'; end if;
  if q.state <> 'shipped' then raise exception 'Only a plaque that was shipped can be marked as delivered.'; end if;
  update public.site_plaques set state = 'delivered', delivered_at = clock_timestamp() where id = p_plaque;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'plaque.delivered', 'site_plaques', p_plaque::text, '{}'::jsonb);
  return public.plaque_json(p_plaque);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.recognition_require(text), public.profile_followers(uuid), public.rank_target(uuid), public.plaque_json(uuid), public.plaque_addresses_wipe(), public.job_visible(uuid, uuid),
  public.job_json(uuid, uuid), public.job_application_json(uuid, uuid), public.job_check(text, text, text, text, text, text, boolean, text, date),
  public.verification_status(uuid), public.verification_request(uuid, text), public.rank_levels(), public.rank_status(uuid), public.rank_request(uuid), public.awards_of(uuid, uuid),
  public.plaques_mine(uuid), public.plaque_claim(uuid, text, text, text, text, text, text, text, text), public.plaque_cancel(uuid),
  public.job_create(uuid, text, text, text, text, text, text, boolean, text, date), public.job_update(uuid, uuid, text, text, text, text, text, text, boolean, text, date),
  public.job_close(uuid, uuid, boolean), public.job_get(uuid, uuid), public.jobs_list(uuid, text, text, boolean, timestamptz, uuid, int), public.jobs_mine(uuid),
  public.job_apply(uuid, uuid, text, text), public.job_applications(uuid, uuid), public.job_application_set(uuid, uuid, text, text), public.job_application_withdraw(uuid, uuid),
  public.job_applications_mine(uuid), public.cms_verifications(text), public.cms_verification_decide(uuid, text, text), public.cms_rank_levels(),
  public.cms_rank_level_set(text, text, bigint, text, boolean, boolean), public.cms_rank_reviews(text), public.cms_rank_decide(uuid, boolean, text), public.cms_award_revoke(uuid, text),
  public.cms_awards(int), public.cms_plaques(text), public.cms_plaque_shipped(uuid, text, text), public.cms_plaque_delivered(uuid)
from public, anon, authenticated;
grant execute on function
  public.verification_status(uuid), public.verification_request(uuid, text), public.rank_levels(), public.rank_status(uuid), public.rank_request(uuid), public.awards_of(uuid, uuid),
  public.plaques_mine(uuid), public.plaque_claim(uuid, text, text, text, text, text, text, text, text), public.plaque_cancel(uuid),
  public.job_create(uuid, text, text, text, text, text, text, boolean, text, date), public.job_update(uuid, uuid, text, text, text, text, text, text, boolean, text, date),
  public.job_close(uuid, uuid, boolean), public.job_get(uuid, uuid), public.jobs_list(uuid, text, text, boolean, timestamptz, uuid, int), public.jobs_mine(uuid),
  public.job_apply(uuid, uuid, text, text), public.job_applications(uuid, uuid), public.job_application_set(uuid, uuid, text, text), public.job_application_withdraw(uuid, uuid),
  public.job_applications_mine(uuid), public.cms_verifications(text), public.cms_verification_decide(uuid, text, text), public.cms_rank_levels(),
  public.cms_rank_level_set(text, text, bigint, text, boolean, boolean), public.cms_rank_reviews(text), public.cms_rank_decide(uuid, boolean, text), public.cms_award_revoke(uuid, text),
  public.cms_awards(int), public.cms_plaques(text), public.cms_plaque_shipped(uuid, text, text), public.cms_plaque_delivered(uuid)
to authenticated;
