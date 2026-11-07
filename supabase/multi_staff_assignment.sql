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
