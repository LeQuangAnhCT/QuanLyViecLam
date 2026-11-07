-- Run after FULL_SETUP_FROM_SCRATCH.sql on new projects or on an existing Shiftly database.
alter table public.profiles add column if not exists active_location text;
grant update (active_location) on public.profiles to authenticated;
alter table public.company_shifts add column if not exists cast_vnd bigint not null default 0;
alter table public.company_shifts drop constraint if exists company_shifts_cast_vnd_check;
alter table public.company_shifts add constraint company_shifts_cast_vnd_check check (cast_vnd between 0 and 100000000);
-- Existing manager shift INSERT/UPDATE RLS policies remain in force.
