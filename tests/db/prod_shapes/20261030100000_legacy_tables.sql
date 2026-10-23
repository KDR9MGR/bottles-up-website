-- Production-only shapes for 20261030100000_account_deletion_legacy_columns.sql: the five older (pre-`site_*`) tables whose columns still stop an account from being deleted,
-- reduced to the id and that one column, exactly as production reported them to the read-only audit supabase/audit/18_account_deletion_blockers.sql on 23 Oct 2026:
--   every one is a foreign key with NO "on delete" rule, nullable, except admin_audit_log.admin_id, which is NOT NULL and "on delete set null" at the same time.
-- admin_audit_log is copied from apps/bottles-up-dashboard-admin-main/supabase/migrations/20260614000001_admin_actions.sql (the admin dashboard made it). The other four are
-- made by hand in production and are not defined anywhere in this repository; only the column that matters is here. Nothing else about them is known or assumed.
-- (vendors and profiles come from the earlier shapes / prerequisites.)

create table public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references auth.users (id) on delete set null,
  action text not null,
  target_table text not null,
  target_id text not null,
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now()
);
create index admin_audit_log_admin_id_idx on public.admin_audit_log (admin_id);

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  created_by uuid references auth.users (id)
);
create table public.event_rsvps (
  id uuid primary key default gen_random_uuid(),
  verified_by uuid references auth.users (id)
);
create table public.vendor_onboarding_data (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid references public.vendors (id)
);
create table public.venues (
  id uuid primary key default gen_random_uuid(),
  manager_id uuid references public.profiles (id)
);
