-- The guard on the classic vendors table. What matters most: a signed-in person cannot give themselves the administrator role, neither by
-- changing their own row nor by inserting one; nobody new lands on the administrator list; and everything legitimate keeps working (people
-- editing their own vendor details, an existing administrator promoting and demoting, the database owner and the service role).
-- (The production-only vendors tables come from tests/db/prod_shapes.)
begin;

do $$
declare
  u1 constant uuid := '5d5a1c10-0000-4000-8000-000000000001';  -- an ordinary signed-in person
  u2 constant uuid := '5d5a1c10-0000-4000-8000-000000000002';
  adm constant uuid := '5d5a1c10-0000-4000-8000-000000000003'; -- an existing administrator
  u4 constant uuid := '5d5a1c10-0000-4000-8000-000000000004';  -- a person who has no vendors row yet
  base int;
begin
  insert into auth.users (id, email) values
    (u1, 'u1@vendors.example'), (u2, 'u2@vendors.example'), (adm, 'adm@vendors.example'), (u4, 'u4@vendors.example');
  perform tests.assert_eq('every new account got its automatic vendors row, with an ordinary role',
    (select count(*) from public.vendors where id in (u1, u2, adm, u4) and role = 'staff')::int, 4);

  ---------------------------------------------------------------- the database owner can still make an administrator
  update public.vendors set role = 'admin' where id = adm;
  perform tests.assert_eq('the database owner can make an administrator', (select count(*) from public.vendor_admins where id = adm)::int, 1);
  base := (select count(*) from public.vendor_admins);

  ---------------------------------------------------------------- ordinary use keeps working
  perform tests.login(u1, 'u1@vendors.example');
  update public.vendors set business_name = 'My Club', onboarding_completed = true where id = u1;
  perform tests.assert_eq('a person can still edit their own vendor details', (select business_name from public.vendors where id = u1), 'My Club');
  perform tests.assert_eq('...and finish the classic onboarding', (select onboarding_completed from public.vendors where id = u1), true);
  update public.vendors set role = 'organizer' where id = u1;
  perform tests.assert_eq('...and ordinary role values are not touched by the guard', (select role from public.vendors where id = u1), 'organizer');
  insert into public.vendors (id, email, role) values (u1, 'u1@vendors.example', 'staff')
    on conflict (id) do update set role = excluded.role, email = excluded.email;
  perform tests.assert_eq('...and the app''s upsert with an ordinary role still works', (select role from public.vendors where id = u1), 'staff');

  ---------------------------------------------------------------- the guard
  perform tests.assert_raises('a signed-in person cannot give themselves the administrator role',
    format($q$update public.vendors set role = 'admin' where id = %L$q$, u1), 'only be given by an administrator');
  perform tests.assert_raises('...not even together with an ordinary edit',
    format($q$update public.vendors set role = 'admin', business_name = 'x' where id = %L$q$, u1), 'only be given by an administrator');
  perform tests.assert_raises('...nor through an upsert',
    format($q$insert into public.vendors (id, email, role) values (%L, 'u1@vendors.example', 'admin') on conflict (id) do update set role = excluded.role$q$, u1),
    'only be given by an administrator');
  update public.vendors set role = 'admin' where id = u2;  -- somebody else's row: the row rules hide it, so nothing happens
  perform tests.assert_true('they are still not an administrator', not public.is_admin());
  perform tests.logout();
  perform tests.assert_eq('the administrator list did not grow', (select count(*) from public.vendor_admins)::int, base);
  perform tests.assert_eq('...and their role did not change', (select role from public.vendors where id = u1), 'staff');
  perform tests.assert_eq('...and nobody else''s row changed either', (select role from public.vendors where id = u2), 'staff');

  -- a person with no row yet inserts their own, already marked administrator
  delete from public.vendors where id = u4;
  perform tests.login(u4, 'u4@vendors.example');
  perform tests.assert_raises('a person cannot insert their own vendors row already marked administrator',
    format($q$insert into public.vendors (id, email, role) values (%L, 'u4@vendors.example', 'admin')$q$, u4), 'only be given by an administrator');
  insert into public.vendors (id, email, role) values (u4, 'u4@vendors.example', 'staff');
  perform tests.assert_eq('...but can insert their own ordinary row', (select count(*) from public.vendors where id = u4)::int, 1);
  perform tests.logout();
  perform tests.assert_eq('the administrator list still did not grow', (select count(*) from public.vendor_admins)::int, base);

  ---------------------------------------------------------------- who still can
  -- (the administrator list itself is closed to clients, so it is read as the owner, after logging out)
  perform tests.login(adm, 'adm@vendors.example');
  update public.vendors set role = 'admin' where id = u2;
  perform tests.logout();
  perform tests.assert_eq('an existing administrator can promote someone', (select count(*) from public.vendor_admins where id = u2)::int, 1);
  perform tests.login(adm, 'adm@vendors.example');
  update public.vendors set role = 'staff' where id = u2;
  perform tests.logout();
  perform tests.assert_eq('...and demote them again', (select count(*) from public.vendor_admins where id = u2)::int, 0);

  perform tests.login_service();
  update public.vendors set role = 'admin' where id = u2;
  perform tests.logout();
  perform tests.assert_eq('the service role can make an administrator', (select count(*) from public.vendor_admins where id = u2)::int, 1);

  perform tests.login(u2, 'u2@vendors.example');
  update public.vendors set role = 'staff' where id = u2;
  perform tests.logout();
  perform tests.assert_eq('an administrator can step down themselves', (select count(*) from public.vendor_admins where id = u2)::int, 0);

  ---------------------------------------------------------------- hygiene
  perform tests.assert_eq('the guard function cannot be called by clients',
    (has_function_privilege('anon', 'public.vendors_role_guard()', 'execute') or has_function_privilege('authenticated', 'public.vendors_role_guard()', 'execute')), false);
end $$;

rollback;
