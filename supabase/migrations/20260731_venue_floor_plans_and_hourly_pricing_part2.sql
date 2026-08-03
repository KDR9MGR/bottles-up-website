-- Completes 20260731_venue_floor_plans_and_hourly_pricing.sql: the first
-- attempt partially applied (site_venue_floors table + RLS-enable only)
-- before erroring on "relation already exists", so this finishes the
-- remaining pieces defensively (IF NOT EXISTS / DROP + CREATE) so it's safe
-- to run regardless of how much of the original migration already landed.

alter table public.site_venues
  add column if not exists booking_start_date date,
  add column if not exists booking_end_date date;

drop policy if exists "public read floors for published venues" on public.site_venue_floors;
create policy "public read floors for published venues" on public.site_venue_floors
  for select using (
    public.is_cms_admin()
    or exists (select 1 from public.site_venues v where v.id = venue_id and v.status = 'published')
  );
drop policy if exists "admins manage floors" on public.site_venue_floors;
create policy "admins manage floors" on public.site_venue_floors
  for all using (public.is_cms_admin()) with check (public.is_cms_admin());

drop trigger if exists site_venue_floors_set_updated_at on public.site_venue_floors;
create trigger site_venue_floors_set_updated_at before update on public.site_venue_floors
  for each row execute function public.set_updated_at();

alter table public.site_table_types
  add column if not exists floor_id uuid references public.site_venue_floors(id) on delete set null,
  add column if not exists pos_x numeric,
  add column if not exists pos_y numeric,
  add column if not exists width numeric,
  add column if not exists height numeric,
  add column if not exists min_guests int,
  add column if not exists pricing_mode text not null default 'flat',
  add column if not exists hourly_rate_cents int,
  add column if not exists min_hours int;

alter table public.site_table_types drop constraint if exists site_table_types_pricing_mode_check;
alter table public.site_table_types add constraint site_table_types_pricing_mode_check
  check (pricing_mode in ('flat', 'hourly'));

alter table public.site_table_bookings
  add column if not exists hours int;

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
