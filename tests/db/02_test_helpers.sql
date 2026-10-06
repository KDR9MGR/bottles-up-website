-- Tiny assertion helpers. Each prints "ok - <name>" or raises "FAIL - ...",
-- which stops the run (psql is started with ON_ERROR_STOP).

create schema if not exists tests;
grant usage on schema tests to public;

create or replace function tests.assert_eq(name text, actual anyelement, expected anyelement)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL - %: expected [%], got [%]', name, expected, actual;
  end if;
  raise notice 'ok - %', name;
end $$;

create or replace function tests.assert_true(name text, cond boolean)
returns void language plpgsql as $$
begin
  if cond is not true then
    raise exception 'FAIL - %: condition was not true', name;
  end if;
  raise notice 'ok - %', name;
end $$;

-- Runs `stmt` as whoever is currently logged in and expects an error whose
-- message contains `expected`.
create or replace function tests.assert_raises(name text, stmt text, expected text)
returns void language plpgsql as $$
declare
  msg text;
begin
  begin
    execute stmt;
  exception when others then
    get stacked diagnostics msg = message_text;
    if position(expected in msg) = 0 then
      raise exception 'FAIL - %: expected an error containing [%], got [%]', name, expected, msg;
    end if;
    raise notice 'ok - %', name;
    return;
  end;
  raise exception 'FAIL - %: expected an error containing [%] but nothing was raised', name, expected;
end $$;

-- A check we KNOW currently fails because of a bug in the code under test.
--  * normal run:  passes while the bug is present, and FAILS the moment the bug
--                 is fixed, so the marker gets removed instead of rotting.
--  * run with the proposed fix applied (tests/db/run.sh --with-fix): behaves as a
--    normal assert_eq, which proves the fix actually works.
create or replace function tests.assert_known_bug(name text, actual anyelement, expected anyelement)
returns void language plpgsql as $$
begin
  if current_setting('tests.fix_applied', true) = 'on' then
    perform tests.assert_eq(name || ' [with the proposed fix]', actual, expected);
  elsif actual is not distinct from expected then
    raise exception 'FIXED - %: this known bug no longer reproduces. Change assert_known_bug to assert_eq in the test.', name;
  else
    raise notice 'ok - KNOWN BUG still present: % (should be [%], is [%])', name, expected, actual;
  end if;
end $$;

-- Become a signed-in user for the rest of the transaction. This is what
-- PostgREST does for a real request: set the JWT claims, switch role.
create or replace function tests.login(uid uuid, user_email text default null)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated', 'email', user_email)::text, true);
  set local role authenticated;
end $$;

create or replace function tests.login_anon()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  set local role anon;
end $$;

create or replace function tests.login_service()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  set local role service_role;
end $$;

create or replace function tests.logout()
returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', '', true);
end $$;

grant execute on all functions in schema tests to public;
