-- Sending a complimentary offer's claim link, and a guard for the public claim page (client Phase 2 brief, section 20, second half: "email/phone -> send secure claim link -> recipient sees
-- venue/event/item/expiry -> chooses location on map"; "Keep provider delivery status and retry controls. Do not announce success before the corresponding operation succeeds").
-- The first half (20261123100000_complimentary_offers) made the offer, the one-use link token (only its hash is kept) and the claim functions, all service-role only. This adds what a SEND needs:
--
--   * site_comp_offer_sends (closed table)   one row per attempt to e-mail the link: who pressed it, to which address, pending -> sent or failed. The provider's own message is never kept: only
--                                            "not configured" or "send failed". It is the log the app shows ("Link e-mailed to ... 21:04", "Not delivered: try again").
--   * comp_offer_send_begin(offer)           the club's owner or manager, for an offer whose link can still be sent (approved, sent or awaiting location; not expired, cancelled or already
--                                            placed). At most 5 sends per offer in 24 hours and 30 per person in an hour. Records the attempt as pending and hands the edge function what the e-mail needs. It does NOT
--                                            make the link: the edge function does that with the service role, only after this said yes.
--   * comp_offer_send_finish(send, ok, why)  service role only: the e-mail went or it did not. A FIRST send that failed and that nobody has opened is taken back (the offer goes back to
--                                            "approved", the link is cleared), so the offer never says "sent" for a link nobody received. A failed RE-send changes nothing about the offer.
--   * comp_offer_sends(offer)                the club's owner or manager reads the attempts, newest first.
--   * comp_claim_throttle(key, limit, secs)  service role only: the public claim page counts a visit against a key (a hash of the visitor's address, or of the link) and is told whether it is
--                                            within the limit. Nothing about a visitor is kept but that hash and the time, for a day.
--
-- Closed tables, reached only through the functions. Plain CREATE, never CREATE OR REPLACE. Needs 20261123100000_complimentary_offers.

do $pre$
declare
  r record;
begin
  for r in select * from (values
      ('public.comp_offer_state(text, timestamp with time zone)'), ('public.comp_offer_issue_link(uuid)'), ('public.comp_claim_view(text)'),
      ('public.can_access_venue(uuid, text[])'), ('public.desk_log(text, text, uuid, jsonb)')) as x(sig) loop
    if to_regprocedure(r.sig) is null then raise exception '% does not exist: run the earlier migrations first. Nothing was changed.', r.sig; end if;
  end loop;
  if to_regclass('public.site_comp_offers') is null then raise exception 'public.site_comp_offers does not exist: run migration 20261123100000 first. Nothing was changed.'; end if;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. The tables (closed)
-- ---------------------------------------------------------------------------
create table public.site_comp_offer_sends (
  id uuid primary key default gen_random_uuid(),
  offer_id uuid not null references public.site_comp_offers (id) on delete cascade,
  sent_by uuid references auth.users (id) on delete set null,
  to_email text not null check (char_length(to_email) <= 254),
  first_send boolean not null,
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
  failure text check (failure is null or failure in ('not_configured', 'send_failed')),
  created_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  constraint site_comp_offer_sends_finished_together check ((status = 'pending') = (finished_at is null)),
  constraint site_comp_offer_sends_failure_when_failed check ((status = 'failed') = (failure is not null))
);
create index site_comp_offer_sends_offer_idx on public.site_comp_offer_sends (offer_id, created_at desc);
create index site_comp_offer_sends_person_idx on public.site_comp_offer_sends (sent_by, created_at desc);

create table public.site_comp_claim_attempts (
  id bigint generated always as identity primary key,
  key text not null check (char_length(key) between 1 and 120),
  at timestamptz not null default clock_timestamp()
);
create index site_comp_claim_attempts_key_idx on public.site_comp_claim_attempts (key, at desc);
create index site_comp_claim_attempts_at_idx on public.site_comp_claim_attempts (at);

alter table public.site_comp_offer_sends enable row level security;
alter table public.site_comp_claim_attempts enable row level security;
revoke all on table public.site_comp_offer_sends, public.site_comp_claim_attempts from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Sending
-- ---------------------------------------------------------------------------
create function public.comp_offer_send_begin(p_offer uuid)
returns table (send_id uuid, venue_id uuid, to_email text, to_name text, venue_name text, event_title text, item text, quantity int, expires_at timestamptz, time_zone text, first_send boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.site_comp_offers;
  v_state text;
  v_id uuid;
  v_first boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into o from public.site_comp_offers x where x.id = p_offer for update;
  if not found or not public.can_access_venue(o.venue_id, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  v_state := public.comp_offer_state(o.status, o.expires_at);
  if v_state not in ('approved', 'sent', 'awaiting_location') then raise exception 'a link cannot be sent for an offer that is %', replace(v_state, '_', ' '); end if;
  if (select count(*) from public.site_comp_offer_sends s where s.offer_id = o.id and s.created_at > clock_timestamp() - interval '24 hours') >= 5 then
    raise exception 'this link was sent 5 times in the last day: wait before sending it again';
  end if;
  if (select count(*) from public.site_comp_offer_sends s where s.sent_by = auth.uid() and s.created_at > clock_timestamp() - interval '1 hour') >= 30 then
    raise exception 'you have sent a lot of links this hour: wait before sending another';
  end if;
  v_first := (v_state = 'approved');
  insert into public.site_comp_offer_sends (offer_id, sent_by, to_email, first_send) values (o.id, auth.uid(), o.recipient_email, v_first) returning id into v_id;
  perform public.desk_log('comp_offer.send', 'site_comp_offers', o.id, jsonb_build_object('venue_id', o.venue_id, 'send_id', v_id, 'first', v_first));
  return query select v_id, o.venue_id, o.recipient_email, o.recipient_name, (select v.name from public.site_venues v where v.id = o.venue_id),
                      (select e.title from public.site_events e where e.id = o.event_id), o.bottle_name, o.quantity, o.expires_at,
                      coalesce((select v.time_zone from public.site_venues v where v.id = o.venue_id), 'America/Toronto'::text), v_first;
end;
$$;

create function public.comp_offer_send_finish(p_send uuid, p_ok boolean, p_why text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.site_comp_offer_sends;
  v_why text := case when p_ok then null when p_why = 'not_configured' then 'not_configured' else 'send_failed' end;
begin
  select * into s from public.site_comp_offer_sends x where x.id = p_send for update;
  if not found or s.status <> 'pending' then return false; end if;
  update public.site_comp_offer_sends set status = case when p_ok then 'sent' else 'failed' end, failure = v_why, finished_at = clock_timestamp() where id = s.id;
  if not p_ok and s.first_send then
    -- A first send nobody received: the offer goes back to "approved" and the link stops existing, so it never says "sent" for a link that was never delivered. Only when nobody has opened it.
    update public.site_comp_offers set status = 'approved', token_hash = null, sent_at = null, updated_at = clock_timestamp()
     where id = s.offer_id and status = 'sent' and claimed_at is null;
  end if;
  return true;
end;
$$;

create function public.comp_offer_sends(p_offer uuid)
returns table (id uuid, to_email text, status text, failure text, created_at timestamptz, finished_at timestamptz, first_send boolean, mine boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_venue uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select o.venue_id into v_venue from public.site_comp_offers o where o.id = p_offer;
  if v_venue is null or not public.can_access_venue(v_venue, array['owner', 'manager']) then raise exception 'not allowed'; end if;
  return query
    select s.id, s.to_email, s.status, s.failure, s.created_at, s.finished_at, s.first_send, (s.sent_by is not distinct from auth.uid())
      from public.site_comp_offer_sends s where s.offer_id = p_offer order by s.created_at desc, s.id limit 10;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The public page's guard
-- ---------------------------------------------------------------------------
create function public.comp_claim_throttle(p_key text, p_limit int, p_window_seconds int)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n bigint;
begin
  if p_key is null or char_length(p_key) < 1 or char_length(p_key) > 120 then raise exception 'a key of 1 to 120 characters is needed'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 1000 then raise exception 'the limit is 1 to 1000'; end if;
  if p_window_seconds is null or p_window_seconds < 1 or p_window_seconds > 86400 then raise exception 'the window is 1 second to a day'; end if;
  delete from public.site_comp_claim_attempts where at < clock_timestamp() - interval '1 day';
  insert into public.site_comp_claim_attempts (key) values (p_key);
  select count(*) into v_n from public.site_comp_claim_attempts a where a.key = p_key and a.at > clock_timestamp() - make_interval(secs => p_window_seconds);
  return v_n <= p_limit;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.comp_offer_send_begin(uuid), public.comp_offer_sends(uuid) from public, anon;
grant execute on function public.comp_offer_send_begin(uuid), public.comp_offer_sends(uuid) to authenticated, service_role;
revoke all on function public.comp_offer_send_finish(uuid, boolean, text), public.comp_claim_throttle(text, int, int) from public, anon, authenticated;
grant execute on function public.comp_offer_send_finish(uuid, boolean, text), public.comp_claim_throttle(text, int, int) to service_role;
