-- Objects the website's migrations ASSUME already exist, but that no migration
-- in this repo creates. They exist in production (created by hand, by another
-- app, or by a migration that was never committed here).
--
-- Replaying the migrations on an empty database fails without them. Each block
-- below was added because a specific migration needed it. If you ever commit
-- the real definitions as migrations, delete the matching block here.
--
-- Definitions are the minimum the tests need, not a copy of production.

-- needed by 20260714120000_cms_schema.sql (updated_at triggers)
create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;
