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
