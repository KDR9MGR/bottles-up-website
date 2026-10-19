-- Payment settings of a venue, for the people who run it (developer brief 15 Oct, section 15: "Bottle payments: Pay Ahead / Pay at Venue / Customer
-- Chooses"; "Deposit required, amount per table or package, recipient, purpose").
--
--   * venue_payment_rules(venue)       what the venue's payment settings are now (owner or manager of that venue).
--   * save_venue_payment_rules(venue, details)   changes the bottle payment mode, and ONLY that.
--
-- Why only the bottle payment mode is changeable here:
--   * bottle_payment_mode ('pay_ahead' | 'pay_at_club' | 'both') is read by the checkout when a booking is made and stored on the booking
--     (bottle_payment_choice), so changing it affects NEW bookings only. Existing bookings keep the terms they were made under.
--   * deposit_is_credit (the deposit is credited against the bottle bill) is NOT stored per booking: the checkout, the totals and the
--     reconciliation read the venue's current value. Changing it would change how bookings that already exist are worked out, which the brief
--     forbids ("existing bookings retain their original terms"). It is therefore read-only here until each booking carries its own copy; asking to
--     change it is refused with a plain sentence. (BottlesUp staff can still change it in the CMS, as before.)
--   * the deposit amount is per table type and already has its own editor (save_venue_table_type).
--
-- Both columns exist in production but are defined by no migration in this repository (they were added by hand); the first statement stops
-- this migration if they are missing, rather than guessing. Plain CREATE FUNCTION; setup_* helpers are from 20261010100000_venue_setup.sql.

do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'site_venues' and column_name = 'bottle_payment_mode')
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'site_venues' and column_name = 'deposit_is_credit') then
    raise exception 'site_venues.bottle_payment_mode and site_venues.deposit_is_credit must exist before this migration. Nothing was changed.';
  end if;
end $$;

create function public.venue_payment_rules(p_venue uuid)
returns table (bottle_payment_mode text, deposit_is_credit boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  return query select v.bottle_payment_mode::text, v.deposit_is_credit from public.site_venues v where v.id = p_venue;
end;
$$;

create function public.save_venue_payment_rules(p_venue uuid, p_details jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mode text;
  v_old text;
begin
  perform public.require_venue_editor(p_venue);
  if p_details is not null and jsonb_typeof(p_details) = 'object' and p_details ? 'deposit_is_credit' then
    raise exception 'whether the deposit is credited against the bottle bill cannot be changed here, because bookings that already exist are worked out with it; ask the BottlesUp team';
  end if;
  perform public.setup_only_keys(p_details, array['bottle_payment_mode']);

  v_mode := public.setup_text(p_details, 'bottle_payment_mode', 'bottle payment', 20);
  if v_mode is null then raise exception 'choose how bottles are paid'; end if;
  if v_mode not in ('pay_ahead', 'pay_at_club', 'both') then raise exception 'bottle payment must be pay ahead, pay at the venue, or the customer chooses'; end if;

  select v.bottle_payment_mode::text into v_old from public.site_venues v where v.id = p_venue for update;
  if not found then raise exception 'not allowed'; end if;
  if v_old = v_mode then return v_mode; end if;

  update public.site_venues set bottle_payment_mode = v_mode where id = p_venue;
  perform public.venue_setup_log('venue.payment_rules_saved', 'site_venues', p_venue, p_venue, jsonb_build_object('bottle_payment_mode_from', v_old, 'bottle_payment_mode_to', v_mode));
  return v_mode;
end;
$$;

revoke all on function public.venue_payment_rules(uuid), public.save_venue_payment_rules(uuid, jsonb) from public, anon;
grant execute on function public.venue_payment_rules(uuid), public.save_venue_payment_rules(uuid, jsonb) to authenticated, service_role;
