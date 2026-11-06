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
  if (to_jsonb(NEW)->'cast_vnd') is distinct from (to_jsonb(OLD)->'cast_vnd') then
    raise exception 'Ca đã chấm công: không được thay đổi tiền cast' using errcode='P4512';
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
  check (event in ('created','updated','cancelled','attendance_in','attendance_out','join_request'));

create or replace function public.notify_manager_activity()
returns trigger language plpgsql security definer set search_path=public as $
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
end $;
revoke all on function public.notify_manager_activity() from public;
drop trigger if exists notify_manager_attendance on public.shift_attendance;
create trigger notify_manager_attendance
after insert or update of checked_out_at on public.shift_attendance
for each row execute function public.notify_manager_activity();
drop trigger if exists notify_manager_join_request on public.company_join_requests;
create trigger notify_manager_join_request
after insert or update of status on public.company_join_requests
for each row execute function public.notify_manager_activity();

commit;
-- End. The SQL editor must report Success. Configure Google OAuth and URL/Key next.
