-- Sales source and closing reports (client Phase 2 brief, section 24 "Sales-source configuration and reporting meaning", and scenario 18 "POS/upload overlap": "No double-counted bar sales;
-- data source clearly labelled").
--
--   WHERE A CLUB'S SALES COME FROM (the owner or a manager of the club chooses; everyone who may see the club's money reads it)
--   * site_venue_sales_source (closed table)   one row per club that has chosen: 'entries' (what BottlesUp recorded: bookings, bottles, payments) or 'upload' (the club also sends a closing
--                                              report). A club that never chose is on 'entries'. Connected POS is NOT offered: no provider is connected, and the brief says an unavailable integration must
--                                              appear as unavailable, not connected (asking for it gets a plain sentence).
--   * venue_sales_source / save_venue_sales_source   read it; change it (owner or manager; audited; saving the same again changes and logs nothing)
--
--   THE CLOSING REPORT (only for a club on 'upload')
--   * site_closing_reports (closed table)      the club's own figures for a night: the period they cover, gross, discounts, refunds (net is worked out), whether the figure already INCLUDES what
--                                              BottlesUp recorded, a short note. One live report per club per night: sending again replaces it (the old one is kept as 'superseded'). It is
--                                              VENUE-REPORTED, never "recorded": nothing here changes a booking, a payment or a report that BottlesUp worked out.
--   * submit_closing_report                    owner or manager of the club
--   * review_closing_report                    the club's owner or a payment verifier checks it and accepts it ('reviewed') or does not ('rejected', with a reason); never the person who
--                                              sent it ("another authorized reviewer handles the reviewer's own entries")
--   * closing_reports                          the club's list (owner, manager, verifier), newest night first
--
--   WHAT THE NIGHT'S SALES MEAN (no double counting, and every figure says where it came from)
--   * night_sales_sources(venue, night)        two labelled blocks that are NEVER added together: "Recorded sales" (BottlesUp: booked, discounts, refunds, collected, unpaid, as of now) and
--                                              "Venue-reported sales" (the live closing report, with its period, its time and whether it has been checked). When the report says it includes
--                                              what BottlesUp recorded, the bar and other part is the report's net minus BottlesUp's net (never below 0), so the bottle and table sales are not counted twice;
--                                              a report that is smaller than what BottlesUp recorded is flagged. An end-of-night upload is labelled as such: it is not live bar sales.
--
-- Plain CREATE for everything; nothing live is replaced. Needs the tenancy, venue setup, table service (night booking ids), close night and refunds migrations.

do $pre$
declare
  r record;
begin
  for r in select * from (values
      ('public.can_access_venue(uuid, text[])'), ('public.require_venue_editor(uuid)'), ('public.venue_setup_log(text, text, uuid, uuid, jsonb)'),
      ('public.night_booking_ids(uuid, date)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
  if to_regclass('public.site_refund_requests') is null then raise exception 'public.site_refund_requests does not exist: run the earlier migrations first. Nothing was changed.'; end if;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. Tables (reached only through the functions below)
-- ---------------------------------------------------------------------------
create table public.site_venue_sales_source (
  venue_id uuid primary key references public.site_venues (id) on delete cascade,
  source text not null check (source in ('entries', 'upload')),
  changed_by uuid references auth.users (id) on delete set null,
  changed_at timestamptz not null default clock_timestamp()
);

-- Closed nights are financial records: the club cannot be deleted while it has any report.
create table public.site_closing_reports (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id),
  business_night date not null,
  version int not null check (version >= 1),
  period_start timestamptz not null,
  period_end timestamptz not null,
  gross_cents bigint not null check (gross_cents between 0 and 100000000000),
  discount_cents bigint not null default 0 check (discount_cents between 0 and 100000000000),
  refund_cents bigint not null default 0 check (refund_cents between 0 and 100000000000),
  net_cents bigint generated always as (gross_cents - discount_cents - refund_cents) stored,
  includes_bottlesup boolean not null,
  note text check (note is null or char_length(note) <= 300),
  status text not null default 'submitted' check (status in ('submitted', 'reviewed', 'rejected', 'superseded')),
  submitted_by uuid references auth.users (id) on delete set null,
  submitted_at timestamptz not null default clock_timestamp(),
  reviewed_by uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  review_note text check (review_note is null or char_length(review_note) <= 300),
  constraint site_closing_reports_period check (period_end > period_start and period_end - period_start <= interval '36 hours'),
  constraint site_closing_reports_within_gross check (discount_cents + refund_cents <= gross_cents),
  constraint site_closing_reports_review_together check ((status in ('reviewed', 'rejected')) <= (reviewed_at is not null)),
  unique (venue_id, business_night, version)
);
create unique index site_closing_reports_one_live on public.site_closing_reports (venue_id, business_night) where status <> 'superseded';

alter table public.site_venue_sales_source enable row level security;
alter table public.site_closing_reports enable row level security;
revoke all on table public.site_venue_sales_source, public.site_closing_reports from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Where the sales come from
-- ---------------------------------------------------------------------------
create function public.venue_sales_source(p_venue uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager', 'verifier']) then raise exception 'not allowed'; end if;
  return coalesce((select s.source from public.site_venue_sales_source s where s.venue_id = p_venue), 'entries');
end;
$$;

create function public.save_venue_sales_source(p_venue uuid, p_source text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before text;
begin
  perform public.require_venue_editor(p_venue);
  if p_source is null then raise exception 'choose a sales source'; end if;
  if p_source = 'pos' then raise exception 'Connected POS is not available yet: no point-of-sale provider is connected'; end if;
  if p_source not in ('entries', 'upload') then raise exception 'the sales source is BottlesUp entries or a closing report upload'; end if;
  v_before := coalesce((select s.source from public.site_venue_sales_source s where s.venue_id = p_venue), 'entries');
  if v_before = p_source and exists (select 1 from public.site_venue_sales_source s where s.venue_id = p_venue) then return p_source; end if;
  insert into public.site_venue_sales_source as s (venue_id, source, changed_by, changed_at) values (p_venue, p_source, auth.uid(), clock_timestamp())
    on conflict (venue_id) do update set source = excluded.source, changed_by = excluded.changed_by, changed_at = excluded.changed_at;
  if v_before <> p_source then
    perform public.venue_setup_log('venue.sales_source', 'venue', p_venue, p_venue, jsonb_build_object('from', v_before, 'to', p_source));
  end if;
  return p_source;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The closing report
-- ---------------------------------------------------------------------------
create function public.submit_closing_report(
  p_venue uuid, p_night date, p_period_start timestamptz, p_period_end timestamptz,
  p_gross_cents bigint, p_discount_cents bigint, p_refund_cents bigint, p_includes_bottlesup boolean, p_note text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source text;
  v_prev public.site_closing_reports;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
begin
  perform public.require_venue_editor(p_venue);
  v_source := coalesce((select s.source from public.site_venue_sales_source s where s.venue_id = p_venue), 'entries');
  if v_source <> 'upload' then raise exception 'this club does not use closing report uploads: change Sales Tracking first'; end if;
  if p_night is null then raise exception 'which night is the report for?'; end if;
  if p_night > current_date + 1 then raise exception 'that night has not happened yet'; end if;
  if p_night < current_date - 90 then raise exception 'a closing report can be sent for the last 90 days'; end if;
  if p_period_start is null or p_period_end is null or p_period_end <= p_period_start then raise exception 'the period must end after it starts'; end if;
  if p_period_end - p_period_start > interval '36 hours' then raise exception 'a closing report covers one night: at most 36 hours'; end if;
  if p_gross_cents is null or p_gross_cents < 0 or p_gross_cents > 100000000000 then raise exception 'enter the gross sales for the period'; end if;
  if coalesce(p_discount_cents, 0) < 0 or coalesce(p_refund_cents, 0) < 0 then raise exception 'discounts and refunds cannot be negative'; end if;
  if coalesce(p_discount_cents, 0) + coalesce(p_refund_cents, 0) > p_gross_cents then raise exception 'discounts and refunds cannot be more than the gross sales'; end if;
  if p_includes_bottlesup is null then raise exception 'say whether the figures include what BottlesUp recorded'; end if;
  if v_note is not null and char_length(v_note) > 300 then raise exception 'the note is at most 300 characters'; end if;

  select * into v_prev from public.site_closing_reports r where r.venue_id = p_venue and r.business_night = p_night and r.status <> 'superseded' for update;
  if v_prev.id is not null then
    update public.site_closing_reports set status = 'superseded' where id = v_prev.id;
  end if;
  insert into public.site_closing_reports (venue_id, business_night, version, period_start, period_end, gross_cents, discount_cents, refund_cents, includes_bottlesup, note, submitted_by)
  values (p_venue, p_night, coalesce((select max(r.version) from public.site_closing_reports r where r.venue_id = p_venue and r.business_night = p_night), 0) + 1,
          p_period_start, p_period_end, p_gross_cents, coalesce(p_discount_cents, 0), coalesce(p_refund_cents, 0), p_includes_bottlesup, v_note, auth.uid())
  returning id into v_id;
  perform public.venue_setup_log('closing_report.submit', 'closing_report', v_id, p_venue,
    jsonb_build_object('night', p_night, 'includes_bottlesup', p_includes_bottlesup, 'net_cents', p_gross_cents - coalesce(p_discount_cents, 0) - coalesce(p_refund_cents, 0), 'replaced', v_prev.id));
  return v_id;
end;
$$;

create function public.review_closing_report(p_report uuid, p_approve boolean, p_note text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_closing_reports;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_status text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into r from public.site_closing_reports x where x.id = p_report for update;
  if r.id is null or not public.can_access_venue(r.venue_id, array['owner', 'verifier']) then raise exception 'not allowed'; end if;
  if r.submitted_by is not distinct from auth.uid() then raise exception 'someone else must review a report you sent'; end if;
  if r.status = 'superseded' then raise exception 'a newer report replaced this one'; end if;
  if r.status <> 'submitted' then raise exception 'this report has already been %', case r.status when 'reviewed' then 'accepted' else 'not accepted' end; end if;
  if p_approve is null then raise exception 'accept the report or say why not'; end if;
  if not p_approve and (v_note is null or char_length(v_note) < 5) then raise exception 'say why the report is not accepted (at least 5 characters)'; end if;
  if v_note is not null and char_length(v_note) > 300 then raise exception 'the note is at most 300 characters'; end if;
  v_status := case when p_approve then 'reviewed' else 'rejected' end;
  update public.site_closing_reports set status = v_status, reviewed_by = auth.uid(), reviewed_at = clock_timestamp(), review_note = v_note where id = r.id;
  perform public.venue_setup_log('closing_report.review', 'closing_report', r.id, r.venue_id, jsonb_build_object('night', r.business_night, 'status', v_status));
  return v_status;
end;
$$;

create function public.closing_reports(p_venue uuid, p_limit int default 30)
returns table (
  id uuid, business_night date, version int, status text, period_start timestamptz, period_end timestamptz, gross_cents bigint, discount_cents bigint, refund_cents bigint,
  net_cents bigint, includes_bottlesup boolean, note text, submitted_at timestamptz, reviewed_at timestamptz, review_note text, mine boolean, can_review boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_review boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager', 'verifier']) then raise exception 'not allowed'; end if;
  v_review := public.can_access_venue(p_venue, array['owner', 'verifier']);
  return query
    select r.id, r.business_night, r.version, r.status, r.period_start, r.period_end, r.gross_cents, r.discount_cents, r.refund_cents, r.net_cents, r.includes_bottlesup, r.note,
           r.submitted_at, r.reviewed_at, r.review_note, (r.submitted_by is not distinct from auth.uid()), (v_review and r.status = 'submitted' and r.submitted_by is distinct from auth.uid())
      from public.site_closing_reports r
     where r.venue_id = p_venue
     order by r.business_night desc, r.version desc
     limit least(greatest(coalesce(p_limit, 30), 1), 100);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. What a night's sales mean: two labelled blocks, never added together
-- ---------------------------------------------------------------------------
create function public.night_sales_sources(p_venue uuid, p_night date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_source text;
  v_ids uuid[];
  v_total bigint; v_disc bigint; v_paid bigint; v_unpaid bigint; v_count int; v_refund bigint;
  v_gross bigint; v_net bigint;
  r public.site_closing_reports;
  v_reported jsonb := null;
  v_bar bigint;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or p_night is null or not public.can_access_venue(p_venue, array['owner', 'manager', 'verifier']) then raise exception 'not allowed'; end if;
  v_source := coalesce((select s.source from public.site_venue_sales_source s where s.venue_id = p_venue), 'entries');
  select coalesce(array_agg(n.id), '{}'::uuid[]) into v_ids from public.night_booking_ids(p_venue, p_night) n;

  select count(*)::int, coalesce(sum(b.amount_total_cents), 0), coalesce(sum(b.discount_cents + b.staff_discount_cents), 0), coalesce(sum(b.amount_paid_cents), 0),
         coalesce(sum(greatest(b.amount_total_cents - b.amount_paid_cents, 0)), 0)
    into v_count, v_total, v_disc, v_paid, v_unpaid
    from public.site_table_bookings b where b.id = any (v_ids);
  select coalesce(sum(f.approved_cents), 0) into v_refund from public.site_refund_requests f where f.status = 'completed' and f.booking_id = any (v_ids);
  v_gross := v_total + v_disc;
  v_net := greatest(v_total - v_refund, 0);

  select * into r from public.site_closing_reports x where x.venue_id = p_venue and x.business_night = p_night and x.status <> 'superseded';
  if r.id is not null then
    v_bar := case when r.includes_bottlesup then greatest(r.net_cents - v_net, 0) else r.net_cents end;
    v_reported := jsonb_build_object(
      'label', 'Venue-reported sales',
      'basis', 'The club''s own end-of-night report. It is not live bar sales.',
      'report_id', r.id, 'version', r.version, 'status', r.status,
      'period_start', r.period_start, 'period_end', r.period_end,
      'gross_cents', r.gross_cents, 'discount_cents', r.discount_cents, 'refund_cents', r.refund_cents, 'net_cents', r.net_cents,
      'includes_bottlesup', r.includes_bottlesup,
      'bar_and_other_cents', v_bar,
      'smaller_than_recorded', (r.includes_bottlesup and r.net_cents < v_net),
      'submitted_at', r.submitted_at, 'reviewed_at', r.reviewed_at,
      'verification', case r.status when 'reviewed' then 'Checked' when 'rejected' then 'Not accepted' else 'Waiting to be checked' end);
  end if;

  return jsonb_build_object(
    'business_night', p_night,
    'source', v_source,
    'source_label', case v_source when 'upload' then 'Closing report upload' else 'BottlesUp entries' end,
    'recorded', jsonb_build_object(
      'label', 'Recorded sales',
      'basis', 'What BottlesUp recorded: table bookings, their bottles and the payments taken.',
      'bookings', v_count, 'gross_cents', v_gross, 'discount_cents', v_disc, 'refund_cents', v_refund, 'net_cents', v_net,
      'collected_cents', v_paid, 'unpaid_cents', v_unpaid, 'as_of', clock_timestamp()),
    'venue_reported', v_reported);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants: signed-in people only; the database decides who may do what inside
-- ---------------------------------------------------------------------------
revoke all on function
  public.venue_sales_source(uuid), public.save_venue_sales_source(uuid, text),
  public.submit_closing_report(uuid, date, timestamptz, timestamptz, bigint, bigint, bigint, boolean, text),
  public.review_closing_report(uuid, boolean, text), public.closing_reports(uuid, int), public.night_sales_sources(uuid, date)
from public, anon;
grant execute on function
  public.venue_sales_source(uuid), public.save_venue_sales_source(uuid, text),
  public.submit_closing_report(uuid, date, timestamptz, timestamptz, bigint, bigint, bigint, boolean, text),
  public.review_closing_report(uuid, boolean, text), public.closing_reports(uuid, int), public.night_sales_sources(uuid, date)
to authenticated, service_role;
