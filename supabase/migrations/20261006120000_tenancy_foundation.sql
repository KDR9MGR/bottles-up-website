-- Tenancy foundation: organizations, role memberships, invitations, shifts.
--
-- Client Phase 2 brief, sections 2, 3 and 12: one connected platform where each
-- person sees only the workspace their role allows, with access checked in the
-- database (hiding a button is not enough), temporary staff on expiring
-- invitations, and every membership attributable to the person who granted it.
--
-- Roles:  owner, manager, organizer, server, door, security, verifier
-- Scope:  owner / organizer = whole organization
--         manager           = one venue
--         server, door, security, verifier = one venue OR one event, optionally
--                             limited to a time window and/or a shift
--
-- Who may grant what (enforced in can_invite_role()):
--   owner      -> managers and venue staff, for venues their organization owns
--   manager    -> venue staff for their own venue only (never another manager)
--   organizer  -> door staff for events their organization owns (never venue access)
--   nobody grants owner or organizer by invitation; create_organization() does.
--
-- Additive only. Existing tables, cms_admins and door_staff are untouched and keep
-- working. New tables are prefixed site_ because this Supabase project is shared
-- with the older vendor app, whose schema already uses names like `shifts`.
--
-- Functions use plain CREATE, never CREATE OR REPLACE, on purpose: if the live database
-- already has a function with the same name and arguments (the project is shared and not
-- every object is in a migration), this must fail loudly instead of overwriting it.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.site_organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  kind text not null check (kind in ('venue_owner', 'organizer')),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger site_organizations_set_updated_at
  before update on public.site_organizations
  for each row execute function public.set_updated_at();

-- Which organization owns a venue or an event. Null = platform-owned (existing rows).
alter table public.site_venues add column org_id uuid references public.site_organizations (id) on delete set null;
alter table public.site_events add column org_id uuid references public.site_organizations (id) on delete set null;
create index site_venues_org_id_idx on public.site_venues (org_id);
create index site_events_org_id_idx on public.site_events (org_id);

create table public.site_shifts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  event_id uuid references public.site_events (id) on delete set null,
  name text not null check (length(trim(name)) > 0),
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);
create index site_shifts_venue_id_idx on public.site_shifts (venue_id);

create table public.site_memberships (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.site_organizations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('owner', 'manager', 'organizer', 'server', 'door', 'security', 'verifier')),
  venue_id uuid references public.site_venues (id) on delete cascade,
  event_id uuid references public.site_events (id) on delete cascade,
  shift_id uuid references public.site_shifts (id) on delete cascade,
  access_start_at timestamptz,
  access_end_at timestamptz,
  status text not null default 'active' check (status in ('active', 'revoked')),
  invited_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references auth.users (id),
  constraint site_memberships_window_check
    check (access_end_at is null or access_start_at is null or access_end_at > access_start_at),
  -- A role is only valid with the scope it is meant for.
  constraint site_memberships_role_scope_check check (
    (role in ('owner', 'organizer') and venue_id is null and event_id is null and shift_id is null)
    or (role = 'manager' and venue_id is not null and event_id is null and shift_id is null)
    or (role in ('server', 'door', 'security', 'verifier') and (venue_id is not null or event_id is not null))
  )
);
create index site_memberships_user_id_idx on public.site_memberships (user_id);
create index site_memberships_org_id_idx on public.site_memberships (org_id);
-- The same grant twice must not make two live memberships.
create unique index site_memberships_one_active_per_scope on public.site_memberships (
  org_id, user_id, role,
  coalesce(venue_id, '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(event_id, '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(shift_id, '00000000-0000-0000-0000-000000000000'::uuid)
) where status = 'active';

create table public.site_invitations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.site_organizations (id) on delete cascade,
  email text not null check (email = lower(email)),
  role text not null check (role in ('manager', 'server', 'door', 'security', 'verifier')),
  venue_id uuid references public.site_venues (id) on delete cascade,
  event_id uuid references public.site_events (id) on delete cascade,
  shift_id uuid references public.site_shifts (id) on delete cascade,
  access_start_at timestamptz,
  access_end_at timestamptz,
  -- Only a hash of the link token is stored; the token itself is shown once, to the inviter.
  token_hash bytea not null,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'revoked')),
  expires_at timestamptz not null,
  invited_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  accepted_by uuid references auth.users (id),
  accepted_at timestamptz,
  membership_id uuid references public.site_memberships (id),
  revoked_at timestamptz,
  revoked_by uuid references auth.users (id),
  constraint site_invitations_window_check
    check (access_end_at is null or access_start_at is null or access_end_at > access_start_at)
);
create unique index site_invitations_token_hash_idx on public.site_invitations (token_hash);
create index site_invitations_org_id_idx on public.site_invitations (org_id);

-- ---------------------------------------------------------------------------
-- Permission helpers. SECURITY DEFINER so they read memberships without tripping
-- RLS on the same tables (no policy recursion); they only ever look at the caller.
-- ---------------------------------------------------------------------------

-- The signed-in user's memberships that are valid RIGHT NOW: not revoked, inside
-- their access window, and inside their shift if they have one.
create function public.active_memberships()
returns setof public.site_memberships
language sql
stable
security definer
set search_path = public
as $$
  select m.*
  from public.site_memberships m
  left join public.site_shifts s on s.id = m.shift_id
  where m.user_id = auth.uid()
    and m.status = 'active'
    and (m.access_start_at is null or now() >= m.access_start_at)
    and (m.access_end_at is null or now() <= m.access_end_at)
    and (m.shift_id is null or (now() >= s.starts_at and now() <= s.ends_at))
$$;

create function public.is_org_member(p_org uuid, p_roles text[] default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.active_memberships() m
    where m.org_id = p_org and (p_roles is null or m.role = any (p_roles))
  )
$$;

-- Owners reach every venue their organization owns; everyone else needs a
-- membership scoped to that exact venue.
create function public.can_access_venue(p_venue uuid, p_roles text[] default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.active_memberships() m
    left join public.site_venues v on v.id = p_venue
    where (p_roles is null or m.role = any (p_roles))
      and ((m.role = 'owner' and v.org_id = m.org_id) or m.venue_id = p_venue)
  )
$$;

-- Owners and organizers reach every event their organization owns; event staff
-- need a membership scoped to that exact event.
create function public.can_access_event(p_event uuid, p_roles text[] default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.active_memberships() m
    left join public.site_events e on e.id = p_event
    where (p_roles is null or m.role = any (p_roles))
      and ((m.role in ('owner', 'organizer') and e.org_id = m.org_id) or m.event_id = p_event)
  )
$$;

-- Can the caller see a membership or invitation with this scope? (the roster)
create function public.can_view_membership(p_org uuid, p_venue uuid, p_event uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.active_memberships() m
    where m.org_id = p_org
      and (
        m.role = 'owner'
        or (m.role = 'manager' and p_venue is not null and m.venue_id = p_venue)
        or (m.role = 'organizer' and p_event is not null)
      )
  )
$$;

-- The one place that says who may grant which role where. Also decides who may
-- revoke it, and who may resend or cancel an invitation.
create function public.can_invite_role(p_org uuid, p_role text, p_venue uuid, p_event uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return false; end if;
  if p_role not in ('manager', 'server', 'door', 'security', 'verifier') then return false; end if;
  -- exactly one scope target: a venue or an event
  if (p_venue is null) = (p_event is null) then return false; end if;

  if p_venue is not null then
    if not exists (select 1 from public.site_venues v where v.id = p_venue and v.org_id = p_org) then
      return false;
    end if;
    if p_role = 'manager' then
      return public.is_org_member(p_org, array['owner']);
    end if;
    return exists (
      select 1 from public.active_memberships() m
      where m.org_id = p_org
        and (m.role = 'owner' or (m.role = 'manager' and m.venue_id = p_venue))
    );
  end if;

  -- event scope: door staff only, appointed by the organization that owns the event
  if p_role <> 'door' then return false; end if;
  if not exists (select 1 from public.site_events e where e.id = p_event and e.org_id = p_org) then
    return false;
  end if;
  return public.is_org_member(p_org, array['owner', 'organizer']);
end;
$$;

-- ---------------------------------------------------------------------------
-- Actions (the only way to change any of this)
-- ---------------------------------------------------------------------------

create function public.create_organization(p_name text, p_kind text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if p_kind not in ('venue_owner', 'organizer') then raise exception 'invalid organization kind'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'name required'; end if;

  insert into public.site_organizations (name, kind, created_by)
    values (trim(p_name), p_kind, v_uid) returning id into v_org;
  insert into public.site_memberships (org_id, user_id, role, invited_by)
    values (v_org, v_uid, case p_kind when 'venue_owner' then 'owner' else 'organizer' end, v_uid);
  return v_org;
end;
$$;

-- "Owner -> Venues -> Add Venue". Each venue keeps its own rooms, payments, staff and stock.
create function public.create_org_venue(p_org uuid, p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.site_organizations o where o.id = p_org and o.kind = 'venue_owner')
     or not public.is_org_member(p_org, array['owner']) then
    raise exception 'not allowed';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'name required'; end if;

  insert into public.site_venues (name, org_id) values (trim(p_name), p_org) returning id into v_venue;
  return v_venue;
end;
$$;

create function public.create_shift(
  p_venue uuid, p_name text, p_starts timestamptz, p_ends timestamptz, p_event uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  insert into public.site_shifts (venue_id, event_id, name, starts_at, ends_at, created_by)
    values (p_venue, p_event, trim(p_name), p_starts, p_ends, auth.uid())
    returning id into v_shift;
  return v_shift;
end;
$$;

-- Creates an invitation, or, if an identical one is still pending, renews it
-- instead of creating a second (resending must never duplicate access).
-- Returns the link token ONCE. Only its hash is stored.
create function public.invite_member(
  p_org uuid, p_email text, p_role text,
  p_venue uuid default null, p_event uuid default null, p_shift uuid default null,
  p_access_start timestamptz default null, p_access_end timestamptz default null,
  p_valid_for interval default interval '7 days'
)
returns table (invitation_id uuid, token text, valid_until timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_token text;
  v_hash bytea;
  v_id uuid;
  v_exp timestamptz;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if position('@' in v_email) < 2 then raise exception 'valid email required'; end if;
  if p_valid_for <= interval '0' or p_valid_for > interval '30 days' then raise exception 'invalid expiry'; end if;
  if p_access_start is not null and p_access_end is not null and p_access_end <= p_access_start then
    raise exception 'invalid access window';
  end if;
  if not public.can_invite_role(p_org, p_role, p_venue, p_event) then raise exception 'not allowed'; end if;
  if p_shift is not null and not exists (
    select 1 from public.site_shifts s where s.id = p_shift and p_venue is not null and s.venue_id = p_venue
  ) then
    raise exception 'shift does not belong to this venue';
  end if;

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_hash := sha256(convert_to(v_token, 'utf8'));
  v_exp := now() + p_valid_for;

  select i.id into v_id
  from public.site_invitations i
  where i.org_id = p_org and i.email = v_email and i.role = p_role and i.status = 'pending'
    and i.venue_id is not distinct from p_venue
    and i.event_id is not distinct from p_event
    and i.shift_id is not distinct from p_shift
  for update;

  if v_id is not null then
    update public.site_invitations
      set token_hash = v_hash, expires_at = v_exp, invited_by = v_uid,
          access_start_at = p_access_start, access_end_at = p_access_end
      where id = v_id;
  else
    insert into public.site_invitations
      (org_id, email, role, venue_id, event_id, shift_id, access_start_at, access_end_at, token_hash, expires_at, invited_by)
    values
      (p_org, v_email, p_role, p_venue, p_event, p_shift, p_access_start, p_access_end, v_hash, v_exp, v_uid)
    returning id into v_id;
  end if;

  return query select v_id, v_token, v_exp;
end;
$$;

-- Renew a pending (or expired) invitation with a fresh link. The old link stops working.
create function public.resend_invitation(p_invitation uuid, p_valid_for interval default interval '7 days')
returns table (invitation_id uuid, token text, valid_until timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv public.site_invitations%rowtype;
  v_token text;
  v_exp timestamptz;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_inv from public.site_invitations i where i.id = p_invitation for update;
  if not found or not public.can_invite_role(v_inv.org_id, v_inv.role, v_inv.venue_id, v_inv.event_id) then
    raise exception 'not allowed';
  end if;
  if v_inv.status = 'accepted' then raise exception 'already accepted'; end if;
  if v_inv.status = 'revoked' then raise exception 'invitation was revoked'; end if;
  if p_valid_for <= interval '0' or p_valid_for > interval '30 days' then raise exception 'invalid expiry'; end if;

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_exp := now() + p_valid_for;
  update public.site_invitations
    set token_hash = sha256(convert_to(v_token, 'utf8')), expires_at = v_exp
    where id = p_invitation;
  return query select p_invitation, v_token, v_exp;
end;
$$;

create function public.revoke_invitation(p_invitation uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv public.site_invitations%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_inv from public.site_invitations i where i.id = p_invitation for update;
  if not found or not public.can_invite_role(v_inv.org_id, v_inv.role, v_inv.venue_id, v_inv.event_id) then
    raise exception 'not allowed';
  end if;
  if v_inv.status <> 'pending' then raise exception 'only a pending invitation can be revoked'; end if;
  update public.site_invitations
    set status = 'revoked', revoked_at = now(), revoked_by = auth.uid()
    where id = p_invitation;
end;
$$;

-- The invitee opens the link while signed in. Returns an outcome the app can
-- explain instead of raising: ok | already_accepted | invalid | revoked | expired | email_mismatch.
create function public.accept_invitation(p_token text)
returns table (outcome text, joined_membership_id uuid, joined_org_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_inv public.site_invitations%rowtype;
  v_mid uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  select * into v_inv
  from public.site_invitations i
  where i.token_hash = sha256(convert_to(coalesce(p_token, ''), 'utf8'))
  for update;

  if not found then
    return query select 'invalid'::text, null::uuid, null::uuid;
    return;
  end if;
  if v_inv.status = 'revoked' then
    return query select 'revoked'::text, null::uuid, null::uuid;
    return;
  end if;
  if v_inv.status = 'accepted' then
    if v_inv.accepted_by = v_uid then
      return query select 'already_accepted'::text, v_inv.membership_id, v_inv.org_id;
    else
      return query select 'invalid'::text, null::uuid, null::uuid;  -- someone else's used link: reveal nothing
    end if;
    return;
  end if;
  if v_inv.expires_at < now() then
    return query select 'expired'::text, null::uuid, null::uuid;
    return;
  end if;
  if v_email <> v_inv.email then
    return query select 'email_mismatch'::text, null::uuid, null::uuid;
    return;
  end if;

  select m.id into v_mid
  from public.site_memberships m
  where m.org_id = v_inv.org_id and m.user_id = v_uid and m.role = v_inv.role and m.status = 'active'
    and m.venue_id is not distinct from v_inv.venue_id
    and m.event_id is not distinct from v_inv.event_id
    and m.shift_id is not distinct from v_inv.shift_id
  limit 1;

  if v_mid is null then
    insert into public.site_memberships
      (org_id, user_id, role, venue_id, event_id, shift_id, access_start_at, access_end_at, invited_by)
    values
      (v_inv.org_id, v_uid, v_inv.role, v_inv.venue_id, v_inv.event_id, v_inv.shift_id,
       v_inv.access_start_at, v_inv.access_end_at, v_inv.invited_by)
    returning id into v_mid;
  end if;

  update public.site_invitations
    set status = 'accepted', accepted_by = v_uid, accepted_at = now(), membership_id = v_mid
    where id = v_inv.id;

  return query select 'ok'::text, v_mid, v_inv.org_id;
end;
$$;

-- Takes access away immediately. The row stays, with who revoked it and when, so
-- earlier actions remain attributable. Ownership changes are a platform-admin task for now.
create function public.revoke_membership(p_membership uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_m public.site_memberships%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_m from public.site_memberships m where m.id = p_membership for update;
  if not found or v_m.status <> 'active' then raise exception 'membership not found'; end if;

  if v_m.role in ('owner', 'organizer') then
    if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  elsif not (public.is_cms_admin() or public.can_invite_role(v_m.org_id, v_m.role, v_m.venue_id, v_m.event_id)) then
    raise exception 'not allowed';
  end if;

  update public.site_memberships
    set status = 'revoked', revoked_at = now(), revoked_by = auth.uid()
    where id = p_membership;
end;
$$;

-- ---------------------------------------------------------------------------
-- What the app asks for
-- ---------------------------------------------------------------------------

-- Every workspace the signed-in user can open right now: role, organization,
-- and the venue / event / shift it is limited to.
create function public.my_workspaces()
returns table (
  membership_id uuid, org_id uuid, org_name text, org_kind text, role text,
  venue_id uuid, venue_name text, event_id uuid, event_title text,
  shift_id uuid, shift_name text, access_start_at timestamptz, access_end_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select m.id, m.org_id, o.name, o.kind, m.role,
         m.venue_id, v.name, m.event_id, e.title,
         m.shift_id, s.name, m.access_start_at, m.access_end_at
  from public.active_memberships() m
  join public.site_organizations o on o.id = m.org_id
  left join public.site_venues v on v.id = m.venue_id
  left join public.site_events e on e.id = m.event_id
  left join public.site_shifts s on s.id = m.shift_id
  order by o.name, m.role, v.name nulls first, e.title nulls first
$$;

-- Venues the caller can reach: all of an owner's, or just the one a manager/staff is scoped to.
create function public.my_venues()
returns table (venue_id uuid, venue_name text, org_id uuid, status text)
language sql
stable
security definer
set search_path = public
as $$
  select distinct v.id, v.name, v.org_id, v.status
  from public.site_venues v
  where public.can_access_venue(v.id)
  order by v.name
$$;

-- The team's invitations with the state the client asked for:
-- pending | accepted | expired | revoked. Never returns the link token.
create function public.list_invitations(p_org uuid)
returns table (
  invitation_id uuid, email text, role text, venue_id uuid, event_id uuid,
  state text, expires_at timestamptz, created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select i.id, i.email, i.role, i.venue_id, i.event_id,
         case when i.status = 'pending' and i.expires_at < now() then 'expired' else i.status end,
         i.expires_at, i.created_at
  from public.site_invitations i
  where i.org_id = p_org and public.can_view_membership(i.org_id, i.venue_id, i.event_id)
  order by i.created_at desc
$$;

-- ---------------------------------------------------------------------------
-- Row level security: the tables are read-only to clients; actions go through
-- the functions above.
-- ---------------------------------------------------------------------------
alter table public.site_organizations enable row level security;
alter table public.site_memberships enable row level security;
alter table public.site_invitations enable row level security;
alter table public.site_shifts enable row level security;

create policy "members read their organizations" on public.site_organizations
  for select to authenticated using (public.is_org_member(id) or public.is_cms_admin());

create policy "read own or managed memberships" on public.site_memberships
  for select to authenticated using (user_id = auth.uid() or public.can_view_membership(org_id, venue_id, event_id) or public.is_cms_admin());

create policy "read invitations you can manage" on public.site_invitations
  for select to authenticated using (public.can_view_membership(org_id, venue_id, event_id) or public.is_cms_admin());

create policy "read shifts for venues you can reach" on public.site_shifts
  for select to authenticated using (public.can_access_venue(venue_id) or public.is_cms_admin());

-- Staff can read the venue and events they are scoped to (drafts included).
-- These two are TO authenticated on purpose: a policy runs as the caller, and anonymous
-- visitors browsing the public site must never need to execute the permission functions.
create policy "members read their venues" on public.site_venues
  for select to authenticated using (public.can_access_venue(id));
create policy "members read their events" on public.site_events
  for select to authenticated using (public.can_access_event(id));

-- No direct writes from the app. Column grants keep the token hash unreadable.
revoke all on public.site_organizations, public.site_memberships, public.site_invitations, public.site_shifts
  from anon, authenticated;
grant select on public.site_organizations, public.site_memberships, public.site_shifts to authenticated;
grant select (id, org_id, email, role, venue_id, event_id, shift_id, access_start_at, access_end_at, status,
              expires_at, invited_by, created_at, accepted_by, accepted_at, membership_id, revoked_at, revoked_by)
  on public.site_invitations to authenticated;

-- Functions: signed-in users only (a function's default is "everyone").
revoke all on function
  public.active_memberships(), public.is_org_member(uuid, text[]), public.can_access_venue(uuid, text[]),
  public.can_access_event(uuid, text[]), public.can_view_membership(uuid, uuid, uuid),
  public.can_invite_role(uuid, text, uuid, uuid), public.create_organization(text, text),
  public.create_org_venue(uuid, text), public.create_shift(uuid, text, timestamptz, timestamptz, uuid),
  public.invite_member(uuid, text, text, uuid, uuid, uuid, timestamptz, timestamptz, interval),
  public.resend_invitation(uuid, interval), public.revoke_invitation(uuid), public.accept_invitation(text),
  public.revoke_membership(uuid), public.my_workspaces(), public.my_venues(), public.list_invitations(uuid)
  from public, anon;
grant execute on function
  public.active_memberships(), public.is_org_member(uuid, text[]), public.can_access_venue(uuid, text[]),
  public.can_access_event(uuid, text[]), public.can_view_membership(uuid, uuid, uuid),
  public.can_invite_role(uuid, text, uuid, uuid), public.create_organization(text, text),
  public.create_org_venue(uuid, text), public.create_shift(uuid, text, timestamptz, timestamptz, uuid),
  public.invite_member(uuid, text, text, uuid, uuid, uuid, timestamptz, timestamptz, interval),
  public.resend_invitation(uuid, interval), public.revoke_invitation(uuid), public.accept_invitation(text),
  public.revoke_membership(uuid), public.my_workspaces(), public.my_venues(), public.list_invitations(uuid)
  to authenticated, service_role;
