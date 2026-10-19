-- Venue linking and event agreements (client Phase 2 brief, section 8; the organizer's Agreements and the venue's Events & Agreements).
--
-- "Organizer path: Event -> Venue -> Request Link. Venue path: Venue Requests -> Review -> Discuss/Approve/Decline. Agreement flow: Propose ->
-- Review -> Request Changes or Accept -> Both accept same version -> Active. Any change to accepted commercial terms creates a new version
-- requiring both acceptances. Store copies, identities, versions and timestamps."
--
--   * The organizer of an event asks a club to host it. The club's manager or owner declines, or the two sides negotiate: either side
--     PROPOSES terms (a new, numbered version; terms are never edited), notes are exchanged, and each side ACCEPTS the latest version. The
--     proposer counts as having accepted their own proposal. When both sides have accepted the same version it is ACTIVE.
--   * The two acceptances must come from two different people, even if one business is on both sides. An acceptance of an old version is
--     refused ("that version was replaced"): nobody agrees to terms they have not seen. Changing an active agreement is another proposal;
--     the old version stays in force until the new one has both acceptances.
--   * Money terms are explicit: a share of bar sales needs a threshold, a formula (a percentage of sales ABOVE the threshold, or of ALL
--     sales once it is reached, which are different amounts) and how refunds, taxes/tips/fees and eligible revenue are treated.
--     agreement_sample works out what a share comes to, to be shown before acceptance. No money moves: this records what was agreed.
--   * Each side sees only the agreements it is party to: the organizer's business its events', the club's manager and owner their club's.
--     Nothing here gives either side the other's data. Agreements are retained: the event and the club cannot be deleted while one exists.
--
-- Plain CREATE, never CREATE OR REPLACE. Needs the tenancy, organizer events and venue setup (setup_* helpers) migrations.

-- ---------------------------------------------------------------------------
-- 1. Tables (reached only through the functions below)
-- ---------------------------------------------------------------------------
create table public.site_agreements (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.site_events (id),
  venue_id uuid not null references public.site_venues (id),
  organizer_org_id uuid not null references public.site_organizations (id),
  status text not null default 'requested' check (status in ('requested', 'negotiating', 'active', 'changes_pending', 'declined', 'cancelled')),
  current_version int not null default 0,
  active_version int,
  request_note text check (request_note is null or char_length(request_note) <= 500),
  requested_by uuid not null references auth.users (id),
  requested_at timestamptz not null default clock_timestamp(),
  closed_by uuid references auth.users (id),
  closed_at timestamptz,
  closed_reason text check (closed_reason is null or char_length(closed_reason) <= 500),
  constraint site_agreements_closed_together check ((status in ('declined', 'cancelled')) = (closed_at is not null))
);
-- One live agreement per event and club.
create unique index site_agreements_one_live_idx on public.site_agreements (event_id, venue_id) where status not in ('declined', 'cancelled');
create index site_agreements_venue_idx on public.site_agreements (venue_id, status);
create index site_agreements_org_idx on public.site_agreements (organizer_org_id, status);

create table public.site_agreement_versions (
  agreement_id uuid not null references public.site_agreements (id),
  version int not null check (version >= 1),
  terms jsonb not null,
  note text check (note is null or char_length(note) <= 500),
  proposed_by uuid not null references auth.users (id),
  proposed_by_side text not null check (proposed_by_side in ('organizer', 'venue')),
  proposed_at timestamptz not null default clock_timestamp(),
  organizer_accepted_by uuid references auth.users (id),
  organizer_accepted_at timestamptz,
  venue_accepted_by uuid references auth.users (id),
  venue_accepted_at timestamptz,
  primary key (agreement_id, version),
  constraint site_agreement_two_people check (organizer_accepted_by is null or venue_accepted_by is null or organizer_accepted_by <> venue_accepted_by)
);

create table public.site_agreement_notes (
  id uuid primary key default gen_random_uuid(),
  agreement_id uuid not null references public.site_agreements (id),
  version int,
  side text not null check (side in ('organizer', 'venue')),
  author_id uuid not null references auth.users (id),
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default clock_timestamp()
);
create index site_agreement_notes_idx on public.site_agreement_notes (agreement_id, created_at);

alter table public.site_agreements enable row level security;
alter table public.site_agreement_versions enable row level security;
alter table public.site_agreement_notes enable row level security;
revoke all on table public.site_agreements, public.site_agreement_versions, public.site_agreement_notes from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
-- Which side of this agreement is the caller on? 'organizer', 'venue', or null. If both (one business on both sides) the caller must say.
create function public.agreement_side(a public.site_agreements, p_prefer text default null)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org boolean := public.can_access_event(a.event_id, array['owner', 'organizer']);
  v_venue boolean := public.can_access_venue(a.venue_id, array['owner', 'manager']);
begin
  if v_org and v_venue then return coalesce(p_prefer, 'organizer'); end if;
  if v_org then return 'organizer'; end if;
  if v_venue then return 'venue'; end if;
  return null;
end;
$$;

-- A number from a details object (0 to 100 with up to two decimals), or null.
create function public.agreement_percent(p jsonb, p_key text, p_label text)
returns numeric
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := p -> p_key;
  n numeric;
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  if jsonb_typeof(v) <> 'number' then raise exception '% must be a number', p_label; end if;
  n := (v #>> '{}')::numeric;
  if n < 0 or n > 100 then raise exception '% must be between 0 and 100', p_label; end if;
  if n <> round(n, 2) then raise exception '% can have at most two decimals', p_label; end if;
  return n;
end;
$$;

-- The terms, checked and tidied. Money terms must be explicit when a share of sales is agreed.
create function public.agreement_check_terms(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_out jsonb := '{}'::jsonb;
  v_txt text;
  v_int int;
  v_pct numeric;
  v_key text;
  v_owner text;
begin
  perform public.setup_only_keys(p, array[
    'starts', 'ends', 'rooms', 'capacity', 'ticket_ownership', 'table_allocation', 'bar_percent', 'threshold_cents', 'formula', 'eligible_revenue',
    'refunds', 'discounts', 'complimentary_items', 'taxes_tips_fees', 'min_spend_rules', 'admissions', 'complimentary_allowance',
    'responsibilities', 'cancellation', 'settlement_timing'
  ]);
  foreach v_key in array array['starts', 'ends'] loop
    v_txt := public.setup_text(p, v_key, case v_key when 'starts' then 'start time' else 'end time' end, 5);
    if v_txt is not null then
      if v_txt !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception '% must be a time like 21:00', case v_key when 'starts' then 'start time' else 'end time' end; end if;
      v_out := v_out || jsonb_build_object(v_key, v_txt);
    end if;
  end loop;
  foreach v_key in array array['rooms', 'table_allocation', 'eligible_revenue', 'refunds', 'discounts', 'complimentary_items', 'taxes_tips_fees', 'min_spend_rules', 'admissions', 'cancellation'] loop
    v_txt := public.setup_text(p, v_key, replace(v_key, '_', ' '), 300);
    if v_txt is not null then v_out := v_out || jsonb_build_object(v_key, v_txt); end if;
  end loop;
  v_txt := public.setup_text(p, 'responsibilities', 'responsibilities', 500);
  if v_txt is not null then v_out := v_out || jsonb_build_object('responsibilities', v_txt); end if;
  v_txt := public.setup_text(p, 'settlement_timing', 'settlement timing', 200);
  if v_txt is not null then v_out := v_out || jsonb_build_object('settlement_timing', v_txt); end if;
  v_int := public.setup_int(p, 'capacity', 'capacity', 1, 100000);
  if v_int is not null then v_out := v_out || jsonb_build_object('capacity', v_int); end if;
  v_int := public.setup_int(p, 'complimentary_allowance', 'complimentary allowance', 0, 10000);
  if v_int is not null then v_out := v_out || jsonb_build_object('complimentary_allowance', v_int); end if;

  v_owner := public.setup_text(p, 'ticket_ownership', 'ticket ownership', 20);
  if v_owner is not null then
    if v_owner not in ('organizer', 'venue', 'shared') then raise exception 'ticket ownership must be organizer, venue or shared'; end if;
    v_out := v_out || jsonb_build_object('ticket_ownership', v_owner);
  end if;

  v_pct := public.agreement_percent(p, 'bar_percent', 'bar percentage');
  v_int := public.setup_int(p, 'threshold_cents', 'threshold', 0, 1000000000);
  v_txt := public.setup_text(p, 'formula', 'formula', 30);
  if v_txt is not null and v_txt not in ('above_threshold', 'all_once_reached') then raise exception 'formula must be above_threshold or all_once_reached'; end if;
  if v_pct is not null then v_out := v_out || jsonb_build_object('bar_percent', v_pct); end if;
  if v_int is not null then v_out := v_out || jsonb_build_object('threshold_cents', v_int); end if;
  if v_txt is not null then v_out := v_out || jsonb_build_object('formula', v_txt); end if;

  if coalesce(v_pct, 0) > 0 then
    if v_int is null then raise exception 'a share of bar sales needs a threshold (0 if it applies from the first sale)'; end if;
    if v_txt is null then raise exception 'say whether the share is of sales ABOVE the threshold or of ALL sales once it is reached'; end if;
    if v_out -> 'eligible_revenue' is null then raise exception 'say which revenue counts towards the share'; end if;
    if v_out -> 'refunds' is null then raise exception 'say how refunds are treated'; end if;
    if v_out -> 'taxes_tips_fees' is null then raise exception 'say how taxes, tips and fees are treated'; end if;
  end if;
  return v_out;
end;
$$;

revoke all on function public.agreement_side(public.site_agreements, text), public.agreement_percent(jsonb, text, text), public.agreement_check_terms(jsonb) from public, anon, authenticated;

-- What the organizer's share comes to, in cents, on [p_sales_cents] of eligible bar sales: shown before anyone accepts. A percentage of
-- sales ABOVE the threshold and a percentage of ALL sales once it is reached are different amounts.
create function public.agreement_sample(p_terms jsonb, p_sales_cents bigint)
returns bigint
language sql
immutable
set search_path = public
as $$
  select case
    when p_sales_cents is null or p_sales_cents < 0 then 0
    when coalesce((p_terms ->> 'bar_percent')::numeric, 0) = 0 then 0
    when p_terms ->> 'formula' = 'above_threshold' then round(greatest(p_sales_cents - coalesce((p_terms ->> 'threshold_cents')::bigint, 0), 0) * (p_terms ->> 'bar_percent')::numeric / 100)::bigint
    when p_terms ->> 'formula' = 'all_once_reached' then
      case when p_sales_cents >= coalesce((p_terms ->> 'threshold_cents')::bigint, 0) then round(p_sales_cents * (p_terms ->> 'bar_percent')::numeric / 100)::bigint else 0 end
    else 0
  end
$$;

-- ---------------------------------------------------------------------------
-- 3. Asking, proposing, accepting
-- ---------------------------------------------------------------------------
create function public.agreement_request(p_event uuid, p_venue uuid, p_message text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  e public.site_events;
  v_msg text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into e from public.site_events x where x.id = p_event;
  if not found or e.org_id is null or not public.can_access_event(p_event, array['owner', 'organizer']) then raise exception 'not allowed'; end if;
  if p_venue is null or not exists (select 1 from public.site_venues v where v.id = p_venue and v.org_id is not null) then raise exception 'choose a club'; end if;
  v_msg := nullif(btrim(p_message), '');
  if v_msg is not null and char_length(v_msg) > 500 then raise exception 'keep the message to 500 characters or fewer'; end if;
  if exists (select 1 from public.site_agreements a where a.event_id = p_event and a.venue_id = p_venue and a.status not in ('declined', 'cancelled')) then
    raise exception 'this event already has an agreement with that club';
  end if;

  insert into public.site_agreements (event_id, venue_id, organizer_org_id, request_note, requested_by) values (p_event, p_venue, e.org_id, v_msg, auth.uid()) returning id into v_id;
  perform public.desk_log('agreement.requested', 'site_agreements', v_id, jsonb_build_object('venue_id', p_venue, 'event_id', p_event));
  return v_id;
end;
$$;

-- A new numbered version of the terms. The proposer counts as having accepted it. Any earlier version stops being open to acceptance.
create function public.agreement_propose(p_agreement uuid, p_terms jsonb, p_note text default null, p_side text default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  v_side text;
  v_terms jsonb;
  v_note text;
  v_ver int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_agreements x where x.id = p_agreement for update;
  if not found then raise exception 'not allowed'; end if;
  v_side := public.agreement_side(a, p_side);
  if v_side is null then raise exception 'not allowed'; end if;
  if a.status in ('declined', 'cancelled') then raise exception 'this agreement is closed'; end if;
  v_terms := public.agreement_check_terms(p_terms);
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 500 then raise exception 'keep the note to 500 characters or fewer'; end if;
  if v_terms = '{}'::jsonb then raise exception 'propose at least one term'; end if;

  v_ver := a.current_version + 1;
  insert into public.site_agreement_versions (agreement_id, version, terms, note, proposed_by, proposed_by_side, organizer_accepted_by, organizer_accepted_at, venue_accepted_by, venue_accepted_at)
    values (p_agreement, v_ver, v_terms, v_note, auth.uid(), v_side,
            case when v_side = 'organizer' then auth.uid() end, case when v_side = 'organizer' then clock_timestamp() end,
            case when v_side = 'venue' then auth.uid() end, case when v_side = 'venue' then clock_timestamp() end);
  update public.site_agreements set current_version = v_ver, status = case when active_version is null then 'negotiating' else 'changes_pending' end where id = p_agreement;
  perform public.desk_log('agreement.proposed', 'site_agreements', p_agreement, jsonb_build_object('venue_id', a.venue_id, 'version', v_ver, 'side', v_side));
  return v_ver;
end;
$$;

-- Accept the LATEST version as the caller's side. Both sides on the same version, by two different people, makes it active.
create function public.agreement_accept(p_agreement uuid, p_version int, p_side text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  v public.site_agreement_versions;
  v_side text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_agreements x where x.id = p_agreement for update;
  if not found then raise exception 'not allowed'; end if;
  v_side := public.agreement_side(a, p_side);
  if v_side is null then raise exception 'not allowed'; end if;
  if a.status in ('declined', 'cancelled') then raise exception 'this agreement is closed'; end if;
  if a.current_version = 0 then raise exception 'nothing has been proposed yet'; end if;
  if p_version is distinct from a.current_version then raise exception 'that version was replaced: read the latest one'; end if;
  select * into v from public.site_agreement_versions x where x.agreement_id = p_agreement and x.version = p_version for update;

  if (v_side = 'organizer' and v.organizer_accepted_by is not null) or (v_side = 'venue' and v.venue_accepted_by is not null) then
    return jsonb_build_object('changed', false, 'status', a.status);
  end if;
  if (v_side = 'organizer' and v.venue_accepted_by = auth.uid()) or (v_side = 'venue' and v.organizer_accepted_by = auth.uid()) then
    raise exception 'the other side has to accept this: it cannot be the same person';
  end if;

  if v_side = 'organizer' then
    update public.site_agreement_versions set organizer_accepted_by = auth.uid(), organizer_accepted_at = clock_timestamp() where agreement_id = p_agreement and version = p_version;
  else
    update public.site_agreement_versions set venue_accepted_by = auth.uid(), venue_accepted_at = clock_timestamp() where agreement_id = p_agreement and version = p_version;
  end if;
  update public.site_agreements set status = 'active', active_version = p_version where id = p_agreement;
  perform public.desk_log('agreement.accepted', 'site_agreements', p_agreement, jsonb_build_object('venue_id', a.venue_id, 'version', p_version, 'side', v_side));
  return jsonb_build_object('changed', true, 'status', 'active', 'version', p_version);
end;
$$;

create function public.agreement_note(p_agreement uuid, p_body text, p_side text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  v_side text;
  v_body text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_agreements x where x.id = p_agreement;
  if not found then raise exception 'not allowed'; end if;
  v_side := public.agreement_side(a, p_side);
  if v_side is null then raise exception 'not allowed'; end if;
  v_body := btrim(p_body);
  if v_body is null or v_body = '' then raise exception 'write the note first'; end if;
  if char_length(v_body) > 1000 then raise exception 'keep a note to 1000 characters or fewer'; end if;
  insert into public.site_agreement_notes (agreement_id, version, side, author_id, body) values (p_agreement, nullif(a.current_version, 0), v_side, auth.uid(), v_body) returning id into v_id;
  perform public.desk_log('agreement.note', 'site_agreements', p_agreement, jsonb_build_object('venue_id', a.venue_id));
  return v_id;
end;
$$;

-- The club says no (before anything is active); either side can withdraw an agreement, with a reason. Nothing is deleted.
create function public.agreement_close(p_agreement uuid, p_reason text, p_side text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  v_side text;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_agreements x where x.id = p_agreement for update;
  if not found then raise exception 'not allowed'; end if;
  v_side := public.agreement_side(a, p_side);
  if v_side is null then raise exception 'not allowed'; end if;
  if a.status in ('declined', 'cancelled') then raise exception 'this agreement is already closed'; end if;
  v_reason := btrim(p_reason);
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'say why'; end if;
  if char_length(v_reason) > 500 then raise exception 'keep the reason to 500 characters or fewer'; end if;
  update public.site_agreements
    set status = case when v_side = 'venue' and a.active_version is null then 'declined' else 'cancelled' end,
        closed_by = auth.uid(), closed_at = clock_timestamp(), closed_reason = v_reason
    where id = p_agreement;
  perform public.desk_log('agreement.closed', 'site_agreements', p_agreement, jsonb_build_object('venue_id', a.venue_id, 'side', v_side, 'was_active', a.active_version is not null));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Reading
-- ---------------------------------------------------------------------------
-- The agreements of a club (manager, owner) or of an organizer's business (owner, organizer): who asked for what, and who has to act next.
create function public.agreement_list(p_venue uuid default null, p_org uuid default null)
returns table (
  agreement_id uuid, event_title text, event_start timestamptz, venue_name text, organizer_name text, status text, current_version int, active_version int,
  side text, waiting_on text, requested_at timestamptz, closed_reason text
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if (p_venue is null) = (p_org is null) then raise exception 'choose a club or a business'; end if;
  if p_venue is not null and not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if p_org is not null and not public.is_org_member(p_org, array['owner', 'organizer']) then raise exception 'not allowed'; end if;

  return query
    select a.id, e.title, e.start_date, v.name, o.name, a.status, a.current_version, a.active_version,
           case when p_venue is not null then 'venue' else 'organizer' end,
           case
             when a.status in ('declined', 'cancelled') then null
             when a.current_version = 0 then 'venue'
             else (select case when x.organizer_accepted_by is null and x.venue_accepted_by is null then null
                               when x.organizer_accepted_by is null then 'organizer'
                               when x.venue_accepted_by is null then 'venue' end
                   from public.site_agreement_versions x where x.agreement_id = a.id and x.version = a.current_version)
           end,
           a.requested_at, a.closed_reason
    from public.site_agreements a
    join public.site_events e on e.id = a.event_id
    join public.site_venues v on v.id = a.venue_id
    join public.site_organizations o on o.id = a.organizer_org_id
    where (p_venue is not null and a.venue_id = p_venue) or (p_org is not null and a.organizer_org_id = p_org)
    order by (a.status in ('declined', 'cancelled')), a.requested_at desc, a.id
    limit 200;
end;
$$;

-- One agreement with every version (the terms as proposed, who proposed, who accepted and when), the discussion, and what the caller can do.
create function public.agreement_detail(p_agreement uuid, p_side text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  v_side text;
  v_cur public.site_agreement_versions;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_agreements x where x.id = p_agreement;
  if not found then raise exception 'not allowed'; end if;
  v_side := public.agreement_side(a, p_side);
  if v_side is null then raise exception 'not allowed'; end if;
  select * into v_cur from public.site_agreement_versions x where x.agreement_id = p_agreement and x.version = a.current_version;

  return jsonb_build_object(
    'agreement_id', a.id,
    'status', a.status,
    'side', v_side,
    'event_title', (select e.title from public.site_events e where e.id = a.event_id),
    'event_start', (select e.start_date from public.site_events e where e.id = a.event_id),
    'venue_name', (select v.name from public.site_venues v where v.id = a.venue_id),
    'organizer_name', (select o.name from public.site_organizations o where o.id = a.organizer_org_id),
    'current_version', a.current_version,
    'active_version', a.active_version,
    'request_note', a.request_note,
    'requested_at', a.requested_at,
    'closed_reason', a.closed_reason,
    'closed_at', a.closed_at,
    'can_accept', a.status not in ('declined', 'cancelled') and a.current_version > 0
      and ((v_side = 'organizer' and v_cur.organizer_accepted_by is null and v_cur.venue_accepted_by is distinct from auth.uid())
        or (v_side = 'venue' and v_cur.venue_accepted_by is null and v_cur.organizer_accepted_by is distinct from auth.uid())),
    'can_propose', a.status not in ('declined', 'cancelled'),
    'can_close', a.status not in ('declined', 'cancelled'),
    'versions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'version', x.version, 'terms', x.terms, 'note', x.note, 'proposed_by_side', x.proposed_by_side, 'proposed_at', x.proposed_at,
        'proposed_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = x.proposed_by),
        'organizer_accepted_at', x.organizer_accepted_at,
        'organizer_accepted_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = x.organizer_accepted_by),
        'venue_accepted_at', x.venue_accepted_at,
        'venue_accepted_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = x.venue_accepted_by),
        'is_active', a.active_version = x.version
      ) order by x.version desc)
      from public.site_agreement_versions x where x.agreement_id = a.id), '[]'::jsonb),
    'notes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'side', n.side, 'version', n.version, 'body', n.body, 'created_at', n.created_at, 'is_mine', n.author_id = auth.uid(),
        'author_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = n.author_id)
      ) order by n.created_at)
      from public.site_agreement_notes n where n.agreement_id = a.id), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.agreement_sample(jsonb, bigint), public.agreement_request(uuid, uuid, text), public.agreement_propose(uuid, jsonb, text, text),
  public.agreement_accept(uuid, int, text), public.agreement_note(uuid, text, text), public.agreement_close(uuid, text, text),
  public.agreement_list(uuid, uuid), public.agreement_detail(uuid, text)
from public, anon;
grant execute on function
  public.agreement_sample(jsonb, bigint), public.agreement_request(uuid, uuid, text), public.agreement_propose(uuid, jsonb, text, text),
  public.agreement_accept(uuid, int, text), public.agreement_note(uuid, text, text), public.agreement_close(uuid, text, text),
  public.agreement_list(uuid, uuid), public.agreement_detail(uuid, text)
to authenticated, service_role;
