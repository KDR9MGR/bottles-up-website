-- Adds an "expired" outcome to checkin_ticket() for tickets scanned after the
-- event has ended (falls back to start_date + 12h if the event has no
-- end_date set - a reasonable default for a nightlife app running late).
-- Only applies to tickets not already checked in - a ticket that WAS
-- checked in during the valid window still reports as already_checked_in
-- regardless of when someone re-scans it later.

alter table public.scan_attempts drop constraint scan_attempts_result_check;
alter table public.scan_attempts add constraint scan_attempts_result_check
  check (result in ('ok', 'already_checked_in', 'not_paid', 'not_found', 'expired'));

create or replace function public.checkin_ticket(p_ticket_code text)
returns table(result text, customer_name text, event_title text, tier_name text, quantity int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_result text;
  v_effective_end timestamptz;
begin
  if not (public.is_cms_admin() or public.is_door_staff()) then
    raise exception 'not authorized';
  end if;

  select o.id, o.status, o.checked_in_at, o.customer_name, o.quantity,
         e.title as event_title, e.start_date, e.end_date, t.name as tier_name
  into v_order
  from public.site_orders o
  join public.site_ticket_tiers t on t.id = o.tier_id
  join public.site_events e on e.id = o.event_id
  where o.ticket_code = p_ticket_code
  for update of o;

  if not found then
    v_result := 'not_found';
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, null, auth.uid());
    return query select v_result, null::text, null::text, null::text, null::int;
  elsif v_order.status <> 'paid' then
    v_result := 'not_paid';
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, v_order.id, auth.uid());
    return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
  elsif v_order.checked_in_at is not null then
    v_result := 'already_checked_in';
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, v_order.id, auth.uid());
    return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
  else
    v_effective_end := coalesce(v_order.end_date, v_order.start_date + interval '12 hours');
    if now() > v_effective_end then
      v_result := 'expired';
      insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
        values (p_ticket_code, v_result, v_order.id, auth.uid());
      return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
    end if;

    update public.site_orders set checked_in_at = now(), checked_in_by = auth.uid() where id = v_order.id;
    v_result := 'ok';
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, v_order.id, auth.uid());
    return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
  end if;
end;
$$;
