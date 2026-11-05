create table if not exists public.shifts (
  id uuid primary key,
  title text not null,
  date date not null,
  start text not null,
  "end" text not null,
  location text,
  status text not null default 'upcoming',
  owner text not null,
  created_at timestamptz not null default now()
);
alter table public.shifts enable row level security;
create policy "public read shifts" on public.shifts for select using (true);
create policy "public insert shifts" on public.shifts for insert with check (true);
create policy "public delete shifts" on public.shifts for delete using (true);
