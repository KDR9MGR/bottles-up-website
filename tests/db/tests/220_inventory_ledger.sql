-- Inventory ledger. What matters most: only the manager and owner of THAT club read or change stock; stock never goes below 0; receiving needs
-- a counted bottle; wastage and adjustments say why; a count sets the level to what was counted; a retry or double tap (same key) is ONE
-- movement, never two receipts; two people receiving at once both land; the ledger says the level before and after, so what orders took
-- in between shows as a gap; movements are kept (the club cannot be deleted, a removed bottle leaves its history under its old name);
-- low-stock levels flag a bottle; and every movement is attributed.
begin;

create function tests.join_as(p_inviter uuid, p_inviter_email text, p_org uuid, p_email text, p_role text, p_venue uuid, p_user uuid) returns void language plpgsql as $$
declare tok text;
begin
  perform tests.login(p_inviter, p_inviter_email);
  select i.token into tok from public.invite_member(p_org, p_email, p_role, p_venue) i;
  perform tests.login(p_user, p_email);
  perform public.accept_invitation(tok);
end $$;
create function tests.run_as(p_user uuid, p_email text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform tests.login(p_user, p_email);
  execute p_sql into v;
  return coalesce(v, 'null');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.mkbottle(p_venue uuid, p_name text, p_size text, p_stock int) returns uuid language sql security definer as $$
  insert into public.site_bottles (venue_id, name, size, price_cents, stock_quantity) values (p_venue, p_name, p_size, 9000, p_stock) returning id $$;
create function tests.stock_of(p_bottle uuid) returns text language sql security definer as $$
  select coalesce(stock_quantity::text, 'untracked') from public.site_bottles where id = p_bottle $$;
create function tests.move(p_user uuid, p_email text, p_venue uuid, p_bottle uuid, p_kind text, p_qty int, p_reason text default null, p_key text default null) returns text language plpgsql as $$
declare r jsonb;
begin
  perform tests.login(p_user, p_email);
  r := public.stock_move(p_venue, p_bottle, p_kind, p_qty, p_reason, null, p_key);
  return concat_ws(':', (r ->> 'before'), (r ->> 'after'), (r ->> 'changed'), coalesce(r ->> 'low', '-'));
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.list_as(p_user uuid, p_email text, p_venue uuid) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(name || ':' || coalesce(quantity::text, '-') || ':' || case when is_low then 'LOW' else 'ok' end, ' | ' order by (is_low) desc, lower(name)) from public.stock_list(p_venue)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;
create function tests.ledger(p_user uuid, p_email text, p_venue uuid, p_bottle uuid default null, p_limit int default 50) returns text language plpgsql as $$
begin
  perform tests.login(p_user, p_email);
  return coalesce((select string_agg(kind || ':' || delta || ':' || coalesce(before_qty::text, '-') || '>' || after_qty || ':' || by_name || case when by_me then '(me)' else '' end || case when reason is not null then ':' || reason else '' end, ' | ' order by created_at desc, movement_id desc)
                   from public.stock_movements(p_venue, p_bottle, p_limit)), '(none)');
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

do $$
declare
  owner_u constant uuid := '00000000-0000-0000-0000-0000000006d1';
  mgr_a constant uuid := '00000000-0000-0000-0000-0000000006d2';
  srv_1 constant uuid := '00000000-0000-0000-0000-0000000006d3';
  ver_a constant uuid := '00000000-0000-0000-0000-0000000006d4';
  sec_1 constant uuid := '00000000-0000-0000-0000-0000000006d5';
  mgr_b constant uuid := '00000000-0000-0000-0000-0000000006d6';
  rando constant uuid := '00000000-0000-0000-0000-0000000006d7';
  org uuid; venue_a uuid; venue_b uuid; vodka uuid; gin uuid; rum uuid; b_other uuid; n int; r text;
begin
  insert into auth.users (id, email) values
    (owner_u, 'owner@stock.example'), (mgr_a, 'mgra@stock.example'), (srv_1, 'srv1@stock.example'), (ver_a, 'vera@stock.example'),
    (sec_1, 'sec1@stock.example'), (mgr_b, 'mgrb@stock.example'), (rando, 'rando@stock.example');
  insert into public.profiles (id, name, email) values (owner_u, 'Olly Owner', 'owner@stock.example'), (mgr_a, 'Mia Manager', 'mgra@stock.example');

  perform tests.login(owner_u, 'owner@stock.example');
  org := public.create_organization('Club Co', 'venue_owner');
  venue_a := public.create_org_venue(org, 'Club A');
  venue_b := public.create_org_venue(org, 'Club B');
  perform tests.join_as(owner_u, 'owner@stock.example', org, 'mgra@stock.example', 'manager', venue_a, mgr_a);
  perform tests.join_as(owner_u, 'owner@stock.example', org, 'mgrb@stock.example', 'manager', venue_b, mgr_b);
  perform tests.join_as(mgr_a, 'mgra@stock.example', org, 'srv1@stock.example', 'server', venue_a, srv_1);
  perform tests.join_as(mgr_a, 'mgra@stock.example', org, 'vera@stock.example', 'verifier', venue_a, ver_a);
  perform tests.join_as(mgr_a, 'mgra@stock.example', org, 'sec1@stock.example', 'security', venue_a, sec_1);
  perform tests.logout();

  vodka := tests.mkbottle(venue_a, 'Vodka', '750ml', 10);
  gin := tests.mkbottle(venue_a, 'Gin', '750ml', null);
  rum := tests.mkbottle(venue_a, 'Rum', '1L', 4);
  b_other := tests.mkbottle(venue_b, 'Whisky', '750ml', 20);

  ---------------------------------------------------------------- who sees the stock
  perform tests.assert_eq('the manager sees the bottles of their club with their levels', tests.list_as(mgr_a, 'mgra@stock.example', venue_a), 'Gin:-:ok | Rum:4:ok | Vodka:10:ok');
  perform tests.assert_eq('the owner sees the same', tests.list_as(owner_u, 'owner@stock.example', venue_a), 'Gin:-:ok | Rum:4:ok | Vodka:10:ok');
  perform tests.assert_eq('a server cannot', tests.list_as(srv_1, 'srv1@stock.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('...nor the verifier', tests.list_as(ver_a, 'vera@stock.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('...nor security', tests.list_as(sec_1, 'sec1@stock.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s manager', tests.list_as(mgr_b, 'mgrb@stock.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('...nor a stranger', tests.list_as(rando, 'rando@stock.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager sees only their own bottles', tests.list_as(mgr_b, 'mgrb@stock.example', venue_b), 'Whisky:20:ok');

  ---------------------------------------------------------------- receiving, wastage, adjusting
  perform tests.assert_eq('a delivery adds stock', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'receive', 24), '10:34:true:false');
  perform tests.assert_eq('the level is now 34', tests.stock_of(vodka), '34');
  perform tests.assert_eq('wastage removes stock and says why', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'wastage', 2, 'dropped a case'), '34:32:true:false');
  perform tests.assert_eq('an adjustment can go down', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'adjust', -3, 'miscounted last week'), '32:29:true:false');
  perform tests.assert_eq('...or up', tests.move(owner_u, 'owner@stock.example', venue_a, vodka, 'adjust', 1, 'found one in the cellar'), '29:30:true:false');
  perform tests.assert_eq('a count sets the level to what was counted', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'count', 28), '30:28:true:false');
  perform tests.assert_eq('...even a count of nothing', tests.move(mgr_a, 'mgra@stock.example', venue_a, rum, 'count', 0), '4:0:true:false');
  perform tests.assert_eq('stock can never go below 0', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'wastage', 29, 'a flood'), 'ERROR: only 28 in stock');
  perform tests.assert_eq('...by adjusting either', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'adjust', -29, 'a flood'), 'ERROR: only 28 in stock');
  perform tests.assert_eq('nothing changed by the refusals', tests.stock_of(vodka), '28');
  perform tests.assert_eq('the first count of an untracked bottle starts tracking it', tests.move(mgr_a, 'mgra@stock.example', venue_a, gin, 'count', 6), '6:true:false' ) ;
  perform tests.assert_eq('...and it is now tracked', tests.stock_of(gin), '6');

  ---------------------------------------------------------------- what is refused
  perform tests.assert_eq('a delivery of nothing', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'receive', 0), 'ERROR: enter how many arrived');
  perform tests.assert_eq('...or less than nothing', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'receive', -5), 'ERROR: enter how many arrived');
  perform tests.assert_eq('wastage needs an amount', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'wastage', 0, 'broken'), 'ERROR: enter how many were lost');
  perform tests.assert_eq('...and a reason', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'wastage', 1), 'ERROR: say what happened to them');
  perform tests.assert_eq('...a real one', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'wastage', 1, 'x'), 'ERROR: say what happened to them');
  perform tests.assert_eq('an adjustment of 0', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'adjust', 0, 'nothing'), 'ERROR: enter the plus or minus amount');
  perform tests.assert_eq('...needs a reason', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'adjust', 2), 'ERROR: say why the level is being changed');
  perform tests.assert_eq('a count must be 0 or more', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'count', -1), 'ERROR: enter the amount you counted (0 or more)');
  perform tests.assert_eq('...and a number', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'count', null), 'ERROR: enter the amount you counted (0 or more)');
  perform tests.assert_eq('a movement of something else', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'steal', 1, 'x'), 'ERROR: choose receive, wastage, adjust or count');
  perform tests.assert_eq('an untracked bottle must be counted before it can be received', tests.move(mgr_a, 'mgra@stock.example', venue_a, tests.mkbottle(venue_a, 'Tequila', null, null), 'receive', 5), 'ERROR: this bottle has not been counted yet: count it first');
  perform tests.assert_eq('a bottle of another club is "not allowed"', tests.move(mgr_a, 'mgra@stock.example', venue_a, b_other, 'receive', 5), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot touch this club''s stock', tests.move(mgr_b, 'mgrb@stock.example', venue_a, vodka, 'receive', 5), 'ERROR: not allowed');
  perform tests.assert_eq('a server cannot', tests.move(srv_1, 'srv1@stock.example', venue_a, vodka, 'receive', 5), 'ERROR: not allowed');
  perform tests.assert_eq('...nor the verifier', tests.move(ver_a, 'vera@stock.example', venue_a, vodka, 'receive', 5), 'ERROR: not allowed');
  perform tests.assert_eq('a bottle that does not exist', tests.move(mgr_a, 'mgra@stock.example', venue_a, gen_random_uuid(), 'receive', 5), 'ERROR: not allowed');
  perform tests.assert_eq('too much at once', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'receive', 100001), 'ERROR: that is more than can be recorded');
  perform tests.assert_eq('a long reason', tests.run_as(mgr_a, 'mgra@stock.example', format($q$select (public.stock_move(%L, %L, 'wastage', 1, %L)) ->> 'after'$q$, venue_a, vodka, repeat('x', 201))), 'ERROR: keep the reason to 200 characters or fewer');
  perform tests.assert_eq('a night that is not current', tests.run_as(mgr_a, 'mgra@stock.example', format($q$select (public.stock_move(%L, %L, 'receive', 1, null, null, null, current_date + 30)) ->> 'after'$q$, venue_a, vodka)), 'ERROR: that is not a current night');
  perform tests.assert_eq('nothing was changed by any of that', tests.stock_of(vodka), '28');

  ---------------------------------------------------------------- a double tap is one movement
  perform tests.assert_eq('a delivery with a key lands once', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'receive', 12, null, 'key-1'), '28:40:true:false');
  perform tests.assert_eq('the same key again is the same delivery, nothing added', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'receive', 12, null, 'key-1'), '28:40:false:-');
  perform tests.assert_eq('...the level is 40, not 52', tests.stock_of(vodka), '40');
  perform tests.assert_eq('the same key from someone else is their own delivery', tests.move(owner_u, 'owner@stock.example', venue_a, vodka, 'receive', 1, null, 'key-1'), '40:41:true:false');
  perform tests.assert_eq('a very long key', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'receive', 1, null, repeat('k', 65)), 'ERROR: that key is too long');

  ---------------------------------------------------------------- low stock
  perform tests.login(mgr_a, 'mgra@stock.example');
  perform public.stock_set_threshold(venue_a, vodka, 5);
  perform public.stock_set_threshold(venue_a, rum, 3);
  perform public.stock_set_threshold(venue_a, gin, 6);
  perform tests.assert_eq('a bottle at or below its level is low, and listed first', tests.list_as(mgr_a, 'mgra@stock.example', venue_a), 'Gin:6:LOW | Rum:0:LOW | Tequila:-:ok | Vodka:41:ok');
  perform tests.assert_eq('a movement says when it leaves a bottle low', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'wastage', 37, 'a party'), '41:4:true:true');
  perform tests.assert_eq('...and when it does not', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'receive', 20), '4:24:true:false');
  perform tests.login(mgr_a, 'mgra@stock.example');
  perform public.stock_set_threshold(venue_a, gin, null);
  perform tests.assert_eq('clearing a level clears the flag', tests.list_as(mgr_a, 'mgra@stock.example', venue_a), 'Rum:0:LOW | Gin:6:ok | Tequila:-:ok | Vodka:24:ok');
  perform tests.assert_eq('a negative level is refused', tests.run_as(mgr_a, 'mgra@stock.example', format($q$select public.stock_set_threshold(%L, %L, -1)::text$q$, venue_a, vodka)), 'ERROR: enter a low-stock level from 0 to 100000');
  perform tests.assert_eq('a server cannot set one', tests.run_as(srv_1, 'srv1@stock.example', format($q$select public.stock_set_threshold(%L, %L, 2)::text$q$, venue_a, vodka)), 'ERROR: not allowed');
  perform tests.assert_eq('another club''s manager cannot', tests.run_as(mgr_b, 'mgrb@stock.example', format($q$select public.stock_set_threshold(%L, %L, 2)::text$q$, venue_a, vodka)), 'ERROR: not allowed');
  perform tests.assert_eq('...nor with another club''s bottle', tests.run_as(mgr_a, 'mgra@stock.example', format($q$select public.stock_set_threshold(%L, %L, 2)::text$q$, venue_a, b_other)), 'ERROR: not allowed');

  ---------------------------------------------------------------- the ledger
  perform tests.assert_eq('one bottle''s ledger, newest first, with who and why',
    tests.ledger(mgr_a, 'mgra@stock.example', venue_a, vodka, 4),
    'receive:20:4>24:Mia Manager(me) | wastage:-37:41>4:Mia Manager(me):a party | receive:1:40>41:Olly Owner | receive:12:28>40:Mia Manager(me)');
  perform tests.assert_eq('the owner sees the same movements, as someone else''s', (tests.ledger(owner_u, 'owner@stock.example', venue_a, vodka, 1)), 'receive:20:4>24:Mia Manager');
  perform tests.assert_eq('the whole club''s ledger includes other bottles', (select count(*) from (select 1 from regexp_matches(tests.ledger(mgr_a, 'mgra@stock.example', venue_a, null, 100), 'count:', 'g')) x)::int, 3);
  perform tests.assert_eq('a count is recorded with its difference', tests.ledger(mgr_a, 'mgra@stock.example', venue_a, rum, 10), 'count:-4:4>0:Mia Manager(me)');
  perform tests.assert_eq('the first count of an untracked bottle has no "before"', tests.ledger(mgr_a, 'mgra@stock.example', venue_a, gin, 10), 'count:0:->6:Mia Manager(me)');
  perform tests.assert_eq('a page is capped at 100 and at least 1', (tests.run_as(mgr_a, 'mgra@stock.example', format($q$select count(*)::text from public.stock_movements(%L, null, 1000)$q$, venue_a))::int <= 100)::text, 'true');
  perform tests.assert_eq('a server cannot read the ledger', tests.ledger(srv_1, 'srv1@stock.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('...nor another club''s manager', tests.ledger(mgr_b, 'mgrb@stock.example', venue_a), 'ERROR: not allowed');
  perform tests.assert_eq('...and another club''s ledger is its own', tests.ledger(mgr_b, 'mgrb@stock.example', venue_b), '(none)');

  ---------------------------------------------------------------- what orders take in between shows as a gap
  perform tests.logout();
  update public.site_bottles set stock_quantity = 20 where id = vodka;   -- bottles ordered outside the ledger: 24 became 20
  perform tests.assert_eq('the next movement records the level at that moment', tests.move(mgr_a, 'mgra@stock.example', venue_a, vodka, 'receive', 6), '20:26:true:false');
  perform tests.assert_eq('so the ledger shows 24 then 20 (4 taken by orders in between)', tests.ledger(mgr_a, 'mgra@stock.example', venue_a, vodka, 2), 'receive:6:20>26:Mia Manager(me) | receive:20:4>24:Mia Manager(me)');

  ---------------------------------------------------------------- kept
  perform tests.logout();
  perform tests.assert_raises('a club with stock movements cannot be deleted', format('delete from public.site_venues where id = %L', venue_a), 'violates foreign key constraint');
  delete from public.site_bottles where id = rum;
  perform tests.assert_eq('a removed bottle leaves its history under its old name', tests.ledger(mgr_a, 'mgra@stock.example', venue_a, null, 100) like '%count:-4:4>0:Mia Manager(me)%', true);
  perform tests.logout();
  perform tests.assert_eq('...with no bottle attached any more', (select count(*) from public.site_stock_movements where bottle_name = 'Rum' and bottle_id is null)::int, 1);
  perform tests.assert_eq('...and its low-stock level went with it', (select count(*) from public.site_stock_thresholds where venue_id = venue_a)::int, 1);
  perform tests.assert_eq('every movement is in the audit log with who made it', (select count(*) from public.audit_log where action like 'stock.%' and actor_id in (mgr_a, owner_u))::int >= 14, true);

  ---------------------------------------------------------------- closed to the outside
  perform tests.login_anon();
  perform tests.assert_raises('an anonymous visitor cannot list stock', format('select * from public.stock_list(%L)', venue_a), 'permission denied');
  perform tests.assert_raises('...or move any', format($q$select public.stock_move(%L, %L, 'receive', 5)$q$, venue_a, vodka), 'permission denied');
  perform tests.logout();
  perform tests.login(mgr_a, 'mgra@stock.example');
  perform tests.assert_raises('the movements table cannot be read directly', 'select * from public.site_stock_movements', 'permission denied');
  perform tests.assert_raises('...nor written', format($q$insert into public.site_stock_movements (venue_id, bottle_name, kind, delta, after_qty, created_by) values (%L, 'x', 'receive', 1, 1, %L)$q$, venue_a, mgr_a), 'permission denied');
  perform tests.assert_raises('...nor the levels', 'select * from public.site_stock_thresholds', 'permission denied');
  perform tests.logout();
end $$;

rollback;
