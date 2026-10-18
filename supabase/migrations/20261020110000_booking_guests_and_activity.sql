-- A booking's Guests and Activity (developer brief 15 Oct, section 14: "Tables & Bookings > Night > Booking. Tabs: Overview | Orders | Payments | Guests |
-- Activity"; "guest allowance", "check-in status, changes and cancellations"; section 19: "Retain failed, refunded and adjusted transactions ... without deleting history").
--
--   * desk_booking_guests(booking)     who is on the booking: the holder and each invited guest ticket (name, whether the ticket was e-mailed,
--                                      whether they are in), the party size, the table's guest limit and how many more guests can be invited.
--                                      The manager or owner of the club, and the server who was given the table. NEVER an e-mail address or phone.
--   * desk_booking_activity(booking)   what happened to the booking, newest first: payments recorded, verified, flagged and resolved, bottle service
--                                      moves, seating and estimates, server changes, and every scan at the door. Manager or owner of the club only.
--                                      Staff are named by profile name ("Staff member" when they have none), never by e-mail; only a fixed list of
--                                      detail fields is passed on (amounts, methods, statuses, reasons), never a whole audit record.
--
-- Both are read only. Both answer "not allowed" for a booking that does not exist or belongs to another club, so a stranger cannot learn which
-- ids exist. Plain CREATE FUNCTION. Needs the server desk and payments (20261014*), cash and flags (20261018100000), seating (20261018110000)
-- and guest tickets (20260923100000) migrations.

create function public.desk_booking_guests(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
  b record;
  v_guests jsonb;
  v_issued int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_level := public.desk_booking_level(p_booking);
  if v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;

  select bk.customer_name, bk.guest_count, bk.checked_in_at, coalesce(tt.max_guests, bk.guest_count) as max_guests, tt.name as table_name
    into b
    from public.site_table_bookings bk
    join public.site_table_types tt on tt.id = bk.table_type_id
   where bk.id = p_booking;
  if not found then raise exception 'not allowed'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', g.id, 'name', g.guest_name, 'ticket_sent', g.ticket_sent_at is not null, 'checked_in_at', g.checked_in_at
         ) order by g.created_at, g.id), '[]'::jsonb), count(*)::int
    into v_guests, v_issued
    from public.guest_tickets g
   where g.booking_id = p_booking;

  return jsonb_build_object(
    'holder_name', b.customer_name,
    'holder_checked_in_at', b.checked_in_at,
    'party_size', b.guest_count,
    'max_guests', b.max_guests,
    'table_name', b.table_name,
    'guests', v_guests,
    'guests_issued', v_issued,
    'guests_in', (select count(*)::int from jsonb_array_elements(v_guests) x where x ->> 'checked_in_at' is not null),
    -- the same rule the guest ticket function uses: the holder plus the invited guests fit the table's guest limit
    'guests_left', greatest(b.max_guests - 1 - v_issued, 0)
  );
end;
$$;

create function public.desk_booking_activity(p_booking uuid, p_limit int default 100)
returns table (at timestamptz, kind text, action text, actor text, details jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 200);
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_booking_level(p_booking) is distinct from 'manager' then raise exception 'not allowed'; end if;

  return query
  with pay as (select p.id from public.site_table_booking_club_payments p where p.booking_id = p_booking),
       line as (select l.id from public.site_table_booking_bottles l where l.booking_id = p_booking),
       flag as (select f.id from public.site_payment_flags f where f.payment_id in (select id from pay)),
  events as (
    select a.created_at as at, 'audit'::text as kind, a.action as action, a.actor_id as actor_id,
           (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
              from jsonb_each(coalesce(a.details, '{}'::jsonb)) as d(k, v)
             where k in ('amount_paid_cents', 'billed_amount_cents', 'payment_method', 'old_status', 'new_status', 'reason',
                         'estimate_minutes', 'from_minutes', 'to_minutes', 'method', 'recorded_as', 'resolution')) as details
      from public.audit_log a
     where (a.entity_type = 'site_table_bookings' and a.entity_id = p_booking::text)
        or (a.entity_type = 'site_table_booking_bottles' and a.entity_id in (select id::text from line))
        or (a.entity_type = 'site_table_booking_club_payments' and a.entity_id in (select id::text from pay))
        or (a.entity_type = 'site_payment_flags' and a.entity_id in (select id::text from flag))
    union all
    select s.created_at, 'scan', 'scan.' || s.result, s.scanned_by,
           jsonb_build_object('guest', s.guest_ticket_id is not null)
      from public.scan_attempts s
     where s.booking_id = p_booking
  )
  select e.at, e.kind, e.action,
         case when e.actor_id is null then 'Staff member' else coalesce(nullif(btrim(pr.name), ''), 'Staff member') end,
         e.details
    from events e
    left join public.profiles pr on pr.id = e.actor_id
   order by e.at desc, e.action
   limit v_limit;
end;
$$;

revoke all on function public.desk_booking_guests(uuid), public.desk_booking_activity(uuid, int) from public, anon;
grant execute on function public.desk_booking_guests(uuid), public.desk_booking_activity(uuid, int) to authenticated, service_role;
