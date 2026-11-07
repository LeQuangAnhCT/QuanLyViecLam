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

create policy "members read own compensation and managers read their company" on public.member_compensation
for select to authenticated using (
  public.account_active() and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin'
  and (user_id=auth.uid() or exists (select 1 from public.company_members m
    where m.company_id=member_compensation.company_id and m.user_id=auth.uid() and m.role='manager'))
);
create policy "managers manage their company compensation" on public.member_compensation
for all to authenticated using (
  public.account_active() and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin'
  and exists (select 1 from public.company_members m where m.company_id=member_compensation.company_id and m.user_id=auth.uid() and m.role='manager')
) with check (
  public.account_active() and coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin'
  and exists (select 1 from public.company_members m where m.company_id=member_compensation.company_id and m.user_id=auth.uid() and m.role='manager')
);

