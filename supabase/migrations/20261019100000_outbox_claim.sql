-- Outbox sender, database side: hand a batch of queued messages to ONE sender at a time, and record how each one went.
--
-- Since 20261018110000 the app queues guest messages (table seated, wait estimate changed, VIP invitation) in public.site_outbox and nothing sent them.
-- The new edge function `process-outbox` sends them by e-mail. This file is the part that must not go wrong: two runs of the sender (a retry, a
-- slow run overlapping the next scheduled one) must never send the same message twice, and a message that keeps failing must stop being tried.
--
--   * outbox_claim(limit)    atomically picks up to `limit` (1 to 50) queued messages, oldest first, that nobody holds, stamps them as held
--                            (claimed_at) and counts the attempt. A hold lasts 10 minutes: if the sender dies half way, the message becomes
--                            available again after that, which is also the pause between a failed attempt and the next one.
--                            It uses FOR UPDATE SKIP LOCKED, so two runs at the same moment get different messages.
--   * outbox_finish(id, result, error)   result 'sent' marks it sent; 'retry' leaves it queued for another go (and fails it for good after the
--                            5th attempt); 'failed' fails it at once (no recipient, unknown kind, too old). Only a message that is still
--                            'queued' can change, so a late or repeated report cannot undo a final state. Returns the state it ended in, or
--                            null when there was nothing to change.
--
-- Both are for the service role only (the edge function). Nothing a person can call. Plain CREATE, never CREATE OR REPLACE. One column is added to
-- a table that has existed since 18 Oct; no row is changed.

alter table public.site_outbox add column claimed_at timestamptz;

create function public.outbox_claim(p_limit int default 20)
returns table (id uuid, kind text, venue_id uuid, ref_id uuid, payload jsonb, attempts int, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  update public.site_outbox o
     set claimed_at = clock_timestamp(), attempts = o.attempts + 1
   where o.id in (
     select q.id
       from public.site_outbox q
      where q.status = 'queued'
        and q.attempts < 5
        and (q.claimed_at is null or q.claimed_at < clock_timestamp() - interval '10 minutes')
      order by q.created_at, q.id
      limit least(greatest(coalesce(p_limit, 20), 1), 50)
        for update skip locked
   )
  returning o.id, o.kind, o.venue_id, o.ref_id, o.payload, o.attempts, o.created_at
$$;

create function public.outbox_finish(p_id uuid, p_result text, p_error text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.site_outbox;
  v_state text;
begin
  if p_result is null or p_result not in ('sent', 'retry', 'failed') then
    raise exception 'result must be sent, retry or failed';
  end if;

  select * into v_row from public.site_outbox where id = p_id and status = 'queued' for update;
  if not found then return null; end if;

  if p_result = 'sent' then
    v_state := 'sent';
  elsif p_result = 'failed' or v_row.attempts >= 5 then
    v_state := 'failed';
  else
    v_state := 'queued';
  end if;

  update public.site_outbox
     set status = v_state,
         sent_at = case when v_state = 'sent' then clock_timestamp() else sent_at end,
         last_error = case when v_state = 'sent' then null else left(nullif(btrim(p_error), ''), 500) end
   where id = p_id;
  return v_state;
end;
$$;

revoke all on function public.outbox_claim(int), public.outbox_finish(uuid, text, text) from public, anon, authenticated;
grant execute on function public.outbox_claim(int), public.outbox_finish(uuid, text, text) to service_role;
