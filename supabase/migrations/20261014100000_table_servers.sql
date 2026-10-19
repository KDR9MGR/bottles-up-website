-- Giving a booking to a server, and a server's own list of tables.
--
-- Client Phase 2 brief, sections 12 and 13: "Manager can assign/reassign tables and orders" and "Server dashboard: My Tables ... table
-- cards show table, lead guest and next action". Until now nothing in the database tied a booking to a person: a server's list in
-- the old staff area comes from production-only functions that authorize through the global door_staff table, which an invited
-- server (a 'server' membership) is not in. This adds the link, and a server's list built on it.
--
-- THE MODEL: one booking has at most one server (site_booking_servers, keyed by the booking). Individual tables do not exist yet
-- (inventory is a count per table type), so what is assigned is the BOOKING, not a physical table. The client brief says "tables";
-- this is the closest the data allows and is flagged for the client to confirm.
--
-- WHO MAY DO WHAT:
--   * assign / take away / see who has which booking: the owner of the business or the manager of THAT club (require_venue_editor).
--   * a server reads only the bookings given to them (my_assigned_tables). They never see another server's, and not the guest's
--     email or phone: a server needs the lead guest's name, not their contact details.
--   * the person must be an active 'server' of that same club (not a door, security or verifier role, not another club's server, not
--     someone whose access ended), and the booking must be paid.
--
-- DELIBERATELY ONLY COLUMNS THAT THE COMMITTED MIGRATIONS DEFINE. What was actually paid, a table's bottle orders and their service
-- state live in production-only columns; they join this list once `supabase db pull` brings them into the repository.
--
-- Plain CREATE, never CREATE OR REPLACE, so a name collision in the shared database fails loudly.

-- ---------------------------------------------------------------------------
-- 1. The link
-- ---------------------------------------------------------------------------
create table public.site_booking_servers (
  booking_id uuid primary key references public.site_table_bookings (id) on delete cascade,
  membership_id uuid not null references public.site_memberships (id) on delete cascade,
  assigned_by uuid not null references auth.users (id),
  assigned_at timestamptz not null default now()
);
create index site_booking_servers_membership_id_idx on public.site_booking_servers (membership_id);

-- Reached only through the functions below. With row level security on and no policy, nobody reads or writes it directly.
alter table public.site_booking_servers enable row level security;
revoke all on table public.site_booking_servers from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Attribution (internal: the app cannot call it, or anyone could write audit entries in anyone's name)
-- ---------------------------------------------------------------------------
create function public.desk_log(p_action text, p_entity_type text, p_entity uuid, p_details jsonb default null)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (
    auth.uid(),
    coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'),
    p_action,
    p_entity_type,
    p_entity::text,
    coalesce(p_details, '{}'::jsonb)
  )
$$;

-- The venue a booking belongs to, or null. Callers check access to THAT venue before touching the booking, and answer "not allowed"
-- for a booking that does not exist, so a stranger cannot learn which booking ids exist.
create function public.booking_venue(p_booking uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select b.venue_id from public.site_table_bookings b where b.id = p_booking
$$;

-- ---------------------------------------------------------------------------
-- 3. The manager's side
-- ---------------------------------------------------------------------------
create function public.assign_booking_server(p_booking uuid, p_membership uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_booking public.site_table_bookings;
  v_member public.site_memberships;
  v_old uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_booking is null or p_membership is null then raise exception 'choose a booking and a server'; end if;

  v_venue := public.booking_venue(p_booking);
  if v_venue is null then raise exception 'not allowed'; end if;
  perform public.require_venue_editor(v_venue);

  -- Lock the booking so two managers giving it to different servers at the same moment end up with one of them, not a mix.
  select * into v_booking from public.site_table_bookings where id = p_booking for update;
  if v_booking.status is distinct from 'paid' then raise exception 'only a paid booking can be given to a server'; end if;

  select * into v_member from public.site_memberships where id = p_membership;
  if not found or v_member.role <> 'server' or v_member.venue_id is distinct from v_venue
     or v_member.org_id is distinct from (select v.org_id from public.site_venues v where v.id = v_venue) then
    raise exception 'that person is not a server at this club';
  end if;
  if v_member.status <> 'active'
     or (v_member.access_end_at is not null and v_member.access_end_at < now())
     or exists (select 1 from public.site_shifts s where s.id = v_member.shift_id and s.ends_at < now()) then
    raise exception 'that person no longer has access to this club';
  end if;

  select a.membership_id into v_old from public.site_booking_servers a where a.booking_id = p_booking;
  if v_old = p_membership then return; end if;   -- already theirs: nothing to change, nothing to record

  insert into public.site_booking_servers (booking_id, membership_id, assigned_by)
  values (p_booking, p_membership, auth.uid())
  on conflict (booking_id) do update
    set membership_id = excluded.membership_id, assigned_by = excluded.assigned_by, assigned_at = now();

  perform public.desk_log(
    case when v_old is null then 'booking.server_assigned' else 'booking.server_reassigned' end,
    'site_table_bookings', p_booking,
    jsonb_build_object('venue_id', v_venue, 'from_membership', v_old, 'to_membership', p_membership, 'to_user', v_member.user_id)
  );
end;
$$;

create function public.unassign_booking_server(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_old uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_venue := public.booking_venue(p_booking);
  if v_venue is null then raise exception 'not allowed'; end if;
  perform public.require_venue_editor(v_venue);

  delete from public.site_booking_servers where booking_id = p_booking returning membership_id into v_old;
  if v_old is null then return; end if;   -- nobody was assigned: nothing to record

  perform public.desk_log('booking.server_removed', 'site_table_bookings', p_booking,
    jsonb_build_object('venue_id', v_venue, 'from_membership', v_old));
end;
$$;

-- Who has which booking, for the club's nights p_from..p_to (business nights, both included; at most 93 and 1000 rows, like the
-- bookings list this goes with). server_available says whether that person can still serve: false once their access was taken
-- away or ended, so the manager can see a table that is nobody's in practice.
create function public.list_venue_booking_servers(p_venue uuid, p_from date, p_to date)
returns table (booking_id uuid, membership_id uuid, user_id uuid, server_available boolean, assigned_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  if p_from is null or p_to is null then raise exception 'choose a start and an end date'; end if;
  if p_to < p_from then raise exception 'the end date is before the start date'; end if;
  if p_to - p_from > 92 then raise exception 'choose at most 93 nights at a time'; end if;

  return query
    select a.booking_id, a.membership_id, m.user_id,
           (m.status = 'active'
              and (m.access_end_at is null or m.access_end_at >= now())
              and not exists (select 1 from public.site_shifts s where s.id = m.shift_id and s.ends_at < now())),
           a.assigned_at
    from public.site_booking_servers a
    join public.site_table_bookings b on b.id = a.booking_id
    join public.site_venue_time_slots s on s.id = b.time_slot_id
    join public.site_memberships m on m.id = a.membership_id
    where b.venue_id = p_venue
      and b.booking_date between p_from and p_to + 1
      and public.booking_night(b.booking_date, s.start_time) between p_from and p_to
    order by public.booking_night(b.booking_date, s.start_time), s.start_time, b.created_at
    limit 1000;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The server's side
-- ---------------------------------------------------------------------------
-- The caller's own tables for one business night (p_night is the night, in the club's terms: a slot before 06:00 belongs to the
-- night before). Only paid bookings that were given to one of the caller's CURRENT server memberships; anyone without one gets an
-- empty list. No guest email or phone.
create function public.my_assigned_tables(p_night date)
returns table (
  booking_id uuid, venue_id uuid, venue_name text, night_date date, start_time time, slot_label text, table_name text,
  guest_count int, customer_name text, confirmation_code text, checked_in_at timestamptz, assigned_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;

  return query
    select b.id, b.venue_id, v.name, public.booking_night(b.booking_date, s.start_time), s.start_time, s.label, t.name,
           b.guest_count, b.customer_name, b.confirmation_code, b.checked_in_at, a.assigned_at
    from public.site_booking_servers a
    join public.site_table_bookings b on b.id = a.booking_id
    join public.site_venue_time_slots s on s.id = b.time_slot_id
    join public.site_table_types t on t.id = b.table_type_id
    join public.site_venues v on v.id = b.venue_id
    where a.membership_id in (select m.id from public.active_memberships() m where m.role = 'server')
      and b.status = 'paid'
      and b.booking_date between p_night and p_night + 1
      and public.booking_night(b.booking_date, s.start_time) = p_night
    order by (s.start_time < time '06:00:00'), s.start_time, b.customer_name, b.created_at
    limit 300;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.desk_log(text, text, uuid, jsonb), public.booking_venue(uuid) from public, anon, authenticated;

revoke all on function
  public.assign_booking_server(uuid, uuid), public.unassign_booking_server(uuid),
  public.list_venue_booking_servers(uuid, date, date), public.my_assigned_tables(date)
  from public, anon;
grant execute on function
  public.assign_booking_server(uuid, uuid), public.unassign_booking_server(uuid),
  public.list_venue_booking_servers(uuid, date, date), public.my_assigned_tables(date)
  to authenticated, service_role;
