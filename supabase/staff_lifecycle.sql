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
