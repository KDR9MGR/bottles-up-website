-- Group admission at the door (developer brief 15 Oct, section 26: "Distinguish Valid, Already Used, Wrong Event, Cancelled/Refunded, Invalid and Group Admission with
-- remaining allowance"; section 12: "group admission allowances").
--
-- A ticket order can cover several guests (site_orders.quantity). Today one scan admits the WHOLE order at once. A group usually arrives in pieces, so the door needs
-- "2 of 4 are in, 2 may still come". This adds that WITHOUT touching the live scan functions (door_scan_ticket, door_verify_ticket_code and the older check-in functions
-- stay exactly as they are): new functions, and one closed table that records each admission.
--
--   * site_order_admissions            one row per admission: which order, how many guests, who, when (closed table, like the other desk records)
--   * door_admit_group(code, count, event)   the scan. Same scope rules and the same outcomes as door_scan_ticket(), plus:
--        'group'     the ticket covers several guests and nobody chose how many yet: NOTHING is admitted, the answer says how many are in and how many are left
--        'too_many'  more than the allowance that is left: nothing is admitted, the answer says how many are left
--        'refunded'  an order that was refunded (door_scan_ticket says 'not_paid' for it): the brief asks for Cancelled/Refunded to be told apart from unpaid
--      With no count a ticket of ONE guest is admitted at once (a scan is still one scan); a ticket of several guests answers 'group' until the person chooses a count.
--      Every answer carries how many guests the ticket covers, how many are in and how many are left. The order is locked while it is counted, so two doors cannot both
--      admit the last guests. An admission is logged in scan_attempts as 'ok' like any other (that table's allowed results are left as they are).
--   * door_admission_counts(events)    how many guests are really in, per event (a partly admitted group counts only the guests who came in)
--   * door_guest_admissions(event)     how many of each ticket order are in, for the guest list
--
-- WHEN AN ORDER IS "CHECKED IN": the first admission also sets site_orders.checked_in_at (and checked_in_by), exactly as a whole-order scan does, so every other scanner and
-- report treats the order as used and refuses it again (they cannot admit the rest of a group twice). The price of that is that those older screens count the whole order
-- as in after the first admission; door_admission_counts() and door_guest_admissions() are the exact figures, and the vendor app uses them. An order admitted whole by an
-- older scanner (checked in, no admission rows) counts as fully in.
--
-- Needs the scoped door scanner (20261009100000). Plain CREATE: a name collision in the shared database fails loudly.

create table public.site_order_admissions (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.site_orders (id) on delete cascade,
  guests int not null check (guests > 0),
  admitted_by uuid references auth.users (id) on delete set null,
  admitted_at timestamptz not null default now()
);
create index site_order_admissions_order_idx on public.site_order_admissions (order_id);
alter table public.site_order_admissions enable row level security;
revoke all on table public.site_order_admissions from public, anon, authenticated;

create function public.door_admit_group(p_ticket_code text, p_count int default null, p_event uuid default null)
returns table (result text, customer_name text, event_title text, tier_name text, quantity int, admitted int, remaining int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := left(trim(coalesce(p_ticket_code, '')), 200);
  v_event uuid;
  v_title text;
  v_covered boolean;
  v_order record;
  v_end timestamptz;
  v_in int;
  v_left int;
  v_n int;
begin
  if auth.uid() is null or not public.has_door_role() then raise exception 'not authorized'; end if;

  -- Scope is decided before anything about the guest is read, as in door_scan_ticket().
  select o.event_id, e.title into v_event, v_title
  from public.site_orders o join public.site_events e on e.id = o.event_id
  where o.ticket_code = v_code;

  if not found then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'not_found', null, auth.uid());
    return query select 'not_found', null::text, null::text, null::text, null::int, null::int, null::int;
    return;
  end if;

  v_covered := public.can_scan_event(v_event);
  if not v_covered or (p_event is not null and v_event <> p_event) then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      select v_code, 'wrong_event', o.id, auth.uid() from public.site_orders o where o.ticket_code = v_code;
    return query select 'wrong_event', null::text, case when v_covered then v_title end, null::text, null::int, null::int, null::int;
    return;
  end if;

  select o.id as order_id, o.status, o.checked_in_at, o.customer_name as customer, o.quantity as guests, o.is_non_transferable, o.access_code_verified,
         e.title as event_title, e.start_date, e.end_date, t.name as tier_name
  into v_order
  from public.site_orders o
  join public.site_ticket_tiers t on t.id = o.tier_id
  join public.site_events e on e.id = o.event_id
  where o.ticket_code = v_code
  for update of o;

  v_in := coalesce((select sum(a.guests) from public.site_order_admissions a where a.order_id = v_order.order_id), 0)::int;
  if v_in = 0 and v_order.checked_in_at is not null then v_in := v_order.guests; end if;   -- admitted whole by another scanner
  v_left := greatest(v_order.guests - v_in, 0);

  if v_order.status <> 'paid' then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'not_paid', v_order.order_id, auth.uid());
    return query select case when v_order.status = 'refunded' then 'refunded' else 'not_paid' end, v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, v_left;
    return;
  end if;

  if v_left = 0 then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'already_checked_in', v_order.order_id, auth.uid());
    return query select 'already_checked_in', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, 0;
    return;
  end if;

  v_end := coalesce(v_order.end_date, v_order.start_date + interval '12 hours');
  if now() > v_end then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'expired', v_order.order_id, auth.uid());
    return query select 'expired', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, v_left;
    return;
  end if;

  if v_order.is_non_transferable and not v_order.access_code_verified then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'code_required', v_order.order_id, auth.uid());
    return query select 'code_required', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, v_left;
    return;
  end if;

  if p_count is null then
    if v_order.guests > 1 then
      -- A group: nothing is admitted until the person says how many are coming in.
      return query select 'group', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, v_left;
      return;
    end if;
    v_n := 1;
  else
    if p_count < 1 then raise exception 'choose how many are coming in'; end if;
    if p_count > v_left then
      return query select 'too_many', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, v_left;
      return;
    end if;
    v_n := p_count;
  end if;

  insert into public.site_order_admissions (order_id, guests, admitted_by) values (v_order.order_id, v_n, auth.uid());
  update public.site_orders set checked_in_at = coalesce(checked_in_at, now()), checked_in_by = coalesce(checked_in_by, auth.uid()) where id = v_order.order_id;
  insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'ok', v_order.order_id, auth.uid());
  return query select 'ok', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in + v_n, v_left - v_n;
end;
$$;

-- How many guests are really in, for events the caller covers (others are left out, so nothing is learned about an event that is not theirs).
create function public.door_admission_counts(p_events uuid[])
returns table (event_id uuid, guests_admitted int)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_door_role() then raise exception 'not authorized'; end if;
  return query
    select e.id,
           coalesce(sum(case
                          when exists (select 1 from public.site_order_admissions a where a.order_id = o.id)
                            then (select sum(a.guests) from public.site_order_admissions a where a.order_id = o.id)
                          when o.checked_in_at is not null then o.quantity
                          else 0
                        end), 0)::int
      from public.site_events e
      left join public.site_orders o on o.event_id = e.id and o.status = 'paid'
     where e.id = any(coalesce(p_events, '{}'::uuid[])) and public.can_scan_event(e.id)
     group by e.id;
end;
$$;

-- How many guests of each ticket order of an event are in, for the guest list (only orders that have had an admission through door_admit_group).
create function public.door_guest_admissions(p_event uuid)
returns table (order_id uuid, admitted int)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_door_role() then raise exception 'not authorized'; end if;
  if not public.can_scan_event(p_event) then raise exception 'not allowed'; end if;
  return query
    select a.order_id, sum(a.guests)::int
      from public.site_order_admissions a join public.site_orders o on o.id = a.order_id
     where o.event_id = p_event and o.status = 'paid'
     group by a.order_id;
end;
$$;

revoke all on function public.door_admit_group(text, int, uuid), public.door_admission_counts(uuid[]), public.door_guest_admissions(uuid) from public, anon;
grant execute on function public.door_admit_group(text, int, uuid), public.door_admission_counts(uuid[]), public.door_guest_admissions(uuid) to authenticated, service_role;
