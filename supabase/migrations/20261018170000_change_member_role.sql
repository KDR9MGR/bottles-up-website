-- Changing a person's role at a club (client Phase 2 brief, section 12: "Owner-to-manager-to-staff delegation", "role change").
--
-- Until now moving someone from server to verifier meant removing them and inviting them again. This does it in one step, with the same
-- rules as inviting and removing: whoever may APPOINT the new role at that club, and may REMOVE the old one, may change it. A role change
--   * is one transaction: the old membership is revoked (with who and when, so earlier actions stay attributable) and the new one starts
--     at once, with the same club, shift and access window, so the person is never without or doubly in access;
--   * is for a club role only: owners and organizers are a platform-admin matter, and an event role (door) has nothing to change to;
--   * is never for yourself, never to the role the person already has, and a manager cannot be given a shift (a manager has a club);
--   * is attributed in the audit log.
-- Plain CREATE, never CREATE OR REPLACE. Needs the tenancy migration.

create function public.change_member_role(p_membership uuid, p_new_role text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_m public.site_memberships%rowtype;
  v_new uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_new_role is null or p_new_role not in ('manager', 'server', 'door', 'security', 'verifier') then raise exception 'choose a role'; end if;

  select * into v_m from public.site_memberships m where m.id = p_membership for update;
  if not found or v_m.status <> 'active' then raise exception 'membership not found'; end if;
  if v_m.user_id = auth.uid() then raise exception 'you cannot change your own role'; end if;
  if v_m.role in ('owner', 'organizer') then raise exception 'not allowed'; end if;
  if v_m.venue_id is null then raise exception 'a role at an event cannot be changed: remove access and invite again'; end if;
  if v_m.role = p_new_role then raise exception 'they already have that role'; end if;

  -- The same rule as removing the old role and appointing the new one.
  if not public.can_invite_role(v_m.org_id, v_m.role, v_m.venue_id, null) or not public.can_invite_role(v_m.org_id, p_new_role, v_m.venue_id, null) then
    raise exception 'not allowed';
  end if;
  if p_new_role = 'manager' and v_m.shift_id is not null then raise exception 'a manager works at a club, not on a shift: remove access and invite again'; end if;
  if exists (
    select 1 from public.site_memberships x
    where x.org_id = v_m.org_id and x.user_id = v_m.user_id and x.role = p_new_role and x.status = 'active'
      and x.venue_id is not distinct from v_m.venue_id and x.event_id is not distinct from v_m.event_id and x.shift_id is not distinct from v_m.shift_id
  ) then
    raise exception 'they already have that role here';
  end if;

  update public.site_memberships set status = 'revoked', revoked_at = now(), revoked_by = auth.uid() where id = p_membership;
  insert into public.site_memberships (org_id, user_id, role, venue_id, event_id, shift_id, access_start_at, access_end_at, invited_by)
    values (v_m.org_id, v_m.user_id, p_new_role, v_m.venue_id, v_m.event_id, v_m.shift_id, v_m.access_start_at, v_m.access_end_at, auth.uid())
    returning id into v_new;
  perform public.desk_log('team.role_changed', 'site_memberships', v_new,
    jsonb_build_object('venue_id', v_m.venue_id, 'user_id', v_m.user_id, 'from', v_m.role, 'to', p_new_role, 'previous_membership', p_membership));
  return v_new;
end;
$$;

revoke all on function public.change_member_role(uuid, text) from public, anon;
grant execute on function public.change_member_role(uuid, text) to authenticated, service_role;
