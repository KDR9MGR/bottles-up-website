-- The get_unavailable_table_types() that supabase/migrations/20260731_venue_floor_plans_and_hourly_pricing_part2.sql defines: the version BEFORE
-- the after-midnight change (it compares the booking date as given, so a 1:00 AM booking stored under the arrival day looks free). Tests use it
-- to put a database into the "before" state. Copied verbatim from that migration; do not edit.
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
