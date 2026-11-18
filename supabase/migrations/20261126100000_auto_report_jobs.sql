-- Sending the reports AUTOMATICALLY when a night is closed (client Phase 2 brief, section 27 "Automatically email the appropriate PDF to configured recipients ... Log delivery failure and
-- allow authorized resend. Never attach venue-wide private metrics to organizer email"; scenario 22 "Role-specific PDFs: owner, manager and organizer receive only appropriate detail").
-- The button (20261119100000_report_emails) stays: it is how a report is sent again or sent by hand. This adds the switch, the queue and the functions a server job needs.
--
-- WHAT IT DOES
--   * A person who may send a kind of report (the same test as the button: report_scope_allowed) can SWITCH ON "send automatically when the night is closed" for it: one switch per club for
--     the club's night report, one per business for the owner's combined report, one per organizer business for its event reports. It is OFF until someone switches it on.
--   * When a club closes a night (or closes it again after the owner reopened it), the reports whose switch is on are QUEUED: the club's night report; the owner's combined report once EVERY
--     club of the business has closed that night; an organizer's event report once every club that hosts the event has closed the event's night. Each report is queued once per close.
--   * A server job (the edge function run-report-jobs, run on a schedule with the service key) takes the queued jobs, asks for the report, makes the PDF, and sends it to the configured list
--     exactly as the button does, writing the same delivery log. Failures before anything was sent are tried again later (5 minutes, 15, an hour, three hours, then it stops and says why).
--     An address that did not accept the e-mail is NOT retried by the job (that would send the others a second copy): it shows in the log, and "Send again" sends it to the failed ones.
--
-- WHY IT IS SAFE (the part to read)
--   * THE SERVER JOB ACTS AS THE PERSON WHO SWITCHED IT ON, through the same functions the button uses (night_report, owner_night_report, organizer_event_sales, report_send_begin). Nothing
--     here decides who may see or send what: the existing functions check the person's access every time, so a person who has since lost it gets "not allowed", nothing is sent, and the
--     status says so. A club-wide report can never reach an organizer's list, because the kinds never mix (report_scope_allowed).
--   * The "acting as" is two settings that last for one call and are put back (report_job_act_as): only the SERVICE ROLE can call the functions that use it, only for a job that is running,
--     and only for the person stored on the switch. Visitors and signed-in people cannot call them.
--   * The e-mail addresses come from the configured list, never from anything typed; the text of the e-mail is fixed (it says the report was sent automatically).
--   * QUEUEING CAN NEVER STOP A NIGHT FROM CLOSING: the trigger catches any problem and only warns.
--   * Closed tables, reached only through the functions. Plain CREATE, never CREATE OR REPLACE. The one change to an existing object is a trigger on site_night_closes.
--
-- Needs the report e-mails (20261119100000), the close-night and owner report (20261018140000, 20261115100000), the agreement access (20261117100000) and the sales source (20261121100000) migrations.

do $pre$
declare
  r record;
begin
  for r in select * from (values
      ('public.report_send_begin(text, uuid, uuid, uuid, text, text, integer, boolean)'), ('public.report_scope_allowed(text, uuid, uuid, uuid)'), ('public.night_report(uuid, date)'),
      ('public.owner_night_report(uuid, date)'), ('public.organizer_event_sales(uuid)'), ('public.night_sales_sources(uuid, date)'), ('public.venue_timezone(uuid)'),
      ('public.agreement_in_force(public.site_agreements)'), ('public.desk_log(text, text, uuid, jsonb)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
  for r in select * from (values ('site_night_closes'), ('site_report_recipients'), ('site_report_deliveries'), ('site_agreements'), ('site_events'), ('site_venues'), ('site_organizations')) as x(t) loop
    if to_regclass('public.' || r.t) is null then raise exception 'public.% does not exist. Nothing was changed.', r.t; end if;
  end loop;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. The tables (closed)
-- ---------------------------------------------------------------------------
create table public.site_report_auto (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.site_organizations (id) on delete cascade,
  venue_id uuid references public.site_venues (id) on delete cascade,
  kind text not null check (kind in ('owner_combined', 'venue_night', 'organizer_sales')),
  enabled boolean not null,
  enabled_by uuid references auth.users (id) on delete set null,
  changed_at timestamptz not null default clock_timestamp(),
  check ((kind = 'venue_night') = (venue_id is not null))
);
create unique index site_report_auto_one on public.site_report_auto (org_id, kind, (coalesce(venue_id, '00000000-0000-0000-0000-000000000000'::uuid)));

create table public.site_report_jobs (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('owner_combined', 'venue_night', 'organizer_sales')),
  org_id uuid not null references public.site_organizations (id) on delete cascade,
  venue_id uuid references public.site_venues (id) on delete cascade,
  event_id uuid references public.site_events (id) on delete cascade,
  report_ref text not null check (char_length(report_ref) between 1 and 60),
  revision int not null check (revision >= 1),
  run_as uuid references auth.users (id) on delete set null,
  status text not null default 'pending' check (status in ('pending', 'running', 'sent', 'failed', 'skipped')),
  attempts int not null default 0 check (attempts between 0 and 5),
  next_attempt_at timestamptz not null default clock_timestamp(),
  last_error text check (last_error is null or char_length(last_error) <= 300),
  batch_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  claimed_at timestamptz,
  finished_at timestamptz,
  constraint site_report_jobs_finished_together check ((status in ('sent', 'failed', 'skipped')) = (finished_at is not null)),
  constraint site_report_jobs_shape check ((kind = 'venue_night') = (venue_id is not null) and (kind = 'organizer_sales') = (event_id is not null))
);
create unique index site_report_jobs_once on public.site_report_jobs
  (kind, org_id, (coalesce(venue_id, '00000000-0000-0000-0000-000000000000'::uuid)), (coalesce(event_id, '00000000-0000-0000-0000-000000000000'::uuid)), report_ref, revision);
create index site_report_jobs_due_idx on public.site_report_jobs (status, next_attempt_at);
create index site_report_jobs_scope_idx on public.site_report_jobs (kind, org_id, venue_id, created_at desc);

alter table public.site_report_auto enable row level security;
alter table public.site_report_jobs enable row level security;
revoke all on table public.site_report_auto, public.site_report_jobs from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Acting as the person who switched it on (internal: nobody signed in can call these)
-- ---------------------------------------------------------------------------
-- Sets the two settings auth.uid() reads, for this transaction only.
create function public.report_job_act_as(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user is null then raise exception 'nobody to act as'; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$;

-- Puts the two settings back as they were.
create function public.report_job_act_as_end(p_sub text, p_claims text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(p_claims, ''), true);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The switch
-- ---------------------------------------------------------------------------
create function public.report_auto_set(p_kind text, p_org uuid, p_venue uuid, p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_enabled is null then raise exception 'choose on or off'; end if;
  if not public.report_scope_allowed(p_kind, p_org, p_venue, null) then raise exception 'not allowed'; end if;
  insert into public.site_report_auto (org_id, venue_id, kind, enabled, enabled_by) values (p_org, p_venue, p_kind, p_enabled, auth.uid())
    on conflict (org_id, kind, (coalesce(venue_id, '00000000-0000-0000-0000-000000000000'::uuid)))
    do update set enabled = excluded.enabled, enabled_by = excluded.enabled_by, changed_at = clock_timestamp();
  perform public.desk_log('report.auto_set', 'site_report_auto', p_org, jsonb_build_object('kind', p_kind, 'org_id', p_org, 'venue_id', p_venue, 'enabled', p_enabled));
  return p_enabled;
end;
$$;

-- One row: is it on, who last changed it, how many addresses are on the list, and what the latest automatic send did.
create function public.report_auto_status(p_kind text, p_org uuid, p_venue uuid default null)
returns table (enabled boolean, changed_by_name text, changed_at timestamptz, mine boolean, recipients int, last_status text, last_ref text, last_at timestamptz, last_error text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a public.site_report_auto;
  j public.site_report_jobs;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.report_scope_allowed(p_kind, p_org, p_venue, null) then raise exception 'not allowed'; end if;
  select * into a from public.site_report_auto x where x.kind = p_kind and x.org_id = p_org and x.venue_id is not distinct from p_venue;
  select * into j from public.site_report_jobs y where y.kind = p_kind and y.org_id = p_org and y.venue_id is not distinct from p_venue order by y.created_at desc, y.id limit 1;
  return query select
    coalesce(a.enabled, false),
    (select coalesce(nullif(btrim(pr.name), ''), 'Someone') from public.profiles pr where pr.id = a.enabled_by),
    a.changed_at,
    coalesce(a.enabled_by = auth.uid(), false),
    (select count(*)::int from public.site_report_recipients r where r.org_id = p_org and r.kind = p_kind and r.venue_id is not distinct from p_venue),
    j.status, j.report_ref, coalesce(j.finished_at, j.created_at), j.last_error;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Queueing (when a night is closed)
-- ---------------------------------------------------------------------------
create function public.report_jobs_enqueue(p_venue uuid, p_night date)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_user uuid;
  v_rev int;
  v_n int := 0;
  v_c int;
  e record;
begin
  select v.org_id into v_org from public.site_venues v where v.id = p_venue;
  if v_org is null or p_night is null then return 0; end if;

  -- 1. the club's own night report
  select a.enabled_by into v_user from public.site_report_auto a where a.kind = 'venue_night' and a.org_id = v_org and a.venue_id = p_venue and a.enabled;
  if v_user is not null then
    select c.close_count into v_rev from public.site_night_closes c where c.venue_id = p_venue and c.business_night = p_night and c.status = 'closed';
    if v_rev is not null then
      insert into public.site_report_jobs (kind, org_id, venue_id, report_ref, revision, run_as) values ('venue_night', v_org, p_venue, p_night::text, v_rev, v_user) on conflict do nothing;
      get diagnostics v_c = row_count;
      v_n := v_n + v_c;
    end if;
  end if;

  -- 2. the owner's combined report, once EVERY club of the business has closed the night
  v_user := null;
  select a.enabled_by into v_user from public.site_report_auto a where a.kind = 'owner_combined' and a.org_id = v_org and a.venue_id is null and a.enabled;
  if v_user is not null
     and exists (select 1 from public.site_venues x where x.org_id = v_org)
     and not exists (select 1 from public.site_venues x where x.org_id = v_org
                      and not exists (select 1 from public.site_night_closes c where c.venue_id = x.id and c.business_night = p_night and c.status = 'closed')) then
    select coalesce(sum(c.close_count), 0)::int into v_rev from public.site_night_closes c join public.site_venues x on x.id = c.venue_id
     where x.org_id = v_org and c.business_night = p_night and c.status = 'closed';
    insert into public.site_report_jobs (kind, org_id, report_ref, revision, run_as) values ('owner_combined', v_org, p_night::text, greatest(v_rev, 1), v_user) on conflict do nothing;
    get diagnostics v_c = row_count;
    v_n := v_n + v_c;
  end if;

  -- 3. an organizer's event report, once every club that hosts the event has closed the event's night (the night is worked out the way organizer_event_sales works it out)
  for e in
    select distinct ev.id as event_id, ev.org_id as organizer_org, ev.start_date as starts
      from public.site_agreements ag join public.site_events ev on ev.id = ag.event_id
     where ag.venue_id = p_venue and public.agreement_in_force(ag) and ev.org_id = ag.organizer_org_id
       and ((ev.start_date at time zone public.venue_timezone(ag.venue_id)) - interval '6 hours')::date = p_night
     order by ev.start_date, ev.id
  loop
    v_user := null;
    select a.enabled_by into v_user from public.site_report_auto a where a.kind = 'organizer_sales' and a.org_id = e.organizer_org and a.venue_id is null and a.enabled;
    if v_user is null then continue; end if;
    if exists (select 1 from public.site_agreements x join public.site_events xe on xe.id = x.event_id
                where x.event_id = e.event_id and public.agreement_in_force(x)
                  and not exists (select 1 from public.site_night_closes c where c.venue_id = x.venue_id and c.status = 'closed'
                                   and c.business_night = ((xe.start_date at time zone public.venue_timezone(x.venue_id)) - interval '6 hours')::date)) then
      continue;
    end if;
    select coalesce(sum(c.close_count), 0)::int into v_rev
      from public.site_agreements x join public.site_events xe on xe.id = x.event_id
      join public.site_night_closes c on c.venue_id = x.venue_id and c.status = 'closed' and c.business_night = ((xe.start_date at time zone public.venue_timezone(x.venue_id)) - interval '6 hours')::date
     where x.event_id = e.event_id and public.agreement_in_force(x);
    insert into public.site_report_jobs (kind, org_id, event_id, report_ref, revision, run_as) values ('organizer_sales', e.organizer_org, e.event_id, e.event_id::text, greatest(v_rev, 1), v_user) on conflict do nothing;
    get diagnostics v_c = row_count;
    v_n := v_n + v_c;
  end loop;
  return v_n;
end;
$$;

-- Fired when a night becomes closed. It must NEVER stop the close: a problem here only warns.
create function public.report_jobs_on_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'closed' and (tg_op = 'INSERT' or old.status is distinct from 'closed' or new.close_count is distinct from old.close_count) then
    begin
      perform public.report_jobs_enqueue(new.venue_id, new.business_night);
    exception when others then
      raise warning 'report jobs: could not queue the reports of % for %: %', new.venue_id, new.business_night, sqlerrm;
    end;
  end if;
  return null;
end;
$$;

create trigger report_jobs_after_close after insert or update on public.site_night_closes for each row execute function public.report_jobs_on_close();

-- ---------------------------------------------------------------------------
-- 5. What the server job calls (service role only)
-- ---------------------------------------------------------------------------
-- Takes the jobs that are due. A job whose run stopped part way (running for more than 15 minutes) is looked at again, or given up on after its fifth try.
create function public.report_job_claim(p_limit int default 3)
returns table (job_id uuid, kind text, org_id uuid, venue_id uuid, event_id uuid, report_ref text, attempts int)
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.site_report_jobs j set status = 'failed', last_error = 'the run stopped before it finished', finished_at = clock_timestamp()
   where j.status = 'running' and j.claimed_at < clock_timestamp() - interval '15 minutes' and j.attempts >= 5;
  update public.site_report_jobs j set status = 'pending', last_error = 'the run stopped before it finished', next_attempt_at = clock_timestamp()
   where j.status = 'running' and j.claimed_at < clock_timestamp() - interval '15 minutes' and j.attempts < 5;
  return query
    with picked as (
      select x.id from public.site_report_jobs x where x.status = 'pending' and x.next_attempt_at <= clock_timestamp()
       order by x.next_attempt_at, x.created_at, x.id limit least(greatest(coalesce(p_limit, 3), 1), 10) for update skip locked)
    update public.site_report_jobs j set status = 'running', attempts = j.attempts + 1, claimed_at = clock_timestamp()
      from picked where j.id = picked.id
    returning j.id, j.kind, j.org_id, j.venue_id, j.event_id, j.report_ref, j.attempts;
end;
$$;

-- The report this job is for, asked for AS the person who switched the automatic sending on. Raises "not allowed" if they no longer may see it.
create function public.report_job_data(p_job uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  j public.site_report_jobs;
  a public.site_report_auto;
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_claims text := current_setting('request.jwt.claims', true);
  v_out jsonb;
  v_sales jsonb;
begin
  select * into j from public.site_report_jobs x where x.id = p_job;
  if not found or j.status <> 'running' then raise exception 'this job is not running'; end if;
  if j.run_as is null then raise exception 'nobody is set to send it'; end if;
  select * into a from public.site_report_auto x where x.kind = j.kind and x.org_id = j.org_id and x.venue_id is not distinct from j.venue_id;
  if not found or not a.enabled or a.enabled_by is distinct from j.run_as then raise exception 'automatic sending was switched off'; end if;

  perform public.report_job_act_as(j.run_as);
  begin
    if j.kind = 'venue_night' then
      v_out := jsonb_build_object('kind', j.kind, 'ref', j.report_ref, 'time_zone', public.venue_timezone(j.venue_id), 'report', public.night_report(j.venue_id, j.report_ref::date));
      begin
        v_sales := public.night_sales_sources(j.venue_id, j.report_ref::date);
      exception when others then
        v_sales := null;
      end;
      v_out := v_out || jsonb_build_object('sales', v_sales);
    elsif j.kind = 'owner_combined' then
      -- the combined report's times are shown in the time zone of the business's first club (by name)
      v_out := jsonb_build_object('kind', j.kind, 'ref', j.report_ref,
        'time_zone', coalesce((select public.venue_timezone(v.id) from public.site_venues v where v.org_id = j.org_id order by lower(v.name), v.id limit 1), 'America/Toronto'),
        'report', public.owner_night_report(j.org_id, j.report_ref::date));
    else
      -- an event report's times are shown in the time zone of the first club that hosts the event
      v_out := jsonb_build_object('kind', j.kind, 'ref', j.report_ref,
        'time_zone', coalesce((select public.venue_timezone(h.venue_id) from public.site_agreements h where h.event_id = j.event_id and public.agreement_in_force(h) order by h.requested_at, h.id limit 1), 'America/Toronto'),
        'report', public.organizer_event_sales(j.event_id));
    end if;
  exception when others then
    perform public.report_job_act_as_end(v_sub, v_claims);
    raise;
  end;
  perform public.report_job_act_as_end(v_sub, v_claims);
  return v_out;
end;
$$;

-- Starts the delivery log for this job's report: the same checks and the same rows as the button (report_send_begin), AS the same person. The addresses come from the list.
create function public.report_job_begin(p_job uuid, p_filename text, p_bytes int)
returns table (delivery_id uuid, batch_id uuid, email text, org_name text, venue_name text, event_title text)
language plpgsql
security definer
set search_path = public
as $$
declare
  j public.site_report_jobs;
  a public.site_report_auto;
  r record;
  v_batch uuid;
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_claims text := current_setting('request.jwt.claims', true);
begin
  select * into j from public.site_report_jobs x where x.id = p_job;
  if not found or j.status <> 'running' then raise exception 'this job is not running'; end if;
  if j.run_as is null then raise exception 'nobody is set to send it'; end if;
  select * into a from public.site_report_auto x where x.kind = j.kind and x.org_id = j.org_id and x.venue_id is not distinct from j.venue_id;
  if not found or not a.enabled or a.enabled_by is distinct from j.run_as then raise exception 'automatic sending was switched off'; end if;

  perform public.report_job_act_as(j.run_as);
  begin
    for r in select * from public.report_send_begin(j.kind, j.org_id, j.venue_id, j.event_id, j.report_ref, p_filename, p_bytes, false) loop
      v_batch := r.batch_id;
      delivery_id := r.delivery_id; batch_id := r.batch_id; email := r.email; org_name := r.org_name; venue_name := r.venue_name; event_title := r.event_title;
      return next;
    end loop;
  exception when others then
    perform public.report_job_act_as_end(v_sub, v_claims);
    raise;
  end;
  perform public.report_job_act_as_end(v_sub, v_claims);
  update public.site_report_jobs set batch_id = v_batch where id = j.id;
  return;
end;
$$;

-- Says how the run went. 'sent' (the e-mails were handed over; an address that did not accept it is in the delivery log), 'skipped' (nothing to do, with the reason), 'failed' (it will
-- not be tried again), 'retry' (try again later: after 5 minutes, 15, an hour, three hours; after the fifth try it fails). Returns the status the job is in now.
create function public.report_job_finish(p_job uuid, p_outcome text, p_error text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  j public.site_report_jobs;
  v_err text := left(nullif(btrim(p_error), ''), 300);
  v_status text;
  v_wait interval;
begin
  if p_outcome is null or p_outcome not in ('sent', 'skipped', 'failed', 'retry') then raise exception 'say how the run went'; end if;
  select * into j from public.site_report_jobs x where x.id = p_job for update;
  if not found or j.status <> 'running' then raise exception 'this job is not running'; end if;
  v_status := case when p_outcome = 'retry' and j.attempts >= 5 then 'failed' when p_outcome = 'retry' then 'pending' else p_outcome end;
  v_wait := case j.attempts when 1 then interval '5 minutes' when 2 then interval '15 minutes' when 3 then interval '1 hour' else interval '3 hours' end;
  update public.site_report_jobs set status = v_status, last_error = case when p_outcome = 'sent' then null else v_err end,
    next_attempt_at = case when v_status = 'pending' then clock_timestamp() + v_wait else next_attempt_at end,
    finished_at = case when v_status in ('sent', 'failed', 'skipped') then clock_timestamp() else null end
   where id = j.id;
  return v_status;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
-- Internal: nobody calls these, not even the service role (the functions below and the trigger run with their owner's rights and reach them).
revoke all on function public.report_job_act_as(uuid), public.report_job_act_as_end(text, text), public.report_jobs_enqueue(uuid, date), public.report_jobs_on_close() from public, anon, authenticated, service_role;
revoke all on function public.report_auto_set(text, uuid, uuid, boolean), public.report_auto_status(text, uuid, uuid) from public, anon;
grant execute on function public.report_auto_set(text, uuid, uuid, boolean), public.report_auto_status(text, uuid, uuid) to authenticated, service_role;
revoke all on function public.report_job_claim(int), public.report_job_data(uuid), public.report_job_begin(uuid, text, int), public.report_job_finish(uuid, text, text) from public, anon, authenticated;
grant execute on function public.report_job_claim(int), public.report_job_data(uuid), public.report_job_begin(uuid, text, int), public.report_job_finish(uuid, text, text) to service_role;
