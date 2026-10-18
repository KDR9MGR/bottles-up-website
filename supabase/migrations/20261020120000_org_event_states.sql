-- Where each of an organizer's events stands, and exactly what blocks publishing it (developer brief 15 Oct, section 10: "Statuses: Draft, Awaiting
-- Venue Approval, Ready to Publish, Live, Ended and Cancelled. Permit draft work while approval is pending and explain exactly what blocks publishing.").
--
-- list_org_event_states(org) answers for the events of an organizer's business (the organizer only, like list_org_events):
--   state     draft | awaiting_venue_approval | ready_to_publish | live | ended
--   blockers  what still stands between a draft and publishing, as keys the app words:
--               business_verification  the business is not verified yet
--               venue_request          no club has been asked to host the event
--               venue_declined         the club that was asked declined (or the request was cancelled)
--               venue_approval         a club was asked and has not agreed terms yet
--   agreement_id / agreement_status / venue_name: the club connection behind it, when there is one.
--
-- Worked out from what exists, never stored: an event is LIVE when it is published and has not ended (it ended when its end time passed, or 12 hours
-- after it started when it has none, the same rule the app uses), READY TO PUBLISH only when the business is verified AND a club has agreed terms (an
-- active agreement, or one with changes proposed on top of an agreed version), AWAITING VENUE APPROVAL while a club has been asked and has not agreed.
-- A published event has no blockers. "Cancelled" is not here: events have no cancelled status in the database yet, so none is shown rather than guessed.
-- Publishing itself is still done by the BottlesUp team (an organizer cannot publish). Plain CREATE FUNCTION; read only.

create function public.list_org_event_states(p_org uuid)
returns table (event_id uuid, state text, blockers text[], agreement_id uuid, agreement_status text, venue_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_verified boolean;
begin
  perform public.require_org_organizer(p_org);
  select coalesce((select v.state = 'verified' from public.site_verifications v where v.org_id = p_org), false) into v_verified;

  return query
  select e.id,
         case
           when e.status = 'published' then
             case when coalesce(e.end_date, e.start_date + interval '12 hours') < now() then 'ended' else 'live' end
           when a.status in ('requested', 'negotiating') or (a.status = 'changes_pending' and a.active_version is null) then 'awaiting_venue_approval'
           when (a.status = 'active' or (a.status = 'changes_pending' and a.active_version is not null)) and v_verified then 'ready_to_publish'
           else 'draft'
         end,
         case
           when e.status = 'published' then '{}'::text[]
           else array_remove(array[
                  case when not v_verified then 'business_verification' end,
                  case when a.id is null and d.id is null then 'venue_request' end,
                  case when a.id is null and d.id is not null then 'venue_declined' end,
                  case when a.status in ('requested', 'negotiating') or (a.status = 'changes_pending' and a.active_version is null) then 'venue_approval' end
                ], null)
         end,
         coalesce(a.id, d.id),
         coalesce(a.status, d.status),
         ven.name
    from public.site_events e
    left join lateral (
      select ag.* from public.site_agreements ag
       where ag.event_id = e.id and ag.organizer_org_id = p_org and ag.status not in ('declined', 'cancelled')
       -- an event asked of two clubs follows the one that has agreed; otherwise the most recent request
       order by (ag.status = 'active' or (ag.status = 'changes_pending' and ag.active_version is not null)) desc, ag.requested_at desc limit 1
    ) a on true
    left join lateral (
      select ag.* from public.site_agreements ag
       where ag.event_id = e.id and ag.organizer_org_id = p_org and ag.status in ('declined', 'cancelled')
       order by ag.closed_at desc limit 1
    ) d on true
    left join public.site_venues ven on ven.id = coalesce(a.venue_id, d.venue_id)
   where e.org_id = p_org
   order by e.start_date desc, e.created_at desc;
end;
$$;

revoke all on function public.list_org_event_states(uuid) from public, anon;
grant execute on function public.list_org_event_states(uuid) to authenticated, service_role;
