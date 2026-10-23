-- Payouts to venues and organizers: the settings BottlesUp controls in the CMS, the payout account status, and a ledger of what was paid (developer brief 15 Oct, sections 20 and 31;
-- the client's answer of 20 Oct: "Should BottlesUp actually pay venues and organizers? Yes: for payments collected through BottlesUp ... Customer pays > Event happens > Payments are
-- checked > Eligible money enters the weekly payout > Venue or organizer receives payment. If the venue collects cash or uses its own card machine, BottlesUp only records it.
-- Do not pay them that money again."; and the user's decision: "payout account structure, BottlesUp's percentage and the weekday: control via the CMS").
--
--   SETTINGS (BottlesUp admins change them in the CMS; owners and organizers only READ what applies to them)
--   * site_payout_settings (one row)       the way money is paid out (manual transfer: the only way until a payment provider's payout accounts are connected), the weekday of the
--                                          weekly payout, how many days after the night the money waits ("hold"), and BottlesUp's percentage of what it pays out
--   * site_payout_overrides                a different percentage, weekday or hold for one business
--   * site_payout_accounts                 the business's payout account STATUS (Incomplete / Under review / Ready / Action required), the account holder and a MASKED account (never a
--                                          full number: the database refuses one), and a note saying what action is needed. Set by BottlesUp after it has checked the details; nothing here
--                                          collects bank details.
--   THE LEDGER (every figure is entered or confirmed by a BottlesUp admin; "Paid" needs a reference: nothing is called paid until a transfer was made)
--   * cms_payout_eligible                  an ESTIMATE per business: the money collected ONLINE through BottlesUp on tables whose night is past the hold and that no payout has taken yet
--                                          (what the booking took in online, not what the club recorded at the club, less BottlesUp's own customer fee), the percentage, the net
--   * cms_create_payout_item               turns the eligible bookings of one business for a period into a payout item (each booking can be in ONE item), with an optional signed adjustment
--   * site_payout_items / site_payout_item_bookings    the item (gross, percentage, commission, adjustment, net, expected date, status, reference) and the bookings it took
--   * cms_set_payout_item_status           Pending > Processing > Paid (with a reference) / Failed (with a reason) / Cancelled (frees its bookings again)
--   * my_payouts(business)                 what an OWNER or ORGANIZER of that business sees: the account status (masked), the settings that apply, the next payout day, the items and what is
--                                          waiting. Read-only. For the table money of a venue's business; an organizer's ticket earnings will be added with settlements.
--
-- Needs the tenancy, accounts and table-service migrations. Plain CREATE; nothing live is replaced.

do $pre$
declare
  r record;
begin
  for r in select * from (values
      ('public.is_cms_admin()'), ('public.setup_int(jsonb, text, text, integer, integer)'), ('public.setup_text(jsonb, text, text, integer)'), ('public.setup_only_keys(jsonb, text[])'),
      ('public.booking_night(date, time without time zone)'), ('public.active_memberships()')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. Tables (closed: written only by the functions below)
-- ---------------------------------------------------------------------------
create table public.site_payout_settings (
  id int primary key default 1 check (id = 1),
  payout_method text not null default 'manual_transfer' check (payout_method in ('manual_transfer')),
  payout_weekday int not null default 3 check (payout_weekday between 0 and 6),   -- 0 Sunday ... 6 Saturday
  hold_days int not null default 2 check (hold_days between 0 and 30),
  commission_bps int not null default 0 check (commission_bps between 0 and 10000),
  commission_set boolean not null default false,                                  -- false until BottlesUp has chosen its percentage
  updated_by uuid references auth.users (id),
  updated_at timestamptz not null default now()
);
insert into public.site_payout_settings (id) values (1);

create table public.site_payout_overrides (
  org_id uuid primary key references public.site_organizations (id) on delete cascade,
  commission_bps int check (commission_bps is null or commission_bps between 0 and 10000),
  payout_weekday int check (payout_weekday is null or payout_weekday between 0 and 6),
  hold_days int check (hold_days is null or hold_days between 0 and 30),
  note text check (note is null or char_length(note) <= 300),
  updated_by uuid references auth.users (id),
  updated_at timestamptz not null default now(),
  constraint site_payout_overrides_something check (commission_bps is not null or payout_weekday is not null or hold_days is not null)
);

create table public.site_payout_accounts (
  org_id uuid primary key references public.site_organizations (id) on delete cascade,
  status text not null default 'incomplete' check (status in ('incomplete', 'under_review', 'ready', 'action_required')),
  account_holder text check (account_holder is null or char_length(account_holder) <= 120),
  masked_account text check (masked_account is null or (char_length(masked_account) <= 24 and masked_account !~ '[0-9]{7,}')),   -- never a full account number
  note text check (note is null or char_length(note) <= 300),
  updated_by uuid references auth.users (id),
  updated_at timestamptz not null default now()
);

create table public.site_payout_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.site_organizations (id),
  period_start date not null,
  period_end date not null,
  gross_cents int not null check (gross_cents >= 0),
  commission_bps int not null check (commission_bps between 0 and 10000),       -- the percentage this item was worked out with
  commission_cents int not null check (commission_cents >= 0),
  adjustments_cents int not null default 0,                                     -- signed: a correction, a refund taken off, a bonus
  adjustment_note text check (adjustment_note is null or char_length(adjustment_note) <= 300),
  net_cents int not null,
  status text not null default 'pending' check (status in ('pending', 'processing', 'paid', 'failed', 'cancelled')),
  expected_on date,
  reference text check (reference is null or char_length(reference) between 3 and 120),
  paid_at timestamptz,
  failure_note text check (failure_note is null or char_length(failure_note) <= 300),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default now(),
  constraint site_payout_items_period_check check (period_end >= period_start),
  constraint site_payout_items_net_check check (net_cents = gross_cents - commission_cents + adjustments_cents),
  constraint site_payout_items_paid_check check (status <> 'paid' or (reference is not null and paid_at is not null)),
  constraint site_payout_items_adjustment_check check (adjustments_cents = 0 or adjustment_note is not null)
);
create index site_payout_items_org_idx on public.site_payout_items (org_id, created_at desc);

create table public.site_payout_item_bookings (
  item_id uuid not null references public.site_payout_items (id) on delete cascade,
  booking_id uuid not null references public.site_table_bookings (id),
  amount_cents int not null check (amount_cents >= 0),
  primary key (item_id, booking_id)
);
create unique index site_payout_item_bookings_one on public.site_payout_item_bookings (booking_id);   -- a booking is in ONE payout item at a time

alter table public.site_payout_settings enable row level security;
alter table public.site_payout_overrides enable row level security;
alter table public.site_payout_accounts enable row level security;
alter table public.site_payout_items enable row level security;
alter table public.site_payout_item_bookings enable row level security;
revoke all on table public.site_payout_settings, public.site_payout_overrides, public.site_payout_accounts, public.site_payout_items, public.site_payout_item_bookings from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers
-- ---------------------------------------------------------------------------
-- The next payout day after today (Toronto) for a weekday (0 Sunday ... 6 Saturday).
create function public.payout_next_date(p_weekday int)
returns date
language sql
stable
set search_path = public
as $$
  select ((now() at time zone 'America/Toronto')::date) + (case when ((p_weekday - extract(dow from (now() at time zone 'America/Toronto'))::int + 7) % 7) = 0 then 7 else ((p_weekday - extract(dow from (now() at time zone 'America/Toronto'))::int + 7) % 7) end)
$$;

-- What applies to one business: the platform's settings, with the business's own override on top.
create function public.payout_effective(p_org uuid)
returns table (commission_bps int, commission_set boolean, payout_weekday int, hold_days int, payout_method text, overridden boolean)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(o.commission_bps, s.commission_bps), (s.commission_set or o.commission_bps is not null), coalesce(o.payout_weekday, s.payout_weekday), coalesce(o.hold_days, s.hold_days),
         s.payout_method, o.org_id is not null
    from public.site_payout_settings s left join public.site_payout_overrides o on o.org_id = p_org
   where s.id = 1
$$;

-- The bookings of one business that can enter a payout now: paid, with an online payment, a night in the period that is past the hold, and in no payout item yet.
-- amount = what the booking took in online (its paid amount less what the club recorded at the club) less BottlesUp's own customer fee, never below zero.
create function public.payout_eligible_bookings(p_org uuid, p_from date, p_to date)
returns table (booking_id uuid, business_night date, amount_cents int)
language sql
stable
security definer
set search_path = public
as $$
  select x.id, x.night, x.amount
    from (
      select b.id, public.booking_night(b.booking_date, s.start_time) as night,
             greatest(greatest(b.amount_paid_cents - coalesce((select sum(cp.amount_paid_cents) from public.site_table_booking_club_payments cp
                                                                where cp.booking_id = b.id and not exists (select 1 from public.site_table_booking_club_payments c2 where c2.corrects_payment_id = cp.id)), 0), 0)
                      - b.bottlesup_fee_cents, 0)::int as amount
        from public.site_table_bookings b
        join public.site_venues v on v.id = b.venue_id
        join public.site_venue_time_slots s on s.id = b.time_slot_id
       where v.org_id = p_org
         and b.status = 'paid' and b.stripe_payment_intent_id is not null
         and not exists (select 1 from public.site_payout_item_bookings l where l.booking_id = b.id)
    ) x
   where x.amount > 0
     and x.night between p_from and p_to
     and x.night <= (now() at time zone 'America/Toronto')::date - (select e.hold_days from public.payout_effective(p_org) e)
$$;
revoke all on function public.payout_next_date(int), public.payout_effective(uuid), public.payout_eligible_bookings(uuid, date, date) from public, anon, authenticated;
grant execute on function public.payout_next_date(int) to service_role;

-- ---------------------------------------------------------------------------
-- 3. The CMS: settings, overrides, accounts
-- ---------------------------------------------------------------------------
create function public.cms_payout_settings()
returns table (payout_method text, payout_weekday int, hold_days int, commission_bps int, commission_set boolean, updated_at timestamp with time zone)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  return query select s.payout_method, s.payout_weekday, s.hold_days, s.commission_bps, s.commission_set, s.updated_at from public.site_payout_settings s where s.id = 1;
end;
$$;

-- Keys that are not sent keep their value. Choosing a percentage marks it as set.
create function public.cms_save_payout_settings(p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_payout_settings;
  v_bps int; v_day int; v_hold int; v_new jsonb; v_old jsonb;
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  perform public.setup_only_keys(p_details, array['commission_bps', 'payout_weekday', 'hold_days']);
  select * into s from public.site_payout_settings where id = 1 for update;
  v_bps := case when p_details ? 'commission_bps' then public.setup_int(p_details, 'commission_bps', 'BottlesUp''s percentage (in hundredths of a percent)', 0, 10000) else s.commission_bps end;
  v_day := case when p_details ? 'payout_weekday' then public.setup_int(p_details, 'payout_weekday', 'the payout weekday', 0, 6) else s.payout_weekday end;
  v_hold := case when p_details ? 'hold_days' then public.setup_int(p_details, 'hold_days', 'the days money waits after the night', 0, 30) else s.hold_days end;
  if v_bps is null or v_day is null or v_hold is null then raise exception 'every setting needs a value'; end if;
  v_old := jsonb_build_object('commission_bps', s.commission_bps, 'payout_weekday', s.payout_weekday, 'hold_days', s.hold_days);
  v_new := jsonb_build_object('commission_bps', v_bps, 'payout_weekday', v_day, 'hold_days', v_hold);
  if v_old = v_new and (s.commission_set or not (p_details ? 'commission_bps')) then return v_new; end if;
  update public.site_payout_settings set commission_bps = v_bps, payout_weekday = v_day, hold_days = v_hold,
    commission_set = commission_set or (p_details ? 'commission_bps'), updated_by = auth.uid(), updated_at = now() where id = 1;
  perform public.desk_log('payout.settings_saved', 'site_payout_settings', '00000000-0000-0000-0000-000000000001'::uuid, jsonb_build_object('from', v_old, 'to', v_new));
  return v_new;
end;
$$;

create function public.cms_payout_overrides()
returns table (org_id uuid, org_name text, org_kind text, commission_bps int, payout_weekday int, hold_days int, note text, updated_at timestamp with time zone)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  return query select o.org_id, g.name, g.kind, o.commission_bps, o.payout_weekday, o.hold_days, o.note, o.updated_at
                 from public.site_payout_overrides o join public.site_organizations g on g.id = o.org_id order by g.name, o.org_id;
end;
$$;

-- A key sent as null removes that part of the override; an override with nothing left is removed.
create function public.cms_save_payout_override(p_org uuid, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.site_payout_overrides;
  v_exists boolean;
  v_bps int; v_day int; v_hold int; v_note text; v_new jsonb;
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.site_organizations g where g.id = p_org) then raise exception 'business not found'; end if;
  perform public.setup_only_keys(p_details, array['commission_bps', 'payout_weekday', 'hold_days', 'note']);
  select * into o from public.site_payout_overrides where org_id = p_org for update;
  v_exists := found;
  v_bps := case when p_details ? 'commission_bps' then public.setup_int(p_details, 'commission_bps', 'BottlesUp''s percentage (in hundredths of a percent)', 0, 10000) else o.commission_bps end;
  v_day := case when p_details ? 'payout_weekday' then public.setup_int(p_details, 'payout_weekday', 'the payout weekday', 0, 6) else o.payout_weekday end;
  v_hold := case when p_details ? 'hold_days' then public.setup_int(p_details, 'hold_days', 'the days money waits after the night', 0, 30) else o.hold_days end;
  v_note := case when p_details ? 'note' then public.setup_text(p_details, 'note', 'the note', 300) else o.note end;
  if v_bps is null and v_day is null and v_hold is null then
    delete from public.site_payout_overrides where org_id = p_org;
    if v_exists then perform public.desk_log('payout.override_removed', 'site_organizations', p_org, jsonb_build_object('org_id', p_org)); end if;
    return null;
  end if;
  v_new := jsonb_build_object('commission_bps', v_bps, 'payout_weekday', v_day, 'hold_days', v_hold, 'note', v_note);
  insert into public.site_payout_overrides (org_id, commission_bps, payout_weekday, hold_days, note, updated_by, updated_at) values (p_org, v_bps, v_day, v_hold, v_note, auth.uid(), now())
  on conflict (org_id) do update set commission_bps = excluded.commission_bps, payout_weekday = excluded.payout_weekday, hold_days = excluded.hold_days, note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  perform public.desk_log('payout.override_saved', 'site_organizations', p_org, jsonb_build_object('org_id', p_org, 'to', v_new));
  return v_new;
end;
$$;

create function public.cms_payout_accounts()
returns table (org_id uuid, org_name text, org_kind text, status text, account_holder text, masked_account text, note text, updated_at timestamp with time zone)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  return query select g.id, g.name, g.kind, coalesce(a.status, 'incomplete'), a.account_holder, a.masked_account, a.note, a.updated_at
                 from public.site_organizations g left join public.site_payout_accounts a on a.org_id = g.id order by g.name, g.id;
end;
$$;

create function public.cms_save_payout_account(p_org uuid, p_details jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_payout_accounts;
  v_status text; v_holder text; v_mask text; v_note text;
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.site_organizations g where g.id = p_org) then raise exception 'business not found'; end if;
  perform public.setup_only_keys(p_details, array['status', 'account_holder', 'masked_account', 'note']);
  select * into a from public.site_payout_accounts where org_id = p_org for update;
  v_status := case when p_details ? 'status' then public.setup_text(p_details, 'status', 'the status', 20) else coalesce(a.status, 'incomplete') end;
  v_holder := case when p_details ? 'account_holder' then public.setup_text(p_details, 'account_holder', 'the account holder', 120) else a.account_holder end;
  v_mask := case when p_details ? 'masked_account' then public.setup_text(p_details, 'masked_account', 'the masked account', 24) else a.masked_account end;
  v_note := case when p_details ? 'note' then public.setup_text(p_details, 'note', 'the note', 300) else a.note end;
  if v_status is null or v_status not in ('incomplete', 'under_review', 'ready', 'action_required') then raise exception 'the status must be incomplete, under review, ready or action required'; end if;
  if v_mask is not null and v_mask ~ '[0-9]{7,}' then raise exception 'never enter a full account number: only the last few digits, for example •••• 1234'; end if;
  if v_status = 'ready' and (v_holder is null or v_mask is null) then raise exception 'an account is only ready once it has an account holder and the last digits of the account'; end if;
  if v_status = 'action_required' and v_note is null then raise exception 'say what action is needed, so the business can be told'; end if;
  insert into public.site_payout_accounts (org_id, status, account_holder, masked_account, note, updated_by, updated_at) values (p_org, v_status, v_holder, v_mask, v_note, auth.uid(), now())
  on conflict (org_id) do update set status = excluded.status, account_holder = excluded.account_holder, masked_account = excluded.masked_account, note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  perform public.desk_log('payout.account_saved', 'site_organizations', p_org, jsonb_build_object('org_id', p_org, 'status', v_status, 'from', a.status));
  return v_status;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The CMS: what is eligible, the payout items
-- ---------------------------------------------------------------------------
create function public.cms_payout_eligible(p_from date, p_to date)
returns table (org_id uuid, org_name text, bookings int, gross_cents int, commission_bps int, commission_cents int, net_cents int, commission_set boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'choose the first and the last night'; end if;
  if p_to - p_from > 366 then raise exception 'choose a period of a year at most'; end if;
  return query
    select g.id, g.name, count(e.booking_id)::int, coalesce(sum(e.amount_cents), 0)::int, f.commission_bps,
           round(coalesce(sum(e.amount_cents), 0) * f.commission_bps / 10000.0)::int,
           (coalesce(sum(e.amount_cents), 0) - round(coalesce(sum(e.amount_cents), 0) * f.commission_bps / 10000.0))::int, f.commission_set
      from public.site_organizations g
      cross join lateral public.payout_effective(g.id) f
      cross join lateral public.payout_eligible_bookings(g.id, p_from, p_to) e
     group by g.id, g.name, f.commission_bps, f.commission_set
     order by g.name, g.id;
end;
$$;

create function public.cms_create_payout_item(p_org uuid, p_from date, p_to date, p_adjustment_cents int default 0, p_adjustment_note text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  f record;
  v_gross int;
  v_commission int;
  v_adj int := coalesce(p_adjustment_cents, 0);
  v_note text := nullif(btrim(coalesce(p_adjustment_note, '')), '');
  v_count int;
  v_ids uuid[];
  v_amounts int[];
  v_id uuid;
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.site_organizations g where g.id = p_org) then raise exception 'business not found'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'choose the first and the last night'; end if;
  if p_to - p_from > 366 then raise exception 'choose a period of a year at most'; end if;
  select * into f from public.payout_effective(p_org);
  if not f.commission_set then raise exception 'choose BottlesUp''s percentage first (in the payout settings), so the payout can be worked out'; end if;
  if v_adj <> 0 and v_note is null then raise exception 'say what the adjustment is for'; end if;
  if v_note is not null and char_length(v_note) > 300 then raise exception 'the adjustment note can be up to 300 characters'; end if;
  perform 1 from public.site_organizations g where g.id = p_org for update;      -- one payout is made for a business at a time

  select count(*)::int, coalesce(sum(e.amount_cents), 0)::int, array_agg(e.booking_id), array_agg(e.amount_cents)
    into v_count, v_gross, v_ids, v_amounts from public.payout_eligible_bookings(p_org, p_from, p_to) e;
  if v_count = 0 then raise exception 'nothing is eligible for that period: no paid online bookings past the waiting days that are not already in a payout'; end if;
  v_commission := round(v_gross * f.commission_bps / 10000.0)::int;
  if v_gross - v_commission + v_adj < 0 then raise exception 'the adjustment is more than the payout comes to'; end if;
  insert into public.site_payout_items (org_id, period_start, period_end, gross_cents, commission_bps, commission_cents, adjustments_cents, adjustment_note, net_cents, expected_on, created_by)
  values (p_org, p_from, p_to, v_gross, f.commission_bps, v_commission, v_adj, v_note, v_gross - v_commission + v_adj, public.payout_next_date(f.payout_weekday), auth.uid()) returning id into v_id;
  insert into public.site_payout_item_bookings (item_id, booking_id, amount_cents) select v_id, x.b, x.a from unnest(v_ids, v_amounts) as x(b, a);
  perform public.desk_log('payout.item_created', 'site_payout_items', v_id, jsonb_build_object('org_id', p_org, 'gross_cents', v_gross, 'commission_cents', v_commission, 'adjustment_cents', v_adj, 'bookings', v_count));
  return v_id;
end;
$$;

create function public.cms_set_payout_item_status(p_item uuid, p_status text, p_reference text default null, p_note text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.site_payout_items;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  select * into i from public.site_payout_items where id = p_item for update;
  if not found then raise exception 'payout not found'; end if;
  if p_status is null or p_status not in ('processing', 'paid', 'failed', 'cancelled') then raise exception 'choose processing, paid, failed or cancelled'; end if;
  if i.status = p_status then return i.status; end if;
  if i.status in ('paid', 'cancelled') then raise exception 'a payout that is % cannot be changed', i.status; end if;
  if v_note is not null and char_length(v_note) > 300 then raise exception 'the note can be up to 300 characters'; end if;
  if p_status = 'processing' and i.status <> 'pending' then raise exception 'only a pending payout can be marked as processing'; end if;
  if p_status = 'paid' then
    if v_ref is null or char_length(v_ref) < 3 or char_length(v_ref) > 120 then raise exception 'enter the transfer reference: a payout is not paid until a transfer was made'; end if;
    update public.site_payout_items set status = 'paid', reference = v_ref, paid_at = now(), failure_note = null, updated_at = now() where id = p_item;
  elsif p_status = 'failed' then
    if v_note is null or char_length(v_note) < 3 then raise exception 'say why the payout failed'; end if;
    update public.site_payout_items set status = 'failed', failure_note = v_note, updated_at = now() where id = p_item;
  elsif p_status = 'cancelled' then
    delete from public.site_payout_item_bookings where item_id = p_item;      -- the bookings can go into another payout
    update public.site_payout_items set status = 'cancelled', updated_at = now() where id = p_item;
  else
    update public.site_payout_items set status = 'processing', updated_at = now() where id = p_item;
  end if;
  perform public.desk_log('payout.item_' || p_status, 'site_payout_items', p_item, jsonb_build_object('org_id', i.org_id, 'from', i.status, 'reference', v_ref, 'reason', v_note));
  return p_status;
end;
$$;

create function public.cms_payout_items(p_status text default null, p_org uuid default null)
returns table (
  item_id uuid, org_id uuid, org_name text, period_start date, period_end date, gross_cents int, commission_bps int, commission_cents int, adjustments_cents int, adjustment_note text,
  net_cents int, status text, expected_on date, reference text, paid_at timestamp with time zone, failure_note text, bookings int, created_at timestamp with time zone
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  if p_status is not null and p_status not in ('pending', 'processing', 'paid', 'failed', 'cancelled') then raise exception 'unknown status'; end if;
  return query
    select i.id, i.org_id, g.name, i.period_start, i.period_end, i.gross_cents, i.commission_bps, i.commission_cents, i.adjustments_cents, i.adjustment_note, i.net_cents, i.status, i.expected_on,
           i.reference, i.paid_at, i.failure_note, (select count(*)::int from public.site_payout_item_bookings l where l.item_id = i.id), i.created_at
      from public.site_payout_items i join public.site_organizations g on g.id = i.org_id
     where (p_status is null or i.status = p_status) and (p_org is null or i.org_id = p_org)
     order by (i.status in ('pending', 'processing', 'failed')) desc, i.created_at desc, i.id
     limit 500;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. What an owner or organizer sees of their own business (read-only)
-- ---------------------------------------------------------------------------
create function public.my_payouts(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f record;
  a public.site_payout_accounts;
  v_kind text;
  v_elig record;
  v_items jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_org is null or not exists (select 1 from public.active_memberships() m where m.org_id = p_org and m.role in ('owner', 'organizer')) then raise exception 'not allowed'; end if;
  select g.kind into v_kind from public.site_organizations g where g.id = p_org;
  select * into f from public.payout_effective(p_org);
  select * into a from public.site_payout_accounts where org_id = p_org;
  select count(*)::int as n, coalesce(sum(e.amount_cents), 0)::int as gross into v_elig
    from public.payout_eligible_bookings(p_org, (now() at time zone 'America/Toronto')::date - 400, (now() at time zone 'America/Toronto')::date) e;
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'period_start', i.period_start, 'period_end', i.period_end, 'gross_cents', i.gross_cents, 'commission_cents', i.commission_cents,
           'adjustments_cents', i.adjustments_cents, 'adjustment_note', i.adjustment_note, 'net_cents', i.net_cents, 'status', i.status, 'expected_on', i.expected_on, 'reference', i.reference,
           'paid_at', i.paid_at, 'failure_note', i.failure_note) order by i.created_at desc), '[]'::jsonb) into v_items
    from (select * from public.site_payout_items where org_id = p_org and status <> 'cancelled' order by created_at desc limit 50) i;
  return jsonb_build_object(
    'org_kind', v_kind,
    'account', jsonb_build_object('status', coalesce(a.status, 'incomplete'), 'account_holder', a.account_holder, 'masked_account', a.masked_account, 'note', a.note),
    'settings', jsonb_build_object('payout_method', f.payout_method, 'commission_set', f.commission_set, 'commission_bps', case when f.commission_set then f.commission_bps end,
                 'payout_weekday', f.payout_weekday, 'hold_days', f.hold_days, 'next_payout_on', public.payout_next_date(f.payout_weekday), 'own_arrangement', f.overridden),
    'waiting', case when v_kind = 'venue_owner' then jsonb_build_object('bookings', v_elig.n, 'gross_cents', v_elig.gross) end,
    'items', v_items);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
revoke all on function
  public.cms_payout_settings(), public.cms_save_payout_settings(jsonb), public.cms_payout_overrides(), public.cms_save_payout_override(uuid, jsonb), public.cms_payout_accounts(),
  public.cms_save_payout_account(uuid, jsonb), public.cms_payout_eligible(date, date), public.cms_create_payout_item(uuid, date, date, int, text),
  public.cms_set_payout_item_status(uuid, text, text, text), public.cms_payout_items(text, uuid), public.my_payouts(uuid)
  from public, anon;
grant execute on function
  public.cms_payout_settings(), public.cms_save_payout_settings(jsonb), public.cms_payout_overrides(), public.cms_save_payout_override(uuid, jsonb), public.cms_payout_accounts(),
  public.cms_save_payout_account(uuid, jsonb), public.cms_payout_eligible(date, date), public.cms_create_payout_item(uuid, date, date, int, text),
  public.cms_set_payout_item_status(uuid, text, text, text), public.cms_payout_items(text, uuid), public.my_payouts(uuid)
  to authenticated, service_role;
