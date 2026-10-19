-- Outbox sender, database side (20261019100000_outbox_claim.sql).
-- What matters: a queued message is handed to exactly one sender at a time and is never handed out again while held; a message that keeps failing
-- stops being tried after the 5th attempt; a final state (sent, failed) can never be undone by a late or repeated report; and only the service
-- role can do any of it.
begin;

do $$
declare
  staff constant uuid := '00000000-0000-0000-0000-0000000000a1';
  admin_u constant uuid := '00000000-0000-0000-0000-0000000000a2';
  rando constant uuid := '00000000-0000-0000-0000-0000000000a3';
  m1 uuid; m2 uuid; m3 uuid; m_sent uuid; m_failed uuid; m_maxed uuid; m_held uuid; m_lapsed uuid;
  r record; n int; ids uuid[]; got uuid[]; st text; err text;
begin
  perform tests.logout();
  delete from public.site_outbox;

  -- three queued messages, oldest first
  insert into public.site_outbox (kind, payload, created_at) values ('seated_ack', '{"confirmation_code":"A"}', now() - interval '3 minutes') returning id into m1;
  insert into public.site_outbox (kind, payload, created_at) values ('estimate_updated', '{"confirmation_code":"A"}', now() - interval '2 minutes') returning id into m2;
  insert into public.site_outbox (kind, payload, created_at) values ('vip_invite', '{"name":"V"}', now() - interval '1 minute') returning id into m3;
  -- messages that must never be handed out
  insert into public.site_outbox (kind, status, sent_at, attempts) values ('seated_ack', 'sent', now(), 1) returning id into m_sent;
  insert into public.site_outbox (kind, status, attempts, last_error) values ('seated_ack', 'failed', 5, 'no recipient') returning id into m_failed;
  insert into public.site_outbox (kind, attempts) values ('seated_ack', 5) returning id into m_maxed;

  ---------------------------------------------------------------- who may call
  perform tests.login(admin_u, 'admin@test.example');
  perform tests.assert_raises('a signed-in administrator cannot claim messages', $q$select * from public.outbox_claim(10)$q$, 'permission denied');
  perform tests.assert_raises('...nor report a result', format($q$select public.outbox_finish(%L, 'sent', null)$q$, m1), 'permission denied');
  perform tests.login(staff, 'staff@test.example');
  perform tests.assert_raises('door staff cannot claim messages', $q$select * from public.outbox_claim(10)$q$, 'permission denied');
  perform tests.login(rando, 'rando@test.example');
  perform tests.assert_raises('a signed-in person cannot claim messages', $q$select * from public.outbox_claim(10)$q$, 'permission denied');
  perform tests.login_anon();
  perform tests.assert_raises('a visitor cannot claim messages', $q$select * from public.outbox_claim(10)$q$, 'permission denied');
  perform tests.assert_raises('...nor report a result', format($q$select public.outbox_finish(%L, 'sent', null)$q$, m1), 'permission denied');
  perform tests.logout();
  perform tests.assert_eq('nothing was claimed by any of those', (select count(*) from public.site_outbox where claimed_at is not null)::int, 0);

  ---------------------------------------------------------------- claiming
  perform tests.login_service();
  select array_agg(c.id order by c.created_at) into got from public.outbox_claim(2) c;
  perform tests.assert_eq('a claim of 2 hands out the 2 OLDEST queued messages, oldest first', got, array[m1, m2]);
  select array_agg(c.id) into got from public.outbox_claim(10) c;
  perform tests.assert_eq('a second claim gets only the one still free (the others are held)', got, array[m3]);
  select count(*) into n from public.outbox_claim(10);
  perform tests.assert_eq('a third claim gets nothing: sent, failed and exhausted messages are never handed out', n, 0);
  perform tests.logout();

  perform tests.assert_eq('a claim counts the attempt', (select attempts from public.site_outbox where id = m1), 1);
  perform tests.assert_true('...and stamps the hold', (select claimed_at is not null from public.site_outbox where id = m1));
  perform tests.assert_eq('...and leaves the message queued (only the sender decides what happens next)', (select status from public.site_outbox where id = m1), 'queued');
  perform tests.assert_eq('a sent message was left alone', (select attempts from public.site_outbox where id = m_sent), 1);
  perform tests.assert_eq('a failed message was left alone', (select attempts from public.site_outbox where id = m_failed), 5);
  perform tests.assert_eq('a message on its 5th attempt is not tried a 6th time', (select attempts from public.site_outbox where id = m_maxed), 5);

  -- the claim returns what the sender needs
  update public.site_outbox set claimed_at = null, attempts = 0 where id = m1;
  perform tests.login_service();
  select * into r from public.outbox_claim(1);
  perform tests.assert_eq('the claim returns the kind', r.kind, 'seated_ack');
  perform tests.assert_eq('...the payload', r.payload ->> 'confirmation_code', 'A');
  perform tests.assert_eq('...the attempt number it just started', r.attempts, 1);
  perform tests.assert_true('...and when the message was queued (so the sender can refuse a stale one)', r.created_at is not null);
  perform tests.logout();

  ---------------------------------------------------------------- holds expire
  update public.site_outbox set claimed_at = clock_timestamp() - interval '9 minutes' where id = m1;
  perform tests.login_service();
  select count(*) into n from public.outbox_claim(10);
  perform tests.assert_eq('a hold of 9 minutes is still a hold', n, 0);
  perform tests.logout();
  update public.site_outbox set claimed_at = clock_timestamp() - interval '11 minutes' where id = m1;
  perform tests.login_service();
  select array_agg(c.id) into got from public.outbox_claim(10) c;
  perform tests.assert_eq('after 10 minutes a dead sender''s message is handed out again', got, array[m1]);
  perform tests.logout();
  perform tests.assert_eq('...as attempt 2', (select attempts from public.site_outbox where id = m1), 2);

  ---------------------------------------------------------------- the batch size is clamped
  delete from public.site_outbox;
  insert into public.site_outbox (kind) select 'seated_ack' from generate_series(1, 60);
  perform tests.login_service();
  select count(*) into n from public.outbox_claim(1000);
  perform tests.assert_eq('a claim asks for at most 50 however much is requested', n, 50);
  select count(*) into n from public.outbox_claim(0);
  perform tests.assert_eq('a claim of 0 still hands out one (never none by accident)', n, 1);
  select count(*) into n from public.outbox_claim(-5);
  perform tests.assert_eq('...and so does a negative one', n, 1);
  perform tests.logout();
  delete from public.site_outbox;
  insert into public.site_outbox (kind) select 'seated_ack' from generate_series(1, 25);
  perform tests.login_service();
  select count(*) into n from public.outbox_claim(null);
  perform tests.assert_eq('no limit means the default of 20', n, 20);
  select count(*) into n from public.outbox_claim();
  perform tests.assert_eq('...and so does leaving it out (5 are left)', n, 5);
  perform tests.logout();
  delete from public.site_outbox;

  ---------------------------------------------------------------- reporting results
  insert into public.site_outbox (kind, attempts, claimed_at) values ('seated_ack', 1, now()) returning id into m1;
  perform tests.login_service();
  perform tests.assert_raises('an unknown result is refused', format($q$select public.outbox_finish(%L, 'done', null)$q$, m1), 'result must be sent, retry or failed');
  perform tests.assert_raises('...and so is none', format($q$select public.outbox_finish(%L, null, null)$q$, m1), 'result must be sent, retry or failed');
  perform tests.assert_eq('an unknown message changes nothing and answers null', public.outbox_finish(gen_random_uuid(), 'sent', null), null);

  st := public.outbox_finish(m1, 'retry', 'provider said 503');
  perform tests.assert_eq('a first failure leaves the message queued for another go', st, 'queued');
  perform tests.logout();
  perform tests.assert_eq('...remembering why', (select last_error from public.site_outbox where id = m1), 'provider said 503');
  perform tests.assert_true('...and not marked sent', (select sent_at is null from public.site_outbox where id = m1));

  update public.site_outbox set attempts = 5 where id = m1;
  perform tests.login_service();
  st := public.outbox_finish(m1, 'retry', 'provider said 503 again');
  perform tests.assert_eq('a failure on the 5th attempt fails the message for good', st, 'failed');
  perform tests.assert_eq('...and a late report on it changes nothing', public.outbox_finish(m1, 'sent', null), null);
  perform tests.logout();
  perform tests.assert_eq('...it stays failed', (select status from public.site_outbox where id = m1), 'failed');
  perform tests.assert_eq('...with its last error', (select last_error from public.site_outbox where id = m1), 'provider said 503 again');

  insert into public.site_outbox (kind, attempts, claimed_at) values ('seated_ack', 1, now()) returning id into m2;
  perform tests.login_service();
  st := public.outbox_finish(m2, 'failed', 'the guest has no e-mail address');
  perform tests.assert_eq('a message that can never be sent fails at once, whatever the attempt', st, 'failed');
  perform tests.logout();
  perform tests.assert_eq('...with the reason', (select last_error from public.site_outbox where id = m2), 'the guest has no e-mail address');

  insert into public.site_outbox (kind, attempts, claimed_at, last_error) values ('seated_ack', 2, now(), 'earlier problem') returning id into m3;
  perform tests.login_service();
  st := public.outbox_finish(m3, 'sent', null);
  perform tests.assert_eq('a sent message ends as sent', st, 'sent');
  perform tests.assert_eq('...and a repeated report on it changes nothing', public.outbox_finish(m3, 'failed', 'x'), null);
  perform tests.logout();
  perform tests.assert_eq('...it stays sent', (select status from public.site_outbox where id = m3), 'sent');
  perform tests.assert_true('...with the time it was sent', (select sent_at is not null from public.site_outbox where id = m3));
  perform tests.assert_true('...and the earlier problem cleared', (select last_error is null from public.site_outbox where id = m3));

  insert into public.site_outbox (kind, attempts, claimed_at) values ('seated_ack', 1, now()) returning id into m_held;
  perform tests.login_service();
  perform public.outbox_finish(m_held, 'retry', repeat('x', 900));
  perform tests.logout();
  perform tests.assert_eq('an error text is cut to the 500 characters the column allows', (select char_length(last_error) from public.site_outbox where id = m_held), 500);
  perform tests.login_service();
  perform public.outbox_finish(m_held, 'retry', '   ');
  perform tests.logout();
  perform tests.assert_true('...and a blank one is stored as nothing', (select last_error is null from public.site_outbox where id = m_held));

  ---------------------------------------------------------------- the table stays closed
  perform tests.login(staff, 'staff@test.example');
  perform tests.assert_raises('door staff still cannot read the outbox directly', $q$select * from public.site_outbox$q$, 'permission denied');
  perform tests.login_service();
  perform tests.assert_true('the service role can (it is what the sender uses to find the recipient)', (select count(*) from public.site_outbox) >= 0);
  perform tests.logout();

  perform tests.assert_true('both functions run with their owner''s rights and a fixed search path',
    (select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%')
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname in ('outbox_claim', 'outbox_finish')));
end $$;

rollback;
