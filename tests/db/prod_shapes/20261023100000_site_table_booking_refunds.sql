-- Production-only shape for 20261023100000_refund_policy_and_requests.sql: public.site_table_booking_refunds, the record the refund edge function writes (online and club
-- refunds). It was made by hand in production and is in no committed migration. This is the shape production reported on 20 Oct 2026 (read-only query): columns,
-- constraints and the two policies (BottlesUp admins manage; a signed-in guest reads their own by verified e-mail). It had 0 rows.
create table if not exists public.site_table_booking_refunds (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.site_table_bookings (id) on delete cascade,
  bottle_line_id uuid references public.site_table_booking_bottles (id) on delete set null,
  refund_type text not null check (refund_type in ('online', 'club')),
  amount_cents integer not null check (amount_cents > 0),
  reason text not null,
  stripe_refund_id text,
  pos_reference text,
  receipt_photo_path text,
  recorded_by uuid references auth.users (id) on delete set null,
  recorded_at timestamptz not null default now()
);
create index if not exists idx_table_booking_refunds_booking on public.site_table_booking_refunds (booking_id);
alter table public.site_table_booking_refunds enable row level security;
drop policy if exists "admins manage refunds" on public.site_table_booking_refunds;
create policy "admins manage refunds" on public.site_table_booking_refunds for all using (public.is_cms_admin()) with check (public.is_cms_admin());
drop policy if exists "users read own refunds by verified email" on public.site_table_booking_refunds;
create policy "users read own refunds by verified email" on public.site_table_booking_refunds for select using (
  auth.role() = 'authenticated' and exists (select 1 from public.site_table_bookings b where b.id = site_table_booking_refunds.booking_id and lower(b.customer_email) = lower(auth.email())));
