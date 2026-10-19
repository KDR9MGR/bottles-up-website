-- Partial delivery of a bottle order (developer brief 15 Oct, section 16: "partial delivery"; section 35 step 11: "Mark partial or full delivery appropriately").
-- 20261014120000_desk_orders.sql said "Delivering part of a line needs a delivered quantity the table does not have: not built". This adds it.
--
--   * site_table_booking_bottles.delivered_quantity   how many of the line's bottles have been handed over so far (additive column, 0 for every existing line)
--   * desk_deliver_part(line, how_many, already)      hand over some of a line. `already` is how many the caller believes were handed over before this: if someone else
--                                                     moved the line in the meantime (or this is a repeated tap, or a retry after a lost answer) the call is refused and
--                                                     nothing is added twice. The last bottles flip the line to Delivered (served); anything less leaves it On the way.
--   * desk_booking_deliveries(booking)                 the delivered count of every line of one booking (the existing order list is left exactly as it is)
--
-- The same rules as marking a line Delivered (desk_set_service_status): the caller is the club's manager or owner, or the server the booking was given to; the booking is
-- confirmed and not closed out; the line is not cancelled and not still being paid online; an item to be paid at the club is not handed over, not even in part, until the
-- table's balance is zero and a payment was recorded. A line must be Ready or On the way first (nothing is handed over before it is prepared), and a Delivered line is final.
-- Locks the booking and then the line, in that order, like every desk function. Moving a line by hand with desk_set_service_status is unchanged: a line it marks Delivered
-- counts as fully delivered whatever its delivered_quantity says (the app shows Delivered as all of them).
--
-- Plain ADD COLUMN and CREATE FUNCTION (a name collision in the shared database fails loudly, and the file runs in one transaction). Needs the server desk migrations
-- (20261014*) and the production-only line columns payment_status, service_status and cancelled_at they already require.

do $$
declare
  missing text;
begin
  select string_agg(x.c, ', ' order by x.c) into missing
  from (values ('payment_status'), ('service_status'), ('cancelled_at'), ('quantity')) as x(c)
  where not exists (select 1 from information_schema.columns k where k.table_schema = 'public' and k.table_name = 'site_table_booking_bottles' and k.column_name = x.c);
  if missing is not null then
    raise exception 'site_table_booking_bottles is missing % (the server desk migrations 20261014* must be applied first). Nothing was changed.', missing;
  end if;
end $$;

alter table public.site_table_booking_bottles add column delivered_quantity int not null default 0 check (delivered_quantity >= 0);

create function public.desk_booking_deliveries(p_booking uuid)
returns table (line_id uuid, delivered_quantity int)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_level text;
begin
  v_level := public.desk_booking_level(p_booking);
  if v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;
  return query
    select bb.id, bb.delivered_quantity
      from public.site_table_booking_bottles bb
     where bb.booking_id = p_booking and bb.payment_status <> 'pending_payment'
     order by bb.created_at, bb.id;
end;
$$;

create function public.desk_deliver_part(p_line uuid, p_quantity int, p_already int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_level text;
  v_booking record;
  v_line record;
  v_total int;
  v_status text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;

  select bb.booking_id into v_booking_id from public.site_table_booking_bottles bb where bb.id = p_line;
  v_level := public.desk_booking_level(v_booking_id);
  if v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;

  select b.id, b.venue_id, b.status, b.reconciled_at, b.amount_total_cents, b.amount_paid_cents into v_booking
    from public.site_table_bookings b where b.id = v_booking_id for update;
  select bb.id, bb.quantity, bb.delivered_quantity, bb.payment_status, bb.service_status, bb.cancelled_at into v_line
    from public.site_table_booking_bottles bb where bb.id = p_line for update;

  if v_booking.status is distinct from 'paid' then raise exception 'only a paid booking has orders to serve'; end if;
  if v_booking.reconciled_at is not null then raise exception 'this table has already been closed out'; end if;
  if v_line.cancelled_at is not null then raise exception 'this item was cancelled'; end if;
  if v_line.payment_status = 'pending_payment' then raise exception 'payment not yet verified for this item'; end if;
  if v_line.service_status = 'served' then raise exception 'this item has already been delivered'; end if;
  if v_line.service_status not in ('ready', 'picked_up') then raise exception 'this item is not ready to be delivered yet'; end if;
  if p_already is distinct from v_line.delivered_quantity then raise exception 'someone else has just changed this item, look at it again'; end if;
  if p_quantity is null or p_quantity < 1 then raise exception 'choose how many were delivered'; end if;
  if p_quantity > v_line.quantity - v_line.delivered_quantity then
    raise exception 'only % of this item are left to deliver', v_line.quantity - v_line.delivered_quantity;
  end if;

  if v_line.payment_status = 'due_at_venue' then
    if greatest(v_booking.amount_total_cents - v_booking.amount_paid_cents, 0) > 0 then
      raise exception 'cannot mark delivered - this table still has a balance due at the venue';
    end if;
    if not exists (select 1 from public.site_table_booking_club_payments cp where cp.booking_id = v_booking_id) then
      raise exception 'cannot mark delivered - no payment has been recorded for this table';
    end if;
  end if;

  v_total := v_line.delivered_quantity + p_quantity;
  v_status := case when v_total >= v_line.quantity then 'served' else 'picked_up' end;
  update public.site_table_booking_bottles set delivered_quantity = v_total, service_status = v_status where id = p_line;

  perform public.desk_log('table_booking.bottle_delivered_part', 'site_table_booking_bottles', p_line,
    jsonb_build_object('venue_id', v_booking.venue_id, 'booking_id', v_booking_id, 'delivered_now', p_quantity, 'delivered_total', v_total, 'of', v_line.quantity,
                       'old_status', v_line.service_status, 'new_status', v_status));
  return jsonb_build_object('delivered', v_total, 'quantity', v_line.quantity, 'service_status', v_status);
end;
$$;

revoke all on function public.desk_booking_deliveries(uuid), public.desk_deliver_part(uuid, int, int) from public, anon;
grant execute on function public.desk_booking_deliveries(uuid), public.desk_deliver_part(uuid, int, int) to authenticated, service_role;
