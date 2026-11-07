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
