CREATE OR REPLACE FUNCTION public.desk_create_walkin(p_venue uuid, p_night date, p_table_type uuid, p_slot uuid, p_guests integer, p_hours integer, p_name text, p_email text, p_phone text, p_terms_confirmed boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.desk_walkin_options(p_venue uuid, p_night date)
 RETURNS TABLE(slot_id uuid, start_time time without time zone, slot_label text, table_type_id uuid, table_name text, max_guests integer, min_guests integer, pricing_mode text, deposit_cents integer, hourly_rate_cents integer, min_hours integer, inventory integer, booked integer, available integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.get_unavailable_table_types(p_venue_id uuid, p_booking_date date, p_time_slot_id uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
      select distinct b.table_type_id
      from public.site_table_bookings b
      join public.site_venue_time_slots ts on ts.id = p_time_slot_id
      where b.venue_id = p_venue_id
        and b.time_slot_id = p_time_slot_id
        and b.booking_date = (case when ts.start_time < time '06:00:00' then p_booking_date + 1 else p_booking_date end)
        and b.status = 'paid';
    $function$
;
