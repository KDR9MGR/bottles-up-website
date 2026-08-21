-- Non-transferable tickets: customer requests a 6-digit email code, door staff
-- verifies it at the door before admitting. Mirrors checkin_ticket()'s
-- SECURITY DEFINER pattern - authorization enforced inside the functions,
-- code hashing/comparison done with pgcrypto (already enabled) so no plaintext
-- code ever touches the database.

alter table public.site_orders
  add column is_non_transferable boolean not null default false,
  add column access_code_verified boolean not null default false,
  add column access_code_verified_at timestamptz;

create table public.ticket_otp_codes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.site_orders(id) on delete cascade,
  code_hash text not null,
  status text not null default 'active' check (status in ('active', 'verified', 'expired')),
  sent_to_email text not null,
  attempts int not null default 0,
  max_attempts int not null default 3,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '5 minutes'),
  verified_at timestamptz,
  verified_by uuid references auth.users(id)
);
create index idx_ticket_otp_codes_order_id on public.ticket_otp_codes(order_id);

alter table public.ticket_otp_codes enable row level security;

-- Only checkin_ticket()/verify_ticket_otp() (SECURITY DEFINER) and the
-- request-ticket-otp edge function (service-role client, bypasses RLS) touch
-- this table. Admins get read access for support/audit purposes.
create policy "admins read otp codes" on public.ticket_otp_codes
  for select using (public.is_cms_admin());

-- Extend the 'requires code, not yet verified' + OTP-specific outcomes.
alter table public.scan_attempts drop constraint scan_attempts_result_check;
alter table public.scan_attempts add constraint scan_attempts_result_check
  check (result in (
    'ok', 'already_checked_in', 'not_paid', 'not_found', 'expired',
    'code_required', 'code_incorrect', 'code_expired', 'no_code_requested'
  ));

-- checkin_ticket(): a non-transferable ticket that hasn't had its access code
-- verified yet reports 'code_required' instead of admitting - the scanner UI
-- then switches to code entry and calls verify_ticket_otp() instead.
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
         o.is_non_transferable, o.access_code_verified,
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

    if v_order.is_non_transferable and not v_order.access_code_verified then
      v_result := 'code_required';
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

-- verify_ticket_otp(): door staff enters the code the customer read out. On a
-- correct, unexpired code this both marks the code verified AND admits the
-- ticket in one step (equivalent to checkin_ticket()'s admit path), since by
-- the time staff ask for the code they've already confirmed everything else.
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

grant execute on function public.verify_ticket_otp(text, text) to authenticated;
