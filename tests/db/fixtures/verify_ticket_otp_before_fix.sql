-- The verify_ticket_otp() that supabase/migrations/20260821_ticket_otp_access_codes.sql defines: the version BEFORE the
-- expiry, ordinary-ticket and missing-code fixes. Tests use it to put a database into the "before" state. Copied verbatim
-- from that migration; do not edit.
create or replace function public.verify_ticket_otp(p_ticket_code text, p_code text)
returns table(result text, customer_name text, event_title text, tier_name text, quantity int, attempts_remaining int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_otp record;
  v_result text;
begin
  if not (public.is_cms_admin() or public.is_door_staff()) then
    raise exception 'not authorized';
  end if;

  select o.id, o.status, o.checked_in_at, o.customer_name, o.quantity,
         o.is_non_transferable, o.access_code_verified,
         e.title as event_title, t.name as tier_name
  into v_order
  from public.site_orders o
  join public.site_ticket_tiers t on t.id = o.tier_id
  join public.site_events e on e.id = o.event_id
  where o.ticket_code = p_ticket_code
  for update of o;

  if not found then
    return query select 'not_found', null::text, null::text, null::text, null::int, null::int;
    return;
  elsif v_order.status <> 'paid' then
    return query select 'not_paid', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  elsif v_order.checked_in_at is not null then
    return query select 'already_checked_in', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  elsif not v_order.is_non_transferable then
    return query select 'ok', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  select * into v_otp
  from public.ticket_otp_codes
  where order_id = v_order.id
  order by created_at desc
  limit 1
  for update;

  if not found or v_otp.status = 'expired' then
    v_result := 'no_code_requested';
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, v_order.id, auth.uid());
    return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  if v_otp.status = 'verified' or now() > v_otp.expires_at then
    if v_otp.status <> 'verified' then
      update public.ticket_otp_codes set status = 'expired' where id = v_otp.id;
    end if;
    v_result := 'code_expired';
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, v_order.id, auth.uid());
    return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  if v_otp.attempts >= v_otp.max_attempts then
    update public.ticket_otp_codes set status = 'expired' where id = v_otp.id;
    v_result := 'code_expired';
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, v_order.id, auth.uid());
    return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  if crypt(p_code, v_otp.code_hash) <> v_otp.code_hash then
    update public.ticket_otp_codes set attempts = attempts + 1 where id = v_otp.id;
    v_result := 'code_incorrect';
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, v_order.id, auth.uid());
    return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity,
      (v_otp.max_attempts - (v_otp.attempts + 1));
    return;
  end if;

  update public.ticket_otp_codes
    set status = 'verified', verified_at = now(), verified_by = auth.uid()
    where id = v_otp.id;
  update public.site_orders
    set access_code_verified = true, access_code_verified_at = now(),
        checked_in_at = now(), checked_in_by = auth.uid()
    where id = v_order.id;

  v_result := 'ok';
  insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
    values (p_ticket_code, v_result, v_order.id, auth.uid());
  return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
end;
$$;
