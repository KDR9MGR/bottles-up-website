-- Exclusive/invite-only ticket tiers: the organizer sets a static access code
-- per tier in the CMS and shares it manually (DM, text, etc). A visitor must
-- enter the correct code before the tier's price is shown or a checkout
-- session can be created for it. Mirrors the promo_codes architecture (hashed
-- storage, edge-function-only access, re-validated server-side at checkout)
-- rather than the door-staff SQL-RPC pattern, since this is a public
-- preview-then-purchase flow, not an authenticated-staff action.

alter table public.site_ticket_tiers
  add column requires_access_code boolean not null default false;

create table public.ticket_tier_access_codes (
  id uuid primary key default gen_random_uuid(),
  tier_id uuid not null unique references public.site_ticket_tiers(id) on delete cascade,
  code_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.ticket_tier_access_codes enable row level security;
-- No SELECT/INSERT/UPDATE policies for anon/authenticated - every touch goes
-- through the set-tier-access-code, validate-tier-access-code, and
-- site-create-checkout-session edge functions (service-role client, bypasses
-- RLS), so a code's hash is never reachable via a direct PostgREST query.
