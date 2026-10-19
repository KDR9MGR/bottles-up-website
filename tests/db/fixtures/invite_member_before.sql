-- The invite_member() that supabase/migrations/20261006120000_tenancy_foundation.sql defines: the version BEFORE the organizer door staff rule. Tests use it to put
-- a database into the "before" state. Copied verbatim from that migration; do not edit.
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
