import assert from 'node:assert/strict'
import { hours, shiftRows, roleLabel, preferredCompanyId } from '../src/domain/calendar.js'

const input = { title: '  Lắp sân khấu  ', location: 'Nhà hát', date: '2026-11-05', end_date: '2026-11-06', start: '22:00', end: '02:00', user_ids: ['one', 'two'] }
const rows = shiftRows(input, 'company')
assert.equal(rows.length, 2)
assert.equal(rows[0].title, 'Lắp sân khấu')
assert.equal(hours(rows[0]), '4.00')
assert.equal(roleLabel('admin'), 'Quản trị hệ thống')
assert.throws(() => shiftRows({ ...input, user_ids: [] }, 'company'), /nhân viên/)
assert.throws(() => shiftRows({ ...input, end_date: input.date }, 'company'), /kết thúc/)
assert.throws(() => shiftRows({ ...input, location: '  ' }, 'company'), /địa điểm/)
assert.throws(() => shiftRows({ ...input, end_date: '2026-11-08' }, 'company'), /24 giờ/)
assert.throws(() => shiftRows(input, ''), /công ty/)
assert.equal(shiftRows({ ...input, user_ids: ['one','one','two'] }, 'company').length, 2)
const existing = [{ ...rows[0], id: 'existing' }]
assert.throws(() => shiftRows(input, 'company', existing), /trùng/)
assert.doesNotThrow(() => shiftRows({ ...input, date: '2026-11-06', end_date: '2026-11-06', start: '02:00', end: '04:00' }, 'company', existing))
assert.equal(preferredCompanyId([{id:'staff-company',role:'staff'},{id:'owner-company',role:'manager'}]),'owner-company')
assert.equal(preferredCompanyId([{id:'staff-company',role:'staff'},{id:'owner-company',role:'manager'}],'staff-company'),'owner-company')
assert.equal(preferredCompanyId([]),'')
console.log('Shift validation, duplicates, overlap, overnight hours and roles: OK')
