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
