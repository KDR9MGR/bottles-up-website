-- Seating a guest, and the customer messages that follow (client Phase 2 brief, section 13 and section 23's "customer outputs").
--
-- "Guest arrival: Scan booking QR -> Validate assignment/event -> Confirm booking and guest -> Review pre-orders/payments -> Mark Seated ->
-- Enter service estimate. Fallback: Search name/reference -> Check another booking detail with guest -> Record manual confirmation. A name
-- match alone must not select the wrong booking. Trigger a customer acknowledgment with booking/order details and the staff-entered
-- estimate. A scan does not mark payment or delivery complete. Only send an estimate when available; update it when staff change it."
--
--   * FIND: a server finds only the tables given to them (a code or name that belongs to another server's table, or to nobody, finds nothing);
--     a manager or owner finds every paid booking of the night at their club. The answer carries the lead guest's NAME, never an email or a
--     phone number.
--   * SEAT: the assigned server, or the club's manager or owner. Once, and a second tap changes nothing. A scan is enough; a manual seating
--     needs the detail that was checked with the guest, and it is recorded. Seating never touches payment or delivery.
--   * ESTIMATE: set and changed by the same people, only after seating, in whole minutes; clearing it is allowed and sends nothing.
--   * UNSEAT: a manager or owner, with a reason (a mis-tap happens).
--   * OUTBOX: the message to the guest is QUEUED, not sent. Nothing here sends an email. A separate sender reads the queue and records sent or
--     failed, so the app can say "queued", "sent" or "failed" and never claims a message arrived before it did.
--
-- Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.site_booking_seating (
  booking_id uuid primary key references public.site_table_bookings (id) on delete cascade,
  seated_by uuid not null references auth.users (id),
  seated_at timestamptz not null default now(),
  method text not null check (method in ('scan', 'manual')),
  confirmation text check (confirmation is null or char_length(confirmation) <= 300),
  estimate_minutes int check (estimate_minutes is null or estimate_minutes between 1 and 480),
  estimate_set_by uuid references auth.users (id),
  estimate_set_at timestamptz,
  constraint site_booking_seating_manual_needs_detail check (method <> 'manual' or char_length(btrim(coalesce(confirmation, ''))) >= 3)
);

-- Messages waiting to go to a customer or a guest, for every feature that sends one. A sender outside the database reads 'queued' rows
-- and sets 'sent' or 'failed' (with the error); nothing in the app can mark a message sent.
create table public.site_outbox (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind ~ '^[a-z][a-z_]{2,39}$'),
  venue_id uuid references public.site_venues (id) on delete cascade,
  ref_id uuid,
  payload jsonb not null default '{}'::jsonb check (pg_column_size(payload) <= 8000),
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed')),
  attempts int not null default 0 check (attempts >= 0),
  last_error text check (last_error is null or char_length(last_error) <= 500),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index site_outbox_status_idx on public.site_outbox (status, created_at);
create index site_outbox_ref_idx on public.site_outbox (ref_id);

alter table public.site_booking_seating enable row level security;
alter table public.site_outbox enable row level security;
revoke all on table public.site_booking_seating, public.site_outbox from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal: put a message in the queue (the app cannot call it, or anyone could queue mail to anyone)
-- ---------------------------------------------------------------------------
create function public.desk_enqueue(p_kind text, p_venue uuid, p_ref uuid, p_payload jsonb default '{}'::jsonb)
returns uuid
language sql
security definer
set search_path = public
as $$
  insert into public.site_outbox (kind, venue_id, ref_id, payload) values (p_kind, p_venue, p_ref, coalesce(p_payload, '{}'::jsonb)) returning id
$$;
revoke all on function public.desk_enqueue(text, uuid, uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Find a booking
-- ---------------------------------------------------------------------------
create function public.desk_find_booking(p_venue uuid, p_night date, p_query text)
returns table (
  booking_id uuid, confirmation_code text, customer_name text, table_name text, guest_count int, start_time time,
  seated boolean, server_name text, is_mine boolean, can_seat boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
  v_q text;
  v_like text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_level := public.desk_level(p_venue);
  if v_level is null then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  v_q := btrim(coalesce(p_query, ''));
  if char_length(v_q) < 3 then raise exception 'type at least 3 letters of the name, or the booking code'; end if;
  if char_length(v_q) > 60 then raise exception 'that is too long to be a name or a booking code'; end if;
  -- A % or _ typed by a person is a character, not a wildcard.
  v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  return query
    select b.id, b.confirmation_code, b.customer_name, t.name, b.guest_count, s.start_time,
           b.checked_in_at is not null,
           case when bs.membership_id is not null then coalesce(nullif(btrim(pr.name), ''), 'Staff member') end,
           coalesce(bs.membership_id in (select m.id from public.active_memberships() m where m.role = 'server'), false),
           (v_level = 'manager' or coalesce(bs.membership_id in (select m.id from public.active_memberships() m where m.role = 'server'), false))
    from public.site_table_bookings b
    join public.site_venue_time_slots s on s.id = b.time_slot_id
    join public.site_table_types t on t.id = b.table_type_id
    left join public.site_booking_servers bs on bs.booking_id = b.id
    left join public.site_memberships sm on sm.id = bs.membership_id
    left join public.profiles pr on pr.id = sm.user_id
    where b.venue_id = p_venue
      and b.status = 'paid'
      and b.booking_date between p_night and p_night + 1
      and public.booking_night(b.booking_date, s.start_time) = p_night
      and (upper(b.confirmation_code) = upper(v_q) or b.customer_name ilike v_like)
      and (v_level = 'manager' or bs.membership_id in (select m.id from public.active_memberships() m where m.role = 'server'))
    order by (upper(b.confirmation_code) = upper(v_q)) desc, s.start_time, b.customer_name, b.id
    limit 10;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Seat, estimate, unseat
-- ---------------------------------------------------------------------------
create function public.desk_mark_seated(p_booking uuid, p_method text default 'scan', p_confirmation text default null, p_estimate_minutes int default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  b public.site_table_bookings;
  v_level text;
  v_detail text;
  v_existing public.site_booking_seating;
  v_seated_at timestamptz;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_venue := public.booking_venue(p_booking);
  v_level := public.desk_booking_level(p_booking);
  if v_venue is null or v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;
  if p_method is null or p_method not in ('scan', 'manual') then raise exception 'choose scan or manual'; end if;
  v_detail := nullif(btrim(p_confirmation), '');
  if p_method = 'manual' and (v_detail is null or char_length(v_detail) < 3) then
    raise exception 'say what you checked with the guest';
  end if;
  if v_detail is not null and char_length(v_detail) > 300 then raise exception 'keep the detail to 300 characters or fewer'; end if;
  if p_estimate_minutes is not null and (p_estimate_minutes < 1 or p_estimate_minutes > 480) then
    raise exception 'the estimate is between 1 and 480 minutes';
  end if;

  -- One at a time per booking: two taps (or a scan and a search) end with one seating and one message.
  select * into b from public.site_table_bookings where id = p_booking for update;
  if b.status is distinct from 'paid' then raise exception 'only a paid booking can be seated'; end if;

  select * into v_existing from public.site_booking_seating where booking_id = p_booking;
  if found or b.checked_in_at is not null then
    -- Already seated (or checked in on the old staff page): nothing changes, nothing is sent again.
    if not found then
      insert into public.site_booking_seating (booking_id, seated_by, seated_at, method, confirmation)
      values (p_booking, coalesce(b.checked_in_by, auth.uid()), b.checked_in_at, 'manual', 'checked in on the staff page')
      on conflict (booking_id) do nothing;
      select * into v_existing from public.site_booking_seating where booking_id = p_booking;
    end if;
    return jsonb_build_object('already', true, 'seated_at', v_existing.seated_at, 'estimate_minutes', v_existing.estimate_minutes);
  end if;

  v_seated_at := now();
  update public.site_table_bookings set checked_in_at = v_seated_at, checked_in_by = auth.uid() where id = p_booking;
  insert into public.site_booking_seating (booking_id, seated_by, seated_at, method, confirmation, estimate_minutes, estimate_set_by, estimate_set_at)
  values (p_booking, auth.uid(), v_seated_at, p_method, v_detail, p_estimate_minutes,
          case when p_estimate_minutes is not null then auth.uid() end, case when p_estimate_minutes is not null then v_seated_at end);

  perform public.desk_enqueue('seated_ack', v_venue, p_booking,
    jsonb_build_object('confirmation_code', b.confirmation_code, 'estimate_minutes', p_estimate_minutes));
  perform public.desk_log('booking.seated', 'site_table_bookings', p_booking,
    jsonb_build_object('venue_id', v_venue, 'method', p_method, 'estimate_minutes', p_estimate_minutes));
  return jsonb_build_object('already', false, 'seated_at', v_seated_at, 'estimate_minutes', p_estimate_minutes);
end;
$$;

create function public.desk_set_estimate(p_booking uuid, p_minutes int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_level text;
  v_s public.site_booking_seating;
  b public.site_table_bookings;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_venue := public.booking_venue(p_booking);
  v_level := public.desk_booking_level(p_booking);
  if v_venue is null or v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;
  if p_minutes is not null and (p_minutes < 1 or p_minutes > 480) then raise exception 'the estimate is between 1 and 480 minutes'; end if;

  select * into b from public.site_table_bookings where id = p_booking for update;
  select * into v_s from public.site_booking_seating where booking_id = p_booking;
  if not found then raise exception 'seat the guest first'; end if;
  if v_s.estimate_minutes is not distinct from p_minutes then
    return jsonb_build_object('changed', false, 'estimate_minutes', v_s.estimate_minutes);
  end if;

  update public.site_booking_seating
    set estimate_minutes = p_minutes, estimate_set_by = auth.uid(), estimate_set_at = now()
    where booking_id = p_booking;
  -- Only an estimate that exists is told to the guest; clearing one sends nothing.
  if p_minutes is not null then
    perform public.desk_enqueue('estimate_updated', v_venue, p_booking,
      jsonb_build_object('confirmation_code', b.confirmation_code, 'estimate_minutes', p_minutes));
  end if;
  perform public.desk_log('booking.estimate_set', 'site_table_bookings', p_booking,
    jsonb_build_object('venue_id', v_venue, 'from_minutes', v_s.estimate_minutes, 'to_minutes', p_minutes));
  return jsonb_build_object('changed', true, 'estimate_minutes', p_minutes);
end;
$$;

create function public.desk_unseat(p_booking uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_venue := public.booking_venue(p_booking);
  if v_venue is null or not public.can_access_venue(v_venue, array['manager', 'owner']) then raise exception 'not allowed'; end if;
  v_reason := btrim(p_reason);
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'say why this guest is being un-seated'; end if;
  if char_length(v_reason) > 300 then raise exception 'keep the reason to 300 characters or fewer'; end if;

  perform 1 from public.site_table_bookings where id = p_booking for update;
  if not exists (select 1 from public.site_booking_seating where booking_id = p_booking)
     and not exists (select 1 from public.site_table_bookings where id = p_booking and checked_in_at is not null) then
    raise exception 'this guest is not seated';
  end if;
  delete from public.site_booking_seating where booking_id = p_booking;
  update public.site_table_bookings set checked_in_at = null, checked_in_by = null where id = p_booking;
  perform public.desk_log('booking.unseated', 'site_table_bookings', p_booking, jsonb_build_object('venue_id', v_venue, 'reason', v_reason));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. What was sent to the guest about a booking
-- ---------------------------------------------------------------------------
create function public.desk_booking_messages(p_booking uuid)
returns table (kind text, status text, created_at timestamptz, sent_at timestamptz, last_error text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
begin
  v_level := public.desk_booking_level(p_booking);
  if public.booking_venue(p_booking) is null or v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;
  return query
    select o.kind, o.status, o.created_at, o.sent_at, o.last_error
    from public.site_outbox o
    where o.ref_id = p_booking and o.kind in ('seated_ack', 'estimate_updated')
    order by o.created_at desc, o.id
    limit 50;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.desk_find_booking(uuid, date, text), public.desk_mark_seated(uuid, text, text, int), public.desk_set_estimate(uuid, int),
  public.desk_unseat(uuid, text), public.desk_booking_messages(uuid)
from public, anon;
grant execute on function
  public.desk_find_booking(uuid, date, text), public.desk_mark_seated(uuid, text, text, int), public.desk_set_estimate(uuid, int),
  public.desk_unseat(uuid, text), public.desk_booking_messages(uuid)
to authenticated, service_role;
