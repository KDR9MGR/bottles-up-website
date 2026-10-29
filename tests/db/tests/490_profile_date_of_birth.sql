-- profiles.date_of_birth (20261102100000): the date of birth is stored, the age is always worked out from it by the database, and anyone under 18 is refused by the
-- rule production already has (profiles_age_check). What matters: an adult's age is set from the date and whatever age was typed is overwritten; the 18th birthday counts on the day itself
-- and the day before does not; a date in the future or before 1900 is refused; a row WITHOUT a date of birth behaves exactly as before; the person can still write their own row (the trigger
-- function is not callable from the app, and that must not stop it firing).
-- (profiles_age_check comes from tests/db/prod_shapes: the prerequisite table does not have it.)
begin;

do $$
declare
  u1 constant uuid := '4d0b0000-0000-4000-8000-000000000001';
  u2 constant uuid := '4d0b0000-0000-4000-8000-000000000002';
  u3 constant uuid := '4d0b0000-0000-4000-8000-000000000003';
  u4 constant uuid := '4d0b0000-0000-4000-8000-000000000004';
  u5 constant uuid := '4d0b0000-0000-4000-8000-000000000005';
  u6 constant uuid := '4d0b0000-0000-4000-8000-000000000006';
  today constant date := current_date;
begin
  insert into auth.users (id, email) select id, 'dob' || n || '@dob.example' from (values (u1, 1), (u2, 2), (u3, 3), (u4, 4), (u5, 5), (u6, 6)) v (id, n);

  ---------------------------------------------------------------- what is in place
  perform tests.assert_eq('the column is a nullable date', (select data_type || ' ' || is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'date_of_birth'), 'date YES');
  perform tests.assert_eq('the age rule of production is in force (this test means nothing without it)', (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.profiles'::regclass and conname = 'profiles_age_check'), 'CHECK ((age >= 18))');
  perform tests.assert_eq('the trigger is one, enabled, before insert or update, only when a date is given',
    (select count(*)::int from pg_trigger t where t.tgrelid = 'public.profiles'::regclass and t.tgname = 'profiles_set_age_from_date_of_birth' and t.tgenabled = 'O' and t.tgtype & 2 = 2 and t.tgtype & 4 = 4 and t.tgtype & 16 = 16 and t.tgqual is not null), 1);
  perform tests.assert_eq('the function runs as the caller with a fixed search_path',
    (select p.prosecdef::text || ' ' || coalesce(p.proconfig::text, 'none') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'profiles_set_age_from_date_of_birth'), 'false {search_path=public}');
  perform tests.assert_true('nobody can call it from the app',
    not has_function_privilege('anon', 'public.profiles_set_age_from_date_of_birth()', 'execute') and not has_function_privilege('authenticated', 'public.profiles_set_age_from_date_of_birth()', 'execute'));

  ---------------------------------------------------------------- the age comes from the date, whatever was typed
  insert into public.profiles (id, name, email, date_of_birth) values (u1, 'One', 'dob1@dob.example', date '1990-06-15');
  perform tests.assert_eq('an adult: the age is worked out', (select age from public.profiles where id = u1), extract(year from age(today::timestamp, timestamp '1990-06-15'))::int);
  insert into public.profiles (id, name, email, date_of_birth, age) values (u2, 'Two', 'dob2@dob.example', date '1985-01-01', 99);
  perform tests.assert_eq('an age typed with it is overwritten, never trusted', (select age from public.profiles where id = u2), extract(year from age(today::timestamp, timestamp '1985-01-01'))::int);
  update public.profiles set age = 30 where id = u2;
  perform tests.assert_eq('...also when only the age is changed later', (select age from public.profiles where id = u2), extract(year from age(today::timestamp, timestamp '1985-01-01'))::int);
  update public.profiles set date_of_birth = date '1970-03-03' where id = u2;
  perform tests.assert_eq('a changed date changes the age', (select age from public.profiles where id = u2), extract(year from age(today::timestamp, timestamp '1970-03-03'))::int);
  update public.profiles set phone_number = '+14165550100' where id = u2;
  perform tests.assert_eq('an unrelated change keeps it', (select age from public.profiles where id = u2), extract(year from age(today::timestamp, timestamp '1970-03-03'))::int);
  insert into public.profiles (id, name, email, date_of_birth) values (u3, 'Leap', 'dob3@dob.example', date '2000-02-29');
  perform tests.assert_eq('...and counted in whole years', (select age from public.profiles where id = u3), extract(year from age(today::timestamp, timestamp '2000-02-29'))::int);

  ---------------------------------------------------------------- the 18th birthday counts on the day itself, not the day before
  insert into public.profiles (id, name, email, date_of_birth) values (u4, 'Eighteen today', 'dob4@dob.example', (today - interval '18 years')::date);
  perform tests.assert_eq('exactly 18 today: accepted, age 18', (select age from public.profiles where id = u4), 18);
  perform tests.assert_raises('one day short of 18: refused', format($q$insert into public.profiles (id, name, email, date_of_birth) values (%L, 'Seventeen', 'dob5@dob.example', %L)$q$, u5, ((today - interval '18 years')::date + 1)), 'profiles_age_check');
  perform tests.assert_raises('a child: refused', format($q$insert into public.profiles (id, name, email, date_of_birth) values (%L, 'Child', 'dob5@dob.example', %L)$q$, u5, (today - interval '10 years')::date), 'profiles_age_check');
  perform tests.assert_raises('an adult cannot be made a minor by changing the date', format($q$update public.profiles set date_of_birth = %L where id = %L$q$, (today - interval '5 years')::date, u1), 'profiles_age_check');
  perform tests.assert_eq('...and the row is unchanged by the refusal', (select date_of_birth from public.profiles where id = u1), date '1990-06-15');
  perform tests.assert_raises('a date in the future: refused', format($q$insert into public.profiles (id, name, email, date_of_birth) values (%L, 'Future', 'dob5@dob.example', %L)$q$, u5, today + 400), 'profiles_age_check');
  perform tests.assert_raises('a date before 1900: refused', format($q$insert into public.profiles (id, name, email, date_of_birth) values (%L, 'Old', 'dob5@dob.example', date '1899-12-31')$q$, u5), 'profiles_date_of_birth_range');
  update public.profiles set date_of_birth = date '1900-01-01' where id = u3;
  perform tests.assert_eq('the first day of 1900 is allowed', (select date_of_birth from public.profiles where id = u3), date '1900-01-01');

  ---------------------------------------------------------------- a row WITHOUT a date of birth is exactly as before
  insert into public.profiles (id, name, email, age) values (u5, 'Old style', 'dob5@dob.example', 41);
  perform tests.assert_eq('no date: the typed age stays', (select age from public.profiles where id = u5), 41);
  perform tests.assert_eq('...and no date is invented', (select date_of_birth from public.profiles where id = u5), null::date);
  update public.profiles set age = 52 where id = u5;
  perform tests.assert_eq('no date: the age can still be edited', (select age from public.profiles where id = u5), 52);
  perform tests.assert_raises('no date: the old rule still refuses an age under 18', format($q$update public.profiles set age = 17 where id = %L$q$, u5), 'profiles_age_check');
  insert into public.profiles (id, name, email) values (u6, 'No age at all', 'dob6@dob.example');
  perform tests.assert_eq('no date and no age: both stay empty', (select age is null and date_of_birth is null from public.profiles where id = u6), true);
  update public.profiles set date_of_birth = null where id = u1;
  perform tests.assert_eq('clearing the date leaves the last age as it was (nothing to work out from)', (select age from public.profiles where id = u1), extract(year from age(today::timestamp, timestamp '1990-06-15'))::int);

  ---------------------------------------------------------------- the person writes their own row, through the app's role, and only theirs
  perform tests.login(u6, 'dob6@dob.example');
  update public.profiles set date_of_birth = date '1995-09-09', phone_number = '+14165550111' where id = u6;
  perform tests.assert_eq('a signed-in person sets their own date and the age follows (the function is not callable by them, and still runs)',
    (select age from public.profiles where id = u6), extract(year from age(today::timestamp, timestamp '1995-09-09'))::int);
  perform tests.logout();
end $$;

rollback;
