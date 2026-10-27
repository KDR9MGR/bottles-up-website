-- Feature switches (customer app completion plan, M0): "Features ship dark". Each part of the client's social and marketplace plan that still
-- needs a business decision (money, subscriptions, rankings, split payments...) is built, tested and then switched on by BottlesUp here, not
-- by shipping a new app.
--
--   * Every switch starts OFF. The apps ask site_features() which are on and hide the rest.
--   * A switch only changes what the apps SHOW. Every database function of a feature that is off still enforces its own rules, so nothing
--     here is a security control; the functions of money features additionally refuse while their switch is off (they call feature_enabled()).
--   * Only a BottlesUp admin (cms_admins) changes a switch, and each change is written to the audit log.
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

create table public.site_feature_flags (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  enabled boolean not null default false,
  note text check (note is null or char_length(note) <= 300),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);
alter table public.site_feature_flags enable row level security;
revoke all on table public.site_feature_flags from public, anon, authenticated;

insert into public.site_feature_flags (key, note) values
  ('social', 'Profiles, following, the home feed, posts, likes and comments'),
  ('stories', 'Stories that last 24 hours'),
  ('reels', 'Short videos and the reels viewer'),
  ('members_only', 'Posts only a creator''s chosen members can see'),
  ('inbox', 'Direct, group and booking conversations between customers'),
  ('reviews', 'Reviews of venues and of events'),
  ('split_payments', 'Guests paying their share of a table or an order'),
  ('marketplace', 'Hiring DJs, photographers and other professionals; quotes and payments'),
  ('venue_hire', 'Event organizers asking venues to host an event; the event workspace'),
  ('referrals', 'Referral links and commissions'),
  ('subscriptions', 'Paid business subscriptions'),
  ('advertising', 'Sponsored placements'),
  ('creator_earnings', 'Creator income and payouts'),
  ('ranks', 'Follower-based verification ranks and awards'),
  ('jobs', 'Jobs and opportunities'),
  ('ai_captions', 'Caption ideas written by an AI for a post, which the person reads and changes before posting');

-- What is switched on. Anyone may ask, signed in or not (the app asks before it knows who is using it); it shows no person, only names of features.
create function public.site_features()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_object_agg(f.key, f.enabled), '{}'::jsonb) from public.site_feature_flags f
$$;

-- For other functions: is this feature on right now?
create function public.feature_enabled(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select f.enabled from public.site_feature_flags f where f.key = p_key), false)
$$;

-- A BottlesUp admin turns a feature on or off.
create function public.cms_set_feature(p_key text, p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old boolean;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;
  if p_enabled is null then raise exception 'Choose on or off.'; end if;
  select f.enabled into v_old from public.site_feature_flags f where f.key = p_key for update;
  if not found then raise exception 'There is no such feature.'; end if;
  if v_old is distinct from p_enabled then
    update public.site_feature_flags set enabled = p_enabled, updated_at = now(), updated_by = auth.uid() where key = p_key;
    insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
    values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'feature_switched', 'feature', p_key,
            jsonb_build_object('from', v_old, 'to', p_enabled));
  end if;
  return public.site_features();
end;
$$;

-- The admin list with notes, for the CMS page.
create function public.cms_list_features()
returns table (key text, enabled boolean, note text, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  return query select f.key, f.enabled, f.note, f.updated_at from public.site_feature_flags f order by f.key;
end;
$$;

revoke all on function public.site_features(), public.feature_enabled(text), public.cms_set_feature(text, boolean), public.cms_list_features()
  from public, anon, authenticated;
grant execute on function public.site_features() to anon, authenticated, service_role;
grant execute on function public.cms_set_feature(text, boolean), public.cms_list_features() to authenticated, service_role;
grant execute on function public.feature_enabled(text) to service_role;
