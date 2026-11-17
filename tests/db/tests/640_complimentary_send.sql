-- Sending a complimentary offer's claim link and the public page's throttle (20261124100000_complimentary_send.sql). What matters: only the club's owner or manager may send, and only for an offer whose link can
-- still be sent; sending is limited (5 per offer a day, 30 per person an hour) and never makes the link itself (the edge function does, afterwards); only the service role says whether the e-mail went; a FIRST
-- send that failed and that nobody opened is taken back so the offer never says "sent" for a link nobody received, while a failed RE-send changes nothing; the provider's own message is never kept; the
-- throttle counts per key and window; the tables are closed; every refusal is a plain sentence and changes nothing.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
  perform tests.logout();
end $$;
create function tests.try(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into r;
  perform tests.logout();
  return coalesce(r, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.try_anon(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login_anon();
  execute p_sql into r;
  perform tests.logout();
  return coalesce(r, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.svc(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login_service();
  execute p_sql into r;
  perform tests.logout();
  return coalesce(r, 'null');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
-- begin a send as a person and return one column of what comes back, as text ("send_id" is replaced by 'id' so a test can compare)
create function tests.begin_col(p_user uuid, p_email text, p_offer uuid, p_col text) returns text language sql as $$
  select tests.try(p_user, p_email, format('select (b.%I)::text from public.comp_offer_send_begin(%L) b', p_col, p_offer))
$$;
-- one send begun, the whole row it returns as jsonb text
create function tests.begin_json(p_user uuid, p_email text, p_offer uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  select to_jsonb(b) into r from public.comp_offer_send_begin(p_offer) b;
  perform tests.logout();
  return r;
end $$;
create function tests.mkbottle(p_venue uuid, p_name text, p_price int) returns uuid language sql security definer as $$
  insert into public.site_bottles (venue_id, name, size, category, price_cents, is_available, is_sold_out) values (p_venue, p_name, '750ml', 'Spirits', p_price, true, false) returning id $$;
create function tests.mkoffer(p_user uuid, p_email text, p_venue uuid, p_bottle uuid, p_to text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform tests.login(p_user, p_email);
  v := public.comp_offer_create(p_venue, p_bottle, 2, p_to, 'Gina Guest', 'Birthday');
  perform tests.logout();
  return v;
end $$;
create function tests.offer_col(p_offer uuid, p_col text) returns text language plpgsql security definer as $$
declare v text;
begin
  execute format('select (%I)::text from public.site_comp_offers where id = %L', p_col, p_offer) into v;
  return coalesce(v, 'null');
end $$;
create function tests.n_sends(p_offer uuid) returns bigint language sql security definer as $$ select count(*) from public.site_comp_offer_sends where offer_id = p_offer $$;
create function tests.send_col(p_send uuid, p_col text) returns text language plpgsql security definer as $$
declare v text;
begin
  execute format('select (%I)::text from public.site_comp_offer_sends where id = %L', p_col, p_send) into v;
  return coalesce(v, 'null');
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000010f1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000010f2';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000010f3';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000010f4';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000010f5';
  org uuid; org2 uuid; venue_a uuid; venue_b uuid; patron uuid;
  o1 uuid; o2 uuid; o3 uuid; o4 uuid; o5 uuid; o6 uuid; o7 uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; tok text; tok2 text; v_n bigint; r text; i int; j jsonb;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@send.example'), (mgr_a, 'mgra@send.example'), (mgr_b, 'mgrb@send.example'), (srv_1, 'srv1@send.example'), (rival_u, 'rival@send.example');
  perform tests.login(owner_u, 'owner@send.example');
  org := public.create_organization('Send Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@send.example', org, 'mgra@send.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@send.example', org, 'mgrb@send.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@send.example', org, 'srv1@send.example', 'server', venue_a, srv_1);
  perform tests.login(rival_u, 'rival@send.example');
  org2 := public.create_organization('Rival Send Co', 'venue_owner');
  perform tests.logout();
  patron := tests.mkbottle(venue_a, 'Patron', 25000);
  -- the owner makes the offers (a manager needs the owner's free-bottle limits first)
  o1 := tests.mkoffer(owner_u, 'owner@send.example', venue_a, patron, 'First.Guest@X.example');
  o2 := tests.mkoffer(owner_u, 'owner@send.example', venue_a, patron, 'two@x.example');
  o3 := tests.mkoffer(owner_u, 'owner@send.example', venue_a, patron, 'three@x.example');
  o4 := tests.mkoffer(owner_u, 'owner@send.example', venue_a, patron, 'four@x.example');
  o5 := tests.mkoffer(owner_u, 'owner@send.example', venue_a, patron, 'five@x.example');
  o6 := tests.mkoffer(owner_u, 'owner@send.example', venue_a, patron, 'six@x.example');
  o7 := tests.mkoffer(owner_u, 'owner@send.example', venue_a, patron, 'seven@x.example');

  -- ---------------------------------------------------------------- who may send
  perform tests.assert_eq('a server cannot send', tests.begin_col(srv_1, 'srv1@send.example', o1, 'send_id'), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.begin_col(mgr_b, 'mgrb@send.example', o1, 'send_id'), 'ERROR: not allowed');
  perform tests.assert_eq('another business''s owner cannot', tests.begin_col(rival_u, 'rival@send.example', o1, 'send_id'), 'ERROR: not allowed');
  perform tests.assert_eq('an offer that does not exist looks the same', tests.begin_col(owner_u, 'owner@send.example', gen_random_uuid(), 'send_id'), 'ERROR: not allowed');
  perform tests.assert_eq('a visitor is refused before anything runs', tests.try_anon(format('select (b.send_id)::text from public.comp_offer_send_begin(%L) b', o1)), 'ERROR: permission denied for function comp_offer_send_begin');
  perform tests.assert_eq('nobody signed in is told to sign in', tests.svc(format('select (b.send_id)::text from public.comp_offer_send_begin(%L) b', o1)), 'ERROR: not authenticated');
  perform tests.assert_eq('none of those wrote an attempt', tests.n_sends(o1), 0::bigint);

  -- ---------------------------------------------------------------- the owner and the club's manager may, and get what the e-mail needs
  s1 := tests.begin_col(owner_u, 'owner@send.example', o1, 'send_id')::uuid;
  perform tests.assert_true('the owner begins a send and gets its id', s1 is not null);
  perform tests.assert_eq('the attempt is pending and the first', tests.send_col(s1, 'status') || '/' || tests.send_col(s1, 'first_send'), 'pending/true');
  perform tests.assert_eq('it is the owner''s', tests.send_col(s1, 'sent_by'), owner_u::text);
  perform tests.assert_eq('to the offer''s own address, as it was stored', tests.send_col(s1, 'to_email'), 'first.guest@x.example');
  perform tests.assert_eq('beginning does NOT make the link: no token yet', tests.offer_col(o1, 'token_hash'), 'null');
  perform tests.assert_eq('and does not mark the offer sent', tests.offer_col(o1, 'status'), 'approved');
  perform tests.assert_eq('the recipient address is what the e-mail goes to', (select to_email from public.site_comp_offer_sends where id = s1), 'first.guest@x.example');
  perform tests.assert_eq('the audit trail has it once', (select count(*) from public.audit_log where action = 'comp_offer.send' and entity_id = o1::text), 1::bigint);
  -- what the e-mail needs, from ONE send begun by the manager
  j := tests.begin_json(mgr_a, 'mgra@send.example', o2);
  perform tests.assert_eq('the venue name', j ->> 'venue_name', 'Club A');
  perform tests.assert_eq('the item', j ->> 'item', 'Patron');
  perform tests.assert_eq('the quantity', j ->> 'quantity', '2');
  perform tests.assert_eq('the name', j ->> 'to_name', 'Gina Guest');
  perform tests.assert_eq('the address', j ->> 'to_email', 'two@x.example');
  perform tests.assert_true('no event', (j -> 'event_title') = 'null'::jsonb);
  perform tests.assert_true('the expiry', (j ->> 'expires_at') is not null);
  perform tests.assert_eq('the club', j ->> 'venue_id', venue_a::text);
  perform tests.assert_eq('a first send says so', j ->> 'first_send', 'true');
  perform tests.assert_eq('the columns are exactly these: nothing about the token or anyone else', (select string_agg(k, ',' order by k) from jsonb_object_keys(j) k),
    'event_title,expires_at,first_send,item,quantity,send_id,time_zone,to_email,to_name,venue_id,venue_name');
  perform tests.assert_eq('a club that never chose a time zone is on the platform default', j ->> 'time_zone', 'America/Toronto');

  -- ---------------------------------------------------------------- which states allow a send
  update public.site_comp_offers set expires_at = now() - interval '1 minute' where id = o3;
  perform tests.assert_eq('an expired offer', tests.begin_col(owner_u, 'owner@send.example', o3, 'send_id'), 'ERROR: a link cannot be sent for an offer that is expired');
  update public.site_comp_offers set status = 'cancelled', cancelled_at = now(), cancel_reason = 'Guest cancelled' where id = o4;
  perform tests.assert_eq('a cancelled offer', tests.begin_col(owner_u, 'owner@send.example', o4, 'send_id'), 'ERROR: a link cannot be sent for an offer that is cancelled');
  update public.site_comp_offers set status = 'location_submitted', location_set_by = 'recipient', location_set_at = now() where id = o5;
  perform tests.assert_eq('one whose recipient already said where they are', tests.begin_col(owner_u, 'owner@send.example', o5, 'send_id'), 'ERROR: a link cannot be sent for an offer that is location submitted');
  update public.site_comp_offers set status = 'accepted' where id = o5;
  perform tests.assert_eq('one already placed at a table', tests.begin_col(owner_u, 'owner@send.example', o5, 'send_id'), 'ERROR: a link cannot be sent for an offer that is accepted');
  update public.site_comp_offers set status = 'delivered', delivered_at = now() where id = o5;
  perform tests.assert_eq('one already delivered', tests.begin_col(owner_u, 'owner@send.example', o5, 'send_id'), 'ERROR: a link cannot be sent for an offer that is delivered');
  perform tests.assert_eq('none of those wrote an attempt', tests.n_sends(o3) + tests.n_sends(o4) + tests.n_sends(o5), 0::bigint);
  update public.site_comp_offers set status = 'sent', sent_at = now() where id = o6;
  perform tests.assert_eq('an offer already sent can be sent again, and says it is not the first', tests.begin_col(owner_u, 'owner@send.example', o6, 'first_send'), 'false');
  update public.site_comp_offers set status = 'awaiting_location', claimed_at = now() where id = o7;
  perform tests.assert_eq('so can one whose link was opened', tests.begin_col(owner_u, 'owner@send.example', o7, 'first_send'), 'false');
  update public.site_venues set time_zone = 'America/Vancouver' where id = venue_a;
  perform tests.assert_eq('a club that chose a time zone gets its own', tests.begin_json(owner_u, 'owner@send.example', o7) ->> 'time_zone', 'America/Vancouver');
  update public.site_venues set time_zone = null where id = venue_a;

  -- ---------------------------------------------------------------- the limits
  -- o2 has 9 attempts' worth of headroom used: it has had 9 begins above (one per column read). Start clean on a fresh offer.
  update public.site_comp_offer_sends set created_at = now() - interval '2 days' where offer_id = o2;
  for i in 1..4 loop perform tests.begin_col(owner_u, 'owner@send.example', o2, 'send_id'); end loop;
  perform tests.assert_eq('four sends in a day are fine (and the fifth)', tests.begin_col(owner_u, 'owner@send.example', o2, 'first_send'), 'true');
  perform tests.assert_eq('the sixth in a day is refused in plain words', tests.begin_col(owner_u, 'owner@send.example', o2, 'send_id'), 'ERROR: this link was sent 5 times in the last day: wait before sending it again');
  perform tests.assert_eq('and wrote nothing', (select count(*) from public.site_comp_offer_sends where offer_id = o2 and created_at > now() - interval '1 day'), 5::bigint);
  update public.site_comp_offer_sends set created_at = now() - interval '25 hours' where id = (select id from public.site_comp_offer_sends where offer_id = o2 order by id limit 1);
  perform tests.assert_eq('an attempt older than a day stops counting', tests.begin_col(owner_u, 'owner@send.example', o2, 'first_send'), 'true');
  perform tests.assert_eq('the limit is for that offer: another offer is not affected', tests.begin_col(owner_u, 'owner@send.example', o1, 'first_send'), 'true');
  -- per person: 30 an hour
  delete from public.site_comp_offer_sends where sent_by = mgr_a;
  insert into public.site_comp_offer_sends (offer_id, sent_by, to_email, first_send, status, failure, finished_at)
    select o3, mgr_a, 'x@x.example', false, 'failed', 'send_failed', now() from generate_series(1, 30);
  perform tests.assert_eq('a person who has sent 30 this hour is asked to wait', tests.begin_col(mgr_a, 'mgra@send.example', o1, 'send_id'), 'ERROR: you have sent a lot of links this hour: wait before sending another');
  perform tests.assert_eq('it is per person: the owner is not stopped by it', tests.begin_col(owner_u, 'owner@send.example', o6, 'first_send'), 'false');
  update public.site_comp_offer_sends set created_at = now() - interval '61 minutes' where sent_by = mgr_a and id = (select id from public.site_comp_offer_sends where sent_by = mgr_a order by id limit 1);
  perform tests.assert_true('29 in the hour is not enough to stop them', tests.begin_col(mgr_a, 'mgra@send.example', o1, 'send_id') ~ '^[0-9a-f-]{36}$');
  delete from public.site_comp_offer_sends where sent_by = mgr_a;

  -- ---------------------------------------------------------------- finishing: only the service role, once, with the provider's message never kept
  perform tests.assert_eq('a manager cannot say the e-mail went', tests.try(mgr_a, 'mgra@send.example', format('select public.comp_offer_send_finish(%L, true, null)::text', s1)), 'ERROR: permission denied for function comp_offer_send_finish');
  perform tests.assert_eq('nor a visitor', tests.try_anon(format('select public.comp_offer_send_finish(%L, true, null)::text', s1)), 'ERROR: permission denied for function comp_offer_send_finish');
  perform tests.assert_eq('the attempt is still pending after those', tests.send_col(s1, 'status'), 'pending');
  perform tests.assert_eq('the service role says it went', tests.svc(format('select public.comp_offer_send_finish(%L, true, %L)::text', s1, 'ignored when it went')), 'true');
  perform tests.assert_eq('it is sent, with a time and no failure', tests.send_col(s1, 'status') || '/' || (tests.send_col(s1, 'finished_at') <> 'null')::text || '/' || tests.send_col(s1, 'failure'), 'sent/true/null');
  perform tests.assert_eq('saying so twice changes nothing and says false', tests.svc(format('select public.comp_offer_send_finish(%L, false, %L)::text', s1, 'send_failed')), 'false');
  perform tests.assert_eq('so it is still sent', tests.send_col(s1, 'status'), 'sent');
  perform tests.assert_eq('an attempt that does not exist is false', tests.svc(format('select public.comp_offer_send_finish(%L, true, null)::text', gen_random_uuid())), 'false');
  perform tests.assert_eq('a first send that went leaves the offer as it was (no token was made by beginning)', tests.offer_col(o1, 'status'), 'approved');

  -- the provider's own words are never kept
  s2 := tests.begin_col(owner_u, 'owner@send.example', o6, 'send_id')::uuid;
  perform tests.svc(format('select public.comp_offer_send_finish(%L, false, %L)::text', s2, 'Resend API error 422: the to address bob@secret.example is not valid'));
  perform tests.assert_eq('a failure with a provider message is stored as a plain reason only', tests.send_col(s2, 'status') || '/' || tests.send_col(s2, 'failure'), 'failed/send_failed');
  s3 := tests.begin_col(owner_u, 'owner@send.example', o6, 'send_id')::uuid;
  perform tests.svc(format('select public.comp_offer_send_finish(%L, false, %L)::text', s3, 'not_configured'));
  perform tests.assert_eq('"not configured" is kept as that', tests.send_col(s3, 'failure'), 'not_configured');
  s3 := tests.begin_col(owner_u, 'owner@send.example', o6, 'send_id')::uuid;
  perform tests.svc(format('select public.comp_offer_send_finish(%L, false, null)::text', s3));
  perform tests.assert_eq('a failure with no reason is "send failed"', tests.send_col(s3, 'failure'), 'send_failed');

  -- ---------------------------------------------------------------- the offer never says "sent" for a link nobody received
  update public.site_comp_offer_sends set created_at = now() - interval '2 days';
  update public.site_comp_offers set status = 'approved', token_hash = null, sent_at = null, claimed_at = null where id in (o1, o6);
  s4 := tests.begin_col(owner_u, 'owner@send.example', o1, 'send_id')::uuid;
  tok := tests.svc(format('select public.comp_offer_issue_link(%L)', o1));
  perform tests.assert_eq('the edge function makes the link after begin: the offer is now sent', tests.offer_col(o1, 'status'), 'sent');
  perform tests.assert_true('and the link works', tests.svc(format('select public.comp_claim_view(%L)::text', tok)) like '%"state": "open"%');
  update public.site_comp_offers set status = 'sent', claimed_at = null where id = o1;
  perform tests.svc(format('select public.comp_offer_send_finish(%L, false, %L)::text', s4, 'send_failed'));
  perform tests.assert_eq('a first send that failed and was never opened: the offer goes back to approved', tests.offer_col(o1, 'status'), 'approved');
  perform tests.assert_eq('and the link no longer exists', tests.offer_col(o1, 'token_hash') || '/' || tests.offer_col(o1, 'sent_at'), 'null/null');
  perform tests.assert_eq('so the old link is simply not found', tests.svc(format('select public.comp_claim_view(%L)::text', tok)), '{"state": "not_found"}');
  -- the guard is on the claim time as well as the state: a "sent" offer that has a claim time is never taken back
  update public.site_comp_offers set status = 'approved', token_hash = null, sent_at = null, claimed_at = null where id = o1;
  s4 := tests.begin_col(owner_u, 'owner@send.example', o1, 'send_id')::uuid;
  tok := tests.svc(format('select public.comp_offer_issue_link(%L)', o1));
  update public.site_comp_offers set claimed_at = now() where id = o1;
  perform tests.svc(format('select public.comp_offer_send_finish(%L, false, %L)::text', s4, 'send_failed'));
  perform tests.assert_eq('a first send that failed, on an offer that has a claim time, leaves it alone', tests.offer_col(o1, 'status'), 'sent');
  update public.site_comp_offers set status = 'approved', token_hash = null, sent_at = null, claimed_at = null where id = o1;
  -- a failure after the recipient opened the link must not undo anything
  s4 := tests.begin_col(owner_u, 'owner@send.example', o1, 'send_id')::uuid;
  tok := tests.svc(format('select public.comp_offer_issue_link(%L)', o1));
  perform tests.svc(format('select public.comp_claim_view(%L)::text', tok));
  perform tests.assert_eq('opened: the offer is awaiting a location', tests.offer_col(o1, 'status'), 'awaiting_location');
  perform tests.svc(format('select public.comp_offer_send_finish(%L, false, %L)::text', s4, 'send_failed'));
  perform tests.assert_eq('a first send that failed but WAS opened leaves the offer alone', tests.offer_col(o1, 'status'), 'awaiting_location');
  perform tests.assert_true('and its link still works', tests.offer_col(o1, 'token_hash') <> 'null');
  -- a failed RE-send changes nothing about the offer
  s5 := tests.begin_col(owner_u, 'owner@send.example', o6, 'send_id')::uuid;
  tok := tests.svc(format('select public.comp_offer_issue_link(%L)', o6));
  update public.site_comp_offer_sends set first_send = false where id = s5;
  perform tests.svc(format('select public.comp_offer_send_finish(%L, false, %L)::text', s5, 'send_failed'));
  perform tests.assert_eq('a failed re-send leaves the offer sent, with the link that was made', tests.offer_col(o6, 'status') || '/' || (tests.offer_col(o6, 'token_hash') <> 'null')::text, 'sent/true');
  -- a send that went leaves the offer sent
  update public.site_comp_offers set status = 'approved', token_hash = null, sent_at = null, claimed_at = null where id = o6;
  s5 := tests.begin_col(owner_u, 'owner@send.example', o6, 'send_id')::uuid;
  tok := tests.svc(format('select public.comp_offer_issue_link(%L)', o6));
  perform tests.svc(format('select public.comp_offer_send_finish(%L, true, null)::text', s5));
  perform tests.assert_eq('a first send that went leaves the offer sent', tests.offer_col(o6, 'status'), 'sent');

  -- ---------------------------------------------------------------- reading the attempts
  update public.site_comp_offer_sends set created_at = now() - interval '2 days';
  delete from public.site_comp_offer_sends;
  insert into public.site_comp_offer_sends (offer_id, sent_by, to_email, first_send, status, failure, created_at, finished_at) values
    (o1, owner_u, 'a@x.example', true, 'failed', 'send_failed', now() - interval '3 minutes', now() - interval '3 minutes'),
    (o1, mgr_a, 'a@x.example', false, 'sent', null, now() - interval '2 minutes', now() - interval '2 minutes'),
    (o1, owner_u, 'a@x.example', false, 'pending', null, now() - interval '1 minute', null);
  perform tests.assert_eq('the manager reads the attempts newest first', tests.try(mgr_a, 'mgra@send.example', format($q$select string_agg(status, ',') from (select * from public.comp_offer_sends(%L)) t$q$, o1)), 'pending,sent,failed');
  perform tests.assert_eq('with which are theirs', tests.try(mgr_a, 'mgra@send.example', format($q$select string_agg(mine::text, ',') from (select * from public.comp_offer_sends(%L)) t$q$, o1)), 'false,true,false');
  perform tests.assert_eq('the owner reads them too, and the others are theirs', tests.try(owner_u, 'owner@send.example', format($q$select string_agg(mine::text, ',') from (select * from public.comp_offer_sends(%L)) t$q$, o1)), 'true,false,true');
  perform tests.assert_eq('the failure reason and the address are there', tests.try(owner_u, 'owner@send.example', format($q$select failure || '/' || to_email from public.comp_offer_sends(%L) where status = 'failed'$q$, o1)), 'send_failed/a@x.example');
  perform tests.assert_eq('a server cannot read them', tests.try(srv_1, 'srv1@send.example', format('select count(*)::text from public.comp_offer_sends(%L)', o1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor another club''s manager', tests.try(mgr_b, 'mgrb@send.example', format('select count(*)::text from public.comp_offer_sends(%L)', o1)), 'ERROR: not allowed');
  perform tests.assert_eq('nor a rival owner', tests.try(rival_u, 'rival@send.example', format('select count(*)::text from public.comp_offer_sends(%L)', o1)), 'ERROR: not allowed');
  perform tests.assert_eq('an offer that does not exist looks the same', tests.try(owner_u, 'owner@send.example', format('select count(*)::text from public.comp_offer_sends(%L)', gen_random_uuid())), 'ERROR: not allowed');
  perform tests.assert_eq('a visitor cannot', tests.try_anon(format('select count(*)::text from public.comp_offer_sends(%L)', o1)), 'ERROR: permission denied for function comp_offer_sends');
  insert into public.site_comp_offer_sends (offer_id, sent_by, to_email, first_send, status, failure, created_at, finished_at)
    select o1, owner_u, 'b@x.example', false, 'sent', null, now() - interval '1 hour' - make_interval(mins => g), now() from generate_series(1, 15) g;
  perform tests.assert_eq('only the latest 10 are returned', tests.try(owner_u, 'owner@send.example', format('select count(*)::text from public.comp_offer_sends(%L)', o1)), '10');

  -- ---------------------------------------------------------------- the throttle for the public page
  perform tests.assert_eq('the first visit is within the limit', tests.svc($q$select public.comp_claim_throttle('ip:aaa', 3, 60)::text$q$), 'true');
  perform tests.assert_eq('the second', tests.svc($q$select public.comp_claim_throttle('ip:aaa', 3, 60)::text$q$), 'true');
  perform tests.assert_eq('the third is the last allowed', tests.svc($q$select public.comp_claim_throttle('ip:aaa', 3, 60)::text$q$), 'true');
  perform tests.assert_eq('the fourth is over', tests.svc($q$select public.comp_claim_throttle('ip:aaa', 3, 60)::text$q$), 'false');
  perform tests.assert_eq('and stays over while it keeps trying', tests.svc($q$select public.comp_claim_throttle('ip:aaa', 3, 60)::text$q$), 'false');
  perform tests.assert_eq('another key is counted on its own', tests.svc($q$select public.comp_claim_throttle('ip:bbb', 3, 60)::text$q$), 'true');
  update public.site_comp_claim_attempts set at = now() - interval '2 minutes' where key = 'ip:aaa';
  perform tests.assert_eq('after the window the old attempts stop counting', tests.svc($q$select public.comp_claim_throttle('ip:aaa', 3, 60)::text$q$), 'true');
  perform tests.assert_eq('the window is the caller''s: a longer one still sees them', tests.svc($q$select public.comp_claim_throttle('ip:aaa', 3, 600)::text$q$), 'false');
  update public.site_comp_claim_attempts set at = now() - interval '2 days' where key = 'ip:bbb';
  perform tests.svc($q$select public.comp_claim_throttle('ip:ccc', 3, 60)::text$q$);
  perform tests.assert_eq('attempts older than a day are cleaned away', (select count(*) from public.site_comp_claim_attempts where key = 'ip:bbb'), 0::bigint);
  perform tests.assert_eq('a manager cannot call it', tests.try(mgr_a, 'mgra@send.example', $q$select public.comp_claim_throttle('ip:x', 3, 60)::text$q$), 'ERROR: permission denied for function comp_claim_throttle');
  perform tests.assert_eq('nor a visitor', tests.try_anon($q$select public.comp_claim_throttle('ip:x', 3, 60)::text$q$), 'ERROR: permission denied for function comp_claim_throttle');
  perform tests.assert_eq('no key', tests.svc($q$select public.comp_claim_throttle(null, 3, 60)::text$q$), 'ERROR: a key of 1 to 120 characters is needed');
  perform tests.assert_eq('an empty key', tests.svc($q$select public.comp_claim_throttle('', 3, 60)::text$q$), 'ERROR: a key of 1 to 120 characters is needed');
  perform tests.assert_eq('a key of 121 characters', tests.svc(format('select public.comp_claim_throttle(%L, 3, 60)::text', repeat('k', 121))), 'ERROR: a key of 1 to 120 characters is needed');
  perform tests.assert_eq('a key of 120 is fine', tests.svc(format('select public.comp_claim_throttle(%L, 3, 60)::text', repeat('k', 120))), 'true');
  perform tests.assert_eq('a limit of 0', tests.svc($q$select public.comp_claim_throttle('ip:x', 0, 60)::text$q$), 'ERROR: the limit is 1 to 1000');
  perform tests.assert_eq('a limit of 1001', tests.svc($q$select public.comp_claim_throttle('ip:x', 1001, 60)::text$q$), 'ERROR: the limit is 1 to 1000');
  perform tests.assert_eq('a window of 0', tests.svc($q$select public.comp_claim_throttle('ip:x', 3, 0)::text$q$), 'ERROR: the window is 1 second to a day');
  perform tests.assert_eq('a window of more than a day', tests.svc($q$select public.comp_claim_throttle('ip:x', 3, 86401)::text$q$), 'ERROR: the window is 1 second to a day');
  perform tests.assert_eq('a refused call counts for nothing', (select count(*) from public.site_comp_claim_attempts where key = 'ip:x'), 0::bigint);

  -- ---------------------------------------------------------------- closed tables, and the table's own rules
  perform tests.assert_eq('signed-in people cannot read the send log', tests.try(owner_u, 'owner@send.example', 'select count(*)::text from public.site_comp_offer_sends'), 'ERROR: permission denied for table site_comp_offer_sends');
  perform tests.assert_eq('nor the throttle', tests.try(owner_u, 'owner@send.example', 'select count(*)::text from public.site_comp_claim_attempts'), 'ERROR: permission denied for table site_comp_claim_attempts');
  perform tests.assert_eq('nor visitors', tests.try_anon('select count(*)::text from public.site_comp_offer_sends'), 'ERROR: permission denied for table site_comp_offer_sends');
  begin
    insert into public.site_comp_offer_sends (offer_id, to_email, first_send, status) values (o1, 'z@x.example', true, 'sent');
    raise exception 'FAIL - the table accepted "sent" with no finish time';
  exception when check_violation then perform tests.assert_true('the table refuses "sent" with no finish time by itself', true); end;
  begin
    insert into public.site_comp_offer_sends (offer_id, to_email, first_send, status, finished_at) values (o1, 'z@x.example', true, 'failed', now());
    raise exception 'FAIL - the table accepted "failed" with no reason';
  exception when check_violation then perform tests.assert_true('the table refuses "failed" with no reason by itself', true); end;
  begin
    insert into public.site_comp_offer_sends (offer_id, to_email, first_send, status, failure, finished_at) values (o1, 'z@x.example', true, 'failed', 'Resend said no', now());
    raise exception 'FAIL - the table accepted a provider message as the reason';
  exception when check_violation then perform tests.assert_true('the table refuses a provider message as the reason by itself', true); end;
  begin
    insert into public.site_comp_offer_sends (offer_id, to_email, first_send, status, failure) values (o1, 'z@x.example', true, 'pending', 'send_failed');
    raise exception 'FAIL - the table accepted a reason on a pending attempt';
  exception when check_violation then perform tests.assert_true('the table refuses a reason on an attempt that has not failed', true); end;

  -- ---------------------------------------------------------------- an account that sent a link can still be deleted
  update public.site_comp_offer_sends set sent_by = mgr_a where id = (select id from public.site_comp_offer_sends where offer_id = o1 order by created_at desc limit 1);
  delete from auth.users where id = mgr_a;
  perform tests.assert_true('deleting the sender''s account is not blocked, and the attempt stays with no sender', exists (select 1 from public.site_comp_offer_sends where offer_id = o1 and sent_by is null));
end $$;

rollback;
