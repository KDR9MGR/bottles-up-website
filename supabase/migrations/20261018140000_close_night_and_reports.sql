-- Preparing, closing and reporting a night (client Phase 2 brief, sections 6 and 27: "Prepare, live and close night", "Close with
-- exceptions", "Preliminary and final nightly reports", "role-specific PDFs").
--
--   * CHECKLIST: the manager (or owner) ticks off what has been done to get the night ready and to shut it down. Ticking is idempotent.
--   * CLOSING: a night closes once. Anything still open (payments not checked, cash not counted, orders not served, alerts and incident
--     reports not dealt with, tables with a balance...) is listed; closing anyway needs it acknowledged AND a reason of at least 10
--     characters, and the list of exceptions is kept with the close. Only the owner reopens a closed night, with a reason; the first close's
--     figures stay in the audit trail.
--   * REPORT: the same figures for everyone, filtered by role: the manager and owner see everything; the payment verifier sees the money
--     (sales, payments, cash, flags) and nothing about security; security sees only the security section and no money. Before the close it
--     is PRELIMINARY (worked out now); after it, FINAL (the figures as they stood at the close; later changes do not rewrite it).
--
-- Payments: a correction is a new record that REPLACES the one it corrects, so the figures count the replacement, not both.
-- A night is the club's business night (booking_night: after-midnight bookings belong to the night before).
-- Plain CREATE, never CREATE OR REPLACE. Needs the table service, cash, seating and security migrations.

-- ---------------------------------------------------------------------------
-- 1. Tables (reached only through the functions below)
-- ---------------------------------------------------------------------------
create table public.site_night_checks (
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  business_night date not null,
  item_key text not null,
  checked_by uuid not null references auth.users (id),
  checked_at timestamptz not null default clock_timestamp(),
  primary key (venue_id, business_night, item_key)
);

-- Closed nights are financial records: the club cannot be deleted while it has any.
create table public.site_night_closes (
  venue_id uuid not null references public.site_venues (id),
  business_night date not null,
  status text not null check (status in ('closed', 'reopened')),
  closed_by uuid not null references auth.users (id),
  closed_at timestamptz not null,
  exceptions jsonb not null default '[]'::jsonb,
  exceptions_note text check (exceptions_note is null or char_length(exceptions_note) <= 500),
  report jsonb not null,
  close_count int not null default 1,
  reopened_by uuid references auth.users (id),
  reopened_at timestamptz,
  reopen_reason text check (reopen_reason is null or char_length(reopen_reason) <= 500),
  primary key (venue_id, business_night),
  constraint site_night_closes_reopened_together check ((status = 'reopened') = (reopened_by is not null and reopened_at is not null))
);

alter table public.site_night_checks enable row level security;
alter table public.site_night_closes enable row level security;
revoke all on table public.site_night_checks, public.site_night_closes from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these; callers check access first)
-- ---------------------------------------------------------------------------
create function public.night_checklist_items()
returns table (item_key text, label text, phase text, sort int)
language sql
immutable
set search_path = public
as $$
  select * from (values
    ('floor_ready', 'Floor plan and tables are set up', 'prepare', 1),
    ('servers_assigned', 'Every booked table has a server', 'prepare', 2),
    ('stock_ready', 'Bottles and stock checked', 'prepare', 3),
    ('float_ready', 'Cash float counted', 'prepare', 4),
    ('security_briefed', 'Security briefed', 'prepare', 5),
    ('doors_ready', 'Door team ready', 'prepare', 6),
    ('floor_cleared', 'Floor cleared and tables released', 'close', 7),
    ('stock_counted', 'Closing stock counted', 'close', 8),
    ('cash_secured', 'Cash counted and locked away', 'close', 9)
  ) as t(item_key, label, phase, sort)
$$;

-- The paid bookings of one business night at a club.
create function public.night_booking_ids(p_venue uuid, p_night date)
returns table (id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select b.id
  from public.site_table_bookings b
  join public.site_venue_time_slots s on s.id = b.time_slot_id
  where b.venue_id = p_venue and b.status = 'paid'
    and b.booking_date between p_night and p_night + 1
    and public.booking_night(b.booking_date, s.start_time) = p_night
$$;

-- What is still open at a club for a night, as [{"key","label","count"}], most important first. Empty when nothing is.
create function public.night_blockers(p_venue uuid, p_night date)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with nb as (select id from public.night_booking_ids(p_venue, p_night)),
  eff as (
    select cp.* from public.site_table_booking_club_payments cp join nb on nb.id = cp.booking_id
    where not exists (select 1 from public.site_table_booking_club_payments c2 where c2.corrects_payment_id = cp.id)
  ),
  items (key, label, n, sort) as (values
    ('payments_to_check', 'payments waiting to be checked',
      (select count(*) from eff where eff.manager_verified_at is null and eff.customer_confirmation_status = 'pending'), 1),
    ('payments_disputed', 'payments disputed by the guest', (select count(*) from eff where eff.customer_confirmation_status = 'disputed'), 2),
    ('flags_open', 'payments flagged and not resolved',
      (select count(*) from public.site_payment_flags f join eff on eff.id = f.payment_id where f.status = 'open'), 3),
    ('handovers_waiting', 'cash handovers not yet counted',
      (select count(*) from public.site_cash_handovers h where h.venue_id = p_venue and h.business_night = p_night and h.status = 'submitted'), 4),
    ('cash_held', 'people still holding cash they have not handed in',
      (select count(*) from public.desk_cash_rows(p_venue, p_night) r where r.collected_cents - r.handed_in_cents > 0), 5),
    ('orders_not_served', 'bottle orders not yet served',
      (select count(*) from public.site_table_booking_bottles bb join nb on nb.id = bb.booking_id
        where bb.cancelled_at is null and bb.payment_status <> 'pending_payment' and bb.service_status <> 'served'), 6),
    ('requests_open', 'requests from tables still open',
      (select count(*) from public.site_service_requests r join nb on nb.id = r.booking_id
        where r.status in ('new', 'acknowledged', 'in_progress', 'escalated')), 7),
    ('balances_due', 'tables with a balance still due',
      (select count(*) from public.site_table_bookings b join nb on nb.id = b.id where b.amount_total_cents > b.amount_paid_cents), 8),
    ('alerts_unresolved', 'security alerts not resolved',
      (select count(*) from public.site_security_alerts a where a.venue_id = p_venue and a.business_night = p_night and a.status <> 'resolved'), 9),
    ('tasks_open', 'security tasks not done',
      (select count(*) from public.site_security_tasks t where t.venue_id = p_venue and t.business_night = p_night and t.status = 'open'), 10),
    ('incidents_to_review', 'incident reports not yet reviewed',
      (select count(*) from public.site_security_incidents i where i.venue_id = p_venue and i.business_night = p_night and i.status = 'submitted'), 11)
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', key, 'label', label, 'count', n) order by sort) filter (where n > 0), '[]'::jsonb) from items
$$;

-- The figures of one night at a club, as they stand now. No access check: callers do it first.
create function public.night_report_data(p_venue uuid, p_night date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_name text;
  v_bookings jsonb;
  v_payments jsonb;
  v_bottles jsonb;
  v_cash jsonb;
  v_flags jsonb;
  v_service jsonb;
  v_security jsonb;
begin
  select v.name into v_name from public.site_venues v where v.id = p_venue;

  select jsonb_build_object(
    'count', count(*),
    'guests', coalesce(sum(b.guest_count), 0),
    'total_cents', coalesce(sum(b.amount_total_cents), 0),
    'paid_cents', coalesce(sum(b.amount_paid_cents), 0),
    'balance_cents', coalesce(sum(greatest(b.amount_total_cents - b.amount_paid_cents, 0)), 0),
    'discount_cents', coalesce(sum(b.discount_cents), 0),
    'seated', count(*) filter (where exists (select 1 from public.site_booking_seating s where s.booking_id = b.id)))
  into v_bookings
  from public.site_table_bookings b where b.id in (select id from public.night_booking_ids(p_venue, p_night));

  select jsonb_build_object(
    'count', count(*),
    'collected_cents', coalesce(sum(cp.amount_paid_cents), 0),
    'billed_cents', coalesce(sum(cp.billed_amount_cents), 0),
    'cash_cents', coalesce(sum(public.desk_cash_part(cp.payment_method, cp.amount_paid_cents, cp.split_breakdown)), 0),
    'debit_cents', coalesce(sum(cp.amount_paid_cents) filter (where cp.payment_method = 'debit'), 0),
    'credit_cents', coalesce(sum(cp.amount_paid_cents) filter (where cp.payment_method = 'credit'), 0),
    'split_card_cents', coalesce(sum(cp.amount_paid_cents - public.desk_cash_part(cp.payment_method, cp.amount_paid_cents, cp.split_breakdown)) filter (where cp.payment_method = 'split'), 0),
    'tax_cents', coalesce(sum(cp.tax_cents), 0),
    'gratuity_cents', coalesce(sum(cp.gratuity_cents), 0),
    'discount_cents', coalesce(sum(cp.discount_cents), 0),
    'unverified', count(*) filter (where cp.manager_verified_at is null),
    'disputed', count(*) filter (where cp.customer_confirmation_status = 'disputed'),
    'no_receipt', count(*) filter (where cp.receipt_photo_path is null),
    'corrections', count(*) filter (where cp.corrects_payment_id is not null))
  into v_payments
  from public.site_table_booking_club_payments cp
  where cp.booking_id in (select id from public.night_booking_ids(p_venue, p_night))
    and not exists (select 1 from public.site_table_booking_club_payments c2 where c2.corrects_payment_id = cp.id);

  select jsonb_build_object(
    'lines', count(*) filter (where bb.cancelled_at is null),
    'value_cents', coalesce(sum(bb.line_total_cents) filter (where bb.cancelled_at is null), 0),
    'served', count(*) filter (where bb.cancelled_at is null and bb.service_status = 'served'),
    'in_progress', count(*) filter (where bb.cancelled_at is null and bb.service_status in ('preparing', 'ready', 'picked_up')),
    'awaiting', count(*) filter (where bb.cancelled_at is null and bb.service_status = 'awaiting_prep'),
    'cancelled', count(*) filter (where bb.cancelled_at is not null),
    'due_at_venue', count(*) filter (where bb.cancelled_at is null and bb.payment_status = 'due_at_venue'))
  into v_bottles
  from public.site_table_booking_bottles bb
  where bb.booking_id in (select id from public.night_booking_ids(p_venue, p_night));

  select jsonb_build_object(
    'handovers', count(*),
    'claimed_cents', coalesce(sum(h.claimed_cents), 0),
    'counted_cents', coalesce(sum(h.counted_cents), 0),
    'shortage_cents', coalesce(sum(h.claimed_cents - h.counted_cents) filter (where h.status = 'acknowledged' and h.counted_cents < h.claimed_cents), 0),
    'overage_cents', coalesce(sum(h.counted_cents - h.claimed_cents) filter (where h.status = 'acknowledged' and h.counted_cents > h.claimed_cents), 0),
    'waiting', count(*) filter (where h.status = 'submitted'),
    'held_cents', coalesce((select sum(greatest(r.collected_cents - r.handed_in_cents, 0)) from public.desk_cash_rows(p_venue, p_night) r), 0))
  into v_cash
  from public.site_cash_handovers h where h.venue_id = p_venue and h.business_night = p_night;

  select jsonb_build_object(
    'raised', count(*),
    'open', count(*) filter (where f.status = 'open'),
    'resolved', count(*) filter (where f.status = 'resolved'),
    'by_resolution', coalesce((select jsonb_object_agg(x.resolution, x.n) from (
        select f2.resolution, count(*) as n from public.site_payment_flags f2
        join public.site_table_booking_club_payments cp2 on cp2.id = f2.payment_id
        where cp2.booking_id in (select id from public.night_booking_ids(p_venue, p_night)) and f2.resolution is not null
        group by f2.resolution) x), '{}'::jsonb))
  into v_flags
  from public.site_payment_flags f
  join public.site_table_booking_club_payments cp on cp.id = f.payment_id
  where cp.booking_id in (select id from public.night_booking_ids(p_venue, p_night));

  select jsonb_build_object(
    'total', count(*),
    'open', count(*) filter (where r.status in ('new', 'acknowledged', 'in_progress', 'escalated')),
    'completed', count(*) filter (where r.status = 'completed'),
    'escalated', count(*) filter (where r.status = 'escalated'),
    'cancelled', count(*) filter (where r.status = 'cancelled'))
  into v_service
  from public.site_service_requests r
  where r.booking_id in (select id from public.night_booking_ids(p_venue, p_night));

  select jsonb_build_object(
    'alerts', (select jsonb_build_object(
        'total', count(*),
        'urgent', count(*) filter (where a.urgent),
        'unresolved', count(*) filter (where a.status <> 'resolved'),
        'escalated', count(*) filter (where a.status = 'escalated'),
        'by_kind', coalesce((select jsonb_object_agg(k.kind, k.n) from (
            select a2.kind, count(*) as n from public.site_security_alerts a2 where a2.venue_id = p_venue and a2.business_night = p_night group by a2.kind) k), '{}'::jsonb))
      from public.site_security_alerts a where a.venue_id = p_venue and a.business_night = p_night),
    'tasks', (select jsonb_build_object('total', count(*), 'done', count(*) filter (where t.status = 'done'), 'open', count(*) filter (where t.status = 'open'))
      from public.site_security_tasks t where t.venue_id = p_venue and t.business_night = p_night),
    'incidents', coalesce((select jsonb_agg(jsonb_build_object('kind', i.kind, 'location', i.location, 'status', i.status) order by i.occurred_at, i.id)
      from public.site_security_incidents i where i.venue_id = p_venue and i.business_night = p_night), '[]'::jsonb))
  into v_security;

  return jsonb_build_object(
    'venue_name', v_name,
    'business_night', p_night,
    'generated_at', clock_timestamp(),
    'bookings', v_bookings,
    'payments', v_payments,
    'bottles', v_bottles,
    'cash', v_cash,
    'flags', v_flags,
    'service', v_service,
    'security', v_security);
end;
$$;

revoke all on function
  public.night_checklist_items(), public.night_booking_ids(uuid, date), public.night_blockers(uuid, date), public.night_report_data(uuid, date)
from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The checklist
-- ---------------------------------------------------------------------------
create function public.night_checklist(p_venue uuid, p_night date)
returns table (item_key text, label text, phase text, done boolean, done_by_name text, done_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;

  return query
    select i.item_key, i.label, i.phase, c.checked_by is not null,
           case when c.checked_by is null then null else coalesce(nullif(btrim(pr.name), ''), 'Staff member') end, c.checked_at
    from public.night_checklist_items() i
    left join public.site_night_checks c on c.venue_id = p_venue and c.business_night = p_night and c.item_key = i.item_key
    left join public.profiles pr on pr.id = c.checked_by
    order by i.sort;
end;
$$;

-- Tick (p_done true) or untick an item. Returns whether anything changed; ticking twice changes nothing. Not on a closed night.
create function public.night_check(p_venue uuid, p_night date, p_key text, p_done boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if p_key is null or not exists (select 1 from public.night_checklist_items() i where i.item_key = p_key) then raise exception 'choose a checklist item'; end if;
  if exists (select 1 from public.site_night_closes c where c.venue_id = p_venue and c.business_night = p_night and c.status = 'closed') then
    raise exception 'this night is closed: the owner has to reopen it first';
  end if;

  if coalesce(p_done, false) then
    insert into public.site_night_checks (venue_id, business_night, item_key, checked_by) values (p_venue, p_night, p_key, auth.uid())
      on conflict (venue_id, business_night, item_key) do nothing;
  else
    delete from public.site_night_checks where venue_id = p_venue and business_night = p_night and item_key = p_key;
  end if;
  get diagnostics n = row_count;
  if n > 0 then
    perform public.desk_log(case when coalesce(p_done, false) then 'night.checked' else 'night.unchecked' end, 'site_night_checks', p_venue,
      jsonb_build_object('venue_id', p_venue, 'night', p_night, 'item', p_key));
  end if;
  return n > 0;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Closing and reopening
-- ---------------------------------------------------------------------------
-- Where the night stands: open or closed, what is still open, and which closing items are not ticked.
create function public.night_close_status(p_venue uuid, p_night date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.site_night_closes;
  v_open_items jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;

  select * into c from public.site_night_closes where venue_id = p_venue and business_night = p_night;
  select coalesce(jsonb_agg(i.label order by i.sort), '[]'::jsonb) into v_open_items
    from public.night_checklist_items() i
    where i.phase = 'close' and not exists (select 1 from public.site_night_checks k where k.venue_id = p_venue and k.business_night = p_night and k.item_key = i.item_key);

  return jsonb_build_object(
    'status', coalesce(c.status, 'open'),
    'closed', coalesce(c.status = 'closed', false),
    'closed_at', c.closed_at,
    'closed_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = c.closed_by),
    'exceptions', coalesce(c.exceptions, '[]'::jsonb),
    'exceptions_note', c.exceptions_note,
    'reopened_at', c.reopened_at,
    'reopen_reason', c.reopen_reason,
    'blockers', public.night_blockers(p_venue, p_night),
    'close_items_open', v_open_items);
end;
$$;

-- Close the night. Anything still open stops it unless p_acknowledge is true and a reason (10+ characters) says why; the exceptions are kept.
create function public.close_night(p_venue uuid, p_night date, p_acknowledge boolean default false, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.site_night_closes;
  v_blockers jsonb;
  v_open_items jsonb;
  v_exceptions jsonb;
  v_note text;
  v_list text;
  v_report jsonb;
  v_existing boolean;
  v_now timestamptz := clock_timestamp();
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if p_night > current_date + 1 then raise exception 'a night that has not started cannot be closed'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 500 then raise exception 'keep the note to 500 characters or fewer'; end if;

  -- One close at a time per club and night: two taps end with one close.
  perform pg_advisory_xact_lock(hashtextextended('night_close:' || p_venue::text || ':' || p_night::text, 0));
  select * into c from public.site_night_closes where venue_id = p_venue and business_night = p_night;
  v_existing := found;
  if v_existing and c.status = 'closed' then raise exception 'this night is already closed'; end if;

  v_blockers := public.night_blockers(p_venue, p_night);
  select coalesce(jsonb_agg(jsonb_build_object('key', i.item_key, 'label', i.label, 'count', 1, 'kind', 'checklist') order by i.sort), '[]'::jsonb) into v_open_items
    from public.night_checklist_items() i
    where i.phase = 'close' and not exists (select 1 from public.site_night_checks k where k.venue_id = p_venue and k.business_night = p_night and k.item_key = i.item_key);
  v_exceptions := v_blockers || v_open_items;

  if jsonb_array_length(v_exceptions) > 0 then
    if not coalesce(p_acknowledge, false) then
      select string_agg(case when (e ->> 'kind') = 'checklist' then 'not ticked: ' || (e ->> 'label') else (e ->> 'count') || ' ' || (e ->> 'label') end, ', ')
        into v_list from jsonb_array_elements(v_exceptions) e;
      raise exception 'still open: %. Deal with it, or close with exceptions and say why', v_list;
    end if;
    if v_note is null or char_length(v_note) < 10 then raise exception 'say why you are closing with these still open (at least 10 characters)'; end if;
  else
    v_note := null;
  end if;

  v_report := public.night_report_data(p_venue, p_night);
  if v_existing then
    update public.site_night_closes
      set status = 'closed', closed_by = auth.uid(), closed_at = v_now, exceptions = v_exceptions, exceptions_note = v_note, report = v_report,
          close_count = close_count + 1, reopened_by = null, reopened_at = null, reopen_reason = null
      where venue_id = p_venue and business_night = p_night;
  else
    insert into public.site_night_closes (venue_id, business_night, status, closed_by, closed_at, exceptions, exceptions_note, report)
      values (p_venue, p_night, 'closed', auth.uid(), v_now, v_exceptions, v_note, v_report);
  end if;

  perform public.desk_log('night.closed', 'site_night_closes', p_venue,
    jsonb_build_object('venue_id', p_venue, 'night', p_night, 'exceptions', jsonb_array_length(v_exceptions), 'report', v_report));
  return jsonb_build_object('closed_at', v_now, 'exceptions', jsonb_array_length(v_exceptions));
end;
$$;

-- Only the owner reopens a closed night, with a reason. Its figures at the close stay in the audit log.
create function public.reopen_night(p_venue uuid, p_night date, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.site_night_closes;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner']) then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  v_reason := btrim(p_reason);
  if v_reason is null or char_length(v_reason) < 10 then raise exception 'say why this night is being reopened (at least 10 characters)'; end if;
  if char_length(v_reason) > 500 then raise exception 'keep the reason to 500 characters or fewer'; end if;

  perform pg_advisory_xact_lock(hashtextextended('night_close:' || p_venue::text || ':' || p_night::text, 0));
  select * into c from public.site_night_closes where venue_id = p_venue and business_night = p_night;
  if not found or c.status <> 'closed' then raise exception 'this night is not closed'; end if;

  update public.site_night_closes set status = 'reopened', reopened_by = auth.uid(), reopened_at = clock_timestamp(), reopen_reason = v_reason
    where venue_id = p_venue and business_night = p_night;
  perform public.desk_log('night.reopened', 'site_night_closes', p_venue, jsonb_build_object('venue_id', p_venue, 'night', p_night, 'reason', v_reason));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The report, by role
-- ---------------------------------------------------------------------------
-- 'full' for the manager and owner, 'finance' for the payment verifier, 'security' for security. Final once closed, else preliminary.
create function public.night_report(p_venue uuid, p_night date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.site_night_closes;
  v_view text;
  v_data jsonb;
  v_out jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if p_venue is null then raise exception 'not allowed'; end if;
  if public.can_access_venue(p_venue, array['owner', 'manager']) then v_view := 'full';
  elsif public.can_access_venue(p_venue, array['verifier']) then v_view := 'finance';
  elsif public.can_access_venue(p_venue, array['security']) then v_view := 'security';
  else raise exception 'not allowed';
  end if;

  select * into c from public.site_night_closes where venue_id = p_venue and business_night = p_night;
  if found and c.status = 'closed' then v_data := c.report; else v_data := public.night_report_data(p_venue, p_night); end if;

  v_out := jsonb_build_object(
    'view', v_view,
    'final', coalesce(c.status = 'closed', false),
    'venue_name', v_data -> 'venue_name',
    'business_night', v_data -> 'business_night',
    'generated_at', v_data -> 'generated_at');
  if coalesce(c.status = 'closed', false) then
    v_out := v_out || jsonb_build_object(
      'closed_at', c.closed_at,
      'closed_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = c.closed_by));
    if v_view <> 'security' then
      v_out := v_out || jsonb_build_object('exceptions', c.exceptions, 'exceptions_note', c.exceptions_note);
    end if;
  end if;

  if v_view in ('full', 'finance') then
    v_out := v_out || jsonb_build_object('bookings', v_data -> 'bookings', 'payments', v_data -> 'payments', 'cash', v_data -> 'cash', 'flags', v_data -> 'flags');
  end if;
  if v_view = 'full' then
    v_out := v_out || jsonb_build_object('bottles', v_data -> 'bottles', 'service', v_data -> 'service');
  end if;
  if v_view in ('full', 'security') then
    v_out := v_out || jsonb_build_object('security', v_data -> 'security');
  end if;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.night_checklist(uuid, date), public.night_check(uuid, date, text, boolean), public.night_close_status(uuid, date),
  public.close_night(uuid, date, boolean, text), public.reopen_night(uuid, date, text), public.night_report(uuid, date)
from public, anon;
grant execute on function
  public.night_checklist(uuid, date), public.night_check(uuid, date, text, boolean), public.night_close_status(uuid, date),
  public.close_night(uuid, date, boolean, text), public.reopen_night(uuid, date, text), public.night_report(uuid, date)
to authenticated, service_role;
