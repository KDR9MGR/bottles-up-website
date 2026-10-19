-- Payments taken at the club, their evidence, and the manager's "Tonight" numbers, for the membership model.
--
-- Client Phase 2 brief, section 15: "External card/cash: record final billed amount, amount collected, method, collector, time,
-- transaction reference where available and clear receipt evidence captured inside the platform", "Display external entry as
-- Recorded - verification pending ... A photo alone does not automatically verify payment", "Prevent self-verification; another
-- authorized reviewer handles the reviewer's own entries", "Corrections and refunds create traceable records, not deletion of
-- original payments", "Evidence is linked to the order and visible only to authorized roles". Section 6: "Needs Attention first ...
-- Tapping a count opens its filtered queue".
--
-- WHY NEW FUNCTIONS: production's record_club_payment / manager_verify_club_payment / list_club_payments authorize through the global
-- `door_staff` and `cms_admins` tables, so an invited server, verifier or club manager is refused. Read on 14 Oct 2026 they also:
--   * accept any door_staff row for ANY booking at ANY club (no club check), and ignore door_staff.can_record_payments;
--   * let the person who recorded a payment verify it, and overwrite an earlier verification;
--   * let a receipt be filed under any path.
-- These functions do the same job for the membership model with those gaps closed. The old ones are left exactly as they are.
--
-- WHO MAY DO WHAT (at THAT club only):
--   record a payment .... the owner/manager, or the server the booking was given to. A server must attach a receipt photo; a manager
--                         may record without one by writing why (cash without a printed receipt).
--   see a table's money . the owner/manager, the server it was given to, and a verifier.
--   verify a payment .... the owner/manager or a verifier, but never the person who recorded it; once only.
--   the numbers ......... the owner/manager.
--
-- WHAT THIS DOES NOT DO (decisions still open with the client / not built): flag a payment, cash handover between server and cashier,
-- corrections, refunds, and settling a customer's dispute. A payment is verified or it stays "Recorded - verification pending".
--
-- Needs 20261014120000 (desk_booking_level). Plain CREATE, never CREATE OR REPLACE.

do $$
declare
  missing text;
begin
  select string_agg(x.t || '.' || x.c, ', ' order by x.t, x.c) into missing
  from (values
    ('site_table_booking_club_payments', 'billed_amount_cents'), ('site_table_booking_club_payments', 'amount_paid_cents'),
    ('site_table_booking_club_payments', 'payment_method'), ('site_table_booking_club_payments', 'split_breakdown'),
    ('site_table_booking_club_payments', 'pos_reference'), ('site_table_booking_club_payments', 'recorded_at'),
    ('site_table_booking_club_payments', 'customer_confirmation_status'), ('site_table_booking_club_payments', 'dispute_reason'),
    ('site_table_booking_club_payments', 'payer_name'), ('site_table_booking_club_payments', 'payer_email'),
    ('site_table_booking_club_payments', 'manager_verified_by'), ('site_table_booking_club_payments', 'manager_verified_note'),
    ('site_table_booking_club_payments', 'corrects_payment_id'), ('site_table_booking_club_payments', 'bottle_subtotal_cents'),
    ('site_table_booking_club_payments', 'discount_cents'), ('site_table_booking_club_payments', 'tax_cents'),
    ('site_table_booking_club_payments', 'gratuity_cents'), ('site_table_booking_club_payments', 'receipt_photo_hash'),
    ('site_table_booking_club_payments', 'device_id'), ('site_table_booking_club_payments', 'missing_receipt_reason'),
    ('site_table_bookings', 'amount_paid_cents'), ('site_table_bookings', 'reconciled_at'),
    ('site_table_bookings', 'closeout_requested_at'), ('site_table_bookings', 'discount_cents')
  ) as x(t, c)
  where not exists (
    select 1 from information_schema.columns k
    where k.table_schema = 'public' and k.table_name = x.t and k.column_name = x.c
  );
  if missing is not null then
    raise exception 'this migration needs columns that exist only in production (%). Run "supabase db pull" first.', missing;
  end if;
  if not exists (select 1 from storage.buckets where id = 'club-payment-receipts') then
    raise exception 'this migration needs the "club-payment-receipts" storage bucket, which exists only in production. Run "supabase db pull" first.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Where a receipt photo lives
-- ---------------------------------------------------------------------------
-- A receipt is stored as <booking id>/<anything>. The booking in the first segment is what decides who may read or add it, so a
-- photo is always tied to one booking. null when the name does not start with a booking id.
create function public.receipt_booking(p_name text)
returns uuid
language sql
immutable
set search_path = public
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/.'
    then split_part(p_name, '/', 1)::uuid
  end
$$;

create policy "desk staff read club payment receipts" on storage.objects
  for select to authenticated
  using (bucket_id = 'club-payment-receipts' and public.desk_booking_level(public.receipt_booking(name)) is not null);
create policy "desk staff add club payment receipts" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'club-payment-receipts' and public.desk_booking_level(public.receipt_booking(name)) in ('manager', 'server'));

-- ---------------------------------------------------------------------------
-- 2. A table's money
-- ---------------------------------------------------------------------------
-- What the table was charged, what has been collected, what is still due, and every payment recorded for it. The owner/manager, the
-- server the table was given to, and a verifier. Payer email is never sent: this app has no use for it.
-- verification is one of: pending ("Recorded - verification pending"), verified (a manager or verifier checked it), customer_confirmed
-- (the customer said so; the venue has not checked it), disputed.
create function public.desk_booking_money(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
  v_b record;
  v_payments jsonb;
begin
  v_level := public.desk_booking_level(p_booking);
  if v_level is null then raise exception 'not allowed'; end if;

  select b.confirmation_code, b.customer_name, b.guest_count, b.currency, b.status, b.amount_total_cents, b.amount_paid_cents,
         b.deposit_cents, b.bottle_subtotal_cents, b.tax_cents, b.bottlesup_fee_cents, b.discount_cents,
         b.reconciled_at, b.closeout_requested_at, t.name as table_name
    into v_b
    from public.site_table_bookings b join public.site_table_types t on t.id = b.table_type_id
    where b.id = p_booking;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', cp.id,
           'billed_amount_cents', cp.billed_amount_cents,
           'amount_paid_cents', cp.amount_paid_cents,
           'payment_method', cp.payment_method,
           'split_breakdown', cp.split_breakdown,
           'pos_reference', cp.pos_reference,
           'receipt_photo_path', cp.receipt_photo_path,
           'missing_receipt_reason', cp.missing_receipt_reason,
           'payer_name', cp.payer_name,
           'recorded_at', cp.recorded_at,
           'recorded_by_me', cp.recorded_by is not null and cp.recorded_by = auth.uid(),
           'bottle_subtotal_cents', cp.bottle_subtotal_cents,
           'discount_cents', cp.discount_cents,
           'tax_cents', cp.tax_cents,
           'gratuity_cents', cp.gratuity_cents,
           'corrects_payment_id', cp.corrects_payment_id,
           'customer_confirmation_status', cp.customer_confirmation_status,
           'manager_verified_at', cp.manager_verified_at,
           'manager_verified_note', cp.manager_verified_note,
           'verification', case
              when cp.customer_confirmation_status = 'disputed' then 'disputed'
              when cp.manager_verified_at is not null then 'verified'
              when cp.customer_confirmation_status = 'confirmed' then 'customer_confirmed'
              else 'pending'
           end
         ) order by cp.recorded_at, cp.id), '[]'::jsonb)
    into v_payments
    from public.site_table_booking_club_payments cp
    where cp.booking_id = p_booking;

  return jsonb_build_object(
    'level', v_level,
    'confirmation_code', v_b.confirmation_code,
    'customer_name', v_b.customer_name,
    'table_name', v_b.table_name,
    'guest_count', v_b.guest_count,
    'currency', v_b.currency,
    'status', v_b.status,
    'amount_total_cents', v_b.amount_total_cents,
    'amount_paid_cents', v_b.amount_paid_cents,
    'balance_due_cents', greatest(v_b.amount_total_cents - v_b.amount_paid_cents, 0),
    'deposit_cents', v_b.deposit_cents,
    'bottle_subtotal_cents', v_b.bottle_subtotal_cents,
    'tax_cents', v_b.tax_cents,
    'bottlesup_fee_cents', v_b.bottlesup_fee_cents,
    'discount_cents', v_b.discount_cents,
    'closed_out', v_b.reconciled_at is not null,
    'closeout_requested', v_b.closeout_requested_at is not null,
    'payments', v_payments
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Recording a payment
-- ---------------------------------------------------------------------------
-- billed = what the club's till says the table owes; paid = what was actually collected now (the booking's paid total goes up by it,
-- never past the booking total, as production's own function does). Rules, in the order they are checked:
--   * the caller is the owner/manager, or the server the booking was given to; the booking is a confirmed one, not yet closed out;
--   * the method is cash, debit, credit or split (a split says how); amounts are whole cents, none negative, collected more than
--     zero, nothing above $100,000;
--   * evidence: a server must attach a receipt photo; a manager may instead write why there is none. A photo's path must start with
--     this booking's id (that is what ties it to the booking and decides who can read it); its hash, when sent, is a SHA-256 in hex;
--   * the same photo recorded again for this booking answers "duplicate" and writes nothing (a repeated tap is not a second payment);
--     without a photo, the same amounts and reason from the same person within a minute are the same repeat;
--   * a till receipt number or a photo already used for another payment at this club is refused.
-- The booking row is locked for the whole call, so two taps at once end up as one payment.
create function public.desk_record_payment(
  p_booking uuid,
  p_billed_amount_cents int,
  p_amount_paid_cents int,
  p_payment_method text,
  p_split_breakdown jsonb default null,
  p_pos_reference text default null,
  p_receipt_photo_path text default null,
  p_payer_name text default null,
  p_payer_email text default null,
  p_bottle_subtotal_cents int default 0,
  p_discount_cents int default 0,
  p_tax_cents int default 0,
  p_gratuity_cents int default 0,
  p_receipt_photo_hash text default null,
  p_device_id text default null,
  p_missing_receipt_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_level text;
  v_booking record;
  v_pos text;
  v_name text;
  v_email text;
  v_device text;
  v_reason text;
  v_existing record;
  v_payment_id uuid;
  v_new_paid int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_level := public.desk_booking_level(p_booking);
  if v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;

  if p_payment_method is null or p_payment_method not in ('cash', 'debit', 'credit', 'split') then
    raise exception 'choose how it was paid';
  end if;
  if p_billed_amount_cents is null or p_amount_paid_cents is null
     or p_bottle_subtotal_cents is null or p_discount_cents is null or p_tax_cents is null or p_gratuity_cents is null then
    raise exception 'enter the amounts';
  end if;
  if p_billed_amount_cents < 0 or p_amount_paid_cents < 0 or p_bottle_subtotal_cents < 0
     or p_discount_cents < 0 or p_tax_cents < 0 or p_gratuity_cents < 0 then
    raise exception 'amounts cannot be negative';
  end if;
  if greatest(p_billed_amount_cents, p_amount_paid_cents, p_bottle_subtotal_cents, p_discount_cents, p_tax_cents, p_gratuity_cents) > 10000000 then
    raise exception 'that amount is too large';
  end if;
  if p_amount_paid_cents = 0 then raise exception 'enter the amount collected'; end if;

  if p_payment_method = 'split' then
    if p_split_breakdown is null or jsonb_typeof(p_split_breakdown) not in ('array', 'object')
       or length(p_split_breakdown::text) > 2000 then
      raise exception 'say how the split was paid';
    end if;
  end if;

  v_pos := nullif(btrim(p_pos_reference), '');
  if v_pos is not null and char_length(v_pos) > 80 then raise exception 'the receipt number is too long'; end if;
  v_name := nullif(btrim(p_payer_name), '');
  if v_name is not null and char_length(v_name) > 120 then raise exception 'the payer''s name is too long'; end if;
  v_email := nullif(btrim(p_payer_email), '');
  if v_email is not null and (char_length(v_email) > 200 or v_email !~ '^[^@\s]+@[^@\s]+$') then
    raise exception 'that email address does not look right';
  end if;
  v_device := nullif(btrim(p_device_id), '');
  if v_device is not null and char_length(v_device) > 100 then raise exception 'the device id is too long'; end if;
  v_reason := nullif(btrim(p_missing_receipt_reason), '');
  if v_reason is not null and char_length(v_reason) > 300 then raise exception 'keep the reason to 300 characters or fewer'; end if;

  if p_receipt_photo_path is null then
    if v_level <> 'manager' then raise exception 'a receipt photo is required'; end if;
    if v_reason is null then raise exception 'a reason is required when recording without a receipt'; end if;
  else
    if char_length(p_receipt_photo_path) > 300 or p_receipt_photo_path !~ ('^' || p_booking::text || '/[^/].*$')
       or p_receipt_photo_path like '%..%' then
      raise exception 'the receipt photo does not belong to this booking';
    end if;
    v_reason := null;
    if p_receipt_photo_hash is not null and p_receipt_photo_hash !~ '^[0-9a-f]{64}$' then
      raise exception 'the receipt photo could not be checked';
    end if;
  end if;

  select b.id, b.venue_id, b.status, b.reconciled_at, b.amount_total_cents, b.amount_paid_cents into v_booking
    from public.site_table_bookings b where b.id = p_booking for update;
  if v_booking.status is distinct from 'paid' then raise exception 'only a confirmed booking can take a payment'; end if;
  if v_booking.reconciled_at is not null then raise exception 'this table has already been closed out'; end if;

  -- A repeated tap: answer with what is already there.
  if p_receipt_photo_path is not null then
    select cp.id into v_existing from public.site_table_booking_club_payments cp
      where cp.booking_id = p_booking and cp.receipt_photo_path = p_receipt_photo_path limit 1;
  else
    select cp.id into v_existing from public.site_table_booking_club_payments cp
      where cp.booking_id = p_booking and cp.receipt_photo_path is null and cp.recorded_by = auth.uid()
        and cp.payment_method = p_payment_method and cp.billed_amount_cents = p_billed_amount_cents
        and cp.amount_paid_cents = p_amount_paid_cents and cp.missing_receipt_reason is not distinct from v_reason
        and cp.recorded_at > now() - interval '1 minute'
      limit 1;
  end if;
  if v_existing.id is not null then
    return jsonb_build_object('success', true, 'duplicate', true, 'payment_id', v_existing.id,
      'new_amount_paid_cents', v_booking.amount_paid_cents,
      'balance_due_cents', greatest(v_booking.amount_total_cents - v_booking.amount_paid_cents, 0));
  end if;

  if v_pos is not null and exists (
    select 1 from public.site_table_booking_club_payments cp
    join public.site_table_bookings b2 on b2.id = cp.booking_id
    where b2.venue_id = v_booking.venue_id and cp.pos_reference = v_pos
  ) then
    raise exception 'this POS receipt number has already been recorded for another payment at this venue';
  end if;
  if p_receipt_photo_hash is not null and exists (
    select 1 from public.site_table_booking_club_payments cp
    join public.site_table_bookings b2 on b2.id = cp.booking_id
    where b2.venue_id = v_booking.venue_id and cp.receipt_photo_hash = p_receipt_photo_hash
  ) then
    raise exception 'this receipt photo has already been used for another payment at this venue';
  end if;

  insert into public.site_table_booking_club_payments (
    booking_id, billed_amount_cents, amount_paid_cents, payment_method, split_breakdown, pos_reference, receipt_photo_path,
    recorded_by, payer_name, payer_email, bottle_subtotal_cents, discount_cents, tax_cents, gratuity_cents,
    receipt_photo_hash, device_id, missing_receipt_reason
  ) values (
    p_booking, p_billed_amount_cents, p_amount_paid_cents, p_payment_method,
    case when p_payment_method = 'split' then p_split_breakdown end, v_pos, p_receipt_photo_path,
    auth.uid(), v_name, v_email, p_bottle_subtotal_cents, p_discount_cents, p_tax_cents, p_gratuity_cents,
    p_receipt_photo_hash, v_device, v_reason
  ) returning id into v_payment_id;

  v_new_paid := least(v_booking.amount_paid_cents + p_amount_paid_cents, v_booking.amount_total_cents);
  update public.site_table_bookings set amount_paid_cents = v_new_paid where id = p_booking;

  perform public.desk_log('table_booking.club_payment_recorded', 'site_table_bookings', p_booking,
    jsonb_build_object('venue_id', v_booking.venue_id, 'payment_id', v_payment_id, 'recorded_as', v_level,
                       'billed_amount_cents', p_billed_amount_cents, 'amount_paid_cents', p_amount_paid_cents,
                       'payment_method', p_payment_method, 'pos_reference', v_pos,
                       'bottle_subtotal_cents', p_bottle_subtotal_cents, 'discount_cents', p_discount_cents,
                       'tax_cents', p_tax_cents, 'gratuity_cents', p_gratuity_cents,
                       'new_amount_paid_cents', v_new_paid, 'device_id', v_device, 'missing_receipt_reason', v_reason));

  return jsonb_build_object('success', true, 'duplicate', false, 'payment_id', v_payment_id,
    'new_amount_paid_cents', v_new_paid,
    'balance_due_cents', greatest(v_booking.amount_total_cents - v_new_paid, 0));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The verifier's queue and verifying
-- ---------------------------------------------------------------------------
-- Payments recorded at the club that need a person: ones nobody has checked yet, and ones the customer disputed (those first, even if
-- they had been checked earlier: a dispute after the fact still has to be looked at), oldest first. The owner/manager and a
-- verifier. recorded_by_me marks the caller's own entries, which they cannot verify. A disputed payment cannot be verified; settling a
-- dispute is not built yet, so it stays here until it is.
create function public.desk_pending_verifications(p_venue uuid)
returns table (
  payment_id uuid, booking_id uuid, confirmation_code text, customer_name text, table_name text, payment_method text,
  billed_amount_cents int, amount_paid_cents int, pos_reference text, receipt_photo_path text, missing_receipt_reason text,
  recorded_at timestamptz, recorded_by_name text, recorded_by_me boolean, customer_confirmation_status text, dispute_reason text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.can_access_venue(p_venue, array['manager', 'owner', 'verifier']) then raise exception 'not allowed'; end if;

  return query
    select cp.id, b.id, b.confirmation_code, b.customer_name, t.name, cp.payment_method,
           cp.billed_amount_cents, cp.amount_paid_cents, cp.pos_reference, cp.receipt_photo_path, cp.missing_receipt_reason,
           cp.recorded_at, pr.name, cp.recorded_by is not null and cp.recorded_by = auth.uid(),
           cp.customer_confirmation_status, cp.dispute_reason
    from public.site_table_booking_club_payments cp
    join public.site_table_bookings b on b.id = cp.booking_id
    join public.site_table_types t on t.id = b.table_type_id
    left join public.profiles pr on pr.id = cp.recorded_by
    where b.venue_id = p_venue
      and (cp.customer_confirmation_status = 'disputed'
           or (cp.manager_verified_at is null and cp.customer_confirmation_status = 'pending'))
    order by (cp.customer_confirmation_status = 'disputed') desc, cp.recorded_at, cp.id
    limit 300;
end;
$$;

-- Marks one payment as checked against the till (or the cash counted). Not by the person who recorded it, not twice, and not once the
-- customer has already answered (production's own rule).
create function public.desk_verify_payment(p_payment uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_venue uuid;
  v_p record;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select cp.booking_id into v_booking_id from public.site_table_booking_club_payments cp where cp.id = p_payment;
  v_venue := public.booking_venue(v_booking_id);
  if v_venue is null or not public.can_access_venue(v_venue, array['manager', 'owner', 'verifier']) then
    raise exception 'not allowed';
  end if;

  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 300 then raise exception 'keep the note to 300 characters or fewer'; end if;

  select cp.recorded_by, cp.manager_verified_at, cp.customer_confirmation_status into v_p
    from public.site_table_booking_club_payments cp where cp.id = p_payment for update;

  if v_p.manager_verified_at is not null then raise exception 'this payment was already verified'; end if;
  if v_p.recorded_by is not null and v_p.recorded_by = auth.uid() then
    raise exception 'you recorded this payment, so someone else has to verify it';
  end if;
  if v_p.customer_confirmation_status <> 'pending' then raise exception 'the customer already responded to this payment'; end if;

  update public.site_table_booking_club_payments
    set manager_verified_at = now(), manager_verified_by = auth.uid(), manager_verified_note = v_note
    where id = p_payment;

  perform public.desk_log('table_booking.club_payment_manager_verified', 'site_table_booking_club_payments', p_payment,
    jsonb_build_object('venue_id', v_venue, 'booking_id', v_booking_id, 'note', v_note));
  return jsonb_build_object('success', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Tonight
-- ---------------------------------------------------------------------------
-- One line per confirmed booking of the night with where it stands: what is still due, how many items are still to deliver, how many
-- payments were recorded and how many of those nobody has checked, and whether it has been closed out. The manager and owner get the
-- whole club; a server only the bookings given to them. The app puts this next to the booking lists it already has.
create function public.desk_table_status(p_venue uuid, p_night date)
returns table (
  booking_id uuid, balance_due_cents int, items_open int, items_delivered int, payments_recorded int, payments_unchecked int,
  closed_out boolean, closeout_requested boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
begin
  v_level := public.desk_level(p_venue);
  if v_level is null then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;

  return query
    select b.id,
           greatest(b.amount_total_cents - b.amount_paid_cents, 0),
           (select count(*)::int from public.site_table_booking_bottles bb
             where bb.booking_id = b.id and bb.cancelled_at is null and bb.payment_status <> 'pending_payment' and bb.service_status <> 'served'),
           (select count(*)::int from public.site_table_booking_bottles bb
             where bb.booking_id = b.id and bb.cancelled_at is null and bb.payment_status <> 'pending_payment' and bb.service_status = 'served'),
           (select count(*)::int from public.site_table_booking_club_payments cp where cp.booking_id = b.id),
           (select count(*)::int from public.site_table_booking_club_payments cp
             where cp.booking_id = b.id and (cp.customer_confirmation_status = 'disputed'
               or (cp.manager_verified_at is null and cp.customer_confirmation_status = 'pending'))),
           b.reconciled_at is not null,
           b.closeout_requested_at is not null
    from public.site_table_bookings b
    join public.site_venue_time_slots s on s.id = b.time_slot_id
    left join public.site_booking_servers bs on bs.booking_id = b.id
    where b.venue_id = p_venue
      and b.status = 'paid'
      and b.booking_date between p_night and p_night + 1
      and public.booking_night(b.booking_date, s.start_time) = p_night
      and (
        v_level = 'manager'
        or bs.membership_id in (select m.id from public.active_memberships() m where m.role = 'server')
      )
    order by s.start_time, b.customer_name, b.id
    limit 1000;
end;
$$;

-- The manager's "Needs attention" numbers for one night. Tapping one opens the matching list. The first group is about the night.
-- The second is club-wide because that is how its list works (payments to check, closings asked for and open requests are not tied
-- to a night): payments_to_check plus payments_disputed is exactly the verifier's queue. Owner/manager only. A booking that has been
-- closed out still counts as a table, and its items and balances still count.
create function public.desk_tonight(p_venue uuid, p_night date)
returns table (
  tables int, guests int, arrived int, without_server int, with_balance int, balance_due_cents bigint,
  orders_new int, orders_in_progress int, orders_delivered int,
  payments_to_check int, payments_disputed int, closeouts_requested int, requests_open int
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.desk_level(p_venue) is distinct from 'manager' then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;

  return query
    with nb as (
      select b.id, b.guest_count, b.checked_in_at, b.amount_total_cents, b.amount_paid_cents
      from public.site_table_bookings b
      join public.site_venue_time_slots s on s.id = b.time_slot_id
      where b.venue_id = p_venue and b.status = 'paid'
        and b.booking_date between p_night and p_night + 1
        and public.booking_night(b.booking_date, s.start_time) = p_night
    ), ln as (
      select bb.service_status
      from public.site_table_booking_bottles bb join nb on nb.id = bb.booking_id
      where bb.cancelled_at is null and bb.payment_status <> 'pending_payment'
    )
    select
      (select count(*)::int from nb),
      (select coalesce(sum(nb.guest_count), 0)::int from nb),
      (select count(*)::int from nb where nb.checked_in_at is not null),
      (select count(*)::int from nb where not exists (select 1 from public.site_booking_servers a where a.booking_id = nb.id)),
      (select count(*)::int from nb where nb.amount_total_cents > nb.amount_paid_cents),
      (select coalesce(sum(greatest(nb.amount_total_cents - nb.amount_paid_cents, 0)), 0)::bigint from nb),
      (select count(*)::int from ln where ln.service_status = 'awaiting_prep'),
      (select count(*)::int from ln where ln.service_status in ('preparing', 'ready', 'picked_up')),
      (select count(*)::int from ln where ln.service_status = 'served'),
      (select count(*)::int from public.site_table_booking_club_payments cp join public.site_table_bookings b on b.id = cp.booking_id
        where b.venue_id = p_venue and cp.manager_verified_at is null and cp.customer_confirmation_status = 'pending'),
      (select count(*)::int from public.site_table_booking_club_payments cp join public.site_table_bookings b on b.id = cp.booking_id
        where b.venue_id = p_venue and cp.customer_confirmation_status = 'disputed'),
      (select count(*)::int from public.site_table_bookings b
        where b.venue_id = p_venue and b.closeout_requested_at is not null and b.reconciled_at is null),
      (select count(*)::int from public.site_service_requests r
        where r.venue_id = p_venue and r.status in ('new', 'acknowledged', 'in_progress', 'escalated'));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.desk_booking_money(uuid),
  public.desk_record_payment(uuid, int, int, text, jsonb, text, text, text, text, int, int, int, int, text, text, text),
  public.desk_pending_verifications(uuid), public.desk_verify_payment(uuid, text),
  public.desk_table_status(uuid, date), public.desk_tonight(uuid, date)
  from public, anon;
grant execute on function
  public.desk_booking_money(uuid),
  public.desk_record_payment(uuid, int, int, text, jsonb, text, text, text, text, int, int, int, int, text, text, text),
  public.desk_pending_verifications(uuid), public.desk_verify_payment(uuid, text),
  public.desk_table_status(uuid, date), public.desk_tonight(uuid, date)
  to authenticated, service_role;

-- The storage policies call this; the caller gets only their own standing.
revoke all on function public.receipt_booking(text) from public, anon;
grant execute on function public.receipt_booking(text) to authenticated, service_role;
