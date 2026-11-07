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
