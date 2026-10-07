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

-- needed by 20261007100000_accounts_onboarding.sql, which extends the shared profiles table
-- (written by both the website and the customer app). Only the columns those apps are
-- known to use; production has more, and its real definition is not in this repo.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text,
  email text,
  phone_number text,
  age int,
  avatar_url text,
  verified boolean
);
