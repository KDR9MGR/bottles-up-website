-- Schema additions for the remaining Claude Design mockup sections:
-- bottle-sign customization (VIP booking), event lineup/good-to-know/organizer
-- block (event detail redesign), and a lead-capture table for the homepage's
-- "Early partner list" form (separate from vip_emails, which is customer-shaped
-- - email/first_name/last_name - not a fit for "venue or brand name").

alter table public.site_table_bookings
  add column bottle_sign_text text;

alter table public.site_events
  add column lineup jsonb not null default '[]',
  add column good_to_know text[] not null default '{}',
  add column organizer_name text,
  add column organizer_bio text,
  add column organizer_verified boolean not null default false,
  add column organizer_instagram text,
  add column organizer_email text,
  add column organizer_avatar_url text;

create table public.partner_leads (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  venue_name text,
  created_at timestamptz not null default now()
);
alter table public.partner_leads enable row level security;
create policy "admins read partner leads" on public.partner_leads
  for select using (public.is_cms_admin());
-- No client insert policy - the submit-partner-lead edge function uses the
-- service-role client, same pattern as vip-subscribe.
