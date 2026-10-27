-- Safety and moderation (customer app completion plan, M5; the stores require reporting, blocking and removal of user content).
--
--   * REPORTING: a person reports a post, a story, a comment, a profile, a message, a review or a job listing they can SEE, with a reason and optional words. One report from one profile for
--     one thing (a second one is the same report, said back as "already"); 20 reports a day from one profile; never your own. The words the reported thing said are
--     copied into the report, so BottlesUp can still read it after it is deleted. Reporting never asks for the community rules, and the person is never told what happened.
--   * THE QUEUE is for BottlesUp admins (cms_admins) only: reports are grouped by the thing reported, oldest first, with how many people reported it and why. Reporters are
--     counted, never named. An admin dismisses the reports, removes the content, suspends the person, or restores what was removed or suspended; each choice is written to
--     the audit log with a note. Nothing is removed automatically: a number of reports is a reason to look, not a verdict.
--   * SUSPENDING a person suspends every profile that login owns (the personal profile and the professional ones), because blocking works the same way (20261101110000).
--     A suspended profile is hidden from everyone else and cannot act; the login itself keeps working for tickets and bookings. A venue's or an event group's profile is
--     run by a team, so it is suspended on its own.
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

create table public.site_reports (
  id uuid primary key default gen_random_uuid(),
  -- The profile that reported; kept as null if that account is deleted, so the report survives.
  reporter uuid references public.site_profiles (id) on delete set null,
  kind text not null check (kind in ('post', 'comment', 'profile', 'message', 'review', 'job')),
  target uuid not null,
  -- Whose content it is (or the profile itself); null once that account is deleted.
  target_profile uuid references public.site_profiles (id) on delete set null,
  reason text not null check (reason in ('spam', 'harassment', 'hate', 'sexual', 'violence', 'scam', 'impersonation', 'self_harm', 'other')),
  details text check (details is null or char_length(btrim(details)) between 1 and 500),
  -- What the reported thing said when it was reported.
  excerpt text check (excerpt is null or char_length(excerpt) <= 500),
  status text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  action text check (action in ('removed', 'suspended', 'dismissed', 'restored')),
  note text check (note is null or char_length(note) <= 500),
  handled_by uuid references auth.users (id) on delete set null,
  handled_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  constraint site_reports_handled check ((status = 'open') = (handled_at is null))
);
create unique index site_reports_one_per_reporter on public.site_reports (reporter, kind, target) where reporter is not null;
create index site_reports_open_idx on public.site_reports (created_at, id) where status = 'open';
create index site_reports_target_idx on public.site_reports (kind, target);
create index site_reports_reporter_day_idx on public.site_reports (reporter, created_at desc);

alter table public.site_reports enable row level security;
revoke all on table public.site_reports from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Reporting
-- ---------------------------------------------------------------------------
create function public.report_create(p_actor uuid, p_kind text, p_target uuid, p_reason text, p_details text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_details text := nullif(btrim(coalesce(p_details, '')), '');
  v_owner uuid;
  v_excerpt text;
  v_id uuid;
begin
  perform public.profile_require_actor(p_actor);
  if not public.feature_enabled('social') then raise exception 'Reporting is not open yet.'; end if;
  if p_kind is null or p_kind not in ('post', 'comment', 'profile', 'message', 'review', 'job') then raise exception 'Say what you are reporting.'; end if;
  if p_reason is null or p_reason not in ('spam', 'harassment', 'hate', 'sexual', 'violence', 'scam', 'impersonation', 'self_harm', 'other') then raise exception 'Choose a reason.'; end if;
  if v_details is not null and char_length(v_details) > 500 then raise exception 'Keep it to 500 characters.'; end if;
  if p_target is null then raise exception 'This isn''t available.'; end if;

  -- Only what the reporter can see can be reported, and the answer for anything else is one sentence.
  if p_kind = 'post' then
    if not public.post_visible(p_actor, p_target) then raise exception 'This isn''t available.'; end if;
    select p.author, coalesce(left(p.caption, 500), '(' || p.kind || ' with no caption)') into v_owner, v_excerpt from public.site_posts p where p.id = p_target;
  elsif p_kind = 'comment' then
    select c.author, left(c.body, 500) into v_owner, v_excerpt
    from public.site_comments c
    where c.id = p_target and c.status = 'active' and public.post_visible(p_actor, c.post) and public.profile_visible(p_actor, c.author);
  elsif p_kind = 'profile' then
    if public.profile_visible(p_actor, p_target) then
      v_owner := p_target;
      select left((public.profile_mini(p_target) ->> 'display_name') || ' (@' || (public.profile_mini(p_target) ->> 'handle') || ')', 500) into v_excerpt;
    end if;
  elsif p_kind = 'message' then
    select m.sender, left(case when m.kind = 'text' then m.body else '[shared ' || m.kind || '] ' || coalesce(m.body, '') end, 500) into v_owner, v_excerpt
    from public.site_dm_messages m
    where m.id = p_target and m.deleted_at is null and public.dm_is_member(p_actor, m.conversation);
  elsif p_kind = 'job' then
    select j.poster, left(j.title || ': ' || j.description, 500) into v_owner, v_excerpt
    from public.site_jobs j
    where j.id = p_target and public.job_visible(p_actor, j.id);
  else
    select r.author, left('Rating ' || r.rating || '/5: ' || coalesce(r.body, ''), 500) into v_owner, v_excerpt
    from public.site_reviews r
    where r.id = p_target and r.status = 'active' and public.profile_visible(p_actor, r.author);
  end if;
  if v_owner is null then raise exception 'This isn''t available.'; end if;
  if public.profile_is_mine(v_owner) then raise exception 'You can''t report your own profile or what you wrote.'; end if;

  select r.id into v_id from public.site_reports r where r.reporter = p_actor and r.kind = p_kind and r.target = p_target;
  if v_id is not null then return jsonb_build_object('id', v_id, 'already', true); end if;

  if (select count(*) from public.site_reports r where r.reporter = p_actor and r.created_at > now() - interval '1 day') >= 20 then
    raise exception 'You have sent a lot of reports today. Our team is looking at them.';
  end if;

  insert into public.site_reports (reporter, kind, target, target_profile, reason, details, excerpt)
  values (p_actor, p_kind, p_target, v_owner, p_reason, v_details, v_excerpt)
  on conflict (reporter, kind, target) where reporter is not null do nothing
  returning id into v_id;
  if v_id is null then
    -- The same report arrived a moment ago from this profile.
    select r.id into v_id from public.site_reports r where r.reporter = p_actor and r.kind = p_kind and r.target = p_target;
    return jsonb_build_object('id', v_id, 'already', true);
  end if;
  return jsonb_build_object('id', v_id, 'already', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The queue (BottlesUp admins only)
-- ---------------------------------------------------------------------------
-- p_status is 'open', 'actioned', 'dismissed' or 'all'. Open ones come oldest first; the others newest handled first.
create function public.cms_reports_list(p_status text default 'open', p_limit int default 50, p_offset int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  if p_status is null or p_status not in ('open', 'actioned', 'dismissed', 'all') then raise exception 'Choose open, actioned, dismissed or all.'; end if;
  return coalesce((
    select jsonb_agg(g.item order by g.sort_key)
    from (
      select
        case when x.status = 'open' then extract(epoch from x.first_at) else -extract(epoch from x.handled_at) end as sort_key,
        jsonb_build_object(
          'kind', x.kind,
          'target', x.target,
          'status', x.status,
          'action', x.action,
          'note', x.note,
          'handled_at', x.handled_at,
          'reports', x.reports,
          'reporters', x.reporters,
          'reasons', x.reasons,
          'details', x.details,
          'excerpt', x.excerpt,
          'first_at', x.first_at,
          'last_at', x.last_at,
          'profile', case when x.target_profile is null then null else public.profile_mini(x.target_profile) || jsonb_build_object('status', (select s.status from public.site_profiles s where s.id = x.target_profile)) end,
          'state', case x.kind
            when 'post' then coalesce((select p.status from public.site_posts p where p.id = x.target), 'gone')
            when 'comment' then coalesce((select c.status from public.site_comments c where c.id = x.target), 'gone')
            when 'review' then coalesce((select r.status from public.site_reviews r where r.id = x.target), 'gone')
            when 'message' then coalesce((select case when m.deleted_at is null then 'active' else 'removed' end from public.site_dm_messages m where m.id = x.target), 'gone')
            when 'job' then coalesce((select case when j.status = 'removed' then 'removed' else 'active' end from public.site_jobs j where j.id = x.target), 'gone')
            else coalesce((select case when s.status = 'active' then 'active' else 'suspended' end from public.site_profiles s where s.id = x.target), 'gone')
          end
        ) as item
      from (
        select r.kind, r.target, r.status, r.handled_at,
               (array_agg(r.target_profile))[1] as target_profile,
               (array_agg(r.action))[1] as action,
               (array_agg(r.note))[1] as note,
               count(*)::int as reports,
               count(distinct r.reporter)::int as reporters,
               (select coalesce(jsonb_agg(d.reason order by d.reason), '[]'::jsonb) from (select distinct r2.reason from public.site_reports r2
                  where r2.kind = r.kind and r2.target = r.target and r2.status = r.status and r2.handled_at is not distinct from r.handled_at) d) as reasons,
               (select coalesce(jsonb_agg(d.details), '[]'::jsonb) from (select r2.details from public.site_reports r2
                  where r2.kind = r.kind and r2.target = r.target and r2.status = r.status and r2.handled_at is not distinct from r.handled_at and r2.details is not null
                  order by r2.created_at limit 5) d) as details,
               (array_agg(r.excerpt order by r.created_at))[1] as excerpt,
               min(r.created_at) as first_at,
               max(r.created_at) as last_at
        from public.site_reports r
        where p_status = 'all' or r.status = p_status
        group by r.kind, r.target, r.status, r.handled_at
      ) x
      order by 1
      limit v_limit offset v_offset
    ) g
  ), '[]'::jsonb);
end;
$$;

-- Every profile that belongs to the same PERSON as p_profile (see profile_key), or the profile alone for a venue's or an event group's.
create function public.moderation_person_profiles(p_profile uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select s.id from public.site_profiles s
  where s.id = p_profile or (s.user_id is not null and s.user_id = (select p.user_id from public.site_profiles p where p.id = p_profile))
$$;

-- Decide what happens to everything reported about one thing. p_action: 'dismiss' (nothing to do), 'remove' (a post, comment, message or review disappears for everyone),
-- 'suspend' (the person behind it, or the profile, is suspended) or 'restore' (undo a removal or a suspension). One note, written to the audit log.
create function public.cms_report_resolve(p_kind text, p_target uuid, p_action text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_profile uuid;
  v_open int;
  v_any int;
  v_n int;
  -- One moment for the whole decision, so the reports it settles stay together in the list.
  v_at timestamptz := clock_timestamp();
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;
  if p_kind is null or p_kind not in ('post', 'comment', 'profile', 'message', 'review', 'job') or p_target is null then raise exception 'Say what was reported.'; end if;
  if p_action is null or p_action not in ('dismiss', 'remove', 'suspend', 'restore') then raise exception 'Choose dismiss, remove, suspend or restore.'; end if;
  if v_note is not null and char_length(v_note) > 500 then raise exception 'Keep the note to 500 characters.'; end if;

  select count(*) filter (where r.status = 'open'), count(*), (array_agg(r.target_profile))[1]
  into v_open, v_any, v_profile
  from public.site_reports r where r.kind = p_kind and r.target = p_target;
  if v_any = 0 then raise exception 'Nobody has reported this.'; end if;
  if p_action <> 'restore' and v_open = 0 then raise exception 'These reports have already been handled.'; end if;

  if p_action = 'remove' then
    if p_kind = 'profile' then raise exception 'A profile is suspended, not removed.'; end if;
    if p_kind = 'post' then update public.site_posts set status = 'removed' where id = p_target;
    elsif p_kind = 'comment' then update public.site_comments set status = 'removed' where id = p_target;
    elsif p_kind = 'review' then update public.site_reviews set status = 'removed' where id = p_target;
    elsif p_kind = 'job' then update public.site_jobs set status = 'removed', closed_at = coalesce(closed_at, now()) where id = p_target;
    else update public.site_dm_messages set deleted_at = coalesce(deleted_at, now()) where id = p_target;
    end if;
  elsif p_action = 'suspend' then
    if v_profile is null then raise exception 'There is no profile left to suspend.'; end if;
    update public.site_profiles set status = 'suspended' where id in (select public.moderation_person_profiles(v_profile));
  elsif p_action = 'restore' then
    if p_kind = 'post' then update public.site_posts set status = 'active' where id = p_target;
    elsif p_kind = 'comment' then update public.site_comments set status = 'active' where id = p_target;
    elsif p_kind = 'review' then update public.site_reviews set status = 'active' where id = p_target;
    elsif p_kind = 'job' then update public.site_jobs set status = 'closed' where id = p_target and status = 'removed';
    elsif p_kind = 'message' then update public.site_dm_messages set deleted_at = null where id = p_target;
    end if;
    -- What was done to the person behind it is undone as well, whatever was reported.
    if v_profile is not null then
      update public.site_profiles set status = 'active' where id in (select public.moderation_person_profiles(v_profile));
    end if;
  end if;

  if p_action = 'restore' then
    update public.site_reports set status = 'dismissed', action = 'restored', note = v_note, handled_by = auth.uid(), handled_at = v_at
    where kind = p_kind and target = p_target and status = 'actioned';
  else
    update public.site_reports
    set status = case p_action when 'dismiss' then 'dismissed' else 'actioned' end,
        action = case p_action when 'dismiss' then 'dismissed' when 'remove' then 'removed' else 'suspended' end,
        note = v_note, handled_by = auth.uid(), handled_at = v_at
    where kind = p_kind and target = p_target and status = 'open';
  end if;
  get diagnostics v_n = row_count;

  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), 'report_' || p_action, 'report', p_target::text,
          jsonb_build_object('kind', p_kind, 'note', v_note, 'reports', v_n));
  return jsonb_build_object('handled', v_n);
end;
$$;

-- Find a profile by its username or name, to suspend or restore it without a report.
create function public.cms_find_profiles(p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := lower(btrim(coalesce(p_query, '')));
  -- What was typed is text to find, not a pattern: a percent sign or underscore matches itself.
  v_like text;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can see this.'; end if;
  if char_length(v_q) < 2 then raise exception 'Type at least 2 letters.'; end if;
  v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'handle', f.handle, 'display_name', f.name, 'category', f.category, 'status', f.status) order by f.handle)
    from (
      select p.id, p.kind, p.category, p.status,
             case p.kind when 'personal' then pr.username else p.handle end as handle,
             case p.kind when 'personal' then coalesce(nullif(btrim(pr.name), ''), pr.username) else p.display_name end as name
      from public.site_profiles p
      left join public.profiles pr on pr.id = p.user_id and p.kind = 'personal'
      where lower(case p.kind when 'personal' then pr.username else p.handle end) like v_like
         or lower(case p.kind when 'personal' then pr.name else p.display_name end) like v_like
      limit 20
    ) f
  ), '[]'::jsonb);
end;
$$;

-- Suspend or restore the person behind a profile directly (an appeal, or something a report did not catch).
create function public.cms_profile_set_status(p_profile uuid, p_suspended boolean, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_n int;
begin
  if auth.uid() is null or not public.is_cms_admin() then raise exception 'Only a BottlesUp admin can change this.'; end if;
  if p_suspended is null then raise exception 'Choose suspend or restore.'; end if;
  if v_note is not null and char_length(v_note) > 500 then raise exception 'Keep the note to 500 characters.'; end if;
  if not exists (select 1 from public.site_profiles s where s.id = p_profile) then raise exception 'There is no such profile.'; end if;
  update public.site_profiles set status = case when p_suspended then 'suspended' else 'active' end where id in (select public.moderation_person_profiles(p_profile));
  get diagnostics v_n = row_count;
  insert into public.audit_log (actor_id, actor_email, action, entity_type, entity_id, details)
  values (auth.uid(), coalesce(nullif(auth.jwt() ->> 'email', ''), 'unknown'), case when p_suspended then 'profile_suspended' else 'profile_restored' end, 'profile', p_profile::text,
          jsonb_build_object('note', v_note, 'profiles', v_n));
  return jsonb_build_object('profiles', v_n, 'suspended', p_suspended);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Daily housekeeping (a scheduled job, as the service role)
-- ---------------------------------------------------------------------------
-- Stories that expired more than p_story_days ago are deleted (they are hidden from everyone the moment they expire; this frees the rows, and their files become unused and are
-- removed by sweep-social-media); read notifications older than p_notification_days (never fewer than 7); caption-idea requests older than two days (they only count a day). The delivery address of a plaque that arrived 90 days ago is wiped.
-- Posts, comments, messages and reports are never touched here: reports are the evidence BottlesUp keeps.
create function public.social_housekeeping(p_story_days int default 7, p_notification_days int default 90)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stories int;
  v_notifications int;
  v_uses int;
  v_plaques int;
begin
  delete from public.site_posts where kind = 'story' and expires_at < now() - make_interval(days => greatest(coalesce(p_story_days, 7), 1));
  get diagnostics v_stories = row_count;
  v_notifications := public.notifications_purge(coalesce(p_notification_days, 90));
  delete from public.site_ai_caption_uses where created_at < now() - interval '2 days';
  get diagnostics v_uses = row_count;
  v_plaques := public.plaque_addresses_wipe();
  return jsonb_build_object('stories', v_stories, 'notifications', v_notifications, 'caption_uses', v_uses, 'plaque_addresses', v_plaques);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.report_create(uuid, text, uuid, text, text), public.cms_reports_list(text, int, int), public.moderation_person_profiles(uuid),
  public.cms_report_resolve(text, uuid, text, text), public.cms_find_profiles(text), public.cms_profile_set_status(uuid, boolean, text), public.social_housekeeping(int, int)
from public, anon, authenticated;
grant execute on function public.social_housekeeping(int, int) to service_role;
grant execute on function
  public.report_create(uuid, text, uuid, text, text), public.cms_reports_list(text, int, int),
  public.cms_report_resolve(text, uuid, text, text), public.cms_find_profiles(text), public.cms_profile_set_status(uuid, boolean, text)
to authenticated, service_role;
