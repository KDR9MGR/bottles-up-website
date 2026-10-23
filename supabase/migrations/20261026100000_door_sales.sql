-- Door sales and the door's shift summary (developer brief 15 Oct, section 26: "Door Sales > Ticket Type > Guest Details > Approved Discount > Payment > Confirm > Issue and Check In Once. Record
-- cash and external-terminal methods separately. In-platform cards require payment confirmation. ... Keep staff-attributed check-ins, sales and cash records after temporary access expires. Email
-- can be captured for cash door sales; make required/optional contact fields clear."; the client's answer of 20 Oct: "cash, the venue's existing card machine, online tickets; staff records the method,
-- ticket issued and checked in once; no new card reader").
--
--   * site_orders gains the way a door sale is recorded: sale_channel ('online' for everything that exists, 'door' for a sale made by a door person), door_payment_method ('cash' or 'external_terminal'),
--     door_reference (the terminal's receipt number: needed for the external terminal, not for cash), sold_by (the staff member: kept after their access ends), door_client_key (one per sale attempt, so
--     a retry or a double tap is ONE sale). A constraint makes a door sale impossible without a method and a key (and a receipt number for the terminal), and an online order impossible with any of
--     them. sold_by is cleared only if that person later deletes their account (the sale itself stays). Not changed here: the older checked_in_by and scan_attempts.scanned_by columns have no
--     such rule, so they already stop the account of anyone who ever scanned a ticket from being deleted; a sale also sets checked_in_by, so it joins them.
--   * door_sale_options(event)    the ticket types the person may sell now (not the ones that need an access code online), with what is left. Only a door person who covers the event, and only while the event is on (the same window as the door's own
--                                 list: from 24 hours before it starts to 3 hours after it ends).
--   * door_sell_ticket(...)       sells N tickets of one type to one guest: the guest's name is needed; email and phone are optional (an email is stored with the sale, nothing is e-mailed from here);
--                                 the tier is locked while capacity is counted, so the last tickets cannot be sold twice; the order is made PAID with a ticket code in the website's format, CHECKED IN once
--                                 (all N guests are in, recorded in site_order_admissions like a group admission), and the tier's sold count goes up. The same key twice returns the same sale. Nothing is paid
--                                 through BottlesUp: cash and terminal sales are only RECORDED (they never enter a payout and cannot be refunded online).
--   * door_shift_summary(event)   the caller's own shift at that event: guests they admitted by scan, the tickets they sold and the cash and terminal totals separately.
--
-- Not here: approved discounts / promo codes at the door (they need ticket discounts, which the organizer manages: not built), in-platform card payments, phone tap-to-pay, and a manager's report of every
-- door person's sales (the records are kept with sold_by for it). Needs the scoped door scanner (20261009100000) and group admission (20261020170000). Plain CREATE for functions; the columns are
-- added to a live table with a default, so no existing order changes.

do $pre$
declare
  r record;
begin
  for r in select * from (values ('public.has_door_role()'), ('public.can_scan_event(uuid)'), ('public.desk_log(text, text, uuid, jsonb)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
  for r in select * from (values ('site_orders'), ('site_ticket_tiers'), ('site_events'), ('site_order_admissions'), ('scan_attempts'), ('audit_log')) as x(t) loop
    if to_regclass('public.' || r.t) is null then raise exception 'public.% does not exist: run the earlier migrations first. Nothing was changed.', r.t; end if;
  end loop;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. How a door sale is recorded
-- ---------------------------------------------------------------------------
alter table public.site_orders
  add column sale_channel text not null default 'online' check (sale_channel in ('online', 'door')),
  add column door_payment_method text check (door_payment_method is null or door_payment_method in ('cash', 'external_terminal')),
  add column door_reference text check (door_reference is null or char_length(door_reference) between 3 and 120),
  add column sold_by uuid references auth.users (id) on delete set null,
  add column door_client_key text check (door_client_key is null or char_length(door_client_key) between 8 and 80);

alter table public.site_orders add constraint site_orders_door_sale_check check (
  (sale_channel = 'online' and door_payment_method is null and door_reference is null and sold_by is null and door_client_key is null)
  or (sale_channel = 'door' and door_payment_method is not null and door_client_key is not null
      and (door_payment_method = 'cash' or door_reference is not null)));

create unique index site_orders_door_sale_key on public.site_orders (sold_by, door_client_key) where door_client_key is not null;

-- ---------------------------------------------------------------------------
-- 2. When the door may sell (internal)
-- ---------------------------------------------------------------------------
-- The same window as the door's own event list (door_events): a published event that starts within a day, is running, or ended less than 3 hours ago.
create function public.door_sale_window_open(p_event uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.site_events e
     where e.id = p_event and e.status = 'published'
       and coalesce(e.end_date, e.start_date + interval '12 hours') > now() - interval '3 hours'
       and e.start_date < now() + interval '24 hours')
$$;

-- ---------------------------------------------------------------------------
-- 3. What can be sold
-- ---------------------------------------------------------------------------
create function public.door_sale_options(p_event uuid)
returns table (tier_id uuid, tier_name text, price_cents int, currency text, capacity int, sold_count int, available int)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_door_role() or p_event is null or not public.can_scan_event(p_event) then raise exception 'not authorized'; end if;
  if not public.door_sale_window_open(p_event) then raise exception 'ticket sales at the door are not open for this event'; end if;
  return query
    select t.id, t.name, t.price_cents, t.currency, t.capacity, t.sold_count, greatest(t.capacity - t.sold_count, 0)
      from public.site_ticket_tiers t
     where t.event_id = p_event and not t.requires_access_code
     order by t.price_cents, t.name, t.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Selling
-- ---------------------------------------------------------------------------
create function public.door_sell_ticket(
  p_event uuid, p_tier uuid, p_quantity int, p_method text, p_name text, p_email text, p_phone text, p_reference text, p_client_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := btrim(coalesce(p_name, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_key text := btrim(coalesce(p_client_key, ''));
  chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  t public.site_ticket_tiers;
  o public.site_orders;
  v_code text;
  v_try int := 0;
  v_amount int;
  v_have boolean;
begin
  if v_uid is null or not public.has_door_role() or p_event is null or not public.can_scan_event(p_event) then raise exception 'not authorized'; end if;
  if char_length(v_key) < 8 or char_length(v_key) > 80 then raise exception 'a sale needs its own key of 8 to 80 characters'; end if;

  -- the same attempt again (a retry, a second tap): the same sale, nothing new
  select * into o from public.site_orders x where x.sold_by = v_uid and x.door_client_key = v_key;
  v_have := found;

  if not v_have then
    if p_method is null or p_method not in ('cash', 'external_terminal') then raise exception 'choose how it was paid: cash, or the card terminal'; end if;
    if p_method = 'external_terminal' and v_ref is null then raise exception 'add the terminal''s receipt number'; end if;
    if v_ref is not null and (char_length(v_ref) < 3 or char_length(v_ref) > 120) then raise exception 'the receipt number needs 3 to 120 characters'; end if;
    if char_length(v_name) < 2 or char_length(v_name) > 120 then raise exception 'the guest''s name needs 2 to 120 characters'; end if;
    if v_email <> '' and (v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or char_length(v_email) > 254) then raise exception 'enter a valid email address, or leave it empty'; end if;
    if v_phone is not null and char_length(v_phone) > 40 then raise exception 'the phone number is too long'; end if;
    if p_quantity is null or p_quantity < 1 or p_quantity > 20 then raise exception 'how many tickets? between 1 and 20'; end if;
    if not public.door_sale_window_open(p_event) then raise exception 'ticket sales at the door are not open for this event'; end if;

    select * into t from public.site_ticket_tiers where id = p_tier and event_id = p_event for update;
    if not found then raise exception 'ticket type not found'; end if;
    if t.requires_access_code then raise exception 'that ticket type is not sold at the door'; end if;

    -- the same key sent twice at the same moment: the second waited for the tier's lock, and the first sale is there now
    select * into o from public.site_orders x where x.sold_by = v_uid and x.door_client_key = v_key;
    v_have := found;
  end if;

  if v_have then
    if o.event_id is distinct from p_event or o.tier_id is distinct from p_tier or o.quantity is distinct from p_quantity then
      raise exception 'that sale key was already used for a different sale';
    end if;
    select * into t from public.site_ticket_tiers where id = o.tier_id;
    return jsonb_build_object('order_id', o.id, 'ticket_code', o.ticket_code, 'quantity', o.quantity, 'amount_cents', o.amount_total_cents, 'currency', o.currency,
      'tier_name', t.name, 'available', greatest(t.capacity - t.sold_count, 0), 'repeated', true);
  end if;

  if t.sold_count + p_quantity > t.capacity then
    raise exception 'only % of these tickets are left', greatest(t.capacity - t.sold_count, 0);
  end if;
  v_amount := t.price_cents * p_quantity;

  -- a ticket code in the website's format; a clash is retried
  loop
    v_code := 'BU-' || (select string_agg(substr(chars, 1 + floor(random() * length(chars))::int, 1), '') from generate_series(1, 8));
    exit when not exists (select 1 from public.site_orders x where x.ticket_code = v_code);
    v_try := v_try + 1;
    if v_try > 20 then raise exception 'a ticket code could not be made; try again'; end if;
  end loop;

  insert into public.site_orders (event_id, tier_id, customer_name, customer_email, customer_phone, quantity, amount_total_cents, currency, status, ticket_code,
                                  checked_in_at, checked_in_by, sale_channel, door_payment_method, door_reference, sold_by, door_client_key)
  values (p_event, t.id, v_name, v_email, v_phone, p_quantity, v_amount, t.currency, 'paid', v_code, now(), v_uid, 'door', p_method, v_ref, v_uid, v_key)
  returning * into o;
  update public.site_ticket_tiers set sold_count = sold_count + p_quantity where id = t.id;
  insert into public.site_order_admissions (order_id, guests, admitted_by) values (o.id, p_quantity, v_uid);
  perform public.desk_log('door.ticket_sold', 'site_orders', o.id,
    jsonb_build_object('event_id', p_event, 'tier', t.name, 'quantity', p_quantity, 'amount_cents', v_amount, 'method', p_method, 'has_email', v_email <> ''));
  return jsonb_build_object('order_id', o.id, 'ticket_code', v_code, 'quantity', p_quantity, 'amount_cents', v_amount, 'currency', t.currency, 'tier_name', t.name,
    'available', greatest(t.capacity - t.sold_count - p_quantity, 0), 'repeated', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The door person's own shift
-- ---------------------------------------------------------------------------
create function public.door_shift_summary(p_event uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_title text;
begin
  if v_uid is null or not public.has_door_role() or p_event is null or not public.can_scan_event(p_event) then raise exception 'not authorized'; end if;
  select e.title into v_title from public.site_events e where e.id = p_event;
  return jsonb_build_object(
    'event_title', v_title,
    -- guests this person let in by scanning (not the ones they sold a ticket to: those are in the sales below)
    'guests_admitted', (
      select coalesce(sum(a.guests), 0)::int from public.site_order_admissions a join public.site_orders o on o.id = a.order_id
       where o.event_id = p_event and o.sale_channel = 'online' and a.admitted_by = v_uid)
      + (select coalesce(sum(o.quantity), 0)::int from public.site_orders o
          where o.event_id = p_event and o.sale_channel = 'online' and o.checked_in_by = v_uid
            and not exists (select 1 from public.site_order_admissions a where a.order_id = o.id)),
    'scans_accepted', (
      select count(*)::int from public.scan_attempts s join public.site_orders o on o.id = s.order_id
       where o.event_id = p_event and o.sale_channel = 'online' and s.scanned_by = v_uid and s.result = 'ok'),
    'sales', coalesce((
      select jsonb_agg(jsonb_build_object('method', m.method, 'sales', m.sales, 'tickets', m.tickets, 'amount_cents', m.amount) order by m.method)
        from (select o.door_payment_method as method, count(*)::int as sales, sum(o.quantity)::int as tickets, sum(o.amount_total_cents)::int as amount
                from public.site_orders o where o.event_id = p_event and o.sale_channel = 'door' and o.sold_by = v_uid
               group by o.door_payment_method) m), '[]'::jsonb),
    'first_sale_at', (select min(o.created_at) from public.site_orders o where o.event_id = p_event and o.sold_by = v_uid),
    'last_sale_at', (select max(o.created_at) from public.site_orders o where o.event_id = p_event and o.sold_by = v_uid));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.door_sale_window_open(uuid) from public, anon, authenticated;
revoke all on function public.door_sale_options(uuid), public.door_sell_ticket(uuid, uuid, int, text, text, text, text, text, text), public.door_shift_summary(uuid) from public, anon;
grant execute on function public.door_sale_options(uuid), public.door_sell_ticket(uuid, uuid, int, text, text, text, text, text, text), public.door_shift_summary(uuid) to authenticated, service_role;
