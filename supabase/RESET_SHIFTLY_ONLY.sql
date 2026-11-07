-- DANGER: THIS ERASES ALL SHIFTLY BUSINESS DATA AND PROFILE DATA.
-- Only run when deliberately rebuilding an existing Shiftly database.
-- Back up the project first. This does NOT delete Supabase auth.users,
-- auth providers, OAuth settings, or avatar objects in Storage.
-- After this succeeds, run FULL_SETUP_FROM_SCRATCH.sql in SQL Editor.
-- DO NOT run in production unless you intend to destroy Shiftly data.
begin;

-- Remove the profile-provisioning hook before dropping its table.
drop trigger if exists on_auth_user_created on auth.users;

-- Tables in dependency-safe order. CASCADE also removes dependent Shiftly views.
drop table if exists public.payroll_overtime_allowances cascade;

drop table if exists public.payroll_payments cascade;

drop table if exists public.shift_attendance cascade;
drop table if exists public.shift_notifications cascade;
drop table if exists public.member_compensation cascade;
drop table if exists public.company_shifts cascade;
drop table if exists public.company_join_requests cascade;
drop table if exists public.company_invitations cascade;
drop table if exists public.company_applications cascade;
drop table if exists public.account_restrictions cascade;
drop table if exists public.freelancer_profiles cascade;
drop table if exists public.company_members cascade;

drop table if exists public.company_deletion_log cascade;
drop table if exists public.companies cascade;
drop table if exists public.shifts cascade;
drop table if exists public.profiles cascade;

commit;
