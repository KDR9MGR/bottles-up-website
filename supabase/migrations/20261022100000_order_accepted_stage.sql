-- The order stage "Accepted" (developer brief 15 Oct, section 16: "Order stages: Submitted > Accepted > Preparing > On the Way > Delivered"; the client's answer of 20 Oct:
-- "Accepted tells the customer that staff has seen and taken responsibility for the order. Keep payment separate. Test the database change and rollback process before
-- requesting approval to put it live").
--
-- WHAT CHANGES
--   * the check constraint on site_table_booking_bottles.service_status allows one more value, 'accepted' (the five old values keep their meaning; no row changes);
--   * desk_set_service_status (the app) accepts it. Accepting is only for an order that is still new: a stale tap on an order that has already moved on is refused
--     with a plain sentence instead of moving it backwards;
--   * desk_tonight and night_report_data count an accepted order as IN PROGRESS (otherwise it would be in no column of Tonight or of the night's report);
--   * update_bottle_service_status (the website's own staff function, made by hand in production, in no committed migration: see tests/db/prod_shapes) accepts it too,
--     so the website's staff pages can show and set the new stage.
--   "Ready" is unchanged and stays between Preparing and On the way: the app shows it as "Ready to collect" inside Preparing (the client's flow has no separate step for it).
--
-- GUARD (compare-and-swap, because this replaces FOUR LIVE functions and a constraint): each function is replaced only if it is exactly the version this repository
-- has (or the production definition recorded in tests/db/prod_shapes); one that already knows 'accepted' is left alone; anything else STOPS the whole migration before
-- anything is changed. The constraint must be exactly the known five-value list, or already allow 'accepted'.
-- Rollback: supabase/go-live/rollback_business_brief_3.sql (puts the five-value constraint and the old functions back; refuses while any line is 'accepted').

do $guard$
declare
  v_live text;
  v_src text;
  v_def text;
  r record;
begin
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conrelid = 'public.site_table_booking_bottles'::regclass and c.conname = 'site_table_booking_bottles_service_status_check';
  if v_def is null then
    raise exception 'the check constraint site_table_booking_bottles_service_status_check does not exist in this database. Nothing was changed.';
  end if;
  if position('accepted' in v_def) = 0 and v_def <> 'CHECK ((service_status = ANY (ARRAY[''awaiting_prep''::text, ''preparing''::text, ''ready''::text, ''picked_up''::text, ''served''::text])))' then
    raise exception 'the service status constraint in this database is not the one this change was written against (%). It was NOT replaced. Nothing was changed.', v_def;
  end if;

  for r in select * from (values
      ('desk_set_service_status', 'p_line uuid, p_status text', '98370707dedeac079c148c1c548d7a0b'),
      ('desk_tonight', 'p_venue uuid, p_night date', '810af92b61e28355ba55661686365e11'),
      ('night_report_data', 'p_venue uuid, p_night date', '138c135de30fe1b85916041d0cb6e902'),
      ('update_bottle_service_status', 'p_bottle_line_id uuid, p_status text', '2c653f60d518d12d7c9e907a02d6fcd0')
    ) as x(fname, fargs, expected) loop
    select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, '')), p.prosrc
      into v_live, v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname and pg_get_function_identity_arguments(p.oid) = r.fargs;
    if v_live is null then
      raise exception 'public.% does not exist in this database. Nothing was changed.', r.fname;
    end if;
    if position('accepted' in v_src) = 0 and v_live <> r.expected then
      raise exception '%() in this database differs from the version this change was written against (live fingerprint %, expected %). It was NOT replaced, because that could undo a change made directly in the database. Inspect it with \sf public.% and reconcile by hand. Nothing was changed.', r.fname, v_live, r.expected, r.fname;
    end if;
  end loop;
end
$guard$;

-- the constraint: the same five values and 'accepted' between the first and the second
do $constraint$
declare
  v_def text;
begin
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conrelid = 'public.site_table_booking_bottles'::regclass and c.conname = 'site_table_booking_bottles_service_status_check';
  if position('accepted' in v_def) = 0 then
    alter table public.site_table_booking_bottles drop constraint site_table_booking_bottles_service_status_check;
    alter table public.site_table_booking_bottles add constraint site_table_booking_bottles_service_status_check
      check (service_status = any (array['awaiting_prep', 'accepted', 'preparing', 'ready', 'picked_up', 'served']));
  end if;
end
$constraint$;

do $replace$
declare
  v_src text;
begin
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'desk_set_service_status';
  if position('accepted' in v_src) = 0 then
    execute $sql$
CREATE OR REPLACE FUNCTION public.desk_set_service_status(p_line uuid, p_status text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_booking_id uuid;
  v_level text;
  v_booking record;
  v_line record;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_status is null or p_status not in ('awaiting_prep', 'accepted', 'preparing', 'ready', 'picked_up', 'served') then
    raise exception 'invalid status';
  end if;

  select bb.booking_id into v_booking_id from public.site_table_booking_bottles bb where bb.id = p_line;
  v_level := public.desk_booking_level(v_booking_id);
  if v_level is null or v_level not in ('manager', 'server') then raise exception 'not allowed'; end if;

  select b.id, b.venue_id, b.status, b.reconciled_at, b.amount_total_cents, b.amount_paid_cents into v_booking
    from public.site_table_bookings b where b.id = v_booking_id for update;
  select bb.id, bb.payment_status, bb.service_status, bb.cancelled_at into v_line
    from public.site_table_booking_bottles bb where bb.id = p_line for update;

  if v_booking.status is distinct from 'paid' then raise exception 'only a paid booking has orders to serve'; end if;
  if v_booking.reconciled_at is not null then raise exception 'this table has already been closed out'; end if;
  if v_line.cancelled_at is not null then raise exception 'this item was cancelled'; end if;
  if v_line.payment_status = 'pending_payment' then raise exception 'payment not yet verified for this item'; end if;

  if v_line.service_status = p_status then return false; end if;

  if v_level = 'server' and v_line.service_status = 'served' then
    raise exception 'a delivered item can only be changed by a manager';
  end if;

  -- Accepting is taking an order that has just come in. A stale tap on an order that is already further along must not move it backwards.
  if p_status = 'accepted' and v_line.service_status <> 'awaiting_prep' then
    raise exception 'this order has already been accepted or is further along';
  end if;

  if p_status = 'served' and v_line.payment_status = 'due_at_venue' then
    if greatest(v_booking.amount_total_cents - v_booking.amount_paid_cents, 0) > 0 then
      raise exception 'cannot mark delivered - this table still has a balance due at the venue';
    end if;
    if not exists (select 1 from public.site_table_booking_club_payments cp where cp.booking_id = v_booking_id) then
      raise exception 'cannot mark delivered - no payment has been recorded for this table';
    end if;
  end if;

  update public.site_table_booking_bottles set service_status = p_status where id = p_line;

  perform public.desk_log('table_booking.bottle_service_status_updated', 'site_table_booking_bottles', p_line,
    jsonb_build_object('venue_id', v_booking.venue_id, 'booking_id', v_booking_id,
                       'old_status', v_line.service_status, 'new_status', p_status));
  return true;
end;
$function$
    $sql$;
  end if;

  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'desk_tonight';
  if position('accepted' in v_src) = 0 then
    execute $sql$
CREATE OR REPLACE FUNCTION public.desk_tonight(p_venue uuid, p_night date)
 RETURNS TABLE(tables integer, guests integer, arrived integer, without_server integer, with_balance integer, balance_due_cents bigint, orders_new integer, orders_in_progress integer, orders_delivered integer, payments_to_check integer, payments_disputed integer, closeouts_requested integer, requests_open integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      (select count(*)::int from ln where ln.service_status in ('accepted', 'preparing', 'ready', 'picked_up')),
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
$function$
    $sql$;
  end if;

  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'night_report_data';
  if position('accepted' in v_src) = 0 then
    execute $sql$
CREATE OR REPLACE FUNCTION public.night_report_data(p_venue uuid, p_night date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_name text;
  v_bookings jsonb;
  v_payments jsonb;
  v_bottles jsonb;
  v_cash jsonb;
  v_flags jsonb;
  v_service jsonb;
  v_security jsonb;
begin
  select v.name into v_name from public.site_venues v where v.id = p_venue;

  select jsonb_build_object(
    'count', count(*),
    'guests', coalesce(sum(b.guest_count), 0),
    'total_cents', coalesce(sum(b.amount_total_cents), 0),
    'paid_cents', coalesce(sum(b.amount_paid_cents), 0),
    'balance_cents', coalesce(sum(greatest(b.amount_total_cents - b.amount_paid_cents, 0)), 0),
    'discount_cents', coalesce(sum(b.discount_cents), 0),
    'seated', count(*) filter (where exists (select 1 from public.site_booking_seating s where s.booking_id = b.id)))
  into v_bookings
  from public.site_table_bookings b where b.id in (select id from public.night_booking_ids(p_venue, p_night));

  select jsonb_build_object(
    'count', count(*),
    'collected_cents', coalesce(sum(cp.amount_paid_cents), 0),
    'billed_cents', coalesce(sum(cp.billed_amount_cents), 0),
    'cash_cents', coalesce(sum(public.desk_cash_part(cp.payment_method, cp.amount_paid_cents, cp.split_breakdown)), 0),
    'debit_cents', coalesce(sum(cp.amount_paid_cents) filter (where cp.payment_method = 'debit'), 0),
    'credit_cents', coalesce(sum(cp.amount_paid_cents) filter (where cp.payment_method = 'credit'), 0),
    'split_card_cents', coalesce(sum(cp.amount_paid_cents - public.desk_cash_part(cp.payment_method, cp.amount_paid_cents, cp.split_breakdown)) filter (where cp.payment_method = 'split'), 0),
    'tax_cents', coalesce(sum(cp.tax_cents), 0),
    'gratuity_cents', coalesce(sum(cp.gratuity_cents), 0),
    'discount_cents', coalesce(sum(cp.discount_cents), 0),
    'unverified', count(*) filter (where cp.manager_verified_at is null),
    'disputed', count(*) filter (where cp.customer_confirmation_status = 'disputed'),
    'no_receipt', count(*) filter (where cp.receipt_photo_path is null),
    'corrections', count(*) filter (where cp.corrects_payment_id is not null))
  into v_payments
  from public.site_table_booking_club_payments cp
  where cp.booking_id in (select id from public.night_booking_ids(p_venue, p_night))
    and not exists (select 1 from public.site_table_booking_club_payments c2 where c2.corrects_payment_id = cp.id);

  select jsonb_build_object(
    'lines', count(*) filter (where bb.cancelled_at is null),
    'value_cents', coalesce(sum(bb.line_total_cents) filter (where bb.cancelled_at is null), 0),
    'served', count(*) filter (where bb.cancelled_at is null and bb.service_status = 'served'),
    'in_progress', count(*) filter (where bb.cancelled_at is null and bb.service_status in ('accepted', 'preparing', 'ready', 'picked_up')),
    'awaiting', count(*) filter (where bb.cancelled_at is null and bb.service_status = 'awaiting_prep'),
    'cancelled', count(*) filter (where bb.cancelled_at is not null),
    'due_at_venue', count(*) filter (where bb.cancelled_at is null and bb.payment_status = 'due_at_venue'))
  into v_bottles
  from public.site_table_booking_bottles bb
  where bb.booking_id in (select id from public.night_booking_ids(p_venue, p_night));

  select jsonb_build_object(
    'handovers', count(*),
    'claimed_cents', coalesce(sum(h.claimed_cents), 0),
    'counted_cents', coalesce(sum(h.counted_cents), 0),
    'shortage_cents', coalesce(sum(h.claimed_cents - h.counted_cents) filter (where h.status = 'acknowledged' and h.counted_cents < h.claimed_cents), 0),
    'overage_cents', coalesce(sum(h.counted_cents - h.claimed_cents) filter (where h.status = 'acknowledged' and h.counted_cents > h.claimed_cents), 0),
    'waiting', count(*) filter (where h.status = 'submitted'),
    'held_cents', coalesce((select sum(greatest(r.collected_cents - r.handed_in_cents, 0)) from public.desk_cash_rows(p_venue, p_night) r), 0))
  into v_cash
  from public.site_cash_handovers h where h.venue_id = p_venue and h.business_night = p_night;

  select jsonb_build_object(
    'raised', count(*),
    'open', count(*) filter (where f.status = 'open'),
    'resolved', count(*) filter (where f.status = 'resolved'),
    'by_resolution', coalesce((select jsonb_object_agg(x.resolution, x.n) from (
        select f2.resolution, count(*) as n from public.site_payment_flags f2
        join public.site_table_booking_club_payments cp2 on cp2.id = f2.payment_id
        where cp2.booking_id in (select id from public.night_booking_ids(p_venue, p_night)) and f2.resolution is not null
        group by f2.resolution) x), '{}'::jsonb))
  into v_flags
  from public.site_payment_flags f
  join public.site_table_booking_club_payments cp on cp.id = f.payment_id
  where cp.booking_id in (select id from public.night_booking_ids(p_venue, p_night));

  select jsonb_build_object(
    'total', count(*),
    'open', count(*) filter (where r.status in ('new', 'acknowledged', 'in_progress', 'escalated')),
    'completed', count(*) filter (where r.status = 'completed'),
    'escalated', count(*) filter (where r.status = 'escalated'),
    'cancelled', count(*) filter (where r.status = 'cancelled'))
  into v_service
  from public.site_service_requests r
  where r.booking_id in (select id from public.night_booking_ids(p_venue, p_night));

  select jsonb_build_object(
    'alerts', (select jsonb_build_object(
        'total', count(*),
        'urgent', count(*) filter (where a.urgent),
        'unresolved', count(*) filter (where a.status <> 'resolved'),
        'escalated', count(*) filter (where a.status = 'escalated'),
        'by_kind', coalesce((select jsonb_object_agg(k.kind, k.n) from (
            select a2.kind, count(*) as n from public.site_security_alerts a2 where a2.venue_id = p_venue and a2.business_night = p_night group by a2.kind) k), '{}'::jsonb))
      from public.site_security_alerts a where a.venue_id = p_venue and a.business_night = p_night),
    'tasks', (select jsonb_build_object('total', count(*), 'done', count(*) filter (where t.status = 'done'), 'open', count(*) filter (where t.status = 'open'))
      from public.site_security_tasks t where t.venue_id = p_venue and t.business_night = p_night),
    'incidents', coalesce((select jsonb_agg(jsonb_build_object('kind', i.kind, 'location', i.location, 'status', i.status) order by i.occurred_at, i.id)
      from public.site_security_incidents i where i.venue_id = p_venue and i.business_night = p_night), '[]'::jsonb))
  into v_security;

  return jsonb_build_object(
    'venue_name', v_name,
    'business_night', p_night,
    'generated_at', clock_timestamp(),
    'bookings', v_bookings,
    'payments', v_payments,
    'bottles', v_bottles,
    'cash', v_cash,
    'flags', v_flags,
    'service', v_service,
    'security', v_security);
end;
$function$
    $sql$;
  end if;

  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'update_bottle_service_status';
  if position('accepted' in v_src) = 0 then
    execute $sql$
CREATE OR REPLACE FUNCTION public.update_bottle_service_status(p_bottle_line_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_line record;
  v_actor_email text;
begin
  if not (public.is_cms_admin() or public.is_door_staff()) then
    raise exception 'not authorized';
  end if;
  if p_status not in ('awaiting_prep', 'accepted', 'preparing', 'ready', 'picked_up', 'served') then
    raise exception 'invalid status';
  end if;

  select id, payment_status, booking_id into v_line
  from public.site_table_booking_bottles
  where id = p_bottle_line_id
  for update;

  if not found then
    raise exception 'bottle line not found';
  end if;
  -- pending_payment = an online payment attempt still in flight, might never
  -- complete - "once payment is verified" excludes exactly this state, but
  -- never due_at_venue, which is already a real, committed order.
  if v_line.payment_status = 'pending_payment' then
    raise exception 'payment not yet verified for this item';
  end if;

  if p_status = 'served' and v_line.payment_status = 'due_at_venue' then
    if not exists (
      select 1 from public.site_table_bookings b
      where b.id = v_line.booking_id and greatest(b.amount_total_cents - b.amount_paid_cents, 0) = 0
    ) then
      raise exception 'cannot mark served - this table still has a balance due at the venue';
    end if;
    if not exists (
      select 1 from public.site_table_booking_club_payments cp
      where cp.booking_id = v_line.booking_id and cp.receipt_photo_path is not null
    ) then
      raise exception 'cannot mark served - no verified POS receipt has been recorded for this table';
    end if;
  end if;

  update public.site_table_booking_bottles set service_status = p_status where id = p_bottle_line_id;

  select coalesce(
    (select email from public.cms_admins where id = auth.uid()),
    (select email from public.door_staff where id = auth.uid()),
    'unknown'
  ) into v_actor_email;

  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (
    auth.uid(), v_actor_email, 'table_booking.bottle_service_status_updated',
    'site_table_booking_bottles', p_bottle_line_id,
    jsonb_build_object('booking_id', v_line.booking_id, 'new_status', p_status)
  );

  return jsonb_build_object('success', true, 'status', p_status);
end;
$function$
    $sql$;
  end if;
end
$replace$;
