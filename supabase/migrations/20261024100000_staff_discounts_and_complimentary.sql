-- Discounts and complimentary (free) bottles given by the club's own people (developer brief 15 Oct, section 21; the client's answer of 20 Oct:
-- "Owner: decides the rules and limits. Manager: approves within those limits. Server: only uses approved discounts or free-bottle allowances. Until limits are set,
-- staff cannot give their own discounts. It is applied, and the system records who approved it and updates stock.").
--
--   THE LIMITS (the OWNER sets them; a manager reads them; BottlesUp admins see them in the CMS)
--   * site_discount_limits (closed table)   per venue: the biggest discount a server and a manager may give on their own (percent of the table's bottles), the free bottles
--                                           a server may give per night and the manager pool per night, and whether discounts combine (they do not, until the owner allows it)
--   * save_venue_discount_limits / venue_discount_limits / desk_concession_limits    set them (owner), read them (owner, manager), and what the caller may do tonight
--
--   WHAT A PERSON GIVES (one record for each, whoever gives it)
--   * site_concessions (closed table)       a DISCOUNT (percent of the table's bottle subtotal, or an amount) or a FREE BOTTLE (a bottle line at no charge); who asked, in what role,
--                                           who approved, the value, the reason, the business night. Applied / Pending / Declined / Voided.
--   * desk_request_discount / desk_request_free_bottle    within the person's own limit it is APPLIED at once (and says so); above it, it waits as PENDING for someone with the
--                                           authority: a server's request for a manager (within the manager's limit), anything above that for the owner. The owner needs no limit.
--   * desk_pending_concessions / desk_decide_concession / desk_void_concession   what waits, approve or decline it (never your own), and take an applied one back
--   * a discount lowers what the table owes (site_table_bookings.staff_discount_cents and amount_total_cents move together; the edge functions that recompute totals subtract it,
--     so it survives bottles being added or cancelled later); it can never be more than the table still owes, and discounts do not combine unless the owner allows it
--   * a free bottle is a real bottle line at 0.00 (stock is counted like any other, it is served like any other); its list value is recorded separately, never as sales
--   * cms_concessions / cms_discount_limits   the CMS's read-only views
--
-- Needs the venue setup, desk, close night, add bottles and floor plan migrations. Plain CREATE for everything new; nothing live is replaced.

do $pre$
declare
  r record;
begin
  for r in select * from (values
      ('public.require_venue_editor(uuid)'), ('public.venue_setup_log(text, text, uuid, uuid, jsonb)'), ('public.setup_only_keys(jsonb, text[])'),
      ('public.setup_int(jsonb, text, text, integer, integer)'), ('public.setup_bool(jsonb, text, text)'), ('public.can_access_venue(uuid, text[])'),
      ('public.desk_level(uuid)'), ('public.desk_booking_level(uuid)'), ('public.desk_log(text, text, uuid, jsonb)'), ('public.is_cms_admin()'),
      ('public.booking_night(date, time without time zone)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
end
$pre$;

alter table public.site_table_bookings add column staff_discount_cents int not null default 0 check (staff_discount_cents >= 0);

-- ---------------------------------------------------------------------------
-- 1. The limits
-- ---------------------------------------------------------------------------
create table public.site_discount_limits (
  venue_id uuid primary key references public.site_venues (id) on delete cascade,
  server_max_percent int not null default 0 check (server_max_percent between 0 and 100),
  manager_max_percent int not null default 0 check (manager_max_percent between 0 and 100),
  server_free_bottles_per_night int not null default 0 check (server_free_bottles_per_night between 0 and 100),
  manager_free_bottles_per_night int not null default 0 check (manager_free_bottles_per_night between 0 and 500),
  allow_stacking boolean not null default false,
  updated_by uuid references auth.users (id),
  updated_at timestamptz not null default now(),
  constraint site_discount_limits_order_check check (server_max_percent <= manager_max_percent and server_free_bottles_per_night <= manager_free_bottles_per_night)
);
alter table public.site_discount_limits enable row level security;
revoke all on table public.site_discount_limits from public, anon, authenticated;

create function public.venue_discount_limits(p_venue uuid)
returns table (has_limits boolean, server_max_percent int, manager_max_percent int, server_free_bottles_per_night int, manager_free_bottles_per_night int, allow_stacking boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  l public.site_discount_limits;
begin
  perform public.require_venue_editor(p_venue);
  select * into l from public.site_discount_limits where venue_id = p_venue;
  if not found then return query select false, 0, 0, 0, 0, false;
  else return query select true, l.server_max_percent, l.manager_max_percent, l.server_free_bottles_per_night, l.manager_free_bottles_per_night, l.allow_stacking; end if;
end;
$$;

-- Only the OWNER sets the limits. Keys that are not sent keep their value (0 / false for a first save). A manager's limit is never below a server's.
create function public.save_venue_discount_limits(p_venue uuid, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l public.site_discount_limits;
  v_exists boolean;
  v_sp int; v_mp int; v_sf int; v_mf int; v_stack boolean;
  v_old jsonb; v_new jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner']) then raise exception 'not allowed'; end if;
  perform public.setup_only_keys(p_details, array['server_max_percent', 'manager_max_percent', 'server_free_bottles_per_night', 'manager_free_bottles_per_night', 'allow_stacking']);
  select * into l from public.site_discount_limits where venue_id = p_venue for update;
  v_exists := found;
  v_sp := case when p_details ? 'server_max_percent' then public.setup_int(p_details, 'server_max_percent', 'the server''s discount limit', 0, 100) else coalesce(l.server_max_percent, 0) end;
  v_mp := case when p_details ? 'manager_max_percent' then public.setup_int(p_details, 'manager_max_percent', 'the manager''s discount limit', 0, 100) else coalesce(l.manager_max_percent, 0) end;
  v_sf := case when p_details ? 'server_free_bottles_per_night' then public.setup_int(p_details, 'server_free_bottles_per_night', 'the server''s free bottles per night', 0, 100) else coalesce(l.server_free_bottles_per_night, 0) end;
  v_mf := case when p_details ? 'manager_free_bottles_per_night' then public.setup_int(p_details, 'manager_free_bottles_per_night', 'the managers'' free bottles per night', 0, 500) else coalesce(l.manager_free_bottles_per_night, 0) end;
  v_stack := case when p_details ? 'allow_stacking' then public.setup_bool(p_details, 'allow_stacking', 'allow discounts to combine') else coalesce(l.allow_stacking, false) end;
  if v_sp is null or v_mp is null or v_sf is null or v_mf is null or v_stack is null then raise exception 'every limit needs a value'; end if;
  if v_sp > v_mp then raise exception 'a server cannot be allowed a bigger discount than a manager'; end if;
  if v_sf > v_mf then raise exception 'a server cannot be allowed more free bottles a night than the managers'' pool'; end if;
  v_new := jsonb_build_object('server_max_percent', v_sp, 'manager_max_percent', v_mp, 'server_free_bottles_per_night', v_sf, 'manager_free_bottles_per_night', v_mf, 'allow_stacking', v_stack);
  v_old := case when v_exists then jsonb_build_object('server_max_percent', l.server_max_percent, 'manager_max_percent', l.manager_max_percent,
    'server_free_bottles_per_night', l.server_free_bottles_per_night, 'manager_free_bottles_per_night', l.manager_free_bottles_per_night, 'allow_stacking', l.allow_stacking) end;
  if v_old is not distinct from v_new then return v_new; end if;
  insert into public.site_discount_limits (venue_id, server_max_percent, manager_max_percent, server_free_bottles_per_night, manager_free_bottles_per_night, allow_stacking, updated_by, updated_at)
  values (p_venue, v_sp, v_mp, v_sf, v_mf, v_stack, auth.uid(), now())
  on conflict (venue_id) do update set server_max_percent = excluded.server_max_percent, manager_max_percent = excluded.manager_max_percent,
    server_free_bottles_per_night = excluded.server_free_bottles_per_night, manager_free_bottles_per_night = excluded.manager_free_bottles_per_night,
    allow_stacking = excluded.allow_stacking, updated_by = excluded.updated_by, updated_at = now();
  perform public.venue_setup_log('venue.discount_limits_saved', 'site_venues', p_venue, p_venue, jsonb_build_object('from', v_old, 'to', v_new));
  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The record of what is given
-- ---------------------------------------------------------------------------
create table public.site_concessions (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  booking_id uuid not null references public.site_table_bookings (id) on delete cascade,
  kind text not null check (kind in ('discount', 'free_bottle')),
  percent int check (percent is null or percent between 1 and 100),
  amount_cents int not null check (amount_cents > 0),            -- the discount, or the list value of the free bottles
  base_cents int check (base_cents is null or base_cents > 0),   -- the table's bottle subtotal a discount was worked out on
  bottle_id uuid references public.site_bottles (id) on delete set null,
  bottle_name text,
  quantity int check (quantity is null or quantity between 1 and 100),
  line_id uuid references public.site_table_booking_bottles (id) on delete set null,
  reason text not null check (char_length(btrim(reason)) between 3 and 300),
  requested_by uuid not null references auth.users (id),
  requested_role text not null check (requested_role in ('server', 'manager', 'owner')),
  status text not null check (status in ('applied', 'pending', 'declined', 'voided')),
  decided_by uuid references auth.users (id),                    -- null when it was within the person's own limit
  decided_role text check (decided_role in ('manager', 'owner')),
  decided_at timestamptz,
  decision_note text check (decision_note is null or char_length(decision_note) <= 300),
  voided_by uuid references auth.users (id),
  voided_at timestamptz,
  business_night date not null,
  created_at timestamptz not null default clock_timestamp(),   -- the real time, so two things given in one step keep their order
  updated_at timestamptz not null default now(),
  constraint site_concessions_shape_check check (
    (kind = 'discount' and bottle_id is null and quantity is null)
    or (kind = 'free_bottle' and bottle_name is not null and quantity is not null and percent is null)),
  constraint site_concessions_decided_check check ((decided_by is null) = (decided_role is null))
);
create index site_concessions_booking_idx on public.site_concessions (booking_id, status);
create index site_concessions_venue_idx on public.site_concessions (venue_id, status, business_night);
alter table public.site_concessions enable row level security;
revoke all on table public.site_concessions from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
-- The caller's authority at this club: 'owner', 'manager' or (for the server a booking was given to) 'server'; null for anyone else.
create function public.concession_role(p_venue uuid, p_booking uuid default null)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when public.can_access_venue(p_venue, array['owner']) then 'owner'
    when public.can_access_venue(p_venue, array['manager']) then 'manager'
    when p_booking is not null and public.desk_booking_level(p_booking) = 'server' then 'server'
  end
$$;

-- The table's bottle subtotal a percent discount is taken of: bottle lines that are not cancelled and are not free.
create function public.concession_base_cents(p_booking uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(l.line_total_cents), 0)::int from public.site_table_booking_bottles l where l.booking_id = p_booking and l.cancelled_at is null and l.line_total_cents > 0
$$;

-- Free bottles a SERVER has given tonight within their own allowance (not counting what a manager approved for them: that came out of the managers' pool).
create function public.concession_server_used(p_venue uuid, p_night date, p_user uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(c.quantity), 0)::int from public.site_concessions c
   where c.venue_id = p_venue and c.business_night = p_night and c.kind = 'free_bottle' and c.status = 'applied'
     and c.requested_by = p_user and c.requested_role = 'server' and c.decided_by is null
$$;

-- Free bottles the MANAGERS have given tonight between them: their own, and what they approved for others (what the owner approved is not counted here).
create function public.concession_pool_used(p_venue uuid, p_night date)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(c.quantity), 0)::int from public.site_concessions c
   where c.venue_id = p_venue and c.business_night = p_night and c.kind = 'free_bottle' and c.status = 'applied'
     and ((c.requested_role = 'manager' and c.decided_by is null) or c.decided_role = 'manager')
$$;

-- Is the booking still open to a discount or a free bottle? A plain sentence when not.
create function public.concession_booking_check(p_booking uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b record;
begin
  select k.status, k.reconciled_at, k.venue_id, k.booking_date, s.start_time into b
    from public.site_table_bookings k join public.site_venue_time_slots s on s.id = k.time_slot_id where k.id = p_booking;
  if b.status is distinct from 'paid' then raise exception 'only a confirmed booking can have a discount or a free bottle'; end if;
  if b.reconciled_at is not null then raise exception 'this table has already been closed out'; end if;
  if exists (select 1 from public.site_night_closes c where c.venue_id = b.venue_id and c.business_night = public.booking_night(b.booking_date, b.start_time) and c.status = 'closed') then
    raise exception 'this night has been closed, so nothing can be given on it';
  end if;
end;
$$;

-- Puts a concession into effect, with the booking locked. A discount lowers what the table owes; a free bottle is a line at no charge.
create function public.concession_apply(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.site_concessions;
  b public.site_table_bookings;
  bt public.site_bottles;
  v_due int;
  v_left int;
  v_line uuid;
begin
  select * into c from public.site_concessions where id = p_id for update;
  select * into b from public.site_table_bookings where id = c.booking_id for update;
  if c.kind = 'discount' then
    v_due := greatest(b.amount_total_cents - b.amount_paid_cents, 0);
    if c.amount_cents > v_due then
      raise exception 'a discount of % is more than this table still owes (%)', to_char(c.amount_cents / 100.0, 'FM999999990.00'), to_char(v_due / 100.0, 'FM999999990.00');
    end if;
    update public.site_table_bookings set staff_discount_cents = staff_discount_cents + c.amount_cents, amount_total_cents = amount_total_cents - c.amount_cents, updated_at = now() where id = b.id;
  else
    select * into bt from public.site_bottles where id = c.bottle_id and venue_id = c.venue_id;
    if not found or not bt.is_available or bt.is_sold_out then raise exception 'that bottle is not available right now'; end if;
    if bt.stock_quantity is not null then
      v_left := bt.stock_quantity - coalesce((select sum(l.quantity)::int from public.site_table_booking_bottles l join public.site_table_bookings k on k.id = l.booking_id
                                              where l.bottle_id = bt.id and k.status = 'paid' and l.payment_status in ('paid', 'due_at_venue') and l.cancelled_at is null), 0);
      if c.quantity > v_left then raise exception 'only % of that bottle are left', greatest(v_left, 0); end if;
    end if;
    insert into public.site_table_booking_bottles (booking_id, bottle_id, bottle_name, size, unit_price_cents, quantity, line_total_cents, is_addon, added_by, payment_status, service_status)
    values (b.id, bt.id, bt.name, bt.size, 0, c.quantity, 0, true, c.requested_by, 'paid', 'awaiting_prep') returning id into v_line;
    update public.site_concessions set line_id = v_line where id = p_id;
  end if;
end;
$$;
revoke all on function public.concession_role(uuid, uuid), public.concession_base_cents(uuid), public.concession_server_used(uuid, date, uuid), public.concession_pool_used(uuid, date),
  public.concession_booking_check(uuid), public.concession_apply(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. What the caller may do on this table tonight
-- ---------------------------------------------------------------------------
create function public.desk_concession_limits(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  v_role text;
  l public.site_discount_limits;
  v_night date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into b from public.site_table_bookings where id = p_booking;
  if not found then raise exception 'not allowed'; end if;
  v_role := public.concession_role(b.venue_id, p_booking);
  if v_role is null then raise exception 'not allowed'; end if;
  select public.booking_night(b.booking_date, s.start_time) into v_night from public.site_venue_time_slots s where s.id = b.time_slot_id;
  select * into l from public.site_discount_limits where venue_id = b.venue_id;
  return jsonb_build_object(
    'role', v_role,
    'limits_set', l.venue_id is not null or v_role = 'owner',
    'max_percent', case v_role when 'owner' then 100 when 'manager' then coalesce(l.manager_max_percent, 0) else coalesce(l.server_max_percent, 0) end,
    'free_bottles_allowed', case v_role when 'owner' then null when 'manager' then coalesce(l.manager_free_bottles_per_night, 0) else coalesce(l.server_free_bottles_per_night, 0) end,
    'free_bottles_used', case v_role when 'owner' then 0 when 'manager' then public.concession_pool_used(b.venue_id, v_night) else public.concession_server_used(b.venue_id, v_night, auth.uid()) end,
    'allow_stacking', coalesce(l.allow_stacking, false),
    'bottle_subtotal_cents', public.concession_base_cents(p_booking),
    'balance_due_cents', greatest(b.amount_total_cents - b.amount_paid_cents, 0),
    'discounted_cents', b.staff_discount_cents);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Asking for a discount or a free bottle
-- ---------------------------------------------------------------------------
-- p_kind 'percent' (p_value 1 to 100, of the table's bottles) or 'amount' (p_value in cents). Within the person's own limit it is applied at once; above it, it waits.
create function public.desk_request_discount(p_booking uuid, p_kind text, p_value int, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  v_role text;
  l public.site_discount_limits;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_base int;
  v_amount int;
  v_pct int;
  v_my_max int;
  v_status text;
  v_night date;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into b from public.site_table_bookings where id = p_booking;
  if not found then raise exception 'not allowed'; end if;
  v_role := public.concession_role(b.venue_id, p_booking);
  if v_role is null then raise exception 'not allowed'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then raise exception 'give a reason of 3 to 300 characters'; end if;
  select * into b from public.site_table_bookings where id = p_booking for update;
  perform public.concession_booking_check(p_booking);
  select * into l from public.site_discount_limits where venue_id = b.venue_id;
  if v_role <> 'owner' and l.venue_id is null then raise exception 'discounts are not set up for this club yet: the owner sets the limits first'; end if;

  v_base := public.concession_base_cents(p_booking);
  if v_base <= 0 then raise exception 'there are no bottles on this table to discount'; end if;
  if p_kind = 'percent' then
    if p_value is null or p_value < 1 or p_value > 100 then raise exception 'a percent discount is between 1 and 100'; end if;
    v_amount := floor(v_base::numeric * p_value / 100)::int;
    if v_amount < 1 then raise exception 'that discount is less than one cent'; end if;
  elsif p_kind = 'amount' then
    if p_value is null or p_value < 1 then raise exception 'how much is the discount?'; end if;
    if p_value > v_base then raise exception 'a discount cannot be more than the table''s bottles (%)', to_char(v_base / 100.0, 'FM999999990.00'); end if;
    v_amount := p_value;
  else
    raise exception 'choose a percent or an amount';
  end if;
  v_pct := ceil(v_amount * 100.0 / v_base)::int;
  if v_amount > greatest(b.amount_total_cents - b.amount_paid_cents, 0) then
    raise exception 'a discount of % is more than this table still owes (%)', to_char(v_amount / 100.0, 'FM999999990.00'), to_char(greatest(b.amount_total_cents - b.amount_paid_cents, 0) / 100.0, 'FM999999990.00');
  end if;
  if not coalesce(l.allow_stacking, false) and exists (select 1 from public.site_concessions c where c.booking_id = p_booking and c.kind = 'discount' and c.status in ('applied', 'pending')) then
    raise exception 'this table already has a discount: discounts do not combine at this club';
  end if;

  v_my_max := case v_role when 'owner' then 100 when 'manager' then l.manager_max_percent else l.server_max_percent end;
  v_status := case when v_pct <= v_my_max then 'applied' else 'pending' end;
  select public.booking_night(b.booking_date, s.start_time) into v_night from public.site_venue_time_slots s where s.id = b.time_slot_id;
  insert into public.site_concessions (venue_id, booking_id, kind, percent, amount_cents, base_cents, reason, requested_by, requested_role, status, business_night)
  values (b.venue_id, p_booking, 'discount', case when p_kind = 'percent' then p_value end, v_amount, v_base, v_reason, auth.uid(), v_role, v_status, v_night) returning id into v_id;
  if v_status = 'applied' then perform public.concession_apply(v_id); end if;
  perform public.desk_log('concession.' || v_status, 'site_concessions', v_id, jsonb_build_object('venue_id', b.venue_id, 'booking_id', p_booking, 'kind', 'discount', 'amount_cents', v_amount, 'percent', v_pct, 'reason', v_reason));
  return jsonb_build_object('id', v_id, 'status', v_status, 'amount_cents', v_amount, 'percent', v_pct);
end;
$$;

create function public.desk_request_free_bottle(p_booking uuid, p_bottle uuid, p_quantity int, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  v_role text;
  l public.site_discount_limits;
  bt public.site_bottles;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_night date;
  v_used int;
  v_allowed int;
  v_status text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into b from public.site_table_bookings where id = p_booking;
  if not found then raise exception 'not allowed'; end if;
  v_role := public.concession_role(b.venue_id, p_booking);
  if v_role is null then raise exception 'not allowed'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then raise exception 'give a reason of 3 to 300 characters'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 100 then raise exception 'how many bottles?'; end if;
  select * into b from public.site_table_bookings where id = p_booking for update;
  perform public.concession_booking_check(p_booking);
  select * into l from public.site_discount_limits where venue_id = b.venue_id;
  if v_role <> 'owner' and l.venue_id is null then raise exception 'free bottles are not set up for this club yet: the owner sets the limits first'; end if;
  select * into bt from public.site_bottles where id = p_bottle and venue_id = b.venue_id;
  if not found then raise exception 'bottle not found'; end if;
  if not bt.is_available or bt.is_sold_out then raise exception 'that bottle is not available right now'; end if;

  select public.booking_night(b.booking_date, s.start_time) into v_night from public.site_venue_time_slots s where s.id = b.time_slot_id;
  if v_role = 'owner' then v_status := 'applied';
  elsif v_role = 'manager' then
    v_status := case when public.concession_pool_used(b.venue_id, v_night) + p_quantity <= l.manager_free_bottles_per_night then 'applied' else 'pending' end;
  else
    v_status := case when public.concession_server_used(b.venue_id, v_night, auth.uid()) + p_quantity <= l.server_free_bottles_per_night then 'applied' else 'pending' end;
  end if;
  insert into public.site_concessions (venue_id, booking_id, kind, amount_cents, bottle_id, bottle_name, quantity, reason, requested_by, requested_role, status, business_night)
  values (b.venue_id, p_booking, 'free_bottle', greatest(bt.price_cents * p_quantity, 1), bt.id, bt.name, p_quantity, v_reason, auth.uid(), v_role, v_status, v_night) returning id into v_id;
  if v_status = 'applied' then perform public.concession_apply(v_id); end if;
  perform public.desk_log('concession.' || v_status, 'site_concessions', v_id, jsonb_build_object('venue_id', b.venue_id, 'booking_id', p_booking, 'kind', 'free_bottle', 'bottle', bt.name, 'quantity', p_quantity, 'reason', v_reason));
  return jsonb_build_object('id', v_id, 'status', v_status, 'value_cents', greatest(bt.price_cents * p_quantity, 1));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Deciding and taking back
-- ---------------------------------------------------------------------------
-- What waits at this club, with whether the CALLER may decide each one (a manager within the manager's limit and pool, and never their own; the owner anything).
create function public.desk_pending_concessions(p_venue uuid)
returns table (
  concession_id uuid, booking_id uuid, confirmation_code text, guest_name text, table_name text, kind text, percent int, amount_cents int, bottle_name text, quantity int,
  reason text, requested_by_name text, requested_role text, created_at timestamp with time zone, can_decide boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_role text;
  l public.site_discount_limits;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  v_role := public.concession_role(p_venue);
  select * into l from public.site_discount_limits where venue_id = p_venue;
  return query
    select c.id, c.booking_id, b.confirmation_code, b.customer_name, t.name, c.kind, c.percent, c.amount_cents, c.bottle_name, c.quantity, c.reason,
           coalesce(nullif(btrim(pr.name), ''), 'Staff member'), c.requested_role, c.created_at,
           (c.requested_by <> auth.uid()) and (v_role = 'owner' or (v_role = 'manager' and (
              (c.kind = 'discount' and ceil(c.amount_cents * 100.0 / c.base_cents) <= coalesce(l.manager_max_percent, 0))
              or (c.kind = 'free_bottle' and public.concession_pool_used(p_venue, c.business_night) + c.quantity <= coalesce(l.manager_free_bottles_per_night, 0)))))
      from public.site_concessions c
      join public.site_table_bookings b on b.id = c.booking_id
      join public.site_table_types t on t.id = b.table_type_id
      left join public.profiles pr on pr.id = c.requested_by
     where c.venue_id = p_venue and c.status = 'pending'
     order by c.created_at, c.id;
end;
$$;

create function public.desk_decide_concession(p_id uuid, p_approve boolean, p_note text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.site_concessions;
  v_role text;
  l public.site_discount_limits;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into c from public.site_concessions where id = p_id for update;
  if not found then raise exception 'not allowed'; end if;
  v_role := public.concession_role(c.venue_id);
  if v_role is null then raise exception 'not allowed'; end if;   -- without a booking the role is only ever 'owner', 'manager' or null
  if c.status <> 'pending' then raise exception 'this request has already been decided'; end if;
  if p_approve is null then raise exception 'approve or decline'; end if;
  if v_note is not null and char_length(v_note) > 300 then raise exception 'the note can be up to 300 characters'; end if;
  if c.requested_by = auth.uid() then raise exception 'you cannot approve your own request: another manager or the owner decides'; end if;

  if not p_approve then
    if v_note is null or char_length(v_note) < 3 then raise exception 'say why it is declined, so the person can be told'; end if;
    update public.site_concessions set status = 'declined', decided_by = auth.uid(), decided_role = v_role, decided_at = now(), decision_note = v_note, updated_at = now() where id = p_id;
    perform public.desk_log('concession.declined', 'site_concessions', p_id, jsonb_build_object('venue_id', c.venue_id, 'booking_id', c.booking_id, 'reason', v_note));
    return 'declined';
  end if;

  select * into l from public.site_discount_limits where venue_id = c.venue_id;
  if v_role = 'manager' then
    if c.kind = 'discount' and ceil(c.amount_cents * 100.0 / c.base_cents) > coalesce(l.manager_max_percent, 0) then
      raise exception 'this is more than a manager may approve: the owner decides';
    end if;
    if c.kind = 'free_bottle' and public.concession_pool_used(c.venue_id, c.business_night) + c.quantity > coalesce(l.manager_free_bottles_per_night, 0) then
      raise exception 'this is more than the managers'' free bottles for the night: the owner decides';
    end if;
  end if;
  perform 1 from public.site_table_bookings k where k.id = c.booking_id for update;
  perform public.concession_booking_check(c.booking_id);
  if c.kind = 'discount' and not coalesce(l.allow_stacking, false) and exists (select 1 from public.site_concessions o where o.booking_id = c.booking_id and o.kind = 'discount' and o.status = 'applied' and o.id <> c.id) then
    raise exception 'this table already has a discount: discounts do not combine at this club';
  end if;
  update public.site_concessions set status = 'applied', decided_by = auth.uid(), decided_role = v_role, decided_at = now(), decision_note = v_note, updated_at = now() where id = p_id;
  perform public.concession_apply(p_id);
  perform public.desk_log('concession.applied', 'site_concessions', p_id, jsonb_build_object('venue_id', c.venue_id, 'booking_id', c.booking_id, 'approved_by_role', v_role, 'reason', v_note));
  return 'applied';
end;
$$;

-- Takes an applied concession back: the discount stops counting (what the table owes goes back up), a free bottle that has not been served is cancelled.
create function public.desk_void_concession(p_id uuid, p_note text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.site_concessions;
  v_role text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  ln public.site_table_booking_bottles;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into c from public.site_concessions where id = p_id for update;
  if not found then raise exception 'not allowed'; end if;
  v_role := public.concession_role(c.venue_id);
  if v_role is null then raise exception 'not allowed'; end if;   -- without a booking the role is only ever 'owner', 'manager' or null
  if c.status = 'voided' then return 'voided'; end if;
  if c.status <> 'applied' then raise exception 'only something that has been applied can be taken back'; end if;
  if v_note is null or char_length(v_note) < 3 then raise exception 'say why it is taken back'; end if;
  perform 1 from public.site_table_bookings k where k.id = c.booking_id for update;
  if exists (select 1 from public.site_table_bookings k where k.id = c.booking_id and k.reconciled_at is not null) then raise exception 'this table has already been closed out'; end if;
  if c.kind = 'discount' then
    update public.site_table_bookings set staff_discount_cents = greatest(staff_discount_cents - c.amount_cents, 0), amount_total_cents = amount_total_cents + c.amount_cents, updated_at = now() where id = c.booking_id;
  else
    select * into ln from public.site_table_booking_bottles where id = c.line_id for update;
    if found then
      if ln.service_status = 'served' or ln.delivered_quantity > 0 then raise exception 'that bottle has already been served, so it cannot be taken back'; end if;
      update public.site_table_booking_bottles set cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = 'Free bottle taken back: ' || v_note where id = ln.id and cancelled_at is null;
    end if;
  end if;
  update public.site_concessions set status = 'voided', voided_by = auth.uid(), voided_at = now(), decision_note = coalesce(decision_note, v_note), updated_at = now() where id = p_id;
  perform public.desk_log('concession.voided', 'site_concessions', p_id, jsonb_build_object('venue_id', c.venue_id, 'booking_id', c.booking_id, 'reason', v_note));
  return 'voided';
end;
$$;

create function public.desk_booking_concessions(p_booking uuid)
returns table (
  concession_id uuid, kind text, percent int, amount_cents int, bottle_name text, quantity int, status text, reason text, requested_by_name text, requested_role text,
  decided_by_name text, decision_note text, created_at timestamp with time zone
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.concession_role((select b.venue_id from public.site_table_bookings b where b.id = p_booking), p_booking) is null then raise exception 'not allowed'; end if;
  return query
    select c.id, c.kind, c.percent, c.amount_cents, c.bottle_name, c.quantity, c.status, c.reason,
           coalesce(nullif(btrim(rq.name), ''), 'Staff member'), c.requested_role,
           case when c.decided_by is null then null else coalesce(nullif(btrim(dc.name), ''), 'Staff member') end, c.decision_note, c.created_at
      from public.site_concessions c
      left join public.profiles rq on rq.id = c.requested_by
      left join public.profiles dc on dc.id = c.decided_by
     where c.booking_id = p_booking
     order by c.created_at, c.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. The CMS's read-only views (BottlesUp admins)
-- ---------------------------------------------------------------------------
create function public.cms_concessions(p_status text default null, p_limit int default 300)
returns table (
  concession_id uuid, venue_name text, confirmation_code text, kind text, percent int, amount_cents int, bottle_name text, quantity int, status text, reason text,
  requested_by_name text, requested_role text, decided_by_name text, decided_role text, business_night date, created_at timestamp with time zone
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  if p_status is not null and p_status not in ('applied', 'pending', 'declined', 'voided') then raise exception 'unknown status'; end if;
  return query
    select c.id, v.name, b.confirmation_code, c.kind, c.percent, c.amount_cents, c.bottle_name, c.quantity, c.status, c.reason,
           coalesce(nullif(btrim(rq.name), ''), 'Staff member'), c.requested_role,
           case when c.decided_by is null then null else coalesce(nullif(btrim(dc.name), ''), 'Staff member') end, c.decided_role, c.business_night, c.created_at
      from public.site_concessions c
      join public.site_venues v on v.id = c.venue_id
      join public.site_table_bookings b on b.id = c.booking_id
      left join public.profiles rq on rq.id = c.requested_by
      left join public.profiles dc on dc.id = c.decided_by
     where p_status is null or c.status = p_status
     order by (c.status = 'pending') desc, c.created_at desc, c.id
     limit least(greatest(coalesce(p_limit, 300), 1), 1000);
end;
$$;

create function public.cms_discount_limits()
returns table (venue_id uuid, venue_name text, has_limits boolean, server_max_percent int, manager_max_percent int, server_free_bottles_per_night int, manager_free_bottles_per_night int, allow_stacking boolean, updated_at timestamp with time zone)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  return query
    select v.id, v.name, l.venue_id is not null, coalesce(l.server_max_percent, 0), coalesce(l.manager_max_percent, 0), coalesce(l.server_free_bottles_per_night, 0),
           coalesce(l.manager_free_bottles_per_night, 0), coalesce(l.allow_stacking, false), l.updated_at
      from public.site_venues v left join public.site_discount_limits l on l.venue_id = v.id
     order by v.name, v.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Grants
-- ---------------------------------------------------------------------------
revoke all on function
  public.venue_discount_limits(uuid), public.save_venue_discount_limits(uuid, jsonb), public.desk_concession_limits(uuid), public.desk_request_discount(uuid, text, int, text),
  public.desk_request_free_bottle(uuid, uuid, int, text), public.desk_pending_concessions(uuid), public.desk_decide_concession(uuid, boolean, text), public.desk_void_concession(uuid, text),
  public.desk_booking_concessions(uuid), public.cms_concessions(text, int), public.cms_discount_limits()
  from public, anon;
grant execute on function
  public.venue_discount_limits(uuid), public.save_venue_discount_limits(uuid, jsonb), public.desk_concession_limits(uuid), public.desk_request_discount(uuid, text, int, text),
  public.desk_request_free_bottle(uuid, uuid, int, text), public.desk_pending_concessions(uuid), public.desk_decide_concession(uuid, boolean, text), public.desk_void_concession(uuid, text),
  public.desk_booking_concessions(uuid), public.cms_concessions(text, int), public.cms_discount_limits()
  to authenticated, service_role;
