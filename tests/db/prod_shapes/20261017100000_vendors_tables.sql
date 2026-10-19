-- Production-only shape for 20261017100000_vendors_role_guard.sql: the classic vendors table, its administrator list, and what is wired to them,
-- copied from what production reported on 17 Oct 2026 (supabase/audit/12_vendors_table_rules.sql). Only what the guard touches or must not break.
-- Left out on purpose: the trigger that deletes the sign-in when a vendors row is deleted (nothing here needs it, and it is dangerous in a test).

-- The real auth.users has this column; the test stand-in does not.
alter table auth.users add column if not exists raw_user_meta_data jsonb;

create table public.vendors (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  business_name text,
  created_at timestamptz default now(),
  role text default 'staff',
  phone text,
  logo_url text,
  stripe_account_id text,
  onboarding_completed boolean default false,
  two_fa_enabled boolean default false,
  updated_at timestamptz default now(),
  status text
);
create table public.vendor_admins (id uuid primary key);
alter table public.vendors enable row level security;
alter table public.vendor_admins enable row level security;

create function public.is_admin() returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.vendor_admins where id = auth.uid());
$$;

create function public.sync_vendor_admins() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if (TG_OP = 'INSERT') then
    if NEW.role = 'admin' then insert into public.vendor_admins(id) values (NEW.id) on conflict do nothing; end if;
    return NEW;
  elsif (TG_OP = 'UPDATE') then
    if OLD.role = 'admin' and NEW.role <> 'admin' then delete from public.vendor_admins where id = OLD.id;
    elsif OLD.role <> 'admin' and NEW.role = 'admin' then insert into public.vendor_admins(id) values (NEW.id) on conflict do nothing;
    end if;
    return NEW;
  elsif (TG_OP = 'DELETE') then
    if OLD.role = 'admin' then delete from public.vendor_admins where id = OLD.id; end if;
    return OLD;
  end if;
  return NEW;
end; $$;
create trigger trg_sync_vendor_admins after insert or delete or update on public.vendors for each row execute function public.sync_vendor_admins();

-- A row for every new account, as production does.
create function public.handle_new_user() returns trigger language plpgsql security definer as $$
begin
  insert into public.vendors (id, email, business_name, onboarding_completed)
  values (NEW.id, NEW.email, coalesce(NEW.raw_user_meta_data->>'name', 'User'), false)
  on conflict (id) do nothing;
  return NEW;
end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create policy "Enable insert for new signups" on public.vendors for insert to authenticated with check (auth.uid() = id);
create policy "Enable select for admin role" on public.vendors for select to authenticated using (is_admin());
create policy "Enable select for own record" on public.vendors for select to public using (auth.uid() = id);
create policy "Enable update for admin role" on public.vendors for update to authenticated using (is_admin()) with check (is_admin());
create policy "Enable update for own record" on public.vendors for update to public using (auth.uid() = id) with check (auth.uid() = id);
create policy "vendors: admin full access" on public.vendors for all to authenticated using (is_admin()) with check (is_admin());
create policy "vendors: read own row" on public.vendors for select to authenticated using (id = auth.uid());
