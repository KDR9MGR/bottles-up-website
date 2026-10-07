-- Owner venue setup: booking-rule arrival times, floors, table types and the bottle menu.
--
-- Client brief, section 2 (venue onboarding): after a business owns a venue it must be able to set the venue up itself:
-- the days and arrival times it accepts bookings, a floor plan, the table types guests book, and the bottle menu.
-- Until now only the BottlesUp admin could write these four tables (RLS "admins manage ...").
--
-- HOW: owners and managers get their own functions instead of write policies on the tables.
--   * Each function checks the person may edit THIS venue (can_access_venue, owner or manager), then writes only the
--     whitelisted fields the admin CMS already writes. Nothing else: no venue status, no slug, no organization.
--   * A row id passed in must belong to the venue passed in, so a manager of one club cannot reach another club's rows by
--     guessing an id.
--   * Deleting something that bookings still point at is refused with a plain sentence instead of a database error.
--   * Every change is attributed in audit_log (who, what, which venue), like the CMS does.
--
-- DELIBERATELY NOT HERE:
--   * table_view, privacy_level, seating_type, amenities, policy_note on table types: these columns exist in production but in
--     no committed migration, so they cannot be tested here. Owners leave them untouched (existing values survive an edit);
--     the BottlesUp admin still edits them in the CMS.
--   * Placing a table type on a floor plan (floor_id, pos_x, pos_y, width, height): that is a drag-and-drop editor and stays
--     in the CMS for now. Editing a table type here never moves it.
--
-- Functions use plain CREATE, never CREATE OR REPLACE, so a name collision in the shared database fails loudly.

-- ---------------------------------------------------------------------------
-- 1. Small internal helpers (not callable from the app)
-- ---------------------------------------------------------------------------

-- The one permission check every function below starts with.
create function public.require_venue_editor(p_venue uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then
    raise exception 'not allowed';
  end if;
end;
$$;

-- Attribution. Only the functions below call this: the app cannot, or anyone could forge audit entries.
create function public.venue_setup_log(p_action text, p_entity_type text, p_entity_id uuid, p_venue uuid, p_details jsonb default null)
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
    p_entity_id::text,
    coalesce(p_details, '{}'::jsonb) || jsonb_build_object('venue_id', p_venue)
  )
$$;

-- Only these keys may appear in a details object.
create function public.setup_only_keys(p jsonb, p_allowed text[])
returns void
language plpgsql
immutable
set search_path = public
as $$
declare v_key text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'details must be an object'; end if;
  for v_key in select jsonb_object_keys(p) loop
    if not (v_key = any (p_allowed)) then raise exception 'unknown field: %', v_key; end if;
  end loop;
end;
$$;

-- A whole number within bounds, or null when the key is missing or JSON null.
create function public.setup_int(p jsonb, p_key text, p_label text, p_min int, p_max int)
returns int
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := p -> p_key;
  t text;
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  t := v #>> '{}';
  if jsonb_typeof(v) <> 'number' or t !~ '^-?[0-9]{1,9}$' then raise exception '% must be a whole number', p_label; end if;
  if t::int < p_min or t::int > p_max then raise exception '% must be between % and %', p_label, p_min, p_max; end if;
  return t::int;
end;
$$;

-- Trimmed text of at most p_max characters, or null when missing, JSON null or blank.
create function public.setup_text(p jsonb, p_key text, p_label text, p_max int)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := p -> p_key;
  t text;
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  if jsonb_typeof(v) <> 'string' then raise exception '% must be text', p_label; end if;
  t := nullif(btrim(v #>> '{}'), '');
  if t is not null and length(t) > p_max then raise exception '% must be % characters or fewer', p_label, p_max; end if;
  return t;
end;
$$;

-- An https link of at most 500 characters, or null.
create function public.setup_url(p jsonb, p_key text, p_label text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare t text := public.setup_text(p, p_key, p_label, 500);
begin
  if t is not null and t !~ '^https://[^[:space:]]+$' then raise exception '% must be an https link', p_label; end if;
  return t;
end;
$$;

-- true or false, or null when the key is missing or JSON null.
create function public.setup_bool(p jsonb, p_key text, p_label text)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare v jsonb := p -> p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  if jsonb_typeof(v) <> 'boolean' then raise exception '% must be true or false', p_label; end if;
  return (v #>> '{}')::boolean;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Booking rules: the days and arrival times a venue accepts bookings
-- ---------------------------------------------------------------------------
create function public.list_venue_time_slots(p_venue uuid)
returns table (slot_id uuid, day_of_week int, start_time time, label text, booking_count bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  return query
    select s.id, s.day_of_week, s.start_time, s.label,
           (select count(*) from public.site_table_bookings b where b.time_slot_id = s.id)
    from public.site_venue_time_slots s
    where s.venue_id = p_venue
    order by s.day_of_week, s.start_time;
end;
$$;

create function public.add_venue_time_slot(p_venue uuid, p_day int, p_start time, p_label text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
  v_id uuid;
begin
  perform public.require_venue_editor(p_venue);
  if p_day is null or p_day < 0 or p_day > 6 then raise exception 'day must be between 0 (Sunday) and 6 (Saturday)'; end if;
  if p_start is null then raise exception 'an arrival time is required'; end if;
  if v_label is not null and length(v_label) > 60 then raise exception 'label must be 60 characters or fewer'; end if;

  -- Two people adding at once must not both pass the checks below.
  perform 1 from public.site_venues v where v.id = p_venue for update;
  if exists (select 1 from public.site_venue_time_slots s where s.venue_id = p_venue and s.day_of_week = p_day and s.start_time = p_start) then
    raise exception 'that arrival time is already added';
  end if;
  if (select count(*) from public.site_venue_time_slots s where s.venue_id = p_venue) >= 150 then
    raise exception 'a venue can have 150 arrival times at most';
  end if;

  insert into public.site_venue_time_slots (venue_id, day_of_week, start_time, label)
  values (p_venue, p_day, p_start, v_label)
  returning id into v_id;

  perform public.venue_setup_log('venue_setup.time_slot_added', 'site_venue_time_slots', v_id, p_venue,
    jsonb_build_object('day_of_week', p_day, 'start_time', p_start::text));
  return v_id;
end;
$$;

create function public.remove_venue_time_slot(p_venue uuid, p_slot uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  begin
    delete from public.site_venue_time_slots s where s.id = p_slot and s.venue_id = p_venue;
  exception when foreign_key_violation then
    raise exception 'this arrival time has bookings, so it cannot be removed';
  end;
  if not found then raise exception 'arrival time not found'; end if;
  perform public.venue_setup_log('venue_setup.time_slot_removed', 'site_venue_time_slots', p_slot, p_venue);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Floors (the floor plan image tables are placed on)
-- ---------------------------------------------------------------------------
create function public.list_venue_floors(p_venue uuid)
returns table (floor_id uuid, label text, image_url text, sort_order int, table_count bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  return query
    select f.id, f.label, f.image_url, f.sort_order,
           (select count(*) from public.site_table_types t where t.floor_id = f.id)
    from public.site_venue_floors f
    where f.venue_id = p_venue
    order by f.sort_order, f.created_at;
end;
$$;

-- p_floor null = add a new floor; otherwise change that floor (which must belong to p_venue).
create function public.save_venue_floor(p_venue uuid, p_floor uuid, p_label text, p_image_url text, p_sort_order int default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
  v_image text := nullif(btrim(coalesce(p_image_url, '')), '');
  v_id uuid;
  v_sort int;
begin
  perform public.require_venue_editor(p_venue);
  if v_label is null then raise exception 'a floor name is required'; end if;
  if length(v_label) > 60 then raise exception 'floor name must be 60 characters or fewer'; end if;
  if v_image is null then raise exception 'a floor plan image is required'; end if;
  if v_image !~ '^https://[^[:space:]]+$' or length(v_image) > 500 then raise exception 'floor plan image must be an https link'; end if;
  if p_sort_order is not null and (p_sort_order < 0 or p_sort_order > 10000) then raise exception 'order must be between 0 and 10000'; end if;

  perform 1 from public.site_venues v where v.id = p_venue for update;

  if p_floor is null then
    if (select count(*) from public.site_venue_floors f where f.venue_id = p_venue) >= 10 then
      raise exception 'a venue can have 10 floors at most';
    end if;
    v_sort := coalesce(p_sort_order, (select coalesce(max(f.sort_order) + 1, 0) from public.site_venue_floors f where f.venue_id = p_venue));
    insert into public.site_venue_floors (venue_id, label, image_url, sort_order)
    values (p_venue, v_label, v_image, v_sort)
    returning id into v_id;
    perform public.venue_setup_log('venue_setup.floor_added', 'site_venue_floors', v_id, p_venue, jsonb_build_object('label', v_label));
  else
    update public.site_venue_floors f set
      label = v_label,
      image_url = v_image,
      sort_order = coalesce(p_sort_order, f.sort_order),
      updated_at = now()
    where f.id = p_floor and f.venue_id = p_venue
    returning f.id into v_id;
    if v_id is null then raise exception 'floor not found'; end if;
    perform public.venue_setup_log('venue_setup.floor_updated', 'site_venue_floors', v_id, p_venue, jsonb_build_object('label', v_label));
  end if;
  return v_id;
end;
$$;

-- Tables placed on the floor stay (as table types) but become unplaced: a position means nothing without its floor,
-- which is also what the CMS saves for an unplaced table.
create function public.remove_venue_floor(p_venue uuid, p_floor uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  if not exists (select 1 from public.site_venue_floors f where f.id = p_floor and f.venue_id = p_venue) then
    raise exception 'floor not found';
  end if;
  update public.site_table_types t set floor_id = null, pos_x = null, pos_y = null, width = null, height = null
  where t.floor_id = p_floor and t.venue_id = p_venue;
  delete from public.site_venue_floors f where f.id = p_floor and f.venue_id = p_venue;
  perform public.venue_setup_log('venue_setup.floor_removed', 'site_venue_floors', p_floor, p_venue);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Table types
-- ---------------------------------------------------------------------------
create function public.list_venue_table_types(p_venue uuid)
returns table (
  type_id uuid, name text, description text, max_guests int, min_guests int, min_spend_cents int, deposit_cents int,
  inventory_count int, image_url text, badge_label text, is_featured boolean, pricing_mode text, hourly_rate_cents int,
  min_hours int, floor_id uuid, sort_order int, booking_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  return query
    select t.id, t.name, t.description, t.max_guests, t.min_guests, t.min_spend_cents, t.deposit_cents,
           t.inventory_count, t.image_url, t.badge_label, t.is_featured, t.pricing_mode, t.hourly_rate_cents,
           t.min_hours, t.floor_id, t.sort_order,
           (select count(*) from public.site_table_bookings b where b.table_type_id = t.id)
    from public.site_table_types t
    where t.venue_id = p_venue
    order by t.sort_order, t.created_at;
end;
$$;

-- p_type null = add a new table type; otherwise change that one (which must belong to p_venue). Only the keys present in
-- p_details change, so an edit never wipes a field the person did not send.
create function public.save_venue_table_type(p_venue uuid, p_type uuid, p_details jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.site_table_types;
  v_name text; v_description text; v_max int; v_min_guests int; v_spend int; v_deposit int; v_inventory int;
  v_image text; v_badge text; v_featured boolean; v_mode text; v_rate int; v_hours int; v_sort int;
  v_id uuid;
begin
  perform public.require_venue_editor(p_venue);
  perform public.setup_only_keys(p_details, array[
    'name', 'description', 'max_guests', 'min_guests', 'min_spend_cents', 'deposit_cents', 'inventory_count',
    'image_url', 'badge_label', 'is_featured', 'pricing_mode', 'hourly_rate_cents', 'min_hours', 'sort_order'
  ]);

  perform 1 from public.site_venues v where v.id = p_venue for update;

  if p_type is not null then
    select * into v_row from public.site_table_types t where t.id = p_type and t.venue_id = p_venue for update;
    if not found then raise exception 'table type not found'; end if;
    v_name := v_row.name; v_description := v_row.description; v_max := v_row.max_guests; v_min_guests := v_row.min_guests;
    v_spend := v_row.min_spend_cents; v_deposit := v_row.deposit_cents; v_inventory := v_row.inventory_count;
    v_image := v_row.image_url; v_badge := v_row.badge_label; v_featured := v_row.is_featured; v_mode := v_row.pricing_mode;
    v_rate := v_row.hourly_rate_cents; v_hours := v_row.min_hours; v_sort := v_row.sort_order;
  else
    if (select count(*) from public.site_table_types t where t.venue_id = p_venue) >= 50 then
      raise exception 'a venue can have 50 table types at most';
    end if;
    v_spend := 0; v_deposit := 0; v_featured := false; v_mode := 'flat';
    v_sort := (select coalesce(max(t.sort_order) + 1, 0) from public.site_table_types t where t.venue_id = p_venue);
  end if;

  if p_details ? 'name' then v_name := public.setup_text(p_details, 'name', 'name', 120); end if;
  if p_details ? 'description' then v_description := public.setup_text(p_details, 'description', 'description', 2000); end if;
  if p_details ? 'max_guests' then v_max := public.setup_int(p_details, 'max_guests', 'maximum guests', 1, 100); end if;
  if p_details ? 'min_guests' then v_min_guests := public.setup_int(p_details, 'min_guests', 'minimum guests', 1, 100); end if;
  if p_details ? 'min_spend_cents' then v_spend := public.setup_int(p_details, 'min_spend_cents', 'minimum spend', 0, 100000000); end if;
  if p_details ? 'deposit_cents' then v_deposit := public.setup_int(p_details, 'deposit_cents', 'deposit', 0, 100000000); end if;
  if p_details ? 'inventory_count' then v_inventory := public.setup_int(p_details, 'inventory_count', 'number of tables', 0, 500); end if;
  if p_details ? 'image_url' then v_image := public.setup_url(p_details, 'image_url', 'image'); end if;
  if p_details ? 'badge_label' then v_badge := public.setup_text(p_details, 'badge_label', 'badge', 40); end if;
  if p_details ? 'is_featured' then v_featured := public.setup_bool(p_details, 'is_featured', 'featured'); end if;
  if p_details ? 'pricing_mode' then v_mode := public.setup_text(p_details, 'pricing_mode', 'pricing mode', 20); end if;
  if p_details ? 'hourly_rate_cents' then v_rate := public.setup_int(p_details, 'hourly_rate_cents', 'hourly rate', 0, 100000000); end if;
  if p_details ? 'min_hours' then v_hours := public.setup_int(p_details, 'min_hours', 'minimum hours', 1, 24); end if;
  if p_details ? 'sort_order' then v_sort := public.setup_int(p_details, 'sort_order', 'order', 0, 10000); end if;

  if v_name is null then raise exception 'a table name is required'; end if;
  if v_max is null then raise exception 'maximum guests is required'; end if;
  if v_inventory is null then raise exception 'the number of tables is required'; end if;
  if v_spend is null then raise exception 'minimum spend is required (use 0 for none)'; end if;
  if v_deposit is null then raise exception 'deposit is required (use 0 for none)'; end if;
  if v_featured is null then raise exception 'featured must be true or false'; end if;
  if v_min_guests is not null and v_min_guests > v_max then raise exception 'minimum guests cannot be more than maximum guests'; end if;
  if v_mode is null or v_mode not in ('flat', 'hourly') then raise exception 'pricing mode must be flat or hourly'; end if;
  if v_mode = 'hourly' then
    if v_rate is null or v_rate < 1 then raise exception 'an hourly rate is required for hourly pricing'; end if;
    v_hours := coalesce(v_hours, 1);
  else
    v_rate := null; v_hours := null;
  end if;

  if p_type is null then
    insert into public.site_table_types (
      venue_id, name, description, max_guests, min_guests, min_spend_cents, deposit_cents, inventory_count,
      image_url, badge_label, is_featured, pricing_mode, hourly_rate_cents, min_hours, sort_order
    ) values (
      p_venue, v_name, v_description, v_max, v_min_guests, v_spend, v_deposit, v_inventory,
      v_image, v_badge, v_featured, v_mode, v_rate, v_hours, v_sort
    ) returning id into v_id;
    perform public.venue_setup_log('venue_setup.table_type_added', 'site_table_types', v_id, p_venue, jsonb_build_object('name', v_name));
  else
    update public.site_table_types t set
      name = v_name, description = v_description, max_guests = v_max, min_guests = v_min_guests,
      min_spend_cents = v_spend, deposit_cents = v_deposit, inventory_count = v_inventory,
      image_url = v_image, badge_label = v_badge, is_featured = v_featured, pricing_mode = v_mode,
      hourly_rate_cents = v_rate, min_hours = v_hours, sort_order = v_sort, updated_at = now()
    where t.id = p_type and t.venue_id = p_venue
    returning t.id into v_id;
    perform public.venue_setup_log('venue_setup.table_type_updated', 'site_table_types', v_id, p_venue, jsonb_build_object('name', v_name));
  end if;
  return v_id;
end;
$$;

create function public.remove_venue_table_type(p_venue uuid, p_type uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  begin
    delete from public.site_table_types t where t.id = p_type and t.venue_id = p_venue;
  exception when foreign_key_violation then
    raise exception 'this table type has bookings, so it cannot be removed. Lower the number of tables or rename it instead';
  end;
  if not found then raise exception 'table type not found'; end if;
  perform public.venue_setup_log('venue_setup.table_type_removed', 'site_table_types', p_type, p_venue);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Bottle menu
-- ---------------------------------------------------------------------------
create function public.list_venue_bottles(p_venue uuid)
returns table (
  bottle_id uuid, name text, size text, description text, price_cents int, category text, image_url text,
  is_available boolean, is_sold_out boolean, stock_quantity int, sort_order int
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  return query
    select b.id, b.name, b.size, b.description, b.price_cents, b.category, b.image_url,
           b.is_available, b.is_sold_out, b.stock_quantity, b.sort_order
    from public.site_bottles b
    where b.venue_id = p_venue
    order by b.sort_order, b.created_at;
end;
$$;

create function public.save_venue_bottle(p_venue uuid, p_bottle uuid, p_details jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.site_bottles;
  v_name text; v_size text; v_description text; v_price int; v_category text; v_image text;
  v_available boolean; v_sold_out boolean; v_stock int; v_sort int;
  v_id uuid;
begin
  perform public.require_venue_editor(p_venue);
  perform public.setup_only_keys(p_details, array[
    'name', 'size', 'description', 'price_cents', 'category', 'image_url', 'is_available', 'is_sold_out', 'stock_quantity', 'sort_order'
  ]);

  perform 1 from public.site_venues v where v.id = p_venue for update;

  if p_bottle is not null then
    select * into v_row from public.site_bottles b where b.id = p_bottle and b.venue_id = p_venue for update;
    if not found then raise exception 'bottle not found'; end if;
    v_name := v_row.name; v_size := v_row.size; v_description := v_row.description; v_price := v_row.price_cents;
    v_category := v_row.category; v_image := v_row.image_url; v_available := v_row.is_available;
    v_sold_out := v_row.is_sold_out; v_stock := v_row.stock_quantity; v_sort := v_row.sort_order;
  else
    if (select count(*) from public.site_bottles b where b.venue_id = p_venue) >= 300 then
      raise exception 'a venue can have 300 bottles at most';
    end if;
    v_available := true; v_sold_out := false;
    v_sort := (select coalesce(max(b.sort_order) + 1, 0) from public.site_bottles b where b.venue_id = p_venue);
  end if;

  if p_details ? 'name' then v_name := public.setup_text(p_details, 'name', 'name', 120); end if;
  if p_details ? 'size' then v_size := public.setup_text(p_details, 'size', 'size', 40); end if;
  if p_details ? 'description' then v_description := public.setup_text(p_details, 'description', 'description', 1000); end if;
  if p_details ? 'price_cents' then v_price := public.setup_int(p_details, 'price_cents', 'price', 0, 10000000); end if;
  if p_details ? 'category' then v_category := public.setup_text(p_details, 'category', 'category', 40); end if;
  if p_details ? 'image_url' then v_image := public.setup_url(p_details, 'image_url', 'image'); end if;
  if p_details ? 'is_available' then v_available := public.setup_bool(p_details, 'is_available', 'available'); end if;
  if p_details ? 'is_sold_out' then v_sold_out := public.setup_bool(p_details, 'is_sold_out', 'sold out'); end if;
  if p_details ? 'stock_quantity' then v_stock := public.setup_int(p_details, 'stock_quantity', 'stock', 0, 100000); end if;
  if p_details ? 'sort_order' then v_sort := public.setup_int(p_details, 'sort_order', 'order', 0, 10000); end if;

  if v_name is null then raise exception 'a bottle name is required'; end if;
  if v_price is null then raise exception 'a price is required'; end if;
  if v_available is null or v_sold_out is null then raise exception 'available and sold out must be true or false'; end if;

  if p_bottle is null then
    insert into public.site_bottles (venue_id, name, size, description, price_cents, category, image_url, is_available, is_sold_out, stock_quantity, sort_order)
    values (p_venue, v_name, v_size, v_description, v_price, v_category, v_image, v_available, v_sold_out, v_stock, v_sort)
    returning id into v_id;
    perform public.venue_setup_log('venue_setup.bottle_added', 'site_bottles', v_id, p_venue, jsonb_build_object('name', v_name));
  else
    update public.site_bottles b set
      name = v_name, size = v_size, description = v_description, price_cents = v_price, category = v_category,
      image_url = v_image, is_available = v_available, is_sold_out = v_sold_out, stock_quantity = v_stock,
      sort_order = v_sort, updated_at = now()
    where b.id = p_bottle and b.venue_id = p_venue
    returning b.id into v_id;
    perform public.venue_setup_log('venue_setup.bottle_updated', 'site_bottles', v_id, p_venue, jsonb_build_object('name', v_name));
  end if;
  return v_id;
end;
$$;

-- Past bottle orders keep their own copy of the name and price, so removing a bottle never changes a past order.
create function public.remove_venue_bottle(p_venue uuid, p_bottle uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_venue_editor(p_venue);
  delete from public.site_bottles b where b.id = p_bottle and b.venue_id = p_venue;
  if not found then raise exception 'bottle not found'; end if;
  perform public.venue_setup_log('venue_setup.bottle_removed', 'site_bottles', p_bottle, p_venue);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
-- The helpers are internal. venue_setup_log in particular must never be callable by a signed-in user, or they could write
-- audit entries in anyone's name.
revoke all on function
  public.require_venue_editor(uuid),
  public.venue_setup_log(text, text, uuid, uuid, jsonb),
  public.setup_only_keys(jsonb, text[]),
  public.setup_int(jsonb, text, text, int, int),
  public.setup_text(jsonb, text, text, int),
  public.setup_url(jsonb, text, text),
  public.setup_bool(jsonb, text, text)
  from public, anon, authenticated;

revoke all on function
  public.list_venue_time_slots(uuid), public.add_venue_time_slot(uuid, int, time, text), public.remove_venue_time_slot(uuid, uuid),
  public.list_venue_floors(uuid), public.save_venue_floor(uuid, uuid, text, text, int), public.remove_venue_floor(uuid, uuid),
  public.list_venue_table_types(uuid), public.save_venue_table_type(uuid, uuid, jsonb), public.remove_venue_table_type(uuid, uuid),
  public.list_venue_bottles(uuid), public.save_venue_bottle(uuid, uuid, jsonb), public.remove_venue_bottle(uuid, uuid)
  from public, anon;
grant execute on function
  public.list_venue_time_slots(uuid), public.add_venue_time_slot(uuid, int, time, text), public.remove_venue_time_slot(uuid, uuid),
  public.list_venue_floors(uuid), public.save_venue_floor(uuid, uuid, text, text, int), public.remove_venue_floor(uuid, uuid),
  public.list_venue_table_types(uuid), public.save_venue_table_type(uuid, uuid, jsonb), public.remove_venue_table_type(uuid, uuid),
  public.list_venue_bottles(uuid), public.save_venue_bottle(uuid, uuid, jsonb), public.remove_venue_bottle(uuid, uuid)
  to authenticated, service_role;
