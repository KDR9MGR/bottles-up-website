-- Complimentary bottle OFFERS with a claim link (client Phase 2 brief, section 20: "Unknown location: email/phone -> send secure claim link -> recipient sees venue/event/item/expiry -> chooses
-- location on map -> staff verify -> route to table/server -> prepare/deliver"; "One claim only; repeated opens do not create orders"; "Provide manual staff location resolution if link fails").
-- This is the DATABASE half. The public claim page and the e-mail that carries the link are NOT part of this migration: nothing is sent, and no function here can be called by a visitor.
--
--   WHAT AN OFFER IS: a bottle (and how many) a club's owner or manager offers to a person by e-mail, with a reason and an optional sign, that expires. It is NOT a sale and NOT yet a free bottle at a
--   table: when staff have placed the recipient at a booking, the offer is accepted THROUGH THE EXISTING FREE-BOTTLE PATH (desk_request_free_bottle, 20261024100000), so the club's own limits, its
--   approval rules, the stock and the "recorded as complimentary, never as sales" accounting are exactly the ones a free bottle at a known table already has. Nothing about eligibility is hard-coded here.
--
--   STATES (the brief's, in order): approved (the link has not been sent yet) -> sent -> awaiting_location (the link was opened) -> location_submitted -> accepted (placed at a booking; a free bottle
--   exists) -> delivered; or cancelled; or EXPIRED (shown, never stored: an offer that is not yet accepted and whose time has passed). "Awaiting approval" is not a state here: only an owner or a manager
--   creates an offer, and that is the approval (it is recorded as approved_by). A server cannot create one.
--
--   THE LINK: a random token of 244 bits made on the server at the moment the link is issued (comp_offer_issue_link), only its SHA-256 is stored, and issuing again replaces it (the old link stops
--   working). Only the service role can issue a link or read through one (comp_claim_view, comp_claim_submit): the public page will call them through an edge function that can rate-limit. The claim
--   shows the venue, the event, the item, the sign and the expiry, and the venue's table LABELS on its floor plan: never another guest's name or booking.
--   ONE CLAIM: a second submission, or opening the link again, changes nothing and creates nothing.
--
--   WHO MAY DO WHAT: the club's owner or manager (staff functions below); a manager needs the owner to have set the club's free-bottle limits first, the same rule as a free bottle at a table (and
--   the limits then apply when the offer is accepted). Nobody else; a visitor cannot call any of it.
--
-- Closed tables, reached only through the functions. Plain CREATE, never CREATE OR REPLACE. Needs the staff discounts and complimentary migration (20261024100000) and the floor plans.

do $pre$
declare
  r record;
begin
  for r in select * from (values
      ('public.can_access_venue(uuid, text[])'), ('public.desk_request_free_bottle(uuid, uuid, integer, text)'), ('public.desk_log(text, text, uuid, jsonb)'),
      ('public.booking_night(date, time without time zone)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
  if to_regclass('public.site_discount_limits') is null or to_regclass('public.site_concessions') is null then
    raise exception 'the staff discounts and complimentary tables are missing: run migration 20261024100000 first. Nothing was changed.';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. The table (closed)
-- ---------------------------------------------------------------------------
create table public.site_comp_offers (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id),
  event_id uuid references public.site_events (id) on delete set null,
  bottle_id uuid references public.site_bottles (id) on delete set null,
  bottle_name text not null check (char_length(bottle_name) between 1 and 120),
  bottle_size text,
  quantity int not null check (quantity between 1 and 12),
  value_cents int not null check (value_cents >= 0),
  recipient_email text not null check (char_length(recipient_email) <= 254 and recipient_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  recipient_name text check (recipient_name is null or char_length(recipient_name) between 1 and 60),
  reason text not null check (char_length(reason) between 3 and 300),
  sign_text text check (sign_text is null or (char_length(sign_text) between 1 and 40 and sign_text !~ '[[:cntrl:]]')),
  status text not null default 'approved' check (status in ('approved', 'sent', 'awaiting_location', 'location_submitted', 'accepted', 'delivered', 'cancelled')),
  expires_at timestamptz not null,
  token_hash text unique,
  created_by uuid references auth.users (id) on delete set null,
  approved_by uuid references auth.users (id) on delete set null,
  approved_at timestamptz not null default clock_timestamp(),
  sent_at timestamptz,
  claimed_at timestamptz,
  location_table_id uuid references public.site_table_types (id) on delete set null,
  location_set_by text check (location_set_by is null or location_set_by in ('recipient', 'staff')),
  location_set_at timestamptz,
  accepted_by uuid references auth.users (id) on delete set null,
  accepted_at timestamptz,
  booking_id uuid references public.site_table_bookings (id) on delete set null,
  concession_id uuid references public.site_concessions (id) on delete set null,
  delivered_by uuid references auth.users (id) on delete set null,
  delivered_at timestamptz,
  cancelled_by uuid references auth.users (id) on delete set null,
  cancelled_at timestamptz,
  cancel_reason text check (cancel_reason is null or char_length(cancel_reason) between 3 and 300),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint site_comp_offers_cancelled_check check (status <> 'cancelled' or (cancelled_at is not null and cancel_reason is not null)),
  constraint site_comp_offers_delivered_check check (status <> 'delivered' or delivered_at is not null),
  constraint site_comp_offers_location_check check (status not in ('location_submitted', 'accepted', 'delivered') or (location_set_by is not null and location_set_at is not null))
);
create index site_comp_offers_venue_idx on public.site_comp_offers (venue_id, created_at desc);
alter table public.site_comp_offers enable row level security;
revoke all on table public.site_comp_offers from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
-- The state a person sees: an offer that is not yet accepted and whose time has passed is EXPIRED, whatever is stored.
create function public.comp_offer_state(p_status text, p_expires timestamptz)
returns text
language sql
stable
set search_path = public
as $$
  select case when p_status in ('approved', 'sent', 'awaiting_location', 'location_submitted') and p_expires <= now() then 'expired' else p_status end
$$;

create function public.comp_token_hash(p_token text)
returns text
language sql
immutable
set search_path = public
as $$ select encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex') $$;

revoke all on function public.comp_offer_state(text, timestamptz), public.comp_token_hash(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Staff: make, read and manage offers (the club's owner and manager)
-- ---------------------------------------------------------------------------
create function public.comp_offer_create(
  p_venue uuid, p_bottle uuid, p_quantity int, p_email text, p_name text, p_reason text, p_sign text default null, p_event uuid default null, p_expires_hours int default 24
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  bt public.site_bottles;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_sign text := nullif(btrim(coalesce(p_sign, '')), '');
  v_owner boolean;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  v_owner := public.can_access_venue(p_venue, array['owner']);
  if not v_owner and not exists (select 1 from public.site_discount_limits l where l.venue_id = p_venue) then raise exception 'free bottles are not set up for this club yet: the owner sets the limits first'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 12 then raise exception 'choose from 1 to 12 bottles'; end if;
  if char_length(v_email) > 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'enter the e-mail address the link is for'; end if;
  if v_name is not null and char_length(v_name) > 60 then raise exception 'keep the name to 60 characters or fewer'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then raise exception 'give a reason of 3 to 300 characters'; end if;
  if v_sign is not null and (char_length(v_sign) > 40 or v_sign ~ '[[:cntrl:]]') then raise exception 'keep the sign to 40 characters, on one line'; end if;
  if p_expires_hours is null or p_expires_hours < 1 or p_expires_hours > 168 then raise exception 'the link can last from 1 hour to 7 days'; end if;
  select * into bt from public.site_bottles x where x.id = p_bottle and x.venue_id = p_venue;
  if not found then raise exception 'bottle not found'; end if;
  if not bt.is_available or bt.is_sold_out then raise exception 'that bottle is not available right now'; end if;
  if p_event is not null and not exists (select 1 from public.site_events e where e.id = p_event) then raise exception 'event not found'; end if;

  insert into public.site_comp_offers (venue_id, event_id, bottle_id, bottle_name, bottle_size, quantity, value_cents, recipient_email, recipient_name, reason, sign_text, expires_at, created_by, approved_by)
    values (p_venue, p_event, bt.id, bt.name, bt.size, p_quantity, bt.price_cents * p_quantity, v_email, v_name, v_reason, v_sign, now() + make_interval(hours => p_expires_hours), auth.uid(), auth.uid())
    returning id into v_id;
  perform public.desk_log('comp_offer.created', 'site_comp_offers', v_id, jsonb_build_object('venue_id', p_venue, 'bottle', bt.name, 'quantity', p_quantity, 'reason', v_reason));
  return v_id;
end;
$$;

create function public.comp_offers_list(p_venue uuid)
returns table (
  offer_id uuid, bottle_name text, bottle_size text, quantity int, value_cents int, recipient_email text, recipient_name text, reason text, sign_text text, status text, expires_at timestamptz,
  created_at timestamptz, created_by_name text, location_table_name text, location_set_by text, booking_id uuid, concession_status text, delivered_at timestamptz, actions text[]
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
    select o.id, o.bottle_name, o.bottle_size, o.quantity, o.value_cents, o.recipient_email, o.recipient_name, o.reason, o.sign_text, public.comp_offer_state(o.status, o.expires_at), o.expires_at,
           o.created_at, (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = o.created_by),
           t.name, o.location_set_by, o.booking_id, c.status, o.delivered_at,
           case public.comp_offer_state(o.status, o.expires_at)
             when 'approved' then array['set_location', 'cancel']
             when 'sent' then array['set_location', 'cancel']
             when 'awaiting_location' then array['set_location', 'cancel']
             when 'location_submitted' then array['accept', 'set_location', 'cancel']
             when 'accepted' then array['mark_delivered']
             else array[]::text[] end
      from public.site_comp_offers o
      left join public.site_table_types t on t.id = o.location_table_id
      left join public.site_concessions c on c.id = o.concession_id
     where o.venue_id = p_venue
     order by o.created_at desc, o.id
     limit 200;
end;
$$;

-- The club's tables by their labels, for placing a recipient by hand (the brief: "manual staff location resolution if link fails").
create function public.comp_offer_tables(p_venue uuid)
returns table (table_id uuid, name text, floor_label text)
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
    select t.id, t.name, f.label
      from public.site_table_types t left join public.site_venue_floors f on f.id = t.floor_id
     where t.venue_id = p_venue
     order by f.sort_order nulls last, lower(t.name), t.id
     limit 300;
end;
$$;

create function public.comp_offer_set_location(p_offer uuid, p_table uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.site_comp_offers;
  v_state text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into o from public.site_comp_offers x where x.id = p_offer for update;
  if not found or not public.can_access_venue(o.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  v_state := public.comp_offer_state(o.status, o.expires_at);
  if v_state = 'expired' then raise exception 'this offer has expired'; end if;
  if v_state not in ('approved', 'sent', 'awaiting_location', 'location_submitted') then raise exception 'this offer is % and its place can no longer be changed', replace(v_state, '_', ' '); end if;
  if p_table is null or not exists (select 1 from public.site_table_types t where t.id = p_table and t.venue_id = o.venue_id) then raise exception 'choose one of this club''s tables'; end if;
  update public.site_comp_offers set location_table_id = p_table, location_set_by = 'staff', location_set_at = clock_timestamp(), status = 'location_submitted', updated_at = clock_timestamp() where id = o.id;
  perform public.desk_log('comp_offer.location_set_by_staff', 'site_comp_offers', o.id, jsonb_build_object('venue_id', o.venue_id, 'table_id', p_table));
  return 'location_submitted';
end;
$$;

-- The bookings a recipient could be placed at: confirmed, at the table they chose, on the given business night.
create function public.comp_offer_bookings(p_offer uuid, p_night date)
returns table (booking_id uuid, confirmation_code text, guest_name text, table_name text, guest_count int)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  o public.site_comp_offers;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into o from public.site_comp_offers x where x.id = p_offer;
  if not found or not public.can_access_venue(o.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose the night'; end if;
  if o.location_table_id is null then return; end if;
  return query
    select b.id, b.confirmation_code, b.customer_name, t.name, b.guest_count
      from public.site_table_bookings b
      join public.site_table_types t on t.id = b.table_type_id
      join public.site_venue_time_slots s on s.id = b.time_slot_id
     where b.venue_id = o.venue_id and b.table_type_id = o.location_table_id and b.status = 'paid' and public.booking_night(b.booking_date, s.start_time) = p_night
     order by b.customer_name, b.id
     limit 50;
end;
$$;

-- Staff have checked the place and found the booking: the offer becomes a free bottle on that booking, through the existing path (the club's limits and approval rules apply there).
create function public.comp_offer_accept(p_offer uuid, p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.site_comp_offers;
  b public.site_table_bookings;
  v_state text;
  v_free jsonb;
  v_concession uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into o from public.site_comp_offers x where x.id = p_offer for update;
  if not found or not public.can_access_venue(o.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  v_state := public.comp_offer_state(o.status, o.expires_at);
  if v_state = 'expired' then raise exception 'this offer has expired'; end if;
  if v_state <> 'location_submitted' then raise exception 'this offer is %: it needs a place before it can be accepted', replace(v_state, '_', ' '); end if;
  if o.bottle_id is null then raise exception 'that bottle is no longer on the menu'; end if;
  select * into b from public.site_table_bookings x where x.id = p_booking;
  if not found or b.venue_id <> o.venue_id then raise exception 'not allowed'; end if;
  if b.table_type_id is distinct from o.location_table_id then raise exception 'that booking is for a different table than the one chosen'; end if;

  v_free := public.desk_request_free_bottle(p_booking, o.bottle_id, o.quantity, o.reason);
  v_concession := (v_free ->> 'id')::uuid;
  update public.site_comp_offers set status = 'accepted', accepted_by = auth.uid(), accepted_at = clock_timestamp(), booking_id = p_booking, concession_id = v_concession, updated_at = clock_timestamp() where id = o.id;
  perform public.desk_log('comp_offer.accepted', 'site_comp_offers', o.id, jsonb_build_object('venue_id', o.venue_id, 'booking_id', p_booking, 'concession_id', v_concession, 'concession_status', v_free ->> 'status'));
  return jsonb_build_object('offer_id', o.id, 'status', 'accepted', 'concession_id', v_concession, 'concession_status', v_free ->> 'status');
end;
$$;

create function public.comp_offer_mark_delivered(p_offer uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.site_comp_offers;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into o from public.site_comp_offers x where x.id = p_offer for update;
  if not found or not public.can_access_venue(o.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if o.status <> 'accepted' then raise exception 'only an accepted offer can be marked delivered'; end if;
  update public.site_comp_offers set status = 'delivered', delivered_by = auth.uid(), delivered_at = clock_timestamp(), updated_at = clock_timestamp() where id = o.id;
  perform public.desk_log('comp_offer.delivered', 'site_comp_offers', o.id, jsonb_build_object('venue_id', o.venue_id));
  return 'delivered';
end;
$$;

-- Before it is accepted. After that a free bottle exists, and taking it back is done on the free bottle itself (desk_void_concession), which refuses one that was already served.
create function public.comp_offer_cancel(p_offer uuid, p_reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.site_comp_offers;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into o from public.site_comp_offers x where x.id = p_offer for update;
  if not found or not public.can_access_venue(o.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if o.status in ('accepted', 'delivered') then raise exception 'a free bottle already exists for this offer: take it back on the free bottle'; end if;
  if o.status = 'cancelled' then raise exception 'this offer is already cancelled'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then raise exception 'give a reason of 3 to 300 characters'; end if;
  update public.site_comp_offers set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = clock_timestamp(), cancel_reason = v_reason, token_hash = null, updated_at = clock_timestamp() where id = o.id;
  perform public.desk_log('comp_offer.cancelled', 'site_comp_offers', o.id, jsonb_build_object('venue_id', o.venue_id, 'reason', v_reason));
  return 'cancelled';
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The link and the claim (SERVICE ROLE ONLY: the public page calls these through an edge function)
-- ---------------------------------------------------------------------------
-- Makes the link's token, stores only its hash, marks the offer sent, and returns the token ONCE for the e-mail. Issuing again replaces the token (the old link stops working).
create function public.comp_offer_issue_link(p_offer uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.site_comp_offers;
  v_token text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  select * into o from public.site_comp_offers x where x.id = p_offer for update;
  if not found then raise exception 'not found'; end if;
  if public.comp_offer_state(o.status, o.expires_at) not in ('approved', 'sent', 'awaiting_location') then raise exception 'a link cannot be issued for an offer that is %', replace(public.comp_offer_state(o.status, o.expires_at), '_', ' '); end if;
  update public.site_comp_offers set token_hash = public.comp_token_hash(v_token), status = case when status = 'approved' then 'sent' else status end, sent_at = coalesce(sent_at, clock_timestamp()), updated_at = clock_timestamp() where id = o.id;
  return v_token;
end;
$$;

-- What the recipient sees. Opening the link the first time moves the offer to "awaiting location". Never raises for a bad token: the page gets a state to word.
create function public.comp_claim_view(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.site_comp_offers;
  v_state text;
begin
  select * into o from public.site_comp_offers x where x.token_hash = public.comp_token_hash(p_token) and p_token is not null and char_length(p_token) >= 32 for update;
  if not found then return jsonb_build_object('state', 'not_found'); end if;
  v_state := public.comp_offer_state(o.status, o.expires_at);
  if v_state = 'expired' then return jsonb_build_object('state', 'expired'); end if;
  if v_state = 'cancelled' then return jsonb_build_object('state', 'cancelled'); end if;
  if v_state in ('location_submitted', 'accepted', 'delivered') then
    return jsonb_build_object('state', 'claimed', 'item', o.bottle_name, 'quantity', o.quantity, 'venue_name', (select v.name from public.site_venues v where v.id = o.venue_id));
  end if;
  if o.status in ('approved', 'sent') then
    update public.site_comp_offers set status = 'awaiting_location', claimed_at = coalesce(claimed_at, clock_timestamp()), updated_at = clock_timestamp() where id = o.id;
  end if;
  return jsonb_build_object(
    'state', 'open',
    'venue_name', (select v.name from public.site_venues v where v.id = o.venue_id),
    'event_title', (select e.title from public.site_events e where e.id = o.event_id),
    'item', o.bottle_name, 'size', o.bottle_size, 'quantity', o.quantity, 'sign', o.sign_text, 'recipient_name', o.recipient_name, 'expires_at', o.expires_at,
    'floors', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'label', f.label, 'image_url', f.image_url) order by f.sort_order, f.id) from public.site_venue_floors f where f.venue_id = o.venue_id), '[]'::jsonb),
    'tables', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'floor_id', t.floor_id, 'pos_x', t.pos_x, 'pos_y', t.pos_y, 'width', t.width, 'height', t.height) order by lower(t.name), t.id)
                          from public.site_table_types t where t.venue_id = o.venue_id), '[]'::jsonb));
end;
$$;

-- The recipient says where they are. One claim only: a second submission changes nothing.
create function public.comp_claim_submit(p_token text, p_table uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.site_comp_offers;
  v_state text;
begin
  select * into o from public.site_comp_offers x where x.token_hash = public.comp_token_hash(p_token) and p_token is not null and char_length(p_token) >= 32 for update;
  if not found then return jsonb_build_object('state', 'not_found'); end if;
  v_state := public.comp_offer_state(o.status, o.expires_at);
  if v_state = 'expired' then return jsonb_build_object('state', 'expired'); end if;
  if v_state = 'cancelled' then return jsonb_build_object('state', 'cancelled'); end if;
  if v_state in ('location_submitted', 'accepted', 'delivered') then return jsonb_build_object('state', 'claimed'); end if;
  if p_table is null or not exists (select 1 from public.site_table_types t where t.id = p_table and t.venue_id = o.venue_id) then return jsonb_build_object('state', 'bad_table'); end if;
  update public.site_comp_offers set location_table_id = p_table, location_set_by = 'recipient', location_set_at = clock_timestamp(), claimed_at = coalesce(claimed_at, clock_timestamp()), status = 'location_submitted', updated_at = clock_timestamp() where id = o.id;
  perform public.desk_log('comp_offer.location_submitted', 'site_comp_offers', o.id, jsonb_build_object('venue_id', o.venue_id, 'table_id', p_table));
  return jsonb_build_object('state', 'submitted');
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.comp_offer_create(uuid, uuid, int, text, text, text, text, uuid, int), public.comp_offers_list(uuid), public.comp_offer_tables(uuid), public.comp_offer_set_location(uuid, uuid),
  public.comp_offer_bookings(uuid, date), public.comp_offer_accept(uuid, uuid), public.comp_offer_mark_delivered(uuid), public.comp_offer_cancel(uuid, text),
  public.comp_offer_issue_link(uuid), public.comp_claim_view(text), public.comp_claim_submit(text, uuid)
  from public, anon;
grant execute on function
  public.comp_offer_create(uuid, uuid, int, text, text, text, text, uuid, int), public.comp_offers_list(uuid), public.comp_offer_tables(uuid), public.comp_offer_set_location(uuid, uuid),
  public.comp_offer_bookings(uuid, date), public.comp_offer_accept(uuid, uuid), public.comp_offer_mark_delivered(uuid), public.comp_offer_cancel(uuid, text)
  to authenticated, service_role;
-- the link and the claim are for the service role (the edge function behind the public page) and for nobody else
revoke all on function public.comp_offer_issue_link(uuid), public.comp_claim_view(text), public.comp_claim_submit(text, uuid) from authenticated;
grant execute on function public.comp_offer_issue_link(uuid), public.comp_claim_view(text), public.comp_claim_submit(text, uuid) to service_role;
