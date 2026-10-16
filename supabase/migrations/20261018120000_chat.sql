-- Chat (client Phase 2 brief, section 23): "Chat -> Venue Staff / Assigned Event / Permitted Direct Conversation. Show pinned instructions and
-- unread counts. Shared event chat includes approved organizer and venue staff ... Show deletion date: seven days after event end.
-- Agreements, payment evidence, formal approvals and incident records are separate retained records."
--
--   * THREE KINDS. The venue's staff chat (everyone with an active role at the club, and the owner of its business); an event chat (the
--     organizer and owner of the event's business, and staff scoped to that event); and a direct conversation between two people who work at
--     a club together.
--   * WHO MAY READ AND WRITE is worked out from the person's CURRENT membership on every call, not from a list of members. Revoke someone and
--     they cannot read or send the next second; their old messages stay.
--   * EVENT CHATS EXPIRE seven days after the event ends (or starts, if it has no end). Expired chats are hidden at once and read-only;
--     chat_purge_expired() deletes them (service role only; nothing in the database runs it on a timer yet: it needs a scheduled job).
--     Only chat is deleted: payments, agreements and incident records live in their own tables and are untouched.
--   * A message is 1 to 2000 characters, at most 30 a minute per person per chat, and a retried send with the same client key is one message.
--   * A manager or owner pins an instruction on a venue chat; the organizer or owner of the event's business pins on an event chat.
--
-- Reached only through the functions below; no table can be read or written by a client. Plain CREATE, never CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.site_chat_conversations (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('venue', 'event', 'direct')),
  venue_id uuid references public.site_venues (id) on delete cascade,
  event_id uuid references public.site_events (id) on delete cascade,
  org_id uuid references public.site_organizations (id) on delete cascade,
  pair_key text,
  delete_after timestamptz,
  pinned_message_id uuid,
  created_at timestamptz not null default now(),
  constraint site_chat_kind_columns check (
    (kind = 'venue' and venue_id is not null and event_id is null and pair_key is null)
    or (kind = 'event' and event_id is not null and venue_id is null and pair_key is null)
    or (kind = 'direct' and pair_key is not null and venue_id is null and event_id is null)
  )
);
create unique index site_chat_one_venue_chat on public.site_chat_conversations (venue_id) where kind = 'venue';
create unique index site_chat_one_event_chat on public.site_chat_conversations (event_id) where kind = 'event';
create unique index site_chat_one_direct_chat on public.site_chat_conversations (pair_key) where kind = 'direct';

create table public.site_chat_direct_members (
  conversation_id uuid not null references public.site_chat_conversations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  primary key (conversation_id, user_id)
);

create table public.site_chat_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.site_chat_conversations (id) on delete cascade,
  sender_id uuid not null references auth.users (id),
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  client_key text check (client_key is null or char_length(client_key) <= 64),
  -- The moment it was written, not the start of the transaction: "unread" compares this with when someone last looked.
  created_at timestamptz not null default clock_timestamp()
);
create index site_chat_messages_conversation_idx on public.site_chat_messages (conversation_id, created_at desc, id desc);
create unique index site_chat_messages_client_key_idx on public.site_chat_messages (conversation_id, sender_id, client_key) where client_key is not null;

alter table public.site_chat_conversations
  add constraint site_chat_pinned_message_fk foreign key (pinned_message_id) references public.site_chat_messages (id) on delete set null;

create table public.site_chat_reads (
  conversation_id uuid not null references public.site_chat_conversations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  last_read_at timestamptz not null default clock_timestamp(),
  primary key (conversation_id, user_id)
);

alter table public.site_chat_conversations enable row level security;
alter table public.site_chat_direct_members enable row level security;
alter table public.site_chat_messages enable row level security;
alter table public.site_chat_reads enable row level security;
revoke all on table public.site_chat_conversations, public.site_chat_direct_members, public.site_chat_messages, public.site_chat_reads from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (the app cannot call these)
-- ---------------------------------------------------------------------------
-- Can the caller read and write this conversation right now?
create function public.chat_can_access(p_conv uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.site_chat_conversations c
    where c.id = p_conv
      and (
        (c.kind = 'venue' and public.can_access_venue(c.venue_id, null))
        or (c.kind = 'event' and public.can_access_event(c.event_id, null))
        or (c.kind = 'direct'
            and exists (select 1 from public.site_chat_direct_members d where d.conversation_id = c.id and d.user_id = auth.uid())
            and exists (select 1 from public.active_memberships()))
      )
  )
$$;

-- Does this person (not the caller) hold an active role at this club right now?
create function public.chat_user_at_venue(p_user uuid, p_venue uuid)
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
    left join public.site_venues v on v.id = p_venue
    where m.user_id = p_user
      and m.status = 'active'
      and (m.access_start_at is null or now() >= m.access_start_at)
      and (m.access_end_at is null or now() <= m.access_end_at)
      and (m.shift_id is null or (now() >= s.starts_at and now() <= s.ends_at))
      and ((m.role = 'owner' and v.org_id = m.org_id) or m.venue_id = p_venue)
  )
$$;

revoke all on function public.chat_can_access(uuid), public.chat_user_at_venue(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The caller's conversations
-- ---------------------------------------------------------------------------
create function public.chat_conversations()
returns table (
  conversation_id uuid, kind text, title text, venue_id uuid, event_id uuid, unread_count int, last_message_at timestamptz,
  last_message_preview text, last_sender_name text, pinned_body text, delete_after timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;

  -- The chats the caller is entitled to exist from their first look.
  insert into public.site_chat_conversations (kind, venue_id, org_id)
    select distinct 'venue', v.id, v.org_id
    from public.site_venues v
    join public.active_memberships() m on (m.venue_id = v.id or (m.role = 'owner' and m.org_id = v.org_id))
    where v.org_id is not null
    on conflict (venue_id) where kind = 'venue' do nothing;

  insert into public.site_chat_conversations (kind, event_id, org_id, delete_after)
    select distinct 'event', e.id, e.org_id, coalesce(e.end_date, e.start_date) + interval '7 days'
    from public.site_events e
    where e.id in (
      select e2.id from public.site_events e2 join public.active_memberships() m on (m.role in ('owner', 'organizer') and m.org_id = e2.org_id)
      union
      select m.event_id from public.active_memberships() m where m.event_id is not null
    )
    on conflict (event_id) where kind = 'event' do nothing;

  -- An event that moved keeps the chat's deletion date in step with it.
  update public.site_chat_conversations c
    set delete_after = coalesce(e.end_date, e.start_date) + interval '7 days'
    from public.site_events e
    where c.kind = 'event' and c.event_id = e.id and c.delete_after is distinct from coalesce(e.end_date, e.start_date) + interval '7 days'
      and public.chat_can_access(c.id);

  return query
    select c.id, c.kind,
           case c.kind when 'venue' then v.name when 'event' then e.title
                else coalesce(nullif(btrim(op.name), ''), 'Staff member') end,
           c.venue_id, c.event_id,
           (select count(*)::int from public.site_chat_messages x
             where x.conversation_id = c.id and x.sender_id <> auth.uid() and x.created_at > coalesce(r.last_read_at, '-infinity'::timestamptz)),
           lm.created_at, left(lm.body, 80), coalesce(nullif(btrim(ls.name), ''), 'Staff member'), pm.body, c.delete_after
    from public.site_chat_conversations c
    left join public.site_venues v on v.id = c.venue_id
    left join public.site_events e on e.id = c.event_id
    left join public.site_chat_direct_members od on od.conversation_id = c.id and od.user_id <> auth.uid() and c.kind = 'direct'
    left join public.profiles op on op.id = od.user_id
    left join public.site_chat_reads r on r.conversation_id = c.id and r.user_id = auth.uid()
    left join lateral (
      select x.created_at, x.body, x.sender_id from public.site_chat_messages x where x.conversation_id = c.id order by x.created_at desc, x.id desc limit 1
    ) lm on true
    left join public.profiles ls on ls.id = lm.sender_id
    left join public.site_chat_messages pm on pm.id = c.pinned_message_id
    where public.chat_can_access(c.id) and (c.delete_after is null or c.delete_after > now())
    order by coalesce(lm.created_at, c.created_at) desc, c.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Reading and writing
-- ---------------------------------------------------------------------------
create function public.chat_messages(p_conversation uuid, p_before timestamptz default null, p_limit int default 50)
returns table (message_id uuid, sender_name text, is_mine boolean, body text, created_at timestamptz, pinned boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.chat_can_access(p_conversation)
     or exists (select 1 from public.site_chat_conversations c where c.id = p_conversation and c.delete_after is not null and c.delete_after <= now()) then
    raise exception 'not allowed';
  end if;
  return query
    select m.id, coalesce(nullif(btrim(pr.name), ''), 'Staff member'), m.sender_id = auth.uid(), m.body, m.created_at,
           m.id = (select c.pinned_message_id from public.site_chat_conversations c where c.id = p_conversation)
    from public.site_chat_messages m
    left join public.profiles pr on pr.id = m.sender_id
    where m.conversation_id = p_conversation and (p_before is null or m.created_at < p_before)
    order by m.created_at desc, m.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

create function public.chat_send(p_conversation uuid, p_body text, p_client_key text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_body text;
  v_id uuid;
  v_key text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.chat_can_access(p_conversation) then raise exception 'not allowed'; end if;
  if exists (select 1 from public.site_chat_conversations c where c.id = p_conversation and c.delete_after is not null and c.delete_after <= now()) then
    raise exception 'this chat has ended';
  end if;
  v_body := btrim(p_body);
  if v_body is null or v_body = '' then raise exception 'write a message first'; end if;
  if char_length(v_body) > 2000 then raise exception 'keep a message to 2000 characters or fewer'; end if;
  v_key := nullif(btrim(p_client_key), '');
  if v_key is not null and char_length(v_key) > 64 then raise exception 'that message key is too long'; end if;

  -- A retried send (same key) is the message already sent.
  if v_key is not null then
    select m.id into v_id from public.site_chat_messages m where m.conversation_id = p_conversation and m.sender_id = auth.uid() and m.client_key = v_key;
    if v_id is not null then return v_id; end if;
  end if;

  if (select count(*) from public.site_chat_messages m
        where m.conversation_id = p_conversation and m.sender_id = auth.uid() and m.created_at > clock_timestamp() - interval '1 minute') >= 30 then
    raise exception 'slow down: you are sending messages too fast';
  end if;

  insert into public.site_chat_messages (conversation_id, sender_id, body, client_key)
    values (p_conversation, auth.uid(), v_body, v_key)
    on conflict (conversation_id, sender_id, client_key) where client_key is not null do nothing
    returning id into v_id;
  if v_id is null then
    select m.id into v_id from public.site_chat_messages m where m.conversation_id = p_conversation and m.sender_id = auth.uid() and m.client_key = v_key;
  end if;
  return v_id;
end;
$$;

create function public.chat_mark_read(p_conversation uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.chat_can_access(p_conversation) then raise exception 'not allowed'; end if;
  insert into public.site_chat_reads (conversation_id, user_id, last_read_at) values (p_conversation, auth.uid(), clock_timestamp())
    on conflict (conversation_id, user_id) do update set last_read_at = excluded.last_read_at;
end;
$$;

-- Pin a message as the instruction at the top of a chat (null un-pins). Managers and owners on a venue chat; the organizer or owner on an event chat.
create function public.chat_pin(p_conversation uuid, p_message uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.site_chat_conversations;
  v_ok boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into c from public.site_chat_conversations where id = p_conversation for update;
  if not found or not public.chat_can_access(p_conversation) then raise exception 'not allowed'; end if;
  v_ok := case c.kind
    when 'venue' then public.can_access_venue(c.venue_id, array['manager', 'owner'])
    when 'event' then public.can_access_event(c.event_id, array['owner', 'organizer'])
    else false end;
  if not v_ok then raise exception 'not allowed'; end if;
  if p_message is not null and not exists (select 1 from public.site_chat_messages m where m.id = p_message and m.conversation_id = p_conversation) then
    raise exception 'that message is not in this chat';
  end if;
  update public.site_chat_conversations set pinned_message_id = p_message where id = p_conversation;
  perform public.desk_log(case when p_message is null then 'chat.unpinned' else 'chat.pinned' end, 'site_chat_conversations', p_conversation, null);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Direct conversations
-- ---------------------------------------------------------------------------
-- The colleagues a person can message: others with an active role at the club. Names and roles only, never an email.
create function public.chat_people(p_venue uuid)
returns table (user_id uuid, name text, role text)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.can_access_venue(p_venue, null) then raise exception 'not allowed'; end if;
  return query
    select distinct on (m.user_id) m.user_id, coalesce(nullif(btrim(pr.name), ''), 'Staff member'), m.role
    from public.site_memberships m
    left join public.profiles pr on pr.id = m.user_id
    left join public.site_venues v on v.id = p_venue
    where m.user_id <> auth.uid()
      and public.chat_user_at_venue(m.user_id, p_venue)
      and (m.venue_id = p_venue or (m.role = 'owner' and m.org_id = v.org_id))
      and m.status = 'active'
    order by m.user_id, case m.role when 'owner' then 0 when 'manager' then 1 else 2 end
    limit 300;
end;
$$;

create function public.chat_start_direct(p_other uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_id uuid;
  v_common boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_other is null then raise exception 'choose who to message'; end if;
  if p_other = auth.uid() then raise exception 'you cannot message yourself'; end if;
  -- Only people who work at a club together: a venue where both hold an active role.
  select exists (
    select 1 from public.site_venues v
    where public.can_access_venue(v.id, null) and public.chat_user_at_venue(p_other, v.id)
  ) into v_common;
  if not v_common then raise exception 'you can only message people you work with'; end if;

  v_key := least(auth.uid()::text, p_other::text) || ':' || greatest(auth.uid()::text, p_other::text);
  select c.id into v_id from public.site_chat_conversations c where c.kind = 'direct' and c.pair_key = v_key;
  if v_id is null then
    insert into public.site_chat_conversations (kind, pair_key) values ('direct', v_key)
      on conflict (pair_key) where kind = 'direct' do nothing returning id into v_id;
    if v_id is null then select c.id into v_id from public.site_chat_conversations c where c.kind = 'direct' and c.pair_key = v_key; end if;
    insert into public.site_chat_direct_members (conversation_id, user_id) values (v_id, auth.uid()), (v_id, p_other) on conflict do nothing;
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Expiry (service role only)
-- ---------------------------------------------------------------------------
create function public.chat_purge_expired()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  delete from public.site_chat_conversations c where c.delete_after is not null and c.delete_after <= now();
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  public.chat_conversations(), public.chat_messages(uuid, timestamptz, int), public.chat_send(uuid, text, text), public.chat_mark_read(uuid),
  public.chat_pin(uuid, uuid), public.chat_people(uuid), public.chat_start_direct(uuid), public.chat_purge_expired()
from public, anon, authenticated;
grant execute on function
  public.chat_conversations(), public.chat_messages(uuid, timestamptz, int), public.chat_send(uuid, text, text), public.chat_mark_read(uuid),
  public.chat_pin(uuid, uuid), public.chat_people(uuid), public.chat_start_direct(uuid)
to authenticated, service_role;
grant execute on function public.chat_purge_expired() to service_role;
