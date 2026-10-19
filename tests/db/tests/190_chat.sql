-- Chat. What matters most: who may read and write is worked out from the person's CURRENT role on every call (revoke them and they are out at
-- once); a venue chat is for that club's staff and its owner, an event chat for the event's organizer, owner and event staff, a direct chat for
-- two people who work at a club together; nothing leaks between clubs; unread counts are per person and never count your own messages; a
-- retried send is one message and a flood is slowed; only managers and organizers pin; an event chat ends seven days after the event and
-- only then is it deleted (by the service role), without touching anything else. (No email address ever leaves these functions.)
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.convs(p_user uuid, p_email text) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(kind || ':' || title || ':' || unread_count, ' | ' order by kind, title) from public.chat_conversations()), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.conv_of(p_user uuid, p_email text, p_kind text, p_title text) returns uuid language plpgsql as $$
declare id uuid;
begin
  perform tests.login(p_user, p_email);
  select conversation_id into id from public.chat_conversations() where kind = p_kind and title = p_title;
  return id;
end $$;
create function tests.send(p_user uuid, p_email text, p_conv uuid, p_body text, p_key text default null) returns text language plpgsql as $$
declare id uuid;
begin
  perform tests.login(p_user, p_email);
  id := public.chat_send(p_conv, p_body, p_key);
  return 'ok:' || id::text;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.read(p_user uuid, p_email text, p_conv uuid, p_limit int default 50, p_before timestamptz default null) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(sender_name || ':' || body || case when is_mine then '(me)' else '' end || case when pinned then '(pinned)' else '' end, ' | ' order by created_at desc, message_id desc)
                   from public.chat_messages(p_conv, p_before, p_limit)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.count_read(p_user uuid, p_email text, p_conv uuid, p_limit int) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return (select count(*)::text from public.chat_messages(p_conv, null, p_limit));
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.mark(p_user uuid, p_email text, p_conv uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  perform public.chat_mark_read(p_conv);
  return 'ok';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.pin(p_user uuid, p_email text, p_conv uuid, p_msg uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  perform public.chat_pin(p_conv, p_msg);
  return 'ok';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.pinned(p_user uuid, p_email text, p_kind text, p_title text) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select pinned_body from public.chat_conversations() where kind = p_kind and title = p_title), '(nothing pinned)');
end $$;
create function tests.people(p_user uuid, p_email text, p_venue uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(name || '/' || role, ' | ' order by name) from public.chat_people(p_venue)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.direct(p_user uuid, p_email text, p_other uuid) returns text language plpgsql as $$
declare id uuid;
begin
  perform tests.login(p_user, p_email);
  id := public.chat_start_direct(p_other);
  return 'ok:' || id::text;
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.rowcount(p_table text, p_conv uuid) returns int language plpgsql security definer as $$
declare n int;
begin
  execute format('select count(*) from public.%I where conversation_id = $1', p_table) into n using p_conv;
  return n;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000003d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000003d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000003d3';
  srv_2 constant uuid := '00000000-0000-0000-0000-0000000003d4';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000003d5';
  sec_a constant uuid := '00000000-0000-0000-0000-0000000003d6';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000003d7';
  org_u constant uuid := '00000000-0000-0000-0000-0000000003d8';   -- the organizer business's owner
  door_e constant uuid := '00000000-0000-0000-0000-0000000003d9';  -- door staff for one event only
  rando constant uuid := '00000000-0000-0000-0000-0000000003da';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; ev uuid; ev2 uuid;
  c_a uuid; c_b uuid; c_ev uuid; c_ev2 uuid; c_dm uuid; c_dm2 uuid;
  txt text; m1 uuid; m2 uuid; m3 uuid; m_ev uuid; m_b uuid; n int;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@chat.example'), (mgr_a, 'mgra@chat.example'), (srv_1, 'srv1@chat.example'), (srv_2, 'srv2@chat.example'),
    (ver_a, 'vera@chat.example'), (sec_a, 'seca@chat.example'), (mgr_b, 'mgrb@chat.example'), (org_u, 'org@chat.example'),
    (door_e, 'doore@chat.example'), (rando, 'rando@chat.example');
  insert into public.profiles (id, name, email) values
    (mgr_a, 'Mia Manager', 'mgra@chat.example'), (srv_1, 'Sam Server', 'srv1@chat.example'), (srv_2, 'Bea Server', 'srv2@chat.example'),
    (ver_a, 'Vera Verifier', 'vera@chat.example'), (owner_u, 'Olly Owner', 'owner@chat.example'), (org_u, 'Olive Organizer', 'org@chat.example'),
    (door_e, 'Dee Door', 'doore@chat.example');

  ---------------------------------------------------------------- set up
  perform tests.login(owner_u, 'owner@chat.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@chat.example', org, 'mgra@chat.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@chat.example', org, 'mgrb@chat.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@chat.example', org, 'srv1@chat.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@chat.example', org, 'srv2@chat.example', 'server', venue_a, srv_2);
  perform tests.join_as(mgr_a, 'mgra@chat.example', org, 'vera@chat.example', 'verifier', venue_a, ver_a);
  perform tests.join_as(mgr_a, 'mgra@chat.example', org, 'seca@chat.example', 'security', venue_a, sec_a);
  perform tests.login(org_u, 'org@chat.example');
  org2 := public.create_organization('Night Events', 'organizer');
  perform tests.logout();
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Night One', 'x', 'Somewhere', now() + interval '2 days', now() + interval '2 days 6 hours', 'draft', org2) returning id into ev;
  insert into public.site_events (title, description, venue_name, start_date, end_date, status, org_id)
    values ('Night Two', 'x', 'Somewhere', now() + interval '9 days', now() + interval '9 days 6 hours', 'draft', org2) returning id into ev2;
  insert into public.site_memberships (org_id, user_id, role, event_id) values (org2, door_e, 'door', ev);

  ---------------------------------------------------------------- who has which chats
  perform tests.assert_eq('a manager has their club''s staff chat', tests.convs(mgr_a, 'mgra@chat.example'), 'venue:Club A:0');
  perform tests.assert_eq('...another club''s manager has theirs and sees nothing of Club A', tests.convs(mgr_b, 'mgrb@chat.example'), 'venue:Club B:0');
  perform tests.assert_eq('the owner has the chat of each club of their business', tests.convs(owner_u, 'owner@chat.example'), 'venue:Club A:0 | venue:Club B:0');
  perform tests.assert_eq('a server, a verifier and security have the club chat', tests.convs(srv_1, 'srv1@chat.example') || ' / ' || tests.convs(ver_a, 'vera@chat.example') || ' / ' || tests.convs(sec_a, 'seca@chat.example'),
    'venue:Club A:0 / venue:Club A:0 / venue:Club A:0');
  perform tests.assert_eq('event door staff have the event chat only', tests.convs(door_e, 'doore@chat.example'), 'event:Night One:0');
  perform tests.assert_eq('the organizer business''s owner has the chat of each of its events (not the clubs'')', tests.convs(org_u, 'org@chat.example'), 'event:Night One:0 | event:Night Two:0');
  perform tests.assert_eq('a stranger has none', tests.convs(rando, 'rando@chat.example'), '(none)');
  perform tests.logout();
  perform tests.assert_eq('there is one chat per club and per event, however often they are looked at', (select count(*) from public.site_chat_conversations where kind in ('venue', 'event'))::int, 4);
  c_a := tests.conv_of(mgr_a, 'mgra@chat.example', 'venue', 'Club A');
  c_b := tests.conv_of(mgr_b, 'mgrb@chat.example', 'venue', 'Club B');
  c_ev := tests.conv_of(door_e, 'doore@chat.example', 'event', 'Night One');
  c_ev2 := tests.conv_of(org_u, 'org@chat.example', 'event', 'Night Two');

  ---------------------------------------------------------------- sending and reading
  txt := tests.send(srv_1, 'srv1@chat.example', c_a, '  Table 4 needs ice  ');
  perform tests.assert_true('a server writes in the club chat', txt like 'ok:%');
  m1 := substr(txt, 4)::uuid;
  perform tests.assert_eq('the manager reads it, trimmed, with the sender''s name', tests.read(mgr_a, 'mgra@chat.example', c_a), 'Sam Server:Table 4 needs ice');
  perform tests.assert_eq('...and the sender sees it as theirs', tests.read(srv_1, 'srv1@chat.example', c_a), 'Sam Server:Table 4 needs ice(me)');
  perform tests.assert_eq('the owner reads it too', tests.read(owner_u, 'owner@chat.example', c_a), 'Sam Server:Table 4 needs ice');
  perform tests.assert_eq('another club''s manager cannot read it', tests.read(mgr_b, 'mgrb@chat.example', c_a), 'ERROR: not allowed');
  perform tests.assert_eq('...nor write in it', tests.send(mgr_b, 'mgrb@chat.example', c_a, 'hello'), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger can neither read...', tests.read(rando, 'rando@chat.example', c_a), 'ERROR: not allowed');
  perform tests.assert_eq('...nor write', tests.send(rando, 'rando@chat.example', c_a, 'hello'), 'ERROR: not allowed');
  perform tests.assert_eq('event staff cannot read the club''s chat', tests.read(door_e, 'doore@chat.example', c_a), 'ERROR: not allowed');
  perform tests.assert_eq('the club''s staff cannot read the event''s chat', tests.read(srv_1, 'srv1@chat.example', c_ev), 'ERROR: not allowed');
  perform tests.assert_eq('a conversation that does not exist is "not allowed" too', tests.read(srv_1, 'srv1@chat.example', gen_random_uuid()), 'ERROR: not allowed');
  perform tests.assert_eq('an empty message is refused', tests.send(srv_1, 'srv1@chat.example', c_a, '   '), 'ERROR: write a message first');
  perform tests.assert_eq('...a message of 2001 characters is refused', tests.send(srv_1, 'srv1@chat.example', c_a, repeat('x', 2001)), 'ERROR: keep a message to 2000 characters or fewer');
  perform tests.assert_true('...2000 is fine', tests.send(srv_1, 'srv1@chat.example', c_a, repeat('y', 2000)) like 'ok:%');

  ---------------------------------------------------------------- retries and floods
  txt := tests.send(srv_2, 'srv2@chat.example', c_a, 'on my way', 'key-1');
  m2 := substr(txt, 4)::uuid;
  perform tests.assert_eq('a retried send (same key) is the same message', tests.send(srv_2, 'srv2@chat.example', c_a, 'on my way', 'key-1'), txt);
  perform tests.logout();
  perform tests.assert_eq('...and there is only one of it', (select count(*) from public.site_chat_messages where conversation_id = c_a and body = 'on my way')::int, 1);
  perform tests.assert_true('the same key from someone else is their own message', tests.send(srv_1, 'srv1@chat.example', c_a, 'on my way too', 'key-1') <> txt);
  perform tests.assert_eq('a key that is too long is refused', tests.send(srv_2, 'srv2@chat.example', c_a, 'hi', repeat('k', 65)), 'ERROR: that message key is too long');
  for i in 1..28 loop
    perform tests.send(srv_2, 'srv2@chat.example', c_a, 'spam ' || i, 'spam-' || i);
  end loop;
  perform tests.assert_eq('the 30th message in a minute still goes', substr(tests.send(srv_2, 'srv2@chat.example', c_a, 'spam 29', 'spam-29'), 1, 3), 'ok:');
  perform tests.assert_eq('the 31st is slowed', tests.send(srv_2, 'srv2@chat.example', c_a, 'spam 30', 'spam-30'), 'ERROR: slow down: you are sending messages too fast');
  perform tests.assert_eq('...and a retry of one already sent is still answered', substr(tests.send(srv_2, 'srv2@chat.example', c_a, 'spam 29', 'spam-29'), 1, 3), 'ok:');
  perform tests.assert_true('...while someone else is not slowed by that', tests.send(srv_1, 'srv1@chat.example', c_a, 'still here') like 'ok:%');

  ---------------------------------------------------------------- paging
  perform tests.logout();
  delete from public.site_chat_messages where conversation_id = c_b;
  for i in 1..120 loop
    insert into public.site_chat_messages (conversation_id, sender_id, body, created_at) values (c_b, mgr_b, 'm' || i, now() - ((121 - i) || ' minutes')::interval);
  end loop;
  select id into m_b from public.site_chat_messages where conversation_id = c_b limit 1;
  perform tests.assert_eq('a page is capped at 100 however many are asked for', tests.count_read(mgr_b, 'mgrb@chat.example', c_b, 500), '100');
  perform tests.assert_eq('...and a page of 0 is a page of 1', tests.count_read(mgr_b, 'mgrb@chat.example', c_b, 0), '1');
  perform tests.assert_eq('the newest come first', tests.read(mgr_b, 'mgrb@chat.example', c_b, 2), 'Staff member:m120(me) | Staff member:m119(me)');
  perform tests.assert_eq('"before" pages backwards', tests.read(mgr_b, 'mgrb@chat.example', c_b, 2, now() - interval '90 seconds'), 'Staff member:m119(me) | Staff member:m118(me)');
  perform tests.assert_eq('...the default page is 50', tests.count_read(mgr_b, 'mgrb@chat.example', c_b, null), '50');

  ---------------------------------------------------------------- unread
  perform tests.logout();
  delete from public.site_chat_messages where conversation_id = c_a;
  delete from public.site_chat_reads where conversation_id = c_a;
  m1 := substr(tests.send(srv_1, 'srv1@chat.example', c_a, 'first'), 4)::uuid;
  m3 := substr(tests.send(mgr_a, 'mgra@chat.example', c_a, 'second'), 4)::uuid;
  perform tests.assert_eq('the manager has 1 unread (the server''s message, not their own)', tests.convs(mgr_a, 'mgra@chat.example'), 'venue:Club A:1');
  perform tests.assert_eq('the server has 1 unread (the manager''s), not their own', tests.convs(srv_1, 'srv1@chat.example'), 'venue:Club A:1');
  perform tests.assert_eq('a person who never opened it has both unread', tests.convs(ver_a, 'vera@chat.example'), 'venue:Club A:2');
  perform tests.assert_eq('marking read clears it for that person only', tests.mark(ver_a, 'vera@chat.example', c_a) || ' ' || tests.convs(ver_a, 'vera@chat.example') || ' / ' || tests.convs(srv_2, 'srv2@chat.example'), 'ok venue:Club A:0 / venue:Club A:2');
  perform tests.assert_eq('a stranger cannot mark it read', tests.mark(rando, 'rando@chat.example', c_a), 'ERROR: not allowed');

  ---------------------------------------------------------------- pinning
  perform tests.assert_eq('a server cannot pin', tests.pin(srv_1, 'srv1@chat.example', c_a, m1), 'ERROR: not allowed');
  perform tests.assert_eq('a manager of ANOTHER club cannot', tests.pin(mgr_b, 'mgrb@chat.example', c_a, m1), 'ERROR: not allowed');
  perform tests.assert_eq('the club''s manager pins an instruction', tests.pin(mgr_a, 'mgra@chat.example', c_a, m3), 'ok');
  perform tests.assert_eq('everyone in the chat sees it at the top', tests.pinned(srv_1, 'srv1@chat.example', 'venue', 'Club A'), 'second');
  perform tests.assert_eq('...and it is marked in the messages', tests.read(srv_2, 'srv2@chat.example', c_a, 1), 'Mia Manager:second(pinned)');
  perform tests.assert_eq('a message from another chat cannot be pinned here', tests.pin(mgr_a, 'mgra@chat.example', c_a, m_b), 'ERROR: that message is not in this chat');
  perform tests.assert_eq('the owner can unpin', tests.pin(owner_u, 'owner@chat.example', c_a, null), 'ok');
  perform tests.assert_eq('...nothing is pinned then', tests.pinned(srv_1, 'srv1@chat.example', 'venue', 'Club A'), '(nothing pinned)');

  ---------------------------------------------------------------- event chat
  txt := tests.send(door_e, 'doore@chat.example', c_ev, 'doors open at 9');
  m_ev := substr(txt, 4)::uuid;
  perform tests.assert_eq('the event''s organizer reads what the door staff wrote', tests.read(org_u, 'org@chat.example', c_ev), 'Dee Door:doors open at 9');
  perform tests.assert_eq('...and has it unread', tests.convs(org_u, 'org@chat.example'), 'event:Night One:1 | event:Night Two:0');
  perform tests.assert_eq('event door staff cannot pin', tests.pin(door_e, 'doore@chat.example', c_ev, m_ev), 'ERROR: not allowed');
  perform tests.assert_eq('the organizer pins', tests.pin(org_u, 'org@chat.example', c_ev, m_ev), 'ok');
  perform tests.assert_eq('...and door staff see it', tests.pinned(door_e, 'doore@chat.example', 'event', 'Night One'), 'doors open at 9');
  perform tests.assert_eq('door staff of one event cannot read another event''s chat', tests.read(door_e, 'doore@chat.example', c_ev2), 'ERROR: not allowed');
  perform tests.logout();
  perform tests.assert_eq('an event chat is deleted seven days after the event ends',
    (select (c.delete_after = e.end_date + interval '7 days')::text from public.site_chat_conversations c join public.site_events e on e.id = c.event_id where c.id = c_ev), 'true');
  update public.site_events set end_date = now() + interval '20 days' where id = ev2;
  txt := tests.convs(org_u, 'org@chat.example');
  perform tests.logout();
  perform tests.assert_eq('an event that moves keeps its chat''s deletion date in step',
    txt || ' ' || (select (abs(extract(epoch from (c.delete_after - (e.end_date + interval '7 days')))) < 1)::text from public.site_chat_conversations c join public.site_events e on e.id = c.event_id where c.id = c_ev2),
    'event:Night One:1 | event:Night Two:0 true');
  update public.site_events set end_date = now() - interval '8 days', start_date = now() - interval '9 days' where id = ev;
  perform tests.assert_eq('once ended, an event chat disappears from the list', tests.convs(door_e, 'doore@chat.example'), '(none)');
  perform tests.assert_eq('...cannot be read any more', tests.read(org_u, 'org@chat.example', c_ev), 'ERROR: not allowed');
  perform tests.assert_eq('...and cannot be written in', tests.send(org_u, 'org@chat.example', c_ev, 'hello?'), 'ERROR: this chat has ended');
  perform tests.login(owner_u, 'owner@chat.example');
  perform tests.assert_raises('an owner cannot purge', 'select public.chat_purge_expired()', 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('before the purge the ended chat''s messages are still stored', tests.rowcount('site_chat_messages', c_ev), 1);
  perform tests.login_service();
  select public.chat_purge_expired() into n;
  perform tests.logout();
  perform tests.assert_eq('the service role purges exactly the ended chat', n, 1);
  perform tests.assert_eq('...its messages are gone', tests.rowcount('site_chat_messages', c_ev), 0);
  perform tests.assert_eq('...the club chats and the other event are untouched', (select count(*) from public.site_chat_conversations where kind in ('venue', 'event'))::int, 3);
  perform tests.assert_eq('...and so are the events themselves and the audit trail', (select count(*) from public.site_events where id = ev)::int, 1);

  ---------------------------------------------------------------- people and direct conversations
  perform tests.assert_eq('a manager can message the club''s other staff (names and roles, no emails, not themselves, not another club)', tests.people(mgr_a, 'mgra@chat.example', venue_a),
    'Bea Server/server | Olly Owner/owner | Sam Server/server | Staff member/security | Vera Verifier/verifier');
  perform tests.assert_eq('a stranger or another club''s manager cannot list them', tests.people(mgr_b, 'mgrb@chat.example', venue_a), 'ERROR: not allowed');
  txt := tests.direct(mgr_a, 'mgra@chat.example', srv_1);
  perform tests.assert_true('a manager starts a direct chat with a server of their club', txt like 'ok:%');
  c_dm := substr(txt, 4)::uuid;
  perform tests.assert_eq('starting it again opens the same one', tests.direct(srv_1, 'srv1@chat.example', mgr_a), 'ok:' || c_dm::text);
  perform tests.assert_true('they talk', tests.send(mgr_a, 'mgra@chat.example', c_dm, 'got a minute?') like 'ok:%');
  perform tests.assert_eq('the server sees it titled with the other person''s name and unread', tests.convs(srv_1, 'srv1@chat.example'), 'direct:Mia Manager:1 | venue:Club A:1');
  perform tests.assert_eq('...and the manager sees the server''s name', (select tests.convs(mgr_a, 'mgra@chat.example')), 'direct:Sam Server:0 | venue:Club A:1');
  perform tests.assert_eq('a third person cannot read their direct chat, not even the owner', tests.read(owner_u, 'owner@chat.example', c_dm), 'ERROR: not allowed');
  perform tests.assert_eq('...nor write in it', tests.send(srv_2, 'srv2@chat.example', c_dm, 'psst'), 'ERROR: not allowed');
  perform tests.assert_eq('you cannot message someone you do not work with', tests.direct(mgr_a, 'mgra@chat.example', mgr_b), 'ERROR: you can only message people you work with');
  perform tests.assert_eq('...nor a stranger', tests.direct(rando, 'rando@chat.example', mgr_a), 'ERROR: you can only message people you work with');
  perform tests.assert_eq('...nor event-only staff', tests.direct(door_e, 'doore@chat.example', mgr_a), 'ERROR: you can only message people you work with');
  perform tests.assert_eq('...nor yourself', tests.direct(mgr_a, 'mgra@chat.example', mgr_a), 'ERROR: you cannot message yourself');
  perform tests.assert_eq('...nor nobody', tests.direct(mgr_a, 'mgra@chat.example', null), 'ERROR: choose who to message');
  perform tests.assert_true('the owner can message club staff', tests.direct(owner_u, 'owner@chat.example', srv_1) like 'ok:%');

  ---------------------------------------------------------------- revoking takes effect at once
  perform tests.send(srv_2, 'srv2@chat.example', c_a, 'last words');
  perform tests.login(mgr_a, 'mgra@chat.example');
  perform public.revoke_membership((select id from public.site_memberships where user_id = srv_2 and role = 'server'));
  perform tests.logout();
  perform tests.assert_eq('a person whose access was revoked has no chats', tests.convs(srv_2, 'srv2@chat.example'), '(none)');
  perform tests.assert_eq('...cannot read the club chat', tests.read(srv_2, 'srv2@chat.example', c_a), 'ERROR: not allowed');
  perform tests.assert_eq('...cannot write in it', tests.send(srv_2, 'srv2@chat.example', c_a, 'let me in'), 'ERROR: not allowed');
  perform tests.assert_eq('...and is no longer someone to message', tests.people(mgr_a, 'mgra@chat.example', venue_a), 'Olly Owner/owner | Sam Server/server | Staff member/security | Vera Verifier/verifier');
  perform tests.assert_eq('...nor can they be started a direct chat with', tests.direct(mgr_a, 'mgra@chat.example', srv_2), 'ERROR: you can only message people you work with');
  perform tests.assert_eq('their earlier messages stay for the others', (select position('last words' in tests.read(mgr_a, 'mgra@chat.example', c_a, 100)) > 0)::text, 'true');
  perform tests.login(mgr_a, 'mgra@chat.example');
  perform public.revoke_membership((select id from public.site_memberships where user_id = srv_1 and role = 'server'));
  perform tests.logout();
  perform tests.assert_eq('someone revoked cannot read their direct chat any more', tests.read(srv_1, 'srv1@chat.example', c_dm), 'ERROR: not allowed');

  ---------------------------------------------------------------- closed to clients
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot list chats', 'select * from public.chat_conversations()', 'permission denied');
  perform tests.assert_raises('...or send', format($q$select public.chat_send(%L, 'hi')$q$, c_a), 'permission denied');
  perform tests.logout();
  perform tests.login(mgr_a, 'mgra@chat.example');
  perform tests.assert_raises('the tables cannot be read directly', 'select * from public.site_chat_messages', 'permission denied');
  perform tests.assert_raises('...nor the conversations', 'select * from public.site_chat_conversations', 'permission denied');
  perform tests.assert_raises('...nor who has read what', 'select * from public.site_chat_reads', 'permission denied');
  perform tests.assert_raises('the internal access check cannot be called', format($q$select public.chat_can_access(%L)$q$, c_a), 'permission denied');
  perform tests.logout();
end $$;

rollback;
