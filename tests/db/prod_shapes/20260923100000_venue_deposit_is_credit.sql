-- Production-only shape for 20260923100000_guest_tickets_and_checkin_fix.sql: the one site_venues column its lookup function reads that no
-- migration in this folder creates. The website and edge functions read it too (src/types/database.ts, _shared/bookingTotals.ts), so it exists in
-- production; it was added by hand. Only the name and type are known from the code; the default below is the safe one (a deposit that is NOT
-- credited against the bottle bill) and is an assumption, not something production reported. Nothing in the tests depends on the default.
alter table public.site_venues add column if not exists deposit_is_credit boolean not null default false;
