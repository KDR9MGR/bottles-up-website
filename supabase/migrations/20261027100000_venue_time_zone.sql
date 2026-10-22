-- Each venue's own time zone (developer brief 15 Oct, section 5: a venue owner's details include "timezone"). Until now every venue was read as America/Toronto, in ONE place: venue_timezone(venue),
-- which the refund policy uses to work out how many hours are left before the guests arrive (a booking is a date and a wall-clock time at the club; "24 hours before" has to be counted from THAT
-- time in the club's zone). This migration lets a venue say its own zone; nothing else changes.
--
--   * site_venues.time_zone     null = the platform's default, America/Toronto (every venue that exists). No existing venue changes.
--   * save_venue_time_zone(venue, zone)   the venue's owner or manager (the same people who edit its profile) sets it, or clears it back to the default with an empty zone. The zone must be a
--                                         region/city name the database knows (America/Vancouver, Europe/London), never an abbreviation or a fixed offset (those do not follow daylight saving).
--                                         Logged like the other setup changes. Changing it changes how the refund policy counts the hours for bookings that are not yet over.
--   * venue_timezone(venue)     now reads the column (the default when it is empty). It was created by 20261023100000 in this same batch (not live yet), so it is simply replaced.
--
-- Payout dates stay on BottlesUp's own calendar (America/Toronto), because BottlesUp makes the transfers, not the venue. Plain CREATE for the new function and column.

do $pre$
declare
  r record;
begin
  for r in select * from (values ('public.require_venue_editor(uuid)'), ('public.venue_setup_log(text, text, uuid, uuid, jsonb)'), ('public.venue_timezone(uuid)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first (20261023100000 creates venue_timezone). Nothing was changed.', r.sig; end if;
  end loop;
  if to_regclass('public.site_venues') is null then raise exception 'public.site_venues does not exist. Nothing was changed.'; end if;
end
$pre$;

alter table public.site_venues add column time_zone text check (time_zone is null or time_zone ~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$');

-- The one place the venue's zone is read from.
create or replace function public.venue_timezone(p_venue uuid)
returns text
language sql
stable
set search_path = public
as $$ select coalesce((select v.time_zone from public.site_venues v where v.id = p_venue), 'America/Toronto'::text) $$;

-- p_zone empty or null puts the default back. Returns the zone now in force.
create function public.save_venue_time_zone(p_venue uuid, p_zone text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_zone text := nullif(btrim(coalesce(p_zone, '')), '');
begin
  perform public.require_venue_editor(p_venue);
  if v_zone is not null and (v_zone !~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$' or not exists (select 1 from pg_timezone_names n where n.name = v_zone)) then
    raise exception 'that time zone is not one the system knows (use a place name such as America/Toronto)';
  end if;
  perform 1 from public.site_venues v where v.id = p_venue for update;
  update public.site_venues v set time_zone = v_zone, updated_at = now() where v.id = p_venue;
  perform public.venue_setup_log('venue_setup.time_zone_saved', 'site_venues', p_venue, p_venue, jsonb_build_object('time_zone', coalesce(v_zone, 'default')));
  return public.venue_timezone(p_venue);
end;
$$;

revoke all on function public.save_venue_time_zone(uuid, text) from public, anon;
grant execute on function public.save_venue_time_zone(uuid, text) to authenticated, service_role;
