-- Temporary staff links (20261118100000_temporary_staff_links.sql). What matters: only the people who may already invite someone invite temporary staff, for server, door, security or verifier only, with an END to
-- the access and a link that lives 1 hour to 7 days; a temporary link CANNOT be used until the invitee has typed the 6-digit code sent to the invited address, on every path (the existing accept function, a plain
-- update); the code is made for the e-mail function only and never reaches the app, is stored only as a hash, is limited in how often it is sent, and five wrong guesses lock it (wrong guesses are counted, so the
-- check answers instead of raising); a verification lasts 30 minutes and belongs to one link; a new link starts again; the preview tells the invitee what they need and tells a stranger nothing; the invitee of an
-- EXPIRED link can ask for a new one, which the people who manage the invitation see; the access really ends; and none of the reads changes anything.
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
-- A temporary invitation: the token, or 'ERROR: <the sentence>'.
create function tests.tmp_invite(p_user uuid, p_email text, p_org uuid, p_to text, p_role text, p_venue uuid, p_hours int default 24, p_end timestamptz default null, p_shift uuid default null) returns text language plpgsql as $$
declare t text;
begin
  perform tests.login(p_user, p_email);
  select i.token into t from public.invite_temporary_staff(p_org, p_to, p_role, p_venue, null, p_shift, null, case when p_end is null and p_shift is null then now() + interval '6 hours' else p_end end, p_hours) i;
  perform tests.logout();
  return t;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
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
-- The code the e-mail function would send: the digits, or 'ERROR: <the sentence>'.
create function tests.issue(p_token text, p_email text) returns text language plpgsql as $$
declare c text;
begin
  perform tests.login_service();
  select i.code into c from public.issue_invitation_code(p_token, p_email) i;
  perform tests.logout();
  return c;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.verify(p_user uuid, p_email text, p_token text, p_code text) returns text language plpgsql as $$
declare o text; l int;
begin
  perform tests.login(p_user, p_email);
  select v.outcome, v.attempts_left into o, l from public.verify_invitation_code(p_token, p_code) v;
  perform tests.logout();
  return o || '/' || coalesce(l::text, '-');
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.accept(p_user uuid, p_email text, p_token text) returns text language plpgsql as $$
declare o text;
begin
  perform tests.login(p_user, p_email);
  select a.outcome into o from public.accept_invitation(p_token) a;
  perform tests.logout();
  return o;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.preview(p_user uuid, p_email text, p_token text) returns jsonb language plpgsql as $$
declare j jsonb;
begin
  perform tests.login(p_user, p_email);
  j := public.invitation_preview(p_token);
  perform tests.logout();
  return j;
exception when others then
  perform tests.logout();
  return jsonb_build_object('error', sqlerrm);
end $$;
create function tests.renew(p_user uuid, p_email text, p_token text, p_note text default null) returns text language plpgsql as $$
declare o text;
begin
  perform tests.login(p_user, p_email);
  o := public.request_invitation_renewal(p_token, p_note);
  perform tests.logout();
  return o;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.inv(p_token text) returns public.site_invitations language sql security definer as $$
  select * from public.site_invitations where token_hash = sha256(convert_to(p_token, 'utf8')) $$;
create function tests.hash_of(p_token text) returns bytea language sql as $$ select sha256(convert_to(p_token, 'utf8')) $$;
create function tests.extras(p_user uuid, p_email text, p_org uuid, p_invitation uuid) returns text language plpgsql as $$
declare r text;
begin
  perform tests.login(p_user, p_email);
  select coalesce(string_agg(i.kind || ':' || i.identity_verified::text || ':' || (i.renewal_requested_at is not null)::text || ':' || coalesce(i.renewal_note, '-'), ' | '), '(none)') into r from public.list_invitation_extras(p_org) i where i.invitation_id = p_invitation;
  perform tests.logout();
  return r;
exception when others then
  perform tests.logout();
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-00000000f0d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-00000000f0d2';
  mgr_b constant uuid := '00000000-0000-0000-0000-00000000f0d3';
  srv_perm constant uuid := '00000000-0000-0000-0000-00000000f0d4';
  temp_u constant uuid := '00000000-0000-0000-0000-00000000f0d5';
  other_u constant uuid := '00000000-0000-0000-0000-00000000f0d6';
  rando constant uuid := '00000000-0000-0000-0000-00000000f0d7';
  plain_u constant uuid := '00000000-0000-0000-0000-00000000f0d8';
  org uuid; venue_a uuid; venue_b uuid; shift_a uuid; shift_b uuid;
  tok text; tok2 text; tok3 text; tok_p text; code text; code2 text; r text; j jsonb; n1 bigint; n2 bigint; n3 bigint; inv_id uuid; mid uuid;
begin
  insert into auth.users (id, email) values (owner_u, 'owner@tmp.example'), (mgr_a, 'mgra@tmp.example'), (mgr_b, 'mgrb@tmp.example'), (srv_perm, 'perm@tmp.example'), (temp_u, 'temp@tmp.example'),
    (other_u, 'other@tmp.example'), (rando, 'rando@tmp.example'), (plain_u, 'plain@tmp.example');
  perform tests.login(owner_u, 'owner@tmp.example');
  org := public.create_organization('Temp Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.logout();
  perform tests.join_as(owner_u, 'owner@tmp.example', org, 'mgra@tmp.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@tmp.example', org, 'mgrb@tmp.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@tmp.example', org, 'perm@tmp.example', 'server', venue_a, srv_perm);
  perform tests.login(mgr_a, 'mgra@tmp.example');
  shift_a := public.create_shift(venue_a, 'Friday late', now() + interval '1 hour', now() + interval '9 hours');
  perform tests.login(mgr_b, 'mgrb@tmp.example');
  shift_b := public.create_shift(venue_b, 'Friday late B', now() + interval '1 hour', now() + interval '9 hours');
  perform tests.logout();

  ---------------------------------------------------------------- nothing changes for what exists
  perform tests.login(mgr_a, 'mgra@tmp.example');
  select i.token into tok_p from public.invite_member(org, 'plain@tmp.example', 'security', venue_a) i;
  select i.token into tok3 from public.invite_member(org, 'plain@tmp.example', 'door', venue_a) i;
  perform tests.logout();
  perform tests.assert_eq('an ordinary invitation is permanent, with nothing confirmed or asked', (select i.kind || '/' || coalesce(i.identity_verified_at::text, '-') || '/' || coalesce(i.renewal_requested_at::text, '-') from tests.inv(tok_p) i), 'permanent/-/-');
  perform tests.assert_eq('the code table is closed to the app', (select count(*) from information_schema.role_table_grants where table_name = 'site_invitation_codes' and grantee in ('anon', 'authenticated', 'public')), 0::bigint);
  perform tests.assert_eq('no column of it holds a code in the clear', (select count(*) from information_schema.columns where table_name = 'site_invitation_codes' and column_name in ('code', 'plain_code', 'code_text')), 0::bigint);

  ---------------------------------------------------------------- inviting temporary staff
  tok := tests.tmp_invite(mgr_a, 'mgra@tmp.example', org, 'Temp@tmp.example', 'server', venue_a);
  perform tests.assert_true('the manager gets a link', length(tok) > 20 and tok not like 'ERROR%');
  perform tests.assert_eq('it is a temporary invitation, pending, to the address as typed in lower case, for a server at the club', (select i.kind || '/' || i.status || '/' || i.email || '/' || i.role || '/' || (i.venue_id = venue_a)::text from tests.inv(tok) i), 'temporary/pending/temp@tmp.example/server/true');
  perform tests.assert_eq('it lives about 24 hours (the suggested default)', (select (i.expires_at > now() + interval '23 hours' and i.expires_at < now() + interval '25 hours')::text from tests.inv(tok) i), 'true');
  perform tests.assert_eq('it carries the end of the access', (select (i.access_end_at > now() + interval '5 hours' and i.access_end_at < now() + interval '7 hours')::text from tests.inv(tok) i), 'true');
  perform tests.assert_true('the invitation is recorded with who made it', exists (select 1 from public.audit_log where action = 'team.temporary_invitation_created' and actor_email = 'mgra@tmp.example' and details ->> 'role' = 'server'));
  perform tests.assert_eq('the owner can invite door staff for the club too', tests.tmp_invite(owner_u, 'owner@tmp.example', org, 'door@tmp.example', 'door', venue_a) not like 'ERROR%', true);
  perform tests.assert_eq('a manager is not temporary staff', tests.tmp_invite(owner_u, 'owner@tmp.example', org, 'boss@tmp.example', 'manager', venue_a), 'ERROR: temporary access is for servers, door staff, security and verifiers');
  perform tests.assert_eq('a role that does not exist', tests.tmp_invite(owner_u, 'owner@tmp.example', org, 'x@tmp.example', 'ceo', venue_a), 'ERROR: temporary access is for servers, door staff, security and verifiers');
  perform tests.assert_eq('there must be an end', tests.try(mgr_a, 'mgra@tmp.example', format($q$select (select i.token from public.invite_temporary_staff(%L, 'a@tmp.example', 'server', %L, null, null, null, null, 24) i)$q$, org, venue_a)), 'ERROR: say when the access ends: an end time, or a shift');
  perform tests.assert_eq('...and not one that is already over', tests.tmp_invite(mgr_a, 'mgra@tmp.example', org, 'b@tmp.example', 'server', venue_a, 24, now() - interval '1 minute'), 'ERROR: the access would already be over');
  perform tests.assert_eq('a link may not be valid for less than an hour', tests.tmp_invite(mgr_a, 'mgra@tmp.example', org, 'c@tmp.example', 'server', venue_a, 0), 'ERROR: the link must stay valid for between 1 hour and 7 days');
  perform tests.assert_eq('...nor more than seven days', tests.tmp_invite(mgr_a, 'mgra@tmp.example', org, 'd@tmp.example', 'server', venue_a, 169), 'ERROR: the link must stay valid for between 1 hour and 7 days');
  perform tests.assert_eq('seven days exactly is fine', tests.tmp_invite(mgr_a, 'mgra@tmp.example', org, 'e@tmp.example', 'server', venue_a, 168) not like 'ERROR%', true);
  perform tests.assert_eq('another club''s manager cannot invite to this club', tests.tmp_invite(mgr_b, 'mgrb@tmp.example', org, 'f@tmp.example', 'server', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot invite anyone', tests.tmp_invite(srv_perm, 'perm@tmp.example', org, 'g@tmp.example', 'server', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('a stranger cannot', tests.tmp_invite(rando, 'rando@tmp.example', org, 'h@tmp.example', 'server', venue_a), 'ERROR: not allowed');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot', format($q$select * from public.invite_temporary_staff(%L, 'i@tmp.example', 'server', %L, null, null, null, now() + interval '1 hour', 24)$q$, org, venue_a), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('a shift can stand for the end of the access', tests.tmp_invite(mgr_a, 'mgra@tmp.example', org, 'shift@tmp.example', 'verifier', venue_a, 24, null, shift_a) not like 'ERROR%', true);
  perform tests.assert_eq('...but only a shift of that club', tests.tmp_invite(mgr_a, 'mgra@tmp.example', org, 'shift2@tmp.example', 'verifier', venue_a, 24, null, shift_b), 'ERROR: shift does not belong to this venue');
  tok2 := tests.tmp_invite(mgr_a, 'mgra@tmp.example', org, 'temp@tmp.example', 'server', venue_a);
  perform tests.assert_eq('inviting the same person again for the same place makes no second invitation: the first link stops working, the new one is the invitation', concat_ws('/',
    (select count(*) from public.site_invitations where email = 'temp@tmp.example' and role = 'server' and status = 'pending'), ((tests.inv(tok)).id is null)::text, (tests.inv(tok2)).kind), '1/true/temporary');
  tok := tok2;

  ---------------------------------------------------------------- the link cannot be used without the code, whatever function is used
  perform tests.assert_eq('accepting without confirming the address is refused', tests.accept(temp_u, 'temp@tmp.example', tok), 'ERROR: confirm your e-mail with the code we sent before using this link');
  perform tests.assert_eq('...nothing was granted', (select count(*) from public.site_memberships where user_id = temp_u and role = 'server'), 0::bigint);
  perform tests.assert_eq('...and the invitation is still pending', (select (tests.inv(tok)).status), 'pending');
  perform tests.assert_raises('a plain update to accepted is refused by the table itself', format($q$update public.site_invitations set status = 'accepted', accepted_by = %L, accepted_at = now() where token_hash = tests.hash_of(%L)$q$, temp_u, tok), 'confirm your e-mail with the code');
  perform tests.assert_eq('a permanent invitation is not asked for a code', tests.accept(plain_u, 'plain@tmp.example', tok_p), 'ok');

  ---------------------------------------------------------------- the code: made for the e-mail function only
  perform tests.login(temp_u, 'temp@tmp.example');
  perform tests.assert_raises('the signed-in invitee cannot ask for the code to be shown to them', format('select * from public.issue_invitation_code(%L, %L)', tok, 'temp@tmp.example'), 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot either', format('select * from public.issue_invitation_code(%L, %L)', tok, 'temp@tmp.example'), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('it is not made for another person''s address', tests.issue(tok, 'other@tmp.example'), 'ERROR: not allowed');
  perform tests.assert_eq('...nor for a link that does not exist', tests.issue('not-a-token', 'temp@tmp.example'), 'ERROR: not allowed');
  perform tests.assert_eq('a permanent link has no code', tests.issue(tok3, 'plain@tmp.example'), 'ERROR: this link does not need a code');
  code := tests.issue(tok, 'TEMP@tmp.example');
  perform tests.assert_true('the code is six digits (the address is matched in any case)', code ~ '^[0-9]{6}$');
  perform tests.assert_eq('only a hash is kept, tied to this invitation', (select (c.code_hash = sha256(convert_to(code || ':' || (tests.inv(tok)).id::text, 'utf8')))::text from public.site_invitation_codes c where c.invitation_id = (tests.inv(tok)).id), 'true');
  perform tests.assert_eq('asking again at once is refused', tests.issue(tok, 'temp@tmp.example'), 'ERROR: please wait a minute before asking for another code');
  update public.site_invitation_codes set last_sent_at = clock_timestamp() - interval '30 seconds' where invitation_id = (tests.inv(tok)).id;
  perform tests.assert_eq('...even half a minute later', tests.issue(tok, 'temp@tmp.example'), 'ERROR: please wait a minute before asking for another code');
  update public.site_invitation_codes set last_sent_at = clock_timestamp() - interval '2 minutes' where invitation_id = (tests.inv(tok)).id;
  code2 := tests.issue(tok, 'temp@tmp.example');
  perform tests.assert_true('after a minute another is made, and counts again from nothing', code2 ~ '^[0-9]{6}$' and (select c.attempts = 0 and c.sends = 2 from public.site_invitation_codes c where c.invitation_id = (tests.inv(tok)).id));
  code := code2;
  for n1 in 3..5 loop
    update public.site_invitation_codes set last_sent_at = clock_timestamp() - interval '2 minutes' where invitation_id = (tests.inv(tok)).id;
    code := tests.issue(tok, 'temp@tmp.example');
  end loop;
  update public.site_invitation_codes set last_sent_at = clock_timestamp() - interval '2 minutes' where invitation_id = (tests.inv(tok)).id;
  perform tests.assert_eq('five codes in an hour is the most', tests.issue(tok, 'temp@tmp.example'), 'ERROR: too many codes: try again in an hour');
  update public.site_invitation_codes set window_started_at = clock_timestamp() - interval '61 minutes', last_sent_at = clock_timestamp() - interval '61 minutes' where invitation_id = (tests.inv(tok)).id;
  code := tests.issue(tok, 'temp@tmp.example');
  perform tests.assert_true('...and after the hour it starts again', code ~ '^[0-9]{6}$' and (select c.sends = 1 from public.site_invitation_codes c where c.invitation_id = (tests.inv(tok)).id));

  ---------------------------------------------------------------- checking the code
  perform tests.assert_eq('someone else''s address', tests.verify(other_u, 'other@tmp.example', tok, code), 'email_mismatch/-');
  perform tests.assert_eq('a link that does not exist', tests.verify(temp_u, 'temp@tmp.example', 'nope', code), 'invalid/-');
  perform tests.assert_eq('letters are not a code, and do not use up a try', tests.verify(temp_u, 'temp@tmp.example', tok, 'abc123'), 'malformed/5');
  perform tests.assert_eq('five digits are not a code either', tests.verify(temp_u, 'temp@tmp.example', tok, '12345'), 'malformed/5');
  perform tests.assert_eq('a wrong code is counted: four tries left', tests.verify(temp_u, 'temp@tmp.example', tok, case when code = '000000' then '000001' else '000000' end), 'wrong/4');
  perform tests.assert_eq('...then three', tests.verify(temp_u, 'temp@tmp.example', tok, case when code = '000000' then '000001' else '000000' end), 'wrong/3');
  perform tests.assert_eq('...two', tests.verify(temp_u, 'temp@tmp.example', tok, case when code = '000000' then '000001' else '000000' end), 'wrong/2');
  perform tests.assert_eq('...one', tests.verify(temp_u, 'temp@tmp.example', tok, case when code = '000000' then '000001' else '000000' end), 'wrong/1');
  perform tests.assert_eq('the fifth wrong code locks it', tests.verify(temp_u, 'temp@tmp.example', tok, case when code = '000000' then '000001' else '000000' end), 'wrong/0');
  perform tests.assert_eq('...and then even the right one is refused', tests.verify(temp_u, 'temp@tmp.example', tok, code), 'locked/0');
  perform tests.assert_eq('a locked code did not confirm anything', (select (tests.inv(tok)).identity_verified_at is null), true);
  update public.site_invitation_codes set last_sent_at = clock_timestamp() - interval '2 minutes' where invitation_id = (tests.inv(tok)).id;
  code := tests.issue(tok, 'temp@tmp.example');
  update public.site_invitation_codes set expires_at = now() - interval '1 second' where invitation_id = (tests.inv(tok)).id;
  perform tests.assert_eq('a code lives ten minutes: after that it is expired', tests.verify(temp_u, 'temp@tmp.example', tok, code), 'code_expired/-');
  update public.site_invitation_codes set last_sent_at = clock_timestamp() - interval '2 minutes' where invitation_id = (tests.inv(tok)).id;
  code := tests.issue(tok, 'temp@tmp.example');
  perform tests.assert_eq('a new code starts the tries again, and its life is about ten minutes', (select (c.attempts = 0 and c.expires_at > now() + interval '9 minutes' and c.expires_at < now() + interval '11 minutes')::text from public.site_invitation_codes c where c.invitation_id = (tests.inv(tok)).id), 'true');
  perform tests.assert_eq('the right code confirms the address', tests.verify(temp_u, 'temp@tmp.example', tok, ' ' || code || ' '), 'ok/-');
  perform tests.assert_eq('...it is remembered on the invitation, and the code is used up', (select ((tests.inv(tok)).identity_verified_at is not null)::text || '/' || (select count(*) from public.site_invitation_codes c where c.invitation_id = (tests.inv(tok)).id)), 'true/0');
  perform tests.assert_eq('confirming again, while it holds, is fine', tests.verify(temp_u, 'temp@tmp.example', tok, '000000'), 'ok/-');
  perform tests.assert_eq('checking a code on a permanent link: none is needed', tests.verify(plain_u, 'plain@tmp.example', tok3, '000000'), 'not_needed/-');
  perform tests.assert_eq('...and on one already used, there is nothing to check', tests.verify(plain_u, 'plain@tmp.example', tok_p, '000000'), 'already_accepted/-');

  ---------------------------------------------------------------- using the link
  update public.site_invitations set identity_verified_at = now() - interval '31 minutes' where token_hash = tests.hash_of(tok);
  perform tests.assert_eq('a confirmation older than half an hour no longer counts', tests.accept(temp_u, 'temp@tmp.example', tok), 'ERROR: confirm your e-mail with the code we sent before using this link');
  perform tests.assert_eq('...and verifying again says so', tests.verify(temp_u, 'temp@tmp.example', tok, '000000'), 'no_code/-');
  update public.site_invitations set identity_verified_at = now() - interval '5 minutes' where token_hash = tests.hash_of(tok);
  perform tests.assert_eq('within half an hour the link works', tests.accept(temp_u, 'temp@tmp.example', tok), 'ok');
  select m.id into mid from public.site_memberships m where m.user_id = temp_u and m.role = 'server' and m.venue_id = venue_a;
  perform tests.assert_eq('...and gives a server at the club whose access ENDS', (select (m.access_end_at > now() + interval '5 hours' and m.access_end_at < now() + interval '7 hours')::text || '/' || m.status from public.site_memberships m where m.id = mid), 'true/active');
  perform tests.assert_eq('the person is a member of the business now', tests.try(temp_u, 'temp@tmp.example', format('select public.is_org_member(%L)::text', org)), 'true');
  perform tests.assert_eq('using the link again changes nothing', tests.accept(temp_u, 'temp@tmp.example', tok), 'already_accepted');
  update public.site_memberships set access_end_at = now() - interval '1 minute', access_start_at = now() - interval '7 hours' where id = mid;
  perform tests.assert_eq('once the end has passed there is no access at all', tests.try(temp_u, 'temp@tmp.example', format('select public.is_org_member(%L)::text', org)), 'false');
  perform tests.assert_eq('...and what they did stays attributable: the membership row is still there', (select count(*) from public.site_memberships where id = mid), 1::bigint);

  ---------------------------------------------------------------- a confirmation belongs to one link
  tok := tests.tmp_invite(mgr_a, 'mgra@tmp.example', org, 'temp@tmp.example', 'door', venue_a);
  perform tests.assert_eq('a second temporary link for the same person starts unconfirmed', tests.accept(temp_u, 'temp@tmp.example', tok), 'ERROR: confirm your e-mail with the code we sent before using this link');
  code := tests.issue(tok, 'temp@tmp.example');
  perform tests.assert_eq('confirmed with its own code', tests.verify(temp_u, 'temp@tmp.example', tok, code), 'ok/-');
  select (tests.inv(tok)).id into inv_id;
  perform tests.assert_eq('a code can be open while the address is already confirmed (the invitee asks again)', tests.issue(tok, 'temp@tmp.example') ~ '^[0-9]{6}$', true);
  perform tests.assert_eq('...it is waiting', (select count(*) from public.site_invitation_codes c where c.invitation_id = inv_id), 1::bigint);
  perform tests.login(mgr_a, 'mgra@tmp.example');
  select r.token into tok2 from public.resend_invitation(inv_id) r;
  perform tests.logout();
  perform tests.assert_eq('a new link clears the confirmation and any open code', concat_ws('/', ((tests.inv(tok2)).identity_verified_at is null)::text, (select count(*) from public.site_invitation_codes c where c.invitation_id = inv_id), ((tests.inv(tok)).id is null)::text), 'true/0/true');
  perform tests.assert_eq('the old link no longer works', tests.accept(temp_u, 'temp@tmp.example', tok), 'invalid');
  perform tests.assert_eq('the new one needs the check again', tests.accept(temp_u, 'temp@tmp.example', tok2), 'ERROR: confirm your e-mail with the code we sent before using this link');
  tok := tok2;

  ---------------------------------------------------------------- what the invitee is told before they accept
  j := tests.preview(temp_u, 'temp@tmp.example', tok);
  perform tests.assert_eq('a good link: a code is needed, to an address shown with most of it hidden, with what the access is', concat_ws('/', j ->> 'outcome', j ->> 'kind', j ->> 'needs_code', j ->> 'email_hint', j ->> 'role', j ->> 'org_name', j ->> 'venue_name',
    ((j ->> 'access_end_at') is not null)::text, j ->> 'renewal_requested'), 'ok/temporary/true/t***@tmp.example/door/Temp Co/Club A/true/false');
  code := tests.issue(tok, 'temp@tmp.example');
  perform tests.verify(temp_u, 'temp@tmp.example', tok, code);
  perform tests.assert_eq('once confirmed no code is needed', tests.preview(temp_u, 'temp@tmp.example', tok) ->> 'needs_code', 'false');
  j := tests.preview(plain_u, 'plain@tmp.example', tok3);
  perform tests.assert_eq('a permanent link never needs a code', concat_ws('/', j ->> 'outcome', j ->> 'kind', j ->> 'needs_code'), 'ok/permanent/false');
  perform tests.assert_eq('a link that does not exist reveals nothing', tests.preview(temp_u, 'temp@tmp.example', 'nope')::text, '{"outcome": "invalid"}');
  perform tests.assert_eq('so does someone else''s link: only that it is not theirs', tests.preview(other_u, 'other@tmp.example', tok)::text, '{"outcome": "email_mismatch"}');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot ask', format('select public.invitation_preview(%L)', tok), 'permission denied');
  perform tests.logout();

  ---------------------------------------------------------------- an expired link: ask for a new one
  perform tests.assert_eq('a link that has not expired needs no renewal', tests.renew(temp_u, 'temp@tmp.example', tok), 'not_expired');
  perform tests.assert_eq('only the invitee can ask', tests.renew(other_u, 'other@tmp.example', tok), 'email_mismatch');
  perform tests.assert_eq('a link that does not exist', tests.renew(temp_u, 'temp@tmp.example', 'nope'), 'invalid');
  update public.site_invitations set expires_at = now() - interval '1 minute', identity_verified_at = null where token_hash = tests.hash_of(tok);
  j := tests.preview(temp_u, 'temp@tmp.example', tok);
  perform tests.assert_eq('the preview of an expired link says so, and that a code is no use', concat_ws('/', j ->> 'outcome', j ->> 'needs_code', j ->> 'role', j ->> 'renewal_requested'), 'expired/false/door/false');
  perform tests.assert_eq('the invitee of an expired link can ask for a new one', tests.renew(temp_u, 'temp@tmp.example', tok, '  I was running late  '), 'requested');
  perform tests.assert_eq('...asking again soon changes nothing', tests.renew(temp_u, 'temp@tmp.example', tok), 'already_requested');
  perform tests.assert_eq('...the preview now says it was asked for', tests.preview(temp_u, 'temp@tmp.example', tok) ->> 'renewal_requested', 'true');
  perform tests.assert_eq('a note is kept trimmed', (select (tests.inv(tok)).renewal_note), 'I was running late');
  perform tests.assert_true('the request is recorded', exists (select 1 from public.audit_log where action = 'team.invitation_renewal_requested' and actor_email = 'temp@tmp.example'));
  perform tests.assert_eq('a note over 200 characters is refused', tests.renew(temp_u, 'temp@tmp.example', tok, repeat('z', 201)), 'ERROR: keep the note to 200 characters or fewer');
  update public.site_invitations set renewal_requested_at = now() - interval '7 hours' where token_hash = tests.hash_of(tok);
  perform tests.assert_eq('a fresh request after six hours', tests.renew(temp_u, 'temp@tmp.example', tok), 'requested');
  perform tests.assert_eq('a code cannot be made for an expired link', tests.issue(tok, 'temp@tmp.example'), 'ERROR: invitation is not pending');
  perform tests.assert_eq('nor can it be checked', tests.verify(temp_u, 'temp@tmp.example', tok, '000000'), 'expired/-');
  perform tests.assert_eq('nor accepted', tests.accept(temp_u, 'temp@tmp.example', tok), 'expired');

  ---------------------------------------------------------------- the people who manage it see the request
  select (tests.inv(tok)).id into inv_id;
  perform tests.assert_eq('the club''s manager sees a temporary invitation, that its address was not confirmed, and the request for a new link', tests.extras(mgr_a, 'mgra@tmp.example', org, inv_id), 'temporary:false:true:-');
  perform tests.assert_eq('the owner sees it too', tests.extras(owner_u, 'owner@tmp.example', org, inv_id), 'temporary:false:true:-');
  perform tests.assert_eq('another club''s manager sees nothing of it', tests.extras(mgr_b, 'mgrb@tmp.example', org, inv_id), '(none)');
  perform tests.assert_eq('a server of the club sees nothing', tests.extras(srv_perm, 'perm@tmp.example', org, inv_id), '(none)');
  perform tests.assert_eq('a stranger is refused', tests.extras(rando, 'rando@tmp.example', org, inv_id), 'ERROR: not allowed');
  perform tests.assert_eq('a permanent invitation with no request is not listed', tests.extras(mgr_a, 'mgra@tmp.example', org, (tests.inv(tok3)).id), '(none)');
  perform tests.login(mgr_a, 'mgra@tmp.example');
  select r.token into tok2 from public.resend_invitation(inv_id) r;
  perform tests.logout();
  perform tests.assert_eq('sending a new link clears the request and the confirmation', tests.extras(mgr_a, 'mgra@tmp.example', org, inv_id), 'temporary:false:false:-');
  perform tests.assert_eq('...and the new link is valid again, needing the check', tests.preview(temp_u, 'temp@tmp.example', tok2) ->> 'needs_code', 'true');
  perform tests.assert_eq('the manager revokes the invitation', tests.try(mgr_a, 'mgra@tmp.example', format('select public.revoke_invitation(%L)::text', inv_id)), '');
  perform tests.assert_eq('...preview', tests.preview(temp_u, 'temp@tmp.example', tok2)::text, '{"outcome": "revoked"}');
  perform tests.assert_eq('...renewal', tests.renew(temp_u, 'temp@tmp.example', tok2), 'revoked');
  perform tests.assert_eq('...code', tests.issue(tok2, 'temp@tmp.example'), 'ERROR: invitation is not pending');
  perform tests.assert_eq('...checking', tests.verify(temp_u, 'temp@tmp.example', tok2, '000000'), 'revoked/-');

  ---------------------------------------------------------------- reading changes nothing
  select count(*) into n1 from public.site_invitations;
  select count(*) into n2 from public.site_invitation_codes;
  select count(*) into n3 from public.audit_log;
  perform tests.preview(temp_u, 'temp@tmp.example', tok2);
  perform tests.extras(mgr_a, 'mgra@tmp.example', org, inv_id);
  perform tests.assert_true('the same rows after looking', (select count(*) from public.site_invitations) = n1 and (select count(*) from public.site_invitation_codes) = n2 and (select count(*) from public.audit_log) = n3);
end $$;

rollback;
