-- Door scanner for invited door staff, scoped to their own event or club.
--
-- Website brief section 5 (Door: Scan, Guests, Door Sale; "Assigned event -> Scan/search guest -> Check access ->
-- Confirm entry") and client brief section 18. Staff invited through the Team screen hold a 'door' membership
-- scoped to ONE event or to ONE club. This lets them scan tickets for exactly that scope and nothing else.
--
-- Why new functions instead of changing checkin_ticket() / verify_ticket_otp():
--   * Those authorize with is_door_staff(), which is global (any door_staff row works on any event), and widening it
--     would hand every invited door person the whole platform. They are left exactly as they are for existing staff.
--   * The live database may have drifted from the repo; replacing a live function from here could silently change it.
--   * checkin_ticket() has a known fall-through bug (RETURN QUERY does not exit, so an expired or code-protected
--     ticket is also admitted; see supabase/proposed/20260830_fix_checkin_ticket_early_returns.sql). The scoped
--     versions below return after every outcome, so they do not have it.
--
-- Scope: a membership covers an event if it names that event, or names a club and the event is linked to that club
-- (site_events.venue_id). Table-booking check-in is NOT covered here: its functions exist only in production, so they
-- cannot be reviewed or tested from this repository.
--
-- Additive only. Functions use plain CREATE, so a name clash with something already in the live database fails loudly.

-- ---------------------------------------------------------------------------
-- Events linked to a club
-- ---------------------------------------------------------------------------
-- Production already has this column (the CMS event form sets it) but no migration in this repository adds it, so a
-- fresh database would not have it. `if not exists` makes this a no-op where it is already there.
alter table public.site_events
  add column if not exists venue_id uuid references public.site_venues (id) on delete set null;
create index if not exists site_events_venue_id_idx on public.site_events (venue_id);

-- A scan that is outside the person's scope is logged as its own outcome.
alter table public.scan_attempts drop constraint if exists scan_attempts_result_check;
alter table public.scan_attempts add constraint scan_attempts_result_check
  check (result in (
    'ok', 'already_checked_in', 'not_paid', 'not_found', 'expired',
    'code_required', 'code_incorrect', 'code_expired', 'no_code_requested', 'wrong_event'
  ));

-- ---------------------------------------------------------------------------
-- Who may scan what
-- ---------------------------------------------------------------------------
-- Does the caller hold a door role right now (not revoked, inside their access window and shift)?
create function public.has_door_role()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.active_memberships() m where m.role = 'door')
$$;

-- May the caller scan tickets for this event?
create function public.can_scan_event(p_event uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.active_memberships() m
    join public.site_events e on e.id = p_event
    where m.role = 'door'
      and (m.event_id = e.id or (m.venue_id is not null and e.venue_id = m.venue_id))
  )
$$;

-- ---------------------------------------------------------------------------
-- The events one workspace can work tonight
-- ---------------------------------------------------------------------------
-- Events this membership covers that are running, starting within a day, or only just finished (so a late guest can
-- still be dealt with), with how many guests are expected and already admitted. 'scope' says whether the person is
-- assigned to the event itself or covers it through the club.
create function public.door_events(p_membership uuid)
returns table (
  event_id uuid, title text, venue_name text, start_date timestamptz, end_date timestamptz,
  scope text, guests_expected int, guests_admitted int
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authorized'; end if;
  if not exists (select 1 from public.active_memberships() m where m.id = p_membership and m.role = 'door') then
    raise exception 'not authorized';
  end if;
  return query
    with mine as materialized (
      select m.event_id, m.venue_id from public.active_memberships() m where m.id = p_membership and m.role = 'door'
    )
    select e.id, e.title, e.venue_name, e.start_date, e.end_date,
           case when exists (select 1 from mine where mine.event_id = e.id) then 'event' else 'venue' end,
           coalesce((select sum(o.quantity) from public.site_orders o where o.event_id = e.id and o.status = 'paid'), 0)::int,
           coalesce((select sum(o.quantity) from public.site_orders o
                     where o.event_id = e.id and o.status = 'paid' and o.checked_in_at is not null), 0)::int
    from public.site_events e
    where exists (select 1 from mine where mine.event_id = e.id or (mine.venue_id is not null and e.venue_id = mine.venue_id))
      and coalesce(e.end_date, e.start_date + interval '12 hours') > now() - interval '3 hours'
      and e.start_date < now() + interval '24 hours'
    order by e.start_date, e.title;
end;
$$;

-- ---------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------
-- Admits a ticket, if it is for an event the caller covers (and, when the screen has an event selected, for THAT
-- event). Same outcomes and result shape as checkin_ticket(), plus 'wrong_event'. Every outcome is logged against the
-- person who scanned. A ticket outside the caller's scope reveals nothing about the guest.
create function public.door_scan_ticket(p_ticket_code text, p_event uuid default null)
returns table (result text, customer_name text, event_title text, tier_name text, quantity int)
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
begin
  if auth.uid() is null or not public.has_door_role() then raise exception 'not authorized'; end if;

  -- Find the event first, without locking or reading the guest, so scope is decided before anything is exposed.
  select o.event_id, e.title into v_event, v_title
  from public.site_orders o join public.site_events e on e.id = o.event_id
  where o.ticket_code = v_code;

  if not found then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'not_found', null, auth.uid());
    return query select 'not_found', null::text, null::text, null::text, null::int;
    return;
  end if;

  v_covered := public.can_scan_event(v_event);
  if not v_covered or (p_event is not null and v_event <> p_event) then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      select v_code, 'wrong_event', o.id, auth.uid() from public.site_orders o where o.ticket_code = v_code;
    -- The event name is only shown when the person covers it (a different event of theirs); never for someone else's.
    return query select 'wrong_event', null::text, case when v_covered then v_title end, null::text, null::int;
    return;
  end if;

  select o.id, o.status, o.checked_in_at, o.customer_name, o.quantity, o.is_non_transferable, o.access_code_verified,
         e.title as event_title, e.start_date, e.end_date, t.name as tier_name
  into v_order
  from public.site_orders o
  join public.site_ticket_tiers t on t.id = o.tier_id
  join public.site_events e on e.id = o.event_id
  where o.ticket_code = v_code
  for update of o;

  if v_order.status <> 'paid' then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'not_paid', v_order.id, auth.uid());
    return query select 'not_paid', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
    return;
  end if;

  if v_order.checked_in_at is not null then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'already_checked_in', v_order.id, auth.uid());
    return query select 'already_checked_in', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
    return;
  end if;

  v_end := coalesce(v_order.end_date, v_order.start_date + interval '12 hours');
  if now() > v_end then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'expired', v_order.id, auth.uid());
    return query select 'expired', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
    return;
  end if;

  if v_order.is_non_transferable and not v_order.access_code_verified then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'code_required', v_order.id, auth.uid());
    return query select 'code_required', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
    return;
  end if;

  update public.site_orders set checked_in_at = now(), checked_in_by = auth.uid() where id = v_order.id;
  insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'ok', v_order.id, auth.uid());
  return query select 'ok', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
end;
$$;

-- The entry-code step for non-transferable tickets: the guest reads out the 6-digit code from their email and staff
-- type it in; three wrong tries lock it. Same rules as verify_ticket_otp(), scoped like door_scan_ticket(). A correct
-- code admits the ticket in the same step. Unlike the older function it also refuses an event that has ended, and it
-- never spends a guess on a ticket the caller has no right to scan.
create function public.door_verify_ticket_code(p_ticket_code text, p_code text, p_event uuid default null)
returns table (result text, customer_name text, event_title text, tier_name text, quantity int, attempts_remaining int)
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
  v_otp record;
  v_end timestamptz;
begin
  if auth.uid() is null or not public.has_door_role() then raise exception 'not authorized'; end if;

  select o.event_id, e.title into v_event, v_title
  from public.site_orders o join public.site_events e on e.id = o.event_id
  where o.ticket_code = v_code;

  if not found then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'not_found', null, auth.uid());
    return query select 'not_found', null::text, null::text, null::text, null::int, null::int;
    return;
  end if;

  v_covered := public.can_scan_event(v_event);
  if not v_covered or (p_event is not null and v_event <> p_event) then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
      select v_code, 'wrong_event', o.id, auth.uid() from public.site_orders o where o.ticket_code = v_code;
    return query select 'wrong_event', null::text, case when v_covered then v_title end, null::text, null::int, null::int;
    return;
  end if;

  select o.id, o.status, o.checked_in_at, o.customer_name, o.quantity, o.is_non_transferable,
         e.title as event_title, e.start_date, e.end_date, t.name as tier_name
  into v_order
  from public.site_orders o
  join public.site_ticket_tiers t on t.id = o.tier_id
  join public.site_events e on e.id = o.event_id
  where o.ticket_code = v_code
  for update of o;

  if v_order.status <> 'paid' then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'not_paid', v_order.id, auth.uid());
    return query select 'not_paid', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  if v_order.checked_in_at is not null then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'already_checked_in', v_order.id, auth.uid());
    return query select 'already_checked_in', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  v_end := coalesce(v_order.end_date, v_order.start_date + interval '12 hours');
  if now() > v_end then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'expired', v_order.id, auth.uid());
    return query select 'expired', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  -- An ordinary ticket needs no code: admit it, exactly as a scan would.
  if not v_order.is_non_transferable then
    update public.site_orders set checked_in_at = now(), checked_in_by = auth.uid() where id = v_order.id;
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'ok', v_order.id, auth.uid());
    return query select 'ok', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  select * into v_otp from public.ticket_otp_codes where order_id = v_order.id order by created_at desc limit 1 for update;

  if not found or v_otp.status = 'expired' then
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'no_code_requested', v_order.id, auth.uid());
    return query select 'no_code_requested', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  if v_otp.status = 'verified' or now() > v_otp.expires_at then
    if v_otp.status <> 'verified' then update public.ticket_otp_codes set status = 'expired' where id = v_otp.id; end if;
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'code_expired', v_order.id, auth.uid());
    return query select 'code_expired', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  if v_otp.attempts >= v_otp.max_attempts then
    update public.ticket_otp_codes set status = 'expired' where id = v_otp.id;
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'code_expired', v_order.id, auth.uid());
    return query select 'code_expired', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    return;
  end if;

  if crypt(coalesce(p_code, ''), v_otp.code_hash) <> v_otp.code_hash then
    update public.ticket_otp_codes set attempts = attempts + 1 where id = v_otp.id;
    insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'code_incorrect', v_order.id, auth.uid());
    return query select 'code_incorrect', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity,
      v_otp.max_attempts - (v_otp.attempts + 1);
    return;
  end if;

  update public.ticket_otp_codes set status = 'verified', verified_at = now(), verified_by = auth.uid() where id = v_otp.id;
  update public.site_orders
    set access_code_verified = true, access_code_verified_at = now(), checked_in_at = now(), checked_in_by = auth.uid()
    where id = v_order.id;
  insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by) values (v_code, 'ok', v_order.id, auth.uid());
  return query select 'ok', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
end;
$$;

-- ---------------------------------------------------------------------------
-- Finding a guest
-- ---------------------------------------------------------------------------
-- Paid guests of an event the caller covers, found by name or ticket code, for when a QR code will not scan. At least two
-- characters are needed (this is a search, not a way to download the guest list), at most 50 rows come back, and no email
-- or phone number is returned. Wildcards in what is typed are literal.
create function public.door_guests(p_event uuid, p_query text)
returns table (
  order_id uuid, customer_name text, ticket_code text, tier_name text, quantity int,
  checked_in_at timestamptz, needs_code boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := trim(coalesce(p_query, ''));
begin
  if auth.uid() is null or not public.has_door_role() then raise exception 'not authorized'; end if;
  if not public.can_scan_event(p_event) then raise exception 'not allowed'; end if;
  if length(v_q) < 2 then return; end if;
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  return query
    select o.id, o.customer_name, o.ticket_code, t.name, o.quantity, o.checked_in_at,
           (o.is_non_transferable and not o.access_code_verified)
    from public.site_orders o
    join public.site_ticket_tiers t on t.id = o.tier_id
    where o.event_id = p_event and o.status = 'paid' and o.ticket_code is not null
      and (o.customer_name ilike '%' || v_q || '%' or o.ticket_code ilike '%' || v_q || '%')
    order by lower(o.customer_name), o.created_at
    limit 50;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function
  public.has_door_role(), public.can_scan_event(uuid), public.door_events(uuid),
  public.door_scan_ticket(text, uuid), public.door_verify_ticket_code(text, text, uuid), public.door_guests(uuid, text)
  from public, anon;
grant execute on function
  public.has_door_role(), public.can_scan_event(uuid), public.door_events(uuid),
  public.door_scan_ticket(text, uuid), public.door_verify_ticket_code(text, text, uuid), public.door_guests(uuid, text)
  to authenticated, service_role;
