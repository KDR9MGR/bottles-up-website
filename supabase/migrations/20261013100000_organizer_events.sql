-- Organizer events: an event organizer creates, edits and removes its own DRAFT events.
--
-- Client feedback (10 Oct 2026): "Event organizer page needs a create event". The organizer's My Events screen was a
-- placeholder, and nothing let an organizer write an event: site_events is writable only by the BottlesUp admin (RLS "admins
-- manage events"), and every event is made in the CMS.
--
-- HOW: an organizer gets three functions instead of write access to the table.
--   * list_org_events, save_org_event, remove_org_event: each checks the person is an organizer of THIS business (an
--     organization of kind 'organizer' where they hold the organizer role), then reads or writes only that business's events.
--     A row id from another business is never reachable: the function looks the event up inside the business it was given.
--   * Events are created as DRAFTS and an organizer can never publish: the field list does not include status, org_id, slug
--     or anything else an organizer must not set, and a key it does not know is refused. The public site only shows published
--     events (RLS), so a draft is private until the BottlesUp team publishes it in the CMS.
--   * A draft can be changed (only the fields sent change) or removed. A published event cannot be changed or removed here:
--     tickets may have been sold, so only BottlesUp touches it.
--   * Every change is attributed in audit_log (who, what, which business), like the CMS and venue setup do.
--
-- DELIBERATELY NOT HERE (client decisions / later pieces of the Phase 2 brief, section 7):
--   * ticket tiers (price, capacity, sale windows): the BottlesUp team still adds them in the CMS,
--   * linking an event to a venue and the agreement with it (venue_id): free-text venue name and address only,
--   * publishing, and the event states beyond draft and published.
--
-- Plain CREATE, never CREATE OR REPLACE, so a name collision in the shared database fails loudly. Needs only the tenancy
-- migration (is_org_member, site_organizations), site_events (and its organizer_name column) and audit_log.

-- ---------------------------------------------------------------------------
-- 1. Small internal helpers (not callable from the app)
-- ---------------------------------------------------------------------------

create function public.require_org_organizer(p_org uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_org is null
     or not exists (select 1 from public.site_organizations o where o.id = p_org and o.kind = 'organizer')
     or not public.is_org_member(p_org, array['organizer']) then
    raise exception 'not allowed';
  end if;
end;
$$;

-- Attribution. Only the functions below call this: the app cannot, or anyone could forge audit entries.
create function public.org_event_log(p_action text, p_event uuid, p_org uuid, p_details jsonb default null)
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
    'site_events',
    p_event::text,
    coalesce(p_details, '{}'::jsonb) || jsonb_build_object('org_id', p_org)
  )
$$;

-- Only these keys may appear in a details object.
create function public.org_event_only_keys(p jsonb, p_allowed text[])
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

-- Trimmed text of at most p_max characters. Missing, JSON null or blank is null, unless it is required.
create function public.org_event_text(p jsonb, p_key text, p_label text, p_max int, p_required boolean)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := p -> p_key;
  t text;
begin
  if v is not null and jsonb_typeof(v) not in ('null', 'string') then raise exception '% must be text', p_label; end if;
  t := case when v is null or jsonb_typeof(v) = 'null' then null else nullif(btrim(v #>> '{}'), '') end;
  if t is null then
    if p_required then raise exception '% is required', p_label; end if;
    return null;
  end if;
  if length(t) > p_max then raise exception '% must be % characters or fewer', p_label, p_max; end if;
  return t;
end;
$$;

-- A whole number within bounds, or null when the key is missing or JSON null.
create function public.org_event_int(p jsonb, p_key text, p_label text, p_min int, p_max int)
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

-- An https link of at most 500 characters, or null.
create function public.org_event_url(p jsonb, p_key text, p_label text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare t text := public.org_event_text(p, p_key, p_label, 500, false);
begin
  if t is not null and t !~ '^https://[^[:space:]]+$' then raise exception '% must be an https link', p_label; end if;
  return t;
end;
$$;

-- A date and time WITH its time zone ("2026-10-24T22:00:00Z"): without one the database would guess, and guess wrong for
-- anyone not in its own zone.
create function public.org_event_time(p jsonb, p_key text, p_label text, p_required boolean)
returns timestamptz
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := p -> p_key;
  t text;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_required then raise exception '% is required', p_label; end if;
    return null;
  end if;
  if jsonb_typeof(v) <> 'string' then raise exception '% must be a date and time', p_label; end if;
  t := btrim(v #>> '{}');
  if t !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' then
    raise exception '% must be a date and time with its time zone', p_label;
  end if;
  begin
    return t::timestamptz;
  exception when others then
    raise exception '% is not a real date and time', p_label;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The functions the organizer's screen calls
-- ---------------------------------------------------------------------------

create function public.list_org_events(p_org uuid)
returns table (
  event_id uuid, title text, description text, venue_name text, address text, start_date timestamptz, end_date timestamptz,
  category text, capacity int, cover_image_url text, status text, ticket_tier_count int
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_org_organizer(p_org);
  return query
    select e.id, e.title, e.description, e.venue_name, e.address, e.start_date, e.end_date,
           e.category, e.capacity, e.cover_image_url, e.status,
           (select count(*)::int from public.site_ticket_tiers t where t.event_id = e.id)
    from public.site_events e
    where e.org_id = p_org
    order by e.start_date desc, e.created_at desc;
end;
$$;

-- p_event null adds a draft; otherwise changes that draft, and only the fields in p_details change.
create function public.save_org_event(p_org uuid, p_event uuid, p_details jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.site_organizations;
  v_ev public.site_events;
  v_title text; v_desc text; v_venue text; v_addr text; v_cat text; v_cover text;
  v_start timestamptz; v_end timestamptz; v_cap int;
  v_id uuid; v_n int;
begin
  perform public.require_org_organizer(p_org);
  -- NOT in this list, on purpose: status (an organizer cannot publish), org_id, slug, banner, gallery, lineup, organizer_*.
  perform public.org_event_only_keys(p_details,
    array['title', 'description', 'venue_name', 'address', 'start_date', 'end_date', 'category', 'capacity', 'cover_image_url']);

  if p_event is null then
    select * into v_org from public.site_organizations where id = p_org for update;  -- serialises two adds, so the cap holds
    select count(*)::int into v_n from public.site_events where org_id = p_org;
    if v_n >= 200 then raise exception 'a business can have 200 events at most'; end if;

    v_title := public.org_event_text(p_details, 'title', 'title', 120, true);
    v_desc := public.org_event_text(p_details, 'description', 'description', 5000, true);
    v_venue := public.org_event_text(p_details, 'venue_name', 'venue name', 120, true);
    v_start := public.org_event_time(p_details, 'start_date', 'start date', true);
    v_end := public.org_event_time(p_details, 'end_date', 'end date', false);
    v_addr := public.org_event_text(p_details, 'address', 'address', 200, false);
    v_cat := public.org_event_text(p_details, 'category', 'category', 40, false);
    v_cap := public.org_event_int(p_details, 'capacity', 'capacity', 0, 100000);
    v_cover := public.org_event_url(p_details, 'cover_image_url', 'cover image');
    if v_end is not null and v_end <= v_start then raise exception 'the end must be after the start'; end if;

    insert into public.site_events (title, description, venue_name, address, start_date, end_date, category, capacity, cover_image_url, status, org_id, organizer_name)
    values (v_title, v_desc, v_venue, v_addr, v_start, v_end, v_cat, v_cap, v_cover, 'draft', p_org, v_org.name)
    returning id into v_id;
    perform public.org_event_log('org_event.created', v_id, p_org, jsonb_build_object('title', v_title));
    return v_id;
  end if;

  select * into v_ev from public.site_events where id = p_event and org_id = p_org for update;
  if not found then raise exception 'event not found'; end if;
  if v_ev.status <> 'draft' then raise exception 'this event is published, so only BottlesUp can change it'; end if;

  -- Start from what is saved; change only what was sent.
  v_title := v_ev.title; v_desc := v_ev.description; v_venue := v_ev.venue_name; v_addr := v_ev.address;
  v_start := v_ev.start_date; v_end := v_ev.end_date; v_cat := v_ev.category; v_cap := v_ev.capacity; v_cover := v_ev.cover_image_url;
  if p_details ? 'title' then v_title := public.org_event_text(p_details, 'title', 'title', 120, true); end if;
  if p_details ? 'description' then v_desc := public.org_event_text(p_details, 'description', 'description', 5000, true); end if;
  if p_details ? 'venue_name' then v_venue := public.org_event_text(p_details, 'venue_name', 'venue name', 120, true); end if;
  if p_details ? 'address' then v_addr := public.org_event_text(p_details, 'address', 'address', 200, false); end if;
  if p_details ? 'start_date' then v_start := public.org_event_time(p_details, 'start_date', 'start date', true); end if;
  if p_details ? 'end_date' then v_end := public.org_event_time(p_details, 'end_date', 'end date', false); end if;
  if p_details ? 'category' then v_cat := public.org_event_text(p_details, 'category', 'category', 40, false); end if;
  if p_details ? 'capacity' then v_cap := public.org_event_int(p_details, 'capacity', 'capacity', 0, 100000); end if;
  if p_details ? 'cover_image_url' then v_cover := public.org_event_url(p_details, 'cover_image_url', 'cover image'); end if;
  if v_end is not null and v_end <= v_start then raise exception 'the end must be after the start'; end if;

  update public.site_events set
    title = v_title, description = v_desc, venue_name = v_venue, address = v_addr, start_date = v_start, end_date = v_end,
    category = v_cat, capacity = v_cap, cover_image_url = v_cover
  where id = p_event;
  perform public.org_event_log('org_event.updated', p_event, p_org, jsonb_build_object('title', v_title));
  return p_event;
end;
$$;

create function public.remove_org_event(p_org uuid, p_event uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_ev public.site_events;
begin
  perform public.require_org_organizer(p_org);
  select * into v_ev from public.site_events where id = p_event and org_id = p_org for update;
  if not found then raise exception 'event not found'; end if;
  if v_ev.status <> 'draft' then raise exception 'this event is published, so only BottlesUp can remove it'; end if;
  begin
    delete from public.site_events where id = p_event;  -- its ticket tiers go with it
  exception when foreign_key_violation then
    raise exception 'this event already has orders, so it cannot be removed';
  end;
  perform public.org_event_log('org_event.removed', p_event, p_org, jsonb_build_object('title', v_ev.title));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Who may call what
-- ---------------------------------------------------------------------------
-- The helpers are internal. org_event_log in particular must never be callable by a signed-in user, or they could write audit
-- entries in anyone's name.
revoke all on function
  public.require_org_organizer(uuid),
  public.org_event_log(text, uuid, uuid, jsonb),
  public.org_event_only_keys(jsonb, text[]),
  public.org_event_text(jsonb, text, text, int, boolean),
  public.org_event_int(jsonb, text, text, int, int),
  public.org_event_url(jsonb, text, text),
  public.org_event_time(jsonb, text, text, boolean)
  from public, anon, authenticated;

revoke all on function
  public.list_org_events(uuid), public.save_org_event(uuid, uuid, jsonb), public.remove_org_event(uuid, uuid)
  from public, anon;
grant execute on function
  public.list_org_events(uuid), public.save_org_event(uuid, uuid, jsonb), public.remove_org_event(uuid, uuid)
  to authenticated, service_role;
