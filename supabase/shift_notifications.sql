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
