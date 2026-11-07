-- Display credited hours from completed shift schedules; preserve attendance logs and separate overtime.
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
      coalesce(sum(greatest(0,extract(epoch from(s.ends_at-s.starts_at))*1000))
        filter(where s.checked_out_at is not null),0)::bigint as completed_shift_ms,
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
      coalesce(s.completed_shift_ms,0) as completed_shift_ms,
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

notify pgrst,'reload schema';
