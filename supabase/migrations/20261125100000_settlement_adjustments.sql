-- Adjustments AFTER a settlement was paid (client Phase 2 brief, section 25: "Later refunds/chargebacks create settlement adjustments with history"; section 26: "possible settlement adjustment";
-- completion scenario 23: "Refund after settlement: original records retained; refund and settlement adjustment visible"). RECORD ONLY, like the settlement itself: nothing here moves money,
-- calls a payment provider or pays anyone. Before payment the amount is still changed with settlement_adjust (20261122120000); this is for the case that function refuses, a paid settlement.
--
-- THE ORIGINAL IS NEVER TOUCHED. A paid settlement (its sales, its terms, its share, its payment record) is not changed by anything below. An adjustment is a separate, signed record kept beside
-- it, and a mistake is put right by a second, opposite adjustment (a "correction"), never by editing or deleting the first. The net amount owed to the organizer after adjustments is
-- worked out when it is read: what was paid, plus the adjustments.
--
--   SIGN: plus = the club owes the organizer MORE (for example a chargeback was won back); minus = the organizer was paid too much (for example a bottle sold in the eligible sales was later
--   refunded). A refund or a chargeback is always a minus; only a correction may add. The net can never go below zero: nothing can take back more than was paid.
--   WHAT IT LINKS TO: a reference the club types (the refund's reference, the chargeback's case number). It is NOT a link to a refund row: a refund of a table booking is not part of the
--   organizer's bar share (the settlement is bar sales only), and a bar-sale refund has no record of its own to point at, so the club says which refund it is and why.
--
--   WHO MAY DO WHAT (a policy assumption, easy to change in the functions below):
--     * the club's OWNER only: record an adjustment, record the payment that settles it, or waive an amount the organizer owes the club
--     * the club's manager or owner: answer the organizer's question
--     * the organizer's business: read, acknowledge, or QUESTION an adjustment that is still open (with a reason). Never record, settle, waive or change one.
--     * the club's manager can read them
--   STATUSES: open -> settled (the owner records the payment made outside BottlesUp, exactly the adjusted amount, with a date and a reference) or waived (the club chooses not to recover a MINUS
--   amount; a plus amount, owed to the organizer, cannot be waived by the club), and disputed (the organizer's question; the club answers and it goes back to open). Settled and waived are final.
--   NO CARRY-FORWARD: an adjustment is not taken off the organizer's next settlement (a different event, a different agreement). It is settled, or waived, on its own.
--   LIMITS: at most 50 adjustments per settlement. Every step is in a history that cannot be edited.
--
-- Closed tables, reached only through the functions. Plain CREATE, never CREATE OR REPLACE. Needs the organizer settlements (20261122120000_organizer_settlements).

do $pre$
declare
  r record;
begin
  for r in select * from (values
      ('public.can_access_venue(uuid, text[])'), ('public.can_access_event(uuid, text[])'), ('public.is_org_member(uuid, text[])'), ('public.settlement_detail(uuid)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
  if to_regclass('public.site_settlements') is null then raise exception 'public.site_settlements does not exist: run migration 20261122120000 first. Nothing was changed.'; end if;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. Tables (closed: written only by the functions below)
-- ---------------------------------------------------------------------------
create table public.site_settlement_adjustments (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.site_settlements (id),
  kind text not null check (kind in ('refund', 'chargeback', 'correction')),
  amount_cents bigint not null check (amount_cents <> 0 and abs(amount_cents) <= 100000000000),
  reason text not null check (char_length(reason) between 3 and 300),
  source_ref text check (source_ref is null or char_length(source_ref) between 3 and 120),
  status text not null default 'open' check (status in ('open', 'disputed', 'settled', 'waived')),
  recorded_by uuid references auth.users (id) on delete set null,
  recorded_at timestamptz not null default clock_timestamp(),
  disputed_reason text check (disputed_reason is null or char_length(disputed_reason) between 5 and 500),
  disputed_by uuid references auth.users (id) on delete set null,
  disputed_at timestamptz,
  organizer_ack_by uuid references auth.users (id) on delete set null,
  organizer_ack_at timestamptz,
  resolved_amount_cents bigint check (resolved_amount_cents is null or resolved_amount_cents > 0),
  resolved_on date,
  resolution_reference text check (resolution_reference is null or char_length(resolution_reference) between 3 and 120),
  resolution_note text check (resolution_note is null or char_length(resolution_note) between 1 and 300),
  resolved_by uuid references auth.users (id) on delete set null,
  resolved_at timestamptz,
  updated_at timestamptz not null default clock_timestamp(),
  constraint site_settlement_adjustments_sign_check check (kind = 'correction' or amount_cents < 0),
  constraint site_settlement_adjustments_disputed_check check (status <> 'disputed' or (disputed_reason is not null and disputed_at is not null)),
  constraint site_settlement_adjustments_settled_check check (status <> 'settled' or (resolved_amount_cents = abs(amount_cents) and resolved_on is not null and resolution_reference is not null and resolved_at is not null)),
  constraint site_settlement_adjustments_waived_check check (status <> 'waived' or (amount_cents < 0 and resolution_note is not null and resolved_at is not null))
);
create index site_settlement_adjustments_settlement_idx on public.site_settlement_adjustments (settlement_id, recorded_at desc);

create table public.site_settlement_adjustment_log (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.site_settlements (id),
  adjustment_id uuid not null references public.site_settlement_adjustments (id),
  at timestamptz not null default clock_timestamp(),
  actor uuid references auth.users (id) on delete set null,
  side text not null check (side in ('venue', 'organizer')),
  action text not null check (action in ('recorded', 'acknowledged', 'questioned', 'answered', 'settled', 'waived')),
  from_status text,
  to_status text,
  amount_cents bigint,
  note text check (note is null or char_length(note) <= 500)
);
create index site_settlement_adjustment_log_idx on public.site_settlement_adjustment_log (settlement_id, at);

alter table public.site_settlement_adjustments enable row level security;
alter table public.site_settlement_adjustment_log enable row level security;
revoke all on table public.site_settlement_adjustments, public.site_settlement_adjustment_log from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helper (the app cannot call it)
-- ---------------------------------------------------------------------------
create function public.settlement_adjustment_log_add(p_adjustment uuid, p_settlement uuid, p_side text, p_action text, p_from text, p_to text, p_amount bigint, p_note text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.site_settlement_adjustment_log (adjustment_id, settlement_id, actor, side, action, from_status, to_status, amount_cents, note)
    values (p_adjustment, p_settlement, auth.uid(), p_side, p_action, p_from, p_to, p_amount, p_note)
$$;

-- ---------------------------------------------------------------------------
-- 3. Reading: the adjustments of one settlement, the totals, the history, and what the caller can do about each (decided HERE, not in the app)
-- ---------------------------------------------------------------------------
create function public.settlement_adjustments(p_agreement uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a public.site_agreements;
  s public.site_settlements;
  v_mgr boolean;
  v_owner boolean;
  v_org boolean;
  v_has boolean;
  v_count int;
  v_total bigint;
  v_open_to_org bigint;
  v_open_to_club bigint;
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
  if not v_has or s.status <> 'paid' then
    return jsonb_build_object('agreement_id', a.id, 'settlement_id', case when v_has then s.id end, 'side', case when v_mgr then 'venue' else 'organizer' end, 'applies', false,
      'items', '[]'::jsonb, 'log', '[]'::jsonb, 'can', jsonb_build_object('record', false));
  end if;

  select count(*), coalesce(sum(x.amount_cents), 0),
         coalesce(sum(x.amount_cents) filter (where x.status in ('open', 'disputed') and x.amount_cents > 0), 0),
         coalesce(-(sum(x.amount_cents) filter (where x.status in ('open', 'disputed') and x.amount_cents < 0)), 0)
    into v_count, v_total, v_open_to_org, v_open_to_club from public.site_settlement_adjustments x where x.settlement_id = s.id;

  return jsonb_build_object(
    'agreement_id', a.id,
    'settlement_id', s.id,
    'side', case when v_mgr then 'venue' else 'organizer' end,
    'applies', true,
    'currency', s.currency,
    'paid_amount_cents', s.paid_amount_cents,
    'paid_on', s.paid_on,
    'count', v_count,
    'adjustments_cents', v_total,
    'net_cents', s.paid_amount_cents + v_total,
    'open_to_organizer_cents', v_open_to_org,
    'open_to_club_cents', v_open_to_club,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', x.id, 'kind', x.kind, 'amount_cents', x.amount_cents,
        'direction', case when x.amount_cents < 0 then 'organizer_owes_club' else 'club_owes_organizer' end,
        'reason', x.reason, 'source_ref', x.source_ref, 'status', x.status,
        'recorded_at', x.recorded_at, 'recorded_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = x.recorded_by),
        'disputed_reason', x.disputed_reason, 'disputed_at', x.disputed_at,
        'organizer_ack_at', x.organizer_ack_at, 'organizer_ack_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = x.organizer_ack_by),
        'resolved_amount_cents', x.resolved_amount_cents, 'resolved_on', x.resolved_on, 'resolution_reference', x.resolution_reference, 'resolution_note', x.resolution_note,
        'resolved_at', x.resolved_at, 'resolved_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = x.resolved_by),
        'resolution_label', case x.status when 'settled' then 'Recorded external payment' when 'waived' then 'Not recovered' end,
        'can', jsonb_build_object(
          'acknowledge', v_org and x.status in ('open', 'settled', 'waived') and x.organizer_ack_at is null,
          'question', v_org and x.status = 'open',
          'answer', v_mgr and x.status = 'disputed',
          'settle', v_owner and x.status = 'open',
          'waive', v_owner and x.status = 'open' and x.amount_cents < 0)) order by x.recorded_at desc, x.id)
      from public.site_settlement_adjustments x where x.settlement_id = s.id), '[]'::jsonb),
    'log', coalesce((
      select jsonb_agg(jsonb_build_object(
        'adjustment_id', l.adjustment_id, 'at', l.at, 'side', l.side, 'action', l.action, 'from_status', l.from_status, 'to_status', l.to_status, 'amount_cents', l.amount_cents, 'note', l.note,
        'by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = l.actor), 'by_me', l.actor = auth.uid()) order by l.at desc, l.id)
      from public.site_settlement_adjustment_log l where l.settlement_id = s.id), '[]'::jsonb),
    'can', jsonb_build_object('record', v_owner and v_count < 50));
end;
$$;

-- For the two lists: which agreements have adjustments after payment, how many are still open, and what is still to be settled in each direction (never netted: what the club still owes
-- the organizer, and what the organizer still owes the club). One row per settlement that has any.
create function public.settlement_adjustment_flags_for_venue(p_venue uuid)
returns table (agreement_id uuid, adjustment_count int, open_count int, open_to_organizer_cents bigint, open_to_club_cents bigint)
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
    select s.agreement_id, count(*)::int, (count(*) filter (where x.status in ('open', 'disputed')))::int,
           coalesce(sum(x.amount_cents) filter (where x.status in ('open', 'disputed') and x.amount_cents > 0), 0)::bigint,
           coalesce(-(sum(x.amount_cents) filter (where x.status in ('open', 'disputed') and x.amount_cents < 0)), 0)::bigint
      from public.site_settlement_adjustments x join public.site_settlements s on s.id = x.settlement_id
     where s.venue_id = p_venue group by s.agreement_id order by s.agreement_id;
end;
$$;

create function public.settlement_adjustment_flags_for_organizer(p_org uuid)
returns table (agreement_id uuid, adjustment_count int, open_count int, open_to_organizer_cents bigint, open_to_club_cents bigint)
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
    select s.agreement_id, count(*)::int, (count(*) filter (where x.status in ('open', 'disputed')))::int,
           coalesce(sum(x.amount_cents) filter (where x.status in ('open', 'disputed') and x.amount_cents > 0), 0)::bigint,
           coalesce(-(sum(x.amount_cents) filter (where x.status in ('open', 'disputed') and x.amount_cents < 0)), 0)::bigint
      from public.site_settlement_adjustments x join public.site_settlements s on s.id = x.settlement_id
     where s.organizer_org_id = p_org group by s.agreement_id order by s.agreement_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The club's owner records an adjustment
-- ---------------------------------------------------------------------------
create function public.settlement_adjustment_record(p_settlement uuid, p_kind text, p_amount_cents bigint, p_reason text, p_ref text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_settlements;
  v_reason text;
  v_ref text;
  v_id uuid;
  v_count int;
  v_total bigint;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into s from public.site_settlements x where x.id = p_settlement for update;
  if not found or not public.can_access_venue(s.venue_id, array['owner']) then raise exception 'not allowed'; end if;
  if s.status <> 'paid' then raise exception 'only a settlement that has been paid takes adjustments after payment: until then, adjust the amount owed'; end if;
  if p_kind is null or p_kind not in ('refund', 'chargeback', 'correction') then raise exception 'say what the adjustment is for: a refund, a chargeback or a correction'; end if;
  if p_amount_cents is null or p_amount_cents = 0 or abs(p_amount_cents) > 100000000000 then raise exception 'enter the change as a plus or minus amount (not 0)'; end if;
  if p_kind in ('refund', 'chargeback') and p_amount_cents > 0 then raise exception 'a refund or a chargeback takes money off what the organizer is owed: enter a minus amount (a correction can add)'; end if;
  v_reason := nullif(btrim(p_reason), '');
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 300 then raise exception 'say why (3 to 300 characters)'; end if;
  v_ref := nullif(btrim(p_ref), '');
  if v_ref is not null and (char_length(v_ref) < 3 or char_length(v_ref) > 120) then raise exception 'keep the reference to 3 to 120 characters'; end if;
  select count(*), coalesce(sum(x.amount_cents), 0) into v_count, v_total from public.site_settlement_adjustments x where x.settlement_id = s.id;
  if v_count >= 50 then raise exception 'this settlement already has 50 adjustments after payment'; end if;
  if s.paid_amount_cents + v_total + p_amount_cents < 0 then raise exception 'the adjustments cannot take back more than was paid'; end if;

  insert into public.site_settlement_adjustments (settlement_id, kind, amount_cents, reason, source_ref, recorded_by) values (s.id, p_kind, p_amount_cents, v_reason, v_ref, auth.uid()) returning id into v_id;
  perform public.settlement_adjustment_log_add(v_id, s.id, 'venue', 'recorded', null, 'open', p_amount_cents, p_kind || ': ' || v_reason);
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The organizer questions or acknowledges; the club answers
-- ---------------------------------------------------------------------------
create function public.settlement_adjustment_question(p_adjustment uuid, p_reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.site_settlement_adjustments;
  s public.site_settlements;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into x from public.site_settlement_adjustments y where y.id = p_adjustment for update;
  if not found then raise exception 'not allowed'; end if;
  select * into s from public.site_settlements z where z.id = x.settlement_id;
  if not public.can_access_event(s.event_id, array['owner', 'organizer']) then raise exception 'not allowed'; end if;
  if x.status <> 'open' then raise exception '%', case x.status when 'disputed' then 'a question is already open' else 'this adjustment has already been dealt with' end; end if;
  v_reason := nullif(btrim(p_reason), '');
  if v_reason is null or char_length(v_reason) < 5 or char_length(v_reason) > 500 then raise exception 'say what you are asking (5 to 500 characters)'; end if;
  update public.site_settlement_adjustments set status = 'disputed', disputed_reason = v_reason, disputed_by = auth.uid(), disputed_at = clock_timestamp(),
    organizer_ack_by = null, organizer_ack_at = null, updated_at = clock_timestamp() where id = x.id;
  perform public.settlement_adjustment_log_add(x.id, s.id, 'organizer', 'questioned', 'open', 'disputed', null, v_reason);
  return 'disputed';
end;
$$;

create function public.settlement_adjustment_answer(p_adjustment uuid, p_note text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.site_settlement_adjustments;
  s public.site_settlements;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into x from public.site_settlement_adjustments y where y.id = p_adjustment for update;
  if not found then raise exception 'not allowed'; end if;
  select * into s from public.site_settlements z where z.id = x.settlement_id;
  if not public.can_access_venue(s.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if x.status <> 'disputed' then raise exception 'there is no open question'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is null or char_length(v_note) < 3 or char_length(v_note) > 500 then raise exception 'write your answer (3 to 500 characters)'; end if;
  update public.site_settlement_adjustments set status = 'open', disputed_reason = null, disputed_by = null, disputed_at = null, updated_at = clock_timestamp() where id = x.id;
  perform public.settlement_adjustment_log_add(x.id, s.id, 'venue', 'answered', 'disputed', 'open', null, v_note);
  return 'open';
end;
$$;

-- The organizer says they have seen it. Returns whether anything changed.
create function public.settlement_adjustment_acknowledge(p_adjustment uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.site_settlement_adjustments;
  s public.site_settlements;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into x from public.site_settlement_adjustments y where y.id = p_adjustment for update;
  if not found then raise exception 'not allowed'; end if;
  select * into s from public.site_settlements z where z.id = x.settlement_id;
  if not public.can_access_event(s.event_id, array['owner', 'organizer']) then raise exception 'not allowed'; end if;
  if x.status = 'disputed' then raise exception 'there is nothing to acknowledge while a question is open'; end if;
  if x.organizer_ack_at is not null then return false; end if;
  update public.site_settlement_adjustments set organizer_ack_by = auth.uid(), organizer_ack_at = clock_timestamp(), updated_at = clock_timestamp() where id = x.id;
  perform public.settlement_adjustment_log_add(x.id, s.id, 'organizer', 'acknowledged', x.status, x.status, x.amount_cents, null);
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Closing an adjustment: the payment that settles it (made OUTSIDE BottlesUp) or a waiver
-- ---------------------------------------------------------------------------
create function public.settlement_adjustment_settle(p_adjustment uuid, p_amount_cents bigint, p_paid_on date, p_reference text, p_evidence text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.site_settlement_adjustments;
  s public.site_settlements;
  v_ref text;
  v_evidence text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into x from public.site_settlement_adjustments y where y.id = p_adjustment for update;
  if not found then raise exception 'not allowed'; end if;
  select * into s from public.site_settlements z where z.id = x.settlement_id;
  if not public.can_access_venue(s.venue_id, array['owner']) then raise exception 'not allowed'; end if;
  if x.status <> 'open' then raise exception '%', case x.status when 'disputed' then 'the organizer has asked a question: answer it first' else 'this adjustment has already been dealt with' end; end if;
  if p_amount_cents is distinct from abs(x.amount_cents) then raise exception 'the amount has to be exactly the adjustment: %', abs(x.amount_cents); end if;
  if p_paid_on is null or p_paid_on > current_date + 1 then raise exception 'choose the date it was paid (not in the future)'; end if;
  v_ref := nullif(btrim(p_reference), '');
  if v_ref is null or char_length(v_ref) < 3 or char_length(v_ref) > 120 then raise exception 'enter a reference for the payment (3 to 120 characters)'; end if;
  v_evidence := nullif(btrim(p_evidence), '');
  if v_evidence is not null and char_length(v_evidence) > 300 then raise exception 'keep the evidence note to 300 characters or fewer'; end if;

  update public.site_settlement_adjustments set status = 'settled', resolved_amount_cents = abs(x.amount_cents), resolved_on = p_paid_on, resolution_reference = v_ref, resolution_note = v_evidence,
    resolved_by = auth.uid(), resolved_at = clock_timestamp(), updated_at = clock_timestamp() where id = x.id;
  perform public.settlement_adjustment_log_add(x.id, s.id, 'venue', 'settled', 'open', 'settled', abs(x.amount_cents), 'Recorded external payment: ' || v_ref);
  return 'settled';
end;
$$;

create function public.settlement_adjustment_waive(p_adjustment uuid, p_reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.site_settlement_adjustments;
  s public.site_settlements;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into x from public.site_settlement_adjustments y where y.id = p_adjustment for update;
  if not found then raise exception 'not allowed'; end if;
  select * into s from public.site_settlements z where z.id = x.settlement_id;
  if not public.can_access_venue(s.venue_id, array['owner']) then raise exception 'not allowed'; end if;
  if x.status <> 'open' then raise exception '%', case x.status when 'disputed' then 'the organizer has asked a question: answer it first' else 'this adjustment has already been dealt with' end; end if;
  if x.amount_cents > 0 then raise exception 'an amount owed to the organizer cannot be waived: record the payment, or a correction if it was a mistake'; end if;
  v_reason := nullif(btrim(p_reason), '');
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 300 then raise exception 'say why it is not being recovered (3 to 300 characters)'; end if;

  update public.site_settlement_adjustments set status = 'waived', resolution_note = v_reason, resolved_by = auth.uid(), resolved_at = clock_timestamp(), updated_at = clock_timestamp() where id = x.id;
  perform public.settlement_adjustment_log_add(x.id, s.id, 'venue', 'waived', 'open', 'waived', abs(x.amount_cents), v_reason);
  return 'waived';
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.settlement_adjustment_log_add(uuid, uuid, text, text, text, text, bigint, text) from public, anon, authenticated;
revoke all on function
  public.settlement_adjustments(uuid), public.settlement_adjustment_flags_for_venue(uuid), public.settlement_adjustment_flags_for_organizer(uuid),
  public.settlement_adjustment_record(uuid, text, bigint, text, text), public.settlement_adjustment_question(uuid, text), public.settlement_adjustment_answer(uuid, text),
  public.settlement_adjustment_acknowledge(uuid), public.settlement_adjustment_settle(uuid, bigint, date, text, text), public.settlement_adjustment_waive(uuid, text)
  from public, anon;
grant execute on function
  public.settlement_adjustments(uuid), public.settlement_adjustment_flags_for_venue(uuid), public.settlement_adjustment_flags_for_organizer(uuid),
  public.settlement_adjustment_record(uuid, text, bigint, text, text), public.settlement_adjustment_question(uuid, text), public.settlement_adjustment_answer(uuid, text),
  public.settlement_adjustment_acknowledge(uuid), public.settlement_adjustment_settle(uuid, bigint, date, text, text), public.settlement_adjustment_waive(uuid, text)
  to authenticated, service_role;
