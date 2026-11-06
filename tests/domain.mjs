import assert from 'node:assert/strict'
import { hours, shiftRows, roleLabel, preferredCompanyId, shiftUpdate } from '../src/domain/calendar.js'

const input = { title: '  Lắp sân khấu  ', location: 'Nhà hát', date: '2026-11-05', end_date: '2026-11-05', start: '08:00', end: '12:00', cast_vnd: 300000, user_ids: ['one', 'two'] }
const rows = shiftRows(input, 'company')
assert.equal(rows.length, 2)
assert.equal(rows[0].title, 'Lắp sân khấu')
assert.equal(hours(rows[0]), '4.00')
assert.equal(roleLabel('admin'), 'Quản trị hệ thống')
assert.equal(roleLabel('manager'), 'Manager')
assert.throws(() => shiftRows({ ...input, user_ids: [] }, 'company'), /nhân viên/)
assert.throws(() => shiftRows({ ...input, end: '07:00' }, 'company'), /kết thúc/)
assert.throws(() => shiftRows({ ...input, location: '  ' }, 'company'), /địa điểm/)
assert.throws(() => shiftRows({ ...input, cast_vnd: -1 }, 'company'), /Cast/)
assert.throws(() => shiftRows(input, ''), /công ty/)
assert.equal(shiftRows({ ...input, user_ids: ['one','one','two'] }, 'company').length, 2)
const existing = [{ ...rows[0], id: 'existing' }]
assert.throws(() => shiftRows(input, 'company', existing), /trùng/)
assert.doesNotThrow(() => shiftRows({ ...input, date: '2026-11-06', start: '02:00', end: '04:00' }, 'company', existing))
assert.equal(preferredCompanyId([{id:'staff-company',role:'staff'},{id:'owner-company',role:'manager'}]),'owner-company')
assert.equal(preferredCompanyId([{id:'staff-company',role:'staff'},{id:'owner-company',role:'manager'}],'staff-company'),'owner-company')
assert.equal(preferredCompanyId([]),'')
const current = { ...rows[0], id: 'one-shift' }
const changed = shiftUpdate({...input, user_ids:['one'], title:' Chương trình mới '}, 'company','one-shift',[current])
assert.equal(changed.title,'Chương trình mới')
assert.equal(changed.user_id,'one')
assert.throws(()=>shiftUpdate({...input,user_ids:['one','two']},'company','one-shift',[current]),/một nhân viên/)
assert.throws(()=>shiftUpdate({...input,user_ids:['one']},'company','one-shift',[current,{...rows[1], user_id:'one', id:'another'}]),/trùng/)
assert.equal(rows[0].cast_vnd,300000)
console.log('Single-day shift validation, cast, duplicates, overlap and roles: OK')
