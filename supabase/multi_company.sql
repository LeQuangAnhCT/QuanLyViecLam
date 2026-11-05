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
