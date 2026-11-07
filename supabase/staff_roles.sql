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
