-- Venue VIP list (client Phase 2 brief, section 21).
--
-- "Profile: name/contact, tier, active/expired status, applicable perks, relevant service preferences, assigned contact and authorized
-- venue-specific visit history. Invitation triggers customer notification and a live-checkable credential. VIP status does not automatically
-- issue event admission. Server sees service perks only; organizer does not automatically receive the venue's full VIP database. Record
-- benefit redemption to prevent repeated use beyond limits."
--
--   * The manager and owner of a club keep its VIP list: contact, tier, validity, a host (an active member of staff), service preferences
--     and private notes, and a list of perks, each with a kind (entry, service or discount) and a limit (per night or in total).
--   * Staff look a guest up by name (3+ letters) or by the credential code: a SERVER sees service perks and service preferences only, club DOOR
--     staff entry perks only; neither sees contact details, notes, history or anyone's whole list. Organizers and event-only door staff see
--     nothing (no function here admits them).
--   * Redeeming a perk records who, when and which night. A perk with a limit cannot be redeemed past it, even by two people at once.
--     An ended or expired membership redeems nothing. A benefit is a record: it never admits anyone to an event or changes a bill by itself.
--   * The invitation is only QUEUED for a sender (site_outbox, kind vip_invite); the app says "queued", never "sent".
--
-- Plain CREATE, never CREATE OR REPLACE. Needs the tenancy, venue setup (setup_* helpers) and seating (outbox) migrations.

-- ---------------------------------------------------------------------------
-- 1. Tables (reached only through the functions below)
-- ---------------------------------------------------------------------------
create table public.site_vip_members (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 2 and 80),
  email text check (email is null or (char_length(email) <= 200 and email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  phone text check (phone is null or char_length(phone) between 5 and 30),
  tier text not null default 'VIP' check (char_length(btrim(tier)) between 2 and 40),
  valid_from date not null default current_date,
  valid_until date,
  host_user uuid references auth.users (id) on delete set null,
  preferences text check (preferences is null or char_length(preferences) <= 300),
  notes text check (notes is null or char_length(notes) <= 500),
  credential_code text not null,
  invited_at timestamptz,
  ended_at timestamptz,
  ended_by uuid references auth.users (id),
  ended_reason text check (ended_reason is null or char_length(ended_reason) <= 300),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default clock_timestamp(),
  constraint site_vip_contact check (email is not null or phone is not null),
  constraint site_vip_dates check (valid_until is null or valid_until >= valid_from),
  constraint site_vip_ended_together check ((ended_at is null) = (ended_by is null))
);
create unique index site_vip_members_code_idx on public.site_vip_members (credential_code);
create index site_vip_members_venue_idx on public.site_vip_members (venue_id, lower(name));

create table public.site_vip_perks (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.site_vip_members (id) on delete cascade,
  kind text not null check (kind in ('entry', 'service', 'discount')),
  label text not null check (char_length(btrim(label)) between 2 and 80),
  max_uses int check (max_uses is null or max_uses between 1 and 1000),
  period text not null default 'night' check (period in ('night', 'total')),
  active boolean not null default true,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default clock_timestamp()
);
create index site_vip_perks_member_idx on public.site_vip_perks (member_id);

create table public.site_vip_redemptions (
  id uuid primary key default gen_random_uuid(),
  perk_id uuid not null references public.site_vip_perks (id) on delete cascade,
  member_id uuid not null references public.site_vip_members (id) on delete cascade,
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  business_night date not null,
  redeemed_by uuid not null references auth.users (id),
  redeemed_at timestamptz not null default clock_timestamp(),
  note text check (note is null or char_length(note) <= 200)
);
create index site_vip_redemptions_perk_idx on public.site_vip_redemptions (perk_id, business_night);
create index site_vip_redemptions_member_idx on public.site_vip_redemptions (member_id, redeemed_at desc);

alter table public.site_vip_members enable row level security;
alter table public.site_vip_perks enable row level security;
alter table public.site_vip_redemptions enable row level security;
revoke all on table public.site_vip_members, public.site_vip_perks, public.site_vip_redemptions from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
-- active, expired, upcoming or ended, for one night.
create function public.vip_status(m public.site_vip_members, p_night date)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when m.ended_at is not null then 'ended'
    when m.valid_from > p_night then 'upcoming'
    when m.valid_until is not null and m.valid_until < p_night then 'expired'
    else 'active'
  end
$$;

-- A date from a details object (text 'YYYY-MM-DD'), or null when missing or JSON null.
create function public.vip_date(p jsonb, p_key text, p_label text)
returns date
language plpgsql
immutable
set search_path = public
as $$
declare
  t text := public.setup_text(p, p_key, p_label, 10);
begin
  if t is null then return null; end if;
  if t !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception '% must be a date (YYYY-MM-DD)', p_label; end if;
  begin
    return t::date;
  exception when others then
    raise exception '% must be a real date', p_label;
  end;
end;
$$;

-- A credential code nobody else has: 8 letters and digits.
create function public.vip_new_code()
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  v_code text;
  n int := 0;
begin
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text || n::text), 1, 8));
    exit when not exists (select 1 from public.site_vip_members x where x.credential_code = v_code);
    n := n + 1;
    if n > 20 then raise exception 'could not make a credential code, try again'; end if;
  end loop;
  return v_code;
end;
$$;

revoke all on function public.vip_status(public.site_vip_members, date), public.vip_date(jsonb, text, text), public.vip_new_code() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The list: add, change, end
-- ---------------------------------------------------------------------------
create function public.vip_add(p_venue uuid, p_details jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text; v_email text; v_phone text; v_tier text; v_from date; v_until date; v_pref text; v_notes text;
  v_host uuid;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  perform public.setup_only_keys(p_details, array['name', 'email', 'phone', 'tier', 'valid_from', 'valid_until', 'preferences', 'notes', 'host']);
  v_name := public.setup_text(p_details, 'name', 'name', 80);
  if v_name is null or char_length(v_name) < 2 then raise exception 'enter the guest''s name'; end if;
  v_email := lower(public.setup_text(p_details, 'email', 'email', 200));
  v_phone := public.setup_text(p_details, 'phone', 'phone', 30);
  if v_email is null and v_phone is null then raise exception 'enter an email or a phone number'; end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'that does not look like an email address'; end if;
  if v_phone is not null and char_length(v_phone) < 5 then raise exception 'that phone number is too short'; end if;
  v_tier := coalesce(public.setup_text(p_details, 'tier', 'tier', 40), 'VIP');
  if char_length(v_tier) < 2 then raise exception 'the tier needs at least 2 characters'; end if;
  v_from := coalesce(public.vip_date(p_details, 'valid_from', 'start date'), current_date);
  v_until := public.vip_date(p_details, 'valid_until', 'end date');
  if v_until is not null and v_until < v_from then raise exception 'the end date is before the start date'; end if;
  v_pref := public.setup_text(p_details, 'preferences', 'service preferences', 300);
  v_notes := public.setup_text(p_details, 'notes', 'notes', 500);
  if p_details ? 'host' and jsonb_typeof(p_details -> 'host') = 'string' then
    if (p_details ->> 'host') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'the host has to be someone who works at this club'; end if;
    v_host := (p_details ->> 'host')::uuid;
    if not public.chat_user_at_venue(v_host, p_venue) then raise exception 'the host has to be someone who works at this club'; end if;
  end if;

  insert into public.site_vip_members (venue_id, name, email, phone, tier, valid_from, valid_until, host_user, preferences, notes, credential_code, created_by)
    values (p_venue, v_name, v_email, v_phone, v_tier, v_from, v_until, v_host, v_pref, v_notes, public.vip_new_code(), auth.uid())
    returning id into v_id;
  perform public.desk_log('vip.added', 'site_vip_members', v_id, jsonb_build_object('venue_id', p_venue, 'tier', v_tier));
  return v_id;
end;
$$;

-- Change what is given; a key that is missing is left alone, a JSON null clears an optional one.
create function public.vip_update(p_member uuid, p_details jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.site_vip_members;
  v_email text; v_phone text; v_tier text; v_from date; v_until date; v_host uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into m from public.site_vip_members where id = p_member for update;
  if not found or not public.can_access_venue(m.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  perform public.setup_only_keys(p_details, array['name', 'email', 'phone', 'tier', 'valid_from', 'valid_until', 'preferences', 'notes', 'host']);

  if p_details ? 'name' then
    m.name := public.setup_text(p_details, 'name', 'name', 80);
    if m.name is null or char_length(m.name) < 2 then raise exception 'enter the guest''s name'; end if;
  end if;
  if p_details ? 'email' then m.email := lower(public.setup_text(p_details, 'email', 'email', 200)); end if;
  if p_details ? 'phone' then m.phone := public.setup_text(p_details, 'phone', 'phone', 30); end if;
  if m.email is null and m.phone is null then raise exception 'enter an email or a phone number'; end if;
  if m.email is not null and m.email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'that does not look like an email address'; end if;
  if m.phone is not null and char_length(m.phone) < 5 then raise exception 'that phone number is too short'; end if;
  if p_details ? 'tier' then
    m.tier := coalesce(public.setup_text(p_details, 'tier', 'tier', 40), 'VIP');
    if char_length(m.tier) < 2 then raise exception 'the tier needs at least 2 characters'; end if;
  end if;
  if p_details ? 'valid_from' then m.valid_from := coalesce(public.vip_date(p_details, 'valid_from', 'start date'), m.valid_from); end if;
  if p_details ? 'valid_until' then m.valid_until := public.vip_date(p_details, 'valid_until', 'end date'); end if;
  if m.valid_until is not null and m.valid_until < m.valid_from then raise exception 'the end date is before the start date'; end if;
  if p_details ? 'preferences' then m.preferences := public.setup_text(p_details, 'preferences', 'service preferences', 300); end if;
  if p_details ? 'notes' then m.notes := public.setup_text(p_details, 'notes', 'notes', 500); end if;
  if p_details ? 'host' then
    if jsonb_typeof(p_details -> 'host') = 'string' then
      if (p_details ->> 'host') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'the host has to be someone who works at this club'; end if;
      m.host_user := (p_details ->> 'host')::uuid;
      if not public.chat_user_at_venue(m.host_user, m.venue_id) then raise exception 'the host has to be someone who works at this club'; end if;
    else
      m.host_user := null;
    end if;
  end if;

  update public.site_vip_members
    set name = m.name, email = m.email, phone = m.phone, tier = m.tier, valid_from = m.valid_from, valid_until = m.valid_until,
        host_user = m.host_user, preferences = m.preferences, notes = m.notes
    where id = p_member;
  perform public.desk_log('vip.updated', 'site_vip_members', p_member, jsonb_build_object('venue_id', m.venue_id, 'keys', (select jsonb_agg(k) from jsonb_object_keys(p_details) k)));
end;
$$;

create function public.vip_end(p_member uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.site_vip_members;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into m from public.site_vip_members where id = p_member for update;
  if not found or not public.can_access_venue(m.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if m.ended_at is not null then raise exception 'this membership has already ended'; end if;
  v_reason := btrim(p_reason);
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'say why the membership is ending'; end if;
  if char_length(v_reason) > 300 then raise exception 'keep the reason to 300 characters or fewer'; end if;
  update public.site_vip_members set ended_at = clock_timestamp(), ended_by = auth.uid(), ended_reason = v_reason where id = p_member;
  perform public.desk_log('vip.ended', 'site_vip_members', p_member, jsonb_build_object('venue_id', m.venue_id));
end;
$$;

create function public.vip_reinstate(p_member uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.site_vip_members;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into m from public.site_vip_members where id = p_member for update;
  if not found or not public.can_access_venue(m.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if m.ended_at is null then raise exception 'this membership has not ended'; end if;
  update public.site_vip_members set ended_at = null, ended_by = null, ended_reason = null where id = p_member;
  perform public.desk_log('vip.reinstated', 'site_vip_members', p_member, jsonb_build_object('venue_id', m.venue_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Perks
-- ---------------------------------------------------------------------------
create function public.vip_add_perk(p_member uuid, p_kind text, p_label text, p_max_uses int default null, p_period text default 'night')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.site_vip_members;
  v_label text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into m from public.site_vip_members where id = p_member;
  if not found or not public.can_access_venue(m.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if p_kind is null or p_kind not in ('entry', 'service', 'discount') then raise exception 'choose entry, service or discount'; end if;
  v_label := btrim(p_label);
  if v_label is null or char_length(v_label) < 2 then raise exception 'say what the perk is'; end if;
  if char_length(v_label) > 80 then raise exception 'keep the perk to 80 characters or fewer'; end if;
  if p_max_uses is not null and (p_max_uses < 1 or p_max_uses > 1000) then raise exception 'the limit has to be from 1 to 1000, or none'; end if;
  if p_period is null or p_period not in ('night', 'total') then raise exception 'choose per night or in total'; end if;
  if (select count(*) from public.site_vip_perks x where x.member_id = p_member and x.active) >= 20 then raise exception 'a member can have at most 20 perks'; end if;

  insert into public.site_vip_perks (member_id, kind, label, max_uses, period, created_by) values (p_member, p_kind, v_label, p_max_uses, p_period, auth.uid()) returning id into v_id;
  perform public.desk_log('vip.perk_added', 'site_vip_perks', v_id, jsonb_build_object('venue_id', m.venue_id, 'member_id', p_member, 'kind', p_kind));
  return v_id;
end;
$$;

create function public.vip_end_perk(p_perk uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.site_vip_perks;
  v_venue uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into k from public.site_vip_perks where id = p_perk for update;
  if not found then raise exception 'not allowed'; end if;
  select m.venue_id into v_venue from public.site_vip_members m where m.id = k.member_id;
  if not public.can_access_venue(v_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if not k.active then raise exception 'this perk has already ended'; end if;
  update public.site_vip_perks set active = false where id = p_perk;
  perform public.desk_log('vip.perk_ended', 'site_vip_perks', p_perk, jsonb_build_object('venue_id', v_venue));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The manager's view
-- ---------------------------------------------------------------------------
create function public.vip_list(p_venue uuid, p_search text default null, p_include_ended boolean default false, p_night date default null)
returns table (
  member_id uuid, name text, tier text, status text, valid_until date, host_name text, perks int, last_visit date, invited boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_night date := coalesce(p_night, current_date);
  v_q text := nullif(btrim(p_search), '');
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;

  return query
    select m.id, m.name, m.tier, public.vip_status(m, v_night), m.valid_until,
           case when m.host_user is null then null else coalesce(nullif(btrim(ph.name), ''), 'Staff member') end,
           (select count(*)::int from public.site_vip_perks k where k.member_id = m.id and k.active),
           (select max(r.business_night) from public.site_vip_redemptions r where r.member_id = m.id),
           m.invited_at is not null
    from public.site_vip_members m
    left join public.profiles ph on ph.id = m.host_user
    where m.venue_id = p_venue
      and (p_include_ended or m.ended_at is null)
      and (v_q is null or m.name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%' or m.credential_code = upper(v_q))
    order by lower(m.name), m.id
    limit 300;
end;
$$;

create function public.vip_detail(p_member uuid, p_night date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.site_vip_members;
  v_night date := coalesce(p_night, current_date);
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into m from public.site_vip_members where id = p_member;
  if not found or not public.can_access_venue(m.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;

  return jsonb_build_object(
    'member_id', m.id,
    'name', m.name,
    'email', m.email,
    'phone', m.phone,
    'tier', m.tier,
    'status', public.vip_status(m, v_night),
    'valid_from', m.valid_from,
    'valid_until', m.valid_until,
    'host_id', m.host_user,
    'host_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = m.host_user),
    'preferences', m.preferences,
    'notes', m.notes,
    'credential_code', m.credential_code,
    'invited_at', m.invited_at,
    'ended_at', m.ended_at,
    'ended_reason', m.ended_reason,
    'perks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'perk_id', k.id, 'kind', k.kind, 'label', k.label, 'max_uses', k.max_uses, 'period', k.period, 'active', k.active,
        'used', (select count(*)::int from public.site_vip_redemptions r where r.perk_id = k.id and (k.period = 'total' or r.business_night = v_night))
      ) order by k.created_at, k.id)
      from public.site_vip_perks k where k.member_id = m.id), '[]'::jsonb),
    'visits', coalesce((
      select jsonb_agg(jsonb_build_object(
        'night', x.business_night, 'perk', x.label, 'by_name', x.by_name, 'at', x.redeemed_at, 'note', x.note
      ) order by x.redeemed_at desc)
      from (
        select r.business_night, k.label, coalesce(nullif(btrim(pr.name), ''), 'Staff member') as by_name, r.redeemed_at, r.note
        from public.site_vip_redemptions r
        join public.site_vip_perks k on k.id = r.perk_id
        left join public.profiles pr on pr.id = r.redeemed_by
        where r.member_id = m.id order by r.redeemed_at desc limit 20
      ) x), '[]'::jsonb));
end;
$$;

-- Queue the invitation (a sender outside the database sends it). At most one in ten minutes.
create function public.vip_invite(p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.site_vip_members;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into m from public.site_vip_members where id = p_member for update;
  if not found or not public.can_access_venue(m.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if m.ended_at is not null then raise exception 'this membership has ended'; end if;
  if m.email is null then raise exception 'this guest has no email address to invite'; end if;
  if m.invited_at is not null and m.invited_at > clock_timestamp() - interval '10 minutes' then raise exception 'an invitation was queued a moment ago'; end if;

  perform public.desk_enqueue('vip_invite', m.venue_id, m.id, jsonb_build_object('name', m.name, 'tier', m.tier, 'credential_code', m.credential_code));
  update public.site_vip_members set invited_at = clock_timestamp() where id = p_member;
  perform public.desk_log('vip.invited', 'site_vip_members', p_member, jsonb_build_object('venue_id', m.venue_id));
  return jsonb_build_object('queued', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. At the club: look a guest up, redeem a perk
-- ---------------------------------------------------------------------------
-- Name (3+ letters) or the credential code. A server sees service perks and service preferences only, the door entry perks only; only a
-- manager or owner also sees the contact details and notes. At most 10 guests.
create function public.vip_lookup(p_venue uuid, p_query text, p_night date default null)
returns table (
  member_id uuid, name text, tier text, status text, valid_until date, host_name text, preferences text, email text, phone text, notes text, perks jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_night date := coalesce(p_night, current_date);
  v_q text := btrim(coalesce(p_query, ''));
  v_manager boolean;
  v_server boolean;
  v_door boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null then raise exception 'not allowed'; end if;
  v_manager := public.can_access_venue(p_venue, array['owner', 'manager']);
  v_server := public.can_access_venue(p_venue, array['server']);
  v_door := public.can_access_venue(p_venue, array['door']);
  if not (v_manager or v_server or v_door) then raise exception 'not allowed'; end if;
  if abs(v_night - current_date) > 2 then raise exception 'that is not a current night'; end if;
  if char_length(v_q) < 3 then raise exception 'type at least 3 letters of the name, or the credential code'; end if;

  return query
    select m.id, m.name, m.tier, public.vip_status(m, v_night), m.valid_until,
           case when m.host_user is null then null else coalesce(nullif(btrim(ph.name), ''), 'Staff member') end,
           case when v_manager or v_server then m.preferences end,
           case when v_manager then m.email end,
           case when v_manager then m.phone end,
           case when v_manager then m.notes end,
           case when public.vip_status(m, v_night) <> 'active' then '[]'::jsonb else coalesce((
             select jsonb_agg(jsonb_build_object(
               'perk_id', k.id, 'kind', k.kind, 'label', k.label, 'max_uses', k.max_uses, 'period', k.period,
               'used', (select count(*)::int from public.site_vip_redemptions r where r.perk_id = k.id and (k.period = 'total' or r.business_night = v_night))
             ) order by k.created_at, k.id)
             from public.site_vip_perks k
             where k.member_id = m.id and k.active
               and (v_manager or (v_server and k.kind = 'service') or (v_door and k.kind = 'entry'))), '[]'::jsonb) end
    from public.site_vip_members m
    left join public.profiles ph on ph.id = m.host_user
    where m.venue_id = p_venue
      and (m.name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%' or m.credential_code = upper(v_q))
    order by (m.credential_code = upper(v_q)) desc, lower(m.name), m.id
    limit 10;
end;
$$;

create function public.vip_redeem(p_perk uuid, p_night date default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.site_vip_perks;
  m public.site_vip_members;
  v_night date := coalesce(p_night, current_date);
  v_note text;
  v_ok boolean;
  v_used int;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into k from public.site_vip_perks where id = p_perk for update;
  if not found then raise exception 'not allowed'; end if;
  select * into m from public.site_vip_members where id = k.member_id;
  v_ok := case k.kind
    when 'service' then public.can_access_venue(m.venue_id, array['owner', 'manager', 'server'])
    when 'entry' then public.can_access_venue(m.venue_id, array['owner', 'manager', 'door'])
    else public.can_access_venue(m.venue_id, array['owner', 'manager'])
  end;
  if not v_ok then raise exception 'not allowed'; end if;
  if abs(v_night - current_date) > 2 then raise exception 'that is not a current night'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 200 then raise exception 'keep the note to 200 characters or fewer'; end if;
  if public.vip_status(m, v_night) <> 'active' then raise exception 'this membership is not active (%)', public.vip_status(m, v_night); end if;
  if not k.active then raise exception 'this perk has ended'; end if;

  select count(*)::int into v_used from public.site_vip_redemptions r where r.perk_id = p_perk and (k.period = 'total' or r.business_night = v_night);
  if k.max_uses is not null and v_used >= k.max_uses then
    raise exception 'this benefit has already been used % of % %', v_used, k.max_uses, case when k.period = 'night' then 'tonight' else 'in total' end;
  end if;

  insert into public.site_vip_redemptions (perk_id, member_id, venue_id, business_night, redeemed_by, note)
    values (p_perk, m.id, m.venue_id, v_night, auth.uid(), v_note) returning id into v_id;
  perform public.desk_log('vip.redeemed', 'site_vip_redemptions', v_id, jsonb_build_object('venue_id', m.venue_id, 'member_id', m.id, 'kind', k.kind));
  return jsonb_build_object('redemption_id', v_id, 'used', v_used + 1, 'max_uses', k.max_uses, 'uses_left', case when k.max_uses is null then null else k.max_uses - v_used - 1 end);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.vip_add(uuid, jsonb), public.vip_update(uuid, jsonb), public.vip_end(uuid, text), public.vip_reinstate(uuid),
  public.vip_add_perk(uuid, text, text, int, text), public.vip_end_perk(uuid), public.vip_list(uuid, text, boolean, date), public.vip_detail(uuid, date),
  public.vip_invite(uuid), public.vip_lookup(uuid, text, date), public.vip_redeem(uuid, date, text)
from public, anon;
grant execute on function
  public.vip_add(uuid, jsonb), public.vip_update(uuid, jsonb), public.vip_end(uuid, text), public.vip_reinstate(uuid),
  public.vip_add_perk(uuid, text, text, int, text), public.vip_end_perk(uuid), public.vip_list(uuid, text, boolean, date), public.vip_detail(uuid, date),
  public.vip_invite(uuid), public.vip_lookup(uuid, text, date), public.vip_redeem(uuid, date, text)
to authenticated, service_role;
