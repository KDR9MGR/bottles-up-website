-- E-mailing a report (client Phase 2 brief, section 27 "Automatically email the appropriate PDF to configured recipients ... Log delivery failure and allow authorized resend. Never
-- attach venue-wide private metrics to organizer email", section 28 "PDF recipients: Settings -> Reports", scenario 22 "Role-specific PDFs: owner, manager and organizer receive only
-- appropriate detail").
--
-- What this adds (new tables and functions only; nothing existing is replaced and no row is changed):
--   * site_report_recipients    who receives which report, kept per kind of report: the owner's combined report (per business), a club's night report (per club), and an
--                               organizer's event report (per organizer business). Closed table: the app reaches it only through the functions below.
--   * site_report_deliveries    one row per e-mail address per send: pending, sent or failed, with a short reason. This is the log a person reads and the list "send again" works from.
--   * report_recipients / add_report_recipient / remove_report_recipient     the list of one kind of report, kept by the people who own that report.
--   * report_send_begin         checks the caller may send THIS report, reads the configured recipients (the app never supplies addresses), and writes one pending row each.
--   * report_send_finish        service role only: the e-mail function records what the provider said.
--   * report_deliveries         the log of one report, for the people who may send it.
--
-- Who may do what (the kinds never mix, which is how a club-wide report cannot reach an organizer):
--   owner_combined   the business's OWNER, for the list and for sending.
--   venue_night      the OWNER or MANAGER of that club, for the list and for sending.
--   organizer_sales  an OWNER or ORGANIZER of the organizer business, for the list; sending also needs access to that event, and the event must belong to that business.
-- A report of one kind goes only to the list of that kind, and the list of a kind can only be edited by the people who may send that kind. A person who is not allowed gets "not allowed",
-- the same sentence for every refusal, so it does not say whether a business, club or event exists.
--
-- Limits: ten addresses per list, a PDF of at most 5 MB, ten sends an hour per person. The text of the e-mail is fixed by the send function (nobody can type a message), so the
-- application cannot be used to send arbitrary mail to a stranger.
--
-- The PDF itself is made by the app and is not stored here: to send again, the app makes it again. Needs the tenancy migration (20261006120000) and desk_log.

do $guard$
declare
  fn text;
begin
  foreach fn in array array['public.is_org_member(uuid, text[])', 'public.can_access_venue(uuid, text[])', 'public.can_access_event(uuid, text[])', 'public.desk_log(text, text, uuid, jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', fn;
    end if;
  end loop;
  if to_regclass('public.site_organizations') is null or to_regclass('public.site_venues') is null or to_regclass('public.site_events') is null then
    raise exception 'the organizations, venues and events tables must exist first. Nothing was changed.';
  end if;
end $guard$;

-- ---------------------------------------------------------------------------
-- 1. The lists and the log
-- ---------------------------------------------------------------------------
create table public.site_report_recipients (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.site_organizations (id) on delete cascade,
  venue_id uuid references public.site_venues (id) on delete cascade,
  kind text not null check (kind in ('owner_combined', 'venue_night', 'organizer_sales')),
  email text not null check (email = lower(email) and char_length(email) <= 254 and email ~ '^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$'),
  added_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  check ((kind = 'venue_night') = (venue_id is not null))
);
create unique index site_report_recipients_unique on public.site_report_recipients
  (org_id, kind, coalesce(venue_id, '00000000-0000-0000-0000-000000000000'::uuid), email);

create table public.site_report_deliveries (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null,
  org_id uuid not null references public.site_organizations (id) on delete cascade,
  venue_id uuid references public.site_venues (id) on delete cascade,
  event_id uuid references public.site_events (id) on delete set null,
  kind text not null check (kind in ('owner_combined', 'venue_night', 'organizer_sales')),
  report_ref text not null check (char_length(report_ref) between 1 and 60),
  filename text not null check (char_length(filename) between 5 and 100),
  email text not null,
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
  error text check (error is null or char_length(error) <= 300),
  bytes int not null check (bytes between 1 and 5242880),
  sent_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index site_report_deliveries_report_idx on public.site_report_deliveries (kind, org_id, venue_id, event_id, report_ref, created_at desc);
create index site_report_deliveries_batch_idx on public.site_report_deliveries (batch_id);
create index site_report_deliveries_sender_idx on public.site_report_deliveries (sent_by, created_at desc);

alter table public.site_report_recipients enable row level security;
alter table public.site_report_deliveries enable row level security;
revoke all on table public.site_report_recipients, public.site_report_deliveries from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Who may handle which report (internal; the app cannot call it)
-- ---------------------------------------------------------------------------
create function public.report_scope_allowed(p_kind text, p_org uuid, p_venue uuid, p_event uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or p_org is null then return false; end if;
  if p_kind = 'owner_combined' then
    return p_venue is null and p_event is null and public.is_org_member(p_org, array['owner']);
  elsif p_kind = 'venue_night' then
    return p_venue is not null and p_event is null
      and exists (select 1 from public.site_venues v where v.id = p_venue and v.org_id = p_org)
      and public.can_access_venue(p_venue, array['owner', 'manager']);
  elsif p_kind = 'organizer_sales' then
    if p_venue is not null then return false; end if;
    if p_event is null then return public.is_org_member(p_org, array['owner', 'organizer']); end if;
    return exists (select 1 from public.site_events e where e.id = p_event and e.org_id = p_org)
      and public.can_access_event(p_event, array['owner', 'organizer']);
  end if;
  return false;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The lists
-- ---------------------------------------------------------------------------
create function public.report_recipients(p_kind text, p_org uuid, p_venue uuid default null)
returns table (id uuid, email text, added_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.report_scope_allowed(p_kind, p_org, p_venue, null) then raise exception 'not allowed'; end if;
  return query
    select r.id, r.email, r.created_at from public.site_report_recipients r
    where r.org_id = p_org and r.kind = p_kind and r.venue_id is not distinct from p_venue
    order by r.email;
end;
$$;

create function public.add_report_recipient(p_kind text, p_org uuid, p_venue uuid, p_email text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.report_scope_allowed(p_kind, p_org, p_venue, null) then raise exception 'not allowed'; end if;
  if char_length(v_email) > 254 or v_email !~ '^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$' then raise exception 'enter one e-mail address, like name@company.com'; end if;
  if exists (select 1 from public.site_report_recipients r where r.org_id = p_org and r.kind = p_kind and r.venue_id is not distinct from p_venue and r.email = v_email) then
    raise exception 'that address is already on the list';
  end if;
  if (select count(*) from public.site_report_recipients r where r.org_id = p_org and r.kind = p_kind and r.venue_id is not distinct from p_venue) >= 10 then
    raise exception 'a list can hold at most 10 addresses: remove one first';
  end if;
  insert into public.site_report_recipients (org_id, venue_id, kind, email, added_by) values (p_org, p_venue, p_kind, v_email, auth.uid()) returning id into v_id;
  perform public.desk_log('report.recipient_added', 'site_report_recipients', v_id, jsonb_build_object('kind', p_kind, 'org_id', p_org, 'venue_id', p_venue, 'email', v_email));
  return v_id;
end;
$$;

create function public.remove_report_recipient(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_report_recipients;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into r from public.site_report_recipients x where x.id = p_id;
  if not found or not public.report_scope_allowed(r.kind, r.org_id, r.venue_id, null) then raise exception 'not allowed'; end if;
  delete from public.site_report_recipients where id = r.id;
  perform public.desk_log('report.recipient_removed', 'site_report_recipients', r.id, jsonb_build_object('kind', r.kind, 'org_id', r.org_id, 'venue_id', r.venue_id, 'email', r.email));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Sending and the log
-- ---------------------------------------------------------------------------
-- Checks that the caller may send this report, takes the addresses from the configured list (never from the caller) and writes one pending row for each. With p_only_failed it
-- takes only the addresses whose latest attempt for this same report failed. Returns the rows for the e-mail function to send, with the names (business, club, event) that go
-- into the message: they are read here, not taken from the caller. The report is identified by its night (a date) or its event, never by free text.
create function public.report_send_begin(
  p_kind text, p_org uuid, p_venue uuid, p_event uuid, p_ref text, p_filename text, p_bytes int, p_only_failed boolean default false
)
returns table (delivery_id uuid, batch_id uuid, email text, org_name text, venue_name text, event_title text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref text := btrim(coalesce(p_ref, ''));
  v_name text := btrim(coalesce(p_filename, ''));
  v_batch uuid := gen_random_uuid();
  v_targets text[];
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_kind = 'organizer_sales' and p_event is null then raise exception 'not allowed'; end if;
  if p_kind <> 'organizer_sales' and p_event is not null then raise exception 'not allowed'; end if;
  if not public.report_scope_allowed(p_kind, p_org, p_venue, p_event) then raise exception 'not allowed'; end if;
  -- What the report is "of" is a night (for the two club reports) or the event itself: nothing typed by a person ends up in the e-mail.
  if p_kind = 'organizer_sales' then
    if v_ref <> p_event::text then raise exception 'say which report this is'; end if;
  else
    begin
      if v_ref !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or to_char(v_ref::date, 'YYYY-MM-DD') <> v_ref then raise exception 'say which night this report is for'; end if;
    exception when invalid_datetime_format or datetime_field_overflow then
      raise exception 'say which night this report is for';
    end;
  end if;
  if v_name !~ '^[A-Za-z0-9 _.()-]{1,95}\.pdf$' then raise exception 'the file name must end in .pdf and use only letters, numbers, spaces and . _ ( ) -'; end if;
  if p_bytes is null or p_bytes < 1 then raise exception 'the report is empty'; end if;
  if p_bytes > 5242880 then raise exception 'this report is too large to e-mail (5 MB at most)'; end if;
  if (select count(distinct d.batch_id) from public.site_report_deliveries d where d.sent_by = auth.uid() and d.created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too many reports sent this hour: try again later';
  end if;

  select coalesce(array_agg(r.email order by r.email), '{}'::text[]) into v_targets
    from public.site_report_recipients r
   where r.org_id = p_org and r.kind = p_kind and r.venue_id is not distinct from p_venue;
  if cardinality(v_targets) = 0 then raise exception 'no one is set to receive this report: add an e-mail address first'; end if;

  if p_only_failed then
    select coalesce(array_agg(l.addr order by l.addr), '{}'::text[]) into v_targets from (
      select distinct on (d.email) d.email as addr, d.status as last_status
        from public.site_report_deliveries d
       where d.kind = p_kind and d.org_id = p_org and d.venue_id is not distinct from p_venue and d.event_id is not distinct from p_event
         and d.report_ref = v_ref and d.email = any (v_targets)
       order by d.email, d.created_at desc, d.id
    ) l
    where l.last_status = 'failed';
    if cardinality(v_targets) = 0 then raise exception 'there is nothing to send again'; end if;
  end if;

  perform public.desk_log('report.send_started', 'site_report_deliveries', v_batch,
    jsonb_build_object('kind', p_kind, 'org_id', p_org, 'venue_id', p_venue, 'event_id', p_event, 'report', v_ref, 'recipients', cardinality(v_targets), 'again', coalesce(p_only_failed, false)));

  return query
    with ins as (
      insert into public.site_report_deliveries (batch_id, org_id, venue_id, event_id, kind, report_ref, filename, email, bytes, sent_by, created_at)
      select v_batch, p_org, p_venue, p_event, p_kind, v_ref, v_name, t.addr, p_bytes, auth.uid(), clock_timestamp() from unnest(v_targets) as t (addr)
      returning public.site_report_deliveries.id as i, public.site_report_deliveries.batch_id as b, public.site_report_deliveries.email as e
    )
    select ins.i, ins.b, ins.e,
           (select o.name from public.site_organizations o where o.id = p_org),
           (select v.name from public.site_venues v where v.id = p_venue),
           (select ev.title from public.site_events ev where ev.id = p_event)
    from ins order by ins.e;
end;
$$;

-- The e-mail function says what the provider answered. Only pending rows change, and each only once.
create function public.report_send_finish(p_results jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int := 0;
  x jsonb;
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' then raise exception 'results must be a list'; end if;
  for x in select * from jsonb_array_elements(p_results) loop
    update public.site_report_deliveries d
       set status = case when coalesce((x ->> 'ok')::boolean, false) then 'sent' else 'failed' end,
           error = case when coalesce((x ->> 'ok')::boolean, false) then null else left(coalesce(nullif(btrim(x ->> 'error'), ''), 'the e-mail was not accepted'), 300) end,
           finished_at = now()
     where d.id = (x ->> 'id')::uuid and d.status = 'pending';
    v_n := v_n + (case when found then 1 else 0 end);
  end loop;
  return v_n;
end;
$$;

-- The log of one report: the latest attempts, newest first, for the people who may send it.
create function public.report_deliveries(p_kind text, p_org uuid, p_venue uuid, p_event uuid, p_ref text, p_limit int default 20)
returns table (email text, status text, error text, sent_at timestamptz, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_kind = 'organizer_sales' and p_event is null then raise exception 'not allowed'; end if;
  if p_kind <> 'organizer_sales' and p_event is not null then raise exception 'not allowed'; end if;
  if not public.report_scope_allowed(p_kind, p_org, p_venue, p_event) then raise exception 'not allowed'; end if;
  return query
    select d.email, d.status, d.error, d.finished_at, d.created_at
    from public.site_report_deliveries d
    where d.kind = p_kind and d.org_id = p_org and d.venue_id is not distinct from p_venue and d.event_id is not distinct from p_event and d.report_ref = btrim(coalesce(p_ref, ''))
    order by d.created_at desc, d.email
    limit greatest(least(coalesce(p_limit, 20), 50), 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.report_scope_allowed(text, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.report_recipients(text, uuid, uuid), public.add_report_recipient(text, uuid, uuid, text), public.remove_report_recipient(uuid),
  public.report_send_begin(text, uuid, uuid, uuid, text, text, int, boolean), public.report_deliveries(text, uuid, uuid, uuid, text, int) from public, anon;
grant execute on function public.report_recipients(text, uuid, uuid), public.add_report_recipient(text, uuid, uuid, text), public.remove_report_recipient(uuid),
  public.report_send_begin(text, uuid, uuid, uuid, text, text, int, boolean), public.report_deliveries(text, uuid, uuid, uuid, text, int) to authenticated, service_role;
revoke all on function public.report_send_finish(jsonb) from public, anon, authenticated;
grant execute on function public.report_send_finish(jsonb) to service_role;
