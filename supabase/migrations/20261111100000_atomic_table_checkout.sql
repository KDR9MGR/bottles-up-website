-- Online table checkout: take the table in ONE step, so the last table of a kind cannot be sold to two guests who check out at the same moment.
--
-- Until now the create-table-booking-checkout function counted the tables taken (site_table_taken_count) in one database call and then inserted the pending
-- booking in another. Two guests starting at the same moment both counted the last table as free and both got a booking. The staff walk-in and the desk have
-- never had this problem: they lock the table type while they count and insert. This function does the same for the online checkout. The edge function keeps its early
-- availability check (a quick, friendly refusal before any bottles or promo code are priced); this one is the check that decides.
--
-- What it does, in one transaction:
--   1. locks the table type of that venue (a second guest for the same type waits here, then counts again and sees the first guest's pending booking),
--   2. checks that the arrival time belongs to that venue,
--   3. counts the taken tables the same way as everyone else (paid bookings, checkouts started within the hold, tables a manager has held or taken out of use;
--      the guest's own earlier unfinished checkout does not block them),
--   4. returns NULL when none is left (nothing is written), otherwise inserts the pending booking and returns its id.
-- Prices, taxes and the promo code are worked out by the edge function from the database, as before; this function only stores them. It is for the service role
-- only (the edge function); visitors and signed-in people cannot call it. A new function: nothing existing is replaced and no row is changed.

create function public.site_reserve_table_booking(
  p_venue uuid,
  p_table_type uuid,
  p_slot uuid,
  p_arrival date,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_guests int,
  p_hours int,
  p_deposit_cents int,
  p_bottle_subtotal_cents int,
  p_tax_cents int,
  p_fee_cents int,
  p_total_cents int,
  p_bottle_payment_choice text,
  p_currency text,
  p_promo_code_id uuid,
  p_discount_cents int,
  p_sign_text text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_table_types;
  v_id uuid;
begin
  select * into t from public.site_table_types where id = p_table_type and venue_id = p_venue for update;
  if not found then raise exception 'table not found'; end if;
  if not exists (select 1 from public.site_venue_time_slots s where s.id = p_slot and s.venue_id = p_venue) then
    raise exception 'arrival time not found';
  end if;
  if p_arrival is null then raise exception 'an arrival date is needed'; end if;
  if p_customer_email is null or btrim(p_customer_email) = '' then raise exception 'an e-mail address is needed'; end if;

  if public.site_table_taken_count(t.id, p_slot, p_arrival, p_customer_email) >= t.inventory_count then
    return null;
  end if;

  insert into public.site_table_bookings (
    venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, customer_phone, guest_count, hours,
    deposit_cents, bottle_subtotal_cents, tax_cents, bottlesup_fee_cents, amount_total_cents, bottle_payment_choice, currency,
    status, promo_code_id, discount_cents, bottle_sign_text
  ) values (
    p_venue, t.id, p_slot, p_arrival, p_customer_name, p_customer_email, p_customer_phone, p_guests, p_hours,
    p_deposit_cents, p_bottle_subtotal_cents, p_tax_cents, p_fee_cents, p_total_cents, p_bottle_payment_choice, p_currency,
    'pending', p_promo_code_id, p_discount_cents, p_sign_text
  ) returning id into v_id;

  return v_id;
end $$;

revoke all on function public.site_reserve_table_booking(uuid, uuid, uuid, date, text, text, text, int, int, int, int, int, int, int, text, text, uuid, int, text)
  from public, anon, authenticated;
grant execute on function public.site_reserve_table_booking(uuid, uuid, uuid, date, text, text, text, int, int, int, int, int, int, int, text, text, uuid, int, text)
  to service_role;
