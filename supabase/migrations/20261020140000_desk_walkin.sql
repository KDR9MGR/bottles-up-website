-- Walk-in table booking by the club's manager or owner (developer brief 15 Oct, section 17: "Floor > Available Table > Customer Details > Terms > Bottles >
-- Payment > Confirm. Capture name and email. Show cash method clearly and retain separate verification status. Update shared availability on confirmation.
-- On failed payment or expired hold, explain the outcome and release the hold appropriately.").
--
--   * desk_walkin_options(venue, night)    for each arrival time offered that night, each table type with its seats, deposit, how many there are, how many are
--                                          booked and how many are left (the same count the booking itself checks).
--   * desk_create_walkin(...)              books a table for a guest who is here: all or nothing, in one step, with the count checked while the table type is
--                                          LOCKED, so two people cannot book the last table at the same moment. No separate hold is needed: nothing is held and
--                                          then lost, the booking either exists or it does not, and a refusal says why. The booking is confirmed with the deposit
--                                          DUE AT THE CLUB (amount paid 0): the deposit is collected afterwards with "Record a payment", which keeps cash, card and
--                                          its verification separate and visible. The guest is seated at once (they are here), a confirmation e-mail is queued
--                                          (never claimed sent), and the booking and who made it are logged.
--
-- Same rules as an online booking: the arrival day is the day after the night for an after-midnight time; pricing is the table's flat deposit or its hourly
-- rate times the hours (at least the minimum); the party fits the table; only paid bookings take a table. A closed night takes no new booking, and the
-- same guest cannot be booked twice for the same time (a repeated tap, or a retry after a lost answer). Plain CREATE.
-- Needs the server desk (20261014*), seating and outbox (20261018110000) and close night (20261018140000) migrations.

create function public.desk_walkin_options(p_venue uuid, p_night date)
returns table (
  slot_id uuid, start_time time, slot_label text, table_type_id uuid, table_name text, max_guests int, min_guests int, pricing_mode text,
  deposit_cents int, hourly_rate_cents int, min_hours int, inventory int, booked int, available int
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_night is null or abs(p_night - current_date) > 1 then raise exception 'that is not a current night'; end if;
  return query
    select s.id, s.start_time, s.label, t.id, t.name, t.max_guests, t.min_guests, t.pricing_mode, t.deposit_cents, t.hourly_rate_cents, t.min_hours, t.inventory_count,
           b.n, greatest(t.inventory_count - b.n, 0)
      from public.site_venue_time_slots s
      cross join public.site_table_types t
      cross join lateral (
        select count(*)::int as n from public.site_table_bookings k
         where k.table_type_id = t.id and k.time_slot_id = s.id and k.status = 'paid'
           and k.booking_date = case when s.start_time < time '06:00:00' then p_night + 1 else p_night end
      ) b
     where s.venue_id = p_venue and t.venue_id = p_venue and s.day_of_week = extract(dow from p_night)::int
     order by (s.start_time < time '06:00:00'), s.start_time, t.sort_order, t.name;
end;
$$;

create function public.desk_create_walkin(
  p_venue uuid, p_night date, p_table_type uuid, p_slot uuid, p_guests int, p_hours int,
  p_name text, p_email text, p_phone text, p_terms_confirmed boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_table_types;
  s public.site_venue_time_slots;
  v_name text := btrim(coalesce(p_name, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_arrival date;
  v_deposit int;
  v_hours int := null;
  v_booked int;
  v_code text;
  v_id uuid;
  v_try int := 0;
  chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_night is null or abs(p_night - current_date) > 1 then raise exception 'that is not a current night'; end if;
  if p_terms_confirmed is not true then raise exception 'confirm that the guest has been told the terms and agrees to them'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then raise exception 'the guest''s name needs 2 to 120 characters'; end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or char_length(v_email) > 254 then raise exception 'enter a valid email address for the guest'; end if;
  if v_phone is not null and char_length(v_phone) > 40 then raise exception 'the phone number is too long'; end if;
  if exists (select 1 from public.site_night_closes c where c.venue_id = p_venue and c.business_night = p_night and c.status = 'closed') then
    raise exception 'this night has been closed, so no new booking can be added';
  end if;

  -- The table type is locked until this booking is in, so the count below cannot be out of date when it is used.
  select * into t from public.site_table_types where id = p_table_type and venue_id = p_venue for update;
  if not found then raise exception 'table not found'; end if;
  select * into s from public.site_venue_time_slots where id = p_slot and venue_id = p_venue;
  if not found then raise exception 'arrival time not found'; end if;
  if s.day_of_week <> extract(dow from p_night)::int then raise exception 'that arrival time is not offered on that night'; end if;

  if p_guests is null or p_guests < 1 then raise exception 'how many guests?'; end if;
  if p_guests > t.max_guests then raise exception 'this table seats up to % guests', t.max_guests; end if;
  if t.min_guests is not null and p_guests < t.min_guests then raise exception 'this table needs at least % guests', t.min_guests; end if;

  if t.pricing_mode = 'hourly' then
    if coalesce(t.hourly_rate_cents, 0) <= 0 then raise exception 'this table is not set up for hourly booking yet'; end if;
    if p_hours is null or p_hours < coalesce(t.min_hours, 1) or p_hours > 24 then
      raise exception 'this table needs between % and 24 hours', coalesce(t.min_hours, 1);
    end if;
    v_hours := p_hours;
    v_deposit := t.hourly_rate_cents * p_hours;
  else
    v_deposit := t.deposit_cents;
  end if;

  v_arrival := case when s.start_time < time '06:00:00' then p_night + 1 else p_night end;
  -- The same guest twice for the same time is almost always a repeated tap or a retry after a lost answer: refuse it, so nobody is booked twice.
  if exists (select 1 from public.site_table_bookings k where k.venue_id = p_venue and k.time_slot_id = s.id and k.booking_date = v_arrival
                and lower(k.customer_email) = v_email and k.status = 'paid') then
    raise exception 'this guest already has a booking for that time';
  end if;
  select count(*)::int into v_booked from public.site_table_bookings k
   where k.table_type_id = t.id and k.time_slot_id = s.id and k.booking_date = v_arrival and k.status = 'paid';
  if v_booked >= t.inventory_count then raise exception 'no tables of this type are left for that time'; end if;

  loop
    v_try := v_try + 1;
    v_code := 'BT-' || (select string_agg(substr(chars, 1 + floor(random() * length(chars))::int, 1), '') from generate_series(1, 8));
    exit when not exists (select 1 from public.site_table_bookings where confirmation_code = v_code);
    if v_try > 20 then raise exception 'a confirmation code could not be made, try again'; end if;
  end loop;

  insert into public.site_table_bookings (
    venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, customer_phone, guest_count, hours,
    deposit_cents, bottle_subtotal_cents, tax_cents, bottlesup_fee_cents, amount_total_cents, amount_paid_cents, currency,
    status, bottle_payment_choice, confirmation_code, checked_in_at, checked_in_by
  ) values (
    p_venue, t.id, s.id, v_arrival, v_name, v_email, v_phone, p_guests, v_hours,
    v_deposit, 0, 0, 0, v_deposit, 0, t.currency,
    'paid', 'pay_at_club', v_code, now(), auth.uid()
  ) returning id into v_id;

  insert into public.site_booking_seating (booking_id, seated_by, seated_at, method, confirmation)
    values (v_id, auth.uid(), now(), 'manual', 'Walk-in guest, seated when the booking was made');

  perform public.desk_enqueue('walkin_confirmation', p_venue, v_id, jsonb_build_object('confirmation_code', v_code));
  perform public.desk_log('booking.walkin_created', 'site_table_bookings', v_id,
    jsonb_build_object('venue_id', p_venue, 'table_type_id', t.id, 'deposit_cents', v_deposit, 'guests', p_guests, 'terms_confirmed', true));

  return jsonb_build_object('booking_id', v_id, 'confirmation_code', v_code, 'deposit_cents', v_deposit, 'due_cents', v_deposit, 'arrival_date', v_arrival, 'tables_left', t.inventory_count - v_booked - 1);
end;
$$;

revoke all on function public.desk_walkin_options(uuid, date), public.desk_create_walkin(uuid, date, uuid, uuid, int, int, text, text, text, boolean) from public, anon;
grant execute on function public.desk_walkin_options(uuid, date), public.desk_create_walkin(uuid, date, uuid, uuid, int, int, text, text, text, boolean) to authenticated, service_role;
