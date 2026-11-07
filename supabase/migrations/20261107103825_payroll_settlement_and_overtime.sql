-- Payroll settlement and overtime, including the required employment notices.
-- Run after staff_business.sql and manager_notifications.sql.
-- Role notices are written atomically with the Manager's compensation change.
alter table public.shift_notifications drop constraint if exists shift_notifications_event_check;
alter table public.shift_notifications add constraint shift_notifications_event_check
  check (event in ('created','updated','cancelled','attendance_in','attendance_out','join_request','employment_changed','payroll_paid'));

create schema if not exists shiftly_private;

create or replace function shiftly_private.notify_employment_change()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  previous_role text;
  next_role text;
begin
  if tg_op = 'UPDATE' then
    if old.employment_type is not distinct from new.employment_type then return new; end if;
    previous_role := case old.employment_type when 'employee' then 'STAFF' else 'Freelance' end;
  else
    if new.employment_type <> 'employee' then return new; end if;
    previous_role := 'Freelance';
  end if;
  next_role := case new.employment_type when 'employee' then 'STAFF' else 'Freelance' end;

  insert into public.shift_notifications(user_id,company_id,event,title,body)
  select new.user_id, new.company_id, 'employment_changed',
         format('Bạn đã được chuyển thành %s', next_role),
         format('Manager của %s đã chuyển vai trò của bạn từ %s sang %s.', c.name, previous_role, next_role)
  from public.company_members m
  join public.companies c on c.id = m.company_id
  where m.company_id = new.company_id and m.user_id = new.user_id and m.role = 'staff';
  return new;
end
$$;
revoke all on function shiftly_private.notify_employment_change() from public, anon, authenticated;

drop trigger if exists notify_staff_employment_change on public.member_compensation;
create trigger notify_staff_employment_change
  after insert or update of employment_type on public.member_compensation
  for each row execute function shiftly_private.notify_employment_change();

notify pgrst, 'reload schema';

-- Additive payroll ledger. Run after the attendance / Cast / staff-role upgrades.
-- Prepared quotes do not count as payments. Paid snapshots and their evidence are immutable.
create schema if not exists shiftly_private;
revoke all on schema shiftly_private from public, anon;
grant usage on schema shiftly_private to authenticated;

alter table public.member_compensation
  add column if not exists monthly_allowance_vnd numeric(14,0) not null default 0;
alter table public.member_compensation drop constraint if exists member_compensation_monthly_allowance_valid;
alter table public.member_compensation add constraint member_compensation_monthly_allowance_valid check (monthly_allowance_vnd>=0);

create table if not exists public.payroll_payments (
  id uuid primary key,
  company_id uuid not null references public.companies(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  pay_month date not null check (pay_month = date_trunc('month',pay_month)::date),
  status text not null default 'prepared' check (status in ('prepared','paid','cancelled')),
  amount_vnd bigint not null check (amount_vnd between 1 and 9007199254740991),
  paid_before_vnd bigint not null check (paid_before_vnd >= 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot)='object'),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  receipt_path text unique,
  transfer_date date,
  note text not null default '' check (char_length(note)<=500),
  paid_by uuid references auth.users(id) on delete restrict,
  paid_at timestamptz,
  check ((status='paid' and receipt_path is not null and transfer_date is not null
            and paid_by is not null and paid_at is not null)
      or (status in ('prepared','cancelled') and receipt_path is null
            and transfer_date is null and paid_by is null and paid_at is null))
);
create unique index if not exists payroll_one_prepared_per_person
  on public.payroll_payments(company_id,user_id,pay_month) where status='prepared';
create index if not exists payroll_company_month_history
  on public.payroll_payments(company_id,pay_month,paid_at desc,id) where status='paid';
create index if not exists payroll_person_history
  on public.payroll_payments(user_id,paid_at desc,id) where status='paid';
create index if not exists payroll_creator_idx on public.payroll_payments(created_by);
create index if not exists payroll_payer_idx on public.payroll_payments(paid_by);

create table if not exists public.payroll_overtime_allowances (
  shift_id uuid primary key references public.company_shifts(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  pay_month date not null check (pay_month=date_trunc('month',pay_month)::date),
  overtime_ms bigint not null check (overtime_ms>0),
  allowance_vnd bigint not null check (allowance_vnd between 0 and 1000000000),
  note text not null default '' check (char_length(note)<=500),
  request_id uuid not null,
  approved_by uuid not null references auth.users(id) on delete restrict,
  approved_at timestamptz not null default now(),
  locked_by_payment_id uuid references public.payroll_payments(id) on delete restrict,
  check (allowance_vnd>0 or char_length(btrim(note))>=3)
);
create index if not exists overtime_company_month_person
  on public.payroll_overtime_allowances(company_id,pay_month,user_id);
create index if not exists overtime_person_idx on public.payroll_overtime_allowances(user_id);
create index if not exists overtime_approver_idx on public.payroll_overtime_allowances(approved_by);
create index if not exists overtime_payment_idx on public.payroll_overtime_allowances(locked_by_payment_id);
create index if not exists payroll_shifts_company_month
  on public.company_shifts(company_id,starts_at,user_id);

alter table public.payroll_payments enable row level security;
alter table public.payroll_overtime_allowances enable row level security;
revoke all on public.payroll_payments,public.payroll_overtime_allowances from public,anon,authenticated;
grant select on public.payroll_payments,public.payroll_overtime_allowances to authenticated;

create or replace function shiftly_private.payroll_today()
returns date language sql stable security invoker set search_path='' as $$
  select (now() at time zone 'Asia/Ho_Chi_Minh')::date
$$;
revoke all on function shiftly_private.payroll_today() from public,anon,authenticated;

create or replace function shiftly_private.payroll_actor_active()
returns boolean language sql stable security invoker set search_path='' as $$
  select auth.uid() is not null and public.account_active()
    and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
$$;
revoke all on function shiftly_private.payroll_actor_active() from public,anon,authenticated;

create or replace function shiftly_private.payroll_manager(p_company uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select shiftly_private.payroll_actor_active() and exists (
    select 1 from public.company_members m
      where m.company_id=p_company and m.user_id=auth.uid() and m.role='manager' and m.is_active
  )
$$;
revoke all on function shiftly_private.payroll_manager(uuid) from public,anon;
grant execute on function shiftly_private.payroll_manager(uuid) to authenticated;

create or replace function shiftly_private.payroll_readable(p_company uuid,p_user uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select shiftly_private.payroll_actor_active()
    and (p_user=auth.uid() or shiftly_private.payroll_manager(p_company))
$$;
revoke all on function shiftly_private.payroll_readable(uuid,uuid) from public,anon;
grant execute on function shiftly_private.payroll_readable(uuid,uuid) to authenticated;

drop policy if exists "payroll snapshots visible to recipient and manager" on public.payroll_payments;
create policy "payroll snapshots visible to recipient and manager" on public.payroll_payments
  for select to authenticated using (
    shiftly_private.payroll_readable(company_id,user_id)
      and (status='paid' or shiftly_private.payroll_manager(company_id))
  );
drop policy if exists "overtime visible to recipient and manager" on public.payroll_overtime_allowances;
create policy "overtime visible to recipient and manager" on public.payroll_overtime_allowances
  for select to authenticated using (shiftly_private.payroll_readable(company_id,user_id));

create or replace function shiftly_private.protect_payroll_payment()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.status='paid' then
    raise exception 'Khoản đã thanh toán được giữ nguyên để đối chiếu' using errcode='P4555';
  end if;
  if tg_op='DELETE' then return old; end if;
  if old.status<>'prepared' or new.status not in ('paid','cancelled')
    or (new.id,new.company_id,new.user_id,new.pay_month,new.amount_vnd,new.paid_before_vnd,
        new.snapshot,new.created_by,new.created_at)
      is distinct from
       (old.id,old.company_id,old.user_id,old.pay_month,old.amount_vnd,old.paid_before_vnd,
        old.snapshot,old.created_by,old.created_at) then
    raise exception 'Không được thay đổi số tiền hoặc người nhận của bảng đã chốt' using errcode='P4555';
  end if;
  return new;
end
$$;
revoke all on function shiftly_private.protect_payroll_payment() from public,anon,authenticated;
drop trigger if exists payroll_payment_immutable on public.payroll_payments;
create trigger payroll_payment_immutable before update or delete on public.payroll_payments
  for each row execute function shiftly_private.protect_payroll_payment();

create or replace function shiftly_private.protect_overtime_allowance()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.locked_by_payment_id is not null and exists (
    select 1 from public.payroll_payments p
      where p.id=old.locked_by_payment_id and p.status in ('prepared','paid')
  ) then
    raise exception 'Phụ cấp này đã nằm trong bảng chốt, không thể sửa' using errcode='P4555';
  end if;
  if tg_op='DELETE' then return old; end if;
  if (new.shift_id,new.company_id,new.user_id,new.pay_month,new.overtime_ms)
      is distinct from (old.shift_id,old.company_id,old.user_id,old.pay_month,old.overtime_ms) then
    raise exception 'Thông tin ca quá giờ được giữ nguyên' using errcode='P4555';
  end if;
  return new;
end
$$;
revoke all on function shiftly_private.protect_overtime_allowance() from public,anon,authenticated;
drop trigger if exists payroll_overtime_immutable on public.payroll_overtime_allowances;
create trigger payroll_overtime_immutable before update or delete on public.payroll_overtime_allowances
  for each row execute function shiftly_private.protect_overtime_allowance();

-- Internal set-based calculation. No direct client EXECUTE grant.
create or replace function shiftly_private.payroll_rows(p_company uuid,p_month date,p_user uuid default null)
returns setof jsonb language sql stable security invoker set search_path='' as $$
  with bounds as (
    select p_month::timestamp at time zone 'Asia/Ho_Chi_Minh' as start_at,
      (p_month::timestamp+interval '1 month') at time zone 'Asia/Ho_Chi_Minh' as end_at
  ), source_shifts as (
    select s.*,a.checked_in_at,a.checked_out_at,coalesce(a.expense_total_vnd,0) as expenses_vnd,
      case when a.checked_out_at is null then 0 else
        greatest(0,extract(epoch from (a.checked_out_at-greatest(s.ends_at,a.checked_in_at)))*1000)::bigint
      end as overtime_ms
    from public.company_shifts s cross join bounds b
      left join public.shift_attendance a on a.shift_id=s.id
    where s.company_id=p_company and s.starts_at>=b.start_at and s.starts_at<b.end_at
      and (p_user is null or s.user_id=p_user)
  ), target_ids as (
    select m.user_id from public.company_members m cross join bounds b
      where m.company_id=p_company and m.role='staff' and (p_user is null or m.user_id=p_user)
        and (m.created_at<b.end_at or exists(select 1 from source_shifts s where s.user_id=m.user_id))
    union
    select s.user_id from source_shifts s
    union
    select p.user_id from public.payroll_payments p where p.company_id=p_company
      and p.pay_month=p_month and p.status in ('prepared','paid') and (p_user is null or p.user_id=p_user)
  ), shift_totals as (
    select s.user_id,count(*) as scheduled_shifts,
      count(*) filter(where s.checked_out_at is not null) as completed_shifts,
      coalesce(sum(s.cast_vnd),0) as planned_cast_vnd,
      coalesce(sum(s.cast_vnd) filter(where s.checked_out_at is not null),0) as shift_cast_vnd,
      coalesce(sum(s.expenses_vnd) filter(where s.checked_out_at is not null),0) as expense_vnd,
      coalesce(sum(greatest(0,extract(epoch from(s.checked_out_at-s.checked_in_at))*1000))
        filter(where s.checked_out_at is not null),0)::bigint as worked_ms,
      coalesce(sum(s.overtime_ms),0)::bigint as overtime_ms,
      count(*) filter(where s.overtime_ms>0 and o.shift_id is null) as unreviewed_overtime,
      coalesce(sum(o.allowance_vnd),0) as overtime_allowance_vnd
    from source_shifts s left join public.payroll_overtime_allowances o on o.shift_id=s.id
    group by s.user_id
  ), paid_totals as (
    select p.user_id,sum(p.amount_vnd) as paid_vnd,count(*) as payment_count,max(p.paid_at) as last_paid_at
    from public.payroll_payments p where p.company_id=p_company and p.pay_month=p_month and p.status='paid'
      and (p_user is null or p.user_id=p_user) group by p.user_id
  ), fixed as (
    select distinct on(p.user_id) p.user_id,p.snapshot,p.status
    from public.payroll_payments p where p.company_id=p_company and p.pay_month=p_month
      and p.status in ('prepared','paid') and (p_user is null or p.user_id=p_user)
    order by p.user_id,(p.status='paid') desc,p.created_at,p.id
  ), pending as (
    select p.user_id,p.id,p.amount_vnd from public.payroll_payments p
      where p.company_id=p_company and p.pay_month=p_month and p.status='prepared'
  ), calculated as (
    select t.user_id,coalesce(nullif(btrim(pr.full_name),''),u.raw_user_meta_data->>'full_name',
        f.snapshot->>'full_name',u.email::text,'Nhân viên') as full_name,
      coalesce(u.email::text,f.snapshot->>'email','') as email,c.name as company_name,
      coalesce(f.snapshot->>'employment_type',mc.employment_type,'freelancer') as employment_type,
      coalesce((f.snapshot->>'monthly_base_vnd')::numeric,mc.monthly_base_vnd,0) as monthly_base_vnd,
      coalesce((f.snapshot->>'monthly_allowance_vnd')::numeric,mc.monthly_allowance_vnd,0) as monthly_allowance_vnd,
      coalesce(s.scheduled_shifts,0) as scheduled_shifts,coalesce(s.completed_shifts,0) as completed_shifts,
      coalesce(s.planned_cast_vnd,0) as planned_cast_vnd,coalesce(s.shift_cast_vnd,0) as shift_cast_vnd,
      coalesce(s.expense_vnd,0) as expense_vnd,coalesce(s.worked_ms,0) as worked_ms,
      coalesce(s.overtime_ms,0) as overtime_ms,coalesce(s.unreviewed_overtime,0) as unreviewed_overtime,
      coalesce(s.overtime_allowance_vnd,0) as overtime_allowance_vnd,
      coalesce(p.paid_vnd,0) as paid_vnd,coalesce(p.payment_count,0) as payment_count,p.last_paid_at,
      q.id as pending_payment_id,q.amount_vnd as pending_amount_vnd,f.user_id is not null as snapshotted
    from target_ids t join public.companies c on c.id=p_company
      left join auth.users u on u.id=t.user_id left join public.profiles pr on pr.id=t.user_id
      left join public.member_compensation mc on mc.company_id=p_company and mc.user_id=t.user_id
      left join fixed f on f.user_id=t.user_id left join shift_totals s on s.user_id=t.user_id
      left join paid_totals p on p.user_id=t.user_id left join pending q on q.user_id=t.user_id
  ), money as (
    select c.*,(c.monthly_base_vnd+c.monthly_allowance_vnd+c.shift_cast_vnd+c.expense_vnd+c.overtime_allowance_vnd) as earned_vnd
    from calculated c
  )
  select to_jsonb(m)||jsonb_build_object('company_id',p_company,'pay_month',p_month,
    'remaining_vnd',greatest(0,m.earned_vnd-m.paid_vnd),
    'pay_from',(p_month+interval '1 month')::date+4,
    'pay_until',(p_month+interval '1 month')::date+9,
    'server_today',shiftly_private.payroll_today())
  from money m order by m.full_name,m.user_id
$$;
revoke all on function shiftly_private.payroll_rows(uuid,date,uuid) from public,anon,authenticated;

create or replace function shiftly_private.payroll_month_summary(p_company uuid,p_month date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare own_user uuid;
begin
  if not shiftly_private.payroll_actor_active() or p_company is null then
    raise exception 'Không có quyền xem bảng lương' using errcode='P4550';
  end if;
  if p_month is null or p_month<>date_trunc('month',p_month)::date
      or p_month<'2000-01-01' or p_month>'2100-12-01' then
    raise exception 'Kỳ lương không hợp lệ' using errcode='P4551';
  end if;
  if not shiftly_private.payroll_manager(p_company) then
    own_user:=auth.uid();
    if not exists(select 1 from public.company_members m where m.company_id=p_company and m.user_id=own_user)
      and not exists(select 1 from public.payroll_payments p where p.company_id=p_company and p.user_id=own_user and p.status='paid') then
      raise exception 'Không có quyền xem kỳ lương của công ty này' using errcode='P4550';
    end if;
  end if;
  return (select coalesce(jsonb_agg(r),'[]'::jsonb) from shiftly_private.payroll_rows(p_company,p_month,own_user) r);
end
$$;
revoke all on function shiftly_private.payroll_month_summary(uuid,date) from public,anon;
grant execute on function shiftly_private.payroll_month_summary(uuid,date) to authenticated;
create or replace function public.payroll_month_summary(p_company uuid,p_month date)
returns jsonb language sql stable security invoker set search_path='' as $$
  select shiftly_private.payroll_month_summary(p_company,p_month)
$$;
revoke all on function public.payroll_month_summary(uuid,date) from public,anon;
grant execute on function public.payroll_month_summary(uuid,date) to authenticated;

create or replace function shiftly_private.payroll_overtime(p_company uuid,p_month date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare only_user uuid;
begin
  perform shiftly_private.payroll_month_summary(p_company,p_month);
  if not shiftly_private.payroll_manager(p_company) then only_user:=auth.uid(); end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.full_name,t.starts_at,t.shift_id),'[]'::jsonb)
    from (
      select s.id as shift_id,s.user_id,
        coalesce(nullif(btrim(pr.full_name),''),u.raw_user_meta_data->>'full_name',u.email::text) as full_name,
        s.title,s.location,s.starts_at,s.ends_at as planned_ends_at,a.checked_in_at,a.checked_out_at,
        greatest(0,extract(epoch from(a.checked_out_at-greatest(a.checked_in_at,s.ends_at)))*1000)::bigint as overtime_ms,
        o.allowance_vnd,o.note,o.approved_at,o.locked_by_payment_id,p.status as locked_status
      from public.company_shifts s join public.shift_attendance a on a.shift_id=s.id
        join auth.users u on u.id=s.user_id left join public.profiles pr on pr.id=s.user_id
        left join public.payroll_overtime_allowances o on o.shift_id=s.id
        left join public.payroll_payments p on p.id=o.locked_by_payment_id
      where s.company_id=p_company and (only_user is null or s.user_id=only_user)
        and s.starts_at>=p_month::timestamp at time zone 'Asia/Ho_Chi_Minh'
        and s.starts_at<(p_month::timestamp+interval '1 month') at time zone 'Asia/Ho_Chi_Minh'
        and a.checked_out_at>greatest(a.checked_in_at,s.ends_at)
    ) t
  );
end
$$;
revoke all on function shiftly_private.payroll_overtime(uuid,date) from public,anon;
grant execute on function shiftly_private.payroll_overtime(uuid,date) to authenticated;
create or replace function public.payroll_overtime(p_company uuid,p_month date)
returns jsonb language sql stable security invoker set search_path='' as $$
  select shiftly_private.payroll_overtime(p_company,p_month)
$$;
revoke all on function public.payroll_overtime(uuid,date) from public,anon;
grant execute on function public.payroll_overtime(uuid,date) to authenticated;

create or replace function shiftly_private.approve_overtime_allowance(
  p_shift uuid,p_amount bigint,p_note text,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s record; existing public.payroll_overtime_allowances; period date; duration bigint;
begin
  select cs.*,a.checked_in_at,a.checked_out_at into s from public.company_shifts cs
    join public.shift_attendance a on a.shift_id=cs.id where cs.id=p_shift;
  if not found or not shiftly_private.payroll_manager(s.company_id) then
    raise exception 'Chỉ Manager của công ty được duyệt phụ cấp' using errcode='P4550';
  end if;
  period:=date_trunc('month',s.starts_at at time zone 'Asia/Ho_Chi_Minh')::date;
  perform pg_advisory_xact_lock(hashtextextended(s.company_id::text||s.user_id::text||period::text,0));
  duration:=greatest(0,extract(epoch from(s.checked_out_at-greatest(s.checked_in_at,s.ends_at)))*1000)::bigint;
  if s.checked_out_at is null or duration<=0 then
    raise exception 'Ca chưa hoàn tất hoặc không có thời gian quá giờ' using errcode='P4554';
  end if;
  if p_request is null or p_amount is null or p_amount not between 0 and 1000000000
    or char_length(coalesce(p_note,''))>500
    or (p_amount=0 and char_length(btrim(coalesce(p_note,'')))<3) then
    raise exception 'Nhập phụ cấp hợp lệ; nếu không bù tiền cần ghi rõ lý do' using errcode='P4558';
  end if;
  select * into existing from public.payroll_overtime_allowances where shift_id=p_shift for update;
  if found and existing.request_id=p_request then
    if existing.allowance_vnd<>p_amount or existing.note<>btrim(coalesce(p_note,'')) then
      raise exception 'Mã yêu cầu đã được sử dụng' using errcode='P4558';
    end if;
    return to_jsonb(existing);
  end if;
  if existing.locked_by_payment_id is not null and exists(select 1 from public.payroll_payments p
      where p.id=existing.locked_by_payment_id and p.status in ('prepared','paid')) then
    raise exception 'Phụ cấp đã chốt; chỉ bảng chưa trả mới được hủy để duyệt lại' using errcode='P4555';
  end if;
  insert into public.payroll_overtime_allowances
    (shift_id,company_id,user_id,pay_month,overtime_ms,allowance_vnd,note,request_id,approved_by)
  values(p_shift,s.company_id,s.user_id,period,duration,p_amount,btrim(coalesce(p_note,'')),p_request,auth.uid())
  on conflict(shift_id) do update set allowance_vnd=excluded.allowance_vnd,note=excluded.note,
    request_id=excluded.request_id,approved_by=excluded.approved_by,approved_at=now(),locked_by_payment_id=null
  returning * into existing;
  return to_jsonb(existing);
end
$$;
revoke all on function shiftly_private.approve_overtime_allowance(uuid,bigint,text,uuid) from public,anon;
grant execute on function shiftly_private.approve_overtime_allowance(uuid,bigint,text,uuid) to authenticated;
create or replace function public.approve_overtime_allowance(p_shift uuid,p_amount bigint,p_note text,p_request uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select shiftly_private.approve_overtime_allowance(p_shift,p_amount,p_note,p_request)
$$;
revoke all on function public.approve_overtime_allowance(uuid,bigint,text,uuid) from public,anon;
grant execute on function public.approve_overtime_allowance(uuid,bigint,text,uuid) to authenticated;

create or replace function shiftly_private.prepare_payroll_payment(p_company uuid,p_user uuid,p_month date,p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare summary jsonb; payment public.payroll_payments; amount numeric; shifts_snapshot jsonb;
begin
  if not shiftly_private.payroll_manager(p_company) then
    raise exception 'Chỉ Manager của công ty được chốt lương' using errcode='P4550';
  end if;
  if p_id is null or p_user is null or p_month is null or p_month<>date_trunc('month',p_month)::date
      or p_month<'2000-01-01' or p_month>'2100-12-01' then
    raise exception 'Thông tin kỳ lương không hợp lệ' using errcode='P4551';
  end if;
  if shiftly_private.payroll_today()<(p_month+interval '1 month')::date+4 then
    raise exception 'Kỳ này được trả từ ngày 5 tháng kế tiếp' using errcode='P4553';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company::text||p_user::text||p_month::text,0));
  select * into payment from public.payroll_payments where id=p_id;
  if found then
    if (payment.company_id,payment.user_id,payment.pay_month) is distinct from(p_company,p_user,p_month) then
      raise exception 'Mã chốt lương đã được sử dụng' using errcode='P4555';
    end if;
    if payment.status='cancelled' then raise exception 'Bảng chốt đã hủy, hãy mở lại bảng mới' using errcode='P4555'; end if;
    return to_jsonb(payment);
  end if;
  select * into payment from public.payroll_payments where company_id=p_company and user_id=p_user
    and pay_month=p_month and status='prepared';
  if found then return to_jsonb(payment); end if;
  select r into summary from shiftly_private.payroll_rows(p_company,p_month,p_user) r;
  if summary is null then raise exception 'Nhân viên không có dữ liệu trong kỳ lương' using errcode='P4559'; end if;
  if (summary->>'unreviewed_overtime')::bigint>0 then
    raise exception 'Hãy duyệt phụ cấp của các ca quá giờ trước khi chốt lương' using errcode='P4554';
  end if;
  amount:=(summary->>'remaining_vnd')::numeric;
  if amount is null or amount<=0 then raise exception 'Kỳ này không còn tiền cần thanh toán' using errcode='P4552'; end if;
  if amount>9007199254740991 or (summary->>'earned_vnd')::numeric>9007199254740991
    or (summary->>'paid_vnd')::numeric>9007199254740991 then
    raise exception 'Số tiền vượt giới hạn được hỗ trợ' using errcode='P4558';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('shift_id',s.id,'title',s.title,'location',s.location,
    'starts_at',s.starts_at,'planned_ends_at',s.ends_at,'checked_in_at',a.checked_in_at,'checked_out_at',a.checked_out_at,
    'cast_vnd',s.cast_vnd,'expense_vnd',a.expense_total_vnd,'overtime_allowance_vnd',coalesce(o.allowance_vnd,0))
    order by s.starts_at,s.id),'[]'::jsonb) into shifts_snapshot
  from public.company_shifts s join public.shift_attendance a on a.shift_id=s.id
    left join public.payroll_overtime_allowances o on o.shift_id=s.id
  where s.company_id=p_company and s.user_id=p_user and a.checked_out_at is not null
    and s.starts_at>=p_month::timestamp at time zone 'Asia/Ho_Chi_Minh'
    and s.starts_at<(p_month::timestamp+interval '1 month') at time zone 'Asia/Ho_Chi_Minh';
  summary:=summary||jsonb_build_object('shifts',shifts_snapshot);
  insert into public.payroll_payments(id,company_id,user_id,pay_month,amount_vnd,paid_before_vnd,snapshot,created_by)
    values(p_id,p_company,p_user,p_month,amount::bigint,(summary->>'paid_vnd')::bigint,summary,auth.uid())
    returning * into payment;
  update public.payroll_overtime_allowances o set locked_by_payment_id=p_id
    where o.company_id=p_company and o.user_id=p_user and o.pay_month=p_month
      and (o.locked_by_payment_id is null or exists(select 1 from public.payroll_payments p
        where p.id=o.locked_by_payment_id and p.status='cancelled'));
  return to_jsonb(payment);
end
$$;
revoke all on function shiftly_private.prepare_payroll_payment(uuid,uuid,date,uuid) from public,anon;
grant execute on function shiftly_private.prepare_payroll_payment(uuid,uuid,date,uuid) to authenticated;
create or replace function public.prepare_payroll_payment(p_company uuid,p_user uuid,p_month date,p_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select shiftly_private.prepare_payroll_payment(p_company,p_user,p_month,p_id)
$$;
revoke all on function public.prepare_payroll_payment(uuid,uuid,date,uuid) from public,anon;
grant execute on function public.prepare_payroll_payment(uuid,uuid,date,uuid) to authenticated;

create or replace function shiftly_private.cancel_payroll_payment(p_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare payment public.payroll_payments;
begin
  select * into payment from public.payroll_payments where id=p_id;
  if not found or not shiftly_private.payroll_manager(payment.company_id) then
    raise exception 'Không có quyền thay đổi bảng chốt này' using errcode='P4550';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(payment.company_id::text||payment.user_id::text||payment.pay_month::text,0));
  select * into payment from public.payroll_payments where id=p_id for update;
  if payment.status='cancelled' then return; end if;
  if payment.status<>'prepared' then raise exception 'Khoản đã thanh toán không được hủy' using errcode='P4555'; end if;
  update public.payroll_payments set status='cancelled' where id=p_id;
  update public.payroll_overtime_allowances set locked_by_payment_id=null where locked_by_payment_id=p_id;
end
$$;
revoke all on function shiftly_private.cancel_payroll_payment(uuid) from public,anon;
grant execute on function shiftly_private.cancel_payroll_payment(uuid) to authenticated;
create or replace function public.cancel_payroll_payment(p_id uuid)
returns void language sql security invoker set search_path='' as $$ select shiftly_private.cancel_payroll_payment(p_id) $$;
revoke all on function public.cancel_payroll_payment(uuid) from public,anon;
grant execute on function public.cancel_payroll_payment(uuid) to authenticated;

-- Storage paths: company UUID / recipient UUID / payment UUID / image UUID.ext.
create or replace function shiftly_private.payroll_receipt_quote(p_name text)
returns uuid language plpgsql immutable security invoker set search_path='' as $$
begin
  if p_name !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$' then return null; end if;
  begin return split_part(p_name,'/',3)::uuid; exception when invalid_text_representation then return null; end;
end
$$;
revoke all on function shiftly_private.payroll_receipt_quote(text) from public,anon,authenticated;

create or replace function shiftly_private.payroll_receipt_access(p_name text,p_operation text)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare payment public.payroll_payments; payment_id uuid;
begin
  if not shiftly_private.payroll_actor_active() then return false; end if;
  payment_id:=shiftly_private.payroll_receipt_quote(p_name);
  if payment_id is null then return false; end if;
  select * into payment from public.payroll_payments where id=payment_id;
  if not found or split_part(p_name,'/',1)<>payment.company_id::text
      or split_part(p_name,'/',2)<>payment.user_id::text then return false; end if;
  if p_operation='read' and payment.status='paid' and payment.receipt_path=p_name then
    return shiftly_private.payroll_readable(payment.company_id,payment.user_id);
  end if;
  if not shiftly_private.payroll_manager(payment.company_id) then return false; end if;
  if p_operation='upload' then return payment.status='prepared'; end if;
  if p_operation='delete' then return payment.status<>'paid' or payment.receipt_path<>p_name; end if;
  return p_operation='read' and payment.status in ('prepared','cancelled');
end
$$;
revoke all on function shiftly_private.payroll_receipt_access(text,text) from public,anon;
grant execute on function shiftly_private.payroll_receipt_access(text,text) to authenticated;

-- Financial evidence must never inherit permissive policies from unrelated buckets.
do $storage$
begin
  if to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null then
    insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
    values('payroll-receipts','payroll-receipts',false,8388608,array['image/jpeg','image/png','image/webp'])
    on conflict(id) do update set public=false,file_size_limit=8388608,
      allowed_mime_types=array['image/jpeg','image/png','image/webp'];
    execute 'drop policy if exists "payroll receipts read" on storage.objects';
    execute 'create policy "payroll receipts read" on storage.objects for select to authenticated using (bucket_id=''payroll-receipts'' and shiftly_private.payroll_receipt_access(name,''read''))';
    execute 'drop policy if exists "payroll receipts upload" on storage.objects';
    execute 'create policy "payroll receipts upload" on storage.objects for insert to authenticated with check (bucket_id=''payroll-receipts'' and shiftly_private.payroll_receipt_access(name,''upload''))';
    execute 'drop policy if exists "payroll receipts cleanup" on storage.objects';
    execute 'create policy "payroll receipts cleanup" on storage.objects for delete to authenticated using (bucket_id=''payroll-receipts'' and shiftly_private.payroll_receipt_access(name,''delete''))';
    execute 'drop policy if exists "payroll receipts restrictive read" on storage.objects';
    execute 'create policy "payroll receipts restrictive read" on storage.objects as restrictive for select to authenticated using (bucket_id<>''payroll-receipts'' or shiftly_private.payroll_receipt_access(name,''read''))';
    execute 'drop policy if exists "payroll receipts restrictive upload" on storage.objects';
    execute 'create policy "payroll receipts restrictive upload" on storage.objects as restrictive for insert to authenticated with check (bucket_id<>''payroll-receipts'' or shiftly_private.payroll_receipt_access(name,''upload''))';
    execute 'drop policy if exists "payroll receipts no overwrite" on storage.objects';
    execute 'create policy "payroll receipts no overwrite" on storage.objects as restrictive for update to public using (bucket_id<>''payroll-receipts'') with check (bucket_id<>''payroll-receipts'')';
    execute 'drop policy if exists "payroll receipts restrictive cleanup" on storage.objects';
    execute 'create policy "payroll receipts restrictive cleanup" on storage.objects as restrictive for delete to authenticated using (bucket_id<>''payroll-receipts'' or shiftly_private.payroll_receipt_access(name,''delete''))';
    execute 'drop policy if exists "payroll receipts anonymous denied" on storage.objects';
    execute 'create policy "payroll receipts anonymous denied" on storage.objects as restrictive for all to anon using (bucket_id<>''payroll-receipts'') with check (bucket_id<>''payroll-receipts'')';
  end if;
end
$storage$;

alter table public.shift_notifications add column if not exists payroll_payment_id uuid
  references public.payroll_payments(id) on delete restrict;
create index if not exists payroll_notification_payment_idx on public.shift_notifications(payroll_payment_id)
  where payroll_payment_id is not null;
alter table public.shift_notifications drop constraint if exists shift_notifications_event_check;
alter table public.shift_notifications add constraint shift_notifications_event_check check
  (event in ('created','updated','cancelled','attendance_in','attendance_out','join_request','employment_changed','payroll_paid'));

create or replace function shiftly_private.finalize_payroll_payment(
  p_id uuid,p_receipt_path text,p_transfer_date date,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare payment public.payroll_payments; total_paid numeric; proof record; today date:=shiftly_private.payroll_today();
begin
  select * into payment from public.payroll_payments where id=p_id;
  if not found or not shiftly_private.payroll_manager(payment.company_id) then
    raise exception 'Chỉ Manager của công ty được xác nhận thanh toán' using errcode='P4550';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(payment.company_id::text||payment.user_id::text||payment.pay_month::text,0));
  select * into payment from public.payroll_payments where id=p_id for update;
  if payment.status='paid' then return to_jsonb(payment); end if;
  if payment.status<>'prepared' then raise exception 'Bảng chốt đã hủy, không thể xác nhận' using errcode='P4555'; end if;
  if p_transfer_date is null or p_transfer_date>today
    or p_transfer_date<(payment.pay_month+interval '1 month')::date+4 then
    raise exception 'Ngày chuyển khoản phải từ ngày 5 tháng kế tiếp và không ở tương lai' using errcode='P4553';
  end if;
  if char_length(coalesce(p_note,''))>500 then raise exception 'Ghi chú tối đa 500 ký tự' using errcode='P4558'; end if;
  if shiftly_private.payroll_receipt_quote(p_receipt_path) is distinct from p_id
    or split_part(p_receipt_path,'/',1)<>payment.company_id::text
    or split_part(p_receipt_path,'/',2)<>payment.user_id::text then
    raise exception 'Ảnh chuyển khoản không thuộc bảng chốt này' using errcode='P4557';
  end if;
  select o.* into proof from storage.objects o where o.bucket_id='payroll-receipts' and o.name=p_receipt_path;
  if not found or (coalesce(proof.owner_id,'')<>auth.uid()::text and proof.owner is distinct from auth.uid())
    or coalesce(proof.metadata->>'mimetype','') not in ('image/jpeg','image/png','image/webp')
    or coalesce((proof.metadata->>'size')::numeric,0) not between 1 and 8388608 then
    raise exception 'Cần tải ảnh chuyển khoản hợp lệ trước khi xác nhận' using errcode='P4557';
  end if;
  select coalesce(sum(p.amount_vnd),0) into total_paid from public.payroll_payments p
    where p.company_id=payment.company_id and p.user_id=payment.user_id and p.pay_month=payment.pay_month and p.status='paid';
  if total_paid<>payment.paid_before_vnd then
    raise exception 'Số đã trả vừa thay đổi. Hãy đối chiếu lại trước khi tiếp tục' using errcode='P4556';
  end if;
  update public.payroll_payments set status='paid',receipt_path=p_receipt_path,transfer_date=p_transfer_date,
    note=btrim(coalesce(p_note,'')),paid_by=auth.uid(),paid_at=now() where id=p_id returning * into payment;
  insert into public.shift_notifications(user_id,company_id,event,title,body,payroll_payment_id)
  values(payment.user_id,payment.company_id,'payroll_paid',
    'Đã thanh toán lương tháng '||to_char(payment.pay_month,'MM/YYYY'),
    coalesce(payment.snapshot->>'company_name','Công ty')||' đã ghi nhận chuyển khoản '||
      replace(to_char(payment.amount_vnd,'FM999,999,999,999,999,990'),',','.')||' đ cho kỳ lương tháng '||
      to_char(payment.pay_month,'MM/YYYY')||'. Mở để xem chứng từ.',payment.id);
  return to_jsonb(payment);
end
$$;
revoke all on function shiftly_private.finalize_payroll_payment(uuid,text,date,text) from public,anon;
grant execute on function shiftly_private.finalize_payroll_payment(uuid,text,date,text) to authenticated;
create or replace function public.finalize_payroll_payment(p_id uuid,p_receipt_path text,p_transfer_date date,p_note text default '')
returns jsonb language sql security invoker set search_path='' as $$
  select shiftly_private.finalize_payroll_payment(p_id,p_receipt_path,p_transfer_date,p_note)
$$;
revoke all on function public.finalize_payroll_payment(uuid,text,date,text) from public,anon;
grant execute on function public.finalize_payroll_payment(uuid,text,date,text) to authenticated;

create or replace function shiftly_private.payroll_payment_history(
  p_company uuid default null,p_month date default null,p_limit integer default 10,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare company_manager boolean:=false; total bigint; result jsonb;
begin
  if not shiftly_private.payroll_actor_active() then raise exception 'Không có quyền xem lịch sử lương' using errcode='P4550'; end if;
  if p_company is not null then company_manager:=shiftly_private.payroll_manager(p_company); end if;
  if p_limit is null or p_offset is null or p_limit not between 1 and 50 or p_offset<0 or p_offset>1000000 then
    raise exception 'Phân trang không hợp lệ' using errcode='P4551';
  end if;
  select count(*) into total from public.payroll_payments p where p.status='paid'
    and (p_company is null or p.company_id=p_company) and (p_month is null or p.pay_month=p_month)
    and (company_manager or p.user_id=auth.uid());
  select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('snapshot',t.snapshot-'shifts')
    order by t.paid_at desc,t.id desc),'[]'::jsonb) into result from (
    select p.* from public.payroll_payments p where p.status='paid'
      and (p_company is null or p.company_id=p_company) and (p_month is null or p.pay_month=p_month)
      and (company_manager or p.user_id=auth.uid())
    order by p.paid_at desc,p.id desc limit p_limit offset p_offset
  ) t;
  return jsonb_build_object('rows',result,'total',total);
end
$$;
revoke all on function shiftly_private.payroll_payment_history(uuid,date,integer,integer) from public,anon;
grant execute on function shiftly_private.payroll_payment_history(uuid,date,integer,integer) to authenticated;
create or replace function public.payroll_payment_history(
  p_company uuid default null,p_month date default null,p_limit integer default 10,p_offset integer default 0)
returns jsonb language sql stable security invoker set search_path='' as $$
  select shiftly_private.payroll_payment_history(p_company,p_month,p_limit,p_offset)
$$;
revoke all on function public.payroll_payment_history(uuid,date,integer,integer) from public,anon;
grant execute on function public.payroll_payment_history(uuid,date,integer,integer) to authenticated;

create or replace function public.payroll_payment_detail(p_id uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
  select to_jsonb(p)||jsonb_build_object('snapshot',p.snapshot-'shifts')
    from public.payroll_payments p where p.id=p_id and p.status='paid'
$$;
revoke all on function public.payroll_payment_detail(uuid) from public,anon;
grant execute on function public.payroll_payment_detail(uuid) to authenticated;

notify pgrst,'reload schema';
