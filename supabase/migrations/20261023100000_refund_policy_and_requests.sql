-- Refund policy set by the venue, and refund requests with their decision (developer brief 15 Oct, sections 26 and 31; the client's answers of 20 Oct: "Each event or booking
-- must clearly show its cancellation policy before payment", "Guest requests cancellation > Authorized person checks the policy > Refund is approved or declined >
-- Guest receives an update"; and the user's decision: "Refund deadlines and amounts can be set by the vendor itself and can be monitored and viewed via the CMS").
--
--   THE POLICY (owner or manager of the venue sets it; guests read it before they pay; the CMS lists every venue's)
--   * site_refund_policies (closed table)    up to 6 rules "cancel at least H hours before arrival: P percent of the deposit back" (more notice never gets less back), whether
--                                            there is no refund once the guests have arrived, and a short note. No row = the venue has not set one (refunds are then at its discretion).
--   * venue_refund_policy / save_venue_refund_policy     read and change it (owner or manager)
--   * public_venue_refund_policy(venue)                  the plain sentences, for the booking page and the checkout (visitors may call it; only published venues)
--   * site_table_bookings.refund_policy                  a copy of the policy on every NEW booking (a BEFORE INSERT trigger, the one 20261021100000 made), so changing the
--                                                        policy later never rewrites the terms a guest booked under
--
--   THE REQUESTS (a manager decides; money moves only once, through the existing refund record)
--   * site_refund_requests (closed table)    Requested > Approved / Declined > Processing > Completed / Failed, with who asked, who decided, the amount, how it is paid back
--   * desk_refund_options                   what the booking's own policy says right now (hours before arrival, percent, suggested amount) and what can still be refunded
--   * guest_request_refund                  a guest asks, with their booking code and e-mail (visitors may call it; one open request per booking)
--   * desk_request_refund / desk_refund_requests / desk_decide_refund    staff record a request, list them, approve (up to what is left; MORE than the policy suggests needs a
--                                                        reason) or decline (a reason is needed)
--   * desk_complete_club_refund             the venue paid it back at the club (cash or its own terminal): recorded with a reference or receipt, the booking's paid amount goes down,
--                                           in one step with the request's completion
--   * refund_request_begin / refund_request_finish      for the refund-table-booking-payment edge function (BottlesUp admins return online payments through Stripe): claims an
--                                                        approved online request so two people cannot return it twice, and records how it ended
--   * cms_refund_requests / cms_refund_policies         the CMS's read-only views (BottlesUp admins only)
--   * desk_may_cancel_booking                the check the cancel-table-booking edge function asks with the caller's own login, so a club's manager or owner can cancel
--   * venue_timezone(venue)                  the one place the venue's time zone is read from (America/Toronto for every venue until time zones are stored per venue)
--
-- Needs: the venue setup, desk, close night and floor plan (20261021100000) migrations, and the hand-made site_table_booking_refunds (tests/db/prod_shapes).
-- Plain CREATE for everything new; the only thing replaced is the trigger function 20261021100000 created in the same go-live (it gains the policy copy).

do $pre$
declare
  r record;
begin
  for r in select * from (values
      ('public.require_venue_editor(uuid)'), ('public.venue_setup_log(text, text, uuid, uuid, jsonb)'), ('public.setup_only_keys(jsonb, text[])'),
      ('public.setup_int(jsonb, text, text, integer, integer)'), ('public.setup_text(jsonb, text, text, integer)'), ('public.setup_bool(jsonb, text, text)'),
      ('public.desk_level(uuid)'), ('public.desk_booking_level(uuid)'), ('public.desk_log(text, text, uuid, jsonb)'), ('public.is_cms_admin()'),
      ('public.booking_night(date, time without time zone)'), ('public.site_table_bookings_snapshot_terms()')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
  if to_regclass('public.site_table_booking_refunds') is null then
    raise exception 'public.site_table_booking_refunds does not exist: it exists in production only (see tests/db/prod_shapes). Nothing was changed.';
  end if;
end
$pre$;

alter table public.site_table_bookings add column refund_policy jsonb;

-- ---------------------------------------------------------------------------
-- 1. The venue's time zone, in one place
-- ---------------------------------------------------------------------------
create function public.venue_timezone(p_venue uuid)
returns text
language sql
stable
set search_path = public
as $$ select 'America/Toronto'::text $$;

-- ---------------------------------------------------------------------------
-- 2. The policy
-- ---------------------------------------------------------------------------
create table public.site_refund_policies (
  venue_id uuid primary key references public.site_venues (id) on delete cascade,
  tiers jsonb not null default '[]'::jsonb,
  no_refund_after_check_in boolean not null default true,
  note text check (note is null or char_length(note) <= 300),
  updated_by uuid references auth.users (id),
  updated_at timestamptz not null default now(),
  constraint site_refund_policies_tiers_check check (jsonb_typeof(tiers) = 'array' and jsonb_array_length(tiers) <= 6)
);
alter table public.site_refund_policies enable row level security;
revoke all on table public.site_refund_policies from public, anon, authenticated;

-- The share of the deposit a guest gets back for the notice they gave: the first rule (most notice first) whose hours the notice reaches; no rule reached = nothing.
-- p_tiers is the policy's list ([{"hours": 48, "percent": 100}, ...]); p_hours is how many hours before arrival the guest cancels (negative = after arrival).
create function public.refund_policy_percent(p_tiers jsonb, p_hours numeric)
returns int
language sql
immutable
set search_path = public
as $$
  select coalesce((
    select (t ->> 'percent')::int
      from jsonb_array_elements(coalesce(p_tiers, '[]'::jsonb)) t
     where p_hours >= (t ->> 'hours')::numeric
     order by (t ->> 'hours')::numeric desc
     limit 1), 0)
$$;

-- The policy as plain sentences, most notice first. p_policy is {"tiers": [...], "no_refund_after_check_in": bool, "note": text}.
create function public.refund_policy_lines(p_policy jsonb)
returns text[]
language plpgsql
immutable
set search_path = public
as $$
declare
  v_lines text[] := '{}';
  t jsonb;
  v_hours int;
  v_pct int;
  v_last int := null;
begin
  if p_policy is null then return array['This venue has not set a refund policy: refunds are decided by the venue.']; end if;
  if jsonb_array_length(coalesce(p_policy -> 'tiers', '[]'::jsonb)) = 0 then
    v_lines := array['The deposit is not refundable.'];
  else
    for t in select x from jsonb_array_elements(p_policy -> 'tiers') x order by (x ->> 'hours')::int desc loop
      v_hours := (t ->> 'hours')::int;
      v_pct := (t ->> 'percent')::int;
      v_lines := array_append(v_lines, (case
        when v_hours = 0 then 'Cancel any time before you arrive: '
        when v_hours % 24 = 0 then 'Cancel at least ' || (v_hours / 24) || case when v_hours = 24 then ' day' else ' days' end || ' before you arrive: '
        else 'Cancel at least ' || v_hours || case when v_hours = 1 then ' hour' else ' hours' end || ' before you arrive: ' end
        || case when v_pct = 100 then 'the whole deposit is refunded.' when v_pct = 0 then 'no refund.' else v_pct || '% of the deposit is refunded.' end));
      v_last := v_hours;
    end loop;
    if v_last is not null and v_last > 0 then v_lines := array_append(v_lines, 'Later than that: no refund.'); end if;
  end if;
  if coalesce((p_policy ->> 'no_refund_after_check_in')::boolean, true) then v_lines := array_append(v_lines, 'Once the guests have arrived there is no refund.'); end if;
  if nullif(btrim(coalesce(p_policy ->> 'note', '')), '') is not null then v_lines := array_append(v_lines, btrim(p_policy ->> 'note')); end if;
  return v_lines;
end;
$$;

create function public.venue_refund_policy(p_venue uuid)
returns table (has_policy boolean, tiers jsonb, no_refund_after_check_in boolean, note text, lines text[])
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p public.site_refund_policies;
begin
  perform public.require_venue_editor(p_venue);
  select * into p from public.site_refund_policies f where f.venue_id = p_venue;
  if not found then
    return query select false, '[]'::jsonb, true, null::text, public.refund_policy_lines(null);
  else
    return query select true, p.tiers, p.no_refund_after_check_in, p.note,
      public.refund_policy_lines(jsonb_build_object('tiers', p.tiers, 'no_refund_after_check_in', p.no_refund_after_check_in, 'note', p.note));
  end if;
end;
$$;

-- p_details: {"tiers": [{"hours": 48, "percent": 100}, {"hours": 24, "percent": 50}], "no_refund_after_check_in": true, "note": "..."}. Every key is optional on a later save:
-- what is not sent stays as it was; the first save needs the tiers (an empty list means the deposit is not refundable).
create function public.save_venue_refund_policy(p_venue uuid, p_details jsonb)
returns text[]
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.site_refund_policies;
  v_tiers jsonb;
  v_flag boolean;
  v_note text;
  v_exists boolean;
  t jsonb;
  v_prev_h int := null;
  v_prev_p int := null;
  v_h int;
  v_p int;
  v_new jsonb;
begin
  perform public.require_venue_editor(p_venue);
  perform public.setup_only_keys(p_details, array['tiers', 'no_refund_after_check_in', 'note']);
  select * into p from public.site_refund_policies f where f.venue_id = p_venue for update;
  v_exists := found;

  if p_details ? 'tiers' then
    v_tiers := p_details -> 'tiers';
    if v_tiers is null or jsonb_typeof(v_tiers) <> 'array' then raise exception 'the refund rules must be a list'; end if;
    if jsonb_array_length(v_tiers) > 6 then raise exception 'a refund policy can have 6 rules at most'; end if;
    -- validate every rule, then normalise: most notice first, whole numbers only
    for t in select x from jsonb_array_elements(v_tiers) x loop
      if jsonb_typeof(t) <> 'object' then raise exception 'each refund rule needs the hours of notice and the percent refunded'; end if;
      perform public.setup_only_keys(t, array['hours', 'percent']);
      v_h := public.setup_int(t, 'hours', 'the hours of notice', 0, 2160);
      v_p := public.setup_int(t, 'percent', 'the percent refunded', 0, 100);
      if v_h is null or v_p is null then raise exception 'each refund rule needs the hours of notice and the percent refunded'; end if;
    end loop;
    if (select count(distinct (x ->> 'hours')::int) from jsonb_array_elements(v_tiers) x) <> jsonb_array_length(v_tiers) then
      raise exception 'two refund rules cannot have the same hours of notice';
    end if;
    for t in select x from jsonb_array_elements(v_tiers) x order by (x ->> 'hours')::int desc loop
      v_h := (t ->> 'hours')::int; v_p := (t ->> 'percent')::int;
      if v_prev_p is not null and v_p > v_prev_p then raise exception 'giving more notice cannot get less back: a rule with fewer hours cannot refund a larger percent'; end if;
      v_prev_h := v_h; v_prev_p := v_p;
    end loop;
    v_tiers := coalesce((select jsonb_agg(jsonb_build_object('hours', (x ->> 'hours')::int, 'percent', (x ->> 'percent')::int) order by (x ->> 'hours')::int desc) from jsonb_array_elements(v_tiers) x), '[]'::jsonb);
  elsif v_exists then
    v_tiers := p.tiers;
  else
    raise exception 'set the refund rules (an empty list means the deposit is not refundable)';
  end if;

  v_flag := case when p_details ? 'no_refund_after_check_in' then public.setup_bool(p_details, 'no_refund_after_check_in', 'no refund after arrival') else coalesce(p.no_refund_after_check_in, true) end;
  if v_flag is null then raise exception 'no refund after arrival must be true or false'; end if;
  v_note := case when p_details ? 'note' then public.setup_text(p_details, 'note', 'the note', 300) else p.note end;

  v_new := jsonb_build_object('tiers', v_tiers, 'no_refund_after_check_in', v_flag, 'note', v_note);
  if v_exists and p.tiers = v_tiers and p.no_refund_after_check_in = v_flag and p.note is not distinct from v_note then
    return public.refund_policy_lines(v_new);
  end if;
  insert into public.site_refund_policies (venue_id, tiers, no_refund_after_check_in, note, updated_by, updated_at)
  values (p_venue, v_tiers, v_flag, v_note, auth.uid(), now())
  on conflict (venue_id) do update set tiers = excluded.tiers, no_refund_after_check_in = excluded.no_refund_after_check_in, note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  perform public.venue_setup_log('venue.refund_policy_saved', 'site_venues', p_venue, p_venue, jsonb_build_object(
    'from', case when v_exists then jsonb_build_object('tiers', p.tiers, 'no_refund_after_check_in', p.no_refund_after_check_in) end, 'to', jsonb_build_object('tiers', v_tiers, 'no_refund_after_check_in', v_flag)));
  return public.refund_policy_lines(v_new);
end;
$$;

-- What a guest reads before they pay. Visitors may call it; only a published venue answers.
create function public.public_venue_refund_policy(p_venue uuid)
returns table (has_policy boolean, lines text[])
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p public.site_refund_policies;
begin
  if not exists (select 1 from public.site_venues v where v.id = p_venue and v.status = 'published') then return; end if;
  select * into p from public.site_refund_policies f where f.venue_id = p_venue;
  if not found then
    return query select false, public.refund_policy_lines(null);
  else
    return query select true, public.refund_policy_lines(jsonb_build_object('tiers', p.tiers, 'no_refund_after_check_in', p.no_refund_after_check_in, 'note', p.note));
  end if;
end;
$$;

-- Every new booking carries the policy it was made under (replaces the trigger function 20261021100000 made: the same two copies as before, and the policy).
create or replace function public.site_table_bookings_snapshot_terms()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_terms jsonb;
  v_credit boolean;
  v_adm int;
  v_pol public.site_refund_policies;
begin
  if new.deposit_terms is null then
    select v.deposit_terms, v.deposit_is_credit into v_terms, v_credit from public.site_venues v where v.id = new.venue_id;
    new.deposit_terms := coalesce(v_terms, jsonb_build_object(
      'recipient', 'venue', 'venue_pct', 100, 'purpose', case when coalesce(v_credit, false) then 'minimum_spend_credit' else 'reservation_fee' end, 'default', true));
  end if;
  if new.included_admissions is null then
    select t.included_admissions into v_adm from public.site_table_types t where t.id = new.table_type_id;
    new.included_admissions := v_adm;
  end if;
  if new.refund_policy is null then
    select * into v_pol from public.site_refund_policies f where f.venue_id = new.venue_id;
    if found then
      new.refund_policy := jsonb_build_object('tiers', v_pol.tiers, 'no_refund_after_check_in', v_pol.no_refund_after_check_in, 'note', v_pol.note);
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Requests
-- ---------------------------------------------------------------------------
create table public.site_refund_requests (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.site_table_bookings (id) on delete cascade,
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  requested_by_kind text not null check (requested_by_kind in ('guest', 'staff')),
  requested_by uuid references auth.users (id),
  reason text not null check (char_length(btrim(reason)) between 3 and 500),
  policy_percent int check (policy_percent is null or policy_percent between 0 and 100),
  suggested_cents int not null default 0 check (suggested_cents >= 0),
  status text not null default 'requested' check (status in ('requested', 'approved', 'declined', 'processing', 'completed', 'failed')),
  approved_cents int check (approved_cents is null or approved_cents > 0),
  method text check (method in ('online', 'club')),
  decided_by uuid references auth.users (id),
  decided_at timestamptz,
  decision_note text check (decision_note is null or char_length(decision_note) <= 500),
  refund_id uuid references public.site_table_booking_refunds (id) on delete set null,
  failure_note text check (failure_note is null or char_length(failure_note) <= 500),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint site_refund_requests_decision_check check (
    (status = 'requested' and decided_at is null and approved_cents is null and method is null)
    or (status = 'declined' and decided_at is not null and decision_note is not null and approved_cents is null)
    or (status in ('approved', 'processing', 'completed', 'failed') and decided_at is not null and approved_cents is not null and method is not null))
);
create unique index site_refund_requests_one_open on public.site_refund_requests (booking_id) where status in ('requested', 'approved', 'processing');
create index site_refund_requests_venue_idx on public.site_refund_requests (venue_id, status, created_at desc);
alter table public.site_refund_requests enable row level security;
revoke all on table public.site_refund_requests from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. What the policy says about one booking now, and what can still be refunded (internal helpers: the app reaches them through the functions below)
-- ---------------------------------------------------------------------------
-- Hours from now to the guests' arrival (negative once it has passed), in the venue's time zone.
create function public.booking_hours_to_arrival(p_booking uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select extract(epoch from (((b.booking_date + s.start_time) at time zone public.venue_timezone(b.venue_id)) - now())) / 3600.0
    from public.site_table_bookings b join public.site_venue_time_slots s on s.id = b.time_slot_id
   where b.id = p_booking
$$;

-- What can still be paid back: what the booking has taken, less what approved or processing requests have already claimed (p_except is the request being decided).
create function public.booking_refundable_cents(p_booking uuid, p_except uuid default null)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select greatest(b.amount_paid_cents - coalesce((select sum(r.approved_cents) from public.site_refund_requests r
                                                   where r.booking_id = b.id and r.status in ('approved', 'processing') and r.id is distinct from p_except), 0), 0)::int
    from public.site_table_bookings b where b.id = p_booking
$$;

-- The booking's own policy applied now: {percent, suggested_cents, reason}. percent is null when the booking has no policy.
create function public.booking_refund_suggestion(p_booking uuid, p_except uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  v_hours numeric;
  v_pct int;
  v_left int;
begin
  select * into b from public.site_table_bookings where id = p_booking;
  if not found then return null; end if;
  v_hours := public.booking_hours_to_arrival(p_booking);
  v_left := public.booking_refundable_cents(p_booking, p_except);
  if b.refund_policy is null then
    return jsonb_build_object('percent', null, 'suggested_cents', 0, 'why', 'This booking was made without a refund policy, so the amount is the venue''s decision.');
  end if;
  if b.checked_in_at is not null and coalesce((b.refund_policy ->> 'no_refund_after_check_in')::boolean, true) then
    return jsonb_build_object('percent', 0, 'suggested_cents', 0, 'why', 'The guests have already arrived, and the policy gives no refund after that.');
  end if;
  v_pct := public.refund_policy_percent(b.refund_policy -> 'tiers', v_hours);
  return jsonb_build_object('percent', v_pct, 'suggested_cents', least(floor(b.deposit_cents::numeric * v_pct / 100)::int, v_left),
    'why', case when v_pct = 0 then 'The notice given is shorter than the policy allows a refund for.' else 'The policy refunds ' || v_pct || '% of the deposit for this much notice.' end);
end;
$$;
revoke all on function public.venue_timezone(uuid), public.refund_policy_percent(jsonb, numeric), public.refund_policy_lines(jsonb), public.booking_hours_to_arrival(uuid),
  public.booking_refundable_cents(uuid, uuid), public.booking_refund_suggestion(uuid, uuid) from public, anon, authenticated;
grant execute on function public.venue_timezone(uuid), public.refund_policy_percent(jsonb, numeric), public.refund_policy_lines(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 5. The app: options, requests, decisions
-- ---------------------------------------------------------------------------
create function public.desk_refund_options(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  v_sugg jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_booking_level(p_booking) is distinct from 'manager' then raise exception 'not allowed'; end if;
  select * into b from public.site_table_bookings where id = p_booking;
  v_sugg := public.booking_refund_suggestion(p_booking);
  return jsonb_build_object(
    'paid_cents', b.amount_paid_cents,
    'deposit_cents', b.deposit_cents,
    'available_cents', public.booking_refundable_cents(p_booking),
    'hours_to_arrival', round(public.booking_hours_to_arrival(p_booking), 1),
    'checked_in', b.checked_in_at is not null,
    'paid_online', b.stripe_payment_intent_id is not null,
    'status', b.status,
    'policy_lines', to_jsonb(public.refund_policy_lines(case when b.refund_policy is null then null else b.refund_policy end)),
    'percent', v_sugg -> 'percent',
    'suggested_cents', (v_sugg ->> 'suggested_cents')::int,
    'why', v_sugg ->> 'why',
    'open_request_id', (select r.id from public.site_refund_requests r where r.booking_id = p_booking and r.status in ('requested', 'approved', 'processing')));
end;
$$;

-- The terms this booking was made under, for its page: the deposit terms and included admissions copied onto it (20261021100000) and the refund policy (above), in words.
-- A manager or owner of the club, or the server the table was given to.
create function public.desk_booking_terms(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_booking_level(p_booking) is null then raise exception 'not allowed'; end if;
  select * into b from public.site_table_bookings where id = p_booking;
  return jsonb_build_object(
    'deposit_cents', b.deposit_cents,
    'deposit_terms', b.deposit_terms,
    'included_admissions', b.included_admissions,
    'refund_policy_set', b.refund_policy is not null,
    'refund_policy_lines', to_jsonb(public.refund_policy_lines(b.refund_policy)));
end;
$$;

create function public.desk_request_refund(p_booking uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_sugg jsonb;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_booking_level(p_booking) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 500 then raise exception 'give a reason of 3 to 500 characters'; end if;
  select * into b from public.site_table_bookings where id = p_booking for update;
  if not found then raise exception 'not allowed'; end if;
  if b.status not in ('paid', 'cancelled') then raise exception 'only a confirmed or cancelled booking can be refunded'; end if;
  if public.booking_refundable_cents(p_booking) <= 0 then raise exception 'nothing is left to refund on this booking'; end if;
  if exists (select 1 from public.site_refund_requests r where r.booking_id = p_booking and r.status in ('requested', 'approved', 'processing')) then
    raise exception 'a refund request for this booking is already open';
  end if;
  v_sugg := public.booking_refund_suggestion(p_booking);
  insert into public.site_refund_requests (booking_id, venue_id, requested_by_kind, requested_by, reason, policy_percent, suggested_cents)
  values (p_booking, b.venue_id, 'staff', auth.uid(), v_reason, (v_sugg ->> 'percent')::int, (v_sugg ->> 'suggested_cents')::int) returning id into v_id;
  perform public.desk_log('refund.requested', 'site_refund_requests', v_id, jsonb_build_object('venue_id', b.venue_id, 'booking_id', p_booking, 'by', 'staff', 'reason', v_reason));
  return v_id;
end;
$$;

-- A guest asks for their money back. They prove it is theirs with the booking code and the e-mail it was made with; anything else gets the same answer.
create function public.guest_request_refund(p_code text, p_email text, p_reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.site_table_bookings;
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_sugg jsonb;
  v_id uuid;
begin
  if char_length(v_reason) < 3 or char_length(v_reason) > 500 then raise exception 'tell us why in a few words (up to 500 characters)'; end if;
  select * into b from public.site_table_bookings k where k.confirmation_code = v_code and lower(k.customer_email) = v_email for update;
  if not found or v_code = '' or v_email = '' then raise exception 'we could not find a booking with that code and e-mail'; end if;
  if b.status not in ('paid', 'cancelled') or b.amount_paid_cents <= 0 then raise exception 'there is nothing paid on this booking to refund'; end if;
  if public.booking_refundable_cents(b.id) <= 0 then raise exception 'there is nothing left to refund on this booking'; end if;
  if exists (select 1 from public.site_refund_requests r where r.booking_id = b.id and r.status in ('requested', 'approved', 'processing')) then
    raise exception 'you have already asked for a refund on this booking: the venue is looking at it';
  end if;
  v_sugg := public.booking_refund_suggestion(b.id);
  insert into public.site_refund_requests (booking_id, venue_id, requested_by_kind, requested_by, reason, policy_percent, suggested_cents)
  values (b.id, b.venue_id, 'guest', auth.uid(), v_reason, (v_sugg ->> 'percent')::int, (v_sugg ->> 'suggested_cents')::int) returning id into v_id;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'guest'), 'refund.requested', 'site_refund_requests', v_id::text, jsonb_build_object('venue_id', b.venue_id, 'booking_id', b.id, 'by', 'guest', 'reason', v_reason));
  return 'Your request has been sent to the venue. They will look at it and update you.';
end;
$$;

create function public.desk_refund_requests(p_venue uuid, p_status text default null)
returns table (
  request_id uuid, booking_id uuid, confirmation_code text, guest_name text, table_name text, booking_date date, requested_by_kind text, reason text, status text,
  paid_cents int, available_cents int, policy_percent int, suggested_cents int, approved_cents int, method text, decision_note text, failure_note text,
  decided_at timestamptz, created_at timestamptz, completed_at timestamptz, refund_reference text, refund_receipt_path text
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_status is not null and p_status not in ('requested', 'approved', 'declined', 'processing', 'completed', 'failed') then raise exception 'unknown status'; end if;
  return query
    select r.id, r.booking_id, b.confirmation_code, b.customer_name, t.name, b.booking_date, r.requested_by_kind, r.reason, r.status,
           b.amount_paid_cents, public.booking_refundable_cents(b.id, r.id), r.policy_percent, r.suggested_cents, r.approved_cents, r.method, r.decision_note, r.failure_note,
           r.decided_at, r.created_at, r.completed_at, f.pos_reference, f.receipt_photo_path
      from public.site_refund_requests r
      join public.site_table_bookings b on b.id = r.booking_id
      join public.site_table_types t on t.id = b.table_type_id
      left join public.site_table_booking_refunds f on f.id = r.refund_id
     where r.venue_id = p_venue and (p_status is null or r.status = p_status)
     order by (r.status = 'requested') desc, r.created_at desc, r.id
     limit 200;
end;
$$;

create function public.desk_decide_refund(p_request uuid, p_approve boolean, p_amount_cents int, p_method text, p_note text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_refund_requests;
  b public.site_table_bookings;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_left int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into r from public.site_refund_requests where id = p_request for update;
  if not found or public.desk_level(r.venue_id) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if r.status <> 'requested' then raise exception 'this request has already been decided'; end if;
  if p_approve is null then raise exception 'approve or decline'; end if;
  if v_note is not null and char_length(v_note) > 500 then raise exception 'the note can be up to 500 characters'; end if;
  select * into b from public.site_table_bookings where id = r.booking_id for update;

  if not p_approve then
    if v_note is null or char_length(v_note) < 3 then raise exception 'say why the refund is declined, so the guest can be told'; end if;
    update public.site_refund_requests set status = 'declined', decided_by = auth.uid(), decided_at = now(), decision_note = v_note, updated_at = now() where id = p_request;
    perform public.desk_log('refund.declined', 'site_refund_requests', p_request, jsonb_build_object('venue_id', r.venue_id, 'booking_id', r.booking_id, 'reason', v_note));
    return 'declined';
  end if;

  if p_method is null or p_method not in ('online', 'club') then raise exception 'choose how it is paid back: online, or at the club'; end if;
  if p_amount_cents is null or p_amount_cents < 1 then raise exception 'how much is refunded?'; end if;
  v_left := public.booking_refundable_cents(r.booking_id, p_request);
  if p_amount_cents > v_left then raise exception 'only % can still be refunded on this booking', to_char(v_left / 100.0, 'FM999999990.00'); end if;
  if p_method = 'online' and b.stripe_payment_intent_id is null then
    raise exception 'there is no online payment on this booking to return; record a refund made at the club instead';
  end if;
  if p_amount_cents > r.suggested_cents and (v_note is null or char_length(v_note) < 3) then
    raise exception 'this is more than the refund policy suggests (%): say why', to_char(r.suggested_cents / 100.0, 'FM999999990.00');
  end if;
  update public.site_refund_requests set status = 'approved', approved_cents = p_amount_cents, method = p_method, decided_by = auth.uid(), decided_at = now(), decision_note = v_note, updated_at = now()
   where id = p_request;
  perform public.desk_log('refund.approved', 'site_refund_requests', p_request, jsonb_build_object('venue_id', r.venue_id, 'booking_id', r.booking_id, 'amount_cents', p_amount_cents, 'method', p_method,
    'suggested_cents', r.suggested_cents, 'reason', v_note));
  return 'approved';
end;
$$;

-- The venue returned the money at the club (cash or its own terminal). The reference or a receipt is the evidence; the booking's paid amount goes down in the same step.
create function public.desk_complete_club_refund(p_request uuid, p_pos_reference text, p_receipt_path text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_refund_requests;
  v_ref text := nullif(btrim(coalesce(p_pos_reference, '')), '');
  v_path text := nullif(btrim(coalesce(p_receipt_path, '')), '');
  v_refund uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into r from public.site_refund_requests where id = p_request for update;
  if not found or public.desk_level(r.venue_id) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if r.status = 'completed' then return r.refund_id; end if;
  if r.status <> 'approved' or r.method <> 'club' then raise exception 'only an approved refund that is paid back at the club can be recorded here'; end if;
  if v_ref is null and v_path is null then raise exception 'add the terminal or receipt reference, or a photo of the receipt, as evidence'; end if;
  if v_ref is not null and char_length(v_ref) > 200 then raise exception 'the reference is too long'; end if;
  -- the photo is filed under the booking's own id in the private receipts bucket (the bucket's policy lets a manager of THAT booking add one there), so it cannot point at another booking's file
  if v_path is not null and (char_length(v_path) > 300 or v_path not like r.booking_id::text || '/%' or v_path like '%..%') then raise exception 'the receipt photo does not belong to this booking'; end if;
  perform 1 from public.site_table_bookings b where b.id = r.booking_id for update;
  insert into public.site_table_booking_refunds (booking_id, refund_type, amount_cents, reason, pos_reference, receipt_photo_path, recorded_by)
  values (r.booking_id, 'club', r.approved_cents, r.reason, v_ref, v_path, auth.uid()) returning id into v_refund;
  update public.site_table_bookings set amount_paid_cents = greatest(amount_paid_cents - r.approved_cents, 0), updated_at = now() where id = r.booking_id;
  update public.site_refund_requests set status = 'completed', refund_id = v_refund, completed_at = now(), updated_at = now() where id = p_request;
  perform public.desk_log('refund.completed', 'site_refund_requests', p_request, jsonb_build_object('venue_id', r.venue_id, 'booking_id', r.booking_id, 'amount_cents', r.approved_cents, 'method', 'club', 'refund_id', v_refund));
  return v_refund;
end;
$$;

-- The cancel-table-booking edge function asks this with the caller's own login before it cancels (a club's manager or owner may cancel a booking of their club).
create function public.desk_may_cancel_booking(p_booking uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.desk_booking_level(p_booking) is distinct from 'manager' then raise exception 'not allowed'; end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. For the refund edge function (BottlesUp admins return online payments through Stripe) and the CMS
-- ---------------------------------------------------------------------------
-- Claims an approved online request for processing: only one caller gets it, so the same refund cannot be sent twice.
create function public.refund_request_begin(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_refund_requests;
begin
  if not (public.is_cms_admin() or auth.role() = 'service_role') then raise exception 'not allowed'; end if;
  update public.site_refund_requests set status = 'processing', updated_at = now()
   where id = p_request and status = 'approved' and method = 'online' returning * into r;
  if not found then raise exception 'this refund is not an approved online refund waiting to be processed'; end if;
  return jsonb_build_object('request_id', r.id, 'booking_id', r.booking_id, 'amount_cents', r.approved_cents, 'reason', r.reason);
end;
$$;

create function public.refund_request_finish(p_request uuid, p_refund_id uuid, p_ok boolean, p_note text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.site_refund_requests;
begin
  if not (public.is_cms_admin() or auth.role() = 'service_role') then raise exception 'not allowed'; end if;
  select * into r from public.site_refund_requests where id = p_request for update;
  if not found then raise exception 'request not found'; end if;
  if r.status in ('completed', 'failed') then return r.status; end if;
  if r.status <> 'processing' then raise exception 'this refund is not being processed'; end if;
  if p_ok is true then
    update public.site_refund_requests set status = 'completed', refund_id = p_refund_id, completed_at = now(), updated_at = now() where id = p_request;
    perform public.desk_log('refund.completed', 'site_refund_requests', p_request, jsonb_build_object('venue_id', r.venue_id, 'booking_id', r.booking_id, 'amount_cents', r.approved_cents, 'method', 'online', 'refund_id', p_refund_id));
    return 'completed';
  end if;
  update public.site_refund_requests set status = 'failed', failure_note = left(coalesce(nullif(btrim(p_note), ''), 'The payment provider did not return the money.'), 500), updated_at = now() where id = p_request;
  perform public.desk_log('refund.failed', 'site_refund_requests', p_request, jsonb_build_object('venue_id', r.venue_id, 'booking_id', r.booking_id, 'reason', left(coalesce(p_note, ''), 200)));
  return 'failed';
end;
$$;

create function public.cms_refund_requests(p_status text default null)
returns table (
  request_id uuid, booking_id uuid, venue_name text, confirmation_code text, guest_name text, guest_email text, requested_by_kind text, reason text, status text, paid_cents int,
  policy_percent int, suggested_cents int, approved_cents int, method text, decision_note text, failure_note text, created_at timestamptz, decided_at timestamptz, completed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  if p_status is not null and p_status not in ('requested', 'approved', 'declined', 'processing', 'completed', 'failed') then raise exception 'unknown status'; end if;
  return query
    select r.id, r.booking_id, v.name, b.confirmation_code, b.customer_name, b.customer_email, r.requested_by_kind, r.reason, r.status, b.amount_paid_cents,
           r.policy_percent, r.suggested_cents, r.approved_cents, r.method, r.decision_note, r.failure_note, r.created_at, r.decided_at, r.completed_at
      from public.site_refund_requests r
      join public.site_table_bookings b on b.id = r.booking_id
      join public.site_venues v on v.id = r.venue_id
     where p_status is null or r.status = p_status
     order by (r.status in ('requested', 'approved', 'processing')) desc, r.created_at desc, r.id
     limit 500;
end;
$$;

create function public.cms_refund_policies()
returns table (venue_id uuid, venue_name text, has_policy boolean, lines text[], updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_cms_admin() then raise exception 'not allowed'; end if;
  return query
    select v.id, v.name, f.venue_id is not null,
           public.refund_policy_lines(case when f.venue_id is null then null else jsonb_build_object('tiers', f.tiers, 'no_refund_after_check_in', f.no_refund_after_check_in, 'note', f.note) end),
           f.updated_at
      from public.site_venues v left join public.site_refund_policies f on f.venue_id = v.id
     order by v.name, v.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
revoke all on function
  public.venue_refund_policy(uuid), public.save_venue_refund_policy(uuid, jsonb), public.public_venue_refund_policy(uuid), public.desk_refund_options(uuid), public.desk_booking_terms(uuid),
  public.desk_request_refund(uuid, text), public.guest_request_refund(text, text, text), public.desk_refund_requests(uuid, text), public.desk_decide_refund(uuid, boolean, int, text, text),
  public.desk_complete_club_refund(uuid, text, text), public.desk_may_cancel_booking(uuid), public.refund_request_begin(uuid), public.refund_request_finish(uuid, uuid, boolean, text),
  public.cms_refund_requests(text), public.cms_refund_policies()
  from public, anon;
grant execute on function
  public.venue_refund_policy(uuid), public.save_venue_refund_policy(uuid, jsonb), public.desk_refund_options(uuid), public.desk_booking_terms(uuid), public.desk_request_refund(uuid, text),
  public.desk_refund_requests(uuid, text), public.desk_decide_refund(uuid, boolean, int, text, text), public.desk_complete_club_refund(uuid, text, text), public.desk_may_cancel_booking(uuid),
  public.refund_request_begin(uuid), public.refund_request_finish(uuid, uuid, boolean, text), public.cms_refund_requests(text), public.cms_refund_policies()
  to authenticated, service_role;
-- guests (visitors too) may read a published venue's policy and ask for a refund with their code and e-mail
grant execute on function public.public_venue_refund_policy(uuid), public.guest_request_refund(text, text, text) to anon, authenticated, service_role;
