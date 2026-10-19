-- Adding bottles to a table, by the people who work it (developer brief 15 Oct, section 16: "Server workflow ... add bottles" and section 35 step 10: "Add a
-- bottle order and record/confirm its payment").
--
-- The pricing, the stock check, the booking totals and the e-mail to the guest already live in ONE place, the edge function add-table-booking-bottles (shared with
-- the website: a staff-added item is always "due at the club", never a checkout). That function lets in only people on the global door_staff and cms_admins lists,
-- which an invited server or manager is not on (see 20261014120000_desk_orders.sql). So this migration does not touch money at all. It adds the two things the
-- edge function and the app need, decided in the database where the rules can be tested:
--
--   * desk_may_add_bottles(booking)   true when the caller may add bottles to this booking right now, otherwise a plain sentence says why not:
--                                     the caller is the club's manager or owner, or the server the booking was given to (nobody else: not a verifier, not another
--                                     club's staff, not a server of another table); the booking is confirmed; the table has not been closed out; the night has
--                                     not been closed. The edge function asks it with the caller's own login before it adds anything.
--   * desk_bottle_menu(booking)       the bottles the club offers right now (available, not sold out) with the price and, when the club counts stock, how many
--                                     are left by the same count the edge function uses (everything already on a confirmed booking, paid or due at the club).
--                                     It runs the check above first, so a person who may not add bottles cannot read the menu through it either.
--
-- Plain CREATE, nothing replaced, no data written. Needs the server desk (20261014*) and close night (20261018140000) migrations.

create function public.desk_may_add_bottles(p_booking uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
  v_b record;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_level := public.desk_booking_level(p_booking);
  if v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;

  select b.status, b.reconciled_at, b.venue_id, b.booking_date, s.start_time into v_b
    from public.site_table_bookings b
    join public.site_venue_time_slots s on s.id = b.time_slot_id
   where b.id = p_booking;
  if v_b.status is distinct from 'paid' then raise exception 'only a confirmed booking can have bottles added'; end if;
  if v_b.reconciled_at is not null then raise exception 'this table has already been closed out'; end if;
  if exists (select 1 from public.site_night_closes c
              where c.venue_id = v_b.venue_id and c.business_night = public.booking_night(v_b.booking_date, v_b.start_time) and c.status = 'closed') then
    raise exception 'this night has been closed, so no bottles can be added';
  end if;
  return true;
end;
$$;

create function public.desk_bottle_menu(p_booking uuid)
returns table (bottle_id uuid, name text, size text, category text, price_cents int, left_count int)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_venue uuid;
begin
  perform public.desk_may_add_bottles(p_booking);
  select b.venue_id into v_venue from public.site_table_bookings b where b.id = p_booking;
  return query
    select bt.id, bt.name, bt.size, bt.category, bt.price_cents,
           case when bt.stock_quantity is null then null
                else greatest(bt.stock_quantity - coalesce((
                       select sum(l.quantity)::int
                         from public.site_table_booking_bottles l
                         join public.site_table_bookings k on k.id = l.booking_id
                        where l.bottle_id = bt.id and k.status = 'paid' and l.payment_status in ('paid', 'due_at_venue')), 0), 0) end
      from public.site_bottles bt
     where bt.venue_id = v_venue and bt.is_available and not bt.is_sold_out
     order by bt.sort_order, bt.name, bt.id;
end;
$$;

revoke all on function public.desk_may_add_bottles(uuid), public.desk_bottle_menu(uuid) from public, anon;
grant execute on function public.desk_may_add_bottles(uuid), public.desk_bottle_menu(uuid) to authenticated, service_role;
