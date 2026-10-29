-- handle_new_user() exactly as production has it (read 29 Oct 2026; fingerprint 0f54e77c86333964079e1a41efa8ea67): security definer, NO search_path.
-- It is the on_auth_user_created trigger's function. Used by migration_guard_signup_without_email.sql to put the old version back.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
as $$
BEGIN
  INSERT INTO public.vendors (id, email, business_name, onboarding_completed)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'name', 'User'),
    false
  )
  ON CONFLICT (id) DO NOTHING;
  
  RETURN NEW;
END;
$$;
