-- Cancelling a business that was added by mistake.
--
-- Client feedback (10 Oct 2026): a venue owner created "Eonics Lounge" by mistake and could not leave the onboarding page
-- or get rid of the business. Nothing in the database let a person remove a business they had created: only the BottlesUp
-- team could, by hand.
--
-- WHAT THIS ALLOWS: the owner (or organizer) of a business that has NOT been verified (state not_submitted, or sent back with
-- more_information_needed) can cancel it. That deletes the business, the details they typed, their draft venues and draft
-- events, any pending venue requests and any unaccepted invitations. It is recorded in audit_log, because the verification
-- history goes with the business.
--
-- WHAT IT REFUSES, in a plain sentence each:
--   * a business under review or verified (it may have been relied on; the BottlesUp team handles those),
--   * a business that still has other active team members (their access would vanish without them being told),
--   * a business with a venue that is live, or an event that is published,
--   * a business whose draft venue or event already has records pointing at it (bookings, orders): the delete would fail
--     on a foreign key, which is turned into a sentence instead of a database error.
--
-- Plain CREATE, never CREATE OR REPLACE, so a name collision in the shared database fails loudly.

create function public.cancel_business(p_org uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.site_organizations;
  v_state text;
  v_venues int;
  v_events int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_org is null or not public.is_org_member(p_org, array['owner', 'organizer']) then raise exception 'not allowed'; end if;

  -- Lock the business and its verification so a submission cannot slip in while this runs.
  select * into v_org from public.site_organizations where id = p_org for update;
  if not found then raise exception 'business not found'; end if;
  select state into v_state from public.site_verifications where org_id = p_org for update;

  if v_state is null or v_state not in ('not_submitted', 'more_information_needed') then
    raise exception 'a business that is under review or verified cannot be cancelled here. Contact BottlesUp';
  end if;

  if exists (
    select 1 from public.site_memberships m
    where m.org_id = p_org and m.status = 'active' and m.user_id <> auth.uid()
  ) then
    raise exception 'this business still has team members. Remove them first';
  end if;

  if exists (select 1 from public.site_venues v where v.org_id = p_org and v.status <> 'draft') then
    raise exception 'this business has a live venue, so it cannot be cancelled here. Contact BottlesUp';
  end if;
  if exists (select 1 from public.site_events e where e.org_id = p_org and e.status <> 'draft') then
    raise exception 'this business has a published event, so it cannot be cancelled here. Contact BottlesUp';
  end if;

  select count(*)::int into v_venues from public.site_venues v where v.org_id = p_org;
  select count(*)::int into v_events from public.site_events e where e.org_id = p_org;

  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (
    auth.uid(),
    coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'),
    'business.cancelled',
    'site_organizations',
    p_org::text,
    jsonb_build_object('name', v_org.name, 'kind', v_org.kind, 'state', v_state, 'draft_venues', v_venues, 'draft_events', v_events)
  );

  begin
    delete from public.site_events where org_id = p_org;   -- drafts only, checked above; their ticket tiers go with them
    delete from public.site_venues where org_id = p_org;   -- drafts only; their setup rows go with them
    delete from public.site_organizations where id = p_org; -- memberships, details, verification, claims and invitations cascade
  exception when foreign_key_violation then
    raise exception 'this business already has records attached, such as bookings or orders, so it cannot be cancelled here. Contact BottlesUp';
  end;
end;
$$;

revoke all on function public.cancel_business(uuid) from public, anon;
grant execute on function public.cancel_business(uuid) to authenticated, service_role;
