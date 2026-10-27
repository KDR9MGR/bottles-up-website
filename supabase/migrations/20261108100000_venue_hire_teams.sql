-- Venue hire, event workspaces and teams (customer app completion plan, M8; client plan page 11).
--
--   * TEAMS: the owner of a professional's own business profile (a DJ, a photographer...) invites people by username with a role: manager, booking agent, content manager, finance
--     assistant, door staff, or a custom pick of what they may do. Three kinds of work are told apart: 'bookings' (services, requests, quotes, hires), 'content' (posts and the profile's
--     own details) and 'finance' (earnings). The person accepts or declines; the owner can change a role or revoke at any time and the access ends at once (every check reads the row
--     as it is now). Only the owner manages the team. A profile run by a venue business (a venue, an event group) is run by that business's own roles in BottlesUp Business instead.
--     Every invitation, answer, change and revocation is in the audit log. The table, and who counts as "mine", are in 20261101110000.
--   * VENUE HIRE: an event group (or a promoter) asks a venue to host its night: a date, hours, the kind of event, expected attendance, the space, equipment, staffing, a budget and
--     special requests. The venue's team answers with an offer (rental cost, deposit, minimum sales, bar share, who controls tickets and tables, staffing, equipment, cancellation terms,
--     how long it stays open). The group agrees, the venue CONFIRMS the date (one confirmed hire per venue per day), and the group links the confirmed hire to its public event. A request,
--     an offer and an agreement are NOT a confirmed booking: the state says which. The money in a hire (rental, deposit, minimum sales, bar share) is agreed here and settled between
--     the group and the venue: BottlesUp does not take it in this version.
--   * THE EVENT WORKSPACE: once a hire is agreed, both sides share a private page with the terms, the schedule and the tasks, the professionals the group has attached from "Hiring
--     professionals" (shown as confirmed only when their deposit is paid, with no money shown to the venue), the linked public event and its ticket numbers, and a list of what is still
--     pending. Each agreement, payment and permission stays separate.
--   * AUTOMATIC CHATS: a team chat (the owner and each accepted member, as people); a hire chat (the group's and the venue's profiles, from the request); an event chat (those two and
--     the professionals attached, from the confirmation). They are ordinary conversations in the inbox. A revoked member leaves the team chat at once.
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.site_hires (
  id uuid primary key default gen_random_uuid(),
  organizer uuid references public.site_profiles (id) on delete set null,
  venue_profile uuid references public.site_profiles (id) on delete set null,
  requested_by uuid references auth.users (id) on delete set null,
  event_date date not null,
  hours text check (hours is null or char_length(hours) <= 60),
  event_type text not null check (char_length(btrim(event_type)) between 2 and 80),
  attendance int check (attendance is null or attendance between 1 and 100000),
  space text check (space is null or char_length(space) <= 160),
  equipment text check (equipment is null or char_length(equipment) <= 300),
  staffing text check (staffing is null or char_length(staffing) <= 300),
  budget_cents int check (budget_cents is null or budget_cents between 0 and 100000000),
  notes text check (notes is null or char_length(notes) <= 1000),
  status text not null default 'requested' check (status in ('requested', 'offered', 'agreed', 'confirmed', 'declined', 'withdrawn', 'cancelled')),
  decline_note text check (decline_note is null or char_length(decline_note) <= 300),
  cancelled_by text check (cancelled_by in ('organizer', 'venue')),
  cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 300),
  event_id uuid references public.site_events (id) on delete set null,
  confirmed_at timestamptz,
  created_at timestamptz not null default clock_timestamp()
);
create index site_hires_organizer_idx on public.site_hires (organizer, created_at desc);
create index site_hires_venue_idx on public.site_hires (venue_profile, created_at desc);
create index site_hires_requested_by_idx on public.site_hires (requested_by);
-- One confirmed hire per venue per day.
create unique index site_hires_one_confirmed on public.site_hires (venue_profile, event_date) where status = 'confirmed';

create table public.site_hire_offers (
  id uuid primary key default gen_random_uuid(),
  hire uuid not null references public.site_hires (id) on delete cascade,
  rental_cents int not null check (rental_cents between 0 and 100000000),
  deposit_cents int not null check (deposit_cents between 0 and 100000000 and deposit_cents <= rental_cents),
  min_sales_cents int not null default 0 check (min_sales_cents between 0 and 100000000),
  bar_share_bps int not null default 0 check (bar_share_bps between 0 and 10000),
  control text not null check (control in ('venue', 'organizer', 'shared')),
  staffing text check (staffing is null or char_length(staffing) <= 300),
  equipment text check (equipment is null or char_length(equipment) <= 300),
  cancellation text check (cancellation is null or char_length(cancellation) <= 600),
  notes text check (notes is null or char_length(notes) <= 1000),
  valid_until timestamptz not null,
  status text not null default 'sent' check (status in ('sent', 'accepted', 'declined', 'withdrawn')),
  created_at timestamptz not null default clock_timestamp()
);
create index site_hire_offers_hire_idx on public.site_hire_offers (hire, created_at desc);
-- One live offer per hire.
create unique index site_hire_offers_one_sent on public.site_hire_offers (hire) where status = 'sent';

-- The tasks and the schedule of a hire.
create table public.site_hire_items (
  id uuid primary key default gen_random_uuid(),
  hire uuid not null references public.site_hires (id) on delete cascade,
  kind text not null check (kind in ('task', 'schedule')),
  title text not null check (char_length(btrim(title)) between 2 and 120),
  at_time time,
  due_on date,
  done boolean not null default false,
  side text not null check (side in ('organizer', 'venue')),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  constraint site_hire_items_shape check ((kind = 'schedule' and at_time is not null and due_on is null) or (kind = 'task' and at_time is null))
);
create index site_hire_items_hire_idx on public.site_hire_items (hire, kind, at_time, created_at);

-- The professionals a group has attached to a hire (a booking from "Hiring professionals").
create table public.site_hire_bookings (
  hire uuid not null references public.site_hires (id) on delete cascade,
  booking uuid not null references public.site_pro_bookings (id) on delete cascade,
  attached_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (hire, booking),
  unique (booking)
);

-- Which conversation is the team chat of a profile, the chat of a hire, or the chat of a hire's event.
create table public.site_chat_links (
  conversation uuid primary key references public.site_dm_conversations (id) on delete cascade,
  kind text not null check (kind in ('team', 'hire', 'event')),
  ref uuid not null,
  unique (kind, ref)
);

alter table public.site_hires enable row level security;
alter table public.site_hire_offers enable row level security;
alter table public.site_hire_items enable row level security;
alter table public.site_hire_bookings enable row level security;
alter table public.site_chat_links enable row level security;
revoke all on table public.site_hires, public.site_hire_offers, public.site_hire_items, public.site_hire_bookings, public.site_chat_links from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
create function public.team_require_on()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not (public.feature_enabled('marketplace') or public.feature_enabled('venue_hire')) then raise exception 'Teams are not open yet.'; end if;
end;
$$;

create function public.hire_require_on()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not public.feature_enabled('venue_hire') then raise exception 'Hosting events at venues is not open yet.'; end if;
end;
$$;

-- What each role may do. A custom role carries what the owner picks.
create function public.team_role_permissions(p_role text)
returns text[]
language sql
immutable
set search_path = public
as $$
  select case p_role
    when 'manager' then array['bookings', 'content', 'finance']
    when 'booking_agent' then array['bookings']
    when 'content_manager' then array['content']
    when 'finance_assistant' then array['finance']
    when 'door_staff' then array[]::text[]
    else null
  end
$$;

-- The conversation behind a chat link, made on first use: a group whose first member is the one who asked for it.
create function public.chat_link_ensure(p_kind text, p_ref uuid, p_title text, p_admin uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conv uuid;
begin
  select l.conversation into v_conv from public.site_chat_links l where l.kind = p_kind and l.ref = p_ref;
  if v_conv is not null then return v_conv; end if;
  insert into public.site_dm_conversations (kind, title, created_by) values ('group', left(btrim(p_title), 60), p_admin) returning id into v_conv;
  insert into public.site_chat_links (conversation, kind, ref) values (v_conv, p_kind, p_ref);
  if p_admin is not null then
    insert into public.site_dm_members (conversation, profile, role, status) values (v_conv, p_admin, 'admin', 'active');
  end if;
  return v_conv;
end;
$$;

create function public.chat_link_join(p_conversation uuid, p_profile uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.site_dm_members (conversation, profile, role, status) values (p_conversation, p_profile, 'member', 'active')
  on conflict (conversation, profile) do update set status = 'active'
$$;

create function public.chat_link_leave(p_kind text, p_ref uuid, p_profile uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.site_dm_members m set status = 'left'
   where m.profile = p_profile and m.conversation = (select l.conversation from public.site_chat_links l where l.kind = p_kind and l.ref = p_ref)
$$;

-- The personal profile of a login (where a person is a member of a team chat).
create function public.personal_profile_of(p_user uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.id from public.site_profiles p where p.user_id = p_user and p.kind = 'personal'
$$;

-- ---------------------------------------------------------------------------
-- 3. Teams
-- ---------------------------------------------------------------------------
create function public.team_require_owner(p_actor uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.team_require_on();
  if p_actor is null or not public.profile_can_act_as(p_actor) then raise exception 'You cannot act as this profile.'; end if;
  if not exists (select 1 from public.site_profiles s where s.id = p_actor and s.kind = 'business' and s.user_id is not null and s.org_id is null) then
    raise exception 'Only a professional''s own profile has a team here. A venue or event group is run from BottlesUp Business.';
  end if;
  if not public.profile_is_owner(p_actor) then raise exception 'Only the owner of the profile manages its team.'; end if;
end;
$$;

create function public.team_member_json(p_team uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', t.id, 'role', t.role, 'permissions', to_jsonb(t.permissions), 'status', t.status, 'invited_at', t.invited_at, 'answered_at', t.answered_at,
    'person', public.market_person(t.member))
    from public.site_profile_team t where t.id = p_team
$$;

create function public.team_invite(p_actor uuid, p_handle text, p_role text, p_permissions text[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_handle text := lower(btrim(coalesce(p_handle, '')));
  v_user uuid;
  v_theirs uuid;
  v_perms text[];
  v_row public.site_profile_team;
  v_id uuid;
begin
  perform public.team_require_owner(p_actor);
  if left(v_handle, 1) = '@' then v_handle := substr(v_handle, 2); end if;
  if p_role is null or public.team_role_permissions(p_role) is null and p_role <> 'custom' then raise exception 'Choose a role.'; end if;
  if p_role = 'custom' then
    if p_permissions is null or cardinality(p_permissions) = 0 then raise exception 'Choose at least one thing a custom role may do.'; end if;
    if not (p_permissions <@ array['bookings', 'content', 'finance']::text[]) then raise exception 'Choose from bookings, content and finance.'; end if;
    select coalesce(array_agg(distinct x order by x), '{}') into v_perms from unnest(p_permissions) x;
  else
    v_perms := public.team_role_permissions(p_role);
  end if;
  select pr.id into v_user from public.profiles pr where pr.username = v_handle;
  v_theirs := case when v_user is null then null else public.personal_profile_of(v_user) end;
  if v_user is null or v_theirs is null or public.profile_blocked_between(p_actor, v_theirs) then raise exception 'No one has that username.'; end if;
  if v_user = auth.uid() then raise exception 'You own this profile already.'; end if;
  select * into v_row from public.site_profile_team t where t.profile = p_actor and t.member = v_user for update;
  if found and v_row.status in ('invited', 'active') then raise exception 'That person is already on the team or has been asked.'; end if;
  if (select count(*) from public.site_profile_team t where t.profile = p_actor and t.status in ('invited', 'active')) >= 20 then raise exception 'A team can have up to 20 people.'; end if;
  if found then
    update public.site_profile_team set role = p_role, permissions = v_perms, status = 'invited', invited_by = auth.uid(), invited_at = clock_timestamp(), answered_at = null where id = v_row.id returning id into v_id;
  else
    insert into public.site_profile_team (profile, member, role, permissions, invited_by) values (p_actor, v_user, p_role, v_perms, auth.uid()) returning id into v_id;
  end if;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'team.invited', 'site_profile_team', v_id::text, jsonb_build_object('profile', p_actor, 'member', v_user, 'role', p_role, 'permissions', v_perms));
  return public.team_member_json(v_id);
end;
$$;

-- The person answers an invitation addressed to them.
create function public.team_answer(p_team uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_profile_team;
  v_owner uuid;
  v_conv uuid;
begin
  perform public.team_require_on();
  if p_accept is null then raise exception 'Say yes or no.'; end if;
  select * into t from public.site_profile_team x where x.id = p_team for update;
  if not found or t.member is distinct from auth.uid() then raise exception 'This invitation is not available.'; end if;
  if t.status <> 'invited' then raise exception 'This invitation has already been answered.'; end if;
  update public.site_profile_team set status = case when p_accept then 'active' else 'declined' end, answered_at = clock_timestamp() where id = p_team;
  if p_accept then
    select s.user_id into v_owner from public.site_profiles s where s.id = t.profile;
    v_conv := public.chat_link_ensure('team', t.profile, 'Team: ' || (select s.display_name from public.site_profiles s where s.id = t.profile), public.personal_profile_of(v_owner));
    perform public.chat_link_join(v_conv, public.personal_profile_of(auth.uid()));
  end if;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), case when p_accept then 'team.accepted' else 'team.declined' end, 'site_profile_team', p_team::text, jsonb_build_object('profile', t.profile));
  return public.team_member_json(p_team);
end;
$$;

-- The owner takes access away, or the person leaves: either way it ends now.
create function public.team_revoke(p_actor uuid, p_team uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_profile_team;
begin
  perform public.team_require_owner(p_actor);
  select * into t from public.site_profile_team x where x.id = p_team for update;
  if not found or t.profile <> p_actor then raise exception 'This team member is not available.'; end if;
  if t.status not in ('invited', 'active') then raise exception 'This person is not on the team.'; end if;
  update public.site_profile_team set status = 'revoked', answered_at = clock_timestamp() where id = p_team;
  perform public.chat_link_leave('team', t.profile, public.personal_profile_of(t.member));
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'team.revoked', 'site_profile_team', p_team::text, jsonb_build_object('profile', p_actor, 'member', t.member, 'was', t.status));
  return public.team_member_json(p_team);
end;
$$;

create function public.team_leave(p_team uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_profile_team;
begin
  perform public.team_require_on();
  select * into t from public.site_profile_team x where x.id = p_team for update;
  if not found or t.member is distinct from auth.uid() then raise exception 'This team is not available.'; end if;
  if t.status <> 'active' then raise exception 'You are not on this team.'; end if;
  update public.site_profile_team set status = 'left', answered_at = clock_timestamp() where id = p_team;
  perform public.chat_link_leave('team', t.profile, public.personal_profile_of(t.member));
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'team.left', 'site_profile_team', p_team::text, jsonb_build_object('profile', t.profile));
  return public.team_member_json(p_team);
end;
$$;

create function public.team_set_role(p_actor uuid, p_team uuid, p_role text, p_permissions text[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_profile_team;
  v_perms text[];
begin
  perform public.team_require_owner(p_actor);
  if p_role is null or public.team_role_permissions(p_role) is null and p_role <> 'custom' then raise exception 'Choose a role.'; end if;
  if p_role = 'custom' then
    if p_permissions is null or cardinality(p_permissions) = 0 then raise exception 'Choose at least one thing a custom role may do.'; end if;
    if not (p_permissions <@ array['bookings', 'content', 'finance']::text[]) then raise exception 'Choose from bookings, content and finance.'; end if;
    select coalesce(array_agg(distinct x order by x), '{}') into v_perms from unnest(p_permissions) x;
  else
    v_perms := public.team_role_permissions(p_role);
  end if;
  select * into t from public.site_profile_team x where x.id = p_team for update;
  if not found or t.profile <> p_actor then raise exception 'This team member is not available.'; end if;
  if t.status not in ('invited', 'active') then raise exception 'This person is not on the team.'; end if;
  update public.site_profile_team set role = p_role, permissions = v_perms where id = p_team;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'team.role_changed', 'site_profile_team', p_team::text, jsonb_build_object('profile', p_actor, 'member', t.member, 'role', p_role, 'permissions', v_perms));
  return public.team_member_json(p_team);
end;
$$;

-- Who is on the team of a profile: shown to everyone who may act as it; only the owner manages.
create function public.team_list(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_owner uuid;
begin
  perform public.team_require_on();
  if p_actor is null or not public.profile_can_act_as(p_actor) then raise exception 'You cannot act as this profile.'; end if;
  select s.user_id into v_owner from public.site_profiles s where s.id = p_actor and s.kind = 'business' and s.user_id is not null and s.org_id is null;
  if v_owner is null then raise exception 'Only a professional''s own profile has a team here. A venue or event group is run from BottlesUp Business.'; end if;
  return jsonb_build_object(
    'can_manage', public.profile_is_owner(p_actor),
    'owner', public.market_person(v_owner),
    'members', coalesce((select jsonb_agg(public.team_member_json(t.id) order by t.invited_at, t.id) from public.site_profile_team t where t.profile = p_actor and t.status in ('invited', 'active')), '[]'::jsonb),
    'chat', (select l.conversation from public.site_chat_links l where l.kind = 'team' and l.ref = p_actor),
    'chat_profile', public.personal_profile_of(auth.uid()));
end;
$$;

create function public.team_invitations_mine()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.team_require_on();
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', t.id, 'role', t.role, 'permissions', to_jsonb(t.permissions), 'invited_at', t.invited_at, 'profile', public.profile_mini(t.profile)) order by t.invited_at desc, t.id)
      from public.site_profile_team t join public.site_profiles s on s.id = t.profile
     where t.member = auth.uid() and t.status = 'invited' and s.status = 'active'
  ), '[]'::jsonb);
end;
$$;

-- What the caller may do as a profile: everything for an owner, a role's permissions for a team member.
create function public.team_my_access(p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.team_require_on();
  if p_profile is null or not public.profile_is_mine(p_profile) then raise exception 'You cannot act as this profile.'; end if;
  return jsonb_build_object(
    'owner', public.profile_is_owner(p_profile),
    'permissions', (select to_jsonb(coalesce(array_agg(k order by k), '{}')) from unnest(array['bookings', 'content', 'finance']) k where public.profile_has_permission(p_profile, k)));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Venue hire: the JSON and the checks
-- ---------------------------------------------------------------------------
-- Where a hire really stands. A request that was never agreed lapses when its day arrives; an offer that ran out is said to have; a confirmed hire is completed once its day has passed.
create function public.hire_state(p_hire uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when h.status in ('requested', 'offered', 'agreed') and h.event_date <= current_date then 'lapsed'
    when h.status = 'offered' and not exists (select 1 from public.site_hire_offers o where o.hire = h.id and o.status = 'sent' and o.valid_until > now()) then 'offer_expired'
    when h.status = 'confirmed' and h.event_date < current_date then 'completed'
    else h.status
  end
  from public.site_hires h where h.id = p_hire
$$;

create function public.hire_offer_json(p_offer uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', o.id, 'rental_cents', o.rental_cents, 'deposit_cents', o.deposit_cents, 'min_sales_cents', o.min_sales_cents, 'bar_share_bps', o.bar_share_bps, 'control', o.control,
    'staffing', o.staffing, 'equipment', o.equipment, 'cancellation', o.cancellation, 'notes', o.notes, 'valid_until', o.valid_until,
    'status', case when o.status = 'sent' and o.valid_until <= now() then 'expired' else o.status end, 'created_at', o.created_at)
    from public.site_hire_offers o where o.id = p_offer
$$;

create function public.hire_json(p_hire uuid, p_side text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', h.id, 'state', public.hire_state(h.id), 'event_date', h.event_date, 'hours', h.hours, 'event_type', h.event_type, 'attendance', h.attendance, 'space', h.space,
    'equipment', h.equipment, 'staffing', h.staffing, 'budget_cents', h.budget_cents, 'notes', h.notes, 'decline_note', h.decline_note, 'cancelled_by', h.cancelled_by,
    'cancel_reason', h.cancel_reason, 'event_id', h.event_id, 'confirmed_at', h.confirmed_at, 'created_at', h.created_at,
    'organizer', case when h.organizer is null then null else public.profile_mini(h.organizer) end,
    'venue', case when h.venue_profile is null then null else public.profile_mini(h.venue_profile) end,
    'requested_by', case when p_side = 'venue' then public.market_person(h.requested_by) else null end,
    'offer', (select public.hire_offer_json(o.id) from public.site_hire_offers o where o.hire = h.id
               order by (o.status = 'accepted') desc, (o.status = 'sent') desc, o.created_at desc, o.id limit 1))
    from public.site_hires h where h.id = p_hire
$$;

-- Which side of a hire is this profile, if the caller may act as it that way? The organizer needs the 'bookings' kind of work; a venue's team is its business's own roles.
create function public.hire_side(p_actor uuid, p_hire uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when h.organizer = p_actor and public.profile_can_act_as(p_actor) and public.profile_has_permission(p_actor, 'bookings') then 'organizer'
    when h.venue_profile = p_actor and public.profile_can_act_as(p_actor) then 'venue'
  end
  from public.site_hires h where h.id = p_hire
$$;

-- ---------------------------------------------------------------------------
-- 5. Venue hire: asking, offering, agreeing, confirming, cancelling
-- ---------------------------------------------------------------------------
create function public.hire_request(
  p_actor uuid, p_venue uuid, p_date date, p_hours text, p_type text, p_attendance int, p_space text, p_equipment text, p_staffing text, p_budget_cents int, p_notes text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hours text := nullif(btrim(coalesce(p_hours, '')), '');
  v_type text := btrim(coalesce(p_type, ''));
  v_space text := nullif(btrim(coalesce(p_space, '')), '');
  v_equipment text := nullif(btrim(coalesce(p_equipment, '')), '');
  v_staffing text := nullif(btrim(coalesce(p_staffing, '')), '');
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
  v_id uuid;
  v_conv uuid;
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  perform public.social_require_rules();
  if not exists (select 1 from public.site_profiles s where s.id = p_actor and s.kind = 'business' and s.category in ('event_group', 'promoter')) then
    raise exception 'Only an event group or a promoter can ask a venue to host an event.';
  end if;
  if p_venue is null or not exists (select 1 from public.site_profiles s where s.id = p_venue and s.kind = 'business' and s.category = 'venue' and s.status = 'active') then
    raise exception 'This venue is not available.';
  end if;
  if public.profile_is_mine(p_venue) then raise exception 'You cannot ask your own venue.'; end if;
  if public.profile_blocked_between(p_actor, p_venue) then raise exception 'This venue is not available.'; end if;
  if p_date is null or p_date <= current_date or p_date > current_date + 730 then raise exception 'Choose a date between tomorrow and two years from now.'; end if;
  if char_length(v_type) < 2 or char_length(v_type) > 80 then raise exception 'Say what kind of event it is in 2 to 80 characters.'; end if;
  if v_hours is not null and char_length(v_hours) > 60 then raise exception 'Keep the hours to 60 characters.'; end if;
  if p_attendance is not null and (p_attendance < 1 or p_attendance > 100000) then raise exception 'Choose an expected attendance between 1 and 100,000.'; end if;
  if v_space is not null and char_length(v_space) > 160 then raise exception 'Keep the space to 160 characters.'; end if;
  if v_equipment is not null and char_length(v_equipment) > 300 then raise exception 'Keep the equipment to 300 characters.'; end if;
  if v_staffing is not null and char_length(v_staffing) > 300 then raise exception 'Keep the staffing to 300 characters.'; end if;
  if p_budget_cents is not null and (p_budget_cents < 0 or p_budget_cents > 100000000) then raise exception 'Choose a budget between 0 and 1,000,000.00.'; end if;
  if v_notes is not null and char_length(v_notes) > 1000 then raise exception 'Keep the special requests to 1000 characters.'; end if;
  if not (public.social_text_ok(v_type) and public.social_text_ok(v_hours) and public.social_text_ok(v_space) and public.social_text_ok(v_equipment) and public.social_text_ok(v_staffing) and public.social_text_ok(v_notes)) then
    raise exception 'That wording is not allowed here.';
  end if;
  if exists (select 1 from public.site_hires h where h.venue_profile = p_venue and h.event_date = p_date and h.status = 'confirmed') then raise exception 'This venue is already booked for a hire that day.'; end if;
  if (select count(*) from public.site_hires h where h.organizer = p_actor and h.created_at > now() - interval '1 day') >= 5 then raise exception 'You have sent a lot of requests today. Try again tomorrow.'; end if;
  if exists (select 1 from public.site_hires h where h.organizer = p_actor and h.venue_profile = p_venue and h.event_date = p_date and h.status in ('requested', 'offered', 'agreed')) then
    raise exception 'You already have a request open with this venue for that day.';
  end if;
  insert into public.site_hires (organizer, venue_profile, requested_by, event_date, hours, event_type, attendance, space, equipment, staffing, budget_cents, notes)
  values (p_actor, p_venue, auth.uid(), p_date, v_hours, v_type, p_attendance, v_space, v_equipment, v_staffing, p_budget_cents, v_notes) returning id into v_id;
  v_conv := public.chat_link_ensure('hire', v_id, 'Hire: ' || (select s.display_name from public.site_profiles s where s.id = p_venue), p_actor);
  perform public.chat_link_join(v_conv, p_venue);
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'hire.requested', 'site_hires', v_id::text, jsonb_build_object('organizer', p_actor, 'venue', p_venue, 'event_date', p_date));
  return public.hire_json(v_id, 'organizer');
end;
$$;

create function public.hire_offer_send(
  p_actor uuid, p_hire uuid, p_rental_cents int, p_deposit_cents int, p_min_sales_cents int, p_bar_share_bps int, p_control text,
  p_staffing text, p_equipment text, p_cancellation text, p_notes text, p_valid_days int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
  v_staffing text := nullif(btrim(coalesce(p_staffing, '')), '');
  v_equipment text := nullif(btrim(coalesce(p_equipment, '')), '');
  v_cancellation text := nullif(btrim(coalesce(p_cancellation, '')), '');
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
  v_offer uuid;
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  select * into h from public.site_hires x where x.id = p_hire for update;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'venue' then raise exception 'This hire is not available.'; end if;
  if h.status not in ('requested', 'offered') or h.event_date <= current_date then raise exception 'This request is no longer open.'; end if;
  if p_rental_cents is null or p_rental_cents < 0 or p_rental_cents > 100000000 then raise exception 'Choose a rental cost between 0 and 1,000,000.00.'; end if;
  if p_deposit_cents is null or p_deposit_cents < 0 or p_deposit_cents > p_rental_cents then raise exception 'The deposit cannot be more than the rental cost.'; end if;
  if p_min_sales_cents is null or p_min_sales_cents < 0 or p_min_sales_cents > 100000000 then raise exception 'Choose a minimum sales figure between 0 and 1,000,000.00.'; end if;
  if p_bar_share_bps is null or p_bar_share_bps < 0 or p_bar_share_bps > 10000 then raise exception 'Choose a bar share between 0%% and 100%%.'; end if;
  if p_control is null or p_control not in ('venue', 'organizer', 'shared') then raise exception 'Say who controls tickets and tables.'; end if;
  if v_staffing is not null and char_length(v_staffing) > 300 then raise exception 'Keep the staffing to 300 characters.'; end if;
  if v_equipment is not null and char_length(v_equipment) > 300 then raise exception 'Keep the equipment to 300 characters.'; end if;
  if v_cancellation is not null and char_length(v_cancellation) > 600 then raise exception 'Keep the cancellation terms to 600 characters.'; end if;
  if v_notes is not null and char_length(v_notes) > 1000 then raise exception 'Keep the notes to 1000 characters.'; end if;
  if p_valid_days is null or p_valid_days < 1 or p_valid_days > 14 then raise exception 'An offer can stay open for 1 to 14 days.'; end if;
  if not (public.social_text_ok(v_staffing) and public.social_text_ok(v_equipment) and public.social_text_ok(v_cancellation) and public.social_text_ok(v_notes)) then raise exception 'That wording is not allowed here.'; end if;
  update public.site_hire_offers set status = 'withdrawn' where hire = p_hire and status = 'sent';
  insert into public.site_hire_offers (hire, rental_cents, deposit_cents, min_sales_cents, bar_share_bps, control, staffing, equipment, cancellation, notes, valid_until)
  values (p_hire, p_rental_cents, p_deposit_cents, p_min_sales_cents, p_bar_share_bps, p_control, v_staffing, v_equipment, v_cancellation, v_notes, now() + make_interval(days => p_valid_days)) returning id into v_offer;
  update public.site_hires set status = 'offered' where id = p_hire;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'hire.offered', 'site_hires', p_hire::text, jsonb_build_object('offer', v_offer, 'rental_cents', p_rental_cents, 'deposit_cents', p_deposit_cents));
  return public.hire_json(p_hire, 'venue');
end;
$$;

-- The venue takes its offer back: the request goes back to waiting for one.
create function public.hire_offer_withdraw(p_actor uuid, p_hire uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  select * into h from public.site_hires x where x.id = p_hire for update;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'venue' then raise exception 'This hire is not available.'; end if;
  if h.status <> 'offered' then raise exception 'There is no offer to withdraw.'; end if;
  update public.site_hire_offers set status = 'withdrawn' where hire = p_hire and status = 'sent';
  update public.site_hires set status = 'requested' where id = p_hire;
  return public.hire_json(p_hire, 'venue');
end;
$$;

-- The organizer turns the offer down: the request goes back to waiting for one.
create function public.hire_offer_decline(p_actor uuid, p_hire uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  select * into h from public.site_hires x where x.id = p_hire for update;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'organizer' then raise exception 'This hire is not available.'; end if;
  if h.status <> 'offered' then raise exception 'There is no offer to turn down.'; end if;
  update public.site_hire_offers set status = 'declined' where hire = p_hire and status = 'sent';
  update public.site_hires set status = 'requested' where id = p_hire;
  return public.hire_json(p_hire, 'organizer');
end;
$$;

create function public.hire_decline(p_actor uuid, p_hire uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  select * into h from public.site_hires x where x.id = p_hire for update;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'venue' then raise exception 'This hire is not available.'; end if;
  if h.status not in ('requested', 'offered') then raise exception 'This request is no longer open.'; end if;
  if v_note is not null and char_length(v_note) > 300 then raise exception 'Keep the note to 300 characters.'; end if;
  if not public.social_text_ok(v_note) then raise exception 'That wording is not allowed here.'; end if;
  update public.site_hire_offers set status = 'withdrawn' where hire = p_hire and status = 'sent';
  update public.site_hires set status = 'declined', decline_note = v_note where id = p_hire;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'hire.declined', 'site_hires', p_hire::text, '{}'::jsonb);
  return public.hire_json(p_hire, 'venue');
end;
$$;

create function public.hire_withdraw(p_actor uuid, p_hire uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  select * into h from public.site_hires x where x.id = p_hire for update;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'organizer' then raise exception 'This hire is not available.'; end if;
  if h.status not in ('requested', 'offered') then raise exception 'This request is no longer open.'; end if;
  update public.site_hire_offers set status = 'withdrawn' where hire = p_hire and status = 'sent';
  update public.site_hires set status = 'withdrawn' where id = p_hire;
  return public.hire_json(p_hire, 'organizer');
end;
$$;

-- The organizer agrees to the offer exactly as it stands.
create function public.hire_agree(p_actor uuid, p_hire uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
  v_offer uuid;
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  select * into h from public.site_hires x where x.id = p_hire for update;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'organizer' then raise exception 'This hire is not available.'; end if;
  if h.status <> 'offered' or h.event_date <= current_date then raise exception 'There is no offer to agree to.'; end if;
  select o.id into v_offer from public.site_hire_offers o where o.hire = p_hire and o.status = 'sent' and o.valid_until > now();
  if v_offer is null then raise exception 'This offer has expired. Ask the venue for a new one.'; end if;
  if exists (select 1 from public.site_hires x where x.venue_profile = h.venue_profile and x.event_date = h.event_date and x.status = 'confirmed') then raise exception 'This venue is already booked for a hire that day.'; end if;
  update public.site_hire_offers set status = 'accepted' where id = v_offer;
  update public.site_hires set status = 'agreed' where id = p_hire;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'hire.agreed', 'site_hires', p_hire::text, jsonb_build_object('offer', v_offer));
  return public.hire_json(p_hire, 'organizer');
end;
$$;

-- The venue confirms the space and the date. Only now is it a booked hire.
create function public.hire_confirm(p_actor uuid, p_hire uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
  v_conv uuid;
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  select * into h from public.site_hires x where x.id = p_hire for update;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'venue' then raise exception 'This hire is not available.'; end if;
  if h.status <> 'agreed' or h.event_date <= current_date then raise exception 'This hire is not waiting for your confirmation.'; end if;
  if exists (select 1 from public.site_hires x where x.venue_profile = h.venue_profile and x.event_date = h.event_date and x.status = 'confirmed') then raise exception 'This venue is already booked for a hire that day.'; end if;
  update public.site_hires set status = 'confirmed', confirmed_at = clock_timestamp() where id = p_hire;
  v_conv := public.chat_link_ensure('event', p_hire, 'Event: ' || h.event_type, h.venue_profile);
  if h.organizer is not null then perform public.chat_link_join(v_conv, h.organizer); end if;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'hire.confirmed', 'site_hires', p_hire::text, jsonb_build_object('event_date', h.event_date));
  return public.hire_json(p_hire, 'venue');
end;
$$;

-- Either side can cancel an agreed or confirmed hire before its day. (A request not yet agreed is declined or withdrawn instead.)
create function public.hire_cancel(p_actor uuid, p_hire uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
  v_side text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  select * into h from public.site_hires x where x.id = p_hire for update;
  v_side := case when found then public.hire_side(p_actor, p_hire) end;
  if v_side is null then raise exception 'This hire is not available.'; end if;
  if h.status not in ('agreed', 'confirmed') then raise exception 'Only an agreed or confirmed hire can be cancelled.'; end if;
  if h.event_date <= current_date then raise exception 'The date has come: this hire can no longer be cancelled.'; end if;
  if v_reason is not null and char_length(v_reason) > 300 then raise exception 'Keep the reason to 300 characters.'; end if;
  if not public.social_text_ok(v_reason) then raise exception 'That wording is not allowed here.'; end if;
  update public.site_hires set status = 'cancelled', cancelled_by = v_side, cancel_reason = v_reason where id = p_hire;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'hire.cancelled', 'site_hires', p_hire::text, jsonb_build_object('by', v_side, 'was', h.status));
  return public.hire_json(p_hire, v_side);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Venue hire: reading
-- ---------------------------------------------------------------------------
create function public.hire_get(p_actor uuid, p_hire uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_side text;
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  v_side := public.hire_side(p_actor, p_hire);
  if v_side is null then raise exception 'This hire is not available.'; end if;
  return public.hire_json(p_hire, v_side);
end;
$$;

-- The hires an event group (or promoter) has asked for.
create function public.hires_mine(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  return coalesce((select jsonb_agg(public.hire_json(h.id, 'organizer') order by h.created_at desc, h.id) from public.site_hires h where h.organizer = p_actor), '[]'::jsonb);
end;
$$;

-- The requests a venue has had.
create function public.hires_for(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  if not exists (select 1 from public.site_profiles s where s.id = p_actor and s.kind = 'business' and s.category = 'venue') then raise exception 'Only a venue profile has hire requests.'; end if;
  return coalesce((select jsonb_agg(public.hire_json(h.id, 'venue') order by h.created_at desc, h.id) from public.site_hires h where h.venue_profile = p_actor), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. The event workspace
-- ---------------------------------------------------------------------------
create function public.hire_item_json(p_item uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('id', i.id, 'kind', i.kind, 'title', i.title, 'at_time', to_char(i.at_time, 'HH24:MI'), 'due_on', i.due_on, 'done', i.done, 'side', i.side, 'created_at', i.created_at)
    from public.site_hire_items i where i.id = p_item
$$;

-- Is the workspace open? From the agreement on, and only for a hire still on.
create function public.hire_workspace_open(p_hire uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.site_hires h where h.id = p_hire and h.status in ('agreed', 'confirmed') and h.event_date >= current_date)
$$;

create function public.hire_item_add(p_actor uuid, p_hire uuid, p_kind text, p_title text, p_at time, p_due date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_side text;
  v_title text := btrim(coalesce(p_title, ''));
  v_id uuid;
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  v_side := public.hire_side(p_actor, p_hire);
  if v_side is null then raise exception 'This hire is not available.'; end if;
  if not public.hire_workspace_open(p_hire) then raise exception 'The workspace opens once the hire is agreed.'; end if;
  if p_kind is null or p_kind not in ('task', 'schedule') then raise exception 'Choose a task or a schedule item.'; end if;
  if char_length(v_title) < 2 or char_length(v_title) > 120 then raise exception 'Give it a title of 2 to 120 characters.'; end if;
  if not public.social_text_ok(v_title) then raise exception 'That wording is not allowed here.'; end if;
  if p_kind = 'schedule' and p_at is null then raise exception 'Say what time it is.'; end if;
  if p_kind = 'task' and p_due is not null and (p_due < current_date or p_due > current_date + 730) then raise exception 'Choose a due date from today to two years from now.'; end if;
  if (select count(*) from public.site_hire_items i where i.hire = p_hire) >= 60 then raise exception 'A workspace holds up to 60 items.'; end if;
  insert into public.site_hire_items (hire, kind, title, at_time, due_on, side, created_by)
  values (p_hire, p_kind, v_title, case when p_kind = 'schedule' then p_at end, case when p_kind = 'task' then p_due end, v_side, auth.uid()) returning id into v_id;
  return public.hire_item_json(v_id);
end;
$$;

create function public.hire_item_set(p_actor uuid, p_item uuid, p_title text, p_done boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.site_hire_items;
  v_title text := btrim(coalesce(p_title, ''));
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  select * into i from public.site_hire_items x where x.id = p_item for update;
  if not found or public.hire_side(p_actor, i.hire) is null then raise exception 'This item is not available.'; end if;
  if not public.hire_workspace_open(i.hire) then raise exception 'The workspace opens once the hire is agreed.'; end if;
  if p_title is not null then
    if char_length(v_title) < 2 or char_length(v_title) > 120 then raise exception 'Give it a title of 2 to 120 characters.'; end if;
    if not public.social_text_ok(v_title) then raise exception 'That wording is not allowed here.'; end if;
  end if;
  update public.site_hire_items set title = case when p_title is null then title else v_title end, done = coalesce(p_done, done) where id = p_item;
  return public.hire_item_json(p_item);
end;
$$;

create function public.hire_item_remove(p_actor uuid, p_item uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.site_hire_items;
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  select * into i from public.site_hire_items x where x.id = p_item for update;
  if not found or public.hire_side(p_actor, i.hire) is null then raise exception 'This item is not available.'; end if;
  delete from public.site_hire_items where id = p_item;
end;
$$;

-- The organizer attaches a professional it has booked on the day (from "Hiring professionals"). The venue sees who is on the bill and whether their deposit is in, never the money.
create function public.hire_attach_booking(p_actor uuid, p_hire uuid, p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
  b public.site_pro_bookings;
  v_conv uuid;
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  select * into h from public.site_hires x where x.id = p_hire for update;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'organizer' then raise exception 'This hire is not available.'; end if;
  if h.status <> 'confirmed' or h.event_date < current_date then raise exception 'Attach professionals once the venue has confirmed the date.'; end if;
  select * into b from public.site_pro_bookings k where k.id = p_booking;
  if not found or b.client is distinct from auth.uid() then raise exception 'This booking is not available.'; end if;
  if b.status in ('cancelled') or public.market_booking_state(p_booking) in ('expired', 'cancelled') then raise exception 'This booking is not active.'; end if;
  if b.event_date <> h.event_date then raise exception 'This booking is for a different day.'; end if;
  if exists (select 1 from public.site_hire_bookings x where x.booking = p_booking) then raise exception 'This booking is already attached to a hire.'; end if;
  if (select count(*) from public.site_hire_bookings x where x.hire = p_hire) >= 30 then raise exception 'A hire holds up to 30 professionals.'; end if;
  insert into public.site_hire_bookings (hire, booking, attached_by) values (p_hire, p_booking, auth.uid());
  select l.conversation into v_conv from public.site_chat_links l where l.kind = 'event' and l.ref = p_hire;
  if v_conv is not null and b.provider is not null then perform public.chat_link_join(v_conv, b.provider); end if;
  return jsonb_build_object('booking', p_booking, 'attached', true);
end;
$$;

create function public.hire_detach_booking(p_actor uuid, p_hire uuid, p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  if public.hire_side(p_actor, p_hire) is distinct from 'organizer' then raise exception 'This hire is not available.'; end if;
  delete from public.site_hire_bookings where hire = p_hire and booking = p_booking;
  if not found then raise exception 'This booking is not attached.'; end if;
  select * into b from public.site_pro_bookings k where k.id = p_booking;
  if b.provider is not null then perform public.chat_link_leave('event', p_hire, b.provider); end if;
end;
$$;

-- The group links a confirmed hire to the public event it runs (an event of a business the caller is an owner or organizer of, at this venue or at none yet, on the day or next to it).
create function public.hire_link_event(p_actor uuid, p_hire uuid, p_event uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_hires;
  e public.site_events;
  v_venue uuid;
  v_day date;
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  select * into h from public.site_hires x where x.id = p_hire for update;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'organizer' then raise exception 'This hire is not available.'; end if;
  if h.status <> 'confirmed' then raise exception 'Link an event once the venue has confirmed the date.'; end if;
  select * into e from public.site_events x where x.id = p_event;
  if not found or e.org_id is null or not public.is_org_member(e.org_id, array['owner', 'organizer']) then raise exception 'You can only link an event your own business runs.'; end if;
  select s.venue_id into v_venue from public.site_profiles s where s.id = h.venue_profile;
  if e.venue_id is not null and v_venue is not null and e.venue_id <> v_venue then raise exception 'That event is at another venue.'; end if;
  v_day := (e.start_date at time zone public.venue_timezone(coalesce(e.venue_id, v_venue)))::date;
  if v_day < h.event_date - 1 or v_day > h.event_date + 1 then raise exception 'That event is on a different day.'; end if;
  update public.site_hires set event_id = p_event where id = p_hire;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'hire.event_linked', 'site_hires', p_hire::text, jsonb_build_object('event', p_event));
  return public.hire_json(p_hire, 'organizer');
end;
$$;

create function public.hire_unlink_event(p_actor uuid, p_hire uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  if public.hire_side(p_actor, p_hire) is distinct from 'organizer' then raise exception 'This hire is not available.'; end if;
  update public.site_hires set event_id = null where id = p_hire;
  return public.hire_json(p_hire, 'organizer');
end;
$$;

-- The events the group could link to a confirmed hire: published events of a business the caller is an owner or organizer of, at this venue (or at none yet), on the day or next to it,
-- that are not linked to another hire already.
create function public.hire_events_linkable(p_actor uuid, p_hire uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  h public.site_hires;
  v_venue uuid;
begin
  perform public.hire_require_on();
  perform public.profile_require_permission(p_actor, 'bookings');
  select * into h from public.site_hires x where x.id = p_hire;
  if not found or public.hire_side(p_actor, p_hire) is distinct from 'organizer' then raise exception 'This hire is not available.'; end if;
  select s.venue_id into v_venue from public.site_profiles s where s.id = h.venue_profile;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'start_date', e.start_date) order by e.start_date, e.id)
      from public.site_events e
     where e.org_id is not null and public.is_org_member(e.org_id, array['owner', 'organizer'])
       and e.status = 'published'
       and (e.venue_id is null or v_venue is null or e.venue_id = v_venue)
       and (e.start_date at time zone public.venue_timezone(coalesce(e.venue_id, v_venue)))::date between h.event_date - 1 and h.event_date + 1
       and not exists (select 1 from public.site_hires o where o.event_id = e.id and o.id <> p_hire and o.status in ('agreed', 'confirmed'))
  ), '[]'::jsonb);
end;
$$;

-- Everything about a hire in one place, for either side: the terms, the schedule and tasks, the lineup, the public event with its ticket numbers, what is still pending, and the chats.
create function public.hire_workspace(p_actor uuid, p_hire uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  h public.site_hires;
  v_side text;
  v_state text;
  v_pending jsonb := '[]'::jsonb;
  v_event jsonb;
  v_bookings jsonb;
  v_tasks int;
  v_sold bigint;
  v_cap bigint;
begin
  perform public.hire_require_on();
  perform public.profile_require_actor(p_actor);
  v_side := public.hire_side(p_actor, p_hire);
  if v_side is null then raise exception 'This hire is not available.'; end if;
  select * into h from public.site_hires x where x.id = p_hire;
  v_state := public.hire_state(p_hire);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', k.id, 'title', k.title, 'provider', public.profile_mini(k.provider), 'state', public.market_booking_state(k.id),
           'confirmed', public.market_booking_state(k.id) in ('confirmed', 'paid', 'done', 'completed')) order by hb.created_at, k.id), '[]'::jsonb)
    into v_bookings
    from public.site_hire_bookings hb join public.site_pro_bookings k on k.id = hb.booking where hb.hire = p_hire;

  if h.event_id is null then
    v_event := null;
  else
    select coalesce(sum(t.sold_count), 0), coalesce(sum(t.capacity), 0) into v_sold, v_cap from public.site_ticket_tiers t where t.event_id = h.event_id;
    select jsonb_build_object('id', e.id, 'title', e.title, 'start_date', e.start_date, 'status', e.status, 'tickets_sold', v_sold, 'tickets_capacity', v_cap) into v_event from public.site_events e where e.id = h.event_id;
  end if;

  select count(*) into v_tasks from public.site_hire_items i where i.hire = p_hire and i.kind = 'task' and not i.done;
  if v_state = 'agreed' then v_pending := v_pending || to_jsonb('The venue has not confirmed the date yet.'::text); end if;
  if v_state = 'offered' then v_pending := v_pending || to_jsonb(case when v_side = 'organizer' then 'There is an offer waiting for your answer.' else 'Waiting for the group to answer your offer.' end); end if;
  if v_state = 'requested' then v_pending := v_pending || to_jsonb(case when v_side = 'venue' then 'This request is waiting for your offer.' else 'Waiting for the venue to make an offer.' end); end if;
  if v_state = 'confirmed' and h.event_id is null then v_pending := v_pending || to_jsonb('No public event is linked yet.'::text); end if;
  if v_state = 'confirmed' then
    select v_pending || coalesce(jsonb_agg(to_jsonb(format('%s has not been paid for yet.', coalesce(pr.display_name, 'A professional')))), '[]'::jsonb) into v_pending
      from public.site_hire_bookings hb join public.site_pro_bookings k on k.id = hb.booking left join public.site_profiles pr on pr.id = k.provider
     where hb.hire = p_hire and public.market_booking_state(k.id) in ('awaiting_deposit', 'confirmed');
  end if;
  if v_tasks > 0 then v_pending := v_pending || to_jsonb(format('%s open task%s.', v_tasks, case when v_tasks = 1 then '' else 's' end)); end if;

  return jsonb_build_object(
    'hire', public.hire_json(p_hire, v_side),
    'side', v_side,
    'open', public.hire_workspace_open(p_hire),
    'items', coalesce((select jsonb_agg(public.hire_item_json(i.id) order by (i.kind = 'schedule') desc, i.at_time, i.due_on nulls last, i.created_at, i.id) from public.site_hire_items i where i.hire = p_hire), '[]'::jsonb),
    'bookings', v_bookings,
    'event', v_event,
    'pending', v_pending,
    'hire_chat', (select l.conversation from public.site_chat_links l where l.kind = 'hire' and l.ref = p_hire),
    'event_chat', (select l.conversation from public.site_chat_links l where l.kind = 'event' and l.ref = p_hire));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.team_require_on(), public.hire_require_on(), public.team_role_permissions(text), public.chat_link_ensure(text, uuid, text, uuid), public.chat_link_join(uuid, uuid),
  public.chat_link_leave(text, uuid, uuid), public.personal_profile_of(uuid), public.team_require_owner(uuid), public.team_member_json(uuid),
  public.team_invite(uuid, text, text, text[]), public.team_answer(uuid, boolean), public.team_revoke(uuid, uuid), public.team_leave(uuid), public.team_set_role(uuid, uuid, text, text[]),
  public.team_list(uuid), public.team_invitations_mine(), public.team_my_access(uuid), public.hire_state(uuid), public.hire_offer_json(uuid), public.hire_json(uuid, text),
  public.hire_side(uuid, uuid),
  public.hire_request(uuid, uuid, date, text, text, int, text, text, text, int, text),
  public.hire_offer_send(uuid, uuid, int, int, int, int, text, text, text, text, text, int), public.hire_offer_withdraw(uuid, uuid), public.hire_offer_decline(uuid, uuid),
  public.hire_decline(uuid, uuid, text), public.hire_withdraw(uuid, uuid), public.hire_agree(uuid, uuid), public.hire_confirm(uuid, uuid), public.hire_cancel(uuid, uuid, text),
  public.hire_get(uuid, uuid), public.hires_mine(uuid), public.hires_for(uuid), public.hire_item_json(uuid), public.hire_workspace_open(uuid),
  public.hire_item_add(uuid, uuid, text, text, time, date), public.hire_item_set(uuid, uuid, text, boolean), public.hire_item_remove(uuid, uuid),
  public.hire_attach_booking(uuid, uuid, uuid), public.hire_detach_booking(uuid, uuid, uuid), public.hire_link_event(uuid, uuid, uuid), public.hire_unlink_event(uuid, uuid),
  public.hire_events_linkable(uuid, uuid), public.hire_workspace(uuid, uuid)
from public, anon, authenticated;
grant execute on function
  public.team_invite(uuid, text, text, text[]), public.team_answer(uuid, boolean), public.team_revoke(uuid, uuid), public.team_leave(uuid), public.team_set_role(uuid, uuid, text, text[]),
  public.team_list(uuid), public.team_invitations_mine(), public.team_my_access(uuid),
  public.hire_request(uuid, uuid, date, text, text, int, text, text, text, int, text),
  public.hire_offer_send(uuid, uuid, int, int, int, int, text, text, text, text, text, int), public.hire_offer_withdraw(uuid, uuid), public.hire_offer_decline(uuid, uuid),
  public.hire_decline(uuid, uuid, text), public.hire_withdraw(uuid, uuid), public.hire_agree(uuid, uuid), public.hire_confirm(uuid, uuid), public.hire_cancel(uuid, uuid, text),
  public.hire_get(uuid, uuid), public.hires_mine(uuid), public.hires_for(uuid),
  public.hire_item_add(uuid, uuid, text, text, time, date), public.hire_item_set(uuid, uuid, text, boolean), public.hire_item_remove(uuid, uuid),
  public.hire_attach_booking(uuid, uuid, uuid), public.hire_detach_booking(uuid, uuid, uuid), public.hire_link_event(uuid, uuid, uuid), public.hire_unlink_event(uuid, uuid),
  public.hire_events_linkable(uuid, uuid), public.hire_workspace(uuid, uuid)
to authenticated;
