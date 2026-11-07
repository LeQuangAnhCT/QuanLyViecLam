import { PGlite } from '@electric-sql/pglite'
import { readFile } from 'node:fs/promises'
import assert from 'node:assert/strict'

const db = new PGlite()
const ids = {
  admin: '11111111-1111-4111-8111-111111111111',
  manager: '22222222-2222-4222-8222-222222222222',
  staff: '33333333-3333-4333-8333-333333333333',
  freelance: '44444444-4444-4444-8444-444444444444',
  outsider: '55555555-5555-4555-8555-555555555555',
  company: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  foreign: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  shift: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  lateShift: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  payment: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  request: 'ffffffff-ffff-4fff-8fff-ffffffffffff'
}

async function login(user, role = 'staff') {
  await db.exec('reset role')
  await db.query("select set_config('request.jwt.claims',$1,false)", [
    JSON.stringify({ sub: user, app_metadata: { role } })
  ])
  await db.exec('set role authenticated')
}
async function owner() {
  await db.exec('reset role')
}
async function reject(call, code) {
  await assert.rejects(call, (error) => !code || error.code === code)
}
const rpc = async (name, args = []) =>
  (
    await db.query(
      `select public.${name}(${args.map((_, i) => '$' + (i + 1)).join(',')}) as value`,
      args
    )
  ).rows[0].value
const summary = async (user) =>
  (await rpc('payroll_month_summary', [ids.company, '2026-10-01'])).find(
    (row) => row.user_id === user
  )

try {
  await db.exec(`
    create role anon; create role authenticated;
    create schema auth;
    create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz,last_sign_in_at timestamptz default now(),raw_user_meta_data jsonb default '{}',raw_app_meta_data jsonb default '{}');
    create table public.profiles(id uuid primary key references auth.users(id),full_name text,birth_date date,hometown text);
    create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
    create function auth.uid() returns uuid language sql stable as $$select (auth.jwt()->>'sub')::uuid$$;
    grant usage on schema auth to authenticated;
    grant execute on function auth.jwt(),auth.uid() to authenticated;
    alter default privileges in schema public grant select,insert,update,delete on tables to authenticated;
    create schema storage;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid default gen_random_uuid() primary key,bucket_id text references storage.buckets(id),name text,owner uuid default auth.uid(),owner_id text default auth.uid()::text,metadata jsonb default '{"mimetype":"image/png","size":1024}',unique(bucket_id,name));
    alter table storage.objects enable row level security;
    grant usage on schema storage to authenticated,anon;
    grant select,insert,update,delete on storage.objects to authenticated;
    grant select on storage.objects to anon;
    create function storage.foldername(text) returns text[] language sql immutable as $$select (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1]$$;
  `)
  for (const [name, id] of Object.entries(ids).filter(([name]) =>
    ['admin', 'manager', 'staff', 'freelance', 'outsider'].includes(name)
  )) {
    await db.query(
      'insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data,raw_app_meta_data) values($1,$2,now(),$3,$4)',
      [
        id,
        name + '@example.test',
        JSON.stringify({ full_name: name }),
        JSON.stringify(name === 'admin' ? { role: 'admin' } : {})
      ]
    )
  }
  for (const file of [
    'multi_company',
    'company_approval',
    'account_controls',
    'admin_scope',
    'member_compensation',
    'shift_business_rules',
    'shift_notifications',
    'shift_attendance',
    'staff_business'
  ]) {
    await db.exec(await readFile(new URL('../supabase/' + file + '.sql', import.meta.url), 'utf8'))
  }
  await db.exec(
    await readFile(new URL('../supabase/production_upgrade.sql', import.meta.url), 'utf8')
  )
  const migration = await readFile(
    new URL('../supabase/payroll_settlements.sql', import.meta.url),
    'utf8'
  )
  await db.exec(migration)
  await db.exec(migration)
  await db.exec(
    "create or replace function shiftly_private.payroll_today() returns date language sql stable as $$select date '2026-11-07'$$"
  )
  await db.query(
    "insert into public.companies(id,name) values($1,'Công ty kiểm thử'),($2,'Công ty khác')",
    [ids.company, ids.foreign]
  )
  await db.query(
    "insert into public.company_members(company_id,user_id,role,created_at) values($1,$2,'manager','2026-09-01'),($1,$3,'staff','2026-09-01'),($1,$4,'staff','2026-09-01'),($5,$6,'manager','2026-09-01')",
    [ids.company, ids.manager, ids.staff, ids.freelance, ids.foreign, ids.outsider]
  )
  await db.query(
    "update public.member_compensation set employment_type='employee',monthly_base_vnd=8000000,monthly_allowance_vnd=200000 where company_id=$1 and user_id=$2",
    [ids.company, ids.staff]
  )
  await db.exec('alter table public.company_shifts disable trigger user')
  await db.query(
    "insert into public.company_shifts(id,company_id,user_id,title,location,starts_at,ends_at,cast_vnd) values($1,$2,$3,'Âm thanh','Đà Nẵng','2026-10-20T08:00:00+07','2026-10-20T12:00:00+07',500000)",
    [ids.shift, ids.company, ids.staff]
  )
  await db.exec('alter table public.company_shifts enable trigger user')
  await db.query(
    "insert into public.shift_attendance(shift_id,company_id,user_id,checked_in_at,checked_out_at,expense_total_vnd) values($1,$2,$3,'2026-10-20T08:00:00+07','2026-10-20T13:30:00+07',100000)",
    [ids.shift, ids.company, ids.staff]
  )

  await login(ids.staff)
  assert.equal((await rpc('payroll_month_summary', [ids.company, '2026-10-01'])).length, 1)
  assert.equal((await summary(ids.staff)).overtime_ms, 5400000)
  await reject(
    () => rpc('approve_overtime_allowance', [ids.shift, 300000, '', ids.request]),
    'P4550'
  )
  await reject(
    () => rpc('prepare_payroll_payment', [ids.company, ids.staff, '2026-10-01', ids.payment]),
    'P4550'
  )
  await login(ids.outsider)
  await reject(() => rpc('payroll_month_summary', [ids.company, '2026-10-01']), 'P4550')
  await login(ids.admin, 'admin')
  await reject(() => rpc('payroll_month_summary', [ids.company, '2026-10-01']), 'P4550')
  assert.equal((await db.query('select * from public.payroll_payments')).rows.length, 0)

  await login(ids.manager)
  await owner()
  await db.query(
    'update public.company_members set is_active=false where company_id=$1 and user_id=$2',
    [ids.company, ids.manager]
  )
  await login(ids.manager)
  await reject(
    () => rpc('prepare_payroll_payment', [ids.company, ids.staff, '2026-10-01', ids.payment]),
    'P4550'
  )
  await owner()
  await db.query(
    'update public.company_members set is_active=true where company_id=$1 and user_id=$2',
    [ids.company, ids.manager]
  )
  await db.exec(
    "create or replace function shiftly_private.payroll_today() returns date language sql stable as $$select date '2026-11-04'$$"
  )
  await login(ids.manager)
  await reject(
    () => rpc('prepare_payroll_payment', [ids.company, ids.staff, '2026-10-01', ids.payment]),
    'P4553'
  )
  await owner()
  await db.exec(
    "create or replace function shiftly_private.payroll_today() returns date language sql stable as $$select date '2026-11-05'$$"
  )
  await login(ids.manager)
  await reject(
    () => rpc('prepare_payroll_payment', [ids.company, ids.staff, '2026-10-01', ids.payment]),
    'P4554'
  )
  await reject(() => rpc('approve_overtime_allowance', [ids.shift, 0, '', ids.request]), 'P4558')
  await rpc('approve_overtime_allowance', [
    ids.shift,
    0,
    'Đã thỏa thuận trong Cast',
    crypto.randomUUID()
  ])
  await rpc('approve_overtime_allowance', [ids.shift, 300000, 'Bù 1 giờ 30 phút', ids.request])
  await rpc('approve_overtime_allowance', [ids.shift, 300000, 'Bù 1 giờ 30 phút', ids.request])
  assert.equal((await summary(ids.staff)).remaining_vnd, 9100000)
  const boundaryQuote = await rpc('prepare_payroll_payment', [
    ids.company,
    ids.staff,
    '2026-10-01',
    crypto.randomUUID()
  ])
  await rpc('cancel_payroll_payment', [boundaryQuote.id])
  assert.equal(
    (await rpc('payroll_overtime', [ids.company, '2026-10-01']))[0].locked_by_payment_id,
    null
  )
  await owner()
  await db.exec(
    "create or replace function shiftly_private.payroll_today() returns date language sql stable as $$select date '2026-11-10'$$"
  )
  await login(ids.manager)
  const quote = await rpc('prepare_payroll_payment', [
    ids.company,
    ids.staff,
    '2026-10-01',
    ids.payment
  ])
  assert.equal(quote.amount_vnd, 9100000)
  assert.equal(
    (
      await rpc('prepare_payroll_payment', [
        ids.company,
        ids.staff,
        '2026-10-01',
        crypto.randomUUID()
      ])
    ).id,
    quote.id
  )
  assert.equal((await summary(ids.staff)).paid_vnd, 0)
  await reject(
    () => rpc('approve_overtime_allowance', [ids.shift, 400000, 'Đổi mức bù', crypto.randomUUID()]),
    'P4555'
  )
  const path = `${ids.company}/${ids.staff}/${ids.payment}/${crypto.randomUUID()}.png`
  await reject(
    () => rpc('finalize_payroll_payment', [ids.payment, path, '2026-11-07', '']),
    'P4557'
  )
  await db.query("insert into storage.objects(bucket_id,name) values('payroll-receipts',$1)", [
    path
  ])
  await reject(
    () => rpc('finalize_payroll_payment', [ids.payment, path, '2026-11-11', '']),
    'P4553'
  )
  await reject(
    () => rpc('finalize_payroll_payment', [ids.payment, path, '2026-11-04', '']),
    'P4553'
  )
  await rpc('finalize_payroll_payment', [ids.payment, path, '2026-11-07', 'Lương tháng 10'])
  await rpc('finalize_payroll_payment', [ids.payment, path, '2026-11-07', 'Lương tháng 10'])
  assert.equal((await summary(ids.staff)).remaining_vnd, 0)
  assert.equal((await summary(ids.staff)).payment_count, 1)
  assert.equal((await summary(ids.freelance)).paid_vnd, 0)
  assert.equal(
    (await db.query('delete from storage.objects where name=$1 returning id', [path])).rows.length,
    0
  )
  await reject(() => rpc('cancel_payroll_payment', [ids.payment]), 'P4555')
  await reject(() =>
    db.query('update public.payroll_payments set amount_vnd=1 where id=$1', [ids.payment])
  )

  await login(ids.staff)
  const history = await rpc('payroll_payment_history', [null, null, 10, 0])
  assert.equal(history.total, 1)
  assert.equal(history.rows[0].amount_vnd, 9100000)
  assert.equal('shifts' in history.rows[0].snapshot, false)
  assert.equal(
    (await db.query('select * from storage.objects where name=$1', [path])).rows.length,
    1
  )
  assert.equal(
    (
      await db.query(
        "select count(*)::int as count from public.shift_notifications where event='payroll_paid'"
      )
    ).rows[0].count,
    1
  )
  await login(ids.freelance)
  assert.equal((await rpc('payroll_payment_history', [null, null, 10, 0])).total, 0)
  assert.equal(
    (await db.query('select * from storage.objects where name=$1', [path])).rows.length,
    0
  )

  // A late completion becomes a supplement; the paid base cannot be changed retroactively.
  await owner()
  await db.exec(
    "create or replace function shiftly_private.payroll_today() returns date language sql stable as $$select date '2026-11-11'$$"
  )
  await db.query(
    'update public.member_compensation set monthly_base_vnd=9999999 where company_id=$1 and user_id=$2',
    [ids.company, ids.staff]
  )
  await db.exec('alter table public.company_shifts disable trigger user')
  await db.query(
    "insert into public.company_shifts(id,company_id,user_id,title,location,starts_at,ends_at,cast_vnd) values($1,$2,$3,'Lắp sân khấu','Huế','2026-10-25T08:00:00+07','2026-10-25T12:00:00+07',400000)",
    [ids.lateShift, ids.company, ids.staff]
  )
  await db.exec('alter table public.company_shifts enable trigger user')
  await db.query(
    "insert into public.shift_attendance(shift_id,company_id,user_id,checked_in_at,checked_out_at) values($1,$2,$3,'2026-10-25T08:00:00+07','2026-10-25T11:30:00+07')",
    [ids.lateShift, ids.company, ids.staff]
  )
  await login(ids.manager)
  assert.equal((await summary(ids.staff)).monthly_base_vnd, 8000000)
  assert.equal((await summary(ids.staff)).remaining_vnd, 400000)
  const supplement = await rpc('prepare_payroll_payment', [
    ids.company,
    ids.staff,
    '2026-10-01',
    crypto.randomUUID()
  ])
  assert.equal(supplement.amount_vnd, 400000)
  await rpc('cancel_payroll_payment', [supplement.id])
  assert.equal((await summary(ids.staff)).remaining_vnd, 400000)
  assert.equal((await summary(ids.staff)).pending_payment_id, null)
  await owner()
  // Deactivated workers retain their own paid history and evidence.
  await db.query(
    'update public.company_members set is_active=false where company_id=$1 and user_id=$2',
    [ids.company, ids.staff]
  )
  await login(ids.staff)
  assert.equal((await rpc('payroll_payment_history', [null, null, 10, 0])).total, 1)
  assert.equal((await rpc('payroll_payment_detail', [ids.payment])).amount_vnd, 9100000)
  assert.equal(
    (await db.query('select id from storage.objects where name=$1', [path])).rows.length,
    1
  )
  await login(ids.manager)
  assert.equal((await summary(ids.staff)).remaining_vnd, 400000)
  await owner()
  // Public avatar policies must keep working without granting anonymous salary evidence access.
  await db.exec(
    "insert into storage.buckets(id,name,public) values('avatars','avatars',true); create policy avatars_public on storage.objects for select to public using (bucket_id='avatars'); insert into storage.objects(bucket_id,name) values('avatars','avatar.png'); set role anon;"
  )
  assert.equal((await db.query('select name from storage.objects')).rows.length, 1)
  await owner()
  await assert.rejects(() =>
    db.query('update public.payroll_payments set amount_vnd=1 where id=$1', [ids.payment])
  )
  await assert.rejects(() =>
    db.query('delete from public.payroll_payments where id=$1', [ids.payment])
  )
  // Reapplying the production upgrade must preserve paid snapshots and durable salary notices.
  await db.exec(await readFile(new URL('../supabase/production_upgrade.sql', import.meta.url), 'utf8'))
  assert.equal((await rpc('payroll_payment_history', [ids.company, '2026-10-01', 10, 0])).total, 1)
  await login(ids.manager)
  assert.equal((await rpc('payroll_payment_detail', [ids.payment])).receipt_path, path)
  assert.equal((await summary(ids.staff)).remaining_vnd, 400000)
  await owner()
  for (const name of [
    'payroll_month_summary(uuid,date)',
    'prepare_payroll_payment(uuid,uuid,date,uuid)',
    'finalize_payroll_payment(uuid,text,date,text)',
    'approve_overtime_allowance(uuid,bigint,text,uuid)'
  ]) {
    assert.equal(
      (
        await db.query("select has_function_privilege('anon',$1,'execute') as allowed", [
          'public.' + name
        ])
      ).rows[0].allowed,
      false
    )
  }
  console.log(
    'Payroll settlement, overtime review, private evidence, idempotency and per-person history: OK'
  )
} finally {
  await db.close()
}
