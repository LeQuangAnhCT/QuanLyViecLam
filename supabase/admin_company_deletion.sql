-- Admin deletion is explicit, audited and independent of company business state.
create schema if not exists shiftly_private;
create table if not exists public.company_deletion_log (
  id uuid primary key,
  company_id uuid not null unique,
  company_name text not null,
  company_snapshot jsonb not null,
  reason text not null check (char_length(btrim(reason)) between 1 and 500),
  deleted_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz not null default now(),
  transaction_id bigint not null,
  receipt_paths text[] not null default '{}',
  files_deleted_at timestamptz
);
create index if not exists company_deletion_history_idx on public.company_deletion_log(deleted_at desc);
create index if not exists company_deletion_actor_idx on public.company_deletion_log(deleted_by);
alter table public.company_deletion_log enable row level security;
revoke all on public.company_deletion_log from public,anon,authenticated;
grant select on public.company_deletion_log to authenticated;
do $$ begin
  if exists(select 1 from pg_roles where rolname='service_role') then
    execute 'grant select,update on public.company_deletion_log to service_role';
  end if;
end $$;
drop policy if exists "admins read company deletion reasons" on public.company_deletion_log;
create policy "admins read company deletion reasons" on public.company_deletion_log
  for select to authenticated using (
    (select auth.uid()) is not null and public.account_active()
    and coalesce((select auth.jwt())->'app_metadata'->>'role','')='admin'
  );

-- Only an audit row created by the deletion RPC in this transaction opens the bypass.
-- Clients cannot insert audit rows, and old audit rows never authorize another transaction.
create or replace function shiftly_private.company_deletion_allowed(p_company uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and public.account_active()
    and coalesce(auth.jwt()->'app_metadata'->>'role','')='admin'
    and exists(select 1 from public.company_deletion_log d where d.company_id=p_company
      and d.deleted_by=auth.uid() and d.transaction_id=txid_current())
$$;
revoke all on function shiftly_private.company_deletion_allowed(uuid) from public,anon,authenticated;

create or replace function shiftly_private.require_company_deletion_reason()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if not shiftly_private.company_deletion_allowed(old.id) then
    raise exception 'Chỉ Admin được xóa công ty và phải nhập lý do xóa' using errcode='P4560';
  end if;
  return old;
end
$$;
revoke all on function shiftly_private.require_company_deletion_reason() from public,anon,authenticated;
drop trigger if exists company_deletion_requires_reason on public.companies;
create trigger company_deletion_requires_reason before delete on public.companies
  for each row execute function shiftly_private.require_company_deletion_reason();

create or replace function shiftly_private.admin_delete_company(p_company uuid,p_reason text,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare company public.companies; entry public.company_deletion_log; paths text[];
begin
  if auth.uid() is null or not public.account_active()
    or coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then
    raise exception 'Chỉ Admin được xóa công ty' using errcode='P4560';
  end if;
  if p_company is null or p_request is null or char_length(btrim(coalesce(p_reason,''))) not between 1 and 500 then
    raise exception 'Nhập lý do xóa công ty, tối đa 500 ký tự' using errcode='P4561';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('delete-company:'||p_company::text,0));
  select * into entry from public.company_deletion_log where id=p_request;
  if found then
    if entry.company_id<>p_company or entry.reason<>btrim(p_reason) then
      raise exception 'Mã yêu cầu xóa đã được sử dụng' using errcode='P4562';
    end if;
    return to_jsonb(entry)-'transaction_id'-'company_snapshot';
  end if;
  select * into entry from public.company_deletion_log where company_id=p_company;
  if found then return to_jsonb(entry)-'transaction_id'-'company_snapshot'; end if;
  select * into company from public.companies where id=p_company for update;
  if not found then raise exception 'Công ty không còn tồn tại. Hãy làm mới danh sách.' using errcode='P4563'; end if;
  -- Block new assignments while the company's dependent rows are being removed.
  perform 1 from public.company_members where company_id=p_company for update;
  paths:='{}';
  if to_regclass('storage.objects') is not null then
    select coalesce(array_agg(o.name),'{}'::text[]) into paths from storage.objects o
      where o.bucket_id='payroll-receipts' and o.name like p_company::text||'/%';
  end if;
  insert into public.company_deletion_log(id,company_id,company_name,company_snapshot,reason,deleted_by,transaction_id,receipt_paths,files_deleted_at)
    values(p_request,p_company,company.name,to_jsonb(company),btrim(p_reason),auth.uid(),txid_current(),paths,
      case when cardinality(paths)=0 then now() end) returning * into entry;

  delete from public.shift_notifications where company_id=p_company
    or payroll_payment_id in (select id from public.payroll_payments where company_id=p_company);
  delete from public.payroll_overtime_allowances where company_id=p_company;
  delete from public.payroll_payments where company_id=p_company;
  delete from public.shift_attendance where company_id=p_company;
  delete from public.company_shifts where company_id=p_company;
  -- Shift-deletion triggers may create cancellation notices; these belong to the removed company.
  delete from public.shift_notifications where company_id=p_company;
  delete from public.company_applications where company_id=p_company;
  delete from public.companies where id=p_company;
  return to_jsonb(entry)-'transaction_id'-'company_snapshot';
end
$$;
revoke all on function shiftly_private.admin_delete_company(uuid,text,uuid) from public,anon;
grant execute on function shiftly_private.admin_delete_company(uuid,text,uuid) to authenticated;
create or replace function public.admin_delete_company(p_company uuid,p_reason text,p_request uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select shiftly_private.admin_delete_company(p_company,p_reason,p_request)
$$;
revoke all on function public.admin_delete_company(uuid,text,uuid) from public,anon;
grant execute on function public.admin_delete_company(uuid,text,uuid) to authenticated;

-- The paid-record guards are replaced below with a narrowly scoped deletion exception.

create or replace function shiftly_private.protect_payroll_payment()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' and shiftly_private.company_deletion_allowed(old.company_id) then return old; end if;
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

create or replace function shiftly_private.protect_overtime_allowance()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' and shiftly_private.company_deletion_allowed(old.company_id) then return old; end if;
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

notify pgrst,'reload schema';
