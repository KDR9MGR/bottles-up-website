-- Team and invitations: what the Team screen reads, and a safe way to email an invitation link.
--
-- Client Phase 2 brief, section 12 and website brief section 3: owners appoint managers, managers
-- appoint staff for their own club, temporary staff get individual expiring links, and every state of an
-- invitation (pending, accepted, expired, revoked) is visible. The write side already exists in
-- 20261006120000_tenancy_foundation.sql (invite_member, resend_invitation, revoke_invitation,
-- revoke_membership, create_shift); this adds the read side and the email bookkeeping.
--
-- Who may do what is NOT re-implemented here: every read and every send defers to can_view_membership()
-- and can_invite_role(), so there is one definition of the rules. Additive only.

-- ---------------------------------------------------------------------------
-- Email bookkeeping on invitations
-- ---------------------------------------------------------------------------
-- The count belongs to one link: sending a fresh link (resend_invitation rotates the token) starts again.
-- These columns are deliberately not granted to the app; they are only reachable through the functions below.
alter table public.site_invitations
  add column email_token_hash bytea,
  add column email_sent_at timestamptz,
  add column email_send_count int not null default 0;

-- ---------------------------------------------------------------------------
-- What the invite form may offer
-- ---------------------------------------------------------------------------
-- The roles the caller may appoint at a venue, straight from can_invite_role() so the screen can never offer
-- something the database would refuse (and never hides something it would allow).
create function public.invitable_roles(p_org uuid, p_venue uuid)
returns setof text
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return query
    select r
    from unnest(array['manager', 'server', 'door', 'security', 'verifier']) as r
    where public.can_invite_role(p_org, r, p_venue, null);
end;
$$;

-- ---------------------------------------------------------------------------
-- The team
-- ---------------------------------------------------------------------------
-- Members of an organization the caller may see: an owner sees everyone, a manager only the staff of their
-- own club (never the owner or another club's people), an organizer the people on their events. 'state' is
-- what a person would call it: active, scheduled (not started yet), expired (window or shift over), revoked.
create function public.list_team(p_org uuid)
returns table (
  membership_id uuid, user_id uuid, email text, name text, role text,
  venue_id uuid, venue_name text, event_id uuid, event_title text, shift_id uuid, shift_name text,
  access_start_at timestamptz, access_end_at timestamptz, state text, created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not (public.is_org_member(p_org) or public.is_cms_admin()) then raise exception 'not allowed'; end if;
  return query
    select m.id, m.user_id, u.email::text, p.name, m.role,
           m.venue_id, v.name, m.event_id, e.title, m.shift_id, s.name,
           m.access_start_at, m.access_end_at,
           case
             when m.status = 'revoked' then 'revoked'
             when m.access_end_at is not null and m.access_end_at < now() then 'expired'
             when s.id is not null and s.ends_at < now() then 'expired'
             when m.access_start_at is not null and m.access_start_at > now() then 'scheduled'
             when s.id is not null and s.starts_at > now() then 'scheduled'
             else 'active'
           end,
           m.created_at
    from public.site_memberships m
    join auth.users u on u.id = m.user_id
    left join public.profiles p on p.id = m.user_id
    left join public.site_venues v on v.id = m.venue_id
    left join public.site_events e on e.id = m.event_id
    left join public.site_shifts s on s.id = m.shift_id
    where m.org_id = p_org
      and (public.is_cms_admin() or public.can_view_membership(m.org_id, m.venue_id, m.event_id))
    order by (m.role in ('owner', 'organizer')) desc, (m.role = 'manager') desc,
             lower(coalesce(p.name, u.email::text)), m.created_at;
end;
$$;

-- Invitations the caller may manage, with the state the client asked for (pending, accepted, expired,
-- revoked), the scope and window, and how many times the current link has been emailed. Never the link.
create function public.list_team_invitations(p_org uuid)
returns table (
  invitation_id uuid, email text, role text,
  venue_id uuid, venue_name text, event_id uuid, event_title text, shift_id uuid, shift_name text,
  access_start_at timestamptz, access_end_at timestamptz,
  state text, expires_at timestamptz, created_at timestamptz,
  emails_sent int, last_emailed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not (public.is_org_member(p_org) or public.is_cms_admin()) then raise exception 'not allowed'; end if;
  return query
    select i.id, i.email, i.role,
           i.venue_id, v.name, i.event_id, e.title, i.shift_id, s.name,
           i.access_start_at, i.access_end_at,
           case when i.status = 'pending' and i.expires_at < now() then 'expired' else i.status end,
           i.expires_at, i.created_at,
           case when i.email_token_hash is not distinct from i.token_hash then i.email_send_count else 0 end,
           case when i.email_token_hash is not distinct from i.token_hash then i.email_sent_at end
    from public.site_invitations i
    left join public.site_venues v on v.id = i.venue_id
    left join public.site_events e on e.id = i.event_id
    left join public.site_shifts s on s.id = i.shift_id
    where i.org_id = p_org
      and (public.is_cms_admin() or public.can_view_membership(i.org_id, i.venue_id, i.event_id))
    order by i.created_at desc;
end;
$$;

-- The upcoming and recent shifts of a venue, for the invite form's shift picker.
create function public.list_shifts(p_venue uuid)
returns table (shift_id uuid, name text, starts_at timestamptz, ends_at timestamptz, event_id uuid, event_title text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  return query
    select s.id, s.name, s.starts_at, s.ends_at, s.event_id, e.title
    from public.site_shifts s
    left join public.site_events e on e.id = s.event_id
    where s.venue_id = p_venue and s.ends_at > now() - interval '2 days'
    order by s.starts_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- Emailing an invitation link
-- ---------------------------------------------------------------------------
-- Called by the send-team-invitation edge function with the CALLER's session. It is what makes emailing safe:
--   * there is no address argument: the only recipient is the one stored on the invitation, so this cannot be
--     used to send BottlesUp-branded mail to anyone else;
--   * the caller must be allowed to manage this invitation AND hold the link token (which only the person who
--     created or resent it was given), and the token must still be the current one;
--   * at most 3 sends per link, at least a minute apart, so it cannot be used to spam the invited person.
-- It records the attempt before the mail is sent, so concurrent calls cannot slip past the limit.
create function public.reserve_invitation_email(p_invitation uuid, p_token text)
returns table (
  invitee_email text, role text, org_name text, venue_name text, event_title text, shift_name text,
  access_start_at timestamptz, access_end_at timestamptz, expires_at timestamptz, inviter_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.site_invitations%rowtype;
  v_count int;
  v_last timestamptz;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;

  select * into i from public.site_invitations x where x.id = p_invitation for update;
  if not found
     or not public.can_invite_role(i.org_id, i.role, i.venue_id, i.event_id)
     or i.token_hash is distinct from sha256(convert_to(coalesce(p_token, ''), 'utf8')) then
    raise exception 'not allowed';
  end if;
  if i.status <> 'pending' or i.expires_at < now() then raise exception 'invitation is not pending'; end if;

  if i.email_token_hash is not distinct from i.token_hash then
    v_count := i.email_send_count;
    v_last := i.email_sent_at;
  else
    v_count := 0;
    v_last := null;
  end if;
  if v_count >= 3 then raise exception 'email limit reached for this link'; end if;
  if v_last is not null and v_last > now() - interval '60 seconds' then
    raise exception 'please wait a minute before sending again';
  end if;

  update public.site_invitations
    set email_token_hash = i.token_hash, email_send_count = v_count + 1, email_sent_at = now()
    where id = i.id;

  return query
    select i.email, i.role, o.name, v.name, e.title, s.name,
           i.access_start_at, i.access_end_at, i.expires_at,
           coalesce(p.name, u.email::text)
    from public.site_organizations o
    left join public.site_venues v on v.id = i.venue_id
    left join public.site_events e on e.id = i.event_id
    left join public.site_shifts s on s.id = i.shift_id
    left join auth.users u on u.id = i.invited_by
    left join public.profiles p on p.id = i.invited_by
    where o.id = i.org_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function
  public.invitable_roles(uuid, uuid), public.list_team(uuid), public.list_team_invitations(uuid),
  public.list_shifts(uuid), public.reserve_invitation_email(uuid, text)
  from public, anon;
grant execute on function
  public.invitable_roles(uuid, uuid), public.list_team(uuid), public.list_team_invitations(uuid),
  public.list_shifts(uuid), public.reserve_invitation_email(uuid, text)
  to authenticated, service_role;
