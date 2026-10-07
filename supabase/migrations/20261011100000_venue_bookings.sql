-- Owner view of table bookings (read only).
--
-- Client brief, section 4 ("Tables & Bookings"): an owner sees the reservations of their own venues: who is coming, on which
-- night, to which table, how many people, and whether it is paid. Until now only the BottlesUp admin could read
-- site_table_bookings (RLS: "admins read table bookings"), so owners could not see their own bookings.
--
-- HOW: a function, not a read policy. It checks the person owns or manages THIS venue (the same check as venue setup), takes a
-- bounded date range, and returns only the columns listed. Nothing here writes, and nothing outside the venue is reachable.
--
-- THE NIGHT: a venue's night runs past midnight. A table booked for 1:00 AM is Saturday night's party but is stored with
-- Sunday's calendar date. Any slot starting before 06:00 belongs to the previous night. That is the same rule as
-- src/lib/bookingNight.ts and supabase/functions/_shared/bookingNight.ts (AFTER_MIDNIGHT_CUTOFF); a test compares the three.
--
-- DELIBERATELY ONLY COLUMNS THAT THE COMMITTED MIGRATIONS DEFINE. Production has more on this table (what was actually paid,
-- cancellation reason and time, reconciliation) that no committed migration creates, so it cannot be tested here and is not
-- guessed at. `status` is read as it is stored, so a 'cancelled' or 'refunded' booking is still labelled as such. Amounts shown
-- are the booked total and deposit, NOT collections: money received needs the production definitions (`supabase db pull`).
-- Bottle orders are left out for the same reason: cancelled lines and their service state live in columns that are not here.
--
-- Plain CREATE, never CREATE OR REPLACE, so a name collision in the shared database fails loudly.

-- The business night a booking belongs to, from its stored arrival date and its slot's start time.
create function public.booking_night(p_arrival date, p_start time)
returns date
language sql
immutable
set search_path = public
as $$
  select case when p_start < time '06:00:00' then p_arrival - 1 else p_arrival end
$$;

-- p_from and p_to are business nights, both included. At most 93 nights at a time and 1000 rows: a bounded answer, so a
-- venue with years of bookings cannot be made to return all of them.
-- require_venue_editor() is the owner-or-manager-of-this-venue check (its name comes from the setup functions).
create function public.list_venue_bookings(p_venue uuid, p_from date, p_to date)
returns table (
  booking_id uuid, night_date date, start_time time, slot_label text, table_name text, guest_count int,
  customer_name text, customer_email text, customer_phone text, status text, fulfillment_status text,
  amount_total_cents int, deposit_cents int, currency text, confirmation_code text, checked_in_at timestamptz, created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  if p_from is null or p_to is null then raise exception 'choose a start and an end date'; end if;
  if p_to < p_from then raise exception 'the end date is before the start date'; end if;
  if p_to - p_from > 92 then raise exception 'choose at most 93 nights at a time'; end if;

  return query
    select b.id, public.booking_night(b.booking_date, s.start_time), s.start_time, s.label, t.name, b.guest_count,
           b.customer_name, b.customer_email, b.customer_phone, b.status, b.fulfillment_status,
           b.amount_total_cents, b.deposit_cents, b.currency, b.confirmation_code, b.checked_in_at, b.created_at
    from public.site_table_bookings b
    join public.site_venue_time_slots s on s.id = b.time_slot_id
    join public.site_table_types t on t.id = b.table_type_id
    where b.venue_id = p_venue
      -- A night's bookings sit on that calendar date or the next one, so this narrows the scan before the exact rule below.
      and b.booking_date between p_from and p_to + 1
      and public.booking_night(b.booking_date, s.start_time) between p_from and p_to
    order by public.booking_night(b.booking_date, s.start_time),
             (s.start_time < time '06:00:00'),   -- the evening first, then the after-midnight tail of the same night
             s.start_time, b.customer_name, b.created_at
    limit 1000;
end;
$$;

revoke all on function public.booking_night(date, time), public.list_venue_bookings(uuid, date, date) from public, anon;
grant execute on function public.booking_night(date, time) to authenticated, service_role;
grant execute on function public.list_venue_bookings(uuid, date, date) to authenticated, service_role;
