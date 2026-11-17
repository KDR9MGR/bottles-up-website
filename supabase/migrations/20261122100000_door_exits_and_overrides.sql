-- Door: exits and live occupancy, and controlled overrides (client Phase 2 brief, section 18: "Controlled overrides require reason and authorized role" and "Track exits if
-- displaying live occupancy; otherwise label Total Checked In").
--
-- WHAT THIS ADDS (everything is new; no live function or table is replaced, door_admit_group() and the scanners stay exactly as they are):
--   * site_events.track_exits        off by default. An owner, organizer or the club's manager turns it on for an event; only then does the door record exits and show "Inside now".
--   * site_order_exits               one row per exit (order, guests, who, when). A closed table, like site_order_admissions.
--   * door_record_exit(code, count, event)   a door person records guests leaving. Refused unless the event tracks exits; never more than are inside. Anyone who is inside can be counted out
--                                    whatever the order's status is now (a guest admitted and refunded afterwards is still in the room).
--   * door_occupancy(event)          admitted, exited and inside now, and whether exits are tracked (door people who cover the event, and those who may manage it).
--   * door_override_entry(code, reason, count, event)   admits a guest the scan held back ONLY because of the entry code (a non-transferable ticket whose code was not verified), by
--                                    someone who may manage the event, with a written reason that is kept. Everything else a scan refuses stays refused: unpaid, refunded, ended,
--                                    wrong event, fully in already. The answer is decided HERE from the order, never from anything the app says.
--   * door_override_log(event)       who overrode what and why, for those who may manage the event.
--   * set_event_exit_tracking(event, on)
--   * door_club_nights(club)         the club's nights that are on now or just ended, with exit tracking and occupancy, for the owner and the manager (they have no door role, so no door_events()).
--
-- WHO MAY OVERRIDE (a policy assumption, easy to change in can_manage_door() below): the owner or an organizer of the organization that owns the event, or the owner or manager of the
-- club the event is linked to. Door staff cannot override: they ask a manager.
--
-- NOT DONE ON PURPOSE: RE-ENTRY. After a guest exits, their ticket still counts as used, so the door will not admit them again. The brief says re-entry "must follow event settings"; the
-- client has not said what the setting is. Until then an exit only lowers "Inside now".
--
-- Plain CREATE, never CREATE OR REPLACE. Needs the group admission migration (20261020170000) and the door scanner (20261009100000).

-- ---------------------------------------------------------------------------
-- 1. Tables and the event setting
-- ---------------------------------------------------------------------------
alter table public.site_events add column if not exists track_exits boolean not null default false;

create table public.site_order_exits (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.site_orders (id) on delete cascade,
  guests int not null check (guests > 0),
  exited_by uuid references auth.users (id) on delete set null,
  exited_at timestamptz not null default now()
);
create index site_order_exits_order_idx on public.site_order_exits (order_id);
alter table public.site_order_exits enable row level security;
revoke all on table public.site_order_exits from public, anon, authenticated;

create table public.site_door_overrides (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.site_orders (id) on delete cascade,
  event_id uuid not null references public.site_events (id) on delete cascade,
  reason text not null check (char_length(reason) between 5 and 300),
  previous_result text not null,
  guests int not null check (guests > 0),
  overridden_by uuid references auth.users (id) on delete set null,
  overridden_at timestamptz not null default now()
);
create index site_door_overrides_event_idx on public.site_door_overrides (event_id, overridden_at desc);
alter table public.site_door_overrides enable row level security;
revoke all on table public.site_door_overrides from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Who may manage an event's door
-- ---------------------------------------------------------------------------
create function public.can_manage_door(p_event uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_event is not null and (
    public.can_access_event(p_event, array['owner', 'organizer'])
    or exists (
      select 1 from public.site_events e
      where e.id = p_event and e.venue_id is not null and public.can_access_venue(e.venue_id, array['owner', 'manager'])
    )
  )
$$;

create function public.set_event_exit_tracking(p_event uuid, p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.can_manage_door(p_event) then raise exception 'not authorized'; end if;
  if p_on is null then raise exception 'say whether exits are tracked'; end if;
  update public.site_events set track_exits = p_on where id = p_event;
  return p_on;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Exits and live occupancy
-- ---------------------------------------------------------------------------
-- Guests in, per order, the way door_admit_group() counts them: admission rows, or the whole order when an older scanner checked it in.
create function public.door_order_in(p_order uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select case
           when exists (select 1 from public.site_order_admissions a where a.order_id = o.id)
             then (select sum(a.guests) from public.site_order_admissions a where a.order_id = o.id)::int
           when o.checked_in_at is not null then o.quantity
           else 0
         end
  from public.site_orders o where o.id = p_order
$$;

create function public.door_record_exit(p_ticket_code text, p_count int default 1, p_event uuid default null)
returns table (result text, customer_name text, quantity int, admitted int, exited int, inside int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := left(trim(coalesce(p_ticket_code, '')), 200);
  v_event uuid;
  v_order record;
  v_in int;
  v_out int;
  v_inside int;
begin
  if auth.uid() is null or not public.has_door_role() then raise exception 'not authorized'; end if;
  if p_count is null or p_count < 1 then raise exception 'choose how many are leaving'; end if;

  select o.event_id into v_event from public.site_orders o where o.ticket_code = v_code;
  if not found then
    return query select 'not_found', null::text, null::int, null::int, null::int, null::int;
    return;
  end if;
  -- Scope is decided before anything about the guest is read, as in door_scan_ticket().
  if not public.can_scan_event(v_event) or (p_event is not null and v_event <> p_event) then
    return query select 'wrong_event', null::text, null::int, null::int, null::int, null::int;
    return;
  end if;
  if not (select e.track_exits from public.site_events e where e.id = v_event) then
    return query select 'not_tracking', null::text, null::int, null::int, null::int, null::int;
    return;
  end if;

  select o.id as order_id, o.status, o.customer_name as customer, o.quantity as guests into v_order
    from public.site_orders o where o.ticket_code = v_code for update of o;
  v_in := coalesce(public.door_order_in(v_order.order_id), 0);
  v_out := coalesce((select sum(x.guests) from public.site_order_exits x where x.order_id = v_order.order_id), 0)::int;
  v_inside := greatest(v_in - v_out, 0);

  -- Whoever is inside can leave, whatever the order's status is now: a guest admitted and refunded afterwards is still in the room and has to be counted out. (Nobody who was never admitted has anything inside.)
  if v_inside = 0 then
    return query select 'nothing_inside', v_order.customer, v_order.guests, v_in, v_out, v_inside;
    return;
  end if;
  if p_count > v_inside then
    return query select 'too_many', v_order.customer, v_order.guests, v_in, v_out, v_inside;
    return;
  end if;

  insert into public.site_order_exits (order_id, guests, exited_by) values (v_order.order_id, p_count, auth.uid());
  return query select 'ok', v_order.customer, v_order.guests, v_in, v_out + p_count, v_inside - p_count;
end;
$$;

create function public.door_occupancy(p_event uuid)
returns table (tracking boolean, admitted int, exited int, inside int)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_admitted int;
  v_exited int;
  v_tracking boolean;
begin
  if auth.uid() is null or p_event is null then raise exception 'not authorized'; end if;
  if not ((public.has_door_role() and public.can_scan_event(p_event)) or public.can_manage_door(p_event)) then raise exception 'not authorized'; end if;

  select e.track_exits into v_tracking from public.site_events e where e.id = p_event;
  select coalesce(sum(public.door_order_in(o.id)), 0)::int into v_admitted from public.site_orders o where o.event_id = p_event and o.status = 'paid';
  select coalesce(sum(x.guests), 0)::int into v_exited
    from public.site_order_exits x join public.site_orders o on o.id = x.order_id where o.event_id = p_event and o.status = 'paid';
  return query select coalesce(v_tracking, false), v_admitted, v_exited, greatest(v_admitted - v_exited, 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Controlled override
-- ---------------------------------------------------------------------------
create function public.door_override_entry(p_ticket_code text, p_reason text, p_count int default null, p_event uuid default null)
returns table (result text, customer_name text, event_title text, tier_name text, quantity int, admitted int, remaining int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := left(trim(coalesce(p_ticket_code, '')), 200);
  v_reason text := btrim(coalesce(p_reason, ''));
  v_event uuid;
  v_order record;
  v_in int;
  v_left int;
  v_n int;
  v_end timestamptz;
begin
  if auth.uid() is null then raise exception 'not authorized'; end if;
  if char_length(v_reason) < 5 or char_length(v_reason) > 300 then raise exception 'give a reason of 5 to 300 characters'; end if;

  select o.event_id into v_event from public.site_orders o where o.ticket_code = v_code;
  if not found then
    -- Only someone who may manage some event learns that a code is unknown; everyone else is simply not authorized.
    if not exists (select 1 from public.active_memberships() m where m.role in ('owner', 'manager', 'organizer')) then raise exception 'not authorized'; end if;
    return query select 'not_found', null::text, null::text, null::text, null::int, null::int, null::int;
    return;
  end if;
  if not public.can_manage_door(v_event) then raise exception 'not authorized'; end if;
  if p_event is not null and v_event <> p_event then
    return query select 'wrong_event', null::text, null::text, null::text, null::int, null::int, null::int;
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

  v_in := coalesce(public.door_order_in(v_order.order_id), 0);
  v_left := greatest(v_order.guests - v_in, 0);

  -- Everything except the entry code stays refused, whoever asks.
  if v_order.status <> 'paid' then
    return query select case when v_order.status = 'refunded' then 'refunded' else 'not_paid' end, v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, v_left;
    return;
  end if;
  if v_left = 0 then
    return query select 'already_checked_in', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, 0;
    return;
  end if;
  v_end := coalesce(v_order.end_date, v_order.start_date + interval '12 hours');
  if now() > v_end then
    return query select 'expired', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, v_left;
    return;
  end if;
  if not (v_order.is_non_transferable and not v_order.access_code_verified) then
    -- Nothing is holding this ticket back: a normal scan admits it, so there is nothing to override.
    return query select 'no_override_needed', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in, v_left;
    return;
  end if;

  if p_count is null then
    if v_order.guests > 1 then
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
  insert into public.site_door_overrides (order_id, event_id, reason, previous_result, guests, overridden_by)
    values (v_order.order_id, v_event, v_reason, 'code_required', v_n, auth.uid());
  insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'ok', v_order.order_id, auth.uid());
  return query select 'ok', v_order.customer, v_order.event_title, v_order.tier_name, v_order.guests, v_in + v_n, v_left - v_n;
end;
$$;

create function public.door_override_log(p_event uuid)
returns table (overridden_at timestamptz, customer_name text, guests int, reason text, by_me boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.can_manage_door(p_event) then raise exception 'not authorized'; end if;
  return query
    select d.overridden_at, o.customer_name, d.guests, d.reason, d.overridden_by = auth.uid()
      from public.site_door_overrides d join public.site_orders o on o.id = d.order_id
     where d.event_id = p_event
     order by d.overridden_at desc, d.id
     limit 100;
end;
$$;

-- The club's nights for the owner and the manager: published events of the club that start within a day or ended less than 12 hours ago.
create function public.door_club_nights(p_venue uuid)
returns table (event_id uuid, title text, start_date timestamptz, end_date timestamptz, track_exits boolean, admitted int, exited int, inside int)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not authorized'; end if;
  return query
    select e.id, e.title, e.start_date, e.end_date, e.track_exits,
           coalesce((select sum(public.door_order_in(o.id)) from public.site_orders o where o.event_id = e.id and o.status = 'paid'), 0)::int,
           coalesce((select sum(x.guests) from public.site_order_exits x join public.site_orders o on o.id = x.order_id where o.event_id = e.id and o.status = 'paid'), 0)::int,
           greatest(coalesce((select sum(public.door_order_in(o.id)) from public.site_orders o where o.event_id = e.id and o.status = 'paid'), 0)
                    - coalesce((select sum(x.guests) from public.site_order_exits x join public.site_orders o on o.id = x.order_id where o.event_id = e.id and o.status = 'paid'), 0), 0)::int
      from public.site_events e
     where e.venue_id = p_venue and e.status = 'published'
       and e.start_date < now() + interval '1 day'
       and coalesce(e.end_date, e.start_date + interval '12 hours') > now() - interval '12 hours'
     order by e.start_date, e.id
     limit 20;
end;
$$;

revoke all on function public.can_manage_door(uuid), public.set_event_exit_tracking(uuid, boolean), public.door_order_in(uuid), public.door_record_exit(text, int, uuid),
  public.door_occupancy(uuid), public.door_override_entry(text, text, int, uuid), public.door_override_log(uuid), public.door_club_nights(uuid) from public, anon;
-- door_order_in() is an inside helper: it answers for any order id, so only the other functions (which run with their owner's rights) and the service role may call it.
revoke all on function public.door_order_in(uuid) from authenticated;
grant execute on function public.can_manage_door(uuid), public.set_event_exit_tracking(uuid, boolean), public.door_record_exit(text, int, uuid),
  public.door_occupancy(uuid), public.door_override_entry(text, text, int, uuid), public.door_override_log(uuid), public.door_club_nights(uuid) to authenticated, service_role;
grant execute on function public.door_order_in(uuid) to service_role;
