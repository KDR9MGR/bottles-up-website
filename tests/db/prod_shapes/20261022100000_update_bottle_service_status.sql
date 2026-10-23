-- Production-only shape for 20261022100000_order_accepted_stage.sql: public.update_bottle_service_status(uuid, text), the website's own staff function (door staff and
-- BottlesUp admins) that changes a bottle line's service status. It was made by hand in production and is in no committed migration. This is its definition exactly as
-- production reported it (read-only query on 20 Oct 2026); the migration replaces it, guarded by a compare-and-swap on this text, so the order "Accepted" stage works
-- from the website's staff pages too.
create or replace function public.update_bottle_service_status(p_bottle_line_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_line record;
  v_actor_email text;
begin
  if not (public.is_cms_admin() or public.is_door_staff()) then
    raise exception 'not authorized';
  end if;
  if p_status not in ('awaiting_prep', 'preparing', 'ready', 'picked_up', 'served') then
    raise exception 'invalid status';
  end if;

  select id, payment_status, booking_id into v_line
  from public.site_table_booking_bottles
  where id = p_bottle_line_id
  for update;

  if not found then
    raise exception 'bottle line not found';
  end if;
  -- pending_payment = an online payment attempt still in flight, might never
  -- complete - "once payment is verified" excludes exactly this state, but
  -- never due_at_venue, which is already a real, committed order.
  if v_line.payment_status = 'pending_payment' then
    raise exception 'payment not yet verified for this item';
  end if;

  if p_status = 'served' and v_line.payment_status = 'due_at_venue' then
    if not exists (
      select 1 from public.site_table_bookings b
      where b.id = v_line.booking_id and greatest(b.amount_total_cents - b.amount_paid_cents, 0) = 0
    ) then
      raise exception 'cannot mark served - this table still has a balance due at the venue';
    end if;
    if not exists (
      select 1 from public.site_table_booking_club_payments cp
      where cp.booking_id = v_line.booking_id and cp.receipt_photo_path is not null
    ) then
      raise exception 'cannot mark served - no verified POS receipt has been recorded for this table';
    end if;
  end if;

  update public.site_table_booking_bottles set service_status = p_status where id = p_bottle_line_id;

  select coalesce(
    (select email from public.cms_admins where id = auth.uid()),
    (select email from public.door_staff where id = auth.uid()),
    'unknown'
  ) into v_actor_email;

  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (
    auth.uid(), v_actor_email, 'table_booking.bottle_service_status_updated',
    'site_table_booking_bottles', p_bottle_line_id,
    jsonb_build_object('booking_id', v_line.booking_id, 'new_status', p_status)
  );

  return jsonb_build_object('success', true, 'status', p_status);
end;
$function$;
