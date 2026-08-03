-- Interactive floor-plan table selection + venue booking windows + hourly
-- pricing. Fully additive: every new column is nullable/defaulted, so
-- existing venues (e.g. KDR CLUBS) with no positioned tables, no booking
-- window, and flat pricing keep working exactly as they do today.

-- Venue-level booking window: bookings are only possible on dates that both
-- match a configured weekly time slot AND fall inside this range (when set).
alter table public.site_venues
  add column booking_start_date date,
  add column booking_end_date date;

-- One row per floor/level of a venue (e.g. "Downstairs", "Upstairs"), each
-- holding the venue's own uploaded floor plan image as the visual background
-- for the interactive table picker.
create table public.site_venue_floors (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues(id) on delete cascade,
  label text not null,
  image_url text not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.site_venue_floors enable row level security;

create policy "public read floors for published venues" on public.site_venue_floors
  for select using (
    public.is_cms_admin()
    or exists (select 1 from public.site_venues v where v.id = venue_id and v.status = 'published')
  );
create policy "admins manage floors" on public.site_venue_floors
  for all using (public.is_cms_admin()) with check (public.is_cms_admin());

create trigger site_venue_floors_set_updated_at before update on public.site_venue_floors
  for each row execute function public.set_updated_at();

-- A table type becomes "positioned" once floor_id/pos_x are set - it then
-- renders as a clickable hotspot on its floor's image instead of a plain
-- card. pos_x/pos_y/width/height are percentages (0-100) of the floor
-- image's dimensions so placement stays correct at any render size.
alter table public.site_table_types
  add column floor_id uuid references public.site_venue_floors(id) on delete set null,
  add column pos_x numeric,
  add column pos_y numeric,
  add column width numeric,
  add column height numeric,
  add column min_guests int,
  add column pricing_mode text not null default 'flat' check (pricing_mode in ('flat', 'hourly')),
  add column hourly_rate_cents int,
  add column min_hours int;

-- Records how many hours were booked for an hourly-priced table (null for
-- flat-priced bookings).
alter table public.site_table_bookings
  add column hours int;

-- Lets the public floor-plan picker grey out already-booked tables before
-- checkout, without exposing any booking/customer data - only IDs.
create or replace function public.get_unavailable_table_types(
  p_venue_id uuid,
  p_booking_date date,
  p_time_slot_id uuid
)
returns setof uuid
language sql
security definer
set search_path = public
stable
as $$
  select distinct table_type_id
  from public.site_table_bookings
  where venue_id = p_venue_id
    and booking_date = p_booking_date
    and time_slot_id = p_time_slot_id
    and status = 'paid';
$$;
