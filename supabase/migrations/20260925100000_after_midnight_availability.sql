-- A table booked for an arrival time before 06:00 is stored under the day the guest ARRIVES, and the picker asks about the NIGHT.
--
-- THIS CHANGE IS ALREADY LIVE IN PRODUCTION (applied by hand on 2026-09-25 through the Supabase MCP as a migration called
-- "fix_after_midnight_booking_dates" and never committed here). This file records its schema half. Running it where the change is
-- already present does NOTHING (see the checks below).
--
-- The rule (kept the same in four places: here, supabase/functions/_shared/bookingNight.ts, src/lib/bookingNight.ts, and booking_night()
-- in 20261011100000_venue_bookings.sql, which is the inverse): a slot that starts before 06:00 is the tail end of the PREVIOUS night's
-- party. A guest who picks "Saturday night" and the 1:00 AM slot arrives on SUNDAY, so the booking is stored with
-- booking_date = Sunday; the night it belongs to is booking_date - 1. Until 2026-09-25 the checkout stored the clicked date (Saturday),
-- so a 1:00 AM booking sat a day early, in the wrong night, and the door's expiry maths (booking_date + start_time + 12 hours) saw a
-- guest who had not arrived yet as long gone.
--
-- What changed in the schema: get_unavailable_table_types(venue, night, slot). The floor-plan picker calls it with the NIGHT the guest
-- clicked. Bookings are now stored under the arrival date, so for an after-midnight slot the function has to look one day later, or a
-- table that is already booked would show as free and could be double-booked. Its signature, grants and callers are unchanged.
--
-- What changed in the code (committed, not in this file): create-table-booking-checkout and create-walkin-table-booking compute the
-- arrival date on the server (computeArrivalDate) before the availability check and the insert.
--
-- DATA, NOT REPEATED HERE ON PURPOSE. When this went live, every existing booking on an after-midnight slot was moved forward one day
-- (7 rows, all at one venue; confirmation codes, payments and tables untouched). That was a one-time correction of rows written
-- before the fix; it is NOT part of this file because running it twice would move those rows a second day. A new database has no such
-- rows. (The statement that was run: update site_table_bookings b set booking_date = b.booking_date + 1 from site_venue_time_slots ts
-- where ts.id = b.time_slot_id and ts.start_time < time '06:00:00'.)
--
-- GUARDS (compare-and-swap, because this replaces a LIVE function):
--   * the live function already rolls the date forward (its body has the 06:00 check)  -> notice, nothing changed.
--   * the live function is exactly the version 20260731_venue_floor_plans_and_hourly_pricing_part2.sql created -> replaced.
--   * anything else (missing, hand-edited, different security or search_path)          -> STOPS, nothing changed.

do $migration$
declare
  v_live text;
  v_src text;
  c_before constant text := '15c65b8f8eae341daf8d6837ba389122';  -- the 20260731 part 2 definition
begin
  select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, '')), p.prosrc
  into v_live, v_src
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_unavailable_table_types'
    and pg_get_function_identity_arguments(p.oid) = 'p_venue_id uuid, p_booking_date date, p_time_slot_id uuid';

  if v_live is null then
    raise exception 'public.get_unavailable_table_types(uuid, date, uuid) does not exist in this database. Nothing was changed.';
  end if;

  if position('06:00:00' in v_src) > 0 then
    raise notice 'get_unavailable_table_types() already rolls the date forward for after-midnight slots: this change is already applied. Nothing was changed.';
    return;
  end if;

  if v_live <> c_before then
    raise exception
      'get_unavailable_table_types() in this database differs from the version this change was written against (live fingerprint %, expected %). '
      'It was NOT replaced, because that could undo a change made directly in the database. Inspect it with \sf public.get_unavailable_table_types '
      'and reconcile by hand. Nothing was changed.', v_live, c_before;
  end if;

  execute $sql$
    create or replace function public.get_unavailable_table_types(p_venue_id uuid, p_booking_date date, p_time_slot_id uuid)
    returns setof uuid
    language sql
    stable
    security definer
    set search_path = public
    as $$
      select distinct b.table_type_id
      from public.site_table_bookings b
      join public.site_venue_time_slots ts on ts.id = p_time_slot_id
      where b.venue_id = p_venue_id
        and b.time_slot_id = p_time_slot_id
        and b.booking_date = (case when ts.start_time < time '06:00:00' then p_booking_date + 1 else p_booking_date end)
        and b.status = 'paid';
    $$
  $sql$;

  raise notice 'get_unavailable_table_types() now looks one day later for after-midnight slots.';
end
$migration$;
