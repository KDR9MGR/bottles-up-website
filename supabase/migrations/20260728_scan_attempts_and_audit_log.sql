-- Scan-attempt logging (every checkin_ticket() call, not just successful ones)
-- and a basic admin audit log, for CMS Dashboard v1.

create table public.scan_attempts (
  id uuid primary key default gen_random_uuid(),
  ticket_code_attempted text not null,
  result text not null check (result in ('ok', 'already_checked_in', 'not_paid', 'not_found')),
  order_id uuid references public.site_orders(id),
  scanned_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.scan_attempts enable row level security;

create policy "admins read scan attempts" on public.scan_attempts
  for select using (public.is_cms_admin());
-- no insert policy for direct client access - only checkin_ticket() (SECURITY DEFINER) writes here.

create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id),
  actor_email text not null,
  action text not null,
  entity_type text not null,
  entity_id text,
  details jsonb,
  created_at timestamptz not null default now()
);
alter table public.audit_log enable row level security;

create policy "admins read audit log" on public.audit_log
  for select using (public.is_cms_admin());
create policy "admins write own audit log" on public.audit_log
  for insert with check (public.is_cms_admin() and actor_id = auth.uid());
-- edge functions (manage-door-staff, resend-ticket-email) insert via the service-role
-- client, which bypasses RLS entirely - no policy needed for those.

-- Extend checkin_ticket() to log one scan_attempts row per call, for every outcome.
create or replace function public.checkin_ticket(p_ticket_code text)
returns table(result text, customer_name text, event_title text, tier_name text, quantity int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_result text;
begin
  if not (public.is_cms_admin() or public.is_door_staff()) then
    raise exception 'not authorized';
  end if;

  select o.id, o.status, o.checked_in_at, o.customer_name, o.quantity,
         e.title as event_title, t.name as tier_name
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
    update public.site_orders set checked_in_at = now(), checked_in_by = auth.uid() where id = v_order.id;
    v_result := 'ok';
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      values (p_ticket_code, v_result, v_order.id, auth.uid());
    return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
  end if;
end;
$$;
