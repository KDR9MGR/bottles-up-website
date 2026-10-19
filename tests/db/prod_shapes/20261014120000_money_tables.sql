-- What production has that no committed migration creates, and that 20261014120000_desk_orders_payments.sql builds on: the money
-- columns of a table booking and of a bottle line, and the club payments table. Copied from the 14 Oct 2026 production report.
-- (Only what the new functions and their tests touch; the real tables have more, e.g. refunds and substitutions.)

-- site_table_bookings
alter table public.site_table_bookings
  add column cancellation_reason text,
  add column cancelled_at timestamptz,
  add column cancelled_by uuid references auth.users (id) on delete set null,
  add column promo_code_id uuid,
  add column discount_cents int not null default 0,
  add column amount_paid_cents int not null default 0 check (amount_paid_cents >= 0),
  add column bottle_payment_choice text not null default 'pay_ahead' check (bottle_payment_choice in ('pay_ahead', 'pay_at_club')),
  add column reconciled_at timestamptz,
  add column reconciled_by uuid references auth.users (id) on delete set null,
  add column reconciliation_override_reason text,
  add column closeout_requested_at timestamptz,
  add column closeout_requested_by uuid references auth.users (id) on delete set null;
alter table public.site_table_bookings drop constraint site_table_bookings_status_check;
alter table public.site_table_bookings add constraint site_table_bookings_status_check
  check (status in ('pending', 'paid', 'failed', 'refunded', 'cancelled'));

-- site_table_booking_bottles
alter table public.site_table_booking_bottles
  add column is_addon boolean not null default false,
  add column added_by uuid references auth.users (id) on delete set null,
  add column payment_status text not null default 'paid' check (payment_status in ('paid', 'due_at_venue', 'pending_payment')),
  add column stripe_checkout_session_id text,
  add column service_status text not null default 'awaiting_prep'
    check (service_status in ('awaiting_prep', 'preparing', 'ready', 'picked_up', 'served')),
  add column cancelled_at timestamptz,
  add column cancelled_by uuid references auth.users (id) on delete set null,
  add column cancellation_reason text;

-- site_table_booking_club_payments (one row per payment staff recorded at the club)
create table public.site_table_booking_club_payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.site_table_bookings (id) on delete cascade,
  billed_amount_cents int not null check (billed_amount_cents >= 0),
  amount_paid_cents int not null check (amount_paid_cents >= 0),
  payment_method text not null check (payment_method in ('cash', 'debit', 'credit', 'split')),
  split_breakdown jsonb,
  pos_reference text,
  receipt_photo_path text,
  recorded_by uuid references auth.users (id) on delete set null,
  recorded_at timestamptz not null default now(),
  confirm_token uuid not null default gen_random_uuid(),
  customer_confirmation_status text not null default 'pending' check (customer_confirmation_status in ('pending', 'confirmed', 'disputed')),
  customer_confirmed_at timestamptz,
  dispute_reason text,
  dispute_evidence_path text,
  customer_notified_at timestamptz,
  payer_name text,
  payer_email text,
  manager_verified_at timestamptz,
  manager_verified_by uuid references auth.users (id) on delete set null,
  manager_verified_note text,
  corrects_payment_id uuid references public.site_table_booking_club_payments (id) on delete set null,
  bottle_subtotal_cents int not null default 0,
  discount_cents int not null default 0,
  tax_cents int not null default 0,
  gratuity_cents int not null default 0,
  receipt_photo_hash text,
  device_id text,
  missing_receipt_reason text
);
create unique index site_table_booking_club_payments_confirm_token_idx on public.site_table_booking_club_payments (confirm_token);

alter table public.site_table_booking_club_payments enable row level security;
create policy "admins manage club payments" on public.site_table_booking_club_payments
  for all using (public.is_cms_admin()) with check (public.is_cms_admin());
create policy "users read own club payments by verified email" on public.site_table_booking_club_payments
  for select using (
    auth.role() = 'authenticated'
    and exists (select 1 from public.site_table_bookings b
                where b.id = booking_id and lower(b.customer_email) = lower(auth.email()))
  );

-- Production refuses to delete a payment record.
create function public.prevent_club_payment_delete() returns trigger language plpgsql set search_path = public as $$
begin
  raise exception 'club payment records can never be deleted - record a correction instead';
end $$;
create trigger no_delete_club_payments before delete on public.site_table_booking_club_payments
  for each row execute function public.prevent_club_payment_delete();

-- The private bucket the receipts go into, and the two policies production already has on it (staff by the global door_staff table).
insert into storage.buckets (id, name, public) values ('club-payment-receipts', 'club-payment-receipts', false);
create policy "staff read club payment receipts" on storage.objects
  for select using (bucket_id = 'club-payment-receipts' and (public.is_cms_admin() or public.is_door_staff()));
create policy "staff upload club payment receipts" on storage.objects
  for insert with check (bucket_id = 'club-payment-receipts' and (public.is_cms_admin() or public.is_door_staff()));
create policy "admins delete club payment receipts" on storage.objects
  for delete using (bucket_id = 'club-payment-receipts' and public.is_cms_admin());
