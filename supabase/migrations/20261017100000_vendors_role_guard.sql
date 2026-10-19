-- Guard on the classic vendors table (the older vendor dashboard's table).
--
-- The administrator role on a vendors row can only be given by an existing administrator, or by the database owner / the service role
-- (the SQL editor and the edge functions). Nobody else can set it, whether by inserting their own row or by changing their own row.
-- Everything else about the table is untouched: people still create and edit their own vendor details and onboarding flag exactly as before,
-- and administrators can still promote and demote.
--
-- Undo (nothing else depends on it):
--   drop trigger vendors_role_guard on public.vendors;
--   drop function public.vendors_role_guard();
--
-- Needs public.vendors and public.is_admin(), which exist only in production (see tests/db/prod_shapes/20261017100000_vendors_tables.sql).
-- Plain CREATE on purpose: if a guard with this name already exists, this stops instead of overwriting it.

create function public.vendors_role_guard() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if new.role is not distinct from 'admin'
     and (tg_op = 'INSERT' or old.role is distinct from 'admin')
     and not (public.is_admin() or current_user in ('postgres', 'supabase_admin', 'service_role'))
  then
    raise exception 'The admin role can only be given by an administrator' using errcode = '42501';
  end if;
  return new;
end $$;

revoke all on function public.vendors_role_guard() from public, anon, authenticated;

create trigger vendors_role_guard
  before insert or update of role on public.vendors
  for each row execute function public.vendors_role_guard();
