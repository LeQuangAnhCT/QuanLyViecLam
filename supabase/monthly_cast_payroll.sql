-- Non-destructive upgrade: replace legacy per-show estimate with per-shift Cast
-- and a monthly allowance. Historic show_rate_vnd stays for compatibility but is ignored.
alter table public.member_compensation
  add column if not exists monthly_allowance_vnd numeric(14,0) not null default 0;
alter table public.member_compensation drop constraint if exists member_compensation_monthly_allowance_valid;
alter table public.member_compensation add constraint member_compensation_monthly_allowance_valid
  check (monthly_allowance_vnd >= 0);
alter table public.member_compensation alter column show_rate_vnd set default 0;

-- PostgreSQL requires DROP before changing an existing table-return signature.
alter table public.shift_attendance add column if not exists expense_total_vnd bigint not null default 0;

drop function if exists public.company_staff_summary(uuid,date);
create function public.company_staff_summary(p_company uuid,p_month date)
returns table (
  user_id uuid, full_name text, email text, employment_type text,
  monthly_base_vnd numeric, monthly_allowance_vnd numeric,
  scheduled_shifts bigint, completed_shifts bigint, worked_hours numeric,
  planned_cast_vnd numeric, cast_total_vnd numeric, estimated_total_vnd numeric
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
    coalesce(sum(s.cast_vnd),0)::numeric,
    coalesce(sum(s.cast_vnd + coalesce(a.expense_total_vnd,0)) filter (where a.checked_out_at is not null),0)::numeric,
    (coalesce(p.monthly_base_vnd,0) + p.monthly_allowance_vnd +
      coalesce(sum(s.cast_vnd + coalesce(a.expense_total_vnd,0)) filter (where a.checked_out_at is not null),0))::numeric
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
revoke all on function public.company_staff_summary(uuid,date) from public, anon;
grant execute on function public.company_staff_summary(uuid,date) to authenticated;
notify pgrst, 'reload schema';
