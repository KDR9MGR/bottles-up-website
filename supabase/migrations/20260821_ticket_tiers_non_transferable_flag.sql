-- Organizer-configured per-tier flag: orders created against a tier with this
-- set copy it onto site_orders.is_non_transferable at checkout time (see
-- site-create-checkout-session), which is what actually gates entry via the
-- OTP access-code flow (20260821_ticket_otp_access_codes.sql).

alter table public.site_ticket_tiers
  add column is_non_transferable boolean not null default false;
