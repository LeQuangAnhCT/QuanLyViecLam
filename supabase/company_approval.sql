-- Applications are reviewed by the platform admin before a company is created.
create table public.company_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references auth.users(id),
  company_name text not null check (char_length(trim(company_name)) between 3 and 120 and company_name ~ '[[:alpha:]]'),
  address text not null check (char_length(trim(address)) between 8 and 250 and address ~ '[[:alpha:]]'),
  phone text not null check (phone ~ '^0[0-9]{9}$'),
  email text not null check (char_length(email) <= 254 and email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'),
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  company_id uuid references public.companies(id)
);
alter table public.companies add column address text;
alter table public.companies add column phone text;
alter table public.companies add column contact_email text;
alter table public.company_applications enable row level security;
create policy "view own or admin applications" on public.company_applications for select to authenticated using (applicant_id=auth.uid() or coalesce(auth.jwt()->'app_metadata'->>'role'='admin',false));
create policy "submit company application" on public.company_applications for insert to authenticated with check (applicant_id=auth.uid() and status='pending' and company_id is null and reviewed_at is null and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin');
revoke execute on function public.create_company(text,uuid) from authenticated;
revoke execute on function public.create_company_by_email(text,text) from authenticated;
create or replace function public.review_company_application(p_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare a public.company_applications; c uuid;
begin
 if coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then raise exception 'Admin only'; end if;
 select * into a from public.company_applications where id=p_id for update;
 if a.id is null or a.status<>'pending' then raise exception 'Application unavailable'; end if;
 if p_approve then
  insert into public.companies(name,address,phone,contact_email) values(trim(a.company_name),trim(a.address),a.phone,lower(trim(a.email))) returning id into c;
  insert into public.company_members(company_id,user_id,role) values(c,a.applicant_id,'manager');
 end if;
 update public.company_applications set status=case when p_approve then 'approved' else 'rejected' end, reviewed_at=now(),company_id=c where id=p_id;
end $$;
revoke all on function public.review_company_application(uuid,boolean) from public;
grant execute on function public.review_company_application(uuid,boolean) to authenticated;

-- Only members who explicitly opt in appear in the freelance directory.
create table public.freelancer_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null check(char_length(trim(display_name)) between 2 and 100 and display_name ~ '[[:alpha:]]'),
 specialty text not null check(char_length(trim(specialty)) between 2 and 200),
 visible boolean not null default false
);
alter table public.freelancer_profiles enable row level security;
create policy "own freelancer profile" on public.freelancer_profiles for all to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
create policy "manager sees public freelancers" on public.freelancer_profiles for select to authenticated using (visible and exists(select 1 from public.company_members m where m.user_id=auth.uid() and m.role='manager'));
create policy "signed in sees companies" on public.companies for select to authenticated using (true);

create table public.company_join_requests (
 company_id uuid not null references public.companies(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 status text not null default 'pending' check(status in ('pending','accepted','rejected')),
 created_at timestamptz not null default now(),
 primary key(company_id,user_id)
);
alter table public.company_join_requests enable row level security;
create policy "view join requests" on public.company_join_requests for select to authenticated using (user_id=auth.uid() or public.is_company_member(company_id,true));
create policy "request membership" on public.company_join_requests for insert to authenticated with check (user_id=auth.uid() and status='pending');
create or replace function public.review_join_request(p_company uuid,p_user uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_company_member(p_company,true) then raise exception 'Manager only'; end if;
 perform 1 from public.company_join_requests where company_id=p_company and user_id=p_user and status='pending' for update;
 if not found then raise exception 'Request unavailable'; end if;
 if p_approve then insert into public.company_members(company_id,user_id,role) values(p_company,p_user,'staff') on conflict do nothing; end if;
 update public.company_join_requests set status=case when p_approve then 'accepted' else 'rejected' end where company_id=p_company and user_id=p_user;
end $$;
revoke all on function public.review_join_request(uuid,uuid,boolean) from public;
grant execute on function public.review_join_request(uuid,uuid,boolean) to authenticated;
create or replace function public.invite_freelancer(p_company uuid,p_user uuid)
returns void language plpgsql security definer set search_path=public as $$
declare target_email text;
begin
 if not exists(select 1 from public.company_members where company_id=p_company and user_id=auth.uid() and role='manager') then raise exception 'Manager only'; end if;
 select u.email into target_email from auth.users u join public.freelancer_profiles f on f.user_id=u.id where u.id=p_user and f.visible;
 if target_email is null then raise exception 'Freelancer unavailable'; end if;
 insert into public.company_invitations(company_id,email) values(p_company,lower(target_email));
end $$;
revoke all on function public.invite_freelancer(uuid,uuid) from public;
grant execute on function public.invite_freelancer(uuid,uuid) to authenticated;
create or replace function public.list_join_requests(p_company uuid)
returns table(user_id uuid,full_name text) language sql stable security definer set search_path=public as $$
 select r.user_id,coalesce(u.raw_user_meta_data->>'full_name',u.email::text) from public.company_join_requests r join auth.users u on u.id=r.user_id
 where r.company_id=p_company and r.status='pending' and public.is_company_member(p_company,true)
$$;
revoke all on function public.list_join_requests(uuid) from public;
grant execute on function public.list_join_requests(uuid) to authenticated;
