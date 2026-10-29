-- A date of birth on the customer profile, and the age kept in step with it.
--
-- The customer app now asks every signed-in person for an e-mail, a phone number and a date of birth before the home screen. Until now profiles held only
-- `age`, a number typed by the person, which goes stale the day after it is typed and cannot be checked. This adds `date_of_birth` and a trigger that
-- sets `age` from it on every insert and update, so the two can never disagree. The existing rule in production, profiles_age_check (age >= 18), then
-- keeps anyone under 18 out, whatever app wrote the row. Rows without a date of birth are not touched (age stays whatever was written, or empty).
--
-- profiles is shared with the website and the older vendor app and is NOT defined by any migration here (its production shape is in tests/db/prod_shapes).
-- Pre-flight: it must exist with `age`, and `date_of_birth` must not be there already.
do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'public.profiles does not exist; this migration extends the shared profiles table';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'age') then
    raise exception 'public.profiles.age is missing; review the table before applying this migration';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'date_of_birth') then
    raise exception 'public.profiles.date_of_birth already exists; review it before applying this migration';
  end if;
end $$;

alter table public.profiles add column date_of_birth date;

-- A date typed wrongly (year 0001, 0200) is caught here; a date in the future makes a negative age, which profiles_age_check refuses.
alter table public.profiles add constraint profiles_date_of_birth_range check (date_of_birth is null or date_of_birth >= date '1900-01-01');

-- Whole years as of today (UTC, the database's clock), the way the app counts them: the age goes up on the birthday itself.
create function public.profiles_set_age_from_date_of_birth()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.age := extract(year from age(current_date::timestamp, new.date_of_birth::timestamp))::int;
  return new;
end;
$$;

-- Only the trigger runs it; it is not something to call from the app. (Firing a trigger does not need the right to execute its function.)
revoke all on function public.profiles_set_age_from_date_of_birth() from public, anon, authenticated;

create trigger profiles_set_age_from_date_of_birth
  before insert or update on public.profiles
  for each row
  when (new.date_of_birth is not null)
  execute function public.profiles_set_age_from_date_of_birth();
