-- Cash handover and flagged payments (client Phase 2 brief, sections 15 and 26, and the payment verifier's Cash / Exceptions / Summary tabs).
--
-- CASH: "Server collection -> Cash held by server -> Handover submitted -> Cashier/manager acknowledges actual amount -> Reconcile.
-- Preserve shortages/overages and holder history."
--   * Cash held = the cash that person recorded for a business night at a club (a cash payment, plus the cash parts of a split), minus what
--     they have already handed in. It is worked out from the payments, never typed in.
--   * A person hands in what they hold, or part of it, never more, and never twice at once (two taps cannot hand in the same cash twice).
--   * Someone else (the venue's manager, owner or verifier; never the person who handed it in) says what they actually counted. A difference
--     is kept as it is (shortage or overage) and needs a reason. An acknowledged handover is never edited.
--
-- FLAGS: "Verify or Flag -> Manager resolves." A verifier (or manager) flags a payment with a reason; only a manager or owner resolves it, with
-- a recorded outcome. Flagging does not change the payment, and nobody flags their own entry.
--
-- WHO SEES WHAT: a server sees only their own cash and handovers; the manager, owner and verifier of THAT club see all of theirs; other staff,
-- other clubs and anonymous visitors see nothing. Every step is attributed in the audit log.
--
-- Needs the table service migrations (the payments table and desk_level / desk_log / booking_venue). Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Tables (reached only through the functions below)
-- ---------------------------------------------------------------------------
create table public.site_cash_handovers (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  business_night date not null,
  from_user uuid not null references auth.users (id),
  claimed_cents int not null check (claimed_cents > 0),
  status text not null default 'submitted' check (status in ('submitted', 'acknowledged')),
  note text check (note is null or char_length(note) <= 300),
  submitted_at timestamptz not null default now(),
  received_by uuid references auth.users (id),
  received_at timestamptz,
  counted_cents int check (counted_cents is null or counted_cents >= 0),
  receive_note text check (receive_note is null or char_length(receive_note) <= 300),
  constraint site_cash_handovers_received_together check (
    (status = 'submitted' and received_by is null and received_at is null and counted_cents is null)
    or (status = 'acknowledged' and received_by is not null and received_at is not null and counted_cents is not null)
  ),
  constraint site_cash_handovers_not_own check (received_by is distinct from from_user)
);
create index site_cash_handovers_venue_night_idx on public.site_cash_handovers (venue_id, business_night);

create table public.site_payment_flags (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.site_table_booking_club_payments (id) on delete cascade,
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  raised_by uuid not null references auth.users (id),
  reason text not null check (char_length(btrim(reason)) between 3 and 500),
  status text not null default 'open' check (status in ('open', 'resolved')),
  raised_at timestamptz not null default now(),
  resolved_by uuid references auth.users (id),
  resolved_at timestamptz,
  resolution text check (resolution in ('confirmed_ok', 'corrected', 'refunded', 'written_off', 'other')),
  resolution_note text check (resolution_note is null or char_length(resolution_note) <= 500),
  constraint site_payment_flags_resolved_together check (
    (status = 'open' and resolved_by is null and resolved_at is null and resolution is null)
    or (status = 'resolved' and resolved_by is not null and resolved_at is not null and resolution is not null)
  )
);
-- One open flag per payment: flagging an already flagged payment is refused, not duplicated.
create unique index site_payment_flags_one_open_idx on public.site_payment_flags (payment_id) where status = 'open';
create index site_payment_flags_venue_idx on public.site_payment_flags (venue_id, status);

alter table public.site_cash_handovers enable row level security;
alter table public.site_payment_flags enable row level security;
revoke all on table public.site_cash_handovers, public.site_payment_flags from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
-- The cash part of one payment: all of it for a cash payment, the cash parts of a split ([{"method":"cash","cents":1200}, ...]), else 0.
create function public.desk_cash_part(p_method text, p_paid int, p_split jsonb)
returns int
language sql
immutable
set search_path = public
as $$
  select case
    when p_method = 'cash' then coalesce(p_paid, 0)
    when p_method = 'split' and jsonb_typeof(p_split) = 'array' then coalesce((
      select sum((e ->> 'cents')::int)::int
      from jsonb_array_elements(p_split) e
      where e ->> 'method' = 'cash' and (e ->> 'cents') ~ '^[0-9]{1,9}$'
    ), 0)
    else 0
  end
$$;

-- Per person: cash collected and cash already handed in, for one club and business night. No access check: callers do it first.
create function public.desk_cash_rows(p_venue uuid, p_night date)
returns table (user_id uuid, collected_cents int, handed_in_cents int)
language sql
stable
security definer
set search_path = public
as $$
  with collected as (
    select cp.recorded_by as uid, sum(public.desk_cash_part(cp.payment_method, cp.amount_paid_cents, cp.split_breakdown))::int as cents
    from public.site_table_booking_club_payments cp
    join public.site_table_bookings b on b.id = cp.booking_id
    join public.site_venue_time_slots s on s.id = b.time_slot_id
    where b.venue_id = p_venue
      and b.booking_date between p_night and p_night + 1
      and public.booking_night(b.booking_date, s.start_time) = p_night
      and cp.recorded_by is not null
      -- A correction is a new record that replaces the one it corrects: count the replacement, not both.
      and not exists (select 1 from public.site_table_booking_club_payments c2 where c2.corrects_payment_id = cp.id)
    group by cp.recorded_by
  ), handed as (
    select h.from_user as uid, sum(h.claimed_cents)::int as cents
    from public.site_cash_handovers h
    where h.venue_id = p_venue and h.business_night = p_night
    group by h.from_user
  )
  select coalesce(c.uid, h.uid), coalesce(c.cents, 0), coalesce(h.cents, 0)
  from collected c full join handed h on h.uid = c.uid
  where coalesce(c.cents, 0) > 0 or coalesce(h.cents, 0) > 0
$$;

revoke all on function public.desk_cash_part(text, int, jsonb), public.desk_cash_rows(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Cash: position, handing in, acknowledging
-- ---------------------------------------------------------------------------
-- Who holds how much cash tonight. Staff who only serve see their own line; the manager, owner and verifier see everyone's.
create function public.desk_cash_position(p_venue uuid, p_night date)
returns table (collector_name text, is_me boolean, collected_cents int, handed_in_cents int, held_cents int)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_all boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  v_all := public.can_access_venue(p_venue, array['manager', 'owner', 'verifier']);
  if not v_all and not public.can_access_venue(p_venue, array['server']) then raise exception 'not allowed'; end if;

  return query
    select coalesce(nullif(btrim(pr.name), ''), 'Staff member'), r.user_id = auth.uid(), r.collected_cents, r.handed_in_cents,
           greatest(r.collected_cents - r.handed_in_cents, 0)
    from public.desk_cash_rows(p_venue, p_night) r
    left join public.profiles pr on pr.id = r.user_id
    where v_all or r.user_id = auth.uid()
    order by (r.user_id = auth.uid()) desc, greatest(r.collected_cents - r.handed_in_cents, 0) desc, 1;
end;
$$;

-- Hand in cash. Up to what the caller holds, never more, never nothing.
create function public.desk_submit_handover(p_venue uuid, p_night date, p_amount_cents int, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_held int;
  v_note text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if not public.can_access_venue(p_venue, array['server', 'manager', 'owner', 'verifier']) then raise exception 'not allowed'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'enter the amount you are handing over'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 300 then raise exception 'keep the note to 300 characters or fewer'; end if;

  -- One person's handovers for one night are taken one at a time, so two taps cannot hand in the same cash twice.
  perform pg_advisory_xact_lock(hashtextextended('cash:' || p_venue::text || ':' || p_night::text || ':' || auth.uid()::text, 0));

  select greatest(r.collected_cents - r.handed_in_cents, 0) into v_held from public.desk_cash_rows(p_venue, p_night) r where r.user_id = auth.uid();
  if coalesce(v_held, 0) <= 0 then raise exception 'you are not holding any cash for this night'; end if;
  if p_amount_cents > v_held then raise exception 'you only hold % for this night', to_char(v_held / 100.0, 'FM999999990.00'); end if;

  insert into public.site_cash_handovers (venue_id, business_night, from_user, claimed_cents, note)
  values (p_venue, p_night, auth.uid(), p_amount_cents, v_note)
  returning id into v_id;

  perform public.desk_log('cash.handover_submitted', 'site_cash_handovers', v_id,
    jsonb_build_object('venue_id', p_venue, 'night', p_night, 'claimed_cents', p_amount_cents));
  return v_id;
end;
$$;

-- The handovers of a night. A server sees their own; the manager, owner and verifier see all of the club's.
create function public.desk_list_handovers(p_venue uuid, p_night date)
returns table (
  handover_id uuid, collector_name text, is_mine boolean, claimed_cents int, status text, submitted_at timestamptz, note text,
  received_by_name text, received_at timestamptz, counted_cents int, difference_cents int, receive_note text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_all boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  v_all := public.can_access_venue(p_venue, array['manager', 'owner', 'verifier']);
  if not v_all and not public.can_access_venue(p_venue, array['server']) then raise exception 'not allowed'; end if;

  return query
    select h.id, coalesce(nullif(btrim(pf.name), ''), 'Staff member'), h.from_user = auth.uid(), h.claimed_cents, h.status, h.submitted_at, h.note,
           case when h.received_by is not null then coalesce(nullif(btrim(pr.name), ''), 'Staff member') end,
           h.received_at, h.counted_cents,
           case when h.counted_cents is not null then h.counted_cents - h.claimed_cents end,
           h.receive_note
    from public.site_cash_handovers h
    left join public.profiles pf on pf.id = h.from_user
    left join public.profiles pr on pr.id = h.received_by
    where h.venue_id = p_venue and h.business_night = p_night and (v_all or h.from_user = auth.uid())
    order by (h.status = 'submitted') desc, h.submitted_at, h.id
    limit 300;
end;
$$;

-- Acknowledge a handover with the amount actually counted. Not your own, not twice, and a difference needs a reason.
create function public.desk_receive_handover(p_handover uuid, p_counted_cents int, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.site_cash_handovers;
  v_note text;
  v_diff int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into h from public.site_cash_handovers where id = p_handover for update;
  if not found or not public.can_access_venue(h.venue_id, array['manager', 'owner', 'verifier']) then raise exception 'not allowed'; end if;
  if h.status <> 'submitted' then raise exception 'this handover was already acknowledged'; end if;
  if h.from_user = auth.uid() then raise exception 'you handed this in, so someone else has to count it'; end if;
  if p_counted_cents is null or p_counted_cents < 0 then raise exception 'enter the amount you counted'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 300 then raise exception 'keep the note to 300 characters or fewer'; end if;
  v_diff := p_counted_cents - h.claimed_cents;
  if v_diff <> 0 and (v_note is null or char_length(v_note) < 3) then
    raise exception 'the amount counted differs from the amount handed in: say why';
  end if;

  update public.site_cash_handovers
    set status = 'acknowledged', received_by = auth.uid(), received_at = now(), counted_cents = p_counted_cents, receive_note = v_note
    where id = p_handover;

  perform public.desk_log('cash.handover_received', 'site_cash_handovers', p_handover,
    jsonb_build_object('venue_id', h.venue_id, 'night', h.business_night, 'claimed_cents', h.claimed_cents, 'counted_cents', p_counted_cents, 'difference_cents', v_diff));
  return jsonb_build_object('difference_cents', v_diff, 'claimed_cents', h.claimed_cents, 'counted_cents', p_counted_cents);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Flagged payments
-- ---------------------------------------------------------------------------
create function public.desk_flag_payment(p_payment uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking uuid;
  v_venue uuid;
  v_recorder uuid;
  v_reason text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select cp.booking_id, cp.recorded_by into v_booking, v_recorder from public.site_table_booking_club_payments cp where cp.id = p_payment;
  v_venue := public.booking_venue(v_booking);
  if v_venue is null or not public.can_access_venue(v_venue, array['manager', 'owner', 'verifier']) then raise exception 'not allowed'; end if;
  if v_recorder is not null and v_recorder = auth.uid() then raise exception 'you recorded this payment, so someone else has to flag it'; end if;
  v_reason := btrim(p_reason);
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'say what is wrong with this payment'; end if;
  if char_length(v_reason) > 500 then raise exception 'keep the reason to 500 characters or fewer'; end if;

  -- Serialise on the payment so two people flagging it at once end with one open flag.
  perform 1 from public.site_table_booking_club_payments cp where cp.id = p_payment for update;
  if exists (select 1 from public.site_payment_flags f where f.payment_id = p_payment and f.status = 'open') then
    raise exception 'this payment is already flagged';
  end if;

  insert into public.site_payment_flags (payment_id, venue_id, raised_by, reason) values (p_payment, v_venue, auth.uid(), v_reason) returning id into v_id;
  perform public.desk_log('payment.flagged', 'site_payment_flags', v_id, jsonb_build_object('venue_id', v_venue, 'payment_id', p_payment));
  return v_id;
end;
$$;

create function public.desk_resolve_flag(p_flag uuid, p_resolution text, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.site_payment_flags;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into f from public.site_payment_flags where id = p_flag for update;
  if not found or not public.can_access_venue(f.venue_id, array['manager', 'owner']) then raise exception 'not allowed'; end if;
  if f.status <> 'open' then raise exception 'this flag was already resolved'; end if;
  if p_resolution is null or p_resolution not in ('confirmed_ok', 'corrected', 'refunded', 'written_off', 'other') then
    raise exception 'choose how it was resolved';
  end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 500 then raise exception 'keep the note to 500 characters or fewer'; end if;
  if p_resolution <> 'confirmed_ok' and (v_note is null or char_length(v_note) < 3) then raise exception 'say what was done'; end if;

  update public.site_payment_flags
    set status = 'resolved', resolved_by = auth.uid(), resolved_at = now(), resolution = p_resolution, resolution_note = v_note
    where id = p_flag;
  perform public.desk_log('payment.flag_resolved', 'site_payment_flags', p_flag, jsonb_build_object('venue_id', f.venue_id, 'resolution', p_resolution));
end;
$$;

-- The flags of a club: open ones first. Manager, owner and verifier.
create function public.desk_list_flags(p_venue uuid, p_status text default 'open')
returns table (
  flag_id uuid, payment_id uuid, booking_id uuid, confirmation_code text, customer_name text, table_name text, payment_method text,
  amount_paid_cents int, reason text, raised_by_name text, raised_by_me boolean, raised_at timestamptz, status text,
  resolution text, resolution_note text, resolved_by_name text, resolved_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.can_access_venue(p_venue, array['manager', 'owner', 'verifier']) then raise exception 'not allowed'; end if;
  if p_status is not null and p_status not in ('open', 'resolved') then raise exception 'choose open or resolved'; end if;

  return query
    select f.id, f.payment_id, b.id, b.confirmation_code, b.customer_name, t.name, cp.payment_method, cp.amount_paid_cents, f.reason,
           coalesce(nullif(btrim(pr.name), ''), 'Staff member'), f.raised_by = auth.uid(), f.raised_at, f.status,
           f.resolution, f.resolution_note,
           case when f.resolved_by is not null then coalesce(nullif(btrim(pv.name), ''), 'Staff member') end, f.resolved_at
    from public.site_payment_flags f
    join public.site_table_booking_club_payments cp on cp.id = f.payment_id
    join public.site_table_bookings b on b.id = cp.booking_id
    join public.site_table_types t on t.id = b.table_type_id
    left join public.profiles pr on pr.id = f.raised_by
    left join public.profiles pv on pv.id = f.resolved_by
    where f.venue_id = p_venue and (p_status is null or f.status = p_status)
    order by (f.status = 'open') desc, f.raised_at desc, f.id
    limit 300;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The verifier's summary (open flags are the whole club's work to do; resolved ones are counted for the night's payments)
-- ---------------------------------------------------------------------------
create function public.desk_verifier_summary(p_venue uuid, p_night date)
returns table (
  payments_recorded int, payments_checked int, payments_to_check int, payments_disputed int, checked_by_me int,
  flags_open int, flags_resolved int, handovers_waiting int, handovers_acknowledged int, cash_difference_cents int
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.can_access_venue(p_venue, array['manager', 'owner', 'verifier']) then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;

  return query
    with pays as (
      select cp.*
      from public.site_table_booking_club_payments cp
      join public.site_table_bookings b on b.id = cp.booking_id
      join public.site_venue_time_slots s on s.id = b.time_slot_id
      where b.venue_id = p_venue and b.booking_date between p_night and p_night + 1
        and public.booking_night(b.booking_date, s.start_time) = p_night
    )
    select (select count(*)::int from pays),
           (select count(*)::int from pays where manager_verified_at is not null),
           (select count(*)::int from pays where manager_verified_at is null and customer_confirmation_status = 'pending'),
           (select count(*)::int from pays where customer_confirmation_status = 'disputed'),
           (select count(*)::int from pays where manager_verified_by = auth.uid()),
           (select count(*)::int from public.site_payment_flags f where f.venue_id = p_venue and f.status = 'open'),
           (select count(*)::int from public.site_payment_flags f join pays on pays.id = f.payment_id where f.venue_id = p_venue and f.status = 'resolved'),
           (select count(*)::int from public.site_cash_handovers h where h.venue_id = p_venue and h.business_night = p_night and h.status = 'submitted'),
           (select count(*)::int from public.site_cash_handovers h where h.venue_id = p_venue and h.business_night = p_night and h.status = 'acknowledged'),
           coalesce((select sum(h.counted_cents - h.claimed_cents)::int from public.site_cash_handovers h
                     where h.venue_id = p_venue and h.business_night = p_night and h.status = 'acknowledged'), 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.desk_cash_position(uuid, date), public.desk_submit_handover(uuid, date, int, text), public.desk_list_handovers(uuid, date),
  public.desk_receive_handover(uuid, int, text), public.desk_flag_payment(uuid, text), public.desk_resolve_flag(uuid, text, text),
  public.desk_list_flags(uuid, text), public.desk_verifier_summary(uuid, date)
from public, anon;
grant execute on function
  public.desk_cash_position(uuid, date), public.desk_submit_handover(uuid, date, int, text), public.desk_list_handovers(uuid, date),
  public.desk_receive_handover(uuid, int, text), public.desk_flag_payment(uuid, text), public.desk_resolve_flag(uuid, text, text),
  public.desk_list_flags(uuid, text), public.desk_verifier_summary(uuid, date)
to authenticated, service_role;
