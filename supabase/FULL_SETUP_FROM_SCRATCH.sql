-- SHIFTLY - COMPLETE SUPABASE INSTALLATION FROM SCRATCH
-- Open a NEW Supabase project > SQL Editor > paste this entire file > Run.
-- Creates all public tables, triggers, functions, access policies and avatar storage.
-- NEVER run against an existing production project; use production_upgrade.sql instead.
-- Does not delete/change auth.users, auth provider setup or storage files.
-- A default Admin account is not created here: sign in using Google first,
-- then promote the chosen Auth user via the one-time admin SQL documented in README.
-- Rerunning on an installed project is intentionally rejected.

begin;

do $$ begin
  if to_regclass('public.company_members') is not null
     or to_regclass('public.company_shifts') is not null
     or to_regclass('public.company_applications') is not null then
    raise exception 'SHIFTLY is already installed. Use production_upgrade.sql for existing projects.';
  end if;
end $$;

-- ==================================================================
-- SOURCE: supabase/schema.sql
-- ==================================================================
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
create policy "admins insert all shifts" on public.shifts for insert to authenticated with check ((auth.jwt()->'app_metadata'->>'role') = 'admin');
create policy "admins update all shifts" on public.shifts for update to authenticated using ((auth.jwt()->'app_metadata'->>'role') = 'admin') with check ((auth.jwt()->'app_metadata'->>'role') = 'admin');
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

-- ==================================================================
-- SOURCE: supabase/multi_company.sql
-- ==================================================================
-- New multi-company tables are separate from legacy shifts, preserving existing data.
create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  created_at timestamptz not null default now()
);
create table if not exists public.company_members (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('manager','staff')),
  created_at timestamptz not null default now(),
  primary key (company_id,user_id)
);
create unique index if not exists one_manager_per_company on public.company_members(company_id) where role = 'manager';
create table if not exists public.company_invitations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  email text not null check (length(trim(email)) > 0),
  status text not null default 'pending' check (status in ('pending','accepted','revoked')),
  created_at timestamptz not null default now()
);
create unique index if not exists one_pending_invitation on public.company_invitations(company_id,lower(email)) where status='pending';
create table if not exists public.company_shifts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  user_id uuid not null,
  title text not null check (length(trim(title))>0),
  location text,
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at>starts_at),
  created_at timestamptz not null default now(),
  foreign key (company_id,user_id) references public.company_members(company_id,user_id)
);
alter table public.companies enable row level security;
alter table public.company_members enable row level security;
alter table public.company_invitations enable row level security;
alter table public.company_shifts enable row level security;

create or replace function public.is_company_member(p_company uuid, p_manager boolean default false)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.company_members where company_id=p_company and user_id=auth.uid() and (not p_manager or role='manager'))
    or coalesce(auth.jwt()->'app_metadata'->>'role'='admin',false)
$$;
revoke all on function public.is_company_member(uuid,boolean) from public;
grant execute on function public.is_company_member(uuid,boolean) to authenticated;

create policy "company access" on public.companies for select to authenticated using (public.is_company_member(id));
create policy "invited company access" on public.companies for select to authenticated using (exists(select 1 from public.company_invitations i where i.company_id=id and i.status='pending' and lower(i.email)=lower(auth.jwt()->>'email')));
create policy "members see company members" on public.company_members for select to authenticated using (public.is_company_member(company_id));
create policy "invitations visible" on public.company_invitations for select to authenticated using (public.is_company_member(company_id,true) or lower(email)=lower(auth.jwt()->>'email'));
create policy "managers invite" on public.company_invitations for insert to authenticated with check (public.is_company_member(company_id,true));
create policy "managers update invitations" on public.company_invitations for update to authenticated using (public.is_company_member(company_id,true)) with check (public.is_company_member(company_id,true));
create policy "company shifts visible" on public.company_shifts for select to authenticated using (public.is_company_member(company_id,true) or (user_id=auth.uid() and public.is_company_member(company_id)));
create policy "managers create shifts" on public.company_shifts for insert to authenticated with check (public.is_company_member(company_id,true));
create policy "managers edit shifts" on public.company_shifts for update to authenticated using (public.is_company_member(company_id,true)) with check (public.is_company_member(company_id,true));
create policy "managers delete shifts" on public.company_shifts for delete to authenticated using (public.is_company_member(company_id,true));

create or replace function public.accept_company_invitation(p_invitation uuid)
returns void language plpgsql security definer set search_path=public as $$
declare inv public.company_invitations;
begin
  select * into inv from public.company_invitations where id=p_invitation for update;
  if auth.uid() is null or inv.id is null or inv.status<>'pending'
    or coalesce(lower(auth.jwt()->>'email'),'')<>lower(inv.email)
    or not exists (select 1 from auth.users u where u.id=auth.uid() and u.email_confirmed_at is not null and lower(u.email)=lower(inv.email)) then
    raise exception 'Invitation unavailable';
  end if;
  insert into public.company_members(company_id,user_id,role) values(inv.company_id,auth.uid(),'staff') on conflict do nothing;
  update public.company_invitations set status='accepted' where id=inv.id;
end $$;
revoke all on function public.accept_company_invitation(uuid) from public;
grant execute on function public.accept_company_invitation(uuid) to authenticated;

-- An admin provisions a company and assigns its one manager atomically.
create or replace function public.create_company(p_name text, p_manager uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  if coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin' then
    raise exception 'Only an admin can create a company';
  end if;
  insert into public.companies(name) values(trim(p_name)) returning id into new_id;
  insert into public.company_members(company_id,user_id,role) values(new_id,p_manager,'manager');
  return new_id;
end $$;
revoke all on function public.create_company(text,uuid) from public;
grant execute on function public.create_company(text,uuid) to authenticated;

-- Planned time only: this does not prove the employee attended.
create or replace view public.planned_attendance with (security_invoker=true) as
select id as shift_id, company_id, user_id, starts_at, ends_at,
       extract(epoch from (ends_at-starts_at))/3600.0 as planned_hours
from public.company_shifts;
grant select on public.planned_attendance to authenticated;

create or replace function public.company_roster(p_company uuid)
returns table(user_id uuid, full_name text, email text, role text)
language sql stable security definer set search_path=public as $$
  select m.user_id, coalesce(u.raw_user_meta_data->>'full_name',u.email::text), u.email::text, m.role
  from public.company_members m join auth.users u on u.id=m.user_id
  where m.company_id=p_company and public.is_company_member(p_company)
$$;
revoke all on function public.company_roster(uuid) from public;
grant execute on function public.company_roster(uuid) to authenticated;

create or replace function public.create_company_by_email(p_name text, p_email text)
returns uuid language plpgsql security definer set search_path=public as $$
declare manager_id uuid;
begin
  if coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin' then raise exception 'Only an admin can create a company'; end if;
  select id into manager_id from auth.users where lower(email)=lower(trim(p_email)) and email_confirmed_at is not null;
  if manager_id is null then raise exception 'Manager must sign in first'; end if;
  return public.create_company(p_name,manager_id);
end $$;
revoke all on function public.create_company_by_email(text,text) from public;
grant execute on function public.create_company_by_email(text,text) to authenticated;

-- ==================================================================
-- SOURCE: supabase/company_approval.sql
-- ==================================================================
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

-- ==================================================================
-- SOURCE: supabase/account_controls.sql
-- ==================================================================
create table public.account_restrictions (
 user_id uuid primary key references auth.users(id) on delete cascade,
 disabled boolean not null default false,
 reason text not null check(length(trim(reason)) between 5 and 500),
 changed_by uuid not null references auth.users(id),
 changed_at timestamptz not null default now()
);
alter table public.account_restrictions enable row level security;
create policy "read own account restriction" on public.account_restrictions for select to authenticated using(user_id=auth.uid() or coalesce(auth.jwt()->'app_metadata'->>'role'='admin',false));
create or replace function public.account_active() returns boolean language sql stable security definer set search_path=public as $$
 select auth.uid() is not null and not exists(select 1 from public.account_restrictions where user_id=auth.uid() and disabled)
$$;
revoke all on function public.account_active() from public;
grant execute on function public.account_active() to authenticated;
create or replace function public.is_company_member(p_company uuid,p_manager boolean default false) returns boolean language sql stable security definer set search_path=public as $$
 select public.account_active() and (exists(select 1 from public.company_members where company_id=p_company and user_id=auth.uid() and (not p_manager or role='manager')) or coalesce(auth.jwt()->'app_metadata'->>'role'='admin',false))
$$;
create policy "active account companies" on public.companies as restrictive for all to authenticated using(public.account_active()) with check(public.account_active());
create policy "active account memberships" on public.company_members as restrictive for all to authenticated using(public.account_active()) with check(public.account_active());
create policy "active account shifts" on public.company_shifts as restrictive for all to authenticated using(public.account_active()) with check(public.account_active());
create policy "active account invitations" on public.company_invitations as restrictive for all to authenticated using(public.account_active()) with check(public.account_active());
create policy "active account applications" on public.company_applications as restrictive for all to authenticated using(public.account_active()) with check(public.account_active());
create policy "active account freelancers" on public.freelancer_profiles as restrictive for all to authenticated using(public.account_active()) with check(public.account_active());
create policy "active account requests" on public.company_join_requests as restrictive for all to authenticated using(public.account_active()) with check(public.account_active());
do $$ begin
 if to_regclass('public.shifts') is not null then execute 'create policy "active account legacy shifts" on public.shifts as restrictive for all to authenticated using(public.account_active()) with check(public.account_active())'; end if;
 if to_regclass('public.profiles') is not null then execute 'create policy "active account legacy profiles" on public.profiles as restrictive for all to authenticated using(public.account_active()) with check(public.account_active())'; end if;
end $$;
create or replace function public.accept_company_invitation(p_invitation uuid) returns void language plpgsql security definer set search_path=public as $$
declare inv public.company_invitations;
begin
 if not public.account_active() then raise exception 'Account disabled'; end if;
 select * into inv from public.company_invitations where id=p_invitation for update;
 if inv.id is null or inv.status<>'pending' or coalesce(lower(auth.jwt()->>'email'),'')<>lower(inv.email)
 or not exists(select 1 from auth.users u where u.id=auth.uid() and u.email_confirmed_at is not null and lower(u.email)=lower(inv.email)) then raise exception 'Invitation unavailable'; end if;
 insert into public.company_members(company_id,user_id,role) values(inv.company_id,auth.uid(),'staff') on conflict do nothing;
 update public.company_invitations set status='accepted' where id=inv.id;
end $$;
create or replace function public.invite_freelancer(p_company uuid,p_user uuid) returns void language plpgsql security definer set search_path=public as $$
declare target_email text;
begin
 if not public.account_active() or not exists(select 1 from public.company_members where company_id=p_company and user_id=auth.uid() and role='manager') then raise exception 'Manager only'; end if;
 select u.email into target_email from auth.users u join public.freelancer_profiles f on f.user_id=u.id where u.id=p_user and f.visible;
 if target_email is null then raise exception 'Freelancer unavailable'; end if;
 insert into public.company_invitations(company_id,email) values(p_company,lower(target_email));
end $$;
create or replace function public.request_company_membership(p_company uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.account_active() then raise exception 'Tài khoản bị vô hiệu hóa'; end if;
 if not exists(select 1 from public.companies where id=p_company) then raise exception 'Công ty không tồn tại'; end if;
 if exists(select 1 from public.company_members where company_id=p_company and user_id=auth.uid()) then raise exception 'Bạn đã là thành viên'; end if;
 insert into public.company_join_requests(company_id,user_id,status) values(p_company,auth.uid(),'pending')
 on conflict(company_id,user_id) do update set status='pending',created_at=now()
 where company_join_requests.status='rejected';
 if not found then raise exception 'Yêu cầu của bạn đang chờ duyệt'; end if;
end $$;
revoke all on function public.request_company_membership(uuid) from public;
grant execute on function public.request_company_membership(uuid) to authenticated;
create or replace function public.admin_list_accounts() returns table(user_id uuid,email text,full_name text,disabled boolean,reason text)
language sql stable security definer set search_path=public as $$
 select u.id,u.email::text,coalesce(u.raw_user_meta_data->>'full_name',u.email::text),coalesce(r.disabled,false),r.reason from auth.users u left join public.account_restrictions r on r.user_id=u.id
 where public.account_active() and coalesce(auth.jwt()->'app_metadata'->>'role','')='admin'
$$;
revoke all on function public.admin_list_accounts() from public;
grant execute on function public.admin_list_accounts() to authenticated;
create or replace function public.admin_set_account_disabled(p_user uuid,p_disabled boolean,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.account_active() or coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then raise exception 'Admin only'; end if;
 if p_user=auth.uid() or exists(select 1 from auth.users where id=p_user and raw_app_meta_data->>'role'='admin') then raise exception 'Cannot disable an admin account'; end if;
 if char_length(trim(coalesce(p_reason,'')))<5 then raise exception 'Reason must have at least 5 characters'; end if;
 insert into public.account_restrictions(user_id,disabled,reason,changed_by) values(p_user,p_disabled,trim(p_reason),auth.uid())
 on conflict(user_id) do update set disabled=excluded.disabled,reason=excluded.reason,changed_by=excluded.changed_by,changed_at=now();
end $$;
revoke all on function public.admin_set_account_disabled(uuid,boolean,text) from public;
grant execute on function public.admin_set_account_disabled(uuid,boolean,text) to authenticated;
create or replace function public.admin_set_company_manager(p_company uuid,p_user uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.account_active() or coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then raise exception 'Admin only'; end if;
 perform 1 from public.companies where id=p_company for update;
 if not found or not exists(select 1 from public.company_members where company_id=p_company and user_id=p_user) then raise exception 'User must be a member'; end if;
 if exists(select 1 from public.account_restrictions where user_id=p_user and disabled) then raise exception 'Account is disabled'; end if;
 update public.company_members set role='staff' where company_id=p_company and role='manager' and user_id<>p_user;
 update public.company_members set role='manager' where company_id=p_company and user_id=p_user;
end $$;
revoke all on function public.admin_set_company_manager(uuid,uuid) from public;
grant execute on function public.admin_set_company_manager(uuid,uuid) to authenticated;

-- Add a registered, verified account as staff; manager transfer is a separate action.
create or replace function public.admin_add_company_member(p_company uuid,p_email text)
returns void language plpgsql security definer set search_path=public as $$
declare target_id uuid;
begin
 if not public.account_active() or coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then raise exception 'Admin only'; end if;
 select id into target_id from auth.users where lower(email)=lower(trim(p_email)) and email_confirmed_at is not null;
 if target_id is null then raise exception 'Tài khoản cần đăng nhập Google trước khi được thêm'; end if;
 if exists(select 1 from public.account_restrictions where user_id=target_id and disabled) then raise exception 'Tài khoản đang bị vô hiệu hóa'; end if;
 insert into public.company_members(company_id,user_id,role) values(p_company,target_id,'staff') on conflict do nothing;
end $$;
revoke all on function public.admin_add_company_member(uuid,text) from public;
grant execute on function public.admin_add_company_member(uuid,text) to authenticated;

-- ==================================================================
-- SOURCE: supabase/admin_scope.sql
-- ==================================================================
-- Platform admins manage the platform, not company schedules or attendance.
create policy "platform admins cannot access company shifts" on public.company_shifts
as restrictive for all to authenticated
using (coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin')
with check (coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin');

do $$ begin
  if to_regclass('public.shifts') is not null then
    execute 'create policy "platform admins cannot access legacy shifts" on public.shifts as restrictive for all to authenticated using (coalesce(auth.jwt()->''app_metadata''->>''role'','''') <> ''admin'') with check (coalesce(auth.jwt()->''app_metadata''->>''role'','''') <> ''admin'')';
  end if;
end $$;

-- Accounts are created through Google sign-in; admins do not enroll users.
revoke execute on function public.admin_add_company_member(uuid,text) from authenticated;

create or replace function public.admin_list_accounts()
returns table(user_id uuid,email text,full_name text,disabled boolean,reason text)
language sql stable security definer set search_path=public as $$
  select u.id,u.email::text,coalesce(u.raw_user_meta_data->>'full_name',u.email::text),
         coalesce(r.disabled,false),r.reason
  from auth.users u left join public.account_restrictions r on r.user_id=u.id
  where public.account_active() and coalesce(auth.jwt()->'app_metadata'->>'role','')='admin'
    and u.last_sign_in_at is not null
$$;

create or replace function public.admin_company_directory()
returns table(id uuid,name text,address text,phone text,contact_email text,manager_name text,manager_email text)
language sql stable security definer set search_path=public as $$
  select c.id,c.name,c.address,c.phone,c.contact_email,
         coalesce(u.raw_user_meta_data->>'full_name',u.email::text),u.email::text
  from public.companies c
  left join public.company_members m on m.company_id=c.id and m.role='manager'
  left join auth.users u on u.id=m.user_id
  where public.account_active() and coalesce(auth.jwt()->'app_metadata'->>'role','')='admin'
  order by c.name
$$;
revoke all on function public.admin_company_directory() from public;
grant execute on function public.admin_company_directory() to authenticated;

-- ==================================================================
-- SOURCE: supabase/production_upgrade.sql
-- ==================================================================
-- SHIFTLY — ONE-PASTE SUPABASE PRODUCTION UPGRADE
-- For an EXISTING project with companies, memberships, Auth and account controls.
-- Paste this entire file into Supabase Dashboard > SQL Editor > Run.
-- This file is designed to be repeatable and preserves existing employees,
-- shifts, attendance, notifications and compensation rates.
-- Back up the database first. All statements run in one transaction.
-- RLS and server-side triggers are enforced independently of the Vue frontend.

-- begin nested transaction removed for fresh install

do $$ begin
  if to_regclass('public.company_members') is null
     or to_regclass('public.company_shifts') is null
     or to_regclass('public.companies') is null
     or to_regclass('public.account_restrictions') is null then
    raise exception 'Thiếu schema cơ bản. Cần chạy multi_company.sql và account_controls.sql trước.';
  end if;
end $$;

-- >>> FILE 1: supabase/member_compensation.sql
-- Compensation belongs to one membership, not to a user globally.
create table if not exists public.member_compensation (
  company_id uuid not null,
  user_id uuid not null,
  employment_type text not null check (employment_type in ('employee','freelancer')),
  monthly_base_vnd numeric(14,0),
  show_rate_vnd numeric(14,0) not null check (show_rate_vnd >= 0),
  updated_at timestamptz not null default now(),
  primary key (company_id,user_id),
  foreign key (company_id,user_id) references public.company_members(company_id,user_id) on delete cascade,
  check ((employment_type='freelancer' and monthly_base_vnd is null) or
         (employment_type='employee' and monthly_base_vnd is not null and monthly_base_vnd >= 0))
);
alter table public.member_compensation enable row level security;
grant select,insert,update,delete on public.member_compensation to authenticated;

drop policy if exists "members read own compensation and managers read their company" on public.member_compensation;
create policy "members read own compensation and managers read their company" on public.member_compensation
for select to authenticated using (
  public.account_active() and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin'
  and (user_id=auth.uid() or exists (select 1 from public.company_members m
    where m.company_id=member_compensation.company_id and m.user_id=auth.uid() and m.role='manager'))
);
drop policy if exists "managers manage their company compensation" on public.member_compensation;
create policy "managers manage their company compensation" on public.member_compensation
for all to authenticated using (
  public.account_active() and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin'
  and exists (select 1 from public.company_members m where m.company_id=member_compensation.company_id and m.user_id=auth.uid() and m.role='manager')
) with check (
  public.account_active() and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin'
  and exists (select 1 from public.company_members m where m.company_id=member_compensation.company_id and m.user_id=auth.uid() and m.role='manager')
);

-- <<< END supabase/member_compensation.sql

-- >>> FILE 2: supabase/shift_business_rules.sql
-- Apply after multi_company, company_approval, account_controls and admin_scope.
-- A shift can span midnight, but one person must not be assigned overlapping hours,
-- including overlapping assignments in different companies.
-- No extension required: a row lock on auth.users serializes changes per user.
create or replace function public.prevent_overlapping_staff_shifts()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.ends_at <= new.starts_at then
    raise exception 'Shift must end after it starts' using errcode='23514';
  end if;
  if new.ends_at - new.starts_at > interval '24 hours' then
    raise exception 'A single shift must not exceed 24 hours' using errcode='23514';
  end if;
  perform 1 from auth.users where id = new.user_id for update;
  if exists (
    select 1 from public.company_shifts s
    where s.user_id = new.user_id
      and s.id is distinct from new.id
      and s.starts_at < new.ends_at
      and s.ends_at > new.starts_at
  ) then
    raise exception 'Staff member already has an overlapping shift' using errcode='23P01';
  end if;
  return new;
end $$;
revoke all on function public.prevent_overlapping_staff_shifts() from public;
drop trigger if exists check_shift_conflict on public.company_shifts;
create trigger check_shift_conflict
before insert or update of user_id,starts_at,ends_at on public.company_shifts
for each row execute function public.prevent_overlapping_staff_shifts();

-- A disabled admin must not be able to approve companies via a direct RPC call.
create or replace function public.review_company_application(p_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare a public.company_applications; c uuid;
begin
  if not public.account_active() or coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin' then
    raise exception 'Active platform admin only';
  end if;
  select * into a from public.company_applications where id=p_id for update;
  if a.id is null or a.status <> 'pending' then raise exception 'Application unavailable'; end if;
  if p_approve then
    if exists(select 1 from public.account_restrictions where user_id=a.applicant_id and disabled) then
      raise exception 'Cannot approve an application for a disabled account';
    end if;
    insert into public.companies(name,address,phone,contact_email)
    values(trim(a.company_name),trim(a.address),a.phone,lower(trim(a.email)))
    returning id into c;
    insert into public.company_members(company_id,user_id,role) values(c,a.applicant_id,'manager');
  end if;
  update public.company_applications
    set status=case when p_approve then 'approved' else 'rejected' end,
        reviewed_at=now(), company_id=c
  where id=p_id;
end $$;
revoke all on function public.review_company_application(uuid,boolean) from public;
grant execute on function public.review_company_application(uuid,boolean) to authenticated;

-- Platform admins are distinct from company managers, even when
-- is_company_member() grants them broad lookup access.
create or replace function public.review_join_request(p_company uuid,p_user uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.account_active()
     or coalesce(auth.jwt()->'app_metadata'->>'role','') = 'admin'
     or not exists(select 1 from public.company_members
                   where company_id=p_company and user_id=auth.uid() and role='manager') then
    raise exception 'Active company manager only';
  end if;
  perform 1 from public.company_join_requests
    where company_id=p_company and user_id=p_user and status='pending' for update;
  if not found then raise exception 'Request unavailable'; end if;
  if p_approve then
    if exists(select 1 from public.account_restrictions where user_id=p_user and disabled) then
      raise exception 'Cannot approve a disabled account';
    end if;
    insert into public.company_members(company_id,user_id,role)
      values(p_company,p_user,'staff') on conflict do nothing;
  end if;
  update public.company_join_requests
    set status=case when p_approve then 'accepted' else 'rejected' end
  where company_id=p_company and user_id=p_user;
end $$;
revoke all on function public.review_join_request(uuid,uuid,boolean) from public;
grant execute on function public.review_join_request(uuid,uuid,boolean) to authenticated;

create or replace function public.list_join_requests(p_company uuid)
returns table(user_id uuid, full_name text)
language sql stable security definer set search_path=public as $$
  select r.user_id,coalesce(u.raw_user_meta_data->>'full_name',u.email::text)
  from public.company_join_requests r join auth.users u on u.id=r.user_id
  where r.company_id=p_company and r.status='pending' and public.account_active()
    and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin'
    and exists(select 1 from public.company_members m where m.company_id=p_company
               and m.user_id=auth.uid() and m.role='manager')
$$;
revoke all on function public.list_join_requests(uuid) from public;
grant execute on function public.list_join_requests(uuid) to authenticated;

-- Prevent direct table access by platform admins to manager-only workflows.
drop policy if exists "platform admins excluded from invitations" on public.company_invitations;
create policy "platform admins excluded from invitations" on public.company_invitations
as restrictive for all to authenticated
using (coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin')
with check (coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin');
drop policy if exists "platform admins excluded from join requests" on public.company_join_requests;
create policy "platform admins excluded from join requests" on public.company_join_requests
as restrictive for all to authenticated
using (coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin')
with check (coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin');

-- <<< END supabase/shift_business_rules.sql

-- >>> FILE 3: supabase/shift_notifications.sql
-- Migration after shift_business_rules.sql.
-- Every staff assignment, change or cancellation leaves a persistent in-app notification.
-- The trigger, rather than the browser, writes the notification in the same transaction
-- as the shift change; a failed shift edit cannot produce a false notification.

create table if not exists public.shift_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  shift_id uuid,
  event text not null check (event in ('created','updated','cancelled')),
  title text not null,
  body text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists shift_notifications_user_created
  on public.shift_notifications (user_id, created_at desc);

alter table public.shift_notifications enable row level security;
revoke all on public.shift_notifications from anon, authenticated;
grant select, update (read_at) on public.shift_notifications to authenticated;

drop policy if exists "staff read own shift notifications" on public.shift_notifications;
create policy "staff read own shift notifications" on public.shift_notifications
  for select to authenticated
  using (public.account_active() and user_id = auth.uid()
    and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin');

drop policy if exists "staff mark own notifications read" on public.shift_notifications;
create policy "staff mark own notifications read" on public.shift_notifications
  for update to authenticated
  using (public.account_active() and user_id = auth.uid()
    and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin')
  with check (public.account_active() and user_id = auth.uid()
    and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin');

create or replace function public.record_shift_notification(
  p_shift public.company_shifts, p_event text)
returns void language plpgsql security definer set search_path=public as $$
declare
  heading text;
  details text;
begin
  heading := case p_event
    when 'created' then 'Bạn có ca làm mới'
    when 'updated' then 'Lịch làm việc đã thay đổi'
    else 'Ca làm việc đã bị hủy'
  end;
  details := format('%s · %s · %s đến %s',
    p_shift.title,
    coalesce(nullif(trim(p_shift.location),''),'Chưa có địa điểm'),
    to_char(p_shift.starts_at at time zone 'Asia/Ho_Chi_Minh','DD/MM/YYYY HH24:MI'),
    to_char(p_shift.ends_at at time zone 'Asia/Ho_Chi_Minh','DD/MM/YYYY HH24:MI'));
  insert into public.shift_notifications(user_id,company_id,shift_id,event,title,body)
  values(p_shift.user_id,p_shift.company_id,p_shift.id,p_event,heading,details);
end $$;
revoke all on function public.record_shift_notification(public.company_shifts,text) from public;

create or replace function public.notify_shift_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if TG_OP = 'INSERT' then
    perform public.record_shift_notification(NEW,'created');
    return NEW;
  elsif TG_OP = 'DELETE' then
    perform public.record_shift_notification(OLD,'cancelled');
    return OLD;
  else
    if (OLD.user_id,OLD.title,OLD.location,OLD.starts_at,OLD.ends_at)
       is not distinct from
       (NEW.user_id,NEW.title,NEW.location,NEW.starts_at,NEW.ends_at) then
      return NEW;
    end if;
    if OLD.user_id is distinct from NEW.user_id then
      perform public.record_shift_notification(OLD,'cancelled');
      perform public.record_shift_notification(NEW,'created');
    else
      perform public.record_shift_notification(NEW,'updated');
    end if;
    return NEW;
  end if;
end $$;
revoke all on function public.notify_shift_change() from public;

drop trigger if exists notify_company_shift_change on public.company_shifts;
create trigger notify_company_shift_change
  after insert or update or delete on public.company_shifts
  for each row execute function public.notify_shift_change();

-- <<< END supabase/shift_notifications.sql

-- >>> FILE 4: supabase/shift_attendance.sql
-- Apply AFTER multi_company.sql, account_controls.sql, admin_scope.sql,
-- shift_business_rules.sql, and shift_notifications.sql.
-- This adds actual time-clock records, separate from planned_attendance (forecast only).
-- Once a staff member checks in, their assigned shift cannot be deleted or rescheduled.

create table if not exists public.shift_attendance (
  shift_id uuid primary key references public.company_shifts(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  checked_in_at timestamptz not null default now(),
  checked_out_at timestamptz,
  constraint attendance_checkout_order check (checked_out_at is null or checked_out_at >= checked_in_at)
);
create index if not exists attendance_company_user_idx on public.shift_attendance(company_id,user_id);

alter table public.shift_attendance enable row level security;
revoke all on public.shift_attendance from public,anon,authenticated;
grant select on public.shift_attendance to authenticated;

drop policy if exists "attendance for self and company manager" on public.shift_attendance;
create policy "attendance for self and company manager"
  on public.shift_attendance for select to authenticated
  using (
    public.account_active()
    and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin'
    and (
      user_id=auth.uid()
      or exists (
        select 1 from public.company_members cm
        where cm.company_id=shift_attendance.company_id
          and cm.user_id=auth.uid() and cm.role='manager'
      )
    )
  );

create or replace function public.clock_in_shift(p_shift uuid)
returns void language plpgsql security definer set search_path=public as $$
declare assignment public.company_shifts;
begin
  if not public.account_active()
    or coalesce(auth.jwt()->'app_metadata'->>'role','')='admin' then
    raise exception 'Tài khoản không có quyền chấm công' using errcode='P4520';
  end if;
  select * into assignment from public.company_shifts where id=p_shift for update;
  if assignment.id is null or assignment.user_id<>auth.uid()
    or not exists(
      select 1 from public.company_members cm
      where cm.company_id=assignment.company_id
        and cm.user_id=auth.uid() and cm.role='staff'
    ) then
    raise exception 'Chỉ nhân viên được phân ca mới được chấm công' using errcode='P4520';
  end if;
  if now() < assignment.starts_at - interval '1 hour'
     or now() > assignment.ends_at + interval '12 hours' then
    raise exception 'Chỉ chấm công từ 1 giờ trước ca đến 12 giờ sau khi ca kết thúc' using errcode='P4521';
  end if;
  if exists(select 1 from public.shift_attendance where shift_id=p_shift) then
    raise exception 'Ca này đã được chấm công trước đó' using errcode='P4522';
  end if;
  insert into public.shift_attendance(shift_id,company_id,user_id)
    values(assignment.id,assignment.company_id,auth.uid());
end $$;
revoke all on function public.clock_in_shift(uuid) from public;
grant execute on function public.clock_in_shift(uuid) to authenticated;

create or replace function public.clock_out_shift(p_shift uuid)
returns void language plpgsql security definer set search_path=public as $$
declare assignment public.company_shifts;
begin
  if not public.account_active()
    or coalesce(auth.jwt()->'app_metadata'->>'role','')='admin' then
    raise exception 'Tài khoản không có quyền chấm công' using errcode='P4520';
  end if;
  select * into assignment from public.company_shifts where id=p_shift for update;
  if assignment.id is null or assignment.user_id<>auth.uid()
    or not exists(
      select 1 from public.company_members cm
      where cm.company_id=assignment.company_id
        and cm.user_id=auth.uid() and cm.role='staff'
    ) then
    raise exception 'Chỉ nhân viên được phân ca mới được chấm công' using errcode='P4520';
  end if;
  update public.shift_attendance
    set checked_out_at=now()
    where shift_id=p_shift and user_id=auth.uid() and checked_out_at is null;
  if not found then
    raise exception 'Ca chưa chấm công vào hoặc đã chấm công ra' using errcode='P4522';
  end if;
end $$;
revoke all on function public.clock_out_shift(uuid) from public;
grant execute on function public.clock_out_shift(uuid) to authenticated;

create or replace function public.protect_clocked_shift()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.shift_attendance where shift_id=OLD.id) then
    if TG_OP='DELETE' then return OLD; end if;
    return NEW;
  end if;
  if TG_OP='DELETE' then
    raise exception 'Không thể hủy ca đã có chấm công' using errcode='P4510';
  end if;
  if (NEW.user_id,NEW.starts_at,NEW.ends_at)
     is distinct from (OLD.user_id,OLD.starts_at,OLD.ends_at) then
    raise exception 'Ca đã chấm công: không được thay nhân viên hoặc thời gian' using errcode='P4511';
  end if;
  return NEW;
end $$;
revoke all on function public.protect_clocked_shift() from public;
drop trigger if exists protect_attended_shifts on public.company_shifts;
create trigger protect_attended_shifts
  before delete or update on public.company_shifts
  for each row execute function public.protect_clocked_shift();

-- Check: planned_attendance is NOT actual clock-in. Existing planned shifts
-- should not get any rows in shift_attendance until a staff member clocks in.

-- <<< END supabase/shift_attendance.sql

-- >>> FILE 5: supabase/staff_business.sql
-- Shiftly: permanent vs seasonal staff.
-- Apply AFTER supabase/member_compensation.sql and supabase/shift_attendance.sql.
-- Non-destructive and repeatable. Existing 'employee' and 'freelancer' codes remain
-- unchanged to preserve historical records and compatibility with older clients.
--
-- employee   = Nhân viên chính thức (monthly base + optional completed-show bonus)
-- freelancer = Nhân viên thời vụ (completed-show rate only)
-- These are EMPLOYMENT TYPES, not authentication roles. Both are staff.

create or replace function public.auto_classify_staff()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.role = 'staff' then
    insert into public.member_compensation
      (company_id,user_id,employment_type,monthly_base_vnd,show_rate_vnd)
    values (new.company_id,new.user_id,'freelancer',null,0)
    on conflict (company_id,user_id) do nothing;
  end if;
  return new;
end $$;
revoke all on function public.auto_classify_staff() from public;

drop trigger if exists auto_classify_new_staff on public.company_members;
create trigger auto_classify_new_staff
  after insert or update of role on public.company_members
  for each row execute function public.auto_classify_staff();

-- Backfill staff who joined before the new classification workflow. Do not
-- overwrite their existing employee/freelancer category or agreed rates.
insert into public.member_compensation
  (company_id,user_id,employment_type,monthly_base_vnd,show_rate_vnd)
select m.company_id,m.user_id,'freelancer',null,0
from public.company_members m
where m.role='staff'
on conflict (company_id,user_id) do nothing;

create or replace function public.enforce_staff_compensation()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.company_members m
      where m.company_id=new.company_id and m.user_id=new.user_id and m.role='staff') then
    raise exception 'Chỉ nhân viên Staff được thiết lập loại và mức lương'
      using errcode='P4540';
  end if;
  return new;
end $$;
revoke all on function public.enforce_staff_compensation() from public;

drop trigger if exists validate_staff_compensation on public.member_compensation;
create trigger validate_staff_compensation
  before insert or update on public.member_compensation
  for each row execute function public.enforce_staff_compensation();

create or replace function public.enforce_staff_shift()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists (
    select 1 from public.company_members m
    where m.company_id=new.company_id and m.user_id=new.user_id and m.role='staff'
  ) then
    raise exception 'Chỉ được phân ca cho nhân viên Staff thuộc công ty'
      using errcode='P4541';
  end if;
  if exists (
    select 1 from public.account_restrictions r
    where r.user_id=new.user_id and r.disabled
  ) then
    raise exception 'Không thể phân ca cho tài khoản đã bị vô hiệu hóa'
      using errcode='P4542';
  end if;
  return new;
end $$;
revoke all on function public.enforce_staff_shift() from public;

drop trigger if exists validate_staff_shift on public.company_shifts;
create trigger validate_staff_shift
  before insert or update of user_id,company_id on public.company_shifts
  for each row execute function public.enforce_staff_shift();

-- Read-only monthly preview. This is NOT a payroll payment or payslip.
-- Values use CURRENT compensation rates and completed check-outs; historical
-- rates, statutory deductions, leave rules and proration are not modeled.
create or replace function public.company_staff_summary(p_company uuid,p_month date)
returns table (
  user_id uuid, full_name text, email text,
  employment_type text, monthly_base_vnd numeric, show_rate_vnd numeric,
  scheduled_shifts bigint, completed_shifts bigint, worked_hours numeric,
  estimated_total_vnd numeric
)
language plpgsql stable security definer set search_path=public as $$
declare
  first_day timestamptz;
  next_month timestamptz;
begin
  if p_month is null or not public.account_active()
    or coalesce(auth.jwt()->'app_metadata'->>'role','')='admin'
    or not exists (
      select 1 from public.company_members m where m.company_id=p_company
        and m.user_id=auth.uid() and m.role='manager'
    ) then
    raise exception 'Chỉ Manager của công ty được xem bảng công và lương'
      using errcode='P4543';
  end if;
  first_day := (date_trunc('month',p_month::timestamp) at time zone 'Asia/Ho_Chi_Minh');
  next_month := ((date_trunc('month',p_month::timestamp) + interval '1 month') at time zone 'Asia/Ho_Chi_Minh');
  return query
    select m.user_id,
      coalesce(u.raw_user_meta_data->>'full_name',u.email::text)::text,
      u.email::text,
      p.employment_type::text,
      p.monthly_base_vnd::numeric,
      p.show_rate_vnd::numeric,
      count(s.id)::bigint,
      count(a.shift_id) filter (where a.checked_out_at is not null)::bigint,
      round(coalesce(sum(extract(epoch from (a.checked_out_at-a.checked_in_at))/3600.0)
        filter (where a.checked_out_at is not null),0)::numeric,2),
      (coalesce(p.monthly_base_vnd,0) +
       coalesce(p.show_rate_vnd,0) * count(a.shift_id)
         filter (where a.checked_out_at is not null))::numeric
    from public.company_members m
      join auth.users u on u.id=m.user_id
      join public.member_compensation p on p.company_id=m.company_id and p.user_id=m.user_id
      left join public.company_shifts s on s.company_id=m.company_id and s.user_id=m.user_id
        and s.starts_at>=first_day and s.starts_at<next_month
      left join public.shift_attendance a on a.shift_id=s.id
    where m.company_id=p_company and m.role='staff'
    group by m.user_id,u.email,u.raw_user_meta_data,p.employment_type,
      p.monthly_base_vnd,p.show_rate_vnd
    order by coalesce(u.raw_user_meta_data->>'full_name',u.email::text);
end $$;
revoke all on function public.company_staff_summary(uuid,date) from public;
grant execute on function public.company_staff_summary(uuid,date) to authenticated;

-- <<< END supabase/staff_business.sql

-- >>> FILE 7: supabase/staff_lifecycle.sql
-- Manager can pause/reactivate a Staff member without deleting attendance history.
-- Existing memberships are active after this non-destructive upgrade.
alter table public.company_members
  add column if not exists is_active boolean not null default true;

create or replace function public.manager_set_staff_active(
  p_company uuid, p_user uuid, p_active boolean
) returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.account_active()
    or coalesce(auth.jwt()->'app_metadata'->>'role','') = 'admin'
    or not exists (select 1 from public.company_members m
      where m.company_id=p_company and m.user_id=auth.uid()
        and m.role='manager' and m.is_active)
  then
    raise exception 'Chỉ Manager đang hoạt động được thay đổi trạng thái nhân viên' using errcode='P4550';
  end if;
  perform 1 from public.company_members m
    where m.company_id=p_company and m.user_id=p_user and m.role='staff' for update;
  if not found then
    raise exception 'Không tìm thấy nhân viên của công ty' using errcode='P4551';
  end if;
  if not p_active then
    if exists(select 1 from public.company_shifts s
      join public.shift_attendance a on a.shift_id=s.id
      where s.company_id=p_company and s.user_id=p_user and a.checked_out_at is null) then
      raise exception 'Nhân viên có ca đang chấm công; hãy chấm công ra trước'
        using errcode='P4552';
    end if;
    -- Future unclocked assignments are cancelled; the trigger notifies the Staff.
    delete from public.company_shifts s
      where s.company_id=p_company and s.user_id=p_user
        and s.starts_at > now()
        and not exists (select 1 from public.shift_attendance a where a.shift_id=s.id);
  end if;
  update public.company_members set is_active=p_active
    where company_id=p_company and user_id=p_user and role='staff';
end $$;
revoke all on function public.manager_set_staff_active(uuid,uuid,boolean) from public;
grant execute on function public.manager_set_staff_active(uuid,uuid,boolean) to authenticated;

-- Extra database guard: do not schedule inactive staff.
create or replace function public.enforce_staff_shift()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists (
    select 1 from public.company_members m
    where m.company_id=new.company_id and m.user_id=new.user_id
      and m.role='staff' and m.is_active
  ) then
    raise exception 'Chỉ được phân ca cho Staff đang hoạt động trong công ty'
      using errcode='P4541';
  end if;
  if exists (select 1 from public.account_restrictions r
    where r.user_id=new.user_id and r.disabled) then
    raise exception 'Không thể phân ca cho tài khoản đã bị vô hiệu hóa'
      using errcode='P4542';
  end if;
  return new;
end $$;
revoke all on function public.enforce_staff_shift() from public;

-- Staff with paused membership cannot initiate another check-in.
create or replace function public.clock_in_shift(p_shift uuid)
returns void language plpgsql security definer set search_path=public as $$
declare assignment public.company_shifts;
begin
  if not public.account_active()
    or coalesce(auth.jwt()->'app_metadata'->>'role','')='admin' then
    raise exception 'Tài khoản không có quyền chấm công' using errcode='P4520';
  end if;
  select * into assignment from public.company_shifts where id=p_shift for update;
  if assignment.id is null or assignment.user_id<>auth.uid()
    or not exists(select 1 from public.company_members cm
      where cm.company_id=assignment.company_id and cm.user_id=auth.uid()
        and cm.role='staff' and cm.is_active) then
    raise exception 'Chỉ Staff đang hoạt động và được phân ca mới được chấm công'
      using errcode='P4520';
  end if;
  if now() < assignment.starts_at - interval '1 hour'
     or now() > assignment.ends_at + interval '12 hours' then
    raise exception 'Chỉ chấm công từ 1 giờ trước ca đến 12 giờ sau khi ca kết thúc'
      using errcode='P4521';
  end if;
  if exists(select 1 from public.shift_attendance where shift_id=p_shift) then
    raise exception 'Ca này đã được chấm công trước đó' using errcode='P4522';
  end if;
  insert into public.shift_attendance(shift_id,company_id,user_id)
    values(assignment.id,assignment.company_id,auth.uid());
end $$;
revoke all on function public.clock_in_shift(uuid) from public;
grant execute on function public.clock_in_shift(uuid) to authenticated;

-- <<< END supabase/staff_lifecycle.sql

-- commit delegated to fresh-install transaction

-- ==================================================================
-- SOURCE: supabase/account_profile_upgrade.sql
-- ==================================================================
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

-- Ensure users that signed in BEFORE the fresh installation have a profile.
insert into public.profiles(id,email,full_name)
select id,email,coalesce(raw_user_meta_data->>'full_name',email)
from auth.users
on conflict (id) do nothing;

-- Manager location, cast and notifications extensions
-- Run after FULL_SETUP_FROM_SCRATCH.sql on new projects or on an existing Shiftly database.
alter table public.profiles add column if not exists active_location text;
grant update (active_location) on public.profiles to authenticated;
alter table public.company_shifts add column if not exists cast_vnd bigint not null default 0;
alter table public.company_shifts drop constraint if exists company_shifts_cast_vnd_check;
alter table public.company_shifts add constraint company_shifts_cast_vnd_check check (cast_vnd between 0 and 100000000);
-- Existing manager shift INSERT/UPDATE RLS policies remain in force.

-- Run after shift_notifications.sql and shift_attendance.sql.
-- Managers receive durable in-app notifications for attendance and join requests.
alter table public.shift_notifications drop constraint if exists shift_notifications_event_check;
alter table public.shift_notifications add constraint shift_notifications_event_check
  check (event in ('created','updated','cancelled','attendance_in','attendance_out','join_request','employment_changed','payroll_paid'));

create or replace function public.notify_manager_activity()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  manager_id uuid;
  shift_title text;
  staff_name text;
  event_name text;
  heading text;
  details text;
begin
  select m.user_id into manager_id from public.company_members m
    where m.company_id = new.company_id and m.role = 'manager' limit 1;
  if manager_id is null or manager_id = new.user_id then return new; end if;
  select coalesce(p.full_name, u.email, 'Nhân viên') into staff_name
    from auth.users u left join public.profiles p on p.id = u.id where u.id = new.user_id;
  if tg_table_name = 'shift_attendance' then
    if tg_op = 'INSERT' then
      event_name := 'attendance_in';
      heading := 'Nhân viên đã chấm công vào';
    elsif old.checked_out_at is null and new.checked_out_at is not null then
      event_name := 'attendance_out';
      heading := 'Nhân viên đã chấm công ra';
    else
      return new;
    end if;
    select s.title into shift_title from public.company_shifts s where s.id = new.shift_id;
    details := format('%s · %s · %s', staff_name, coalesce(shift_title,'Ca làm việc'),
      to_char(coalesce(new.checked_out_at,new.checked_in_at) at time zone 'Asia/Ho_Chi_Minh','DD/MM/YYYY HH24:MI'));
    insert into public.shift_notifications(user_id,company_id,shift_id,event,title,body)
      values(manager_id,new.company_id,new.shift_id,event_name,heading,details);
  elsif tg_table_name = 'company_join_requests' and new.status = 'pending'
      and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    insert into public.shift_notifications(user_id,company_id,shift_id,event,title,body)
      values(manager_id,new.company_id,null,'join_request','Có yêu cầu gia nhập công ty',
        format('%s vừa gửi yêu cầu tham gia công ty.',staff_name));
  end if;
  return new;
end $$;
revoke all on function public.notify_manager_activity() from public;
drop trigger if exists notify_manager_attendance on public.shift_attendance;
create trigger notify_manager_attendance
after insert or update of checked_out_at on public.shift_attendance
for each row execute function public.notify_manager_activity();
drop trigger if exists notify_manager_join_request on public.company_join_requests;
create trigger notify_manager_join_request
after insert or update of status on public.company_join_requests
for each row execute function public.notify_manager_activity();

-- Protect cast of any shift that has been clocked in.
-- Upgrade existing Shiftly database. Run in Supabase SQL Editor.
-- A checked-in shift's cast is immutable even through direct API calls.
create or replace function public.protect_clocked_shift()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.shift_attendance where shift_id=OLD.id) then
    if TG_OP='DELETE' then return OLD; end if;
    return NEW;
  end if;
  if TG_OP='DELETE' then
    raise exception 'Không thể hủy ca đã có chấm công' using errcode='P4510';
  end if;
  if (NEW.user_id,NEW.starts_at,NEW.ends_at)
     is distinct from (OLD.user_id,OLD.starts_at,OLD.ends_at) then
    raise exception 'Ca đã chấm công: không được thay nhân viên hoặc thời gian' using errcode='P4511';
  end if;
  if NEW.cast_vnd is distinct from OLD.cast_vnd then
    raise exception 'Ca đã chấm công: không được thay đổi cast / thù lao' using errcode='P4512';
  end if;
  return NEW;
end $$;
revoke all on function public.protect_clocked_shift() from public;

-- Multi-person shift assignment and cast-based monthly payroll
-- Atomic Manager edit of all members assigned to an identical job/time/location/cast.
-- Legacy data has one row per Staff, so matching attributes define the job group.
create or replace function public.manager_update_work_assignments(
  p_shift uuid, p_users uuid[], p_title text, p_location text,
  p_starts_at timestamptz, p_ends_at timestamptz, p_cast_vnd bigint
) returns void language plpgsql security definer set search_path=public as $$
declare
  original public.company_shifts;
  assignment public.company_shifts;
  selected_ids uuid[];
  prior_ids uuid[];
  target_id uuid;
begin
  select * into original from public.company_shifts where id=p_shift for update;
  if original.id is null then
    raise exception 'Không tìm thấy ca làm cần cập nhật' using errcode='P4560';
  end if;
  if not public.account_active()
    or coalesce(auth.jwt()->'app_metadata'->>'role','')='admin'
    or not exists(select 1 from public.company_members cm
      where cm.company_id=original.company_id and cm.user_id=auth.uid() and cm.role='manager') then
    raise exception 'Chỉ Manager được thay đổi phân công' using errcode='P4561';
  end if;
  select array_agg(distinct u) into selected_ids from unnest(p_users) as x(u) where u is not null;
  if selected_ids is null or cardinality(selected_ids)=0
    or nullif(btrim(p_title),'') is null or nullif(btrim(p_location),'') is null
    or p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at
    or p_ends_at>p_starts_at+interval '24 hours'
    or p_cast_vnd is null or p_cast_vnd < 0 or p_cast_vnd > 100000000 then
    raise exception 'Dữ liệu phân ca không hợp lệ' using errcode='P4562';
  end if;
  -- Protect the entire work group, including shifts already checked in.
  if exists (
    select 1 from public.company_shifts s
    join public.shift_attendance a on a.shift_id=s.id
    where s.company_id=original.company_id
      and s.title=original.title and coalesce(s.location,'')=coalesce(original.location,'')
      and s.starts_at=original.starts_at and s.ends_at=original.ends_at
      and s.cast_vnd=original.cast_vnd
      and (not (s.user_id=any(selected_ids))
        or s.starts_at<>p_starts_at or s.ends_at<>p_ends_at or s.cast_vnd<>p_cast_vnd)
  ) then
    raise exception 'Không thể bỏ nhân viên đã chấm công hoặc thay giờ/Cast' using errcode='P4512';
  end if;
  -- Lock matching assignments before the changes to avoid stale membership.
  perform 1 from public.company_shifts s
    where s.company_id=original.company_id
      and s.title=original.title and coalesce(s.location,'')=coalesce(original.location,'')
      and s.starts_at=original.starts_at and s.ends_at=original.ends_at
      and s.cast_vnd=original.cast_vnd
    for update;
  select array_agg(s.user_id) into prior_ids from public.company_shifts s
    where s.company_id=original.company_id
      and s.title=original.title and coalesce(s.location,'')=coalesce(original.location,'')
      and s.starts_at=original.starts_at and s.ends_at=original.ends_at
      and s.cast_vnd=original.cast_vnd;
  for assignment in
    select * from public.company_shifts s
    where s.company_id=original.company_id
      and s.title=original.title and coalesce(s.location,'')=coalesce(original.location,'')
      and s.starts_at=original.starts_at and s.ends_at=original.ends_at
      and s.cast_vnd=original.cast_vnd
  loop
    if assignment.user_id=any(selected_ids) then
      update public.company_shifts set title=btrim(p_title),location=btrim(p_location),
        starts_at=p_starts_at,ends_at=p_ends_at,cast_vnd=p_cast_vnd
        where id=assignment.id;
    else
      delete from public.company_shifts where id=assignment.id;
    end if;
  end loop;
  foreach target_id in array selected_ids loop
    if not (target_id=any(prior_ids)) then
      insert into public.company_shifts(company_id,user_id,title,location,starts_at,ends_at,cast_vnd)
      values (original.company_id,target_id,btrim(p_title),btrim(p_location),p_starts_at,p_ends_at,p_cast_vnd);
    end if;
  end loop;
end $$;
revoke all on function public.manager_update_work_assignments(uuid,uuid[],text,text,timestamptz,timestamptz,bigint) from public, anon;
grant execute on function public.manager_update_work_assignments(uuid,uuid[],text,text,timestamptz,timestamptz,bigint) to authenticated;
notify pgrst, 'reload schema';

-- Non-destructive upgrade: replace legacy per-show estimate with per-shift Cast
-- and a monthly allowance. Historic show_rate_vnd stays for compatibility but is ignored.
alter table public.member_compensation
  add column if not exists monthly_allowance_vnd numeric(14,0) not null default 0;
alter table public.member_compensation drop constraint if exists member_compensation_monthly_allowance_valid;
alter table public.member_compensation add constraint member_compensation_monthly_allowance_valid
  check (monthly_allowance_vnd >= 0);
alter table public.member_compensation alter column show_rate_vnd set default 0;

-- PostgreSQL requires DROP before changing an existing table-return signature.
-- Record expenses while an assigned Staff member's attendance is open.
alter table public.shift_attendance
  add column if not exists expenses jsonb not null default '[]'::jsonb,
  add column if not exists expense_total_vnd bigint not null default 0;

create or replace function public.add_shift_expense(p_shift uuid, p_id uuid, p_note text, p_amount bigint)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  entry public.shift_attendance;
  expense jsonb;
begin
  if p_id is null or p_note is null or char_length(btrim(p_note)) not between 1 and 160
     or p_amount is null or p_amount not between 1 and 100000000 then
    raise exception 'Chi phí phát sinh không hợp lệ' using errcode='P4532';
  end if;
  select a.* into entry from public.shift_attendance a
    where a.shift_id=p_shift and a.user_id=auth.uid()
      and public.account_active()
      and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin'
      and exists (
        select 1 from public.company_members m
        where m.company_id=a.company_id and m.user_id=a.user_id and m.role='staff'
      )
    for update;
  if not found then
    raise exception 'Bạn cần chấm công cho ca của mình trước khi nhập chi phí' using errcode='P4530';
  end if;
  expense := jsonb_build_object('id',p_id,'note',btrim(p_note),'amount_vnd',p_amount);
  if entry.expenses @> jsonb_build_array(expense) then
    return to_jsonb(entry);
  end if;
  if entry.checked_out_at is not null then
    raise exception 'Ca đã hoàn thành, không thể thêm chi phí' using errcode='P4531';
  end if;
  if entry.expenses @> jsonb_build_array(jsonb_build_object('id',p_id))
     or jsonb_array_length(entry.expenses) >= 100 then
    raise exception 'Khoản chi đã tồn tại hoặc đã đạt giới hạn 100 khoản' using errcode='P4532';
  end if;
  update public.shift_attendance a
    set expenses=a.expenses || jsonb_build_array(expense),
        expense_total_vnd=a.expense_total_vnd + p_amount
    where a.shift_id=p_shift
    returning a.* into entry;
  return to_jsonb(entry);
end $$;
revoke all on function public.add_shift_expense(uuid,uuid,text,bigint) from public, anon;
grant execute on function public.add_shift_expense(uuid,uuid,text,bigint) to authenticated;
notify pgrst, 'reload schema';

drop function if exists public.company_staff_summary(uuid,date);
create function public.company_staff_summary(p_company uuid,p_month date)
returns table (
  user_id uuid, full_name text, email text, employment_type text,
  monthly_base_vnd numeric, monthly_allowance_vnd numeric,
  scheduled_shifts bigint, completed_shifts bigint, worked_hours numeric,
  planned_cast_vnd numeric, cast_total_vnd numeric, estimated_total_vnd numeric
)
language plpgsql stable security definer set search_path=public as $$
declare first_day timestamptz; next_month timestamptz;
begin
  if p_month is null or not public.account_active()
    or coalesce(auth.jwt()->'app_metadata'->>'role','')='admin'
    or not exists (
      select 1 from public.company_members m where m.company_id=p_company
        and m.user_id=auth.uid() and m.role='manager'
    ) then
    raise exception 'Chỉ Manager của công ty được xem bảng công và lương'
      using errcode='P4543';
  end if;
  first_day := (date_trunc('month',p_month::timestamp) at time zone 'Asia/Ho_Chi_Minh');
  next_month := ((date_trunc('month',p_month::timestamp) + interval '1 month') at time zone 'Asia/Ho_Chi_Minh');
  return query
  select m.user_id,
    coalesce(u.raw_user_meta_data->>'full_name',u.email::text)::text,
    u.email::text,
    p.employment_type::text,
    p.monthly_base_vnd::numeric,
    p.monthly_allowance_vnd::numeric,
    count(s.id)::bigint,
    count(a.shift_id) filter (where a.checked_out_at is not null)::bigint,
    round(coalesce(sum(extract(epoch from (a.checked_out_at-a.checked_in_at))/3600.0)
      filter (where a.checked_out_at is not null),0)::numeric,2),
    coalesce(sum(s.cast_vnd),0)::numeric,
    coalesce(sum(s.cast_vnd + coalesce(a.expense_total_vnd,0)) filter (where a.checked_out_at is not null),0)::numeric,
    (coalesce(p.monthly_base_vnd,0) + p.monthly_allowance_vnd +
      coalesce(sum(s.cast_vnd + coalesce(a.expense_total_vnd,0)) filter (where a.checked_out_at is not null),0))::numeric
  from public.company_members m
    join auth.users u on u.id=m.user_id
    join public.member_compensation p on p.company_id=m.company_id and p.user_id=m.user_id
    left join public.company_shifts s on s.company_id=m.company_id and s.user_id=m.user_id
      and s.starts_at>=first_day and s.starts_at<next_month
    left join public.shift_attendance a on a.shift_id=s.id
  where m.company_id=p_company and m.role='staff'
  group by m.user_id,u.email,u.raw_user_meta_data,p.employment_type,
    p.monthly_base_vnd,p.monthly_allowance_vnd
  order by coalesce(u.raw_user_meta_data->>'full_name',u.email::text);
end $$;
revoke all on function public.company_staff_summary(uuid,date) from public, anon;
grant execute on function public.company_staff_summary(uuid,date) to authenticated;
notify pgrst, 'reload schema';

-- Admin account details use Auth for platform roles and memberships for company roles.
create or replace function public.admin_account_directory()
returns table (
  user_id uuid, email text, full_name text, disabled boolean, reason text,
  role text, age integer, hometown text, active_location text
)
language sql stable security definer set search_path = '' as $$
  select a.user_id, a.email, coalesce(nullif(btrim(p.full_name), ''), a.full_name),
         a.disabled, a.reason,
         case
           when u.raw_app_meta_data->>'role' = 'admin' then 'admin'
           when exists (
             select 1 from public.company_members m
             where m.user_id = a.user_id and m.role = 'manager'
           ) then 'manager'
           else 'staff'
         end,
         case when isfinite(details.birth_date) and details.birth_date <= details.today
           then extract(year from age(details.today, details.birth_date))::integer
         end,
         nullif(btrim(to_jsonb(p)->>'hometown'), ''),
         nullif(btrim(to_jsonb(p)->>'active_location'), '')
  from public.admin_list_accounts() a
  join auth.users u on u.id = a.user_id
  left join public.profiles p on p.id = a.user_id
  cross join lateral (
    select (to_jsonb(p)->>'birth_date')::date as birth_date,
           (now() at time zone 'Asia/Ho_Chi_Minh')::date as today
  ) details
  where (select auth.uid()) is not null
    and coalesce((select auth.jwt())->'app_metadata'->>'role', '') = 'admin'
    and public.account_active()
$$;
revoke all on function public.admin_account_directory() from public, anon;
grant execute on function public.admin_account_directory() to authenticated;
notify pgrst, 'reload schema';

-- Classify the accounts and colleagues a caller can already list.
-- Compensation remains private to each worker and the company's Manager.
create schema if not exists shiftly_private;
revoke all on schema shiftly_private from public, anon;
grant usage on schema shiftly_private to authenticated;

create or replace function shiftly_private.workspace_roles(p_company uuid)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  is_admin boolean := coalesce(auth.jwt()->'app_metadata'->>'role','') = 'admin';
begin
  if auth.uid() is null or not public.account_active() then return '{}'::jsonb; end if;

  if p_company is null and is_admin then
    return (
      select coalesce(jsonb_object_agg(a.user_id, case
        when u.raw_app_meta_data->>'role' = 'admin' then 'admin'
        when company_roles.is_manager then 'manager'
        when company_roles.is_official_staff then 'staff'
        else 'freelance'
      end), '{}'::jsonb)
      from public.admin_list_accounts() a
      join auth.users u on u.id = a.user_id
      left join (
        select m.user_id,
               bool_or(m.role = 'manager') as is_manager,
               bool_or(m.role = 'staff' and p.employment_type = 'employee') as is_official_staff
        from public.company_members m
        left join public.member_compensation p using (company_id, user_id)
        group by m.user_id
      ) company_roles on company_roles.user_id = a.user_id
    );
  end if;

  if p_company is not null and not is_admin and public.is_company_member(p_company) then
    return (
      select coalesce(jsonb_object_agg(m.user_id, case
        when m.role = 'manager' then 'manager'
        when p.employment_type = 'employee' then 'staff'
        else 'freelance'
      end), '{}'::jsonb)
      from public.company_members m
      left join public.member_compensation p using (company_id, user_id)
      where m.company_id = p_company
    );
  end if;

  return '{}'::jsonb;
end
$$;
revoke all on function shiftly_private.workspace_roles(uuid) from public, anon;
grant execute on function shiftly_private.workspace_roles(uuid) to authenticated;

create or replace function public.workspace_roles(p_company uuid default null)
returns jsonb
language sql stable security invoker set search_path = '' as $$
  select shiftly_private.workspace_roles(p_company)
$$;
revoke all on function public.workspace_roles(uuid) from public, anon;
grant execute on function public.workspace_roles(uuid) to authenticated;
notify pgrst, 'reload schema';

-- Run after staff_business.sql and manager_notifications.sql.
-- Role notices are written atomically with the Manager's compensation change.
alter table public.shift_notifications drop constraint if exists shift_notifications_event_check;
alter table public.shift_notifications add constraint shift_notifications_event_check
  check (event in ('created','updated','cancelled','attendance_in','attendance_out','join_request','employment_changed','payroll_paid'));

create schema if not exists shiftly_private;

create or replace function shiftly_private.notify_employment_change()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  previous_role text;
  next_role text;
begin
  if tg_op = 'UPDATE' then
    if old.employment_type is not distinct from new.employment_type then return new; end if;
    previous_role := case old.employment_type when 'employee' then 'STAFF' else 'Freelance' end;
  else
    if new.employment_type <> 'employee' then return new; end if;
    previous_role := 'Freelance';
  end if;
  next_role := case new.employment_type when 'employee' then 'STAFF' else 'Freelance' end;

  insert into public.shift_notifications(user_id,company_id,event,title,body)
  select new.user_id, new.company_id, 'employment_changed',
         format('Bạn đã được chuyển thành %s', next_role),
         format('Manager của %s đã chuyển vai trò của bạn từ %s sang %s.', c.name, previous_role, next_role)
  from public.company_members m
  join public.companies c on c.id = m.company_id
  where m.company_id = new.company_id and m.user_id = new.user_id and m.role = 'staff';
  return new;
end
$$;
revoke all on function shiftly_private.notify_employment_change() from public, anon, authenticated;

drop trigger if exists notify_staff_employment_change on public.member_compensation;
create trigger notify_staff_employment_change
  after insert or update of employment_type on public.member_compensation
  for each row execute function shiftly_private.notify_employment_change();

notify pgrst, 'reload schema';

-- >>> FILE: supabase/payroll_settlements.sql
-- Additive payroll ledger. Run after the attendance / Cast / staff-role upgrades.
-- Prepared quotes do not count as payments. Paid snapshots and their evidence are immutable.
create schema if not exists shiftly_private;
revoke all on schema shiftly_private from public, anon;
grant usage on schema shiftly_private to authenticated;

alter table public.member_compensation
  add column if not exists monthly_allowance_vnd numeric(14,0) not null default 0;
alter table public.member_compensation drop constraint if exists member_compensation_monthly_allowance_valid;
alter table public.member_compensation add constraint member_compensation_monthly_allowance_valid check (monthly_allowance_vnd>=0);

create table if not exists public.payroll_payments (
  id uuid primary key,
  company_id uuid not null references public.companies(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  pay_month date not null check (pay_month = date_trunc('month',pay_month)::date),
  status text not null default 'prepared' check (status in ('prepared','paid','cancelled')),
  amount_vnd bigint not null check (amount_vnd between 1 and 9007199254740991),
  paid_before_vnd bigint not null check (paid_before_vnd >= 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot)='object'),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  receipt_path text unique,
  transfer_date date,
  note text not null default '' check (char_length(note)<=500),
  paid_by uuid references auth.users(id) on delete restrict,
  paid_at timestamptz,
  check ((status='paid' and receipt_path is not null and transfer_date is not null
            and paid_by is not null and paid_at is not null)
      or (status in ('prepared','cancelled') and receipt_path is null
            and transfer_date is null and paid_by is null and paid_at is null))
);
create unique index if not exists payroll_one_prepared_per_person
  on public.payroll_payments(company_id,user_id,pay_month) where status='prepared';
create index if not exists payroll_company_month_history
  on public.payroll_payments(company_id,pay_month,paid_at desc,id) where status='paid';
create index if not exists payroll_person_history
  on public.payroll_payments(user_id,paid_at desc,id) where status='paid';
create index if not exists payroll_creator_idx on public.payroll_payments(created_by);
create index if not exists payroll_payer_idx on public.payroll_payments(paid_by);

create table if not exists public.payroll_overtime_allowances (
  shift_id uuid primary key references public.company_shifts(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  pay_month date not null check (pay_month=date_trunc('month',pay_month)::date),
  overtime_ms bigint not null check (overtime_ms>0),
  allowance_vnd bigint not null check (allowance_vnd between 0 and 1000000000),
  note text not null default '' check (char_length(note)<=500),
  request_id uuid not null,
  approved_by uuid not null references auth.users(id) on delete restrict,
  approved_at timestamptz not null default now(),
  locked_by_payment_id uuid references public.payroll_payments(id) on delete restrict,
  check (allowance_vnd>0 or char_length(btrim(note))>=3)
);
create index if not exists overtime_company_month_person
  on public.payroll_overtime_allowances(company_id,pay_month,user_id);
create index if not exists overtime_person_idx on public.payroll_overtime_allowances(user_id);
create index if not exists overtime_approver_idx on public.payroll_overtime_allowances(approved_by);
create index if not exists overtime_payment_idx on public.payroll_overtime_allowances(locked_by_payment_id);
create index if not exists payroll_shifts_company_month
  on public.company_shifts(company_id,starts_at,user_id);

alter table public.payroll_payments enable row level security;
alter table public.payroll_overtime_allowances enable row level security;
revoke all on public.payroll_payments,public.payroll_overtime_allowances from public,anon,authenticated;
grant select on public.payroll_payments,public.payroll_overtime_allowances to authenticated;

create or replace function shiftly_private.payroll_today()
returns date language sql stable security invoker set search_path='' as $$
  select (now() at time zone 'Asia/Ho_Chi_Minh')::date
$$;
revoke all on function shiftly_private.payroll_today() from public,anon,authenticated;

create or replace function shiftly_private.payroll_actor_active()
returns boolean language sql stable security invoker set search_path='' as $$
  select auth.uid() is not null and public.account_active()
    and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
$$;
revoke all on function shiftly_private.payroll_actor_active() from public,anon,authenticated;

create or replace function shiftly_private.payroll_manager(p_company uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select shiftly_private.payroll_actor_active() and exists (
    select 1 from public.company_members m
      where m.company_id=p_company and m.user_id=auth.uid() and m.role='manager' and m.is_active
  )
$$;
revoke all on function shiftly_private.payroll_manager(uuid) from public,anon;
grant execute on function shiftly_private.payroll_manager(uuid) to authenticated;

create or replace function shiftly_private.payroll_readable(p_company uuid,p_user uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select shiftly_private.payroll_actor_active()
    and (p_user=auth.uid() or shiftly_private.payroll_manager(p_company))
$$;
revoke all on function shiftly_private.payroll_readable(uuid,uuid) from public,anon;
grant execute on function shiftly_private.payroll_readable(uuid,uuid) to authenticated;

drop policy if exists "payroll snapshots visible to recipient and manager" on public.payroll_payments;
create policy "payroll snapshots visible to recipient and manager" on public.payroll_payments
  for select to authenticated using (
    shiftly_private.payroll_readable(company_id,user_id)
      and (status='paid' or shiftly_private.payroll_manager(company_id))
  );
drop policy if exists "overtime visible to recipient and manager" on public.payroll_overtime_allowances;
create policy "overtime visible to recipient and manager" on public.payroll_overtime_allowances
  for select to authenticated using (shiftly_private.payroll_readable(company_id,user_id));

create or replace function shiftly_private.protect_payroll_payment()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.status='paid' then
    raise exception 'Khoản đã thanh toán được giữ nguyên để đối chiếu' using errcode='P4555';
  end if;
  if tg_op='DELETE' then return old; end if;
  if old.status<>'prepared' or new.status not in ('paid','cancelled')
    or (new.id,new.company_id,new.user_id,new.pay_month,new.amount_vnd,new.paid_before_vnd,
        new.snapshot,new.created_by,new.created_at)
      is distinct from
       (old.id,old.company_id,old.user_id,old.pay_month,old.amount_vnd,old.paid_before_vnd,
        old.snapshot,old.created_by,old.created_at) then
    raise exception 'Không được thay đổi số tiền hoặc người nhận của bảng đã chốt' using errcode='P4555';
  end if;
  return new;
end
$$;
revoke all on function shiftly_private.protect_payroll_payment() from public,anon,authenticated;
drop trigger if exists payroll_payment_immutable on public.payroll_payments;
create trigger payroll_payment_immutable before update or delete on public.payroll_payments
  for each row execute function shiftly_private.protect_payroll_payment();

create or replace function shiftly_private.protect_overtime_allowance()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.locked_by_payment_id is not null and exists (
    select 1 from public.payroll_payments p
      where p.id=old.locked_by_payment_id and p.status in ('prepared','paid')
  ) then
    raise exception 'Phụ cấp này đã nằm trong bảng chốt, không thể sửa' using errcode='P4555';
  end if;
  if tg_op='DELETE' then return old; end if;
  if (new.shift_id,new.company_id,new.user_id,new.pay_month,new.overtime_ms)
      is distinct from (old.shift_id,old.company_id,old.user_id,old.pay_month,old.overtime_ms) then
    raise exception 'Thông tin ca quá giờ được giữ nguyên' using errcode='P4555';
  end if;
  return new;
end
$$;
revoke all on function shiftly_private.protect_overtime_allowance() from public,anon,authenticated;
drop trigger if exists payroll_overtime_immutable on public.payroll_overtime_allowances;
create trigger payroll_overtime_immutable before update or delete on public.payroll_overtime_allowances
  for each row execute function shiftly_private.protect_overtime_allowance();

-- Internal set-based calculation. No direct client EXECUTE grant.
create or replace function shiftly_private.payroll_rows(p_company uuid,p_month date,p_user uuid default null)
returns setof jsonb language sql stable security invoker set search_path='' as $$
  with bounds as (
    select p_month::timestamp at time zone 'Asia/Ho_Chi_Minh' as start_at,
      (p_month::timestamp+interval '1 month') at time zone 'Asia/Ho_Chi_Minh' as end_at
  ), source_shifts as (
    select s.*,a.checked_in_at,a.checked_out_at,coalesce(a.expense_total_vnd,0) as expenses_vnd,
      case when a.checked_out_at is null then 0 else
        greatest(0,extract(epoch from (a.checked_out_at-greatest(s.ends_at,a.checked_in_at)))*1000)::bigint
      end as overtime_ms
    from public.company_shifts s cross join bounds b
      left join public.shift_attendance a on a.shift_id=s.id
    where s.company_id=p_company and s.starts_at>=b.start_at and s.starts_at<b.end_at
      and (p_user is null or s.user_id=p_user)
  ), target_ids as (
    select m.user_id from public.company_members m cross join bounds b
      where m.company_id=p_company and m.role='staff' and (p_user is null or m.user_id=p_user)
        and (m.created_at<b.end_at or exists(select 1 from source_shifts s where s.user_id=m.user_id))
    union
    select s.user_id from source_shifts s
    union
    select p.user_id from public.payroll_payments p where p.company_id=p_company
      and p.pay_month=p_month and p.status in ('prepared','paid') and (p_user is null or p.user_id=p_user)
  ), shift_totals as (
    select s.user_id,count(*) as scheduled_shifts,
      count(*) filter(where s.checked_out_at is not null) as completed_shifts,
      coalesce(sum(s.cast_vnd),0) as planned_cast_vnd,
      coalesce(sum(s.cast_vnd) filter(where s.checked_out_at is not null),0) as shift_cast_vnd,
      coalesce(sum(s.expenses_vnd) filter(where s.checked_out_at is not null),0) as expense_vnd,
      coalesce(sum(greatest(0,extract(epoch from(s.checked_out_at-s.checked_in_at))*1000))
        filter(where s.checked_out_at is not null),0)::bigint as worked_ms,
      coalesce(sum(greatest(0,extract(epoch from(s.ends_at-s.starts_at))*1000))
        filter(where s.checked_out_at is not null),0)::bigint as completed_shift_ms,
      coalesce(sum(s.overtime_ms),0)::bigint as overtime_ms,
      count(*) filter(where s.overtime_ms>0 and o.shift_id is null) as unreviewed_overtime,
      coalesce(sum(o.allowance_vnd),0) as overtime_allowance_vnd
    from source_shifts s left join public.payroll_overtime_allowances o on o.shift_id=s.id
    group by s.user_id
  ), paid_totals as (
    select p.user_id,sum(p.amount_vnd) as paid_vnd,count(*) as payment_count,max(p.paid_at) as last_paid_at
    from public.payroll_payments p where p.company_id=p_company and p.pay_month=p_month and p.status='paid'
      and (p_user is null or p.user_id=p_user) group by p.user_id
  ), fixed as (
    select distinct on(p.user_id) p.user_id,p.snapshot,p.status
    from public.payroll_payments p where p.company_id=p_company and p.pay_month=p_month
      and p.status in ('prepared','paid') and (p_user is null or p.user_id=p_user)
    order by p.user_id,(p.status='paid') desc,p.created_at,p.id
  ), pending as (
    select p.user_id,p.id,p.amount_vnd from public.payroll_payments p
      where p.company_id=p_company and p.pay_month=p_month and p.status='prepared'
  ), calculated as (
    select t.user_id,coalesce(nullif(btrim(pr.full_name),''),u.raw_user_meta_data->>'full_name',
        f.snapshot->>'full_name',u.email::text,'Nhân viên') as full_name,
      coalesce(u.email::text,f.snapshot->>'email','') as email,c.name as company_name,
      coalesce(f.snapshot->>'employment_type',mc.employment_type,'freelancer') as employment_type,
      coalesce((f.snapshot->>'monthly_base_vnd')::numeric,mc.monthly_base_vnd,0) as monthly_base_vnd,
      coalesce((f.snapshot->>'monthly_allowance_vnd')::numeric,mc.monthly_allowance_vnd,0) as monthly_allowance_vnd,
      coalesce(s.scheduled_shifts,0) as scheduled_shifts,coalesce(s.completed_shifts,0) as completed_shifts,
      coalesce(s.planned_cast_vnd,0) as planned_cast_vnd,coalesce(s.shift_cast_vnd,0) as shift_cast_vnd,
      coalesce(s.expense_vnd,0) as expense_vnd,coalesce(s.worked_ms,0) as worked_ms,
      coalesce(s.completed_shift_ms,0) as completed_shift_ms,
      coalesce(s.overtime_ms,0) as overtime_ms,coalesce(s.unreviewed_overtime,0) as unreviewed_overtime,
      coalesce(s.overtime_allowance_vnd,0) as overtime_allowance_vnd,
      coalesce(p.paid_vnd,0) as paid_vnd,coalesce(p.payment_count,0) as payment_count,p.last_paid_at,
      q.id as pending_payment_id,q.amount_vnd as pending_amount_vnd,f.user_id is not null as snapshotted
    from target_ids t join public.companies c on c.id=p_company
      left join auth.users u on u.id=t.user_id left join public.profiles pr on pr.id=t.user_id
      left join public.member_compensation mc on mc.company_id=p_company and mc.user_id=t.user_id
      left join fixed f on f.user_id=t.user_id left join shift_totals s on s.user_id=t.user_id
      left join paid_totals p on p.user_id=t.user_id left join pending q on q.user_id=t.user_id
  ), money as (
    select c.*,(c.monthly_base_vnd+c.monthly_allowance_vnd+c.shift_cast_vnd+c.expense_vnd+c.overtime_allowance_vnd) as earned_vnd
    from calculated c
  )
  select to_jsonb(m)||jsonb_build_object('company_id',p_company,'pay_month',p_month,
    'remaining_vnd',greatest(0,m.earned_vnd-m.paid_vnd),
    'pay_from',(p_month+interval '1 month')::date+4,
    'pay_until',(p_month+interval '1 month')::date+9,
    'server_today',shiftly_private.payroll_today())
  from money m order by m.full_name,m.user_id
$$;
revoke all on function shiftly_private.payroll_rows(uuid,date,uuid) from public,anon,authenticated;

create or replace function shiftly_private.payroll_month_summary(p_company uuid,p_month date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare own_user uuid;
begin
  if not shiftly_private.payroll_actor_active() or p_company is null then
    raise exception 'Không có quyền xem bảng lương' using errcode='P4550';
  end if;
  if p_month is null or p_month<>date_trunc('month',p_month)::date
      or p_month<'2000-01-01' or p_month>'2100-12-01' then
    raise exception 'Kỳ lương không hợp lệ' using errcode='P4551';
  end if;
  if not shiftly_private.payroll_manager(p_company) then
    own_user:=auth.uid();
    if not exists(select 1 from public.company_members m where m.company_id=p_company and m.user_id=own_user)
      and not exists(select 1 from public.payroll_payments p where p.company_id=p_company and p.user_id=own_user and p.status='paid') then
      raise exception 'Không có quyền xem kỳ lương của công ty này' using errcode='P4550';
    end if;
  end if;
  return (select coalesce(jsonb_agg(r),'[]'::jsonb) from shiftly_private.payroll_rows(p_company,p_month,own_user) r);
end
$$;
revoke all on function shiftly_private.payroll_month_summary(uuid,date) from public,anon;
grant execute on function shiftly_private.payroll_month_summary(uuid,date) to authenticated;
create or replace function public.payroll_month_summary(p_company uuid,p_month date)
returns jsonb language sql stable security invoker set search_path='' as $$
  select shiftly_private.payroll_month_summary(p_company,p_month)
$$;
revoke all on function public.payroll_month_summary(uuid,date) from public,anon;
grant execute on function public.payroll_month_summary(uuid,date) to authenticated;

create or replace function shiftly_private.payroll_overtime(p_company uuid,p_month date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare only_user uuid;
begin
  perform shiftly_private.payroll_month_summary(p_company,p_month);
  if not shiftly_private.payroll_manager(p_company) then only_user:=auth.uid(); end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.full_name,t.starts_at,t.shift_id),'[]'::jsonb)
    from (
      select s.id as shift_id,s.user_id,
        coalesce(nullif(btrim(pr.full_name),''),u.raw_user_meta_data->>'full_name',u.email::text) as full_name,
        s.title,s.location,s.starts_at,s.ends_at as planned_ends_at,a.checked_in_at,a.checked_out_at,
        greatest(0,extract(epoch from(a.checked_out_at-greatest(a.checked_in_at,s.ends_at)))*1000)::bigint as overtime_ms,
        o.allowance_vnd,o.note,o.approved_at,o.locked_by_payment_id,p.status as locked_status
      from public.company_shifts s join public.shift_attendance a on a.shift_id=s.id
        join auth.users u on u.id=s.user_id left join public.profiles pr on pr.id=s.user_id
        left join public.payroll_overtime_allowances o on o.shift_id=s.id
        left join public.payroll_payments p on p.id=o.locked_by_payment_id
      where s.company_id=p_company and (only_user is null or s.user_id=only_user)
        and s.starts_at>=p_month::timestamp at time zone 'Asia/Ho_Chi_Minh'
        and s.starts_at<(p_month::timestamp+interval '1 month') at time zone 'Asia/Ho_Chi_Minh'
        and a.checked_out_at>greatest(a.checked_in_at,s.ends_at)
    ) t
  );
end
$$;
revoke all on function shiftly_private.payroll_overtime(uuid,date) from public,anon;
grant execute on function shiftly_private.payroll_overtime(uuid,date) to authenticated;
create or replace function public.payroll_overtime(p_company uuid,p_month date)
returns jsonb language sql stable security invoker set search_path='' as $$
  select shiftly_private.payroll_overtime(p_company,p_month)
$$;
revoke all on function public.payroll_overtime(uuid,date) from public,anon;
grant execute on function public.payroll_overtime(uuid,date) to authenticated;

create or replace function shiftly_private.approve_overtime_allowance(
  p_shift uuid,p_amount bigint,p_note text,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s record; existing public.payroll_overtime_allowances; period date; duration bigint;
begin
  select cs.*,a.checked_in_at,a.checked_out_at into s from public.company_shifts cs
    join public.shift_attendance a on a.shift_id=cs.id where cs.id=p_shift;
  if not found or not shiftly_private.payroll_manager(s.company_id) then
    raise exception 'Chỉ Manager của công ty được duyệt phụ cấp' using errcode='P4550';
  end if;
  period:=date_trunc('month',s.starts_at at time zone 'Asia/Ho_Chi_Minh')::date;
  perform pg_advisory_xact_lock(hashtextextended(s.company_id::text||s.user_id::text||period::text,0));
  duration:=greatest(0,extract(epoch from(s.checked_out_at-greatest(s.checked_in_at,s.ends_at)))*1000)::bigint;
  if s.checked_out_at is null or duration<=0 then
    raise exception 'Ca chưa hoàn tất hoặc không có thời gian quá giờ' using errcode='P4554';
  end if;
  if p_request is null or p_amount is null or p_amount not between 0 and 1000000000
    or char_length(coalesce(p_note,''))>500
    or (p_amount=0 and char_length(btrim(coalesce(p_note,'')))<3) then
    raise exception 'Nhập phụ cấp hợp lệ; nếu không bù tiền cần ghi rõ lý do' using errcode='P4558';
  end if;
  select * into existing from public.payroll_overtime_allowances where shift_id=p_shift for update;
  if found and existing.request_id=p_request then
    if existing.allowance_vnd<>p_amount or existing.note<>btrim(coalesce(p_note,'')) then
      raise exception 'Mã yêu cầu đã được sử dụng' using errcode='P4558';
    end if;
    return to_jsonb(existing);
  end if;
  if existing.locked_by_payment_id is not null and exists(select 1 from public.payroll_payments p
      where p.id=existing.locked_by_payment_id and p.status in ('prepared','paid')) then
    raise exception 'Phụ cấp đã chốt; chỉ bảng chưa trả mới được hủy để duyệt lại' using errcode='P4555';
  end if;
  insert into public.payroll_overtime_allowances
    (shift_id,company_id,user_id,pay_month,overtime_ms,allowance_vnd,note,request_id,approved_by)
  values(p_shift,s.company_id,s.user_id,period,duration,p_amount,btrim(coalesce(p_note,'')),p_request,auth.uid())
  on conflict(shift_id) do update set allowance_vnd=excluded.allowance_vnd,note=excluded.note,
    request_id=excluded.request_id,approved_by=excluded.approved_by,approved_at=now(),locked_by_payment_id=null
  returning * into existing;
  return to_jsonb(existing);
end
$$;
revoke all on function shiftly_private.approve_overtime_allowance(uuid,bigint,text,uuid) from public,anon;
grant execute on function shiftly_private.approve_overtime_allowance(uuid,bigint,text,uuid) to authenticated;
create or replace function public.approve_overtime_allowance(p_shift uuid,p_amount bigint,p_note text,p_request uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select shiftly_private.approve_overtime_allowance(p_shift,p_amount,p_note,p_request)
$$;
revoke all on function public.approve_overtime_allowance(uuid,bigint,text,uuid) from public,anon;
grant execute on function public.approve_overtime_allowance(uuid,bigint,text,uuid) to authenticated;

create or replace function shiftly_private.prepare_payroll_payment(p_company uuid,p_user uuid,p_month date,p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare summary jsonb; payment public.payroll_payments; amount numeric; shifts_snapshot jsonb;
begin
  if not shiftly_private.payroll_manager(p_company) then
    raise exception 'Chỉ Manager của công ty được chốt lương' using errcode='P4550';
  end if;
  if p_id is null or p_user is null or p_month is null or p_month<>date_trunc('month',p_month)::date
      or p_month<'2000-01-01' or p_month>'2100-12-01' then
    raise exception 'Thông tin kỳ lương không hợp lệ' using errcode='P4551';
  end if;
  if shiftly_private.payroll_today()<(p_month+interval '1 month')::date+4 then
    raise exception 'Kỳ này được trả từ ngày 5 tháng kế tiếp' using errcode='P4553';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company::text||p_user::text||p_month::text,0));
  select * into payment from public.payroll_payments where id=p_id;
  if found then
    if (payment.company_id,payment.user_id,payment.pay_month) is distinct from(p_company,p_user,p_month) then
      raise exception 'Mã chốt lương đã được sử dụng' using errcode='P4555';
    end if;
    if payment.status='cancelled' then raise exception 'Bảng chốt đã hủy, hãy mở lại bảng mới' using errcode='P4555'; end if;
    return to_jsonb(payment);
  end if;
  select * into payment from public.payroll_payments where company_id=p_company and user_id=p_user
    and pay_month=p_month and status='prepared';
  if found then return to_jsonb(payment); end if;
  select r into summary from shiftly_private.payroll_rows(p_company,p_month,p_user) r;
  if summary is null then raise exception 'Nhân viên không có dữ liệu trong kỳ lương' using errcode='P4559'; end if;
  if (summary->>'unreviewed_overtime')::bigint>0 then
    raise exception 'Hãy duyệt phụ cấp của các ca quá giờ trước khi chốt lương' using errcode='P4554';
  end if;
  amount:=(summary->>'remaining_vnd')::numeric;
  if amount is null or amount<=0 then raise exception 'Kỳ này không còn tiền cần thanh toán' using errcode='P4552'; end if;
  if amount>9007199254740991 or (summary->>'earned_vnd')::numeric>9007199254740991
    or (summary->>'paid_vnd')::numeric>9007199254740991 then
    raise exception 'Số tiền vượt giới hạn được hỗ trợ' using errcode='P4558';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('shift_id',s.id,'title',s.title,'location',s.location,
    'starts_at',s.starts_at,'planned_ends_at',s.ends_at,'checked_in_at',a.checked_in_at,'checked_out_at',a.checked_out_at,
    'cast_vnd',s.cast_vnd,'expense_vnd',a.expense_total_vnd,'overtime_allowance_vnd',coalesce(o.allowance_vnd,0))
    order by s.starts_at,s.id),'[]'::jsonb) into shifts_snapshot
  from public.company_shifts s join public.shift_attendance a on a.shift_id=s.id
    left join public.payroll_overtime_allowances o on o.shift_id=s.id
  where s.company_id=p_company and s.user_id=p_user and a.checked_out_at is not null
    and s.starts_at>=p_month::timestamp at time zone 'Asia/Ho_Chi_Minh'
    and s.starts_at<(p_month::timestamp+interval '1 month') at time zone 'Asia/Ho_Chi_Minh';
  summary:=summary||jsonb_build_object('shifts',shifts_snapshot);
  insert into public.payroll_payments(id,company_id,user_id,pay_month,amount_vnd,paid_before_vnd,snapshot,created_by)
    values(p_id,p_company,p_user,p_month,amount::bigint,(summary->>'paid_vnd')::bigint,summary,auth.uid())
    returning * into payment;
  update public.payroll_overtime_allowances o set locked_by_payment_id=p_id
    where o.company_id=p_company and o.user_id=p_user and o.pay_month=p_month
      and (o.locked_by_payment_id is null or exists(select 1 from public.payroll_payments p
        where p.id=o.locked_by_payment_id and p.status='cancelled'));
  return to_jsonb(payment);
end
$$;
revoke all on function shiftly_private.prepare_payroll_payment(uuid,uuid,date,uuid) from public,anon;
grant execute on function shiftly_private.prepare_payroll_payment(uuid,uuid,date,uuid) to authenticated;
create or replace function public.prepare_payroll_payment(p_company uuid,p_user uuid,p_month date,p_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select shiftly_private.prepare_payroll_payment(p_company,p_user,p_month,p_id)
$$;
revoke all on function public.prepare_payroll_payment(uuid,uuid,date,uuid) from public,anon;
grant execute on function public.prepare_payroll_payment(uuid,uuid,date,uuid) to authenticated;

create or replace function shiftly_private.cancel_payroll_payment(p_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare payment public.payroll_payments;
begin
  select * into payment from public.payroll_payments where id=p_id;
  if not found or not shiftly_private.payroll_manager(payment.company_id) then
    raise exception 'Không có quyền thay đổi bảng chốt này' using errcode='P4550';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(payment.company_id::text||payment.user_id::text||payment.pay_month::text,0));
  select * into payment from public.payroll_payments where id=p_id for update;
  if payment.status='cancelled' then return; end if;
  if payment.status<>'prepared' then raise exception 'Khoản đã thanh toán không được hủy' using errcode='P4555'; end if;
  update public.payroll_payments set status='cancelled' where id=p_id;
  update public.payroll_overtime_allowances set locked_by_payment_id=null where locked_by_payment_id=p_id;
end
$$;
revoke all on function shiftly_private.cancel_payroll_payment(uuid) from public,anon;
grant execute on function shiftly_private.cancel_payroll_payment(uuid) to authenticated;
create or replace function public.cancel_payroll_payment(p_id uuid)
returns void language sql security invoker set search_path='' as $$ select shiftly_private.cancel_payroll_payment(p_id) $$;
revoke all on function public.cancel_payroll_payment(uuid) from public,anon;
grant execute on function public.cancel_payroll_payment(uuid) to authenticated;

-- Storage paths: company UUID / recipient UUID / payment UUID / image UUID.ext.
create or replace function shiftly_private.payroll_receipt_quote(p_name text)
returns uuid language plpgsql immutable security invoker set search_path='' as $$
begin
  if p_name !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$' then return null; end if;
  begin return split_part(p_name,'/',3)::uuid; exception when invalid_text_representation then return null; end;
end
$$;
revoke all on function shiftly_private.payroll_receipt_quote(text) from public,anon,authenticated;

create or replace function shiftly_private.payroll_receipt_access(p_name text,p_operation text)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare payment public.payroll_payments; payment_id uuid;
begin
  if not shiftly_private.payroll_actor_active() then return false; end if;
  payment_id:=shiftly_private.payroll_receipt_quote(p_name);
  if payment_id is null then return false; end if;
  select * into payment from public.payroll_payments where id=payment_id;
  if not found or split_part(p_name,'/',1)<>payment.company_id::text
      or split_part(p_name,'/',2)<>payment.user_id::text then return false; end if;
  if p_operation='read' and payment.status='paid' and payment.receipt_path=p_name then
    return shiftly_private.payroll_readable(payment.company_id,payment.user_id);
  end if;
  if not shiftly_private.payroll_manager(payment.company_id) then return false; end if;
  if p_operation='upload' then return payment.status='prepared'; end if;
  if p_operation='delete' then return payment.status<>'paid' or payment.receipt_path<>p_name; end if;
  return p_operation='read' and payment.status in ('prepared','cancelled');
end
$$;
revoke all on function shiftly_private.payroll_receipt_access(text,text) from public,anon;
grant execute on function shiftly_private.payroll_receipt_access(text,text) to authenticated;

-- Financial evidence must never inherit permissive policies from unrelated buckets.
do $storage$
begin
  if to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null then
    insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
    values('payroll-receipts','payroll-receipts',false,8388608,array['image/jpeg','image/png','image/webp'])
    on conflict(id) do update set public=false,file_size_limit=8388608,
      allowed_mime_types=array['image/jpeg','image/png','image/webp'];
    execute 'drop policy if exists "payroll receipts read" on storage.objects';
    execute 'create policy "payroll receipts read" on storage.objects for select to authenticated using (bucket_id=''payroll-receipts'' and shiftly_private.payroll_receipt_access(name,''read''))';
    execute 'drop policy if exists "payroll receipts upload" on storage.objects';
    execute 'create policy "payroll receipts upload" on storage.objects for insert to authenticated with check (bucket_id=''payroll-receipts'' and shiftly_private.payroll_receipt_access(name,''upload''))';
    execute 'drop policy if exists "payroll receipts cleanup" on storage.objects';
    execute 'create policy "payroll receipts cleanup" on storage.objects for delete to authenticated using (bucket_id=''payroll-receipts'' and shiftly_private.payroll_receipt_access(name,''delete''))';
    execute 'drop policy if exists "payroll receipts restrictive read" on storage.objects';
    execute 'create policy "payroll receipts restrictive read" on storage.objects as restrictive for select to authenticated using (bucket_id<>''payroll-receipts'' or shiftly_private.payroll_receipt_access(name,''read''))';
    execute 'drop policy if exists "payroll receipts restrictive upload" on storage.objects';
    execute 'create policy "payroll receipts restrictive upload" on storage.objects as restrictive for insert to authenticated with check (bucket_id<>''payroll-receipts'' or shiftly_private.payroll_receipt_access(name,''upload''))';
    execute 'drop policy if exists "payroll receipts no overwrite" on storage.objects';
    execute 'create policy "payroll receipts no overwrite" on storage.objects as restrictive for update to public using (bucket_id<>''payroll-receipts'') with check (bucket_id<>''payroll-receipts'')';
    execute 'drop policy if exists "payroll receipts restrictive cleanup" on storage.objects';
    execute 'create policy "payroll receipts restrictive cleanup" on storage.objects as restrictive for delete to authenticated using (bucket_id<>''payroll-receipts'' or shiftly_private.payroll_receipt_access(name,''delete''))';
    execute 'drop policy if exists "payroll receipts anonymous denied" on storage.objects';
    execute 'create policy "payroll receipts anonymous denied" on storage.objects as restrictive for all to anon using (bucket_id<>''payroll-receipts'') with check (bucket_id<>''payroll-receipts'')';
  end if;
end
$storage$;

alter table public.shift_notifications add column if not exists payroll_payment_id uuid
  references public.payroll_payments(id) on delete restrict;
create index if not exists payroll_notification_payment_idx on public.shift_notifications(payroll_payment_id)
  where payroll_payment_id is not null;
alter table public.shift_notifications drop constraint if exists shift_notifications_event_check;
alter table public.shift_notifications add constraint shift_notifications_event_check check
  (event in ('created','updated','cancelled','attendance_in','attendance_out','join_request','employment_changed','payroll_paid'));

create or replace function shiftly_private.finalize_payroll_payment(
  p_id uuid,p_receipt_path text,p_transfer_date date,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare payment public.payroll_payments; total_paid numeric; proof record; today date:=shiftly_private.payroll_today();
begin
  select * into payment from public.payroll_payments where id=p_id;
  if not found or not shiftly_private.payroll_manager(payment.company_id) then
    raise exception 'Chỉ Manager của công ty được xác nhận thanh toán' using errcode='P4550';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(payment.company_id::text||payment.user_id::text||payment.pay_month::text,0));
  select * into payment from public.payroll_payments where id=p_id for update;
  if payment.status='paid' then return to_jsonb(payment); end if;
  if payment.status<>'prepared' then raise exception 'Bảng chốt đã hủy, không thể xác nhận' using errcode='P4555'; end if;
  if p_transfer_date is null or p_transfer_date>today
    or p_transfer_date<(payment.pay_month+interval '1 month')::date+4 then
    raise exception 'Ngày chuyển khoản phải từ ngày 5 tháng kế tiếp và không ở tương lai' using errcode='P4553';
  end if;
  if char_length(coalesce(p_note,''))>500 then raise exception 'Ghi chú tối đa 500 ký tự' using errcode='P4558'; end if;
  if shiftly_private.payroll_receipt_quote(p_receipt_path) is distinct from p_id
    or split_part(p_receipt_path,'/',1)<>payment.company_id::text
    or split_part(p_receipt_path,'/',2)<>payment.user_id::text then
    raise exception 'Ảnh chuyển khoản không thuộc bảng chốt này' using errcode='P4557';
  end if;
  select o.* into proof from storage.objects o where o.bucket_id='payroll-receipts' and o.name=p_receipt_path;
  if not found or (coalesce(proof.owner_id,'')<>auth.uid()::text and proof.owner is distinct from auth.uid())
    or coalesce(proof.metadata->>'mimetype','') not in ('image/jpeg','image/png','image/webp')
    or coalesce((proof.metadata->>'size')::numeric,0) not between 1 and 8388608 then
    raise exception 'Cần tải ảnh chuyển khoản hợp lệ trước khi xác nhận' using errcode='P4557';
  end if;
  select coalesce(sum(p.amount_vnd),0) into total_paid from public.payroll_payments p
    where p.company_id=payment.company_id and p.user_id=payment.user_id and p.pay_month=payment.pay_month and p.status='paid';
  if total_paid<>payment.paid_before_vnd then
    raise exception 'Số đã trả vừa thay đổi. Hãy đối chiếu lại trước khi tiếp tục' using errcode='P4556';
  end if;
  update public.payroll_payments set status='paid',receipt_path=p_receipt_path,transfer_date=p_transfer_date,
    note=btrim(coalesce(p_note,'')),paid_by=auth.uid(),paid_at=now() where id=p_id returning * into payment;
  insert into public.shift_notifications(user_id,company_id,event,title,body,payroll_payment_id)
  values(payment.user_id,payment.company_id,'payroll_paid',
    'Đã thanh toán lương tháng '||to_char(payment.pay_month,'MM/YYYY'),
    coalesce(payment.snapshot->>'company_name','Công ty')||' đã ghi nhận chuyển khoản '||
      replace(to_char(payment.amount_vnd,'FM999,999,999,999,999,990'),',','.')||' đ cho kỳ lương tháng '||
      to_char(payment.pay_month,'MM/YYYY')||'. Mở để xem chứng từ.',payment.id);
  return to_jsonb(payment);
end
$$;
revoke all on function shiftly_private.finalize_payroll_payment(uuid,text,date,text) from public,anon;
grant execute on function shiftly_private.finalize_payroll_payment(uuid,text,date,text) to authenticated;
create or replace function public.finalize_payroll_payment(p_id uuid,p_receipt_path text,p_transfer_date date,p_note text default '')
returns jsonb language sql security invoker set search_path='' as $$
  select shiftly_private.finalize_payroll_payment(p_id,p_receipt_path,p_transfer_date,p_note)
$$;
revoke all on function public.finalize_payroll_payment(uuid,text,date,text) from public,anon;
grant execute on function public.finalize_payroll_payment(uuid,text,date,text) to authenticated;

create or replace function shiftly_private.payroll_payment_history(
  p_company uuid default null,p_month date default null,p_limit integer default 10,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare company_manager boolean:=false; total bigint; result jsonb;
begin
  if not shiftly_private.payroll_actor_active() then raise exception 'Không có quyền xem lịch sử lương' using errcode='P4550'; end if;
  if p_company is not null then company_manager:=shiftly_private.payroll_manager(p_company); end if;
  if p_limit is null or p_offset is null or p_limit not between 1 and 50 or p_offset<0 or p_offset>1000000 then
    raise exception 'Phân trang không hợp lệ' using errcode='P4551';
  end if;
  select count(*) into total from public.payroll_payments p where p.status='paid'
    and (p_company is null or p.company_id=p_company) and (p_month is null or p.pay_month=p_month)
    and (company_manager or p.user_id=auth.uid());
  select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('snapshot',t.snapshot-'shifts')
    order by t.paid_at desc,t.id desc),'[]'::jsonb) into result from (
    select p.* from public.payroll_payments p where p.status='paid'
      and (p_company is null or p.company_id=p_company) and (p_month is null or p.pay_month=p_month)
      and (company_manager or p.user_id=auth.uid())
    order by p.paid_at desc,p.id desc limit p_limit offset p_offset
  ) t;
  return jsonb_build_object('rows',result,'total',total);
end
$$;
revoke all on function shiftly_private.payroll_payment_history(uuid,date,integer,integer) from public,anon;
grant execute on function shiftly_private.payroll_payment_history(uuid,date,integer,integer) to authenticated;
create or replace function public.payroll_payment_history(
  p_company uuid default null,p_month date default null,p_limit integer default 10,p_offset integer default 0)
returns jsonb language sql stable security invoker set search_path='' as $$
  select shiftly_private.payroll_payment_history(p_company,p_month,p_limit,p_offset)
$$;
revoke all on function public.payroll_payment_history(uuid,date,integer,integer) from public,anon;
grant execute on function public.payroll_payment_history(uuid,date,integer,integer) to authenticated;

create or replace function public.payroll_payment_detail(p_id uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
  select to_jsonb(p)||jsonb_build_object('snapshot',p.snapshot-'shifts')
    from public.payroll_payments p where p.id=p_id and p.status='paid'
$$;
revoke all on function public.payroll_payment_detail(uuid) from public,anon;
grant execute on function public.payroll_payment_detail(uuid) to authenticated;

notify pgrst,'reload schema';

-- <<< END supabase/payroll_settlements.sql

-- >>> FILE: supabase/admin_company_deletion.sql
-- Admin deletion is explicit, audited and independent of company business state.
create schema if not exists shiftly_private;
create table if not exists public.company_deletion_log (
  id uuid primary key,
  company_id uuid not null unique,
  company_name text not null,
  company_snapshot jsonb not null,
  reason text not null check (char_length(btrim(reason)) between 1 and 500),
  deleted_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz not null default now(),
  transaction_id bigint not null,
  receipt_paths text[] not null default '{}',
  files_deleted_at timestamptz
);
create index if not exists company_deletion_history_idx on public.company_deletion_log(deleted_at desc);
create index if not exists company_deletion_actor_idx on public.company_deletion_log(deleted_by);
alter table public.company_deletion_log enable row level security;
revoke all on public.company_deletion_log from public,anon,authenticated;
grant select on public.company_deletion_log to authenticated;
do $$ begin
  if exists(select 1 from pg_roles where rolname='service_role') then
    execute 'grant select,update on public.company_deletion_log to service_role';
  end if;
end $$;
drop policy if exists "admins read company deletion reasons" on public.company_deletion_log;
create policy "admins read company deletion reasons" on public.company_deletion_log
  for select to authenticated using (
    (select auth.uid()) is not null and public.account_active()
    and coalesce((select auth.jwt())->'app_metadata'->>'role','')='admin'
  );

-- Only an audit row created by the deletion RPC in this transaction opens the bypass.
-- Clients cannot insert audit rows, and old audit rows never authorize another transaction.
create or replace function shiftly_private.company_deletion_allowed(p_company uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and public.account_active()
    and coalesce(auth.jwt()->'app_metadata'->>'role','')='admin'
    and exists(select 1 from public.company_deletion_log d where d.company_id=p_company
      and d.deleted_by=auth.uid() and d.transaction_id=txid_current())
$$;
revoke all on function shiftly_private.company_deletion_allowed(uuid) from public,anon,authenticated;

create or replace function shiftly_private.require_company_deletion_reason()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if not shiftly_private.company_deletion_allowed(old.id) then
    raise exception 'Chỉ Admin được xóa công ty và phải nhập lý do xóa' using errcode='P4560';
  end if;
  return old;
end
$$;
revoke all on function shiftly_private.require_company_deletion_reason() from public,anon,authenticated;
drop trigger if exists company_deletion_requires_reason on public.companies;
create trigger company_deletion_requires_reason before delete on public.companies
  for each row execute function shiftly_private.require_company_deletion_reason();

create or replace function shiftly_private.admin_delete_company(p_company uuid,p_reason text,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare company public.companies; entry public.company_deletion_log; paths text[];
begin
  if auth.uid() is null or not public.account_active()
    or coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then
    raise exception 'Chỉ Admin được xóa công ty' using errcode='P4560';
  end if;
  if p_company is null or p_request is null or char_length(btrim(coalesce(p_reason,''))) not between 1 and 500 then
    raise exception 'Nhập lý do xóa công ty, tối đa 500 ký tự' using errcode='P4561';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('delete-company:'||p_company::text,0));
  select * into entry from public.company_deletion_log where id=p_request;
  if found then
    if entry.company_id<>p_company or entry.reason<>btrim(p_reason) then
      raise exception 'Mã yêu cầu xóa đã được sử dụng' using errcode='P4562';
    end if;
    return to_jsonb(entry)-'transaction_id'-'company_snapshot';
  end if;
  select * into entry from public.company_deletion_log where company_id=p_company;
  if found then return to_jsonb(entry)-'transaction_id'-'company_snapshot'; end if;
  select * into company from public.companies where id=p_company for update;
  if not found then raise exception 'Công ty không còn tồn tại. Hãy làm mới danh sách.' using errcode='P4563'; end if;
  -- Block new assignments while the company's dependent rows are being removed.
  perform 1 from public.company_members where company_id=p_company for update;
  paths:='{}';
  if to_regclass('storage.objects') is not null then
    select coalesce(array_agg(o.name),'{}'::text[]) into paths from storage.objects o
      where o.bucket_id='payroll-receipts' and o.name like p_company::text||'/%';
  end if;
  insert into public.company_deletion_log(id,company_id,company_name,company_snapshot,reason,deleted_by,transaction_id,receipt_paths,files_deleted_at)
    values(p_request,p_company,company.name,to_jsonb(company),btrim(p_reason),auth.uid(),txid_current(),paths,
      case when cardinality(paths)=0 then now() end) returning * into entry;

  delete from public.shift_notifications where company_id=p_company
    or payroll_payment_id in (select id from public.payroll_payments where company_id=p_company);
  delete from public.payroll_overtime_allowances where company_id=p_company;
  delete from public.payroll_payments where company_id=p_company;
  delete from public.shift_attendance where company_id=p_company;
  delete from public.company_shifts where company_id=p_company;
  -- Shift-deletion triggers may create cancellation notices; these belong to the removed company.
  delete from public.shift_notifications where company_id=p_company;
  delete from public.company_applications where company_id=p_company;
  delete from public.companies where id=p_company;
  return to_jsonb(entry)-'transaction_id'-'company_snapshot';
end
$$;
revoke all on function shiftly_private.admin_delete_company(uuid,text,uuid) from public,anon;
grant execute on function shiftly_private.admin_delete_company(uuid,text,uuid) to authenticated;
create or replace function public.admin_delete_company(p_company uuid,p_reason text,p_request uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select shiftly_private.admin_delete_company(p_company,p_reason,p_request)
$$;
revoke all on function public.admin_delete_company(uuid,text,uuid) from public,anon;
grant execute on function public.admin_delete_company(uuid,text,uuid) to authenticated;

-- The paid-record guards are replaced below with a narrowly scoped deletion exception.

create or replace function shiftly_private.protect_payroll_payment()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' and shiftly_private.company_deletion_allowed(old.company_id) then return old; end if;
  if old.status='paid' then
    raise exception 'Khoản đã thanh toán được giữ nguyên để đối chiếu' using errcode='P4555';
  end if;
  if tg_op='DELETE' then return old; end if;
  if old.status<>'prepared' or new.status not in ('paid','cancelled')
    or (new.id,new.company_id,new.user_id,new.pay_month,new.amount_vnd,new.paid_before_vnd,
        new.snapshot,new.created_by,new.created_at)
      is distinct from
       (old.id,old.company_id,old.user_id,old.pay_month,old.amount_vnd,old.paid_before_vnd,
        old.snapshot,old.created_by,old.created_at) then
    raise exception 'Không được thay đổi số tiền hoặc người nhận của bảng đã chốt' using errcode='P4555';
  end if;
  return new;
end
$$;
revoke all on function shiftly_private.protect_payroll_payment() from public,anon,authenticated;

create or replace function shiftly_private.protect_overtime_allowance()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' and shiftly_private.company_deletion_allowed(old.company_id) then return old; end if;
  if old.locked_by_payment_id is not null and exists (
    select 1 from public.payroll_payments p
      where p.id=old.locked_by_payment_id and p.status in ('prepared','paid')
  ) then
    raise exception 'Phụ cấp này đã nằm trong bảng chốt, không thể sửa' using errcode='P4555';
  end if;
  if tg_op='DELETE' then return old; end if;
  if (new.shift_id,new.company_id,new.user_id,new.pay_month,new.overtime_ms)
      is distinct from (old.shift_id,old.company_id,old.user_id,old.pay_month,old.overtime_ms) then
    raise exception 'Thông tin ca quá giờ được giữ nguyên' using errcode='P4555';
  end if;
  return new;
end
$$;
revoke all on function shiftly_private.protect_overtime_allowance() from public,anon,authenticated;

notify pgrst,'reload schema';

-- <<< END supabase/admin_company_deletion.sql

commit;
-- End. The SQL editor must report Success. Configure Google OAuth and URL/Key next.
