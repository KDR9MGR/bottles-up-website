-- Splitting the bill (customer app completion plan, M6; client plan page 8): the person who booked a table asks friends to pay a share of what is STILL OWED AT THE CLUB. Each friend pays
-- their share online on Stripe's page; the amount is added to what the booking has been paid (exactly as a payment recorded at the club is), so the venue's own screens show the balance
-- going down with no change on their side.
--
--   * WHAT IS SPLIT: only the balance after the booking is confirmed (amount_total_cents - amount_paid_cents), never the first checkout (that keeps its 10-minute hold untouched). The
--     host books and pays as before; splitting is an optional extra on a confirmed booking.
--   * WHO: the host is the person whose verified e-mail is the booking's (the same proof the rest of the site uses); the friends are people with a personal profile who have not blocked
--     the host and whom the host has not blocked. A friend sees only the venue, the night, the host's first name and their own amount: never the booking's code, total or other shares.
--   * HOW MUCH: 1 to 20 shares, each between 5.00 and 5,000.00, adding up to no more than the balance at that moment. Equal or uneven is the app's choice: the database only checks.
--   * WHEN: a deadline chosen by the host, at least an hour away, at most 14 days away and no later than the booking is over (twelve hours after arrival). A share unpaid at the
--     deadline lapses; the host owes the rest at the club as before. Paying is refused after the deadline, so nothing needs to run on a timer.
--   * REFUNDS: a share is paid back IN FULL when the host cancels the split, when the venue cancels or refunds the booking, when the host's account is deleted, or when the money could not
--     be applied (the table was settled at the club in the meantime: the surplus). After the booking is over a paid share stays. The refund itself is done by the website's
--     `process-split-refunds` / `cancel-split` functions through Stripe; the database only says what is due and records what was paid back.
--   * THE MONEY NEVER MOVES TWICE: applying a payment is idempotent by Stripe session; a refund is recorded once per Stripe refund id.
--   * NO FEE: the BottlesUp fee and tax were already part of the booking's total; a share adds nothing on top.
--   * Everything refuses with "Splitting the bill is not open yet." until the `split_payments` switch is on (20261101100000).
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.site_splits (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.site_table_bookings (id) on delete cascade,
  -- The person who booked. If their account is deleted the split ends and everything paid is paid back (see split_refunds_due).
  host uuid references auth.users (id) on delete set null,
  status text not null default 'open' check (status in ('open', 'cancelled')),
  deadline timestamptz not null,
  created_at timestamptz not null default clock_timestamp(),
  cancelled_at timestamptz,
  constraint site_splits_cancelled_shape check ((status = 'cancelled') = (cancelled_at is not null))
);
create unique index site_splits_one_open on public.site_splits (booking_id) where status = 'open';
create index site_splits_booking_idx on public.site_splits (booking_id, created_at desc);
create index site_splits_host_idx on public.site_splits (host, created_at desc);

create table public.site_split_shares (
  id uuid primary key default gen_random_uuid(),
  split_id uuid not null references public.site_splits (id) on delete cascade,
  -- The friend's personal profile. Set to nothing if their account is deleted (a share they already paid stays applied; nothing names them).
  payer uuid references public.site_profiles (id) on delete set null,
  amount_cents int not null check (amount_cents between 500 and 500000),
  status text not null default 'unpaid' check (status in ('unpaid', 'pending', 'paid', 'declined', 'void')),
  stripe_session_id text unique,
  stripe_payment_intent_id text,
  -- A started payment page lapses after this; the share may then be started again.
  pending_until timestamptz,
  paid_at timestamptz,
  -- What Stripe took, what of it counts towards the booking, and what of that has been taken back off the booking again (a refund while the booking is still on).
  paid_cents int not null default 0 check (paid_cents >= 0),
  applied_cents int not null default 0 check (applied_cents >= 0),
  reversed_cents int not null default 0 check (reversed_cents >= 0),
  -- What has to be paid back to the friend, and what has been.
  refund_due_cents int not null default 0 check (refund_due_cents >= 0),
  refunded_cents int not null default 0 check (refunded_cents >= 0),
  refund_id text,
  refunded_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  constraint site_split_shares_money check (applied_cents <= paid_cents and reversed_cents <= applied_cents and refund_due_cents <= paid_cents and refunded_cents <= refund_due_cents),
  constraint site_split_shares_paid_shape check ((status = 'paid') = (paid_at is not null))
);
create unique index site_split_shares_one_per_person on public.site_split_shares (split_id, payer) where payer is not null;
create index site_split_shares_payer_idx on public.site_split_shares (payer, created_at desc) where payer is not null;
create index site_split_shares_refund_idx on public.site_split_shares (split_id) where refund_due_cents > refunded_cents;

alter table public.site_splits enable row level security;
alter table public.site_split_shares enable row level security;
revoke all on table public.site_splits, public.site_split_shares from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Helpers (internal)
-- ---------------------------------------------------------------------------
create function public.split_require_on()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not public.feature_enabled('split_payments') then raise exception 'Splitting the bill is not open yet.'; end if;
end;
$$;

-- Is the signed-in person the one who made this booking? (Their sign-in e-mail equals the booking's, ignoring case: the same proof the rest of the site uses.)
create function public.split_is_host(p_booking uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and coalesce(btrim(auth.email()), '') <> '' and exists (
    select 1 from public.site_table_bookings b where b.id = p_booking and lower(btrim(b.customer_email)) = lower(btrim(auth.email()))
  )
$$;

-- What the friend sees of the share's state. Lapsed and cancelled things are said as such, whatever the stored status.
create function public.split_share_state(p_share uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when s.status = 'paid' and s.refund_due_cents > 0 and s.refunded_cents >= s.refund_due_cents then 'refunded'
    when s.status = 'paid' and s.refund_due_cents > s.refunded_cents then 'refunding'
    when s.status = 'paid' then 'paid'
    when s.status = 'declined' then 'declined'
    when s.status = 'void' or sp.status = 'cancelled' or b.status <> 'paid' then 'cancelled'
    when now() > sp.deadline then 'expired'
    when s.status = 'pending' and s.pending_until > now() then 'pending'
    else 'unpaid'
  end
  from public.site_split_shares s
  join public.site_splits sp on sp.id = s.split_id
  join public.site_table_bookings b on b.id = sp.booking_id
  where s.id = p_share
$$;

-- The first word of a person's name, for what a friend is told about the host.
create function public.split_first_name(p_user uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(split_part(btrim(coalesce(pr.name, '')), ' ', 1), ''), nullif(pr.username, ''), 'A friend') from public.profiles pr where pr.id = p_user
$$;

-- The host's view of one split.
create function public.split_card(p_split uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  sp public.site_splits;
  b public.site_table_bookings;
  v_shares jsonb;
  v_collected int;
  v_outstanding int;
  v_state text;
  v_all_paid boolean;
begin
  select * into sp from public.site_splits where id = p_split;
  if not found then return null; end if;
  select * into b from public.site_table_bookings where id = sp.booking_id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id,
           'payer', case when s.payer is null then null else public.profile_mini(s.payer) end,
           'amount_cents', s.amount_cents,
           'status', public.split_share_state(s.id),
           'paid_at', s.paid_at) order by s.created_at, s.id), '[]'::jsonb)
    into v_shares from public.site_split_shares s where s.split_id = p_split;
  select coalesce(sum(s.applied_cents - s.reversed_cents), 0)::int into v_collected from public.site_split_shares s where s.split_id = p_split and s.status = 'paid';
  select coalesce(sum(s.amount_cents), 0)::int into v_outstanding from public.site_split_shares s where s.split_id = p_split and public.split_share_state(s.id) in ('unpaid', 'pending');
  select bool_and(public.split_share_state(s.id) in ('paid', 'refunding', 'refunded')) into v_all_paid from public.site_split_shares s where s.split_id = p_split;
  v_state := case
    when sp.status = 'cancelled' then 'cancelled'
    when coalesce(v_all_paid, false) then 'complete'
    when now() > sp.deadline then 'expired'
    else 'open'
  end;
  return jsonb_build_object(
    'id', sp.id,
    'booking_id', sp.booking_id,
    'state', v_state,
    'deadline', sp.deadline,
    'currency', b.currency,
    'balance_cents', greatest(b.amount_total_cents - b.amount_paid_cents, 0),
    'collected_cents', v_collected,
    'outstanding_cents', v_outstanding,
    'shares', v_shares,
    'created_at', sp.created_at
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The host: make a split, look at it, cancel it
-- ---------------------------------------------------------------------------
-- p_shares: [{"payer": <personal profile id>, "amount_cents": 2500}, ...]
create function public.split_create(p_booking uuid, p_shares jsonb, p_deadline timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  v_balance int;
  v_hours numeric;
  v_item jsonb;
  v_payer uuid;
  v_amount int;
  v_payer_user uuid;
  v_total int := 0;
  v_seen uuid[] := '{}';
  v_id uuid;
begin
  perform public.split_require_on();
  if p_booking is null then raise exception 'Choose a booking.'; end if;
  select * into b from public.site_table_bookings where id = p_booking for update;
  if not found or not public.split_is_host(p_booking) then raise exception 'This booking is not yours.'; end if;
  if b.status <> 'paid' then raise exception 'Only a confirmed booking can be split.'; end if;
  v_balance := greatest(b.amount_total_cents - b.amount_paid_cents, 0);
  if v_balance <= 0 then raise exception 'Nothing is left to pay on this booking.'; end if;
  v_hours := public.booking_hours_to_arrival(p_booking);
  if v_hours is null then raise exception 'This booking has no arrival time.'; end if;
  if v_hours <= -12 then raise exception 'This booking is over.'; end if;
  if exists (select 1 from public.site_refund_requests r where r.booking_id = p_booking and r.status in ('requested', 'approved', 'processing')) then
    raise exception 'A refund is being looked at on this booking, so it cannot be split now.';
  end if;
  if exists (select 1 from public.site_splits s where s.booking_id = p_booking and s.status = 'open') then
    raise exception 'This booking already has a split: cancel it before making a new one.';
  end if;
  if (select count(*) from public.site_splits s where s.host = auth.uid() and s.created_at > now() - interval '1 day') >= 5 then
    raise exception 'You have made a lot of splits today. Try again tomorrow.';
  end if;

  if p_deadline is null or p_deadline < now() + interval '1 hour' then raise exception 'Choose a deadline at least an hour from now.'; end if;
  if p_deadline > now() + interval '14 days' then raise exception 'Choose a deadline within 14 days.'; end if;
  if p_deadline > now() + make_interval(secs => (v_hours + 12) * 3600) then raise exception 'The deadline cannot be after the booking is over.'; end if;

  if p_shares is null or jsonb_typeof(p_shares) <> 'array' or jsonb_array_length(p_shares) < 1 then raise exception 'Choose at least one friend.'; end if;
  if jsonb_array_length(p_shares) > 20 then raise exception 'A split can have up to 20 friends.'; end if;

  insert into public.site_splits (booking_id, host, deadline) values (p_booking, auth.uid(), p_deadline) returning id into v_id;
  for v_item in select * from jsonb_array_elements(p_shares) loop
    if jsonb_typeof(v_item) <> 'object' or jsonb_typeof(v_item -> 'payer') is distinct from 'string' or jsonb_typeof(v_item -> 'amount_cents') is distinct from 'number' then
      raise exception 'Each share needs a friend and an amount.';
    end if;
    v_payer := (v_item ->> 'payer')::uuid;
    if (v_item ->> 'amount_cents') !~ '^[0-9]+$' then raise exception 'Each amount must be a whole number of cents.'; end if;
    v_amount := (v_item ->> 'amount_cents')::int;
    if v_amount < 500 then raise exception 'The smallest share is 5.00.'; end if;
    if v_amount > 500000 then raise exception 'The largest share is 5,000.00.'; end if;
    if v_payer = any (v_seen) then raise exception 'Each friend can be asked once.'; end if;
    v_seen := v_seen || v_payer;
    select p.user_id into v_payer_user from public.site_profiles p where p.id = v_payer and p.kind = 'personal' and p.status = 'active';
    if v_payer_user is null then raise exception 'One of the people you chose is not available.'; end if;
    if v_payer_user = auth.uid() then raise exception 'You do not need to ask yourself: your part is what is left at the club.'; end if;
    if exists (select 1 from public.site_blocks k where (k.blocker_key = v_payer_user and k.blocked_key = auth.uid()) or (k.blocker_key = auth.uid() and k.blocked_key = v_payer_user)) then
      raise exception 'One of the people you chose is not available.';
    end if;
    v_total := v_total + v_amount;
    insert into public.site_split_shares (split_id, payer, amount_cents) values (v_id, v_payer, v_amount);
  end loop;
  if v_total > v_balance then
    raise exception 'The shares add up to more than what is left to pay on this booking (% %).', upper(b.currency), to_char(v_balance / 100.0, 'FM999999990.00');
  end if;

  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'guest'), 'split.created', 'site_splits', v_id::text,
          jsonb_build_object('booking_id', p_booking, 'shares', jsonb_array_length(p_shares), 'total_cents', v_total, 'deadline', p_deadline));
  return public.split_card(v_id);
end;
$$;

-- The booking's split as its host sees it: the open one, otherwise the latest. Null when it never had one.
create function public.split_for_booking(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.split_require_on();
  if not public.split_is_host(p_booking) then raise exception 'This booking is not yours.'; end if;
  select s.id into v_id from public.site_splits s where s.booking_id = p_booking order by (s.status = 'open') desc, s.created_at desc, s.id limit 1;
  if v_id is null then return null; end if;
  return public.split_card(v_id);
end;
$$;

-- Cancels the split. Friends who have not paid are released; those who have are paid back in full (the website does it right after: cancel-split).
create function public.split_cancel(p_split uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  sp public.site_splits;
  b public.site_table_bookings;
  v_refunds int;
begin
  perform public.split_require_on();
  select * into sp from public.site_splits where id = p_split for update;
  if not found then raise exception 'This split is not available.'; end if;
  select * into b from public.site_table_bookings where id = sp.booking_id for update;
  if not public.split_is_host(sp.booking_id) then raise exception 'This split is not available.'; end if;
  if sp.status = 'cancelled' then raise exception 'This split is already cancelled.'; end if;
  if coalesce(public.booking_hours_to_arrival(sp.booking_id), 0) <= -12 then raise exception 'This booking is over, so the split can no longer be cancelled here. Ask the venue.'; end if;
  update public.site_splits set status = 'cancelled', cancelled_at = clock_timestamp() where id = p_split;
  update public.site_split_shares set status = 'void' where split_id = p_split and status in ('unpaid', 'pending');
  update public.site_split_shares set refund_due_cents = paid_cents where split_id = p_split and status = 'paid' and refund_due_cents < paid_cents;
  get diagnostics v_refunds = row_count;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'guest'), 'split.cancelled', 'site_splits', p_split::text, jsonb_build_object('booking_id', sp.booking_id, 'refunds', v_refunds));
  return public.split_card(p_split);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The friend: what they are asked to pay, say no, start paying, ask how it went
-- ---------------------------------------------------------------------------
-- The shares the signed-in person has been asked for, newest first. Only what a friend should know.
create function public.split_my_shares()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.split_require_on();
  return coalesce((
    select jsonb_agg(row order by created desc, sid)
      from (
        select s.created_at as created, s.id as sid, jsonb_build_object(
                 'id', s.id,
                 'state', public.split_share_state(s.id),
                 'amount_cents', s.amount_cents,
                 'currency', b.currency,
                 'deadline', sp.deadline,
                 'host', public.split_first_name(sp.host),
                 'venue', v.name,
                 'booking_date', b.booking_date,
                 'start_time', t.start_time,
                 'paid_at', s.paid_at) as row
          from public.site_split_shares s
          join public.site_splits sp on sp.id = s.split_id
          join public.site_table_bookings b on b.id = sp.booking_id
          join public.site_venues v on v.id = b.venue_id
          left join public.site_venue_time_slots t on t.id = b.time_slot_id
          join public.site_profiles me on me.id = s.payer and me.user_id = auth.uid() and me.kind = 'personal'
         where not exists (select 1 from public.site_blocks k where (k.blocker_key = auth.uid() and k.blocked_key = sp.host) or (k.blocker_key = sp.host and k.blocked_key = auth.uid()))
           and s.created_at > now() - interval '60 days'
         limit 100
      ) x
  ), '[]'::jsonb);
end;
$$;

-- One share the signed-in person was asked for, or an error that never says why it is not theirs.
create function public.split_share_status(p_share uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.site_split_shares;
begin
  perform public.split_require_on();
  select x.* into s from public.site_split_shares x
    join public.site_profiles me on me.id = x.payer and me.user_id = auth.uid()
   where x.id = p_share;
  if not found then raise exception 'This request is not available.'; end if;
  return jsonb_build_object('id', s.id, 'state', public.split_share_state(s.id), 'amount_cents', s.amount_cents, 'paid_at', s.paid_at);
end;
$$;

create function public.split_share_decline(p_share uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_split_shares;
begin
  perform public.split_require_on();
  select x.* into s from public.site_split_shares x
    join public.site_profiles me on me.id = x.payer and me.user_id = auth.uid()
   where x.id = p_share for update of x;
  if not found then raise exception 'This request is not available.'; end if;
  if public.split_share_state(p_share) not in ('unpaid', 'expired') then
    raise exception 'This request can no longer be turned down.';
  end if;
  update public.site_split_shares set status = 'declined' where id = p_share;
  return jsonb_build_object('id', p_share, 'state', 'declined');
end;
$$;

-- Checks that the signed-in person may pay this share NOW and says what to charge. The website's create-split-checkout calls it with the person's own login before it asks Stripe.
-- If a payment page was started less than half an hour ago, its Stripe session is returned so the same page is reopened and nobody pays twice.
create function public.split_share_begin(p_share uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_split_shares;
  sp public.site_splits;
  b public.site_table_bookings;
  v_state text;
  v_slot text;
begin
  perform public.split_require_on();
  select x.* into s from public.site_split_shares x
    join public.site_profiles me on me.id = x.payer and me.user_id = auth.uid()
   where x.id = p_share;
  if not found then raise exception 'This request is not available.'; end if;
  select * into sp from public.site_splits where id = s.split_id;
  select * into b from public.site_table_bookings where id = sp.booking_id;
  if exists (select 1 from public.site_blocks k where (k.blocker_key = auth.uid() and k.blocked_key = sp.host) or (k.blocker_key = sp.host and k.blocked_key = auth.uid())) then
    raise exception 'This request is not available.';
  end if;
  v_state := public.split_share_state(p_share);
  if v_state = 'paid' or v_state = 'refunding' or v_state = 'refunded' then raise exception 'You already paid this.'; end if;
  if v_state = 'declined' then raise exception 'You turned this request down.'; end if;
  if v_state = 'cancelled' then raise exception 'This request was cancelled.'; end if;
  if v_state = 'expired' then raise exception 'The time to pay this has passed. Ask the host to send a new request.'; end if;
  if greatest(b.amount_total_cents - b.amount_paid_cents, 0) < s.amount_cents then
    raise exception 'The rest of this table has been paid in the meantime, so there is nothing left for you to pay.';
  end if;
  select to_char(t.start_time, 'HH24:MI') into v_slot from public.site_venue_time_slots t where t.id = b.time_slot_id;
  return jsonb_build_object(
    'id', s.id,
    'amount_cents', s.amount_cents,
    'currency', b.currency,
    'booking_id', b.id,
    'venue', (select v.name from public.site_venues v where v.id = b.venue_id),
    'booking_date', b.booking_date,
    'start_time', v_slot,
    'host', public.split_first_name(sp.host),
    'pending_session', case when v_state = 'pending' then s.stripe_session_id else null end);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The website's payment functions (the service role only)
-- ---------------------------------------------------------------------------
-- A payment page was created for this share.
create function public.split_share_attach(p_share uuid, p_session text, p_until timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_session is null or btrim(p_session) = '' then raise exception 'a Stripe session is needed'; end if;
  update public.site_split_shares set status = 'pending', stripe_session_id = p_session, pending_until = p_until where id = p_share and status in ('unpaid', 'pending');
  if not found then raise exception 'this share cannot be paid now'; end if;
end;
$$;

-- Stripe has taken the money for this session. Idempotent: the same session twice changes nothing the second time. Answers {result, applied_cents, refund_cents}:
--   applied  - the share counts towards the booking (and any surplus is to be paid back)
--   refund   - the money could not be applied (split cancelled, booking no longer on, amount not the share's): all of it is to be paid back
--   already  - this session was recorded before
--   unknown  - no share has this session
create function public.split_share_paid(p_session text, p_payment_intent text, p_amount int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_split_shares;
  sp public.site_splits;
  b public.site_table_bookings;
  v_apply int;
begin
  select * into s from public.site_split_shares where stripe_session_id = p_session for update;
  if not found then return jsonb_build_object('result', 'unknown'); end if;
  if s.status = 'paid' then return jsonb_build_object('result', 'already', 'applied_cents', s.applied_cents, 'refund_cents', s.refund_due_cents - s.refunded_cents); end if;
  select * into sp from public.site_splits where id = s.split_id for update;
  select * into b from public.site_table_bookings where id = sp.booking_id for update;
  if p_amount is null or p_amount <= 0 then raise exception 'an amount is needed'; end if;

  if sp.status <> 'open' or sp.host is null or b.status <> 'paid' or s.status in ('declined', 'void') or p_amount <> s.amount_cents then
    update public.site_split_shares
       set status = 'paid', paid_at = clock_timestamp(), stripe_payment_intent_id = p_payment_intent, paid_cents = p_amount, applied_cents = 0, refund_due_cents = p_amount
     where id = s.id;
    insert into public.audit_log (actor_email, action, entity_type, entity_id, details)
    values ('stripe', 'split.share_paid_unusable', 'site_split_shares', s.id::text, jsonb_build_object('booking_id', b.id, 'amount_cents', p_amount, 'split_status', sp.status, 'booking_status', b.status));
    return jsonb_build_object('result', 'refund', 'applied_cents', 0, 'refund_cents', p_amount);
  end if;

  v_apply := least(p_amount, greatest(b.amount_total_cents - b.amount_paid_cents, 0));
  update public.site_table_bookings set amount_paid_cents = amount_paid_cents + v_apply where id = b.id;
  update public.site_split_shares
     set status = 'paid', paid_at = clock_timestamp(), stripe_payment_intent_id = p_payment_intent, paid_cents = p_amount, applied_cents = v_apply, refund_due_cents = p_amount - v_apply
   where id = s.id;
  insert into public.audit_log (actor_email, action, entity_type, entity_id, details)
  values ('stripe', 'split.share_paid', 'site_split_shares', s.id::text, jsonb_build_object('booking_id', b.id, 'amount_cents', p_amount, 'applied_cents', v_apply, 'surplus_cents', p_amount - v_apply));
  return jsonb_build_object('result', 'applied', 'applied_cents', v_apply, 'refund_cents', p_amount - v_apply);
end;
$$;

-- What has to be paid back now. First it looks for paid shares that should be paid back in full and are not marked so yet (the booking was cancelled or refunded, or the host's
-- account is gone; a share that only has a surplus due is raised to its whole amount), then lists every share with money due.
create function public.split_refunds_due()
returns table (share_id uuid, split_id uuid, stripe_payment_intent_id text, cents int)
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.site_split_shares s
     set refund_due_cents = s.paid_cents
    from public.site_splits sp, public.site_table_bookings b
   where sp.id = s.split_id and b.id = sp.booking_id and s.status = 'paid' and s.paid_cents > 0 and s.refund_due_cents < s.paid_cents
     and (sp.host is null or b.status in ('cancelled', 'refunded'));
  return query
    select s.id, s.split_id, s.stripe_payment_intent_id, (s.refund_due_cents - s.refunded_cents)::int
      from public.site_split_shares s
     where s.refund_due_cents > s.refunded_cents and s.stripe_payment_intent_id is not null
     order by s.paid_at, s.id;
end;
$$;

-- Stripe has paid back p_cents of this share (p_refund_id is Stripe's). Idempotent by refund id. While the booking is still on, what had been added to it comes off again.
create function public.split_share_refunded(p_share uuid, p_refund_id text, p_cents int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_split_shares;
  sp public.site_splits;
  b public.site_table_bookings;
  v_take int;
  v_reverse int;
begin
  if p_refund_id is null or btrim(p_refund_id) = '' or p_cents is null or p_cents <= 0 then raise exception 'a refund id and an amount are needed'; end if;
  select * into s from public.site_split_shares where id = p_share for update;
  if not found then raise exception 'this share does not exist'; end if;
  if s.refund_id is not distinct from p_refund_id and s.refunded_cents > 0 then return jsonb_build_object('result', 'already', 'refunded_cents', s.refunded_cents); end if;
  select * into sp from public.site_splits where id = s.split_id for update;
  select * into b from public.site_table_bookings where id = sp.booking_id for update;
  v_take := least(p_cents, s.refund_due_cents - s.refunded_cents);
  if v_take <= 0 then return jsonb_build_object('result', 'nothing_due', 'refunded_cents', s.refunded_cents); end if;
  v_reverse := 0;
  if b.status = 'paid' then
    -- Money paid back goes first against what was never added to the booking (the surplus); only the rest comes off the booking again.
    v_reverse := least(greatest(v_take - greatest((s.paid_cents - s.applied_cents) - s.refunded_cents, 0), 0), s.applied_cents - s.reversed_cents);
    update public.site_table_bookings set amount_paid_cents = greatest(amount_paid_cents - v_reverse, 0) where id = b.id;
  end if;
  update public.site_split_shares
     set refunded_cents = refunded_cents + v_take, reversed_cents = reversed_cents + v_reverse, refund_id = p_refund_id, refunded_at = clock_timestamp()
   where id = p_share;
  insert into public.audit_log (actor_email, action, entity_type, entity_id, details)
  values ('stripe', 'split.share_refunded', 'site_split_shares', p_share::text, jsonb_build_object('booking_id', b.id, 'refund_id', p_refund_id, 'refunded_cents', v_take, 'taken_off_booking_cents', v_reverse));
  return jsonb_build_object('result', 'refunded', 'refunded_cents', s.refunded_cents + v_take, 'taken_off_booking_cents', v_reverse);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.split_require_on(), public.split_is_host(uuid), public.split_share_state(uuid), public.split_first_name(uuid), public.split_card(uuid),
  public.split_create(uuid, jsonb, timestamptz), public.split_for_booking(uuid), public.split_cancel(uuid), public.split_my_shares(), public.split_share_status(uuid),
  public.split_share_decline(uuid), public.split_share_begin(uuid), public.split_share_attach(uuid, text, timestamptz), public.split_share_paid(text, text, int),
  public.split_refunds_due(), public.split_share_refunded(uuid, text, int)
from public, anon, authenticated;
grant execute on function
  public.split_create(uuid, jsonb, timestamptz), public.split_for_booking(uuid), public.split_cancel(uuid), public.split_my_shares(), public.split_share_status(uuid),
  public.split_share_decline(uuid), public.split_share_begin(uuid)
to authenticated;
grant execute on function
  public.split_share_attach(uuid, text, timestamptz), public.split_share_paid(text, text, int), public.split_refunds_due(), public.split_share_refunded(uuid, text, int)
to service_role;
