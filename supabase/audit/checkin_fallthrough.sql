-- READ-ONLY. Run in the Supabase SQL editor. Changes nothing (the transaction is read-only and rolled back).
--
-- checkin_ticket() used to admit tickets it had just refused (see
-- supabase/migrations/20260830120000_fix_checkin_ticket_early_returns.sql). In that case one scan wrote TWO log rows in the
-- same instant: the refusal ('expired' or 'code_required') and an 'ok'. This finds those scans, so you can see what the bug
-- actually did to real guests before deciding whether anything needs repairing.
--
-- What each kind means:
--   expired        the guest was turned away (the scanner showed "Event has ended"), but the order was ALSO marked checked in.
--                  Harmless to entry; it only makes the order look used.
--   code_required  a non-transferable ticket was marked checked in by the first scan, before its entry code was verified.
--                  The scanner then asked for the code, the code step answered "already checked in", and the code was never
--                  checked. Staff had to decide by eye. This is the one that matters.

begin read only;

-- 1. How many scans, and how many orders, were affected.
select
  count(*) filter (where a.result = 'expired')       as refused_as_expired_but_admitted,
  count(*) filter (where a.result = 'code_required') as refused_for_code_but_admitted,
  count(distinct a.order_id)                         as orders_affected,
  min(a.created_at)                                  as first_affected_scan,
  max(a.created_at)                                  as last_affected_scan
from public.scan_attempts a
join public.scan_attempts b on b.order_id = a.order_id and b.created_at = a.created_at and b.result = 'ok'
where a.result in ('expired', 'code_required');

-- 2. Each affected scan, newest first. Look at the code_required rows on events that have not finished yet.
select a.created_at       as scanned_at,
       a.result           as refused_as,
       e.title            as event,
       e.start_date       as event_starts,
       o.ticket_code,
       t.name             as tier,
       o.quantity,
       o.is_non_transferable,
       o.access_code_verified,
       o.checked_in_at,
       (select otp.status from public.ticket_otp_codes otp where otp.order_id = o.id order by otp.created_at desc limit 1) as latest_code_status,
       u.email            as scanned_by
from public.scan_attempts a
join public.scan_attempts b on b.order_id = a.order_id and b.created_at = a.created_at and b.result = 'ok'
join public.site_orders o on o.id = a.order_id
join public.site_events e on e.id = o.event_id
join public.site_ticket_tiers t on t.id = o.tier_id
left join auth.users u on u.id = a.scanned_by
where a.result in ('expired', 'code_required')
order by a.created_at desc;

-- 3. Non-transferable tickets that are checked in WITHOUT a verified entry code, whatever the cause. Any of these on an
--    event that is still to come is a guest who would now be told "already checked in" when they try to enter.
select e.title as event, e.start_date as event_starts, o.ticket_code, o.quantity, o.checked_in_at
from public.site_orders o
join public.site_events e on e.id = o.event_id
where o.is_non_transferable and o.checked_in_at is not null and not o.access_code_verified
order by e.start_date desc, o.checked_in_at desc;

rollback;
