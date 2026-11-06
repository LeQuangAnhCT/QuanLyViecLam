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
