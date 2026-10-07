-- READ-ONLY. Run in the Supabase SQL editor. Changes nothing (the transaction is read-only and rolled back).
--
-- verify_ticket_otp() used to skip the "has the event ended?" check that checkin_ticket() has (fixed by
-- supabase/migrations/20260830130000_fix_verify_ticket_otp_expiry.sql). A correct entry code therefore admitted a guest of an
-- event that was already over. This lists guests whose entry code was accepted AFTER their event's end time.
--
-- Honest limits. Of the three defects fixed in that migration only this one leaves a trace to find:
--   * an ordinary ticket answered "ok" without being marked used           -> leaves nothing in the data
--   * a call with no code at all admitting the guest                       -> looks exactly like a normal code entry
-- and the scanner screen never reaches any of the three (it only asks for a code after a "code required" answer), so these
-- were only possible by calling the function directly. An empty result here is good news, not proof about the other two.

begin read only;

select e.title                       as event,
       e.end_date,
       e.start_date,
       o.ticket_code,
       o.quantity,
       o.access_code_verified_at     as code_accepted_at,
       o.checked_in_at,
       u.email                       as admitted_by
from public.site_orders o
join public.site_events e on e.id = o.event_id
left join auth.users u on u.id = o.checked_in_by
where o.access_code_verified_at is not null
  and o.access_code_verified_at > coalesce(e.end_date, e.start_date + interval '12 hours')
order by o.access_code_verified_at desc;

rollback;
