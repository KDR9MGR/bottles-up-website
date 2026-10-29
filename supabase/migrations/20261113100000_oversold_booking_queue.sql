-- A table that was paid for after it had gone to someone else: flag it for the manager instead of confirming it.
--
-- A guest who starts the online checkout keeps the table for 10 minutes (the checkout hold). If they pay AFTER that, another guest may have taken the table in the
-- meantime. Stripe has already taken the money, but nothing checked the table again: the booking was marked paid and the confirmation e-mail promised a table that
-- two guests now hold. (Brief 2 Oct, section 16: "If payment is confirmed after a hold expires, reconcile the existing payment and resource before confirming;
-- route conflicts for resolution/refund rather than selling an already-booked table.")
--
-- What this adds (all new; nothing existing is replaced and no row is changed):
--   * site_booking_conflicts       one row per booking that was found to be double-booked; nobody reads or writes it directly (row level security, no grants).
--   * site_flag_oversold_booking   service role only. The Stripe fulfilment calls it after marking a booking paid. It locks the table type, counts the PAID bookings and
--                                  the tables a manager has held or taken out of use for that arrival time, and opens a conflict when they are more than the club has.
--                                  Calling it again for the same booking changes nothing and gives the same answer while the conflict is open. A guest who has
--                                  already been sent their confirmation is never flagged afterwards. The edge function does not send the guest a confirmation
--                                  while a conflict is open.
--   * desk_booking_conflicts       the club's manager or owner lists them (open ones, or all), with the guest's contact so they can call.
--   * desk_resolve_booking_conflict the manager closes one with how it was settled and a note. It checks the facts instead of trusting the word: "moved" only if the
--                                  booking no longer overbooks its table, "refunded" only if the booking is refunded or cancelled; "kept" (the club found the table) always.
-- The manager moves a booking with the existing desk_move_booking and refunds it with the existing refund flow; this only records that it was dealt with.

do $guard$
declare r record;
begin
  for r in select * from (values ('public.desk_level(uuid)'), ('public.desk_log(text, text, uuid, jsonb)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then
      raise exception '% does not exist: run the earlier server desk migrations first. Nothing was changed.', r.sig;
    end if;
  end loop;
  for r in select * from (values ('site_table_bookings'), ('site_table_types'), ('site_venue_time_slots'), ('site_table_blocks'), ('site_venues')) as x(t) loop
    if to_regclass('public.' || r.t) is null then raise exception 'public.% does not exist. Nothing was changed.', r.t; end if;
  end loop;
end $guard$;

create table public.site_booking_conflicts (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.site_table_bookings (id) on delete cascade,
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  table_type_id uuid not null references public.site_table_types (id) on delete cascade,
  time_slot_id uuid not null references public.site_venue_time_slots (id) on delete cascade,
  booking_date date not null,                          -- the ARRIVAL date, like site_table_bookings.booking_date
  kind text not null default 'oversold' check (kind in ('oversold')),
  status text not null default 'open' check (status in ('open', 'resolved')),
  paid_count int not null check (paid_count >= 0),     -- what was counted when it was found: paid bookings plus tables held or out of use
  inventory_count int not null check (inventory_count >= 0),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users (id) on delete set null,
  resolution text check (resolution in ('moved', 'refunded', 'kept')),
  resolution_note text check (resolution_note is null or char_length(btrim(resolution_note)) between 3 and 500),
  constraint site_booking_conflicts_state_check check (
    (status = 'open' and resolved_at is null and resolution is null and resolution_note is null)
    or (status = 'resolved' and resolved_at is not null and resolution is not null and resolution_note is not null))
);
create index site_booking_conflicts_venue_idx on public.site_booking_conflicts (venue_id, status, created_at desc);
alter table public.site_booking_conflicts enable row level security;
revoke all on table public.site_booking_conflicts from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Opening a conflict (called by the Stripe fulfilment, with the service role)
-- ---------------------------------------------------------------------------
create function public.site_flag_oversold_booking(p_booking uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  c public.site_booking_conflicts;
  v_inventory int;
  v_paid int;
  v_held int;
begin
  select * into b from public.site_table_bookings where id = p_booking;
  if not found or b.status <> 'paid' then return false; end if;

  -- One at a time per kind of table: two late payments at once are counted one after the other, so the second sees the first.
  select t.inventory_count into v_inventory from public.site_table_types t where t.id = b.table_type_id for update;
  if not found then return false; end if;

  select * into c from public.site_booking_conflicts k where k.booking_id = b.id;
  if found then return c.status = 'open'; end if;
  -- A guest who has already been sent their confirmation was served before whoever pays now: never flagged afterwards. (A guest who has NOT been confirmed yet
  -- may be flagged together with a later payer; the manager sees both, which is the safe way round.)
  if b.confirmation_sent_at is not null then return false; end if;

  select count(*)::int into v_paid from public.site_table_bookings k
   where k.table_type_id = b.table_type_id and k.time_slot_id = b.time_slot_id and k.booking_date = b.booking_date and k.status = 'paid';
  select coalesce(sum(k.quantity), 0)::int into v_held from public.site_table_blocks k
   where k.table_type_id = b.table_type_id and k.time_slot_id = b.time_slot_id and k.booking_date = b.booking_date
     and k.released_at is null and (k.expires_at is null or k.expires_at > now());

  if v_paid + v_held <= v_inventory then return false; end if;

  insert into public.site_booking_conflicts (booking_id, venue_id, table_type_id, time_slot_id, booking_date, paid_count, inventory_count)
  values (b.id, b.venue_id, b.table_type_id, b.time_slot_id, b.booking_date, v_paid + v_held, v_inventory);
  return true;
end $$;
revoke all on function public.site_flag_oversold_booking(uuid) from public, anon, authenticated;
grant execute on function public.site_flag_oversold_booking(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- The club's list
-- ---------------------------------------------------------------------------
create function public.desk_booking_conflicts(p_venue uuid, p_include_resolved boolean default false)
returns table (
  conflict_id uuid, booking_id uuid, confirmation_code text, customer_name text, customer_email text, customer_phone text,
  table_name text, arrival_date date, arrival_time time, guest_count int, amount_paid_cents int, currency text,
  tables_counted int, tables_available int, status text, resolution text, resolution_note text, created_at timestamptz, resolved_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  return query
    select k.id, b.id, b.confirmation_code, b.customer_name, b.customer_email, b.customer_phone,
           t.name, b.booking_date, s.start_time, b.guest_count, b.amount_paid_cents, b.currency,
           k.paid_count, k.inventory_count, k.status, k.resolution, k.resolution_note, k.created_at, k.resolved_at
      from public.site_booking_conflicts k
      join public.site_table_bookings b on b.id = k.booking_id
      join public.site_table_types t on t.id = b.table_type_id
      join public.site_venue_time_slots s on s.id = b.time_slot_id
     where k.venue_id = p_venue and (p_include_resolved or k.status = 'open')
     order by (k.status = 'open') desc, k.created_at desc;
end $$;
revoke all on function public.desk_booking_conflicts(uuid, boolean) from public, anon;
grant execute on function public.desk_booking_conflicts(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Closing one
-- ---------------------------------------------------------------------------
create function public.desk_resolve_booking_conflict(p_conflict uuid, p_resolution text, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.site_booking_conflicts;
  b public.site_table_bookings;
  v_note text := nullif(btrim(p_note), '');
  v_inventory int;
  v_taken int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into c from public.site_booking_conflicts where id = p_conflict for update;
  if not found then raise exception 'not allowed'; end if;
  if public.desk_level(c.venue_id) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_resolution is null or p_resolution not in ('moved', 'refunded', 'kept') then raise exception 'say how it was settled: moved, refunded or kept'; end if;
  if v_note is null or char_length(v_note) < 3 then raise exception 'say what was done, in a few words'; end if;
  if char_length(v_note) > 500 then raise exception 'keep the note to 500 characters or fewer'; end if;
  if c.status <> 'open' then raise exception 'this has already been dealt with'; end if;

  select * into b from public.site_table_bookings where id = c.booking_id;

  if p_resolution = 'moved' then
    -- Where the booking is NOW must no longer be overbooked.
    select t.inventory_count into v_inventory from public.site_table_types t where t.id = b.table_type_id for update;
    select (select count(*) from public.site_table_bookings k
             where k.table_type_id = b.table_type_id and k.time_slot_id = b.time_slot_id and k.booking_date = b.booking_date and k.status = 'paid')
         + coalesce((select sum(k.quantity) from public.site_table_blocks k
             where k.table_type_id = b.table_type_id and k.time_slot_id = b.time_slot_id and k.booking_date = b.booking_date
               and k.released_at is null and (k.expires_at is null or k.expires_at > now())), 0)
      into v_taken;
    if b.status <> 'paid' or v_taken > v_inventory then
      raise exception 'that table is still double-booked: move the booking to another table first';
    end if;
  elsif p_resolution = 'refunded' then
    if b.status not in ('refunded', 'cancelled') then raise exception 'refund or cancel the booking first'; end if;
  end if;

  update public.site_booking_conflicts
     set status = 'resolved', resolution = p_resolution, resolution_note = v_note, resolved_at = now(), resolved_by = auth.uid()
   where id = c.id;
  perform public.desk_log('booking.conflict_resolved', 'site_booking_conflicts', c.id,
    jsonb_build_object('venue_id', c.venue_id, 'booking_id', c.booking_id, 'resolution', p_resolution));
end $$;
revoke all on function public.desk_resolve_booking_conflict(uuid, text, text) from public, anon;
grant execute on function public.desk_resolve_booking_conflict(uuid, text, text) to authenticated;
