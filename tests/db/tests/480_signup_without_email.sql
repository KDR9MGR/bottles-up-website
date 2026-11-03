-- A new sign-in whose account has no e-mail (Sign in with Apple when Apple does not send it, a new phone-number sign-up) must go ahead. Before 20261031100000 the trigger that
-- gives every new account a row in the older vendors table tried to write the missing e-mail into vendors.email (required in production) and the whole sign-up failed with
-- "Database error saving new user". What matters: an account with no e-mail is created (and can be deleted again) and simply gets no vendors row; an account with an e-mail gets exactly
-- the row it always got; the requirement on vendors.email itself is untouched (this test is meaningless if it is not in force); the function has a fixed search_path.
-- (The production-only vendors tables, and the NOT NULL on vendors.email, come from tests/db/prod_shapes.)
begin;

do $$
declare
  named   constant uuid := '5d5a1c20-0000-4000-8000-000000000001';  -- e-mail and a name
  unnamed constant uuid := '5d5a1c20-0000-4000-8000-000000000002';  -- e-mail, no name
  nomail  constant uuid := '5d5a1c20-0000-4000-8000-000000000003';  -- no e-mail at all (phone / Apple without the e-mail)
  empty   constant uuid := '5d5a1c20-0000-4000-8000-000000000004';  -- an empty-string e-mail: not "no e-mail", behaves as it always did
  nomail2 constant uuid := '5d5a1c20-0000-4000-8000-000000000005';  -- a second one, and one that is deleted again
  v record;
begin
  ---------------------------------------------------------------- the requirement that caused the failure is still in force
  perform tests.assert_eq('vendors.email is required (this is what an account with no e-mail used to hit)',
    (select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'vendors' and column_name = 'email'), 'NO');
  perform tests.assert_raises('a vendors row cannot be written without an e-mail', $q$insert into public.vendors (id, email) values (gen_random_uuid(), null)$q$, 'null value');

  ---------------------------------------------------------------- an account WITH an e-mail gets the row it always got
  insert into auth.users (id, email, raw_user_meta_data) values (named, 'named@signup.example', '{"name": "Ana Club"}');
  select * into v from public.vendors where id = named;
  perform tests.assert_eq('with an e-mail and a name: the vendors row is made', v.id is not null, true);
  perform tests.assert_eq('  its e-mail is the account''s', v.email, 'named@signup.example');
  perform tests.assert_eq('  its business name is the name given', v.business_name, 'Ana Club');
  perform tests.assert_eq('  onboarding is not completed', v.onboarding_completed, false);
  perform tests.assert_eq('  it is an ordinary role, never an administrator', v.role, 'staff');

  insert into auth.users (id, email) values (unnamed, 'unnamed@signup.example');
  perform tests.assert_eq('with an e-mail and no name: the business name is "User", as before', (select business_name from public.vendors where id = unnamed), 'User');

  insert into auth.users (id, email) values (empty, '');
  perform tests.assert_eq('an EMPTY e-mail is not "no e-mail": the row is made as before', (select email from public.vendors where id = empty), '');

  ---------------------------------------------------------------- an account WITHOUT an e-mail: the sign-up goes ahead, with no vendors row
  insert into auth.users (id, email) values (nomail, null);
  perform tests.assert_eq('with no e-mail: the account is created', (select count(*)::int from auth.users where id = nomail), 1);
  perform tests.assert_eq('with no e-mail: no vendors row is made', (select count(*)::int from public.vendors where id = nomail), 0);
  insert into auth.users (id, email, raw_user_meta_data) values (nomail2, null, '{"name": "Phone Person"}');
  perform tests.assert_eq('with no e-mail but a name: the account is created', (select count(*)::int from auth.users where id = nomail2), 1);
  perform tests.assert_eq('with no e-mail but a name: still no vendors row', (select count(*)::int from public.vendors where id = nomail2), 0);
  perform tests.assert_eq('nobody landed on the administrator list because of these sign-ups',
    (select count(*)::int from public.vendor_admins where id in (named, unnamed, empty, nomail, nomail2)), 0);

  ---------------------------------------------------------------- such an account can be deleted again (it has nothing in vendors to remove)
  delete from auth.users where id = nomail2;
  perform tests.assert_eq('an account that never had a vendors row can be deleted', (select count(*)::int from auth.users where id = nomail2), 0);

  ---------------------------------------------------------------- the function and its trigger
  perform tests.assert_eq('the trigger on auth.users is still there, enabled, and is the only one',
    (select string_agg(t.tgname || ':' || t.tgenabled::text, ',') from pg_trigger t where t.tgrelid = 'auth.users'::regclass and not t.tgisinternal), 'on_auth_user_created:O');
  perform tests.assert_eq('handle_new_user() is security definer with a fixed search_path',
    (select p.prosecdef::text || ' ' || coalesce(p.proconfig::text, 'none') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'handle_new_user'), 'true {search_path=public}');
end $$;

rollback;
