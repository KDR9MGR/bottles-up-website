-- Production-only shape for 20261031100000_signup_without_email.sql: in production vendors.email is NOT NULL with no default (read 29 Oct 2026 from information_schema.columns;
-- the shape in 20261017100000_vendors_tables.sql, copied from the 17 Oct read, had it nullable). That requirement is what made a sign-up with no e-mail fail.
alter table public.vendors alter column email set not null;
