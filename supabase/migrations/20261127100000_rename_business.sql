-- Renaming a business from the Business app (developer fix list, 22 Nov 2026, item 4).
--
-- WHY: nothing in the database let a business change its name: site_organizations has no direct writes from the apps, and only BottlesUp could rename one by hand.
--
-- WHAT THIS ADDS: one function, rename_business(p_org, p_name), and one column, site_organizations.name_changed_at (null = never renamed).
--
-- WHO: the business's own owner (a venue business) or organizer (an event business): the person create_organization() made, because nobody is ever invited into those two roles. Managers, door
-- staff and everybody else are refused, and so is an owner whose access is limited to one venue, one event or a shift.
--
-- THE NAME: spaces are tidied (trimmed, runs of spaces made one), 2 to 80 characters, no control characters. No other business may already use it (ignoring capitals and extra spaces), so one
-- business cannot take another's name. It must be a change: the same name is refused.
--
-- HOW OFTEN: once every 30 days, so a name cannot be swapped back and forth to pass as another business. Changing only the capitals or the spacing of the same name (fixing a typo) is always
-- allowed and does not start the 30 days.
--
-- WHAT IT CHANGES: the business's name, and the copy of the organizer's name that its events carry (site_events.organizer_name) for every event that has NOT started yet or is still a draft.
-- An event that has already started or finished keeps the name it was held under. Everything that looks the business up by id (agreements, settlements, team lists, report e-mails) shows the
-- new name from now on, because that is the one place it is stored: this migration does not copy it anywhere else.
--
-- It is recorded in audit_log ('business.renamed', with the old name, the new name and how many events were updated).
--
-- Plain CREATE, never CREATE OR REPLACE, so a name collision in the shared database fails loudly.

alter table public.site_organizations add column name_changed_at timestamptz;

create function public.rename_business(p_org uuid, p_name text)
returns table (new_name text, events_updated int, can_change_again_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.site_organizations;
  v_new text;
  v_old_key text;
  v_new_key text;
  v_count int := 0;
  v_now timestamptz := now();
  v_only_tidy boolean;
  v_next timestamptz;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_org is null then raise exception 'not allowed'; end if;

  -- Only the business's own owner or organizer, with access to the whole business (not one venue, one event or one shift), and only while that access is valid.
  if not exists (
    select 1 from public.active_memberships() m
    where m.org_id = p_org and m.role in ('owner', 'organizer') and m.venue_id is null and m.event_id is null and m.shift_id is null
  ) then
    raise exception 'not allowed';
  end if;

  -- Tidy the name: control characters are refused, runs of spaces become one.
  if p_name is null then raise exception 'the business name must be at least 2 characters'; end if;
  if p_name ~ '[[:cntrl:]]' then raise exception 'the business name has characters that are not allowed'; end if;
  v_new := regexp_replace(btrim(p_name), '\s+', ' ', 'g');
  if length(v_new) < 2 then raise exception 'the business name must be at least 2 characters'; end if;
  if length(v_new) > 80 then raise exception 'the business name can be at most 80 characters'; end if;

  v_new_key := lower(v_new);

  -- One rename of one name at a time, so two businesses cannot both take a free name in the same moment.
  perform pg_advisory_xact_lock(hashtext('rename_business:' || v_new_key));

  select * into v_org from public.site_organizations o where o.id = p_org for update;
  if not found then raise exception 'not allowed'; end if;

  v_old_key := lower(regexp_replace(btrim(v_org.name), '\s+', ' ', 'g'));
  v_only_tidy := (v_old_key = v_new_key);

  if v_org.name = v_new then raise exception 'that is already the name of this business'; end if;

  if not v_only_tidy then
    if exists (
      select 1 from public.site_organizations o
      where o.id <> p_org and lower(regexp_replace(btrim(o.name), '\s+', ' ', 'g')) = v_new_key
    ) then
      raise exception 'another business already uses that name. Choose a different one';
    end if;

    if v_org.name_changed_at is not null and v_org.name_changed_at > v_now - interval '30 days' then
      raise exception 'the name was changed on %. It can be changed again from %',
        to_char(v_org.name_changed_at at time zone 'UTC', 'FMDD FMMonth YYYY'),
        to_char((v_org.name_changed_at + interval '30 days') at time zone 'UTC', 'FMDD FMMonth YYYY');
    end if;
  end if;

  update public.site_organizations o
     set name = v_new,
         name_changed_at = case when v_only_tidy then o.name_changed_at else v_now end
   where o.id = p_org;

  -- The events carry a copy of the organizer's name: refresh it for the ones that have not started (and drafts), leave the ones already held as they were.
  update public.site_events e
     set organizer_name = v_new
   where e.org_id = p_org
     and (e.status = 'draft' or e.start_date > v_now);
  get diagnostics v_count = row_count;

  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (
    auth.uid(),
    coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'),
    'business.renamed',
    'site_organizations',
    p_org::text,
    jsonb_build_object('old_name', v_org.name, 'new_name', v_new, 'events_updated', v_count, 'tidy_only', v_only_tidy)
  );

  v_next := case when v_only_tidy then v_org.name_changed_at + interval '30 days' else v_now + interval '30 days' end;
  return query select v_new, v_count, v_next;
end;
$$;

revoke all on function public.rename_business(uuid, text) from public, anon;
grant execute on function public.rename_business(uuid, text) to authenticated, service_role;
