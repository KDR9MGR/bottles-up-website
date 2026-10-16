-- Security (client Phase 2 brief, section 23, and the Security workspace: Alerts, Tasks, Chat, Incidents).
--
-- "Security flow: Shift -> Alert -> Acknowledge -> Location/details -> Respond -> Resolve/Escalate. Incident: New Report -> Location ->
-- Details -> Submit. Restrict finance access."
--
--   * ALERTS: anyone working at a club (server, security, manager, owner) can raise one: what kind, where, and whether it is urgent. Security,
--     the manager and the owner of THAT club take it (acknowledge), say they are responding, then resolve it (what was done) or escalate it to a
--     manager (why). Each step happens once: two people tapping Acknowledge at once end with one of them holding it and the other told who.
--     A server sees only the alerts they raised.
--   * TASKS: a manager or owner gives a task to a member of security (or leaves it for any of them); the person marks it done. Nobody but a
--     manager or owner cancels one.
--   * INCIDENTS: a report (what, where, when, details, what was done) that is KEPT: it cannot be edited or deleted through the app, and the
--     club cannot be deleted while it has any. Later facts are added as notes (append-only). A manager or owner reviews a report, never their own.
--   * Security can see NOTHING about money: none of the finance functions admit the security role, and this migration adds none.
--
-- Every step is attributed in the audit log. Plain CREATE, never CREATE OR REPLACE. Needs the tenancy and table service migrations.

-- ---------------------------------------------------------------------------
-- 1. Tables (reached only through the functions below)
-- ---------------------------------------------------------------------------
create table public.site_security_alerts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  business_night date not null,
  kind text not null check (kind in ('fight', 'medical', 'intoxicated', 'theft', 'crowd', 'other')),
  urgent boolean not null default false,
  location text not null check (char_length(btrim(location)) between 2 and 200),
  details text check (details is null or char_length(details) <= 1000),
  status text not null default 'open' check (status in ('open', 'acknowledged', 'responding', 'resolved', 'escalated')),
  raised_by uuid not null references auth.users (id),
  raised_at timestamptz not null default clock_timestamp(),
  acknowledged_by uuid references auth.users (id),
  acknowledged_at timestamptz,
  resolved_by uuid references auth.users (id),
  resolved_at timestamptz,
  resolution_note text check (resolution_note is null or char_length(resolution_note) <= 500),
  escalated_by uuid references auth.users (id),
  escalated_at timestamptz,
  escalation_note text check (escalation_note is null or char_length(escalation_note) <= 500),
  constraint site_security_alerts_resolved_together check ((status = 'resolved') = (resolved_by is not null and resolved_at is not null)),
  constraint site_security_alerts_taken_together check (status not in ('acknowledged', 'responding') or (acknowledged_by is not null and acknowledged_at is not null)),
  constraint site_security_alerts_escalated_together check (escalated_by is null or escalated_at is not null)
);
create index site_security_alerts_venue_night_idx on public.site_security_alerts (venue_id, business_night, status);

create table public.site_security_tasks (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id) on delete cascade,
  business_night date not null,
  title text not null check (char_length(btrim(title)) between 3 and 120),
  details text check (details is null or char_length(details) <= 500),
  assigned_to uuid references auth.users (id),
  status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default clock_timestamp(),
  closed_by uuid references auth.users (id),
  closed_at timestamptz,
  closing_note text check (closing_note is null or char_length(closing_note) <= 300),
  constraint site_security_tasks_closed_together check ((status = 'open') = (closed_by is null and closed_at is null))
);
create index site_security_tasks_venue_night_idx on public.site_security_tasks (venue_id, business_night, status);

-- Incident records are retained: no cascade from the club, and no function edits or deletes one.
create table public.site_security_incidents (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.site_venues (id),
  business_night date not null,
  kind text not null check (kind in ('fight', 'medical', 'intoxicated', 'theft', 'harassment', 'weapon', 'crowd', 'property', 'other')),
  occurred_at timestamptz not null,
  location text not null check (char_length(btrim(location)) between 2 and 200),
  details text not null check (char_length(btrim(details)) between 10 and 2000),
  actions_taken text check (actions_taken is null or char_length(actions_taken) <= 1000),
  reported_by uuid not null references auth.users (id),
  created_at timestamptz not null default clock_timestamp(),
  status text not null default 'submitted' check (status in ('submitted', 'reviewed')),
  reviewed_by uuid references auth.users (id),
  reviewed_at timestamptz,
  review_note text check (review_note is null or char_length(review_note) <= 500),
  constraint site_security_incidents_reviewed_together check ((status = 'reviewed') = (reviewed_by is not null and reviewed_at is not null)),
  constraint site_security_incidents_not_own_review check (reviewed_by is distinct from reported_by)
);
create index site_security_incidents_venue_idx on public.site_security_incidents (venue_id, created_at desc);

create table public.site_security_incident_notes (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.site_security_incidents (id),
  author_id uuid not null references auth.users (id),
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default clock_timestamp()
);
create index site_security_incident_notes_idx on public.site_security_incident_notes (incident_id, created_at);

alter table public.site_security_alerts enable row level security;
alter table public.site_security_tasks enable row level security;
alter table public.site_security_incidents enable row level security;
alter table public.site_security_incident_notes enable row level security;
revoke all on table public.site_security_alerts, public.site_security_tasks, public.site_security_incidents, public.site_security_incident_notes
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helper (the app cannot call it)
-- ---------------------------------------------------------------------------
-- Does this person (not the caller) hold this role at this club right now?
create function public.security_has_role(p_user uuid, p_venue uuid, p_role text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.site_memberships m
    left join public.site_shifts s on s.id = m.shift_id
    where m.user_id = p_user
      and m.role = p_role
      and m.venue_id = p_venue
      and m.status = 'active'
      and (m.access_start_at is null or now() >= m.access_start_at)
      and (m.access_end_at is null or now() <= m.access_end_at)
      and (m.shift_id is null or (now() >= s.starts_at and now() <= s.ends_at))
  )
$$;

revoke all on function public.security_has_role(uuid, uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Alerts
-- ---------------------------------------------------------------------------
create function public.security_raise_alert(p_venue uuid, p_night date, p_kind text, p_urgent boolean, p_location text, p_details text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_location text;
  v_details text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager', 'security', 'server']) then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if abs(p_night - current_date) > 2 then raise exception 'that is not a current night'; end if;
  if p_kind is null or p_kind not in ('fight', 'medical', 'intoxicated', 'theft', 'crowd', 'other') then raise exception 'choose what kind of alert this is'; end if;
  v_location := btrim(p_location);
  if v_location is null or char_length(v_location) < 2 then raise exception 'say where it is'; end if;
  if char_length(v_location) > 200 then raise exception 'keep the location to 200 characters or fewer'; end if;
  v_details := nullif(btrim(p_details), '');
  if v_details is not null and char_length(v_details) > 1000 then raise exception 'keep the details to 1000 characters or fewer'; end if;
  if (select count(*) from public.site_security_alerts a where a.raised_by = auth.uid() and a.raised_at > clock_timestamp() - interval '10 minutes') >= 10 then
    raise exception 'slow down: you have raised several alerts in the last few minutes';
  end if;

  insert into public.site_security_alerts (venue_id, business_night, kind, urgent, location, details, raised_by)
    values (p_venue, p_night, p_kind, coalesce(p_urgent, false), v_location, v_details, auth.uid())
    returning id into v_id;
  perform public.desk_log('security.alert_raised', 'site_security_alerts', v_id,
    jsonb_build_object('venue_id', p_venue, 'night', p_night, 'kind', p_kind, 'urgent', coalesce(p_urgent, false)));
  return v_id;
end;
$$;

-- The alerts of one night at a club. Security, manager and owner see all of them; a server sees the ones they raised.
create function public.security_alerts(p_venue uuid, p_night date)
returns table (
  alert_id uuid, kind text, urgent boolean, location text, details text, status text, raised_by_name text, raised_by_me boolean, raised_at timestamptz,
  acknowledged_by_name text, acknowledged_at timestamptz, resolved_by_name text, resolved_at timestamptz, resolution_note text,
  escalated_by_name text, escalated_at timestamptz, escalation_note text, can_act boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_all boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  v_all := public.can_access_venue(p_venue, array['owner', 'manager', 'security']);
  if not v_all and not public.can_access_venue(p_venue, array['server']) then raise exception 'not allowed'; end if;

  return query
    select a.id, a.kind, a.urgent, a.location, a.details, a.status,
           coalesce(nullif(btrim(pr.name), ''), 'Staff member'), a.raised_by = auth.uid(), a.raised_at,
           case when a.acknowledged_by is null then null else coalesce(nullif(btrim(pa.name), ''), 'Staff member') end, a.acknowledged_at,
           case when a.resolved_by is null then null else coalesce(nullif(btrim(ps.name), ''), 'Staff member') end, a.resolved_at, a.resolution_note,
           case when a.escalated_by is null then null else coalesce(nullif(btrim(pe.name), ''), 'Staff member') end, a.escalated_at, a.escalation_note,
           v_all
    from public.site_security_alerts a
    left join public.profiles pr on pr.id = a.raised_by
    left join public.profiles pa on pa.id = a.acknowledged_by
    left join public.profiles ps on ps.id = a.resolved_by
    left join public.profiles pe on pe.id = a.escalated_by
    where a.venue_id = p_venue and a.business_night = p_night and (v_all or a.raised_by = auth.uid())
    order by (a.status = 'resolved'), a.urgent desc, a.raised_at desc, a.id
    limit 200;
end;
$$;

-- Take it, respond, resolve or escalate. Each is a step in order; repeating a step that has already happened changes nothing.
create function public.security_alert_act(p_alert uuid, p_action text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.site_security_alerts;
  v_manager boolean;
  v_note text;
  v_status text;
  v_holder text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into a from public.site_security_alerts where id = p_alert for update;
  if not found or not public.can_access_venue(a.venue_id, array['owner', 'manager', 'security']) then raise exception 'not allowed'; end if;
  if p_action is null or p_action not in ('acknowledge', 'respond', 'resolve', 'escalate') then raise exception 'choose what to do with this alert'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 500 then raise exception 'keep the note to 500 characters or fewer'; end if;
  if a.status = 'resolved' then raise exception 'this alert is already resolved'; end if;
  v_manager := public.can_access_venue(a.venue_id, array['owner', 'manager']);

  if p_action = 'acknowledge' then
    if a.status <> 'open' then
      select coalesce(nullif(btrim(pr.name), ''), 'Staff member') into v_holder from public.profiles pr where pr.id = coalesce(a.acknowledged_by, a.escalated_by);
      return jsonb_build_object('changed', false, 'status', a.status, 'by_name', coalesce(v_holder, 'Staff member'));
    end if;
    update public.site_security_alerts set status = 'acknowledged', acknowledged_by = auth.uid(), acknowledged_at = clock_timestamp() where id = p_alert;
    v_status := 'acknowledged';

  elsif p_action = 'respond' then
    if a.status = 'responding' then return jsonb_build_object('changed', false, 'status', a.status); end if;
    if a.status = 'open' then raise exception 'take the alert first'; end if;
    if a.status = 'escalated' then raise exception 'this alert was escalated to a manager'; end if;
    update public.site_security_alerts set status = 'responding' where id = p_alert;
    v_status := 'responding';

  elsif p_action = 'resolve' then
    if a.status = 'open' then raise exception 'take the alert first'; end if;
    if a.status = 'escalated' and not v_manager then raise exception 'this alert was escalated: a manager resolves it'; end if;
    if a.status in ('acknowledged', 'responding') and not v_manager and a.acknowledged_by is distinct from auth.uid() then
      raise exception 'only the person who took this alert, or a manager, can resolve it';
    end if;
    if v_note is null or char_length(v_note) < 3 then raise exception 'say what was done'; end if;
    update public.site_security_alerts
      set status = 'resolved', resolved_by = auth.uid(), resolved_at = clock_timestamp(), resolution_note = v_note
      where id = p_alert;
    v_status := 'resolved';

  else
    if a.status = 'escalated' then return jsonb_build_object('changed', false, 'status', a.status); end if;
    if v_note is null or char_length(v_note) < 3 then raise exception 'say why this needs a manager'; end if;
    update public.site_security_alerts
      set status = 'escalated', escalated_by = auth.uid(), escalated_at = clock_timestamp(), escalation_note = v_note
      where id = p_alert;
    v_status := 'escalated';
  end if;

  perform public.desk_log('security.alert_' || p_action, 'site_security_alerts', p_alert,
    jsonb_build_object('venue_id', a.venue_id, 'from', a.status, 'to', v_status));
  return jsonb_build_object('changed', true, 'status', v_status);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Tasks
-- ---------------------------------------------------------------------------
create function public.security_create_task(p_venue uuid, p_night date, p_title text, p_details text default null, p_assignee uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text;
  v_details text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if abs(p_night - current_date) > 2 then raise exception 'that is not a current night'; end if;
  v_title := btrim(p_title);
  if v_title is null or char_length(v_title) < 3 then raise exception 'say what the task is'; end if;
  if char_length(v_title) > 120 then raise exception 'keep the title to 120 characters or fewer'; end if;
  v_details := nullif(btrim(p_details), '');
  if v_details is not null and char_length(v_details) > 500 then raise exception 'keep the details to 500 characters or fewer'; end if;
  if p_assignee is not null and not public.security_has_role(p_assignee, p_venue, 'security') then
    raise exception 'a task can only be given to someone on the security team of this club';
  end if;

  insert into public.site_security_tasks (venue_id, business_night, title, details, assigned_to, created_by)
    values (p_venue, p_night, v_title, v_details, p_assignee, auth.uid()) returning id into v_id;
  perform public.desk_log('security.task_created', 'site_security_tasks', v_id, jsonb_build_object('venue_id', p_venue, 'night', p_night, 'assigned_to', p_assignee));
  return v_id;
end;
$$;

-- Manager and owner see every task of the night; security sees the ones given to them and the ones nobody has taken yet.
create function public.security_tasks(p_venue uuid, p_night date)
returns table (
  task_id uuid, title text, details text, status text, assigned_to_name text, assigned_to_me boolean, unassigned boolean, created_by_name text,
  created_at timestamptz, closed_by_name text, closed_at timestamptz, closing_note text, can_manage boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_manager boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  v_manager := public.can_access_venue(p_venue, array['owner', 'manager']);
  if not v_manager and not public.can_access_venue(p_venue, array['security']) then raise exception 'not allowed'; end if;

  return query
    select t.id, t.title, t.details, t.status,
           case when t.assigned_to is null then null else coalesce(nullif(btrim(pt.name), ''), 'Staff member') end,
           t.assigned_to = auth.uid(), t.assigned_to is null,
           coalesce(nullif(btrim(pc.name), ''), 'Staff member'), t.created_at,
           case when t.closed_by is null then null else coalesce(nullif(btrim(px.name), ''), 'Staff member') end, t.closed_at, t.closing_note,
           v_manager
    from public.site_security_tasks t
    left join public.profiles pt on pt.id = t.assigned_to
    left join public.profiles pc on pc.id = t.created_by
    left join public.profiles px on px.id = t.closed_by
    where t.venue_id = p_venue and t.business_night = p_night
      and (v_manager or t.assigned_to = auth.uid() or t.assigned_to is null)
    order by (t.status <> 'open'), t.created_at desc, t.id
    limit 200;
end;
$$;

-- claim: take a task nobody has. done: finish one. cancel: a manager withdraws it.
create function public.security_task_act(p_task uuid, p_action text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.site_security_tasks;
  v_manager boolean;
  v_security boolean;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into t from public.site_security_tasks where id = p_task for update;
  if not found then raise exception 'not allowed'; end if;
  v_manager := public.can_access_venue(t.venue_id, array['owner', 'manager']);
  v_security := public.can_access_venue(t.venue_id, array['security']);
  if not v_manager and not v_security then raise exception 'not allowed'; end if;
  if p_action is null or p_action not in ('claim', 'done', 'cancel') then raise exception 'choose what to do with this task'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 300 then raise exception 'keep the note to 300 characters or fewer'; end if;

  if t.status <> 'open' then
    return jsonb_build_object('changed', false, 'status', t.status);
  end if;
  -- Security can only touch a task that is theirs or that nobody has taken.
  if not v_manager and t.assigned_to is not null and t.assigned_to <> auth.uid() then raise exception 'not allowed'; end if;

  if p_action = 'claim' then
    if t.assigned_to is not null then
      if t.assigned_to = auth.uid() then return jsonb_build_object('changed', false, 'status', t.status); end if;
      raise exception 'this task is already given to someone';
    end if;
    if not v_security then raise exception 'only the security team takes tasks'; end if;
    update public.site_security_tasks set assigned_to = auth.uid() where id = p_task;
    perform public.desk_log('security.task_claimed', 'site_security_tasks', p_task, jsonb_build_object('venue_id', t.venue_id));
    return jsonb_build_object('changed', true, 'status', 'open');
  elsif p_action = 'done' then
    update public.site_security_tasks
      set status = 'done', closed_by = auth.uid(), closed_at = clock_timestamp(), closing_note = v_note,
          assigned_to = coalesce(assigned_to, case when v_security then auth.uid() end)
      where id = p_task;
    perform public.desk_log('security.task_done', 'site_security_tasks', p_task, jsonb_build_object('venue_id', t.venue_id));
    return jsonb_build_object('changed', true, 'status', 'done');
  else
    if not v_manager then raise exception 'only a manager or the owner cancels a task'; end if;
    update public.site_security_tasks set status = 'cancelled', closed_by = auth.uid(), closed_at = clock_timestamp(), closing_note = v_note where id = p_task;
    perform public.desk_log('security.task_cancelled', 'site_security_tasks', p_task, jsonb_build_object('venue_id', t.venue_id));
    return jsonb_build_object('changed', true, 'status', 'cancelled');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Incidents (retained records)
-- ---------------------------------------------------------------------------
create function public.security_report_incident(
  p_venue uuid, p_night date, p_kind text, p_occurred_at timestamptz, p_location text, p_details text, p_actions_taken text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_location text;
  v_details text;
  v_actions text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_venue is null or not public.can_access_venue(p_venue, array['owner', 'manager', 'security']) then raise exception 'not allowed'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if abs(p_night - current_date) > 2 then raise exception 'that is not a current night'; end if;
  if p_kind is null or p_kind not in ('fight', 'medical', 'intoxicated', 'theft', 'harassment', 'weapon', 'crowd', 'property', 'other') then
    raise exception 'choose what kind of incident this is';
  end if;
  if p_occurred_at is null then raise exception 'say when it happened'; end if;
  if p_occurred_at > now() + interval '5 minutes' then raise exception 'an incident cannot have happened in the future'; end if;
  if p_occurred_at < now() - interval '3 days' then raise exception 'an incident more than 3 days old cannot be reported here'; end if;
  v_location := btrim(p_location);
  if v_location is null or char_length(v_location) < 2 then raise exception 'say where it happened'; end if;
  if char_length(v_location) > 200 then raise exception 'keep the location to 200 characters or fewer'; end if;
  v_details := btrim(p_details);
  if v_details is null or char_length(v_details) < 10 then raise exception 'describe what happened (at least 10 characters)'; end if;
  if char_length(v_details) > 2000 then raise exception 'keep the details to 2000 characters or fewer'; end if;
  v_actions := nullif(btrim(p_actions_taken), '');
  if v_actions is not null and char_length(v_actions) > 1000 then raise exception 'keep what was done to 1000 characters or fewer'; end if;

  insert into public.site_security_incidents (venue_id, business_night, kind, occurred_at, location, details, actions_taken, reported_by)
    values (p_venue, p_night, p_kind, p_occurred_at, v_location, v_details, v_actions, auth.uid()) returning id into v_id;
  perform public.desk_log('security.incident_reported', 'site_security_incidents', v_id, jsonb_build_object('venue_id', p_venue, 'night', p_night, 'kind', p_kind));
  return v_id;
end;
$$;

-- Newest first. Security, manager and owner of the club.
create function public.security_incidents(p_venue uuid, p_limit int default 50, p_before timestamptz default null)
returns table (
  incident_id uuid, business_night date, kind text, occurred_at timestamptz, location text, status text, reported_by_name text, reported_by_me boolean,
  created_at timestamptz, note_count int, reviewed_by_name text, reviewed_at timestamptz, can_review boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_manager boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_manager := public.can_access_venue(p_venue, array['owner', 'manager']);
  if not v_manager and not public.can_access_venue(p_venue, array['security']) then raise exception 'not allowed'; end if;

  return query
    select i.id, i.business_night, i.kind, i.occurred_at, i.location, i.status,
           coalesce(nullif(btrim(pr.name), ''), 'Staff member'), i.reported_by = auth.uid(), i.created_at,
           (select count(*)::int from public.site_security_incident_notes n where n.incident_id = i.id),
           case when i.reviewed_by is null then null else coalesce(nullif(btrim(pv.name), ''), 'Staff member') end, i.reviewed_at,
           v_manager and i.status = 'submitted' and i.reported_by <> auth.uid()
    from public.site_security_incidents i
    left join public.profiles pr on pr.id = i.reported_by
    left join public.profiles pv on pv.id = i.reviewed_by
    where i.venue_id = p_venue and (p_before is null or i.created_at < p_before)
    order by i.created_at desc, i.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

-- One incident with everything said about it, in order.
create function public.security_incident_detail(p_incident uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  i public.site_security_incidents;
  v_manager boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.site_security_incidents where id = p_incident;
  if not found then raise exception 'not allowed'; end if;
  v_manager := public.can_access_venue(i.venue_id, array['owner', 'manager']);
  if not v_manager and not public.can_access_venue(i.venue_id, array['security']) then raise exception 'not allowed'; end if;

  return jsonb_build_object(
    'incident_id', i.id,
    'business_night', i.business_night,
    'kind', i.kind,
    'occurred_at', i.occurred_at,
    'location', i.location,
    'details', i.details,
    'actions_taken', i.actions_taken,
    'status', i.status,
    'reported_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = i.reported_by),
    'reported_by_me', i.reported_by = auth.uid(),
    'created_at', i.created_at,
    'reviewed_by_name', (select coalesce(nullif(btrim(pr.name), ''), 'Staff member') from public.profiles pr where pr.id = i.reviewed_by),
    'reviewed_at', i.reviewed_at,
    'review_note', i.review_note,
    'can_review', v_manager and i.status = 'submitted' and i.reported_by <> auth.uid(),
    'notes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'author_name', coalesce(nullif(btrim(pa.name), ''), 'Staff member'),
        'is_mine', n.author_id = auth.uid(),
        'body', n.body,
        'created_at', n.created_at
      ) order by n.created_at, n.id)
      from public.site_security_incident_notes n
      left join public.profiles pa on pa.id = n.author_id
      where n.incident_id = i.id
    ), '[]'::jsonb)
  );
end;
$$;

-- Add a later fact to a report. Notes are never edited or removed.
create function public.security_incident_note(p_incident uuid, p_body text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.site_security_incidents;
  v_body text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.site_security_incidents where id = p_incident;
  if not found or not public.can_access_venue(i.venue_id, array['owner', 'manager', 'security']) then raise exception 'not allowed'; end if;
  v_body := btrim(p_body);
  if v_body is null or v_body = '' then raise exception 'write the note first'; end if;
  if char_length(v_body) > 1000 then raise exception 'keep a note to 1000 characters or fewer'; end if;

  insert into public.site_security_incident_notes (incident_id, author_id, body) values (p_incident, auth.uid(), v_body) returning id into v_id;
  perform public.desk_log('security.incident_note', 'site_security_incidents', p_incident, jsonb_build_object('venue_id', i.venue_id));
  return v_id;
end;
$$;

-- A manager or owner marks a report reviewed, never their own.
create function public.security_review_incident(p_incident uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.site_security_incidents;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into i from public.site_security_incidents where id = p_incident for update;
  if not found or not public.can_access_venue(i.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  if i.status <> 'submitted' then raise exception 'this report was already reviewed'; end if;
  if i.reported_by = auth.uid() then raise exception 'you wrote this report, so someone else has to review it'; end if;
  v_note := nullif(btrim(p_note), '');
  if v_note is not null and char_length(v_note) > 500 then raise exception 'keep the note to 500 characters or fewer'; end if;

  update public.site_security_incidents set status = 'reviewed', reviewed_by = auth.uid(), reviewed_at = clock_timestamp(), review_note = v_note where id = p_incident;
  perform public.desk_log('security.incident_reviewed', 'site_security_incidents', p_incident, jsonb_build_object('venue_id', i.venue_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. The night at a glance (the manager's Tonight and the security home)
-- ---------------------------------------------------------------------------
create function public.security_summary(p_venue uuid, p_night date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_night is null then raise exception 'choose a night'; end if;
  if not public.can_access_venue(p_venue, array['owner', 'manager', 'security']) then raise exception 'not allowed'; end if;

  return jsonb_build_object(
    'alerts_unresolved', (select count(*)::int from public.site_security_alerts a where a.venue_id = p_venue and a.business_night = p_night and a.status <> 'resolved'),
    'alerts_waiting', (select count(*)::int from public.site_security_alerts a where a.venue_id = p_venue and a.business_night = p_night and a.status = 'open'),
    'alerts_urgent', (select count(*)::int from public.site_security_alerts a where a.venue_id = p_venue and a.business_night = p_night and a.urgent and a.status <> 'resolved'),
    'alerts_escalated', (select count(*)::int from public.site_security_alerts a where a.venue_id = p_venue and a.business_night = p_night and a.status = 'escalated'),
    'tasks_open', (select count(*)::int from public.site_security_tasks t where t.venue_id = p_venue and t.business_night = p_night and t.status = 'open'),
    'incidents_to_review', (select count(*)::int from public.site_security_incidents i where i.venue_id = p_venue and i.business_night = p_night and i.status = 'submitted')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.security_raise_alert(uuid, date, text, boolean, text, text), public.security_alerts(uuid, date), public.security_alert_act(uuid, text, text),
  public.security_create_task(uuid, date, text, text, uuid), public.security_tasks(uuid, date), public.security_task_act(uuid, text, text),
  public.security_report_incident(uuid, date, text, timestamptz, text, text, text), public.security_incidents(uuid, int, timestamptz),
  public.security_incident_detail(uuid), public.security_incident_note(uuid, text), public.security_review_incident(uuid, text),
  public.security_summary(uuid, date)
from public, anon;
grant execute on function
  public.security_raise_alert(uuid, date, text, boolean, text, text), public.security_alerts(uuid, date), public.security_alert_act(uuid, text, text),
  public.security_create_task(uuid, date, text, text, uuid), public.security_tasks(uuid, date), public.security_task_act(uuid, text, text),
  public.security_report_incident(uuid, date, text, timestamptz, text, text, text), public.security_incidents(uuid, int, timestamptz),
  public.security_incident_detail(uuid), public.security_incident_note(uuid, text), public.security_review_incident(uuid, text),
  public.security_summary(uuid, date)
to authenticated, service_role;
