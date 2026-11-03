-- Fix: a new sign-in whose account has no e-mail address failed with "Database error saving new user" (Sign in with Apple when Apple does not send the e-mail; a new phone-number sign-up).
--
-- Every new account fires the trigger on_auth_user_created, which runs handle_new_user() and adds a row to the older vendors table with the account's e-mail. In production
-- vendors.email is NOT NULL (read 29 Oct 2026), and an account with no e-mail has nothing to put there, so the insert broke and took the whole sign-up down with it: Supabase Auth
-- reports that as "Database error saving new user" (code unexpected_failure). With an e-mail the trigger cannot fail, which is why e-mail and Google sign-ups worked.
--
-- handle_new_user() now creates no vendors row when the account has no e-mail, and does exactly what it did before otherwise (same columns, same name rule, same conflict rule).
-- Nothing needs that row for such an account: the six accounts already in production without an e-mail (one Apple, five phone) have none or an old one, and a person is routed by their
-- workspaces and by vendors.onboarding_completed = true, never by the mere existence of the row. It also gets a fixed search_path (public), which a SECURITY DEFINER function should have
-- and this one did not; every table it touches is already written as public.<name>.
--
-- WHY THIS IS GUARDED: this replaces a LIVE function that exists only in production (not in any committed migration), so it is compare-and-swap like the earlier replacements:
--   * live function is the version read from production on 29 Oct 2026   -> replaced with the fixed one
--   * live function already has this fix                                 -> nothing to do (safe to run twice)
--   * live function is anything else, or missing                         -> STOPS with an error and changes nothing; inspect it with \sf public.handle_new_user and reconcile by hand
-- The comparison is on the body with whitespace ignored, plus security definer and search_path. The trigger on auth.users, the vendors table and all privileges are not touched.
-- Undo: put the old version back (tests/db/fixtures/handle_new_user_before.sql). Sign-ups with an e-mail are unaffected either way.

do $migration$
declare
  v_live text;
  c_before constant text := '0f54e77c86333964079e1a41efa8ea67';  -- production's handle_new_user() as read on 29 Oct 2026
  c_after  constant text := '9c85aa68c490b14d9fa1982dfe1c572e';  -- the same, with no vendors row for an account without an e-mail, and search_path = public
begin
  select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) || '|' || p.prosecdef::text || '|' || coalesce(p.proconfig::text, ''))
  into v_live
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'handle_new_user'
    and pg_get_function_identity_arguments(p.oid) = '';

  if v_live is null then
    raise exception 'public.handle_new_user() does not exist in this database. Nothing was changed.';
  end if;

  if v_live = c_after then
    raise notice 'handle_new_user() already has this fix; nothing to do.';
    return;
  end if;

  if v_live <> c_before then
    raise exception
      'handle_new_user() in this database differs from the version this fix was written against (live fingerprint %, expected %). '
      'It was NOT replaced, because that could undo a change made directly in the database. '
      'Inspect it with \sf public.handle_new_user, then add the one change by hand (return early when new.email is null, before the insert into public.vendors) or reconcile and re-run. Nothing was changed.',
      v_live, c_before;
  end if;

  execute $fn$
    create or replace function public.handle_new_user()
    returns trigger
    language plpgsql
    security definer
    set search_path = public
    as $$
    begin
      -- vendors.email is required; an account with no e-mail (phone sign-up, Apple without the e-mail) gets no row here, and the sign-up goes ahead.
      if new.email is null then
        return new;
      end if;

      insert into public.vendors (id, email, business_name, onboarding_completed)
      values (new.id, new.email, coalesce(new.raw_user_meta_data->>'name', 'User'), false)
      on conflict (id) do nothing;

      return new;
    end;
    $$;
  $fn$;

  raise notice 'handle_new_user() fixed: an account with no e-mail no longer stops the sign-up.';
end
$migration$;
