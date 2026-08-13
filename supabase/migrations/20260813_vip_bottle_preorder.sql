-- VIP bottle pre-order: bottle catalog per venue, cart line items on a table
-- booking, and the cost-breakdown fields (bottle subtotal / tax / BottlesUp
-- fee) needed to show "table deposit + bottles + tax + fee = total" at
-- checkout, per the BottlesUp VIP Table + Bottle Pre-Order product doc.

create table public.site_bottles (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues(id) on delete cascade,
  name text not null,
  size text, -- e.g. "750ml"
  description text,
  price_cents int not null check (price_cents >= 0),
  currency text not null default 'cad',
  category text, -- e.g. "Tequila", "Champagne"
  image_url text,
  is_available boolean not null default true, -- pre-order ON/OFF
  is_sold_out boolean not null default false, -- venue can 86 a bottle without hiding/deleting it
  stock_quantity int, -- optional; null = untracked/unlimited
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Line items for a paid table booking's bottle order. Bottle name/price are
-- snapshotted here (not just a bottle_id FK) so a later catalog edit never
-- rewrites the receipt for an order that already happened.
create table public.site_table_booking_bottles (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.site_table_bookings(id) on delete cascade,
  bottle_id uuid references public.site_bottles(id) on delete set null,
  bottle_name text not null,
  size text,
  unit_price_cents int not null check (unit_price_cents >= 0),
  quantity int not null check (quantity > 0),
  line_total_cents int not null check (line_total_cents >= 0),
  created_at timestamptz not null default now()
);

-- amount_total_cents already holds "the amount actually charged" (see
-- create-table-booking-checkout), which up to now was just the deposit /
-- hourly total. These new columns break that figure down into its parts so
-- the CMS and confirmation email can show a real line-by-line receipt, per
-- the doc's "Review Cart" step (deposit + bottle subtotal + tax + fee = total).
alter table public.site_table_bookings
  add column deposit_cents int not null default 0,
  add column bottle_subtotal_cents int not null default 0,
  add column tax_cents int not null default 0,
  add column bottlesup_fee_cents int not null default 0,
  add column fulfillment_status text not null default 'confirmed'
    check (fulfillment_status in ('confirmed', 'preparing', 'served', 'completed'));

-- Backfill existing rows: their entire amount_total_cents was the deposit/hourly
-- charge, with no bottles/tax/fee involved.
update public.site_table_bookings set deposit_cents = amount_total_cents;

-- Per-venue sales tax rate (basis points, e.g. 1300 = 13%) - venues are in
-- different jurisdictions so this isn't a single global number. Defaults to 0
-- so existing venues keep charging exactly what they charge today until a
-- venue admin sets a real rate.
alter table public.site_venues
  add column tax_rate_bps int not null default 0 check (tax_rate_bps >= 0),
  add column show_bottle_images boolean not null default true;

-- Platform-wide BottlesUp service fee (basis points), applied to deposit +
-- bottle subtotal at checkout. One global rate, set from CMS Site Content -
-- unlike tax this isn't jurisdiction-specific, it's BottlesUp's own fee.
alter table public.site_content
  add column bottlesup_fee_bps int not null default 0 check (bottlesup_fee_bps >= 0);

alter table public.site_bottles enable row level security;
alter table public.site_table_booking_bottles enable row level security;

create policy "public read available bottles for published venues" on public.site_bottles
  for select using (
    public.is_cms_admin()
    or (
      is_available and not is_sold_out
      and exists (select 1 from public.site_venues v where v.id = venue_id and v.status = 'published')
    )
  );
create policy "admins manage bottles" on public.site_bottles
  for all using (public.is_cms_admin()) with check (public.is_cms_admin());

-- Line items: same pattern as site_table_bookings - only ever written by the
-- create-table-booking-checkout edge function using the service_role key.
create policy "admins read booking bottles" on public.site_table_booking_bottles
  for select using (public.is_cms_admin());

create trigger site_bottles_set_updated_at before update on public.site_bottles
  for each row execute function public.set_updated_at();
