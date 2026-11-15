-- Organizer settlement RECORDS (client Phase 2 brief, section 25: "Organizer share and payout recording"; paths "Organizer Event -> Settlement", "Owner Money -> Organizer Settlements",
-- "Manager Event -> Settlement Review"). RECORD ONLY: nothing here moves money, calls a payment provider or pays anyone. A payment is recorded AFTER it was made somewhere else, and the record
-- says so ("Recorded external payment"). It does not replace BottlesUp's own payouts (site_payout_items), which are a different thing: what BottlesUp pays out.
--
-- WHAT A SETTLEMENT IS: what the club owes the event's organizer under the ACCEPTED agreement (site_agreements, 20261018180000), for the organizer's SHARE OF BAR SALES: a percentage of the
-- eligible bar sales above a threshold, or of all of them once it is reached, exactly as agreement_sample() works it out. One per agreement. It is estimated, reviewed, approved, then a payment
-- is recorded. Tickets and tables are NOT included: who owns that money (ticket_ownership, table_allocation) is free text in the terms and the client has not said how it is split.
--
--   WHERE THE FIGURE COMES FROM: the club's manager or owner ENTERS the eligible bar sales and says where they come from (for example "closing report of Fri 14 Nov, reviewed"). The terms say
--   which revenue is eligible, how refunds and taxes, tips and fees are treated in words, not in numbers, so the app cannot work the figure out by itself. It is shown as the venue's own
--   figure, never as a BottlesUp-counted one. The terms (version, percentage, threshold, formula and the three wordings) are COPIED into the settlement, so a later renegotiation does not
--   change a settlement that is already being worked on.
--
--   WHO MAY DO WHAT (a policy assumption from the brief, easy to change in the functions below):
--     * the club's manager or owner: enter or change the sales, adjust the amount (with a note), review, and answer a question
--     * the club's OWNER only: approve, and record the payment (a manager reviews, the owner approves and pays)
--     * the organizer's business: read it, acknowledge it once approved, or QUESTION it with a reason before it is paid. The organizer can never change the sales, the amount or the status
--       otherwise, and can never record a payment.
--   STATUSES: estimated -> reviewed -> approved -> paid, and disputed (a question from the organizer, with its reason; the club answers it and it goes back to estimated). The brief also names
--   "Reconciliation pending" and "Payment pending": those are the waiting between steps (estimated = reconciliation pending, approved = payment pending) and are shown with those words, not stored.
--   Changing the amount or the sales after a review or an approval sends it back to estimated: nobody approves figures they have not seen. A paid settlement is final here: an adjustment AFTER
--   payment (a later refund or chargeback) is not recorded yet.
--
--   THE PAYMENT RECORD: paying party (the club), recipient (the organizer), the exact amount approved (nothing else is accepted), the currency (CAD, like every price in the platform), the date it
--   was paid (not in the future), a reference (3 to 120 characters), optional evidence text, who recorded it and when. Every step is also written to a history that cannot be edited.
--
-- Everything is reached through functions; the two tables are closed. Plain CREATE, never CREATE OR REPLACE. Needs the agreements (20261018180000) and agreement access (20261117100000) migrations.

do $pre$
declare
  r record;
begin
  for r in select * from (values
      ('public.agreement_in_force(public.site_agreements)'), ('public.agreement_sample(jsonb, bigint)'), ('public.can_access_venue(uuid, text[])'), ('public.can_access_event(uuid, text[])'),
      ('public.is_org_member(uuid, text[])')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. Tables (closed: written only by the functions below)
-- ---------------------------------------------------------------------------
create table public.site_settlements (
  id uuid primary key default gen_random_uuid(),
  agreement_id uuid not null references public.site_agreements (id),
  agreement_version int not null,
  event_id uuid not null references public.site_events (id),
  venue_id uuid not null references public.site_venues (id),
  organizer_org_id uuid not null references public.site_organizations (id),
  terms jsonb not null,
  eligible_sales_cents bigint not null check (eligible_sales_cents between 0 and 100000000000),
  sales_note text not null check (char_length(sales_note) between 3 and 300),
  share_cents bigint not null check (share_cents >= 0),
  adjustment_cents bigint not null default 0,
  adjustment_note text check (adjustment_note is null or char_length(adjustment_note) between 3 and 300),
  currency text not null default 'cad',
  status text not null default 'estimated' check (status in ('estimated', 'reviewed', 'approved', 'paid', 'disputed')),
  entered_by uuid references auth.users (id) on delete set null,
  entered_at timestamptz not null default clock_timestamp(),
  reviewed_by uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  approved_by uuid references auth.users (id) on delete set null,
  approved_at timestamptz,
  paid_amount_cents bigint check (paid_amount_cents is null or paid_amount_cents >= 0),
  paid_on date,
  payment_reference text check (payment_reference is null or char_length(payment_reference) between 3 and 120),
  payment_evidence text check (payment_evidence is null or char_length(payment_evidence) between 1 and 300),
  paid_recorded_by uuid references auth.users (id) on delete set null,
  paid_recorded_at timestamptz,
  disputed_reason text check (disputed_reason is null or char_length(disputed_reason) between 5 and 500),
  disputed_by uuid references auth.users (id) on delete set null,
  disputed_at timestamptz,
  organizer_ack_by uuid references auth.users (id) on delete set null,
  organizer_ack_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint site_settlements_payable_check check (share_cents + adjustment_cents >= 0),
  constraint site_settlements_adjustment_needs_note check (adjustment_cents = 0 or adjustment_note is not null),
  constraint site_settlements_paid_check check (status <> 'paid' or (paid_amount_cents is not null and paid_on is not null and payment_reference is not null and paid_recorded_at is not null and approved_at is not null)),
  constraint site_settlements_disputed_check check (status <> 'disputed' or (disputed_reason is not null and disputed_at is not null))
);
create unique index site_settlements_one_per_agreement on public.site_settlements (agreement_id);
create index site_settlements_venue_idx on public.site_settlements (venue_id, updated_at desc);
create index site_settlements_org_idx on public.site_settlements (organizer_org_id, updated_at desc);

create table public.site_settlement_log (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.site_settlements (id),
  at timestamptz not null default clock_timestamp(),
  actor uuid references auth.users (id) on delete set null,
  side text not null check (side in ('venue', 'organizer')),
  action text not null check (action in ('sales_saved', 'adjusted', 'reviewed', 'approved', 'payment_recorded', 'questioned', 'resolved', 'acknowledged')),
  from_status text,
  to_status text,
  amount_cents bigint,
  note text check (note is null or char_length(note) <= 500)
);
create index site_settlement_log_idx on public.site_settlement_log (settlement_id, at);

alter table public.site_settlements enable row level security;
alter table public.site_settlement_log enable row level security;
revoke all on table public.site_settlements, public.site_settlement_log from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
create function public.settlement_log_add(p_settlement uuid, p_side text, p_action text, p_from text, p_to text, p_amount bigint, p_note text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.site_settlement_log (settlement_id, actor, side, action, from_status, to_status, amount_cents, note) values (p_settlement, auth.uid(), p_side, p_action, p_from, p_to, p_amount, p_note)
$$;

-- The share of the numbers in [terms]: the base it is worked on (sales above the threshold, or all of them once it is reached) for the screen to show.
create function public.settlement_base(p_terms jsonb, p_sales bigint)
returns bigint
language sql
immutable
set search_path = public
as $$
  select case
    when p_terms ->> 'formula' = 'above_threshold' then greatest(p_sales - coalesce((p_terms ->> 'threshold_cents')::bigint, 0), 0)
    when p_terms ->> 'formula' = 'all_once_reached' then case when p_sales >= coalesce((p_terms ->> 'threshold_cents')::bigint, 0) then p_sales else 0 end
    else 0
  end
$$;

-- ---------------------------------------------------------------------------
-- 3. Lists: one row per agreement that has a share of bar sales to settle (in force with a share, or already settled)
-- ---------------------------------------------------------------------------
create function public.settlements_for_venue(p_venue uuid)
returns table (
  agreement_id uuid, event_id uuid, event_title text, event_start timestamptz, venue_name text, organizer_name text, agreement_status text,
  bar_percent numeric, threshold_cents bigint, formula text,
  settlement_id uuid, status text, eligible_sales_cents bigint, share_cents bigint, adjustment_cents bigint, payable_cents bigint, paid_on date, updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;

  return query
    select a.id, e.id, e.title, e.start_date, v.name, o.name, a.status,
           (coalesce(s.terms, t.terms) ->> 'bar_percent')::numeric, (coalesce(s.terms, t.terms) ->> 'threshold_cents')::bigint, coalesce(s.terms, t.terms) ->> 'formula',
           s.id, s.status, s.eligible_sales_cents, s.share_cents, s.adjustment_cents, s.share_cents + s.adjustment_cents, s.paid_on, s.updated_at
    from public.site_agreements a
    join public.site_events e on e.id = a.event_id
    join public.site_venues v on v.id = a.venue_id
    join public.site_organizations o on o.id = a.organizer_org_id
    left join public.site_settlements s on s.agreement_id = a.id
    left join public.site_agreement_versions t on t.agreement_id = a.id and t.version = a.active_version
    where a.venue_id = p_venue and (s.id is not null or (public.agreement_in_force(a) and coalesce((t.terms ->> 'bar_percent')::numeric, 0) > 0))
    order by e.start_date desc, a.id
    limit 200;
end;
$$;

create function public.settlements_for_organizer(p_org uuid)
returns table (
  agreement_id uuid, event_id uuid, event_title text, event_start timestamptz, venue_name text, organizer_name text, agreement_status text,
  bar_percent numeric, threshold_cents bigint, formula text,
  settlement_id uuid, status text, eligible_sales_cents bigint, share_cents bigint, adjustment_cents bigint, payable_cents bigint, paid_on date, updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_org is null or not public.is_org_member(p_org, array['owner', 'organizer']) then raise exception 'not allowed'; end if;

  return query
    select a.id, e.id, e.title, e.start_date, v.name, o.name, a.status,
           (coalesce(s.terms, t.terms) ->> 'bar_percent')::numeric, (coalesce(s.terms, t.terms) ->> 'threshold_cents')::bigint, coalesce(s.terms, t.terms) ->> 'formula',
           s.id, s.status, s.eligible_sales_cents, s.share_cents, s.adjustment_cents, s.share_cents + s.adjustment_cents, s.paid_on, s.updated_at
    from public.site_agreements a
    join public.site_events e on e.id = a.event_id
    join public.site_venues v on v.id = a.venue_id
    join public.site_organizations o on o.id = a.organizer_org_id
    left join public.site_settlements s on s.agreement_id = a.id
    left join public.site_agreement_versions t on t.agreement_id = a.id and t.version = a.active_version
    where a.organizer_org_id = p_org and (s.id is not null or (public.agreement_in_force(a) and coalesce((t.terms ->> 'bar_percent')::numeric, 0) > 0))
    order by e.start_date desc, a.id
    limit 200;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. One settlement with its calculation, its history, and what the caller can do about it (decided HERE, not in the app)
-- ---------------------------------------------------------------------------
create function public.settlement_detail(p_agreement uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  s public.site_settlements;
  v_terms jsonb;
  v_mgr boolean;
  v_owner boolean;
  v_org boolean;
  v_has boolean;
  v_share boolean;
  v_status text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_agreements x where x.id = p_agreement;
  if not found then raise exception 'not allowed'; end if;
  v_mgr := public.can_access_venue(a.venue_id, array['owner', 'manager']);
  v_owner := public.can_access_venue(a.venue_id, array['owner']);
  v_org := public.can_access_event(a.event_id, array['owner', 'organizer']);
  if not (v_mgr or v_org) then raise exception 'not allowed'; end if;

  select * into s from public.site_settlements x where x.agreement_id = p_agreement;
  v_has := found;
  v_terms := case when v_has then s.terms else (select t.terms from public.site_agreement_versions t where t.agreement_id = a.id and t.version = a.active_version) end;
  v_share := coalesce((v_terms ->> 'bar_percent')::numeric, 0) > 0;
  v_status := case when v_has then s.status end;

  return jsonb_build_object(
    'agreement_id', a.id,
    'side', case when v_mgr then 'venue' else 'organizer' end,
    'event_title', (select e.title from public.site_events e where e.id = a.event_id),
    'event_start', (select e.start_date from public.site_events e where e.id = a.event_id),
    'venue_name', (select v.name from public.site_venues v where v.id = a.venue_id),
    'organizer_name', (select o.name from public.site_organizations o where o.id = a.organizer_org_id),
    'agreement_status', a.status,
    'agreement_version', case when v_has then s.agreement_version else a.active_version end,
    'terms', case when v_terms is null then null else jsonb_build_object(
      'bar_percent', v_terms -> 'bar_percent', 'threshold_cents', v_terms -> 'threshold_cents', 'formula', v_terms -> 'formula', 'eligible_revenue', v_terms -> 'eligible_revenue',
      'refunds', v_terms -> 'refunds', 'taxes_tips_fees', v_terms -> 'taxes_tips_fees', 'settlement_timing', v_terms -> 'settlement_timing') end,
    'has_share', v_share,
    'settlement', case when not v_has then null else jsonb_build_object(
      'id', s.id, 'status', s.status, 'currency', s.currency,
      'eligible_sales_cents', s.eligible_sales_cents, 'sales_note', s.sales_note,
      'base_cents', public.settlement_base(s.terms, s.eligible_sales_cents), 'share_cents', s.share_cents,
      'adjustment_cents', s.adjustment_cents, 'adjustment_note', s.adjustment_note, 'payable_cents', s.share_cents + s.adjustment_cents,
      'entered_at', s.entered_at, 'entered_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = s.entered_by),
      'reviewed_at', s.reviewed_at, 'reviewed_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = s.reviewed_by),
      'approved_at', s.approved_at, 'approved_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = s.approved_by),
      'paid_amount_cents', s.paid_amount_cents, 'paid_on', s.paid_on, 'payment_reference', s.payment_reference, 'payment_evidence', s.payment_evidence,
      'paid_recorded_at', s.paid_recorded_at, 'paid_recorded_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = s.paid_recorded_by),
      'payment_label', case when s.status = 'paid' then 'Recorded external payment' end,
      'disputed_reason', s.disputed_reason, 'disputed_at', s.disputed_at,
      'organizer_ack_at', s.organizer_ack_at, 'organizer_ack_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = s.organizer_ack_by),
      'updated_at', s.updated_at) end,
    'log', case when not v_has then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'at', l.at, 'side', l.side, 'action', l.action, 'from_status', l.from_status, 'to_status', l.to_status, 'amount_cents', l.amount_cents, 'note', l.note,
        'by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = l.actor), 'by_me', l.actor = auth.uid()) order by l.at desc, l.id)
      from public.site_settlement_log l where l.settlement_id = s.id), '[]'::jsonb) end,
    'can', jsonb_build_object(
      'save_sales', v_mgr and v_share and public.agreement_in_force(a) and (not v_has or v_status in ('estimated', 'reviewed')),
      'adjust', v_mgr and v_has and v_status <> 'paid',
      'review', v_mgr and v_status = 'estimated',
      'approve', v_owner and v_status = 'reviewed',
      'record_payment', v_owner and v_status = 'approved',
      'acknowledge', v_org and v_status in ('approved', 'paid') and s.organizer_ack_at is null,
      'question', v_org and v_status in ('estimated', 'reviewed', 'approved'),
      'resolve', v_mgr and v_status = 'disputed'));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The club enters the sales
-- ---------------------------------------------------------------------------
-- Starts the settlement, or changes the sales of one that is still estimated or only reviewed (a reviewed one goes back to estimated). Returns the settlement's id.
create function public.settlement_save_sales(p_agreement uuid, p_eligible_sales_cents bigint, p_note text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  s public.site_settlements;
  v_terms jsonb;
  v_note text;
  v_share bigint;
  v_has boolean;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_agreements x where x.id = p_agreement;
  if not found or not public.can_access_venue(a.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if p_eligible_sales_cents is null or p_eligible_sales_cents < 0 or p_eligible_sales_cents > 100000000000 then raise exception 'enter the eligible bar sales as an amount of 0 or more'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is null or char_length(v_note) < 3 or char_length(v_note) > 300 then raise exception 'say where the figure comes from (3 to 300 characters)'; end if;

  select * into s from public.site_settlements x where x.agreement_id = p_agreement for update;
  v_has := found;
  if v_has and s.status in ('approved', 'paid', 'disputed') then
    raise exception '%', case s.status
      when 'approved' then 'this settlement has been approved: adjust the amount to change it'
      when 'paid' then 'this settlement has been paid'
      else 'the organizer has asked a question: answer it first' end;
  end if;
  if not public.agreement_in_force(a) then raise exception 'this agreement is not active, so there is nothing to settle yet'; end if;
  select t.terms into v_terms from public.site_agreement_versions t where t.agreement_id = a.id and t.version = a.active_version;
  if v_terms is null or coalesce((v_terms ->> 'bar_percent')::numeric, 0) = 0 then raise exception 'this agreement has no share of bar sales to settle'; end if;
  v_share := public.agreement_sample(v_terms, p_eligible_sales_cents);

  if v_has then
    update public.site_settlements set
      terms = v_terms, agreement_version = a.active_version, eligible_sales_cents = p_eligible_sales_cents, sales_note = v_note, share_cents = v_share,
      status = 'estimated', entered_by = auth.uid(), entered_at = clock_timestamp(), reviewed_by = null, reviewed_at = null, updated_at = clock_timestamp()
      where id = s.id;
    v_id := s.id;
    perform public.settlement_log_add(v_id, 'venue', 'sales_saved', s.status, 'estimated', p_eligible_sales_cents, v_note);
  else
    insert into public.site_settlements (agreement_id, agreement_version, event_id, venue_id, organizer_org_id, terms, eligible_sales_cents, sales_note, share_cents, entered_by)
      values (a.id, a.active_version, a.event_id, a.venue_id, a.organizer_org_id, v_terms, p_eligible_sales_cents, v_note, v_share, auth.uid())
      on conflict (agreement_id) do nothing returning id into v_id;
    if v_id is null then raise exception 'someone started this settlement a moment ago: look at it again'; end if;
    perform public.settlement_log_add(v_id, 'venue', 'sales_saved', null, 'estimated', p_eligible_sales_cents, v_note);
  end if;
  return v_id;
end;
$$;

-- A signed change to the amount owed, with a note that is kept ("Later refunds/chargebacks create settlement adjustments with history"). The amount owed never goes below 0. Not after payment.
create function public.settlement_adjust(p_settlement uuid, p_amount_cents bigint, p_note text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_settlements;
  v_note text;
  v_new bigint;
  v_to text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into s from public.site_settlements x where x.id = p_settlement for update;
  if not found or not public.can_access_venue(s.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if s.status = 'paid' then raise exception 'this settlement has been paid: adjustments after payment are not recorded yet'; end if;
  if p_amount_cents is null or p_amount_cents = 0 or abs(p_amount_cents) > 100000000000 then raise exception 'enter the change as a plus or minus amount (not 0)'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is null or char_length(v_note) < 3 or char_length(v_note) > 300 then raise exception 'say why the amount is changing (3 to 300 characters)'; end if;
  v_new := s.adjustment_cents + p_amount_cents;
  if s.share_cents + v_new < 0 then raise exception 'the amount owed cannot go below zero'; end if;

  v_to := case when s.status in ('reviewed', 'approved') then 'estimated' else s.status end;
  update public.site_settlements set adjustment_cents = v_new, adjustment_note = v_note, status = v_to,
    reviewed_by = case when v_to = 'estimated' then null else reviewed_by end, reviewed_at = case when v_to = 'estimated' then null else reviewed_at end,
    approved_by = case when v_to = 'estimated' then null else approved_by end, approved_at = case when v_to = 'estimated' then null else approved_at end,
    updated_at = clock_timestamp()
    where id = s.id;
  perform public.settlement_log_add(s.id, 'venue', 'adjusted', s.status, v_to, p_amount_cents, v_note);
  return s.share_cents + v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Review, approval and the payment record
-- ---------------------------------------------------------------------------
create function public.settlement_review(p_settlement uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_settlements;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into s from public.site_settlements x where x.id = p_settlement for update;
  if not found or not public.can_access_venue(s.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if s.status <> 'estimated' then raise exception 'only an estimated settlement can be reviewed'; end if;
  update public.site_settlements set status = 'reviewed', reviewed_by = auth.uid(), reviewed_at = clock_timestamp(), updated_at = clock_timestamp() where id = s.id;
  perform public.settlement_log_add(s.id, 'venue', 'reviewed', 'estimated', 'reviewed', s.share_cents + s.adjustment_cents, null);
  return 'reviewed';
end;
$$;

create function public.settlement_approve(p_settlement uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_settlements;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into s from public.site_settlements x where x.id = p_settlement for update;
  if not found or not public.can_access_venue(s.venue_id, array['owner']) then raise exception 'not allowed'; end if;
  if s.status <> 'reviewed' then raise exception 'only a reviewed settlement can be approved'; end if;
  update public.site_settlements set status = 'approved', approved_by = auth.uid(), approved_at = clock_timestamp(), updated_at = clock_timestamp() where id = s.id;
  perform public.settlement_log_add(s.id, 'venue', 'approved', 'reviewed', 'approved', s.share_cents + s.adjustment_cents, null);
  return 'approved';
end;
$$;

-- Records a payment that was made outside BottlesUp. The amount has to be exactly what was approved; nothing is sent anywhere.
create function public.settlement_record_payment(p_settlement uuid, p_amount_cents bigint, p_paid_on date, p_reference text, p_evidence text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_settlements;
  v_ref text;
  v_evidence text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into s from public.site_settlements x where x.id = p_settlement for update;
  if not found or not public.can_access_venue(s.venue_id, array['owner']) then raise exception 'not allowed'; end if;
  if s.status <> 'approved' then raise exception 'only an approved settlement can have its payment recorded'; end if;
  if p_amount_cents is distinct from s.share_cents + s.adjustment_cents then raise exception 'the amount has to be exactly what was approved: %', s.share_cents + s.adjustment_cents; end if;
  if p_paid_on is null or p_paid_on > current_date + 1 then raise exception 'choose the date it was paid (not in the future)'; end if;
  v_ref := nullif(btrim(p_reference), '');
  if v_ref is null or char_length(v_ref) < 3 or char_length(v_ref) > 120 then raise exception 'enter a reference for the payment (3 to 120 characters)'; end if;
  v_evidence := nullif(btrim(p_evidence), '');
  if v_evidence is not null and char_length(v_evidence) > 300 then raise exception 'keep the evidence note to 300 characters or fewer'; end if;

  update public.site_settlements set status = 'paid', paid_amount_cents = p_amount_cents, paid_on = p_paid_on, payment_reference = v_ref, payment_evidence = v_evidence,
    paid_recorded_by = auth.uid(), paid_recorded_at = clock_timestamp(), updated_at = clock_timestamp()
    where id = s.id;
  perform public.settlement_log_add(s.id, 'venue', 'payment_recorded', 'approved', 'paid', p_amount_cents, 'Recorded external payment: ' || v_ref);
  return 'paid';
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. The organizer questions or acknowledges; the club answers
-- ---------------------------------------------------------------------------
create function public.settlement_question(p_settlement uuid, p_reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_settlements;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into s from public.site_settlements x where x.id = p_settlement for update;
  if not found or not public.can_access_event(s.event_id, array['owner', 'organizer']) then raise exception 'not allowed'; end if;
  if s.status not in ('estimated', 'reviewed', 'approved') then raise exception '%', case s.status when 'paid' then 'this settlement has been paid' else 'a question is already open' end; end if;
  v_reason := nullif(btrim(p_reason), '');
  if v_reason is null or char_length(v_reason) < 5 or char_length(v_reason) > 500 then raise exception 'say what you are asking (5 to 500 characters)'; end if;
  update public.site_settlements set status = 'disputed', disputed_reason = v_reason, disputed_by = auth.uid(), disputed_at = clock_timestamp(),
    reviewed_by = null, reviewed_at = null, approved_by = null, approved_at = null, organizer_ack_by = null, organizer_ack_at = null, updated_at = clock_timestamp()
    where id = s.id;
  perform public.settlement_log_add(s.id, 'organizer', 'questioned', s.status, 'disputed', null, v_reason);
  return 'disputed';
end;
$$;

create function public.settlement_resolve(p_settlement uuid, p_note text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_settlements;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into s from public.site_settlements x where x.id = p_settlement for update;
  if not found or not public.can_access_venue(s.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if s.status <> 'disputed' then raise exception 'there is no open question'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is null or char_length(v_note) < 3 or char_length(v_note) > 500 then raise exception 'write your answer (3 to 500 characters)'; end if;
  update public.site_settlements set status = 'estimated', disputed_reason = null, disputed_by = null, disputed_at = null, updated_at = clock_timestamp() where id = s.id;
  perform public.settlement_log_add(s.id, 'venue', 'resolved', 'disputed', 'estimated', null, v_note);
  return 'estimated';
end;
$$;

-- The organizer says they have seen the approved (or paid) settlement. Returns whether anything changed.
create function public.settlement_acknowledge(p_settlement uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_settlements;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into s from public.site_settlements x where x.id = p_settlement for update;
  if not found or not public.can_access_event(s.event_id, array['owner', 'organizer']) then raise exception 'not allowed'; end if;
  if s.status not in ('approved', 'paid') then raise exception 'there is nothing to acknowledge until it has been approved'; end if;
  if s.organizer_ack_at is not null then return false; end if;
  update public.site_settlements set organizer_ack_by = auth.uid(), organizer_ack_at = clock_timestamp(), updated_at = clock_timestamp() where id = s.id;
  perform public.settlement_log_add(s.id, 'organizer', 'acknowledged', s.status, s.status, s.share_cents + s.adjustment_cents, null);
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.settlement_log_add(uuid, text, text, text, text, bigint, text), public.settlement_base(jsonb, bigint) from public, anon, authenticated;
revoke all on function
  public.settlements_for_venue(uuid), public.settlements_for_organizer(uuid), public.settlement_detail(uuid), public.settlement_save_sales(uuid, bigint, text), public.settlement_adjust(uuid, bigint, text),
  public.settlement_review(uuid), public.settlement_approve(uuid), public.settlement_record_payment(uuid, bigint, date, text, text), public.settlement_question(uuid, text),
  public.settlement_resolve(uuid, text), public.settlement_acknowledge(uuid)
  from public, anon;
grant execute on function
  public.settlements_for_venue(uuid), public.settlements_for_organizer(uuid), public.settlement_detail(uuid), public.settlement_save_sales(uuid, bigint, text), public.settlement_adjust(uuid, bigint, text),
  public.settlement_review(uuid), public.settlement_approve(uuid), public.settlement_record_payment(uuid, bigint, date, text, text), public.settlement_question(uuid, text),
  public.settlement_resolve(uuid, text), public.settlement_acknowledge(uuid)
  to authenticated, service_role;
