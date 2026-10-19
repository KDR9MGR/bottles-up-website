-- Bottle orders at a table, for the people who work the table: the server whose table it is, and the manager and owner of the club.
--
-- Client Phase 2 brief, sections 13 and 14: "Orders filter by new, needs payment, preparing, on the way, delivered...", "Service:
-- Submitted > Accepted > Preparing > On the way > Delivered. Record staff identity and times", "Multiple staff cannot claim/fulfil the
-- same work accidentally. Repeated taps must not create another order", "Payment and service states remain independent".
--
-- WHY NEW FUNCTIONS: the website's own staff functions (list_my_bottle_orders, update_bottle_service_status, ...) authorize through the
-- global `door_staff` / `cms_admins` tables. An invited server (a 'server' membership) is in neither, so they are refused. These do
-- the same job for the membership model: the caller must hold the right role at THAT club, and a server only reaches the bookings
-- that were given to them (site_booking_servers, 20261014100000). The old functions are left exactly as they are.
--
-- WHAT THIS BUILDS ON THAT NO COMMITTED MIGRATION DEFINES: the money columns of a booking (amount_paid_cents, reconciled_at, ...), a
-- bottle line's payment_status / service_status / cancelled_at, and the club payments table. They exist in production (read on
-- 14 Oct 2026, supabase/audit/06_server_desk_definitions.sql). The check below stops this migration, with a message, on a database
-- that lacks them (a fresh staging project: run `supabase db pull` first) instead of creating functions that fail later.
--
-- THE FIVE SERVICE STATES are the ones production's check constraint allows: awaiting_prep, preparing, ready, picked_up, served. The
-- brief names Submitted / Accepted / Preparing / On the way / Delivered; the app shows New / Preparing / Ready / On the way / Delivered.
-- Delivering part of a line ("partial delivery by item and quantity") needs a delivered quantity the table does not have: not built.
--
-- Plain CREATE, never CREATE OR REPLACE, so a name collision in the shared database fails loudly.

do $$
declare
  missing text;
begin
  select string_agg(x.t || '.' || x.c, ', ' order by x.t, x.c) into missing
  from (values
    ('site_table_bookings', 'amount_paid_cents'), ('site_table_bookings', 'reconciled_at'),
    ('site_table_bookings', 'closeout_requested_at'), ('site_table_bookings', 'discount_cents'),
    ('site_table_booking_bottles', 'payment_status'), ('site_table_booking_bottles', 'service_status'),
    ('site_table_booking_bottles', 'cancelled_at'), ('site_table_booking_bottles', 'cancellation_reason'),
    ('site_table_booking_bottles', 'is_addon'),
    ('site_table_booking_club_payments', 'booking_id'), ('site_table_booking_club_payments', 'recorded_by'),
    ('site_table_booking_club_payments', 'receipt_photo_path'), ('site_table_booking_club_payments', 'manager_verified_at')
  ) as x(t, c)
  where not exists (
    select 1 from information_schema.columns k
    where k.table_schema = 'public' and k.table_name = x.t and k.column_name = x.c
  );
  if missing is not null then
    raise exception 'this migration needs columns that exist only in production (%). Run "supabase db pull" first.', missing;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. How the caller stands towards ONE booking
-- ---------------------------------------------------------------------------
-- 'manager' (owns the business or manages that club), 'server' (holds a current server role at that club AND the booking was given
-- to them), 'verifier' (holds a current verifier role at that club), or null (also for a booking that does not exist, so nobody can
-- probe which ids exist). It only ever reports the CALLER's own standing, so it is safe to leave callable; the receipt storage
-- policies in 20261014130000 need it to be.
create function public.desk_booking_level(p_booking uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_server uuid;
begin
  v_venue := public.booking_venue(p_booking);
  if v_venue is null then return null; end if;
  if public.can_access_venue(v_venue, array['manager', 'owner']) then return 'manager'; end if;

  select a.membership_id into v_server from public.site_booking_servers a where a.booking_id = p_booking;
  if v_server is not null and v_server in (select m.id from public.active_memberships() m where m.role = 'server') then
    return 'server';
  end if;

  if public.can_access_venue(v_venue, array['verifier']) then return 'verifier'; end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Reading orders
-- ---------------------------------------------------------------------------
-- The bottle lines of one business night at one club (p_night is the night in the club's terms: a slot before 06:00 belongs to the
-- night before). A manager or owner gets every paid booking of the club; a server only the bookings given to them. Lines whose online
-- payment is still in flight (pending_payment), cancelled lines and tables that were closed out are left out: they are not work to do.
-- Unfinished work first, oldest first (so the longest wait is at the top), then what was delivered. At most 1000 lines.
create function public.desk_orders(p_venue uuid, p_night date)
returns table (
  line_id uuid, booking_id uuid, confirmation_code text, customer_name text, table_name text, guest_count int,
  bottle_name text, size text, quantity int, line_total_cents int, is_addon boolean,
  payment_status text, service_status text, ordered_at timestamptz, checked_in_at timestamptz,
  balance_due_cents int, server_membership_id uuid, server_is_me boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
begin
  v_level := public.desk_level(p_venue);
  if v_level is null then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;

  return query
    select bb.id, b.id, b.confirmation_code, b.customer_name, t.name, b.guest_count,
           bb.bottle_name, bb.size, bb.quantity, bb.line_total_cents, bb.is_addon,
           bb.payment_status, bb.service_status, bb.created_at, b.checked_in_at,
           greatest(b.amount_total_cents - b.amount_paid_cents, 0),
           bs.membership_id,
           coalesce(bs.membership_id in (select m.id from public.active_memberships() m), false)
    from public.site_table_booking_bottles bb
    join public.site_table_bookings b on b.id = bb.booking_id
    join public.site_venue_time_slots s on s.id = b.time_slot_id
    join public.site_table_types t on t.id = b.table_type_id
    left join public.site_booking_servers bs on bs.booking_id = b.id
    where b.venue_id = p_venue
      and b.status = 'paid'
      and b.reconciled_at is null
      and b.booking_date between p_night and p_night + 1
      and public.booking_night(b.booking_date, s.start_time) = p_night
      and bb.cancelled_at is null
      and bb.payment_status <> 'pending_payment'
      and (
        v_level = 'manager'
        or bs.membership_id in (select m.id from public.active_memberships() m where m.role = 'server')
      )
    order by (bb.service_status = 'served'), bb.created_at, b.customer_name, bb.id
    limit 1000;
end;
$$;

-- Every line of one booking, cancelled ones included (with their reason), for the table's order sheet. A manager, or the server the
-- booking was given to. Lines whose online payment is still in flight are left out.
create function public.desk_booking_orders(p_booking uuid)
returns table (
  line_id uuid, bottle_name text, size text, quantity int, unit_price_cents int, line_total_cents int, is_addon boolean,
  payment_status text, service_status text, ordered_at timestamptz, cancelled_at timestamptz, cancellation_reason text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
begin
  v_level := public.desk_booking_level(p_booking);
  if v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;

  return query
    select bb.id, bb.bottle_name, bb.size, bb.quantity, bb.unit_price_cents, bb.line_total_cents, bb.is_addon,
           bb.payment_status, bb.service_status, bb.created_at, bb.cancelled_at, bb.cancellation_reason
    from public.site_table_booking_bottles bb
    where bb.booking_id = p_booking
      and bb.payment_status <> 'pending_payment'
    order by bb.created_at, bb.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Moving an order along
-- ---------------------------------------------------------------------------
-- Answers true when the line changed, false when it was already in that state (a repeated tap, or a colleague got there first:
-- nothing is written and nothing is recorded twice). Who may: a manager or owner of the club, or the server the booking was given to.
--   * only a paid booking that has not been closed out; a cancelled line cannot be moved; a line whose online payment is still in
--     flight cannot be moved ("payment not yet verified for this item" - the website's own sentence);
--   * a server cannot take an item back out of Delivered: only a manager can;
--   * an item that is to be paid at the venue can only be marked Delivered once the table's balance is zero AND a payment was
--     recorded for the table (with its receipt, or with the manager's written reason for having none).
-- Locks the booking first and then the line, in that order everywhere, so a payment being recorded at the same moment is either
-- fully seen or not at all.
create function public.desk_set_service_status(p_line uuid, p_status text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_level text;
  v_booking record;
  v_line record;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_status is null or p_status not in ('awaiting_prep', 'preparing', 'ready', 'picked_up', 'served') then
    raise exception 'invalid status';
  end if;

  select bb.booking_id into v_booking_id from public.site_table_booking_bottles bb where bb.id = p_line;
  v_level := public.desk_booking_level(v_booking_id);
  if v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;

  select b.id, b.venue_id, b.status, b.reconciled_at, b.amount_total_cents, b.amount_paid_cents into v_booking
    from public.site_table_bookings b where b.id = v_booking_id for update;
  select bb.id, bb.payment_status, bb.service_status, bb.cancelled_at into v_line
    from public.site_table_booking_bottles bb where bb.id = p_line for update;

  if v_booking.status is distinct from 'paid' then raise exception 'only a paid booking has orders to serve'; end if;
  if v_booking.reconciled_at is not null then raise exception 'this table has already been closed out'; end if;
  if v_line.cancelled_at is not null then raise exception 'this item was cancelled'; end if;
  if v_line.payment_status = 'pending_payment' then raise exception 'payment not yet verified for this item'; end if;

  if v_line.service_status = p_status then return false; end if;

  if v_level = 'server' and v_line.service_status = 'served' then
    raise exception 'a delivered item can only be changed by a manager';
  end if;

  if p_status = 'served' and v_line.payment_status = 'due_at_venue' then
    if greatest(v_booking.amount_total_cents - v_booking.amount_paid_cents, 0) > 0 then
      raise exception 'cannot mark delivered - this table still has a balance due at the venue';
    end if;
    if not exists (select 1 from public.site_table_booking_club_payments cp where cp.booking_id = v_booking_id) then
      raise exception 'cannot mark delivered - no payment has been recorded for this table';
    end if;
  end if;

  update public.site_table_booking_bottles set service_status = p_status where id = p_line;

  perform public.desk_log('table_booking.bottle_service_status_updated', 'site_table_booking_bottles', p_line,
    jsonb_build_object('venue_id', v_booking.venue_id, 'booking_id', v_booking_id,
                       'old_status', v_line.service_status, 'new_status', p_status));
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.desk_booking_level(uuid), public.desk_orders(uuid, date), public.desk_booking_orders(uuid),
  public.desk_set_service_status(uuid, text)
  from public, anon;
grant execute on function
  public.desk_booking_level(uuid), public.desk_orders(uuid, date), public.desk_booking_orders(uuid),
  public.desk_set_service_status(uuid, text)
  to authenticated, service_role;
