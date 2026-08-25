-- Week 1 of the partner marketplace rollout (Venue Owner / Promoter /
-- Organizer self-serve accounts): registration, email verification (reuses
-- Supabase Auth's own confirmation flow - same as customer signup), and the
-- 18+ / duplicate-account checks from the compliance doc. Profile details,
-- tax ID collection, Stripe Connect, and DocuSign agreements are later weeks -
-- deliberately out of scope here.

create table public.partner_accounts (
  id uuid primary key references auth.users(id) on delete cascade,
  user_type text not null check (user_type in ('venue_operator', 'promoter', 'organizer')),
  legal_name text not null,
  date_of_birth date not null,
  onboarding_step int not null default 1,
  onboarding_status text not null default 'pending' check (onboarding_status in ('pending', 'active', 'suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.partner_accounts enable row level security;

create policy "partners read own account" on public.partner_accounts
  for select using (id = auth.uid());
create policy "admins read partner accounts" on public.partner_accounts
  for select using (public.is_cms_admin());
-- No insert/update policy for partners themselves - only
-- create_partner_account() (SECURITY DEFINER) writes here, so the age gate
-- and one-account-per-person rule can't be bypassed via a direct PostgREST call.

-- Called right after supabase.auth.signUp() creates the (unconfirmed) auth
-- user - this is the actual enforcement point for the "auto-reject" rules
-- from the compliance doc (age, disposable email, duplicate account).
create or replace function public.create_partner_account(
  p_user_type text,
  p_legal_name text,
  p_date_of_birth date
)
returns public.partner_accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_age int;
  v_email text;
  v_domain text;
  v_disposable_domains text[] := array[
    'mailinator.com', 'tempmail.com', '10minutemail.com', 'guerrillamail.com',
    'throwawaymail.com', 'yopmail.com', 'trashmail.com', 'getnada.com',
    'fakeinbox.com', 'maildrop.cc', 'sharklasers.com', 'dispostable.com'
  ];
  v_row public.partner_accounts;
begin
  if auth.uid() is null then
    raise exception 'not authorized';
  end if;
  if p_user_type not in ('venue_operator', 'promoter', 'organizer') then
    raise exception 'invalid user_type';
  end if;
  if p_legal_name is null or length(trim(p_legal_name)) = 0 then
    raise exception 'legal_name is required';
  end if;

  v_age := extract(year from age(p_date_of_birth));
  if v_age < 18 then
    raise exception 'You must be 18 or older to register';
  end if;
  if v_age > 120 then
    raise exception 'Invalid date of birth';
  end if;

  v_email := lower(coalesce(auth.email(), ''));
  v_domain := split_part(v_email, '@', 2);
  if v_domain = any(v_disposable_domains) then
    raise exception 'Please use a real (non-disposable) email address';
  end if;

  if exists (select 1 from public.partner_accounts where id = auth.uid()) then
    raise exception 'You already have a partner account';
  end if;

  insert into public.partner_accounts (id, user_type, legal_name, date_of_birth)
    values (auth.uid(), p_user_type, trim(p_legal_name), p_date_of_birth)
    returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.create_partner_account(text, text, date) to authenticated;
