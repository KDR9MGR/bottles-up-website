-- The guest's bottle sign, for the staff who serve the table.
--
-- At checkout a guest can type a short sign for their bottles ("Happy Birthday", 24 characters at most); it is kept on the booking (site_table_bookings.bottle_sign_text, since
-- 20260825) but no staff screen could read it, so the server never knew. (Brief 2 Oct, section 14: the sign "travels with the order".) This adds the one read the booking page needs.
--
-- desk_booking_sign(booking): the club's manager or owner, or the server who has the table, gets the sign (trimmed), or NULL when there is none. A verifier, the door, another
-- server, another club's manager and visitors are refused. A new function: nothing existing is replaced and no row is changed.

do $guard$
begin
  if to_regprocedure('public.desk_booking_level(uuid)') is null then
    raise exception 'public.desk_booking_level(uuid) does not exist: run the earlier server desk migrations first. Nothing was changed.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'site_table_bookings' and column_name = 'bottle_sign_text') then
    raise exception 'site_table_bookings.bottle_sign_text must exist first (20260825). Nothing was changed.';
  end if;
end $guard$;

create function public.desk_booking_sign(p_booking uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_level text;
  v_sign text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_level := public.desk_booking_level(p_booking);
  if v_level is null or v_level = 'verifier' then raise exception 'not allowed'; end if;
  select nullif(btrim(b.bottle_sign_text), '') into v_sign from public.site_table_bookings b where b.id = p_booking;
  return v_sign;
end $$;
revoke all on function public.desk_booking_sign(uuid) from public, anon;
grant execute on function public.desk_booking_sign(uuid) to authenticated;
