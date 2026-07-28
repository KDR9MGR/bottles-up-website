-- Slugs for venues/events were being generated client-side in the CMS forms,
-- duplicating logic that already exists in public.generate_slug(). Move this
-- to a trigger so it's consistent regardless of which client writes the row,
-- and so slugs are guaranteed unique (client-side generation had no
-- uniqueness check beyond the DB's unique constraint rejecting the insert).
create or replace function public.set_venue_slug()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  base_slug text;
  candidate text;
  suffix int := 1;
begin
  if new.slug is null or new.slug = '' then
    base_slug := coalesce(nullif(public.generate_slug(new.name), ''), 'venue');
    candidate := base_slug;
    while exists (
      select 1 from public.site_venues
      where slug = candidate and id is distinct from new.id
    ) loop
      suffix := suffix + 1;
      candidate := base_slug || '-' || suffix;
    end loop;
    new.slug := candidate;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_set_venue_slug on public.site_venues;
create trigger trg_set_venue_slug
before insert or update on public.site_venues
for each row execute function public.set_venue_slug();

create or replace function public.set_event_slug()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  base_slug text;
  candidate text;
  suffix int := 1;
begin
  if new.slug is null or new.slug = '' then
    base_slug := coalesce(nullif(public.generate_slug(new.title), ''), 'event');
    candidate := base_slug;
    while exists (
      select 1 from public.site_events
      where slug = candidate and id is distinct from new.id
    ) loop
      suffix := suffix + 1;
      candidate := base_slug || '-' || suffix;
    end loop;
    new.slug := candidate;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_set_event_slug on public.site_events;
create trigger trg_set_event_slug
before insert or update on public.site_events
for each row execute function public.set_event_slug();

-- Let admins mark a table type as the highlighted/recommended option and give
-- it a short badge (e.g. "MOST POPULAR", "BEST VIEW") to match the reference
-- design, instead of hardcoding tier names in the frontend.
alter table public.site_table_types
  add column badge_label text,
  add column is_featured boolean not null default false;
