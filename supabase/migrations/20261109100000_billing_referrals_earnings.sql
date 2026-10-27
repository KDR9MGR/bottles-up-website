-- Subscriptions, referrals, tips and the earnings overview (customer app completion plan, M9; client plan pages 12 and 13).
--
--   * SUBSCRIPTIONS: the owner of a professional's own business profile subscribes it (CAD 29.99 a month or 299 a year to start; the prices, and the commission a subscribed profile pays,
--     are set in the CMS). Payment is Stripe Billing on Stripe's page; the website's functions write what Stripe says (sub_apply, idempotent: it sets a state, it does not add). While a
--     subscription is active the profile's commission on hiring is the subscribed one (0% to start): this is written into site_commission_overrides (20261107100000), which fixes a
--     booking's commission when a quote is accepted. A subscription that ends takes the override away; bookings already made keep the commission fixed when they were accepted.
--   * REFERRALS: a profile has a code; a new person claims it once (never their own); when the referred person's first ticket order or table booking is paid, within the days the CMS
--     sets, the referrer is credited a flat amount (CAD 5 to start; a monthly cap per referrer). The credit is written by a trigger on the orders and table bookings that can never stop a
--     purchase (any error in it is swallowed). Credits are payable money: BottlesUp pays them by hand and records it (cms_referral_credit_paid).
--   * TIPS: any person can send a tip to a public profile on Stripe's page; BottlesUp holds it, keeps a commission (5% to start), and the creator's share is withdrawable at once and paid
--     by hand (cms_creator_payout_paid). A tip is never refunded by the app.
--   * THE EARNINGS OVERVIEW keeps different things apart (the client's rule): money collected, money held for future bookings, what was earned, what can be withdrawn and what was paid out,
--     for hiring, tips and referral credits separately. Views and sales are not earnings; a deposit for a future job is held, not earned.
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.site_billing_settings (
  id int primary key default 1 check (id = 1),
  sub_monthly_cents int not null default 2999 check (sub_monthly_cents between 100 and 1000000),
  sub_yearly_cents int not null default 29900 check (sub_yearly_cents between 100 and 10000000),
  currency text not null default 'cad' check (currency ~ '^[a-z]{3}$'),
  stripe_price_monthly text check (stripe_price_monthly is null or stripe_price_monthly ~ '^price_[A-Za-z0-9]+$'),
  stripe_price_yearly text check (stripe_price_yearly is null or stripe_price_yearly ~ '^price_[A-Za-z0-9]+$'),
  subscribed_commission_bps int not null default 0 check (subscribed_commission_bps between 0 and 5000),
  referral_credit_cents int not null default 500 check (referral_credit_cents between 0 and 100000),
  referral_days int not null default 90 check (referral_days between 1 and 730),
  referral_monthly_cap int not null default 50 check (referral_monthly_cap between 1 and 10000),
  tip_commission_bps int not null default 500 check (tip_commission_bps between 0 and 5000),
  tip_min_cents int not null default 200 check (tip_min_cents between 100 and 100000),
  tip_max_cents int not null default 50000 check (tip_max_cents between 100 and 1000000),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null,
  check (tip_min_cents <= tip_max_cents)
);
insert into public.site_billing_settings (id) values (1);

create table public.site_subscriptions (
  id uuid primary key default gen_random_uuid(),
  profile uuid not null references public.site_profiles (id) on delete cascade,
  payer uuid references auth.users (id) on delete set null,
  plan text not null check (plan in ('monthly', 'yearly')),
  status text not null default 'incomplete' check (status in ('incomplete', 'active', 'past_due', 'cancelled')),
  stripe_customer text,
  stripe_subscription text unique,
  stripe_session text unique,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
-- One live subscription per profile.
create unique index site_subscriptions_one_live on public.site_subscriptions (profile) where status in ('active', 'past_due');
create index site_subscriptions_payer_idx on public.site_subscriptions (payer);

create table public.site_referral_codes (
  profile uuid primary key references public.site_profiles (id) on delete cascade,
  code text not null unique check (code ~ '^[A-Z0-9]{8}$'),
  created_at timestamptz not null default clock_timestamp()
);

create table public.site_referrals (
  referred uuid primary key references auth.users (id) on delete cascade,
  referrer uuid references public.site_profiles (id) on delete set null,
  code text not null,
  claimed_at timestamptz not null default clock_timestamp()
);
create index site_referrals_referrer_idx on public.site_referrals (referrer, claimed_at);

create table public.site_referral_credits (
  id uuid primary key default gen_random_uuid(),
  referrer uuid references public.site_profiles (id) on delete set null,
  referred uuid references auth.users (id) on delete set null,
  source text not null check (source in ('ticket_order', 'table_booking')),
  source_id uuid not null,
  amount_cents int not null check (amount_cents > 0),
  status text not null default 'payable' check (status in ('payable', 'paid')),
  reference text check (reference is null or char_length(reference) <= 120),
  paid_at timestamptz,
  paid_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  unique (source, source_id)
);
create index site_referral_credits_referrer_idx on public.site_referral_credits (referrer, created_at);

create table public.site_tips (
  id uuid primary key default gen_random_uuid(),
  creator uuid references public.site_profiles (id) on delete set null,
  tipper uuid references auth.users (id) on delete set null,
  amount_cents int not null check (amount_cents between 100 and 1000000),
  commission_bps int not null check (commission_bps between 0 and 5000),
  message text check (message is null or char_length(message) <= 200),
  status text not null default 'created' check (status in ('created', 'paid', 'void')),
  stripe_session text unique,
  stripe_payment_intent text,
  paid_at timestamptz,
  paid_out_at timestamptz,
  payout_reference text check (payout_reference is null or char_length(payout_reference) <= 120),
  created_at timestamptz not null default clock_timestamp()
);
create index site_tips_creator_idx on public.site_tips (creator, status);
create index site_tips_tipper_idx on public.site_tips (tipper, created_at);

alter table public.site_billing_settings enable row level security;
alter table public.site_subscriptions enable row level security;
alter table public.site_referral_codes enable row level security;
alter table public.site_referrals enable row level security;
alter table public.site_referral_credits enable row level security;
alter table public.site_tips enable row level security;
revoke all on table public.site_billing_settings, public.site_subscriptions, public.site_referral_codes, public.site_referrals, public.site_referral_credits, public.site_tips from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
create function public.billing_require(p_feature text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not public.feature_enabled(p_feature) then
    raise exception '%', case p_feature
      when 'subscriptions' then 'Subscriptions are not open yet.'
      when 'referrals' then 'Referrals are not open yet.'
      else 'Tips are not open yet.' end;
  end if;
end;
$$;

-- Does the caller own this profile and is it a professional's own (user-run) business profile in good standing?
create function public.billing_owned_profile(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.site_profiles s where s.id = p_profile and s.kind = 'business' and s.user_id = auth.uid() and s.org_id is null and s.status = 'active')
$$;

-- ---------------------------------------------------------------------------
-- 3. Subscriptions
-- ---------------------------------------------------------------------------
create function public.sub_json(p_sub uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('id', x.id, 'profile', x.profile, 'plan', x.plan, 'status', x.status, 'current_period_end', x.current_period_end, 'cancel_at_period_end', x.cancel_at_period_end)
    from public.site_subscriptions x where x.id = p_sub
$$;

-- The prices, and what a subscription changes.
create function public.sub_plans()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.billing_require('subscriptions');
  return (select jsonb_build_object('currency', s.currency, 'monthly_cents', s.sub_monthly_cents, 'yearly_cents', s.sub_yearly_cents, 'subscribed_commission_bps', s.subscribed_commission_bps,
                                    'standard_commission_bps', (select p.commission_bps from public.site_pro_settings p where p.id = 1))
            from public.site_billing_settings s where s.id = 1);
end;
$$;

-- The subscription of a profile the caller owns: the live one, or the latest.
create function public.sub_status(p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.billing_require('subscriptions');
  if not public.billing_owned_profile(p_profile) then raise exception 'Only the owner of a professional''s own profile can manage its subscription.'; end if;
  return (select public.sub_json(x.id) from public.site_subscriptions x where x.profile = p_profile and x.status <> 'incomplete'
           order by (x.status in ('active', 'past_due')) desc, x.updated_at desc limit 1);
end;
$$;

-- Starts a subscription: what the website needs to open Stripe's page. Nothing is live until Stripe says so.
create function public.sub_begin(p_profile uuid, p_plan text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_billing_settings;
  v_id uuid;
begin
  perform public.billing_require('subscriptions');
  if p_plan is null or p_plan not in ('monthly', 'yearly') then raise exception 'Choose monthly or yearly.'; end if;
  if not public.billing_owned_profile(p_profile) then raise exception 'Only the owner of a professional''s own profile can subscribe it.'; end if;
  if exists (select 1 from public.site_subscriptions x where x.profile = p_profile and x.status in ('active', 'past_due')) then raise exception 'This profile already has a subscription.'; end if;
  select * into s from public.site_billing_settings where id = 1;
  select x.id into v_id from public.site_subscriptions x where x.profile = p_profile and x.status = 'incomplete' and x.plan = p_plan and x.stripe_session is null and x.created_at > now() - interval '1 day' order by x.created_at desc limit 1;
  if v_id is null then
    insert into public.site_subscriptions (profile, payer, plan) values (p_profile, auth.uid(), p_plan) returning id into v_id;
  else
    update public.site_subscriptions set payer = auth.uid(), updated_at = clock_timestamp() where id = v_id;
  end if;
  return jsonb_build_object(
    'subscription_id', v_id, 'plan', p_plan, 'currency', s.currency,
    'amount_cents', case p_plan when 'monthly' then s.sub_monthly_cents else s.sub_yearly_cents end,
    'price', case p_plan when 'monthly' then s.stripe_price_monthly else s.stripe_price_yearly end,
    'customer', (select x.stripe_customer from public.site_subscriptions x where x.payer = auth.uid() and x.stripe_customer is not null order by x.updated_at desc limit 1),
    'profile_name', (select pr.display_name from public.site_profiles pr where pr.id = p_profile));
end;
$$;

-- The website remembers which Stripe page belongs to the subscription it is starting.
create function public.sub_attach(p_sub uuid, p_session text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_session is null or p_session !~ '^cs_[A-Za-z0-9_]+$' then raise exception 'a Stripe session is needed'; end if;
  update public.site_subscriptions set stripe_session = p_session, updated_at = clock_timestamp() where id = p_sub and status = 'incomplete' and stripe_session is null;
end;
$$;

-- The customer id the billing portal needs, for the owner only.
create function public.sub_customer(p_profile uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v text;
begin
  perform public.billing_require('subscriptions');
  if not public.billing_owned_profile(p_profile) then raise exception 'Only the owner of a professional''s own profile can manage its subscription.'; end if;
  select x.stripe_customer into v from public.site_subscriptions x where x.profile = p_profile and x.stripe_customer is not null order by x.updated_at desc limit 1;
  if v is null then raise exception 'This profile has no subscription to manage.'; end if;
  return v;
end;
$$;

-- What Stripe says about a subscription, written as it is (so hearing it twice changes nothing). Stripe's statuses become ours; a live one gives the profile the subscribed commission
-- until the end of the period it has paid for; an ended one takes it away.
create function public.sub_apply(p_stripe_subscription text, p_customer text, p_status text, p_period_end timestamptz, p_cancel_at_end boolean, p_sub uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.site_subscriptions;
  v_status text;
  s public.site_billing_settings;
begin
  if p_stripe_subscription is null or p_stripe_subscription !~ '^sub_[A-Za-z0-9]+$' then raise exception 'a Stripe subscription is needed'; end if;
  v_status := case when p_status in ('active', 'trialing') then 'active' when p_status in ('past_due', 'unpaid') then 'past_due' when p_status in ('canceled', 'incomplete_expired') then 'cancelled' else null end;
  if v_status is null then return jsonb_build_object('result', 'ignored'); end if;
  select * into x from public.site_subscriptions where stripe_subscription = p_stripe_subscription for update;
  if not found and p_sub is not null then
    select * into x from public.site_subscriptions where id = p_sub and stripe_subscription is null for update;
  end if;
  if not found then return jsonb_build_object('result', 'unknown'); end if;
  -- An older message arriving late does not undo a newer one.
  if x.current_period_end is not null and p_period_end is not null and p_period_end < x.current_period_end then return jsonb_build_object('result', 'stale', 'profile', x.profile, 'status', x.status); end if;
  update public.site_subscriptions set stripe_subscription = p_stripe_subscription, stripe_customer = coalesce(p_customer, stripe_customer), status = v_status,
         current_period_end = coalesce(p_period_end, current_period_end), cancel_at_period_end = coalesce(p_cancel_at_end, false), updated_at = clock_timestamp()
   where id = x.id;
  select * into s from public.site_billing_settings where id = 1;
  if v_status = 'active' and coalesce(p_period_end, x.current_period_end) is not null then
    insert into public.site_commission_overrides (profile, commission_bps, until, source) values (x.profile, s.subscribed_commission_bps, coalesce(p_period_end, x.current_period_end), 'subscription')
    on conflict (profile) do update set commission_bps = excluded.commission_bps, until = excluded.until, source = excluded.source, updated_at = clock_timestamp()
      where public.site_commission_overrides.source = 'subscription';
  elsif v_status = 'cancelled' then
    delete from public.site_commission_overrides where profile = x.profile and source = 'subscription';
  end if;
  insert into public.audit_log (actor_email, action, entity_type, entity_id, details)
  values ('stripe', 'subscription.' || v_status, 'site_subscriptions', x.id::text, jsonb_build_object('profile', x.profile, 'plan', x.plan, 'period_end', p_period_end));
  return jsonb_build_object('result', 'applied', 'profile', x.profile, 'status', v_status);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Referrals
-- ---------------------------------------------------------------------------
-- The caller's code for a profile they may act as: made the first time it is asked for.
create function public.referral_code(p_profile uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_try int := 0;
begin
  perform public.billing_require('referrals');
  perform public.profile_require_actor(p_profile);
  select c.code into v_code from public.site_referral_codes c where c.profile = p_profile;
  while v_code is null and v_try < 10 loop
    v_try := v_try + 1;
    begin
      insert into public.site_referral_codes (profile, code) values (p_profile, upper(substr(md5(random()::text || clock_timestamp()::text || p_profile::text), 1, 8))) returning code into v_code;
    exception when unique_violation then
      select c.code into v_code from public.site_referral_codes c where c.profile = p_profile;
    end;
  end loop;
  if v_code is null then raise exception 'We could not make a code. Try again.'; end if;
  return jsonb_build_object('code', v_code);
end;
$$;

-- A person says who sent them. Once, never their own profile's code, never after the first purchase window has begun for something else.
create function public.referral_claim(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_profile uuid;
begin
  perform public.billing_require('referrals');
  if v_code !~ '^[A-Z0-9]{8}$' then raise exception 'That code is not right.'; end if;
  if exists (select 1 from public.site_referrals r where r.referred = auth.uid()) then raise exception 'You have already used a code.'; end if;
  select c.profile into v_profile from public.site_referral_codes c join public.site_profiles s on s.id = c.profile where c.code = v_code and s.status = 'active';
  if v_profile is null then raise exception 'That code is not right.'; end if;
  if public.profile_is_mine(v_profile) then raise exception 'You cannot use your own code.'; end if;
  if public.profile_blocked_between((select p.id from public.site_profiles p where p.user_id = auth.uid() and p.kind = 'personal'), v_profile) then raise exception 'That code is not right.'; end if;
  insert into public.site_referrals (referred, referrer, code) values (auth.uid(), v_profile, v_code);
  return jsonb_build_object('claimed', true, 'referrer', public.profile_mini(v_profile));
end;
$$;

-- Has the caller used a code, and who sent them?
create function public.referral_mine()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.billing_require('referrals');
  return (select jsonb_build_object('referrer', case when r.referrer is null then null else public.profile_mini(r.referrer) end, 'claimed_at', r.claimed_at) from public.site_referrals r where r.referred = auth.uid());
end;
$$;

-- How a profile's code is doing: people who used it, and the credits (waiting to be paid, and paid).
create function public.referral_stats(p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.billing_require('referrals');
  perform public.profile_require_permission(p_profile, 'finance');
  return jsonb_build_object(
    'referred', (select count(*) from public.site_referrals r where r.referrer = p_profile),
    'credited', (select count(*) from public.site_referral_credits c where c.referrer = p_profile),
    'payable_cents', coalesce((select sum(c.amount_cents) from public.site_referral_credits c where c.referrer = p_profile and c.status = 'payable'), 0),
    'paid_cents', coalesce((select sum(c.amount_cents) from public.site_referral_credits c where c.referrer = p_profile and c.status = 'paid'), 0),
    'credit_cents', (select s.referral_credit_cents from public.site_billing_settings s where s.id = 1));
end;
$$;

-- A paid purchase by a referred person: the referrer is credited, once, if it is the person's first paid purchase and falls within the days the CMS allows and under the monthly cap.
-- Called by the trigger below with the buyer's e-mail; it can never stop the purchase (the trigger swallows any error).
create function public.referral_credit_for(p_email text, p_source text, p_source_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  r public.site_referrals;
  s public.site_billing_settings;
begin
  if not public.feature_enabled('referrals') then return; end if;
  select u.id into v_user from auth.users u where lower(u.email) = lower(btrim(p_email)) limit 1;
  if v_user is null then return; end if;
  select * into r from public.site_referrals where referred = v_user;
  if not found or r.referrer is null then return; end if;
  select * into s from public.site_billing_settings where id = 1;
  if s.referral_credit_cents <= 0 or r.claimed_at < now() - make_interval(days => s.referral_days) then return; end if;
  if exists (select 1 from public.site_referral_credits c where c.referred = v_user) then return; end if;
  if (select count(*) from public.site_referral_credits c where c.referrer = r.referrer and c.created_at > now() - interval '30 days') >= s.referral_monthly_cap then return; end if;
  insert into public.site_referral_credits (referrer, referred, source, source_id, amount_cents) values (r.referrer, v_user, p_source, p_source_id, s.referral_credit_cents) on conflict (source, source_id) do nothing;
end;
$$;

create function public.referral_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.referral_credit_for(new.customer_email, case tg_table_name when 'site_orders' then 'ticket_order' else 'table_booking' end, new.id);
  exception when others then
    null;
  end;
  return new;
end;
$$;

create trigger site_orders_referral_credit after insert on public.site_orders for each row when (new.status = 'paid') execute function public.referral_trigger();
create trigger site_orders_referral_credit_paid after update of status on public.site_orders for each row when (new.status = 'paid' and old.status is distinct from 'paid') execute function public.referral_trigger();
create trigger site_table_bookings_referral_credit after insert on public.site_table_bookings for each row when (new.status = 'paid') execute function public.referral_trigger();
create trigger site_table_bookings_referral_credit_paid after update of status on public.site_table_bookings for each row when (new.status = 'paid' and old.status is distinct from 'paid') execute function public.referral_trigger();

-- ---------------------------------------------------------------------------
-- 5. Tips
-- ---------------------------------------------------------------------------
create function public.tip_begin(p_creator uuid, p_amount_cents int, p_message text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_billing_settings;
  v_msg text := nullif(btrim(coalesce(p_message, '')), '');
  v_me uuid;
  v_id uuid;
begin
  perform public.billing_require('creator_earnings');
  perform public.social_require_rules();
  select * into s from public.site_billing_settings where id = 1;
  if p_creator is null or not exists (select 1 from public.site_profiles c where c.id = p_creator and c.status = 'active' and c.privacy = 'public' and c.kind = 'business') then raise exception 'This profile cannot be tipped.'; end if;
  if public.profile_is_mine(p_creator) then raise exception 'You cannot tip your own profile.'; end if;
  select p.id into v_me from public.site_profiles p where p.user_id = auth.uid() and p.kind = 'personal';
  if v_me is not null and public.profile_blocked_between(v_me, p_creator) then raise exception 'This profile cannot be tipped.'; end if;
  if p_amount_cents is null or p_amount_cents < s.tip_min_cents or p_amount_cents > s.tip_max_cents then
    raise exception 'A tip is from % to %.', public.market_money(s.tip_min_cents), public.market_money(s.tip_max_cents);
  end if;
  if v_msg is not null and char_length(v_msg) > 200 then raise exception 'Keep the message to 200 characters.'; end if;
  if not public.social_text_ok(v_msg) then raise exception 'That wording is not allowed here.'; end if;
  if (select count(*) from public.site_tips t where t.tipper = auth.uid() and t.created_at > now() - interval '1 day') >= 10 then raise exception 'You have sent a lot of tips today. Try again tomorrow.'; end if;
  insert into public.site_tips (creator, tipper, amount_cents, commission_bps, message) values (p_creator, auth.uid(), p_amount_cents, s.tip_commission_bps, v_msg) returning id into v_id;
  return jsonb_build_object('tip_id', v_id, 'amount_cents', p_amount_cents, 'currency', s.currency, 'creator_name', (select c.display_name from public.site_profiles c where c.id = p_creator));
end;
$$;

create function public.tip_attach(p_tip uuid, p_session text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_session is null or p_session !~ '^cs_[A-Za-z0-9_]+$' then raise exception 'a Stripe session is needed'; end if;
  update public.site_tips set stripe_session = p_session where id = p_tip and status = 'created' and stripe_session is null;
end;
$$;

-- Stripe says a tip was paid. Applied once per session.
create function public.tip_paid(p_session text, p_payment_intent text, p_amount int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_tips;
begin
  select * into t from public.site_tips where stripe_session = p_session for update;
  if not found then return jsonb_build_object('result', 'unknown'); end if;
  if t.status = 'paid' then return jsonb_build_object('result', 'already'); end if;
  if p_amount is distinct from t.amount_cents then
    insert into public.audit_log (actor_email, action, entity_type, entity_id, details) values ('stripe', 'tip.amount_mismatch', 'site_tips', t.id::text, jsonb_build_object('expected', t.amount_cents, 'got', p_amount));
    return jsonb_build_object('result', 'mismatch');
  end if;
  update public.site_tips set status = 'paid', paid_at = clock_timestamp(), stripe_payment_intent = p_payment_intent where id = t.id;
  return jsonb_build_object('result', 'applied', 'creator', t.creator, 'net_cents', t.amount_cents - (t.amount_cents::bigint * t.commission_bps / 10000)::int);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. The earnings overview
-- ---------------------------------------------------------------------------
-- Collected, held, earned, withdrawable and paid out, kept apart for hiring, tips and referrals. For a profile the caller may act as with the 'finance' kind of work.
create function public.earnings_overview(p_profile uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.profile_require_permission(p_profile, 'finance');
  return jsonb_build_object(
    'hiring', jsonb_build_object(
      'collected_cents', coalesce((select sum(b.paid_cents) from public.site_pro_bookings b where b.provider = p_profile and b.status in ('active', 'disputed', 'completed')), 0),
      'held_cents', coalesce((select sum(b.paid_cents) from public.site_pro_bookings b where b.provider = p_profile and b.status in ('active', 'disputed')), 0),
      'earned_cents', coalesce((select sum(o.net_cents) from public.site_pro_payouts o where o.provider = p_profile and o.status in ('releasable', 'paid')), 0),
      'withdrawable_cents', coalesce((select sum(o.net_cents) from public.site_pro_payouts o where o.provider = p_profile and o.status = 'releasable'), 0),
      'paid_cents', coalesce((select sum(o.net_cents) from public.site_pro_payouts o where o.provider = p_profile and o.status = 'paid'), 0),
      'commission_cents', coalesce((select sum(o.commission_cents) from public.site_pro_payouts o where o.provider = p_profile and o.status in ('releasable', 'paid')), 0)),
    'tips', jsonb_build_object(
      'collected_cents', coalesce((select sum(t.amount_cents) from public.site_tips t where t.creator = p_profile and t.status = 'paid'), 0),
      'earned_cents', coalesce((select sum(t.amount_cents - (t.amount_cents::bigint * t.commission_bps / 10000)::int) from public.site_tips t where t.creator = p_profile and t.status = 'paid'), 0),
      'withdrawable_cents', coalesce((select sum(t.amount_cents - (t.amount_cents::bigint * t.commission_bps / 10000)::int) from public.site_tips t where t.creator = p_profile and t.status = 'paid' and t.paid_out_at is null), 0),
      'paid_cents', coalesce((select sum(t.amount_cents - (t.amount_cents::bigint * t.commission_bps / 10000)::int) from public.site_tips t where t.creator = p_profile and t.status = 'paid' and t.paid_out_at is not null), 0),
      'count', (select count(*) from public.site_tips t where t.creator = p_profile and t.status = 'paid')),
    'referrals', jsonb_build_object(
      'earned_cents', coalesce((select sum(c.amount_cents) from public.site_referral_credits c where c.referrer = p_profile), 0),
      'withdrawable_cents', coalesce((select sum(c.amount_cents) from public.site_referral_credits c where c.referrer = p_profile and c.status = 'payable'), 0),
      'paid_cents', coalesce((select sum(c.amount_cents) from public.site_referral_credits c where c.referrer = p_profile and c.status = 'paid'), 0)),
    'subscription', (select public.sub_json(x.id) from public.site_subscriptions x where x.profile = p_profile and x.status in ('active', 'past_due') limit 1));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. The CMS
-- ---------------------------------------------------------------------------
create function public.cms_billing_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  return (select to_jsonb(s) - 'id' - 'updated_by' from public.site_billing_settings s where s.id = 1);
end;
$$;

create function public.cms_billing_settings_set(
  p_monthly_cents int, p_yearly_cents int, p_price_monthly text, p_price_yearly text, p_subscribed_commission_bps int,
  p_referral_credit_cents int, p_referral_days int, p_referral_monthly_cap int, p_tip_commission_bps int, p_tip_min_cents int, p_tip_max_cents int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pm text := nullif(btrim(coalesce(p_price_monthly, '')), '');
  v_py text := nullif(btrim(coalesce(p_price_yearly, '')), '');
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;
  if p_monthly_cents is null or p_monthly_cents < 100 or p_monthly_cents > 1000000 then raise exception 'The monthly price must be between 1.00 and 10,000.00.'; end if;
  if p_yearly_cents is null or p_yearly_cents < 100 or p_yearly_cents > 10000000 then raise exception 'The yearly price must be between 1.00 and 100,000.00.'; end if;
  if v_pm is not null and v_pm !~ '^price_[A-Za-z0-9]+$' then raise exception 'The monthly Stripe price id looks like price_123.'; end if;
  if v_py is not null and v_py !~ '^price_[A-Za-z0-9]+$' then raise exception 'The yearly Stripe price id looks like price_123.'; end if;
  if p_subscribed_commission_bps is null or p_subscribed_commission_bps < 0 or p_subscribed_commission_bps > 5000 then raise exception 'The subscribed commission must be between 0 and 50 percent.'; end if;
  if p_referral_credit_cents is null or p_referral_credit_cents < 0 or p_referral_credit_cents > 100000 then raise exception 'A referral credit must be between 0 and 1,000.00.'; end if;
  if p_referral_days is null or p_referral_days < 1 or p_referral_days > 730 then raise exception 'A referral counts for 1 to 730 days.'; end if;
  if p_referral_monthly_cap is null or p_referral_monthly_cap < 1 or p_referral_monthly_cap > 10000 then raise exception 'The monthly cap must be 1 to 10,000 credits.'; end if;
  if p_tip_commission_bps is null or p_tip_commission_bps < 0 or p_tip_commission_bps > 5000 then raise exception 'The tip commission must be between 0 and 50 percent.'; end if;
  if p_tip_min_cents is null or p_tip_min_cents < 100 or p_tip_min_cents > 100000 then raise exception 'The smallest tip must be between 1.00 and 1,000.00.'; end if;
  if p_tip_max_cents is null or p_tip_max_cents < p_tip_min_cents or p_tip_max_cents > 1000000 then raise exception 'The biggest tip must be at least the smallest, and at most 10,000.00.'; end if;
  update public.site_billing_settings set sub_monthly_cents = p_monthly_cents, sub_yearly_cents = p_yearly_cents, stripe_price_monthly = v_pm, stripe_price_yearly = v_py,
         subscribed_commission_bps = p_subscribed_commission_bps, referral_credit_cents = p_referral_credit_cents, referral_days = p_referral_days, referral_monthly_cap = p_referral_monthly_cap,
         tip_commission_bps = p_tip_commission_bps, tip_min_cents = p_tip_min_cents, tip_max_cents = p_tip_max_cents, updated_at = now(), updated_by = auth.uid() where id = 1;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'billing.settings', 'site_billing_settings', '1',
          jsonb_build_object('monthly_cents', p_monthly_cents, 'yearly_cents', p_yearly_cents, 'subscribed_commission_bps', p_subscribed_commission_bps, 'referral_credit_cents', p_referral_credit_cents, 'tip_commission_bps', p_tip_commission_bps));
  return public.cms_billing_settings();
end;
$$;

create function public.cms_subscriptions(p_status text default 'active')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  if p_status is null or p_status not in ('active', 'past_due', 'cancelled', 'all') then raise exception 'Choose active, past due, cancelled or all.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'profile', (select pr.display_name from public.site_profiles pr where pr.id = x.profile), 'plan', x.plan, 'status', x.status,
                                        'current_period_end', x.current_period_end, 'cancel_at_period_end', x.cancel_at_period_end, 'payer', public.market_person(x.payer))
                     order by x.updated_at desc, x.id)
      from public.site_subscriptions x where x.status <> 'incomplete' and (p_status = 'all' or x.status = p_status)
  ), '[]'::jsonb);
end;
$$;

-- Referral credits waiting to be paid (or paid), for BottlesUp to pay by hand.
create function public.cms_referral_credits(p_status text default 'payable')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  if p_status is null or p_status not in ('payable', 'paid', 'all') then raise exception 'Choose payable, paid or all.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'amount_cents', c.amount_cents, 'status', c.status, 'source', c.source, 'reference', c.reference, 'created_at', c.created_at, 'paid_at', c.paid_at,
                                        'referrer', case when c.referrer is null then null else public.profile_mini(c.referrer) end,
                                        'referrer_person', (select public.market_person(pr.user_id) from public.site_profiles pr where pr.id = c.referrer)) order by c.created_at, c.id)
      from public.site_referral_credits c where p_status = 'all' or c.status = p_status
  ), '[]'::jsonb);
end;
$$;

create function public.cms_referral_credit_paid(p_credit uuid, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  c public.site_referral_credits;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;
  if v_ref is null or char_length(v_ref) > 120 then raise exception 'Write the transfer reference (up to 120 characters).'; end if;
  select * into c from public.site_referral_credits where id = p_credit for update;
  if not found then raise exception 'There is no such credit.'; end if;
  if c.status <> 'payable' then raise exception 'This credit is not waiting to be paid.'; end if;
  update public.site_referral_credits set status = 'paid', reference = v_ref, paid_at = clock_timestamp(), paid_by = auth.uid() where id = p_credit;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'referral.credit_paid', 'site_referral_credits', p_credit::text, jsonb_build_object('amount_cents', c.amount_cents, 'reference', v_ref));
  return jsonb_build_object('id', p_credit, 'status', 'paid');
end;
$$;

-- What each creator can be paid from tips, for BottlesUp to pay by hand; and the payment recorded.
create function public.cms_creator_payouts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('creator', t.creator, 'name', (select pr.display_name from public.site_profiles pr where pr.id = t.creator),
                                        'person', (select public.market_person(pr.user_id) from public.site_profiles pr where pr.id = t.creator),
                                        'tips', t.n, 'withdrawable_cents', t.net) order by t.net desc, t.creator)
      from (select x.creator, count(*) as n, sum(x.amount_cents - (x.amount_cents::bigint * x.commission_bps / 10000)::int)::int as net
              from public.site_tips x where x.status = 'paid' and x.paid_out_at is null and x.creator is not null group by x.creator) t
  ), '[]'::jsonb);
end;
$$;

create function public.cms_creator_payout_paid(p_creator uuid, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_n int;
  v_net int;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can do this.'; end if;
  if v_ref is null or char_length(v_ref) > 120 then raise exception 'Write the transfer reference (up to 120 characters).'; end if;
  select count(*), coalesce(sum(x.amount_cents - (x.amount_cents::bigint * x.commission_bps / 10000)::int), 0) into v_n, v_net from public.site_tips x where x.creator = p_creator and x.status = 'paid' and x.paid_out_at is null;
  if v_n = 0 then raise exception 'There is nothing to pay this creator.'; end if;
  update public.site_tips set paid_out_at = clock_timestamp(), payout_reference = v_ref where creator = p_creator and status = 'paid' and paid_out_at is null;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'creator.payout_paid', 'site_tips', p_creator::text, jsonb_build_object('tips', v_n, 'net_cents', v_net, 'reference', v_ref));
  return jsonb_build_object('creator', p_creator, 'tips', v_n, 'net_cents', v_net);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.billing_require(text), public.billing_owned_profile(uuid), public.sub_json(uuid), public.sub_plans(), public.sub_status(uuid), public.sub_begin(uuid, text), public.sub_attach(uuid, text),
  public.sub_customer(uuid), public.sub_apply(text, text, text, timestamptz, boolean, uuid), public.referral_code(uuid), public.referral_claim(text), public.referral_mine(), public.referral_stats(uuid),
  public.referral_credit_for(text, text, uuid), public.referral_trigger(), public.tip_begin(uuid, int, text), public.tip_attach(uuid, text), public.tip_paid(text, text, int), public.earnings_overview(uuid),
  public.cms_billing_settings(), public.cms_billing_settings_set(int, int, text, text, int, int, int, int, int, int, int), public.cms_subscriptions(text), public.cms_referral_credits(text),
  public.cms_referral_credit_paid(uuid, text), public.cms_creator_payouts(), public.cms_creator_payout_paid(uuid, text)
from public, anon, authenticated;
grant execute on function
  public.sub_plans(), public.sub_status(uuid), public.sub_begin(uuid, text), public.sub_customer(uuid), public.referral_code(uuid), public.referral_claim(text), public.referral_mine(),
  public.referral_stats(uuid), public.tip_begin(uuid, int, text), public.earnings_overview(uuid), public.cms_billing_settings(),
  public.cms_billing_settings_set(int, int, text, text, int, int, int, int, int, int, int), public.cms_subscriptions(text), public.cms_referral_credits(text),
  public.cms_referral_credit_paid(uuid, text), public.cms_creator_payouts(), public.cms_creator_payout_paid(uuid, text)
to authenticated;
grant execute on function
  public.sub_attach(uuid, text), public.sub_apply(text, text, text, timestamptz, boolean, uuid), public.tip_attach(uuid, text), public.tip_paid(text, text, int)
to service_role;
