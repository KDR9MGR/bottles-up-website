-- Renaming a business from the Business app (20261127100000_rename_business.sql; developer fix list 22 Nov, item 4). What matters: only the business's own owner or organizer (with access that is
-- still valid) can do it; the name is tidied and checked (length, characters, not the same, not another business's); once every 30 days, except a fix of capitals or spacing; the events that have
-- NOT started (and drafts) carry the new name and the ones already held keep the old; the business really has the new name everywhere it is read; it leaves a record; a refused attempt changes nothing.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
-- run one statement as a person (an error is returned as text)
create function tests.run_as(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
-- read or change a closed table as its owner
create function tests.q(p_sql text) returns text language plpgsql security definer as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, 'null');
end $$;
create function tests.x(p_sql text) returns void language plpgsql security definer as $$ begin execute p_sql; end $$;
create function tests.names(p_org uuid) returns text language sql security definer as $$
  select coalesce(string_agg(e.title || '=' || coalesce(e.organizer_name, '-'), ', ' order by e.title), '') from public.site_events e where e.org_id = p_org $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000006a1';
  mgr_u constant uuid := '00000000-0000-0000-0000-0000000006a2';
  stranger constant uuid := '00000000-0000-0000-0000-0000000006a3';
  rival_u constant uuid := '00000000-0000-0000-0000-0000000006a4';
  org_u constant uuid := '00000000-0000-0000-0000-0000000006a5';
  door_u constant uuid := '00000000-0000-0000-0000-0000000006a6';
  org uuid; rival uuid; eorg uuid; venue uuid; r record; n_audit int; changed timestamptz; rn text;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@rn.example'), (mgr_u, 'mgr@rn.example'), (stranger, 'stranger@rn.example'), (rival_u, 'rival@rn.example'), (org_u, 'organizer@rn.example'), (door_u, 'door@rn.example');

  perform tests.login(owner_u, 'owner@rn.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue := public.create_org_venue(org, 'Club A');
  perform tests.join_as(owner_u, 'owner@rn.example', org, 'mgr@rn.example', 'manager', venue, mgr_u);
  perform tests.login(rival_u, 'rival@rn.example');
  rival := public.create_organization('Rival  Nights', 'venue_owner');
  perform tests.login(org_u, 'organizer@rn.example');
  eorg := public.create_organization('Events Crew', 'organizer');
  perform tests.logout();

  -- the events the business carries its name on: a draft in the past, a published one that has not started, one that is happening now, one already finished, and a rival's published one
  insert into public.site_events (title, description, venue_name, start_date, status, org_id, organizer_name) values
    ('e1 draft old', 'd', 'Club A', now() - interval '20 days', 'draft', org, 'Club Co'),
    ('e2 next week', 'd', 'Club A', now() + interval '7 days', 'published', org, 'Club Co'),
    ('e3 on now', 'd', 'Club A', now() - interval '1 hour', 'published', org, 'Club Co'),
    ('e4 last month', 'd', 'Club A', now() - interval '30 days', 'published', org, 'Club Co'),
    ('r1 rival next week', 'd', 'Rival', now() + interval '7 days', 'published', rival, 'Rival Nights');
  perform tests.assert_true('a new business has never been renamed', (select name_changed_at is null from public.site_organizations where id = org));

  ---------------------------------------------------------------- who may rename
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot rename', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, org), 'permission denied');
  perform tests.login_service();
  perform tests.assert_raises('the service role has no person behind it, so it is told to sign in', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, org), 'not authenticated');
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform tests.assert_raises('a token with no user is told to sign in', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, org), 'not authenticated');
  perform tests.login(stranger, 'stranger@rn.example');
  perform tests.assert_raises('a stranger cannot rename someone else''s business', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, org), 'not allowed');
  perform tests.assert_raises('...nor one that does not exist', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, gen_random_uuid()), 'not allowed');
  perform tests.assert_raises('...nor no business at all', $q$select * from public.rename_business(null, 'Anything Goes')$q$, 'not allowed');
  perform tests.login(rival_u, 'rival@rn.example');
  perform tests.assert_raises('the owner of another business cannot rename this one', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, org), 'not allowed');
  perform tests.assert_raises('...and an organizer business cannot be renamed by a venue owner', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, eorg), 'not allowed');
  perform tests.login(mgr_u, 'mgr@rn.example');
  perform tests.assert_raises('a manager of the business cannot rename it (only the owner)', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, org), 'not allowed');
  perform tests.logout();
  perform tests.assert_eq('nothing changed after those attempts', (select name from public.site_organizations where id = org), 'Club Co');

  -- an owner whose access has ended is not an owner any more
  perform tests.x(format($q$update public.site_memberships set access_end_at = now() - interval '1 hour' where org_id = %L and user_id = %L$q$, org, owner_u));
  perform tests.login(owner_u, 'owner@rn.example');
  perform tests.assert_raises('an owner whose access has run out is refused', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, org), 'not allowed');
  perform tests.x(format($q$update public.site_memberships set access_end_at = null where org_id = %L and user_id = %L$q$, org, owner_u));
  perform tests.x(format($q$update public.site_memberships set status = 'revoked' where org_id = %L and user_id = %L$q$, org, owner_u));
  perform tests.login(owner_u, 'owner@rn.example');
  perform tests.assert_raises('...and so is one whose access was taken away', format($q$select * from public.rename_business(%L, 'Anything Goes')$q$, org), 'not allowed');
  perform tests.x(format($q$update public.site_memberships set status = 'active' where org_id = %L and user_id = %L$q$, org, owner_u));
  perform tests.logout();

  ---------------------------------------------------------------- the name itself
  perform tests.login(owner_u, 'owner@rn.example');
  perform tests.assert_raises('no name is refused', format($q$select * from public.rename_business(%L, null)$q$, org), 'at least 2 characters');
  perform tests.assert_raises('a blank name is refused', format($q$select * from public.rename_business(%L, '    ')$q$, org), 'at least 2 characters');
  perform tests.assert_raises('one letter is refused', format($q$select * from public.rename_business(%L, ' A ')$q$, org), 'at least 2 characters');
  perform tests.assert_raises('81 characters is refused', format($q$select * from public.rename_business(%L, %L)$q$, org, repeat('x', 81)), 'at most 80 characters');
  perform tests.assert_eq('80 characters is the limit and is accepted by the length rule (checked below with a rename)', length(repeat('x', 80)), 80);
  perform tests.assert_raises('a tab inside the name is refused', format($q$select * from public.rename_business(%L, E'Club\tCo Two')$q$, org), 'characters that are not allowed');
  perform tests.assert_raises('a line break inside the name is refused', format($q$select * from public.rename_business(%L, E'Club\nCo Two')$q$, org), 'characters that are not allowed');
  perform tests.assert_raises('the same name is refused', format($q$select * from public.rename_business(%L, 'Club Co')$q$, org), 'already the name');
  perform tests.assert_raises('...even with spaces around it', format($q$select * from public.rename_business(%L, '   Club Co   ')$q$, org), 'already the name');
  perform tests.assert_raises('another business''s name is refused', format($q$select * from public.rename_business(%L, 'Rival Nights')$q$, org), 'another business already uses that name');
  perform tests.assert_raises('...whatever the capitals', format($q$select * from public.rename_business(%L, 'RIVAL NIGHTS')$q$, org), 'another business already uses that name');
  perform tests.assert_raises('...and the spacing (the rival wrote two spaces)', format($q$select * from public.rename_business(%L, ' rival   nights ')$q$, org), 'another business already uses that name');
  perform tests.assert_eq('none of those changed anything', (select name from public.site_organizations where id = org), 'Club Co');
  perform tests.assert_true('...and the 30-day clock never started', (select name_changed_at is null from public.site_organizations where id = org));
  perform tests.logout();
  perform tests.assert_eq('no record was made for refused attempts', (select count(*) from public.audit_log where action = 'business.renamed')::int, 0);
  perform tests.assert_eq('no event changed', tests.names(org), 'e1 draft old=Club Co, e2 next week=Club Co, e3 on now=Club Co, e4 last month=Club Co');

  ---------------------------------------------------------------- renaming
  perform tests.login(owner_u, 'owner@rn.example');
  select * into r from public.rename_business(org, '   Club   Co   Toronto ');
  perform tests.logout();
  perform tests.assert_eq('the name is tidied', r.new_name, 'Club Co Toronto');
  perform tests.assert_eq('the business has the new name', (select name from public.site_organizations where id = org), 'Club Co Toronto');
  perform tests.assert_eq('two events were updated: the draft and the one that has not started', r.events_updated, 2);
  perform tests.assert_eq('only those two carry the new name: the one on now and the finished one keep the old',
    tests.names(org), 'e1 draft old=Club Co Toronto, e2 next week=Club Co Toronto, e3 on now=Club Co, e4 last month=Club Co');
  perform tests.assert_eq('the rival''s event is untouched', tests.names(rival), 'r1 rival next week=Rival Nights');
  perform tests.assert_eq('the rival''s name is untouched', (select name from public.site_organizations where id = rival), 'Rival  Nights');
  perform tests.assert_true('the clock started now', (select name_changed_at between now() - interval '1 minute' and now() + interval '1 minute' from public.site_organizations where id = org));
  perform tests.assert_true('the answer says when it can be changed again: 30 days on', r.can_change_again_at between now() + interval '29 days 23 hours' and now() + interval '30 days 1 hour');
  select count(*)::int into n_audit from public.audit_log where action = 'business.renamed' and entity_id = org::text and details ->> 'old_name' = 'Club Co' and details ->> 'new_name' = 'Club Co Toronto'
    and (details ->> 'events_updated')::int = 2 and actor_id = owner_u;
  perform tests.assert_eq('it was recorded, with who, the old and new name and the events changed', n_audit, 1);
  perform tests.login(owner_u, 'owner@rn.example');
  perform tests.assert_eq('the owner''s business list shows the new name', (select org_name from public.my_businesses() where org_id = org), 'Club Co Toronto');
  perform tests.assert_eq('...and so do their workspaces', (select org_name from public.my_workspaces() where org_id = org limit 1), 'Club Co Toronto');
  perform tests.login(mgr_u, 'mgr@rn.example');
  perform tests.assert_eq('the manager''s workspace shows it too (it is one name, in one place)', (select org_name from public.my_workspaces() where org_id = org limit 1), 'Club Co Toronto');
  perform tests.logout();

  ---------------------------------------------------------------- once every 30 days
  changed := (select name_changed_at from public.site_organizations where id = org);
  perform tests.login(owner_u, 'owner@rn.example');
  rn := tests.run_as(owner_u, 'owner@rn.example', format($q$select new_name from public.rename_business(%L, 'Club Co Downtown')$q$, org));
  perform tests.assert_true('a second change straight away is refused, and says why and when', rn like 'ERROR: the name was changed on % It can be changed again from %');
  perform tests.assert_true('...the message names the day it can be changed again (30 days on)', rn like '%' || to_char((changed + interval '30 days') at time zone 'UTC', 'FMDD FMMonth YYYY') || '%');
  perform tests.assert_eq('it did not change', (select name from public.site_organizations where id = org), 'Club Co Toronto');
  perform tests.assert_eq('...nor did the events', tests.names(org), 'e1 draft old=Club Co Toronto, e2 next week=Club Co Toronto, e3 on now=Club Co, e4 last month=Club Co');

  -- fixing capitals or spacing is a typo fix: allowed at once, and it does not restart the 30 days (the clock is moved back 10 days first, because now() does not move inside one test)
  perform tests.x(format($q$update public.site_organizations set name_changed_at = now() - interval '10 days' where id = %L$q$, org));
  changed := (select name_changed_at from public.site_organizations where id = org);
  select * into r from public.rename_business(org, 'club co TORONTO');
  perform tests.logout();
  perform tests.assert_eq('a change of capitals only is allowed inside the 30 days', (select name from public.site_organizations where id = org), 'club co TORONTO');
  perform tests.assert_true('...and does not move the clock', (select name_changed_at = changed from public.site_organizations where id = org));
  perform tests.assert_eq('...and the upcoming events follow it', tests.names(org), 'e1 draft old=club co TORONTO, e2 next week=club co TORONTO, e3 on now=Club Co, e4 last month=Club Co');
  perform tests.assert_true('...and the answer still gives the day the real change can next be made', r.can_change_again_at = changed + interval '30 days');
  perform tests.assert_eq('...and it was recorded as a tidy-only change', (select count(*)::int from public.audit_log where action = 'business.renamed' and (details ->> 'tidy_only')::boolean), 1);

  -- after 30 days it can change again
  perform tests.x(format($q$update public.site_organizations set name_changed_at = now() - interval '29 days 23 hours' where id = %L$q$, org));
  perform tests.login(owner_u, 'owner@rn.example');
  perform tests.assert_raises('29 days and 23 hours on is still too soon', format($q$select * from public.rename_business(%L, 'Club Co Downtown')$q$, org), 'can be changed again from');
  perform tests.logout();
  perform tests.x(format($q$update public.site_organizations set name_changed_at = now() - interval '30 days 1 minute' where id = %L$q$, org));
  perform tests.login(owner_u, 'owner@rn.example');
  select * into r from public.rename_business(org, repeat('y', 80));
  perform tests.logout();
  perform tests.assert_eq('after 30 days it can be changed again (and an 80 character name fits)', (select length(name) from public.site_organizations where id = org), 80);
  perform tests.assert_eq('...two events followed it', r.events_updated, 2);

  ---------------------------------------------------------------- an event business
  perform tests.login(org_u, 'organizer@rn.example');
  select * into r from public.rename_business(eorg, 'Events Crew Canada');
  perform tests.logout();
  perform tests.assert_eq('an event organizer renames its own business too', r.new_name, 'Events Crew Canada');
  perform tests.x(format($q$update public.site_organizations set name_changed_at = null where id = %L$q$, eorg));
  perform tests.login(org_u, 'organizer@rn.example');
  select * into r from public.rename_business(eorg, 'Ab');
  perform tests.logout();
  perform tests.assert_eq('a two-character name is long enough', (select name from public.site_organizations where id = eorg), 'Ab');

  ---------------------------------------------------------------- a name that was free again
  perform tests.login(rival_u, 'rival@rn.example');
  select * into r from public.rename_business(rival, 'Club Co Toronto');
  perform tests.logout();
  perform tests.assert_eq('a name the first business gave up can be taken by another', (select name from public.site_organizations where id = rival), 'Club Co Toronto');

  ---------------------------------------------------------------- no way round it
  perform tests.login(owner_u, 'owner@rn.example');
  perform tests.assert_raises('the apps cannot write a business''s name directly', format($q$update public.site_organizations set name = 'Sneaky' where id = %L$q$, org), 'permission denied');
  perform tests.logout();
end $$;

rollback;
