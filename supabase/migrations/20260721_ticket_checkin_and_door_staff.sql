-- Ticket redemption tracking, door-staff role, and self-serve ticket recovery.

alter table public.site_orders
  add column checked_in_at timestamptz,
  add column checked_in_by uuid references auth.users(id);

create table public.door_staff (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now()
);
alter table public.door_staff enable row level security;

create or replace function public.is_door_staff()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (select 1 from public.door_staff where id = auth.uid());
$$;

-- staff can see their own membership row (drives the client-side auth check);
-- cms admins manage the roster from a CMS page.
create policy "door staff read own row" on public.door_staff
  for select using (id = auth.uid());
create policy "admins manage door staff" on public.door_staff
  for all using (public.is_cms_admin()) with check (public.is_cms_admin());

-- Lets a buyer who verifies ownership of an email (via Supabase magic-link auth)
-- see every order placed with that email, without adding a user_id column or
-- touching the guest-checkout insert path at all.
create policy "users read own orders by verified email" on public.site_orders
  for select using (auth.role() = 'authenticated' and lower(customer_email) = lower(auth.email()));

-- Atomic check-in: single source of truth for "has this ticket been used".
-- SECURITY DEFINER because door_staff has no direct UPDATE grant on site_orders -
-- authorization is enforced inside the function instead (mirrors is_cms_admin()).
create or replace function public.checkin_ticket(p_ticket_code text)
returns table(result text, customer_name text, event_title text, tier_name text, quantity int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
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
    return query select 'not_found', null::text, null::text, null::text, null::int;
  elsif v_order.status <> 'paid' then
    return query select 'not_paid', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
  elsif v_order.checked_in_at is not null then
    return query select 'already_checked_in', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
  else
    update public.site_orders set checked_in_at = now(), checked_in_by = auth.uid() where id = v_order.id;
    return query select 'ok', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
  end if;
end;
$$;

grant execute on function public.checkin_ticket(text) to authenticated;
