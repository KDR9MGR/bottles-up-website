-- Accounts and onboarding: personal profile, business details, verification states,
-- venue claims and the venue setup checklist.
--
-- Client website brief (4 Oct 2026), sections 2 and 3:
--   * Personal account: name, available username, photo, short bio, city, optional socials.
--     Existing app users keep the same identity; nobody registers twice.
--   * Business account (Venue Owner or Event Organizer) on the SAME login, built on the
--     organizations and memberships from 20261006120000_tenancy_foundation.sql.
--   * Verification is a visible state machine: not_submitted -> under_review ->
--     more_information_needed <-> under_review -> verified. A CMS admin decides.
--   * Verification and setup readiness are SEPARATE: a verified business can still have
--     an unfinished floor plan, and an unverified one can keep drafting its setup.
--   * Existing venues are searched before a new one is created; a request for a venue that
--     already exists is a CLAIM that a human reviews. It never replaces an owner silently.
--
-- Additive only. Functions use plain CREATE (never CREATE OR REPLACE) so a same-named
-- function that already exists in the live database makes this fail instead of being
-- overwritten. Legal review of the verification documents is out of scope (client note);
-- this stores the product state only.

-- ---------------------------------------------------------------------------
-- Pre-flight: profiles is shared with the customer app and is NOT defined by any
-- migration in this repo. Stop if production already has columns with these names
-- instead of guessing what they contain.
-- ---------------------------------------------------------------------------
do $$
declare c text;
begin
  if to_regclass('public.profiles') is null then
    raise exception 'public.profiles does not exist; this migration extends the shared profiles table';
  end if;
  foreach c in array array['username', 'bio', 'city', 'social_links', 'profile_completed_at'] loop
    if exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'profiles' and column_name = c) then
      raise exception 'public.profiles.% already exists; review it before applying this migration', c;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Personal profile
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column username text,
  add column bio text,
  add column city text,
  add column social_links jsonb not null default '{}'::jsonb,
  add column profile_completed_at timestamptz;

alter table public.profiles
  add constraint profiles_username_format check (username is null or username ~ '^[a-z0-9._]{3,30}$'),
  add constraint profiles_bio_length check (bio is null or length(bio) <= 280),
  add constraint profiles_social_links_object check (jsonb_typeof(social_links) = 'object');

create unique index profiles_username_unique on public.profiles (username) where username is not null;

-- Keeps only known social keys with short, non-empty text values. Internal helper.
create function public.clean_social_links(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_out jsonb := '{}'::jsonb;
  v_key text;
  v_val text;
begin
  if p is null then return v_out; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'social links must be an object'; end if;
  for v_key in select jsonb_object_keys(p) loop
    if v_key not in ('instagram', 'tiktok', 'x', 'facebook', 'youtube', 'spotify', 'website') then
      raise exception 'unknown social link: %', v_key;
    end if;
    if jsonb_typeof(p -> v_key) <> 'string' then raise exception 'social link % must be text', v_key; end if;
    v_val := trim(p ->> v_key);
    if length(v_val) > 200 then raise exception 'social link % is too long', v_key; end if;
    if v_val <> '' then v_out := v_out || jsonb_build_object(v_key, v_val); end if;
  end loop;
  return v_out;
end;
$$;

-- "Is this username free?" for the profile form. Signed-in users only, so it cannot be
-- used to enumerate usernames anonymously. Your own current username counts as free.
create function public.username_available(p_username text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v text := lower(trim(coalesce(p_username, '')));
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if v !~ '^[a-z0-9._]{3,30}$' then return false; end if;
  if v in ('admin', 'administrator', 'support', 'help', 'staff', 'bottlesup', 'official', 'root', 'system', 'moderator') then
    return false;
  end if;
  return not exists (select 1 from public.profiles p where p.username = v and p.id <> auth.uid());
end;
$$;

-- Creates or completes the caller's own profile. The first onboarding task for a new
-- account; an existing app user finishing a partial profile uses the same call.
-- Never touches phone, age or verified, which the apps own.
create function public.save_my_profile(
  p_name text,
  p_username text,
  p_city text,
  p_bio text default null,
  p_social jsonb default '{}'::jsonb,
  p_avatar_url text default null
)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := trim(coalesce(p_name, ''));
  v_user text := lower(trim(coalesce(p_username, '')));
  v_city text := trim(coalesce(p_city, ''));
  v_bio text := nullif(trim(coalesce(p_bio, '')), '');
  v_avatar text := nullif(trim(coalesce(p_avatar_url, '')), '');
  v_row public.profiles;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if length(v_name) = 0 or length(v_name) > 100 then raise exception 'name is required (100 characters at most)'; end if;
  if length(v_city) = 0 or length(v_city) > 80 then raise exception 'city is required (80 characters at most)'; end if;
  if v_bio is not null and length(v_bio) > 280 then raise exception 'bio must be 280 characters or fewer'; end if;
  if v_avatar is not null and (v_avatar !~ '^https://' or length(v_avatar) > 500) then
    raise exception 'photo must be an https link';
  end if;
  if not public.username_available(v_user) then raise exception 'username is not available'; end if;

  begin
    insert into public.profiles (id, name, email, username, city, bio, social_links, avatar_url, profile_completed_at)
    values (v_uid, v_name, lower(coalesce(auth.email(), '')), v_user, v_city, v_bio,
            public.clean_social_links(p_social), v_avatar, now())
    on conflict (id) do update set
      name = excluded.name,
      username = excluded.username,
      city = excluded.city,
      bio = excluded.bio,
      social_links = excluded.social_links,
      avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url),
      profile_completed_at = coalesce(public.profiles.profile_completed_at, now())
    returning * into v_row;
  exception when unique_violation then
    -- Someone took it between the availability check and the write.
    raise exception 'username is not available';
  end;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Business details and verification
-- ---------------------------------------------------------------------------
create table public.site_business_profiles (
  org_id uuid primary key references public.site_organizations (id) on delete cascade,
  legal_name text,
  description text,
  logo_url text,
  representative_name text,
  representative_role text,
  representative_phone text,
  contact_email text,
  contact_phone text,
  address text,
  city text,
  website text,
  social_links jsonb not null default '{}'::jsonb,
  representative_confirmed_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint site_business_social_object check (jsonb_typeof(social_links) = 'object')
);

create trigger site_business_profiles_set_updated_at
  before update on public.site_business_profiles
  for each row execute function public.set_updated_at();

create table public.site_verifications (
  org_id uuid primary key references public.site_organizations (id) on delete cascade,
  state text not null default 'not_submitted'
    check (state in ('not_submitted', 'under_review', 'more_information_needed', 'verified')),
  -- What the reviewer needs, shown to the business while state = more_information_needed.
  request_message text,
  submission_count int not null default 0,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users (id),
  updated_at timestamptz not null default now()
);

create trigger site_verifications_set_updated_at
  before update on public.site_verifications
  for each row execute function public.set_updated_at();

-- Every state change, with who made it. Corrections are new rows, never edits.
create table public.site_verification_events (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.site_organizations (id) on delete cascade,
  from_state text not null,
  to_state text not null,
  actor uuid references auth.users (id),
  message text,
  created_at timestamptz not null default now()
);
create index site_verification_events_org_idx on public.site_verification_events (org_id, created_at);

-- A business asking to own a venue that already exists. Defined here (before the functions
-- that count claims) because SQL-language functions check their tables when created.
create table public.site_venue_claims (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.site_organizations (id) on delete cascade,
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  requested_by uuid not null references auth.users (id),
  message text check (message is null or length(message) <= 500),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  review_note text,
  reviewed_by uuid references auth.users (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index site_venue_claims_one_pending on public.site_venue_claims (org_id, venue_id) where status = 'pending';
create index site_venue_claims_venue_idx on public.site_venue_claims (venue_id);

-- Every organization starts with an empty details row and a not_submitted verification.
create function public.site_org_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.site_business_profiles (org_id) values (new.id);
  insert into public.site_verifications (org_id) values (new.id);
  return new;
end;
$$;

create trigger site_organizations_after_insert
  after insert on public.site_organizations
  for each row execute function public.site_org_after_insert();

-- What is still missing before the business can be submitted, as stable keys the page maps
-- to messages and to the field to fix. Empty array = ready to submit.
create function public.verification_missing(p_org uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org public.site_organizations;
  b public.site_business_profiles;
  m text[] := '{}';
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not (public.is_org_member(p_org, array['owner', 'organizer']) or public.is_cms_admin()) then
    raise exception 'not allowed';
  end if;
  select * into v_org from public.site_organizations where id = p_org;
  select * into b from public.site_business_profiles where org_id = p_org;

  if coalesce(trim(b.legal_name), '') = '' then m := array_append(m, 'legal_name'); end if;
  if coalesce(trim(b.representative_name), '') = '' then m := array_append(m, 'representative_name'); end if;
  if coalesce(trim(b.representative_phone), '') = '' then m := array_append(m, 'representative_phone'); end if;
  if coalesce(trim(b.contact_email), '') = '' then m := array_append(m, 'contact_email'); end if;
  if coalesce(trim(b.address), '') = '' then m := array_append(m, 'address'); end if;
  if b.representative_confirmed_at is null then m := array_append(m, 'representative_confirmed'); end if;

  if v_org.kind = 'organizer' then
    if coalesce(trim(b.description), '') = '' then m := array_append(m, 'description'); end if;
  else
    -- A venue owner needs at least one venue added or claimed (a pending claim counts).
    if not exists (select 1 from public.site_venues v where v.org_id = p_org)
       and not exists (select 1 from public.site_venue_claims c where c.org_id = p_org and c.status = 'pending') then
      m := array_append(m, 'venue');
    end if;
  end if;
  return m;
end;
$$;

-- Saves a draft of the business details. Owners and organizers only.
-- While under review or verified the identity details are locked (changing them would
-- change what was reviewed); the public-facing ones stay editable. Unknown keys are an
-- error, not silently dropped, so a typo in the app shows up immediately.
create function public.save_business_details(p_org uuid, p_details jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state text;
  v_key text;
  v_locked text[] := array['legal_name', 'representative_name', 'representative_role', 'representative_phone',
                           'contact_email', 'contact_phone', 'address', 'city', 'representative_confirmed'];
  v_open text[] := array['description', 'logo_url', 'website', 'social_links'];
  v_email text;
  v_phone text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.is_org_member(p_org, array['owner', 'organizer']) then raise exception 'not allowed'; end if;
  if p_details is null or jsonb_typeof(p_details) <> 'object' then raise exception 'details must be an object'; end if;

  select state into v_state from public.site_verifications where org_id = p_org;

  for v_key in select jsonb_object_keys(p_details) loop
    if not (v_key = any (v_locked) or v_key = any (v_open)) then
      raise exception 'unknown field: %', v_key;
    end if;
    if v_key = any (v_locked) and v_state in ('under_review', 'verified') then
      raise exception 'details are locked while %; field: %', replace(v_state, '_', ' '), v_key;
    end if;
  end loop;

  v_email := lower(nullif(trim(p_details ->> 'contact_email'), ''));
  if p_details ? 'contact_email' and v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'contact email is not valid';
  end if;
  v_phone := nullif(trim(p_details ->> 'representative_phone'), '');
  if p_details ? 'representative_phone' and v_phone is not null and v_phone !~ '^\+?[0-9 ().-]{7,20}$' then
    raise exception 'representative phone is not valid';
  end if;
  if p_details ? 'contact_phone' and nullif(trim(p_details ->> 'contact_phone'), '') is not null
     and trim(p_details ->> 'contact_phone') !~ '^\+?[0-9 ().-]{7,20}$' then
    raise exception 'contact phone is not valid';
  end if;
  if p_details ? 'website' and nullif(trim(p_details ->> 'website'), '') is not null
     and (trim(p_details ->> 'website') !~ '^https?://[^[:space:]]+$' or length(trim(p_details ->> 'website')) > 300) then
    raise exception 'website must start with http:// or https://';
  end if;
  if p_details ? 'logo_url' and nullif(trim(p_details ->> 'logo_url'), '') is not null
     and (trim(p_details ->> 'logo_url') !~ '^https://[^[:space:]]+$' or length(trim(p_details ->> 'logo_url')) > 500) then
    raise exception 'logo must be an https link';
  end if;
  if p_details ? 'description' and length(coalesce(p_details ->> 'description', '')) > 2000 then
    raise exception 'description must be 2000 characters or fewer';
  end if;
  if p_details ? 'legal_name' and length(coalesce(p_details ->> 'legal_name', '')) > 200 then
    raise exception 'legal name is too long';
  end if;
  if p_details ? 'address' and length(coalesce(p_details ->> 'address', '')) > 300 then
    raise exception 'address is too long';
  end if;

  update public.site_business_profiles b set
    legal_name = case when p_details ? 'legal_name' then nullif(trim(p_details ->> 'legal_name'), '') else b.legal_name end,
    description = case when p_details ? 'description' then nullif(trim(p_details ->> 'description'), '') else b.description end,
    logo_url = case when p_details ? 'logo_url' then nullif(trim(p_details ->> 'logo_url'), '') else b.logo_url end,
    representative_name = case when p_details ? 'representative_name' then nullif(trim(p_details ->> 'representative_name'), '') else b.representative_name end,
    representative_role = case when p_details ? 'representative_role' then nullif(trim(p_details ->> 'representative_role'), '') else b.representative_role end,
    representative_phone = case when p_details ? 'representative_phone' then v_phone else b.representative_phone end,
    contact_email = case when p_details ? 'contact_email' then v_email else b.contact_email end,
    contact_phone = case when p_details ? 'contact_phone' then nullif(trim(p_details ->> 'contact_phone'), '') else b.contact_phone end,
    address = case when p_details ? 'address' then nullif(trim(p_details ->> 'address'), '') else b.address end,
    city = case when p_details ? 'city' then nullif(trim(p_details ->> 'city'), '') else b.city end,
    website = case when p_details ? 'website' then nullif(trim(p_details ->> 'website'), '') else b.website end,
    social_links = case when p_details ? 'social_links' then public.clean_social_links(p_details -> 'social_links') else b.social_links end,
    representative_confirmed_at = case
      when p_details ? 'representative_confirmed' then
        case when (p_details ->> 'representative_confirmed')::boolean then coalesce(b.representative_confirmed_at, now()) else null end
      else b.representative_confirmed_at end
  where b.org_id = p_org;
end;
$$;

-- Submits for review. Refuses an incomplete submission and says exactly what is missing.
create function public.submit_verification(p_org uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state text;
  v_missing text[];
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.is_org_member(p_org, array['owner', 'organizer']) then raise exception 'not allowed'; end if;

  select state into v_state from public.site_verifications where org_id = p_org for update;
  if v_state = 'under_review' then raise exception 'already under review'; end if;
  if v_state = 'verified' then raise exception 'already verified'; end if;

  v_missing := public.verification_missing(p_org);
  if cardinality(v_missing) > 0 then
    raise exception 'incomplete' using detail = array_to_string(v_missing, ',');
  end if;

  update public.site_verifications set
    state = 'under_review',
    submitted_at = now(),
    submission_count = submission_count + 1,
    request_message = null
  where org_id = p_org;
  insert into public.site_verification_events (org_id, from_state, to_state, actor)
    values (p_org, v_state, 'under_review', auth.uid());
  return 'under_review';
end;
$$;

-- A CMS admin's decision. 'verify' or 'request_info' (which must say what is needed).
create function public.review_verification(p_org uuid, p_decision text, p_message text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state text;
  v_new text;
  v_msg text := nullif(trim(coalesce(p_message, '')), '');
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  if p_decision not in ('verify', 'request_info') then raise exception 'invalid decision'; end if;

  select state into v_state from public.site_verifications where org_id = p_org for update;
  if v_state is null then raise exception 'business not found'; end if;
  if v_state <> 'under_review' then raise exception 'only a business under review can be reviewed'; end if;
  if p_decision = 'request_info' and (v_msg is null or length(v_msg) < 3) then
    raise exception 'say what information is needed';
  end if;

  v_new := case p_decision when 'verify' then 'verified' else 'more_information_needed' end;
  update public.site_verifications set
    state = v_new,
    request_message = case when v_new = 'more_information_needed' then v_msg else null end,
    reviewed_at = now(),
    reviewed_by = auth.uid()
  where org_id = p_org;
  insert into public.site_verification_events (org_id, from_state, to_state, actor, message)
    values (p_org, v_state, v_new, auth.uid(), v_msg);
  return v_new;
end;
$$;

-- The caller's businesses (owner / organizer roles) with where each one stands.
create function public.my_businesses()
returns table (
  org_id uuid, org_name text, org_kind text, role text,
  verification_state text, request_message text, submitted_at timestamptz,
  missing text[], venue_count int, pending_claims int
)
language sql
stable
security definer
set search_path = public
as $$
  select o.id, o.name, o.kind, m.role,
         v.state, v.request_message, v.submitted_at,
         public.verification_missing(o.id),
         (select count(*)::int from public.site_venues sv where sv.org_id = o.id),
         (select count(*)::int from public.site_venue_claims c where c.org_id = o.id and c.status = 'pending')
  from public.active_memberships() m
  join public.site_organizations o on o.id = m.org_id
  join public.site_verifications v on v.org_id = o.id
  where m.role in ('owner', 'organizer')
  order by o.name
$$;

-- ---------------------------------------------------------------------------
-- 3. Finding and claiming an existing venue
-- ---------------------------------------------------------------------------

-- Look before creating a duplicate listing. Returns only what is needed to recognise a
-- venue (no gallery, no internals), at most 20 rows, and a query of 2+ characters.
create function public.search_venues(p_query text)
returns table (venue_id uuid, name text, address text, is_claimed boolean, claimed_by_you boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := trim(coalesce(p_query, ''));
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if length(v_q) < 2 then return; end if;
  -- escape LIKE wildcards in the visitor's text
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  return query
    select v.id, v.name, v.address, v.org_id is not null,
           v.org_id is not null and public.is_org_member(v.org_id, array['owner'])
    from public.site_venues v
    where v.name ilike '%' || v_q || '%' or coalesce(v.address, '') ilike '%' || v_q || '%'
    order by v.name
    limit 20;
end;
$$;

create function public.request_venue_claim(p_org uuid, p_venue uuid, p_message text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.site_organizations o where o.id = p_org and o.kind = 'venue_owner')
     or not public.is_org_member(p_org, array['owner']) then
    raise exception 'not allowed';
  end if;
  select org_id into v_owner from public.site_venues where id = p_venue;
  if not found then raise exception 'venue not found'; end if;
  if v_owner = p_org then raise exception 'this venue already belongs to your business'; end if;
  if length(coalesce(p_message, '')) > 500 then raise exception 'message must be 500 characters or fewer'; end if;

  begin
    insert into public.site_venue_claims (org_id, venue_id, requested_by, message)
      values (p_org, p_venue, auth.uid(), nullif(trim(coalesce(p_message, '')), ''))
      returning id into v_id;
  exception when unique_violation then
    raise exception 'you already have a pending request for this venue';
  end;
  return v_id;
end;
$$;

-- A CMS admin approves or rejects. Approving assigns the venue; any other pending
-- requests for it are closed so they do not linger.
create function public.review_venue_claim(p_claim uuid, p_approve boolean, p_note text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.site_venue_claims;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  select * into c from public.site_venue_claims where id = p_claim for update;
  if not found then raise exception 'request not found'; end if;
  if c.status <> 'pending' then raise exception 'this request was already reviewed'; end if;
  if not p_approve and (v_note is null or length(v_note) < 3) then
    raise exception 'say why the request is rejected';
  end if;

  update public.site_venue_claims set
    status = case when p_approve then 'approved' else 'rejected' end,
    review_note = v_note, reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_claim;

  if p_approve then
    update public.site_venues set org_id = c.org_id where id = c.venue_id;
    update public.site_venue_claims set
      status = 'rejected', review_note = 'Venue was assigned to another business',
      reviewed_by = auth.uid(), reviewed_at = now()
    where venue_id = c.venue_id and status = 'pending' and id <> p_claim;
  end if;
  return case when p_approve then 'approved' else 'rejected' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Venue profile and setup checklist
-- ---------------------------------------------------------------------------
-- Owners and managers edit the public profile of a venue they can reach. Only these
-- fields: never status (publishing), slug or the owning organization.
create function public.update_venue_profile(p_venue uuid, p_details jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_gallery text[];
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if p_details is null or jsonb_typeof(p_details) <> 'object' then raise exception 'details must be an object'; end if;

  for v_key in select jsonb_object_keys(p_details) loop
    if v_key not in ('name', 'description', 'address', 'cover_image_url', 'gallery') then
      raise exception 'unknown field: %', v_key;
    end if;
  end loop;

  if p_details ? 'name' and (length(trim(coalesce(p_details ->> 'name', ''))) = 0 or length(p_details ->> 'name') > 120) then
    raise exception 'name is required (120 characters at most)';
  end if;
  if p_details ? 'description' and length(coalesce(p_details ->> 'description', '')) > 4000 then
    raise exception 'description must be 4000 characters or fewer';
  end if;
  if p_details ? 'address' and length(coalesce(p_details ->> 'address', '')) > 300 then
    raise exception 'address is too long';
  end if;
  if p_details ? 'cover_image_url' and nullif(trim(p_details ->> 'cover_image_url'), '') is not null
     and (trim(p_details ->> 'cover_image_url') !~ '^https://[^[:space:]]+$' or length(trim(p_details ->> 'cover_image_url')) > 500) then
    raise exception 'cover image must be an https link';
  end if;
  if p_details ? 'gallery' then
    if jsonb_typeof(p_details -> 'gallery') <> 'array' then raise exception 'gallery must be a list'; end if;
    if jsonb_array_length(p_details -> 'gallery') > 20 then raise exception 'gallery can hold 20 images at most'; end if;
    select coalesce(array_agg(x), '{}') into v_gallery from jsonb_array_elements_text(p_details -> 'gallery') x;
    if exists (select 1 from unnest(v_gallery) g where g !~ '^https://[^[:space:]]+$' or length(g) > 500) then
      raise exception 'gallery images must be https links';
    end if;
  end if;

  update public.site_venues v set
    name = case when p_details ? 'name' then trim(p_details ->> 'name') else v.name end,
    description = case when p_details ? 'description' then nullif(trim(p_details ->> 'description'), '') else v.description end,
    address = case when p_details ? 'address' then nullif(trim(p_details ->> 'address'), '') else v.address end,
    cover_image_url = case when p_details ? 'cover_image_url' then nullif(trim(p_details ->> 'cover_image_url'), '') else v.cover_image_url end,
    gallery = case when p_details ? 'gallery' then v_gallery else v.gallery end,
    updated_at = now()
  where v.id = p_venue;
  return p_venue;
end;
$$;

-- The setup checklist, computed from what actually exists. 'todo' steps carry what is
-- missing; 'unavailable' steps are not modelled yet and never count toward readiness.
-- Readiness is deliberately independent of verification state.
create function public.venue_setup_status(p_venue uuid)
returns table (step text, status text, required boolean, detail text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.site_venues;
  n int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  select * into v from public.site_venues where id = p_venue;

  step := 'profile'; required := true;
  if coalesce(trim(v.description), '') <> '' and coalesce(trim(v.address), '') <> '' and coalesce(trim(v.cover_image_url), '') <> '' then
    status := 'done'; detail := null;
  else
    status := 'todo';
    detail := concat_ws(', ',
      case when coalesce(trim(v.description), '') = '' then 'description' end,
      case when coalesce(trim(v.address), '') = '' then 'address' end,
      case when coalesce(trim(v.cover_image_url), '') = '' then 'cover image' end);
  end if;
  return next;

  step := 'floor_plan'; required := true;
  select count(*) into n from public.site_venue_floors f where f.venue_id = p_venue;
  status := case when n > 0 then 'done' else 'todo' end; detail := case when n = 0 then 'add a floor plan image' end;
  return next;

  step := 'tables'; required := true;
  select count(*) into n from public.site_table_types t where t.venue_id = p_venue;
  status := case when n > 0 then 'done' else 'todo' end; detail := case when n = 0 then 'add a table type with capacity, deposit and minimum spend' end;
  return next;

  step := 'bottles'; required := true;
  select count(*) into n from public.site_bottles b where b.venue_id = p_venue;
  status := case when n > 0 then 'done' else 'todo' end; detail := case when n = 0 then 'add bottles to the menu' end;
  return next;

  step := 'booking_rules'; required := true;
  select count(*) into n from public.site_venue_time_slots s where s.venue_id = p_venue;
  status := case when n > 0 then 'done' else 'todo' end; detail := case when n = 0 then 'choose the days and arrival times you accept bookings' end;
  return next;

  step := 'team'; required := false;
  select count(*) into n from public.site_memberships m
    where m.venue_id = p_venue and m.status = 'active';
  if n = 0 then
    select count(*) into n from public.site_invitations i where i.venue_id = p_venue and i.status = 'pending' and i.expires_at > now();
  end if;
  status := case when n > 0 then 'done' else 'todo' end; detail := case when n = 0 then 'invite a manager or staff' end;
  return next;

  -- Not modelled yet: shown honestly, never counted.
  step := 'payments'; required := false; status := 'unavailable'; detail := 'payment configuration is not available yet';
  return next;
  step := 'notifications'; required := false; status := 'unavailable'; detail := 'notifications and report recipients are not available yet';
  return next;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4b. Read models for the claim list and the admin review screens
-- ---------------------------------------------------------------------------
-- A business's own claim requests, with the venue name (the claimer cannot read the venue row).
create function public.list_venue_claims(p_org uuid)
returns table (claim_id uuid, venue_id uuid, venue_name text, status text, review_note text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not (public.is_org_member(p_org, array['owner']) or public.is_cms_admin()) then raise exception 'not allowed'; end if;
  return query
    select c.id, c.venue_id, v.name, c.status, c.review_note, c.created_at
    from public.site_venue_claims c
    join public.site_venues v on v.id = c.venue_id
    where c.org_id = p_org
    order by c.created_at desc;
end;
$$;

-- Businesses waiting for a decision, oldest first, with what the reviewer needs to decide.
create function public.admin_verification_queue()
returns table (
  org_id uuid, org_name text, org_kind text, state text, submitted_at timestamptz, submission_count int,
  legal_name text, representative_name text, representative_phone text, contact_email text,
  address text, city text, website text, description text, owner_email text, venue_count int
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  return query
    select o.id, o.name, o.kind, v.state, v.submitted_at, v.submission_count,
           b.legal_name, b.representative_name, b.representative_phone, b.contact_email,
           b.address, b.city, b.website, b.description,
           (select u.email::text from auth.users u where u.id = o.created_by),
           (select count(*)::int from public.site_venues sv where sv.org_id = o.id)
    from public.site_verifications v
    join public.site_organizations o on o.id = v.org_id
    join public.site_business_profiles b on b.org_id = v.org_id
    where v.state = 'under_review'
    order by v.submitted_at, o.name;
end;
$$;

-- Pending ownership requests, with the venue's current owner so a reviewer never replaces one blindly.
create function public.admin_venue_claims()
returns table (
  claim_id uuid, org_id uuid, org_name text, venue_id uuid, venue_name text, venue_address text,
  current_owner_org uuid, current_owner_name text, message text, created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  return query
    select c.id, c.org_id, o.name, c.venue_id, v.name, v.address,
           v.org_id, (select co.name from public.site_organizations co where co.id = v.org_id),
           c.message, c.created_at
    from public.site_venue_claims c
    join public.site_organizations o on o.id = c.org_id
    join public.site_venues v on v.id = c.venue_id
    where c.status = 'pending'
    order by c.created_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Storage: business and venue images
-- ---------------------------------------------------------------------------
-- Logos and venue photos appear on public pages, so reads are public. Writes are only allowed
-- inside the folder of an organization you belong to: <organization id>/<file>. Owners and
-- organizers may replace or delete; a manager may only ADD files, so one manager cannot
-- overwrite another venue's image. Size and type limits are enforced by the bucket itself.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('business-media', 'business-media', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- The organization a file path belongs to, or null when the first folder is not an organization id.
-- Parsed with a pattern first so a malformed path is simply "no organization", never an error.
create function public.business_media_org(p_name text)
returns uuid
language sql
immutable
set search_path = public
as $$
  select case when split_part(p_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then split_part(p_name, '/', 1)::uuid end
$$;

create policy "public read business media" on storage.objects
  for select using (bucket_id = 'business-media');
create policy "members add business media" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'business-media'
              and public.business_media_org(name) is not null
              and public.is_org_member(public.business_media_org(name), array['owner', 'organizer', 'manager']));
create policy "owners replace business media" on storage.objects
  for update to authenticated
  using (bucket_id = 'business-media'
         and public.is_org_member(public.business_media_org(name), array['owner', 'organizer']));
create policy "owners delete business media" on storage.objects
  for delete to authenticated
  using (bucket_id = 'business-media'
         and public.is_org_member(public.business_media_org(name), array['owner', 'organizer']));

-- ---------------------------------------------------------------------------
-- Row level security, grants
-- ---------------------------------------------------------------------------
alter table public.site_business_profiles enable row level security;
alter table public.site_verifications enable row level security;
alter table public.site_verification_events enable row level security;
alter table public.site_venue_claims enable row level security;

create policy "business members read their details" on public.site_business_profiles
  for select to authenticated using (public.is_org_member(org_id, array['owner', 'organizer']) or public.is_cms_admin());
create policy "business members read their verification" on public.site_verifications
  for select to authenticated using (public.is_org_member(org_id, array['owner', 'organizer']) or public.is_cms_admin());
create policy "business members read their verification history" on public.site_verification_events
  for select to authenticated using (public.is_org_member(org_id, array['owner', 'organizer']) or public.is_cms_admin());
create policy "owners read their venue requests" on public.site_venue_claims
  for select to authenticated using (public.is_org_member(org_id, array['owner']) or public.is_cms_admin());

-- No direct writes from the app: every change goes through the functions above.
revoke all on public.site_business_profiles, public.site_verifications,
              public.site_verification_events, public.site_venue_claims from anon, authenticated;
grant select on public.site_business_profiles, public.site_verifications,
                public.site_verification_events, public.site_venue_claims to authenticated;

revoke all on function
  public.clean_social_links(jsonb), public.username_available(text),
  public.save_my_profile(text, text, text, text, jsonb, text),
  public.site_org_after_insert(), public.verification_missing(uuid),
  public.save_business_details(uuid, jsonb), public.submit_verification(uuid),
  public.review_verification(uuid, text, text), public.my_businesses(),
  public.search_venues(text), public.request_venue_claim(uuid, uuid, text),
  public.review_venue_claim(uuid, boolean, text), public.update_venue_profile(uuid, jsonb),
  public.venue_setup_status(uuid), public.list_venue_claims(uuid),
  public.admin_verification_queue(), public.admin_venue_claims()
  from public, anon;
grant execute on function
  public.username_available(text), public.save_my_profile(text, text, text, text, jsonb, text),
  public.verification_missing(uuid), public.save_business_details(uuid, jsonb),
  public.submit_verification(uuid), public.review_verification(uuid, text, text),
  public.my_businesses(), public.search_venues(text), public.request_venue_claim(uuid, uuid, text),
  public.review_venue_claim(uuid, boolean, text), public.update_venue_profile(uuid, jsonb),
  public.venue_setup_status(uuid), public.list_venue_claims(uuid),
  public.admin_verification_queue(), public.admin_venue_claims()
  to authenticated, service_role;
