-- Temporary staff: an individual, expiring link that is checked by an e-mailed code, and a way to ask for a new link (client Phase 2 brief, section 12: "Temporary staff use individual
-- secure expiring links with identity verification ... Expired links offer a request for renewed access rather than an empty error"; scenario 3 "Temporary staff invite expires/revokes: no further
-- operational access; prior actions remain attributable").
--
--   * A TEMPORARY invitation is an ordinary invitation (invite_member does the work) marked kind = 'temporary' by invite_temporary_staff: for a server, door, security or verifier only, with an END
--     to the access (an end time or a shift, which already end access by themselves: active_memberships() stops honouring the membership), and a link that lives from 1 hour to 7 days (the client has not
--     settled the default; the app suggests 24 hours and the person inviting chooses). Everything else about invitations (who may invite whom, one live link per person and scope, e-mailing, revoking)
--     is unchanged.
--   * IDENTITY CHECK: accepting a temporary link needs a 6-digit code sent to the invited e-mail address. issue_invitation_code (service role only: the code must reach the invitee ONLY by e-mail,
--     never in an answer to the app) makes the code for the signed-in person whose address is the invited one; at most one a minute and five an hour; a code lives 10 minutes. verify_invitation_code
--     checks it: five wrong guesses lock it (a new code starts again); a right one is remembered for 30 minutes on the invitation. Wrong guesses are COUNTED, so verify answers with an outcome instead of
--     raising (a raised error would undo the count). Only a hash of the code is stored.
--   * The check is enforced by the table, not the app: a trigger refuses to mark a temporary invitation accepted unless it was verified in the last 30 minutes, so the existing accept_invitation (not
--     replaced) cannot be used to skip it. A new link (resend_invitation or inviting again) clears the verification and any open code, by another trigger on the token.
--   * invitation_preview(token): what the invitee needs before accepting (whether a code is needed, the address it will go to with most of it hidden, what the access is, whether it has expired).
--   * request_invitation_renewal(token): the invitee of an EXPIRED link asks for a new one; the person who invited sees the request (list_invitation_extras) and sends a new link as usual.
--   * list_invitation_extras(org): kind, whether the identity was confirmed and any renewal request, for the invitations the caller may manage.
--
-- Additive only: new columns whose defaults change nothing (every existing invitation is permanent), one table (reached only through functions), new functions, two triggers. No existing function is
-- replaced and no row is rewritten. Needs the tenancy (20261006120000), team invitations (20261008100000) migrations; invite_member keeps working as it is.

do $guard$
declare
  fn text;
begin
  foreach fn in array array['public.invite_member(uuid, text, text, uuid, uuid, uuid, timestamptz, timestamptz, interval)', 'public.can_invite_role(uuid, text, uuid, uuid)', 'public.can_view_membership(uuid, uuid, uuid)',
                            'public.desk_log(text, text, uuid, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception '% does not exist: run the earlier tenancy and team invitation migrations first. Nothing was changed.', fn;
    end if;
  end loop;
  if to_regclass('public.site_invitations') is null then
    raise exception 'public.site_invitations must exist first. Nothing was changed.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'site_invitations' and column_name in ('kind', 'identity_verified_at', 'renewal_requested_at', 'renewal_note')) then
    raise exception 'an invitation column from this migration already exists: it was already applied, or something else made one. Nothing was changed.';
  end if;
end $guard$;

-- ---------------------------------------------------------------------------
-- 1. Columns and the code table
-- ---------------------------------------------------------------------------
alter table public.site_invitations
  add column kind text not null default 'permanent' constraint site_invitations_kind_check check (kind in ('permanent', 'temporary')),
  add column identity_verified_at timestamptz,
  add column renewal_requested_at timestamptz,
  add column renewal_note text constraint site_invitations_renewal_note_check check (renewal_note is null or char_length(renewal_note) <= 200);

-- One live code per invitation. Only a hash is kept; the code itself exists only in the e-mail.
create table public.site_invitation_codes (
  invitation_id uuid primary key references public.site_invitations (id) on delete cascade,
  code_hash bytea not null,
  expires_at timestamptz not null,
  attempts int not null default 0 check (attempts >= 0),
  sends int not null default 1 check (sends >= 1),
  window_started_at timestamptz not null default clock_timestamp(),
  last_sent_at timestamptz not null default clock_timestamp()
);
alter table public.site_invitation_codes enable row level security;
revoke all on table public.site_invitation_codes from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The table keeps the rules, whichever function is used
-- ---------------------------------------------------------------------------
-- A temporary invitation cannot become accepted unless its identity was confirmed in the last 30 minutes.
create function public.temporary_invitation_gate()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' and new.kind = 'temporary'
     and (new.identity_verified_at is null or new.identity_verified_at < now() - interval '30 minutes') then
    raise exception 'confirm your e-mail with the code we sent before using this link';
  end if;
  return new;
end;
$$;
create trigger site_invitations_temporary_gate before update of status on public.site_invitations
  for each row execute function public.temporary_invitation_gate();

-- A new link (a new token) starts again: the old confirmation, any open code and any renewal request are cleared.
create function public.invitation_new_link_resets()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.token_hash is distinct from old.token_hash then
    new.identity_verified_at := null;
    new.renewal_requested_at := null;
    new.renewal_note := null;
    delete from public.site_invitation_codes where invitation_id = new.id;
  end if;
  return new;
end;
$$;
create trigger site_invitations_new_link_resets before update of token_hash on public.site_invitations
  for each row execute function public.invitation_new_link_resets();
revoke all on function public.temporary_invitation_gate(), public.invitation_new_link_resets() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Inviting temporary staff
-- ---------------------------------------------------------------------------
create function public.invite_temporary_staff(
  p_org uuid, p_email text, p_role text,
  p_venue uuid default null, p_event uuid default null, p_shift uuid default null,
  p_access_start timestamptz default null, p_access_end timestamptz default null,
  p_valid_hours int default 24
)
returns table (invitation_id uuid, token text, valid_until timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_role is null or p_role not in ('server', 'door', 'security', 'verifier') then raise exception 'temporary access is for servers, door staff, security and verifiers'; end if;
  if p_access_end is null and p_shift is null then raise exception 'say when the access ends: an end time, or a shift'; end if;
  if p_access_end is not null and p_access_end <= now() then raise exception 'the access would already be over'; end if;
  if p_valid_hours is null or p_valid_hours < 1 or p_valid_hours > 168 then raise exception 'the link must stay valid for between 1 hour and 7 days'; end if;

  select * into r from public.invite_member(p_org, p_email, p_role, p_venue, p_event, p_shift, p_access_start, p_access_end, make_interval(hours => p_valid_hours));
  update public.site_invitations set kind = 'temporary' where id = r.invitation_id;
  perform public.desk_log('team.temporary_invitation_created', 'site_invitations', r.invitation_id,
    jsonb_build_object('org_id', p_org, 'role', p_role, 'venue_id', p_venue, 'event_id', p_event, 'shift_id', p_shift, 'valid_hours', p_valid_hours, 'access_end_at', p_access_end));
  return query select r.invitation_id, r.token, r.valid_until;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The code (service role only: it must reach the invitee only by e-mail)
-- ---------------------------------------------------------------------------
create function public.issue_invitation_code(p_token text, p_email text)
returns table (
  invitee_email text, code text, code_expires_at timestamptz, role text, org_name text, venue_name text, event_title text, shift_name text,
  access_start_at timestamptz, access_end_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.site_invitations%rowtype;
  c public.site_invitation_codes%rowtype;
  v_code text;
  v_sends int := 1;
  v_window timestamptz := clock_timestamp();
begin
  select * into i from public.site_invitations x where x.token_hash = sha256(convert_to(coalesce(p_token, ''), 'utf8')) for update;
  if not found or lower(coalesce(p_email, '')) <> i.email then raise exception 'not allowed'; end if;
  if i.kind <> 'temporary' then raise exception 'this link does not need a code'; end if;
  if i.status <> 'pending' or i.expires_at < now() then raise exception 'invitation is not pending'; end if;

  select * into c from public.site_invitation_codes x where x.invitation_id = i.id for update;
  if found then
    if c.window_started_at > now() - interval '1 hour' then
      v_window := c.window_started_at;
      v_sends := c.sends + 1;
      if c.sends >= 5 then raise exception 'too many codes: try again in an hour'; end if;
    end if;
    if c.last_sent_at > now() - interval '60 seconds' then raise exception 'please wait a minute before asking for another code'; end if;
  end if;

  -- Six digits from a random value (no pattern, no clock).
  v_code := lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into public.site_invitation_codes (invitation_id, code_hash, expires_at, attempts, sends, window_started_at, last_sent_at)
    values (i.id, sha256(convert_to(v_code || ':' || i.id::text, 'utf8')), now() + interval '10 minutes', 0, v_sends, v_window, clock_timestamp())
    on conflict (invitation_id) do update
      set code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0, sends = excluded.sends, window_started_at = excluded.window_started_at, last_sent_at = excluded.last_sent_at;

  return query
    select i.email, v_code, now() + interval '10 minutes', i.role, o.name, v.name, e.title, s.name, i.access_start_at, i.access_end_at
    from public.site_organizations o
    left join public.site_venues v on v.id = i.venue_id
    left join public.site_events e on e.id = i.event_id
    left join public.site_shifts s on s.id = i.shift_id
    where o.id = i.org_id;
end;
$$;

-- outcome: ok | wrong | malformed | locked | code_expired | no_code | not_needed | invalid | revoked | expired | already_accepted | email_mismatch
create function public.verify_invitation_code(p_token text, p_code text)
returns table (outcome text, attempts_left int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  i public.site_invitations%rowtype;
  c public.site_invitation_codes%rowtype;
  v_code text := btrim(coalesce(p_code, ''));
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.site_invitations x where x.token_hash = sha256(convert_to(coalesce(p_token, ''), 'utf8')) for update;
  if not found then return query select 'invalid'::text, null::int; return; end if;
  if i.status = 'revoked' then return query select 'revoked'::text, null::int; return; end if;
  if i.status = 'accepted' then return query select 'already_accepted'::text, null::int; return; end if;
  if i.expires_at < now() then return query select 'expired'::text, null::int; return; end if;
  if v_email <> i.email then return query select 'email_mismatch'::text, null::int; return; end if;
  if i.kind <> 'temporary' then return query select 'not_needed'::text, null::int; return; end if;
  if i.identity_verified_at is not null and i.identity_verified_at >= now() - interval '30 minutes' then return query select 'ok'::text, null::int; return; end if;

  select * into c from public.site_invitation_codes x where x.invitation_id = i.id for update;
  if not found then return query select 'no_code'::text, null::int; return; end if;
  if c.expires_at < now() then return query select 'code_expired'::text, null::int; return; end if;
  if c.attempts >= 5 then return query select 'locked'::text, 0; return; end if;
  if v_code !~ '^[0-9]{6}$' then return query select 'malformed'::text, 5 - c.attempts; return; end if;

  if c.code_hash is distinct from sha256(convert_to(v_code || ':' || i.id::text, 'utf8')) then
    update public.site_invitation_codes set attempts = attempts + 1 where invitation_id = i.id;
    return query select 'wrong'::text, 5 - (c.attempts + 1);
    return;
  end if;

  update public.site_invitations set identity_verified_at = now() where id = i.id;
  delete from public.site_invitation_codes where invitation_id = i.id;
  return query select 'ok'::text, null::int;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. What the invitee sees before accepting, and asking for a new link
-- ---------------------------------------------------------------------------
-- outcome: ok | invalid | revoked | expired | already_accepted | email_mismatch. Only 'ok' and 'expired' carry details; a wrong token or another person's link reveals nothing.
create function public.invitation_preview(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  i public.site_invitations%rowtype;
  v_expired boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.site_invitations x where x.token_hash = sha256(convert_to(coalesce(p_token, ''), 'utf8'));
  if not found then return jsonb_build_object('outcome', 'invalid'); end if;
  if i.status = 'revoked' then return jsonb_build_object('outcome', 'revoked'); end if;
  if i.status = 'accepted' then return jsonb_build_object('outcome', case when i.accepted_by = auth.uid() then 'already_accepted' else 'invalid' end); end if;
  if v_email <> i.email then return jsonb_build_object('outcome', 'email_mismatch'); end if;
  v_expired := i.expires_at < now();

  return jsonb_build_object(
    'outcome', case when v_expired then 'expired' else 'ok' end,
    'kind', i.kind,
    'needs_code', i.kind = 'temporary' and not v_expired and (i.identity_verified_at is null or i.identity_verified_at < now() - interval '30 minutes'),
    'email_hint', left(split_part(i.email, '@', 1), 1) || '***@' || split_part(i.email, '@', 2),
    'role', i.role,
    'org_name', (select o.name from public.site_organizations o where o.id = i.org_id),
    'venue_name', (select v.name from public.site_venues v where v.id = i.venue_id),
    'event_title', (select e.title from public.site_events e where e.id = i.event_id),
    'shift_name', (select s.name from public.site_shifts s where s.id = i.shift_id),
    'access_start_at', i.access_start_at,
    'access_end_at', i.access_end_at,
    'expires_at', i.expires_at,
    'renewal_requested', i.renewal_requested_at is not null);
end;
$$;

-- outcome: requested | already_requested | not_expired | invalid | revoked | accepted | email_mismatch. At most once every 6 hours.
create function public.request_invitation_renewal(p_token text, p_note text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  i public.site_invitations%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.site_invitations x where x.token_hash = sha256(convert_to(coalesce(p_token, ''), 'utf8')) for update;
  if not found then return 'invalid'; end if;
  if i.status = 'revoked' then return 'revoked'; end if;
  if i.status = 'accepted' then return case when i.accepted_by = auth.uid() then 'accepted' else 'invalid' end; end if;
  if v_email <> i.email then return 'email_mismatch'; end if;
  if i.expires_at >= now() then return 'not_expired'; end if;
  if v_note is not null and char_length(v_note) > 200 then raise exception 'keep the note to 200 characters or fewer'; end if;
  if i.renewal_requested_at is not null and i.renewal_requested_at > now() - interval '6 hours' then return 'already_requested'; end if;

  update public.site_invitations set renewal_requested_at = now(), renewal_note = v_note where id = i.id;
  perform public.desk_log('team.invitation_renewal_requested', 'site_invitations', i.id, jsonb_build_object('org_id', i.org_id, 'role', i.role));
  return 'requested';
end;
$$;

-- For the people who manage invitations: which are temporary, whether the identity was confirmed, and who has asked for a new link.
create function public.list_invitation_extras(p_org uuid)
returns table (invitation_id uuid, kind text, identity_verified boolean, renewal_requested_at timestamptz, renewal_note text)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not (public.is_org_member(p_org) or public.is_cms_admin()) then raise exception 'not allowed'; end if;
  return query
    select i.id, i.kind, i.identity_verified_at is not null and i.identity_verified_at >= now() - interval '30 minutes', i.renewal_requested_at, i.renewal_note
    from public.site_invitations i
    where i.org_id = p_org and i.status = 'pending'
      and (i.kind = 'temporary' or i.renewal_requested_at is not null)
      and (public.is_cms_admin() or public.can_view_membership(i.org_id, i.venue_id, i.event_id))
    order by i.created_at desc, i.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.invite_temporary_staff(uuid, text, text, uuid, uuid, uuid, timestamptz, timestamptz, int), public.verify_invitation_code(text, text), public.invitation_preview(text),
  public.request_invitation_renewal(text, text), public.list_invitation_extras(uuid) from public, anon;
grant execute on function public.invite_temporary_staff(uuid, text, text, uuid, uuid, uuid, timestamptz, timestamptz, int), public.verify_invitation_code(text, text), public.invitation_preview(text),
  public.request_invitation_renewal(text, text), public.list_invitation_extras(uuid) to authenticated, service_role;
-- The code is made for the e-mail function only.
revoke all on function public.issue_invitation_code(text, text) from public, anon, authenticated;
grant execute on function public.issue_invitation_code(text, text) to service_role;
