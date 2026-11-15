-- Stock overview: what is on the shelf, what is promised to tables, what has been handed over, and what is still for sale (client Phase 2 brief, section 22: "More -> Inventory ->
-- Available / Reserved / Low Stock -> Product -> Movements", and "Show most-sold bottles by selected period"). READ ONLY: it changes no stock number, no movement, no booking and no
-- bottle line. One new function, nothing replaced.
--
-- WHAT IT ANSWERS, per bottle of one club (the same people as stock_list(): the club's owner or manager):
--   on_hand      the counted stock (site_bottles.stock_quantity), null while the bottle has not been counted
--   reserved     sold to a table and NOT handed over yet (quantity minus what was delivered)
--   handed_over  sold to a table and already handed over (a line marked Delivered counts in full, a part delivery counts its delivered_quantity)
--   available    what may still be sold: on_hand minus everything sold (reserved + handed over), never below 0; null while the bottle has not been counted
--   sold         bottles sold in the chosen period (by the moment the line was ordered; both ends included), for the "most sold" list
--   low_threshold, is_low, is_sold_out    exactly as stock_list() gives them
--
-- WHAT COUNTS AS SOLD: a line of a confirmed (paid) booking whose line is paid or due at the venue, the same test desk_bottle_menu() uses to say how many are left, EXCEPT that a line
-- that was cancelled does not count here (brief: "Cancelled unissued orders release reservations"). desk_bottle_menu() still counts a cancelled line as sold, so its "left" can be lower than
-- "available" here by the cancelled amount; changing that live function is a separate decision (see HANDOFF).
--
-- A KNOWN GAP THIS DOES NOT CLOSE: handing a bottle over does not reduce the counted stock in the live system (the brief says "Issue reduces physical stock and clears the relevant
-- reservation"). So "available" subtracts every sold line of every night, handed over or not, exactly as desk_bottle_menu() does. That is right while on_hand is the stock before those
-- sales; but a closing count sets on_hand to what is really on the shelf, which already excludes what was handed over, and the same sales are then subtracted a second time. Fixing that
-- means changing the delivery functions or the count, which is a production decision: this function shows the numbers as they are and nothing more.
--
-- Plain CREATE FUNCTION, never CREATE OR REPLACE. Needs the inventory ledger (20261018150000), partial delivery (20261020160000) and the production-only line columns they require.

do $$
declare
  missing text;
begin
  select string_agg(x.c, ', ' order by x.c) into missing
  from (values ('payment_status'), ('service_status'), ('cancelled_at'), ('quantity'), ('delivered_quantity'), ('bottle_id'), ('created_at')) as x(c)
  where not exists (select 1 from information_schema.columns k where k.table_schema = 'public' and k.table_name = 'site_table_booking_bottles' and k.column_name = x.c);
  if missing is not null then
    raise exception 'site_table_booking_bottles is missing % (the server desk and partial delivery migrations must be applied first). Nothing was changed.', missing;
  end if;
  if to_regclass('public.site_stock_thresholds') is null then
    raise exception 'public.site_stock_thresholds is missing (the inventory ledger migration 20261018150000 must be applied first). Nothing was changed.';
  end if;
end $$;

create function public.stock_overview(p_venue uuid, p_from timestamptz default null, p_to timestamptz default null)
returns table (
  bottle_id uuid, name text, size text, category text, tracked boolean,
  on_hand int, reserved int, handed_over int, available int, sold int,
  low_threshold int, is_low boolean, is_sold_out boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_to timestamptz;
  v_from timestamptz;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;

  v_to := coalesce(p_to, now());
  v_from := coalesce(p_from, v_to - interval '30 days');
  if v_from >= v_to then raise exception 'the period has to end after it starts'; end if;
  if v_to - v_from > interval '366 days' then raise exception 'choose a period of a year or less'; end if;

  return query
    with lines as (
      select l.bottle_id as bid,
             l.quantity as qty,
             case when l.service_status = 'served' then l.quantity else least(greatest(coalesce(l.delivered_quantity, 0), 0), l.quantity) end as handed,
             l.created_at as ordered_at
        from public.site_table_booking_bottles l
        join public.site_table_bookings k on k.id = l.booking_id
       where k.venue_id = p_venue and k.status = 'paid' and l.payment_status in ('paid', 'due_at_venue') and l.cancelled_at is null and l.bottle_id is not null
    ), per_bottle as (
      select x.bid,
             sum(x.qty)::int as sold_all,
             sum(x.qty - x.handed)::int as reserved,
             sum(x.handed)::int as handed,
             (coalesce(sum(x.qty) filter (where x.ordered_at >= v_from and x.ordered_at <= v_to), 0))::int as sold_period
        from lines x group by x.bid
    )
    select b.id, b.name, b.size, b.category, b.stock_quantity is not null,
           b.stock_quantity,
           coalesce(a.reserved, 0),
           coalesce(a.handed, 0),
           case when b.stock_quantity is null then null else greatest(b.stock_quantity - coalesce(a.sold_all, 0), 0) end,
           coalesce(a.sold_period, 0),
           t.low_threshold,
           b.stock_quantity is not null and t.low_threshold is not null and b.stock_quantity <= t.low_threshold,
           coalesce(b.is_sold_out, false)
      from public.site_bottles b
      left join public.site_stock_thresholds t on t.bottle_id = b.id
      left join per_bottle a on a.bid = b.id
     where b.venue_id = p_venue
     order by lower(b.name), b.size nulls first, b.id
     limit 500;
end;
$$;

revoke all on function public.stock_overview(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.stock_overview(uuid, timestamptz, timestamptz) to authenticated, service_role;
