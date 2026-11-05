import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const db = new PGlite();
const admin = '11111111-1111-4111-8111-111111111111';
const manager = '22222222-2222-4222-8222-222222222222';
const staff = '33333333-3333-4333-8333-333333333333';
const outsider = '44444444-4444-4444-8444-444444444444';

await db.exec(`
  create role authenticated;
  create schema auth;
  create table auth.users(id uuid primary key, email text, email_confirmed_at timestamptz, last_sign_in_at timestamptz default now(), raw_user_meta_data jsonb default '{}', raw_app_meta_data jsonb default '{}');
  create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
  create function auth.uid() returns uuid language sql stable as $$ select (auth.jwt()->>'sub')::uuid $$;
  grant usage on schema auth to authenticated;
  grant execute on function auth.jwt(),auth.uid() to authenticated;
  alter default privileges in schema public grant select,insert,update,delete on tables to authenticated;
`);
await db.query(`insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data,raw_app_meta_data) values
 ($1,'admin@example.com',now(),'{"full_name":"Admin"}','{"role":"admin"}'),
 ($2,'manager@example.com',now(),'{"full_name":"Manager"}','{}'),
 ($3,'staff@example.com',now(),'{"full_name":"Staff"}','{}'),
 ($4,'other@example.com',now(),'{"full_name":"Other"}','{}')`,[admin,manager,staff,outsider]);
for (const file of ['supabase/multi_company.sql','supabase/company_approval.sql','supabase/account_controls.sql','supabase/admin_scope.sql','supabase/member_compensation.sql','supabase/shift_business_rules.sql']) {
  await db.exec(await readFile(new URL('../'+file,import.meta.url),'utf8'));
}
async function login(id,role='staff',email='') {
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:id,email,app_metadata:{role}})]);
  await db.exec('set role authenticated');
}
async function expectDenied(fn) {
  await assert.rejects(fn);
}
await login(manager,'staff','manager@example.com');
await expectDenied(()=>db.query("insert into public.company_applications(applicant_id,company_name,address,phone,email) values($1,'ABC Events','12 ABC Street','1234567890','a@example.com')",[manager]));
const application = await db.query("insert into public.company_applications(applicant_id,company_name,address,phone,email) values($1,'ABC Events','12 ABC Street','0912345678','a@example.com') returning id",[manager]);
await expectDenied(()=>db.query('select public.review_company_application($1,true)',[application.rows[0].id]));
await login(admin,'admin','admin@example.com');
await expectDenied(()=>db.query('select public.create_company_by_email($1,$2)',['Forbidden','manager@example.com']));
await db.query('select public.review_company_application($1,true)',[application.rows[0].id]);
const result=await db.query('select id from public.companies where name=$1',['ABC Events']);
assert.equal(result.rows.length,1);
const company=result.rows[0].id;
await login(staff,'staff','staff@example.com');
await db.query('select public.request_company_membership($1)',[company]);
await expectDenied(()=>db.query('select public.review_join_request($1,$2,true)',[company,staff]));
await login(admin,'admin','admin@example.com');
await expectDenied(()=>db.query('select public.review_join_request($1,$2,true)',[company,staff]));
await login(manager,'staff','manager@example.com');
await db.query('select public.review_join_request($1,$2,true)',[company,staff]);
await db.query("insert into public.member_compensation(company_id,user_id,employment_type,monthly_base_vnd,show_rate_vnd) values($1,$2,'employee',8000000,500000)",[company,staff]);
await expectDenied(()=>db.query("insert into public.member_compensation(company_id,user_id,employment_type,monthly_base_vnd,show_rate_vnd) values($1,$2,'freelancer',1,500000)",[company,manager]));
await db.query("insert into public.company_shifts(company_id,user_id,title,starts_at,ends_at) values($1,$2,'Show',now(),now()+interval '4 hours')",[company,staff]);
await expectDenied(()=>db.query("insert into public.company_shifts(company_id,user_id,title,starts_at,ends_at) values($1,$2,'Overlap',now()+interval '1 hour',now()+interval '3 hours')",[company,staff]));
await db.query("insert into public.company_shifts(company_id,user_id,title,starts_at,ends_at) values($1,$2,'Adjacent',now()+interval '4 hours',now()+interval '6 hours')",[company,staff]);
await expectDenied(()=>db.query("insert into public.company_shifts(company_id,user_id,title,starts_at,ends_at) values($1,$2,'Too long',now()+interval '6 hours',now()+interval '36 hours')",[company,staff]));
await db.query("insert into public.company_invitations(company_id,email) values($1,'other@example.com')",[company]);
await login(outsider,'staff','other@example.com');
assert.equal((await db.query('select * from public.member_compensation')).rows.length,0);
assert.equal((await db.query('select * from public.company_shifts')).rows.length,0);
await expectDenied(()=>db.query("insert into public.company_shifts(company_id,user_id,title,starts_at,ends_at) values($1,$2,'Unauthorized',now(),now()+interval '1 hour')",[company,staff]));
assert.equal((await db.query('select * from public.company_members where company_id=$1',[company])).rows.length,0);
const invitation=await db.query("select id from public.company_invitations where email='other@example.com'");
assert.equal(invitation.rows.length,1);
await db.query('select public.accept_company_invitation($1)',[invitation.rows[0].id]);
assert.equal((await db.query('select * from public.company_members where company_id=$1 and user_id=$2',[company,outsider])).rows.length,1);
await login(staff,'staff','staff@example.com');
assert.equal((await db.query('select * from public.member_compensation')).rows.length,1);
assert.equal((await db.query('update public.member_compensation set show_rate_vnd=1 returning *')).rows.length,0);
assert.equal((await db.query('select * from public.company_shifts')).rows.length,2);
await expectDenied(()=>db.query('select public.admin_set_account_disabled($1,true,$2)',[manager,'Không hợp lệ']));
await login(admin,'admin','admin@example.com');
assert.equal((await db.query('select * from public.member_compensation')).rows.length,0);
assert.equal((await db.query('select * from public.company_shifts')).rows.length,0);
assert.equal((await db.query('select * from public.planned_attendance')).rows.length,0);
await expectDenied(()=>db.query("insert into public.company_shifts(company_id,user_id,title,starts_at,ends_at) values($1,$2,'Unauthorized',now(),now()+interval '1 hour')",[company,staff]));
await expectDenied(()=>db.query('select public.admin_add_company_member($1,$2)',[company,'staff@example.com']));
const listing = await db.query('select * from public.admin_company_directory()');
assert.equal(listing.rows.length,1);
assert.equal(listing.rows[0].manager_email,'manager@example.com');
assert.equal((await db.query('select * from public.admin_list_accounts()')).rows.length,4);
await db.query('select public.admin_set_account_disabled($1,true,$2)',[staff,'Kiểm thử']);
await login(staff,'staff','staff@example.com');
assert.equal((await db.query('select * from public.company_shifts')).rows.length,0);
await expectDenied(()=>db.query('select public.request_company_membership($1)',[company]));
assert.equal((await db.query('select * from public.companies')).rows.length,0);
await expectDenied(()=>db.query("insert into public.company_applications(applicant_id,company_name,address,phone,email) values($1,'ABC Events','12 ABC Street','0912345678','a@example.com')",[staff]));
await login(admin,'admin','admin@example.com');
await db.query('select public.admin_set_account_disabled($1,false,$2)',[staff,'Khôi phục']);
await db.query('select public.admin_set_company_manager($1,$2)',[company,staff]);
await login(staff,'staff','staff@example.com');
assert.equal((await db.query('select * from public.company_shifts')).rows.length,2);
await db.close();
console.log('Database roles, admin/manager isolation, shift overlaps, limits, and account controls: OK');
