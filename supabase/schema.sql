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
