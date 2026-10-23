-- Floor plan placement, table states, moving a booking, and deposit terms (developer brief 15 Oct, sections 13 and 15; the client's answers of 20 Oct: "similar to
-- the website" and "table checkout hold: 10 minutes").
--
--   PLACEMENT (owner or manager of the venue; the website's CMS drag-and-drop editor, now also in the app)
--   * list_venue_table_layout(venue)                      every table type with its floor, position (percent of the floor image), size and included admissions
--   * place_venue_table / unplace_venue_table             put a table type on a floor, or take it off (same columns the CMS writes: floor_id, pos_x, pos_y, width, height)
--   * set_table_included_admissions(venue, type, count)   how many guests a booking of this table includes (null = not stated; never silently "unlimited")
--
--   TABLE STATES (the floor map): Available, Held, Booked, Occupied, Unavailable
--   * site_table_blocks (closed table)   a manager's HOLD (timed) or UNAVAILABLE (until reopened) on some tables of a type for one arrival time; never on tables already booked
--   * site_table_taken_count(...)        the ONE count every booking path uses: paid bookings + checkouts started in the last 10 minutes (the checkout HOLD) + active blocks
--   * desk_table_states / desk_table_block / desk_table_release / desk_table_blocks   the floor map and the manager's block and reopen actions
--   * the public picker (get_unavailable_table_types), the walk-in options and the walk-in booking now use that count, so a blocked or held table cannot be sold
--     (the website's checkout and legacy walk-in functions call it too: see supabase/functions)
--
--   MOVING A BOOKING
--   * site_booking_moves (closed table), desk_move_booking(booking, new table type, reason), desk_booking_moves(booking), desk_booking_move_options(booking)
--     the same booking moves to another table type for the same arrival time after the availability and party-size checks; who, when, from, to and why are kept;
--     the amounts the guest agreed to do NOT change (the price difference is recorded, never charged or refunded silently).
--
--   DEPOSIT TERMS (venue default; effect on NEW bookings only)
--   * site_venues.deposit_terms {recipient: venue|organizer|split, venue_pct, purpose: reservation_fee|minimum_spend_credit|admission}
--   * venue_deposit_terms / save_venue_deposit_terms     read and change the venue's default (owner or manager)
--   * a BEFORE INSERT trigger copies the venue's terms and the table's included admissions onto every new booking, whichever path created it, so later changes
--     never rewrite a booking that exists ("save accepted terms"). A venue that never chose gets: venue keeps it, purpose from its credit switch (marked default).
--   * purpose must agree with the venue's deposit_is_credit switch (which BottlesUp staff own, see 20261020100000): credit <-> "minimum spend credit".
--
-- GUARD for the three LIVE functions this changes (get_unavailable_table_types 20260925100000; desk_walkin_options and desk_create_walkin 20261020140000):
-- each is replaced only if it is exactly the version this repository has; if it already uses the shared count nothing is replaced; anything else STOPS the whole
-- migration before anything is built. Needs the venue setup, desk, seating, close night and walk-in migrations. Plain CREATE for everything new.

-- ---------------------------------------------------------------------------
-- 0. Check everything this builds on, and the three live functions, BEFORE changing anything
-- ---------------------------------------------------------------------------
do $guard$
declare
  v_live text;
  v_src text;
  r record;
  c_before_unavail constant text := '5123b477984bdf2be9bd9249891ed7fd';
  c_before_options constant text := '769e7903007730163ef1d470464716ca';
  c_before_walkin constant text := '0a86d106ee2055b36d574636222fe46b';
begin
  for r in select * from (values
      ('public.require_venue_editor(uuid)'), ('public.venue_setup_log(text, text, uuid, uuid, jsonb)'), ('public.setup_only_keys(jsonb, text[])'),
      ('public.setup_int(jsonb, text, text, integer, integer)'), ('public.setup_text(jsonb, text, text, integer)'), ('public.desk_level(uuid)'),
      ('public.desk_booking_level(uuid)'), ('public.desk_log(text, text, uuid, jsonb)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then
      raise exception '% does not exist: run the earlier venue setup and server desk migrations first. Nothing was changed.', r.sig;
    end if;
  end loop;
  for r in select * from (values ('site_night_closes'), ('site_booking_seating'), ('site_venue_time_slots'), ('site_venue_floors'), ('profiles')) as x(t) loop
    if to_regclass('public.' || r.t) is null then raise exception 'public.% does not exist. Nothing was changed.', r.t; end if;
  end loop;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'site_venues' and column_name = 'deposit_is_credit') then
    raise exception 'site_venues.deposit_is_credit must exist first (20261020100000). Nothing was changed.';
  end if;

  -- each live function: already using the shared count, or exactly the known version, or STOP
  for r in select * from (values
      ('get_unavailable_table_types', 'p_venue_id uuid, p_booking_date date, p_time_slot_id uuid', c_before_unavail),
      ('desk_walkin_options', 'p_venue uuid, p_night date', c_before_options),
      ('desk_create_walkin', 'p_venue uuid, p_night date, p_table_type uuid, p_slot uuid, p_guests integer, p_hours integer, p_name text, p_email text, p_phone text, p_terms_confirmed boolean', c_before_walkin)
    ) as x(fname, fargs, expected) loop
    select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, '')), p.prosrc
      into v_live, v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname and pg_get_function_identity_arguments(p.oid) = r.fargs;
    if v_live is null then
      raise exception 'public.% does not exist in this database. Nothing was changed.', r.fname;
    end if;
    if position('site_table_taken_count' in v_src) = 0 and v_live <> r.expected then
      raise exception '%() in this database differs from the version this change was written against (live fingerprint %, expected %). It was NOT replaced, because that could undo a change made directly in the database. Inspect it with \sf public.% and reconcile by hand. Nothing was changed.', r.fname, v_live, r.expected, r.fname;
    end if;
  end loop;
end
$guard$;

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.site_table_types
  add column included_admissions int check (included_admissions is null or included_admissions between 0 and 100);
alter table public.site_table_bookings
  add column included_admissions int,
  add column deposit_terms jsonb;
alter table public.site_venues
  add column deposit_terms jsonb;

-- ---------------------------------------------------------------------------
-- 2. Blocks (a hold or "unavailable") and moves: closed tables, written only by the functions below
-- ---------------------------------------------------------------------------
create table public.site_table_blocks (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  table_type_id uuid not null references public.site_table_types (id) on delete cascade,
  time_slot_id uuid not null references public.site_venue_time_slots (id) on delete cascade,
  booking_date date not null,                      -- the ARRIVAL date, like site_table_bookings.booking_date
  kind text not null check (kind in ('held', 'unavailable')),
  quantity int not null default 1 check (quantity between 1 and 500),
  reason text not null check (char_length(btrim(reason)) between 3 and 200),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz,                          -- a hold ends by itself; "unavailable" lasts until reopened
  released_at timestamptz,
  released_by uuid references auth.users (id),
  constraint site_table_blocks_expiry_check check ((kind = 'held' and expires_at is not null) or (kind = 'unavailable' and expires_at is null)),
  constraint site_table_blocks_release_check check ((released_at is null) = (released_by is null))
);
create index site_table_blocks_active_idx on public.site_table_blocks (table_type_id, time_slot_id, booking_date) where released_at is null;
alter table public.site_table_blocks enable row level security;
revoke all on table public.site_table_blocks from public, anon, authenticated;

create table public.site_booking_moves (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.site_table_bookings (id) on delete cascade,
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  from_table_type uuid references public.site_table_types (id) on delete set null,
  to_table_type uuid references public.site_table_types (id) on delete set null,
  from_name text not null,
  to_name text not null,
  price_difference_cents int,                      -- informational: the new table's flat deposit minus the old one's; never charged or refunded by the move
  reason text not null check (char_length(btrim(reason)) between 3 and 200),
  moved_by uuid not null references auth.users (id),
  moved_at timestamptz not null default clock_timestamp()   -- the real time of the insert, so two moves in one step still have an order
);
create index site_booking_moves_booking_idx on public.site_booking_moves (booking_id, moved_at);
alter table public.site_booking_moves enable row level security;
revoke all on table public.site_booking_moves from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The one count: how many tables of a type are taken for an arrival time
-- ---------------------------------------------------------------------------
-- The length of the checkout hold: a guest who has started paying keeps the table for this long (the client's answer, 20 Oct: 10 minutes).
create function public.site_checkout_hold()
returns interval
language sql
immutable
set search_path = public
as $$ select interval '10 minutes' $$;

-- Paid bookings + checkouts started within the hold (not the one whose e-mail is p_exclude_email: a guest retrying does not block themselves)
-- + active blocks. p_date is the ARRIVAL date. Internal: the website's functions call it with the service role; the desk functions call it directly.
create function public.site_table_taken_count(p_type uuid, p_slot uuid, p_date date, p_exclude_email text default null)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select
    (select count(*) from public.site_table_bookings b
      where b.table_type_id = p_type and b.time_slot_id = p_slot and b.booking_date = p_date and b.status = 'paid')::int
  + (select count(*) from public.site_table_bookings b
      where b.table_type_id = p_type and b.time_slot_id = p_slot and b.booking_date = p_date and b.status = 'pending'
        and b.created_at > now() - public.site_checkout_hold()
        and (p_exclude_email is null or lower(b.customer_email) <> lower(p_exclude_email)))::int
  + coalesce((select sum(k.quantity) from public.site_table_blocks k
               where k.table_type_id = p_type and k.time_slot_id = p_slot and k.booking_date = p_date
                 and k.released_at is null and (k.expires_at is null or k.expires_at > now())), 0)::int
$$;
revoke all on function public.site_checkout_hold(), public.site_table_taken_count(uuid, uuid, date, text) from public, anon, authenticated;
grant execute on function public.site_checkout_hold(), public.site_table_taken_count(uuid, uuid, date, text) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Replace the three live functions that decide "is a table free" (guarded above)
-- ---------------------------------------------------------------------------
do $replace$
declare
  v_src text;
begin
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_unavailable_table_types';
  if position('site_table_taken_count' in v_src) = 0 then
    execute $sql$
    create or replace function public.get_unavailable_table_types(p_venue_id uuid, p_booking_date date, p_time_slot_id uuid)
    returns setof uuid
    language sql
    stable
    security definer
    set search_path = public
    as $$
      select t.id
        from public.site_table_types t
        join public.site_venue_time_slots ts on ts.id = p_time_slot_id and ts.venue_id = p_venue_id
       where t.venue_id = p_venue_id
         and public.site_table_taken_count(t.id, ts.id, case when ts.start_time < time '06:00:00' then p_booking_date + 1 else p_booking_date end) >= t.inventory_count
    $$
    $sql$;
  end if;

  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'desk_walkin_options';
  if position('site_table_taken_count' in v_src) = 0 then
    execute $sql$
create or replace function public.desk_walkin_options(p_venue uuid, p_night date)
returns table (
  slot_id uuid, start_time time, slot_label text, table_type_id uuid, table_name text, max_guests int, min_guests int, pricing_mode text,
  deposit_cents int, hourly_rate_cents int, min_hours int, inventory int, booked int, available int
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
  if p_night is null or abs(p_night - current_date) > 1 then raise exception 'that is not a current night'; end if;
  return query
    select s.id, s.start_time, s.label, t.id, t.name, t.max_guests, t.min_guests, t.pricing_mode, t.deposit_cents, t.hourly_rate_cents, t.min_hours, t.inventory_count,
           b.n, greatest(t.inventory_count - x.taken, 0)
      from public.site_venue_time_slots s
      cross join public.site_table_types t
      cross join lateral (
        select count(*)::int as n from public.site_table_bookings k
         where k.table_type_id = t.id and k.time_slot_id = s.id and k.status = 'paid'
           and k.booking_date = case when s.start_time < time '06:00:00' then p_night + 1 else p_night end
      ) b
      cross join lateral (
        select public.site_table_taken_count(t.id, s.id, case when s.start_time < time '06:00:00' then p_night + 1 else p_night end) as taken
      ) x
     where s.venue_id = p_venue and t.venue_id = p_venue and s.day_of_week = extract(dow from p_night)::int
     order by (s.start_time < time '06:00:00'), s.start_time, t.sort_order, t.name;
end;
$$

    $sql$;
  end if;

  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'desk_create_walkin';
  if position('site_table_taken_count' in v_src) = 0 then
    execute $sql$
create or replace function public.desk_create_walkin(
  p_venue uuid, p_night date, p_table_type uuid, p_slot uuid, p_guests int, p_hours int,
  p_name text, p_email text, p_phone text, p_terms_confirmed boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_table_types;
  s public.site_venue_time_slots;
  v_name text := btrim(coalesce(p_name, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_arrival date;
  v_deposit int;
  v_hours int := null;
  v_booked int;
  v_code text;
  v_id uuid;
  v_try int := 0;
  chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_night is null or abs(p_night - current_date) > 1 then raise exception 'that is not a current night'; end if;
  if p_terms_confirmed is not true then raise exception 'confirm that the guest has been told the terms and agrees to them'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then raise exception 'the guest''s name needs 2 to 120 characters'; end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or char_length(v_email) > 254 then raise exception 'enter a valid email address for the guest'; end if;
  if v_phone is not null and char_length(v_phone) > 40 then raise exception 'the phone number is too long'; end if;
  if exists (select 1 from public.site_night_closes c where c.venue_id = p_venue and c.business_night = p_night and c.status = 'closed') then
    raise exception 'this night has been closed, so no new booking can be added';
  end if;

  -- The table type is locked until this booking is in, so the count below cannot be out of date when it is used.
  select * into t from public.site_table_types where id = p_table_type and venue_id = p_venue for update;
  if not found then raise exception 'table not found'; end if;
  select * into s from public.site_venue_time_slots where id = p_slot and venue_id = p_venue;
  if not found then raise exception 'arrival time not found'; end if;
  if s.day_of_week <> extract(dow from p_night)::int then raise exception 'that arrival time is not offered on that night'; end if;

  if p_guests is null or p_guests < 1 then raise exception 'how many guests?'; end if;
  if p_guests > t.max_guests then raise exception 'this table seats up to % guests', t.max_guests; end if;
  if t.min_guests is not null and p_guests < t.min_guests then raise exception 'this table needs at least % guests', t.min_guests; end if;

  if t.pricing_mode = 'hourly' then
    if coalesce(t.hourly_rate_cents, 0) <= 0 then raise exception 'this table is not set up for hourly booking yet'; end if;
    if p_hours is null or p_hours < coalesce(t.min_hours, 1) or p_hours > 24 then
      raise exception 'this table needs between % and 24 hours', coalesce(t.min_hours, 1);
    end if;
    v_hours := p_hours;
    v_deposit := t.hourly_rate_cents * p_hours;
  else
    v_deposit := t.deposit_cents;
  end if;

  v_arrival := case when s.start_time < time '06:00:00' then p_night + 1 else p_night end;
  -- The same guest twice for the same time is almost always a repeated tap or a retry after a lost answer: refuse it, so nobody is booked twice.
  if exists (select 1 from public.site_table_bookings k where k.venue_id = p_venue and k.time_slot_id = s.id and k.booking_date = v_arrival
                and lower(k.customer_email) = v_email and k.status = 'paid') then
    raise exception 'this guest already has a booking for that time';
  end if;
  -- paid bookings, checkouts in progress (the hold) and the manager's blocks: the same count every booking path uses
  v_booked := public.site_table_taken_count(t.id, s.id, v_arrival);
  if v_booked >= t.inventory_count then raise exception 'no tables of this type are left for that time'; end if;

  loop
    v_try := v_try + 1;
    v_code := 'BT-' || (select string_agg(substr(chars, 1 + floor(random() * length(chars))::int, 1), '') from generate_series(1, 8));
    exit when not exists (select 1 from public.site_table_bookings where confirmation_code = v_code);
    if v_try > 20 then raise exception 'a confirmation code could not be made, try again'; end if;
  end loop;

  insert into public.site_table_bookings (
    venue_id, table_type_id, time_slot_id, booking_date, customer_name, customer_email, customer_phone, guest_count, hours,
    deposit_cents, bottle_subtotal_cents, tax_cents, bottlesup_fee_cents, amount_total_cents, amount_paid_cents, currency,
    status, bottle_payment_choice, confirmation_code, checked_in_at, checked_in_by
  ) values (
    p_venue, t.id, s.id, v_arrival, v_name, v_email, v_phone, p_guests, v_hours,
    v_deposit, 0, 0, 0, v_deposit, 0, t.currency,
    'paid', 'pay_at_club', v_code, now(), auth.uid()
  ) returning id into v_id;

  insert into public.site_booking_seating (booking_id, seated_by, seated_at, method, confirmation)
    values (v_id, auth.uid(), now(), 'manual', 'Walk-in guest, seated when the booking was made');

  perform public.desk_enqueue('walkin_confirmation', p_venue, v_id, jsonb_build_object('confirmation_code', v_code));
  perform public.desk_log('booking.walkin_created', 'site_table_bookings', v_id,
    jsonb_build_object('venue_id', p_venue, 'table_type_id', t.id, 'deposit_cents', v_deposit, 'guests', p_guests, 'terms_confirmed', true));

  return jsonb_build_object('booking_id', v_id, 'confirmation_code', v_code, 'deposit_cents', v_deposit, 'due_cents', v_deposit, 'arrival_date', v_arrival, 'tables_left', t.inventory_count - v_booked - 1);
end;
$$

    $sql$;
  end if;
end
$replace$;

-- ---------------------------------------------------------------------------
-- 5. Placement on the floor plan, and included admissions (owner or manager)
-- ---------------------------------------------------------------------------
create function public.list_venue_table_layout(p_venue uuid)
returns table (
  type_id uuid, name text, max_guests int, inventory_count int, deposit_cents int,
  floor_id uuid, pos_x numeric, pos_y numeric, width numeric, height numeric, included_admissions int
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  return query
    select t.id, t.name, t.max_guests, t.inventory_count, t.deposit_cents, t.floor_id, t.pos_x, t.pos_y, t.width, t.height, t.included_admissions
      from public.site_table_types t
     where t.venue_id = p_venue
     order by t.sort_order, t.created_at;
end;
$$;

-- Position and size are percentages (0 to 100) of the floor image, exactly as the website's editor stores them, so a placement made in the app shows on the
-- website's picker at any size. The box must lie inside the image.
create function public.place_venue_table(p_venue uuid, p_type uuid, p_floor uuid, p_x numeric, p_y numeric, p_w numeric, p_h numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  if p_floor is null or p_x is null or p_y is null or p_w is null or p_h is null then raise exception 'choose a floor and where the table goes'; end if;
  if p_x < 0 or p_y < 0 or p_w < 2 or p_h < 2 or p_x + p_w > 100.01 or p_y + p_h > 100.01 then
    raise exception 'the table must be at least 2 percent wide and high and fully inside the floor plan';
  end if;
  perform 1 from public.site_venues v where v.id = p_venue for update;
  if not exists (select 1 from public.site_venue_floors f where f.id = p_floor and f.venue_id = p_venue) then raise exception 'floor not found'; end if;
  update public.site_table_types t
     set floor_id = p_floor, pos_x = round(p_x, 2), pos_y = round(p_y, 2), width = round(p_w, 2), height = round(p_h, 2), updated_at = now()
   where t.id = p_type and t.venue_id = p_venue;
  if not found then raise exception 'table type not found'; end if;
  perform public.venue_setup_log('venue_setup.table_placed', 'site_table_types', p_type, p_venue, jsonb_build_object('floor_id', p_floor));
end;
$$;

create function public.unplace_venue_table(p_venue uuid, p_type uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  update public.site_table_types t
     set floor_id = null, pos_x = null, pos_y = null, width = null, height = null, updated_at = now()
   where t.id = p_type and t.venue_id = p_venue;
  if not found then raise exception 'table type not found'; end if;
  perform public.venue_setup_log('venue_setup.table_unplaced', 'site_table_types', p_type, p_venue);
end;
$$;

-- p_count null = not stated. A stated number is how many guests a booking of this table includes (0 = none; the booking is not admission).
create function public.set_table_included_admissions(p_venue uuid, p_type uuid, p_count int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max int;
begin
  perform public.require_venue_editor(p_venue);
  select t.max_guests into v_max from public.site_table_types t where t.id = p_type and t.venue_id = p_venue for update;
  if not found then raise exception 'table type not found'; end if;
  if p_count is not null and (p_count < 0 or p_count > 100) then raise exception 'included admissions must be between 0 and 100'; end if;
  if p_count is not null and p_count > v_max then raise exception 'a booking cannot include more admissions (%) than the table seats (%)', p_count, v_max; end if;
  update public.site_table_types t set included_admissions = p_count, updated_at = now() where t.id = p_type and t.venue_id = p_venue;
  perform public.venue_setup_log('venue_setup.table_admissions_set', 'site_table_types', p_type, p_venue, jsonb_build_object('included_admissions', p_count));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. The floor map and the manager's block / reopen actions (owner or manager)
-- ---------------------------------------------------------------------------
-- One row per arrival time offered that night and table type: how many tables are booked (not yet seated), occupied (seated or checked in), held (a manager's
-- hold or a checkout in progress), unavailable (blocked), and free. Same arrival-date rule as everywhere (an after-midnight time belongs to the next calendar day).
create function public.desk_table_states(p_venue uuid, p_night date)
returns table (
  slot_id uuid, start_time time, slot_label text, table_type_id uuid, table_name text, max_guests int, floor_id uuid,
  pos_x numeric, pos_y numeric, width numeric, height numeric,
  inventory int, booked int, occupied int, held int, unavailable int, available int
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
  if p_night is null or p_night < current_date - 1 or p_night > current_date + 60 then raise exception 'that night cannot be shown'; end if;
  return query
    select s.id, s.start_time, s.label, t.id, t.name, t.max_guests, t.floor_id, t.pos_x, t.pos_y, t.width, t.height,
           t.inventory_count, c.booked, c.occupied, c.held, c.unavail,
           greatest(t.inventory_count - c.booked - c.occupied - c.held - c.unavail, 0)
      from public.site_venue_time_slots s
      cross join public.site_table_types t
      cross join lateral (select case when s.start_time < time '06:00:00' then p_night + 1 else p_night end as arrival) a
      cross join lateral (
        select
          (select count(*)::int from public.site_table_bookings k
            where k.table_type_id = t.id and k.time_slot_id = s.id and k.booking_date = a.arrival and k.status = 'paid'
              and k.checked_in_at is null and not exists (select 1 from public.site_booking_seating z where z.booking_id = k.id)) as booked,
          (select count(*)::int from public.site_table_bookings k
            where k.table_type_id = t.id and k.time_slot_id = s.id and k.booking_date = a.arrival and k.status = 'paid'
              and (k.checked_in_at is not null or exists (select 1 from public.site_booking_seating z where z.booking_id = k.id))) as occupied,
          (select count(*)::int from public.site_table_bookings k
            where k.table_type_id = t.id and k.time_slot_id = s.id and k.booking_date = a.arrival and k.status = 'pending'
              and k.created_at > now() - public.site_checkout_hold())
          + coalesce((select sum(q.quantity)::int from public.site_table_blocks q
                       where q.table_type_id = t.id and q.time_slot_id = s.id and q.booking_date = a.arrival and q.kind = 'held'
                         and q.released_at is null and q.expires_at > now()), 0) as held,
          coalesce((select sum(q.quantity)::int from public.site_table_blocks q
                     where q.table_type_id = t.id and q.time_slot_id = s.id and q.booking_date = a.arrival and q.kind = 'unavailable'
                       and q.released_at is null), 0) as unavail
      ) c
     where s.venue_id = p_venue and t.venue_id = p_venue and s.day_of_week = extract(dow from p_night)::int
     order by (s.start_time < time '06:00:00'), s.start_time, t.sort_order, t.name;
end;
$$;

-- Holds some tables for a while (p_kind 'held', p_minutes 5 to 1440) or takes them out of sale until reopened (p_kind 'unavailable', no minutes). Only tables that
-- are free right now can be blocked: a table somebody has booked is never silently taken away.
create function public.desk_table_block(p_venue uuid, p_night date, p_type uuid, p_slot uuid, p_kind text, p_quantity int, p_reason text, p_minutes int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_table_types;
  s public.site_venue_time_slots;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_arrival date;
  v_free int;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_kind is null or p_kind not in ('held', 'unavailable') then raise exception 'choose hold or unavailable'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then raise exception 'give a reason of 3 to 200 characters'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 500 then raise exception 'how many tables?'; end if;
  if p_kind = 'held' and (p_minutes is null or p_minutes < 5 or p_minutes > 1440) then raise exception 'a hold lasts between 5 minutes and 24 hours'; end if;
  if p_kind = 'unavailable' and p_minutes is not null then raise exception 'a table that is unavailable stays so until it is reopened, so it has no time limit'; end if;
  if p_night is null or p_night < current_date - 1 or p_night > current_date + 60 then raise exception 'that night cannot be changed'; end if;

  select * into t from public.site_table_types where id = p_type and venue_id = p_venue for update;
  if not found then raise exception 'table not found'; end if;
  select * into s from public.site_venue_time_slots where id = p_slot and venue_id = p_venue;
  if not found then raise exception 'arrival time not found'; end if;
  if s.day_of_week <> extract(dow from p_night)::int then raise exception 'that arrival time is not offered on that night'; end if;
  if exists (select 1 from public.site_night_closes c where c.venue_id = p_venue and c.business_night = p_night and c.status = 'closed') then
    raise exception 'this night has been closed, so its tables cannot be changed';
  end if;

  v_arrival := case when s.start_time < time '06:00:00' then p_night + 1 else p_night end;
  v_free := t.inventory_count - public.site_table_taken_count(t.id, s.id, v_arrival);
  if p_quantity > v_free then
    raise exception 'only % of these tables are free for that time; tables that are already booked or held cannot be blocked', greatest(v_free, 0);
  end if;

  insert into public.site_table_blocks (venue_id, table_type_id, time_slot_id, booking_date, kind, quantity, reason, created_by, expires_at)
  values (p_venue, t.id, s.id, v_arrival, p_kind, p_quantity, v_reason, auth.uid(), case when p_kind = 'held' then now() + make_interval(mins => p_minutes) end)
  returning id into v_id;
  perform public.desk_log('table.' || case when p_kind = 'held' then 'held' else 'blocked' end, 'site_table_blocks', v_id,
    jsonb_build_object('venue_id', p_venue, 'table_type_id', t.id, 'quantity', p_quantity, 'reason', v_reason, 'minutes', p_minutes));
  return jsonb_build_object('block_id', v_id, 'free_after', v_free - p_quantity);
end;
$$;

-- Reopens tables: true when a block was ended now, false when it had already ended (released or run out), so a repeated tap changes nothing.
create function public.desk_table_release(p_block uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_table_blocks;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into b from public.site_table_blocks where id = p_block for update;
  if not found or public.desk_level(b.venue_id) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if b.released_at is not null or (b.expires_at is not null and b.expires_at <= now()) then return false; end if;
  update public.site_table_blocks set released_at = now(), released_by = auth.uid() where id = p_block;
  perform public.desk_log('table.reopened', 'site_table_blocks', p_block, jsonb_build_object('venue_id', b.venue_id, 'table_type_id', b.table_type_id, 'quantity', b.quantity));
  return true;
end;
$$;

-- The holds and unavailable tables in force for a night, with who made them and why.
create function public.desk_table_blocks(p_venue uuid, p_night date)
returns table (block_id uuid, table_type_id uuid, table_name text, slot_id uuid, start_time time, kind text, quantity int, reason text, made_by text, made_at timestamptz, expires_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'which night?'; end if;
  return query
    select k.id, k.table_type_id, t.name, k.time_slot_id, s.start_time, k.kind, k.quantity, k.reason,
           coalesce(nullif(btrim(pr.name), ''), 'Staff member'), k.created_at, k.expires_at
      from public.site_table_blocks k
      join public.site_table_types t on t.id = k.table_type_id
      join public.site_venue_time_slots s on s.id = k.time_slot_id
      left join public.profiles pr on pr.id = k.created_by
     where k.venue_id = p_venue and k.released_at is null and (k.expires_at is null or k.expires_at > now())
       and k.booking_date = case when s.start_time < time '06:00:00' then p_night + 1 else p_night end
     order by s.start_time, t.name, k.created_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Moving a booking to another table
-- ---------------------------------------------------------------------------
create function public.desk_move_booking(p_booking uuid, p_to_type uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  s public.site_venue_time_slots;
  f public.site_table_types;
  t public.site_table_types;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_night date;
  v_diff int;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_booking_level(p_booking) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then raise exception 'give a reason of 3 to 200 characters'; end if;

  select * into b from public.site_table_bookings where id = p_booking for update;
  if not found then raise exception 'not allowed'; end if;
  if b.status is distinct from 'paid' then raise exception 'only a confirmed booking can be moved'; end if;
  if b.table_type_id = p_to_type then raise exception 'the booking is already at that table'; end if;

  select * into s from public.site_venue_time_slots where id = b.time_slot_id;
  v_night := case when s.start_time < time '06:00:00' then b.booking_date - 1 else b.booking_date end;
  if exists (select 1 from public.site_night_closes c where c.venue_id = b.venue_id and c.business_night = v_night and c.status = 'closed') then
    raise exception 'this night has been closed, so the booking cannot be moved';
  end if;

  -- both table types are locked (always in the same order), so two people moving bookings at once cannot both take the last table
  perform 1 from public.site_table_types x where x.id in (b.table_type_id, p_to_type) order by x.id for update;
  select * into f from public.site_table_types where id = b.table_type_id;
  select * into t from public.site_table_types where id = p_to_type and venue_id = b.venue_id;
  if not found then raise exception 'table not found'; end if;

  if b.guest_count > t.max_guests then raise exception 'that table seats up to % guests and this booking has %', t.max_guests, b.guest_count; end if;
  if t.min_guests is not null and b.guest_count < t.min_guests then raise exception 'that table needs at least % guests and this booking has %', t.min_guests, b.guest_count; end if;
  if public.site_table_taken_count(t.id, b.time_slot_id, b.booking_date) >= t.inventory_count then raise exception 'no tables of that type are free for that time'; end if;

  v_diff := case when f.pricing_mode = 'flat' and t.pricing_mode = 'flat' then t.deposit_cents - f.deposit_cents end;
  update public.site_table_bookings set table_type_id = t.id, updated_at = now() where id = b.id;
  insert into public.site_booking_moves (booking_id, venue_id, from_table_type, to_table_type, from_name, to_name, price_difference_cents, reason, moved_by)
  values (b.id, b.venue_id, f.id, t.id, f.name, t.name, v_diff, v_reason, auth.uid()) returning id into v_id;
  perform public.desk_log('booking.moved', 'site_table_bookings', b.id, jsonb_build_object('venue_id', b.venue_id, 'reason', v_reason, 'from_table_type', f.id, 'to_table_type', t.id));
  return jsonb_build_object('move_id', v_id, 'from', f.name, 'to', t.name, 'price_difference_cents', v_diff);
end;
$$;

create function public.desk_booking_moves(p_booking uuid)
returns table (moved_at timestamptz, from_table text, to_table text, moved_by text, reason text, price_difference_cents int)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_booking_level(p_booking) is distinct from 'manager' then raise exception 'not allowed'; end if;
  return query
    select m.moved_at, m.from_name, m.to_name, coalesce(nullif(btrim(pr.name), ''), 'Staff member'), m.reason, m.price_difference_cents
      from public.site_booking_moves m
      left join public.profiles pr on pr.id = m.moved_by
     where m.booking_id = p_booking
     order by m.moved_at desc, m.id;
end;
$$;

-- The tables a confirmed booking could be moved to: every table type of the venue, how many are free for the booking's arrival time, whether the party fits
-- (seats and minimum), and the recorded price difference. The booking's own table is listed too and marked, so the app can show where it is now. The move itself
-- re-checks every one of these while it holds the tables, so this list is only what the app offers.
create function public.desk_booking_move_options(p_booking uuid)
returns table (table_type_id uuid, table_name text, max_guests int, min_guests int, available int, fits boolean, is_current boolean, price_difference_cents int)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  b public.site_table_bookings;
  f public.site_table_types;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_booking_level(p_booking) is distinct from 'manager' then raise exception 'not allowed'; end if;
  select * into b from public.site_table_bookings where id = p_booking;
  if not found then raise exception 'not allowed'; end if;
  select * into f from public.site_table_types where id = b.table_type_id;
  return query
    select t.id, t.name, t.max_guests, t.min_guests,
           greatest(t.inventory_count - public.site_table_taken_count(t.id, b.time_slot_id, b.booking_date), 0),
           b.guest_count <= t.max_guests and (t.min_guests is null or b.guest_count >= t.min_guests),
           t.id = b.table_type_id,
           case when f.pricing_mode = 'flat' and t.pricing_mode = 'flat' then t.deposit_cents - f.deposit_cents end
      from public.site_table_types t
     where t.venue_id = b.venue_id
     order by t.sort_order, t.created_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Deposit terms: the venue's default, and a copy on every new booking
-- ---------------------------------------------------------------------------
create function public.venue_deposit_terms(p_venue uuid)
returns table (terms jsonb, deposit_is_credit boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  return query select v.deposit_terms, v.deposit_is_credit from public.site_venues v where v.id = p_venue;
end;
$$;

create function public.save_venue_deposit_terms(p_venue uuid, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recipient text;
  v_pct int;
  v_purpose text;
  v_credit boolean;
  v_old jsonb;
  v_new jsonb;
begin
  perform public.require_venue_editor(p_venue);
  perform public.setup_only_keys(p_details, array['recipient', 'venue_pct', 'purpose']);

  v_recipient := public.setup_text(p_details, 'recipient', 'recipient', 20);
  v_pct := public.setup_int(p_details, 'venue_pct', 'the venue''s share', 0, 100);
  v_purpose := public.setup_text(p_details, 'purpose', 'purpose', 30);
  if v_recipient is null or v_recipient not in ('venue', 'organizer', 'split') then raise exception 'choose who receives the deposit: the venue, the approved organizer, or a split'; end if;
  if v_purpose is null or v_purpose not in ('reservation_fee', 'minimum_spend_credit', 'admission') then
    raise exception 'choose what the deposit is for: a reservation fee, a credit toward the minimum spend, or admission';
  end if;
  if v_recipient = 'venue' then
    if v_pct is not null and v_pct <> 100 then raise exception 'when the venue keeps the deposit its share is 100 percent'; end if;
    v_pct := 100;
  elsif v_recipient = 'organizer' then
    if v_pct is not null and v_pct <> 0 then raise exception 'when the organizer receives the deposit the venue''s share is 0 percent'; end if;
    v_pct := 0;
  else
    if v_pct is null or v_pct < 1 or v_pct > 99 then raise exception 'for a split give the venue''s share between 1 and 99 percent (the organizer gets the rest, so the two add up to 100)'; end if;
  end if;

  select v.deposit_is_credit, v.deposit_terms into v_credit, v_old from public.site_venues v where v.id = p_venue for update;
  if not found then raise exception 'not allowed'; end if;
  -- the credit switch is owned by BottlesUp (bookings are worked out with it), so the purpose has to agree with it
  if v_purpose = 'minimum_spend_credit' and not v_credit then
    raise exception 'the deposit is not credited toward the bottle bill at this venue, so it cannot be a minimum spend credit; choose reservation fee or admission, or ask the BottlesUp team to switch the credit on';
  end if;
  if v_purpose <> 'minimum_spend_credit' and v_credit then
    raise exception 'the deposit is credited toward the bottle bill at this venue, so its purpose is a minimum spend credit; ask the BottlesUp team if that should change';
  end if;

  v_new := jsonb_build_object('recipient', v_recipient, 'venue_pct', v_pct, 'purpose', v_purpose);
  if v_old is not distinct from v_new then return v_new; end if;
  update public.site_venues set deposit_terms = v_new where id = p_venue;
  perform public.venue_setup_log('venue.deposit_terms_saved', 'site_venues', p_venue, p_venue, jsonb_build_object('from', v_old, 'to', v_new));
  return v_new;
end;
$$;

-- Every new booking carries the terms it was made under: the venue's deposit terms and the table's included admissions, copied when the row is made, whichever
-- function or edge function makes it. (Changing the venue's terms later never touches a booking that exists.)
create function public.site_table_bookings_snapshot_terms()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_terms jsonb;
  v_credit boolean;
  v_adm int;
begin
  if new.deposit_terms is null then
    select v.deposit_terms, v.deposit_is_credit into v_terms, v_credit from public.site_venues v where v.id = new.venue_id;
    new.deposit_terms := coalesce(v_terms, jsonb_build_object(
      'recipient', 'venue', 'venue_pct', 100, 'purpose', case when coalesce(v_credit, false) then 'minimum_spend_credit' else 'reservation_fee' end, 'default', true));
  end if;
  if new.included_admissions is null then
    select t.included_admissions into v_adm from public.site_table_types t where t.id = new.table_type_id;
    new.included_admissions := v_adm;
  end if;
  return new;
end;
$$;
create trigger site_table_bookings_snapshot_terms before insert on public.site_table_bookings
  for each row execute function public.site_table_bookings_snapshot_terms();
revoke all on function public.site_table_bookings_snapshot_terms() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------------
revoke all on function
  public.list_venue_table_layout(uuid), public.place_venue_table(uuid, uuid, uuid, numeric, numeric, numeric, numeric), public.unplace_venue_table(uuid, uuid),
  public.set_table_included_admissions(uuid, uuid, int), public.desk_table_states(uuid, date), public.desk_table_block(uuid, date, uuid, uuid, text, int, text, int),
  public.desk_table_release(uuid), public.desk_table_blocks(uuid, date), public.desk_move_booking(uuid, uuid, text), public.desk_booking_moves(uuid), public.desk_booking_move_options(uuid),
  public.venue_deposit_terms(uuid), public.save_venue_deposit_terms(uuid, jsonb)
  from public, anon;
grant execute on function
  public.list_venue_table_layout(uuid), public.place_venue_table(uuid, uuid, uuid, numeric, numeric, numeric, numeric), public.unplace_venue_table(uuid, uuid),
  public.set_table_included_admissions(uuid, uuid, int), public.desk_table_states(uuid, date), public.desk_table_block(uuid, date, uuid, uuid, text, int, text, int),
  public.desk_table_release(uuid), public.desk_table_blocks(uuid, date), public.desk_move_booking(uuid, uuid, text), public.desk_booking_moves(uuid), public.desk_booking_move_options(uuid),
  public.venue_deposit_terms(uuid), public.save_venue_deposit_terms(uuid, jsonb)
  to authenticated, service_role;
-- the three replaced functions keep the grants they already had (create or replace does not change them)
