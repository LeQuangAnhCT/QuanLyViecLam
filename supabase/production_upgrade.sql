-- SHIFTLY — ONE-PASTE SUPABASE PRODUCTION UPGRADE
-- For an EXISTING project with companies, memberships, Auth and account controls.
-- Paste this entire file into Supabase Dashboard > SQL Editor > Run.
-- This file is designed to be repeatable and preserves existing employees,
-- shifts, attendance, notifications and compensation rates.
-- Back up the database first. All statements run in one transaction.
-- RLS and server-side triggers are enforced independently of the Vue frontend.

begin;

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
-- Allow rerunning after new report signature was installed in previous deployment.
drop function if exists public.company_staff_summary(uuid,date);
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

-- Manager profile / notifications / multi-person work & monthly Cast payroll (non-destructive)
-- SOURCE: supabase/manager_location_cast.sql
-- Run after FULL_SETUP_FROM_SCRATCH.sql on new projects or on an existing Shiftly database.
alter table public.profiles add column if not exists active_location text;
grant update (active_location) on public.profiles to authenticated;
alter table public.company_shifts add column if not exists cast_vnd bigint not null default 0;
alter table public.company_shifts drop constraint if exists company_shifts_cast_vnd_check;
alter table public.company_shifts add constraint company_shifts_cast_vnd_check check (cast_vnd between 0 and 100000000);
-- Existing manager shift INSERT/UPDATE RLS policies remain in force.

-- SOURCE: supabase/manager_notifications.sql
-- Run after shift_notifications.sql and shift_attendance.sql.
-- Managers receive durable in-app notifications for attendance and join requests.
alter table public.shift_notifications drop constraint if exists shift_notifications_event_check;
alter table public.shift_notifications add constraint shift_notifications_event_check
  check (event in ('created','updated','cancelled','attendance_in','attendance_out','join_request'));

create or replace function public.notify_manager_activity()
returns trigger language plpgsql security definer set search_path=public as $$
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
end $$;
revoke all on function public.notify_manager_activity() from public;
drop trigger if exists notify_manager_attendance on public.shift_attendance;
create trigger notify_manager_attendance
after insert or update of checked_out_at on public.shift_attendance
for each row execute function public.notify_manager_activity();
drop trigger if exists notify_manager_join_request on public.company_join_requests;
create trigger notify_manager_join_request
after insert or update of status on public.company_join_requests
for each row execute function public.notify_manager_activity();

-- SOURCE: supabase/lock_clocked_shift_cast.sql
-- Upgrade existing Shiftly database. Run in Supabase SQL Editor.
-- A checked-in shift's cast is immutable even through direct API calls.
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
  if NEW.cast_vnd is distinct from OLD.cast_vnd then
    raise exception 'Ca đã chấm công: không được thay đổi cast / thù lao' using errcode='P4512';
  end if;
  return NEW;
end $$;
revoke all on function public.protect_clocked_shift() from public;

-- SOURCE: supabase/multi_staff_assignment.sql
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
revoke all on function public.manager_update_work_assignments(uuid,uuid[],text,text,timestamptz,timestamptz,bigint) from public;
grant execute on function public.manager_update_work_assignments(uuid,uuid[],text,text,timestamptz,timestamptz,bigint) to authenticated;
notify pgrst, 'reload schema';

-- SOURCE: supabase/monthly_cast_payroll.sql
-- Non-destructive upgrade: replace legacy per-show estimate with per-shift Cast
-- and a monthly allowance. Historic show_rate_vnd stays for compatibility but is ignored.
alter table public.member_compensation
  add column if not exists monthly_allowance_vnd numeric(14,0) not null default 0;
alter table public.member_compensation drop constraint if exists member_compensation_monthly_allowance_valid;
alter table public.member_compensation add constraint member_compensation_monthly_allowance_valid
  check (monthly_allowance_vnd >= 0);
alter table public.member_compensation alter column show_rate_vnd set default 0;

-- PostgreSQL requires DROP before changing an existing table-return signature.
drop function if exists public.company_staff_summary(uuid,date);
create function public.company_staff_summary(p_company uuid,p_month date)
returns table (
  user_id uuid, full_name text, email text, employment_type text,
  monthly_base_vnd numeric, monthly_allowance_vnd numeric,
  scheduled_shifts bigint, completed_shifts bigint, worked_hours numeric,
  cast_total_vnd numeric, estimated_total_vnd numeric
)
language plpgsql stable security definer set search_path=public as $$
declare first_day timestamptz; next_month timestamptz;
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
    p.monthly_allowance_vnd::numeric,
    count(s.id)::bigint,
    count(a.shift_id) filter (where a.checked_out_at is not null)::bigint,
    round(coalesce(sum(extract(epoch from (a.checked_out_at-a.checked_in_at))/3600.0)
      filter (where a.checked_out_at is not null),0)::numeric,2),
    coalesce(sum(s.cast_vnd) filter (where a.checked_out_at is not null),0)::numeric,
    (coalesce(p.monthly_base_vnd,0) + p.monthly_allowance_vnd +
      coalesce(sum(s.cast_vnd) filter (where a.checked_out_at is not null),0))::numeric
  from public.company_members m
    join auth.users u on u.id=m.user_id
    join public.member_compensation p on p.company_id=m.company_id and p.user_id=m.user_id
    left join public.company_shifts s on s.company_id=m.company_id and s.user_id=m.user_id
      and s.starts_at>=first_day and s.starts_at<next_month
    left join public.shift_attendance a on a.shift_id=s.id
  where m.company_id=p_company and m.role='staff'
  group by m.user_id,u.email,u.raw_user_meta_data,p.employment_type,
    p.monthly_base_vnd,p.monthly_allowance_vnd
  order by coalesce(u.raw_user_meta_data->>'full_name',u.email::text);
end $$;
revoke all on function public.company_staff_summary(uuid,date) from public;
grant execute on function public.company_staff_summary(uuid,date) to authenticated;
notify pgrst, 'reload schema';

commit;
