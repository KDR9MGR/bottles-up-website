-- Organizer-provided door staff, when the club permits it (developer brief 15 Oct, "Latest decisions": "Organizers can invite their own door staff when the venue
-- permits it"; section 25: "Agreement setting: Allow Organizer Door Staff - Yes / No. Once approved, organizer invites within agreed permissions ... Venue managers
-- see assignments and can revoke venue access. Door staff cannot change pricing, issue refunds or access banking").
--
-- THE RULE (decided in the database, not by hiding buttons): an organizer may invite door staff for an event only if
--   * the event has NO connection with a club (the organizer's own event: as before), or
--   * the event's club agreement is APPROVED (active, or changes proposed on top of an agreed version) AND the club has ALLOWED organizer door staff on it.
-- The club's permission is a switch on the agreement, off until the club turns it on. Turning it off also cancels the invitations still waiting; people already
-- in keep their access until the club (or the organizer) removes them one by one.
--
--   * site_agreements.organizer_door_staff   the club's permission (additive column, false by default; no row is changed)
--   * event_door_allowed(event)              the rule above (internal)
--   * invite_member(...)                     REPLACED, compare-and-swap (see below): the same function plus ONE line that applies the rule to event invitations
--   * organizer_event_door_status(org)       for the organizer: per event, own event / allowed / not allowed / awaiting the club's approval
--   * venue_door_permissions(venue)          for the club's owner or manager: each live agreement and whether door staff is allowed
--   * set_organizer_door_staff(agreement, allowed)   the club turns it on or off
--   * venue_event_door_staff(venue)          the organizers' door staff and invitations at the club's events: who, which event, state
--   * revoke_event_door_access(membership | invitation)   the club takes someone's access away (the organizer already can, through revoke_membership)
--
-- GUARD for the one replaced live function (invite_member, 20261006120000, in production since 16 Oct): it is replaced only if it is exactly the version this
-- repository has; if it already has the rule nothing is replaced; anything else STOPS, changes nothing. Everything is one statement: all or nothing.
-- Needs the tenancy, team invitations, organizer events and event agreements migrations.

do $migration$
declare
  v_live text;
  v_src text;
  c_before constant text := 'cada6eec917b99ecd953f4c4dcb64040';  -- invite_member as 20261006120000 defines it
begin
  select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, '')), p.prosrc
    into v_live, v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'invite_member'
     and pg_get_function_identity_arguments(p.oid) = 'p_org uuid, p_email text, p_role text, p_venue uuid, p_event uuid, p_shift uuid, p_access_start timestamp with time zone, p_access_end timestamp with time zone, p_valid_for interval';
  if v_live is null then
    raise exception 'public.invite_member does not exist in this database. Nothing was changed.';
  end if;
  if position('event_door_allowed' in v_src) > 0 then
    raise notice 'invite_member() already applies the door staff rule: this change is already applied. Nothing was changed.';
    return;
  end if;
  if v_live <> c_before then
    raise exception 'invite_member() in this database differs from the version this change was written against (live fingerprint %, expected %). It was NOT replaced, because that could undo a change made directly in the database. Inspect it with \sf public.invite_member and reconcile by hand. Nothing was changed.', v_live, c_before;
  end if;

  execute $sql$ alter table public.site_agreements add column organizer_door_staff boolean not null default false $sql$;

  execute $sql$
    create function public.event_door_allowed(p_event uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = public
    as $$
      select case
        when not exists (select 1 from public.site_agreements a where a.event_id = p_event and a.status not in ('declined', 'cancelled')) then true
        else exists (
          select 1 from public.site_agreements a
           where a.event_id = p_event
             and (a.status = 'active' or (a.status = 'changes_pending' and a.active_version is not null))
             and a.organizer_door_staff
        )
      end
    $$
  $sql$;

  execute $sql$
    create or replace function public.invite_member(
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
      if p_event is not null and not public.event_door_allowed(p_event) then
        raise exception 'the club has not allowed door staff for this event';
      end if;
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
    $$
  $sql$;

  execute $sql$
    create function public.organizer_event_door_status(p_org uuid)
    returns table (event_id uuid, event_title text, state text, agreement_id uuid, club_name text)
    language plpgsql
    stable
    security definer
    set search_path = public
    as $$
    #variable_conflict use_column
    begin
      perform public.require_org_organizer(p_org);
      return query
        select e.id, e.title,
               case
                 when a.id is null then 'own_event'
                 when not (a.status = 'active' or (a.status = 'changes_pending' and a.active_version is not null)) then 'awaiting_approval'
                 when a.organizer_door_staff then 'allowed'
                 else 'not_allowed'
               end,
               a.id, v.name
          from public.site_events e
          left join lateral (
            select ag.* from public.site_agreements ag
             where ag.event_id = e.id and ag.organizer_org_id = p_org and ag.status not in ('declined', 'cancelled')
             order by (ag.status = 'active' or (ag.status = 'changes_pending' and ag.active_version is not null)) desc, ag.requested_at desc limit 1
          ) a on true
          left join public.site_venues v on v.id = a.venue_id
         where e.org_id = p_org
         order by e.start_date desc, e.created_at desc;
    end;
    $$
  $sql$;

  execute $sql$
    create function public.venue_door_permissions(p_venue uuid)
    returns table (agreement_id uuid, event_id uuid, event_title text, event_start timestamptz, organizer_name text, agreement_status text, approved boolean, door_staff_allowed boolean)
    language plpgsql
    stable
    security definer
    set search_path = public
    as $$
    #variable_conflict use_column
    begin
      perform public.require_venue_editor(p_venue);
      return query
        select a.id, e.id, e.title, e.start_date, o.name, a.status,
               (a.status = 'active' or (a.status = 'changes_pending' and a.active_version is not null)),
               a.organizer_door_staff
          from public.site_agreements a
          join public.site_events e on e.id = a.event_id
          join public.site_organizations o on o.id = a.organizer_org_id
         where a.venue_id = p_venue and a.status not in ('declined', 'cancelled')
         order by e.start_date desc, a.requested_at desc;
    end;
    $$
  $sql$;

  execute $sql$
    create function public.set_organizer_door_staff(p_agreement uuid, p_allowed boolean)
    returns boolean
    language plpgsql
    security definer
    set search_path = public
    as $$
    declare
      a public.site_agreements;
      v_cancelled int := 0;
    begin
      if auth.uid() is null then raise exception 'not authenticated'; end if;
      if p_allowed is null then raise exception 'choose yes or no'; end if;
      select * into a from public.site_agreements where id = p_agreement for update;
      if not found or not public.can_access_venue(a.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
      if a.status in ('declined', 'cancelled') then raise exception 'this agreement has ended'; end if;
      if a.organizer_door_staff = p_allowed then return p_allowed; end if;

      update public.site_agreements set organizer_door_staff = p_allowed where id = p_agreement;
      if not p_allowed then
        update public.site_invitations i
           set status = 'revoked', revoked_at = now(), revoked_by = auth.uid()
         where i.event_id = a.event_id and i.role = 'door' and i.status = 'pending';
        get diagnostics v_cancelled = row_count;
      end if;
      perform public.desk_log('agreement.door_staff_set', 'site_agreements', p_agreement,
        jsonb_build_object('venue_id', a.venue_id, 'event_id', a.event_id, 'allowed', p_allowed, 'pending_invitations_cancelled', v_cancelled));
      return p_allowed;
    end;
    $$
  $sql$;

  execute $sql$
    create function public.venue_event_door_staff(p_venue uuid)
    returns table (membership_id uuid, invitation_id uuid, event_id uuid, event_title text, organizer_name text, person text, state text, access_start_at timestamptz, access_end_at timestamptz)
    language plpgsql
    stable
    security definer
    set search_path = public
    as $$
    #variable_conflict use_column
    begin
      perform public.require_venue_editor(p_venue);
      return query
        select m.id, null::uuid, e.id, e.title, o.name,
               coalesce(nullif(btrim(p.name), ''), u.email::text),
               case when m.status = 'revoked' then 'revoked'
                    when m.access_end_at is not null and m.access_end_at < now() then 'expired'
                    when m.access_start_at is not null and m.access_start_at > now() then 'scheduled'
                    else 'active' end,
               m.access_start_at, m.access_end_at
          from public.site_memberships m
          join public.site_events e on e.id = m.event_id
          join public.site_organizations o on o.id = m.org_id
          join auth.users u on u.id = m.user_id
          left join public.profiles p on p.id = m.user_id
         where m.role = 'door'
           and exists (select 1 from public.site_agreements a where a.event_id = m.event_id and a.venue_id = p_venue and a.status not in ('declined', 'cancelled'))
        union all
        select null::uuid, i.id, e.id, e.title, o.name, i.email,
               case when i.expires_at < now() then 'invitation_expired' else 'invited' end,
               i.access_start_at, i.access_end_at
          from public.site_invitations i
          join public.site_events e on e.id = i.event_id
          join public.site_organizations o on o.id = i.org_id
         where i.role = 'door' and i.status = 'pending'
           and exists (select 1 from public.site_agreements a where a.event_id = i.event_id and a.venue_id = p_venue and a.status not in ('declined', 'cancelled'))
         order by 4, 6;
    end;
    $$
  $sql$;

  execute $sql$
    create function public.revoke_event_door_access(p_membership uuid default null, p_invitation uuid default null)
    returns void
    language plpgsql
    security definer
    set search_path = public
    as $$
    declare
      v_event uuid;
      v_venue uuid;
    begin
      if auth.uid() is null then raise exception 'not authenticated'; end if;
      if (p_membership is null) = (p_invitation is null) then raise exception 'choose one person or one invitation'; end if;

      if p_membership is not null then
        select m.event_id into v_event from public.site_memberships m where m.id = p_membership and m.role = 'door' and m.status = 'active' for update;
      else
        select i.event_id into v_event from public.site_invitations i where i.id = p_invitation and i.role = 'door' and i.status = 'pending' for update;
      end if;
      if v_event is null then raise exception 'not allowed'; end if;

      select a.venue_id into v_venue
        from public.site_agreements a
       where a.event_id = v_event and a.status not in ('declined', 'cancelled') and public.can_access_venue(a.venue_id, array['owner', 'manager'])
       limit 1;
      if v_venue is null then raise exception 'not allowed'; end if;

      if p_membership is not null then
        update public.site_memberships set status = 'revoked', revoked_at = now(), revoked_by = auth.uid() where id = p_membership;
      else
        update public.site_invitations set status = 'revoked', revoked_at = now(), revoked_by = auth.uid() where id = p_invitation;
      end if;
      perform public.desk_log('event_door_staff.revoked_by_club', case when p_membership is not null then 'site_memberships' else 'site_invitations' end, coalesce(p_membership, p_invitation),
        jsonb_build_object('venue_id', v_venue, 'event_id', v_event));
    end;
    $$
  $sql$;

  execute $sql$ revoke all on function public.event_door_allowed(uuid) from public, anon, authenticated $sql$;
  execute $sql$
    revoke all on function public.organizer_event_door_status(uuid), public.venue_door_permissions(uuid), public.set_organizer_door_staff(uuid, boolean),
      public.venue_event_door_staff(uuid), public.revoke_event_door_access(uuid, uuid) from public, anon
  $sql$;
  execute $sql$
    grant execute on function public.organizer_event_door_status(uuid), public.venue_door_permissions(uuid), public.set_organizer_door_staff(uuid, boolean),
      public.venue_event_door_staff(uuid), public.revoke_event_door_access(uuid, uuid) to authenticated, service_role
  $sql$;

  raise notice 'organizer door staff recorded: the club''s permission, the rule in invite_member(), and the organizer and club views.';
end
$migration$;
