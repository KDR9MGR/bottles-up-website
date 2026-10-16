-- Inventory ledger (client Phase 2 brief, section 22: "Movements ledger, receive, adjust, wastage, closing count, low-stock thresholds").
--
-- A bottle's stock level is site_bottles.stock_quantity (null = not counted / unlimited, which is how the booking pages already read it).
-- This adds the RECORD of how it changed by hand: every receive, wastage, adjustment and count is a movement with who, when, why, and the
-- level before and after. Levels also move when bottles are ordered, outside this ledger; each movement's "before" is the level at that
-- moment, so a gap between one movement's "after" and the next one's "before" is what orders took in between (the app says so).
--
--   * RECEIVE adds stock; WASTAGE removes it (breakage, spillage, gifts) and says why; ADJUST fixes a mistake by a plus or minus amount and
--     says why; COUNT sets the level to what was actually counted (the first count also starts tracking a bottle). Stock never goes below 0.
--   * Each movement can carry a client key, so a double tap or a retry after a bad connection is ONE movement, never two receipts.
--   * Manager and owner of THAT club only. Nobody edits or deletes a movement. Low-stock levels are set per bottle.
--
-- Plain CREATE, never CREATE OR REPLACE. Needs the venue setup migration (site_bottles).

-- ---------------------------------------------------------------------------
-- 1. Tables (reached only through the functions below)
-- ---------------------------------------------------------------------------
-- Movements are kept: the club cannot be deleted while any exist. A bottle can be removed from the menu: its history stays, under the name it
-- had when each movement was made.
create table public.site_stock_movements (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id),
  bottle_id uuid references public.site_bottles (id) on delete set null,
  bottle_name text not null,
  bottle_size text,
  kind text not null check (kind in ('receive', 'wastage', 'adjust', 'count')),
  delta int not null,
  before_qty int check (before_qty is null or before_qty >= 0),
  after_qty int not null check (after_qty >= 0),
  reason text check (reason is null or char_length(reason) <= 200),
  note text check (note is null or char_length(note) <= 300),
  business_night date,
  client_key text check (client_key is null or char_length(client_key) <= 64),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default clock_timestamp()
);
create index site_stock_movements_bottle_idx on public.site_stock_movements (bottle_id, created_at desc, id desc);
create index site_stock_movements_venue_idx on public.site_stock_movements (venue_id, created_at desc, id desc);
create unique index site_stock_movements_client_key_idx on public.site_stock_movements (venue_id, created_by, client_key) where client_key is not null;

create table public.site_stock_thresholds (
  bottle_id uuid primary key references public.site_bottles (id) on delete cascade,
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  low_threshold int not null check (low_threshold between 0 and 100000),
  set_by uuid not null references auth.users (id),
  set_at timestamptz not null default clock_timestamp()
);

alter table public.site_stock_movements enable row level security;
alter table public.site_stock_thresholds enable row level security;
revoke all on table public.site_stock_movements, public.site_stock_thresholds from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The stock of a club
-- ---------------------------------------------------------------------------
create function public.stock_list(p_venue uuid)
returns table (
  bottle_id uuid, name text, size text, tracked boolean, quantity int, low_threshold int, is_low boolean, is_sold_out boolean, last_moved_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;

  return query
    select b.id, b.name, b.size, b.stock_quantity is not null, b.stock_quantity, t.low_threshold,
           b.stock_quantity is not null and t.low_threshold is not null and b.stock_quantity <= t.low_threshold,
           coalesce(b.is_sold_out, false),
           (select max(m.created_at) from public.site_stock_movements m where m.bottle_id = b.id)
    from public.site_bottles b
    left join public.site_stock_thresholds t on t.bottle_id = b.id
    where b.venue_id = p_venue
    order by (b.stock_quantity is not null and t.low_threshold is not null and b.stock_quantity <= t.low_threshold) desc, lower(b.name), b.size nulls first, b.id
    limit 500;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Movements
-- ---------------------------------------------------------------------------
-- p_quantity: receive and wastage take a positive amount; adjust a plus or minus amount (not 0); count the amount counted (0 or more).
create function public.stock_move(
  p_venue uuid, p_bottle uuid, p_kind text, p_quantity int, p_reason text default null, p_note text default null, p_client_key text default null, p_night date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_bottles;
  v_reason text;
  v_note text;
  v_key text;
  v_before int;
  v_after int;
  v_delta int;
  m public.site_stock_movements;
  v_low int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if p_kind is null or p_kind not in ('receive', 'wastage', 'adjust', 'count') then raise exception 'choose receive, wastage, adjust or count'; end if;
  v_key := nullif(btrim(p_client_key), '');
  if v_key is not null and char_length(v_key) > 64 then raise exception 'that key is too long'; end if;
  v_reason := nullif(btrim(p_reason), '');
  v_note := nullif(btrim(p_note), '');
  if v_reason is not null and char_length(v_reason) > 200 then raise exception 'keep the reason to 200 characters or fewer'; end if;
  if v_note is not null and char_length(v_note) > 300 then raise exception 'keep the note to 300 characters or fewer'; end if;
  if p_night is not null and abs(p_night - current_date) > 2 then raise exception 'that is not a current night'; end if;

  -- A retry (same key, same person) is the movement already recorded.
  if v_key is not null then
    select * into m from public.site_stock_movements x where x.venue_id = p_venue and x.created_by = auth.uid() and x.client_key = v_key;
    if found then
      return jsonb_build_object('movement_id', m.id, 'changed', false, 'before', m.before_qty, 'after', m.after_qty);
    end if;
  end if;

  select * into b from public.site_bottles x where x.id = p_bottle and x.venue_id = p_venue for update;
  if not found then raise exception 'not allowed'; end if;
  v_before := b.stock_quantity;

  if p_kind = 'count' then
    if p_quantity is null or p_quantity < 0 then raise exception 'enter the amount you counted (0 or more)'; end if;
    if p_quantity > 100000 then raise exception 'that is more than can be recorded'; end if;
    v_after := p_quantity;
    v_delta := v_after - coalesce(v_before, v_after);
  else
    if v_before is null then raise exception 'this bottle has not been counted yet: count it first'; end if;
    if p_kind = 'receive' then
      if p_quantity is null or p_quantity <= 0 then raise exception 'enter how many arrived'; end if;
      v_delta := p_quantity;
    elsif p_kind = 'wastage' then
      if p_quantity is null or p_quantity <= 0 then raise exception 'enter how many were lost'; end if;
      if v_reason is null or char_length(v_reason) < 3 then raise exception 'say what happened to them'; end if;
      v_delta := -p_quantity;
    else
      if p_quantity is null or p_quantity = 0 then raise exception 'enter the plus or minus amount'; end if;
      if v_reason is null or char_length(v_reason) < 3 then raise exception 'say why the level is being changed'; end if;
      v_delta := p_quantity;
    end if;
    if abs(v_delta) > 100000 then raise exception 'that is more than can be recorded'; end if;
    v_after := v_before + v_delta;
    if v_after < 0 then raise exception 'only % in stock', v_before; end if;
    if v_after > 100000 then raise exception 'that is more than can be recorded'; end if;
  end if;

  update public.site_bottles set stock_quantity = v_after where id = p_bottle;
  insert into public.site_stock_movements (venue_id, bottle_id, bottle_name, bottle_size, kind, delta, before_qty, after_qty, reason, note, business_night, client_key, created_by)
    values (p_venue, p_bottle, b.name, b.size, p_kind, v_delta, v_before, v_after, v_reason, v_note, p_night, v_key, auth.uid())
    returning * into m;
  perform public.desk_log('stock.' || p_kind, 'site_stock_movements', m.id,
    jsonb_build_object('venue_id', p_venue, 'bottle_id', p_bottle, 'delta', v_delta, 'before', v_before, 'after', v_after));
  select t.low_threshold into v_low from public.site_stock_thresholds t where t.bottle_id = p_bottle;
  return jsonb_build_object('movement_id', m.id, 'changed', true, 'before', v_before, 'after', v_after, 'low', v_low is not null and v_after <= v_low);
end;
$$;

-- Set (or with null, clear) the level at which a bottle counts as low.
create function public.stock_set_threshold(p_venue uuid, p_bottle uuid, p_threshold int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.site_bottles b where b.id = p_bottle and b.venue_id = p_venue) then raise exception 'not allowed'; end if;
  if p_threshold is not null and (p_threshold < 0 or p_threshold > 100000) then raise exception 'enter a low-stock level from 0 to 100000'; end if;

  if p_threshold is null then
    delete from public.site_stock_thresholds where bottle_id = p_bottle;
  else
    insert into public.site_stock_thresholds (bottle_id, venue_id, low_threshold, set_by) values (p_bottle, p_venue, p_threshold, auth.uid())
      on conflict (bottle_id) do update set low_threshold = excluded.low_threshold, set_by = excluded.set_by, set_at = clock_timestamp();
  end if;
  perform public.desk_log('stock.threshold', 'site_bottles', p_bottle, jsonb_build_object('venue_id', p_venue, 'threshold', p_threshold));
end;
$$;

-- The ledger, newest first: one bottle's, or the whole club's. A page is at most 100.
create function public.stock_movements(p_venue uuid, p_bottle uuid default null, p_limit int default 50, p_before timestamptz default null)
returns table (
  movement_id uuid, bottle_id uuid, bottle_name text, size text, kind text, delta int, before_qty int, after_qty int, reason text, note text,
  by_name text, by_me boolean, created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;

  return query
    select m.id, m.bottle_id, m.bottle_name, m.bottle_size, m.kind, m.delta, m.before_qty, m.after_qty, m.reason, m.note,
           coalesce(nullif(btrim(pr.name), ''), 'Staff member'), m.created_by = auth.uid(), m.created_at
    from public.site_stock_movements m
    left join public.profiles pr on pr.id = m.created_by
    where m.venue_id = p_venue and (p_bottle is null or m.bottle_id = p_bottle) and (p_before is null or m.created_at < p_before)
    order by m.created_at desc, m.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.stock_list(uuid), public.stock_move(uuid, uuid, text, int, text, text, text, date), public.stock_set_threshold(uuid, uuid, int),
  public.stock_movements(uuid, uuid, int, timestamptz)
from public, anon;
grant execute on function
  public.stock_list(uuid), public.stock_move(uuid, uuid, text, int, text, text, text, date), public.stock_set_threshold(uuid, uuid, int),
  public.stock_movements(uuid, uuid, int, timestamptz)
to authenticated, service_role;
