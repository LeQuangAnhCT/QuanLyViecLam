create table if not exists public.shifts (
  id uuid primary key,
  user_id uuid references auth.users(id) on delete cascade,
  title text not null,
  date date not null,
  start text not null,
  "end" text not null,
  location text,
  status text not null default 'upcoming',
  owner text not null,
  created_at timestamptz not null default now()
);
alter table public.shifts add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.shifts enable row level security;
drop policy if exists "public read shifts" on public.shifts;
drop policy if exists "public insert shifts" on public.shifts;
drop policy if exists "public delete shifts" on public.shifts;
drop policy if exists "users read own shifts" on public.shifts;
drop policy if exists "users insert own shifts" on public.shifts;
drop policy if exists "users delete own shifts" on public.shifts;
create policy "users read own shifts" on public.shifts for select to authenticated using (auth.uid() = user_id);
create policy "users insert own shifts" on public.shifts for insert to authenticated with check (auth.uid() = user_id);
create policy "users delete own shifts" on public.shifts for delete to authenticated using (auth.uid() = user_id);
create policy "admins read all shifts" on public.shifts for select to authenticated using ((auth.jwt()->'app_metadata'->>'role') = 'admin');
create policy "admins delete all shifts" on public.shifts for delete to authenticated using ((auth.jwt()->'app_metadata'->>'role') = 'admin');

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  role text not null default 'staff',
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "users read profiles" on public.profiles;
drop policy if exists "admins read profiles" on public.profiles;
create policy "users read profiles" on public.profiles for select to authenticated using (auth.uid() = id);
create policy "admins read profiles" on public.profiles for select to authenticated using ((auth.jwt()->'app_metadata'->>'role') = 'admin');
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin insert into public.profiles(id,email,full_name) values(new.id,new.email,new.raw_user_meta_data->>'full_name') on conflict(id) do update set email=excluded.email,full_name=excluded.full_name; return new; end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();
