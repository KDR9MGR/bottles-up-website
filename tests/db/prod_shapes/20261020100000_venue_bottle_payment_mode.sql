-- Production-only shape for 20261020100000_venue_payment_rules.sql: site_venues.bottle_payment_mode, which the website and the checkout read
-- (src/types/database.ts: 'pay_ahead' | 'pay_at_club' | 'both') but no migration here creates. Only the name and the three values are known from the
-- code; the default and the constraint below are assumptions, not something production reported. (deposit_is_credit has its own shape file.)
alter table public.site_venues add column if not exists bottle_payment_mode text not null default 'pay_ahead'
  check (bottle_payment_mode in ('pay_ahead', 'pay_at_club', 'both'));
alter table public.site_venues add column if not exists deposit_is_credit boolean not null default false;
