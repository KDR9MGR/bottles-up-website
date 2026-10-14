-- Service requests: a table asks for water, ice, a question about the order or the bill, and the staff deal with it.
--
-- Client Phase 2 brief, section 17: "Server Requests -> Open -> Acknowledge -> Complete or Escalate. Request card: table, type, request
-- source, time, assigned staff and status. Types include server assistance, water/ice/mixers, order question, bill request and table
-- issue. Statuses: New, Acknowledged, In progress, Completed, Escalated/Cancelled. Manager can reassign." Section 14 adds that several
-- staff must not claim the same work by accident and repeated taps must not create a second one.
--
-- WHO: a server, the manager of the club or the owner of the business. A server sees the requests of their own tables and of tables
-- nobody has been given (so nothing is lost), never another server's. A manager or owner sees and handles every request of the club.
--
-- WHAT HAPPENS:
--   * Staff log a request for a paid booking (create_service_request). It goes to the table's server if the booking has one.
--     Asking again for the same thing while it is still open returns the same request instead of making another (the database
--     enforces this with a unique index, so two taps at once cannot both succeed).
--   * One function moves a request along (update_service_request): acknowledge, start, complete, escalate to a manager, cancel
--     (both of the last two need a reason), and a manager can hand it to someone else. The first server to acknowledge owns it; a
--     second one is told someone else has it. Doing the same thing twice is not an error: it changes nothing.
--   * Every change is attributed in audit_log.
--
-- NOT HERE YET: requests made by the guest themselves from the customer app (the column `source` allows 'guest' for that; nothing
-- creates one yet), and billing for a charged item (that goes through an order, never silently through a request).
--
-- Built only on columns the committed migrations define. Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. The requests
-- ---------------------------------------------------------------------------
create table public.site_service_requests (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  booking_id uuid not null references public.site_table_bookings (id) on delete cascade,
  kind text not null check (kind in ('assistance', 'water_ice_mixers', 'order_question', 'bill_request', 'table_issue')),
  note text check (note is null or char_length(note) <= 300),
  source text not null default 'staff' check (source in ('staff', 'guest')),
  status text not null default 'new' check (status in ('new', 'acknowledged', 'in_progress', 'completed', 'escalated', 'cancelled')),
  assigned_membership_id uuid references public.site_memberships (id) on delete set null,
  -- Why it was escalated, cancelled or completed with a remark: the last such note.
  status_note text check (status_note is null or char_length(status_note) <= 300),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  closed_at timestamptz,
  updated_at timestamptz not null default now(),
  -- A closed request has a closing time and an open one does not.
  constraint site_service_requests_closed_check check ((status in ('completed', 'cancelled')) = (closed_at is not null))
);
create index site_service_requests_venue_idx on public.site_service_requests (venue_id, status);
create index site_service_requests_booking_idx on public.site_service_requests (booking_id);
-- Asking for the same thing twice while it is open is one request.
create unique index site_service_requests_one_open_per_kind on public.site_service_requests (booking_id, kind)
  where status in ('new', 'acknowledged', 'in_progress', 'escalated');

alter table public.site_service_requests enable row level security;
revoke all on table public.site_service_requests from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (not callable by the app)
-- ---------------------------------------------------------------------------
-- 'manager' (manager of the club, or owner of the business), 'server', or null.
create function public.desk_level(p_venue uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when public.can_access_venue(p_venue, array['manager', 'owner']) then 'manager'
    when public.can_access_venue(p_venue, array['server']) then 'server'
  end
$$;

-- The caller's own membership to record against a request they take: their server role at the club first, then manager, then owner.
create function public.desk_membership(p_venue uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select m.id
  from public.active_memberships() m
  left join public.site_venues v on v.id = p_venue
  where (m.role in ('server', 'manager') and m.venue_id = p_venue) or (m.role = 'owner' and v.org_id = m.org_id)
  order by case m.role when 'server' then 0 when 'manager' then 1 else 2 end
  limit 1
$$;

-- Can this membership take work at this club in one of these roles? null when it can, otherwise why not.
create function public.desk_staff_problem(p_membership uuid, p_venue uuid, p_roles text[])
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.site_memberships;
begin
  select * into m from public.site_memberships where id = p_membership;
  if not found or m.role <> all (p_roles) or m.venue_id is distinct from p_venue
     or m.org_id is distinct from (select v.org_id from public.site_venues v where v.id = p_venue) then
    return 'not_staff';
  end if;
  if m.status <> 'active'
     or (m.access_end_at is not null and m.access_end_at < now())
     or exists (select 1 from public.site_shifts s where s.id = m.shift_id and s.ends_at < now()) then
    return 'no_access';
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Asking
-- ---------------------------------------------------------------------------
create function public.create_service_request(p_booking uuid, p_kind text, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_level text;
  v_status text;
  v_server uuid;
  v_note text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_venue := public.booking_venue(p_booking);
  if v_venue is null then raise exception 'not allowed'; end if;
  v_level := public.desk_level(v_venue);
  if v_level is null then raise exception 'not allowed'; end if;

  if p_kind is null or p_kind not in ('assistance', 'water_ice_mixers', 'order_question', 'bill_request', 'table_issue') then
    raise exception 'choose what the table needs';
  end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 300 then raise exception 'keep the note to 300 characters or fewer'; end if;

  select b.status into v_status from public.site_table_bookings b where b.id = p_booking;
  if v_status is distinct from 'paid' then raise exception 'only a paid booking can have service requests'; end if;

  select a.membership_id into v_server from public.site_booking_servers a where a.booking_id = p_booking;
  if v_level = 'server' and v_server is not null and v_server not in (select m.id from public.active_memberships() m) then
    raise exception 'this table belongs to another server';
  end if;

  insert into public.site_service_requests (venue_id, booking_id, kind, note, source, assigned_membership_id, created_by)
  values (v_venue, p_booking, p_kind, v_note, 'staff', v_server, auth.uid())
  on conflict (booking_id, kind) where status in ('new', 'acknowledged', 'in_progress', 'escalated') do nothing
  returning id into v_id;

  if v_id is null then
    -- Already asked for and still open: that is the request.
    select r.id into v_id from public.site_service_requests r
      where r.booking_id = p_booking and r.kind = p_kind and r.status in ('new', 'acknowledged', 'in_progress', 'escalated');
    return v_id;
  end if;

  perform public.desk_log('service_request.created', 'site_service_requests', v_id,
    jsonb_build_object('venue_id', v_venue, 'booking_id', p_booking, 'kind', p_kind));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Reading
-- ---------------------------------------------------------------------------
-- Open requests oldest first (the longest wait on top), then, if asked for, those closed in the last 24 hours, newest first. At most
-- 300. A server gets their own tables' requests and those of tables nobody has; a manager or owner gets all of the club's.
create function public.list_service_requests(p_venue uuid, p_include_closed boolean default false)
returns table (
  request_id uuid, booking_id uuid, confirmation_code text, customer_name text, table_name text, guest_count int,
  kind text, note text, source text, status text, assigned_membership_id uuid, assigned_to_me boolean,
  created_at timestamptz, acknowledged_at timestamptz, closed_at timestamptz, status_note text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_level := public.desk_level(p_venue);
  if v_level is null then raise exception 'not allowed'; end if;

  return query
    select r.id, r.booking_id, b.confirmation_code, b.customer_name, t.name, b.guest_count,
           r.kind, r.note, r.source, r.status, r.assigned_membership_id,
           coalesce(r.assigned_membership_id in (select m.id from public.active_memberships() m), false),
           r.created_at, r.acknowledged_at, r.closed_at, r.status_note
    from public.site_service_requests r
    join public.site_table_bookings b on b.id = r.booking_id
    join public.site_table_types t on t.id = b.table_type_id
    left join public.site_booking_servers bs on bs.booking_id = r.booking_id
    where r.venue_id = p_venue
      and (r.status not in ('completed', 'cancelled') or (p_include_closed and r.closed_at > now() - interval '24 hours'))
      and (
        v_level = 'manager'
        or coalesce(r.assigned_membership_id, bs.membership_id) is null
        or coalesce(r.assigned_membership_id, bs.membership_id) in (select m.id from public.active_memberships() m)
      )
    order by (r.status in ('completed', 'cancelled')),
             (case when r.status not in ('completed', 'cancelled') then r.created_at end),
             (case when r.status in ('completed', 'cancelled') then r.closed_at end) desc,
             r.id
    limit 300;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Moving a request along
-- ---------------------------------------------------------------------------
-- p_action: acknowledge | start | complete | escalate | cancel | reassign.   p_note: required to escalate or cancel, optional
-- otherwise (up to 300 characters).   p_assignee: the membership to hand it to (reassign only).
create function public.update_service_request(p_request uuid, p_action text, p_note text default null, p_assignee uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_level text;
  v_req public.site_service_requests;
  v_server uuid;
  v_handler uuid;
  v_mine boolean;
  v_free boolean;
  v_me uuid;
  v_to text;
  v_note text;
  v_problem text;
  v_log text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_action is null or p_action not in ('acknowledge', 'start', 'complete', 'escalate', 'cancel', 'reassign') then
    raise exception 'unknown action';
  end if;

  select r.venue_id into v_venue from public.site_service_requests r where r.id = p_request;
  if v_venue is null then raise exception 'not allowed'; end if;
  v_level := public.desk_level(v_venue);
  if v_level is null then raise exception 'not allowed'; end if;

  -- Lock the request: two servers pressing Acknowledge together are served one after the other, and the second sees the first.
  select * into v_req from public.site_service_requests where id = p_request for update;
  if not found then raise exception 'not allowed'; end if;

  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 300 then raise exception 'keep the note to 300 characters or fewer'; end if;

  select a.membership_id into v_server from public.site_booking_servers a where a.booking_id = v_req.booking_id;
  v_handler := coalesce(v_req.assigned_membership_id, v_server);
  v_mine := v_handler is not null and v_handler in (select m.id from public.active_memberships() m);
  v_free := v_handler is null;
  v_me := public.desk_membership(v_venue);

  v_to := case p_action
    when 'acknowledge' then 'acknowledged' when 'start' then 'in_progress' when 'complete' then 'completed'
    when 'escalate' then 'escalated' when 'cancel' then 'cancelled' end;

  -- Doing again what was already done is not an error: a repeated tap changes nothing and records nothing.
  if v_to is not null and v_req.status = v_to and (v_level = 'manager' or v_mine) then return; end if;

  if v_req.status in ('completed', 'cancelled') then raise exception 'this request is already closed'; end if;

  -------------------------------------------------------------- handing it to someone else (managers only)
  if p_action = 'reassign' then
    if v_level <> 'manager' then raise exception 'only a manager can hand a request to someone else'; end if;
    v_problem := case when p_assignee is null then 'not_staff'
                      else public.desk_staff_problem(p_assignee, v_venue, array['server', 'manager']) end;
    if v_problem = 'not_staff' then raise exception 'that person is not staff at this club'; end if;
    if v_problem = 'no_access' then raise exception 'that person no longer has access to this club'; end if;
    -- The new person has to take it themselves, so it goes back to New.
    update public.site_service_requests
      set assigned_membership_id = p_assignee, status = 'new', acknowledged_at = null, updated_at = now()
      where id = p_request;
    perform public.desk_log('service_request.reassigned', 'site_service_requests', p_request,
      jsonb_build_object('venue_id', v_venue, 'booking_id', v_req.booking_id, 'from_membership', v_req.assigned_membership_id,
                         'to_membership', p_assignee, 'from_status', v_req.status));
    return;
  end if;

  -------------------------------------------------------------- who may act
  if v_req.status = 'escalated' and v_level <> 'manager' then raise exception 'this request was passed to a manager'; end if;
  if not (v_level = 'manager' or v_mine or v_free) then
    raise exception '%', case when v_req.status = 'new' then 'this request belongs to another server'
                              else 'someone else has already taken this request' end;
  end if;

  -------------------------------------------------------------- which moves are possible from here
  if p_action = 'acknowledge' then
    if v_req.status not in ('new', 'escalated') then
      raise exception '%', case when v_mine then 'you have already taken this request' else 'someone else has already taken this request' end;
    end if;
    update public.site_service_requests
      set status = 'acknowledged', assigned_membership_id = v_me, acknowledged_at = now(), updated_at = now()
      where id = p_request;
    v_log := 'service_request.acknowledged';

  elsif p_action = 'start' then
    if v_req.status <> 'acknowledged' then raise exception 'acknowledge the request first'; end if;
    update public.site_service_requests set status = 'in_progress', updated_at = now() where id = p_request;
    v_log := 'service_request.started';

  elsif p_action = 'complete' then
    -- Completing a New request takes it too: whoever does the work owns it.
    update public.site_service_requests
      set status = 'completed', closed_at = now(), updated_at = now(),
          status_note = coalesce(v_note, status_note),
          assigned_membership_id = case when v_req.status in ('new', 'escalated') then v_me else assigned_membership_id end,
          acknowledged_at = coalesce(acknowledged_at, now())
      where id = p_request;
    v_log := 'service_request.completed';

  elsif p_action = 'escalate' then
    if v_note is null then raise exception 'say why you are passing this request to a manager'; end if;
    update public.site_service_requests
      set status = 'escalated', status_note = v_note, updated_at = now(),
          assigned_membership_id = coalesce(assigned_membership_id, v_me)
      where id = p_request;
    v_log := 'service_request.escalated';

  else  -- cancel
    if v_note is null then raise exception 'say why this request is being cancelled'; end if;
    update public.site_service_requests
      set status = 'cancelled', closed_at = now(), status_note = v_note, updated_at = now(),
          assigned_membership_id = coalesce(assigned_membership_id, v_me)
      where id = p_request;
    v_log := 'service_request.cancelled';
  end if;

  perform public.desk_log(v_log, 'site_service_requests', p_request,
    jsonb_build_object('venue_id', v_venue, 'booking_id', v_req.booking_id, 'kind', v_req.kind, 'from_status', v_req.status, 'to_status', v_to));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.desk_level(uuid), public.desk_membership(uuid), public.desk_staff_problem(uuid, uuid, text[])
  from public, anon, authenticated;

revoke all on function
  public.create_service_request(uuid, text, text), public.list_service_requests(uuid, boolean),
  public.update_service_request(uuid, text, text, uuid)
  from public, anon;
grant execute on function
  public.create_service_request(uuid, text, text), public.list_service_requests(uuid, boolean),
  public.update_service_request(uuid, text, text, uuid)
  to authenticated, service_role;
