-- "Your Venue Access" and the organizer's Sales (client Phase 2 brief, section 7: "Organizer event tabs: Overview, Sales, Guests, Team, Settlement ... Show a Your Venue Access panel listing granted
-- permissions"; section 8: "Venue grants event-specific access to selected bar-sales figures, ticket/check-in figures, capacity, table sales, operational chat and settlement details. Restrict
-- both data and permitted actions"; scenario 4 "Organizer links venue: accepted agreement and approved visibility; no cross-editing ownership").
--
--   * THE SIX THINGS a club can share with the organizer of an event it hosts, one by one: bar_sales, ticket_checkins, capacity, table_sales, chat, settlement. The club's owner or manager turns each on or
--     off (set_agreement_grant), and only once the agreement is ACTIVE (both sides accepted a version; it stays so while a newer version waits for both acceptances). A grant is not a copy of data: nothing
--     is shared before it is read, and a withdrawn grant stops sharing at once. When the agreement is declined or cancelled, nothing is shared whatever rows exist.
--   * WHAT EXISTS TODAY is said by the database, not guessed by the app: agreement_grant_available() is true for ticket_checkins, capacity and table_sales. bar_sales (no sales source is connected, brief
--     section 24), chat (event chats are not tied to grants) and settlement (not built; the client has not decided) are recorded when the club allows them but have no data behind them yet, and are
--     reported as not available, never as connected. Making one available later is one change to that function.
--   * agreement_grants(agreement): the six, each allowed / available, for either side of the agreement; the club also sees who allowed it and when, and that it may change them.
--   * organizer_venue_access(business): the "Your Venue Access" panel: every open agreement of the organizer's events, with the six.
--   * organizer_event_sales(event): the organizer's read-only Sales. Their own tickets are always there (paid orders only: sold, checked in, gross, refunded, by tier; gross is not added across
--     currencies). From each club that hosts the event, only what that club has allowed AND the database can supply: table_sales (the club's tables booked on the event's business night, counts and money,
--     no guest names), capacity (the agreed capacity against tickets sold and checked in), ticket_checkins (the door's count and the last check-in).
--     The organizer never gets a club's other data, a guest's name, e-mail, phone or any payment detail, and cannot change anything through it.
--
-- A new table (reached only through these functions) and new functions: nothing existing is replaced and no row is changed. Needs the event agreements (20261018180000), organizer events, close-night
-- (night_booking_ids) and venue time zone (venue_timezone) migrations.

do $guard$
declare
  fn text;
begin
  foreach fn in array array['public.agreement_side(public.site_agreements, text)', 'public.night_booking_ids(uuid, date)', 'public.venue_timezone(uuid)', 'public.venue_setup_log(text, text, uuid, uuid, jsonb)',
                            'public.can_access_event(uuid, text[])', 'public.is_org_member(uuid, text[])'] loop
    if to_regprocedure(fn) is null then
      raise exception '% does not exist: run the earlier agreement, close-night and time zone migrations first. Nothing was changed.', fn;
    end if;
  end loop;
  if to_regclass('public.site_agreements') is null or to_regclass('public.site_agreement_versions') is null then
    raise exception 'public.site_agreements and site_agreement_versions must exist first. Nothing was changed.';
  end if;
  if to_regclass('public.site_agreement_grants') is not null then
    raise exception 'public.site_agreement_grants already exists: this migration was already applied. Nothing was changed.';
  end if;
end $guard$;

-- ---------------------------------------------------------------------------
-- 1. What can be shared
-- ---------------------------------------------------------------------------
create table public.site_agreement_grants (
  agreement_id uuid not null references public.site_agreements (id),
  grant_key text not null check (grant_key in ('bar_sales', 'ticket_checkins', 'capacity', 'table_sales', 'chat', 'settlement')),
  granted_by uuid references auth.users (id) on delete set null,
  granted_at timestamptz not null default clock_timestamp(),
  primary key (agreement_id, grant_key)
);
alter table public.site_agreement_grants enable row level security;
revoke all on table public.site_agreement_grants from public, anon, authenticated;

create function public.agreement_grant_keys()
returns text[]
language sql
immutable
set search_path = public
as $$ select array['bar_sales', 'ticket_checkins', 'capacity', 'table_sales', 'chat', 'settlement']::text[] $$;

-- Whether the database has anything to show for a grant today. The others are recorded when the club allows them and shown as "not available yet".
create function public.agreement_grant_available(p_key text)
returns boolean
language sql
immutable
set search_path = public
as $$ select p_key in ('ticket_checkins', 'capacity', 'table_sales') $$;

-- An agreement shares nothing unless it is in force.
create function public.agreement_in_force(a public.site_agreements)
returns boolean
language sql
immutable
set search_path = public
as $$ select a.status in ('active', 'changes_pending') $$;

revoke all on function public.agreement_grant_keys(), public.agreement_grant_available(text), public.agreement_in_force(public.site_agreements) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The club allows or withdraws one thing
-- ---------------------------------------------------------------------------
-- Returns whether anything changed (allowing what is allowed, or withdrawing what is not, changes nothing).
create function public.set_agreement_grant(p_agreement uuid, p_grant text, p_allowed boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  v_n int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_agreements x where x.id = p_agreement for update;
  if not found or public.agreement_side(a, 'venue') is distinct from 'venue' then raise exception 'not allowed'; end if;
  if p_grant is null or not (p_grant = any (public.agreement_grant_keys())) then raise exception 'choose one of the things a club can share'; end if;
  if p_allowed is null then raise exception 'say whether to share it, yes or no'; end if;
  if not public.agreement_in_force(a) then raise exception 'the agreement has to be active before you can share anything under it'; end if;

  if p_allowed then
    insert into public.site_agreement_grants (agreement_id, grant_key, granted_by) values (a.id, p_grant, auth.uid()) on conflict do nothing;
  else
    delete from public.site_agreement_grants g where g.agreement_id = a.id and g.grant_key = p_grant;
  end if;
  get diagnostics v_n = row_count;
  if v_n = 0 then return false; end if;

  perform public.venue_setup_log(case when p_allowed then 'agreement.access_allowed' else 'agreement.access_withdrawn' end, 'site_agreements', a.id, a.venue_id,
    jsonb_build_object('grant', p_grant, 'event_id', a.event_id, 'organizer_org_id', a.organizer_org_id));
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Reading what is shared
-- ---------------------------------------------------------------------------
create function public.agreement_grants(p_agreement uuid, p_side text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  v_side text;
  v_force boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_agreements x where x.id = p_agreement;
  if not found then raise exception 'not allowed'; end if;
  v_side := public.agreement_side(a, p_side);
  if v_side is null then raise exception 'not allowed'; end if;
  v_force := public.agreement_in_force(a);

  return jsonb_build_object(
    'agreement_id', a.id,
    'status', a.status,
    'side', v_side,
    'in_force', v_force,
    'can_change', v_side = 'venue' and v_force,
    'grants', (
      select jsonb_agg(jsonb_build_object(
          'key', t.k,
          'allowed', v_force and g.agreement_id is not null,
          'available', public.agreement_grant_available(t.k),
          'granted_at', case when v_force then g.granted_at end,
          'granted_by_name', case when v_side = 'venue' and v_force and g.agreement_id is not null
                                  then coalesce((select nullif(btrim(pr.name), '') from public.profiles pr where pr.id = g.granted_by), 'Staff member') end
        ) order by t.ord)
      from unnest(public.agreement_grant_keys()) with ordinality as t(k, ord)
      left join public.site_agreement_grants g on g.agreement_id = a.id and g.grant_key = t.k));
end;
$$;

-- The organizer's "Your Venue Access" panel: every open agreement of the business's events with the six things, as the club has set them.
create function public.organizer_venue_access(p_org uuid)
returns table (agreement_id uuid, event_id uuid, event_title text, event_start timestamptz, venue_id uuid, venue_name text, status text, in_force boolean, grants jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_org is null or not public.is_org_member(p_org, array['owner', 'organizer']) then raise exception 'not allowed'; end if;
  return query
    select a.id, e.id, e.title, e.start_date, v.id, v.name, a.status, public.agreement_in_force(a),
           (select jsonb_agg(jsonb_build_object(
                'key', t.k,
                'allowed', public.agreement_in_force(a) and g.agreement_id is not null,
                'available', public.agreement_grant_available(t.k)) order by t.ord)
            from unnest(public.agreement_grant_keys()) with ordinality as t(k, ord)
            left join public.site_agreement_grants g on g.agreement_id = a.id and g.grant_key = t.k)
    from public.site_agreements a
    join public.site_events e on e.id = a.event_id
    join public.site_venues v on v.id = a.venue_id
    where a.organizer_org_id = p_org and a.status not in ('declined', 'cancelled')
    order by e.start_date desc, a.requested_at desc, a.id
    limit 200;
end;
$$;

-- The organizer's read-only Sales for one event.
create function public.organizer_event_sales(p_event uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  e public.site_events;
  a public.site_agreements;
  v_tickets jsonb;
  v_currencies text[];
  v_venues jsonb := '[]'::jsonb;
  v_grants jsonb;
  v_key text;
  v_data jsonb;
  v_allowed boolean;
  v_night date;
  v_terms jsonb;
  v_cur text[];
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_event is null or not public.can_access_event(p_event, array['owner', 'organizer']) then raise exception 'not allowed'; end if;
  select * into e from public.site_events x where x.id = p_event;

  -- The organizer's own tickets: paid orders only; refunds are told apart; money is not added across currencies.
  select coalesce(array_agg(distinct lower(o.currency) order by lower(o.currency)), '{}'::text[]) into v_currencies
    from public.site_orders o where o.event_id = p_event and o.status = 'paid';
  select jsonb_build_object(
      'orders', (select count(*)::int from public.site_orders o where o.event_id = p_event and o.status = 'paid'),
      'tickets_sold', (select coalesce(sum(o.quantity), 0)::int from public.site_orders o where o.event_id = p_event and o.status = 'paid'),
      'checked_in', (select coalesce(sum(o.quantity), 0)::int from public.site_orders o where o.event_id = p_event and o.status = 'paid' and o.checked_in_at is not null),
      'refunded_orders', (select count(*)::int from public.site_orders o where o.event_id = p_event and o.status = 'refunded'),
      'refunded_cents', (select coalesce(sum(o.amount_total_cents), 0)::bigint from public.site_orders o where o.event_id = p_event and o.status = 'refunded'),
      'currency_mixed', cardinality(v_currencies) > 1,
      'currency', case when cardinality(v_currencies) > 1 then null else upper(coalesce(v_currencies[1], 'cad')) end,
      'gross_cents', case when cardinality(v_currencies) > 1 then null
                          else (select coalesce(sum(o.amount_total_cents), 0)::bigint from public.site_orders o where o.event_id = p_event and o.status = 'paid') end,
      'by_tier', coalesce((
        select jsonb_agg(jsonb_build_object('tier', x.name, 'price_cents', x.price_cents, 'capacity', x.capacity, 'currency', upper(x.currency), 'sold', x.sold, 'checked_in', x.checked_in, 'gross_cents', x.gross) order by x.name, x.id)
        from (
          select tt.id, tt.name, tt.price_cents, tt.capacity, tt.currency,
                 coalesce(sum(o.quantity), 0)::int as sold,
                 coalesce(sum(o.quantity) filter (where o.checked_in_at is not null), 0)::int as checked_in,
                 coalesce(sum(o.amount_total_cents), 0)::bigint as gross
          from public.site_ticket_tiers tt
          left join public.site_orders o on o.tier_id = tt.id and o.event_id = p_event and o.status = 'paid'
          where tt.event_id = p_event
          group by tt.id, tt.name, tt.price_cents, tt.capacity, tt.currency) x), '[]'::jsonb))
    into v_tickets;

  -- What each club that hosts the event shares: only what it has allowed and the database can supply.
  for a in select x.* from public.site_agreements x where x.event_id = p_event and x.status not in ('declined', 'cancelled') order by x.requested_at, x.id loop
    v_grants := '[]'::jsonb;
    v_night := ((e.start_date at time zone public.venue_timezone(a.venue_id)) - interval '6 hours')::date;
    select av.terms into v_terms from public.site_agreement_versions av where av.agreement_id = a.id and av.version = a.active_version;
    foreach v_key in array public.agreement_grant_keys() loop
      v_allowed := public.agreement_in_force(a) and exists (select 1 from public.site_agreement_grants g where g.agreement_id = a.id and g.grant_key = v_key);
      v_data := null;
      if v_allowed and public.agreement_grant_available(v_key) then
        if v_key = 'table_sales' then
          select coalesce(array_agg(distinct lower(coalesce(nullif(btrim(b.currency), ''), 'cad')) order by lower(coalesce(nullif(btrim(b.currency), ''), 'cad'))), '{}'::text[]) into v_cur
            from public.site_table_bookings b where b.id in (select n.id from public.night_booking_ids(a.venue_id, v_night) n);
          v_data := jsonb_build_object(
            'night', v_night,
            'tables', (select count(*)::int from public.site_table_bookings b where b.id in (select n.id from public.night_booking_ids(a.venue_id, v_night) n)),
            'guests', (select coalesce(sum(b.guest_count), 0)::int from public.site_table_bookings b where b.id in (select n.id from public.night_booking_ids(a.venue_id, v_night) n)),
            'currency_mixed', cardinality(v_cur) > 1,
            'currency', case when cardinality(v_cur) > 1 then null else upper(coalesce(v_cur[1], 'cad')) end,
            'booked_cents', case when cardinality(v_cur) > 1 then null
                                 else (select coalesce(sum(b.amount_total_cents), 0)::bigint from public.site_table_bookings b where b.id in (select n.id from public.night_booking_ids(a.venue_id, v_night) n)) end,
            'paid_cents', case when cardinality(v_cur) > 1 then null
                               else (select coalesce(sum(b.amount_paid_cents), 0)::bigint from public.site_table_bookings b where b.id in (select n.id from public.night_booking_ids(a.venue_id, v_night) n)) end);
        elsif v_key = 'capacity' then
          v_data := jsonb_build_object(
            'agreed', nullif(v_terms ->> 'capacity', '')::int,
            'tickets_sold', (v_tickets ->> 'tickets_sold')::int,
            'checked_in', (v_tickets ->> 'checked_in')::int);
        elsif v_key = 'ticket_checkins' then
          v_data := jsonb_build_object(
            'checked_in', (v_tickets ->> 'checked_in')::int,
            'tickets_sold', (v_tickets ->> 'tickets_sold')::int,
            'last_check_in_at', (select max(o.checked_in_at) from public.site_orders o where o.event_id = p_event and o.status = 'paid'));
        end if;
      end if;
      v_grants := v_grants || jsonb_build_array(jsonb_build_object('key', v_key, 'allowed', v_allowed, 'available', public.agreement_grant_available(v_key), 'data', v_data));
    end loop;
    v_venues := v_venues || jsonb_build_array(jsonb_build_object(
      'agreement_id', a.id, 'venue_id', a.venue_id, 'venue_name', (select v.name from public.site_venues v where v.id = a.venue_id),
      'status', a.status, 'in_force', public.agreement_in_force(a), 'grants', v_grants));
  end loop;

  return jsonb_build_object(
    'generated_at', clock_timestamp(),
    'event', jsonb_build_object('id', e.id, 'title', e.title, 'start', e.start_date, 'end', e.end_date, 'status', e.status, 'capacity', e.capacity, 'venue_name', e.venue_name),
    'tickets', v_tickets,
    'venues', v_venues);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.set_agreement_grant(uuid, text, boolean), public.agreement_grants(uuid, text), public.organizer_venue_access(uuid), public.organizer_event_sales(uuid) from public, anon;
grant execute on function public.set_agreement_grant(uuid, text, boolean), public.agreement_grants(uuid, text), public.organizer_venue_access(uuid), public.organizer_event_sales(uuid) to authenticated, service_role;
