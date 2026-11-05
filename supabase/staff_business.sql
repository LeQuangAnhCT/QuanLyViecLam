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
