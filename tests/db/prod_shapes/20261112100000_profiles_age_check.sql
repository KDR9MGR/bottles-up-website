-- Production-only shape for 20261112100000_profile_date_of_birth.sql: in production profiles.age must be 18 or more (profiles_age_check, read 29 Oct 2026 from pg_constraint).
-- The prerequisite table in 01_prod_prerequisites.sql does not have it. The new trigger relies on this rule to keep under-18s out, so the test is meaningless without it.
alter table public.profiles add constraint profiles_age_check check (age >= 18);
