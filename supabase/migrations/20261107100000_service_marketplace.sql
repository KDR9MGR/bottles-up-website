-- Hiring professionals (customer app completion plan, M7; client plan page 10): a DJ, photographer, MC or other professional lists services; a customer sends a request for a date; the
-- professional answers with a quote (total, scope, a deposit, when the balance is due); the customer accepts and pays the deposit (or all of it) on Stripe's page; BottlesUp HOLDS the money;
-- after the job it is confirmed (or auto-confirmed) and the professional is paid out by BottlesUp, less the commission.
--
--   * WHO: a professional is a BUSINESS profile whose category is not a venue or an event group; whoever may act as it (profile_can_act_as) runs its services, requests and quotes.
--     A customer is any signed-in person; they cannot hire a profile they run themselves, nor one that blocked them or they blocked.
--   * THE FLOW: request (a date, a place, a message, optionally a service and a budget) -> ONE live quote per request (a new quote withdraws the old) -> accept (the quote must still be valid,
--     the date free) -> a booking that must be paid within 24 hours (the deposit, or everything when the deposit is the whole amount) -> the balance by its due date -> the professional marks it
--     done on or after the date -> the customer confirms (or three days pass) -> the payout is releasable -> BottlesUp pays the professional and records it (cms_pro_payout_paid).
--   * MONEY: the exact amounts are the quote's; the commission is a percentage fixed when the quote is accepted (site_pro_settings, 5% to start); payments are idempotent by Stripe session;
--     refunds are idempotent by Stripe refund id; both are for the website's service role alone (the same discipline as splitting a bill, 20261106100000).
--   * CANCELLING: the professional cancels any time and everything paid is paid back; the customer cancels at least `free_cancel_days` (7) before the date and everything paid is paid back;
--     later, BottlesUp keeps the deposit (at least 30% of the total) for the professional and pays back the rest. Unpaid acceptances lapse after 24 hours; a balance not paid by its due
--     date cancels the booking the same way (the customer lost the deposit).
--   * DISPUTES: the customer may open one from the date until 7 days after it, while the booking is not completed: the payout is held and BottlesUp's staff decide (release, refund in part,
--     refund in full) in the CMS. Everything is in the audit log.
--   * Every function refuses with "Hiring professionals is not open yet." until the `marketplace` switch is on (20261101100000).
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.site_pro_settings (
  id int primary key default 1 check (id = 1),
  commission_bps int not null default 500 check (commission_bps between 0 and 5000),
  free_cancel_days int not null default 7 check (free_cancel_days between 0 and 60),
  confirm_days int not null default 3 check (confirm_days between 1 and 30),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);
insert into public.site_pro_settings (id) values (1);

create table public.site_pro_services (
  id uuid primary key default gen_random_uuid(),
  profile uuid not null references public.site_profiles (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 3 and 80),
  description text check (description is null or char_length(description) <= 1000),
  from_cents int check (from_cents is null or from_cents between 0 and 5000000),
  price_note text check (price_note is null or char_length(price_note) <= 80),
  active boolean not null default true,
  created_at timestamptz not null default clock_timestamp()
);
create index site_pro_services_profile_idx on public.site_pro_services (profile, active, created_at);

-- Days a professional is not free, set by hand (days with an accepted booking are busy too, worked out from the bookings).
create table public.site_pro_busy (
  profile uuid not null references public.site_profiles (id) on delete cascade,
  day date not null,
  primary key (profile, day)
);

create table public.site_pro_requests (
  id uuid primary key default gen_random_uuid(),
  client uuid references auth.users (id) on delete set null,
  provider uuid references public.site_profiles (id) on delete set null,
  service uuid references public.site_pro_services (id) on delete set null,
  event_date date not null,
  time_note text check (time_note is null or char_length(time_note) <= 60),
  location text check (location is null or char_length(location) <= 160),
  guests int check (guests is null or guests between 1 and 100000),
  message text not null check (char_length(btrim(message)) between 3 and 1000),
  budget_cents int check (budget_cents is null or budget_cents between 0 and 50000000),
  status text not null default 'requested' check (status in ('requested', 'quoted', 'declined', 'withdrawn', 'accepted')),
  decline_note text check (decline_note is null or char_length(decline_note) <= 300),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create index site_pro_requests_client_idx on public.site_pro_requests (client, created_at desc);
create index site_pro_requests_provider_idx on public.site_pro_requests (provider, status, created_at desc);

create table public.site_pro_quotes (
  id uuid primary key default gen_random_uuid(),
  request uuid not null references public.site_pro_requests (id) on delete cascade,
  total_cents int not null check (total_cents between 1000 and 5000000),
  deposit_cents int not null check (deposit_cents > 0),
  balance_due_by date,
  scope text not null check (char_length(btrim(scope)) between 10 and 1500),
  valid_until timestamptz not null,
  status text not null default 'sent' check (status in ('sent', 'accepted', 'declined', 'withdrawn')),
  created_at timestamptz not null default clock_timestamp(),
  constraint site_pro_quotes_deposit_le_total check (deposit_cents <= total_cents),
  constraint site_pro_quotes_balance_date check ((deposit_cents = total_cents) = (balance_due_by is null))
);
create unique index site_pro_quotes_one_live on public.site_pro_quotes (request) where status = 'sent';

create table public.site_pro_bookings (
  id uuid primary key default gen_random_uuid(),
  quote uuid not null unique references public.site_pro_quotes (id) on delete restrict,
  request uuid not null references public.site_pro_requests (id) on delete cascade,
  client uuid references auth.users (id) on delete set null,
  provider uuid references public.site_profiles (id) on delete set null,
  title text not null,
  event_date date not null,
  currency text not null default 'cad',
  total_cents int not null check (total_cents > 0),
  deposit_cents int not null check (deposit_cents > 0 and deposit_cents <= total_cents),
  balance_due_by date,
  commission_bps int not null check (commission_bps between 0 and 5000),
  free_cancel_days int not null,
  pay_by timestamptz not null,
  status text not null default 'awaiting_deposit' check (status in ('awaiting_deposit', 'active', 'completed', 'disputed', 'cancelled')),
  paid_cents int not null default 0 check (paid_cents >= 0),
  provider_done_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by text check (cancelled_by in ('client', 'provider', 'system')),
  cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 300),
  created_at timestamptz not null default clock_timestamp(),
  constraint site_pro_bookings_cancelled_shape check ((status = 'cancelled') = (cancelled_at is not null and cancelled_by is not null)),
  constraint site_pro_bookings_completed_shape check ((status = 'completed') = (completed_at is not null))
);
create index site_pro_bookings_client_idx on public.site_pro_bookings (client, created_at desc);
create index site_pro_bookings_provider_idx on public.site_pro_bookings (provider, event_date);

create table public.site_pro_payments (
  id uuid primary key default gen_random_uuid(),
  booking uuid not null references public.site_pro_bookings (id) on delete cascade,
  kind text not null check (kind in ('deposit', 'balance', 'full')),
  amount_cents int not null check (amount_cents > 0),
  status text not null default 'created' check (status in ('created', 'pending', 'paid', 'void')),
  stripe_session_id text unique,
  stripe_payment_intent_id text,
  pending_until timestamptz,
  paid_at timestamptz,
  paid_cents int not null default 0 check (paid_cents >= 0),
  refund_due_cents int not null default 0 check (refund_due_cents >= 0),
  refunded_cents int not null default 0 check (refunded_cents >= 0),
  refund_id text,
  created_at timestamptz not null default clock_timestamp(),
  constraint site_pro_payments_money check (refund_due_cents <= paid_cents and refunded_cents <= refund_due_cents),
  constraint site_pro_payments_paid_shape check ((status = 'paid') = (paid_at is not null))
);
create index site_pro_payments_booking_idx on public.site_pro_payments (booking, created_at);
create index site_pro_payments_refund_idx on public.site_pro_payments (booking) where refund_due_cents > refunded_cents;

create table public.site_pro_disputes (
  id uuid primary key default gen_random_uuid(),
  booking uuid not null unique references public.site_pro_bookings (id) on delete cascade,
  opened_by uuid references auth.users (id) on delete set null,
  reason text not null check (char_length(btrim(reason)) between 10 and 1000),
  status text not null default 'open' check (status in ('open', 'resolved')),
  outcome text check (outcome in ('release', 'refund_part', 'refund_full')),
  refund_cents int check (refund_cents is null or refund_cents >= 0),
  note text check (note is null or char_length(note) <= 500),
  decided_by uuid references auth.users (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  constraint site_pro_disputes_shape check ((status = 'resolved') = (outcome is not null and decided_at is not null))
);

create table public.site_pro_payouts (
  id uuid primary key default gen_random_uuid(),
  booking uuid not null unique references public.site_pro_bookings (id) on delete restrict,
  provider uuid references public.site_profiles (id) on delete set null,
  gross_cents int not null check (gross_cents > 0),
  commission_cents int not null check (commission_cents >= 0),
  net_cents int not null check (net_cents >= 0),
  status text not null default 'releasable' check (status in ('held', 'releasable', 'paid', 'void')),
  reference text check (reference is null or char_length(reference) <= 120),
  paid_at timestamptz,
  paid_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  constraint site_pro_payouts_net check (net_cents = gross_cents - commission_cents),
  constraint site_pro_payouts_paid_shape check ((status = 'paid') = (paid_at is not null and reference is not null))
);
create index site_pro_payouts_status_idx on public.site_pro_payouts (status, created_at);

alter table public.site_pro_settings enable row level security;
alter table public.site_pro_services enable row level security;
alter table public.site_pro_busy enable row level security;
alter table public.site_pro_requests enable row level security;
alter table public.site_pro_quotes enable row level security;
alter table public.site_pro_bookings enable row level security;
alter table public.site_pro_payments enable row level security;
alter table public.site_pro_disputes enable row level security;
alter table public.site_pro_payouts enable row level security;
revoke all on table public.site_pro_settings, public.site_pro_services, public.site_pro_busy, public.site_pro_requests, public.site_pro_quotes, public.site_pro_bookings,
  public.site_pro_payments, public.site_pro_disputes, public.site_pro_payouts from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Helpers (internal)
-- ---------------------------------------------------------------------------
create function public.market_require_on()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not public.feature_enabled('marketplace') then raise exception 'Hiring professionals is not open yet.'; end if;
end;
$$;

-- Is this profile one that can sell services? A business profile that is neither a venue nor an event group, in good standing.
create function public.market_is_provider(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.site_profiles p where p.id = p_profile and p.kind = 'business' and p.status = 'active' and p.category not in ('venue', 'event_group'))
$$;

-- The professional's side of a request or booking: the actor must be a professional the caller may act as.
create function public.market_require_provider(p_actor uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.market_require_on();
  if p_actor is null or not public.profile_can_act_as(p_actor) then raise exception 'You cannot act as this profile.'; end if;
  if not public.market_is_provider(p_actor) then raise exception 'Only a professional profile can do this.'; end if;
end;
$$;

create function public.market_commission_bps(p_provider uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select s.commission_bps from public.site_pro_settings s where s.id = 1
$$;

-- Is the day taken? Set by hand, or held by a booking that is waiting for its deposit (still inside its 24 hours), confirmed, done or in dispute.
create function public.market_day_busy(p_provider uuid, p_day date, p_except_booking uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.site_pro_busy b where b.profile = p_provider and b.day = p_day)
      or exists (select 1 from public.site_pro_bookings k
                  where k.provider = p_provider and k.event_date = p_day and k.id is distinct from p_except_booking
                    and (k.status in ('active', 'disputed') or (k.status = 'awaiting_deposit' and k.pay_by > now())))
$$;

-- What a person sees of a booking's progress, in one word.
create function public.market_booking_state(p_booking uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when b.status = 'cancelled' then 'cancelled'
    when b.status = 'completed' then 'completed'
    when b.status = 'disputed' then 'disputed'
    when b.status = 'awaiting_deposit' and b.pay_by <= now() then 'expired'
    when b.status = 'awaiting_deposit' then 'awaiting_deposit'
    when b.provider_done_at is not null then 'done'
    when b.paid_cents >= b.total_cents then 'paid'
    else 'confirmed'
  end
  from public.site_pro_bookings b where b.id = p_booking
$$;

create function public.market_money(p_cents int)
returns text
language sql
immutable
set search_path = public
as $$
  select to_char(p_cents / 100.0, 'FM999,999,990.00')
$$;

-- A person for the other side to see: their name and username, nothing else.
create function public.market_person(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when pr.id is null then null else jsonb_build_object('name', coalesce(nullif(btrim(pr.name), ''), pr.username, 'A customer'), 'handle', pr.username) end
    from (select 1) x left join public.profiles pr on pr.id = p_user
$$;

create function public.market_quote_json(p_quote uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', q.id, 'total_cents', q.total_cents, 'deposit_cents', q.deposit_cents, 'balance_due_by', q.balance_due_by, 'scope', q.scope, 'valid_until', q.valid_until,
    'status', case when q.status = 'sent' and q.valid_until <= now() then 'expired' else q.status end, 'created_at', q.created_at)
    from public.site_pro_quotes q where q.id = p_quote
$$;

-- One booking as either side sees it. `side` says which.
create function public.market_booking_json(p_booking uuid, p_side text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
  v_state text;
begin
  select * into b from public.site_pro_bookings where id = p_booking;
  if not found then return null; end if;
  v_state := public.market_booking_state(p_booking);
  return jsonb_build_object(
    'id', b.id, 'request_id', b.request, 'state', v_state, 'title', b.title, 'event_date', b.event_date, 'currency', b.currency,
    'total_cents', b.total_cents, 'deposit_cents', b.deposit_cents, 'balance_due_by', b.balance_due_by, 'paid_cents', b.paid_cents,
    'owed_cents', greatest(b.total_cents - b.paid_cents, 0),
    'pay_by', b.pay_by, 'provider_done_at', b.provider_done_at, 'completed_at', b.completed_at, 'cancelled_by', b.cancelled_by, 'cancel_reason', b.cancel_reason,
    'free_cancel_days', b.free_cancel_days,
    'provider', case when b.provider is null then null else public.profile_mini(b.provider) end,
    'client', case when p_side = 'provider' then public.market_person(b.client) else null end,
    'net_cents', case when p_side = 'provider' then b.total_cents - (b.total_cents::bigint * b.commission_bps / 10000)::int else null end,
    'commission_bps', case when p_side = 'provider' then b.commission_bps else null end,
    'dispute', (select jsonb_build_object('id', d.id, 'status', d.status, 'outcome', d.outcome, 'reason', d.reason) from public.site_pro_disputes d where d.booking = b.id),
    'created_at', b.created_at);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The professional: services and days off
-- ---------------------------------------------------------------------------
create function public.pro_service_save(p_actor uuid, p_id uuid, p_title text, p_description text, p_from_cents int, p_note text, p_active boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text := btrim(coalesce(p_title, ''));
  v_desc text := nullif(btrim(coalesce(p_description, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
begin
  perform public.market_require_provider(p_actor);
  if char_length(v_title) < 3 or char_length(v_title) > 80 then raise exception 'Give the service a name of 3 to 80 characters.'; end if;
  if v_desc is not null and char_length(v_desc) > 1000 then raise exception 'Keep the description to 1000 characters.'; end if;
  if v_note is not null and char_length(v_note) > 80 then raise exception 'Keep the price note to 80 characters.'; end if;
  if p_from_cents is not null and (p_from_cents < 0 or p_from_cents > 5000000) then raise exception 'Choose a price between 0 and 50,000.00.'; end if;
  if not (public.social_text_ok(v_title) and public.social_text_ok(v_desc) and public.social_text_ok(v_note)) then raise exception 'That wording is not allowed here.'; end if;
  if p_id is null then
    if (select count(*) from public.site_pro_services s where s.profile = p_actor) >= 20 then raise exception 'A profile can list up to 20 services.'; end if;
    insert into public.site_pro_services (profile, title, description, from_cents, price_note, active) values (p_actor, v_title, v_desc, p_from_cents, v_note, coalesce(p_active, true)) returning id into v_id;
  else
    update public.site_pro_services set title = v_title, description = v_desc, from_cents = p_from_cents, price_note = v_note, active = coalesce(p_active, true) where id = p_id and profile = p_actor returning id into v_id;
    if v_id is null then raise exception 'That service is not available.'; end if;
  end if;
  return (select jsonb_build_object('id', s.id, 'title', s.title, 'description', s.description, 'from_cents', s.from_cents, 'price_note', s.price_note, 'active', s.active) from public.site_pro_services s where s.id = v_id);
end;
$$;

create function public.pro_service_remove(p_actor uuid, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.market_require_provider(p_actor);
  delete from public.site_pro_services where id = p_id and profile = p_actor;
  if not found then raise exception 'That service is not available.'; end if;
end;
$$;

-- The services of a professional: everyone sees the active ones, the professional's own team sees all.
create function public.pro_services_of(p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_mine boolean;
begin
  perform public.market_require_on();
  if not public.market_is_provider(p_profile) then return '[]'::jsonb; end if;
  v_mine := public.profile_is_mine(p_profile);
  if not v_mine and exists (select 1 from public.site_profiles me where me.user_id = auth.uid() and me.kind = 'personal' and public.profile_blocked_between(me.id, p_profile)) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'description', s.description, 'from_cents', s.from_cents, 'price_note', s.price_note, 'active', s.active) order by s.created_at, s.id)
                     from public.site_pro_services s where s.profile = p_profile and (s.active or v_mine)), '[]'::jsonb);
end;
$$;

-- Marks a day as not free (or free again).
create function public.pro_busy_set(p_actor uuid, p_day date, p_busy boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.market_require_provider(p_actor);
  if p_day is null or p_day < current_date or p_day > current_date + 730 then raise exception 'Choose a day within the next two years.'; end if;
  if p_busy then
    insert into public.site_pro_busy (profile, day) values (p_actor, p_day) on conflict do nothing;
  else
    delete from public.site_pro_busy where profile = p_actor and day = p_day;
  end if;
end;
$$;

-- The days a professional is not free in a window of up to 400 days from p_from.
create function public.pro_busy_days(p_profile uuid, p_from date, p_days int default 120)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from date := coalesce(p_from, current_date);
  v_to date := coalesce(p_from, current_date) + least(greatest(coalesce(p_days, 120), 1), 400);
begin
  perform public.market_require_on();
  if not public.market_is_provider(p_profile) then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(d order by d) from (
      select b.day as d from public.site_pro_busy b where b.profile = p_profile and b.day >= v_from and b.day < v_to
      union
      select k.event_date from public.site_pro_bookings k
       where k.provider = p_profile and k.event_date >= v_from and k.event_date < v_to
         and (k.status in ('active', 'disputed') or (k.status = 'awaiting_deposit' and k.pay_by > now()))
    ) x), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Requests and quotes
-- ---------------------------------------------------------------------------
create function public.pro_request_create(p_provider uuid, p_service uuid, p_event_date date, p_time_note text, p_location text, p_guests int, p_message text, p_budget_cents int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_msg text := btrim(coalesce(p_message, ''));
  v_time text := nullif(btrim(coalesce(p_time_note, '')), '');
  v_loc text := nullif(btrim(coalesce(p_location, '')), '');
  v_me uuid;
  v_id uuid;
begin
  perform public.market_require_on();
  perform public.social_require_rules();
  if not public.market_is_provider(p_provider) then raise exception 'This professional is not available.'; end if;
  if public.profile_is_mine(p_provider) then raise exception 'You cannot hire yourself.'; end if;
  select p.id into v_me from public.site_profiles p where p.user_id = auth.uid() and p.kind = 'personal';
  if v_me is not null and public.profile_blocked_between(v_me, p_provider) then raise exception 'This professional is not available.'; end if;
  if p_service is not null and not exists (select 1 from public.site_pro_services s where s.id = p_service and s.profile = p_provider and s.active) then raise exception 'That service is not available.'; end if;
  if p_event_date is null or p_event_date <= current_date or p_event_date > current_date + 730 then raise exception 'Choose a date between tomorrow and two years from now.'; end if;
  if char_length(v_msg) < 3 or char_length(v_msg) > 1000 then raise exception 'Tell them about the job in 3 to 1000 characters.'; end if;
  if v_time is not null and char_length(v_time) > 60 then raise exception 'Keep the time to 60 characters.'; end if;
  if v_loc is not null and char_length(v_loc) > 160 then raise exception 'Keep the place to 160 characters.'; end if;
  if p_guests is not null and (p_guests < 1 or p_guests > 100000) then raise exception 'Choose a number of guests between 1 and 100,000.'; end if;
  if p_budget_cents is not null and (p_budget_cents < 0 or p_budget_cents > 50000000) then raise exception 'Choose a budget between 0 and 500,000.00.'; end if;
  if not (public.social_text_ok(v_msg) and public.social_text_ok(v_time) and public.social_text_ok(v_loc)) then raise exception 'That wording is not allowed here.'; end if;
  if public.market_day_busy(p_provider, p_event_date) then raise exception 'This professional is not free on that day.'; end if;
  if (select count(*) from public.site_pro_requests r where r.client = auth.uid() and r.created_at > now() - interval '1 day') >= 5 then raise exception 'You have sent a lot of requests today. Try again tomorrow.'; end if;
  if exists (select 1 from public.site_pro_requests r where r.client = auth.uid() and r.provider = p_provider and r.event_date = p_event_date and r.status in ('requested', 'quoted')) then
    raise exception 'You already have a request open with this professional for that day.';
  end if;
  insert into public.site_pro_requests (client, provider, service, event_date, time_note, location, guests, message, budget_cents)
  values (auth.uid(), p_provider, p_service, p_event_date, v_time, v_loc, p_guests, v_msg, p_budget_cents) returning id into v_id;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'service.requested', 'site_pro_requests', v_id::text, jsonb_build_object('provider', p_provider, 'event_date', p_event_date));
  return public.pro_request_json(v_id, 'client');
end;
$$;

-- A request with the other side's name, the live quote and the booking if there is one.
create function public.pro_request_json(p_request uuid, p_side text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.site_pro_requests;
  v_quote uuid;
  v_booking uuid;
begin
  select * into r from public.site_pro_requests where id = p_request;
  if not found then return null; end if;
  select q.id into v_quote from public.site_pro_quotes q where q.request = r.id and q.status in ('sent', 'accepted') order by (q.status = 'accepted') desc, q.created_at desc limit 1;
  select b.id into v_booking from public.site_pro_bookings b where b.request = r.id;
  return jsonb_build_object(
    'id', r.id, 'status', r.status, 'event_date', r.event_date, 'time_note', r.time_note, 'location', r.location, 'guests', r.guests, 'message', r.message,
    'budget_cents', r.budget_cents, 'decline_note', r.decline_note, 'created_at', r.created_at,
    'service', (select jsonb_build_object('id', s.id, 'title', s.title) from public.site_pro_services s where s.id = r.service),
    'provider', case when r.provider is null then null else public.profile_mini(r.provider) end,
    'client', case when p_side = 'provider' then public.market_person(r.client) else null end,
    'quote', case when v_quote is null then null else public.market_quote_json(v_quote) end,
    'booking', case when v_booking is null then null else public.market_booking_json(v_booking, p_side) end);
end;
$$;

-- Which side is the caller on? 'client', 'provider' or null.
create function public.market_side(p_request uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when r.client = auth.uid() then 'client' when r.provider is not null and public.profile_can_act_as(r.provider) then 'provider' else null end
    from public.site_pro_requests r where r.id = p_request
$$;

create function public.pro_request_get(p_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_side text;
begin
  perform public.market_require_on();
  v_side := public.market_side(p_request);
  if v_side is null then raise exception 'This request is not available.'; end if;
  return public.pro_request_json(p_request, v_side);
end;
$$;

create function public.pro_requests_mine()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.market_require_on();
  return coalesce((select jsonb_agg(public.pro_request_json(x.id, 'client') order by x.created_at desc, x.id) from (
    select r.id, r.created_at from public.site_pro_requests r where r.client = auth.uid() order by r.created_at desc, r.id limit 100) x), '[]'::jsonb);
end;
$$;

create function public.pro_requests_for(p_actor uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.market_require_provider(p_actor);
  return coalesce((select jsonb_agg(public.pro_request_json(x.id, 'provider') order by x.created_at desc, x.id) from (
    select r.id, r.created_at from public.site_pro_requests r where r.provider = p_actor order by r.created_at desc, r.id limit 100) x), '[]'::jsonb);
end;
$$;

create function public.pro_quote_send(p_actor uuid, p_request uuid, p_total_cents int, p_deposit_cents int, p_balance_due_by date, p_scope text, p_valid_days int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_pro_requests;
  v_scope text := btrim(coalesce(p_scope, ''));
  v_id uuid;
begin
  perform public.market_require_provider(p_actor);
  select * into r from public.site_pro_requests where id = p_request for update;
  if not found or r.provider is distinct from p_actor then raise exception 'This request is not available.'; end if;
  if r.status not in ('requested', 'quoted') then raise exception 'This request is closed.'; end if;
  if r.event_date <= current_date then raise exception 'The date of this request has passed.'; end if;
  if public.market_day_busy(p_actor, r.event_date) then raise exception 'You are not free on that day: change your days off first.'; end if;
  if p_total_cents is null or p_total_cents < 1000 or p_total_cents > 5000000 then raise exception 'Choose a total between 10.00 and 50,000.00.'; end if;
  if p_deposit_cents is null or p_deposit_cents > p_total_cents or p_deposit_cents < (p_total_cents + 9) / 10 then raise exception 'The deposit must be at least a tenth of the total, and no more than the total.'; end if;
  if p_deposit_cents < p_total_cents then
    if p_balance_due_by is null or p_balance_due_by < current_date or p_balance_due_by >= r.event_date then raise exception 'The balance must be due before the date of the job.'; end if;
  elsif p_balance_due_by is not null then
    raise exception 'There is no balance when the deposit is the whole amount.';
  end if;
  if char_length(v_scope) < 10 or char_length(v_scope) > 1500 then raise exception 'Say what is included in 10 to 1500 characters.'; end if;
  if not public.social_text_ok(v_scope) then raise exception 'That wording is not allowed here.'; end if;
  if p_valid_days is null or p_valid_days < 1 or p_valid_days > 14 then raise exception 'A quote can stay open for 1 to 14 days.'; end if;
  update public.site_pro_quotes set status = 'withdrawn' where request = p_request and status = 'sent';
  insert into public.site_pro_quotes (request, total_cents, deposit_cents, balance_due_by, scope, valid_until)
  values (p_request, p_total_cents, p_deposit_cents, p_balance_due_by, v_scope, now() + make_interval(days => p_valid_days)) returning id into v_id;
  update public.site_pro_requests set status = 'quoted', updated_at = clock_timestamp() where id = p_request;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'service.quoted', 'site_pro_quotes', v_id::text, jsonb_build_object('request', p_request, 'total_cents', p_total_cents, 'deposit_cents', p_deposit_cents));
  return public.pro_request_json(p_request, 'provider');
end;
$$;

create function public.pro_quote_withdraw(p_actor uuid, p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_pro_requests;
begin
  perform public.market_require_provider(p_actor);
  select * into r from public.site_pro_requests where id = p_request for update;
  if not found or r.provider is distinct from p_actor then raise exception 'This request is not available.'; end if;
  update public.site_pro_quotes set status = 'withdrawn' where request = p_request and status = 'sent';
  if not found then raise exception 'There is no open quote to withdraw.'; end if;
  update public.site_pro_requests set status = 'requested', updated_at = clock_timestamp() where id = p_request and status = 'quoted';
  return public.pro_request_json(p_request, 'provider');
end;
$$;

create function public.pro_request_decline(p_actor uuid, p_request uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_pro_requests;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.market_require_provider(p_actor);
  if v_note is not null and char_length(v_note) > 300 then raise exception 'Keep the note to 300 characters.'; end if;
  if not public.social_text_ok(v_note) then raise exception 'That wording is not allowed here.'; end if;
  select * into r from public.site_pro_requests where id = p_request for update;
  if not found or r.provider is distinct from p_actor then raise exception 'This request is not available.'; end if;
  if r.status not in ('requested', 'quoted') then raise exception 'This request is closed.'; end if;
  update public.site_pro_quotes set status = 'withdrawn' where request = p_request and status = 'sent';
  update public.site_pro_requests set status = 'declined', decline_note = v_note, updated_at = clock_timestamp() where id = p_request;
  return public.pro_request_json(p_request, 'provider');
end;
$$;

-- The customer takes their request back.
create function public.pro_request_withdraw(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_pro_requests;
begin
  perform public.market_require_on();
  select * into r from public.site_pro_requests where id = p_request for update;
  if not found or r.client is distinct from auth.uid() then raise exception 'This request is not available.'; end if;
  if r.status not in ('requested', 'quoted') then raise exception 'This request is closed.'; end if;
  update public.site_pro_quotes set status = 'withdrawn' where request = p_request and status = 'sent';
  update public.site_pro_requests set status = 'withdrawn', updated_at = clock_timestamp() where id = p_request;
  return public.pro_request_json(p_request, 'client');
end;
$$;

create function public.pro_quote_decline(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_pro_requests;
begin
  perform public.market_require_on();
  select * into r from public.site_pro_requests where id = p_request for update;
  if not found or r.client is distinct from auth.uid() then raise exception 'This request is not available.'; end if;
  update public.site_pro_quotes set status = 'declined' where request = p_request and status = 'sent' and valid_until > now();
  if not found then raise exception 'There is no open quote to turn down.'; end if;
  update public.site_pro_requests set status = 'requested', updated_at = clock_timestamp() where id = p_request and status = 'quoted';
  return public.pro_request_json(p_request, 'client');
end;
$$;

-- The customer accepts the live quote: a booking that must be paid within 24 hours.
create function public.pro_quote_accept(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_pro_requests;
  q public.site_pro_quotes;
  s public.site_pro_settings;
  v_title text;
  v_id uuid;
begin
  perform public.market_require_on();
  select * into r from public.site_pro_requests where id = p_request for update;
  if not found or r.client is distinct from auth.uid() then raise exception 'This request is not available.'; end if;
  select * into q from public.site_pro_quotes where request = p_request and status = 'sent' for update;
  if not found then raise exception 'There is no quote to accept.'; end if;
  if q.valid_until <= now() then raise exception 'This quote has expired. Ask for a new one.'; end if;
  if r.event_date <= current_date then raise exception 'The date of this job has passed.'; end if;
  if q.balance_due_by is not null and q.balance_due_by < current_date then raise exception 'The balance date of this quote has passed. Ask for a new quote.'; end if;
  if r.provider is null or not public.market_is_provider(r.provider) then raise exception 'This professional is not available.'; end if;
  if public.market_day_busy(r.provider, r.event_date) then raise exception 'This professional is no longer free on that day.'; end if;
  select * into s from public.site_pro_settings where id = 1;
  v_title := coalesce((select sv.title from public.site_pro_services sv where sv.id = r.service), 'Booking with ' || coalesce((select pr.display_name from public.site_profiles pr where pr.id = r.provider), 'a professional'));
  insert into public.site_pro_bookings (quote, request, client, provider, title, event_date, total_cents, deposit_cents, balance_due_by, commission_bps, free_cancel_days, pay_by)
  values (q.id, r.id, r.client, r.provider, left(v_title, 120), r.event_date, q.total_cents, q.deposit_cents, q.balance_due_by, public.market_commission_bps(r.provider), s.free_cancel_days, now() + interval '24 hours')
  returning id into v_id;
  update public.site_pro_quotes set status = 'accepted' where id = q.id;
  update public.site_pro_requests set status = 'accepted', updated_at = clock_timestamp() where id = r.id;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'service.accepted', 'site_pro_bookings', v_id::text, jsonb_build_object('total_cents', q.total_cents, 'deposit_cents', q.deposit_cents));
  return public.market_booking_json(v_id, 'client');
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Bookings: reading
-- ---------------------------------------------------------------------------
create function public.pro_booking_get(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
  v_side text;
begin
  perform public.market_require_on();
  select * into b from public.site_pro_bookings where id = p_booking;
  if not found then raise exception 'This booking is not available.'; end if;
  v_side := case when b.client = auth.uid() then 'client' when b.provider is not null and public.profile_can_act_as(b.provider) then 'provider' end;
  if v_side is null then raise exception 'This booking is not available.'; end if;
  return public.market_booking_json(p_booking, v_side);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Paying (the website's functions call these)
-- ---------------------------------------------------------------------------
-- The customer may pay NOW: what, how much. Called with the customer's own login by create-service-checkout.
create function public.pro_payment_begin(p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
  v_owed int;
  v_kind text;
  v_amount int;
  v_open public.site_pro_payments;
  v_pid uuid;
begin
  perform public.market_require_on();
  select * into b from public.site_pro_bookings where id = p_booking for update;
  if not found or b.client is distinct from auth.uid() then raise exception 'This booking is not available.'; end if;
  if b.status = 'awaiting_deposit' then
    if b.pay_by <= now() then raise exception 'The time to pay for this booking has passed. Ask for a new quote.'; end if;
    v_kind := case when b.deposit_cents >= b.total_cents then 'full' else 'deposit' end;
    v_amount := case when v_kind = 'full' then b.total_cents else b.deposit_cents end;
  elsif b.status = 'active' then
    v_owed := b.total_cents - b.paid_cents;
    if v_owed <= 0 then raise exception 'You have paid everything for this booking.'; end if;
    v_kind := 'balance';
    v_amount := v_owed;
  else
    raise exception 'This booking cannot be paid now.';
  end if;
  select * into v_open from public.site_pro_payments p where p.booking = b.id and p.kind = v_kind and p.status in ('created', 'pending') order by p.created_at desc limit 1;
  if found then
    if v_open.status = 'pending' and v_open.pending_until > now() then
      return jsonb_build_object('payment_id', v_open.id, 'kind', v_kind, 'amount_cents', v_open.amount_cents, 'currency', b.currency, 'title', b.title, 'event_date', b.event_date,
                                'provider', (select pr.display_name from public.site_profiles pr where pr.id = b.provider), 'pending_session', v_open.stripe_session_id);
    end if;
    update public.site_pro_payments set status = 'void' where id = v_open.id;
  end if;
  insert into public.site_pro_payments (booking, kind, amount_cents) values (b.id, v_kind, v_amount) returning id into v_pid;
  return jsonb_build_object('payment_id', v_pid, 'kind', v_kind, 'amount_cents', v_amount, 'currency', b.currency, 'title', b.title, 'event_date', b.event_date,
                            'provider', (select pr.display_name from public.site_profiles pr where pr.id = b.provider), 'pending_session', null);
end;
$$;

create function public.pro_payment_attach(p_payment uuid, p_session text, p_until timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_session is null or btrim(p_session) = '' then raise exception 'a Stripe session is needed'; end if;
  update public.site_pro_payments set status = 'pending', stripe_session_id = p_session, pending_until = p_until where id = p_payment and status in ('created', 'pending');
  if not found then raise exception 'this payment cannot be started now'; end if;
end;
$$;

-- Stripe has taken the money for this session. Idempotent. Answers {result, applied_cents, refund_cents}:
--   applied  - counted towards the booking
--   refund   - could not be used (the booking was cancelled, or the amount is not the payment's): all of it is to be paid back
--   already / unknown
create function public.pro_payment_paid(p_session text, p_payment_intent text, p_amount int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.site_pro_payments;
  b public.site_pro_bookings;
  v_owed int;
  v_apply int;
begin
  select * into p from public.site_pro_payments where stripe_session_id = p_session for update;
  if not found then return jsonb_build_object('result', 'unknown'); end if;
  if p.status = 'paid' then return jsonb_build_object('result', 'already', 'applied_cents', p.paid_cents - p.refund_due_cents, 'refund_cents', p.refund_due_cents - p.refunded_cents); end if;
  if p_amount is null or p_amount <= 0 then raise exception 'an amount is needed'; end if;
  select * into b from public.site_pro_bookings where id = p.booking for update;
  v_owed := greatest(b.total_cents - b.paid_cents, 0);
  if p_amount <> p.amount_cents or b.status not in ('awaiting_deposit', 'active') or (b.status = 'awaiting_deposit' and b.pay_by <= now() - interval '1 hour') or v_owed <= 0 or p.status = 'void' then
    update public.site_pro_payments set status = 'paid', paid_at = clock_timestamp(), stripe_payment_intent_id = p_payment_intent, paid_cents = p_amount, refund_due_cents = p_amount where id = p.id;
    insert into public.audit_log (actor_email, action, entity_type, entity_id, details)
    values ('stripe', 'service.payment_unusable', 'site_pro_payments', p.id::text, jsonb_build_object('booking', b.id, 'amount_cents', p_amount, 'booking_status', b.status));
    return jsonb_build_object('result', 'refund', 'applied_cents', 0, 'refund_cents', p_amount);
  end if;
  v_apply := least(p_amount, v_owed);
  update public.site_pro_payments set status = 'paid', paid_at = clock_timestamp(), stripe_payment_intent_id = p_payment_intent, paid_cents = p_amount, refund_due_cents = p_amount - v_apply where id = p.id;
  update public.site_pro_bookings set paid_cents = paid_cents + v_apply, status = case when status = 'awaiting_deposit' then 'active' else status end where id = b.id;
  insert into public.audit_log (actor_email, action, entity_type, entity_id, details)
  values ('stripe', 'service.payment_taken', 'site_pro_payments', p.id::text, jsonb_build_object('booking', b.id, 'amount_cents', p_amount, 'applied_cents', v_apply));
  return jsonb_build_object('result', 'applied', 'applied_cents', v_apply, 'refund_cents', p_amount - v_apply);
end;
$$;

-- What has to be paid back now.
create function public.pro_refunds_due()
returns table (payment_id uuid, booking_id uuid, stripe_payment_intent_id text, cents int)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select p.id, p.booking, p.stripe_payment_intent_id, (p.refund_due_cents - p.refunded_cents)::int
      from public.site_pro_payments p
     where p.refund_due_cents > p.refunded_cents and p.stripe_payment_intent_id is not null
     order by p.paid_at, p.id;
end;
$$;

create function public.pro_payment_refunded(p_payment uuid, p_refund_id text, p_cents int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.site_pro_payments;
  v_take int;
begin
  if p_refund_id is null or btrim(p_refund_id) = '' or p_cents is null or p_cents <= 0 then raise exception 'a refund id and an amount are needed'; end if;
  select * into p from public.site_pro_payments where id = p_payment for update;
  if not found then raise exception 'this payment does not exist'; end if;
  if p.refund_id is not distinct from p_refund_id and p.refunded_cents > 0 then return jsonb_build_object('result', 'already', 'refunded_cents', p.refunded_cents); end if;
  v_take := least(p_cents, p.refund_due_cents - p.refunded_cents);
  if v_take <= 0 then return jsonb_build_object('result', 'nothing_due', 'refunded_cents', p.refunded_cents); end if;
  update public.site_pro_payments set refunded_cents = refunded_cents + v_take, refund_id = p_refund_id where id = p_payment;
  insert into public.audit_log (actor_email, action, entity_type, entity_id, details)
  values ('stripe', 'service.payment_refunded', 'site_pro_payments', p_payment::text, jsonb_build_object('booking', p.booking, 'refund_id', p_refund_id, 'refunded_cents', v_take));
  return jsonb_build_object('result', 'refunded', 'refunded_cents', p.refunded_cents + v_take);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Money out: cancelling, the payout ledger
-- ---------------------------------------------------------------------------
-- Asks for p_cents of what a booking took to be paid back, newest payments first (a payment can only be paid back what it took).
create function public.market_refund_mark(p_booking uuid, p_cents int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
  v_left int := p_cents;
  v_room int;
begin
  for p in select * from public.site_pro_payments where booking = p_booking and status = 'paid' order by paid_at desc, id loop
    exit when v_left <= 0;
    v_room := p.paid_cents - p.refund_due_cents;
    if v_room <= 0 then continue; end if;
    update public.site_pro_payments set refund_due_cents = refund_due_cents + least(v_room, v_left) where id = p.id;
    v_left := v_left - least(v_room, v_left);
  end loop;
end;
$$;

-- A payout for p_gross cents kept from a booking (the job done, or a deposit kept), less the commission fixed when the quote was accepted.
create function public.market_payout_make(p_booking uuid, p_gross int, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
  v_commission int;
begin
  if p_gross <= 0 then return; end if;
  select * into b from public.site_pro_bookings where id = p_booking;
  v_commission := (p_gross::bigint * b.commission_bps / 10000)::int;
  insert into public.site_pro_payouts (booking, provider, gross_cents, commission_cents, net_cents, status)
  values (p_booking, b.provider, p_gross, v_commission, p_gross - v_commission, p_status)
  on conflict (booking) do nothing;
end;
$$;

-- Cancels a booking and works out who gets what. p_by is 'client', 'provider' or 'system'. p_policy: 'full' pays back everything paid; 'by_date' pays back everything when the job is at least
-- free_cancel_days away and otherwise keeps the deposit (at least 30% of the total) for the professional; 'keep' always keeps it (a balance that was never paid).
create function public.market_cancel(p_booking uuid, p_by text, p_reason text, p_policy text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
  v_keep int := 0;
  v_late boolean;
begin
  select * into b from public.site_pro_bookings where id = p_booking for update;
  if b.status in ('cancelled', 'completed') then return; end if;
  v_late := p_policy = 'keep' or (p_policy = 'by_date' and b.event_date - current_date < b.free_cancel_days);
  if v_late then v_keep := least(b.paid_cents, greatest(b.deposit_cents, (b.total_cents * 30 / 100))); end if;
  update public.site_pro_bookings set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = p_by, cancel_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300) where id = p_booking;
  update public.site_pro_payments set status = 'void' where booking = p_booking and status in ('created', 'pending');
  perform public.market_refund_mark(p_booking, b.paid_cents - v_keep);
  if v_keep > 0 then perform public.market_payout_make(p_booking, v_keep, 'releasable'); end if;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'system'), 'service.cancelled', 'site_pro_bookings', p_booking::text,
          jsonb_build_object('by', p_by, 'paid_cents', b.paid_cents, 'kept_cents', v_keep, 'refund_cents', b.paid_cents - v_keep));
end;
$$;

create function public.pro_booking_cancel(p_booking uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
  v_by text;
begin
  perform public.market_require_on();
  select * into b from public.site_pro_bookings where id = p_booking for update;
  if not found then raise exception 'This booking is not available.'; end if;
  v_by := case when b.client = auth.uid() then 'client' when b.provider is not null and public.profile_can_act_as(b.provider) then 'provider' end;
  if v_by is null then raise exception 'This booking is not available.'; end if;
  if b.status in ('cancelled', 'completed') then raise exception 'This booking is already closed.'; end if;
  if b.status = 'disputed' then raise exception 'This booking is in dispute: BottlesUp will decide it.'; end if;
  if b.event_date <= current_date and b.status = 'active' then raise exception 'The date has come: if something went wrong, open a dispute instead.'; end if;
  perform public.market_cancel(p_booking, v_by, p_reason, case when v_by = 'provider' then 'full' else 'by_date' end);
  return public.market_booking_json(p_booking, v_by);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. After the job
-- ---------------------------------------------------------------------------
create function public.pro_booking_done(p_actor uuid, p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
begin
  perform public.market_require_provider(p_actor);
  select * into b from public.site_pro_bookings where id = p_booking for update;
  if not found or b.provider is distinct from p_actor then raise exception 'This booking is not available.'; end if;
  if b.status <> 'active' then raise exception 'This booking cannot be marked done now.'; end if;
  if b.event_date > current_date then raise exception 'You can mark it done on the day of the job or after.'; end if;
  if b.paid_cents < b.total_cents then raise exception 'It has not been paid in full yet.'; end if;
  if b.provider_done_at is not null then raise exception 'You already marked this done.'; end if;
  update public.site_pro_bookings set provider_done_at = clock_timestamp() where id = p_booking;
  return public.market_booking_json(p_booking, 'provider');
end;
$$;

-- Completed: the payout becomes releasable.
create function public.market_complete(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
begin
  select * into b from public.site_pro_bookings where id = p_booking for update;
  if b.status <> 'active' then return; end if;
  update public.site_pro_bookings set status = 'completed', completed_at = clock_timestamp() where id = p_booking;
  perform public.market_payout_make(p_booking, b.paid_cents, 'releasable');
end;
$$;

create function public.pro_booking_confirm(p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
begin
  perform public.market_require_on();
  select * into b from public.site_pro_bookings where id = p_booking for update;
  if not found or b.client is distinct from auth.uid() then raise exception 'This booking is not available.'; end if;
  if b.status <> 'active' or b.provider_done_at is null then raise exception 'This booking is not waiting for your confirmation.'; end if;
  perform public.market_complete(p_booking);
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'service.confirmed', 'site_pro_bookings', p_booking::text, '{}'::jsonb);
  return public.market_booking_json(p_booking, 'client');
end;
$$;

create function public.pro_dispute_open(p_booking uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_pro_bookings;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  perform public.market_require_on();
  select * into b from public.site_pro_bookings where id = p_booking for update;
  if not found or b.client is distinct from auth.uid() then raise exception 'This booking is not available.'; end if;
  if b.status <> 'active' then raise exception 'This booking cannot be disputed now.'; end if;
  if b.event_date > current_date then raise exception 'You can open a dispute on the day of the job or after.'; end if;
  if b.event_date + 7 < current_date then raise exception 'The time to open a dispute has passed.'; end if;
  if char_length(v_reason) < 10 or char_length(v_reason) > 1000 then raise exception 'Say what went wrong in 10 to 1000 characters.'; end if;
  if not public.social_text_ok(v_reason) then raise exception 'That wording is not allowed here.'; end if;
  insert into public.site_pro_disputes (booking, opened_by, reason) values (p_booking, auth.uid(), v_reason);
  update public.site_pro_bookings set status = 'disputed' where id = p_booking;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'service.disputed', 'site_pro_bookings', p_booking::text, jsonb_build_object('reason', left(v_reason, 200)));
  return public.market_booking_json(p_booking, 'client');
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Daily housekeeping (a scheduled job, as the service role)
-- ---------------------------------------------------------------------------
-- Cancels what lapsed (an acceptance never paid, a balance not paid in time, a customer or professional whose account is gone), completes what was done and not disputed in
-- `confirm_days`, and marks old payment pages void. Safe to run any number of times.
create function public.market_housekeeping()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_pro_settings;
  b record;
  v_lapsed int := 0;
  v_balance int := 0;
  v_gone int := 0;
  v_done int := 0;
begin
  select * into s from public.site_pro_settings where id = 1;
  for b in select id from public.site_pro_bookings where status = 'awaiting_deposit' and pay_by <= now() - interval '1 hour' loop
    perform public.market_cancel(b.id, 'system', 'Not paid in time.', 'full');
    v_lapsed := v_lapsed + 1;
  end loop;
  for b in select id from public.site_pro_bookings where status = 'active' and paid_cents < total_cents and balance_due_by is not null and balance_due_by < current_date loop
    perform public.market_cancel(b.id, 'client', 'The balance was not paid by its due date.', 'keep');
    v_balance := v_balance + 1;
  end loop;
  for b in select id, provider from public.site_pro_bookings where status in ('awaiting_deposit', 'active') and (provider is null or client is null) loop
    perform public.market_cancel(b.id, case when b.provider is null then 'provider' else 'client' end, 'An account was closed.', case when b.provider is null then 'full' else 'by_date' end);
    v_gone := v_gone + 1;
  end loop;
  for b in select id from public.site_pro_bookings where status = 'active' and provider_done_at is not null and provider_done_at <= now() - make_interval(days => s.confirm_days) loop
    perform public.market_complete(b.id);
    v_done := v_done + 1;
  end loop;
  update public.site_pro_payments set status = 'void' where status in ('created', 'pending') and created_at < now() - interval '2 days';
  return jsonb_build_object('lapsed', v_lapsed, 'balance_unpaid', v_balance, 'accounts_gone', v_gone, 'completed', v_done);
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. BottlesUp's staff (the CMS)
-- ---------------------------------------------------------------------------
create function public.cms_pro_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  return (select jsonb_build_object('commission_bps', s.commission_bps, 'free_cancel_days', s.free_cancel_days, 'confirm_days', s.confirm_days, 'updated_at', s.updated_at) from public.site_pro_settings s where s.id = 1);
end;
$$;

create function public.cms_pro_settings_set(p_commission_bps int, p_free_cancel_days int, p_confirm_days int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;
  if p_commission_bps is null or p_commission_bps < 0 or p_commission_bps > 5000 then raise exception 'The commission must be between 0 and 50 percent.'; end if;
  if p_free_cancel_days is null or p_free_cancel_days < 0 or p_free_cancel_days > 60 then raise exception 'Free cancellation must be between 0 and 60 days before the job.'; end if;
  if p_confirm_days is null or p_confirm_days < 1 or p_confirm_days > 30 then raise exception 'Automatic confirmation must be 1 to 30 days after the job is marked done.'; end if;
  update public.site_pro_settings set commission_bps = p_commission_bps, free_cancel_days = p_free_cancel_days, confirm_days = p_confirm_days, updated_at = now(), updated_by = auth.uid() where id = 1;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'marketplace.settings', 'site_pro_settings', '1',
          jsonb_build_object('commission_bps', p_commission_bps, 'free_cancel_days', p_free_cancel_days, 'confirm_days', p_confirm_days));
  return public.cms_pro_settings();
end;
$$;

create function public.cms_pro_disputes(p_status text default 'open')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  if p_status is null or p_status not in ('open', 'resolved', 'all') then raise exception 'Choose open, resolved or all.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'status', d.status, 'reason', d.reason, 'outcome', d.outcome, 'refund_cents', d.refund_cents, 'note', d.note, 'created_at', d.created_at, 'decided_at', d.decided_at,
      'booking', jsonb_build_object('id', b.id, 'title', b.title, 'event_date', b.event_date, 'total_cents', b.total_cents, 'paid_cents', b.paid_cents, 'currency', b.currency,
                                    'provider', (select pr.display_name from public.site_profiles pr where pr.id = b.provider), 'client', public.market_person(b.client)))
      order by d.created_at, d.id)
    from public.site_pro_disputes d join public.site_pro_bookings b on b.id = d.booking where p_status = 'all' or d.status = p_status), '[]'::jsonb);
end;
$$;

-- Decides a dispute. release: the professional is paid as if confirmed. refund_full: everything paid goes back. refund_part: p_refund_cents goes back and the rest is released.
create function public.cms_pro_dispute_resolve(p_dispute uuid, p_outcome text, p_refund_cents int, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.site_pro_disputes;
  b public.site_pro_bookings;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_refund int := 0;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can decide this.'; end if;
  if p_outcome is null or p_outcome not in ('release', 'refund_part', 'refund_full') then raise exception 'Choose release, refund in part or refund in full.'; end if;
  if v_note is null then raise exception 'Write a note: the customer and the professional can be shown it.'; end if;
  if char_length(v_note) > 500 then raise exception 'Keep the note to 500 characters.'; end if;
  select * into d from public.site_pro_disputes where id = p_dispute for update;
  if not found then raise exception 'There is no such dispute.'; end if;
  if d.status = 'resolved' then raise exception 'This dispute is already decided.'; end if;
  select * into b from public.site_pro_bookings where id = d.booking for update;
  if p_outcome = 'refund_full' then v_refund := b.paid_cents;
  elsif p_outcome = 'refund_part' then
    if p_refund_cents is null or p_refund_cents <= 0 or p_refund_cents >= b.paid_cents then raise exception 'A part refund must be more than nothing and less than everything paid (%).', public.market_money(b.paid_cents); end if;
    v_refund := p_refund_cents;
  end if;
  if v_refund > 0 then perform public.market_refund_mark(b.id, v_refund); end if;
  if p_outcome = 'refund_full' then
    update public.site_pro_bookings set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = 'system', cancel_reason = 'Decided in favour of the customer.' where id = b.id;
  else
    update public.site_pro_bookings set status = 'completed', completed_at = clock_timestamp() where id = b.id;
    perform public.market_payout_make(b.id, b.paid_cents - v_refund, 'releasable');
  end if;
  update public.site_pro_disputes set status = 'resolved', outcome = p_outcome, refund_cents = v_refund, note = v_note, decided_by = auth.uid(), decided_at = clock_timestamp() where id = p_dispute;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'service.dispute_decided', 'site_pro_disputes', p_dispute::text, jsonb_build_object('outcome', p_outcome, 'refund_cents', v_refund, 'note', v_note));
  return jsonb_build_object('id', p_dispute, 'outcome', p_outcome, 'refund_cents', v_refund);
end;
$$;

create function public.cms_pro_payouts(p_status text default 'releasable')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  if p_status is null or p_status not in ('releasable', 'paid', 'all') then raise exception 'Choose releasable, paid or all.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id, 'status', x.status, 'gross_cents', x.gross_cents, 'commission_cents', x.commission_cents, 'net_cents', x.net_cents, 'reference', x.reference, 'paid_at', x.paid_at, 'created_at', x.created_at,
      'currency', b.currency, 'title', b.title, 'event_date', b.event_date, 'provider', (select pr.display_name from public.site_profiles pr where pr.id = x.provider))
      order by x.created_at, x.id)
    from public.site_pro_payouts x join public.site_pro_bookings b on b.id = x.booking where p_status = 'all' or x.status = p_status), '[]'::jsonb);
end;
$$;

create function public.cms_pro_payout_paid(p_payout uuid, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.site_pro_payouts;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;
  if v_ref is null or char_length(v_ref) > 120 then raise exception 'Write the transfer reference (up to 120 characters).'; end if;
  select * into x from public.site_pro_payouts where id = p_payout for update;
  if not found then raise exception 'There is no such payout.'; end if;
  if x.status <> 'releasable' then raise exception 'This payout is not waiting to be paid.'; end if;
  update public.site_pro_payouts set status = 'paid', reference = v_ref, paid_at = clock_timestamp(), paid_by = auth.uid() where id = p_payout;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'service.payout_paid', 'site_pro_payouts', p_payout::text, jsonb_build_object('net_cents', x.net_cents, 'reference', v_ref));
  return jsonb_build_object('id', p_payout, 'status', 'paid');
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.market_require_on(), public.market_is_provider(uuid), public.market_require_provider(uuid), public.market_commission_bps(uuid), public.market_day_busy(uuid, date, uuid),
  public.market_booking_state(uuid), public.market_money(int), public.market_person(uuid), public.market_quote_json(uuid), public.market_booking_json(uuid, text),
  public.pro_service_save(uuid, uuid, text, text, int, text, boolean), public.pro_service_remove(uuid, uuid), public.pro_services_of(uuid), public.pro_busy_set(uuid, date, boolean),
  public.pro_busy_days(uuid, date, int), public.pro_request_create(uuid, uuid, date, text, text, int, text, int), public.pro_request_json(uuid, text), public.market_side(uuid),
  public.pro_request_get(uuid), public.pro_requests_mine(), public.pro_requests_for(uuid), public.pro_quote_send(uuid, uuid, int, int, date, text, int),
  public.pro_quote_withdraw(uuid, uuid), public.pro_request_decline(uuid, uuid, text), public.pro_request_withdraw(uuid), public.pro_quote_decline(uuid), public.pro_quote_accept(uuid),
  public.pro_booking_get(uuid), public.pro_payment_begin(uuid), public.pro_payment_attach(uuid, text, timestamptz), public.pro_payment_paid(text, text, int),
  public.pro_refunds_due(), public.pro_payment_refunded(uuid, text, int), public.market_refund_mark(uuid, int), public.market_payout_make(uuid, int, text),
  public.market_cancel(uuid, text, text, text), public.pro_booking_cancel(uuid, text), public.pro_booking_done(uuid, uuid), public.market_complete(uuid),
  public.pro_booking_confirm(uuid), public.pro_dispute_open(uuid, text), public.market_housekeeping(), public.cms_pro_settings(), public.cms_pro_settings_set(int, int, int),
  public.cms_pro_disputes(text), public.cms_pro_dispute_resolve(uuid, text, int, text), public.cms_pro_payouts(text), public.cms_pro_payout_paid(uuid, text)
from public, anon, authenticated;
grant execute on function
  public.pro_service_save(uuid, uuid, text, text, int, text, boolean), public.pro_service_remove(uuid, uuid), public.pro_services_of(uuid), public.pro_busy_set(uuid, date, boolean),
  public.pro_busy_days(uuid, date, int), public.pro_request_create(uuid, uuid, date, text, text, int, text, int), public.pro_request_get(uuid), public.pro_requests_mine(),
  public.pro_requests_for(uuid), public.pro_quote_send(uuid, uuid, int, int, date, text, int), public.pro_quote_withdraw(uuid, uuid), public.pro_request_decline(uuid, uuid, text),
  public.pro_request_withdraw(uuid), public.pro_quote_decline(uuid), public.pro_quote_accept(uuid), public.pro_booking_get(uuid), public.pro_payment_begin(uuid),
  public.pro_booking_cancel(uuid, text), public.pro_booking_done(uuid, uuid), public.pro_booking_confirm(uuid), public.pro_dispute_open(uuid, text),
  public.cms_pro_settings(), public.cms_pro_settings_set(int, int, int), public.cms_pro_disputes(text), public.cms_pro_dispute_resolve(uuid, text, int, text),
  public.cms_pro_payouts(text), public.cms_pro_payout_paid(uuid, text)
to authenticated;
grant execute on function
  public.pro_payment_attach(uuid, text, timestamptz), public.pro_payment_paid(text, text, int), public.pro_refunds_due(), public.pro_payment_refunded(uuid, text, int),
  public.market_housekeeping()
to service_role;
