-- Fix: verify_ticket_otp() ignored whether the event was over, "admitted" ordinary tickets without recording it, and let a
-- missing code through.
--
-- Three defects in the entry-code check (20260821_ticket_otp_access_codes.sql), all on paths the scanner screen does not
-- normally reach but a door person can call directly:
--
--   1. NO EXPIRY CHECK. checkin_ticket() refuses a ticket once its event has ended; verify_ticket_otp() never looked. A
--      correct code therefore admitted a guest of an event that was over. It now refuses with 'expired', in the same place
--      in the order of checks as checkin_ticket(): not found, not paid, already checked in, EXPIRED, then the ticket kind.
--      It decides this before looking at the code, so refusing does not burn the guest's code or spend one of their tries.
--
--   2. AN ORDINARY TICKET WAS "OK" BUT NEVER MARKED USED. For a ticket that is not non-transferable the function answered
--      'ok' and returned without recording the entry, so the same ticket could be "admitted" again and again. It now admits
--      it for real (marks it checked in, by whom, and logs it), exactly as a scan would.
--
--   3. A MISSING CODE ADMITTED THE GUEST. crypt(NULL, hash) is NULL, and NULL <> hash is not true, so a call with no code
--      skipped the wrong-code branch and carried on to admit the guest. A missing code is now an incorrect one, and spends a try.
--
-- Everything else, including the three-tries lockout and the five-minute code life, is the existing definition unchanged.
--
-- WHY THIS IS GUARDED: this replaces a LIVE function, and the live one may not be the version this repository describes (not
-- every change to the live database is in a migration). Same compare-and-swap as 20260830120000_fix_checkin_ticket_early_returns.sql:
--   * live function is the old repository version  -> replaced with the fixed one
--   * live function already has the fix            -> nothing to do (safe to run twice)
--   * live function is anything else               -> STOPS with an error and changes nothing; inspect it with
--                                                     \sf public.verify_ticket_otp and reconcile by hand
-- The comparison is on the body with whitespace ignored, plus security definer and search_path. Existing privileges are kept.

do $migration$
declare
  v_live text;
  c_before constant text := '842493fc4bcab29b5acfc94775929bad';  -- the 20260821 definition
  c_after  constant text := 'c109bccac3091ce5bdf9dcec1a4f7f7f';  -- the same, with the three fixes
begin
  select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
  into v_live
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'verify_ticket_otp'
    and pg_get_function_identity_arguments(p.oid) = 'p_ticket_code text, p_code text';

  if v_live is null then
    raise exception 'public.verify_ticket_otp(text, text) does not exist in this database. Nothing was changed.';
  end if;

  if v_live = c_after then
    raise notice 'verify_ticket_otp() already has this fix; nothing to do.';
    return;
  end if;

  if v_live <> c_before then
    raise exception
      'verify_ticket_otp() in this database differs from the version this fix was written against (live fingerprint %, expected %). '
      'It was NOT replaced, because that could undo a change made directly in the database. '
      'Inspect it with \sf public.verify_ticket_otp, then apply the three changes by hand (an expiry check before the ticket-kind check, '
      'marking an ordinary ticket checked in, and treating a missing code as incorrect) or reconcile and re-run. Nothing was changed.',
      v_live, c_before;
  end if;

  execute $fn$
    create or replace function public.verify_ticket_otp(p_ticket_code text, p_code text)
    returns table(result text, customer_name text, event_title text, tier_name text, quantity int, attempts_remaining int)
    language plpgsql
    security definer
    set search_path = public
    as $$
    declare
      v_order record;
      v_otp record;
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
        return query select 'not_found', null::text, null::text, null::text, null::int, null::int;
        return;
      elsif v_order.status <> 'paid' then
        return query select 'not_paid', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
        return;
      elsif v_order.checked_in_at is not null then
        return query select 'already_checked_in', v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
        return;
      end if;

      -- An event that has ended admits nobody, whatever the code. Decided before the code is looked at, so a refusal does not
      -- burn the guest's code or spend one of their tries.
      v_effective_end := coalesce(v_order.end_date, v_order.start_date + interval '12 hours');
      if now() > v_effective_end then
        v_result := 'expired';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
        return;
      end if;

      -- An ordinary ticket needs no code: admit it, exactly as a scan would (it used to answer ok without recording the entry).
      if not v_order.is_non_transferable then
        update public.site_orders set checked_in_at = now(), checked_in_by = auth.uid() where id = v_order.id;
        v_result := 'ok';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
        return;
      end if;

      select * into v_otp
      from public.ticket_otp_codes
      where order_id = v_order.id
      order by created_at desc
      limit 1
      for update;

      if not found or v_otp.status = 'expired' then
        v_result := 'no_code_requested';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
        return;
      end if;

      if v_otp.status = 'verified' or now() > v_otp.expires_at then
        if v_otp.status <> 'verified' then
          update public.ticket_otp_codes set status = 'expired' where id = v_otp.id;
        end if;
        v_result := 'code_expired';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
        return;
      end if;

      if v_otp.attempts >= v_otp.max_attempts then
        update public.ticket_otp_codes set status = 'expired' where id = v_otp.id;
        v_result := 'code_expired';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
        return;
      end if;

      -- coalesce: crypt() of a missing code is NULL, and NULL <> hash is not true, which used to fall through to "admit".
      if crypt(coalesce(p_code, ''), v_otp.code_hash) <> v_otp.code_hash then
        update public.ticket_otp_codes set attempts = attempts + 1 where id = v_otp.id;
        v_result := 'code_incorrect';
        insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
          values (p_ticket_code, v_result, v_order.id, auth.uid());
        return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity,
          (v_otp.max_attempts - (v_otp.attempts + 1));
        return;
      end if;

      update public.ticket_otp_codes
        set status = 'verified', verified_at = now(), verified_by = auth.uid()
        where id = v_otp.id;
      update public.site_orders
        set access_code_verified = true, access_code_verified_at = now(),
            checked_in_at = now(), checked_in_by = auth.uid()
        where id = v_order.id;

      v_result := 'ok';
      insert into public.scan_attempts (ticket_code_attempted, result, order_id, scanned_by)
        values (p_ticket_code, v_result, v_order.id, auth.uid());
      return query select v_result, v_order.customer_name, v_order.event_title, v_order.tier_name, v_order.quantity, null::int;
    end;
    $$;
  $fn$;

  raise notice 'verify_ticket_otp() fixed: an ended event admits nobody, an ordinary ticket is really marked used, and a missing code is not a right code.';
end
$migration$;
