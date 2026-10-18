-- Guest tickets for table bookings, and the check-in functions that know about them.
--
-- THIS CHANGE IS ALREADY LIVE IN PRODUCTION. It was applied by hand on 2026-09-23 (through the Supabase MCP, as a migration called
-- "guest_tickets_and_checkin_fix") and was never committed here, so a database built from this repository did not have it. This file
-- records it. Running it where the change is already present does NOTHING (see the first check below), so it is safe in production
-- and in any database that was built the same way; it exists so a fresh database (tests, a new project) ends up the same as production.
--
-- What it adds
--   * public.guest_tickets: one row per guest a table-booking holder invites (name, email, a code of its own, whether the ticket was
--     emailed, whether the guest has checked in). Row level security is on; only a CMS admin can read it, nobody can write through the
--     API. Every write goes through the manage-guest-tickets edge function (service role) or through checkin_ticket() below.
--   * scan_attempts.guest_ticket_id: so the audit trail can say WHICH guest was scanned, not only which booking.
--   * checkin_ticket(): rewritten to look in three places, in order: an event ticket (site_orders.ticket_code, with the entry-code
--     step for non-transferable tickets), a table booking's confirmation code (the holder), and a guest ticket (guest_tickets.guest_code,
--     which checks in that one guest and leaves the booking's own check-in alone, so guests can arrive separately).
--   * lookup_table_booking_for_checkin(): the door staff's read of a booking before checking in. It now accepts either the holder's
--     code or a guest's code, always describes the whole booking, and says who was scanned (scanned_*) and who else is on the list.
--
-- Why checkin_ticket() is replaced here: 20260821_ticket_otp_access_codes.sql rewrote it for the entry-code feature and, in doing so,
-- dropped the table-booking branch that 20260729_vip_table_booking.sql had added. From 2026-08-21 a table-booking confirmation code
-- answered 'not_found' at the door. The rewrite below restores that branch and adds the guest-ticket one. (It keeps the early-return
-- fix of 20260830120000: every branch records one scan attempt and returns once.)
--
-- Not done here, on purpose: nothing is changed in a database that already has guest_tickets, and no data is touched.
--
-- GUARDS (the same compare-and-swap idea as 20260830120000, because checkin_ticket() is a LIVE function that this repository
-- may not describe exactly):
--   * guest_tickets already exists         -> the change is already applied: a notice, nothing changed.
--   * checkin_ticket() is not exactly one of the two versions this repository has produced (the 20260821 definition, or the same
--     with the two early returns of 20260830120000) -> STOPS with an error and changes nothing.
--   * lookup_table_booking_for_checkin() already exists but guest_tickets does not -> the plain CREATE FUNCTION fails, the whole
--     block rolls back, nothing is changed (that function is not defined by any earlier migration, so a copy here is unknown).
-- Everything runs as ONE statement, so it either all happens or none of it does.

do $migration$
declare
  v_live text;
  c_0821 constant text := '553484477fdc48844c3595be7cd1543f';  -- checkin_ticket as 20260821 defined it
  c_0830 constant text := '28d05a7c0699859b4d97f3e6fed6effd';  -- the same with the two early returns (20260830120000)
begin
  if to_regclass('public.guest_tickets') is not null then
    raise notice 'public.guest_tickets already exists: this change is already applied. Nothing was changed.';
    return;
  end if;

  select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
  into v_live
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'checkin_ticket'
    and pg_get_function_identity_arguments(p.oid) = 'p_ticket_code text';

  if v_live is null then
    raise exception 'public.checkin_ticket(text) does not exist in this database. Nothing was changed.';
  end if;
  if v_live not in (c_0821, c_0830) then
    raise exception
      'checkin_ticket() in this database differs from the versions this repository has produced (live fingerprint %, expected % or %). '
      'It was NOT replaced, because that could undo a change made directly in the database. Inspect it with \sf public.checkin_ticket '
      'and reconcile by hand. Nothing was changed.', v_live, c_0821, c_0830;
  end if;

  execute $sql$
    create table public.guest_tickets (
      id uuid primary key default gen_random_uuid(),
      booking_id uuid not null references public.site_table_bookings(id) on delete cascade,
      guest_name text not null,
      guest_email text not null,
      guest_code text not null unique,
      ticket_sent_at timestamptz,
      checked_in_at timestamptz,
      checked_in_by uuid references auth.users(id),
      created_at timestamptz not null default now()
    )
  $sql$;
  execute $sql$ create index idx_guest_tickets_booking_id on public.guest_tickets(booking_id) $sql$;
  execute $sql$ alter table public.guest_tickets enable row level security $sql$;
  -- Same shape as ticket_otp_codes: admins can read for support and the CMS; every write is the service role or checkin_ticket().
  execute $sql$
    create policy "admins read guest tickets" on public.guest_tickets
      for select using (public.is_cms_admin())
  $sql$;

  execute $sql$ alter table public.scan_attempts add column guest_ticket_id uuid references public.guest_tickets(id) $sql$;

  execute $sql$
    create or replace function public.checkin_ticket(p_ticket_code text)
    returns table(result text, customer_name text, event_title text, tier_name text, quantity int)
    language plpgsql
    security definer
    set search_path = public
    as $$
    declare
      v_order record;
      v_booking record;
      v_guest record;
      v_result text;
      v_effective_end timestamptz;
    begin
      if not (public.is_cms_admin() or public.is_door_staff()) then
        raise exception 'not authorized';
      end if;

      -- 1) Event ticket
      select o.id, o.status, o.checked_in_at, o.customer_name, o.quantity,
             o.is_non_transferable, o.access_code_verified,
             e.title as event_title, e.start_date, e.end_date, t.name as tier_name
      into v_order
      from public.site_orders o
      join public.site_ticket_tiers t on t.id = o.tier_id
      join public.site_events e on e.id = o.event_id
      where o.ticket_code = p_ticket_code
      for update of o;

      if found then
        if v_order.status <> 'paid' then
          v_result := 'not_paid';
        elsif v_order.checked_in_at is not null then
          v_result := 'already_checked_in';
        else
          v_effective_end := coalesce(v_order.end_date, v_order.start_date + interval '12 hours');
          if now() > v_effective_end then
            v_result := 'expired';
          elsif v_order.is_non_transferable and not v_order.access_code_verified then
            v_result := 'code_required';
          else
            update public.site_orders set checked_in_at = now(), checked_in_by = auth.uid() where id = v_order.id;
            v_result := 'ok';
          end if;
        end if;

        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
        return;
      end if;

      -- 2) Table booking holder code
      select b.id, b.status, b.checked_in_at, b.customer_name, b.guest_count,
             v.name as venue_name, tt.name as table_type_name,
             b.booking_date, ts.start_time
      into v_booking
      from public.site_table_bookings b
      join public.site_table_types tt on tt.id = b.table_type_id
      join public.site_venues v on v.id = b.venue_id
      join public.site_venue_time_slots ts on ts.id = b.time_slot_id
      where b.confirmation_code = p_ticket_code
      for update of b;

      if found then
        if v_booking.status <> 'paid' then
          v_result := 'not_paid';
        elsif v_booking.checked_in_at is not null then
          v_result := 'already_checked_in';
        else
          v_effective_end := ((v_booking.booking_date::timestamp + v_booking.start_time) at time zone 'utc') + interval '12 hours';
          if now() > v_effective_end then
            v_result := 'expired';
          else
            update public.site_table_bookings set checked_in_at = now(), checked_in_by = auth.uid() where id = v_booking.id;
            v_result := 'ok';
          end if;
        end if;

        insert into public.scan_attempts (ticket_code_attempted, result, booking_id, scanned_by)
          values (p_ticket_code, v_result, v_booking.id, auth.uid());
        return query select v_result, v_booking.customer_name,
          v_booking.venue_name || ' - ' || to_char(v_booking.booking_date, 'FMMon DD') || ' ' || to_char(v_booking.start_time, 'FMHH12:MI AM'),
          v_booking.table_type_name, v_booking.guest_count;
        return;
      end if;

      -- 3) Guest ticket code (an invited guest, not the booking holder)
      select g.id, g.guest_name, g.checked_in_at as guest_checked_in_at, g.booking_id,
             b.status, b.booking_date, ts.start_time,
             v.name as venue_name, tt.name as table_type_name
      into v_guest
      from public.guest_tickets g
      join public.site_table_bookings b on b.id = g.booking_id
      join public.site_table_types tt on tt.id = b.table_type_id
      join public.site_venues v on v.id = b.venue_id
      join public.site_venue_time_slots ts on ts.id = b.time_slot_id
      where g.guest_code = p_ticket_code
      for update of g;

      if not found then
        v_result := 'not_found';
        insert into public.scan_attempts (ticket_code_attempted, result, scanned_by)
          values (p_ticket_code, v_result, auth.uid());
        return query select v_result, null::text, null::text, null::text, null::int;
        return;
      end if;

      if v_guest.status <> 'paid' then
        v_result := 'not_paid';
      elsif v_guest.guest_checked_in_at is not null then
        v_result := 'already_checked_in';
      else
        v_effective_end := ((v_guest.booking_date::timestamp + v_guest.start_time) at time zone 'utc') + interval '12 hours';
        if now() > v_effective_end then
          v_result := 'expired';
        else
          update public.guest_tickets set checked_in_at = now(), checked_in_by = auth.uid() where id = v_guest.id;
          v_result := 'ok';
        end if;
      end if;

      insert into public.scan_attempts (ticket_code_attempted, result, booking_id, guest_ticket_id, scanned_by)
        values (p_ticket_code, v_result, v_guest.booking_id, v_guest.id, auth.uid());
      return query select v_result, v_guest.guest_name,
        v_guest.venue_name || ' - ' || to_char(v_guest.booking_date, 'FMMon DD') || ' ' || to_char(v_guest.start_time, 'FMHH12:MI AM'),
        v_guest.table_type_name, 1;
    end;
    $$
  $sql$;

  -- The door staff's read of a booking before checking in. Plain CREATE (see the guards above). It reads production-only columns
  -- (reconciled_at, closeout_requested_at, amount_paid_cents, fulfillment_status, the bottle lines' service and payment state): plpgsql
  -- does not look at them until the function runs, so creating it here is fine; running it needs those columns (tests/db/prod_shapes).
  execute $sql$
    create function public.lookup_table_booking_for_checkin(p_code text)
    returns jsonb
    language plpgsql
    security definer
    set search_path = public
    as $$
    declare
      v_booking record;
      v_bottles jsonb;
      v_guests jsonb;
      v_booking_id uuid;
      v_scanned_guest_id uuid := null;
      v_scanned_name text;
      v_scanned_checked_in_at timestamptz;
    begin
      if not (public.is_cms_admin() or public.is_door_staff()) then
        raise exception 'not authorized';
      end if;

      select b.id into v_booking_id from public.site_table_bookings b where b.confirmation_code = p_code;

      if v_booking_id is null then
        select g.id, g.guest_name, g.checked_in_at, g.booking_id
        into v_scanned_guest_id, v_scanned_name, v_scanned_checked_in_at, v_booking_id
        from public.guest_tickets g
        where g.guest_code = p_code;

        if v_booking_id is null then
          return jsonb_build_object('found', false);
        end if;
      end if;

      select b.id, b.customer_name, b.customer_email, b.guest_count, b.booking_date,
             b.status, b.checked_in_at, b.fulfillment_status, b.deposit_cents,
             b.amount_total_cents, b.amount_paid_cents, b.confirmation_code,
             b.currency, b.reconciled_at, b.closeout_requested_at,
             v.name as venue_name, v.deposit_is_credit,
             tt.name as table_type_name, coalesce(tt.max_guests, b.guest_count) as max_guests,
             ts.start_time
      into v_booking
      from public.site_table_bookings b
      join public.site_venues v on v.id = b.venue_id
      join public.site_table_types tt on tt.id = b.table_type_id
      join public.site_venue_time_slots ts on ts.id = b.time_slot_id
      where b.id = v_booking_id;

      if v_scanned_guest_id is null then
        v_scanned_checked_in_at := v_booking.checked_in_at;
        v_scanned_name := v_booking.customer_name;
      end if;

      select coalesce(jsonb_agg(jsonb_build_object(
               'id', bb.id,
               'bottle_name', bb.bottle_name,
               'size', bb.size,
               'quantity', bb.quantity,
               'line_total_cents', bb.line_total_cents,
               'payment_status', bb.payment_status,
               'service_status', bb.service_status,
               'cancelled_at', bb.cancelled_at,
               'cancellation_reason', bb.cancellation_reason
             ) order by bb.created_at), '[]'::jsonb)
      into v_bottles
      from public.site_table_booking_bottles bb
      where bb.booking_id = v_booking.id
        and bb.payment_status <> 'pending_payment';

      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id,
               'guest_name', g.guest_name,
               'guest_email', g.guest_email,
               'ticket_sent_at', g.ticket_sent_at,
               'checked_in_at', g.checked_in_at
             ) order by g.created_at), '[]'::jsonb)
      into v_guests
      from public.guest_tickets g
      where g.booking_id = v_booking.id;

      return jsonb_build_object(
        'found', true,
        'id', v_booking.id,
        'confirmation_code', v_booking.confirmation_code,
        'customer_name', v_booking.customer_name,
        'customer_email', v_booking.customer_email,
        'guest_count', v_booking.guest_count,
        'max_guests', v_booking.max_guests,
        'venue_name', v_booking.venue_name,
        'table_type_name', v_booking.table_type_name,
        'booking_date', v_booking.booking_date,
        'start_time', v_booking.start_time,
        'status', v_booking.status,
        'checked_in_at', v_booking.checked_in_at,
        'fulfillment_status', v_booking.fulfillment_status,
        'deposit_cents', v_booking.deposit_cents,
        'deposit_is_credit', v_booking.deposit_is_credit,
        'amount_total_cents', v_booking.amount_total_cents,
        'amount_paid_cents', v_booking.amount_paid_cents,
        'currency', v_booking.currency,
        'reconciled_at', v_booking.reconciled_at,
        'closeout_requested_at', v_booking.closeout_requested_at,
        'bottles', v_bottles,
        'guests', v_guests,
        'scanned_code', p_code,
        'scanned_entity', case when v_scanned_guest_id is null then 'holder' else 'guest' end,
        'scanned_guest_id', v_scanned_guest_id,
        'scanned_name', v_scanned_name,
        'scanned_checked_in_at', v_scanned_checked_in_at
      );
    end;
    $$
  $sql$;

  -- Like every other staff-facing function in this repository: closed to visitors, open to signed-in people (the function itself
  -- then requires a CMS admin or door staff member).
  execute $sql$ revoke all on function public.lookup_table_booking_for_checkin(text) from public, anon $sql$;
  execute $sql$ grant execute on function public.lookup_table_booking_for_checkin(text) to authenticated, service_role $sql$;

  raise notice 'guest tickets recorded: guest_tickets, scan_attempts.guest_ticket_id, checkin_ticket() (event ticket, holder, guest), lookup_table_booking_for_checkin().';
end
$migration$;
