-- Run once in Supabase SQL Editor before using the profile page.
alter table public.profiles add column if not exists birth_date date;
alter table public.profiles add column if not exists hometown text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles enable row level security;

drop policy if exists "users insert own profile" on public.profiles;
create policy "users insert own profile" on public.profiles
  for insert to authenticated with check (id = auth.uid() and role = 'staff');
drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
grant select, insert, update (full_name,birth_date,hometown,avatar_url) on public.profiles to authenticated;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('avatars','avatars',true,2097152,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true,file_size_limit=2097152,
  allowed_mime_types=array['image/jpeg','image/png','image/webp'];
drop policy if exists "users upload own avatar" on storage.objects;
create policy "users upload own avatar" on storage.objects
  for insert to authenticated with check (bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "public read avatars" on storage.objects;
create policy "public read avatars" on storage.objects
  for select to public using (bucket_id='avatars');
