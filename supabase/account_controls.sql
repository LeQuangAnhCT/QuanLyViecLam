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
