-- Fix: checkin_ticket() admitted tickets it had just refused.
--
-- BUG: checkin_ticket() answers 'expired' and 'code_required' with RETURN QUERY, which appends a row but does NOT leave
-- the function. Execution carried on into the admit code, so for those two cases a single scan:
--   * returned TWO rows (the refusal, then 'ok'). The scanner shows row 1, so the guest was still turned away at the
--     door ...
--   * ... but the order was ALSO marked checked in, and an 'ok' scan was logged.
-- Consequences: expired tickets show up as checked in; and a non-transferable ticket was admitted by the FIRST scan, so
-- the entry-code step that follows (verify_ticket_otp) reported 'already_checked_in' instead of ever verifying a code.
-- The 'expired' path has been like this since 20260728, 'code_required' since 20260821.
--
-- The fix is two added `return;` lines. Everything else is the definition from 20260821_ticket_otp_access_codes.sql.
--
-- WHY THIS IS GUARDED: the project is shared and not every change to the live database is in a migration, so the live
-- checkin_ticket() may not be the one this repository describes. Replacing it blindly could silently undo a hot-fix.
-- So this migration replaces the function only if the live one is EXACTLY the version it was written against (compared
-- on its body with whitespace ignored, plus security definer and search_path). It then:
--   * live function is the old repository version  -> replaced with the fixed one
--   * live function already has the fix            -> nothing to do (safe to run twice, or after fixing it by hand)
--   * live function is anything else               -> STOPS with an error and changes nothing, so a person can look
--                                                     at it (\sf public.checkin_ticket) and reconcile by hand
--
-- Numbered to sort before the unapplied tenancy migrations, so applying this first does not put those out of order.
--
-- Scans that were wrongly admitted BEFORE this fix are not repaired here (that is a decision about real guests, not a
-- schema change). To see them, run supabase/audit/checkin_fallthrough.sql (read-only).

do $migration$
declare
  v_live text;
  c_before constant text := '553484477fdc48844c3595be7cd1543f';  -- the 20260821 definition
  c_after  constant text := '28d05a7c0699859b4d97f3e6fed6effd';  -- the same, with the two returns added
begin
  select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
  into v_live
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'checkin_ticket'
    and pg_get_function_identity_arguments(p.oid) = 'p_ticket_code text';

  if v_live is null then
    raise exception 'public.checkin_ticket(text) does not exist in this database. Nothing was changed.';
  end if;

  if v_live = c_after then
    raise notice 'checkin_ticket() already has this fix; nothing to do.';
    return;
  end if;

  if v_live <> c_before then
    raise exception
      'checkin_ticket() in this database differs from the version this fix was written against (live fingerprint %, expected %). '
      'It was NOT replaced, because that could undo a change made directly in the database. '
      'Inspect it with \sf public.checkin_ticket, then either add the two missing "return;" lines by hand '
      '(after the ''expired'' and ''code_required'' RETURN QUERY lines) or reconcile and re-run. Nothing was changed.',
      v_live, c_before;
  end if;

  execute $fn$
    create or replace function public.checkin_ticket(p_ticket_code text)
    returns table(result text, customer_name text, event_title text, tier_name text, quantity int)
    language plpgsql
    security definer
    set search_path = public
    as $$
    declare
      v_order record;
      v_result text;
      v_effective_end timestamptz;
    begin
      if not (public.is_cms_admin() or public.is_door_staff()) then
        raise exception 'not authorized';
      end if;

      select o.id, o.status, o.checked_in_at, o.customer_name, o.quantity,
             o.is_non_transferable, o.access_code_verified,
             e.title as event_title, e.start_date, e.end_date, t.name as tier_name
      into v_order
      from public.site_orders o
      join public.site_ticket_tiers t on t.id = o.tier_id
      join public.site_events e on e.id = o.event_id
      where o.ticket_code = p_ticket_code
      for update of o;

      if not found then
        v_result := 'not_found';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, null, auth.uid());
        return query select v_result, null::text, null::text, null::text, null::int;
      elsif v_order.status <> 'paid' then
        v_result := 'not_paid';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
      elsif v_order.checked_in_at is not null then
        v_result := 'already_checked_in';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
      else
        v_effective_end := coalesce(v_order.end_date, v_order.start_date + interval '12 hours');
        if now() > v_effective_end then
          v_result := 'expired';
          insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
            values (p_ticket_code, v_result, v_order.id, auth.uid());
          return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
          return;
        end if;

        if v_order.is_non_transferable and not v_order.access_code_verified then
          v_result := 'code_required';
          insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
            values (p_ticket_code, v_result, v_order.id, auth.uid());
          return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
          return;
        end if;

        update public.site_orders set checked_in_at = now(), checked_in_by = auth.uid() where id = v_order.id;
        v_result := 'ok';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity;
      end if;
    end;
    $$;
  $fn$;

  raise notice 'checkin_ticket() fixed: expired and code-protected tickets are now refused without being admitted.';
end
$migration$;
