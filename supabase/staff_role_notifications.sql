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
