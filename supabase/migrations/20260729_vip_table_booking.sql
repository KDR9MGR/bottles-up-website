-- VIP table booking system: venues, recurring weekly time slots, table types
-- (Silver/Gold/Platinum-style), and the actual bookings, mirroring the
-- site_events / site_ticket_tiers / site_orders pattern as closely as possible.

create table public.site_venues (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique,
  description text,
  address text,
  cover_image_url text,
  gallery text[] not null default '{}',
  status text not null default 'draft' check (status in ('draft', 'published')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Which days of week + arrival times this venue accepts table bookings for.
create table public.site_venue_time_slots (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues(id) on delete cascade,
  day_of_week int not null check (day_of_week between 0 and 6), -- 0 = Sunday
  start_time time not null,
  label text, -- optional display label, e.g. "Early", "Prime", "Late"
  created_at timestamptz not null default now()
);

-- Table categories offered at a venue (Silver/Gold/Platinum/Diamond-style).
create table public.site_table_types (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues(id) on delete cascade,
  name text not null,
  description text,
  max_guests int not null check (max_guests > 0),
  min_spend_cents int not null check (min_spend_cents >= 0),
  deposit_cents int not null check (deposit_cents >= 0),
  currency text not null default 'cad',
  inventory_count int not null check (inventory_count >= 0), -- physical tables of this type
  image_url text,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.site_table_bookings (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues(id),
  table_type_id uuid not null references public.site_table_types(id),
  time_slot_id uuid not null references public.site_venue_time_slots(id),
  booking_date date not null,
  customer_name text not null,
  customer_email text not null,
  customer_phone text,
  guest_count int not null check (guest_count > 0),
  amount_total_cents int not null check (amount_total_cents >= 0), -- deposit charged
  currency text not null default 'cad',
  stripe_checkout_session_id text unique,
  stripe_payment_intent_id text,
  status text not null default 'pending' check (status in ('pending', 'paid', 'failed', 'refunded')),
  confirmation_code text unique,
  confirmation_sent_at timestamptz,
  checked_in_at timestamptz,
  checked_in_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.site_venues enable row level security;
alter table public.site_venue_time_slots enable row level security;
alter table public.site_table_types enable row level security;
alter table public.site_table_bookings enable row level security;

create policy "public read published venues" on public.site_venues
  for select using (status = 'published' or public.is_cms_admin());
create policy "admins manage venues" on public.site_venues
  for all using (public.is_cms_admin()) with check (public.is_cms_admin());

create policy "public read time slots for published venues" on public.site_venue_time_slots
  for select using (
    public.is_cms_admin()
    or exists (select 1 from public.site_venues v where v.id = venue_id and v.status = 'published')
  );
create policy "admins manage time slots" on public.site_venue_time_slots
  for all using (public.is_cms_admin()) with check (public.is_cms_admin());

create policy "public read table types for published venues" on public.site_table_types
  for select using (
    public.is_cms_admin()
    or exists (select 1 from public.site_venues v where v.id = venue_id and v.status = 'published')
  );
create policy "admins manage table types" on public.site_table_types
  for all using (public.is_cms_admin()) with check (public.is_cms_admin());

-- bookings: no public insert policy at all - rows are only ever written by the
-- create-table-booking-checkout edge function using the service_role key,
-- same pattern as site_orders.
create policy "admins read table bookings" on public.site_table_bookings
  for select using (public.is_cms_admin());
create policy "admins update table bookings" on public.site_table_bookings
  for update using (public.is_cms_admin()) with check (public.is_cms_admin());

create trigger site_venues_set_updated_at before update on public.site_venues
  for each row execute function public.set_updated_at();
create trigger site_table_types_set_updated_at before update on public.site_table_types
  for each row execute function public.set_updated_at();
create trigger site_table_bookings_set_updated_at before update on public.site_table_bookings
  for each row execute function public.set_updated_at();

-- Let the same door-staff/admin scanner recognize table-booking confirmation
-- codes alongside ticket codes.
alter table public.scan_attempts add column booking_id uuid references public.site_table_bookings(id);

create or replace function public.checkin_ticket(p_ticket_code text)
returns table(result text, customer_name text, event_title text, tier_name text, quantity int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_booking record;
  v_result text;
  v_customer_name text;
  v_context text;
  v_item_name text;
  v_qty int;
  v_effective_end timestamptz;
begin
  if not (public.is_cms_admin() or public.is_door_staff()) then
    raise exception 'not authorized';
  end if;

  select o.id, o.status, o.checked_in_at, o.customer_name, o.quantity,
         e.title as event_title, e.start_date, e.end_date, t.name as tier_name
  into v_order
  from public.site_orders o
  join public.site_ticket_tiers t on t.id = o.tier_id
  join public.site_events e on e.id = o.event_id
  where o.ticket_code = p_ticket_code
  for update of o;

  if found then
    v_customer_name := v_order.customer_name;
    v_context := v_order.event_title;
    v_item_name := v_order.tier_name;
    v_qty := v_order.quantity;

    if v_order.status <> 'paid' then
      v_result := 'not_paid';
    elsif v_order.checked_in_at is not null then
      v_result := 'already_checked_in';
    else
      v_effective_end := greatest(v_order.start_date + interval '12 hours', coalesce(v_order.end_date, v_order.start_date));
      if now() > v_effective_end then
        v_result := 'expired';
      else
        update public.site_orders set checked_in_at = now(), checked_in_by = auth.uid() where id = v_order.id;
        v_result := 'ok';
      end if;
    end if;

    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, v_order.id, auth.uid());
    return query select v_result, v_customer_name, v_context, v_item_name, v_qty;
    return;
  end if;

  -- Not a ticket code - try a table-booking confirmation code.
  select b.id, b.status, b.checked_in_at, b.customer_name, b.guest_count,
         v.name as venue_name, tt.name as table_type_name,
         b.booking_date, ts.start_time
  into v_booking
  from public.site_table_bookings b
  join public.site_table_types tt on tt.id = b.table_type_id
  join public.site_venues v on v.id = b.venue_id
  join public.site_venue_time_slots ts on ts.id = b.time_slot_id
  where b.confirmation_code = p_ticket_code
  for update of b;

  if not found then
    v_result := 'not_found';
    insert into public.scan_attempts (ticket_code_attempted, result, scanned_by)
      values (p_ticket_code, v_result, auth.uid());
    return query select v_result, null::text, null::text, null::text, null::int;
    return;
  end if;

  v_customer_name := v_booking.customer_name;
  v_context := v_booking.venue_name || ' - ' || to_char(v_booking.booking_date, 'FMMon DD') || ' ' || to_char(v_booking.start_time, 'FMHH12:MI AM');
  v_item_name := v_booking.table_type_name;
  v_qty := v_booking.guest_count;

  if v_booking.status <> 'paid' then
    v_result := 'not_paid';
  elsif v_booking.checked_in_at is not null then
    v_result := 'already_checked_in';
  else
    v_effective_end := ((v_booking.booking_date::timestamp + v_booking.start_time) at time zone 'utc') + interval '12 hours';
    if now() > v_effective_end then
      v_result := 'expired';
    else
      update public.site_table_bookings set checked_in_at = now(), checked_in_by = auth.uid() where id = v_booking.id;
      v_result := 'ok';
    end if;
  end if;

  insert into public.scan_attempts (ticket_code_attempted, result, booking_id, scanned_by)
    values (p_ticket_code, v_result, v_booking.id, auth.uid());
  return query select v_result, v_customer_name, v_context, v_item_name, v_qty;
end;
$$;
