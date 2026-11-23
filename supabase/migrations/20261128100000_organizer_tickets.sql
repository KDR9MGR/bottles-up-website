-- Organizers create their own tickets from the Business app (developer fix list, 22 Nov 2026, item 3): types, prices, quantities and sale dates.
--
-- WHY: the organizer-events migration (20261013100000) let an organizer write the EVENT, and said in so many words that ticket tiers "are still added in the CMS" by the BottlesUp team.
-- The Business app's own ticket screen writes the OLD tables (`events`, `ticket_types`), which the customer app and the website do not read.
--
-- WHAT THIS ADDS:
--   * two nullable columns on site_ticket_tiers: sale_starts_at and sale_ends_at (empty = on sale as always, so every existing ticket type is unchanged), and a check that a window ends after it starts;
--   * three functions an organizer calls instead of getting write access to the table (like the event functions): list_org_tiers, save_org_tier, remove_org_tier.
--
-- WHO: the organizer of the business that owns the event (require_org_organizer: the same person who may write the event). Venue owners do not create events or tickets here: events are the
-- organizer's, and a club's own nights are made in the CMS.
--
-- THE RULES, one set for drafts and for published events:
--   * An event that has ended (its end time passed, or 12 hours after it started when it has none: the rule the rest of the system uses) cannot have its tickets changed.
--   * A ticket type has a name (1 to 60 characters, with its spaces tidied: no runs of spaces, not the same as another type of the event), a price in cents (0 to 1,000,000, so free is allowed), and a capacity (1 to 100,000). An event may
--     have at most 20 types.
--   * Sales may be given a start, an end, both or neither; they need a time zone; the end must be after the start; sales cannot end after the event ends, or start once it has ended.
--   * Once a type has SOLD (sold_count above zero, or a paid or refunded order), its price and its name cannot change (buyers have tickets that say them): add a new type instead.
--   * Capacity can be raised any time, and lowered only down to what is already sold.
--   * A type can be removed only if nobody has an order for it, of any kind (even one that was started and not paid): otherwise it is closed by setting its sales to end.
--   * Access codes and non-transferable tickets stay in the CMS: they are not in the field list, and a field the function does not know is refused.
--
-- NOT DONE HERE: checking the sale window when somebody buys is the checkout function's job (supabase/functions/site-create-checkout-session) and is a separate pull request; door sales
-- (a person at the door selling a ticket) are not held to the window on purpose.
--
-- Every change is attributed in audit_log through org_event_log, like the event functions. Plain CREATE, never CREATE OR REPLACE.

alter table public.site_ticket_tiers
  add column sale_starts_at timestamptz,
  add column sale_ends_at timestamptz,
  add constraint site_ticket_tiers_sale_window_check check (sale_starts_at is null or sale_ends_at is null or sale_ends_at > sale_starts_at);

-- ---------------------------------------------------------------------------
-- The event an organizer's tickets belong to: theirs, and not over. Returns the locked event row.
-- ---------------------------------------------------------------------------
create function public.org_tier_event(p_org uuid, p_event uuid)
returns public.site_events
language plpgsql
security definer
set search_path = public
as $$
declare v_ev public.site_events;
begin
  select * into v_ev from public.site_events e where e.id = p_event and e.org_id = p_org for update;
  if not found then raise exception 'event not found'; end if;
  if coalesce(v_ev.end_date, v_ev.start_date + interval '12 hours') < now() then
    raise exception 'this event has ended, so its tickets can no longer be changed';
  end if;
  return v_ev;
end;
$$;

-- Has this ticket type been sold, or paid for and refunded? Then buyers hold tickets that carry its name and price.
create function public.org_tier_has_sold(p_tier uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select t.sold_count > 0 from public.site_ticket_tiers t where t.id = p_tier), false)
      or exists (select 1 from public.site_orders o where o.tier_id = p_tier and o.status in ('paid', 'refunded'))
$$;

-- ---------------------------------------------------------------------------
-- The organizer's functions
-- ---------------------------------------------------------------------------

create function public.list_org_tiers(p_org uuid, p_event uuid)
returns table (
  tier_id uuid, name text, price_cents int, currency text, capacity int, sold_count int,
  sale_starts_at timestamptz, sale_ends_at timestamptz, has_sold boolean, has_orders boolean, requires_access_code boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public.require_org_organizer(p_org);
  if not exists (select 1 from public.site_events e where e.id = p_event and e.org_id = p_org) then raise exception 'event not found'; end if;
  return query
    select t.id, t.name, t.price_cents, t.currency, t.capacity, t.sold_count, t.sale_starts_at, t.sale_ends_at,
           public.org_tier_has_sold(t.id),
           exists (select 1 from public.site_orders o where o.tier_id = t.id),
           t.requires_access_code
    from public.site_ticket_tiers t
    where t.event_id = p_event
    order by t.price_cents, t.created_at, t.id;
end;
$$;

-- p_tier null adds a ticket type; otherwise changes that type, and only the fields in p_details change.
-- Fields: name, price_cents, capacity, sale_starts_at, sale_ends_at (the last two may be null to clear them).
create function public.save_org_tier(p_org uuid, p_event uuid, p_tier uuid, p_details jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ev public.site_events;
  v_t public.site_ticket_tiers;
  v_ev_end timestamptz;
  v_name text;
  v_price int;
  v_cap int;
  v_start timestamptz;
  v_end timestamptz;
  v_id uuid;
begin
  perform public.require_org_organizer(p_org);
  perform public.org_event_only_keys(p_details, array['name', 'price_cents', 'capacity', 'sale_starts_at', 'sale_ends_at']);
  v_ev := public.org_tier_event(p_org, p_event);
  v_ev_end := coalesce(v_ev.end_date, v_ev.start_date + interval '12 hours');

  if p_tier is null then
    v_name := regexp_replace(public.org_event_text(p_details, 'name', 'ticket name', 60, true), '\s+', ' ', 'g');
    v_price := public.org_event_int(p_details, 'price_cents', 'price', 0, 1000000);
    if v_price is null then raise exception 'price is required'; end if;
    v_cap := public.org_event_int(p_details, 'capacity', 'capacity', 1, 100000);
    if v_cap is null then raise exception 'capacity is required'; end if;
    v_start := public.org_event_time(p_details, 'sale_starts_at', 'sales start', false);
    v_end := public.org_event_time(p_details, 'sale_ends_at', 'sales end', false);
    if (select count(*) from public.site_ticket_tiers t where t.event_id = p_event) >= 20 then
      raise exception 'an event can have at most 20 ticket types';
    end if;
  else
    select * into v_t from public.site_ticket_tiers t where t.id = p_tier and t.event_id = p_event for update;
    if not found then raise exception 'ticket type not found'; end if;
    -- Start from what is saved; change only what was sent.
    v_name := v_t.name; v_price := v_t.price_cents; v_cap := v_t.capacity; v_start := v_t.sale_starts_at; v_end := v_t.sale_ends_at;
    if p_details ? 'name' then v_name := regexp_replace(public.org_event_text(p_details, 'name', 'ticket name', 60, true), '\s+', ' ', 'g'); end if;
    if p_details ? 'price_cents' then
      v_price := public.org_event_int(p_details, 'price_cents', 'price', 0, 1000000);
      if v_price is null then raise exception 'price is required'; end if;
    end if;
    if p_details ? 'capacity' then
      v_cap := public.org_event_int(p_details, 'capacity', 'capacity', 1, 100000);
      if v_cap is null then raise exception 'capacity is required'; end if;
    end if;
    if p_details ? 'sale_starts_at' then v_start := public.org_event_time(p_details, 'sale_starts_at', 'sales start', false); end if;
    if p_details ? 'sale_ends_at' then v_end := public.org_event_time(p_details, 'sale_ends_at', 'sales end', false); end if;

    if public.org_tier_has_sold(p_tier) then
      if v_price <> v_t.price_cents then raise exception 'tickets of this type have been sold, so its price cannot be changed. Add a new ticket type instead'; end if;
      if v_name <> v_t.name then raise exception 'tickets of this type have been sold, so its name cannot be changed. Add a new ticket type instead'; end if;
    end if;
    if v_cap < v_t.sold_count then
      raise exception 'the capacity cannot be lower than the % tickets already sold', v_t.sold_count;
    end if;
  end if;

  if v_start is not null and v_end is not null and v_end <= v_start then raise exception 'ticket sales must end after they start'; end if;
  if v_end is not null and v_end > v_ev_end then raise exception 'ticket sales cannot end after the event ends'; end if;
  if v_start is not null and v_start >= v_ev_end then raise exception 'ticket sales cannot start once the event has ended'; end if;
  if exists (select 1 from public.site_ticket_tiers t where t.event_id = p_event and lower(btrim(t.name)) = lower(v_name) and t.id is distinct from p_tier) then
    raise exception 'this event already has a ticket type with that name';
  end if;

  if p_tier is null then
    insert into public.site_ticket_tiers (event_id, name, price_cents, capacity, sale_starts_at, sale_ends_at)
    values (p_event, v_name, v_price, v_cap, v_start, v_end)
    returning id into v_id;
    perform public.org_event_log('org_tier.created', p_event, p_org, jsonb_build_object('tier', v_id, 'name', v_name, 'price_cents', v_price, 'capacity', v_cap, 'sale_starts_at', v_start, 'sale_ends_at', v_end));
    return v_id;
  end if;

  update public.site_ticket_tiers t
     set name = v_name, price_cents = v_price, capacity = v_cap, sale_starts_at = v_start, sale_ends_at = v_end
   where t.id = p_tier;
  perform public.org_event_log('org_tier.updated', p_event, p_org, jsonb_build_object('tier', p_tier, 'name', v_name, 'price_cents', v_price, 'capacity', v_cap, 'sale_starts_at', v_start, 'sale_ends_at', v_end));
  return p_tier;
end;
$$;

create function public.remove_org_tier(p_org uuid, p_tier uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_t public.site_ticket_tiers;
begin
  perform public.require_org_organizer(p_org);
  select t.* into v_t
    from public.site_ticket_tiers t join public.site_events e on e.id = t.event_id
   where t.id = p_tier and e.org_id = p_org
   for update of t;
  if not found then raise exception 'ticket type not found'; end if;
  perform public.org_tier_event(p_org, v_t.event_id);
  if v_t.sold_count > 0 or exists (select 1 from public.site_orders o where o.tier_id = p_tier) then
    raise exception 'people have bought or started to buy this ticket type, so it cannot be removed. Set its sales to end now instead';
  end if;
  begin
    delete from public.site_ticket_tiers where id = p_tier;
  exception when foreign_key_violation then
    raise exception 'people have bought or started to buy this ticket type, so it cannot be removed. Set its sales to end now instead';
  end;
  perform public.org_event_log('org_tier.removed', v_t.event_id, p_org, jsonb_build_object('tier', p_tier, 'name', v_t.name));
end;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.org_tier_event(uuid, uuid), public.org_tier_has_sold(uuid) from public, anon, authenticated;
revoke all on function public.list_org_tiers(uuid, uuid), public.save_org_tier(uuid, uuid, uuid, jsonb), public.remove_org_tier(uuid, uuid) from public, anon;
grant execute on function public.list_org_tiers(uuid, uuid), public.save_org_tier(uuid, uuid, uuid, jsonb), public.remove_org_tier(uuid, uuid) to authenticated, service_role;
